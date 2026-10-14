import { useMemo } from "react";
import { fogAnimation, fogDelay, fogDots, type Point } from "./dots";

// Draws the fog grid at a fixed size; the parent clips and fades it.
// animate is the loop's length in seconds; without it the fog is still.
export function Fog({ width, height, step, roads, marks = [], animate }: { width: number; height: number; step: number; roads: Point[][]; marks?: Point[]; animate?: number }) {
  const { lit, edge, fog } = useMemo(() => fogDots(width, height, step, roads), [width, height, step, roads]);
  const road = (at: number) => (animate ? { className: "rts-fog-road", style: { animationDelay: fogDelay(at, animate) } } : {});
  return (
    <svg aria-hidden="true" width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="pointer-events-none absolute left-0 top-0">
      {animate && <style>{fogAnimation(animate)}</style>}
      {fog.map(([x, y]) => <circle key={`f${x},${y}`} cx={x} cy={y} r={1.1} fill="rgba(154,149,168,0.16)" />)}
      {edge.map(([x, y, at]) => <circle key={`e${x},${y}`} cx={x} cy={y} r={1.4} fill="rgba(154,149,168,0.4)" {...road(at)} />)}
      {lit.map(([x, y, at]) => {
        const r = road(at);
        return <circle key={`l${x},${y}`} cx={x} cy={y} r={1.8} fillOpacity={0.85} className={`fill-accent ${r.className ?? ""}`} style={r.style} />;
      })}
      {marks.map(([x, y]) => (
        <g key={`m${x},${y}`}>
          <circle cx={x} cy={y} r={8} fill="none" className="stroke-accent" strokeOpacity={0.35} />
          <circle cx={x} cy={y} r={3} className="fill-accent" />
        </g>
      ))}
    </svg>
  );
}
