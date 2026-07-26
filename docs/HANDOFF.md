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
fixtures/perry-live.json        THE REAL CAPTURE -- 465 nodes, what the demo uses
fixtures/perry-live-fault.json  same tree, vdda_touch disabled -- minute 4 + fallback
fixtures/perry.json             synthetic healthy snapshot (superseded, 11 nodes)
fixtures/perry-fault.json       synthetic snapshot, pm8937_l10 disabled (superseded)
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

**Dev venvs are scratchpad and session-specific — they will be gone.** Do not
plan around them. Recreating what the demo needs takes one command:

```bash
python -m venv .demovenv && .demovenv/Scripts/python.exe -m pip install jaclang byllm
```

Verified working 2026-07-26 on Windows/Python 3.14 — installs clean, no
llvmlite problem (that is musl-only). **Minute 4 of the demo needs this**, so
build it before presenting, not during.

If you only need the CLI and not `-x`, the vendored wheel works with no install
at all: unzip `vendor/jaclang-0.16.7-py3-none-any.whl` somewhere and set
`PYTHONPATH` to it. That is what `scripts/jacos` does on the phone.

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
- **`cp -h` does not exist** in busybox or coreutils. Use `-L`. Paired with
  `2>/dev/null` it produced an empty device tree capture that looked like
  success. Any capture step needs a hard post-check, not a silent redirect.
- **`~/.ssh/config` with a UTF-8 BOM** (PowerShell `>` or `Set-Content` writes
  one) makes OpenSSH fail with `Bad configuration option: \357\273\277host`.
  Write it with `-Encoding ascii` or strip the BOM.
- litellm prints a red provider banner even for MockLLM; `src/quiet.py` must be
  imported before byllm.

**Real device tree (learned 2026-07-26, second session)**

- **`interrupt-parent` is inherited.** A node with `interrupts` and no
  `interrupt-parent` routes to the nearest ancestor that has one. Resolving it
  self-only found 6 edges where perry has 79. `interrupts-extended` overrides it
  entirely and carries its own `<&ctrl specifier...>` pairs.
- **PMIC rails are bare children of a regulator container** — node name `l10`,
  no `compatible`, no `regulator-name`. Key off `regulator-*` property
  constraints, not compatible. Their sysfs label is the bare node name.
- **Join sysfs to the tree via each device's `of_node` symlink, never by
  reconstructing the device name.** `<addr>.<name>` is platform-only; i2c is
  `1-0020`, spi `spi0.1`, mmc `mmc0:0001`. The name heuristic reported the
  touchscreen as dead while `rmi4_i2c` was bound to it.
- **One tree node can back two sysfs devices** (i2c controller = platform device
  + adapter). Prefer whichever bound, or the unbound one wins and the bus reads
  as dead.
- **A DT node Linux never instantiated is not a probe failure.** `opp-table`,
  `idle-states`, `/timer`, `cpu@N` all have compatible strings and never bind.
  `in_sysfs` carries the ground truth through the graph.
- Real numbers: **465 nodes, 732 edges**; 464 parent_bus, 126 clocked_by,
  79 interrupts_to, 40 supplied_by, 18 dma_by, 5 reset_by. 26 regulators, all
  matched to sysfs. Build ~8 s on the phone, health ~7 s.
- **Captures are redacted by default.** perry's tree carries `serial-number`,
  the wcnss wifi `local-mac-address`, and `pmos_boot_uuid`/`pmos_root_uuid` in
  `/chosen` bootargs. `tools/dtb.py` strips those on capture, because snapshots
  are committed and the repo is going public. `--keep-identifiers` disables it
  and warns; do not commit the result.
- Device tree docs for this phone: https://github.com/aneesh-pradhan/xylitol

**Tooling gotchas**

- PowerShell here-strings passed to `git commit -m` get word-split when the
  message contains double quotes. Use `git commit -F <file>`.
- `Expand-Archive` refuses `.whl`; use Python's `zipfile`.

---

## 5. State: what is done, what is not

**Working and verified end to end against the real device:** graph import with
phandle resolution; type-dispatched assessment; dependency traversal;
root-cause ranking; typed byLLM explanation with offline mock; live/replay
parity; idempotent rebuild across runs; core CLI works without `byllm`
installed (it is imported lazily inside `cmd_diagnose`, and `-x` degrades to a
message rather than a traceback).

**Done on the phone:** preflight, SSH keys, passwordless auth, offline jaclang
install, real device tree capture, graph build, health, and root-cause
traversal — all verified against real hardware on 2026-07-26.

The end-to-end run that works today, on the phone and on the laptop:

```
build   465 nodes, 732 edges from fixtures/perry-live.json
health  16 findings (9 disabled rails, 7 unbound platform devices)
diagnose touchscreen -> walks 19 nodes, no fault (touchscreen is healthy)
--break-rail l6 -> ROOT CAUSE at hop 3, rail l6 disabled at 1800 mV
```

The real dependency chain the demo walks: `touchscreen@20` → `vdda_touch_vreg`
→ PMIC rail `l6` → `i2c@78b7000` → `clock-controller@1800000` → `xo-board`.
That is a genuine MSM8937 power tree, not the synthetic fixture.

### The demo — decided, rewritten, and dry-run on hardware

`docs/DEMO.md` is current as of 2026-07-26. **Every command in it was run
against the real phone and its real output is pasted in.** Do not re-derive it;
read it and rehearse it.

