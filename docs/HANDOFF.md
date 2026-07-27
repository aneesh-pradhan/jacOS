# JacOS — session handoff

Everything a fresh session needs to continue without re-deriving anything.
Written 2026-07-26.

**Start at §13** — the unbound-device heuristic fix and the numbers it moved.
§12 is the seventh session, which closed the two device-validation items §11
left open; everything above that is background and findings.

**Any health finding count printed before §13 is stale.** §5 says 16, §9/§11/
§12 say 18. The current answer is 16 with a different composition, and the Pi
is 1, not 3. §13 has the table.

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
src/main.jac        WEB entry point (fullstack): server imports + cl{} block
src/webapi.sv.jac   WEB server half -- walker:pub wrappers + wire view objs
src/components/ManPage.cl.jac    WEB client UI, drawn as a man page
src/components/ManPage.impl.jac  WEB handler bodies (all walker spawns)
src/components/ManPage.css       WEB styling (phosphor-terminal man page)
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

1. ~~Fix the web console's client render crash.~~ **Done — see §9.** The
   console loads in under a second, renders styled, and draws the dependency
   subgraph. Four separate bugs, none of them the one §7 suspected.
2. **Run the timed 4-minute rehearsal.** Everything the *terminal* demo needs
   is verified and committed; what has never been measured is whether it fits
   in 4 minutes.
3. **Devpost.** Partial-submission checkpoint 5:50 PM, hard close 7:15 PM. A
   **demo video** is on the submission checklist and does not exist yet —
   earlier sessions missed this entirely. Also on the checklist: star
   `github.com/jaseci-labs/jac`.
4. `clk_summary` parsing is still unimplemented; clocks assess as "present".
   The file *is* now capturable (68 KB, needs sudo + debugfs), so the data is
   there if someone wants real clock health.

Repo visibility is **done** — flipped public 2026-07-26.

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

---

## 7. The web console (added 2026-07-26, third session)

A second frontend over the same graph, styled as a man page. **Read this before
touching `src/main.jac`, `src/webapi.sv.jac` or `src/components/`.**

### Why it exists

Two reasons, in order of how much they matter.

The honest one: the submission checklist says *"Code must contain 40% of Jac"*,
and GitHub's own language stats put the repo at **34.6% Jac** (Python 45.9%,
Shell 19.4%). `tools/dtb.py` alone is 23,712 bytes — 72% of all Python here.
Rewriting the phandle parser hours before judging would be reckless, so the
honest way to move the number is to *add Jac*, not shave Python. After this
session the source tree measures **46.8% Jac** by bytes. Re-check the number
GitHub actually publishes with:

```bash
gh api repos/aneesh-pradhan/jacOS/languages
```

The better one: the console is not a bolted-on demo. The client calls
`root spawn DiagnoseNode(query=p)` and the server wrapper spawns **the same
`Diagnose` walker the CLI spawns**. One graph, one set of walkers, two
frontends — and no diagnostic logic anywhere in the web layer. If the traversal
rules change in `diagnose.jac`, both move together and neither can drift. That
is a much stronger Use-of-Jac claim than a second implementation would be.

### Architecture

Jac 0.16.7 has a full-stack story built in — no `jac-cloud` needed. It turns on
*codespaces*: `.sv.jac` is server, `.cl.jac` is client (compiled to React via
Vite/Bun), plain `.jac` mixes both through a `cl { }` block. `kind = "fullstack"`
in `jac.toml` wires it up and needs the `jac-client` pip plugin.

```
src/main.jac                     entry: server imports, then cl{} mounting ManPage
src/webapi.sv.jac                walker:pub wrappers + NodeView/Hop/DiagnosisView
src/components/ManPage.cl.jac    the man page; owns all state (stateful shell)
src/components/ManPage.impl.jac  handler bodies -- every one is a walker spawn
src/components/ManPage.css       phosphor-terminal styling
```

Endpoints: `LoadTree`, `Status`, `TreeNodes`, `HealthCheck`, `DiagnoseNode`.

Run it:

```bash
.demovenv/Scripts/jac.exe start src/main.jac --port 8100
```

Dev mode (`--dev`) splits ports: client on `--port`, API on `port+1`. Without
`--dev` both are on one port, which is simpler to reason about — prefer it.

### What is verified and what is not

**Server half: verified end to end.** `POST /walker/LoadTree` returns
`StatusView(device='motorola-perry', nodes=465, edges=732, mode='replay')` and
`POST /walker/DiagnoseNode {"query":"touchscreen"}` returns a `DiagnosisView`
whose 19-hop trail is **identical to the CLI's**. The typed `obj`s cross the
wire hydrated. This is the load-bearing claim and it holds.

**Client half: FIXED in §9 — read that instead of the paragraph below.** The
account here of *what* breaks is accurate; the three suspects it nominates are
all wrong, and the real causes are in §9.

**Client half: renders, then crashes.** The page serves 200, React mounts, and
the man page draws correctly in its loading state — header, NAME, SYNOPSIS,
DEVICE TREE, SEE ALSO, footer all present and styled. Then `LoadTree` and
`TreeNodes` both return **200**, and the moment the populated tree renders the
component throws and blanks the page:

```
TypeError: Cannot read properties of undefined (reading 'message')
```

Both RPCs succeed, so **this is a render bug, not a data bug.** Prime suspects,
in the order worth checking:

1. `n.kind[0:3]` in the tree row — string slicing on a possibly-empty `kind`.
2. `", ".join(n.rails)` — `rails` undefined on some rows.
3. The inline `style={{"paddingLeft": ...}}` dict inside a statement slot.

Reproduce: start the server, open `localhost:8100`, watch the browser console.
`jac browse` is the documented QA tool but **needs Chrome on PATH** (set
`JACBROWSER_CHROME`); it is not installed on this machine.

