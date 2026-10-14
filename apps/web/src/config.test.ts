import { expect, test } from "bun:test";
import { need } from "./config";

test("a missing build setting stops the build by name", () => {
  expect(() => need("PUBLIC_CONTACT_EMAIL", undefined)).toThrow("PUBLIC_CONTACT_EMAIL");
  expect(() => need("PUBLIC_ADDON_URL", "")).toThrow("PUBLIC_ADDON_URL");
  expect(need("PUBLIC_ADDON_URL", "https://example.test")).toBe("https://example.test");
});
