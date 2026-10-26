#include "settings.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hle.h"
#include "input_bind.h"

#define SETTINGS_FILE settings_file()

// P4G_SETTINGS=<path>: another settings file (test runs never touch the player's p4g.ini)
static const char *settings_file(void) {
    const char *e = getenv("P4G_SETTINGS");
    return e && *e ? e : "p4g.ini";
}

Settings g_settings = {
    .aspect = ASPECT_ORIGINAL,
    .volume = 1.0f,
    .reverb = true,
    .movie_audio = true,
    .rumble = true,
    .rumble_strength = 100,
    .menu_confirm = MENU_CONFIRM_CONTROLLER,
    .upscaler = UPSCALE_SHARP,
    .upscaler_auto = true,
    .res_auto = true,
    .fps_cap = FPS_60,
    .touch_mode = TOUCH_AUTO,
    .touch_opacity = 0.85f,
    .touch_scale = 1.0f,
    .touch_haptics = true,
};

// The game's text and voice languages: data.cpk holds the Japanese base, and each other language is its own archive
// (data_e.cpk English, data_fr / data_de / data_it / data_es, data_k Korean, data_c / data_ck Chinese), which the
// game picks from the system language it reads back (runtime/services/am.c), as on the console.
const char *const g_language_codes[N_LANGUAGES] = {"auto", "ja", "en-US", "fr", "de", "it", "es", "ko", "zh-Hans"};
const char *const g_language_names[N_LANGUAGES] = {"Auto", "Japanese", "English", "French", "German", "Italian",
                                                   "Spanish", "Korean", "Chinese (Simplified)"};

// LANG_AUTO: English (apps get no locale variables from the system on Apple platforms; pick one in settings)
static const char *host_language(void) { return "en-US"; }

const char *settings_language(void) {
    int i = g_settings.language;
    return i > LANG_AUTO && i < N_LANGUAGES ? g_language_codes[i] : host_language();
}

const char *settings_language_name(void) {
    const char *c = settings_language();
    for (int i = 0; i < N_LANGUAGES; i++)
        if (!strcmp(c, g_language_codes[i])) return g_language_names[i];
    return "English";
}

int g_default_upscaler = UPSCALE_SHARP;
int g_default_res_mode = RES_MATCH;
bool g_gpu_integrated;

static const char *res_name(int m) {
    static char n[8];
    if (m >= 1 && m <= 8) { snprintf(n, sizeof n, "%dx", m); return n; }
    return m == RES_DYNAMIC ? "dynamic" : m == RES_Q75 ? "75%" : m == RES_Q50 ? "50%" : m == RES_Q25 ? "25%" : "match";
}

void settings_resolve_defaults(bool integrated) {
    g_gpu_integrated = integrated;
    g_default_upscaler = UPSCALE_SHARP;
    g_default_res_mode = RES_MATCH;
    if (g_settings.upscaler_auto) g_settings.upscaler = g_default_upscaler;
    if (g_settings.res_auto) g_settings.res_mode = g_default_res_mode;
    LOG("[settings] upscaler %s, resolution %s, anti-aliasing %s, %d fps\n",
        g_settings.upscaler == UPSCALE_BILINEAR ? "bilinear" : "metalfx", res_name(g_settings.res_mode),
        g_settings.antialias == AA_SMAA ? "smaa" : "off", g_settings.fps_cap);
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }

