import type { Point, Timing } from "@road-to-sixty/ui/dots";

// The hero's two wandering roads, the same every build: a seeded random
// walk that turns back towards the middle near the edges.
function seeded(seed: number) {
  let s = seed | 0;
  return () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function walk(rnd: () => number, width: number, height: number, x: number, y: number, a: number, steps: number, len: number): Point[] {
  const pts: Point[] = [[x, y]];
  for (let i = 0; i < steps; i++) {
    a += (rnd() - 0.5) * 0.9;
    if (x < 30 || x > width - 30 || y < 30 || y > height - 30) {
      const back = Math.atan2(height / 2 - y, width / 2 - x);
      a += Math.atan2(Math.sin(back - a), Math.cos(back - a)) * 0.3;
    }
    x += Math.cos(a) * len;
    y += Math.sin(a) * len;
    pts.push([x, y]);
  }
  return pts;
}

// Wide enough for a 2560 px screen; narrower screens see its middle.
export const HERO = { width: 2560, height: 900 };
const rnd = seeded(11);
export const HERO_ROADS: Point[][] = [
  walk(rnd, HERO.width, HERO.height, -20, 640, -0.4, 110, 30),
  walk(rnd, HERO.width, HERO.height, HERO.width + 20, 120, Math.PI + 0.3, 90, 30),
];
export const HERO_MARKS: Point[] = HERO_ROADS.flatMap((road) => road.filter((_, i) => i >= 7 && (i - 7) % 10 === 0));

// The "one road" band: Desk's road (blue) and Laptop's (cream) light up
// together, then the road they joined into.
export const BAND = { width: 1280, height: 460 };
export const BAND_ROADS: Point[][] = [
  [[-20, 70], [140, 90], [300, 130], [430, 170], [560, 230]],
  [[-20, 400], [150, 370], [310, 330], [440, 280], [560, 230]],
  [[560, 230], [700, 200], [840, 225], [1010, 150], [1300, 110]],
];
export const BAND_COLOURS = ["#3aa0ff", "rgba(247, 244, 238, 0.85)", "#3aa0ff"];
export const BAND_TIMING: Timing[] = [{ start: 0, share: 0.5 }, { start: 0, share: 0.5 }, { start: 0.5, share: 0.5 }];
export const BAND_MARKS: Point[] = [[560, 230], [1010, 150]];
