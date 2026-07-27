"""The JacOS web console, drawn as a manual page.

The conceit is not decoration. A man page is the format a bring-up engineer
already reads, and its sections map cleanly onto what the graph can answer:
SYNOPSIS is the command surface, DEVICE TREE is the topology, DIAGNOSTICS is
the walk. Rendering the tool's own output in its own idiom keeps the demo
legible from ten feet away.

State lives in `ManPage` and only there -- this is the stateful shell. Handler
bodies are in `ManPage.impl.jac`; the section markup below stays readable as a
result. The smaller components above it are pure: they take data and a
callback, hold nothing, and exist so that no click handler has to be written as
an inline lambda inside a statement slot (see `TreeRow`).
"""

sv import from ..webapi {
    NodeView, Hop, GraphNode, GraphEdge, DiagnosisView, StatusView,
    LoadTree, Status, TreeNodes, HealthCheck, DiagnoseNode
}


# --- leaf components ---------------------------------------------------------

"""One row of the device tree pane.

Exists as a component rather than markup inlined into the parent's `for` slot
because of a real compiler bug: a lambda written inside a slot body has its own
braces read as a *view slot*, so `onClick={lambda e: MouseEvent {
diagnosePath(n.path); }}` compiled to `__jac_view_kids.push(diagnosePath(...))`
-- clicking a row pushed a pending promise into an already-rendered element's
children instead of running the walker. A child component that closes over its
own row id is both the documented pattern and immune to it.
"""
def:pub TreeRow(row: NodeView, active: bool, onPick: Callable[[str], None]) -> JsxElement {
    def handle(e: MouseEvent) {
        onPick(row.path);
    }

    # Built by hand rather than with `", ".join(row.rails)`. That call lowers
    # to `_jac.poly.call(", ", "join", ...)` -- a method dispatch on a string
    # primitive -- and it is the one expression on this page that runs only
    # once a row actually has rails, which is exactly when the console went
    # blank. See the note in docs/HANDOFF.md §8.
    rails = "";
    for (k, r) in enumerate(row.rails) {
        rails = rails + (", " if k > 0 else "") + r;
    }

    return <div
        className={"tr"
                   + (" tr-bad" if not row.healthy else "")
                   + (" tr-on" if active else "")}
        onClick={handle}
        title={row.path + ("  ·  " + row.detail if row.detail else "")}
    >
        <span className={"tr-k tr-k-" + (row.kind if row.kind else "device")}>
            {row.kind[0:3] if row.kind else "···"}
        </span>
        <span className="tr-p">{row.path}</span>
        {if rails {
            <span className="tr-r">{"← " + rails}</span>
        }}
    </div>;
}


