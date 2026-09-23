/*
 * audio_haptic.c — стук по битам MP3/WAV на Taptic Engine макбука (Apple Silicon)
 *
 * Как работает:
 *  1. mp3/m4a/aiff/flac -> afconvert -> временный wav 22050 Гц моно 16-бит
 *  2. onset-детекция: energy flux + адаптивный порог (медиана за ~1 с)
 *  3. каждый бит -> waveform по силе удара (gain), свежий актуатор на удар
 *
 * Актуатор — через приватный MultitouchSupport.framework, грузится через
 * dlopen/dlsym (обязательно на ARM — прямой линк ломается из-за PAC).
 * Хэндл актуатора одноразовый (single-shot): под каждый удар новый хэндл.
 *
 * Сборка: make audio_haptic
 * Использование: ./audio_haptic song.mp3 [опции]
 *
 * Палец во время игры — на трекпаде, иначе не чувствуется (Force Touch).
 */

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>
#include <dlfcn.h>
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MT_FW "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
#define MTDEVICE_ID_OFFSET 64

/* См. midi_haptic.c: оффсет может отличаться на другом железе — автоподбор. */
static long g_mt_offset = MTDEVICE_ID_OFFSET;
static int g_offset_given = 0;

#define ANA_RATE   22050   // частота анализа после afconvert
#define FRAME      1024    // окно анализа (~46 мс)
#define HOP        512     // шаг (~23 мс)
#define HIST_SEC   1.0     // окно адаптивного порога, сек
#define SILENCE_E  1e-7    // ниже этой энергии — тишина, битов нет

/* ---------- приватный фреймворк (ARM-safe через dlopen) ---------- */

static void *mt_handle = NULL;

typedef CFTypeRef (*MTActuatorCreateFromDeviceID_t)(uint64_t deviceID);
typedef IOReturn  (*MTActuatorOpen_t)(CFTypeRef actuator, uint32_t options);
typedef IOReturn  (*MTActuatorClose_t)(CFTypeRef actuator);
typedef IOReturn  (*MTActuatorActuate_t)(CFTypeRef actuator, int32_t waveform,
                                         uint32_t a1, uint32_t a2, uint32_t a3);
typedef CFMutableArrayRef (*MTDeviceCreateList_t)(void);

static MTActuatorCreateFromDeviceID_t pMTActuatorCreateFromDeviceID = NULL;
static MTActuatorOpen_t               pMTActuatorOpen = NULL;
static MTActuatorClose_t              pMTActuatorClose = NULL;
static MTActuatorActuate_t            pMTActuatorActuate = NULL;
static MTDeviceCreateList_t           pMTDeviceCreateList = NULL;

static int load_mt(void) {
    mt_handle = dlopen(MT_FW, RTLD_LAZY);
    if (!mt_handle) {
        fprintf(stderr, "error: dlopen MultitouchSupport: %s\n", dlerror());
        return -1;
    }
    pMTActuatorCreateFromDeviceID = (MTActuatorCreateFromDeviceID_t)dlsym(mt_handle, "MTActuatorCreateFromDeviceID");
    pMTActuatorOpen    = (MTActuatorOpen_t)dlsym(mt_handle, "MTActuatorOpen");
    pMTActuatorClose   = (MTActuatorClose_t)dlsym(mt_handle, "MTActuatorClose");
    pMTActuatorActuate = (MTActuatorActuate_t)dlsym(mt_handle, "MTActuatorActuate");
    pMTDeviceCreateList = (MTDeviceCreateList_t)dlsym(mt_handle, "MTDeviceCreateList");
    if (!pMTActuatorCreateFromDeviceID || !pMTActuatorOpen ||
        !pMTActuatorClose || !pMTActuatorActuate) {
        fprintf(stderr, "error: не нашлись MTActuator-символы\n");
        return -1;
    }
    return 0;
}

static uint64_t mt_device_get_id_at(void *dev, long offset) {
    uint64_t id = 0;
    memcpy(&id, (uint8_t *)dev + offset, sizeof(id));
    return id;
}

