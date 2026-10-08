"""Generates the zone map data for the journey map:

  RoadToSixty/ZoneOverlays.lua   every explorable overlay of every zone map,
                                 so zones show fully revealed, and the list
                                 of zones with a mask
  RoadToSixty/ZoneMasks/*.tga    one mask per zone in the zone's shape, so
                                 neighbouring zones' art can show side by side,
                                 and city_<uiMapID>.tga for the cities in
                                 CITY_MASKS: where the city's street plan has
                                 drawing, so the zone around shows past it,
                                 and paper.tga, a seamless tile of blank
                                 parchment from Stormwind's plan, for land no
                                 zone map covers

Reads the client's tables and files from wago.tools for a Forever build:
  UiMapXMapArt         uiMap -> map art
  UiMapArt             map art -> highlight file (the zone's shape, lit on
                       the continent map under the cursor)
  WorldMapOverlay      overlays per map art: size and offset in art pixels
  WorldMapOverlayTile  256x256 file pieces of each overlay, by row and column
  UiMapArtTile         256x256 pieces of each map art (city street plans)
  UiMapArtStyleLayer   map art size

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

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps, ImageStat

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

# City street plans whose drawing sits on bare parchment, which would hide
# the zone around the city. The mask keeps the drawing: pixels whose colour
# differs from the parchment (summed over the channels, at CITY_WORK width)
# by more than cut, closed by close to join the districts, holes filled,
# opened by open to drop specks and stray letters, grown by grow, softened
# by soft. band is the burnt edge, never drawing. fill lists boxes (shares
# of the art: x1, y1, x2, y2) kept, such as plain ground between districts
# that would show the zone's art there; clear lists boxes left out, such as
# the title banner the zone around already has. Other cities' plans are drawn edge to edge, so this
# would cut them to pieces; they have no mask.
# ZoneMasks/paper.tga: PAPER_BOX of Stormwind's plan (blank parchment, clear
# of a speck), scaled to PAPER_SIZE square, its slow light and dark taken
# out (PAPER_FLATTEN blur), and blended with a half-tile shifted copy so it
# repeats without seams.
PAPER_CITY, PAPER_BOX, PAPER_SIZE, PAPER_FLATTEN = 1453, (910, 520, 990, 600), 256, 40

CITY_WORK = 250
CITY_SIZE = 256
CITY_MASKS = {
    # Stormwind: the canal and wall between the harbour and the districts.
    1453: dict(cut=120, close=9, open=6, grow=2, soft=3, band=6,
               fill=[(0.26, 0.1, 0.38, 0.6)], clear=[(0.5, 0.0, 0.95, 0.2)]),
}



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


def map_art(art, rows):
    """A map art's base layer, its tiles put together."""
    tiles = {(int(r["RowIndex"]), int(r["ColIndex"])): int(r["FileDataID"])
             for r in rows if r["UiMapArtID"] == art and r["LayerIndex"] == "0"}
    full = Image.new("RGB", (TILE * (1 + max(c for _, c in tiles)), TILE * (1 + max(r for r, _ in tiles))))
    for (r, c), file_id in tiles.items():
        image = Image.open(io.BytesIO(fetch(f"https://wago.tools/api/casc/{file_id}?version={BUILD}")))
        full.paste(image.convert("RGB"), (c * TILE, r * TILE))
    return full


