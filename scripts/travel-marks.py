"""Draws the red X that marks where a boat or zeppelin landed on the journey
map, as on an adventure film's travel map:

  RoadToSixty/Travel/cross.tga

The colour is baked in rather than tinted in game, so the lit edge keeps its
lighter red. Drawn SCALE times larger and shrunk, for smooth edges. Needs
Pillow (pip install pillow).

Usage: python scripts/travel-marks.py
"""
import math
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "RoadToSixty" / "Travel"
SIZE = 64
SCALE = 4

RED = (0.86, 0.06, 0.05)
DARK = (0.32, 0.0, 0.0)


def render(shade):
    """An RGBA image from shade(x, y) -> (r, g, b, a) or None, with x and y
    from -1 to 1 across the image (y down)."""
    big = SIZE * SCALE
    image = Image.new("RGBa", (big, big))
    pixels = image.load()
    for py in range(big):
        y = (py + 0.5) / big * 2 - 1
        for px in range(big):
            x = (px + 0.5) / big * 2 - 1
            colour = shade(x, y)
            if colour:
                r, g, b, a = colour
                # Premultiplied, so the shrink does not darken the edges.
                pixels[px, py] = tuple(round(min(1, max(0, c)) * a * 255) for c in (r, g, b)) + (round(a * 255),)
    return image.resize((SIZE, SIZE), Image.LANCZOS).convert("RGBA")


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def cross(x, y):
    """Two crossed bars with rounded corners and a dark outline, lit from the
    top left."""
    half_length, half_width, corner = 0.82, 0.2, 0.08
    best = None
    for angle in (math.pi / 4, -math.pi / 4):
        c, s = math.cos(angle), math.sin(angle)
        u, v = x * c + y * s, -x * s + y * c
        # Signed distance to a rounded box.
        qx, qy = abs(u) - half_length + corner, abs(v) - half_width + corner
        outside = math.hypot(max(qx, 0), max(qy, 0))
        dist = outside + min(max(qx, qy), 0) - corner
        best = dist if best is None else min(best, dist)
    outline = 0.06
    if best > outline:
        return None
    if best > 0:
        return DARK + (1,)
    lift = 0.8 + 0.35 * (-(x + y) / 2)
    colour = tuple(c * lift for c in RED)
    # Bevel: lighter near the edge facing the light.
    bevel = max(0, 1 - -best / 0.07)
    colour = mix(colour, mix(RED, (1, 0.55, 0.5), 0.6), bevel * max(0, -(x + y)) * 0.6)
    return colour + (1,)


def main():
    OUT.mkdir(exist_ok=True)
    render(cross).save(OUT / "cross.tga")
    print(f"Wrote {OUT / 'cross.tga'}")


if __name__ == "__main__":
    main()
