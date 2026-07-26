"""JacOS command line.

    jac run src/jacos.jac -- build [spec.json]      import a device tree snapshot
    jac run src/jacos.jac -- graph                  print the hardware topology
    jac run src/jacos.jac -- health                 assess everything
    jac run src/jacos.jac -- diagnose <query>       localise a fault
    jac run src/jacos.jac -- diagnose <query> -x    ...and explain it with byLLM

The graph persists between invocations, so `build` runs once and every later
command queries the live registry. That is not a cache -- in Jac the graph is
the database.
"""

import sys;
import hw;

import from topology { HwNode, Registry, SuppliedBy }
import from importer { BuildGraph, Lookup }
import from diagnose { Diagnose, Probe, Survey }

# `explain` is imported lazily inside cmd_diagnose. It pulls in byLLM, which
# pulls in litellm -- a heavy dependency that is genuinely painful to install
# on a 1 GB phone. Everything except `diagnose -x` must keep working without it.


def banner() -> None {
    print("");
    print("  JacOS -- your hardware, as a graph");
    print("  mode: " + hw.mode());
    print("");
}


def show_faults(faults: list[dict]) -> None {
    if not faults {
        print("  no faults found along the dependency chain");
        return;
    }
    for f in faults {
        print("  ! hop " + str(f["hop"]) + "  " + f["path"]);
        print("           " + f["detail"]);
    }
}


def cmd_build(args: list[str]) -> None {
    spec = "fixtures/perry.json";
    if len(args) > 0 {
        spec = args[0];
    }
    b = root spawn BuildGraph(spec_path=spec);
    print("  built " + str(b.nodes_made) + " nodes, "
          + str(b.edges_made) + " edges from " + spec);
    dev = b.meta.get("device", "unknown");
    print("  device: " + str(dev));
    if not b.meta.get("has_runtime_overlay", False) {
        print("  note: no runtime overlay in this snapshot -- driver binding and");
        print("        regulator state will be unknown. Re-capture with");
        print("        scripts/10-capture-topology.sh on the device.");
    }
}


def cmd_graph() -> None {
    nodes = [root ->:Registry:->];
    if not nodes {
        print("  empty registry -- run `build` first");
        return;
    }
    print("  " + str(len(nodes)) + " nodes");
    for n in nodes {
        supplies = [n ->:SuppliedBy:->];
        line = "  " + n.kind[0:3] + "  " + n.path;
        if supplies {
            rails = [];
            for s in supplies {
                rails.append(s.label or s.name);
            }
            line += "   <- " + ", ".join(rails);
        }
        print(line);
    }
}


def cmd_health() -> None {
    nodes = [root ->:Registry:->];
    if not nodes {
        print("  empty registry -- run `build` first");
        return;
    }
    s = root spawn Survey();
    print("  assessed " + str(s.assessed) + " nodes");
    if not s.unhealthy {
        print("  all healthy");
        return;
    }
    for u in s.unhealthy {
        print("  ! " + u["path"] + "  ::  " + u["detail"]);
    }
}


def cmd_diagnose(args: list[str]) -> None {
    if not args {
        print("  usage: diagnose <path-or-name> [-x]");
        return;
    }
    query = args[0];
    want_explain = "-x" in args or "--explain" in args;

    lk = root spawn Lookup(query=query);
    if not lk.found {
        print("  no node matching '" + query + "' -- run `build` first?");
        return;
    }
    target = lk.found[0];
    if len(lk.found) > 1 {
        print("  " + str(len(lk.found)) + " matches, using: " + target.path);
    }

    print("  symptom node: " + target.path);
    d = target spawn Diagnose(symptom="reported failure at " + target.path);

    print("");
    print("  walked " + str(len(d.trail)) + " nodes:");
    for p in d.trail {
        print("    -> " + p);
    }

    print("");
    show_faults(d.faults);

    rc = d.root_cause();
    print("");
    if not rc {
        print("  ROOT CAUSE: none identified");
        return;
    }
    print("  ROOT CAUSE: " + rc["path"]);
    print("              " + rc["detail"]);

    if not want_explain {
        return;
    }

    print("");
    try {
        import from explain { explain_fault, llm_backed }
    } except Exception as e {
        print("  byLLM not available -- `pip install byllm` to enable -x");
        print("  (" + str(e) + ")");
        return;
    }

    if llm_backed() {
        print("  asking the model...");
    } else {
        print("  (no OPENAI_API_KEY -- using offline mock)");
    }
    dx = explain_fault(
        symptom="failure reported at " + target.path,
        trail=d.trail,
        faults=d.faults,
        root_cause=rc,
        dmesg=hw.dmesg_tail(target.name, 30)
    );
    print("");
    print("  DIAGNOSIS  (confidence " + str(dx.confidence) + ")");
    print("  cause:     " + dx.root_cause);
    print("  reasoning: " + dx.reasoning);
    print("  next step: " + dx.next_step);
}


with entry {
    argv = sys.argv;
    args = [];
    seen_sep = False;
    for a in argv {
        if seen_sep {
            args.append(a);
        }
        if a == "--" {
            seen_sep = True;
        }
    }
    # Fall back to everything after the script name when `--` was not used.
    if not args and len(argv) > 1 {
        args = argv[1:];
    }

    cmd = "help";
    if args {
        cmd = args[0];
        args = args[1:];
    }

    banner();
    if cmd == "build" {
        cmd_build(args);
    } elif cmd == "graph" {
        cmd_graph();
    } elif cmd == "health" {
        cmd_health();
    } elif cmd == "diagnose" {
        cmd_diagnose(args);
    } else {
        print("  commands: build [spec.json] | graph | health | diagnose <query> [-x]");
    }
    print("");
}
