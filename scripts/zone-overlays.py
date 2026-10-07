"""Generates the zone map data for the journey map:

  RoadToSixty/ZoneOverlays.lua   every explorable overlay of every zone map,
                                 so zones show fully revealed, and the list
                                 of zones with a mask
  RoadToSixty/ZoneMasks/*.tga    one mask per zone in the zone's shape, so
                                 neighbouring zones' art can show side by side

Reads the client's tables and files from wago.tools for a Forever build:
  UiMapXMapArt         uiMap -> map art
  UiMapArt             map art -> highlight file (the zone's shape, lit on
                       the continent map under the cursor)
  WorldMapOverlay      overlays per map art: size and offset in art pixels
  WorldMapOverlayTile  256x256 file pieces of each overlay, by row and column

The highlight files hold the shape only in their colour (alpha is solid), so
they cannot mask as they are; each is turned into a white TGA with the shape
in its alpha. Needs Pillow (pip install pillow) to read the BLP files.

Usage: python scripts/zone-overlays.py [build]   (default below)
"""
import csv
import io
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageOps

BUILD = sys.argv[1] if len(sys.argv) > 1 else "1.60.1.70245"
TILE = 256
ADDON = Path(__file__).resolve().parent.parent / "RoadToSixty"
OUT = ADDON / "ZoneOverlays.lua"
MASKS = ADDON / "ZoneMasks"
CONTINENTS = {"1414", "1415"}   # Kalimdor, Eastern Kingdoms
ZONE = "3"                      # UiMap type

# Masks are saved MASK_SIZE pixels square: the highlight scaled to MASK_INNER
# with MASK_PAD empty pixels around it, so a shape reaching the highlight's
# edge can still grow and soften past it. The shapes are soft, so small
# masks lose nothing and keep the addon small. The shape is the highlight
# brighter than MASK_CUT of its brightest pixel, closed by MASK_CLOSE[zone]
# where a highlight leaves out part of the zone (Loch Modan's lake), holes
# filled, grown by MASK_GROW, as the highlights sit inside the zone's border
# and would leave gaps between zones, then softened by MASK_SOFT. Sizes are
# in saved pixels; the work is done at WORK_SCALE times that.
MASK_SIZE, MASK_INNER, MASK_PAD = 64, 48, 8
WORK_SCALE = 2
MASK_CUT = 0.3
MASK_CLOSE = {1432: 10}
MASK_GROW = 4
MASK_SOFT = 2

# ZoneMasks/edge.tga, stretched over each zone's art: solid, but clear for
# the outer EDGE_CLEAR of each side and fading in until EDGE_SOLID, to hide
# the burnt edge and torn frames zone maps have. Shares of the art's size.
EDGE_SIZE = 128
EDGE_CLEAR, EDGE_SOLID = 0.02, 0.09


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "RoadToSixty zone map generator"})
    with urllib.request.urlopen(req) as resp:
        return resp.read()


def table(name):
    data = fetch(f"https://wago.tools/db2/{name}/csv?build={BUILD}")
    return list(csv.DictReader(io.StringIO(data.decode("utf-8"))))


