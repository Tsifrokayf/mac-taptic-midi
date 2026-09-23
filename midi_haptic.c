/*
 * midi_haptic.c — воспроизведение MIDI-файлов на Taptic Engine макбука (Apple Silicon)
 *
 * Как работает:
 *  - Парсит Standard MIDI File (формат 0/1, без внешних зависимостей)
 *  - Строит временную шкалу note_on событий с учётом tempo-карт
 *  - Каждую ноту отображает в waveform Taptic Engine и дёргает актуатор
 *    через приватный MultitouchSupport.framework
 *
 * Важно для ARM (arm64e): приватный фреймворк грузится через dlopen/dlsym,
 * а не через прямой extern — иначе PAC (pointer authentication) даёт bus error.
 * Подход взят из mactic (MatMercer/mactic, public domain).
 *
 * Waveform ID (эмпирически, прошивка может отличаться):
 *   1 = слабый клик, 2 = сильный клик (Force Touch), 3 = buzz,
 *   4 = лёгкий тап, 5 = средний тап, 6 = сильный тап
 *
 * Сборка: make
 * Использование: ./midi_haptic song.mid [опции]
 *
 * ОБРАТИ ВНИМАНИЕ: Taptic Engine в трекпаде ощущается, только если палец
 * лежит на трекпаде. Положи палец на трекпад перед воспроизведением.
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

/* Оффсет ID устройства в структуре MTDevice: 64 найден эмпирически на
 * M3/Sequoia, но на другом железе (Intel) или macOS может отличаться —
 * тогда срабатывает автоподбор ниже. Переопределяется --device-offset. */
static long g_mt_offset = MTDEVICE_ID_OFFSET;
static int g_offset_given = 0;

/* ---------- приватный фреймворк: динамическая загрузка (ARM-safe) ---------- */

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
    pMTActuatorOpen   = (MTActuatorOpen_t)dlsym(mt_handle, "MTActuatorOpen");
    pMTActuatorClose  = (MTActuatorClose_t)dlsym(mt_handle, "MTActuatorClose");
    pMTActuatorActuate = (MTActuatorActuate_t)dlsym(mt_handle, "MTActuatorActuate");
    pMTDeviceCreateList = (MTDeviceCreateList_t)dlsym(mt_handle, "MTDeviceCreateList");

    if (!pMTActuatorCreateFromDeviceID || !pMTActuatorOpen ||
        !pMTActuatorClose || !pMTActuatorActuate) {
        fprintf(stderr, "error: не нашлись MTActuator-символы (macOS обновилась?)\n");
        return -1;
    }
    return 0;
}

static uint64_t mt_device_get_id_at(void *dev, long offset) {
    uint64_t id = 0;
    memcpy(&id, (uint8_t *)dev + offset, sizeof(id));
    return id;
}

/* ID первого устройства с рабочим актуатором при данном оффсете, -1 если нет. */
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
        if (!act) {
            if (verbose)
                printf("  [%ld] offset %ld: актуатор не создался\n", (long)i, offset);
            continue;
        }
        IOReturn r = pMTActuatorOpen(act, 0);
        if (verbose)
            printf("  [%ld] offset %ld, device ID: %" PRIu64 " (0x%" PRIx64 ") %s\n",
                   (long)i, offset, devID, devID,
                   r == kIOReturnSuccess ? "<- Taptic Engine!" : "(без актуатора)");
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
    if (!pMTDeviceCreateList) {
        fprintf(stderr, "error: MTDeviceCreateList недоступен\n");
        return -1;
    }
    int64_t id = try_offset(g_mt_offset, verbose);
    if (id != -1 || g_offset_given) return id;
    // Оффсет 64 не дал устройства — железо/macOS другие: сканируем 0..248.
    // Неверные ID безопасно отсеиваются (актуатор не открывается).
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

/* ---------- MIDI-парсер (SMF, без зависимостей) ---------- */

typedef struct {
    uint32_t tick;      // абсолютный тик
    uint8_t  note;      // 0..127
    uint8_t  vel;       // 1..127 (0 отфильтрованы)
    uint8_t  ch;        // 0..15
    uint16_t track;     // номер трека
} NoteEvent;

