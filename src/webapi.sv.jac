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

"""The result of localising a fault."""
obj DiagnosisView {
    has symptom: str,
        target: str,
        walked: int,
        trail: list[Hop],
        faults: list[Hop],
        root_cause_path: str,
        root_cause_detail: str,
        found: bool;
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
"""
walker:pub LoadTree {
    has spec_path: str = "fixtures/perry-live.json",
        reports: list[StatusView] = [];

    can go with Root entry {
        b = here spawn BuildGraph(spec_path=self.spec_path);
        report StatusView(
            device=str(b.meta.get("device", "unknown")),
            nodes=b.nodes_made,
            edges=b.edges_made,
            mode=os.environ.get("JACOS_MODE", "auto"),
            spec=self.spec_path,
            loaded=True
        );
    }
}

"""Report the current graph without touching it."""
walker:pub Status {
    has reports: list[StatusView] = [];

    can go with Root entry {
        nodes = [here ->:Registry:->];
        report StatusView(
            device="motorola-perry",
            nodes=len(nodes),
            edges=0,
            mode=os.environ.get("JACOS_MODE", "auto"),
            spec="",
            loaded=len(nodes) > 0
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
        report DiagnosisView(
            symptom=self.query,
            target=target.path,
            walked=len(d.trail),
            trail=trail,
            faults=faults,
            root_cause_path=str(rc.get("path", "")),
            root_cause_detail=str(rc.get("detail", "")),
            found=True
        );
    }
}
