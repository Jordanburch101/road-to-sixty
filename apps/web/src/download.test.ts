import { expect, test } from "bun:test";
import { pick } from "./download";

const mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
const windows = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const android = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36";
const linux = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

test("a Mac gets the Mac download and Windows the Windows one", () => {
  expect(pick({ userAgent: mac, maxTouchPoints: 0 })).toBe("mac");
  expect(pick({ userAgent: windows })).toBe("windows");
  expect(pick({ userAgent: "", platform: "Windows" })).toBe("windows");
  expect(pick({ userAgent: "", platform: "macOS", maxTouchPoints: 0 })).toBe("mac");
});

test("phones, tablets, Linux and anything unknown are offered both", () => {
  expect(pick({ userAgent: iphone })).toBe("choose");
  expect(pick({ userAgent: android })).toBe("choose");
  expect(pick({ userAgent: linux })).toBe("choose");
  expect(pick({ userAgent: "" })).toBe("choose");
});

test("an iPad, whose browser says it is a Mac, is offered both", () => {
  expect(pick({ userAgent: mac, maxTouchPoints: 5 })).toBe("choose");
});
