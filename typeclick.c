/*
 * typeclick.c — печатная машинка: щелчок Taptic Engine на каждое нажатие клавиши.
 *
 * Слушает клавиатуру глобально через CGEventTap и дёргает актуатор трекпада
 * (приватный MultitouchSupport.framework через dlopen — ARM-safe).
 * Модификаторы (shift/cmd/...) не щёлкают, пробел/ввод/стереть/esc — свои звуки.
 * Звуки настраиваются: флаги --space/--enter/... или файл ~/.typeclickrc
 * (строки вида `space=5`, перечитывается наживую при каждом нажатии).
 * Прощупать все паттерны: ./typeclick --list
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
#include <sys/stat.h>
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
// 51 стереть, 53 esc, 48 tab, 54-63 модификаторы.
// Значения по умолчанию: esc — buzz, его ни с чем не спутать. */
static int w_space = 5, w_tab = 5, w_enter = 2, w_del = 1, w_esc = 3, w_key = 4;
// 1 = группа задана флагом командной строки — конфиг её не трогает
static int cli_locked[6] = {0, 0, 0, 0, 0, 0}; // space,tab,enter,delete,esc,key

static const char *wave_name(int w) {
    switch (w) {
        case 1: return "слабый клик";
        case 2: return "сильный клик";
        case 3: return "buzz";
        case 4: return "лёгкий тап";
        case 5: return "средний тап";
        case 6: return "сильный тап";
        default: return "?";
    }
}

static int wave_for_key(int code) {
    switch (code) {
        case 49: return w_space;
        case 48: return w_tab;
        case 36: return w_enter;
        case 51: return w_del;
        case 53: return w_esc;
        case 54: case 55: case 58: case 59:
        case 60: case 61: case 62: case 63:
            return 0;      // модификаторы молчат
        default: return w_key;
    }
}

/* ---------- конфиг ~/.typeclickrc (живое перечитывание) ---------- */

static char g_cfg_path[4096] = "";
static time_t g_cfg_mtime = 0;
static long g_cfg_mtime_ns = 0;
static int g_cfg_have = 0;

static int parse_wave(const char *v, int *out) {
    char *e = NULL;
    long n = strtol(v, &e, 10);
    if (!e || *e != '\0' || n < 1 || n > 6) return -1;
    *out = (int)n;
    return 0;
}

static char *trim(char *s) {
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    char *end = s + strlen(s);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t' ||
                       end[-1] == '\n' || end[-1] == '\r')) end--;
    *end = '\0';
    return s;
}

static void load_config(void) {
    if (!g_cfg_path[0]) return;
    struct stat st;
    if (stat(g_cfg_path, &st) != 0) return; // файла нет — остаёмся на текущем
    if (g_cfg_have && st.st_mtime == g_cfg_mtime &&
        st.st_mtimespec.tv_nsec == g_cfg_mtime_ns) return;
    FILE *f = fopen(g_cfg_path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *s = trim(line);
        if (*s == '#' || *s == '\0') continue;
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = '\0';
        char *k = trim(s);
        char *v = trim(eq + 1);
        int *dst = NULL;
        int locked = 0;
        if (!strcmp(k, "space")) { dst = &w_space; locked = cli_locked[0]; }
        else if (!strcmp(k, "tab")) { dst = &w_tab; locked = cli_locked[1]; }
        else if (!strcmp(k, "enter")) { dst = &w_enter; locked = cli_locked[2]; }
        else if (!strcmp(k, "delete")) { dst = &w_del; locked = cli_locked[3]; }
        else if (!strcmp(k, "esc")) { dst = &w_esc; locked = cli_locked[4]; }
        else if (!strcmp(k, "key")) { dst = &w_key; locked = cli_locked[5]; }
        else { fprintf(stderr, "warn: config: неизвестный ключ '%s'\n", k); continue; }
        if (locked) continue; // флаг командной строки важнее файла
        int n = 0;
        if (parse_wave(v, &n) != 0) {
            fprintf(stderr, "warn: config: '%s' ждёт число 1..6\n", k);
            continue;
        }
        *dst = n;
    }
    fclose(f);
    g_cfg_mtime = st.st_mtime;
    g_cfg_mtime_ns = st.st_mtimespec.tv_nsec;
    g_cfg_have = 1;
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
    load_config(); // конфиг перечитывается наживую
    int w = wave_for_key(code);
    if (g_verbose) printf("key %d -> wave %d (%s)\n", code, w, wave_name(w));
    if (w > 0) fire(w);
    return event; // событие пропускаем дальше — печать не ломаем
}

