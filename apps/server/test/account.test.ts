import type { CharacterInfo, DeviceInfo, RestoreResponse, VersionInfo } from "@road-to-sixty/api";
import { beforeEach, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import { config } from "../src/config";
import { db } from "../src/db";
import { characters, devices, jobs, user, versions } from "../src/schema";
import { CHAR, call, check, journey, newDevice, reset, savedFile, session, sessions, upload, workAll } from "./helpers";

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

async function twoVersions() {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000), levels: { 3: { t: 900 } } })));
  await workAll();
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000)], levels: { 3: { t: 900 }, 4: { t: 4900 } } })));
  await workAll();
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  const [newest, older] = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c!.id}/versions`));
  return { desk, c: c!, newest: newest!, older: older! };
}

const restore = (token: string, id: number, version: number) =>
  call(token, `/v1/characters/${id}/restore`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ version }),
  });

test("restoring a version makes it current again, keeps the old one in history, and is sent as a restore", async () => {
  const { desk, c, newest, older } = await twoVersions();
  const { version } = await json<RestoreResponse>(restore(desk.token, c.id, older.id));
  const history = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c.id}/versions`));
  expect(history[0]).toMatchObject({ id: version, kind: "restore", level: 3, current: true, restoredFrom: { id: older.id } });
  expect(history.map((v) => v.id)).toContain(newest.id);
  const [entry] = (await check(desk.token)).characters;
  expect(entry).toMatchObject({ version, restore: version, replace: true });
});

test("a restore can't pick the current version, or another player's", async () => {
  const { desk, c, newest, older } = await twoVersions();
  expect((await restore(desk.token, c.id, newest.id)).status).toBe(400);
  const other = await newDevice("user-2", "Elsewhere");
  expect((await restore(other.token, c.id, older.id)).status).toBe(404);
  expect((await restore(desk.token, c.id, 999999)).status).toBe(404);
});

test("an upload waiting to be merged when a restore is picked is set aside, not merged on top", async () => {
  const { desk, c, older } = await twoVersions();
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000), ...session(9000)] })));
  const { version } = await json<RestoreResponse>(restore(desk.token, c.id, older.id));
  await workAll();
  const [after] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  const [head] = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c.id}/versions`));
  expect(head).toMatchObject({ id: version, current: true });
  expect(after!.level).toBe(3);
});

test("the PC list shows each linked PC with its versions and when it was last seen", async () => {
  const desk = await newDevice("user-1", "Desk");
  await newDevice("user-1", "Laptop");
  await newDevice("user-2", "Elsewhere");
  await call(desk.token, "/v1/check?addon=1.9.0&app=0.1.2");
  const list = await json<DeviceInfo[]>(call(desk.token, "/v1/devices"));
  expect(list.map((d) => d.name)).toEqual(["Desk", "Laptop"]);
  expect(list[0]).toMatchObject({ id: desk.device.id, addonVersion: "1.9.0", appVersion: "0.1.2" });
});

test("a PC can be renamed; a name is trimmed to 40 characters and can't be empty", async () => {
  const desk = await newDevice("user-1", "Desk");
  const rename = (name: unknown) =>
    call(desk.token, `/v1/devices/${desk.device.id}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name }),
    });
  expect(await json<DeviceInfo>(rename("  ROG   Ally\n"))).toMatchObject({ name: "ROG Ally" });
  expect((await json<DeviceInfo>(rename("x".repeat(200)))).name).toHaveLength(40);
  expect((await rename("   ")).status).toBe(400);
  expect((await rename(12)).status).toBe(400);
});

test("unlinking a PC stops its token at once, from itself or another PC, but not another player's", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  const other = await newDevice("user-2", "Elsewhere");
  expect((await call(other.token, `/v1/devices/${laptop.device.id}`, { method: "DELETE" })).status).toBe(404);
  expect((await call(desk.token, `/v1/devices/${laptop.device.id}`, { method: "DELETE" })).status).toBe(200);
  expect((await call(laptop.token, "/v1/check")).status).toBe(401);
  expect((await json<DeviceInfo[]>(call(desk.token, "/v1/devices"))).map((d) => d.name)).toEqual(["Desk"]);
  expect((await call(desk.token, `/v1/devices/${desk.device.id}`, { method: "DELETE" })).status).toBe(200);
  expect((await call(desk.token, "/v1/check")).status).toBe(401);
});

test("the export is a zip of each character's journey that unzip accepts, accents and all", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await upload(desk.token, savedFile(journey({ events: session(2000) })), { realm: "Azjol-Nérub", name: "Zoë" });
  await workAll();
  const r = await call(desk.token, "/v1/export");
  expect(r.headers.get("content-type")).toBe("application/zip");
  const dir = await mkdtemp(join(tmpdir(), "rts-export-"));
  try {
    const path = join(dir, "export.zip");
    await Bun.write(path, await r.arrayBuffer());
    const tested = Bun.spawnSync(["unzip", "-t", path]);
    expect(tested.exitCode).toBe(0);
    // Apple's unzip ignores the UTF-8 flag and garbles accented names, so
    // the names are read with Python's zipfile, which honours it.
    const names = Bun.spawnSync(["python3", "-I", "-c", "import sys, zipfile; print('\\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))", path]);
    const listed = names.stdout.toString().trim().split("\n").sort();
    expect(listed).toEqual(["_classic_beta_/Azjol-Nérub/Zoë.lua", "_classic_beta_/Test Realm/Ann.lua"]);
    const text = Bun.spawnSync(["unzip", "-p", path, "_classic_beta_/Test Realm/Ann.lua"]).stdout.toString();
    expect(text.startsWith("RoadToSixtyCharDB = ")).toBe(true);
    expect(sessions(text)).toBe(1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("delete everything removes the player's rows, files and PCs, even with a merge waiting, and no one else's", async () => {
  const desk = await newDevice("user-1", "Desk");
  const other = await newDevice("user-2", "Elsewhere");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await upload(other.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(desk.token, savedFile(journey({ events: session(5000) }))); // still queued
  expect((await call(desk.token, "/v1/account", { method: "DELETE" })).status).toBe(200);

  expect((await call(desk.token, "/v1/check")).status).toBe(401);
  expect(await db.select().from(user).where(eq(user.id, "user-1"))).toEqual([]);
  expect(await db.select().from(devices).where(eq(devices.userId, "user-1"))).toEqual([]);
  expect(await db.select().from(characters).where(eq(characters.userId, "user-1"))).toEqual([]);
  expect((await db.select().from(jobs)).length).toBe(1); // only user-2's finished job is left
  const s3 = new Bun.S3Client(config.s3);
  expect((await s3.list({ prefix: "user-1/" })).contents ?? []).toEqual([]);
  expect(((await s3.list({ prefix: "user-2/" })).contents ?? []).length).toBeGreaterThan(0);
  expect((await call(other.token, "/v1/check")).status).toBe(200);
  expect((await db.select().from(versions)).length).toBeGreaterThan(0);
});