### Findings — do not rediscover these

- **`jac create --force` overwrites `jac.toml` and `.gitignore`.** It silently
  replaced the project's real `jac.toml` (name, description, the `byllm`
  dependency) with a generic scaffold one. Both were recovered by hand. Back
  them up before scaffolding anything.
- **The CSS annex must be named `Comp.css`, NOT `Comp.style.css`.** The bundled
  `jac-cl-styling` guide says `.style.css`; the compiler actually emits
  `import "./ManPage.css"`, so the guide's name fails the Vite build with
  `Could not resolve "./ManPage.css"`. The guide is wrong here.
- **A stale Vite failure is cached and survives the fix.** After renaming the
  CSS the identical error kept being served (same "1.3s"/"428ms" timings gave
  it away). `rm -rf .jac/client/compiled` and restart.
- **Module resolution anchors at the entry file's directory.** `main.jac` at the
  repo root loading `src.webapi` makes that module's bare `import from topology`
  fail with `No module named 'topology'` — and `diagnose.jac`'s `import hw`
  would fail next. Fix: keep the web entry **inside `src/`** (`entry-point =
  "src/main.jac"`) so the server resolves modules exactly as the CLI does. Do
  not hoist `main.jac` to the root.
- **`jac check` is stricter than `jac run`.** `src/jacos.jac` has always failed
  `jac check` (`Lookup.found` is an untyped `list`, so spawn results type as
  `Unknown`) while running fine. Do not "fix" the CLI in response to those
  errors. New code should still check clean — dict subscripts need `as int` /
  `as str` casts and spawn results need `as <Walker>`.
- **E2023, redundant slot braces.** Inside a statement-slot body you are already
  in slot mode: write `if cond { <X/> }`, not `{if cond { <X/> }}`. The braces
  are only needed when descending from a JSX element's *children* into a slot.
- **`jac guide <name>` is the authoritative Jac reference** and ships with the
  compiler. `jac guide` lists ~25 of them. `jac-cl-components`,
  `jac-fullstack-patterns` and `jac-cl-styling` are the ones that matter here.
  They are far better than guessing at the syntax.
- Client walker spawns take **kwargs**; `def:pub` function RPCs take
  **positional args only** (kwargs 422). Reader responses are cached 60s.

### Resume command

```bash
ssh perry 'cd ~/jacos && ./scripts/jacos build fixtures/perry-live.json && ./scripts/jacos diagnose touchscreen'
```

That must report **no faults**. A healthy start is what makes the injected
fault mean something. Then follow `docs/DEMO.md` — it is current and every
command in it has been run.

Laptop side, needed for minute 4 (scratchpad venvs do not survive a session).
`jac-client` is needed only for the web console, not for the terminal demo:

```bash
python -m venv .demovenv && .demovenv/Scripts/python.exe -m pip install jaclang byllm jac-client
```

The first `jac start` after a fresh venv downloads Bun and ~80 npm packages
into `.jac/` (about 90 s). `.jac/` is gitignored, so a clone pays that cost
once. Budget for it — do not discover it on stage.

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

---

## 8. Web console, fourth session — the "frontend is broken" triage

Written 2026-07-26, interrupted by a planned reboot. **Superseded by §9 —
all of it is fixed now.** Kept because the reasoning is still the fastest way
to understand the shape of the problem: §7's suspect list is wrong, and the
"inaccessible" symptom is a separate bug from the crash. §8's central
insight — that the error everyone was chasing is the ErrorBoundary's own
secondary crash and not the real error — was correct and is what made §9
possible. Its *diagnosis* of Failure A as a deadlock was wrong; see §9.

### There are two independent failures, not one

§7 describes one bug (a client render crash). There are actually two, and the
second one masks the first, which is why this looked so confusing.

**Failure A — the dev server deadlocks, and that is what "localhost:8100 is
completely inaccessible" means.** Verified on the live process:

```
netstat: 0.0.0.0:8100 LISTENING  +  five sockets stuck in CLOSE_WAIT
Get-Process: Threads = 1, CPU consumed over a 5 s window = 0.00 s
```

One thread, zero CPU, sockets the server accepted and never closed. It is
blocked, not spinning — so it is a deadlock or an unbounded blocking wait inside
request handling, *not* an infinite loop and *not* slow graph import. Once the
accept backlog fills with those CLOSE_WAIT sockets, Windows starts **actively
refusing** new connections, so the port goes from "hangs" to "connection
refused" and the server looks dead while the process is still alive. Both
symptoms are the same bug at different backlog depths.

Consequence worth internalising: **`jac start` printing "Server ready" tells you
nothing.** It printed that every single time while serving nothing.

**Failure B — the render crash from §7, which is still real and still
unexplained**, but see below: the error message everyone has been chasing is not
the error.

### `Cannot read properties of undefined (reading 'message')` is a red herring

Resolved the minified frame `Nx` in `.jac/client/dist/client.*.js`. It is **not
JacOS code** — it is jac-client's own ErrorBoundary fallback component:

```js
function Nx(e){const{error:t,resetErrorBoundary:i}=e; ... [t.message] ... }
```

mounted at the bundle root as
`createElement(ErrorBoundary,{FallbackComponent:Nx,onError:Fx}, <App/>)`.

So the sequence is: the real error throws → the boundary catches it → the
boundary renders `Nx` → **`Nx` crashes on `error.message` because `error` is
undefined** → that secondary crash is what reaches `window.onerror` and what
lands in `.jac/jacos-web.stderr.log`. The original error is swallowed and never
logged anywhere.

