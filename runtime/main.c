// Persona 4 Golden entry: load modules, set up the kernel, run nn::init::Start on the main thread.
// The platform front end (the Mac window, or the iOS app in runtime/platform/ios) calls rt_boot() and then runs the
// window loop (ui_run) on the main thread.
#include <SDL3/SDL.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "gamelib.h"
#include "paths.h"
#include "settings.h"
#include "hle.h"
#include "kernel.h"

const char *g_romfs_dir;

static void run_array(Cpu *c, uint64_t arr, uint64_t size) {
    for (uint64_t i = 0; i < size / 8; i++) {
        uint64_t fn = ((uint64_t *)arr)[i];
        if (fn) guest_call(c, fn);
    }
}

// nn::init::Start calls x2 right after nnosInitialize and x3 after nninitStartup, just before nnMain: SDK
// constructors run early, the game's once nninitStartup has set up its heap. rtld runs a module's DT_INIT, which
// registers it (and its TLS template) with musl via __nnmusl_init_dso and then runs its init_array.
static void module_init(Cpu *c, Module *m) {
    LOG("init %s (DT_INIT %llx, %llu init_array entries)\n", m->name, m->init, m->init_array_sz / 8);
    if (m->init) guest_call(c, m->init);
    else run_array(c, m->init_array, m->init_array_sz);
}

static void rtld_init_sdk(Cpu *c) {
    for (int i = 1; i < g_nmodules; i++) module_init(c, &g_modules[i]);  // (sdk, then the subsdk modules)
}
static void rtld_init_main(Cpu *c) { module_init(c, &g_modules[0]); }
static void rtld_fini(Cpu *c) { (void)c; LOG("nnMain returned\n"); }

// Claim the guest address range before anything else can map there (constructor: before the allocator's regions).
// macOS: on a collision, re-exec for a fresh layout. iOS can't re-exec: the window there is below anything the system
// puts in an app's address space, and a failure is reported on screen (P4G_REEXEC is never set).
#if defined(__APPLE__) && TARGET_OS_IPHONE
#include <mach/mach.h>
// Why the window couldn't be had, for the log (this runs before ios_main.m opens Documents/log.txt): the regions
// mapped across the window and the highest address the app may map at all (iOS's per-app address space limit).
static char vm_report[4096];
static void vm_report_take(void) {
    int n = snprintf(vm_report, sizeof vm_report, "FATAL: guest address range %llx-%llx is not free\n", GUEST_LO, GUEST_HI);
    // every region over 256 MB and every gap over 1 GB, in address order (the window needs one of the gaps)
    vm_address_t a = 0, prev_end = 0;
    for (int k = 0; k < 100000 && n < (int)sizeof vm_report - 160; k++) {
        vm_size_t sz = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj)) break;
        if (a - prev_end >= 0x40000000ull)
            n += snprintf(vm_report + n, sizeof vm_report - n, "[vm] free %llx-%llx (%.1f GB)\n", (unsigned long long)prev_end,
                          (unsigned long long)a, (a - prev_end) / 1073741824.0);
        if (sz >= 0x10000000ull || (a + sz > GUEST_LO && a < GUEST_HI))
            n += snprintf(vm_report + n, sizeof vm_report - n, "[vm] mapped %llx-%llx (%.2f GB) prot %d\n", (unsigned long long)a,
                          (unsigned long long)(a + sz), sz / 1073741824.0, info.protection);
        prev_end = a + sz;
        a += sz;
    }
    // the app's address space limits (TASK_VM_INFO: max_address is iOS's per-app ceiling)
    task_vm_info_data_t vi;
    mach_msg_type_number_t vc = TASK_VM_INFO_COUNT;
    uint64_t lo = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &vc) == KERN_SUCCESS) lo = (uint64_t)vi.max_address;
    n += snprintf(vm_report + n, sizeof vm_report - n, "[vm] address space ends at %llx (%.1f GB)\n", lo, lo / 1073741824.0);
}
const char *rt_vm_report(void) { return vm_report[0] ? vm_report : NULL; }
#endif