def paper(full):
    """The paper tile, from the plan's base art."""
    n = PAPER_SIZE
    patch = full.crop(PAPER_BOX).resize((n, n), Image.BICUBIC)
    mean = tuple(round(v) for v in ImageStat.Stat(patch).mean)
    blur = patch.filter(ImageFilter.GaussianBlur(PAPER_FLATTEN))
    flat = ImageChops.add(ImageChops.subtract(patch, blur, 1, 128), Image.new("RGB", (n, n), mean), 1, -128)
    # The original in the middle, the shifted copy (seams in its middle) at the edges.
    weight = Image.new("L", (n, n))
    weight.putdata([round(255 * min(1, 4 * min(x, n - 1 - x, y, n - 1 - y) / n)) for y in range(n) for x in range(n)])
    return Image.composite(flat, ImageChops.offset(flat, n // 2, n // 2), weight)


def city_mask(full, size, p):
    """The mask alpha for a city's street plan, CITY_SIZE pixels square."""
    w = CITY_WORK
    h = round(w * size[1] / size[0])
    plan = full.crop((0, 0) + size).resize((w, h), Image.LANCZOS).filter(ImageFilter.GaussianBlur(1))

    # The parchment's colour: the median just inside the burnt edge.
    b = p["band"]
    edge = [plan.getpixel((x, y)) for x in range(b, w - b) for y in (b, h - b - 1)]
    edge += [plan.getpixel((w - b - 1, y)) for y in range(b, h - b)]
    paper = tuple(sorted(px[i] for px in edge)[len(edge) // 2] for i in range(3))
    r, g, bl = ImageChops.difference(plan, Image.new("RGB", plan.size, paper)).split()
    diff = ImageChops.add(ImageChops.add(r, g), bl)

    shape = diff.point(lambda v: 255 if v > p["cut"] else 0)
    shape = shape.filter(ImageFilter.MaxFilter(2 * p["close"] + 1)).filter(ImageFilter.MinFilter(2 * p["close"] + 1))
    draw = ImageDraw.Draw(shape)
    for box in [(0, 0, w, b), (0, h - b, w, h), (0, 0, b, h), (w - b, 0, w, h)]:
        draw.rectangle(box, fill=0)
    for x1, y1, x2, y2 in p.get("fill", []):
        draw.rectangle((x1 * w, y1 * h, x2 * w, y2 * h), fill=255)
    for x1, y1, x2, y2 in p.get("clear", []):
        draw.rectangle((x1 * w, y1 * h, x2 * w, y2 * h), fill=0)
    ImageDraw.floodfill(shape, (0, 0), 128)
    shape = shape.point(lambda v: 0 if v == 128 else 255)
    shape = shape.filter(ImageFilter.MinFilter(2 * p["open"] + 1)).filter(ImageFilter.MaxFilter(2 * p["open"] + 1))
    shape = shape.filter(ImageFilter.MaxFilter(2 * p["grow"] + 1)).filter(ImageFilter.GaussianBlur(p["soft"]))
    return shape.resize((CITY_SIZE, CITY_SIZE), Image.LANCZOS)


def city_masks(maps_by_art):
    """Writes a mask per city in CITY_MASKS, and the paper tile; returns the
    cities' uiMap IDs."""
    sizes = {r["UiMapArtStyleID"]: (int(r["LayerWidth"]), int(r["LayerHeight"]))
             for r in table("UiMapArtStyleLayer") if r["LayerIndex"] == "0"}
    styles = {r["ID"]: r["UiMapArtStyleID"] for r in table("UiMapArt")}
    rows = table("UiMapArtTile")
    done = []
    for art, maps in sorted(maps_by_art.items()):
        for m in maps:
            if m not in CITY_MASKS and m != PAPER_CITY:
                continue
            full = map_art(art, rows)
            if m == PAPER_CITY:
                paper(full).save(MASKS / "paper.tga")
            if m in CITY_MASKS:
                mask = Image.new("RGBA", (CITY_SIZE, CITY_SIZE), (255, 255, 255, 0))
                mask.putalpha(city_mask(full, sizes[styles[art]], CITY_MASKS[m]))
                mask.save(MASKS / f"city_{m}.tga")
                done.append(m)
    return sorted(done)


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
    cities = city_masks(maps_by_art)

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
    lines += [
        "",
        "-- Cities with a mask in ZoneMasks\\city_<uiMapID>.tga: where their street",
        "-- plan has drawing, over the whole plan.",
        "ns.CityMasks = {",
    ]
    lines += [f"    [{m}] = true," for m in cities]
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    total = sum(len(v) for v in per_map.values())
    print(f"{total} overlays for {len(per_map)} maps, {len(masked)} masks, {len(cities)} city masks -> {ADDON}")


if __name__ == "__main__":
    main()