The touchscreen on this phone is *healthy* (`rmi4_i2c` bound), so the fault is
injected. **The chosen path is live unbind on the phone for minutes 2–3, plus
`--break-rail vdda_touch` in replay on the laptop for minute 4.** Both produce
the same `ROOT CAUSE: /vdda_touch_vreg`, which is what keeps the two halves of
the demo telling one story. This was chosen over an all-replay demo because
touching real hardware is the project's strongest claim.

**It is a two-terminal demo.** T1 = `ssh perry`, T2 = laptop. Minute 4 must run
on T2 because byllm is not installed on the phone and should not be. Discovering
this on stage is the failure mode DEMO.md now exists to prevent.

**Live unbind** (`sudo sh scripts/20-fault-inject.sh unbind i2c 1-0020`,
restore with `rebind i2c 1-0020 rmi4_i2c`) produces a real two-hop cascade:

```
! hop 1  /soc@0/i2c@78b7000/touchscreen@20   NO DRIVER BOUND
! hop 2  /vdda_touch_vreg                     rail vdda_touch is disabled
ROOT CAUSE: /vdda_touch_vreg
```

That second hop is not a bug and not staged. Unbinding the driver drops its
regulator reference, `vdda_touch` goes `num_users` 1 → 0 and powers down;
rebinding brings it back to `enabled`/1. Verified both directions.

But note the causality is **inverted relative to what was injected**: we broke
the driver and the tool blames the rail, because its ranking prefers the
deepest fault in the dependency chain. That heuristic is right for real
bring-up (a dead rail is why a device does not probe) and wrong for this
particular injection. **A judge who watched you type `unbind` will ask.**
DEMO.md has the rehearsed answer verbatim — the short version is that the rail
genuinely fell over because the driver was the consumer holding it up, and the
walker found that by traversal, not staging.

**`--break-rail <label>` only affects replay mode**, because live mode re-reads
sysfs and overrides the snapshot. That is why minute 4 is a laptop step.

**NOT done — this is where to resume:**

1. **Run the timed 4-minute rehearsal.** Everything it needs is verified and
   committed; what has never been measured is whether it fits in 4 minutes.
   This is the only remaining task before judging.
2. Make the repo public before judging (command in §2). **Still private.**
3. `clk_summary` parsing is still unimplemented; clocks assess as "present".
   The file *is* now capturable (68 KB, needs sudo + debugfs), so the data is
   there if someone wants real clock health.

**Remaining risk is presentation, not correctness.** The tree resolves cleanly
— no unresolvable phandles on perry, all 63 interrupt nodes and all 26
regulators matched. The open questions are whether the demo fits in 4 minutes
and whether 16 health findings reads as signal or noise to a judge.

byLLM is not installed on the phone and should not be (litellm drags in
pydantic-core and tiktoken, needing musl aarch64 wheels). `-x` is a laptop
step; on the phone it prints "byLLM not available" and keeps going.
`jac-cloud` fleet view is unstarted.

**Post-event, not now: JacHammer deploy.** Assessed 2026-07-26 against
`docs.jachammer.ai`. It is a browser-based full-stack app builder with GitHub
import, sandbox deploys (7-day, free) and permanent deploys. Live mode is
impossible there — no `/sys` — but `hw.py` auto-detects that
(`LIVE = os.path.isdir(DT_BASE)`) and falls back to replay with no code change,
and byLLM would work better there than on musl. The real blocker is that JacOS
is a CLI and JacHammer deploys web apps, so it is a frontend build, not a
deploy. Rejected for the event because it competes with rehearsal time and a
hosted replay of a canned snapshot is strictly less impressive than real
hardware. Good post-event artifact, and the natural home for the fleet view.

### Resume command

**The phone is already provisioned and healthy** as of the end of the
2026-07-26 session — jaclang installed, `~/jacos` populated, touchscreen bound,
no fault injected. To pick up for the rehearsal:

```bash
ssh perry 'cd ~/jacos && ./scripts/jacos build fixtures/perry-live.json && ./scripts/jacos diagnose touchscreen'
```

That must report **no faults**. A healthy start is what makes the injected
fault mean something. Then follow `docs/DEMO.md` — it is current and every
command in it has been run.

Laptop side, needed for minute 4 (scratchpad venvs do not survive a session):

```bash
python -m venv .demovenv && .demovenv/Scripts/python.exe -m pip install jaclang byllm
```

If the phone was reflashed or `~/jacos` is gone, reprovision from scratch:

```bash
ssh perry 'mkdir -p ~/jacos/vendor'
scp -r src tools scripts fixtures perry:~/jacos/
scp vendor/jaclang-0.16.7-py3-none-any.whl perry:~/jacos/vendor/
ssh perry 'cd ~/jacos && chmod +x scripts/*.sh scripts/jacos && sh scripts/30-install-offline.sh vendor/jaclang-0.16.7-py3-none-any.whl'
ssh perry 'cd ~/jacos && sudo sh scripts/10-capture-topology.sh && sudo chown -R xylitol /tmp/jacos-snapshot && python3 tools/dtb.py /tmp/jacos-snapshot -o fixtures/perry-live.json'
```

Then pull the snapshot back for the replay fallback:

```bash
scp perry:~/jacos/fixtures/perry-live.json fixtures/perry-live.json
scp perry:/tmp/jacos-snapshot.tar.gz fixtures/perry-snapshot.tar.gz   # gitignored, but minute 4 needs it
```