__attribute__((constructor(101))) static void reserve_guest_space(void) {
    if (plat_reserve_guest(GUEST_LO, GUEST_HI)) return;
#if defined(__APPLE__) && TARGET_OS_IPHONE
    setenv("P4G_GUEST_RANGE_TAKEN", "1", 1);  // (the front end shows it instead of starting the game)
    vm_report_take();
#else
    const char *tries = getenv("P4G_REEXEC");
    int n = tries ? atoi(tries) : 0;
    if (n >= 20) {
        fprintf(stderr, "FATAL: guest address range %llx-%llx is not free\n", GUEST_LO, GUEST_HI);
        exit(1);
    }
    char buf[16];
    snprintf(buf, sizeof buf, "%d", n + 1);
    setenv("P4G_REEXEC", buf, 1);
    plat_exec(NULL);
    perror("re-exec");
    exit(1);
#endif
}

void rt_request_reboot(int kind) { LOG("[reboot] not supported (%d)\n", kind); }
int rt_reboot_requested(void) { return RT_REBOOT_NONE; }
void reboot_test_frame(uint64_t frame) { (void)frame; }

// root: the folder holding exefs/ and romfs/ (the player's own extracted game files)
void rt_boot(const char *root) {
    char exefs[1024], romfs[1024], npdm_path[1024];
    snprintf(exefs, sizeof exefs, "%s/exefs", root);
    snprintf(romfs, sizeof romfs, "%s/romfs", root);
    snprintf(npdm_path, sizeof npdm_path, "%s/main.npdm", exefs);
    if (!g_romfs_dir) g_romfs_dir = strdup(romfs);

    char why[512];
    if (!gamelib_load(root, why, sizeof why)) FATAL("%s\n", why);
    loader_load(exefs);
    settings_load();
    kernel_init();
    dispatch_init();

    uint32_t stack_size = 0x100000;
    int prio = 44;
    FILE *f = fopen(npdm_path, "rb");
    if (f) {
        uint8_t meta[0x80];
        if (fread(meta, 1, sizeof meta, f) == sizeof meta && !memcmp(meta, "META", 4)) {
            prio = meta[0xE];
            stack_size = *(uint32_t *)(meta + 0x1C);
        }
        fclose(f);
    }
    LOG("main thread: prio %d, stack 0x%x\n", prio, stack_size);

    // SDK 14: nn::init::Start(thread handle, args region, init sdk modules, init main, finalize) - the third callback
    // runs after nnMain returns (the older two-callback Start is _ZN2nn4init5StartEmmPFvvES2_)
    uint64_t start = loader_find_symbol("_ZN2nn4init5StartEmmPFvvES2_S2_");
    if (!start) FATAL("nn::init::Start not found\n");
    uint64_t init_sdk = hle_register("<rtld_init_sdk>", rtld_init_sdk);
    uint64_t init_main = hle_register("<rtld_init_main>", rtld_init_main);
    uint64_t fini = hle_register("<rtld_fini>", rtld_fini);
    KThread *t = kernel_create_main_thread(start, stack_size, prio);
    kernel_run_main(t, t->handle, 0, init_sdk, init_main, fini);
}

static void log_startup_info(void) {
    PlatSysInfo si = {0};
    plat_system_info(&si);
    unsigned long long gb10 = (si.ram * 10 + (1ull << 29)) >> 30;
    fprintf(stderr, "[info] Persona 4 Golden %s, %s, %s, %d cores, %llu.%llu GB RAM, guest at %llx\n", P4G_VERSION,
            si.os[0] ? si.os : "unknown OS", si.cpu[0] ? si.cpu : "unknown CPU", si.cores, gb10 / 10, gb10 % 10,
            GUEST_LO);
}

#if !(defined(__APPLE__) && TARGET_OS_IPHONE)
// The Mac: p4g [<game folder>] (default: ./game, holding exefs/ and romfs/)
int main(int argc, char **argv) {
    plat_init();
    setvbuf(stderr, NULL, _IOLBF, 0);
    log_startup_info();
    static char root[1024] = "game";
    for (int i = 1; i < argc; i++)
        if (argv[i][0] != '-' && !realpath(argv[i], root)) snprintf(root, sizeof root, "%s", argv[i]);
    rt_paths_init();
    rt_boot(root);
    ui_run();
    return 0;
}
#else
void rt_ios_log_startup_info(void) { log_startup_info(); }
#endif
