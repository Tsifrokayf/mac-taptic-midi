#!/usr/bin/env python3
"""Рисует иконку приложения (тёмный сквиркл + оранжевые вибро-бары) без зависимостей.
Выход: MidiHapticApp.iconset/ с PNG всех размеров для iconutil.
"""
import binascii
import os
import struct
import zlib

SIZE = 512
OUT = "MidiHapticApp.iconset"

BG_TOP = (58, 58, 63)
BG_BOT = (22, 22, 26)
ACCENT = (255, 159, 10)
MARGIN = 30
RADIUS = 118


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def render(size):
    s = SIZE / size  # масштаб из базовых координат
    rows = []
    # бары в базовых координатах 512
    widths, gap = 46, 30
    heights = [190, 300, 390, 300, 190]
    total_w = 5 * widths + 4 * gap
    x0 = (SIZE - total_w) / 2
    bars = []
    for i, h in enumerate(heights):
        cx = x0 + i * (widths + gap) + widths / 2
        y0 = (SIZE - h) / 2
        bars.append((cx, y0, y0 + h))
    hw = widths / 2

    for y in range(size):
        row = []
        by = (y + 0.5) * s  # базовая координата центра пикселя
        for x in range(size):
            bx = (x + 0.5) * s
            # скруглённый фон: дистанция до угловых центров
            qx = MARGIN + RADIUS if bx < MARGIN + RADIUS else (SIZE - MARGIN - RADIUS if bx > SIZE - MARGIN - RADIUS else bx)
            qy = MARGIN + RADIUS if by < MARGIN + RADIUS else (SIZE - MARGIN - RADIUS if by > SIZE - MARGIN - RADIUS else by)
            dx, dy = bx - qx, by - qy
            inside_bg = (MARGIN <= bx <= SIZE - MARGIN and MARGIN <= by <= SIZE - MARGIN
                         and dx * dx + dy * dy <= RADIUS * RADIUS)
            if not inside_bg:
                row.append((0, 0, 0, 0))
                continue
            t = by / SIZE
            r = int(BG_TOP[0] + (BG_BOT[0] - BG_TOP[0]) * t)
            g = int(BG_TOP[1] + (BG_BOT[1] - BG_TOP[1]) * t)
            b = int(BG_TOP[2] + (BG_BOT[2] - BG_TOP[2]) * t)
            # бары-капсулы
            for (ccx, y0, y1) in bars:
                # расстояние до вертикального отрезка [y0+hw, y1-hw]
                seg = min(max(by, y0 + hw), y1 - hw)
                ddx, ddy = bx - ccx, by - seg
                if ddx * ddx + ddy * ddy <= hw * hw and y0 <= by <= y1:
                    r, g, b = ACCENT
                    break
            row.append((r, g, b, 255))
        rows.append(row)
    return rows


def write_png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for (r, g, b, a) in row:
            raw += bytes((r, g, b, a))
    comp = zlib.compress(bytes(raw), 9)

    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", binascii.crc32(typ + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", comp)
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def downscale(rows, dim):
    h, w = len(rows), len(rows[0])
    f = w // dim
    out = []
    for y in range(dim):
        orow = []
        for x in range(dim):
            sr = sg = sb = sa = 0
            for dy in range(f):
                for dx in range(f):
                    r, g, b, a = rows[y * f + dy][x * f + dx]
                    sr += r; sg += g; sb += b; sa += a
            n = f * f
            orow.append((sr // n, sg // n, sb // n, sa // n))
        out.append(orow)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    base = render(SIZE)
    targets = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
               (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
               (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
               (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
               (512, "icon_512x512.png")]
    cache = {}
    for dim, name in targets:
        if dim not in cache:
            cache[dim] = base if dim == SIZE else downscale(base, dim)
        write_png(os.path.join(OUT, name), cache[dim])
        print("wrote", name)


if __name__ == "__main__":
    main()