typedef struct {
    uint32_t tick;
    uint32_t us_per_quarter; // темп (микросекунд на четверть), дефолт 500000 = 120bpm
} TempoEvent;

typedef struct {
    NoteEvent  *notes;
    size_t      nnotes, cap_notes;
    TempoEvent *tempos;
    size_t      ntempos, cap_tempos;
    uint16_t    division;   // ticks per quarter
    uint16_t    format;
    uint16_t    ntracks;
} MidiSong;

static void song_free(MidiSong *s) {
    free(s->notes);
    free(s->tempos);
    memset(s, 0, sizeof(*s));
}

static void push_note(MidiSong *s, NoteEvent e) {
    if (s->nnotes == s->cap_notes) {
        s->cap_notes = s->cap_notes ? s->cap_notes * 2 : 1024;
        s->notes = realloc(s->notes, s->cap_notes * sizeof(NoteEvent));
        if (!s->notes) { fprintf(stderr, "error: out of memory\n"); exit(1); }
    }
    s->notes[s->nnotes++] = e;
}

static void push_tempo(MidiSong *s, TempoEvent e) {
    if (s->ntempos == s->cap_tempos) {
        s->cap_tempos = s->cap_tempos ? s->cap_tempos * 2 : 16;
        s->tempos = realloc(s->tempos, s->cap_tempos * sizeof(TempoEvent));
        if (!s->tempos) { fprintf(stderr, "error: out of memory\n"); exit(1); }
    }
    s->tempos[s->ntempos++] = e;
}

static uint16_t rd16be(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t rd32be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* Читает Variable Length Quantity. Возвращает значение, *pos сдвигается. -1 при ошибке. */
static int64_t read_vlq(const uint8_t *data, size_t len, size_t *pos) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        if (*pos >= len) return -1;
        uint8_t b = data[(*pos)++];
        v = (v << 7) | (b & 0x7F);
        if (!(b & 0x80)) return (int64_t)v;
    }
    return -1; // слишком длинный VLQ
}

static int cmp_note_tick(const void *a, const void *b) {
    const NoteEvent *na = a, *nb = b;
    if (na->tick != nb->tick) return na->tick < nb->tick ? -1 : 1;
    if (na->track != nb->track) return na->track < nb->track ? -1 : 1;
    return 0;
}

static int cmp_tempo_tick(const void *a, const void *b) {
    const TempoEvent *ta = a, *tb = b;
    if (ta->tick != tb->tick) return ta->tick < tb->tick ? -1 : 1;
    return 0;
}

/* Парсит один трек. Возвращает 0 при успехе. */
static int parse_track(const uint8_t *data, size_t len, uint16_t track_no, MidiSong *song) {
    size_t pos = 0;
    uint32_t abs_tick = 0;
    uint8_t running = 0;

    while (pos < len) {
        int64_t delta = read_vlq(data, len, &pos);
        if (delta < 0) { fprintf(stderr, "warn: трек %u: битый delta-time\n", track_no); return -1; }
        abs_tick += (uint32_t)delta;
        if (pos >= len) break;

        uint8_t b = data[pos];
        uint8_t status;
        if (b & 0x80) {
            status = b;
            pos++;
        } else {
            if (running == 0) { fprintf(stderr, "warn: трек %u: running status без статуса\n", track_no); return -1; }
            status = running;
        }

        if (status == 0xFF) { // meta
            if (pos + 1 > len) return -1;
            uint8_t type = data[pos++];
            int64_t mlen = read_vlq(data, len, &pos);
            if (mlen < 0 || pos + (size_t)mlen > len) return -1;
            if (type == 0x51 && mlen == 3) { // set tempo
                uint32_t usq = ((uint32_t)data[pos] << 16) |
                               ((uint32_t)data[pos + 1] << 8) |
                               (uint32_t)data[pos + 2];
                if (usq == 0) usq = 500000;
                push_tempo(song, (TempoEvent){ abs_tick, usq });
            } else if (type == 0x2F) { // end of track
                break;
            }
            pos += (size_t)mlen;
            // meta не влияет на running status
        } else if (status == 0xF0 || status == 0xF7) { // sysex
            int64_t slen = read_vlq(data, len, &pos);
            if (slen < 0 || pos + (size_t)slen > len) return -1;
            pos += (size_t)slen;
            running = 0;
        } else {
            uint8_t hi = status & 0xF0;
            uint8_t ch = status & 0x0F;
            running = status;
            if (hi == 0xC0 || hi == 0xD0) { // 1 байт данных
                if (pos + 1 > len) return -1;
                pos += 1;
            } else { // 2 байта данных
                if (pos + 2 > len) return -1;
                uint8_t d0 = data[pos], d1 = data[pos + 1];
                pos += 2;
                if (hi == 0x90) { // note on
                    if (d1 != 0) push_note(song, (NoteEvent){ abs_tick, d0, d1, ch, track_no });
                    // vel==0 это note off по стандарту — игнорируем
                }
                // note off (0x80) и остальное для хаптики не нужно
            }
        }
    }
    return 0;
}

