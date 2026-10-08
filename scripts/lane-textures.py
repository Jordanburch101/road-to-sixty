"""Draws the effects that flow inside the hearthstone and teleport lanes on
the journey map (Routes.lua's ns.SeaLane):

  RoadToSixty/Travel/wisps.tga     soft streaks of arcane light
  RoadToSixty/Travel/sparkles.tga  small four-pointed stars
  RoadToSixty/Travel/vines.tga     two twining strands with leaves

Each is white on transparent, tinted in game, and repeats seamlessly along
its length so the map can scroll it along a lane. Brightness fades towards
the top and bottom edges, so the effect sits inside the lane's band. Drawn
SCALE times larger and shrunk, for smooth edges. Needs Pillow.

Usage: python scripts/lane-textures.py
"""
import math
import random
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "RoadToSixty" / "Travel"
SCALE = 2


def save(name, width, height, value):
    """value(x, y) -> 0-1 alpha, x along the lane in 0-1 (wrapping), y
    across it in -1 to 1."""
    w, h = width * SCALE, height * SCALE
    alpha = Image.new("L", (w, h))
    pixels = alpha.load()
    for py in range(h):
        y = (py + 0.5) / h * 2 - 1
        for px in range(w):
            pixels[px, py] = round(255 * max(0.0, min(1.0, value((px + 0.5) / w, y))))
    alpha = alpha.resize((width, height), Image.LANCZOS)
    image = Image.new("RGBA", (width, height), (255, 255, 255, 0))
    image.putalpha(alpha)
    image.save(OUT / f"{name}.tga")
    print(f"Wrote {OUT / name}.tga")


def band(y, soft=0.75):
    """Fade towards the lane's edges."""
    return max(0.0, 1 - (abs(y) / soft) ** 2) if abs(y) < soft else 0.0


def wisps():
    rng = random.Random(7)
    # Streaks: (brightness repeats, wave repeats, phase, wave phase, centre, amplitude, thickness).
    streaks = [(rng.randint(1, 3), rng.randint(1, 2), rng.random(), rng.random(),
                rng.uniform(-0.35, 0.35), rng.uniform(0.1, 0.3), rng.uniform(0.08, 0.16)) for _ in range(6)]

    def value(x, y):
        v = 0
        for n, m, p, q, c, amp, thick in streaks:
            centre = c + amp * math.sin(2 * math.pi * (m * x + q))
            glow = (0.5 + 0.5 * math.sin(2 * math.pi * (n * x + p))) ** 3
            v += glow * math.exp(-((y - centre) / thick) ** 2)
        return v * band(y)
    save("wisps", 256, 32, value)


def sparkles():
    rng = random.Random(3)
    stars = [(rng.random(), rng.uniform(-0.45, 0.45), rng.uniform(0.6, 1)) for _ in range(9)]

    def value(x, y):
        v = 0
        for sx, sy, s in stars:
            # Distance along the lane, wrapping round the texture's ends;
            # the texture is 4 times as long as it is high.
            dx = ((x - sx + 0.5) % 1 - 0.5) * 4 * 2
            dy = y - sy
            r = math.hypot(dx, dy)
            core = math.exp(-(r / 0.09) ** 2)
            rays = math.exp(-(abs(dx) / 0.025) ** 2) * math.exp(-(abs(dy) / 0.3) ** 2) \
                + math.exp(-(abs(dy) / 0.025) ** 2) * math.exp(-(abs(dx) / 0.3) ** 2)
            v += s * (core + 0.6 * rays)
        return v * band(y, 0.85)
    save("sparkles", 128, 32, value)


def vines():
    def value(x, y):
        v = 0
        for phase in (0, 0.5):
            t = 2 * math.pi * (2 * x + phase)
            centre = 0.45 * math.sin(t)
            # The strand, a little thicker where it crosses the middle.
            v = max(v, math.exp(-((y - centre) / (0.09 + 0.03 * abs(math.cos(t)))) ** 2))
            # A leaf off each crest, pointing outwards.
            for crest in (0.125, 0.375):
                lx = ((x - (crest - phase / 2)) % 0.5) - 0.25
                if abs(lx) < 0.06:
                    side = 1 if math.sin(2 * math.pi * (2 * (crest - phase / 2) + phase)) > 0 else -1
                    ly = y - side * 0.62
                    leaf = math.exp(-(lx / 0.035) ** 2 - (ly / 0.18) ** 2)
                    v = max(v, leaf * 0.9)
        return v * band(y, 0.95)
    save("vines", 256, 32, value)


def main():
    OUT.mkdir(exist_ok=True)
    wisps()
    sparkles()
    vines()


if __name__ == "__main__":
    main()
