#!/usr/bin/env python3
"""Generate the grayscale weather icons used by the Kindle dashboard.

Writes 200x200 8-bit grayscale PNGs into kindle/extensions/rekindle/icons/.
Shapes are drawn at 4x and downsampled for anti-aliased edges.

Usage: python3 tools/make_icons.py   (requires Pillow)
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 200
SCALE = 4
S = SIZE * SCALE
OUT = Path(__file__).resolve().parent.parent / "kindle" / "extensions" / "rekindle" / "icons"

BLACK = 0
WHITE = 255
GRAY = 150


def canvas():
    img = Image.new("L", (S, S), WHITE)
    return img, ImageDraw.Draw(img)


def u(v):
    """Scale a 200-px design coordinate to the supersampled canvas."""
    return int(round(v * SCALE))


def sun(d, cx, cy, r, rays=True):
    if rays:
        for i in range(8):
            a = i * math.pi / 4
            x1, y1 = cx + math.cos(a) * (r + 14), cy + math.sin(a) * (r + 14)
            x2, y2 = cx + math.cos(a) * (r + 34), cy + math.sin(a) * (r + 34)
            d.line([(u(x1), u(y1)), (u(x2), u(y2))], fill=BLACK, width=u(9))
    d.ellipse([u(cx - r), u(cy - r), u(cx + r), u(cy + r)], fill=BLACK)


def moon(d, cx, cy, r):
    d.ellipse([u(cx - r), u(cy - r), u(cx + r), u(cy + r)], fill=BLACK)
    o = r * 0.55
    d.ellipse([u(cx - r + o), u(cy - r - o * 0.5), u(cx + r + o), u(cy + r - o * 0.5)], fill=WHITE)


def cloud(d, x, y, w, fill=BLACK, outline_white=False):
    """Cloud whose bounding box starts at (x, y) with width w (height ~0.55w)."""
    h = w * 0.55
    parts = [
        (x + w * 0.05, y + h * 0.45, x + w * 0.45, y + h * 0.95),
        (x + w * 0.22, y + h * 0.10, x + w * 0.62, y + h * 0.80),
        (x + w * 0.48, y + h * 0.25, x + w * 0.95, y + h * 0.95),
    ]
    base = (x + w * 0.20, y + h * 0.55, x + w * 0.80, y + h * 0.95)
    if outline_white:
        pad = 7
        for (a, b, c, e) in parts:
            d.ellipse([u(a - pad), u(b - pad), u(c + pad), u(e + pad)], fill=WHITE)
        d.rectangle([u(base[0] - pad), u(base[1] - pad), u(base[2] + pad), u(base[3] + pad)], fill=WHITE)
    for (a, b, c, e) in parts:
        d.ellipse([u(a), u(b), u(c), u(e)], fill=fill)
    d.rectangle([u(base[0]), u(base[1]), u(base[2]), u(base[3])], fill=fill)


def drops(d, xs, y, length, width):
    for x in xs:
        d.line([(u(x), u(y)), (u(x - 10), u(y + length))], fill=BLACK, width=u(width))


def flakes(d, points, r):
    for (cx, cy) in points:
        for i in range(3):
            a = i * math.pi / 3
            dx, dy = math.cos(a) * r, math.sin(a) * r
            d.line([(u(cx - dx), u(cy - dy)), (u(cx + dx), u(cy + dy))], fill=BLACK, width=u(6))


def save(img, name):
    img.resize((SIZE, SIZE), Image.LANCZOS).save(OUT / f"{name}.png", optimize=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    img, d = canvas()
    sun(d, 100, 100, 42)
    save(img, "clear-day")

    img, d = canvas()
    moon(d, 100, 100, 62)
    save(img, "clear-night")

    img, d = canvas()
    sun(d, 72, 72, 30)
    cloud(d, 40, 78, 150, outline_white=True)
    save(img, "partly-day")

    img, d = canvas()
    moon(d, 75, 68, 44)
    cloud(d, 40, 78, 150, outline_white=True)
    save(img, "partly-night")

    img, d = canvas()
    cloud(d, 18, 50, 164)
    save(img, "cloudy")

    img, d = canvas()
    cloud(d, 30, 20, 140, fill=GRAY)
    for i, y in enumerate((120, 145, 170)):
        x0 = 25 if i % 2 == 0 else 45
        d.line([(u(x0), u(y)), (u(x0 + 130), u(y))], fill=BLACK, width=u(10))
    save(img, "fog")

    img, d = canvas()
    cloud(d, 18, 12, 164)
    drops(d, (60, 100, 140), 130, 26, 7)
    save(img, "drizzle")

    img, d = canvas()
    cloud(d, 18, 8, 164)
    drops(d, (50, 85, 120, 155), 118, 60, 10)
    save(img, "rain")

    img, d = canvas()
    cloud(d, 18, 8, 164)
    flakes(d, [(55, 140), (100, 165), (145, 140)], 18)
    save(img, "snow")

    # Small charging bolt for the battery gauge (14x22).
    bw, bh = 14, 22
    small = Image.new("L", (bw * SCALE, bh * SCALE), WHITE)
    sd = ImageDraw.Draw(small)
    pts = [(9, 0), (1, 13), (6, 13), (4, 22), (13, 8), (8, 8), (11, 0)]
    sd.polygon([(u(x), u(y)) for (x, y) in pts], fill=BLACK)
    small.resize((bw, bh), Image.LANCZOS).save(OUT / "bolt.png", optimize=True)

    img, d = canvas()
    cloud(d, 18, 8, 164)
    bolt = [(105, 105), (70, 160), (98, 160), (82, 198), (135, 138), (106, 138), (125, 105)]
    d.polygon([(u(x), u(y)) for (x, y) in bolt], fill=BLACK, outline=WHITE)
    save(img, "thunder")

    print(f"wrote icons to {OUT}")


if __name__ == "__main__":
    main()
