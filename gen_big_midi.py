#!/usr/bin/env python3
"""Толстый MIDI для проверки зависания: 3000 нот в один тик.
dry-run такого файла печатает ~225 КБ — больше 64 КБ буфера пайпа."""
import struct

N = 3000
data = b""
data += b"\x00\xff\x51\x03\x07\xa1\x20"  # tempo 120
for i in range(N):
    data += bytes([0x00, 0x90, 21 + (i % 88), 100])  # delta 0, note_on
data += b"\x00\xff\x2f\x00"  # end of track

track = b"MTrk" + struct.pack(">I", len(data)) + data
header = b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480)
with open("test_big.mid", "wb") as f:
    f.write(header + track)
print(f"saved test_big.mid: {N} notes")
