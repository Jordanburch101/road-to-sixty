// A character whose head file is missing from storage, by any cause (#114):
// merges, restores and the export carry on without it.
import type { CharacterInfo, RestoreResponse, VersionInfo } from "@road-to-sixty/api";
import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { checkHeads } from "../src/heads";
import { prune } from "../src/prune";
import { characters, jobs, versionParents, versions } from "../src/schema";
import * as storage from "../src/storage";
import { remove, unpack } from "../src/storage";
import { call, journey, newDevice, reset, savedFile, session, sessions, stored, upload, workAll } from "./helpers";

beforeEach(reset);
afterEach(() => mock.restore());

const json = async <T>(r: Response | Promise<Response>) => (await (await r).json()) as T;
const character = async () => (await db.select().from(characters))[0]!;
const version = async (id: number) => (await db.select().from(versions).where(eq(versions.id, id)))[0]!;
const download = async (token: string, id: number) => {
  const r = await call(token, `/v1/versions/${id}`);
  return { status: r.status, text: r.ok ? new TextDecoder().decode(unpack(new Uint8Array(await r.arrayBuffer()))) : "" };
};

// Two merged versions of Ann: the first with one session, the head with two.
async function twoVersions() {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const first = (await character()).headVersionId!;
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000)] })));
  await workAll();
  const head = (await character()).headVersionId!;
  return { desk, first: await version(first), head: await version(head) };
}

test("an upload onto a head whose file is missing merges onto the newest version still there", async () => {
  const errors = spyOn(console, "error").mockImplementation(() => {});
  const { desk, first, head } = await twoVersions();
  await remove(desk.device.userId, head.fingerprint);
  const laptop = await newDevice("user-1", "Laptop");
  await upload(laptop.token, savedFile(journey({ events: session(9000) })));
  await workAll();

  const c = await character();
  expect(c.headVersionId).not.toBe(head.id);
  const merged = await version(c.headVersionId!);
  expect(merged.kind).toBe("merged");
  expect(await stored(desk.device.userId, merged.fingerprint)).toBe(true);
  // The first version's play and the new upload's; the lost file's own
  // session comes back with Desk's next upload.
  const { status, text } = await download(desk.token, merged.id);
  expect(status).toBe(200);
  expect(sessions(text)).toBe(2);
  expect(text).toContain("9000");
  const parents = await db.select().from(versionParents).where(eq(versionParents.versionId, merged.id));
  expect(parents.map((p) => p.parentId)).toContain(first.id);
  const [up] = await db.select().from(versions).where(eq(versions.deviceId, laptop.device.id));
  expect(up!.status).toBe("accepted");
  expect(errors.mock.calls.some((args) => String(args[0]).includes(`version ${head.id}, has no file`))).toBe(true);

  // Desk's next session brings the lost one back.
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000), ...session(13000)] })));
  await workAll();
  expect(sessions((await download(desk.token, (await character()).headVersionId!)).text)).toBe(4);
});

test("building on an earlier version follows what the head was made from, so a restore's removed play stays out", async () => {
  spyOn(console, "error").mockImplementation(() => {});
  const desk = await newDevice("user-1", "Desk");
  const made: number[] = [];
  for (const events of [session(1000), [...session(1000), ...session(3000)], [...session(1000), ...session(3000), ...session(5000)]]) {
    await upload(desk.token, savedFile(journey({ events })));
    await workAll();
    made.push((await character()).headVersionId!);
  }
  const [first, second] = made;
  const c = await character();
  // Back to the second version, taking 5000 out. Its file is the second's.
  const r = await call(desk.token, `/v1/characters/${c.id}/restore`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ version: second }),
  });
  const { version: restored } = (await r.json()) as RestoreResponse;
  await remove(desk.device.userId, (await version(restored)).fingerprint);

  // The third version is newer and still there, but the restore replaced
  // it: the merge builds on the first, which the restore holds.
  const laptop = await newDevice("user-1", "Laptop");
  await upload(laptop.token, savedFile(journey({ events: session(9000) })), { received: String(restored) });
  await workAll();
  const head = (await character()).headVersionId!;
  const parents = await db.select().from(versionParents).where(eq(versionParents.versionId, head));
  expect(parents.map((p) => p.parentId)).toContain(first!);
  const { text } = await download(desk.token, head);
  expect(text).toContain("9000");
  expect(text).not.toContain("5000");
});

test("storage failing is not a missing file: the merge waits and tries again, and the head stays", async () => {
  const { desk, head } = await twoVersions();
  spyOn(storage, "getPackedIfThere").mockImplementation(async () => {
    throw new Error("storage is down");
  });
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000), ...session(9000)] })));
  await workAll();
  expect((await character()).headVersionId).toBe(head.id);
  const [job] = await db.select().from(jobs).where(eq(jobs.state, "queued"));
  expect(job!.error).toContain("storage is down");
});