static int64_t try_offset(long offset, int verbose) {
    CFMutableArrayRef devices = pMTDeviceCreateList();
    if (!devices) return -1;
    CFIndex count = CFArrayGetCount(devices);
    if (verbose) printf("Найдено multitouch-устройств: %ld\n", (long)count);
    int64_t found = -1;
    for (CFIndex i = 0; i < count; i++) {
        void *dev = (void *)CFArrayGetValueAtIndex(devices, i);
        uint64_t devID = mt_device_get_id_at(dev, offset);
        if (devID == 0) continue;
        CFTypeRef act = pMTActuatorCreateFromDeviceID(devID);
        if (!act) continue;
        IOReturn r = pMTActuatorOpen(act, 0);
        if (verbose)
            printf("  [%ld] offset %ld, device ID: %" PRIu64 " %s\n", (long)i, offset,
                   devID, r == kIOReturnSuccess ? "<- Taptic Engine!" : "(без актуатора)");
        if (r == kIOReturnSuccess) {
            pMTActuatorClose(act);
            if (found == -1) found = (int64_t)devID;
        }
        CFRelease(act);
    }
    CFRelease(devices);
    return found;
}

static int64_t find_trackpad_device_id(int verbose) {
    if (!pMTDeviceCreateList) { fprintf(stderr, "error: MTDeviceCreateList недоступен\n"); return -1; }
    int64_t id = try_offset(g_mt_offset, verbose);
    if (id != -1 || g_offset_given) return id;
    if (verbose) printf("offset 64 не дал устройства — сканирую 0..248...\n");
    for (long off = 0; off <= 248; off += 8) {
        if (off == MTDEVICE_ID_OFFSET) continue;
        id = try_offset(off, 0);
        if (id != -1) {
            g_mt_offset = off;
            printf("Подобран offset %ld, device ID: %" PRId64 "\n", off, id);
            return id;
        }
    }
    return -1;
}

static IOReturn actuate_once(int64_t deviceID, int waveform) {
    CFTypeRef act = pMTActuatorCreateFromDeviceID((uint64_t)deviceID);
    if (!act) return -1;
    IOReturn r = pMTActuatorOpen(act, 0);
    if (r == kIOReturnSuccess)
        r = pMTActuatorActuate(act, waveform, 0, 0, 0);
    pMTActuatorClose(act);
    CFRelease(act);
    return r;
}

/* ---------- маппинг силы -> waveform (как velocity в midi_haptic) ---------- */

static int map_by_strength(double s /*0..1*/) {
    int vel = 1 + (int)(s * 126.0);
    if (vel <= 50)  return 4; // лёгкий тап
    if (vel <= 85)  return 5; // средний тап
    if (vel <= 110) return 2; // сильный клик
    return 6;                 // сильный тап
}

static const char *waveform_name(int w) {
    switch (w) {
        case 1: return "слабый клик";
        case 2: return "сильный клик";
        case 3: return "buzz";
        case 4: return "лёгкий тап";
        case 5: return "средний тап";
        case 6: return "сильный тап";
        default: return "кастом";
    }
}

/* ---------- WAV: конвертация + чтение ---------- */

static int has_ext(const char *path, const char *ext) {
    size_t n = strlen(path), m = strlen(ext);
    if (n < m) return 0;
    for (size_t i = 0; i < m; i++) {
        char a = path[n - m + i], b = ext[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) return 0;
    }
    return 1;
}

/* wav -> уже wav 22050 моно: просто копируем путь; иначе afconvert во временный файл.
 * Возвращает путь к wav (malloc или исходник) и флаг надо_ли_удалять. */
static char *to_analysis_wav(const char *in, int *is_temp) {
    *is_temp = 0;
    if (has_ext(in, ".wav") || has_ext(in, ".wave")) {
        return (char *)in;
    }
    char tmpl[] = "/tmp/audio_haptic_XXXXXX.wav";
    int fd = mkstemps(tmpl, 4); // 4 = длина ".wav"
    if (fd < 0) { fprintf(stderr, "error: mkstemps: %s\n", strerror(errno)); return NULL; }
    close(fd);
    // afconvert умеет mp3/m4a/aiff/flac/caf напрямую
    char cmd[8192];
    snprintf(cmd, sizeof(cmd),
             "afconvert -f WAVE -d LEI16@%d -c 1 --mix \"%s\" \"%s\" 2>/dev/null",
             ANA_RATE, in, tmpl);
    int rc = system(cmd);
    if (rc != 0) {
        unlink(tmpl);
        fprintf(stderr, "error: afconvert не смог прочитать '%s' (код %d)\n", in, rc);
        return NULL;
    }
    *is_temp = 1;
    return strdup(tmpl);
}