static int parse_midi_file(const char *path, MidiSong *song) {
    memset(song, 0, sizeof(*song));
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "error: не могу открыть '%s': %s\n", path, strerror(errno)); return -1; }
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (fsize < 14) { fclose(f); fprintf(stderr, "error: файл слишком маленький для MIDI\n"); return -1; }
    uint8_t *buf = malloc((size_t)fsize);
    if (!buf) { fclose(f); return -1; }
    if (fread(buf, 1, (size_t)fsize, f) != (size_t)fsize) { fclose(f); free(buf); return -1; }
    fclose(f);

    if (memcmp(buf, "MThd", 4) != 0) {
        fprintf(stderr, "error: нет заголовка MThd — это не Standard MIDI File\n");
        free(buf);
        return -1;
    }
    uint32_t hlen = rd32be(buf + 4);
    if (hlen < 6) { free(buf); fprintf(stderr, "error: битый MThd\n"); return -1; }
    song->format   = rd16be(buf + 8);
    song->ntracks  = rd16be(buf + 10);
    song->division = rd16be(buf + 12);

    if (song->division & 0x8000) {
        fprintf(stderr, "error: SMPTE-тайминг не поддерживается (только ticks/quarter)\n");
        free(buf);
        return -1;
    }
    if (song->division == 0) { free(buf); fprintf(stderr, "error: division=0\n"); return -1; }
    if (song->format == 2) {
        fprintf(stderr, "warn: формат 2 (асинхронные паттерны) — играем все треки подряд по тикам\n");
    }

    size_t pos = 8 + hlen;
    uint16_t parsed = 0;
    for (uint16_t t = 0; t < song->ntracks; t++) {
        if (pos + 8 > (size_t)fsize) { fprintf(stderr, "warn: треков меньше, чем заявлено (%u/%u)\n", parsed, song->ntracks); break; }
        if (memcmp(buf + pos, "MTrk", 4) != 0) {
            fprintf(stderr, "warn: чанк %u не MTrk — пропускаю\n", t);
            if (pos + 8 > (size_t)fsize) break;
            uint32_t skip = rd32be(buf + pos + 4);
            pos += 8 + skip;
            continue;
        }
        uint32_t tlen = rd32be(buf + pos + 4);
        if (pos + 8 + tlen > (size_t)fsize) { fprintf(stderr, "warn: трек %u обрезан\n", t); break; }
        parse_track(buf + pos + 8, tlen, t, song);
        pos += 8 + tlen;
        parsed++;
    }
    free(buf);

    if (song->nnotes == 0) {
        fprintf(stderr, "error: note_on событий не найдено (пустой MIDI?)\n");
        return -1;
    }
    qsort(song->notes, song->nnotes, sizeof(NoteEvent), cmp_note_tick);
    if (song->ntempos > 1) qsort(song->tempos, song->ntempos, sizeof(TempoEvent), cmp_tempo_tick);
    return 0;
}

/* ---------- маппинг нот -> waveform ---------- */

typedef enum { MAP_VELOCITY = 0, MAP_PITCH = 1, MAP_DRUMS = 2 } MapMode;

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

/* velocity -> интенсивность удара */
static int map_by_velocity(uint8_t vel) {
    if (vel <= 50)  return 4;
    if (vel <= 85)  return 5;
    if (vel <= 110) return 2;
    return 6;
}

