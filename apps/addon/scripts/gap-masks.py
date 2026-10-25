"""Draws the per-continent textures Gaps.lua paints land and sea no zone map
covers through, in RoadToSixty/Gaps/ (Gaps/Era/ for Era, Gaps/Anniversary/), each stretched over its continent's
map art (uiMapID 1414 Kalimdor, 1415 Eastern Kingdoms):

  land_<id>.tga   where the continent is land: the parchment shows there
  field_<id>.tga  the colour the parchment takes at each place: the
                  parchment colour of the zone maps nearest it, blended
                  (Jordan, 2026-10-23: one colour sat lighter or darker than
                  the zones round each gap)
  sea_<id>.tga    the sea near the land (SEA_NEAR, fading by SEA_FAR): zone
                  map sea (gap-textures.py's sea.tga) shows there instead of
                  the continent art's, blown up and blurred
  hatch_<id>.tga  the band off the coast where zone maps draw their brown
                  strokes on the sea (HATCH_NEAR, fading by HATCH_FAR)
  shore_<id>.tga  a thin band along the coast, in the light blue-grey of the
                  zone maps' shorelines
  mountains_<id>.tga  the land a little in from the coast (MOUNTAINS): gaps
                  are nearly always the range between two zones, and get
                  mountains (gap-textures.py's mountains.tga) there

Land is where the continent art is saturated (its sea and parchment are
greyish), the way OpenMap finds it (tools/map-preview/render.py, land_of),
less the burnt frame and the decorated corners, less Blizzard's sea
hatching (brown strokes as saturated as land: rows alternating light and
dark down the art with little change across it), less pieces centred near
the art's sides (aged parchment, the ship and serpent drawings) and specks,
its holes filled (the hatching test takes the big lettering for sea too);
pulled in a little from the coast (SHRINK) for the parchment.

The field: each zone's parchment colour is the median of its base art's
blank parchment (warm, smooth pixels inside its frame); zones are placed on
the continent from UiMapAssignment as the game's GetMapRectOnMap places
them; each place takes the zones' colours weighted by how near their
middles are (FIELD_REACH, in zone sizes). Gaps.lua mixes it with two copies
of the parchment (MIX: the first copy whole, the field over it, the second
copy over that); the field holds what makes the mix come out at the
wanted colour, given the parchment's own mean.

Reads the client's tables and map art from wago.tools; CACHE keeps the art
tiles between runs. PREVIEW writes each continent's art with the land
tinted, and the field over its land, to check by eye.

Usage: python scripts/gap-masks.py [build] [preview folder] [cache folder]
(needs Pillow and numpy; run after scripts/gap-textures.py)
"""

import csv
import io
import sys
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

BUILD = sys.argv[1] if len(sys.argv) > 1 else "1.60.1.70245"
PREVIEW = Path(sys.argv[2]) if len(sys.argv) > 2 else None
CACHE = Path(sys.argv[3]) if len(sys.argv) > 3 else None
CONTINENTS = (1414, 1415)       # Kalimdor, Eastern Kingdoms
CITIES = {1453, 1454, 1455, 1456, 1457, 1458, 1947, 1954}   # street plans, not zone maps
TILE = 256
SIZE = 512                      # each mask's side; stretched over the continent's art
FIELD_SIZE = 128

BLUR = 4                        # art px of blur before reading saturation
SAT = (0.36, 0.48)              # saturation from which art starts to be land, and is
FRAME = 0.05                    # share of each side that is the frame, never land
CORNER = (0.16, 0.22)           # share of width and height of each decorated corner
HATCH = 0.012                   # vertical-over-horizontal contrast that marks sea hatching
HATCH_GROW = 3                  # art px the hatching found is grown by
EDGE_BAND = (0.28, 0.18)        # land pieces centred this close to a side (left and right, top and
                                #  bottom) are the frame's (wider across: the ship's drawing; not down:
                                #  the north of the Eastern Kingdoms is centred 23% from the top)
SPECK = 0.0005                  # share of the art below which a piece of land is a speck
SHRINK = 2                      # art px the parchment is pulled in from the coast
SOFT = 1.5                      # art px of softening of the parchment's edge

# Off the coast, in continent art px (one is about 14 px of a zone map):
SEA_NEAR, SEA_FAR = 8, 16       # zone map sea, full to here, gone by here
HATCH_NEAR, HATCH_FAR = 3, 10   # the strokes (Tanaris draws them some 150 zone px out)
SHORE = (-2.5, 1.0)             # the shoreline band, from inside the land's edge to past it
MOUNTAINS = (3, 6)              # in from the coast: mountains start here, and are whole from here

