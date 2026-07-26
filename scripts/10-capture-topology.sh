#!/bin/sh
# JacOS :: topology capture
# Dumps the device tree + relevant sysfs state from the phone into a tarball.
# Pure busybox shell -- no Python needed on the device.
#
#   ssh user@172.16.42.1 'sh -' < scripts/10-capture-topology.sh
#   scp user@172.16.42.1:/tmp/jacos-snapshot.tar.gz fixtures/
#   python py/dtb.py fixtures/jacos-snapshot.tar.gz -o fixtures/perry.json
#
# The resulting snapshot is what lets you develop, demo, and recover from a
# dead phone WITHOUT the hardware attached. Capture early, capture often.

set -u
OUT=/tmp/jacos-snapshot
rm -rf "$OUT"; mkdir -p "$OUT"

echo "[jacos] capturing to $OUT"

# --- device tree -------------------------------------------------------------
# /sys/firmware/devicetree/base is the UNFLATTENED tree exposed as a filesystem:
# every node is a directory, every property is a file. Far easier to consume
# than parsing a binary .dtb, and it reflects what the kernel actually booted.
DT=/sys/firmware/devicetree/base
[ -d "$DT" ] || DT=/proc/device-tree
if [ -d "$DT" ]; then
  echo "[jacos] device tree from $DT"
  mkdir -p "$OUT/devicetree"
  # -h dereferences the symlink; device tree dirs are small (~1-2 MB).
  cp -rh "$DT"/. "$OUT/devicetree/" 2>/dev/null
else
  echo "[jacos] WARNING: no device tree found" >&2
fi

# --- driver binding ----------------------------------------------------------
# Which devices actually got a driver bound. This is the single most useful
# signal for "why is my touchscreen dead".
echo "[jacos] driver binding"
{
  for bus in /sys/bus/*/; do
    bn=$(basename "$bus")
    for dev in "$bus"devices/*/; do
      [ -e "$dev" ] || continue
      dn=$(basename "$dev")
      drv=""
      [ -L "$dev/driver" ] && drv=$(basename "$(readlink "$dev/driver")")
      printf '%s\t%s\t%s\n' "$bn" "$dn" "$drv"
    done
  done
} > "$OUT/driver-binding.tsv" 2>/dev/null

# --- regulators --------------------------------------------------------------
echo "[jacos] regulators"
{
  for r in /sys/class/regulator/*/; do
    [ -e "$r" ] || continue
    rn=$(basename "$r")
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$rn" \
      "$(cat "$r/name"        2>/dev/null)" \
      "$(cat "$r/state"       2>/dev/null)" \
      "$(cat "$r/microvolts"  2>/dev/null)" \
      "$(cat "$r/num_users"   2>/dev/null)"
  done
} > "$OUT/regulators.tsv" 2>/dev/null

# --- clocks ------------------------------------------------------------------
echo "[jacos] clocks"
mount -t debugfs none /sys/kernel/debug 2>/dev/null
cat /sys/kernel/debug/clk/clk_summary > "$OUT/clk_summary.txt" 2>/dev/null \
  || echo "[jacos] note: clk_summary unavailable (need root + debugfs)" >&2

# --- kernel log + misc -------------------------------------------------------
echo "[jacos] dmesg / misc"
dmesg           > "$OUT/dmesg.txt"        2>/dev/null
cat /proc/interrupts > "$OUT/interrupts.txt" 2>/dev/null
cat /proc/cpuinfo    > "$OUT/cpuinfo.txt"    2>/dev/null
uname -a             > "$OUT/uname.txt"      2>/dev/null

tar -czf /tmp/jacos-snapshot.tar.gz -C /tmp jacos-snapshot 2>/dev/null
echo "[jacos] done -> /tmp/jacos-snapshot.tar.gz ($(du -h /tmp/jacos-snapshot.tar.gz | cut -f1))"
echo "[jacos] pull it with:  scp user@172.16.42.1:/tmp/jacos-snapshot.tar.gz fixtures/"