**Everything in §7's "prime suspects, in the order worth checking" list was
guesswork against this phantom.** All three suspects have since been patched
(uncommitted, see below) and the crash is unchanged — confirmed by timestamps:
`ManPage.cl.jac` edited 15:50, bundle rebuilt 15:58, identical crash logged
16:02. Do not spend more time on that list.

**The next move on Failure B is to make the real error visible, not to guess
again.** Options, best first: render the page and read the browser console
directly (React logs the original error via `console.error` *before* the
boundary re-renders, so it is visible in devtools even though it never reaches
`window.onerror`); or flip `[plugins.client] debug` in `jac.toml` (currently
`false`, added uncommitted this session) and rebuild; or temporarily wrap
`<ManPage/>` so the boundary is bypassed.

### One genuine compiler bug, found by reading the emitted JS

Independent of both failures above, and it will bite during the demo the moment
anyone clicks a device-tree row. In `ManPage.cl.jac` the row handler is

```jac
onClick={lambda e: MouseEvent { diagnosePath(n.path); }}
```

`.jac/client/compiled/components/ManPage.js` emits it as:

```js
"onClick": e => { __jac_view_kids_2.push(diagnosePath(n.path)); }
```

The lambda body sits inside a JSX children slot, so the compiler treated the
lambda's own braces as a *view slot body* and rewrote a plain call into a push
onto the enclosing children accumulator. Clicking a row therefore pushes a
pending Promise into the children array of an already-rendered element instead
of running the walker. The identical lambda on the SYNOPSIS `run` button
compiles correctly (`e => { diagnosePath(query); }`) because it is not nested in
a `for` slot.

Workaround to try: hoist the body out of the lambda — give `ManPage` a named
`def onRowClick(p: str)` and pass a reference, rather than an inline lambda
inside a slot. Same shape as `onClick={boot}`, which compiles clean.

### Uncommitted working-tree state as of the reboot

`git status` is dirty and **none of it is committed**. Do not assume `master`
reflects any of this:

- `src/components/ManPage.cl.jac` / `.impl.jac` — renamed the state field
  `filter` → `query` (it shadowed nothing provable; unverified as a fix),
  guarded `n.kind[0:3]` and `n.rails`, dropped the inline `style={{...}}` dict.
  These are §7's three suspects. **They do not fix the crash.**
- `jac.toml` — added `debug = false` under `[plugins.client]`.
- `src/hw.py` — new `_clk_summary_map()`, implementing the `clk_summary`
  parsing listed as open item 4 in §5. Clocks now assess by `enable_count`
  instead of always reporting "present". **Untested against the phone**, and it
  changes health output, so re-run the §5 end-to-end numbers before trusting the
  demo: it can move the "16 findings" count.
- `pi_capture.py` — untracked, new, unrelated to the console: paramiko driver
  that waits for `raspberrypi.local`, pushes `10-capture-topology.sh`, and pulls
  a tarball to `fixtures/pizero-snapshot.tar.gz`. Note it has a **hardcoded
  default password in cleartext** (`pi`/`raspberry`) and the repo is public —
  do not commit it in that form.

### Restart procedure after the reboot

The reboot clears Failure A's wedged process and the CLOSE_WAIT backlog for
free, which is the one good thing about it. Before assuming a fresh `jac start`
works, know that **stale servers squat the port**: this session found *two*
complete `jac start ... --port 8100` process trees alive simultaneously (six
processes, from 15:56 and 16:13). Only the older tree actually held the
listening socket; the newer one still printed the full "Server ready" banner, so
there was no way to tell from its output that it owned nothing. Always check
first:

```powershell
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='jac.exe'" | Select-Object ProcessId,Name,CommandLine | Format-List
```

Kill every `jac start` tree you find, confirm the port is free, then start one:

```powershell
Get-NetTCPConnection -State Listen -LocalPort 8100 -ErrorAction SilentlyContinue
```

Verify it is actually serving before opening a browser — "Server ready" is not
evidence. A raw socket probe is the honest test, because `Invoke-WebRequest`
reports a saturated backlog as "Unable to connect", which reads like "nothing is
listening" and sends you down the wrong path:

```powershell
$c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1',8100)
```

Then clear the client build cache before rebuilding — §7 already records that a
stale Vite failure survives the fix that should have cleared it:

```bash
rm -rf .jac/client/compiled .jac/client/dist
```

### Priority call for the time that is left

Failure A blocks everything, including the ability to observe Failure B, so it
goes first. But be honest about the clock: the web console is a Use-of-Jac
booster on a submission whose **terminal demo is already verified end to end on
real hardware**, and §5 items 2 and 3 — the never-measured 4-minute rehearsal
and the **demo video that does not exist** — are on the critical path to
submitting at all. If the console is not serving within a short, fixed timebox,
cut it and ship the terminal demo. The 46.8%-Jac source ratio from §7 is already
banked in the tree either way.

---

## 9. Web console, fifth session — working, styled, and drawing the graph

Written 2026-07-26. **The console works end to end.** Both failures in §8 are
fixed, and there were two more nobody had found. Every claim below was checked
in a browser against the running server, not inferred.

### Failure A was never a deadlock — the import is just slow

`LoadTree` takes **~40–75 s**, because `BuildGraph` purges and reinserts 465
nodes and 732 edges and every one of those is a persisted write. The CLI pays
27 s for the same work, so this is inherent to the store, not a server bug.

The dev server handles **one request at a time**. `boot()` called `LoadTree`
unconditionally on mount, so for over a minute every other fetch sat in the
accept backlog — which is what produced §8's five `CLOSE_WAIT` sockets, and
then outright connection refusals once the backlog filled. "One thread, 0.00 s
CPU over a 5 s window" was not a lock; it was a process blocked on disk.

