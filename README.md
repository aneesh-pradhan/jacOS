# JacOS

**Your hardware, as a graph.**

The Linux device tree is already a tree of nodes with typed relationships between
them. Jac is a language whose primitives are nodes, edges, and walkers that move
through them. JacOS is what happens when you take that correspondence seriously:
it lifts a running phone's device tree into a live Jac graph, and turns hardware
debugging into graph traversal.

Target hardware is a **Motorola Moto E4 (`motorola-perry`)** running
postmarketOS — a 2017 phone with a Snapdragon SoC, rescued from e-waste.

---

## The problem

Porting Linux to a phone is mostly one question, asked a hundred times: *the
touchscreen is dead, why?* The tooling for answering it is `dmesg | grep` and
tribal knowledge. The information you actually need — that the touchscreen's
`vdd-supply` is a phandle pointing at `pm8937_l10`, and that rail never came up —
is sitting right there in the device tree. It's just not connected to anything
that can reason about it.

## The approach

```
device tree (/sys/firmware/devicetree/base)
        │
        │  tools/dtb.py — resolves phandles into typed edges
        ▼
   node/edge spec (JSON)
        │
        │  src/importer.jac — materialises Jac archetypes
        ▼
   live Jac graph  ──  walkers traverse it  ──  byLLM explains the result
```

A device's `vdd-supply = <&pm8937_l10>` becomes a `SuppliedBy` edge. `clocks =
<&gcc 42>` becomes a `ClockedBy` edge. Once those exist, "what does this device
depend on" is a traversal, and "what broke" is a traversal that assesses each
hop.

## Why this is Jac and not a Python script

Two things carry real weight in the language, not in a wrapper around it:

**Assessment is dispatched by node type on arrival.** A regulator is healthy if
its rail is enabled. A device is healthy if a driver bound to it. Those are
different questions, and `Diagnose` never branches on kind — it arrives, and the
right ability fires:

```jac
can check_regulator with Regulator entry { ... }
can check_device    with Device    entry { ... }
can check_bus       with Bus       entry { ... }
```

**Descent is written once for all hardware.** Every node type inherits `HwNode`,
so one generic exit ability defines the traversal policy for the entire machine:

```jac
can descend with HwNode exit {
    visit [->:SuppliedBy:->];
    visit [->:ClockedBy:->];
    visit [->:ResetBy:->];
    visit [->:ParentBus:->];
}
```

**The graph is the database.** Jac persists everything reachable from `root`, so
`build` runs once and every later command queries the live registry. There is no
ORM, no schema, and no serialisation layer anywhere in this repo.

**byLLM does the narrow job.** The walker finds the fault by traversal, not by
asking a model. The LLM takes a *verified* fault plus kernel log context and
returns a typed `Diagnosis` object — the return type is the schema, so there is
no prompt template and no output parsing in `src/explain.jac`.

---

## Quick start

```bash
pip install jaclang byllm          # byllm is optional; only `diagnose -x` needs it
# on postmarketOS / Alpine (musl), skip the llvmlite dependency entirely:
#   pip3 install --break-system-packages --no-deps jaclang

# generate a synthetic snapshot so you can run with no phone attached
python tools/dtb.py --synthesize -o fixtures/perry.json
python tools/dtb.py --synthesize --break-rail pm8937_l10 -o fixtures/perry-fault.json

jac run src/jacos.jac -- build fixtures/perry-fault.json
jac run src/jacos.jac -- graph
jac run src/jacos.jac -- health
jac run src/jacos.jac -- diagnose touchscreen
jac run src/jacos.jac -- diagnose touchscreen -x     # + byLLM explanation
```

Output:

```
  symptom node: /soc/i2c@78b6000/touchscreen@20

  walked 7 nodes:
    -> /soc/i2c@78b6000/touchscreen@20
    -> /soc/spmi@200f000/pmic@0/regulators/l10
    -> /soc/spmi@200f000/pmic@0/regulators/l6
    -> /soc/i2c@78b6000
    -> /soc/clock-controller@1800000
    -> /soc
    -> /

  ! hop 2  /soc/spmi@200f000/pmic@0/regulators/l10
           rail pm8937_l10 is disabled at 1800 mV

  ROOT CAUSE: /soc/spmi@200f000/pmic@0/regulators/l10
```

## Live vs replay

Same walkers, two data sources. `src/hw.py` auto-detects; force with
`JACOS_MODE=live|replay`.

| | source | used for |
|---|---|---|
| **live** | real sysfs on the phone | the actual demo |
| **replay** | a captured snapshot | laptop development, and surviving a dead phone on stage |

Capture a real snapshot with `scripts/10-capture-topology.sh` (pure busybox, no
Python needed on the device), then convert it with `tools/dtb.py`.

## Layout

```
src/topology.jac    node + edge archetypes — the schema
src/importer.jac    builds the graph from a spec; BuildGraph, Lookup
src/diagnose.jac    Diagnose, Survey, Probe walkers
src/explain.jac     byLLM Diagnosis type + sem annotations
src/jacos.jac       CLI entry point
src/hw.py           live/replay hardware state
tools/dtb.py        device tree -> node/edge spec, incl. phandle resolution
scripts/            on-device preflight, capture, and fault injection
```

## Status

Working: graph import with phandle resolution, type-dispatched assessment,
dependency traversal, root-cause ranking, typed byLLM explanation, live/replay
parity, offline mock fallback.

Not done yet: real perry snapshot (needs the phone), `clk_summary` parsing for
genuine clock health, and `jac-cloud` serving for a remote fleet view.
