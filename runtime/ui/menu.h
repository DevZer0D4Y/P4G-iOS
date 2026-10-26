// In-game overlay menu. Not built yet: the settings live in the launcher (iOS) and p4g.ini; these are its hooks.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

typedef union SDL_Event SDL_Event;

static inline bool menu_handle_event(const SDL_Event *e) { (void)e; return false; }
static inline bool menu_is_open(void) { return false; }
static inline void menu_apply_window_requests(void *sdl_window) { (void)sdl_window; }
static inline void menu_test_open(void) {}
#if defined(__APPLE__) && defined(__OBJC__)
static inline void menu_render(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLTexture> target) {
    (void)dev; (void)cb; (void)target;
}
#endif
