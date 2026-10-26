// The start screen (ios/src/launcher.m): game files check, the save folder, settings, Play.
#pragma once
#import <Foundation/Foundation.h>

// Shows the launcher and returns once the player taps Play with the game files in place (main thread, before the
// game's window exists). game_dir: Documents/game.
void p4g_launcher_run(NSString *game_dir);
// A message the app can't go past (shown instead of the launcher; never returns).
void p4g_launcher_fatal(NSString *message);
