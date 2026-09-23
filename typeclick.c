/*
 * typeclick.c — печатная машинка: щелчок Taptic Engine на каждое нажатие клавиши.
 *
 * Слушает клавиатуру глобально через CGEventTap и дёргает актуатор трекпада
 * (приватный MultitouchSupport.framework через dlopen — ARM-safe).
 * Модификаторы (shift/cmd/...) не щёлкают, пробел/ввод/стереть — свои звуки.
 *
 * ВНИМАНИЕ: нужен доступ «Мониторинг ввода»:
 *   Системные настройки → Конфиденциальность → Мониторинг ввода → + typeclick
 * Без него CGEventTap не создаётся — программа сама об этом скажет.
 *
 * Сборка: make typeclick. Работа: ./typeclick [-v] (Ctrl-C — выход).
 * Палец во время печати — на трекпаде, иначе не чувствуется.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>
#include <dlfcn.h>
#include <getopt.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MT_FW "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
#define MTDEVICE_ID_OFFSET 64

static long g_mt_offset = MTDEVICE_ID_OFFSET;
static int g_offset_given = 0;
static int64_t g_device = -1;
static int g_verbose = 0;
static double g_min_gap = 0.015; // минимум 15 мс между щелчками
static double g_last_fire = -1;
static CFMachPortRef g_tap = NULL;

/* ---------- Taptic Engine (dlopen, как в midi_haptic) ---------- */

typedef CFTypeRef (*MTActuatorCreateFromDeviceID_t)(uint64_t deviceID);
typedef IOReturn  (*MTActuatorOpen_t)(CFTypeRef actuator, uint32_t options);
typedef IOReturn  (*MTActuatorClose_t)(CFTypeRef actuator);
typedef IOReturn  (*MTActuatorActuate_t)(CFTypeRef actuator, int32_t waveform,
                                         uint32_t a1, uint32_t a2, uint32_t a3);
typedef CFMutableArrayRef (*MTDeviceCreateList_t)(void);

static MTActuatorCreateFromDeviceID_t pCreate;
static MTActuatorOpen_t               pOpen;
static MTActuatorClose_t              pClose;
static MTActuatorActuate_t            pActuate;
static MTDeviceCreateList_t           pList;

static int load_mt(void) {
    void *h = dlopen(MT_FW, RTLD_LAZY);
    if (!h) { fprintf(stderr, "error: dlopen: %s\n", dlerror()); return -1; }
    pCreate  = (MTActuatorCreateFromDeviceID_t)dlsym(h, "MTActuatorCreateFromDeviceID");
    pOpen    = (MTActuatorOpen_t)dlsym(h, "MTActuatorOpen");
    pClose   = (MTActuatorClose_t)dlsym(h, "MTActuatorClose");
    pActuate = (MTActuatorActuate_t)dlsym(h, "MTActuatorActuate");
    pList    = (MTDeviceCreateList_t)dlsym(h, "MTDeviceCreateList");
    if (!pCreate || !pOpen || !pClose || !pActuate) {
        fprintf(stderr, "error: нет MTActuator-символов\n");
        return -1;
    }
    return 0;
}

static int64_t try_offset(long off, int verbose) {
    if (!pList) return -1;
    CFMutableArrayRef devs = pList();
    if (!devs) return -1;
    CFIndex n = CFArrayGetCount(devs);
    int64_t found = -1;
    for (CFIndex i = 0; i < n; i++) {
        void *dev = (void *)CFArrayGetValueAtIndex(devs, i);
        uint64_t id = 0;
        memcpy(&id, (uint8_t *)dev + off, sizeof(id));
        if (id == 0) continue;
        CFTypeRef act = pCreate(id);
        if (!act) continue;
        IOReturn r = pOpen(act, 0);
        if (verbose) printf("  offset %ld: %" PRIu64 " %s\n", off, id,
                            r == kIOReturnSuccess ? "<- Taptic Engine!" : "(мимо)");
        if (r == kIOReturnSuccess) {
            pClose(act);
            if (found == -1) found = (int64_t)id;
        }
        CFRelease(act);
    }
    CFRelease(devs);
    return found;
}