Fix: **ask before importing.** `boot()` spawns `Status` first and only builds
when the graph is empty. A `GraphMeta` node (in `webapi.sv.jac`, hung off root
by a `MetaOf` edge so `BuildGraph`'s registry purge walks past it) records
device/nodes/edges/spec, so `Status` answers in ~90 ms. `LoadTree` also
declines to rebuild a spec that is already resident unless passed
`force=True`, which is what the SYNOPSIS `build` button sends.

Page load is now **under a second**.

### `node` is a reserved word, and misusing it silently empties every `impl`

`def:pub TreeRow(node: NodeView, ...)` in a `.cl.jac` produces
`error[E0013]: 'node' is a keyword and cannot be used as a parameter name`.
The build does **not** fail. What happens instead is that the compiler emits
the component markup correctly and drops every `impl` body on the floor:

```js
async function boot() {}          // ManPage.impl.jac, silently discarded
async function diagnosePath(p) {}
```

So the page renders its loading state forever and never issues a single
walker call. Rename the parameter (`row`, `blk`) or escape it as `` `node ``.

**`jac check` catches this and the client build does not.** Run
`jac check src/components/*.cl.jac` after touching a component; hard errors
there are real even though §7 is right that `jac check` also flags harmless
things in `src/jacos.jac`.

### The render crash: `", ".join(...)` does not survive client lowering

This is the bug that outlived four sessions. In `.cl.jac`,
`", ".join(row.rails)` lowers to `_jac.poly.call(", ", "join", row.rails)` —
a method dispatch on a **string primitive** — and it throws a non-`Error`
value. That is precisely why §8 found `error` to be `undefined` inside the
ErrorBoundary fallback: there was no error object to read `.message` from.

It only executes on a row that actually *has* rails, which is why the page
looked fine while loading and blanked the instant real data arrived, and why
§7's "guard `n.rails`" patch changed nothing — `rails` was never undefined.

Build the string with a loop instead (see `TreeRow`). Treat client-side
`str.join`, and Python string methods generally, as suspect in `.cl.jac`.

### The stylesheet had never once loaded — in any session

§7 records that the man page "draws correctly ... header, NAME, SYNOPSIS ...
all present and styled". The structure was there; **the styling never was.**
The archived bundle from that session contains zero CSS text. The page had
been rendering as unstyled black-on-white Times New Roman the whole time.

The annex mechanism works like this, and it is easy to invert:

- The **source** must be `ManPage.style.css`. The compiler pairs it by base
  name and injects `import "./ManPage.css";` — that emitted name is its
  *output*, not the name you give the file.
- §7 read the emitted import as the required source name and renamed the file
  to `ManPage.css`. That stops the pairing dead: no import is emitted, no CSS
  enters the bundle, and the build goes green. A silent unstyled page is the
  failure mode, which is why it survived so long.
- But `.style.css` does not work here either: the compiler emits the import
  and then **never copies the annex** into `.jac/client/compiled/components/`,
  so Rollup dies on `Could not resolve "./ManPage.css"`.

**The route that works** — and is the guide's documented one for app-wide CSS
— is an explicit import of a file under `assets/`:

```jac
cl {
    import "@jac-client/assets/console.css";
    ...
}
```

`assets/console.css` is copied to `compiled/assets/`, `@jac-client/assets` is
already aliased there in the generated Vite config, Vite emits `dist/styles.css`
and the server links it as `/static/styles.css` on its own. Verified in the
browser: `document.styleSheets` is non-empty and `.man` computes to the
phosphor palette.

### DEPENDENCY GRAPH — the console now draws the graph as a graph

New section between DEVICE TREE and DIAGNOSTICS. `DiagnoseNode` additionally
reports `nodes: list[GraphNode]` and `edges: list[GraphEdge]`, projected by
`_subgraph()` in `webapi.sv.jac`, which follows exactly the four edge types
`Diagnose.descend` follows so the drawing and the walk cannot disagree. It is
projection only — it reads the assessment `Diagnose` already wrote and decides
nothing about health.

Layout is client-side (position is a property of the picture, not of the
hardware): column by hop distance from the symptom, row by arrival order,
deterministic so the drawing is identical every time it is shown. Edge colour
is edge archetype — amber `supplied_by`, cyan `clocked_by`, violet `reset_by`,
dashed grey `parent_bus` — with a legend, because "these are different kinds of
relationship" is the entire claim. Clicking any block re-runs the walk from it.

Verified for touchscreen: 19 boxes, 32 edges, six depth columns, contained in
its own horizontal scroller so the page never scrolls sideways.

**Use `camera@10` for the console, not `touchscreen`.** The touchscreen is
healthy, so the browser demo ends on "no faults found" — true, and flat. The
rear camera on this phone is genuinely dead and needs no injection at all:

```
/soc@0/cci@1b0c000/i2c-bus@0/camera@10  <-  cam_vana_2v8, cam_vio_1v8, l23
```

All three of its supplies are disabled, so the walk lights four hot edges
across 22 nodes and ranks **`l23`** — the PMIC rail — above the two local
regulators, which is exactly the class-then-depth heuristic in
`Diagnose.root_cause()` doing its job on real data. It is the strongest thing
the console can show, and unlike the terminal demo's `unbind` it invites no
awkward question about what was staged.

Motion is spent deliberately and only twice: edges pointing at an unhealthy
node animate, and the root cause carries an expanding halo. Everything else is
still, so on a projector the eye goes straight down the fault chain. Anything
that adds a third moving thing is taking that away.

### Two things to know before demoing it

- **`health` reports 18 findings here, not the 16 in §5** — *(both counts are
  superseded; see §13, which fixed two false positives and lands on 16 with a
  different composition. The machine-dependence below is still true.)* — and
  *which number you get depends on the machine*, which is the part that
  matters. The
  `_clk_summary_map()` added to `src/hw.py` reads clock state from
  `fixtures/clk_summary.txt` or from `fixtures/perry-snapshot.tar.gz`. **That
  tarball is gitignored** (`fixtures/*.tar.gz`) and happens to be present in
  this working copy, so clocks assess by `enable_count` here and report 18. On
  a fresh clone the file is absent, `_clk_summary_map()` returns empty, clocks
  fall back to "present", and health reports 16. Decide which number the demo
  script claims, and if it is 18, make sure the machine you present from
  actually has the tarball — `scp perry:/tmp/jacos-snapshot.tar.gz
  fixtures/perry-snapshot.tar.gz`.
- **The `build` button really does cost ~40 s** and blocks the whole server
  while it runs. It is labelled with that in the UI. Do not press it on stage;
  the graph is already resident and `Status` proves it in milliseconds.

### What is left, in priority order

1. **The timed 4-minute rehearsal.** Still never measured. This is the single
   highest-value thing left and it needs a human with a stopwatch.
2. **The Devpost demo video.** On the submission checklist, still does not
   exist.
3. **Star `github.com/jaseci-labs/jac`** — also on the checklist, ten seconds.
4. **The Pi Zero W capture** (§10). Genuinely nice, genuinely optional.
5. `jac mcp` and a jac-cloud fleet view — both post-event.

Repo visibility, the 40%-Jac requirement, and the console are all done. As of
this session `gh api repos/aneesh-pradhan/jacOS/languages` reports Jac 62,691 /
Python 35,004 / Shell 13,864 / CSS 9,521 — **51.8% Jac**, comfortably over the
40% the checklist asks for and up from the 34.6% in §7.

### Stale second build tree

`src/.jac/` exists alongside the real `.jac/` — an older tree from when the
entry resolved differently. It holds a 2:59 PM `compiled/components/ManPage.css`
and its own `data/main.db`. Nothing reads it now. It is worth deleting once
someone confirms the DB in it is not the one being demoed.

---

## 10. The Raspberry Pi, and running this repo with parallel agents

Written 2026-07-26 at the end of the fifth session.

### The Pi Zero W

There is a second board in play. Verified over its serial console this
session — it is **up, healthy, and untouched by JacOS**:

```
Raspberry Pi Zero W Rev 1.1   armv6l   Linux 6.18.34+rpt-rpi-v6
Python 3.13.5    426 MB RAM    57 GB SD, 4% used    34 °C
162 device tree nodes, 5 regulators, 50 platform devices
base64, tar, gzip present (no xxd)    sshd active    home dir empty
```

**Reach it on `COM6` at 115200, not over the network.** A Silicon Labs CP210x
USB-UART bridge is wired to its console and a shell is already logged in as
`pi`. The network route does not work here and it is worth knowing why so
nobody re-debugs it: sshd *is* active and the Pi *does* have an address
(`10.104.9.37`), but the laptop is on `10.104.8.248` and the two cannot route
to each other — the venue network isolates clients. `raspberrypi.local` does
not resolve for the same reason. `pi_capture.py` therefore cannot run as
designed; it now fails with that explanation instead of looping forever.

A probe script that reads the console without typing anything into it lives in
the scratchpad pattern below — open the port, send a bare `\r`, collect for a
few seconds, close. **Only one process may hold `COM6`.** A PuTTY window
titled `COM6 - PuTTY` had it locked at the start of this session; it was closed
with permission. Check for one before assuming the adapter is broken.

The capture is worth doing and is not hard: 162 nodes gzip small, and
`base64` on the Pi plus a decode on the laptop moves the tarball over the
console in seconds at 115200. The payoff is the strongest version of this
project's claim — *the same walkers, unmodified, on a completely different
SoC* — because `topology.jac` and `diagnose.jac` never learn what a BCM2835
is. Do it after the rehearsal and the video, not before.

### If several agents work this repo at once

Most of this repo parallelises fine. Five things do not, because they are
single instances of shared state, and two agents touching one of them produce
failures that look like bugs in the code:

- **Port 8100 and the dev server.** One `jac start` at a time. §8 records two
  complete server trees alive at once, only the older holding the socket,
  both printing "Server ready" — there is no way to tell from the banner which
  one owns the port. Kill every `jac.exe`/`python.exe` tree and confirm the
  port is free before starting one.
- **`.jac/data/main.db` — the graph is a shared database.** A `LoadTree` with
  `force=True` purges and rebuilds it for ~40 s while blocking the whole
  server, and anything else reading the graph during that window sees a
  half-built tree. Exactly one agent may own graph rebuilds.
- **`.jac/client/compiled` and `.jac/client/dist`.** The fix for a stale Vite
  failure is to delete both, which detonates any concurrent build. One agent
  owns the client build loop.
- **`COM6`.** Exclusive lock, one holder, no sharing.
- **The phone.** One `perry`, and `scripts/20-fault-inject.sh` changes global
  hardware state — an unbind by one agent is visible to every other.

The work that *does* fan out cleanly, and is worth splitting: the rehearsal
timing pass, the demo video, the Pi capture, `clk_summary` portability (§9),
and documentation. Those touch disjoint files and no shared device.

One process rule that matters more with several agents than with one:
**`git commit -F <file>`, never `-m`.** PowerShell word-splits a `-m` message
containing double quotes, and the resulting commit log is the one artifact a
later session cannot repair.

---

## 11. Sixth session — submission push, jac_OS rebrand, wrap before reboot

Written 2026-07-26 ~6:30 PM, wrapping because the laptop needs a restart
(suspected cause of the phone USB-network failure below). Devpost hard close
is 7:15 PM tonight; if you are reading this after the event, items 1-2 below
are moot and item 4 (Pi validation) is the interesting one.

### Done this session

- **Devpost copy**: `docs/DEVPOST.md` (commit `a5c9041`) is ready-to-paste —
  title, tagline, description, challenges, built-with, checklist, and a 1:30
  video shot list. The human was pasting it into Devpost at ~6:15 PM.
  **Live language stat: 50.2% Jac** (69,403 bytes) — §9's "51.8%" is stale
  because CSS grew. Repo confirmed public. `jaseci-labs/jac` starred.
- **Web console rebranded jac_OS** (commit `df2584c`) and verified in a real
  browser: tab title (was literally "app" — nothing had ever set
  `[plugins.client.app_meta_data] title`), header/footer `JAC_OS(1)`, NAME
  line. Deliberately NOT changed: the SYNOPSIS (`jacos build|...` is the real
  executable) and the ASCII banner (redrawing box glyphs unrehearsed is how
  the page breaks on a projector).
- **The console demo path is browser-verified**: type `camera@10`, RUN →
  22-node walk, faults at hops 2/3/4/6, `ROOT CAUSE .../l23` disabled at
  1200 mV, dependency graph draws with the four-archetype legend.
  **§13 changed this: the hot hops are now 2/3/4** (hop 6 was a false
  positive). The root cause is unchanged. Re-rehearse the beat.
- **This machine reports 18 health findings** (the gitignored
  `fixtures/perry-snapshot.tar.gz` is present) — claim 18, not 16.
  **Superseded by §13: it is now 16**, and not §5's 16 either.
- **Pi Zero captured over COM6** (commit `0a53fcf`):
  `fixtures/pizero-live.json`, 162 nodes from a BCM2835. `tools/dtb.py` no
  longer hardcodes the board name (read from root `compatible`; perry output
  byte-identical). Graph build verified — it announces
  `raspberrypi-model-zero-w` — but the health/topology pass was interrupted.

### Known console behaviors (verified, don't rediscover)

- The dev server is single-threaded and blocks in `recv` on an idle browser
  keep-alive socket: a SECOND client (curl, another tab) can starve ~90 s.
  One tab on 8100, nothing else polling it. Browser-driven use is fast.
- First `DiagnoseNode` after boot once measured 143 s under contention with
  the page's own boot requests; a clean re-time was never completed. Verify
  the latency once before doing it live.
- Do not click the `build` RUN button on stage (~75 s, blocks everything).

### Punch list after the reboot, in order

1. **Devpost**: confirm the submission saved; the demo video is the last
   checklist item and needs a human (shot list in DEVPOST.md §6).
2. **Restart the web console**: check nothing squats port 8100, then
   `.demovenv/Scripts/jac.exe start src/main.jac --port 8100`. The graph is
   resident, so Status answers instantly — no rebuild.
3. **Phone validation — never completed this session.** The Moto E4 boots
   and its USB gadget enumerates (Windows shows "UsbNcm Host Device"), but
   the host stuck at APIPA `169.254.x` — no DHCP lease from the phone, so
   `172.16.42.1` unreachable. The reboot is the first thing to try; if DHCP
   still fails, assign `172.16.42.2/24` on that adapter from an elevated
   shell. Then run the §7 resume command (must report no faults) and one
   unbind → diagnose → rebind → diagnose round trip. Leave the phone healthy.
4. **Finish the Pi validation** (optional, post-event ok): run build+health
   against `fixtures/pizero-live.json` and record the numbers. Only then
   claim cross-SoC out loud.
5. The timed 4-minute rehearsal — still never measured.

---

## 12. Seventh session — both device validations closed

Written 2026-07-27, the day after the Devpost close. §11 items 3 and 4 are
done; the numbers are below. Nothing in this session was committed.

### Item 3 — the phone, validated end to end

**The USB-network failure was never the phone.** §11 diagnosed it as "no DHCP
lease from the phone." The real cause is one level down: with the host stuck on
APIPA `169.254.x`, there is **no route into `172.16.42.0/24`**, so no packet
ever leaves the interface. The phone's `usb0` was up the entire time, correctly
holding `172.16.42.1/16`.

This matters because the symptoms mimic dead hardware convincingly. Before the
static IP the adapter's neighbor table held **only multicast entries, no
peer**, and `ping -6 ff02::1%<ifIndex>` got no reply — which reads as "nothing
on the other end" and is entirely explained by having no route. **Check the
host routing table before suspecting the device.**

- **Rebooting the laptop did not fix it.** §11 lists the reboot as the first
  thing to try; it was tried and the APIPA state returned. Skip it.
- The fix is the elevated static IP, and it works completely:
  `New-NetIPAddress -InterfaceAlias 'Ethernet 4' -IPAddress 172.16.42.2
  -PrefixLength 24`. Ping went 3/3 at 1 ms, ARP `Reachable`.
- **Prefer `-PrefixLength 16`** to match the phone's `usb0`. `/24` works only
  because each subnet happens to contain the other.
- **The address is `Tentative` for a moment** during duplicate-address
  detection, and connections opened in that window still time out. One `ssh`
  attempt failed for this reason alone. Confirm `AddressState: Preferred`
  before concluding the fix failed.

Resume command result — the §7 gate, unchanged: `465 nodes, 732 edges`,
`mode: live`, `diagnose touchscreen` walks 19 nodes, **no faults found**.

The unbind round trip was run and matches §5 verbatim in both directions:

```
unbind i2c 1-0020   -> ! hop 1 touchscreen@20  NO DRIVER BOUND
                       ! hop 2 /vdda_touch_vreg  rail vdda_touch is disabled
                       ROOT CAUSE: /vdda_touch_vreg
rebind i2c 1-0020 rmi4_i2c -> no faults found
```

The restored walk re-reads live sysfs, so it is independent confirmation the
rail came back enabled rather than a cached "clean". **The phone was left
healthy.**

### Item 4 — the Pi Zero, and the limit it exposes

Build and health against `fixtures/pizero-live.json`, replay mode on the
laptop. **The Pi does not need to be connected for this** — the fixture was
captured in §11 (commit `0a53fcf`) and this is a pure replay run.

| | Pi Zero W (BCM2835) | perry (MSM8937) |
|---|---|---|
| nodes / edges | 162 / 247 | 465 / 732 |
| device | `raspberrypi-model-zero-w` | `motorola-perry` |
| regulators | 5 | 26 |
| health findings | 3 → **1** (§13) | 18 → **16** (§13) |

```
! /cam1_regulator      ::  rail cam1-reg is disabled
! /chosen              ::  NO DRIVER BOUND -- device did not probe
! /soc/timer@7e003000  ::  NO DRIVER BOUND -- device did not probe
```

**The cross-SoC claim is validated, but only for construction and traversal.**
`topology.jac` and `diagnose.jac` never learn what a BCM2835 is and needed zero
changes. That part is real and is worth saying out loud.

**Health precision is not validated — 2 of the 3 findings are false
positives**, and §4's stated defense does not cover them. *(Fixed in §13 —
both are gone, on perry as well as the Pi. The diagnosis below is still the
clearest statement of what was wrong.)*

- `/chosen` is not a device; it holds bootargs. Pi firmware stamps it
  `compatible = "simple_bus"`, so `tools/dtb.py` classifies it `kind: "bus"`
  and it gets assessed.
- `/soc/timer@7e003000` is a clocksource. Linux drives it through the timer
  subsystem, never the driver-model probe path, so it legitimately never binds.

**Both have `in_sysfs: 1`.** §4 records that `in_sysfs` carries the ground
truth for exactly this class of node, and on perry it did — those nodes were
absent from sysfs entirely. On the Pi they are **present but unbound**, so the
guard never fires. The heuristic was tuned against one SoC and does not
transfer. `in_sysfs` is necessary but not sufficient; distinguishing "never
instantiated" from "failed to probe" needs a second signal.

`/cam1_regulator` is a true reading (`bound: true`, `reg_state: "disabled"`,
0 µV) — a fixed camera rail that is off because no camera is attached. Correct,
and benign rather than a fault.

**Recommended framing:** claim the walkers running unmodified on a second SoC;
do not quote Pi findings counts. *(§13 lifts the second half — the Pi now
reports a single finding and it is a true one, so the count is quotable.)*

### One cosmetic gotcha worth knowing on a projector

During `build`, the banner printed `graph 465 nodes / rails 26 regulators`
while the line below announced `built 162 nodes`. The banner renders from the
graph resident at **startup**, before the rebuild lands. Harmless, but it reads
as a contradiction on a screen. The subsequent `health` run showed `162 / 5`
correctly.

### What is left

1. ~~**Tighten the unbound-device heuristic**~~ **Done — see §13.** It also
   removed two false positives nobody had noticed on perry.
2. The timed 4-minute rehearsal — still never measured, and moot unless a
   video is still wanted.
3. `jac mcp`, jac-cloud fleet view, JacHammer deploy (§5) — all post-event.

Separately, §9's note still stands: `src/.jac/` is a stale second build tree
and can be deleted once someone confirms its DB is not the one being demoed.

---

## 13. The unbound-device heuristic, fixed — and the numbers it moved

Written 2026-07-27. **Every health finding count printed before this section
is stale.** §5 says 16, §9 and §11 and §12 say 18; the answer is now **16 with
a different composition**, and the Pi's 3 is now 1. Read the table below
rather than any earlier number.

### What was actually wrong

`_expects_driver()` in `src/hw.py` had three defects, and the first is the one
that mattered:

1. **`in_sysfs` short-circuited every rule below it.** The function returned
   `in_sysfs == 1` before it ever reached the compatible-string filters, so a
   node that is in sysfs but is pure topology or is claimed by an early
   subsystem was reported as a failed probe. This survived six sessions
   because on perry those nodes happen to have `in_sysfs == 0` and exited one
   line earlier. It took a second SoC to expose it. **§4's claim that
   `in_sysfs` carries the ground truth for never-instantiated nodes is
   therefore wrong** — it is necessary, not sufficient.
2. **Separator mismatch.** `_NO_DRIVER_EXPECTED` held `simple-bus`; Pi
   firmware emits `simple_bus`. Compared raw, it never matched.
3. **The empty-compatible rule only ran on the `in_sysfs == -1` path.** Driver
   matching is by compatible string, so a node with none cannot be a *failed
   probe* by construction — that holds on every path.

The fix reorders the function so the by-construction rules run first and
`in_sysfs` decides only what is left, and adds `_STRUCTURAL_PATHS` (DT
metadata nodes: `/chosen`, `/aliases`, `/memory`, …, matched on base path),
`_norm_compat()` (separator normalisation), and `_declared_not_probed()` (the
`TIMER_OF_DECLARE` class — the ARM architected timer and the BCM2835 system
timer both land here).

### The numbers, verified on both boards and on real hardware

| Check | Before | After |
|---|---|---|
| Pi Zero health (replay) | 3 | **1** — only the true `cam1_regulator` |
| perry health (replay) | 18 | **16** = 12 disabled rails + 4 devices |
| perry health (**live on the phone**) | 6 device findings | **4** |
| touchscreen: healthy → unbind → rebind, on hardware | clean / 2-hop / clean | **unchanged** |
| `camera@10` root cause | `l23` | **`l23`** |

**perry's new 16 is not §5's old 16.** The composition differs — §5 described
9 rails + 7 unbound devices; it is now 12 rails + 4 devices. Do not treat the
matching total as evidence that nothing changed.

**`camera@10` now lights hops 2/3/4, not §11's 2/3/4/6.** The dropped hop was
`/soc@0/cci@1b0c000/i2c-bus@0`, which has an empty compatible — the CCI driver
registers it as an i2c adapter and an adapter never has a driver bound in the
probe sense. The console demo is arguably better for it: three power faults
descending to the deepest rail, with no confusing "the i2c bus is also broken"
hop in the middle. **Re-rehearse that beat before showing it.**

Live and replay disagree on rail counts (14 live vs 16 replay, `l14` at
1775 mV vs 1800). That is ordinary — live mode re-reads sysfs and those rails
are genuinely powered at the moment. The *device* findings are identical in
both modes, which is the part that proves the fix works on the live path too.

### The four device findings that remain, and why they were kept

Asked the live phone whether a driver even exists for each. **None is
registered** — `ls /sys/bus/platform/drivers` has no match for `labibb`,
`rpm-msg-ram`, `syscon`, `tcsr`, or `battery` — while all four exist as
platform devices (`1937000.syscon`, `60000.sram`, `battery`,
`200f000.spmi:pmic@3:labibb`). So the kernel instantiated the node and no
driver in this build could ever bind.

That splits them, and only one is actionable:

| Node | Compatible | Verdict |
|---|---|---|
| `/soc@0/syscon@1937000` | `qcom,tcsr-msm8917`, `syscon` | provider — reached by phandle lookup, never binds |
| `/soc@0/sram@60000` | `qcom,rpm-msg-ram` | provider — consumed by the RPM/SMD driver |
| `/battery` | `simple-battery` | data-only binding, referenced by the charger |
| `/soc@0/…/pmic@3/labibb` | `qcom,pmi8950-lab-ibb` | **genuine** — an upstream driver exists, this kernel lacks it |

`labibb` is exactly the finding a porter wants ("enable
`CONFIG_REGULATOR_QCOM_LABIBB`"), so **all four were deliberately left in**
rather than suppressed by another compatible-string blocklist.

The three providers need a signal the graph does not carry yet, and there is a
graph-native one: **a provider is a node that other nodes point at by
phandle.** `tools/dtb.py` already resolves phandles; it just does not emit an
edge for generic references such as `monitored-battery` or `qcom,tcsr`. Adding
that edge type turns "unbound providers are not faults" into a traversal rule
instead of a blocklist, which fits the project's thesis better than any
string-matching would. That is the next piece of work. **Done — §14.**

---

## 14. The provider rule — perry health is now 13

Written 2026-07-27, in a hurry before a commit deadline. **perry: 16 → 13**
(12 disabled rails + `labibb`). `/battery`, `/soc@0/sram@60000` and
`/soc@0/syscon@1937000` are gone; `labibb` correctly stays. Demo paths
re-verified in replay: `touchscreen` clean, `camera@10` → hops 2/3/4,
`ROOT CAUSE .../l23`.

### How a provider is identified

`dtc` assigns a phandle **only to nodes something actually references**, so
carrying one is the tree's own record of "I am a reference target" — 168 of
perry's 465 nodes. `tools/dtb.py` used to discard this as noise; it now emits
it as `referenced` on every node, `topology.jac` carries it on `HwNode`, and
`probe_health` treats unbound-but-referenced as a provider rather than a
failed probe.

**Resolving references the other way does not work, and was tried.** Scanning
every cell for a value matching a known phandle produces constant phantom hits
because phandles are small integers and device trees are full of small
integers — `brcm,pins`, `drive-strength` and `bus-width` all generate them.
Pi `/chosen` picked up two bogus referrers that way. Do not retry this.

### Two caveats, both real

- **`dtc -@` destroys the signal.** A tree built with symbol export gives every
  *labelled* node a phandle whether or not anything points at it. The Pi Zero
  has 143 of 162 referenced and **all 143 are exactly the `__symbols__`
  entries**; perry exports none. `build_spec` therefore forces `referenced`
  to False whenever `/__symbols__` is present and says so on stderr. Without
  that guard this would have repeated the §13 bug precisely — a signal meaning
  one thing on one board and something else on the next. **The Pi is
  unaffected either way**: its only finding is a regulator, assessed on a
  different branch.
- **A provider that genuinely died is now silent.** A gpio controller that
  failed to probe is referenced by half the tree and lands in this branch, and
  that is exactly the fault a bring-up engineer wants. Its consumers still
  report, so it surfaces as downstream symptoms rather than vanishing — but if
  this ever misleads someone, the fix is to delete the `referenced` branch in
  `probe_health` and take the noise back.

### Not done — pick this up first

**The live path was NOT re-validated on the phone for this change.** §13 was;
this was not, for time. Before trusting it on hardware:

```bash
scp src/hw.py src/diagnose.jac src/topology.jac src/importer.jac perry:~/jacos/src/
ssh perry 'cd ~/jacos && rm -f .jac/data/jacos.db* && ./scripts/jacos build fixtures/perry-live.json && ./scripts/jacos health'
```

Expect 4 device findings to drop to 1 (`labibb`). Rail counts differ live.

**Adding a `has` field to `HwNode` drifts the persisted schema** — `jac` logs
`SqliteMemory: schema drift ... best-effort load` per node and the graph is
stale. Delete `.jac/data/<entry>.db*` and rebuild. The web console's
`main.db` needs the same treatment before it is next demoed.

`fixtures/perry-live.json`, `perry-live-fault.json` and `pizero-live.json`
were patched in place with the new field rather than regenerated, so every
other value is untouched — the diff is pure additions, one line per node.
