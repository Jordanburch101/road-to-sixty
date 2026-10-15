import { expect, test } from "bun:test";
import { Window } from "../src/limits";

test("a window allows its maximum, refuses the next, and allows again once the oldest leaves", () => {
  let now = 0;
  const w = new Window(3, 60, () => now);
  expect([w.take("pc"), w.take("pc"), w.take("pc")]).toEqual([true, true, true]);
  expect(w.take("pc")).toBe(false);
  expect(w.retryAfter("pc")).toBe(60);
  now = 59_000;
  expect(w.take("pc")).toBe(false);
  expect(w.retryAfter("pc")).toBe(1);
  now = 60_001;
  expect(w.take("pc")).toBe(true);
});

test("each PC has its own count, and a refused try isn't counted", () => {
  let now = 0;
  const w = new Window(1, 60, () => now);
  expect(w.take("a")).toBe(true);
  expect(w.take("a")).toBe(false);
  expect(w.take("a")).toBe(false);
  expect(w.take("b")).toBe(true);
  now = 60_001;
  expect(w.take("a")).toBe(true);
});
