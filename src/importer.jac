"""Materialise a JacOS hardware graph from a device tree spec.

`tools/dtb.py` produces the spec (nodes + edges as JSON) from a phone capture.
This walker turns that spec into live Jac archetypes hanging off `root`.
"""

import json;

import from topology {
    HwNode, Device, Bus, Regulator, Clock, IrqController,
    Registry, ParentBus, SuppliedBy, ClockedBy, ResetBy, DmaBy, InterruptsTo
}


"""Construct the right node archetype for a spec record."""
def make_node(rec: dict) -> HwNode {
    k = rec.get("kind", "device");
    p = rec.get("path", "");

    n: HwNode = Device(path=p);
    if k == "regulator" {
        n = Regulator(path=p);
    } elif k == "clock" {
        n = Clock(path=p);
    } elif k == "bus" {
        n = Bus(path=p);
    } elif k == "irq_controller" {
        n = IrqController(path=p);
    }

    n.name = rec.get("name", "");
    n.kind = k;
    n.compatible = rec.get("compatible", []);
    n.status = rec.get("status", "okay");
    n.label = rec.get("label", "");
    n.driver = rec.get("driver", "");
    n.bound = rec.get("bound", False);
    n.reg_state = rec.get("reg_state", "");
    n.microvolts = rec.get("microvolts", 0);
    n.in_sysfs = rec.get("in_sysfs", -1);
    n.referenced = rec.get("referenced", False);
    return n;
}


walker BuildGraph {
    has spec_path: str = "fixtures/perry.json";
    has index: dict = {};
    has meta: dict = {};
    has nodes_made: int = 0;
    has edges_made: int = 0;

    # Jac persists everything reachable from `root` between runs -- the graph
    # is the database, there is no ORM and no schema migration. Great for a
    # long-lived device registry, fatal for an importer that must be able to
    # run twice. So purge first unless the caller explicitly wants to append.
    has reset: bool = True;

    can build with Root entry {
        if self.reset {
            # Destroying the registry nodes cascades to their edges. Note that
            # `del <variable>` only unbinds the name -- node destruction needs
            # the list-literal form, hence the loop.
            for stale in [->:Registry:->] {
                del [stale];
            }
        }

        fh = open(self.spec_path, "r");
        spec = json.load(fh);
        fh.close();

        self.meta = spec.get("meta", {});

        for rec in spec.get("nodes", []) {
            n = make_node(rec);
            self.index[n.path] = n;
            here +>: Registry :+> n;
            self.nodes_made += 1;
        }

        for e in spec.get("edges", []) {
            s = self.index.get(e.get("src", ""));
            d = self.index.get(e.get("dst", ""));
            if (s is None) or (d is None) {
                continue;
            }
            k = e.get("kind", "");
            lbl = e.get("label", "");

            if k == "parent_bus" {
                s +>: ParentBus :+> d;
            } elif k == "supplied_by" {
                s +>: SuppliedBy : rail=lbl :+> d;
            } elif k == "clocked_by" {
                s +>: ClockedBy : clk=lbl :+> d;
            } elif k == "reset_by" {
                s +>: ResetBy : line=lbl :+> d;
            } elif k == "dma_by" {
                s +>: DmaBy : channel=lbl :+> d;
            } elif k == "interrupts_to" {
                s +>: InterruptsTo :+> d;
            } else {
                continue;
            }
            self.edges_made += 1;
        }
    }
}


"""Find a node by exact path, or by fuzzy suffix match on its name.

Lets the CLI take `touchscreen` instead of the full
`/soc/i2c@78b6000/touchscreen@20`.
"""
walker Lookup {
    has query: str = "";
    has found: list = [];

    can search with Root entry {
        for n in [->:Registry:->] {
            if n.path == self.query {
                self.found = [n];
                return;
            }
        }
        for n in [->:Registry:->] {
            if (self.query in n.path) or (self.query in n.name) {
                self.found.append(n);
            }
        }
    }
}
