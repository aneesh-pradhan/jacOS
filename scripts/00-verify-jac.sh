#!/bin/sh
# JacOS :: phone-side preflight
# Run this ON the Moto E4 over SSH. It answers the one question that can kill
# the project: does Jac actually execute on this device?
#
#   scp scripts/00-verify-jac.sh user@172.16.42.1:~/
#   ssh user@172.16.42.1 'sh 00-verify-jac.sh'
#
# Exits 0 if at least one Jac execution path works.

set -u

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  [ OK ]   %s\n' "$1"; }
bad()  { printf '  [FAIL]   %s\n' "$1"; }
info() { printf '  [ .. ]   %s\n' "$1"; }

say "1. Machine profile"
info "uname:  $(uname -a)"
ARCH="$(uname -m)"
info "arch:   $ARCH"
case "$ARCH" in
  aarch64|arm64) ok "64-bit ARM. Prebuilt jac binary is published for this." ;;
  armv7*|armv8l) bad "32-bit userspace. NO prebuilt jac binary exists for armv7." ;;
  *)             bad "Unexpected arch '$ARCH'." ;;
esac

# musl vs glibc decides whether the prebuilt binary can even load.
if [ -e /lib/ld-musl-*.so.1 ] 2>/dev/null; then
  LIBC=musl
elif [ -e /lib/ld-linux-aarch64.so.1 ] || [ -e /lib64/ld-linux-x86-64.so.2 ]; then
  LIBC=glibc
else
  LIBC=unknown
fi
info "libc:   $LIBC"
[ "$LIBC" = "musl" ] && info "Alpine/musl -- glibc-linked binaries will NOT run without a shim."

info "mem:    $(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"

say "2. Path A -- prebuilt self-contained jac binary"
if command -v jac >/dev/null 2>&1; then
  if jac --version >/dev/null 2>&1; then
    ok "jac binary present and runs: $(jac --version 2>&1 | head -1)"
    PATH_A=yes
  else
    bad "jac present but fails to execute (expected on musl: needs glibc)"
    PATH_A=no
  fi
else
  info "jac not installed yet. Install with:"
  info "  curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | sh"
  PATH_A=no
fi

say "3. Path B -- system CPython + pip install jaclang"
if command -v python3 >/dev/null 2>&1; then
  PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
  info "python3: $PYV  (jaclang requires >= 3.12)"
  if python3 -c 'import sys;raise SystemExit(0 if sys.version_info>=(3,12) else 1)' 2>/dev/null; then
    ok "Python version is sufficient."
    if python3 -c 'import jaclang' 2>/dev/null; then
      ok "jaclang already importable."
      PATH_B=yes
    else
      info "jaclang not installed. On musl, install it WITHOUT its only dependency:"
      info ""
      info "    pip3 install --break-system-packages --no-deps jaclang"
      info ""
      info "llvmlite is jaclang's sole declared dependency and ships no musl wheels,"
      info "so a plain install tries to build it from source and needs a full LLVM"
      info "toolchain. Nothing in jaclang actually imports it -- it is only reachable"
      info "through the .na.jac native codegen path, which JacOS does not use. Verified:"
      info "the whole pipeline produces identical output with llvmlite absent."
      PATH_B=unknown
    fi
  else
    bad "Python too old for jaclang."
    PATH_B=no
  fi
else
  bad "No python3 on device.  apk add python3 py3-pip"
  PATH_B=no
fi

say "4. Path C -- glibc shim (fallback if A failed on musl)"
if command -v podman >/dev/null 2>&1 || command -v distrobox >/dev/null 2>&1; then
  ok "Container runtime available -- a glibc container can host jac."
else
  info "No podman/distrobox. Install with: apk add podman"
  info "Only needed if Paths A and B both fail."
fi

say "5. Data sources JacOS reads"
for p in /sys/firmware/devicetree/base /sys/class/regulator /sys/bus /proc/device-tree; do
  if [ -e "$p" ]; then ok "$p"; else bad "$p  (missing)"; fi
done
if [ -r /sys/kernel/debug/clk/clk_summary ]; then
  ok "/sys/kernel/debug/clk/clk_summary (need root)"
else
  info "/sys/kernel/debug/clk/clk_summary unreadable -- mount -t debugfs none /sys/kernel/debug"
fi

# --- Path D -- vendored wheel on PYTHONPATH ---------------------------------
# This is the path JacOS actually ships (scripts/30-install-offline.sh): the
# wheel is pure Python, so it needs neither pip nor network. Check it last but
# treat it as a pass -- without this the preflight reports FAIL on a device
# where the whole pipeline demonstrably runs.
say "6. Path D -- vendored wheel on PYTHONPATH (what JacOS ships)"
VENDOR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/vendor
if [ -d "$VENDOR/jaclang" ]; then
  if PYTHONPATH="$VENDOR" python3 -m jaclang --version >/dev/null 2>&1; then
    ok "Vendored jaclang runs from $VENDOR"
    PATH_D=yes
  else
    note "$VENDOR exists but python3 -m jaclang failed there."
    PATH_D=no
  fi
else
  note "No unpacked wheel yet. Run: sh scripts/30-install-offline.sh <wheel>"
  PATH_D=no
fi

say "VERDICT"
if [ "${PATH_D:-no}" = "yes" ]; then
  ok "Jac runs here via the vendored wheel. Proceed."
  exit 0
elif [ "${PATH_A:-no}" = "yes" ] || [ "${PATH_B:-no}" = "yes" ]; then
  ok "Jac can run on this device. Proceed."
  exit 0
else
  bad "No confirmed Jac execution path yet. Work through Path B then C."
  bad "Do NOT leave this unresolved until the hackathon."
  exit 1
fi