FIELD_REACH = 0.45              # a zone's colour reaches this far from its middle, in its map's sizes
MIX = (0.5, 1 / 3)              # Gaps.lua: the field's alpha over the first copy, the second copy's over that

# Each game has its own map art: Forever repainted every map, and the
# Anniversary realms (2.5) repainted the continents for the Blood Elf and
# Draenei lands, under the same file IDs as Era's. So an Era build (1.15)
# writes Gaps/Era/, an Anniversary build Gaps/Anniversary/ (Gaps.lua picks
# the set for the client), and a Forever build Gaps/ itself.
SET = "Era" if BUILD.startswith("1.15.") else "Anniversary" if BUILD.startswith("2.5.") else ""
CLASSIC = SET != ""
OUT = Path(__file__).resolve().parent.parent / "RoadToSixty" / "Gaps" / SET

# The classic continent art draws its coasts tens of pixels from where the
# zone maps draw them (mountains showed on the sea round Eversong and the
# Wetlands, Jordan 2026-10-25), so where a zone map clearly shows sea, it
# takes the land away (zone_votes). Zone sea is grey-blue: blue at least
# WATER_BLUE of red and saturation below WATER_SAT; mountains and fields are
# far warmer. A zone counts from ZONE_TRUST[0] in from its map's edge (its
# frame) and fully from ZONE_TRUST[1]; overlapping zones vote, and they only
# take land away, never add it: a test that missed a range must not sink it.
WATER_BLUE, WATER_SAT = 0.42, 0.6
ZONE_TRUST = (0.06, 0.2)
ZONE_WEIGHT = 0.3


def fetch(url, cached=None):
    if CACHE and cached:
        path = CACHE / cached
        if path.exists():
            return path.read_bytes()
    req = urllib.request.Request(url, headers={"User-Agent": "RoadToSixty gap mask generator"})
    with urllib.request.urlopen(req) as resp:
        data = resp.read()
    if CACHE and cached:
        CACHE.mkdir(parents=True, exist_ok=True)
        (CACHE / cached).write_bytes(data)
    return data


_tables = {}


def table(name):
    if name not in _tables:
        data = fetch(f"https://wago.tools/db2/{name}/csv?build={BUILD}")
        _tables[name] = list(csv.DictReader(io.StringIO(data.decode("utf-8"))))
    return _tables[name]


def base_art(uimap):
    """A map's base art, its tiles put together, as floats 0 to 1."""
    art = next(r["UiMapArtID"] for r in table("UiMapXMapArt") if r["UiMapID"] == str(uimap) and r["PhaseID"] == "0")
    style = next(r["UiMapArtStyleID"] for r in table("UiMapArt") if r["ID"] == art)
    w, h = next((int(r["LayerWidth"]), int(r["LayerHeight"])) for r in table("UiMapArtStyleLayer")
                if r["UiMapArtStyleID"] == style and r["LayerIndex"] == "0")
    tiles = {(int(r["RowIndex"]), int(r["ColIndex"])): int(r["FileDataID"])
             for r in table("UiMapArtTile") if r["UiMapArtID"] == art and r["LayerIndex"] == "0"}
    full = Image.new("RGB", (TILE * (1 + max(c for _, c in tiles)), TILE * (1 + max(r for r, _ in tiles))))
    for (row, col), file_id in tiles.items():
        data = fetch(f"https://wago.tools/api/casc/{file_id}?version={BUILD}", f"{BUILD}-{file_id}.blp")
        full.paste(Image.open(io.BytesIO(data)).convert("RGB"), (col * TILE, row * TILE))
    return np.asarray(full.crop((0, 0, w, h))).astype(np.float32) / 255


def blur(a, r):
    """About a Gaussian of radius r: three box blurs, each way."""
    k = max(1, int(round(r)))
    for axis in (0, 1):
        for _ in range(3):
            pad = [(0, 0)] * a.ndim
            pad[axis] = (k + 1, k)
            c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis)
            hi = np.take(c, range(2 * k + 1, c.shape[axis]), axis=axis)
            lo = np.take(c, range(0, c.shape[axis] - 2 * k - 1), axis=axis)
            a = (hi - lo) / (2 * k + 1)
    return a


