"""Live hardware state, read at walker-arrival time.

The graph built from the device tree describes how the hardware is *wired*.
This module answers whether each piece is currently *working*. Walkers call
into it as they arrive at each node.

Two modes, same interface:

  live    -- read real sysfs on the phone
  replay  -- serve state recorded in a snapshot, so the demo runs on a laptop
             with no hardware attached (and survives the phone dying on stage)

`LIVE` is auto-detected but can be forced with JACOS_MODE=live|replay.
"""

from __future__ import annotations

import os

DT_BASE = "/sys/firmware/devicetree/base"

_forced = os.environ.get("JACOS_MODE", "").strip().lower()
if _forced in ("live", "replay"):
    LIVE = _forced == "live"
else:
    LIVE = os.path.isdir(DT_BASE)


def mode() -> str:
    return "live" if LIVE else "replay"


def _read(path: str, default: str = "") -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except (OSError, PermissionError):
        return default


def _sysfs_name(dt_path: str) -> str:
    """/soc/i2c@78b6000 -> 78b6000.i2c  (how the kernel names platform devices)"""
    leaf = dt_path.rsplit("/", 1)[-1]
    if "@" in leaf:
        name, addr = leaf.split("@", 1)
        return f"{addr}.{name}"
    return leaf


def device_model() -> str:
    """The board's own name for itself, straight from the device tree.

    `/proc/device-tree/model` is NUL-terminated, hence the strip. Empty in
    replay mode, where there is no board to ask -- callers decide what to show
    instead.
    """
    if not LIVE:
        return ""
    return _read("/proc/device-tree/model").replace("\x00", "").strip()


_OF_MAP: dict[str, str] | None = None
_CLK_SUMMARY_MAP: dict[str, dict] | None = None


def _clk_summary_map() -> dict[str, dict]:
    global _CLK_SUMMARY_MAP
    if _CLK_SUMMARY_MAP is not None:
        return _CLK_SUMMARY_MAP
    
    out: dict[str, dict] = {}
    raw = ""
    if LIVE:
        raw = _read("/sys/kernel/debug/clk/clk_summary")
    else:
        snap = os.environ.get("JACOS_SNAPSHOT_CLK", "")
        if snap:
            raw = _read(snap)
        elif os.path.exists("fixtures/clk_summary.txt"):
            raw = _read("fixtures/clk_summary.txt")
        elif os.path.exists("fixtures/perry-snapshot.tar.gz"):
            try:
                import tarfile
                with tarfile.open("fixtures/perry-snapshot.tar.gz", "r:gz") as tar:
                    member = tar.extractfile("jacos-snapshot/clk_summary.txt")
                    if member:
                        raw = member.read().decode("utf-8", errors="replace")
            except Exception:
                pass
                
    if not raw:
        _CLK_SUMMARY_MAP = out
        return out
        
    for line in raw.splitlines()[3:]:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 2:
            name = parts[0]
            try:
                en = int(parts[1])
            except ValueError:
                en = 0
            out[name] = {"enable_count": en, "rate": parts[4] if len(parts) > 4 else "0"}
            
    _CLK_SUMMARY_MAP = out
    return out


def _of_node_map() -> dict[str, str]:
    """Device tree path -> bound driver name (empty string if unbound).

    Built from each sysfs device's `of_node` symlink, which is the kernel's own
    record of which tree node a device came from. Scanned once and cached: a
    walker hits this for all 465 nodes.
    """
    global _OF_MAP
    if _OF_MAP is not None:
        return _OF_MAP
    out: dict[str, str] = {}
    for bus in _BUSES:
        root = f"/sys/bus/{bus}/devices"
        try:
            entries = os.listdir(root)
        except OSError:
            continue
        for entry in entries:
            base = os.path.join(root, entry)
            of = os.path.join(base, "of_node")
            if not os.path.exists(of):
                continue
            try:
                real = os.path.realpath(of)
            except OSError:
                continue
            for prefix in (DT_BASE, "/proc/device-tree"):
                if real.startswith(prefix):
                    dt_path = real[len(prefix):] or "/"
                    drv = ""
                    link = os.path.join(base, "driver")
                    if os.path.islink(link):
                        drv = os.path.basename(os.readlink(link))
                    # An i2c controller shows up twice: as the platform device
                    # that binds a driver and as the adapter that binds none.
                    # Keep whichever actually bound.
                    if dt_path not in out or (drv and not out[dt_path]):
                        out[dt_path] = drv
                    break
    _OF_MAP = out
    return out


