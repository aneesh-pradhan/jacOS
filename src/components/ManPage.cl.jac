"""The JacOS web console, drawn as a manual page.

The conceit is not decoration. A man page is the format a bring-up engineer
already reads, and its sections map cleanly onto what the graph can answer:
SYNOPSIS is the command surface, DEVICE TREE is the topology, DIAGNOSTICS is
the walk. Rendering the tool's own output in its own idiom keeps the demo
legible from ten feet away.

State lives here and only here -- this is the stateful shell. Handler bodies
are in `ManPage.impl.jac`; the section markup below stays readable as a result.
"""

sv import from ..webapi {
    NodeView, Hop, DiagnosisView, StatusView,
    LoadTree, Status, TreeNodes, HealthCheck, DiagnoseNode
}

def:pub ManPage -> JsxElement {
    has status: StatusView | None = None,
        nodes: list[NodeView] = [],
        faults: list[NodeView] = [],
        diag: DiagnosisView | None = None,
        filter: str = "touchscreen",
        booting: bool = True,
        busy: str = "";

    # Import the tree once, then draw it. `LoadTree` is idempotent, so a
    # refresh re-imports rather than stacking a second tree on the graph.
    async can with entry {
        await boot();
    }

    # Re-filtering is a server round trip, not a client-side array filter, so
    # the tree pane and `jacos graph <pattern>` agree by construction. Guarded
    # on `booting` because this effect also fires on mount, where `boot()`
    # already owns the first fetch.
    async can with [filter] entry {
        if not booting {
            await refreshTree();
        }
    }

    async def boot -> None;
    async def refreshTree -> None;
    async def runHealth -> None;
    async def diagnosePath(p: str) -> None;

    def onFilter(e: ChangeEvent) -> None {
        filter = e.target.value;
    }

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
                                onClick={boot}
                                disabled={busy != ""}
                            >run</button>
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
                                value={filter}
                                onChange={onFilter}
                                spellCheck={False}
                                aria-label="filter device tree"
                            />
                            <button
                                className="man-run"
                                onClick={lambda e: MouseEvent { diagnosePath(filter); }}
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
                                {" has been lifted into a Jac graph: "}
                                <b>{str(status.nodes)}</b>{" nodes, "}
                                <b>{str(status.edges)}</b>
                                {" typed edges. Every hardware block is a node; every "}
                                <i>vdd-supply</i>{", "}<i>clocks</i>{" and "}
                                <i>interrupt-parent</i>
                                {" phandle is an edge. Fault-finding is therefore a "}
                                {"traversal, not a grep."}
                            </p>
                            <p className="man-dim">
                                {"mode: " + status.mode + "  ·  spec: "}
                                {status.spec if status.spec else "(already resident)"}
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
                            {"Filtered by ‘" + filter + "’. "}
                            {str(len(nodes)) + " node(s). Select one to walk its dependencies."}
                        </p>
                        <div className="man-tree">
                            {if len(nodes) == 0 {
                                <p className="man-dim">no node matches that pattern.</p>
                                skip;
                            }}
                            {for (i, n) in enumerate(nodes) {
                                <div
                                    key={str(i)}
                                    className={"tr" + (" tr-bad" if not n.healthy else "")
                                               + (" tr-on" if diag is not None and diag.target == n.path else "")}
                                    onClick={lambda e: MouseEvent { diagnosePath(n.path); }}
                                >
                                    <span className="tr-k">{n.kind[0:3]}</span>
                                    <span className="tr-p" style={{"paddingLeft": str(n.depth * 8) + "px"}}>
                                        {n.path}
                                    </span>
                                    {if len(n.rails) > 0 {
                                        <span className="tr-r">{"← " + ", ".join(n.rails)}</span>
                                    }}
                                </div>
                            }}
                        </div>
                    </div>
                </section>

                <section className="man-sec">
                    <h2>DIAGNOSTICS</h2>
                    <div className="man-body">
                        {if busy != "" {
                            <p className="man-dim">{"walking… (" + busy + ")"}</p>
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