test("a stamped upload with nothing of the pre-stamp journey left to compare goes to its own row", async () => {
  spyOn(console, "error").mockImplementation(() => {});
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const old = await character();
  await remove(desk.device.userId, (await version(old.headVersionId!)).fingerprint);
  await upload(desk.token, savedFile(journey({ journeyId: "stamp-b", events: session(9000) })));
  await workAll();
  const rows = await db.select().from(characters).orderBy(characters.id);
  expect(rows).toHaveLength(2);
  expect(rows[0]).toMatchObject({ id: old.id, journey: null, headVersionId: old.headVersionId });
  expect(rows[1]!.journey).toBe("stamp-b");
  expect(sessions((await download(desk.token, rows[1]!.headVersionId!)).text)).toBe(1);
});

test("with no version's file left, an upload is merged alone and the character works again", async () => {
  spyOn(console, "error").mockImplementation(() => {});
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const lost = await version((await character()).headVersionId!);
  await remove(desk.device.userId, lost.fingerprint);
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000)] })));
  await workAll();
  const c = await character();
  expect(c.headVersionId).not.toBe(lost.id);
  const { status, text } = await download(desk.token, c.headVersionId!);
  expect(status).toBe(200);
  expect(sessions(text)).toBe(2);
});

test("a head whose file is missing can still be restored away from", async () => {
  spyOn(console, "error").mockImplementation(() => {});
  const { desk, first, head } = await twoVersions();
  await remove(desk.device.userId, head.fingerprint);
  const [c] = await json<CharacterInfo[]>(call(desk.token, "/v1/characters"));
  const r = await call(desk.token, `/v1/characters/${c!.id}/restore`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ version: first.id }),
  });
  expect(r.status).toBe(200);
  const { version: made } = (await r.json()) as RestoreResponse;
  const history = await json<VersionInfo[]>(call(desk.token, `/v1/characters/${c!.id}/versions`));
  expect(history[0]).toMatchObject({ id: made, kind: "restore", current: true, restoredFrom: { id: first.id } });
  // Worked out from the nearest version the head was made from whose file
  // is there, the first itself, so nothing is taken out.
  expect(JSON.parse((await version(made)).removed!)).toEqual([]);
  expect((await download(desk.token, made)).status).toBe(200);
});

test("restoring a version whose file is missing answers 410 and leaves the journey as it was", async () => {
  spyOn(console, "error").mockImplementation(() => {});
  const { desk, first, head } = await twoVersions();
  await remove(desk.device.userId, first.fingerprint);
  const c = await character();
  const r = await call(desk.token, `/v1/characters/${c.id}/restore`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ version: first.id }),
  });
  expect(r.status).toBe(410);
  expect(((await r.json()) as { error: string }).error).toContain("missing");
  expect((await character()).headVersionId).toBe(head.id);
  expect(await db.select().from(versions).where(eq(versions.kind, "restore"))).toHaveLength(0);
});

test("the export leaves out a character whose file is missing, and names it", async () => {
  spyOn(console, "error").mockImplementation(() => {});
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await upload(desk.token, savedFile(journey({ events: session(2000) })), { name: "Zoe" });
  await workAll();
  const [zoe] = await db.select().from(characters).where(eq(characters.name, "Zoe"));
  await remove(desk.device.userId, (await version(zoe!.headVersionId!)).fingerprint);
  const r = await call(desk.token, "/v1/export");
  expect(r.status).toBe(200);
  const dir = await mkdtemp(join(tmpdir(), "rts-export-"));
  try {
    const path = join(dir, "export.zip");
    await Bun.write(path, await r.arrayBuffer());
    expect(Bun.spawnSync(["unzip", "-t", path]).exitCode).toBe(0);
    const listed = Bun.spawnSync(["unzip", "-Z1", path]).stdout.toString().trim().split("\n").sort();
    expect(listed).toEqual(["Missing.txt", "_classic_beta_/Test Realm/Ann.lua"]);
    const note = Bun.spawnSync(["unzip", "-p", path, "Missing.txt"]).stdout.toString();
    expect(note).toContain("_classic_beta_/Test Realm/Zoe.lua");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("the daily check logs each head whose file is missing, in a dry run too", async () => {
  const errors = spyOn(console, "error").mockImplementation(() => {});
  const logs = spyOn(console, "log").mockImplementation(() => {});
  const { desk, head } = await twoVersions();
  expect(await checkHeads()).toEqual({ checked: 1, missing: [] });
  await remove(desk.device.userId, head.fingerprint);
  expect(await checkHeads()).toEqual({ checked: 1, missing: [head.characterId] });
  errors.mockClear();
  logs.mockClear();
  await prune("dry");
  expect(errors.mock.calls.some((args) => String(args[0]).includes(`character ${head.characterId}'s head`))).toBe(true);
  expect(logs.mock.calls.some((args) => String(args[0]) === "heads: 1 checked, 1 missing")).toBe(true);
});
