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


def _find_driver(dt_path: str) -> str:
    """Which driver, if any, is currently bound to this device tree node."""
    want = _sysfs_name(dt_path)
    for bus in ("platform", "i2c", "spi", "mmc", "usb", "spmi"):
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


def _expects_driver(path: str, compatible: list | None) -> bool:
    if path in ("/", ""):
        return False
    compatible = compatible or []
    if not compatible:
        # No compatible string means nothing can match a driver to it.
        return False
    return not any(c in _NO_DRIVER_EXPECTED for c in compatible)


def probe_health(path: str, kind: str, label: str = "",
                 driver: str = "", bound: bool = False,
                 reg_state: str = "", microvolts: int = 0,
                 compatible: list | None = None) -> dict:
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
        healthy = reg_state == "enabled"
        detail = (f"rail {label or path} is {reg_state or 'unknown'}"
                  + (f" at {microvolts/1000:.0f} mV" if microvolts else ""))
        return {"healthy": healthy, "state": reg_state or "unknown", "detail": detail}

    if kind in ("device", "bus"):
        if not _expects_driver(path, compatible):
            return {"healthy": True, "state": "structural",
                    "detail": "container node -- no driver expected"}
        if LIVE:
            live_drv = _find_driver(path)
            driver, bound = live_drv, bool(live_drv)
        healthy = bool(bound and driver)
        detail = (f"driver '{driver}' bound" if healthy
                  else "NO DRIVER BOUND -- device did not probe")
        return {"healthy": healthy, "state": "bound" if healthy else "unbound",
                "detail": detail}

    # Clock and interrupt controllers: presence in the tree with status okay is
    # the best cheap signal. clk_summary parsing is a stretch goal.
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
