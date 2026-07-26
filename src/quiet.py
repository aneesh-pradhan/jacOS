"""Silence litellm's provider banner.

byLLM routes through litellm, which prints a red "Provider List:" block on any
unrecognised model name -- including our offline MockLLM. Harmless, but it
looks like a crash on a projector. Import this *before* byllm.
"""

import os

os.environ.setdefault("LITELLM_LOG", "ERROR")

try:  # pragma: no cover - best effort, litellm may not be installed
    import litellm

    litellm.suppress_debug_info = True
except Exception:
    pass
