# The 4 minutes

Scored on: Use of Jac (40%), Real-World Use Case (20%), Technical Execution
(20%), Demo & Story (20%). You must score ≥3 on Use of Jac to be eligible for
anything, so every beat below is built around showing Jac doing the work.

Every command here was run end to end against the real phone on 2026-07-26.
The outputs shown are the actual outputs, not sketches.

## Two terminals

Set these up before you walk anywhere. Font cranked, judges are 10 feet away.

- **T1 — the phone.** `ssh perry`, then `cd ~/jacos`. Minutes 2 and 3.
- **T2 — the laptop.** Repo root. Minute 4 only, because byLLM is not installed
  on the phone and should not be (litellm drags in pydantic-core and tiktoken,
  which need musl aarch64 wheels).

## Before you walk up

- [ ] Phone **already booted**, `ssh perry` confirmed. Never boot on stage.
- [ ] T1: `./scripts/jacos build fixtures/perry-live.json` already run once.
- [ ] T1: `./scripts/jacos diagnose touchscreen` says **no faults** — proves you
      start healthy and the fault you inject is real.
- [ ] Fault **not yet injected**. You inject it live, that's the moment.
- [ ] Rebind command on the clipboard:
      `sudo sh scripts/20-fault-inject.sh rebind i2c 1-0020 rmi4_i2c`
- [ ] T2: `JACOS_MODE=replay JACOS_LLM=mock` exported, and the broken snapshot
      built (see minute 4). Do this **before** you present.

## Minute 1 — who it's for, what breaks

> "This is a Moto E4 from 2017. It runs Linux. I'm the person porting Linux to
> it, and I spend most of my time asking one question: the touchscreen is dead,
> why? The answer is always somewhere in the device tree, and my tools are
> `dmesg` and grep."

Hold up the phone. Don't explain the architecture yet.

## Minute 2 — the graph

```bash
./scripts/jacos graph touchscreen
```

```
  1 of 465 nodes matching 'touchscreen'
  dev  /soc@0/i2c@78b7000/touchscreen@20   <- vdda_touch, l6
```

> "That's this phone's real device tree — 465 nodes, read out of the running
> kernel. The device tree is already a tree. Jac is a graph language. So JacOS
> imports it into a live Jac graph: every hardware block is a node, and every
> `vdd-supply` phandle becomes a typed power edge."

Point at `<- vdda_touch, l6`. That is the touchscreen's power dependency,
extracted from phandles, now a first-class edge. Two hops, because the fixed
regulator `vdda_touch` is itself fed by PMIC rail `l6`.

## Minute 3 — break it, then walk to the fault

```bash
sudo sh scripts/20-fault-inject.sh unbind i2c 1-0020
```

Touchscreen goes dead. Let them see it. Then:

```bash
./scripts/jacos diagnose touchscreen
```

```
  ! hop 1  /soc@0/i2c@78b7000/touchscreen@20
           NO DRIVER BOUND -- device did not probe
  ! hop 2  /vdda_touch_vreg
           rail vdda_touch is disabled

  ROOT CAUSE: /vdda_touch_vreg
              rail vdda_touch is disabled
```

> "That's a walker. It spawned on the symptom node and traversed the dependency
> edges outward. Each hop assessed itself — and here's the part that's actually
> Jac: a regulator and an i2c controller are healthy for completely different
> reasons, and the walker never branches on type. It arrives, and the right
> ability fires."

Show `src/diagnose.jac` for five seconds. The `can check_* with <Type> entry`
lines are the whole argument for your Jac score. Don't narrate them — let them
be read.

### Rehearse this one answer

A judge may ask: *you unbound a driver, why does it blame a regulator?*

> "Because the rail genuinely went down. `vdda_touch` is consumer-enabled — the
> touchscreen driver was the thing holding it up. Kill the driver and the rail
> drops with it, `num_users` 1 to 0. I didn't stage that second hop; the walker
> followed the power edge and found it. That's the difference between reading
> one sysfs file and traversing the graph."

This is true and verified in both directions. It is the strongest 15 seconds
available to you — do not wing it.

## Minute 4 — explain, then land it

Switch to **T2, the laptop.** Prepared beforehand:

```bash
python tools/dtb.py fixtures/perry-snapshot.tar.gz --break-rail vdda_touch -o /tmp/vt.json
jac run src/jacos.jac -- build /tmp/vt.json
```

On stage, one command:

```bash
jac run src/jacos.jac -- diagnose touchscreen -x
```

Same root cause as the phone just produced, now with the explanation layer:

```
  DIAGNOSIS  (confidence 0.9)
  cause:     /vdda_touch_vreg
  reasoning: The touchscreen's vdd supply is the fixed regulator vdda_touch, and
             it is disabled. ...
```

> "The walker found the fault by traversal, not by guessing. byLLM only phrases
> it — and because the return type is a `Diagnosis` object, there's no prompt
> template and no output parsing anywhere in the file. The type is the schema."

Close on the use case, not the tech:

> "This is a $10 phone out of a drawer. It has a CPU, a battery, a modem, and
> sensors. The reason nobody builds on these is that bringing Linux up on them
> is miserable. JacOS makes the hardware introspectable — and it works on any
> board with a device tree, which is every ARM board there is."

## After you finish

```bash
sudo sh scripts/20-fault-inject.sh rebind i2c 1-0020 rmi4_i2c
```

Confirm with `./scripts/jacos diagnose touchscreen` → "no faults".

## If something breaks

| Failure | Recovery |
|---|---|
| Phone unreachable | Do the whole demo on T2. `JACOS_MODE=replay`, build from the `--break-rail vdda_touch` snapshot. Say "I captured this off the device this morning" — true, and it is the same 465-node tree. |
| Phone dies mid-demo | Same, and you already have T2 built and ready. Keep talking. |
| Walker finds nothing | You forgot to inject, or you rebuilt the graph after injecting in replay mode. In live mode the graph does not need rebuilding — sysfs is re-read on arrival. |
| `-x` prints "byLLM not available" | You are on the phone, not the laptop. Minute 4 is T2 only. |
| Rebind fails | The device may have re-probed already. Check `ls /sys/bus/i2c/devices/1-0020/driver`. |

## What not to do

- **Do not** present the postmarketOS port as today's work. It predates the
  event. Say so plainly — "we brought a phone that already runs Linux; today we
  built the layer on top." Judges score one day of building, and honesty here
  costs you nothing while getting caught costs you everything.
- **Do not** run bare `./scripts/jacos graph`. It prints all 465 nodes and the
  touchscreen lands at line 218, off screen. Always pass the filter.
- **Do not** spend time on the boot process. It's not what you're scored on.
- **Do not** read the code aloud. Show it, pause, keep talking.