void settings_load(void) {
    static bool loaded;
    if (loaded) return;
    loaded = true;
    FILE *f = fopen(SETTINGS_FILE, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        char key[64];
        char val[128] = {0};
        if (sscanf(line, " %63[^= ] = %127[^\n]", key, val) != 2) continue;
        if (!strcmp(key, "aspect")) g_settings.aspect = !strcmp(val, "original") ? ASPECT_ORIGINAL : ASPECT_UNLOCKED;
        else if (!strcmp(key, "fullscreen")) g_settings.fullscreen = atoi(val) != 0;
        else if (!strcmp(key, "volume")) g_settings.volume = (float)atof(val);
        else if (!strcmp(key, "reverb")) g_settings.reverb = atoi(val) != 0;
        else if (!strcmp(key, "movie_audio")) g_settings.movie_audio = atoi(val) != 0;
        else if (!strcmp(key, "show_fps")) g_settings.show_fps = atoi(val) != 0;
        else if (!strcmp(key, "resolution")) {
            int n = atoi(val);
            g_settings.res_auto = !strcmp(val, "auto");
            if (g_settings.res_auto) { g_settings.res_mode = g_default_res_mode; continue; }
            g_settings.res_mode = !strcmp(val, "dynamic") ? RES_DYNAMIC : !strcmp(val, "75%") ? RES_Q75 :
                                  !strcmp(val, "50%") ? RES_Q50 : !strcmp(val, "25%") ? RES_Q25 :
                                  (n >= 1 && n <= 4) ? n : n > 4 ? 4 : RES_MATCH;
        }
        else if (!strcmp(key, "upscaler")) {
            g_settings.upscaler_auto = !strcmp(val, "auto");
            g_settings.upscaler = g_settings.upscaler_auto ? g_default_upscaler
                                  : !strcmp(val, "bilinear") ? UPSCALE_BILINEAR : UPSCALE_SHARP;
        }
        else if (!strcmp(key, "antialias")) g_settings.antialias = !strcmp(val, "off") ? AA_OFF : AA_SMAA;
        else if (!strcmp(key, "dpad_move")) g_settings.dpad_move = atoi(val) != 0;
        else if (!strcmp(key, "rumble")) g_settings.rumble = atoi(val) != 0;
        else if (!strcmp(key, "rumble_strength")) g_settings.rumble_strength = atoi(val);
        else if (!strcmp(key, "controller_light")) g_settings.controller_light = atoi(val) != 0;
        else if (!strcmp(key, "background_input")) g_settings.bg_input = atoi(val) != 0;
        else if (!strcmp(key, "prompts")) g_settings.prompts = !strcmp(val, "nintendo") ? PROMPTS_NINTENDO : !strcmp(val, "xbox") ?
                                                              PROMPTS_XBOX : !strcmp(val, "playstation") ? PROMPTS_PLAYSTATION : PROMPTS_AUTO;
        else if (!strcmp(key, "menu_confirm")) g_settings.menu_confirm = !strcmp(val, "game") ? MENU_CONFIRM_GAME
                                                                                                  : MENU_CONFIRM_CONTROLLER;
        else if (!strcmp(key, "language")) {
            g_settings.language = LANG_AUTO;
            for (int i = 1; i < N_LANGUAGES; i++)
                if (!strcmp(val, g_language_codes[i])) g_settings.language = i;
        }
        else if (!strcmp(key, "fps_cap")) g_settings.fps_cap = atoi(val) == 30 ? FPS_30 : FPS_60;
        else if (!strcmp(key, "touch")) g_settings.touch_mode = !strcmp(val, "on") ? TOUCH_ON : !strcmp(val, "off") ? TOUCH_OFF : TOUCH_AUTO;
        else if (!strcmp(key, "touch_opacity")) g_settings.touch_opacity = (float)atof(val);
        else if (!strcmp(key, "touch_scale")) g_settings.touch_scale = (float)atof(val);
        else if (!strcmp(key, "touch_haptics")) g_settings.touch_haptics = atoi(val) != 0;
        else if (!strcmp(key, "menu_tip_seen")) g_settings.menu_tip_seen = atoi(val) != 0;
        else bind_settings_load(key, val);  // bind_pad_* / bind_key_*: runtime/hle/bindings.c
    }
    fclose(f);
    g_settings.volume = clampf(g_settings.volume, 0, 2);
    g_settings.touch_opacity = clampf(g_settings.touch_opacity, 0.2f, 1);
    g_settings.touch_scale = clampf(g_settings.touch_scale, 0.75f, 1.5f);
    if (g_settings.rumble_strength < 25 || g_settings.rumble_strength > 100) g_settings.rumble_strength = 100;
    LOG("[settings] loaded %s\n", SETTINGS_FILE);
}

void settings_save(void) {
    FILE *f = fopen(SETTINGS_FILE, "w");
    if (!f) { LOG("[settings] cannot write %s\n", SETTINGS_FILE); return; }
    fprintf(f, "# Persona 4 Golden settings (edited from the launcher and the in-game menu)\n");
    fprintf(f, "aspect = %s\n", g_settings.aspect == ASPECT_ORIGINAL ? "original" : "unlocked");
    fprintf(f, "fullscreen = %d\n", g_settings.fullscreen);
    fprintf(f, "volume = %.2f\n", g_settings.volume);
    fprintf(f, "reverb = %d\n", g_settings.reverb);
    fprintf(f, "movie_audio = %d\n", g_settings.movie_audio);
    fprintf(f, "show_fps = %d\n", g_settings.show_fps);
    fprintf(f, "upscaler = %s\n", g_settings.upscaler_auto ? "auto" : g_settings.upscaler == UPSCALE_METALFX ? "metalfx" : "bilinear");
    fprintf(f, "antialias = %s\n", g_settings.antialias == AA_SMAA ? "smaa" : "off");
    fprintf(f, "resolution = %s\n", g_settings.res_auto ? "auto" : res_name(g_settings.res_mode));
    fprintf(f, "dpad_move = %d\n", g_settings.dpad_move);
    fprintf(f, "rumble = %d\n", g_settings.rumble);
    fprintf(f, "rumble_strength = %d\n", g_settings.rumble_strength);
    fprintf(f, "controller_light = %d\n", g_settings.controller_light);
    fprintf(f, "background_input = %d\n", g_settings.bg_input);
    static const char *const prompts[] = {"auto", "nintendo", "xbox", "playstation"};
    fprintf(f, "prompts = %s\n", prompts[g_settings.prompts & 3]);
    fprintf(f, "menu_confirm = %s\n", g_settings.menu_confirm == MENU_CONFIRM_CONTROLLER ? "controller" : "game");
    fprintf(f, "language = %s\n", g_language_codes[g_settings.language > LANG_AUTO && g_settings.language < N_LANGUAGES
                                                     ? g_settings.language : LANG_AUTO]);
    fprintf(f, "fps_cap = %d\n", g_settings.fps_cap);
    static const char *const touch[] = {"auto", "on", "off"};
    fprintf(f, "touch = %s\n", touch[g_settings.touch_mode % 3]);
    fprintf(f, "touch_opacity = %.2f\ntouch_scale = %.2f\ntouch_haptics = %d\n", g_settings.touch_opacity,
            g_settings.touch_scale, g_settings.touch_haptics);
    fprintf(f, "menu_tip_seen = %d\n", g_settings.menu_tip_seen);
    bind_settings_save(f);
    fclose(f);
}
