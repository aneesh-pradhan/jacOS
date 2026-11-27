#!/bin/sh
# Hardware-free checks for JacOS.
#
# Runs on a laptop or in CI. It never reads live sysfs: JACOS_MODE=replay
# forces the committed fixtures, so a machine that happens to have a device
# tree still exercises the replay path. Nothing in here needs the phone.
#
# Deletes the gitignored .jac/ graph cache first so the run matches a clean
# clone. Re-run `build` afterwards if you had a graph loaded for the console.

set -eu

cd "$(dirname "$0")/.."

export NO_COLOR=1
export JACOS_ASCII=1
export JACOS_MODE=replay

need() {
    # $1 = command output, $2 = required substring
    printf '%s\n' "$1" | grep -q -F -- "$2" || {
        printf 'missing expected output: %s\n' "$2" >&2
        printf '%s\n' "$1" >&2
        exit 1
    }
}

count_eq() {
    # $1 = command output, $2 = grep -c pattern, $3 = expected count
    n=$(printf '%s\n' "$1" | grep -c -E -- "$2" || true)
    if [ "$n" != "$3" ]; then
        printf 'expected %s matches of %s, got %s\n' "$3" "$2" "$n" >&2
        printf '%s\n' "$1" >&2
        exit 1
    fi
}

echo "[jacos] python compile"
python3 -m py_compile tools/dtb.py src/hw.py src/quiet.py pi_capture.py

echo "[jacos] synthesizer matches fixtures/perry.json"
synth=$(mktemp)
trap 'rm -f "$synth"' EXIT
python3 tools/dtb.py --synthesize -o "$synth"
cmp "$synth" fixtures/perry.json

echo "[jacos] jac check (files that are clean today)"
# diagnose.jac, importer.jac, and jacos.jac report pre-existing checker
# errors and still run. They are exercised below by `jaclang run`, not by
# `jac check`. See AGENTS.md.
python3 -m jaclang check src/topology.jac
python3 -m jaclang check src/explain.jac
python3 -m jaclang check src/main.jac
python3 -m jaclang check src/webapi.sv.jac
python3 -m jaclang check src/components/ManPage.cl.jac
python3 -m jaclang check src/components/ManPage.impl.jac

echo "[jacos] replay the committed Moto E4 capture"
rm -rf .jac
out=$(python3 -m jaclang run src/jacos.jac -- build fixtures/perry-live.json)
printf '%s\n' "$out"
need "$out" "built 465 nodes, 732 edges from fixtures/perry-live.json"
need "$out" "device: motorola-perry"
need "$out" "mode      replay"

out=$(python3 -m jaclang run src/jacos.jac -- graph touchscreen)
printf '%s\n' "$out"
need "$out" "1 of 465 nodes matching 'touchscreen'"
need "$out" "dev  /soc@0/i2c@78b7000/touchscreen@20   <- vdda_touch, l6"

out=$(python3 -m jaclang run src/jacos.jac -- diagnose touchscreen)
printf '%s\n' "$out"
need "$out" "symptom node: /soc@0/i2c@78b7000/touchscreen@20"
need "$out" "no faults found along the dependency chain"
need "$out" "ROOT CAUSE: none identified"

out=$(python3 -m jaclang run src/jacos.jac -- health)
printf '%s\n' "$out"
need "$out" "assessed 465 nodes"
# 12 rails that are off in the capture, plus labibb with no driver.
count_eq "$out" '^  ! ' 13

echo "[jacos] replay the same tree with vdda_touch disabled"
out=$(python3 -m jaclang run src/jacos.jac -- build fixtures/perry-live-fault.json)
printf '%s\n' "$out"
need "$out" "built 465 nodes, 732 edges from fixtures/perry-live-fault.json"

out=$(python3 -m jaclang run src/jacos.jac -- diagnose touchscreen)
printf '%s\n' "$out"
need "$out" "! hop 2  /vdda_touch_vreg"
need "$out" "rail vdda_touch is disabled"
need "$out" "ROOT CAUSE: /vdda_touch_vreg"

echo "[jacos] synthetic perry fault fixture"
out=$(python3 -m jaclang run src/jacos.jac -- build fixtures/perry-fault.json)
printf '%s\n' "$out"
need "$out" "built 11 nodes, 14 edges from fixtures/perry-fault.json"
need "$out" "device: motorola-perry (synthetic)"

out=$(python3 -m jaclang run src/jacos.jac -- diagnose touchscreen)
printf '%s\n' "$out"
need "$out" "ROOT CAUSE: /soc/spmi@200f000/pmic@0/regulators/l10"
need "$out" "rail pm8937_l10 is disabled at 1800 mV"

echo "[jacos] replay the committed Pi Zero W capture"
out=$(python3 -m jaclang run src/jacos.jac -- build fixtures/pizero-live.json)
printf '%s\n' "$out"
need "$out" "built 162 nodes, 247 edges from fixtures/pizero-live.json"
need "$out" "device: raspberrypi-model-zero-w"

out=$(python3 -m jaclang run src/jacos.jac -- health)
printf '%s\n' "$out"
need "$out" "assessed 162 nodes"
need "$out" "rail cam1-reg is disabled"
count_eq "$out" '^  ! ' 1

echo "[jacos] offline checks passed"
