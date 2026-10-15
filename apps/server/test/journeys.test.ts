// One journey per character (spec 2026-10-15, journeys): stamps, which row
// an upload goes to, current and earlier journeys, removing a character.
// GUIDs here are made up.
import type { CharacterInfo } from "@road-to-sixty/api";
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { characters, jobs, versions } from "../src/schema";
import { unpack } from "../src/storage";
import { stampOf } from "../src/sync";
import { CHAR, addUser, call, check, journey, newDevice, reset, savedFile, session, sessions, stored, upload, workAll } from "./helpers";

beforeEach(reset);
afterEach(() => mock.restore());

const A = "Player-1-0A";
const B = "Player-1-0B";
const stamped = (stamp: string, events: unknown[] = session(1000)) => savedFile(journey({ journeyId: stamp, events }));
const rows = () => db.select().from(characters).orderBy(characters.id);
const download = async (token: string, id: number) =>
  unpack(new Uint8Array(await (await call(token, `/v1/versions/${id}`)).arrayBuffer()));

test("a name holds several journeys but only one from before stamps", async () => {
  const userId = await addUser("user-1");
  const row = (journey: string | null) => ({ userId, ...CHAR, journey });
  await db.insert(characters).values([row(null), row("Player-1-0A:0"), row("Player-1-0A:7000")]);
  await expect(db.insert(characters).values(row(null)).execute()).rejects.toThrow();
  await expect(db.insert(characters).values(row("Player-1-0A:0")).execute()).rejects.toThrow();
});

test("the stamp is read from the uploaded file, and a malformed one is refused", async () => {
  expect(stampOf(stamped(`${A}:0`))).toBe(`${A}:0`);
  expect(stampOf(savedFile(journey()))).toBeNull();
  expect(stampOf(stamped(`Player-1-${"0".repeat(60)}:0`))).toBeUndefined();
  expect(stampOf(stamped("no colon"))).toBeUndefined();
  const { token } = await newDevice("user-1", "Desk");
  expect((await upload(token, stamped("no colon"))).status).toBe(400);
});

test("a stamped upload adopts the same journey from before stamps", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, stamped(`${A}:0`, [...session(1000), ...session(5000)]));
  await workAll();
  const [only, ...more] = await rows();
  expect(more).toEqual([]);
  expect(only!.journey).toBe(`${A}:0`);
  const [entry] = (await check(token)).characters;
  expect(sessions(await download(token, entry!.version!))).toBe(2);
});

test("a namesake remade before its old journey had a stamp gets a journey of its own, which becomes current", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, stamped(`${B}:0`, session(9000)));
  await workAll();
  const [old, made] = await rows();
  expect(old!.journey).toBeNull();
  expect(made!.journey).toBe(`${B}:0`);
  expect(sessions(await download(token, old!.headVersionId!))).toBe(1);
  expect(sessions(await download(token, made!.headVersionId!))).toBe(1);
});

test("two uploads of a namesake queued before the worker runs both go to its new journey", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(desk.token, stamped(`${B}:0`, session(9000)));
  await upload(laptop.token, stamped(`${B}:0`, [...session(9000), ...session(9500)]));
  await workAll();
  const all = await rows();
  expect(all).toHaveLength(2);
  expect(sessions(await download(desk.token, all[1]!.headVersionId!))).toBe(2);
  expect(await db.select().from(jobs).where(eq(jobs.state, "failed"))).toEqual([]);
});

test("an erase starts a new journey; a PC still on the old one keeps updating that one", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  await upload(desk.token, stamped(`${A}:0`, session(1000)));
  await workAll();
  await upload(desk.token, stamped(`${A}:7000`, session(8000)));
  await workAll();
  await upload(laptop.token, stamped(`${A}:0`, [...session(1000), ...session(3000)]));
  await workAll();
  const [old, erased] = await rows();
  expect(old!.journey).toBe(`${A}:0`);
  expect(erased!.journey).toBe(`${A}:7000`);
  expect(sessions(await download(desk.token, old!.headVersionId!))).toBe(2);
  expect(sessions(await download(desk.token, erased!.headVersionId!))).toBe(1);
});

test("an upload from an addon before stamps never joins a newer journey", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, stamped(`${A}:0`, session(1000)));
  await workAll();
  await upload(token, stamped(`${A}:7000`, session(8000)));
  await workAll();
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(2000)] })));
  await workAll();
  const [old, erased] = await rows();
  expect(sessions(await download(token, old!.headVersionId!))).toBe(2);
  expect(sessions(await download(token, erased!.headVersionId!))).toBe(1);
});

