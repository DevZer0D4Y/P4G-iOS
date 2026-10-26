"""Hand-written changes to the lifted game code, per build (tools/builds.py), for the main module.

HOOKS:   {address: (expected instruction word, [jump targets], description)}: the runtime decides at that instruction
         (runtime/hle/hooks.c rt_hook) whether it runs, is skipped (1) or jumps to targets[k] (k + 2).
PATCHES: {address: function(module, address) -> C}: replaces one instruction with the returned C.
"""

HOOKS, PATCHES = {}, {}


def load(key):
    global HOOKS, PATCHES
    table = {'v1_0_0': {}}.get(key, {})
    HOOKS = table.get('hooks', {})
    PATCHES = table.get('patches', {})
    return HOOKS, PATCHES
