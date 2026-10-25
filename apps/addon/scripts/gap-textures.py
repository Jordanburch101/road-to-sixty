"""Draws the tiles Gaps.lua paints land and sea no zone map covers with, in
RoadToSixty/Gaps/ (Gaps/Era/ or Gaps/Anniversary/ for those builds), all at zone map scale (one pixel is one pixel of a zone
map's art), from the zone maps' own art so the gaps look like the zones
round them:

  parchment.tga  blank parchment: Forever's zone maps are blank parchment
                 under their explored pieces, and Loch Modan's base art has
                 the largest clean patch (Jordan's reference, 2026-10-23:
                 large soft blotches, a fine grain, nothing repeating;
                 Road to Sixty's paper.tga, a small tile with distinct
                 marks, repeated visibly)
  sea.tga        open sea, mottled blue-grey: Tanaris' Great Sea, clear of
                 its chart lines (Westfall's, more yellow, has a faint
                 meridian that repeated as a seam at every tile)
  hatch.tga      the brown strokes zone maps draw on the sea along a coast:
                 drawn here, horizontal lines HATCH_PERIOD apart (measured on
                 Wetlands' west coast: 5.6 px) in its ink, broken into
                 strokes, as alpha over that ink colour

Each patch is made to tile (its last columns and rows crossfaded into its
first) and its mottling strengthened round its mean (CONTRAST):
Gaps.lua mixes two copies of each at different sizes to hide the repeat,
and the parchment with a colour field (gap-masks.py), which average some of
it away. Colours are kept: Loch Modan's parchment, RGB 150 / 113 / 44, is
already that of Jordan's reference (152 / 112 / 46).

Usage: python scripts/gap-textures.py [build]   (needs Pillow and numpy;
run before scripts/gap-masks.py, which reads parchment.tga's mean)
"""

import csv
import io
import sys
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

BUILD = sys.argv[1] if len(sys.argv) > 1 else "1.60.1.70245"
TILE = 256

# (uiMapID, crop in its art's pixels, pixels crossfaded to make it tile, contrast,
#  flatten: px of blur whose colour is taken out, leaving finer mottling round
#  the mean, or 0; the sea's patch has a warm blotch from the map's burnt
#  top edge, which repeated at every tile)
PARCHMENT = (1432, (300, 130, 620, 450), 64, 2.6, 0)    # Loch Modan: 320 square, 256 left
SEA = (1446, (815, 45, 975, 205), 32, 1.3, 20)          # Tanaris: 160 square, 128 left

HATCH_SIZE = (128, 64)          # width, height: 11 lines of the period below
HATCH_LINES = 11
HATCH_INK = (100, 68, 30)       # a touch darker than the darkest of the measured strokes
HATCH_ALPHA = 0.45
HATCH_WIDTH = 0.45              # px, half a stroke's core
HATCH_BREAKS = 0.35             # share of each line left out between strokes

# Each game has its own map art: Forever repainted every map, and the
# Anniversary realms (2.5) repainted the continents for the Blood Elf and
# Draenei lands, under the same file IDs as Era's. So an Era build (1.15)
# writes Gaps/Era/, an Anniversary build Gaps/Anniversary/ (Gaps.lua picks
# the set for the client), and a Forever build Gaps/ itself.
SET = "Era" if BUILD.startswith("1.15.") else "Anniversary" if BUILD.startswith("2.5.") else ""
CLASSIC = SET != ""
OUT = Path(__file__).resolve().parent.parent / "RoadToSixty" / "Gaps" / SET


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "RoadToSixty gap texture generator"})
    with urllib.request.urlopen(req) as resp:
        return resp.read()


_tables = {}


def table(name):
    if name not in _tables:
        data = fetch(f"https://wago.tools/db2/{name}/csv?build={BUILD}")
        _tables[name] = list(csv.DictReader(io.StringIO(data.decode("utf-8"))))
    return _tables[name]


def base_art(uimap):
    art = next(r["UiMapArtID"] for r in table("UiMapXMapArt") if r["UiMapID"] == str(uimap) and r["PhaseID"] == "0")
    tiles = {(int(r["RowIndex"]), int(r["ColIndex"])): int(r["FileDataID"])
             for r in table("UiMapArtTile") if r["UiMapArtID"] == art and r["LayerIndex"] == "0"}
    full = Image.new("RGB", (TILE * (1 + max(c for _, c in tiles)), TILE * (1 + max(r for r, _ in tiles))))
    for (row, col), file_id in tiles.items():
        tile = Image.open(io.BytesIO(fetch(f"https://wago.tools/api/casc/{file_id}?version={BUILD}")))
        full.paste(tile.convert("RGB"), (col * TILE, row * TILE))
    return full


def wrap(a, k):
    """a made to tile: its last k columns and rows crossfaded into its first."""
    r = np.linspace(0, 1, k + 2)[1:-1]
    a = a.copy()
    w = a.shape[1]
    a[:, :k] = a[:, w - k:] * (1 - r)[None, :, None] + a[:, :k] * r[None, :, None]
    a = a[:, :w - k]
    h = a.shape[0]
    a[:k] = a[h - k:] * (1 - r)[:, None, None] + a[:k] * r[:, None, None]
    return a[:h - k]


