"""JacOS topology -- the Linux device tree as first-class Jac archetypes.

Every hardware block on the phone becomes a graph node; every dependency
between blocks becomes a typed edge. Once that exists, "why is my touchscreen
dead" stops being a grep problem and becomes a traversal.

The node hierarchy matters: walkers dispatch abilities on arrival *by node
type*, so a regulator and an i2c controller get genuinely different health
semantics without a single branch in the walker body.
"""

node HwNode {
    has path: str;                          # canonical device tree path
    has name: str = "";
    has kind: str = "device";
    has compatible: list[str] = [];
    has status: str = "okay";               # device tree status property
    has label: str = "";                    # regulator-name / label, if any

    # runtime binding state, filled by the importer or read live by hw.py
    has driver: str = "";
    has bound: bool = False;
    has reg_state: str = "";
    has microvolts: int = 0;

    # assessment, written by walkers on arrival
    has healthy: bool = True;
    has state: str = "unchecked";
    has detail: str = "";
}

"""A leaf peripheral: touchscreen, modem, mmc controller."""
node Device(HwNode) {}

"""A bus or controller that other nodes hang off: i2c, spmi, /soc itself."""
node Bus(HwNode) {}

"""A power rail from the PMIC. The usual culprit in bring-up failures."""
node Regulator(HwNode) {}

"""A clock source or clock controller."""
node Clock(HwNode) {}

"""An interrupt controller."""
node IrqController(HwNode) {}


# --- edges -----------------------------------------------------------------
# Structural containment is one relationship; the interesting ones are the
# cross-tree phandle references, because those are what an actual fault
# propagates along.

"""The OS device registry: root -> every known node.

Dependency edges point *outward* from a device to the things it needs, which
is the direction a fault-finding walker wants to travel. That leaves children
unreachable from root, so this edge doubles as the index that keeps the whole
graph reachable and addressable by path.
"""
edge Registry {}

"""Child sits on this parent bus."""
edge ParentBus {}

"""Device draws power from this regulator. `rail` is the supply name."""
edge SuppliedBy {
    has rail: str = "";
}

"""Device is driven by this clock."""
edge ClockedBy {
    has clk: str = "";
}

"""Device is held in / released from reset by this line."""
edge ResetBy {
    has line: str = "";
}

"""Device routes DMA through this controller."""
edge DmaBy {
    has channel: str = "";
}

"""Device raises interrupts into this controller."""
edge InterruptsTo {}