def grow(mask, r):
    """A boolean mask grown (r > 0) or shrunk (r < 0) by r px, square."""
    img = Image.fromarray((mask * 255).astype(np.uint8))
    f = ImageFilter.MaxFilter if r > 0 else ImageFilter.MinFilter
    return np.asarray(img.filter(f(2 * abs(r) + 1))) > 127


def distance(mask, most):
    """Px from mask (0 inside it) out to most, by growing it one px at a time."""
    d = np.full(mask.shape, float(most), np.float32)
    ring = mask.copy()
    d[ring] = 0
    for step in range(1, most):
        ring = grow(ring, 1)
        d[ring & (d == most)] = step
    return d


def keep_continent(mask):
    """Only the pieces of land centred clear of the art's outer EDGE_BAND and
    at least SPECK of it: the aged parchment along the frame and the
    drawings in the corners (a ship, a sea serpent) read as land too."""
    h, w = mask.shape
    # (a copy: floodfill does nothing to an image still backed by the array)
    img = Image.fromarray(np.where(mask, 255, 0).astype(np.uint8)).copy()
    keep = np.zeros_like(mask)
    label = 0
    while label < 250:
        left = np.argwhere(np.asarray(img) == 255)
        if len(left) == 0:
            break
        label += 1
        y, x = left[0]
        ImageDraw.floodfill(img, (int(x), int(y)), label)
        piece = np.asarray(img) == label
        ys, xs = np.nonzero(piece)
        cy, cx = ys.mean() / h, xs.mean() / w
        bx, by = EDGE_BAND
        clear = bx <= cx <= 1 - bx and by <= cy <= 1 - by
        if clear and piece.sum() >= SPECK * h * w:
            keep |= piece
    return keep


