"""Turn a traversal result into an engineer-readable diagnosis.

The walker already knows *what* is broken -- it found the fault by traversal,
not by asking a model. The LLM's job is narrower and more honest: take a
verified fault plus the surrounding kernel log and phrase it the way a bring-up
engineer would, then name the next command to run.

Because the return type is a `Diagnosis` object rather than a string, byLLM
enforces the schema for us. There is no prompt template and no output parsing
anywhere in this file -- the type *is* the contract.
"""

import os;
import quiet;   # must precede byllm -- see src/quiet.py

# PyPI ships this as the standalone `byllm` package; the Jaseci monorepo
# vendors the same module at `jaclang.byllm.lib`. Prefer the installed one.
import from byllm.lib { Model, MockLLM }


"""A structured verdict about one hardware fault."""
obj Diagnosis {
    has root_cause: str;
    has confidence: float;
    has reasoning: str;
    has next_step: str;
}

sem Diagnosis.root_cause =
    "Device tree path of the single node most likely responsible for the symptom.";
sem Diagnosis.confidence =
    "How certain the diagnosis is, from 0.0 to 1.0.";
sem Diagnosis.reasoning =
    "Two or three sentences explaining the causal chain from root cause to symptom, "
    "in the register a Linux board bring-up engineer would use.";
sem Diagnosis.next_step =
    "One concrete shell command or check to run next on the device.";


"""Offline stand-in so the demo survives a dead network."""
# Kept in step with fixtures/perry-live.json, NOT the synthetic fixture. If the
# canned answer names a rail the walker did not actually find, the demo prints
# "ROOT CAUSE: l6" and then an explanation about pm8937_l10 directly underneath
# it, and the contradiction is the most visible thing on screen.
glob MOCK = Diagnosis(
    root_cause="/vdda_touch_vreg",
    confidence=0.9,
    reasoning="The touchscreen's vdd supply is the fixed regulator vdda_touch, "
              "and it is disabled. With no rail the RMI4 controller never answers "
              "on i2c, so rmi4_i2c fails to probe and no input device appears. "
              "vdda_touch is consumer-enabled, so it drops as soon as nothing is "
              "holding it up -- the dead driver and the dead rail are one fault.",
    next_step="for r in /sys/class/regulator/*/; do "
              "[ \"$(cat $r/name)\" = vdda_touch ] && cat $r/state $r/num_users; done"
);


"""Pick a backend. Falls back to a mock when there is no key or JACOS_LLM=mock.

Hackathon wifi is not a dependency worth betting a demo on.
"""
def pick_model() -> object {
    if os.environ.get("JACOS_LLM", "") == "mock" {
        return MockLLM(model_name="mockllm", config={"outputs": [MOCK]});
    }
    if os.environ.get("OPENAI_API_KEY", "") == "" {
        return MockLLM(model_name="mockllm", config={"outputs": [MOCK]});
    }
    return Model(model_name=os.environ.get("JACOS_MODEL", "gpt-4o-mini"));
}

glob llm = pick_model();


def explain_fault(
    symptom: str,
    trail: list[str],
    faults: list[dict],
    root_cause: dict,
    dmesg: str
) -> Diagnosis by llm();

sem explain_fault =
    "You are a Linux board bring-up engineer on a Motorola Moto E4 running "
    "postmarketOS. A dependency walk over the device tree started at the "
    "symptom node and followed power, clock and bus edges outward. `trail` is "
    "the order nodes were visited, `faults` is everything that assessed "
    "unhealthy, and `root_cause` is the walker's own pick. Confirm or correct "
    "that pick using the kernel log, and explain the causal chain concisely.";


"""True when a real model is wired up, rather than the offline mock."""
def llm_backed() -> bool {
    return (os.environ.get("JACOS_LLM", "") != "mock")
       and (os.environ.get("OPENAI_API_KEY", "") != "");
}