def _find_driver(dt_path: str) -> str:
    """Which driver, if any, is currently bound to this device tree node."""
    om = _of_node_map()
    if dt_path in om:
        return om[dt_path]
    # Fallback: the platform device naming convention.
    want = _sysfs_name(dt_path)
    for bus in _BUSES:
        link = f"/sys/bus/{bus}/devices/{want}/driver"
        if os.path.islink(link):
            return os.path.basename(os.readlink(link))
    return ""


def _regulator_state(label: str) -> tuple[str, int]:
    """Look up a regulator by its device tree name, e.g. 'pm8937_l10'."""
    root = "/sys/class/regulator"
    if not os.path.isdir(root):
        return "", 0
    try:
        entries = os.listdir(root)
    except OSError:
        return "", 0
    for entry in entries:
        base = os.path.join(root, entry)
        if _read(os.path.join(base, "name")) == label:
            uv = _read(os.path.join(base, "microvolts"), "0")
            return _read(os.path.join(base, "state")), int(uv) if uv.isdigit() else 0
    return "", 0


# Nodes that legitimately have no driver bound. Flagging these as faults
# buries the real root cause under structural noise -- the device tree root and
# `simple-bus` containers are pure topology, nothing ever probes them.
_NO_DRIVER_EXPECTED = {"simple-bus", "simple-mfd", "simple-pm-bus"}

# Device tree metadata nodes. The spec defines these as description rather
# than hardware, so nothing probes them whatever they happen to carry.
#
# `in_sysfs` alone does not filter them: Raspberry Pi firmware stamps /chosen
# with `compatible = "simple_bus"` and the node does land in sysfs, so on a Pi
# it reported as "NO DRIVER BOUND -- device did not probe". Match on the base
# path so /memory@0 and friends are covered too.
_STRUCTURAL_PATHS = {
    "/", "", "/chosen", "/aliases", "/__symbols__", "/__overrides__",
    "/memory", "/reserved-memory", "/thermal-zones", "/cpus",
}

_BUSES = ("platform", "i2c", "spi", "mmc", "usb", "spmi")


def _norm_compat(c: str) -> str:
    """Normalise a compatible string for comparison.

    Vendors are inconsistent about the separator -- the DT binding is
    `simple-bus`, but Pi firmware emits `simple_bus`. Comparing raw strings
    silently misses the second form.
    """
    return c.strip().lower().replace("_", "-")


def _is_structural_path(path: str) -> bool:
    return path in _STRUCTURAL_PATHS or path.split("@")[0] in _STRUCTURAL_PATHS


def _declared_not_probed(compatible: list) -> bool:
    """Is this node claimed by a subsystem that bypasses the driver model?

    Timers are set up through a `TIMER_OF_DECLARE` table during early boot,
    well before the driver model exists. The node is real hardware and it does
    appear in sysfs, but no platform driver ever binds to it, so "unbound" is
    normal rather than a fault. True of the ARM architected timer on perry
    (`arm,armv8-timer`) and the BCM2835 system timer on the Pi alike -- both
    were reporting as faults before this.
    """
    return any(_norm_compat(c).endswith("-timer") for c in compatible)


def _device_present(dt_path: str) -> bool:
    """Did Linux actually instantiate a device for this device tree node?

    This is the difference between "failed to probe" and "was never a driver
    model device in the first place". Plenty of legitimate device tree nodes --
    opp-table, idle-states, /timer, cpu@N, reserved-memory -- carry a compatible
    string and are still not something a driver ever binds to. Guessing at that
    from compatible strings is a losing game; asking sysfs whether the device
    exists is ground truth.
    """
    if dt_path in _of_node_map():
        return True
    want = _sysfs_name(dt_path)
    return any(os.path.isdir(f"/sys/bus/{bus}/devices/{want}") for bus in _BUSES)