typedef struct {
    int16_t *pcm;      // моно, нормировано позже делением на 32768
    size_t   nsamples;
    int      rate;
    double   duration;
} Audio;

static uint16_t rd16le(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int read_wav_mono16(const char *path, Audio *au) {
    memset(au, 0, sizeof(*au));
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "error: не могу открыть '%s': %s\n", path, strerror(errno)); return -1; }
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (fsize < 44) { fclose(f); fprintf(stderr, "error: '%s' слишком мал для WAV\n", path); return -1; }
    uint8_t *buf = malloc((size_t)fsize);
    if (!buf) { fclose(f); return -1; }
    if (fread(buf, 1, (size_t)fsize, f) != (size_t)fsize) { fclose(f); free(buf); return -1; }
    fclose(f);

    if (memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
        free(buf); fprintf(stderr, "error: '%s' не WAV\n", path); return -1;
    }
    // идём по чанкам
    size_t pos = 12;
    int fmt_found = 0, audio_fmt = 0, channels = 0, rate = 0, bits = 0;
    uint8_t *data = NULL;
    size_t data_len = 0;
    while (pos + 8 <= (size_t)fsize) {
        uint32_t clen = rd32le(buf + pos + 4);
        if (pos + 8 + clen > (size_t)fsize) break;
        if (memcmp(buf + pos, "fmt ", 4) == 0 && clen >= 16) {
            audio_fmt = rd16le(buf + pos + 8);
            channels  = rd16le(buf + pos + 10);
            rate      = (int)rd32le(buf + pos + 12);
            bits      = rd16le(buf + pos + 22);
            fmt_found = 1;
        } else if (memcmp(buf + pos, "data", 4) == 0) {
            data = buf + pos + 8;
            data_len = clen;
        }
        pos += 8 + clen + (clen & 1);
    }
    if (!fmt_found || !data) { free(buf); fprintf(stderr, "error: в '%s' нет fmt/data чанков\n", path); return -1; }
    if (audio_fmt != 1 || bits != 16) {
        free(buf); fprintf(stderr, "error: нужен PCM 16-bit (fmt=%d bits=%d)\n", audio_fmt, bits); return -1;
    }
    if (channels < 1 || rate <= 0) { free(buf); fprintf(stderr, "error: битый fmt\n"); return -1; }

    size_t frames = data_len / (size_t)(2 * channels);
    int16_t *pcm = malloc(frames * sizeof(int16_t));
    if (!pcm) { free(buf); return -1; }
    for (size_t i = 0; i < frames; i++) {
        int32_t acc = 0;
        for (int c = 0; c < channels; c++)
            acc += (int16_t)rd16le(data + (i * channels + c) * 2);
        pcm[i] = (int16_t)(acc / channels);
    }
    free(buf);
    au->pcm = pcm;
    au->nsamples = frames;
    au->rate = rate;
    au->duration = (double)frames / rate;
    return 0;
}

/* ---------- onset-детекция (energy flux + адаптивный порог) ---------- */

typedef struct {
    double time;     // сек
    double strength; // 0..1
} Hit;

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

// nth_element нет в libc — медиана через qsort копии (окон ~43 шт, дёшево)
static double median_of(const double *v, int n, double *tmp) {
    memcpy(tmp, v, (size_t)n * sizeof(double));
    qsort(tmp, (size_t)n, sizeof(double), cmp_double);
    return n % 2 ? tmp[n / 2] : 0.5 * (tmp[n / 2 - 1] + tmp[n / 2]);
}

