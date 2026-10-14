// The fog of war background: a grid of faint dots, lit along the roads a
// journey took, like the map uncovering where you've been. Animated, the
// lit stretch travels along each road: dots light up in turn, swell for a
// moment, then fade back into the fog. Each lit dot also knows its road, so
// a page can colour roads apart and light them one after another (Timing).

export type Point = [number, number];
// at: when the dot lights, as a fraction of the loop: how far along its
// nearest road it sits, or within that road's share when roads are timed.
export type Dot = [x: number, y: number, at: number, road: number];
// A road's turn in the loop: it starts lighting at start and takes share of it.
export type Timing = { start: number; share: number };

// Grid dots start half a step in, so the grid sits centred in the box.
export function fogDots(width: number, height: number, step: number, roads: Point[][], timing?: Timing[]) {
  const lengths = roads.map((road) => road.slice(1).map((b, i) => Math.hypot(b[0] - road[i]![0], b[1] - road[i]![1])));
  const totals = lengths.map((l) => l.reduce((a, b) => a + b, 0));
  const lit: Dot[] = [],
    edge: Dot[] = [],
    fog: Point[] = [];
  for (let x = step / 2; x < width; x += step) {
    for (let y = step / 2; y < height; y += step) {
      let near = Infinity,
        at = 0,
        which = 0;
      roads.forEach((road, r) => {
        let before = 0;
        for (let i = 0; i + 1 < road.length; i++) {
          const [d, t] = distance([x, y], road[i]!, road[i + 1]!);
          if (d < near) {
            near = d;
            which = r;
            const along = totals[r]! > 0 ? (before + t * lengths[r]![i]!) / totals[r]! : 0;
            const turn = timing?.[r];
            at = turn ? turn.start + along * turn.share : along;
          }
          before += lengths[r]![i]!;
        }
      });
      if (near < step * 1.2) lit.push([x, y, at, which]);
      else if (near < step * 3.2) edge.push([x, y, at, which]);
      else fog.push([x, y]);
    }
  }
  return { lit, edge, fog };
}

// The CSS for lit and half-lit dots with the class rts-fog-road. Every dot
// runs the same loop; fogDelay starts each one partway in.
export function fogAnimation(seconds: number): string {
  return [
    "@keyframes rts-fog{0%{opacity:0;transform:scale(.4)}5%{opacity:1;transform:scale(1.9)}12%{opacity:1;transform:scale(1)}" +
      "40%{opacity:1;transform:scale(1)}55%{opacity:0;transform:scale(.6)}100%{opacity:0;transform:scale(.6)}}",
    `.rts-fog-road{opacity:0;transform-box:fill-box;transform-origin:center;animation:rts-fog ${seconds}s linear infinite}`,
    "@media (prefers-reduced-motion:reduce){.rts-fog-road{animation:none;opacity:1}}",
  ].join("\n");
}

// Negative, so the loop is already running when the page appears.
export function fogDelay(at: number, seconds: number): string {
  return `${(at * seconds - seconds).toFixed(2)}s`;
}

// How far p is from the segment a to b, and where along it (0 to 1) the
// nearest point lies.
function distance([px, py]: Point, [ax, ay]: Point, [bx, by]: Point): [number, number] {
  const dx = bx - ax,
    dy = by - ay;
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy || 1)));
  return [Math.hypot(px - ax - t * dx, py - ay - t * dy), t];
}
