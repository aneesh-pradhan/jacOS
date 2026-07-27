# Devpost submission — ready to paste

Everything in this file is final copy. Paste it into the Devpost fields as
marked. The only thing that needs a human is the demo video (§6, §7).

Rubric being written to: **Use of Jac 40%** (hard gate — below 3 is ineligible
for every prize), Real-World Use Case 20%, Technical Execution 20%,
Demo & Story 20%.

---

## 1. Title and tagline

**Project name**

```
JacOS
```

**Tagline (one line)**

```
Your hardware, as a graph: a phone's live Linux device tree lifted into a Jac graph, so hardware debugging becomes traversal.
```

---

## 2. Description (~300 words) — paste into "About the project"

```
Bringing Linux up on a new board is one question asked a hundred times a day:
the touchscreen is dead, why? The answer is always in the device tree, and the
tools for finding it are dmesg and grep.

The Linux device tree is already a tree of nodes with typed relationships. Jac
is a language whose primitives are nodes, edges and walkers. JacOS takes that
correspondence seriously. It reads the device tree out of a running kernel and
materialises it as a live Jac graph: 465 nodes and 732 edges off a real Motorola
Moto E4. A device's `vdd-supply = <&pm8937_l6>` phandle becomes a typed
SuppliedBy edge; `clocks = <&gcc 42>` becomes ClockedBy. Once those edges exist,
"what does this device depend on" is a traversal.

Assessment is dispatched by node type on arrival — `can check_regulator with
Regulator entry`, `can check_device with Device entry`. A regulator is healthy
if its rail is enabled; a device is healthy if a driver bound. Those are
different questions and the walker never branches on kind: it arrives and the
right ability fires. Descent is one generic exit ability on the HwNode base, so
traversal policy is written once for the whole machine. Root cause is ranked by
walking the dependency chain and preferring the deepest, most fundamental fault.
byLLM's return type is a typed `Diagnosis` object, so the type is the schema —
there is no prompt template and no output parsing anywhere in the repo. The
walker finds the fault; the LLM only phrases it.

The same walkers drive both frontends. The web console's client does
`root spawn DiagnoseNode(...)` and the server wrapper spawns the identical
`Diagnose` walker the CLI spawns. One graph, two frontends, zero duplicated
diagnostic logic.

We brought a phone that already runs Linux; today we built the layer on top.
Every number above was verified on that hardware.

For a board bring-up engineer or postmarketOS porter, this turns tribal
knowledge into a query. And it makes a $10 phone out of a drawer — CPU,
battery, modem, sensors — worth reviving instead of throwing away.
```

---

## 3. How we built it / Challenges / What we learned

### How we built it

```
tools/dtb.py walks /sys/firmware/devicetree/base and resolves every phandle
into a typed node/edge spec, then joins it against sysfs for live state.
src/topology.jac declares the HwNode hierarchy and the five edge archetypes.
src/importer.jac materialises the spec into Jac archetypes hung off root — and
because Jac persists everything reachable from root, that graph *is* the
database. No ORM, no schema, no serialisation layer in the repo.

src/diagnose.jac holds the walkers: Diagnose (spawn on a symptom, traverse
outward, assess each hop, rank a root cause), Survey and Probe. src/explain.jac
declares the byLLM Diagnosis object. src/jacos.jac is the CLI. src/main.jac plus
src/webapi.sv.jac and src/components/ManPage.cl.jac are the fullstack web
console — Jac 0.16.7 codespaces, no jac-cloud needed.

On the device: busybox-only capture scripts, and an offline install that unzips
the jaclang wheel and points PYTHONPATH at it, because the phone has no pip and
no network.
```

### Challenges we ran into

```
1. interrupt-parent is inherited. A device tree node with `interrupts` and no
   `interrupt-parent` routes to the nearest ancestor that has one. Resolving it
   self-only found 6 interrupt edges where the phone actually has 79.
   interrupts-extended overrides it entirely and carries its own
   <&controller specifier...> pairs. Getting this right is the difference
   between a graph and a disconnected pile of nodes.

2. You cannot reconstruct a Linux device name from a device tree node name. We
   tried: <addr>.<name> is platform-bus-only, i2c is "1-0020", spi is "spi0.1",
   mmc is "mmc0:0001". The heuristic confidently reported the touchscreen as
   dead while rmi4_i2c was bound to it. The fix is to join through each
   device's `of_node` symlink in sysfs — the kernel already publishes the
   mapping, so never guess it. One tree node can also back two sysfs devices
   (an i2c controller is both a platform device and an adapter); prefer
   whichever bound, or the bus reads as dead.

3. A device tree node Linux never instantiated is not a probe failure.
   opp-table, idle-states, /timer and cpu@N all carry compatible strings and
   never bind. Without an in_sysfs ground-truth flag propagated through the
   graph, health output is dominated by false positives.

4. `", ".join(list)` does not survive client lowering. In a .cl.jac it lowers to
   a method dispatch on a string primitive and throws a *non-Error* value —
   which is why jac-client's own ErrorBoundary then crashed reading
   `error.message` on `undefined`, and why the real error was never logged
   anywhere. That phantom error message cost four sessions of debugging. It only
   fired on rows that actually had rails, so the page looked fine while loading
   and blanked the instant real data arrived.

5. PMIC rails are bare children of a regulator container: node name `l10`, no
   `compatible`, no `regulator-name`. You have to key off regulator-* property
   constraints rather than compatible strings to find them at all. All 26 on
   this phone now match to sysfs.
```

