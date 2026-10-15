import { expect, test } from "bun:test";
import { latestJson } from "./latest-json";

test("both Mac processors get the universal build, Windows its installer, Linux its AppImage", () => {
  const json = latestJson({
    version: "0.1.0",
    base: "https://dl.example",
    pubDate: "2026-10-14T00:00:00Z",
    mac: { file: "Road-to-Sixty.app.tar.gz", signature: "m" },
    windows: { file: "Road-to-Sixty_0.1.0_x64-setup.exe", signature: "w" },
    linux: { file: "Road-to-Sixty_0.1.0_amd64.AppImage", signature: "l" },
  });
  expect(json.platforms["darwin-aarch64"]).toEqual({ url: "https://dl.example/app/0.1.0/Road-to-Sixty.app.tar.gz", signature: "m" });
  expect(json.platforms["darwin-x86_64"]).toEqual(json.platforms["darwin-aarch64"]);
  expect(json.platforms["windows-x86_64"]).toEqual({ url: "https://dl.example/app/0.1.0/Road-to-Sixty_0.1.0_x64-setup.exe", signature: "w" });
  expect(json.platforms["linux-x86_64"]).toEqual({ url: "https://dl.example/app/0.1.0/Road-to-Sixty_0.1.0_amd64.AppImage", signature: "l" });
  expect(json.version).toBe("0.1.0");
});