def land_of(art):
    """Where the art is land, solid (before any pulling in or softening)."""
    h, w = art.shape[:2]
    soft = blur(art, BLUR)
    mx, mn = soft.max(2), soft.min(2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    land = np.clip((sat - SAT[0]) / (SAT[1] - SAT[0]), 0, 1)

    fy, fx = int(h * FRAME), int(w * FRAME)
    land[:fy], land[h - fy:], land[:, :fx], land[:, w - fx:] = 0, 0, 0, 0
    cx, cy = int(w * CORNER[0]), int(h * CORNER[1])
    for ys in (slice(0, cy), slice(h - cy, h)):
        for xs in (slice(0, cx), slice(w - cx, w)):
            land[ys, xs] = 0

    lum = art.mean(2)
    dy = np.abs(np.diff(lum, axis=0, prepend=lum[:1]))
    dx = np.abs(np.diff(lum, axis=1, prepend=lum[:, :1]))
    stripe = blur(blur(dy, 4) - blur(dx, 4), 3)
    land[grow(grow(stripe > HATCH, -2), 2 + HATCH_GROW)] = 0

    return fill_holes(keep_continent(grow(grow(land > 0.5, -1), 1)))


def fill_holes(mask):
    """Land with every hole filled: whatever the open sea round the art's
    edge does not reach. The hatching test also takes the continent's big
    lettering and some zone borders for sea, holes in the land; lakes go
    too, which zone art covers."""
    img = Image.fromarray(np.where(mask, 255, 0).astype(np.uint8)).copy()
    ImageDraw.floodfill(img, (0, 0), 128)
    return np.asarray(img) != 128


def parchment_colour(uimap):
    """The median of a zone map's blank parchment: warm, smooth pixels inside
    its frame, as 0 to 255. From its base art: what shows of a zone round a
    gap is mostly its painting of the land beyond its own, base parchment.
    (Tried with every explored piece drawn over the base: the test then
    takes the painted land, far more saturated, Westfall's at 154 / 112 / 10,
    and the gaps would come out too yellow.)"""
    art = base_art(uimap)
    h, w = art.shape[:2]
    inner = art[int(h * 0.08):int(h * 0.92), int(w * 0.08):int(w * 0.92)]
    r, g, b = inner[..., 0], inner[..., 1], inner[..., 2]
    warm = (r > g) & (g > b) & (b < 0.6 * r)
    lum = inner.mean(2)
    rough = blur(np.abs(np.diff(lum, axis=0, prepend=lum[:1])) + np.abs(np.diff(lum, axis=1, prepend=lum[:, :1])), 3)
    smooth = rough < np.percentile(rough, 40)
    pick = inner[warm & smooth]
    if len(pick) < 500:
        pick = inner[warm]
    return np.median(pick, axis=0) * 255


def assignment(uimap, world=None):
    """A map's placement in the world; world picks the row on that world
    (a continent has one on 530 too, where the Blood Elf and Draenei lands are)."""
    return next((r for r in table("UiMapAssignment") if r["UiMapID"] == str(uimap)
                 and (r["MapID"] == world if world else r["OrderIndex"] == "0")), None)


def to_art(a):
    """World y, x to a map's art u, v (0 to 1), from its assignment."""
    f = lambda k: float(a[k])
    def u(y):
        return f("UiMin_0") + (f("Region_4") - y) / (f("Region_4") - f("Region_1")) * (f("UiMax_0") - f("UiMin_0"))
    def v(x):
        return f("UiMin_1") + (f("Region_3") - x) / (f("Region_3") - f("Region_0")) * (f("UiMax_1") - f("UiMin_1"))
    return u, v


def from_art(a):
    """A map's art u, v (0 to 1) to world y, x."""
    f = lambda k: float(a[k])
    def y(u):
        return f("Region_4") - (u - f("UiMin_0")) / (f("UiMax_0") - f("UiMin_0")) * (f("Region_4") - f("Region_1"))
    def x(v):
        return f("Region_3") - (v - f("UiMin_1")) / (f("UiMax_1") - f("UiMin_1")) * (f("Region_3") - f("Region_0"))
    return y, x


def zone_rect(zone, continent):
    """A zone map's rect on its continent's map: u1, v1, u2, v2."""
    za = assignment(zone)
    ca = za and assignment(continent, za["MapID"])
    if not ca:
        return None
    y, x = from_art(za)
    u, v = to_art(ca)
    return u(y(0)), v(x(0)), u(y(1)), v(x(1))


def zones_of(continent):
    return [int(r["ID"]) for r in table("UiMap")
            if r["ParentUiMapID"] == str(continent) and r["Type"] == "3" and int(r["ID"]) not in CITIES]


def zone_water(zone):
    """Where a zone map's own art is clearly sea: grey-blue, less its frame.
    Lakes, rivers and snow come out as water too; inside land they are
    filled again (fill_holes) once the votes are in."""
    art = base_art(zone)
    h, w = art.shape[:2]
    soft = blur(art, BLUR)
    r, b = soft[..., 0], soft[..., 2]
    mx, mn = soft.max(2), soft.min(2)
    sat = (mx - mn) / np.maximum(mx, 1e-6)
    water = blur(((b > WATER_BLUE * r) & (sat < WATER_SAT)).astype(np.float32), 6) > 0.5
    fy, fx = int(h * FRAME), int(w * FRAME)
    water[:fy], water[h - fy:], water[:, :fx], water[:, w - fx:] = False, False, False, False
    return grow(grow(water, -3), 3)


def zone_votes(continent, solid):
    """The continent's land, less where the zone maps covering it show sea."""
    h, w = solid.shape
    votes = np.zeros((h, w), np.float32)
    weights = np.zeros((h, w), np.float32)
    for zone in zones_of(continent):
        rect = zone_rect(zone, continent)
        if not rect:
            continue
        u1, v1, u2, v2 = rect
        x1, x2 = sorted((u1 * w, u2 * w))
        y1, y2 = sorted((v1 * h, v2 * h))
        X1, Y1, X2, Y2 = max(0, int(x1)), max(0, int(y1)), min(w, int(np.ceil(x2))), min(h, int(np.ceil(y2)))
        if X2 <= X1 or Y2 <= Y1:
            continue
        water = zone_water(zone).astype(np.float32)
        zh, zw = water.shape
        # (each continent px takes the zone art px at its middle)
        xs = ((np.arange(X1, X2) + 0.5 - x1) / (x2 - x1) * zw).clip(0, zw - 1).astype(int)
        ys = ((np.arange(Y1, Y2) + 0.5 - y1) / (y2 - y1) * zh).clip(0, zh - 1).astype(int)
        part = water[np.ix_(ys, xs)]
        fx = np.minimum(xs, zw - 1 - xs) / zw
        fy = np.minimum(ys, zh - 1 - ys) / zh
        edge = np.minimum(fx[None, :], fy[:, None])
        trust = np.clip((edge - ZONE_TRUST[0]) / (ZONE_TRUST[1] - ZONE_TRUST[0]), 0, 1)
        votes[Y1:Y2, X1:X2] += trust * part
        weights[Y1:Y2, X1:X2] += trust
        print(f"  zone {zone}: sea {part.mean():.2f} of its rect")
    sea = (weights >= ZONE_WEIGHT) & (votes / np.maximum(weights, 1e-6) > 0.5)
    return solid & ~sea


def field_of(continent, land, parchment_mean):
    zones = zones_of(continent)
    gu, gv = np.meshgrid((np.arange(FIELD_SIZE) + 0.5) / FIELD_SIZE, (np.arange(FIELD_SIZE) + 0.5) / FIELD_SIZE)
    total = np.zeros((FIELD_SIZE, FIELD_SIZE, 3), np.float64)
    weight = np.zeros((FIELD_SIZE, FIELD_SIZE), np.float64)
    for zone in zones:
        rect = zone_rect(zone, continent)
        if not rect:
            continue
        colour = parchment_colour(zone)
        u1, v1, u2, v2 = rect
        cu, cv = (u1 + u2) / 2, (v1 + v2) / 2
        ru, rv = abs(u2 - u1) * FIELD_REACH, abs(v2 - v1) * FIELD_REACH
        w = np.exp(-(((gu - cu) / ru) ** 2 + ((gv - cv) / rv) ** 2))
        total += w[..., None] * colour
        weight += w
        print(f"  zone {zone}: parchment {colour.round(0)}")
    mean = total.sum((0, 1)) / max(weight.sum(), 1e-9)
    wanted = (total + 1e-3 * mean) / (weight + 1e-3)[..., None]
    fa, ca = MIX
    keep = (1 - ca) * (1 - fa) + ca                  # the parchment's share of the mix
    field = (wanted - keep * np.asarray(parchment_mean)) / ((1 - ca) * fa)
    return wanted, np.clip(field, 0, 255)


def save_alpha(alpha, name, size=SIZE):
    a = Image.fromarray((np.clip(alpha, 0, 1) * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)
    image = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    image.putalpha(a)
    image.save(OUT / name)


def ramp(d, near, far):
    return np.clip((far - d) / (far - near), 0, 1) ** 1.5


def main():
    parchment = np.asarray(Image.open(OUT / "parchment.tga").convert("RGB")).reshape(-1, 3).mean(0)
    for continent in CONTINENTS:
        print(f"continent {continent}")
        art = base_art(continent)
        solid = land_of(art)
        if CLASSIC:
            solid = fill_holes(zone_votes(continent, solid))
        land = np.clip(blur(grow(solid, -SHRINK).astype(np.float32), SOFT), 0, 1)
        save_alpha(land, f"land_{continent}.tga")

        sea = distance(solid, SEA_FAR + 1)
        save_alpha(ramp(sea, SEA_NEAR, SEA_FAR) * (~solid), f"sea_{continent}.tga")
        save_alpha(ramp(sea, HATCH_NEAR, HATCH_FAR) * (~solid), f"hatch_{continent}.tga")
        inside = distance(~solid, max(4, MOUNTAINS[1] + 1))
        save_alpha(np.clip((inside - MOUNTAINS[0]) / (MOUNTAINS[1] - MOUNTAINS[0]), 0, 1) * solid,
                   f"mountains_{continent}.tga")
        inside = np.minimum(inside, 4)
        edge = np.where(solid, -inside, sea)
        shore = np.clip(1 - np.abs(edge - (SHORE[0] + SHORE[1]) / 2) / ((SHORE[1] - SHORE[0]) / 2), 0, 1)
        save_alpha(blur(shore.astype(np.float32), 0.8), f"shore_{continent}.tga")

        wanted, field = field_of(continent, land, parchment)
        Image.fromarray(field.round().astype(np.uint8)).save(OUT / f"field_{continent}.tga")
        print(f"wrote land, sea, hatch, shore, mountains and field for {continent}")

        if PREVIEW:
            PREVIEW.mkdir(parents=True, exist_ok=True)
            h, w = land.shape
            want = np.asarray(Image.fromarray(wanted.round().clip(0, 255).astype(np.uint8)).resize((w, h))) / 255
            show = art * (1 - land[..., None]) + want * land[..., None]
            show = show * (1 - 0.6 * shore[..., None]) + np.array([0.6, 0.65, 0.62]) * 0.6 * shore[..., None]
            Image.fromarray((np.clip(show, 0, 1) * 255).astype(np.uint8)).save(PREVIEW / f"gap_{continent}.png")


if __name__ == "__main__":
    main()
