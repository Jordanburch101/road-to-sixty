import { useMemo } from "react";
import { fogDots, type Point } from "./dots";

// Draws the fog grid at a fixed size; the parent clips and fades it.
export function Fog({ width, height, step, roads, marks = [] }: { width: number; height: number; step: number; roads: Point[][]; marks?: Point[] }) {
  const { lit, edge, fog } = useMemo(() => fogDots(width, height, step, roads), [width, height, step, roads]);
  return (
    <svg aria-hidden="true" width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="pointer-events-none absolute left-0 top-0">
      {fog.map(([x, y]) => <circle key={`f${x},${y}`} cx={x} cy={y} r={1.1} fill="rgba(154,149,168,0.16)" />)}
      {edge.map(([x, y]) => <circle key={`e${x},${y}`} cx={x} cy={y} r={1.4} fill="rgba(154,149,168,0.4)" />)}
      {lit.map(([x, y]) => <circle key={`l${x},${y}`} cx={x} cy={y} r={1.8} className="fill-accent" fillOpacity={0.85} />)}
      {marks.map(([x, y]) => (
        <g key={`m${x},${y}`}>
          <circle cx={x} cy={y} r={8} fill="none" className="stroke-accent" strokeOpacity={0.35} />
          <circle cx={x} cy={y} r={3} className="fill-accent" />
        </g>
      ))}
    </svg>
  );
}