### What we learned

```
Jac's ability-dispatch order is load-bearing and worth knowing exactly: for a
subtype instance the parent-type entry ability fires first, then the subtype's,
then exit abilities. That is why assessment lives only on the subtypes and
descent lives only on the base — the language enforces the separation for us.

Jac persists the root graph between runs, which is a feature that will bite you
once: walker dedup guards must live on the walker, not on node state. Guarding
on node.state made every run after the first silently assess nothing.

`node` is a reserved word. Using it as a parameter name in a .cl.jac emits an
error from `jac check` but the client build still goes green — and silently
drops every impl body on the floor. Run `jac check` on components.

And the broadest lesson: the same walkers, unmodified, work against a live
phone and a captured snapshot, because topology.jac and diagnose.jac never
learn what an MSM8937 is. Model the relationships and the traversal is portable.
```

---

## 4. Built with

```
jac, jaclang-0.16.7, byllm, jac-client, postmarketos, linux-device-tree,
busybox, alpine-linux, python, sysfs, react, vite, qualcomm-msm8937,
motorola-moto-e4, aarch64
```

Short form for the Devpost "Built With" tag field:

```
jac  jaclang  byllm  jac-client  postmarketos  busybox  python  linux  devicetree  react
```

---

## 5. Submission checklist

| Item | Status | Evidence |
|---|---|---|
| Repo public | **DONE** | `gh api repos/aneesh-pradhan/jacOS --jq .private` → `false` |
| Code ≥40% Jac | **DONE — 50.2%** | see below |
| Repo URL in submission | pending human | `https://github.com/aneesh-pradhan/jacOS` |
| **Demo video** | **TODO — HUMAN** | does not exist yet; shot list in §6 |
| Star `github.com/jaseci-labs/jac` | manager owns this | ten seconds |
| Devpost hard close | **7:15 PM today** | partial-submission checkpoint 5:50 PM has passed |

**Language percentages**, from `gh api repos/aneesh-pradhan/jacOS/languages`
(measured 2026-07-26, ~5:55 PM):

| Language | Bytes | Share |
|---|---|---|
| **Jac** | **69,403** | **50.2%** |
| Python | 39,730 | 28.8% |
| CSS | 15,164 | 11.0% |
| Shell | 13,864 | 10.0% |
| **Total** | **138,161** | |

Jac is **50.2%**, comfortably over the 40% the checklist asks for, and up from
34.6% before the web console existed. Re-check with:

```bash
gh api repos/aneesh-pradhan/jacOS --jq .private
gh api repos/aneesh-pradhan/jacOS/languages
```

Where to point a judge who asks "show me where Jac runs":

- `src/diagnose.jac` — the `can check_* with <Type> entry` abilities and
  `can descend with HwNode exit`. This is the 40%.
- `src/topology.jac` — node and edge archetypes; the schema is the graph.
- `src/explain.jac` — byLLM returning a typed `Diagnosis`, no prompt template.
- `src/webapi.sv.jac` — the web console spawning the *same* `Diagnose` walker.

---

## 6. Demo video shot list — 45 to 90 seconds

Record this in one take if possible. Two terminals side by side (or cut between
them), then the browser. Fonts cranked. No slides, no title card longer than two
seconds — the rubric rewards showing the workflow, not describing it.

**Setup before you hit record**

- Phone booted, `ssh perry` live, `cd ~/jacos`, graph already built
  (`./scripts/jacos build fixtures/perry-live.json`).
- Fault **not** injected yet.
- T2 (laptop): `.demovenv` active, `JACOS_MODE=replay JACOS_LLM=mock` exported,
  and `jac run src/jacos.jac -- build fixtures/perry-live-fault.json` already
  run.
- Web console already serving on `localhost:8100` with the graph resident.
  **Do not press the `build` button on camera** — it costs ~40 s and blocks the
  server.
- Rebind command on the clipboard:
  `sudo sh scripts/20-fault-inject.sh rebind i2c 1-0020 rmi4_i2c`

**Shot 1 — 0:00–0:10 · the phone, healthy** *(T1)*

Hold the phone in frame for two seconds, then:

```bash
./scripts/jacos graph touchscreen
./scripts/jacos diagnose touchscreen
```

Voiceover: *"This is a 2017 Moto E4 running Linux. 465 device tree nodes, read
out of the running kernel and imported into a live Jac graph. Right now the
touchscreen is healthy."*