static Hit *detect_hits(const Audio *au, double sens, double min_gap_sec,
                        long max_hits, double tshift, size_t *nhits_out) {
    *nhits_out = 0;
    int hop = HOP * ANA_RATE / au->rate; // пересчёт под реальную частоту
    if (hop < 64) hop = 64;
    int frame = hop * 2;
    if (au->nsamples < (size_t)frame) return NULL;

    int nfr = (int)((au->nsamples - frame) / hop) + 1;
    double *energy = calloc((size_t)nfr, sizeof(double));
    double *flux = calloc((size_t)nfr, sizeof(double));
    if (!energy || !flux) { free(energy); free(flux); return NULL; }

    for (int i = 0; i < nfr; i++) {
        double e = 0;
        size_t off = (size_t)i * hop;
        for (int j = 0; j < frame; j += 4) { // каждый 4-й сэмпл — достаточно для энергии
            double s = au->pcm[off + j] / 32768.0;
            e += s * s;
        }
        energy[i] = e / (frame / 4);
    }
    for (int i = 1; i < nfr; i++) {
        double d = energy[i] - energy[i - 1];
        flux[i] = d > 0 ? d : 0;
    }

    int hist = (int)(HIST_SEC * au->rate / hop); // ~43 кадра
    if (hist < 8) hist = 8;
    double *tmp = malloc((size_t)hist * sizeof(double));
    double *win = malloc((size_t)hist * sizeof(double));
    if (!tmp || !win) { free(energy); free(flux); free(tmp); free(win); return NULL; }

    // p95 flux для нормировки силы
    double *all = malloc((size_t)nfr * sizeof(double));
    memcpy(all, flux, (size_t)nfr * sizeof(double));
    qsort(all, (size_t)nfr, sizeof(double), cmp_double);
    double p95 = all[(size_t)(nfr * 0.95)];
    free(all);
    if (p95 < 1e-9) { free(energy); free(flux); free(tmp); free(win); return NULL; } // тишина

    double k = 2.0 / sens; // sens=1 -> порог 2x медианы; sens=2 -> 1x (больше ударов)
    int gap_fr = (int)(min_gap_sec * au->rate / hop);
    if (gap_fr < 1) gap_fr = 1;

    Hit *hits = NULL;
    size_t nh = 0, cap = 0;
    int last_hit = -gap_fr * 2;
    for (int i = 1; i < nfr - 1; i++) {
        int w0 = i - hist;
        if (w0 < 0) w0 = 0;
        int wn = 0;
        for (int j = w0; j < i; j++) win[wn++] = flux[j];
        double med = median_of(win, wn, tmp);
        double thr = med * k;
        if (thr < p95 * 0.02) thr = p95 * 0.02; // пол: не стучать по шуму/тишине
        if (energy[i] < SILENCE_E) continue;
        if (flux[i] > thr && flux[i] >= flux[i - 1] && flux[i] >= flux[i + 1] &&
            i - last_hit >= gap_fr) {
            double s = (flux[i] - thr) / (p95 - thr);
            if (s < 0) s = 0;
            if (s > 1) s = 1;
            if (nh == cap) {
                cap = cap ? cap * 2 : 256;
                hits = realloc(hits, cap * sizeof(Hit));
                if (!hits) break;
            }
            hits[nh++] = (Hit){ (double)((size_t)i * hop) / au->rate + tshift, s };
            last_hit = i;
            if (max_hits > 0 && (long)nh >= max_hits) break;
        }
    }
    free(energy); free(flux); free(tmp); free(win);
    *nhits_out = nh;
    return hits;
}

/* Живой сдвиг: GUI пишет миллисекунды в файл, движок перечитывает
 * его перед каждым ударом — подгонка синхрона в реальном времени.
 * Без --offset-file используется статичный --offset-ms. */
static const char *g_offset_file = NULL;
static double g_offset_static_ms = 0;
static double g_offset_cache_ms = 0;

static double live_offset_sec(void) {
    if (!g_offset_file) return g_offset_static_ms / 1000.0;
    FILE *f = fopen(g_offset_file, "r");
    if (f) {
        double v = 0;
        if (fscanf(f, "%lf", &v) == 1) {
            if (v < -1000) v = -1000;
            if (v > 1000) v = 1000;
            g_offset_cache_ms = v;
        }
        fclose(f);
    }
    return g_offset_cache_ms / 1000.0;
}

/* ---------- время ---------- */

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void sleep_until(double deadline) {
    double dt = deadline - now_sec();
    if (dt <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)dt;
    ts.tv_nsec = (long)((dt - ts.tv_sec) * 1e9);
    nanosleep(&ts, NULL);
}

