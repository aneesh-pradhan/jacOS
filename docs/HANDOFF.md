# JacOS — session handoff

Everything a fresh session needs to continue without re-deriving anything.
Written 2026-07-26.

---

## 1. What this is and why it looks like this

**Event:** JacHacks SF, Founders Inc, `JUL_26_2026`. 4-minute demo, parallel
groups. Rubric is in `~/Downloads/JacHacks_SF_Rubric_HACKERS.pdf`.

Scoring: **Use of Jac 40%** (hard gate — below 3 you are ineligible for every
prize), Real-World Use Case 20%, Technical Execution 20%, Demo & Story 20%.
Judged against *one day* of building. A 5 on Jac requires "the product depends
on Jac, used with depth or originality: walkers, graph traversal, byLLM."

**The original idea was "JacOS: a minimal Linux OS for the Moto E4."** That was
rejected, and it matters that a future session does not drift back to it:

- Jac cannot be the OS. Kernel, init, libc, busybox are not its layer. You'd end
  up with an Alpine system plus a Jac script on top — rubric level 1,
  "the product would work the same without it," which is a disqualification.
- The postmarketOS port already existed before the event. Judges score one day
  of building, so the impressive part is out of scope while the in-scope part
  would be thin.

**The pivot that was chosen instead:** keep the phone as a demo prop, move the
novelty into userspace. The Linux device tree is already a tree of nodes with
typed relationships; Jac's primitives are nodes, edges, and walkers. JacOS lifts
the running device tree into a live Jac graph and makes hardware fault-finding a
traversal.

The phone port must be presented as **given infrastructure, stated plainly** —
"we brought a phone that already runs Linux; today we built the layer on top."

**Target user (rubric wants one person, not a market):** a board bring-up
engineer / postmarketOS porter. Their whole job is "the touchscreen is dead,
why," and their tools are `dmesg` and grep. Close on e-waste revival as the
*why it matters*, not as the core claim.

---

## 2. Repo

`C:\GitHub\jacOS` → https://github.com/aneesh-pradhan/jacOS — **currently
private.** Judges need it public:

```bash
gh repo edit aneesh-pradhan/jacOS --visibility public --accept-visibility-change-consequences
```

```
src/topology.jac    HwNode hierarchy + typed edges (the schema)
src/importer.jac    BuildGraph, Lookup — spec -> live graph
src/diagnose.jac    Diagnose, Survey, Probe walkers
src/explain.jac     byLLM Diagnosis obj + sem annotations
src/jacos.jac       CLI entry point
src/hw.py           live sysfs vs snapshot replay, one interface
src/quiet.py        silences litellm's provider banner
tools/dtb.py        device tree -> node/edge spec, phandle resolution, synthesizer
scripts/00-verify-jac.sh        on-device preflight
scripts/10-capture-topology.sh  busybox topology capture
scripts/20-fault-inject.sh      demo fault injection (driver unbind)
scripts/30-install-offline.sh   unpack jaclang wheel, no pip
scripts/jacos                   launcher, sets PYTHONPATH
fixtures/perry.json             synthetic healthy snapshot
fixtures/perry-fault.json       synthetic snapshot, pm8937_l10 disabled
docs/DEMO.md                    minute-by-minute run of show + failure recovery
vendor/                         gitignored; holds jaclang-0.16.7 wheel
```

Git log is clean and each commit message explains a real finding. Keep that up.

### The two design choices that carry the 40%

Do not refactor these away — they *are* the Jac score:

1. **Assessment dispatches by node type on arrival.** `can check_regulator with
   Regulator entry`, `can check_device with Device entry`, etc. A regulator is
   healthy if its rail is enabled; a device is healthy if a driver bound. The
   walker never branches on kind.
2. **Descent is one generic exit ability** (`can descend with HwNode exit`)
   inherited by every hardware type, so traversal policy is written once.

Third pillar: byLLM's return type is a `Diagnosis` object, so the type is the
schema — there is no prompt template and no output parsing anywhere in the repo.
The walker finds the fault by traversal; the LLM only phrases it.

---

## 3. Environment

**Phone (verified 2026-07-26):** Moto E4, pmOS, kernel `7.1.5-msm89x7
#3-perry-xylitol`, **aarch64**, **musl**, **Python 3.14**, 1833 MB RAM. All of
`/sys/firmware/devicetree/base`, `/sys/class/regulator`, `/sys/bus`,
`/proc/device-tree` present. `clk_summary` needs
`mount -t debugfs none /sys/kernel/debug`.

**SSH:** alias `perry` in `~/.ssh/config` → `xylitol@172.16.42.1`, key
`~/.ssh/jacos_perry` (ed25519, no passphrase, `IdentitiesOnly yes`). Passwordless
auth confirmed working. Device credentials are at `C:\Users\pradh\.jacos\SECRETS.md`
— deliberately **outside** the repo, because it is about to go public and a
gitignored secrets file is one `git add -f` from leaking. Password should be
rotated after the event.

**Dev venvs** (scratchpad, session-specific — recreate if gone):
`venv` full install, `nollvm` jaclang `--no-deps`, `bare` empty for PYTHONPATH
testing, `vendor/` unpacked wheel.

Jac 0.16.7. `pip install jaclang byllm` on the laptop reproduces everything.

---

## 4. Hard-won findings — do not rediscover these

