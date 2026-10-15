import { expect, test } from "bun:test";
import { digits, LAUNCH } from "./countdown";

test("launch is 23:00 UTC on 4 November", () => {
  expect(new Date(LAUNCH).toISOString()).toBe("2026-11-04T23:00:00.000Z");
});

test("the time left reads as days, hours, minutes and seconds", () => {
  expect(digits(((20 * 24 + 7) * 3600 + 5 * 60 + 9) * 1000 + 999)).toBe("20070509");
});

test("the board stops at zero", () => {
  expect(digits(0)).toBe("00000000");
  expect(digits(-5000)).toBe("00000000");
});
