import { useMemo } from "react";
import { fogAnimation, fogDelay, fogDots, type Point, type Timing } from "./dots";

// Draws the fog grid at a fixed size; the parent clips and fades it.
// animate is the loop's length in seconds; without it the fog is still.
// The length goes on each dot too, so two fogs on a page keep their speeds.
export function Fog({
  width,
  height,
  step,
  roads,
  marks = [],
  animate,
  colours,
  timing,
}: {
  width: number;
  height: number;
  step: number;
  roads: Point[][];
  marks?: Point[];
  animate?: number;
  colours?: string[];
  timing?: Timing[];
}) {
  const { lit, edge, fog } = useMemo(() => fogDots(width, height, step, roads, timing), [width, height, step, roads, timing]);
  const moving = (at: number) =>
    animate ? { className: "rts-fog-road", style: { animationDelay: fogDelay(at, animate), animationDuration: `${animate}s` } } : { style: {} };
  return (
    <svg aria-hidden="true" width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="pointer-events-none absolute left-0 top-0">
      {animate ? <style>{fogAnimation(animate)}</style> : null}
      {fog.map(([x, y]) => <circle key={`f${x},${y}`} cx={x} cy={y} r={1.1} fill="rgba(154,149,168,0.16)" />)}
      {edge.map(([x, y, at]) => <circle key={`e${x},${y}`} cx={x} cy={y} r={1.4} fill="rgba(154,149,168,0.4)" {...moving(at)} />)}
      {lit.map(([x, y, at, road]) => {
        const m = moving(at);
        const colour = colours?.[road];
        return (
          <circle
            key={`l${x},${y}`}
            cx={x}
            cy={y}
            r={1.8}
            fillOpacity={0.85}
            className={`${colour ? "" : "fill-accent"} ${m.className ?? ""}`}
            style={{ ...m.style, ...(colour ? { fill: colour } : {}) }}
          />
        );
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