def _expects_driver(path: str, compatible: list | None,
                    in_sysfs: int = -1) -> bool:
    """Could a driver ever have bound here, so that "unbound" means something?

    Order matters. The checks that rule a node out *by construction* run first,
    because they hold no matter what sysfs says. Only then does `in_sysfs`
    decide, and it answers a narrower question than it looks like it does:
    "did the kernel instantiate a device", not "should one have probed".

    Getting that order wrong is the bug this function used to have. `in_sysfs`
    short-circuited every rule below it, so a node that is in sysfs but is pure
    topology (`/chosen`) or claimed by an early subsystem (`/timer`) was
    reported as a failed probe. That went unnoticed because on perry those
    nodes happen to have `in_sysfs == 0` and exited early -- until a second SoC
    turned up where they do not.
    """
    if _is_structural_path(path):
        return False

    compatible = compatible or []
    # Drivers match on compatible strings. With none, nothing can match, so
    # whatever this node is it cannot be a *failed probe*. Perry's
    # /soc@0/cci@1b0c000/i2c-bus@0 is one: the CCI driver registers it as an
    # i2c adapter, and an adapter never has a driver bound in this sense.
    if not compatible:
        return False
    if any(_norm_compat(c) in _NO_DRIVER_EXPECTED for c in compatible):
        return False
    if _declared_not_probed(compatible):
        return False

    # in_sysfs: 1 present, 0 absent, -1 unknown (fall back to the heuristic).
    if in_sysfs >= 0:
        return in_sysfs == 1
    if LIVE:
        return _device_present(path)
    return True


def probe_health(path: str, kind: str, label: str = "",
                 driver: str = "", bound: bool = False,
                 reg_state: str = "", microvolts: int = 0,
                 compatible: list | None = None,
                 in_sysfs: int = -1) -> dict:
    """Assess one node. Returns {healthy, state, detail}.

    In live mode the recorded values are treated as hints and re-read from
    sysfs; in replay mode they are the answer. Either way the walker sees an
    identical shape, which is what keeps the demo and the real thing the same
    code path.
    """
    if kind == "regulator":
        if LIVE and label:
            live_state, live_uv = _regulator_state(label)
            if live_state:
                reg_state, microvolts = live_state, live_uv
        # Only a rail sysfs positively reports as disabled counts as a fault.
        # Some always-on rails (vph_pwr, the raw battery feed) expose an empty
        # `state` file; calling that unhealthy is a false positive, and a
        # diagnostic that cries wolf on the battery rail does not get trusted
        # about the touchscreen.
        healthy = reg_state != "disabled"
        detail = (f"rail {label or path} is {reg_state or 'unknown'}"
                  + (f" at {microvolts/1000:.0f} mV" if microvolts else ""))
        return {"healthy": healthy, "state": reg_state or "unknown", "detail": detail}

    if kind in ("device", "bus"):
        if not _expects_driver(path, compatible, in_sysfs):
            return {"healthy": True, "state": "structural",
                    "detail": "description node -- no driver expected"}
        if LIVE:
            live_drv = _find_driver(path)
            driver, bound = live_drv, bool(live_drv)
        healthy = bool(bound and driver)
        detail = (f"driver '{driver}' bound" if healthy
                  else "NO DRIVER BOUND -- device did not probe")
        return {"healthy": healthy, "state": "bound" if healthy else "unbound",
                "detail": detail}

    if kind == "clock":
        cm = _clk_summary_map()
        clk_name = label or path.split("/")[-1]
        clk_name = clk_name.split("@")[0]
        if not cm:
            return {"healthy": True, "state": "present", "detail": f"{kind} present"}
        if clk_name in cm:
            info = cm[clk_name]
            en = info["enable_count"]
            rate = info["rate"]
            # A clock is healthy if it is enabled (has users) or if its rate is set,
            # but for simple fault-finding, `enable_count > 0` is the strongest signal.
            healthy = en > 0
            state = "enabled" if healthy else "disabled"
            detail = f"clock {clk_name} is {state} (rate: {rate})"
            return {"healthy": healthy, "state": state, "detail": detail}
        else:
            return {"healthy": True, "state": "unknown", "detail": f"clock {clk_name} not found in summary"}

    # Interrupt controllers
    return {"healthy": True, "state": "present", "detail": f"{kind} present"}


def dmesg_tail(pattern: str = "", limit: int = 40) -> str:
    """Recent kernel log lines, optionally filtered. Feeds the LLM explainer."""
    if LIVE:
        try:
            import subprocess
            raw = subprocess.run(["dmesg"], capture_output=True, text=True,
                                 timeout=5).stdout
        except Exception:
            raw = ""
    else:
        snap = os.environ.get("JACOS_SNAPSHOT_DMESG", "")
        raw = _read(snap) if snap else ""

    lines = raw.splitlines()
    if pattern:
        lines = [ln for ln in lines if pattern.lower() in ln.lower()]
    return "\n".join(lines[-limit:])