"""One hardware block as a box in the dependency drawing.

Positioned by the parent -- `x`/`y` are layout, which is a property of the
picture and not of the hardware, so they are computed in the browser and never
cross the wire.
"""
def:pub GraphBox(
    blk: GraphNode, x: int, y: int, w: int, h: int,
    onPick: Callable[[str], None]
) -> JsxElement {
    def handle(e: MouseEvent) {
        onPick(blk.path);
    }

    cls = "gb gb-" + (blk.kind if blk.kind else "device");
    if not blk.healthy {
        cls = cls + " gb-bad";
    }
    if blk.is_root_cause {
        cls = cls + " gb-rc";
    }
    if blk.is_target {
        cls = cls + " gb-target";
    }

    caption = blk.label if blk.label else blk.name;
    if not caption {
        caption = blk.path;
    }

    return <g className={cls} onClick={handle}>
        <title>{blk.path + ("  ·  " + blk.detail if blk.detail else "")}</title>
        {#* Halo sits behind the box and only exists on the root cause, so the
            one block the whole walk was looking for is the one thing on the
            canvas that moves. *#}
        {if blk.is_root_cause {
            <rect className="gb-halo" x={x - 5} y={y - 5} width={w + 10} height={h + 10} rx={4}/>
        }}
        <rect className="gb-r" x={x} y={y} width={w} height={h} rx={2}/>
        <rect className="gb-tab" x={x} y={y} width={3} height={h}/>
        <text className="gb-t" x={x + 10} y={y + 14}>
            {caption[0:26] if len(caption) > 26 else caption}
        </text>
        <text className="gb-s" x={x + 10} y={y + 26}>
            {(blk.kind if blk.kind else "device")
             + ("  ·  " + blk.state if blk.state and blk.state != "unchecked" else "")}
        </text>
        {if blk.is_root_cause {
            <circle className="gb-pulse" cx={x + w - 11} cy={y + 11} r={4}/>
        }}
    </g>;
}


"""The dependency subgraph, drawn as a graph.

This is the section that earns the browser its place: the CLI can print the
trail as a list, but only a picture shows that a device's rail, its clock and
its parent bus are three *different* kinds of dependency fanning out of one
node, and that they reconverge further down. Edge colour is edge archetype.

Layout is a plain layered assignment -- column by hop distance from the
symptom, row by arrival order within that column. No force simulation: the
graph is a shallow DAG and a deterministic layout means the picture is
identical every time it is shown, which matters when it is being demoed.
"""
def:pub DepGraph(
    nodes: list[GraphNode], edges: list[GraphEdge],
    onPick: Callable[[str], None]
) -> JsxElement {
    if len(nodes) == 0 {
        return <p className="man-dim">no dependency graph yet — run a diagnose.</p>;
    }

    COLW = 252;
    ROWH = 54;
    BOXW = 210;
    BOXH = 36;
    PADX = 14;
    PADY = 40;
    BEND = (COLW - BOXW) // 2;

    gx: dict[str, int] = {};
    gy: dict[str, int] = {};
    used: dict[int, int] = {};
    cols: list[int] = [];
    maxrow = 0;
    maxdepth = 0;

    for n in nodes {
        r = used.get(n.depth, 0) as int;
        used[n.depth] = r + 1;
        gx[n.path] = PADX + n.depth * COLW;
        gy[n.path] = PADY + r * ROWH;
        if r > maxrow { maxrow = r; }
        if n.depth > maxdepth { maxdepth = n.depth; }
        if n.depth not in cols { cols = cols + [n.depth]; }
    }

    W = PADX * 2 + maxdepth * COLW + BOXW;
    H = PADY + (maxrow + 1) * ROWH;

    # An edge is "hot" when the thing it points at assessed unhealthy, which
    # makes the chain from the symptom down to the root cause the only moving
    # thing in the picture. Everything else stays still: on a projector,
    # motion is the strongest pointer there is, and spending it on decoration
    # wastes it.
    sick: dict[str, bool] = {};
    for n in nodes {
        if not n.healthy {
            sick[n.path] = True;
        }
    }

    return <div className="dg-wrap">
        <svg className="dg" width={W} height={H} viewBox={"0 0 " + str(W) + " " + str(H)}>
            <defs>
                <marker id="dg-tip" markerWidth={8} markerHeight={8}
                        refX={7} refY={3} orient="auto">
                    <path className="dg-tip" d="M0,0 L7,3 L0,6 Z"/>
                </marker>
            </defs>

            {#* Column bands, drawn first: they give the eye a rail to follow
                left-to-right and make "how many hops down" readable without
                counting boxes. *#}
            {for (i, d) in enumerate(cols) {
                <rect
                    key={"b" + str(i)}
                    className={"dg-band" + (" dg-band-alt" if i % 2 == 1 else "")}
                    x={PADX + d * COLW - 9}
                    y={26}
                    width={BOXW + 18}
                    height={H - 30}
                    rx={3}
                />
            }}

            {for (i, d) in enumerate(cols) {
                <text key={"c" + str(i)} className="dg-col" x={PADX + d * COLW} y={20}>
                    {"symptom" if d == 0 else "depth " + str(d)}
                </text>
            }}

            {#* Edges first so the boxes paint over their endpoints. The
                control offset is half the horizontal gap, not a constant:
                columns are COLW apart but the boxes are BOXW wide, so a fixed
                offset overshoots the gap and the curve doubles back on
                itself. *#}
            {for (i, e) in enumerate(edges) {
                <path
                    key={"e" + str(i)}
                    className={"dg-e dg-e-" + e.kind
                               + (" dg-e-hot" if e.dst in sick else "")}
                    markerEnd="url(#dg-tip)"
                    d={"M " + str(gx.get(e.src, 0) + BOXW) + "," + str(gy.get(e.src, 0) + BOXH // 2)
                       + " C " + str(gx.get(e.src, 0) + BOXW + BEND) + "," + str(gy.get(e.src, 0) + BOXH // 2)
                       + " " + str(gx.get(e.dst, 0) - BEND) + "," + str(gy.get(e.dst, 0) + BOXH // 2)
                       + " " + str(gx.get(e.dst, 0)) + "," + str(gy.get(e.dst, 0) + BOXH // 2)}
                />
            }}

            {for (i, n) in enumerate(nodes) {
                <GraphBox
                    key={"n" + str(i)}
                    blk={n}
                    x={gx.get(n.path, 0) as int}
                    y={gy.get(n.path, 0) as int}
                    w={BOXW}
                    h={BOXH}
                    onPick={onPick}
                />
            }}
        </svg>

        <div className="dg-key">
            <span className="dg-k dg-k-supplied_by">supplied_by</span>
            <span className="dg-k dg-k-clocked_by">clocked_by</span>
            <span className="dg-k dg-k-reset_by">reset_by</span>
            <span className="dg-k dg-k-parent_bus">parent_bus</span>
        </div>
    </div>;
}


# --- the page ----------------------------------------------------------------

def:pub ManPage -> JsxElement {
    has status: StatusView | None = None,
        nodes: list[NodeView] = [],
        faults: list[NodeView] = [],
        diag: DiagnosisView | None = None,
        query: str = "touchscreen",
        booting: bool = True,
        busy: str = "";

    # Ask what is resident before importing anything. `LoadTree` purges and
    # reinserts 465 nodes and 732 edges against the persisted store, which
    # takes over a minute, and the dev server answers one request at a time --
    # so building on mount stalled every later fetch behind it and the console
    # never got past its loading state. Import only when the graph is empty.
    async can with entry {
        await boot();
    }

    # Re-filtering is a server round trip, not a client-side array filter, so
    # the tree pane and `jacos graph <pattern>` agree by construction. Guarded
    # on `booting` because this effect also fires on mount, where `boot()`
    # already owns the first fetch.
    async can with [query] entry {
        if not booting {
            await refreshTree();
        }
    }

    async def boot -> None;
    async def rebuild -> None;
    async def refreshTree -> None;
    async def runHealth -> None;
    async def diagnosePath(p: str) -> None;

    def onFilter(e: ChangeEvent) {
        query = e.target.value;
    }

    def onRunQuery(e: MouseEvent) {
        pick(query);
    }

    # Sync wrapper so children can take a plain `Callable[[str], None]`, and
    # the single place that refuses to queue a second walk on top of a running
    # one -- each walk is a real traversal on a single-threaded server.
    def pick(p: str) {
        if busy == "" {
            diagnosePath(p);
        }
    }

    gnodes: list[GraphNode] = diag.nodes if diag is not None else [];
    gedges: list[GraphEdge] = diag.edges if diag is not None else [];

    return
        <div className="man">
            <div className="man-sheet">

                <header className="man-hdr">
                    <span>JACOS(1)</span>
                    <span>JacOS Reference Manual</span>
                    <span>JACOS(1)</span>
                </header>

                <section className="man-sec">
                    <h2>NAME</h2>
                    <div className="man-body">
                        <b>jacos</b>{" — the Linux device tree as a first-class Jac graph"}
                    </div>
                </section>

                <section className="man-sec">
                    <h2>SYNOPSIS</h2>
                    <div className="man-body man-syn">
                        <div className="man-cmd">
                            <b>jacos</b> <i>build</i> {"[spec]"}
                            <button
                                className="man-run"
                                onClick={rebuild}
                                disabled={busy != ""}
                            >run</button>
                            <span className="man-note">{"re-imports the snapshot · ~75s"}</span>
                        </div>
                        <div className="man-cmd">
                            <b>jacos</b> <i>health</i>
                            <button
                                className="man-run"
                                onClick={runHealth}
                                disabled={busy != ""}
                            >run</button>
                        </div>
                        <div className="man-cmd">
                            <b>jacos</b> <i>diagnose</i>{" "}
                            <input
                                className="man-in"
                                value={query}
                                onChange={onFilter}
                                spellCheck={False}
                                aria-label="filter device tree"
                            />
                            <button
                                className="man-run"
                                onClick={onRunQuery}
                                disabled={busy != ""}
                            >run</button>
                        </div>
                    </div>
                </section>

                <section className="man-sec">
                    <h2>DESCRIPTION</h2>
                    <div className="man-body">
                        {if status is not None {
                            <p>
                                {"The running device tree of "}
                                <b>{status.device}</b>
                                {" has been lifted into a Jac graph. Every hardware block is "}
                                {"a node; every "}
                                <i>vdd-supply</i>{", "}<i>clocks</i>{" and "}
                                <i>interrupt-parent</i>
                                {" phandle is a typed edge. Fault-finding is therefore a "}
                                {"traversal, not a grep."}
                            </p>
                            <div className="man-stats">
                                <div className="stat">
                                    <span className="stat-n">{str(status.nodes)}</span>
                                    <span className="stat-l">nodes</span>
                                </div>
                                <div className="stat">
                                    <span className="stat-n">
                                        {str(status.edges) if status.edges >= 0 else "—"}
                                    </span>
                                    <span className="stat-l">typed edges</span>
                                </div>
                                <div className="stat">
                                    <span className="stat-n">{status.mode}</span>
                                    <span className="stat-l">mode</span>
                                </div>
                                <div className="stat">
                                    <span className="stat-n">{str(len(faults))}</span>
                                    <span className="stat-l">findings</span>
                                </div>
                            </div>
                            <p className="man-dim">
                                {"spec: " + (status.spec if status.spec else "(already resident)")}
                            </p>
                        } else {
                            <p className="man-dim">importing device tree…</p>
                        }}
                    </div>
                </section>

                <section className="man-sec">
                    <h2>DEVICE TREE</h2>
                    <div className="man-body">
                        <p className="man-dim">
                            {"Filtered by ‘" + query + "’. "}
                            {str(len(nodes)) + " node(s). Select one to walk its dependencies."}
                        </p>
                        <div className="man-tree">
                            {if len(nodes) == 0 {
                                <p className="man-dim">no node matches that pattern.</p>
                                skip;
                            }}
                            {for (i, n) in enumerate(nodes) {
                                <TreeRow
                                    key={str(i)}
                                    row={n}
                                    active={diag is not None and diag.target == n.path}
                                    onPick={pick}
                                />
                            }}
                        </div>
                    </div>
                </section>

                <section className="man-sec">
                    <h2>DEPENDENCY GRAPH</h2>
                    <div className="man-body">
                        <p className="man-dim">
                            {"What the walker traversed, drawn as the graph it is. "}
                            {"Colour is edge archetype; click any block to re-run from there."}
                        </p>
                        <DepGraph nodes={gnodes} edges={gedges} onPick={pick}/>
                    </div>
                </section>

                <section className="man-sec">
                    <h2>DIAGNOSTICS</h2>
                    <div className="man-body">
                        {if busy != "" {
                            <p className="man-busy">{"walking… (" + busy + ")"}</p>
                        }}
                        {if diag is not None and diag.found {
                            <p>
                                {"symptom node: "}<b>{diag.target}</b>
                                {"  ·  walked " + str(diag.walked) + " nodes"}
                            </p>
                            <div className="man-walk">
                                {for (i, h) in enumerate(diag.trail) {
                                    <div key={str(i)} className={"hop" + (" hop-bad" if h.faulty else "")}>
                                        <span className="hop-n">{("!" if h.faulty else " ") + " hop " + str(h.hop)}</span>
                                        <span>{h.path}</span>
                                    </div>
                                }}
                            </div>
                            if diag.root_cause_path {
                                <div className="man-rc">
                                    <div className="man-rc-h">ROOT CAUSE</div>
                                    <div className="man-rc-p">{diag.root_cause_path}</div>
                                    <div className="man-rc-d">{diag.root_cause_detail}</div>
                                </div>
                            } else {
                                <p className="man-ok">
                                    no faults found along the dependency chain.
                                </p>
                            }
                        }}
                        {if diag is not None and not diag.found {
                            <p className="man-dim">{"no node matching ‘" + diag.symptom + "’."}</p>
                        }}
                        {if len(faults) > 0 {
                            <p className="man-sub">{"whole-machine survey — " + str(len(faults)) + " finding(s)"}</p>
                            <div className="man-walk">
                                {for (i, f) in enumerate(faults) {
                                    <div key={str(i)} className="hop hop-bad">
                                        <span className="hop-n">{"!"}</span>
                                        <span>{f.path}</span>
                                        <span className="tr-r">{f.detail}</span>
                                    </div>
                                }}
                            </div>
                        }}
                    </div>
                </section>

                <section className="man-sec">
                    <h2>SEE ALSO</h2>
                    <div className="man-body man-dim">
                        <i>topology.jac</i>{"(the schema), "}
                        <i>diagnose.jac</i>{"(the walkers), "}
                        <i>webapi.sv.jac</i>{"(this console’s server half)."}
                        <br/>
                        {"The CLI and this page spawn the same walkers."}
                    </div>
                </section>

                <footer className="man-ftr">
                    <span>motorola-perry</span>
                    <span>JacHacks SF 2026</span>
                    <span>JACOS(1)</span>
                </footer>

            </div>
        </div>;
}
