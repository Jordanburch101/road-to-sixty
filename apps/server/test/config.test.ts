import { expect, test } from "bun:test";
import { pruneMode } from "../src/config";

test("the clean-up runs dry unless told otherwise, and refuses a value it doesn't know", () => {
  expect(pruneMode(undefined)).toBe("dry");
  expect(pruneMode("on")).toBe("on");
  expect(pruneMode("off")).toBe("off");
  expect(() => pruneMode("yes")).toThrow("PRUNE");
});
