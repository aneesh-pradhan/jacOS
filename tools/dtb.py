"""Device tree -> JacOS graph spec.

The Linux device tree is already a tree of nodes with typed relationships
between them. Jac is a language whose primitives are nodes, edges and walkers.
This module is the bridge: it turns `/sys/firmware/devicetree/base` into a
node/edge spec that `src/importer.jac` materialises as a real Jac graph.

The interesting part is not the tree structure -- that's just directories. It's
the *phandle* references. `vdd-supply = <&pm8937_l10>` is a cross-tree pointer
from a device to its power regulator. Those references are what turn a tree
into a graph, and they are exactly the edges a fault-localisation walker needs
to follow.

Usage:
    python py/dtb.py <snapshot.tar.gz|snapshot_dir|/sys/firmware/devicetree/base> -o out.json
    python py/dtb.py --synthesize -o fixtures/perry.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
import tarfile
import tempfile

# Properties whose value is a bare phandle (or phandle + specifier cells).
SUPPLY_RE = re.compile(r"^(.*)-supply$")

# --------------------------------------------------------------------------
# redaction
# --------------------------------------------------------------------------
# A device tree describes hardware, but a few properties identify the specific
# unit it was captured from. Snapshots are meant to be committed and shared --
# that is the whole point of the replay path -- so strip these by default and
# make keeping them a deliberate act.

_REDACT_EXACT = {"serial-number", "device-serial", "imei"}
_REDACT_SUBSTR = ("mac-address", "ethaddr", "wlan-addr")
_UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}"
                      r"-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
REDACTED = "<redacted>"


def redact_props(props: dict) -> tuple[dict, int]:
    """Strip unit-identifying values, keeping the property itself visible.

    Replacing rather than deleting is deliberate: a reader should be able to
    tell that the node *has* a serial number without learning what it is.
    """
    out, hits = {}, 0
    for k, v in props.items():
        kl = k.lower()
        if kl in _REDACT_EXACT or any(s in kl for s in _REDACT_SUBSTR):
            out[k] = REDACTED
            hits += 1
            continue
        # Filesystem UUIDs ride along in the kernel command line.
        if isinstance(v, str) and _UUID_RE.search(v):
            out[k] = _UUID_RE.sub(REDACTED, v)
            hits += 1
            continue
        out[k] = v
    return out, hits


# Buses where "a device exists but no driver bound" is a genuine probe failure.
# Deliberately excludes cpu/clocksource/nvmem/auxiliary, whose devices are not
# things a driver binds to.
DRIVER_BUSES = {"platform", "i2c", "spi", "mmc", "usb", "spmi"}
CELL_PROPS = {
    # prop name    -> (edge kind, property on target giving specifier cell count)
    "clocks":      ("clocked_by", "#clock-cells"),
    "resets":      ("reset_by", "#reset-cells"),
    "dmas":        ("dma_by", "#dma-cells"),
}


# --------------------------------------------------------------------------
# property decoding
# --------------------------------------------------------------------------

def decode_prop(raw: bytes):
    """Best-effort decode of a device tree property blob.

    Device tree properties are untyped bytes. The kernel's own tooling uses the
    same heuristics: printable+NUL-terminated looks like strings, a multiple of
    4 bytes looks like big-endian u32 cells, anything else stays hex.
    """
    if raw == b"":
        return True  # zero-length property == boolean true (e.g. `regulator-always-on`)

    if raw.endswith(b"\x00") and all(32 <= b < 127 or b == 0 for b in raw):
        parts = [p.decode("ascii") for p in raw.split(b"\x00") if p]
        if parts:
            return parts[0] if len(parts) == 1 else parts

    if len(raw) % 4 == 0:
        cells = list(struct.unpack(f">{len(raw)//4}I", raw))
        return cells[0] if len(cells) == 1 else cells

    return "0x" + raw.hex()


def as_cells(value) -> list[int]:
    """Coerce a decoded property back to a flat list of u32 cells."""
    if isinstance(value, int):
        return [value]
    if isinstance(value, list) and all(isinstance(v, int) for v in value):
        return list(value)
    return []


# --------------------------------------------------------------------------
# tree walk
# --------------------------------------------------------------------------

def read_tree(base: str) -> dict[str, dict]:
    """Walk the devicetree filesystem into {path: {prop: decoded}}."""
    tree: dict[str, dict] = {}
    for dirpath, _dirnames, filenames in os.walk(base):
        rel = os.path.relpath(dirpath, base).replace(os.sep, "/")
        path = "/" if rel == "." else "/" + rel
        props = {}
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            try:
                with open(fp, "rb") as fh:
                    props[fn] = decode_prop(fh.read())
            except (OSError, PermissionError):
                continue
        tree[path] = props
    return tree


def classify(path: str, props: dict) -> str:
    """Bucket a node into a JacOS archetype.

    Kept deliberately shallow -- the walkers care about power/clock/bus roles,
    not about every driver subsystem in the kernel.
    """
    compat = props.get("compatible", "")
    compat_s = " ".join(compat) if isinstance(compat, list) else str(compat)
    name = path.rsplit("/", 1)[-1].split("@")[0]

    # A PMIC rail is a bare child of a regulator container: node name `l10`, no
    # compatible, no regulator-name. What it always has is regulator-* property
    # constraints, so key off those. Matching on compatible alone finds the four
    # board-level regulator-fixed nodes and misses all ~50 real rails.
    if any(k.startswith("regulator-") for k in props):
        return "regulator"
    # ...but not the container itself, whose compatible is `*-regulators` plural
    # and whose only job is to group the rails below it.
    if "regulator" in compat_s and not compat_s.rstrip().endswith("-regulators"):
        return "regulator"
    if name.startswith("regulator") and "regulators" not in name:
        return "regulator"
    if "#clock-cells" in props or "clock-controller" in compat_s or name in ("clocks", "clock"):
        return "clock"
    if "interrupt-controller" in props:
        return "irq_controller"
    if "#address-cells" in props and "#size-cells" in props and path != "/":
        return "bus"
    return "device"


def interrupt_parent_of(path: str, tree: dict[str, dict], by_phandle: dict[int, str]):
    """Resolve a node's interrupt controller, honouring DT inheritance.

    `interrupt-parent` is inherited: a node that declares `interrupts` but no
    `interrupt-parent` routes to the nearest ancestor that does. Resolving it
    self-only is the difference between 6 edges and 60 on a real tree.
    """
    node = path
    while True:
        cells = as_cells(tree.get(node, {}).get("interrupt-parent"))
        if cells:
            return by_phandle.get(cells[0])
        if node == "/":
            return None
        node = node.rsplit("/", 1)[0] or "/"


def build_spec(tree: dict[str, dict], meta: dict, redact: bool = True) -> dict:
    """Turn the raw property tree into a node/edge spec."""
    # phandle -> path, so cross-tree references can be resolved to real nodes.
    by_phandle: dict[int, str] = {}
    for path, props in tree.items():
        for key in ("phandle", "linux,phandle"):
            v = props.get(key)
            if isinstance(v, int):
                by_phandle[v] = path

    nodes, edges = [], []
    unresolved: list[tuple[str, str, int]] = []
    redacted = 0

    for path, props in sorted(tree.items()):
        compat = props.get("compatible", [])
        if isinstance(compat, str):
            compat = [compat]
        status = props.get("status", "okay")

        kind = classify(path, props)
        leaf = path.rsplit("/", 1)[-1] or "/"

        # Drop phandle noise and anything unserialisable from the payload.
        payload = {
            k: v for k, v in props.items()
            if k not in ("phandle", "linux,phandle", "name")
            and isinstance(v, (str, int, bool, list))
        }
        if redact:
            payload, hits = redact_props(payload)
            redacted += hits
        # /sys/class/regulator/*/name reports a PMIC rail by its bare node name
        # ("l10"), so fall back to that when the node carries no regulator-name.
        # Without it every rail on the device has an empty label and nothing in
        # the runtime overlay can match.
        label = props.get("regulator-name") or props.get("label") or ""
        if not label and kind == "regulator":
            label = leaf.split("@")[0]

        nodes.append({
            "path": path,
            "name": leaf,
            "kind": kind,
            "compatible": compat if isinstance(compat, list) else [],
            "status": status if isinstance(status, str) else "okay",
            "label": label if isinstance(label, str) else "",
            # Drop phandle noise and anything unserialisable from the payload.
            "props": payload,
        })

        # --- structural edge: child -> parent bus ---------------------------
        if path != "/":
            parent = path.rsplit("/", 1)[0] or "/"
            if parent in tree:
                edges.append({"src": path, "dst": parent, "kind": "parent_bus", "label": ""})

        # --- power edges: <name>-supply = <&regulator> ----------------------
        for key, val in props.items():
            m = SUPPLY_RE.match(key)
            if not m:
                continue
            for ph in as_cells(val):
                target = by_phandle.get(ph)
                if target:
                    edges.append({
                        "src": path, "dst": target,
                        "kind": "supplied_by", "label": m.group(1),
                    })

        # --- clock / reset / dma edges (phandle + specifier cells) ----------
        for key, (kind, cells_prop) in CELL_PROPS.items():
            cells = as_cells(props.get(key))
            names = props.get(key.rstrip("s") + "-names", [])
            if isinstance(names, str):
                names = [names]
            i, n = 0, 0
            while i < len(cells):
                target = by_phandle.get(cells[i])
                if target is None:
                    # The specifier width lives on the target, so without it we
                    # cannot know how many cells to skip. Bail rather than
                    # misparse the rest of the list into bogus edges.
                    unresolved.append((path, key, cells[i]))
                    break
                width = tree.get(target, {}).get(cells_prop, 0)
                width = width if isinstance(width, int) else 0
                edges.append({
                    "src": path, "dst": target, "kind": kind,
                    "label": names[n] if n < len(names) else "",
                })
                i += 1 + width
                n += 1

        # --- interrupt routing ---------------------------------------------
        # Precedence is defined by the spec:
        #   1. `interrupts-extended` carries its own <&ctrl specifier...> pairs
        #      and overrides everything else.
        #   2. otherwise `interrupts` routes to the inherited interrupt parent.
        # An `interrupt-parent` with no `interrupts` is inherited configuration
        # for descendants, not an interrupt of this node -- no edge for it.
        ext = as_cells(props.get("interrupts-extended"))
        if ext:
            i = 0
            while i < len(ext):
                target = by_phandle.get(ext[i])
                if target is None:
                    unresolved.append((path, "interrupts-extended", ext[i]))
                    break
                width = tree.get(target, {}).get("#interrupt-cells", 0)
                edges.append({"src": path, "dst": target,
                              "kind": "interrupts_to", "label": ""})
                i += 1 + (width if isinstance(width, int) else 0)
        elif "interrupts" in props:
            target = interrupt_parent_of(path, tree, by_phandle)
            if target:
                edges.append({"src": path, "dst": target,
                              "kind": "interrupts_to", "label": ""})

    meta["redacted"] = redacted if redact else -1
    if redacted:
        print(f"[jacos] redacted {redacted} unit-identifying propert"
              f"{'y' if redacted == 1 else 'ies'}", file=sys.stderr)
    elif not redact:
        print("[jacos] WARNING: --keep-identifiers set; snapshot identifies "
              "this specific device", file=sys.stderr)

    if unresolved:
        # Unresolvable phandles stop the parse of that property, because the
        # specifier width lives on the target we just failed to find. Say so --
        # a silently short edge list is the failure mode that hides real gaps.
        print(f"[jacos] warning: {len(unresolved)} unresolvable phandle reference(s)",
              file=sys.stderr)
        for p, prop, ph in unresolved[:5]:
            print(f"[jacos]   {p} {prop} -> phandle 0x{ph:x}", file=sys.stderr)

    return {"meta": meta, "nodes": nodes, "edges": edges}


# --------------------------------------------------------------------------
# live-state overlay
# --------------------------------------------------------------------------

def overlay_snapshot(spec: dict, snap_dir: str) -> dict:
    """Fold captured runtime state (driver binding, regulators) into the spec."""
    # Two indexes: by device tree path (authoritative, from of_node) and by
    # sysfs device name (fallback for captures taken before of_node was
    # recorded, and for devices with no of_node at all).
    by_path: dict[str, str] = {}
    binding: dict[str, str] = {}
    tsv = os.path.join(snap_dir, "driver-binding.tsv")
    if os.path.exists(tsv):
        with open(tsv, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 3:
                    continue
                bus, dev, drv = parts[0], parts[1], parts[2]
                if bus not in DRIVER_BUSES:
                    # cpu, clocksource, nvmem and friends expose devices that
                    # never bind a driver by design. Counting them makes every
                    # CPU core look like a failed probe.
                    continue
                binding[dev] = drv
                of = parts[3] if len(parts) > 3 else ""
                if not of:
                    continue
                # Several sysfs devices can share one tree node -- an i2c
                # controller appears both as the platform device
                # "78b7000.i2c" (which binds i2c_qup) and as the adapter
                # "i2c-1" (which binds nothing). Let a bound entry win, or the
                # adapter overwrites the controller and the bus reads as dead.
                if of not in by_path or (drv and not by_path[of]):
                    by_path[of] = drv

    regs: dict[str, dict] = {}
    rtsv = os.path.join(snap_dir, "regulators.tsv")
    if os.path.exists(rtsv):
        with open(rtsv, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 4 and p[1]:
                    regs[p[1]] = {"state": p[2], "microvolts": p[3]}

    for n in spec["nodes"]:
        # sysfs device names are typically "<unit-addr>.<node-name>", e.g.
        # "78b6000.i2c" for /soc/i2c@78b6000 -- reconstruct and match.
        # Prefer the of_node join; fall back to the platform naming convention
        # "<unit-addr>.<node-name>", e.g. "78b6000.i2c" for /soc/i2c@78b6000.
        leaf = n["name"]
        key = leaf
        if "@" in leaf:
            nm, addr = leaf.split("@", 1)
            key = f"{addr}.{nm}"

        if n["path"] in by_path:
            drv, present = by_path[n["path"]], True
        elif key in binding:
            drv, present = binding[key], True
        else:
            drv, present = "", False

        # Recording *whether the device exists at all*, separately from whether
        # it bound, is what lets replay distinguish "did not probe" from "was
        # never a driver model device". Without it every opp-table and
        # idle-states node reads as a probe failure.
        if binding:
            n["in_sysfs"] = 1 if present else 0
        if present:
            n["driver"] = drv
            n["bound"] = bool(drv)
        if n["kind"] == "regulator" and n.get("label") in regs:
            r = regs[n["label"]]
            n["reg_state"] = r["state"]
            n["microvolts"] = int(r["microvolts"]) if r["microvolts"].isdigit() else 0

    spec["meta"]["has_runtime_overlay"] = bool(binding or regs)
    return spec


# --------------------------------------------------------------------------
# synthetic fixture
# --------------------------------------------------------------------------

def synthesize() -> dict:
    """A small but structurally honest stand-in for perry.

    Shaped like a real MSM8937 tree: an i2c bus hanging off /soc, a touchscreen
    on that bus, both a power rail and a clock behind it, and an interrupt
    controller. Enough topology for the diagnose walker to have somewhere to
    walk. Replace with a real capture as soon as the phone is up.
    """
    N = lambda path, kind, **kw: dict(
        path=path, name=path.rsplit("/", 1)[-1] or "/", kind=kind,
        compatible=kw.pop("compatible", []), status=kw.pop("status", "okay"),
        label=kw.pop("label", ""), props=kw.pop("props", {}), **kw)
    E = lambda s, d, k, l="": dict(src=s, dst=d, kind=k, label=l)

    nodes = [
        N("/", "device", compatible=["motorola,perry", "qcom,msm8937"]),
        N("/soc", "bus"),
        N("/soc/intc@b000000", "irq_controller", compatible=["qcom,msm-qgic2"]),
        N("/soc/clock-controller@1800000", "clock", compatible=["qcom,gcc-msm8937"]),
        N("/soc/spmi@200f000", "bus", compatible=["qcom,spmi-pmic-arb"],
          driver="spmi_pmic_arb", bound=True),
        N("/soc/spmi@200f000/pmic@0", "device", compatible=["qcom,pm8937"],
          driver="qcom_spmi_pmic", bound=True),
        N("/soc/spmi@200f000/pmic@0/regulators/l10", "regulator",
          label="pm8937_l10", compatible=["qcom,rpm-smd-regulator"],
          reg_state="enabled", microvolts=1800000),
        N("/soc/spmi@200f000/pmic@0/regulators/l6", "regulator",
          label="pm8937_l6", compatible=["qcom,rpm-smd-regulator"],
          reg_state="enabled", microvolts=1800000),
        N("/soc/i2c@78b6000", "bus", compatible=["qcom,i2c-qup-v2.2.1"],
          driver="i2c_qup", bound=True),
        N("/soc/i2c@78b6000/touchscreen@20", "device",
          compatible=["synaptics,rmi4-i2c"], driver="rmi4_i2c", bound=True),
        N("/soc/mmc@7824900", "device", compatible=["qcom,sdhci-msm-v4"],
          driver="sdhci_msm", bound=True),
    ]
    edges = [
        E("/soc", "/", "parent_bus"),
        E("/soc/intc@b000000", "/soc", "parent_bus"),
        E("/soc/clock-controller@1800000", "/soc", "parent_bus"),
        E("/soc/spmi@200f000", "/soc", "parent_bus"),
        E("/soc/spmi@200f000/pmic@0", "/soc/spmi@200f000", "parent_bus"),
        E("/soc/i2c@78b6000", "/soc", "parent_bus"),
        E("/soc/i2c@78b6000/touchscreen@20", "/soc/i2c@78b6000", "parent_bus"),
        E("/soc/mmc@7824900", "/soc", "parent_bus"),
        # the chain the demo walks
        E("/soc/i2c@78b6000/touchscreen@20", "/soc/spmi@200f000/pmic@0/regulators/l10",
          "supplied_by", "vdd"),
        E("/soc/i2c@78b6000/touchscreen@20", "/soc/spmi@200f000/pmic@0/regulators/l6",
          "supplied_by", "vio"),
        E("/soc/i2c@78b6000/touchscreen@20", "/soc/intc@b000000", "interrupts_to"),
        E("/soc/i2c@78b6000", "/soc/clock-controller@1800000", "clocked_by", "core"),
        E("/soc/i2c@78b6000", "/soc/spmi@200f000/pmic@0/regulators/l6", "supplied_by", "vdd"),
        E("/soc/mmc@7824900", "/soc/clock-controller@1800000", "clocked_by", "core"),
    ]
    return {
        "meta": {"source": "synthesized", "device": "motorola-perry (synthetic)",
                 "arch": "aarch64", "has_runtime_overlay": True},
        "nodes": nodes, "edges": edges,
    }


# --------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="Device tree -> JacOS graph spec")
    ap.add_argument("source", nargs="?",
                    help="snapshot tarball, snapshot dir, or a devicetree base dir")
    ap.add_argument("-o", "--out", default="-", help="output JSON path ('-' for stdout)")
    ap.add_argument("--synthesize", action="store_true",
                    help="emit a synthetic perry-shaped fixture instead of reading hardware")
    ap.add_argument("--keep-identifiers", action="store_true",
                    help="do NOT redact serial number, MAC addresses and "
                         "filesystem UUIDs. Snapshots are meant to be "
                         "committed, so redaction is the default.")
    ap.add_argument("--break-rail", metavar="LABEL",
                    help="mark a regulator disabled, producing a faulty snapshot "
                         "for offline demos (e.g. --break-rail pm8937_l10)")
    args = ap.parse_args(argv)

    if args.synthesize:
        spec = synthesize()
    else:
        if not args.source:
            ap.error("need a source path (or --synthesize)")

        tmp = None
        src = args.source
        if src.endswith((".tar.gz", ".tgz")):
            tmp = tempfile.mkdtemp(prefix="jacos-")
            with tarfile.open(src) as tf:
                tf.extractall(tmp)  # trusted: produced by our own capture script
            src = os.path.join(tmp, "jacos-snapshot")

        snap_dir = src
        dt_base = os.path.join(src, "devicetree")
        if not os.path.isdir(dt_base):
            dt_base, snap_dir = src, os.path.dirname(src)

        if not os.path.isdir(dt_base):
            sys.exit(f"no device tree at {dt_base}")

        meta = {"source": os.path.abspath(args.source), "device": "motorola-perry"}
        uname = os.path.join(snap_dir, "uname.txt")
        if os.path.exists(uname):
            meta["uname"] = open(uname, encoding="utf-8", errors="replace").read().strip()

        spec = build_spec(read_tree(dt_base), meta,
                          redact=not args.keep_identifiers)
        spec = overlay_snapshot(spec, snap_dir)

    if args.break_rail:
        hits = 0
        for n in spec["nodes"]:
            if n.get("kind") == "regulator" and n.get("label") == args.break_rail:
                n["reg_state"] = "disabled"
                hits += 1
        if not hits:
            sys.exit(f"no regulator labelled {args.break_rail!r} in this snapshot")
        spec["meta"]["injected_fault"] = f"{args.break_rail} disabled"
        print(f"[jacos] injected fault: {args.break_rail} disabled", file=sys.stderr)

    blob = json.dumps(spec, indent=2)
    if args.out == "-":
        print(blob)
    else:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(blob)
        print(f"[jacos] {len(spec['nodes'])} nodes, {len(spec['edges'])} edges -> {args.out}",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
