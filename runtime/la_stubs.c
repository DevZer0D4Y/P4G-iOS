// Hooks of Link's Awakening features the LASRecomp renderer and services still call (texture patches, cosmetic
// recolours, mirror mode, enemy randomizer): P4G has none of them, so each one does nothing.
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "nvn/texpatch.h"

int texpatch_identify(const NvnTexture *t) { (void)t; return -1; }
int texpatch_bottle_kind(int id) { (void)id; return 0; }
uint8_t *texpatch_ui_rgba(const char *name, int *w, int *h) { (void)name, (void)w, (void)h; return NULL; }
int texpatch_ui_rgba_list(const char *const *names, int n, uint8_t **out, int *w, int *h) {
    (void)names, (void)n, (void)out, (void)w, (void)h;
    return 0;
}
NvnTexture *texpatch_hint_icon(void) { return NULL; }
bool texpatch_is_item_cursor(int id) { (void)id; return false; }
uint32_t texpatch_generation(void) { return 0; }
void texpatch_apply(int id, uint32_t lv, uint8_t *blocks, uint32_t w, uint32_t h, uint32_t row) {
    (void)id, (void)lv, (void)blocks, (void)w, (void)h, (void)row;
}
int texpatch_heart_kind(int id) { (void)id; return 0; }
void texpatch_heart_tint(int kind, float tint[8]) { (void)kind, (void)tint; }

int recolour_identify(const NvnTexture *t, uint64_t total) { (void)t, (void)total; return -1; }
const char *recolour_name(int id) { (void)id; return NULL; }
int recolour_class_of(int id) { (void)id; return 0; }
int recolour_pick(int a, int b) { (void)b; return a; }
void recolour_tint(int cls, float tint[8]) { (void)cls, (void)tint; }
void recolour_add(int cls[2], int c) { (void)cls, (void)c; }
void recolour_tint_draw(const int cls[2], float tint[RECOLOUR_TINT_FLOATS]) { (void)cls, (void)tint; }

bool mirror_draw(bool composite) { (void)composite; return false; }
bool mirror_scene_size(uint32_t sw, uint32_t sh, uint32_t w, uint32_t h) { (void)sw, (void)sh, (void)w, (void)h; return false; }
void enemy_random_filter(const char *host, uint64_t off, uint8_t *dst, uint64_t n) { (void)host, (void)off, (void)dst, (void)n; }

// ---- the Link's Awakening game hooks the renderer, input and file services call every frame
typedef struct Cpu Cpu;
void chamber_game_tick(Cpu *c, uint64_t frame) { (void)c, (void)frame; }
void digs_game_tick(Cpu *c, uint64_t frame) { (void)c, (void)frame; }
void give_item_tick(Cpu *c, uint64_t frame) { (void)c, (void)frame; }
void pot_bush_game_tick(Cpu *c, uint64_t frame) { (void)c, (void)frame; }
void shell_spots_tick(Cpu *c, uint64_t frame) { (void)c, (void)frame; }
void pets_game_tick(Cpu *c) { (void)c; }
void warp_game_tick(Cpu *c) { (void)c; }
int cheats_link_health(int *max) { if (max) *max = 0; return -1; }  // (-1: not in play: the light bar keeps its colour)
void escape_bottle_tint(int kind, const float *ui, uint32_t ui_size, float tint[8]) { (void)kind, (void)ui, (void)ui_size, (void)tint; }
void flags_ext_save_read(const char *path, uint64_t addr, int64_t off, int64_t size) { (void)path, (void)addr, (void)off, (void)size; }
bool flags_ext_save_written(const char *path, uint64_t addr, int64_t off, int64_t size) {
    (void)path, (void)addr, (void)off, (void)size;
    return false;
}
void save_editor_file_read(const char *path, uint64_t addr, int64_t off, int64_t size) { (void)path, (void)addr, (void)off, (void)size; }
void save_editor_frame(uint64_t frame) { (void)frame; }
uint64_t g_stick_freeze_until, g_test_stick_until, g_test_buttons, g_test_buttons_until;
int32_t g_test_lx, g_test_ly, g_stick_lx, g_stick_ly;
char g_window_shot_request[256];
uint64_t game_camera_zone(void) { return 0; }
int game_in_play(void) { return 0; }
bool hint_sheet_icon_draw(const float *ui, uint32_t ui_size) { (void)ui, (void)ui_size; return false; }
void input_note_rstick(int32_t ry) { (void)ry; }
const char *larecomp_version(void) { return "p4g-0.1.0"; }  // (the shader caches' tag)
bool menu_input_captured(void) { return false; }
int menu_keyboard_run(const char *initial, int max_len, char *out, int cap) {  // (no on-screen keyboard yet: the default)
    (void)max_len;
    snprintf(out, (size_t)cap, "%s", initial ? initial : "");
    return 1;
}
bool mirror_input(void) { return false; }
bool pets_hide_item_cursor(void) { return false; }
uint64_t pets_menu_input(uint64_t b, int32_t st[4]) { (void)st; return b; }
uint64_t tracker_map_input(uint64_t b, int32_t st[4]) { (void)st; return b; }
bool pot_glow_active(void) { return false; }
void pot_gold_tint(float tint[8]) { (void)tint; }
bool pot_instance_gold(const float *m) { (void)m; return false; }
void pot_item_draw(float *m) { (void)m; }
bool pot_level_active(void) { return false; }
void pot_probe(const float *m, bool tintable, uint64_t mesh, uint32_t inst) { (void)m, (void)tintable, (void)mesh, (void)inst; }
bool pot_tint(const float *m, float tint[8], uint64_t mesh) { (void)m, (void)tint, (void)mesh; return false; }
void qol_tick(void) {}
void romfs_file_read_hook(const char *path) { (void)path; }
void run_timer_ending_movie(void) {}
void run_timer_tick(void) {}
void run_timer_title(void) {}
void scene_size_log(bool composite, uint32_t sw, uint32_t sh, uint32_t w, uint32_t h) { (void)composite, (void)sw, (void)sh, (void)w, (void)h; }
void warp_frame(uint64_t frame) { (void)frame; }
bool widescreen_allowed(void) { return false; }
void widescreen_backdrop_seen(uint64_t hash) { (void)hash; }
float widescreen_effect_stretch(uint64_t fs_hash) { (void)fs_hash; return 1.0f; }
void widescreen_frame_end(uint64_t frame) { (void)frame; }
// (the whole game image: uv origin 0,0 and size 1,1; the viewport the caller computed stays)
void widescreen_present_crop(uint64_t frame, double shape, float crop[4], double *vx, double *vy, double *vw, double *vh) {
    (void)frame, (void)shape, (void)vx, (void)vy, (void)vw, (void)vh;
    crop[0] = crop[1] = 0;
    crop[2] = crop[3] = 1;
}
void widescreen_scene_ubo(const float *u, uint64_t size) { (void)u, (void)size; }
void widescreen_set_factor(float f) { (void)f; }
bool widescreen_ui_pane_partial(const float *u, uint64_t size) { (void)u, (void)size; return false; }
bool world_on_screen(void) { return true; }
const char *game_level_name(void) { return ""; }
void recolour_pack(float tint[8], float shift, float sat, float val, float centre, float width, float min_sat,
                   float spread) {
    (void)tint, (void)shift, (void)sat, (void)val, (void)centre, (void)width, (void)min_sat, (void)spread;
}
