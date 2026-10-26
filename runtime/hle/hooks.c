// Hook points: instructions of the game's code that call into the runtime (tools/patches_p4g.py HOOKS). The generated
// code at a hook site runs `rt_hook(c, site)`: 0 runs the instruction, 1 skips it, k + 2 jumps to its k-th target.
// P4G has no hook sites yet.
#include "../hle.h"

int rt_hook(Cpu *c, uint64_t site) {
    (void)c;
    LOG("[hook] unknown site %llx\n", (unsigned long long)site);
    return 0;
}
