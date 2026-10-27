// User settings (p4g.ini in the data folder), edited from the launcher and the in-game menu.
#pragma once
#include <stdbool.h>

enum { ASPECT_UNLOCKED = 0, ASPECT_ORIGINAL = 1 };
enum { RES_MATCH = 0, /* 1..8 = 1x..8x */ RES_DYNAMIC = 9, RES_Q75 = 10, RES_Q25 = 11, RES_Q50 = 12 };
enum { UPSCALE_BILINEAR = 0, UPSCALE_METALFX = 1, UPSCALE_FSR1 = 2 };
#define UPSCALE_SHARP UPSCALE_METALFX
enum { AA_OFF = 0, AA_SMAA = 1 };
enum { PROMPTS_AUTO = 0, PROMPTS_NINTENDO = 1, PROMPTS_XBOX = 2, PROMPTS_PLAYSTATION = 3 };
enum { MENU_CONFIRM_GAME = 0, MENU_CONFIRM_CONTROLLER = 1 };
// Frame rate cap: the game's own 30, or 60 (the default; runtime/nvn/pace.c)
enum { FPS_30 = 30, FPS_60 = 60 };
// Touch controls (iOS, runtime/platform/ios_touch.mm): shown when no controller is connected, always, or never
enum { TOUCH_AUTO = 0, TOUCH_ON = 1, TOUCH_OFF = 2 };
// System language served to the game (runtime/services/am.c GetDesiredLanguage, services/hid_set.c): P4G picks its
// text and voice archive (data_e.cpk, data_fr.cpk, ...) from it, as on the console.
enum { LANG_AUTO = 0, N_LANGUAGES = 9 };
extern const char *const g_language_codes[N_LANGUAGES];
extern const char *const g_language_names[N_LANGUAGES];

typedef struct {
    int aspect;
    bool fullscreen;
    int res_mode;
    bool res_auto;
    int upscaler;
    bool upscaler_auto;
    int antialias;
    float volume;
    bool reverb;
    bool movie_audio;
    bool show_fps;
    bool dpad_move;
    bool rumble;
    int rumble_strength;
    bool controller_light;
    bool bg_input;
    int language;
    int prompts;
    int menu_confirm;
    int fps_cap;          // FPS_30 / FPS_60
    int touch_mode;       // TOUCH_*
    float touch_opacity;  // 0.1 .. 1
    float touch_scale;    // 0.75 .. 1.5
    bool touch_haptics;
    float res_scale;      // Match display's resolution x this: 0.5 .. 1.5 (above 1: drawn sharper than the screen)
    float sharpness;      // the present pass's contrast-adaptive sharpening: 0 (off) .. 1
    float camera_sens;    // the touch pad's camera stick: 0.25 .. 2
    bool menu_tip_seen;
} Settings;

extern Settings g_settings;

void settings_load(void);
void settings_save(void);
void settings_resolve_defaults(bool integrated);
extern int g_default_upscaler;
extern int g_default_res_mode;
extern bool g_gpu_integrated;
const char *settings_language(void);
const char *settings_language_name(void);
