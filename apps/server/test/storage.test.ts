import { beforeAll, expect, test } from "bun:test";
import { MAX_RAW, fingerprint, get, pack, put, unpack } from "../src/storage";
import { reset } from "./helpers";

beforeAll(reset);

test("a file is stored once under its fingerprint and read back", async () => {
  const raw = new TextEncoder().encode("RoadToSixtyCharDB = {}");
  const fp = fingerprint(raw);
  expect(fp).toMatch(/^[0-9a-f]{64}$/);
  await put("user-1", fp, pack(raw));
  await put("user-1", fp, pack(raw));
  expect(new TextDecoder().decode(await get("user-1", fp))).toBe("RoadToSixtyCharDB = {}");
});

test("unpacking refuses more than 32 MB, however small the packed file", () => {
  const bomb = pack(new Uint8Array(MAX_RAW + 1));
  expect(bomb.length).toBeLessThan(10_000);
  expect(() => unpack(bomb)).toThrow();
  expect(unpack(pack(new Uint8Array(MAX_RAW))).length).toBe(MAX_RAW);
});
