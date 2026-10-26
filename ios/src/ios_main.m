// Persona 4 Golden on iOS: the app's entry. SDL runs UIKit (SDL_main.h turns main into SDL_main, called once the app
// has finished launching, on the main thread); this shows the launcher, then boots the game and runs its window loop.
//
// Files (the app's Documents folder, open in the Files app):
//   game/exefs/   main, main.npdm, sdk, subsdk0, rtld  - the player's own extracted game files
//   game/romfs/   data.cpk, data_movie.cpk, ...
//   Save/         the game's save data (swap a save in and out here)
//   p4g.ini       settings          log.txt / log.prev.txt  the last two runs' logs
#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "launcher.h"

void rt_boot(const char *root);
int ui_run(void);
void plat_init(void);
void rt_paths_init(void);
void rt_ios_log_startup_info(void);
void settings_load(void);

static NSString *documents(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// stderr (the runtime's log) into Documents/log.txt, the previous run's kept as log.prev.txt
static void open_log(NSString *docs) {
    NSString *log = [docs stringByAppendingPathComponent:@"log.txt"];
    NSString *prev = [docs stringByAppendingPathComponent:@"log.prev.txt"];
    [[NSFileManager defaultManager] removeItemAtPath:prev error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:log toPath:prev error:nil];
    freopen(log.fileSystemRepresentation, "w", stderr);
    setvbuf(stderr, NULL, _IOLBF, 0);
}

// Environment switches from Documents/env.txt (KEY=VALUE lines): for diagnostic runs without a rebuild
static void load_env_file(NSString *docs) {
    NSString *text = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"env.txt"]
                                               encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [l rangeOfString:@"="];
        if (!l.length || [l hasPrefix:@"#"] || eq.location == NSNotFound) continue;
        setenv([l substringToIndex:eq.location].UTF8String, [l substringFromIndex:eq.location + 1].UTF8String, 1);
        fprintf(stderr, "[env] %s\n", l.UTF8String);
    }
}

int main(int argc, char *argv[]) {
    (void)argc, (void)argv;
    NSString *docs = documents();
    for (NSString *d in @[@"game", @"game/exefs", @"game/romfs", @"Save"])
        [[NSFileManager defaultManager] createDirectoryAtPath:[docs stringByAppendingPathComponent:d]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    open_log(docs);
    load_env_file(docs);
    setenv("P4G_DATA_ROOT", docs.fileSystemRepresentation, 1);
    plat_init();
    rt_ios_log_startup_info();
    rt_paths_init();  // (the data root becomes the working directory: p4g.ini, Save/ are relative to it)
    settings_load();
    if (getenv("P4G_GUEST_RANGE_TAKEN")) {  // (runtime/main.c reserve_guest_space)
        extern const char *rt_vm_report(void);
        if (rt_vm_report()) fputs(rt_vm_report(), stderr);
        p4g_launcher_fatal(@"iOS didn't give the game its memory window. Close other apps and open Persona 4 Golden "
                           @"again. If it keeps happening, send Documents/log.txt.");
        return 1;
    }
    // sound with the ring / silent switch on, like other games (SDL's default category is ambient)
    SDL_SetHint(SDL_HINT_AUDIO_CATEGORY, "playback");
    // In the background iOS refuses GPU work: the game is held at its next frame until the app is back in front
    // (runtime/nvn/metal.m backend_present_now waits on g_app_inactive)
    extern volatile int g_app_inactive;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil
        queue:nil usingBlock:^(NSNotification *n) { g_app_inactive = 1; fprintf(stderr, "[app] inactive: game held\n"); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:nil usingBlock:^(NSNotification *n) { g_app_inactive = 0; fprintf(stderr, "[app] active again\n"); }];
    NSString *game = [docs stringByAppendingPathComponent:@"game"];
    p4g_launcher_run(game);  // (returns when Play is tapped with the game files in place)
    rt_boot(game.fileSystemRepresentation);
    ui_run();
    return 0;
}
