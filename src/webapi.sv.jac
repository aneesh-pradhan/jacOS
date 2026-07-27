"""JacOS web console -- the server half.

This module deliberately contains *no* diagnostic logic. Every endpoint here is
a thin `walker:pub` wrapper that spawns the same walker the CLI spawns, so the
browser and `jac run src/jacos.jac` are two frontends over one brain. If the
traversal rules change in `diagnose.jac`, both move together and neither can
drift.

The one thing this layer adds is projection: `HwNode` carries assessment state
and runtime binding fields that the UI has no use for, so walkers report small
`obj` views instead. Those cross the wire hydrated, which is what gives the
client typed `.path` / `.state` access rather than dict-key guessing.
"""

import os;

import from topology {
    HwNode, Device, Bus, Regulator, Clock, IrqController,
    Registry, ParentBus, SuppliedBy, ClockedBy, ResetBy, InterruptsTo
}
import from importer { BuildGraph, Lookup }
import from diagnose { Diagnose, Survey }


# --- wire views -------------------------------------------------------------
# Small, flat, and JSON-friendly. `depth` and `rails` are precomputed here
# because the client should render a tree, not derive one.

"""One hardware node as the console draws it."""
obj NodeView {
    has path: str,
        name: str,
        kind: str,
        label: str,
        state: str,
        detail: str,
        healthy: bool,
        depth: int,
        bound: bool,
        driver: str,
        compatible: str,
        rails: list[str];
}

"""One hop of a dependency walk."""
obj Hop {
    has hop: int,
        path: str,
        kind: str,
        detail: str,
        faulty: bool;
}

"""One node of the dependency subgraph, positioned for drawing.

`depth` is hops from the symptom, which is what the renderer lays out on its
long axis -- so the picture is the traversal, read left to right.
"""
obj GraphNode {
    has path: str,
        name: str,
        kind: str,
        label: str,
        state: str,
        detail: str,
        healthy: bool,
        depth: int,
        is_target: bool,
        is_root_cause: bool;
}

"""One typed dependency edge, as drawn.

`kind` is the edge archetype -- `supplied_by`, `clocked_by`, `reset_by`,
`parent_bus` -- because the whole point of the picture is that these are
different relationships, not undifferentiated lines.
"""
obj GraphEdge {
    has src: str,
        dst: str,
        kind: str,
        label: str;
}

"""The result of localising a fault."""
obj DiagnosisView {
    has symptom: str,
        target: str,
        walked: int,
        trail: list[Hop],
        faults: list[Hop],
        root_cause_path: str,
        root_cause_detail: str,
        found: bool,
        nodes: list[GraphNode] = [],
        edges: list[GraphEdge] = [];
}

"""Whole-machine summary for the console header."""
obj StatusView {
    has device: str,
        nodes: int,
        edges: int,
        mode: str,
        spec: str,
        loaded: bool;
}


# --- resident-graph bookkeeping ---------------------------------------------

"""What is currently imported, recorded so nobody has to re-import to find out.

`BuildGraph` purges and reinserts 465 nodes and 732 edges against the persisted
store, which costs over a minute here -- and the dev server handles one request
at a time, so a rebuild on page load stalls every other fetch behind it until
the browser gives up and the accept backlog fills with half-open sockets. This
node is the cheap answer to "is the tree already loaded", so the console can ask
before it acts.
"""
node GraphMeta {
    has device: str = "",
        nodes: int = 0,
        edges: int = 0,
        spec: str = "";
}

"""root -> the single `GraphMeta` record.

Deliberately *not* a `Registry` edge: `BuildGraph`'s purge sweeps everything it
finds along `Registry`, and the bookkeeping has to outlive the graph it
describes long enough to be rewritten.
"""
edge MetaOf {}


# --- helpers ----------------------------------------------------------------

"""Depth of a device tree path, so the UI can indent without parsing paths."""
def _depth(path: str) -> int {
    if path == "/" {
        return 0;
    }
    return path.strip("/").count("/") + 1;
}

"""Project a graph node onto the flat view the console renders."""
def _view(n: HwNode) -> NodeView {
    rails: list[str] = [];
    for s in [n ->:SuppliedBy:->] {
        rails.append(str(s.label or s.name));
    }
    return NodeView(
        path=n.path,
        name=n.name,
        kind=n.kind,
        label=n.label,
        state=n.state,
        detail=n.detail,
        healthy=n.healthy,
        depth=_depth(n.path),
        bound=n.bound,
        driver=n.driver,
        compatible=(n.compatible[0] if n.compatible else ""),
        rails=rails
    );
}

