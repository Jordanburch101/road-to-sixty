import { type CSSProperties, useMemo } from "react";
import { fogAnimation, fogDelay, fogDots, type Point, type Timing } from "./dots";

// Draws the fog grid at a fixed size; the parent clips and fades it.
// animate is the loop's length in seconds; without it the fog is still.
// The length is set on the svg (--rts-fog-s), so two fogs on a page keep
// their speeds. The faint grid is one repeating pattern: a circle per dot
// made the website's hero thousands of elements.
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
  const { lit, edge } = useMemo(() => fogDots(width, height, step, roads, timing), [width, height, step, roads, timing]);
  const moving = (at: number) =>
    animate ? { className: "rts-fog-road", style: { animationDelay: fogDelay(at, animate) } } : { style: {} };
  // Named by its size, so the website's two fogs don't share one pattern.
  const grid = `rts-fog-${width}-${height}-${step}`;
  return (
    <svg aria-hidden="true" width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="pointer-events-none absolute left-0 top-0"
      style={animate ? ({ "--rts-fog-s": `${animate}s` } as CSSProperties) : undefined}
    >
      {animate ? <style>{fogAnimation(animate)}</style> : null}
      <pattern id={grid} width={step} height={step} patternUnits="userSpaceOnUse">
        <circle cx={step / 2} cy={step / 2} r={1.1} fill="rgba(154,149,168,0.16)" />
      </pattern>
      <rect width={width} height={height} fill={`url(#${grid})`} />
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
