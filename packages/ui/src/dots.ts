// The fog of war background: a grid of faint dots, lit along the roads a
// journey took, like the map uncovering where you've been.

export type Point = [number, number];

// Grid dots start half a step in, so the grid sits centred in the box.
export function fogDots(width: number, height: number, step: number, roads: Point[][]) {
  const lit: Point[] = [],
    edge: Point[] = [],
    fog: Point[] = [];
  for (let x = step / 2; x < width; x += step) {
    for (let y = step / 2; y < height; y += step) {
      let near = Infinity;
      for (const road of roads) {
        for (let i = 0; i + 1 < road.length; i++) near = Math.min(near, distance([x, y], road[i]!, road[i + 1]!));
      }
      (near < step * 1.2 ? lit : near < step * 3.2 ? edge : fog).push([x, y]);
    }
  }
  return { lit, edge, fog };
}

function distance([px, py]: Point, [ax, ay]: Point, [bx, by]: Point) {
  const dx = bx - ax,
    dy = by - ay;
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy || 1)));
  return Math.hypot(px - ax - t * dx, py - ay - t * dy);
}