"""Collect the dependency subgraph under a node, breadth-first.

Follows exactly the four edge types `Diagnose.descend` follows, in the same
order, so the drawing and the walk cannot show different pictures. This is
projection, not diagnosis: it reads the assessment `Diagnose` already wrote onto
each node and never decides anything about health itself.

Breadth-first rather than the walker's depth-first arrival order because
`depth` here means "hops from the symptom", which is a layout coordinate. The
trail stays the record of what the walker actually did.
"""
def _subgraph(start: HwNode, rc_path: str, limit: int) -> dict {
    order: list[HwNode] = [start];
    depth: dict[str, int] = {start.path: 0};
    seen: dict[str, bool] = {start.path: True};
    edges: list[GraphEdge] = [];

    i = 0;
    while i < len(order) {
        cur = order[i] as HwNode;
        i += 1;
        if len(order) >= limit {
            break;
        }
        d = depth[cur.path] as int;

        # Unrolled rather than looped over a list of filters: an edge filter is
        # syntax, not a value, so there is nothing to iterate over.
        dests: list[HwNode] = [];
        kinds: list[str] = [];
        for x in [cur ->:SuppliedBy:->] { dests.append(x as HwNode); kinds.append("supplied_by"); }
        for x in [cur ->:ClockedBy:->]  { dests.append(x as HwNode); kinds.append("clocked_by"); }
        for x in [cur ->:ResetBy:->]    { dests.append(x as HwNode); kinds.append("reset_by"); }
        for x in [cur ->:ParentBus:->]  { dests.append(x as HwNode); kinds.append("parent_bus"); }

        for (j, dst) in enumerate(dests) {
            edges.append(GraphEdge(
                src=cur.path,
                dst=dst.path,
                kind=kinds[j],
                label=str(dst.label or dst.name)
            ));
            if dst.path not in seen {
                seen[dst.path] = True;
                depth[dst.path] = d + 1;
                order.append(dst);
            }
        }
    }

    nodes: list[GraphNode] = [];
    for n in order {
        nodes.append(GraphNode(
            path=n.path,
            name=n.name,
            kind=n.kind,
            label=n.label,
            state=n.state,
            detail=n.detail,
            healthy=n.healthy,
            depth=depth[n.path] as int,
            is_target=(n.path == start.path),
            is_root_cause=(n.path == rc_path and rc_path != "")
        ));
    }

    # Drop edges to nodes the limit cut off, so the renderer never has a line
    # pointing at nothing.
    kept: list[GraphEdge] = [];
    for e in edges {
        if e.dst in seen {
            kept.append(e);
        }
    }
    return {"nodes": nodes, "edges": kept};
}


"""Turn a `Diagnose` fault dict into a wire `Hop`."""
def _fault_hop(f: dict) -> Hop {
    return Hop(
        hop=f["hop"] as int,
        path=f["path"] as str,
        kind=f["kind"] as str,
        detail=f["detail"] as str,
        faulty=True
    );
}


# --- endpoints --------------------------------------------------------------

"""Import a device tree snapshot into the graph.

Idempotent by way of `BuildGraph`, which purges before rebuilding -- the graph
persists in `.jac/data`, so without that a reload would stack a second tree on
top of the first.

That purge-and-reinsert is the expensive part: ~27 s from the CLI and ~75 s
here, because every node and edge is a persisted write. So this walker refuses
to redo it when the requested spec is already resident. `force` is the escape
hatch for "I changed the snapshot on disk", and it is the only path that pays
the full cost.
"""
walker:pub LoadTree {
    has spec_path: str = "fixtures/perry-live.json",
        force: bool = False,
        reports: list[StatusView] = [];

    can go with Root entry {
        known = [here ->:MetaOf:->];
        resident = len([here ->:Registry:->]);

        if (not self.force) and resident > 0 and len(known) > 0 {
            m = known[0] as GraphMeta;
            if m.spec == self.spec_path {
                report StatusView(
                    device=m.device,
                    nodes=resident,
                    edges=m.edges,
                    mode=os.environ.get("JACOS_MODE", "auto"),
                    spec=m.spec,
                    loaded=True
                );
                return;
            }
        }

        b = here spawn BuildGraph(spec_path=self.spec_path);
        device = str(b.meta.get("device", "unknown"));

        for old in known {
            del [old];
        }
        fresh = GraphMeta(
            device=device,
            nodes=b.nodes_made,
            edges=b.edges_made,
            spec=self.spec_path
        );
        here +>: MetaOf :+> fresh;

        report StatusView(
            device=device,
            nodes=b.nodes_made,
            edges=b.edges_made,
            mode=os.environ.get("JACOS_MODE", "auto"),
            spec=self.spec_path,
            loaded=True
        );
    }
}

