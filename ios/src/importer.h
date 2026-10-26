// Imports the game from the player's own dump on the device (ios/src/importer.c): an NSP, NSZ, XCI or XCZ and their
// prod.keys in, the game folder's exefs/ and romfs/ out. The launcher runs it off the main thread and shows `job`.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ImportJob {
    // progress, read by the launcher while the import runs
    volatile int64_t done, total;  // bytes through the current phase
    volatile const char *phase;    // what it is doing, for the status line
    volatile bool cancel;          // set to stop early (the import then fails with "cancelled")
    char error[512];               // why it failed, for the player
    // checks the exefs it just wrote (the build of the game) before the long RomFS part; false refuses it, with why
    bool (*check_exefs)(const char *exefs_dir, char *why, size_t why_size);
    // test hook: called for each RomFS file instead of writing it (NULL: written under out_dir/romfs)
    bool (*romfs_sink)(void *ctx, const char *path, const void *data, size_t size, bool first, bool last);
    void *sink_ctx;
} ImportJob;

// The title this app runs (the program NCA picked from the container must have it).
#define IMPORT_TITLE_ID 0x010062B01525C000ull

// True when the name looks like a game dump the importer reads (.nsp .nsz .xci .xcz, any case).
bool import_is_game_file(const char *name);
// Extracts `src` with the keys in `keys_path` into out_dir/exefs and out_dir/romfs. Returns false with job->error set.
bool import_game(const char *src, const char *keys_path, const char *out_dir, ImportJob *job);