def patch(spec, name):
    uimap, crop, k, contrast, flatten = spec
    tile = wrap(np.asarray(base_art(uimap).crop(crop)).astype(np.float32), k)
    mean = tile.reshape(-1, 3).mean(0)
    if flatten:
        # (the blur wraps round, as the tile does)
        big = np.tile(tile, (3, 3, 1))
        soft = np.asarray(Image.fromarray(np.clip(big, 0, 255).astype(np.uint8))
                          .filter(ImageFilter.GaussianBlur(flatten))).astype(np.float32)
        h, w = tile.shape[:2]
        tile = tile - soft[h:2 * h, w:2 * w] + mean
    tile = mean + (tile - mean) * contrast
    Image.fromarray(np.clip(tile, 0, 255).round().astype(np.uint8)).save(OUT / f"{name}.tga")
    flat = tile.reshape(-1, 3)
    print(f"wrote {name}.tga, {tile.shape[1]} x {tile.shape[0]}, mean {flat.mean(0).round(1)}, "
          f"mottling {np.clip(flat, 0, 255).std(0).round(1)}")


def smooth_noise(n, cells, rng):
    """1D noise of n samples, wrapping, smooth over n / cells."""
    knots = rng.random(cells)
    x = np.arange(n) * cells / n
    i = np.floor(x).astype(int)
    t = x - i
    t = t * t * (3 - 2 * t)
    return knots[i % cells] * (1 - t) + knots[(i + 1) % cells] * t


def hatch():
    w, h = HATCH_SIZE
    rng = np.random.default_rng(7)
    alpha = np.zeros((h, w), np.float32)
    period = h / HATCH_LINES
    ys = np.arange(h)
    for line in range(HATCH_LINES):
        centre = line * period + rng.uniform(-0.4, 0.4)
        # (a little thinner or thicker along the line, broken into strokes)
        width = HATCH_WIDTH + 0.25 * smooth_noise(w, 4, rng)
        on = (smooth_noise(w, 6, rng) > HATCH_BREAKS).astype(np.float32)
        on = np.convolve(np.concatenate([on[-2:], on, on[:2]]), np.ones(5) / 5, "valid")
        d = np.abs(((ys[:, None] - centre + h / 2) % h) - h / 2)
        alpha = np.maximum(alpha, np.clip(1 - d / (width[None, :] * 1.6), 0, 1) * on[None, :])
    image = Image.new("RGBA", (w, h), HATCH_INK + (0,))
    image.putalpha(Image.fromarray((alpha * HATCH_ALPHA * 255).round().astype(np.uint8)))
    image.save(OUT / "hatch.tga")
    print(f"wrote hatch.tga, {w} x {h}, a line every {period:.2f} px")


# Mountains: land no zone map covers is nearly always the range between two
# zones, and OpenMap paints its gaps with mountains by hand (its MapGapFill,
# Blizzard's art, so not ours to take: its LICENSE leaves textures made from
# WoW's art out). Ours are quilted (Efros and Freeman's image quilting) from
# the mountain ranges of zone maps, at their scale: blocks cut from inside
# the ranges laid on a grid that wraps round, each overlapping the ones
# already laid and cut where the two differ least, so the tile repeats
# without a seam and holds no half-mountain.
MOUNTAIN_SOURCES = (1416, 1426, 1432, 1418)   # Alterac, Dun Morogh, Loch Modan, Badlands
MOUNTAIN_SIZE = 512             # the tile's side
MOUNTAIN_STEP = 64              # blocks are laid this far apart (dividing the side) ...
MOUNTAIN_OVERLAP = 16           # ... each this much larger, overlapping its neighbours
MOUNTAIN_CANDIDATES = 300       # blocks tried for each place
MOUNTAIN_ENERGY = 72            # percentile of stroke density from which art is a range
MOUNTAIN_INSIDE = 0.9           # share of a block that must be range for it to be taken


