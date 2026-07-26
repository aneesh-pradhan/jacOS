# The 4 minutes

Scored on: Use of Jac (40%), Real-World Use Case (20%), Technical Execution
(20%), Demo & Story (20%). You must score ≥3 on Use of Jac to be eligible for
anything, so every beat below is built around showing Jac doing the work.

## Before you walk up

- [ ] Phone **already booted**, SSH over USB confirmed. Never boot on stage.
- [ ] `jac run src/jacos.jac -- build` already run once (the graph persists).
- [ ] Terminal font size cranked. Judges are 10 feet away.
- [ ] Fault **not yet injected** — you inject it live, that's the moment.
- [ ] Rebind command copy-pasted somewhere, in case you need to recover.
- [ ] `fixtures/perry-fault.json` present, so replay mode works if the phone dies.
- [ ] `JACOS_LLM=mock` ready to paste if the wifi is bad.

## Minute 1 — who it's for, what breaks

> "This is a Moto E4 from 2017. It runs Linux. I'm the person porting Linux to
> it, and I spend most of my time asking one question: the touchscreen is dead,
> why? The answer is always somewhere in the device tree, and my tools are
> `dmesg` and grep."

Hold up the phone. Don't explain the architecture yet.

## Minute 2 — the graph

```bash
jac run src/jacos.jac -- graph
```

> "The device tree is already a tree. Jac is a graph language. So JacOS imports
> the running kernel's device tree into a live Jac graph — every hardware block
> is a node, and every `vdd-supply` phandle becomes a typed power edge."

Point at the `<- pm8937_l10, pm8937_l6` column. That's the touchscreen's power
dependency, extracted from a phandle, now a first-class edge.

## Minute 3 — break it, then walk to the fault

```bash
# on the phone
sudo sh scripts/20-fault-inject.sh unbind i2c 3-0020
```

Touchscreen goes dead. Let them see it.

```bash
jac run src/jacos.jac -- diagnose touchscreen
```

> "That's a walker. It spawned on the symptom node and traversed the dependency
> edges outward. Each hop assessed itself — and here's the part that's actually
> Jac: a regulator and an i2c controller are healthy for completely different
> reasons, and the walker never branches on type. It arrives, and the right
> ability fires."

Show `src/diagnose.jac` on screen for five seconds. The three `can check_* with
<Type> entry` lines are the whole argument for your Jac score. Don't narrate
them — let them be read.

## Minute 4 — explain, then land it

```bash
jac run src/jacos.jac -- diagnose touchscreen -x
```

> "The walker found the fault by traversal, not by guessing. byLLM only phrases
> it — and because the return type is a `Diagnosis` object, there's no prompt
> template and no output parsing anywhere in the file. The type is the schema."

Close on the use case, not the tech:

> "This is a $10 phone out of a drawer. It has a CPU, a battery, a modem, and
> sensors. The reason nobody builds on these is that bringing Linux up on them
> is miserable. JacOS makes the hardware introspectable — and it works on any
> board with a device tree, which is every ARM board there is."

## If something breaks

| Failure | Recovery |
|---|---|
| Phone unreachable | `JACOS_MODE=replay`, build from `fixtures/perry-fault.json`. Say "I captured this off the device this morning" — true, and keeps moving. |
| No network for byLLM | `export JACOS_LLM=mock`. Output is identical in shape. |
| `byllm` not installed | Everything except `-x` still runs. Skip minute 4's command, keep the story. |
| Walker finds nothing | You forgot to inject the fault, or you rebuilt from `perry.json` instead of `perry-fault.json`. |

## What not to do

- **Do not** present the postmarketOS port as today's work. It predates the
  event. Say so plainly — "we brought a phone that already runs Linux; today we
  built the layer on top." Judges score one day of building, and honesty here
  costs you nothing while getting caught costs you everything.
- **Do not** spend time on the boot process. It's not what you're scored on.
- **Do not** read the code aloud. Show it, pause, keep talking.
