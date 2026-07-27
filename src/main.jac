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
    # App-wide stylesheet, imported explicitly rather than paired as a
    # `ManPage.style.css` annex next to the component. The annex route is
    # documented and the compiler does emit `import "./ManPage.css"` for it,
    # but it never copies the file into the build tree Vite actually reads
    # (`.jac/client/compiled/components/`), so the build dies on
    # `Could not resolve "./ManPage.css"`. Naming the source `ManPage.css`
    # instead -- which an earlier session tried -- suppresses the import
    # entirely and ships an unstyled page that looks like a clean build.
    # `@jac-client/assets` is aliased to the compiled assets directory, so
    # this path resolves without depending on annex pairing at all.
    import "@jac-client/assets/console.css";

    import from .components.ManPage { ManPage }

    def:pub app -> JsxElement {
        return <ManPage/>;
    }
}