static void usage(const char *prog) {
    fprintf(stderr,
        "Использование: %s [опции]\n"
        "  --space N --tab N --enter N --delete N --esc N --key N\n"
        "                          waveform 1..6 на группы клавиш\n"
        "                          (по умолч.: key=4 space=5 tab=5 enter=2 delete=1 esc=3)\n"
        "  --config PATH           конфиг вида `space=5` (по умолч. ~/.typeclickrc,\n"
        "                          перечитывается наживую при каждом нажатии)\n"
        "  --list                  прощупать waveform 1..6 и выйти\n"
        "  --test-wave N           один удар N и выйти\n"
        "  --probe-key CODE        какой waveform у кода клавиши (49 пробел,\n"
        "                          36 ввод, 51 стереть, 53 esc) и выйти\n"
        "  --min-gap MS            минимум между щелчками, мс (по умолч. 15)\n"
        "  -v                      печатать каждый код клавиши\n"
        "  -d ID                   ID устройства вручную\n"
        "  --device-offset N       оффсет ID (по умолч. 64 + автоподбор)\n"
        "Выход: Ctrl-C. Нужен доступ «Мониторинг ввода» (см. шапку файла).\n",
        prog);
}

int main(int argc, char *argv[]) {
    int list_mode = 0, test_wave = 0, probe_key = -1;
    const char *config_arg = NULL;
    static struct option opts[] = {
        {"min-gap", required_argument, 0, 1001},
        {"device-offset", required_argument, 0, 1002},
        {"space", required_argument, 0, 1003},
        {"tab", required_argument, 0, 1004},
        {"enter", required_argument, 0, 1005},
        {"delete", required_argument, 0, 1006},
        {"esc", required_argument, 0, 1007},
        {"key", required_argument, 0, 1008},
        {"config", required_argument, 0, 1009},
        {"list", no_argument, 0, 1010},
        {"test-wave", required_argument, 0, 1011},
        {"probe-key", required_argument, 0, 1012},
        {0, 0, 0, 0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "vd:h", opts, NULL)) != -1) {
        int n = 0;
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
        case 1003: case 1004: case 1005:
        case 1006: case 1007: case 1008: {
            if (parse_wave(optarg, &n) != 0) { fprintf(stderr, "error: нужен waveform 1..6\n"); return 1; }
            // порядок групп: space,tab,enter,delete,esc,key
            int *dsts[] = {&w_space, &w_tab, &w_enter, &w_del, &w_esc, &w_key};
            *dsts[opt - 1003] = n;
            cli_locked[opt - 1003] = 1;
            break;
        }
        case 1009: config_arg = optarg; break;
        case 1010: list_mode = 1; break;
        case 1011:
            if (parse_wave(optarg, &test_wave) != 0 || test_wave < 1) {
                fprintf(stderr, "error: --test-wave 1..6\n"); return 1;
            }
            break;
        case 1012: probe_key = atoi(optarg); break;
        case 'v': g_verbose = 1; break;
        case 'd': g_device = atoll(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }

    if (load_mt() != 0) return 1;

    // конфиг: явный --config или ~/.typeclickrc, если есть
    if (config_arg) {
        snprintf(g_cfg_path, sizeof(g_cfg_path), "%s", config_arg);
    } else {
        const char *home = getenv("HOME");
        if (home) snprintf(g_cfg_path, sizeof(g_cfg_path), "%s/.typeclickrc", home);
    }
    load_config(); // стартовые значения из файла (флаги уже залочены выше)

    if (probe_key >= 0) { // устройство не нужно — только маппинг
        int w = wave_for_key(probe_key);
        printf("key %d -> wave %d (%s)\n", probe_key, w, wave_name(w));
        return 0;
    }

    if (g_device == -1) {
        g_device = find_device();
        if (g_device == -1) {
            fprintf(stderr, "error: Taptic Engine не найден\n");
            return 1;
        }
        printf("Устройство: %" PRId64 "\n", g_device);
    }

    if (list_mode) {
        printf("Waveform 1..6 (палец на трекпаде!):\n");
        for (int w = 1; w <= 6; w++) {
            printf("  %d (%s)... ", w, wave_name(w));
            fflush(stdout);
            g_last_fire = -1;
            fire(w);
            printf("ok\n");
            usleep(600000);
        }
        return 0;
    }
    if (test_wave > 0) {
        printf("wave %d (%s), палец на трекпаде!\n", test_wave, wave_name(test_wave));
        fflush(stdout);
        g_last_fire = -1;
        fire(test_wave);
        return 0;
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
