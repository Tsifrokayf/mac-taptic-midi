#!/usr/bin/env python3
"""Синтезирует тестовый трек: щелчки 120bpm + бас-синус + хэт.
Без зависимостей (модуль wave)."""
import math
import struct
import wave

SR = 22050
BPM = 120
BEATS = 8
DUR = BEATS * 60 / BPM  # 4 c

n = int(SR * DUR)
buf = [0.0] * n

# кик: затухающий синус 60 Гц на каждой доле
for b in range(BEATS):
    t0 = int(b * 60 / BPM * SR)
    L = int(0.12 * SR)
    for i in range(L):
        if t0 + i < n:
            env = math.exp(-i / (0.03 * SR))
            buf[t0 + i] += 0.9 * env * math.sin(2 * math.pi * 60 * i / SR)

# хэт: короткий шум на восьмых
import random
random.seed(7)
for b in range(BEATS * 2):
    t0 = int(b * 30 / BPM * SR)
    L = int(0.03 * SR)
    for i in range(L):
        if t0 + i < n:
            buf[t0 + i] += 0.25 * math.exp(-i / (0.008 * SR)) * random.uniform(-1, 1)

# бас-синус 110 Гц тихо фоном
for i in range(n):
    buf[i] += 0.08 * math.sin(2 * math.pi * 110 * i / SR)

peak = max(abs(v) for v in buf)
with wave.open("test_beat.wav", "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(struct.pack("<%dh" % n, *[int(v / peak * 30000) for v in buf]))
print("saved test_beat.wav", DUR, "sec,", BEATS, "kicks")
