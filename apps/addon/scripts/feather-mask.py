"""Draws the soft-edged masks Map.lua and ZoneArt.lua stretch over map art, in
RoadToSixty/Gaps/: solid in the middle, clear for the outer CLEAR of each
side and fading in until SOLID (shares of the art's size), the same smooth
ramp as Road to Sixty's ZoneMasks/edge.tga (apps/addon/scripts/
zone-overlays.py), which clears 2% and is solid from 9%:

  feather.tga  1% to 20%: each continent's art over the world map, so its
               rectangle, frame and painted sea fade out instead of ending
               in a straight line (OpenMap feathers its continents about as
               far, its MapFeatherWide); and each zone's painting round its
               own land, so its darkened edge is gone before the gap paper
  rim.tga      3.5% to 9%: each zone's own land where it reaches its map's
               edge. Zone maps' burnt frames run 1.6% to 8% in (Elwynn's
               top 2.1%, Duskwood's 8%) and darken a little past that;
               through edge.tga the rest of Elwynn's top frame showed as a
               line, burnt notches and all, where Elwynn meets the gap north
               of Stormwind (Jordan, 2026-10-23)

Usage: python scripts/feather-mask.py   (needs Pillow)
"""

from pathlib import Path

from PIL import Image

SIZE = 256
MASKS = {"feather": (0.01, 0.2), "rim": (0.035, 0.09)}

OUT = Path(__file__).resolve().parent.parent / "RoadToSixty" / "Gaps"


def mask(clear, solid):
    def ramp(d):
        t = min(1, max(0, (d / SIZE - clear) / (solid - clear)))
        return t * t * (3 - 2 * t)
    alpha = Image.new("L", (SIZE, SIZE))
    alpha.putdata([
        round(255 * min(ramp(x + 0.5), ramp(SIZE - x - 0.5), ramp(y + 0.5), ramp(SIZE - y - 0.5)))
        for y in range(SIZE) for x in range(SIZE)
    ])
    image = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    image.putalpha(alpha)
    return image


def main():
    OUT.mkdir(exist_ok=True)
    for name, (clear, solid) in MASKS.items():
        mask(clear, solid).save(OUT / f"{name}.tga")
        print(f"wrote {name}.tga")


if __name__ == "__main__":
    main()
