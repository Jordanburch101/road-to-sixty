"""Draws the portals that may replace the hearthstone and teleport lines on
the journey map, one at each end of the jump:

  RoadToSixty/Travel/portal-swirl.tga  three spiral arms, brightest near the rim
  RoadToSixty/Travel/portal-rim.tga    a glowing ring
  RoadToSixty/Travel/portal-hole.tga   a disc fading out at its edge, drawn dark
  RoadToSixty/Travel/portal-glow.tga   a soft round glow, for flares

Each is white on transparent and tinted in game; the swirl is spun with
SetRotation. Drawn SCALE times larger and shrunk, for smooth edges. Needs
Pillow.

Usage: python scripts/portal-textures.py
"""
import math
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "RoadToSixty" / "Travel"
SIZE = 64
SCALE = 4


def save(name, value):
    """value(r, theta) -> 0-1 alpha, r from the centre (1 at the edge)."""
    s = SIZE * SCALE
    alpha = Image.new("L", (s, s))
    pixels = alpha.load()
    for py in range(s):
        y = (py + 0.5) / s * 2 - 1
        for px in range(s):
            x = (px + 0.5) / s * 2 - 1
            r = math.hypot(x, y)
            v = value(r, math.atan2(y, x)) if r < 1 else 0.0
            pixels[px, py] = round(255 * max(0.0, min(1.0, v)))
    alpha = alpha.resize((SIZE, SIZE), Image.LANCZOS)
    image = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    image.putalpha(alpha)
    image.save(OUT / f"{name}.tga")
    print(f"Wrote {OUT / name}.tga")


def swirl(r, theta):
    # Arms curl inwards; the twist makes them spirals rather than spokes.
    arms = (0.5 + 0.5 * math.cos(3 * theta + 11 * r)) ** 5
    envelope = math.sin(math.pi * min(1.0, r / 0.92)) ** 0.7
    return arms * envelope * (0.35 + 0.65 * r)


def rim(r, _):
    return math.exp(-((r - 0.78) / 0.09) ** 2) + 0.35 * math.exp(-((r - 0.78) / 0.25) ** 2)


def hole(r, _):
    # Solid in the middle, softening towards the rim.
    return 1 - max(0.0, (r - 0.55) / 0.3) ** 1.5 if r < 0.85 else 0.0


def glow(r, _):
    return (1 - r) ** 2


def main():
    OUT.mkdir(exist_ok=True)
    save("portal-swirl", swirl)
    save("portal-rim", rim)
    save("portal-hole", hole)
    save("portal-glow", glow)


if __name__ == "__main__":
    main()