**Jac / language**

- **Jac persists the root graph between runs** in `.jac/data/<entry>.db`. Two
  consequences that both caused real bugs: the importer must purge before
  rebuilding, and walker dedup guards must live on the *walker*, not on node
  state — guarding on `node.state` made every run after the first silently
  assess nothing.
- **`del <variable>` only unbinds the name.** Destroying nodes needs the
  list-literal form, `del [n]`, hence the loop in `BuildGraph`.
  `Jac.reset_graph()` exists but invalidates `root` mid-walk — do not call it
  from a walker standing on root.
- **Ability dispatch order:** for a subtype instance, the parent-type entry
  ability fires first, then the subtype's, then exit abilities. Verified
  empirically. This is why assessment lives only on subtypes.
- **byLLM import path is `byllm.lib`** on PyPI. The Jaseci monorepo vendors the
  same module at `jaclang.byllm.lib`; docs and fixtures use the latter and it
  will not resolve against a pip install.
- `MockLLM(model_name="mockllm", config={"outputs": [obj]})` returns typed
  objects fine — this is the offline demo fallback.
- Edge syntax: `src +>: EdgeType : field=val :+> dst`, filters `[->:Edge:->]`,
  `[<-:Edge:<-]`, `[-->][?attr=="x"]`, `[edge -->]`.

**Install / platform**

- **llvmlite is jaclang's only declared dependency, and nothing imports it.** It
  is reachable only via the `.na.jac` native codegen path, which JacOS does not
  use. It publishes no musl wheels, so a plain pip install on Alpine tries to
  build it from source. `pip install --no-deps jaclang` produces byte-identical
  output. **Verified.**
- **jaclang is a pure-Python wheel, so pip is not needed at all.** Unzip it with
  `python3 -c "import zipfile..."` and point `PYTHONPATH` at the directory. The
  full pipeline runs from a bare interpreter this way — verified. This is what
  `scripts/30-install-offline.sh` and `scripts/jacos` do, and it means the phone
  needs no network whatsoever. `pip3` is **not** present on the device.
- **`python3 -m jaclang` is PATH-proof.** Non-interactive `ssh perry '...'` does
  not source the profile, so `~/.local/bin/jac` is not on PATH.
- **CRLF breaks shell scripts on Alpine** (`bad interpreter`). `.gitattributes`
  forces LF. scp from Windows also drops the execute bit — `chmod +x` after.
- litellm prints a red provider banner even for MockLLM; `src/quiet.py` must be
  imported before byllm.

**Tooling gotchas**

- PowerShell here-strings passed to `git commit -m` get word-split when the
  message contains double quotes. Use `git commit -F <file>`.
- `Expand-Archive` refuses `.whl`; use Python's `zipfile`.

---

## 5. State: what is done, what is not

**Working and verified end to end** (against the synthetic fixture):
graph import with phandle resolution; type-dispatched assessment; dependency
traversal; root-cause ranking; typed byLLM explanation with offline mock;
live/replay parity; idempotent rebuild across runs; core CLI works without
`byllm` installed (it is imported lazily inside `cmd_diagnose`).

Correct output on `fixtures/perry-fault.json`:

```
ROOT CAUSE: /soc/spmi@200f000/pmic@0/regulators/l10
            rail pm8937_l10 is disabled at 1800 mV
```

**Done on the phone:** preflight, SSH keys, passwordless auth.

**NOT done — this is where to resume:**

1. `scp` the repo + wheel to `~/jacos` and run `scripts/30-install-offline.sh`.
2. **Capture the real device tree** and build the graph from it. *Nothing has
   ever run against a real DTB.* Expect ~800–1500 nodes vs the synthetic 11.
3. Rehearse the demo against real hardware.

**Highest open risk: `tools/dtb.py` phandle resolution on a real tree.** It has
only ever seen an 11-node synthetic fixture. Specific things likely to break:
`clocks` specifier widths are read from the target's `#clock-cells` and the
parser bails on the first unresolvable phandle; `interrupts-extended` is not
handled at all (only `interrupt-parent`); regulator `label`/`regulator-name`
matching against `/sys/class/regulator` is heuristic. **Tell: node count looks
right but edge count is suspiciously low.**

Other open items: byLLM is not installed on the phone and probably should not be
(litellm drags in pydantic-core and tiktoken, needing musl aarch64 wheels) — run
`diagnose -x` from the laptop against a captured snapshot, or use
`JACOS_LLM=mock`. `clk_summary` parsing for real clock health is unimplemented;
clocks currently assess as "present." `jac-cloud` fleet view is unstarted.

### Resume command

```bash
ssh perry 'mkdir -p ~/jacos'
scp -r src tools scripts fixtures vendor perry:~/jacos/
ssh perry 'cd ~/jacos && sh scripts/30-install-offline.sh vendor/jaclang-0.16.7-py3-none-any.whl'
ssh -t perry 'cd ~/jacos && sudo sh scripts/10-capture-topology.sh && python3 tools/dtb.py /tmp/jacos-snapshot -o fixtures/perry.json'
ssh perry 'cd ~/jacos && chmod +x scripts/jacos && ./scripts/jacos build fixtures/perry.json && ./scripts/jacos health'
```

Then pull the snapshot back for the replay fallback:

```bash
scp perry:~/jacos/fixtures/perry.json fixtures/perry-live.json
```
