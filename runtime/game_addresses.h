// Fixed addresses in the game's code (LASRecomp kept one table per Link's Awakening version). P4G has none yet: GA()
// reads 0 and the features that used one stay off. Per-build P4G addresses go in tools/builds.py / patches_p4g.py.
#pragma once
#include <stdint.h>
#define GA(name) ((uint64_t)0)
