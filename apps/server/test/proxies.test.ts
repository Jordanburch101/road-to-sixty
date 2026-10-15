import { expect, test } from "bun:test";
import { getIP } from "@better-auth/core/utils/ip";
import { auth } from "../src/auth";
import { TRUSTED_PROXIES } from "../src/proxies";

const ip = (headers: Record<string, string>) => getIP(new Headers(headers), auth.options);

test("through Cloudflare, the visitor is the address Cloudflare saw", () => {
  expect(ip({ "x-forwarded-for": "198.51.100.7, 172.70.1.2" })).toBe("198.51.100.7");
  expect(ip({ "x-forwarded-for": "172.70.1.2", "cf-connecting-ip": "198.51.100.7" })).toBe("198.51.100.7");
});

test("straight at the server, a forged header can't change the visitor", () => {
  expect(ip({ "x-forwarded-for": "198.51.100.7, 203.0.113.9" })).toBe("203.0.113.9");
  expect(ip({ "x-forwarded-for": "172.70.1.2, 203.0.113.9", "cf-connecting-ip": "198.51.100.7" })).toBe("203.0.113.9");
});

test("Cloudflare's ranges are all valid, and link codes have their own limit", () => {
  expect(TRUSTED_PROXIES).toContain("172.64.0.0/13");
  expect(auth.options.rateLimit?.customRules?.["/device/code"]).toEqual({ window: 60, max: 10 });
});
