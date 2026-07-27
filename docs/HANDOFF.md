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

- **`health` reports 18 findings here, not the 16 in §5** — and *which number
  you get depends on the machine*, which is the part that matters. The
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

### Stale second build tree

`src/.jac/` exists alongside the real `.jac/` — an older tree from when the
entry resolved differently. It holds a 2:59 PM `compiled/components/ManPage.css`
and its own `data/main.db`. Nothing reads it now. It is worth deleting once
someone confirms the DB in it is not the one being demoed.