/* ---------- CLI ---------- */

static void usage(const char *prog) {
    fprintf(stderr,
        "Использование: %s file.mp3 [опции]   (mp3/m4a/aiff/flac/wav)\n"
        "\n"
        "  -g, --gain GAIN         громкость: множитель силы 0.10..2.00 (по умолч. 1.00)\n"
        "  -s, --sens SENS         чуйка детектора 0.50..2.00 (по умолч. 1.00):\n"
        "                          больше = ловит больше тихих битов\n"
        "  --min-gap MS            минимальная пауза между ударами, мс (по умолч. 90)\n"
        "  --max-hits N            ограничить число ударов (0 = без лимита)\n"
        "  --offset-ms MS        сдвиг вибрации относительно звука, мс -1000..1000 (по умолч. 0)\n"
        "  --offset-file PATH    живой сдвиг: перечитывать мс из файла перед каждым ударом\n"
        "  --device-offset N     оффсет ID устройства (по умолч. 64, обычно не нужен)\n"
        "  --immediate             без паузы «старт через 1 сек» (для запуска из GUI)\n"
        "  -n, --dry-run           только показать биты, без вибрации\n"
        "  --info                  только анализ и статистика, не играть\n"
        "  -v, --verbose           печатать каждый удар\n"
        "  -d, --device ID         ID multitouch-устройства (по умолч. авто)\n"
        "  -h, --help              эта справка\n"
        "\n"
        "Примеры:\n"
        "  %s song.mp3\n"
        "  %s song.mp3 -s 1.5 -g 1.3 --dry-run\n"
        "\n"
        "ВАЖНО: во время воспроизведения держи палец на трекпаде.\n",
        prog, prog, prog);
}