"""Report the current graph without touching it.

This is what the console asks on mount. It must stay cheap -- the edge count
comes off the `GraphMeta` record rather than a traversal, so the answer costs
one hop no matter how large the tree is.
"""
walker:pub Status {
    has reports: list[StatusView] = [];

    can go with Root entry {
        resident = len([here ->:Registry:->]);
        known = [here ->:MetaOf:->];

        if resident > 0 and len(known) > 0 {
            m = known[0] as GraphMeta;
            report StatusView(
                device=m.device,
                nodes=resident,
                edges=m.edges,
                mode=os.environ.get("JACOS_MODE", "auto"),
                spec=m.spec,
                loaded=True
            );
            return;
        }

        # No meta record: the graph was imported by something that predates it
        # (the CLI's `BuildGraph`, or a build from before this walker existed).
        # Counting the edges here would mean ~2300 traversals and about a
        # minute, so report "unknown" rather than a confident zero.
        report StatusView(
            device="motorola-perry",
            nodes=resident,
            edges=-1,
            mode=os.environ.get("JACOS_MODE", "auto"),
            spec="",
            loaded=resident > 0
        );
    }
}

"""Every registered node, sorted by path, as the console's tree pane.

Sorted server-side on purpose: client `sorted()` rejects an inline key lambda,
and a stable order means the rendered tree is identical on every reload.
"""
walker:pub TreeNodes {
    has filter: str = "",
        reports: list[NodeView] = [];

    can go with Root entry {
        by_path: dict[str, HwNode] = {};
        for n in [here ->:Registry:->] {
            by_path[str(n.path)] = n as HwNode;
        }
        needle = self.filter.lower();
        for p in sorted(by_path.keys()) {
            if needle and needle not in p.lower() {
                continue;
            }
            report _view(by_path[p]);
        }
    }
}

"""Assess every node once and report only what is unhealthy."""
walker:pub HealthCheck {
    has reports: list[NodeView] = [];

    can go with Root entry {
        here spawn Survey();
        by_path: dict[str, HwNode] = {};
        for n in [here ->:Registry:->] {
            if not n.healthy {
                by_path[str(n.path)] = n as HwNode;
            }
        }
        for p in sorted(by_path.keys()) {
            report _view(by_path[p]);
        }
    }
}

"""Localise a fault: spawn `Diagnose` on the matching node and report the walk.

This is the endpoint that carries the demo. It does not reimplement anything --
`Lookup` finds the symptom node and `Diagnose` walks the dependency edges,
exactly as the CLI does.
"""
walker:pub DiagnoseNode {
    has query: str = "",
        max_nodes: int = 60,
        reports: list[DiagnosisView] = [];

    can go with Root entry {
        lk = here spawn Lookup(query=self.query);
        if not lk.found {
            report DiagnosisView(
                symptom=self.query, target="", walked=0, trail=[], faults=[],
                root_cause_path="", root_cause_detail="", found=False
            );
            return;
        }
        target = lk.found[0] as HwNode;
        d = (target spawn Diagnose(
            symptom="reported failure at " + target.path
        )) as Diagnose;

        faulty_paths: list[str] = [];
        faults: list[Hop] = [];
        for f in d.faults {
            faulty_paths.append(f["path"] as str);
            faults.append(_fault_hop(f));
        }

        trail: list[Hop] = [];
        idx = 0;
        for p in d.trail {
            idx += 1;
            trail.append(Hop(
                hop=idx, path=str(p), kind="", detail="",
                faulty=(p in faulty_paths)
            ));
        }

        rc = d.root_cause();
        rc_path = str(rc.get("path", ""));

        # Drawn from the graph rather than from the trail: the trail is a list,
        # and a list cannot show that the rail and the bus are two different
        # kinds of dependency hanging off the same device.
        sub = _subgraph(target, rc_path, self.max_nodes);

        report DiagnosisView(
            symptom=self.query,
            target=target.path,
            walked=len(d.trail),
            trail=trail,
            faults=faults,
            root_cause_path=rc_path,
            root_cause_detail=str(rc.get("detail", "")),
            found=True,
            nodes=sub["nodes"] as list,
            edges=sub["edges"] as list
        );
    }
}