static int64_t find_device(void) {
    int64_t id = try_offset(g_mt_offset, 0);
    if (id != -1 || g_offset_given) return id;
    for (long off = 0; off <= 248; off += 8) {
        if (off == MTDEVICE_ID_OFFSET) continue;
        id = try_offset(off, 0);
        if (id != -1) {
            g_mt_offset = off;
            printf("Подобран offset %ld\n", off);
            return id;
        }
    }
    return -1;
}

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void fire(int wave) {
    double now = now_sec();
    if (now - g_last_fire < g_min_gap) return; // защита от пулемёта
    g_last_fire = now;
    CFTypeRef act = pCreate((uint64_t)g_device);
    if (!act) return;
    if (pOpen(act, 0) == kIOReturnSuccess)
        pActuate(act, wave, 0, 0, 0);
    pClose(act);
    CFRelease(act);
}

/* ---------- клавиши ---------- */

/* keycode -> waveform (0 = молчать). Коды CG: 49 пробел, 36 ввод,
// 51 стереть, 53 esc, 48 tab, 54-63 модификаторы. */
static int wave_for_key(int code) {
    switch (code) {
        case 49: return 5; // пробел — средний тап
        case 48: return 5; // tab
        case 36: return 2; // ввод — сильный клик
        case 51: return 1; // стереть — слабый клик
        case 53: return 6; // esc — сильный тап
        case 54: case 55: case 58: case 59:
        case 60: case 61: case 62: case 63:
            return 0;      // модификаторы молчат
        default: return 4; // буквы/цифры — лёгкий тап
    }
}

static CGEventRef key_callback(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void *info) {
    (void)proxy; (void)info;
    if (type == kCGEventTapDisabledByTimeout) {
        CGEventTapEnable(g_tap, true);
        return event;
    }
    if (type != kCGEventKeyDown) return event;
    int code = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    int w = wave_for_key(code);
    if (g_verbose) printf("key %d -> wave %d\n", code, w);
    if (w > 0) fire(w);
    return event; // событие пропускаем дальше — печать не ломаем
}

static void usage(const char *prog) {
    fprintf(stderr,
        "Использование: %s [опции]\n"
        "  --min-gap MS   минимум между щелчками, мс (по умолч. 15)\n"
        "  -v             печатать каждый код клавиши\n"
        "  -d ID          ID устройства вручную\n"
        "  --device-offset N  оффсет ID (по умолч. 64 + автоподбор)\n"
        "Выход: Ctrl-C. Нужен доступ «Мониторинг ввода» (см. шапку файла).\n",
        prog);
}

int main(int argc, char *argv[]) {
    static struct option opts[] = {
        {"min-gap", required_argument, 0, 1001},
        {"device-offset", required_argument, 0, 1002},
        {0, 0, 0, 0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "vd:h", opts, NULL)) != -1) {
        switch (opt) {
        case 1001:
            g_min_gap = atof(optarg) / 1000.0;
            if (g_min_gap < 0 || g_min_gap > 1) { fprintf(stderr, "error: --min-gap 0..1000\n"); return 1; }
            break;
        case 1002: {
            long v = atol(optarg);
            if (v < 0 || v > 512) { fprintf(stderr, "error: --device-offset 0..512\n"); return 1; }
            g_mt_offset = v;
            g_offset_given = 1;
            break;
        }
        case 'v': g_verbose = 1; break;
        case 'd': g_device = atoll(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }

    if (load_mt() != 0) return 1;
    if (g_device == -1) {
        g_device = find_device();
        if (g_device == -1) {
            fprintf(stderr, "error: Taptic Engine не найден\n");
            return 1;
        }
        printf("Устройство: %" PRId64 "\n", g_device);
    }

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault, mask,
                                         key_callback, NULL);
    if (!tap) {
        fprintf(stderr,
            "error: CGEventTap не создался — нет доступа.\n"
            "Открой: Системные настройки → Конфиденциальность и безопасность →\n"
            "Мониторинг ввода → добавь typeclick (перетащи бинарь в список).\n");
        return 1;
    }
    // tap нужен и в колбэке (перевключение по таймауту)
    g_tap = tap;

    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    printf("Печатай! Палец на трекпаде. Выход: Ctrl-C\n");
    fflush(stdout);
    CFRunLoopRun();
    return 0;
}