def ranges_of(art):
    """Where a zone map's art is a mountain range: dense with strokes (its
    parchment's mottling is soft), less water and the sea's hatching (dense
    too: rows light and dark down, little across) and the frame."""
    lum = art.mean(2)
    soft = lambda a, r: np.asarray(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
                                   .filter(ImageFilter.GaussianBlur(r))).astype(np.float32)
    gx = np.abs(np.diff(lum, axis=1, prepend=lum[:, :1]))
    gy = np.abs(np.diff(lum, axis=0, prepend=lum[:1]))
    energy = soft((gx + gy) * 4, 6) / 4
    r, b = art[..., 0], art[..., 2]
    # (the sea's hatching lies by water: all near water goes, and strongly
    # striped art elsewhere; mountains' strokes run sideways too, so the
    # stripe test is loose: at 140 it took two thirds of Dun Morogh's)
    water = soft((b > r * 0.72) * 255.0, 25) > 20
    stripe = soft(np.clip((gy - gx) * 8 + 128, 0, 255), 4) > 175
    # (and Dun Morogh's snowy peaks: grey among the gold)
    mx, mn = art.max(2), art.min(2)
    snow = soft(((mx - mn) / np.maximum(mx, 1) < 0.35) * 255.0, 6) > 60
    ranges = (energy > np.percentile(energy, MOUNTAIN_ENERGY)) & ~water & ~stripe & ~snow
    h, w = lum.shape
    ranges[: int(h * .06)] = ranges[-int(h * .06):] = False
    ranges[:, : int(w * .05)] = ranges[:, -int(w * .05):] = False
    return np.asarray(Image.fromarray((ranges * 255).astype(np.uint8))
                      .filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(9))) > 127


def min_cut(err):
    """For an overlap err (rows by columns, cut running down it): a mask,
    1 right of the cheapest path from top to bottom."""
    h, w = err.shape
    cost = err.copy()
    for y in range(1, h):
        left = np.concatenate([[np.inf], cost[y - 1, :-1]])
        right = np.concatenate([cost[y - 1, 1:], [np.inf]])
        cost[y] += np.minimum(np.minimum(left, cost[y - 1]), right)
    mask = np.zeros((h, w), np.float32)
    x = int(np.argmin(cost[-1]))
    for y in range(h - 1, -1, -1):
        mask[y, x:] = 1
        if y:
            lo, hi = max(0, x - 1), min(w, x + 2)
            x = lo + int(np.argmin(cost[y - 1, lo:hi]))
    return mask


def mountains():
    rng = np.random.default_rng(11)
    step, ov = MOUNTAIN_STEP, MOUNTAIN_OVERLAP
    block = step + ov
    sources, spots = [], []
    for uimap in MOUNTAIN_SOURCES:
        art = np.asarray(base_art(uimap).crop((0, 0, 1002, 668))).astype(np.float32)
        inside = ranges_of(art).astype(np.float64)
        # (each block's share of range, from its top left corner: a box sum)
        c = np.pad(inside.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
        share = (c[block:, block:] - c[:-block, block:] - c[block:, :-block] + c[:-block, :-block]) / block ** 2
        ys, xs = np.nonzero(share >= MOUNTAIN_INSIDE)
        keep = rng.permutation(len(ys))[:4000]          # (plenty to choose from, and quick)
        ys, xs = ys[keep], xs[keep]
        sources.append(art)
        spots += [(len(sources) - 1, y, x) for y, x in zip(ys, xs)]
        print(f"  mountains of {uimap}: {len(ys)} blocks to take from")
    n = MOUNTAIN_SIZE // step
    size = MOUNTAIN_SIZE
    out = np.zeros((size, size, 3), np.float32)
    laid = np.zeros((size, size), bool)
    for j in range(n):
        for i in range(n):
            ys = (np.arange(block) + j * step) % size
            xs = (np.arange(block) + i * step) % size
            have = laid[np.ix_(ys, xs)]
            target = out[np.ix_(ys, xs)]
            best, best_err = None, np.inf
            for c in rng.choice(len(spots), MOUNTAIN_CANDIDATES, replace=False):
                s, y, x = spots[c]
                cand = sources[s][y:y + block, x:x + block]
                err = ((cand - target) ** 2).sum(2)[have].sum() if have.any() else rng.random()
                if err < best_err:
                    best, best_err = cand, err
            # (each overlap laid already: the new block from the cheapest cut on)
            err = ((best - target) ** 2).sum(2)
            keep = np.ones((block, block), np.float32)
            if have[:, :ov].all():
                keep[:, :ov] = np.minimum(keep[:, :ov], min_cut(err[:, :ov]))
            if have[:ov, :].all():
                keep[:ov, :] = np.minimum(keep[:ov, :], min_cut(err[:ov, :].T).T)
            if have[:, -ov:].all():
                keep[:, -ov:] = np.minimum(keep[:, -ov:], 1 - min_cut(err[:, -ov:]))
            if have[-ov:, :].all():
                keep[-ov:, :] = np.minimum(keep[-ov:, :], 1 - min_cut(err[-ov:, :].T).T)
            keep[~have] = 1
            keep = np.asarray(Image.fromarray((keep * 255).astype(np.uint8))
                              .filter(ImageFilter.GaussianBlur(1))).astype(np.float32) / 255
            keep[~have] = 1
            out[np.ix_(ys, xs)] = target * (1 - keep[..., None]) + best * keep[..., None]
            laid[np.ix_(ys, xs)] = True
    Image.fromarray(np.clip(out, 0, 255).round().astype(np.uint8)).save(OUT / "mountains.tga")
    print(f"wrote mountains.tga, {size} x {size}")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    patch(PARCHMENT, "parchment")
    patch(SEA, "sea")
    hatch()
    mountains()


if __name__ == "__main__":
    main()
