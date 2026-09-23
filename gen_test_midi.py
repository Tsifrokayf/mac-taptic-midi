#!/usr/bin/env python3
"""Генерирует тестовые MIDI-файлы без внешних зависимостей (чистый struct)."""
import struct

def vlq(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    # старший байт первый, у всех кроме последнего бит 0x80
    res = bytes(reversed(out))
    # поправить continuation bits: у всех кроме последнего должен стоять 0x80
    res = bytes((b | 0x80) if i < len(res) - 1 else (b & 0x7F)
                for i, b in enumerate(res))
    return res

def make_track(events):
    """events: list of (delta_ticks, bytes)"""
    data = b""
    for delta, payload in events:
        data += vlq(delta) + payload
    return b"MTrk" + struct.pack(">I", len(data)) + data

def save(path, tracks, division=480, fmt=1):
    header = b"MThd" + struct.pack(">IHHH", 6, fmt, len(tracks), division)
    with open(path, "wb") as f:
        f.write(header)
        for t in tracks:
            f.write(t)
    print(f"saved {path}")

TEMPO_120 = bytes([0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])  # 500000 us/q
TEMPO_140 = bytes([0xFF, 0x51, 0x03, 0x06, 0x8A, 0x1B])  # ~428571 us/q
END = bytes([0xFF, 0x2F, 0x00])

def note_on(ch, note, vel):
    return bytes([0x90 | ch, note, vel])

def note_off(ch, note):
    return bytes([0x80 | ch, note, 0x40])

# --- test1: гамма C мажор, 8 нот с растущей velocity ---
ev = [(0, TEMPO_120)]
notes = [60, 62, 64, 65, 67, 69, 71, 72]
vels = [40, 55, 70, 85, 95, 105, 115, 127]
for i, (n, v) in enumerate(zip(notes, vels)):
    ev.append((0 if i == 0 else 480, note_on(0, n, v)))
    ev.append((480, note_off(0, n)))
ev.append((0, END))
save("test_scale.mid", [make_track(ev)])

# --- test2: аккорды + смена темпа + барабаны на 10 канале ---
ev2 = [(0, TEMPO_120)]
# C major chord
for n in (60, 64, 67):
    ev2.append((0, note_on(0, n, 90)))
ev2.append((960, note_off(0, 60)))
ev2.append((0, note_off(0, 64)))
ev2.append((0, note_off(0, 67)))
ev2.append((0, TEMPO_140))  # ускорение
for n in (65, 69, 72):
    ev2.append((0, note_on(0, n, 110)))
ev2.append((960, note_off(0, 65)))
ev2.append((0, note_off(0, 69)))
ev2.append((0, note_off(0, 72)))
ev2.append((0, END))

# барабаны: kick-hat-snare-hat
dr = []
for i, (n, v) in enumerate([(36, 120), (42, 60), (38, 110), (42, 60),
                            (36, 120), (42, 60), (38, 110), (46, 80)]):
    dr.append((0 if i == 0 else 240, note_on(9, n, v)))
    dr.append((120, note_off(9, n)))
dr.append((0, END))
save("test_chords_drums.mid", [make_track(ev2), make_track(dr)])