test("a new journey of a name counts toward the 100", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await db
    .insert(characters)
    .values(Array.from({ length: 99 }, (_, i) => ({ userId: device.userId, game: CHAR.game, realm: CHAR.realm, name: `Alt${i}` })));
  expect((await upload(token, stamped(`${A}:0`))).status).toBe(200);
  const refused = await upload(token, stamped(`${A}:7000`, session(8000)));
  expect(refused.status).toBe(422);
  expect(await refused.text()).toBe("This account has reached 100 characters");
});

test("check offers only a name's current journey, and the list marks the earlier one", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, stamped(`${B}:0`, session(9000)));
  await workAll();
  const [old, made] = await rows();
  expect((await check(token)).characters.map((c) => c.version)).toEqual([made!.headVersionId]);
  const list = (await (await call(token, "/v1/characters")).json()) as CharacterInfo[];
  expect(list.map((c) => [c.id, c.earlier])).toEqual([
    [old!.id, true],
    [made!.id, false],
  ]);
});

test("the export names an earlier journey apart from the current one", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, stamped(`${B}:0`, session(9000)));
  await workAll();
  const [old] = await rows();
  const dir = await mkdtemp(join(tmpdir(), "rts-export-"));
  try {
    const path = join(dir, "export.zip");
    await Bun.write(path, await (await call(token, "/v1/export")).arrayBuffer());
    const names = Bun.spawnSync(["python3", "-I", "-c", "import sys, zipfile; print('\\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))", path]);
    expect(names.stdout.toString().trim().split("\n").sort()).toEqual([
      `_classic_beta_/Test Realm/Ann (earlier ${old!.id}).lua`,
      "_classic_beta_/Test Realm/Ann.lua",
    ]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

const remove = (token: string, id: number) => call(token, `/v1/characters/${id}`, { method: "DELETE" });

test("removing a character takes its rows and files, and frees its place", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await rows();
  const files = (await db.select().from(versions).where(eq(versions.characterId, c!.id))).map((v) => v.fingerprint);
  expect((await remove(token, c!.id)).status).toBe(200);
  expect(await rows()).toEqual([]);
  expect(await db.select().from(versions)).toEqual([]);
  for (const fp of files) expect(await stored("user-1", fp)).toBe(false);
  expect((await check(token)).characters).toEqual([]);
});

test("removing a character keeps a file another character shares", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const file = savedFile(journey({ events: session(1000) }));
  await upload(token, file);
  await upload(token, file, { name: "Bob" });
  await workAll();
  const [ann, bob] = await rows();
  expect((await remove(token, ann!.id)).status).toBe(200);
  expect(sessions(await download(token, bob!.headVersionId!))).toBe(1);
});

test("removing another player's character, or one that isn't there, is not found", async () => {
  const mine = await newDevice("user-1", "Desk");
  const theirs = await newDevice("user-2", "Elsewhere");
  await upload(theirs.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await rows();
  expect((await remove(mine.token, c!.id)).status).toBe(404);
  expect((await remove(mine.token, 999)).status).toBe(404);
  expect(await rows()).toHaveLength(1);
});

test("removing a character while its merge runs answers 409 and keeps it", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await db.update(jobs).set({ state: "running", claimedAt: new Date() });
  const [c] = await rows();
  const r = await remove(token, c!.id);
  expect(r.status).toBe(409);
  expect(((await r.json()) as { error: string }).error).toBe("Its latest upload is being merged; try again in a minute");
  expect(await rows()).toHaveLength(1);
});

test("a removed character's place under the 100 frees at once", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await db
    .insert(characters)
    .values(Array.from({ length: 100 }, (_, i) => ({ userId: device.userId, game: CHAR.game, realm: CHAR.realm, name: `Alt${i}` })));
  expect((await upload(token, savedFile(journey({ events: session(1000) })))).status).toBe(422);
  const [first] = await rows();
  expect((await remove(token, first!.id)).status).toBe(200);
  expect((await upload(token, savedFile(journey({ events: session(1000) })))).status).toBe(200);
});

test("a name's current journey can't be removed before its earlier ones, which would become current again", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, stamped(`${A}:0`, session(1000)));
  await workAll();
  await upload(token, stamped(`${A}:7000`, session(8000)));
  await workAll();
  const [old, erased] = await rows();
  const refused = await remove(token, erased!.id);
  expect(refused.status).toBe(409);
  expect(((await refused.json()) as { error: string }).error).toBe("Remove this character's earlier journeys first");
  expect((await check(token)).characters.map((c) => c.version)).toEqual([erased!.headVersionId]);
  expect((await remove(token, old!.id)).status).toBe(200);
  expect((await remove(token, erased!.id)).status).toBe(200);
  expect(await rows()).toEqual([]);
});