/* pitch -> высота тону в «высоту» тапа (низкие — тяжёлые, высокие — лёгкие) */
static int map_by_pitch(uint8_t note, uint8_t vel) {
    (void)vel;
    if (note < 36) return 2;       // бас — сильный клик
    if (note < 48) return 6;       // низкий регистр — сильный тап
    if (note < 60) return 5;       // средний — средний тап
    if (note < 72) return 4;       // верхняя середина — лёгкий тап
    if (note < 84) return 5;
    return 4;                      // самый верх — лёгкий тап
}

/* барабаны (канал 10, ch==9): kick/snare/hat */
static int map_drums(uint8_t note, uint8_t vel) {
    if (note == 35 || note == 36) return 2;              // kick — сильный клик
    if (note == 38 || note == 40) return 6;              // snare — сильный тап
    if (note >= 42 && note <= 46) return 4;              // hats — лёгкий тап
    if (note >= 49 && note <= 52) return 5;              // crash/ride — средний
    return map_by_velocity(vel);
}

static int map_note(uint8_t note, uint8_t vel, uint8_t ch, MapMode mode) {
    if (mode == MAP_PITCH) return map_by_pitch(note, vel);
    if (mode == MAP_DRUMS) {
        if (ch == 9) return map_drums(note, vel);
        return map_by_velocity(vel);
    }
    return map_by_velocity(vel); // MAP_VELOCITY default
}

static const char *note_name(uint8_t n) {
    static const char *names[] = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};
    static char buf[8];
    snprintf(buf, sizeof(buf), "%s%d", names[n % 12], (int)n / 12 - 1);
    return buf;
}

/* Одно срабатывание со свежим актуатором.
 * Важно: хэндл актуатора одноразовый (single-shot) — после одного Actuate
 * повторные вызовы на том же хэндле возвращают успех, но НЕ вибрируют.
 * Поэтому под каждую ноту создаём новый хэндл (как chain-режим в mactic). */
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

/* Живой сдвиг: GUI пишет миллисекунды в файл, движок перечитывает
 * его перед каждой нотой — подгонка синхрона в реальном времени.
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

/* ---------- точное время ---------- */

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void sleep_until(double deadline) {
    double now = now_sec();
    double dt = deadline - now;
    if (dt <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)dt;
    ts.tv_nsec = (long)((dt - ts.tv_sec) * 1e9);
    nanosleep(&ts, NULL);
}

/* ---------- CLI ---------- */

static void usage(const char *prog) {
    fprintf(stderr,
        "Использование: %s file.mid [опции]\n"
        "\n"
        "  file.mid              MIDI-файл (формат 0/1, .mid/.midi)\n"
        "  -m, --map MODE        velocity (по громкости, по умолч.), pitch (по высоте), drums (барабаны 10 канала отдельно)\n"
        "  -t, --tempo SCALE     множитель темпа (0.25..4.0, по умолч. 1.0). 2.0 = в 2 раза быстрее\n"
        "  -g, --gain GAIN         громкость: множитель velocity 0.10..2.00 (по умолч. 1.00).\n"
        "                          Тише = лёгкие тапы, громче = сильные удары\n"
        "  -c, --channels LIST   каналы 1-16 через запятую или all (по умолч. all). Напр.: 1,10\n"
        "  --min-vel N           игнорировать ноты с velocity < N (1..127, по умолч. 1)\n"
        "  --max-notes N         ограничить число нот (для теста, 0 = без лимита)\n"
        "  --loop N              повторить воспроизведение N раз (1..99, по умолч. 1)\n"
        "  --info                только разобрать файл и показать длительность, не играть\n"
        "  --offset-ms MS        сдвиг вибрации относительно звука, мс -1000..1000 (по умолч. 0)\n"
        "  --offset-file PATH    живой сдвиг: перечитывать мс из файла перед каждой нотой\n"
        "                          (ползунок синхрона в GUI пишет туда — подгонка наживую)\n"
        "  --device-offset N     оффсет ID устройства в структуре (по умолч. 64,\n"
        "                          обычно не нужен — есть автоподбор)\n"
        "  --immediate             без паузы «старт через 1 сек» (для запуска из GUI)\n"
        "  -n, --dry-run         только показать ноты и тайминги, без вибрации\n"
        "  -v, --verbose         подробно печатать каждую ноту\n"
        "  -d, --device ID       ID multitouch-устройства (по умолч. авто)\n"
        "  -s, --scan            показать устройства и выйти\n"
        "  -l, --list            проиграть waveform 1-6 для проверки и выйти\n"
        "  -h, --help            эта справка\n"
        "\n"
        "Примеры:\n"
        "  %s song.mid\n"
        "  %s song.mid -m drums -v\n"
        "  %s song.mid -t 1.5 -c 1,10 --dry-run\n"
        "\n"
        "ВАЖНО: во время воспроизведения держи палец на трекпаде —\n"
        "иначе Taptic Engine не чувствуется (так устроен Force Touch).\n",
        prog, prog, prog, prog);
}