int main(int argc, char *argv[]) {
    double gain = 1.0, sens = 1.0;
    double min_gap_ms = 90.0;
    long max_hits = 0;
    double offset_ms = 0;
    const char *offset_file = NULL;
    int immediate = 0;
    int dry_run = 0, verbose = 0, info_only = 0;
    int64_t deviceID = -1;
    const char *in_path = NULL;

    static struct option long_opts[] = {
        {"gain", required_argument, 0, 'g'},
        {"sens", required_argument, 0, 's'},
        {"min-gap", required_argument, 0, 1001},
        {"max-hits", required_argument, 0, 1002},
        {"offset-ms", required_argument, 0, 1004},
        {"offset-file", required_argument, 0, 1005},
        {"immediate", no_argument, 0, 1006},
        {"device-offset", required_argument, 0, 1007},
        {"dry-run", no_argument, 0, 'n'},
        {"info", no_argument, 0, 1003},
        {"verbose", no_argument, 0, 'v'},
        {"device", required_argument, 0, 'd'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "g:s:nvd:h", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'g':
            gain = atof(optarg);
            if (gain < 0.10 || gain > 2.0) { fprintf(stderr, "error: --gain 0.10..2.00\n"); return 1; }
            break;
        case 's':
            sens = atof(optarg);
            if (sens < 0.50 || sens > 2.0) { fprintf(stderr, "error: --sens 0.50..2.00\n"); return 1; }
            break;
        case 1001:
            min_gap_ms = atof(optarg);
            if (min_gap_ms < 20 || min_gap_ms > 1000) { fprintf(stderr, "error: --min-gap 20..1000\n"); return 1; }
            break;
        case 1002:
            max_hits = atol(optarg);
            if (max_hits < 0) { fprintf(stderr, "error: --max-hits >= 0\n"); return 1; }
            break;
        case 1004:
            offset_ms = atof(optarg);
            if (offset_ms < -1000 || offset_ms > 1000) { fprintf(stderr, "error: --offset-ms -1000..1000\n"); return 1; }
            break;
        case 1005:
            offset_file = optarg;
            break;
        case 1006:
            immediate = 1;
            break;
        case 1007: {
            long v = atol(optarg);
            if (v < 0 || v > 512) { fprintf(stderr, "error: --device-offset 0..512\n"); return 1; }
            g_mt_offset = v;
            g_offset_given = 1;
            break;
        }
        case 'n': dry_run = 1; break;
        case 1003: info_only = 1; break;
        case 'v': verbose = 1; break;
        case 'd': deviceID = atoll(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }
    if (optind < argc) in_path = argv[optind];
    if (!in_path) { usage(argv[0]); return 1; }

    if (load_mt() != 0) return 1;

    if (!info_only && !dry_run && deviceID == -1) {
        deviceID = find_trackpad_device_id(0);
        if (deviceID == -1) {
            fprintf(stderr, "error: Taptic Engine не найден. Нужен макбук с Force Touch трекпадом.\n");
            return 1;
        }
        printf("Устройство (Taptic Engine): %" PRId64 "\n", deviceID);
    }

    int is_temp = 0;
    char *wav_path = to_analysis_wav(in_path, &is_temp);
    if (!wav_path) return 1;

    Audio au;
    if (read_wav_mono16(wav_path, &au) != 0) {
        if (is_temp) { unlink(wav_path); free(wav_path); }
        return 1;
    }
    if (is_temp) { unlink(wav_path); free(wav_path); }

    size_t nhits = 0;
    Hit *hits = detect_hits(&au, sens, min_gap_ms / 1000.0, max_hits,
                            0.0, &nhits);

    printf("Файл: %s  (%.1f c, %d Гц)\n", in_path, au.duration, au.rate);
    printf("Битов: %zu (%.1f уд/с), sens=%.2f, gain x%.2f, offset %+.0f мс%s\n",
           nhits, au.duration > 0 ? nhits / au.duration : 0, sens, gain, offset_ms,
           offset_file ? " (+ живой файл)" : "");
    if (offset_file) printf("Live-сдвиг из: %s\n", offset_file);
    if (nhits == 0) {
        fprintf(stderr, "warn: биты не найдены — попробуй -s 1.5..2.0\n");
        free(au.pcm);
        free(hits);
        return 0;
    }

    if (info_only) { free(au.pcm); free(hits); return 0; }
    g_offset_static_ms = offset_ms;
    g_offset_file = offset_file;
    if (dry_run) {
        printf("--- DRY RUN (без вибрации) ---\n");
        fflush(stdout);
    } else {
        if (!immediate) {
            printf("Положи палец на трекпад! Старт через 1 сек...\n");
            fflush(stdout);
            sleep(1);
        }
        // Маркер для GUI: движок готов, дальше шкала t0 — звук можно стартовать.
        printf("READY\n");
        fflush(stdout);
    }

    // при сухом прогоне показываем все биты сразу, без ожидания
    if (dry_run || verbose) {
        for (size_t i = 0; i < nhits; i++) {
            double s = hits[i].strength * gain;
            if (s > 1) s = 1;
            int w = map_by_strength(s);
            double show_t = hits[i].time + (offset_file ? 0.0 : offset_ms / 1000.0);
            printf("[%7.2f] сила=%.2f -> wave %d (%s)\n",
                   show_t, s, w, waveform_name(w));
        }
        fflush(stdout);
    }
    if (dry_run) { printf("\nDry-run завершён: %zu ударов\n", nhits); free(au.pcm); free(hits); return 0; }

    sleep(1);
    double t0 = now_sec();
    size_t played = 0, failed = 0;
    for (size_t i = 0; i < nhits; i++) {
        // ждём короткими кусками, перечитывая живой сдвиг, —
        // ползунок синхрона действует прямо во время паузы
        for (;;) {
            double at = t0 + hits[i].time + live_offset_sec();
            double now = now_sec();
            if (now >= at) break;
            double wake = at - now;
            if (wake > 0.05) wake = 0.05;
            sleep_until(now + wake);
        }
        double s = hits[i].strength * gain;
        if (s > 1) s = 1;
        int w = map_by_strength(s);
        IOReturn r = actuate_once(deviceID, w);
        if (r != kIOReturnSuccess) r = actuate_once(deviceID, w);
        if (r == kIOReturnSuccess) played++;
        else { failed++; if (verbose) printf("  !! actuate failed (0x%x)\n", r); }
    }
    printf("\nГотово: сыграно %zu ударов%s\n", played,
           failed ? " (часть не удалась — см. verbose)" : "");

    free(au.pcm);
    free(hits);
    return 0;
}
