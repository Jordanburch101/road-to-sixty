import { expect, test } from "bun:test";
import { fogDots } from "./dots";

test("dots on the road are lit, near it half lit, the rest fogged", () => {
  const road: [number, number][] = [[0, 50], [200, 50]];
  const { lit, edge, fog } = fogDots(200, 200, 20, [road]);
  expect(lit).toContainEqual([70, 50]);
  expect(edge).toContainEqual([70, 90]);
  expect(fog).toContainEqual([70, 150]);
  expect(lit.length + edge.length + fog.length).toBe(100);
});

test("with no roads everything is fogged", () => {
  const { lit, edge, fog } = fogDots(100, 100, 50, []);
  expect([lit.length, edge.length, fog.length]).toEqual([0, 0, 4]);
});
