"""Fault localisation as graph traversal.

Spawn this walker at a symptom ("the touchscreen is dead") and it walks the
device's *dependency* edges -- power rails, clocks, resets, parent buses --
assessing each hop until it finds something broken.

Two things make this idiomatic Jac rather than a Python script with extra
syntax:

  1. Assessment is dispatched by node type on arrival. A regulator is healthy
     if its rail is enabled; a device is healthy if a driver bound to it. Those
     are different questions, and the walker never branches on kind -- it just
     arrives, and the right ability fires.

  2. Descent is a single generic exit ability. Every node type inherits it, so
     the traversal policy is written once, in one place, for all hardware.
"""

import hw;

import from topology {
    HwNode, Device, Bus, Regulator, Clock, IrqController,
    Registry, ParentBus, SuppliedBy, ClockedBy, ResetBy, InterruptsTo
}


walker Diagnose {
    has symptom: str = "";
    has trail: list[str] = [];        # order of arrival, for the explainer
    has faults: list[dict] = [];      # everything that assessed unhealthy
    has expanded: list[str] = [];     # traversal dedup -- the graph has cycles
    has follow_bus: bool = True;

    # --- assessment, dispatched by hardware class --------------------------

    can check_regulator with Regulator entry {
        if not self.arrive(here) { return; }
        self.record(here, hw.probe_health(
            here.path, "regulator", here.label, "", False,
            here.reg_state, here.microvolts));
    }

    can check_device with Device entry {
        if not self.arrive(here) { return; }
        self.record(here, hw.probe_health(
            here.path, "device", here.label, here.driver, here.bound, "", 0,
            here.compatible, here.in_sysfs, here.referenced));
    }

    can check_bus with Bus entry {
        if not self.arrive(here) { return; }
        self.record(here, hw.probe_health(
            here.path, "bus", here.label, here.driver, here.bound, "", 0,
            here.compatible, here.in_sysfs, here.referenced));
    }

    can check_clock with Clock entry {
        if not self.arrive(here) { return; }
        self.record(here, hw.probe_health(here.path, "clock", here.label, "", False, "", 0));
    }

    can check_irq with IrqController entry {
        if not self.arrive(here) { return; }
        self.record(here, hw.probe_health(here.path, "irq_controller", here.label,
                                          "", False, "", 0));
    }

    # --- descent, written once for every hardware class --------------------

    can descend with HwNode exit {
        if here.path in self.expanded {
            return;
        }
        self.expanded.append(here.path);

        # Order matters for readability of the trail: power first, because
        # that is where bring-up failures actually live.
        visit [->:SuppliedBy:->];
        visit [->:ClockedBy:->];
        visit [->:ResetBy:->];
        if self.follow_bus {
            visit [->:ParentBus:->];
        }
    }

    # --- helpers -----------------------------------------------------------

    """Register arrival. Returns False if this walk already assessed the node.

    The guard lives on the walker, not on the node. Node state persists between
    runs (the graph is the database), so guarding on `n.state` would make every
    run after the first silently assess nothing.
    """
    def arrive(n: HwNode) -> bool {
        if n.path in self.trail {
            return False;
        }
        self.trail.append(n.path);
        return True;
    }

    def record(n: HwNode, h: dict) -> None {
        n.healthy = h["healthy"];
        n.state = h["state"];
        n.detail = h["detail"];
        if not n.healthy {
            self.faults.append({
                "path": n.path,
                "kind": n.kind,
                "label": n.label,
                "state": n.state,
                "detail": n.detail,
                "hop": len(self.trail),
            });
        }
    }

    """The likeliest root cause among everything that assessed unhealthy.

    Two signals, in order:

      Class. A dead power rail or clock *causes* the failure of everything
      downstream of it. A device that failed to probe is far more often a
      symptom of one of those than an independent fault. So supply faults
      outrank device faults regardless of distance.

      Depth. Within a class, the fault furthest along the dependency chain
      wins -- it explains the ones nearer the symptom, never the reverse.
    """
    def root_cause() -> dict {
        best: dict = {};
        best_score = -1;
        for f in self.faults {
            weight = 0;
            if f["kind"] == "regulator" or f["kind"] == "clock" {
                weight = 100;
            }
            score = weight + f["hop"];
            if score > best_score {
                best_score = score;
                best = f;
            }
        }
        return best;
    }
}


"""Whole-machine health report: assess every registered node exactly once.

Rides the registry edges straight off root rather than following dependencies,
so it stays linear in the size of the device tree. A real perry DTB is around a
thousand nodes -- spawning a dependency walk from each of them would be
quadratic and far too slow to put in front of judges.
"""
walker Survey {
    has assessed: int = 0;
    has unhealthy: list[dict] = [];

    can start with Root entry {
        visit [->:Registry:->];
    }

    can look with HwNode entry {
        h = hw.probe_health(here.path, here.kind, here.label,
                            here.driver, here.bound, here.reg_state,
                            here.microvolts, here.compatible, here.in_sysfs,
                            here.referenced);
        here.healthy = h["healthy"];
        here.state = h["state"];
        here.detail = h["detail"];
        self.assessed += 1;
        if not here.healthy {
            self.unhealthy.append({"path": here.path, "kind": here.kind,
                                   "detail": here.detail});
        }
        # Deliberately no `visit` here: the registry fan-out from root already
        # reaches every node, and descending would revisit the whole graph.
    }
}


"""Dependency-subtree probe: assess what one device relies on.

Same traversal as Diagnose but without the root-cause ranking -- useful for
answering "what does this thing actually need in order to work".
"""
walker Probe {
    has trail: list[str] = [];
    has unhealthy: list[dict] = [];
    has expanded: list[str] = [];

    can look with HwNode entry {
        if here.path in self.trail {
            return;
        }
        h = hw.probe_health(here.path, here.kind, here.label,
                            here.driver, here.bound, here.reg_state, here.microvolts,
                            here.compatible, here.in_sysfs, here.referenced);
        here.healthy = h["healthy"];
        here.state = h["state"];
        here.detail = h["detail"];
        self.trail.append(here.path);
        if not here.healthy {
            self.unhealthy.append({"path": here.path, "kind": here.kind,
                                   "detail": here.detail});
        }
    }

    can descend with HwNode exit {
        if here.path in self.expanded {
            return;
        }
        self.expanded.append(here.path);
        visit [->:SuppliedBy:->];
        visit [->:ClockedBy:->];
        visit [->:ResetBy:->];
        visit [->:ParentBus:->];
        visit [->:InterruptsTo:->];
    }
}
