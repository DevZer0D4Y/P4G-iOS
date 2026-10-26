// (LASRecomp's randomizer interface: P4G has no seeds, so every query answers "none"; runtime/la_stubs.c)
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
static inline const char *rando_seed_dir(void) { return NULL; }
static inline bool rando_romfs_override(const char *path, char *out, size_t cap) { (void)path, (void)out, (void)cap; return false; }
