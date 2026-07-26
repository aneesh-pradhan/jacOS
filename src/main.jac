"""JacOS -- web console entry point.

The console is a second frontend over the graph that `src/jacos.jac` already
drives from the terminal. Both spawn the same walkers; neither owns the
diagnostic logic. See `src/webapi.sv.jac`.

The server import below registers the endpoints at boot. Client `sv import`s
self-register as well, but the entry-module import is the explicit form and
costs nothing.
"""

import from webapi {
    NodeView, Hop, DiagnosisView, StatusView,
    LoadTree, Status, TreeNodes, HealthCheck, DiagnoseNode
}

cl {
    import from .components.ManPage { ManPage }

    def:pub app -> JsxElement {
        return <ManPage/>;
    }
}