def overlays(maps_by_art):
    tiles = defaultdict(dict)
    for row in table("WorldMapOverlayTile"):
        tiles[row["WorldMapOverlayID"]][(int(row["RowIndex"]), int(row["ColIndex"]))] = int(row["FileDataID"])

    per_map = defaultdict(list)
    for o in table("WorldMapOverlay"):
        maps = maps_by_art.get(o["UiMapArtID"])
        if not maps:
            continue  # art no map uses
        w, h = int(o["TextureWidth"]), int(o["TextureHeight"])
        across, down = -(-w // TILE), -(-h // TILE)
        pieces = tiles[o["ID"]]
        ids = [pieces.get((r, c), 0) for r in range(down) for c in range(across)]
        if 0 in ids:
            print(f"overlay {o['ID']}: missing pieces, skipped", file=sys.stderr)
            continue
        entry = (w, h, int(o["OffsetX"]), int(o["OffsetY"]), ids)
        for m in maps:
            per_map[m].append(entry)
    return per_map


def mask_shape(highlight, zone):
    """The mask alpha for a zone's highlight image, MASK_SIZE pixels square."""
    s = WORK_SCALE
    grey = highlight.convert("RGB").convert("L").resize((MASK_INNER * s, MASK_INNER * s), Image.LANCZOS)
    cut = MASK_CUT * (grey.getextrema()[1] or 1)
    shape = ImageOps.expand(grey.point(lambda v: 255 if v >= cut else 0), MASK_PAD * s, fill=0)
    close = MASK_CLOSE.get(zone)
    if close:
        shape = shape.filter(ImageFilter.MaxFilter(2 * close * s + 1))
        shape = shape.filter(ImageFilter.MinFilter(2 * close * s + 1))
    # Fill holes: whatever a flood from the blank corner misses is inside.
    ImageDraw.floodfill(shape, (0, 0), 128)
    shape = shape.point(lambda v: 0 if v == 128 else 255)
    shape = shape.filter(ImageFilter.MaxFilter(2 * MASK_GROW * s + 1))
    shape = shape.filter(ImageFilter.GaussianBlur(MASK_SOFT * s))
    return shape.resize((MASK_SIZE, MASK_SIZE), Image.LANCZOS)


def edge_mask():
    """Alpha for edge.tga: solid in the middle, fading out towards every side."""
    def ramp(d):
        t = min(1, max(0, (d / EDGE_SIZE - EDGE_CLEAR) / (EDGE_SOLID - EDGE_CLEAR)))
        return t * t * (3 - 2 * t)
    alpha = Image.new("L", (EDGE_SIZE, EDGE_SIZE))
    alpha.putdata([
        round(255 * min(ramp(x + 0.5), ramp(EDGE_SIZE - x - 0.5), ramp(y + 0.5), ramp(EDGE_SIZE - y - 0.5)))
        for y in range(EDGE_SIZE) for x in range(EDGE_SIZE)
    ])
    return alpha


def masks(maps_by_art):
    """Writes the edge mask and a mask per zone with a highlight file; returns
    the uiMap IDs of the zone masks."""
    zones = {r["ID"] for r in table("UiMap") if r["Type"] == ZONE and r["ParentUiMapID"] in CONTINENTS}
    highlight = {r["ID"]: int(r["HighlightFileDataID"]) for r in table("UiMapArt")}
    MASKS.mkdir(exist_ok=True)
    for old in MASKS.glob("*.tga"):
        old.unlink()
    edge = Image.new("RGBA", (EDGE_SIZE, EDGE_SIZE), (255, 255, 255, 0))
    edge.putalpha(edge_mask())
    edge.save(MASKS / "edge.tga")
    done = []
    for art, maps in sorted(maps_by_art.items()):
        file_id = highlight.get(art, 0)
        for m in maps:
            if str(m) not in zones or not file_id:
                continue
            image = Image.open(io.BytesIO(fetch(f"https://wago.tools/api/casc/{file_id}?version={BUILD}")))
            mask = Image.new("RGBA", (MASK_SIZE, MASK_SIZE), (255, 255, 255, 0))
            mask.putalpha(mask_shape(image, m))
            mask.save(MASKS / f"{m}.tga")
            done.append(m)
    return sorted(done)


def main():
    maps_by_art = defaultdict(list)
    for row in table("UiMapXMapArt"):
        maps_by_art[row["UiMapArtID"]].append(int(row["UiMapID"]))

    per_map = overlays(maps_by_art)
    masked = masks(maps_by_art)

    lines = [
        "local _, ns = ...",
        "",
        "-- Zone map data from the client's tables (build " + BUILD + ", via",
        "-- wago.tools). Generated by scripts/zone-overlays.py, do not edit by hand.",
        "",
        "-- Every explorable overlay of each zone map:",
        "-- uiMapID = { { width, height, offsetX, offsetY, fileIDs... }, ... }",
        "-- in map art pixels; fileIDs are 256x256 pieces, row by row.",
        "ns.ZoneOverlayData = {",
    ]
    for m in sorted(per_map):
        lines.append(f"    [{m}] = {{")
        for w, h, x, y, ids in sorted(per_map[m], key=lambda e: (e[3], e[2])):
            lines.append(f"        {{ {w}, {h}, {x}, {y}, {', '.join(map(str, ids))} }},")
        lines.append("    },")
    lines.append("}")
    lines += [
        "",
        "-- Zones with a mask in ZoneMasks\\<uiMapID>.tga: the zone's highlight file",
        "-- with ZoneMaskPad of its size added as empty border on each side.",
        f"ns.ZoneMaskPad = {MASK_PAD} / {MASK_INNER}",
        "ns.ZoneMasks = {",
    ]
    lines += [f"    [{m}] = true," for m in masked]
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    total = sum(len(v) for v in per_map.values())
    print(f"{total} overlays for {len(per_map)} maps, {len(masked)} masks -> {ADDON}")


if __name__ == "__main__":
    main()
