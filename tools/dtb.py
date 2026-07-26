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

    if "regulator" in compat_s or "regulator-name" in props or name.startswith("regulator"):
        return "regulator"
    if "#clock-cells" in props or "clock-controller" in compat_s or name in ("clocks", "clock"):
        return "clock"
    if "interrupt-controller" in props:
        return "irq_controller"
    if "#address-cells" in props and "#size-cells" in props and path != "/":
        return "bus"
    return "device"


def build_spec(tree: dict[str, dict], meta: dict) -> dict:
    """Turn the raw property tree into a node/edge spec."""
    # phandle -> path, so cross-tree references can be resolved to real nodes.
    by_phandle: dict[int, str] = {}
    for path, props in tree.items():
        for key in ("phandle", "linux,phandle"):
            v = props.get(key)
            if isinstance(v, int):
                by_phandle[v] = path

    nodes, edges = [], []

    for path, props in sorted(tree.items()):
        compat = props.get("compatible", [])
        if isinstance(compat, str):
            compat = [compat]
        status = props.get("status", "okay")

        nodes.append({
            "path": path,
            "name": path.rsplit("/", 1)[-1] or "/",
            "kind": classify(path, props),
            "compatible": compat if isinstance(compat, list) else [],
            "status": status if isinstance(status, str) else "okay",
            "label": props.get("regulator-name") or props.get("label") or "",
            # Drop phandle noise and anything unserialisable from the payload.
            "props": {
                k: v for k, v in props.items()
                if k not in ("phandle", "linux,phandle", "name")
                and isinstance(v, (str, int, bool, list))
            },
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
                    break  # unresolvable phandle; bail rather than misparse the rest
                width = tree.get(target, {}).get(cells_prop, 0)
                width = width if isinstance(width, int) else 0
                edges.append({
                    "src": path, "dst": target, "kind": kind,
                    "label": names[n] if n < len(names) else "",
                })
                i += 1 + width
                n += 1

        # --- interrupt routing ---------------------------------------------
        for ph in as_cells(props.get("interrupt-parent")):
            target = by_phandle.get(ph)
            if target:
                edges.append({"src": path, "dst": target, "kind": "interrupts_to", "label": ""})

    return {"meta": meta, "nodes": nodes, "edges": edges}


# --------------------------------------------------------------------------
# live-state overlay
# --------------------------------------------------------------------------

def overlay_snapshot(spec: dict, snap_dir: str) -> dict:
    """Fold captured runtime state (driver binding, regulators) into the spec."""
    binding: dict[str, str] = {}
    tsv = os.path.join(snap_dir, "driver-binding.tsv")
    if os.path.exists(tsv):
        with open(tsv, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 3:
                    _bus, dev, drv = parts
                    binding[dev] = drv

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
        leaf = n["name"]
        if "@" in leaf:
            nm, addr = leaf.split("@", 1)
            key = f"{addr}.{nm}"
            if key in binding:
                n["driver"] = binding[key]
                n["bound"] = bool(binding[key])
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

        spec = build_spec(read_tree(dt_base), meta)
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