Let "no faults" sit on screen for a beat. This is what makes the next shot mean
something.

**Shot 2 — 0:10–0:22 · break it live** *(T1)*

```bash
sudo sh scripts/20-fault-inject.sh unbind i2c 1-0020
```

Voiceover: *"I'm going to kill the touchscreen driver on the real device, right
now."*

Show the phone's screen not responding if you can get it in frame.

**Shot 3 — 0:22–0:42 · the walker finds the cascade** *(T1)*

```bash
./scripts/jacos diagnose touchscreen
```

```
  ! hop 1  /soc@0/i2c@78b7000/touchscreen@20
           NO DRIVER BOUND -- device did not probe
  ! hop 2  /vdda_touch_vreg
           rail vdda_touch is disabled

  ROOT CAUSE: /vdda_touch_vreg
```

Voiceover: *"That's a Jac walker. It spawned on the symptom node and traversed
the dependency edges outward. Each hop assessed itself — and a regulator and an
i2c controller are healthy for completely different reasons. The walker never
branches on type. It arrives, and the right ability fires."*

Cut to `src/diagnose.jac` for three seconds — just the `can check_* with <Type>
entry` lines. Do not read them aloud.

**Shot 4 — 0:42–0:58 · the explanation layer** *(T2, laptop)*

```bash
jac run src/jacos.jac -- diagnose touchscreen -x
```

```
  DIAGNOSIS  (confidence 0.9)
  cause:     /vdda_touch_vreg
  reasoning: The touchscreen's vdd supply is the fixed regulator vdda_touch, and
             it is disabled. ...
```

Voiceover: *"Same root cause the phone just produced, now phrased. byLLM's
return type is a Diagnosis object — the type is the schema, so there's no prompt
template and no output parsing anywhere in the file. The walker found the fault
by traversal. The model only writes the sentence."*

**Shot 5 — 0:58–1:20 · the web console, same walkers** *(browser)*

Go to `localhost:8100`, type `camera@10`, hit run.

Voiceover: *"Second frontend, same graph, same walkers — the client spawns the
identical Diagnose walker the CLI spawns. This is the rear camera on this phone,
and it's genuinely dead; nothing is injected here. All three of its supplies are
down, and the walk ranks the PMIC rail `l23` above the two local regulators,
because a rail is more fundamental than the regulators hanging off it."*

Point at the DEPENDENCY GRAPH section: colour is edge archetype — amber
`supplied_by`, cyan `clocked_by`, violet `reset_by`, dashed grey `parent_bus`.
The root cause `l23` carries the expanding halo.

**Shot 6 — 1:20–1:30 · land it** *(back on the phone in frame)*

Voiceover: *"This is a $10 phone out of a drawer. It has a CPU, a battery, a
modem and sensors, and the only reason nobody builds on these is that bringing
Linux up on them is miserable. JacOS makes the hardware introspectable — and it
works on any board with a device tree, which is every ARM board there is."*

**After you stop recording**

```bash
sudo sh scripts/20-fault-inject.sh rebind i2c 1-0020 rmi4_i2c
./scripts/jacos diagnose touchscreen     # must say no faults
```

### Trim options if you are over 90 seconds

Cut in this order — Shot 5 is the last thing to lose, because it is the
strongest Use-of-Jac evidence in the video:

1. Shot 6's voiceover down to one sentence.
2. Shot 1's `graph touchscreen` (keep `diagnose`, you need the healthy baseline).
3. Shot 4 down to the `cause:` line only.

Do **not** cut Shot 1's healthy result or Shot 2's live unbind. The video's
whole credibility is that the fault was injected on real hardware on camera.

### The one question you must have an answer ready for

A judge who watched you type `unbind` will ask: *you broke the driver, why does
it blame the regulator?* Verbatim from `docs/DEMO.md`, rehearsed:

> "Because the rail genuinely went down. `vdda_touch` is consumer-enabled — the
> touchscreen driver was the thing holding it up. Kill the driver and the rail
> drops with it, `num_users` 1 to 0. I didn't stage that second hop; the walker
> followed the power edge and found it. That's the difference between reading
> one sysfs file and traversing the graph."

This is true and verified in both directions. It is the strongest 15 seconds
available to you — do not wing it.

If you would rather not invite the question at all, the `camera@10` path in
Shot 5 needs no injection whatsoever: that camera is really dead, all three
supplies are really disabled, and `l23` is really the rail underneath them.

---

## 7. Things a human still has to do

1. **Record the demo video** using §6 and upload it to Devpost. This is the only
   hard blocker left on the submission.
2. **Star `github.com/jaseci-labs/jac`** (manager is handling it).
3. Paste §1–§4 into the Devpost fields.
4. Decide whether the script claims **16** or **18** health findings — the count
   depends on whether `fixtures/perry-snapshot.tar.gz` is present on the
   presenting machine (it is gitignored). See HANDOFF §9. The video above never
   states the number, deliberately.
