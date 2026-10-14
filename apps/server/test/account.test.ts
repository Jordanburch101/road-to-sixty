import type { CharacterInfo, VersionInfo } from "@road-to-sixty/api";
import { beforeEach, expect, test } from "bun:test";
import { CHAR, call, journey, newDevice, reset, savedFile, session, upload, workAll } from "./helpers";

beforeEach(reset);

const json = async <T>(r: Response | Promise<Response>) => (await (await r).json()) as T;

test("the characters list says class, level, time played and which PC last synced each", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000), levels: { 7: { t: 900 } }, played: 4000, class: "WARRIOR" })));
  await workAll();
  const list = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  expect(list).toEqual([expect.objectContaining({ ...CHAR, class: "WARRIOR", level: 7, played: 4000, syncedFrom: "Desk" })]);
  expect(Date.parse(list[0]!.syncedAt)).toBeGreaterThan(0);
  expect(list[0]!.lastPlayedAt).toBe(new Date(1120 * 1000).toISOString());
});

test("a journey with no level snapshots lists its level as unknown", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  expect(c!.level).toBeNull();
  const [v] = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c!.id}/versions`));
  expect(v!.level).toBeNull();
});

test("a character's history lists each merged version, newest first, with the PC that made it", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  await upload(desk.token, savedFile(journey({ events: session(1000), levels: { 3: { t: 900 } } })));
  await workAll();
  await upload(laptop.token, savedFile(journey({ events: session(5000), levels: { 4: { t: 4900 } } })));
  await workAll();
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  const history = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c!.id}/versions`));
  expect(history.map((v) => [v.kind, v.from, v.level, v.current])).toEqual([
    ["merged", "Laptop", 4, true],
    ["merged", "Desk", 3, false],
  ]);
  expect(history[0]!.restoredFrom).toBeNull();
});

test("another player's character is not found", async () => {
  const desk = await newDevice("user-1", "Desk");
  const other = await newDevice("user-2", "Elsewhere");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  expect(await json<CharacterInfo[]>(call(other.token, "/v1/characters"))).toEqual([]);
  expect((await call(other.token, `/v1/characters/${c!.id}/versions`)).status).toBe(404);
  expect((await call(other.token, "/v1/characters/nonsense/versions")).status).toBe(404);
});

test("the account routes need a live PC token", async () => {
  expect((await call("nope", "/v1/characters")).status).toBe(401);
});
