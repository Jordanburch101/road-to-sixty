"""Draws the art of the gear screen's item bars (GearScreen.lua, issue #64),
picked in /rts gearswatch bars:

  RoadToSixty/Gear/flame.tga      streaks of fire along the bar (tiles)
  RoadToSixty/Gear/flare.tga      a soft round glow behind the item's icon
  RoadToSixty/Gear/sparkles.tga   small stars round the icon, fading out
                                  before the edges, so it can turn

All white on transparent, tinted in game with the item's quality colour.
The flame repeats seamlessly along its width. Drawn SCALE times larger and
shrunk, for smooth edges. Needs Pillow.

Usage: python scripts/gear-bar-textures.py
"""
import math
import random
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "RoadToSixty" / "Gear"
SCALE = 4


def clamp(v):
    return max(0.0, min(1.0, v))


def render(width, height, value):
    """value(x, y) -> (r, g, b, a) in 0-1, x across in 0-1, y in -1 (top)
    to 1 (bottom). Returns the image at size."""
    w, h = width * SCALE, height * SCALE
    image = Image.new("RGBA", (w, h))
    pixels = image.load()
    for py in range(h):
        y = (py + 0.5) / h * 2 - 1
        for px in range(w):
            r, g, b, a = value((px + 0.5) / w, y)
            pixels[px, py] = (round(255 * clamp(r)), round(255 * clamp(g)), round(255 * clamp(b)), round(255 * clamp(a)))
    return image.resize((width, height), Image.LANCZOS)


def save(name, image):
    image.save(OUT / f"{name}.tga")
    print(f"Wrote {OUT / name}.tga")


def grey(v, a=1.0):
    return (v, v, v, a)


# Noise that repeats along x: a sum of sines with whole cycles across.
def tiling_noise(seed, octaves=5, base=3):
    rng = random.Random(seed)
    waves = []
    for o in range(octaves):
        for _ in range(3):
            waves.append((base * (2 ** o) + rng.randint(0, base), rng.uniform(0.5, 3) * (o + 1),
                          rng.uniform(0, 2 * math.pi), rng.uniform(0, 2 * math.pi), 0.5 ** o))
    total = sum(w[4] for w in waves)

    def noise(x, y):
        s = 0
        for cycles, fy, px, py, amp in waves:
            s += amp * math.sin(2 * math.pi * cycles * x + px) * math.sin(fy * y * math.pi + py)
        return 0.5 + 0.5 * s / total
    return noise



def flame():
    a1, a2 = tiling_noise(7, octaves=4, base=3), tiling_noise(8, octaves=4, base=5)

    def value(x, y):
        n = a1(x, y * 3) * 0.6 + a2(x, y * 5) * 0.4
        core = math.exp(-(y / 0.35) ** 2)
        tongues = clamp((n - 0.45) * 3) * math.exp(-(y / 0.75) ** 2)
        return grey(1, clamp(core * 0.7 + tongues * 0.8))
    save("flame", render(256, 32, value))


def flare():
    def value(x, y):
        dx, dy = x * 2 - 1, y
        d = math.hypot(dx, dy)
        # Round and soft, gone before the edges: a star's arms here made a
        # plus round every icon.
        glow = 0.75 * math.exp(-(d / 0.42) ** 2) + 0.25 * math.exp(-(d / 0.15) ** 2)
        return grey(1, clamp(glow * clamp((1 - d) / 0.2)))
    save("flare", render(64, 64, value))


def sparkle_ring(name, seed, count):
    """Small four-point stars scattered round the middle, fading out well
    before the edges, so it can turn behind an icon without showing corners."""
    rng = random.Random(seed)
    stars = []
    for k in range(count):
        # Evenly round the circle, each nudged a little, at alternating depths.
        angle = 2 * math.pi * (k + rng.uniform(-0.3, 0.3)) / count
        radius = (0.42 if k % 2 else 0.68) + rng.uniform(-0.08, 0.08)
        stars.append((math.cos(angle) * radius, math.sin(angle) * radius, rng.uniform(0.6, 1.2), rng.uniform(0.5, 1)))

    def value(x, y):
        dx, dy = x * 2 - 1, y
        a = 0
        for sx, sy, size, bright in stars:
            ex, ey = (dx - sx) / size, (dy - sy) / size
            d = math.hypot(ex, ey)
            spike = math.exp(-abs(ex) / 0.012) * math.exp(-abs(ey) / 0.07) + math.exp(-abs(ey) / 0.012) * math.exp(-abs(ex) / 0.07)
            a += bright * (math.exp(-(d / 0.025) ** 2) + 0.7 * spike + 0.25 * math.exp(-(d / 0.06) ** 2))
        r = math.hypot(dx, dy)
        fade = clamp((0.92 - r) / 0.25)
        return grey(1, clamp(a) * fade)
    save(name, render(128, 128, value))


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    flame()
    flare()
    sparkle_ring("sparkles", 62, 11)
