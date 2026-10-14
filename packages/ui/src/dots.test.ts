import { expect, test } from "bun:test";
import { fogAnimation, fogDelay, fogDots } from "./dots";

const xy = (dots: number[][]) => dots.map(([x, y]) => [x, y]);

test("dots on the road are lit, near it half lit, the rest fogged", () => {
  const road: [number, number][] = [[0, 50], [200, 50]];
  const { lit, edge, fog } = fogDots(200, 200, 20, [road]);
  expect(xy(lit)).toContainEqual([70, 50]);
  expect(xy(edge)).toContainEqual([70, 90]);
  expect(fog).toContainEqual([70, 150]);
  expect(lit.length + edge.length + fog.length).toBe(100);
});

test("with no roads everything is fogged", () => {
  const { lit, edge, fog } = fogDots(100, 100, 50, []);
  expect([lit.length, edge.length, fog.length]).toEqual([0, 0, 4]);
});

test("each lit dot knows how far along its road it sits, so the light can travel along it", () => {
  const road: [number, number][] = [[0, 50], [100, 50], [200, 50]];
  const { lit } = fogDots(200, 100, 20, [road]);
  const at = (x: number) => lit.find(([lx, ly]) => lx === x && ly === 50)![2];
  expect(at(10)).toBeCloseTo(0.05);
  expect(at(190)).toBeCloseTo(0.95);
});

test("the animation starts each dot as far into its loop as it is along the road, and stays still for reduced motion", () => {
  expect(fogDelay(0.25, 20)).toBe("-15.00s");
  expect(fogDelay(0, 14)).toBe("-14.00s");
  const css = fogAnimation(14);
  expect(css).toContain("rts-fog-road");
  expect(css).toContain("14s");
  expect(css).toContain("prefers-reduced-motion");
});

test("each lit dot knows which road it is on", () => {
  const top: [number, number][] = [[0, 20], [200, 20]];
  const bottom: [number, number][] = [[0, 180], [200, 180]];
  const { lit } = fogDots(200, 200, 20, [top, bottom]);
  expect(lit.find(([x, y]) => x === 90 && y === 10)![3]).toBe(0);
  expect(lit.find(([x, y]) => x === 90 && y === 190)![3]).toBe(1);
});

test("a timed road lights only in its own share of the loop", () => {
  const first: [number, number][] = [[0, 20], [200, 20]];
  const then: [number, number][] = [[0, 180], [200, 180]];
  const { lit } = fogDots(200, 200, 20, [first, then], [{ start: 0, share: 0.5 }, { start: 0.5, share: 0.5 }]);
  for (const [, , at, road] of lit) {
    if (road === 0) expect(at).toBeLessThanOrEqual(0.5);
    else expect(at).toBeGreaterThanOrEqual(0.5);
  }
});
