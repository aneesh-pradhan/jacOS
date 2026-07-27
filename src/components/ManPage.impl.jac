"""Handler bodies for the JacOS console.

Every one of these is a walker spawn and nothing else. There is no fetch, no
URL, no JSON shape to keep in sync: `root spawn DiagnoseNode(query=p)` in the
browser runs the same walker the CLI runs, and the reports come back as
hydrated `DiagnosisView` objects.
"""

impl ManPage.boot -> None {
    busy = "status";

    # Ask before importing. A rebuild is a ~75 s single-threaded stall, so
    # doing it unconditionally on mount meant every other fetch queued behind
    # it and the page never left its loading state.
    st = root spawn Status();
    if st.reports and len(st.reports) > 0 and st.reports[0].loaded {
        status = st.reports[0];
    } else {
        busy = "build";
        loaded = root spawn LoadTree(spec_path="fixtures/perry-live.json");
        if loaded.reports and len(loaded.reports) > 0 {
            status = loaded.reports[0];
        }
    }

    tree = root spawn TreeNodes(filter=query);
    nodes = tree.reports;
    booting = False;
    busy = "";
}

impl ManPage.rebuild -> None {
    busy = "build";
    loaded = root spawn LoadTree(spec_path="fixtures/perry-live.json", force=True);
    if loaded.reports and len(loaded.reports) > 0 {
        status = loaded.reports[0];
    }
    tree = root spawn TreeNodes(filter=query);
    nodes = tree.reports;
    # A rebuild replaces every node object, so anything held from the previous
    # graph now points at destroyed nodes. Drop it rather than render it.
    faults = [];
    diag = None;
    busy = "";
}

impl ManPage.refreshTree -> None {
    busy = "graph";
    tree = root spawn TreeNodes(filter=query);
    nodes = tree.reports;
    busy = "";
}

impl ManPage.runHealth -> None {
    busy = "health";
    survey = root spawn HealthCheck();
    faults = survey.reports;
    # The survey writes assessment state onto every node, so the tree pane is
    # stale the moment it finishes. Re-read it rather than let the two panes
    # disagree about what is healthy.
    tree = root spawn TreeNodes(filter=query);
    nodes = tree.reports;
    busy = "";
}

impl ManPage.diagnosePath(p: str) -> None {
    busy = "diagnose";
    walk = root spawn DiagnoseNode(query=p);
    if walk.reports and len(walk.reports) > 0 {
        diag = walk.reports[0];
    }
    busy = "";
}
