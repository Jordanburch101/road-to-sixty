import { expect, test } from "bun:test";
import { fileUrl, link, need } from "./config";

test("a missing build setting stops the build by name", () => {
  expect(() => need("PUBLIC_CONTACT_EMAIL", undefined)).toThrow("PUBLIC_CONTACT_EMAIL");
  expect(() => need("PUBLIC_ADDON_URL", "")).toThrow("PUBLIC_ADDON_URL");
  expect(need("PUBLIC_ADDON_URL", "https://example.test")).toBe("https://example.test");
});

test("an address setting must be a full address, and loses a trailing slash", () => {
  expect(() => link("PUBLIC_ADDON_URL", "curseforge.com/wow/addons/x")).toThrow("PUBLIC_ADDON_URL");
  expect(link("PUBLIC_DOWNLOADS", "https://dl.example.test/")).toBe("https://dl.example.test");
});

test("each computer's download has the fixed name the release uploads", () => {
  expect(fileUrl("mac")).toBe("https://dl.roadtosixty.online/app/Road-to-Sixty.dmg");
  expect(fileUrl("windows")).toBe("https://dl.roadtosixty.online/app/Road-to-Sixty-Setup.exe");
  expect(fileUrl("linux")).toBe("https://dl.roadtosixty.online/app/Road-to-Sixty.AppImage");
});
