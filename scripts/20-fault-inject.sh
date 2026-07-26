#!/bin/sh
# JacOS :: demo fault injection
# THE MONEY SHOT. Run on the phone to deliberately break something, then let
# the diagnose walker find it live on stage.
#
#   ssh user@172.16.42.1 'sudo sh 20-fault-inject.sh unbind <bus> <device>'
#   ssh user@172.16.42.1 'sudo sh 20-fault-inject.sh list'
#
# Unbinding a driver is clean, instant, and fully reversible -- much safer on
# stage than yanking a regulator, which can wedge the device or corrupt state.

set -u
CMD="${1:-help}"

case "$CMD" in
  list)
    echo "--- bound devices (candidates to break) ---"
    for bus in /sys/bus/*/; do
      bn=$(basename "$bus")
      for dev in "$bus"devices/*/; do
        [ -L "$dev/driver" ] || continue
        printf '%-12s %-40s -> %s\n' "$bn" "$(basename "$dev")" \
          "$(basename "$(readlink "$dev/driver")")"
      done
    done
    ;;

  unbind)
    BUS="${2:?usage: 20-fault-inject.sh unbind <bus> <device>}"
    DEV="${3:?usage: 20-fault-inject.sh unbind <bus> <device>}"
    DRV=$(basename "$(readlink "/sys/bus/$BUS/devices/$DEV/driver")")
    echo "[jacos] unbinding $DEV from $DRV on bus $BUS"
    echo "$DEV" > "/sys/bus/$BUS/drivers/$DRV/unbind"
    echo "[jacos] fault injected. Save the rebind command:"
    echo "        echo $DEV > /sys/bus/$BUS/drivers/$DRV/bind"
    ;;

  rebind)
    BUS="${2:?usage: 20-fault-inject.sh rebind <bus> <device> <driver>}"
    DEV="${3:?}"; DRV="${4:?}"
    echo "$DEV" > "/sys/bus/$BUS/drivers/$DRV/bind"
    echo "[jacos] rebound $DEV -> $DRV"
    ;;

  *)
    sed -n '2,12p' "$0"
    ;;
esac
