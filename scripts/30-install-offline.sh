#!/bin/sh
# JacOS :: offline Jac install
#
# postmarketOS ships python3 but not necessarily pip, and getting the phone
# online over USB is more trouble than it is worth. It also does not matter:
# jaclang is a pure-Python wheel, a wheel is a zip, and python3 can unzip it.
# No pip, no apk, no network on the device.
#
#   scp vendor/jaclang-0.16.7-py3-none-any.whl perry:~/jacos/
#   ssh perry 'cd ~/jacos && sh scripts/30-install-offline.sh jaclang-0.16.7-py3-none-any.whl'

set -eu

WHEEL="${1:-}"
if [ -z "$WHEEL" ]; then
  echo "usage: sh scripts/30-install-offline.sh <jaclang-*.whl>" >&2
  exit 2
fi
if [ ! -f "$WHEEL" ]; then
  echo "no such wheel: $WHEEL" >&2
  exit 2
fi

HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HERE/vendor"

# Resolve the wheel to an absolute path before touching DEST. The obvious place
# to scp the wheel is vendor/ itself, and DEST gets wiped below -- so a relative
# path would pass the -f check above and then be deleted out from under us.
WHEEL=$(cd "$(dirname "$WHEEL")" && pwd)/$(basename "$WHEEL")

# Same reason: if the wheel lives inside DEST, park it somewhere the wipe
# cannot reach and extract from there.
case "$WHEEL" in
  "$DEST"/*)
    STAGE=$(mktemp -d)
    trap 'rm -rf "$STAGE"' EXIT
    cp "$WHEEL" "$STAGE/"
    WHEEL="$STAGE/$(basename "$WHEEL")"
    ;;
esac

echo "[jacos] unpacking $WHEEL -> $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
python3 - "$WHEEL" "$DEST" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
print("  extracted ok")
PY

echo "[jacos] verifying"
# PYTHONPATH does not process the .pth hook that a real install would, so this
# check matters: it exercises the actual import machinery, not just the version
# banner.
PYTHONPATH="$DEST" python3 -m jaclang --version | sed -n '4p'

cat <<EOF

[jacos] done. Run JacOS with the wrapper, which sets PYTHONPATH for you:

    ./scripts/jacos build fixtures/perry.json
    ./scripts/jacos health
    ./scripts/jacos diagnose touchscreen

EOF