static int parse_channels(const char *s, int mask[16]) {
    for (int i = 0; i < 16; i++) mask[i] = 0;
    if (strcmp(s, "all") == 0) { for (int i = 0; i < 16; i++) mask[i] = 1; return 0; }
    char *copy = strdup(s);
    if (!copy) return -1;
    char *tok = strtok(copy, ",");
    int any = 0;
    while (tok) {
        char *end = NULL;
        long v = strtol(tok, &end, 10);
        if (!end || *end != '\0' || v < 1 || v > 16) { free(copy); return -1; }
        mask[v - 1] = 1;
        any = 1;
        tok = strtok(NULL, ",");
    }
    free(copy);
    return any ? 0 : -1;
}

int main(int argc, char *argv[]) {
    MapMode map_mode = MAP_VELOCITY;
    double tempo_scale = 1.0;
    double gain = 1.0;
    int ch_mask[16];
    for (int i = 0; i < 16; i++) ch_mask[i] = 1;
    int min_vel = 1;
    long max_notes = 0;
    int loop_count = 1;
    int info_only = 0;
    double offset_ms = 0;
    const char *offset_file = NULL;
    int immediate = 0;
    int dry_run = 0, verbose = 0;
    int64_t deviceID = -1;
    int scan_mode = 0, list_mode = 0;
    const char *mid_path = NULL;

    static struct option long_opts[] = {
        {"map", required_argument, 0, 'm'},
        {"tempo", required_argument, 0, 't'},
        {"gain", required_argument, 0, 'g'},
        {"channels", required_argument, 0, 'c'},
        {"min-vel", required_argument, 0, 1001},
        {"max-notes", required_argument, 0, 1002},
        {"loop", required_argument, 0, 1004},
        {"info", no_argument, 0, 1003},
        {"offset-ms", required_argument, 0, 1005},
        {"offset-file", required_argument, 0, 1006},
        {"immediate", no_argument, 0, 1007},
        {"device-offset", required_argument, 0, 1008},
        {"dry-run", no_argument, 0, 'n'},
        {"verbose", no_argument, 0, 'v'},
        {"device", required_argument, 0, 'd'},
        {"scan", no_argument, 0, 's'},
        {"list", no_argument, 0, 'l'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "m:t:c:g:nvd:slh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'm':
            if (strcmp(optarg, "velocity") == 0) map_mode = MAP_VELOCITY;
            else if (strcmp(optarg, "pitch") == 0) map_mode = MAP_PITCH;
            else if (strcmp(optarg, "drums") == 0) map_mode = MAP_DRUMS;
            else { fprintf(stderr, "error: --map должен быть velocity|pitch|drums\n"); return 1; }
            break;
        case 't':
            tempo_scale = atof(optarg);
            if (tempo_scale < 0.25 || tempo_scale > 4.0) {
                fprintf(stderr, "error: --tempo должен быть 0.25..4.0\n"); return 1;
            }
            break;
        case 'g':
            gain = atof(optarg);
            if (gain < 0.10 || gain > 2.0) {
                fprintf(stderr, "error: --gain должен быть 0.10..2.00\n"); return 1;
            }
            break;
        case 'c':
            if (parse_channels(optarg, ch_mask) != 0) {
                fprintf(stderr, "error: --channels: 'all' или список 1-16 через запятую\n"); return 1;
            }
            break;
        case 1001:
            min_vel = atoi(optarg);
            if (min_vel < 1 || min_vel > 127) { fprintf(stderr, "error: --min-vel 1..127\n"); return 1; }
            break;
        case 1002:
            max_notes = atol(optarg);
            if (max_notes < 0) { fprintf(stderr, "error: --max-notes >= 0\n"); return 1; }
            break;
        case 1003:
            info_only = 1;
            break;
        case 1004:
            loop_count = atoi(optarg);
            if (loop_count < 1 || loop_count > 99) { fprintf(stderr, "error: --loop 1..99\n"); return 1; }
            break;
        case 1005:
            offset_ms = atof(optarg);
            if (offset_ms < -1000 || offset_ms > 1000) { fprintf(stderr, "error: --offset-ms -1000..1000\n"); return 1; }
            break;
        case 1006:
            offset_file = optarg;
            break;
        case 1007:
            immediate = 1;
            break;
        case 1008: {
            long v = atol(optarg);
            if (v < 0 || v > 512) { fprintf(stderr, "error: --device-offset 0..512\n"); return 1; }
            g_mt_offset = v;
            g_offset_given = 1;
            break;
        }
        case 'n': dry_run = 1; break;
        case 'v': verbose = 1; break;
        case 'd': deviceID = atoll(optarg); break;
        case 's': scan_mode = 1; break;
        case 'l': list_mode = 1; break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }
    if (optind < argc) mid_path = argv[optind];

    if (load_mt() != 0) return 1;

    if (scan_mode) {
        printf("Сканирую multitouch-устройства...\n");
        int64_t id = find_trackpad_device_id(1);
        if (id == -1) printf("Taptic Engine не найден.\n");
        return 0;
    }

    if (!info_only && (list_mode || (mid_path && !dry_run)) && deviceID == -1) {
        deviceID = find_trackpad_device_id(0);
        if (deviceID == -1) {
            fprintf(stderr, "error: Taptic Engine не найден. Нужен макбук с Force Touch трекпадом.\n");
            return 1;
        }
        printf("Устройство (Taptic Engine): %" PRId64 "\n", deviceID);
    }

    if (list_mode) {
        printf("Проверяю waveform 1-6 (палец на трекпаде!)...\n");
        for (int32_t w = 1; w <= 6; w++) {
            printf("  waveform %d (%s)... ", w, waveform_name(w));
            fflush(stdout);
            IOReturn r = actuate_once(deviceID, w);
            printf("%s\n", r == kIOReturnSuccess ? "ok" : "ОШИБКА");
            usleep(600000);
        }
        if (!mid_path) return 0;
    }

    if (!mid_path) {
        usage(argv[0]);
        return 1;
    }

    MidiSong song;
    if (parse_midi_file(mid_path, &song) != 0) return 1;

    /* фильтрация по каналам и velocity */
    size_t kept = 0;
    for (size_t i = 0; i < song.nnotes; i++) {
        NoteEvent *e = &song.notes[i];
        if (!ch_mask[e->ch]) continue;
        if (e->vel < min_vel) continue;
        if (max_notes > 0 && (long)kept >= max_notes) break;
        song.notes[kept++] = *e;
    }
    song.nnotes = kept;
    if (song.nnotes == 0) {
        fprintf(stderr, "error: после фильтров не осталось нот\n");
        song_free(&song);
        return 1;
    }

    /* перевод тиков в секунды с учётом темпа */
    double *times = malloc(song.nnotes * sizeof(double));
    if (!times) { song_free(&song); return 1; }
    {
        double us_per_tick = 500000.0 / song.division; // дефолтный темп
        size_t ti = 0;
        // tempos уже отсортированы; пропускаем те, что на тике 0
        uint32_t last_tick = 0;
        double last_sec = 0.0;
        // найти темп на тике 0
        for (size_t k = 0; k < song.ntempos; k++) {
            if (song.ntempos > 0 && song.tempos[k].tick == 0) {
                us_per_tick = (double)song.tempos[k].us_per_quarter / song.division;
            }
        }
        // идём по нотам, обновляя темп по мере прохождения tempo-событий
        size_t tempo_idx = 0;
        // пропустить темпы на тике 0 (уже применены)
        while (tempo_idx < song.ntempos && song.tempos[tempo_idx].tick == 0) tempo_idx++;
        for (size_t i = 0; i < song.nnotes; i++) {
            uint32_t tk = song.notes[i].tick;
            while (tempo_idx < song.ntempos && song.tempos[tempo_idx].tick <= tk) {
                uint32_t ttk = song.tempos[tempo_idx].tick;
                last_sec += (ttk - last_tick) * us_per_tick / 1e6;
                last_tick = ttk;
                us_per_tick = (double)song.tempos[tempo_idx].us_per_quarter / song.division;
                tempo_idx++;
            }
            times[i] = (last_sec + (tk - last_tick) * us_per_tick / 1e6) / tempo_scale;
            (void)ti;
        }
    }

    double total = times[song.nnotes - 1];
    const char *mapname = map_mode == MAP_VELOCITY ? "velocity" :
                          map_mode == MAP_PITCH ? "pitch" : "drums";
    printf("Файл: %s  (формат %u, треков %u, division %u)\n",
           mid_path, song.format, song.ntracks, song.division);
    printf("Нот: %zu, длительность: %.1f c, map=%s, tempo x%.2f, gain x%.2f, offset %+.0f мс%s\n",
           song.nnotes, total, mapname, tempo_scale, gain, offset_ms,
           offset_file ? " (+ живой файл)" : "");
    if (offset_file) printf("Live-сдвиг из: %s\n", offset_file);
    if (song.ntempos > 0) {
        printf("Темп-картa: %zu событий", song.ntempos);
        for (size_t k = 0; k < song.ntempos && k < 5; k++)
            printf(" [tick %u: %u bpm]", song.tempos[k].tick,
                   (unsigned)(60000000u / song.tempos[k].us_per_quarter));
        printf("%s\n", song.ntempos > 5 ? " ..." : "");
    }
    if (info_only) {
        fflush(stdout);
        free(times);
        song_free(&song);
        return 0;
    }
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

    size_t played = 0, failed = 0;
    for (int round = 0; round < loop_count; round++) {
        if (loop_count > 1) {
            printf("--- круг %d/%d ---\n", round + 1, loop_count);
            fflush(stdout);
        }
        double t0 = now_sec();
        for (size_t i = 0; i < song.nnotes; i++) {
            NoteEvent *e = &song.notes[i];
            double at = dry_run ? times[i] + offset_ms / 1000.0
                                : times[i] + live_offset_sec();
            if (!dry_run) {
                // ждём короткими кусками, перечитывая живой сдвиг, —
                // ползунок синхрона действует прямо во время паузы
                for (;;) {
                    at = times[i] + live_offset_sec();
                    double now = now_sec();
                    if (now >= t0 + at) break;
                    double wake = t0 + at - now;
                    if (wake > 0.05) wake = 0.05;
                    sleep_until(now + wake);
                }
            }
            int eff = (int)(e->vel * gain + 0.5); // громкость: масштабируем velocity
            if (eff < 1) eff = 1;
            if (eff > 127) eff = 127;
            int w = map_note(e->note, (uint8_t)eff, e->ch, map_mode);
            if (verbose || dry_run) {
                if (gain == 1.0)
                    printf("[%7.2f] ch=%2d note=%3d (%-3s) vel=%3d -> wave %d (%s)\n",
                           at, e->ch + 1, e->note, note_name(e->note),
                           e->vel, w, waveform_name(w));
                else
                    printf("[%7.2f] ch=%2d note=%3d (%-3s) vel=%3d x%.2f->%3d -> wave %d (%s)\n",
                           at, e->ch + 1, e->note, note_name(e->note),
                           e->vel, gain, eff, w, waveform_name(w));
                fflush(stdout);
            }
            if (!dry_run) {
                // свежий актуатор под каждую ноту (single-shot — см. actuate_once)
                IOReturn r = actuate_once(deviceID, w);
                if (r != kIOReturnSuccess) r = actuate_once(deviceID, w); // одна перепроба
                if (r == kIOReturnSuccess) played++;
                else { failed++; if (verbose) printf("  !! actuate failed (0x%x)\n", r); }
            }
        }
    }

    if (!dry_run) {
        printf("\nГотово: сыграно %zu нот%s\n", played,
               failed ? " (часть не удалась — см. verbose)" : "");
    } else {
        printf("\nDry-run завершён: %zu нот\n", song.nnotes);
    }

    free(times);
    song_free(&song);
    return 0;
}
