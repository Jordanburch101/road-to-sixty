import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { and, eq, inArray } from "drizzle-orm";
import { client, db } from "../src/db";
import { prune } from "../src/prune";
import { characters, jobs, verification, versions } from "../src/schema";
import * as storage from "../src/storage";
import { remove } from "../src/storage";
import { journey, newDevice, reset, savedFile, session, stored, upload, workAll } from "./helpers";

beforeEach(reset);
afterEach(() => mock.restore());

const at = (id: number, when: string) => client`UPDATE versions SET created_at = ${when}::timestamptz WHERE id = ${id}`;
const row = async (id: number) => (await db.select().from(versions).where(eq(versions.id, id)))[0]!;
// Plays and merges n sessions in a row; returns the merged versions' ids, oldest first.
async function play(token: string, n: number) {
  const ids: number[] = [];
  for (let i = 1; i <= n; i++) {
    await upload(token, savedFile(journey({ events: Array.from({ length: i }, (_, k) => session(1000 * (k + 1))).flat() })));
    await workAll();
    const [c] = await db.select().from(characters);
    ids.push(c!.headVersionId!);
  }
  return ids;
}

// n more merged versions of the one character, made now, with files of
// their own that aren't stored (the clean-up treats a missing file as gone).
async function pile(n: number) {
  const [c] = await db.select().from(characters);
  const [head] = await db.select().from(versions).where(eq(versions.id, c!.headVersionId!));
  const made = await db
    .insert(versions)
    .values(Array.from({ length: n }, (_, i) => ({ ...head!, id: undefined, weekly: false, fingerprint: `pile-${i}`, createdAt: new Date() })))
    .returning({ id: versions.id });
  return made.map((m) => m.id);
}

test("an upload's file goes once its merge is done, not while it waits", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  const [waiting] = await db.select().from(versions).where(eq(versions.kind, "upload"));
  await prune("on");
  expect((await row(waiting!.id)).prunedAt).toBeNull();
  expect(await stored(device.userId, waiting!.fingerprint)).toBe(true);
  await workAll();
  await prune("on");
  expect((await row(waiting!.id)).prunedAt).not.toBeNull();
  expect(await stored(device.userId, waiting!.fingerprint)).toBe(false);
});

test("the newest 100 versions stay at any age; past them, each finished week's newest and the head", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  const [a, b, c, d, head] = await play(token, 5);
  await at(a!, "2025-01-06T10:00Z"); // Monday
  await at(b!, "2025-01-08T10:00Z"); // same week, newer: kept
  await at(c!, "2025-01-13T10:00Z"); // the next week's only one: kept
  // The head, in a week whose kept version is already chosen, so only the
  // rule that never prunes a head can keep it.
  await at(head!, "2025-01-14T10:00Z");
  await db.update(versions).set({ weekly: true }).where(eq(versions.id, c!));
  await prune("on");
  for (const id of [a!, b!, c!, d!, head!]) expect((await row(id)).prunedAt).toBeNull(); // all in the newest 100

  await pile(100);
  await prune("on");
  expect((await row(a!)).prunedAt).not.toBeNull();
  expect(await stored(device.userId, (await row(a!)).fingerprint)).toBe(false);
  expect((await row(d!)).prunedAt).not.toBeNull(); // past the newest 100, in a week still under way
  for (const id of [b!, c!, head!]) expect((await row(id)).prunedAt).toBeNull();
  expect([(await row(b!)).weekly, (await row(c!)).weekly]).toEqual([true, true]);
  expect([(await row(d!)).weekly, (await row(head!)).weekly]).toEqual([false, false]);
});

test("weeks are counted in UTC: Sunday 23:00 and Monday 01:00 are different weeks", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const [sun, mon] = await play(token, 3);
  await at(sun!, "2025-01-12T23:00Z");
  await at(mon!, "2025-01-13T01:00Z");
  await prune("on");
  expect([(await row(sun!)).weekly, (await row(mon!)).weekly]).toEqual([true, true]);
});

test("a file another kept version shares stays", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  const [a, b] = await play(token, 3);
  await at(a!, "2025-01-06T10:00Z");
  await at(b!, "2025-01-07T10:00Z"); // b is that week's keeper, a goes once past the newest 100
  await pile(100);
  const shared = await row(a!);
  await db.insert(versions).values({ ...shared, id: undefined, weekly: false, createdAt: new Date() });
  await prune("on");
  expect((await row(a!)).prunedAt).not.toBeNull();
  expect(await stored(device.userId, shared.fingerprint)).toBe(true);
});

test("a refused or replaced upload is kept 30 days, as the app won't send it again", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(5000)] }))); // replaces the first in the queue
  await workAll();
  const [folded] = await db.select().from(versions).where(eq(versions.status, "superseded"));
  await prune("on");
  expect((await row(folded!.id)).prunedAt).toBeNull();
  expect(await stored(device.userId, folded!.fingerprint)).toBe(true);
  await at(folded!.id, "2025-01-06T10:00Z");
  await prune("on");
  expect((await row(folded!.id)).prunedAt).not.toBeNull();
});

test("dry deletes nothing and says what it would; a second run finds nothing; a missing file doesn't stop it", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  const [a] = await play(token, 2);
  await at(a!, "2025-01-06T10:00Z");
  const uploads = await db.select().from(versions).where(eq(versions.kind, "upload"));
  const dry = await prune("dry");
  expect(dry).toEqual([{ characterId: expect.any(Number), versions: 2, files: 2, bytes: expect.any(Number) }]);
  for (const u of uploads) expect(await stored(device.userId, u.fingerprint)).toBe(true);
  expect((await db.select().from(versions)).every((v) => v.prunedAt === null)).toBe(true);

  await remove(device.userId, uploads[0]!.fingerprint);
  expect((await prune("on")).length).toBe(1);
  expect((await db.select().from(versions).where(inArray(versions.id, uploads.map((u) => u.id)))).every((v) => v.prunedAt !== null)).toBe(true);
  expect(await prune("on")).toEqual([]);
});

test("old finished jobs and expired sign-in rows go; recent ones and dry runs leave them", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(5000)] })));
  await workAll();
  const [old, recent] = await db.select().from(jobs).orderBy(jobs.id);
  await client`UPDATE jobs SET finished_at = now() - interval '31 days' WHERE id = ${old!.id}`;
  await db.insert(verification).values({ id: "v-old", identifier: "x", value: "x", expiresAt: new Date(Date.now() - 1000) });
  await db.insert(verification).values({ id: "v-live", identifier: "x", value: "x", expiresAt: new Date(Date.now() + 3600_000) });
  await prune("dry");
  expect((await db.select().from(jobs)).length).toBe(2);
  expect((await db.select().from(verification)).length).toBe(2);
  await prune("on");
  expect((await db.select().from(jobs)).map((j) => j.id)).toEqual([recent!.id]);
  expect((await db.select().from(verification)).map((v) => v.id)).toEqual(["v-live"]);
});

test("a version is marked pruned before its file is deleted, so a restore can't pick it up in between", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const [a] = await play(token, 3);
  await at(a!, "2025-01-06T10:00Z");
  const seen: (Date | null)[] = [];
  const real = storage.remove;
  spyOn(storage, "remove").mockImplementation(async (userId, fp) => {
    const rows = await db.select().from(versions).where(eq(versions.fingerprint, fp));
    seen.push(...rows.map((r) => r.prunedAt));
    return real(userId, fp);
  });
  await prune("on");
  expect(seen.length).toBeGreaterThan(0);
  expect(seen.every((t) => t !== null)).toBe(true);
});

test("one account the clean-up fails on doesn't stop it for the others", async () => {
  const ann = await newDevice("user-1", "Desk");
  const bob = await newDevice("user-2", "Desk");
  await upload(ann.token, savedFile(journey({ events: session(1000) })));
  await upload(bob.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const real = storage.remove;
  spyOn(storage, "remove").mockImplementation(async (userId, fp) => {
    if (userId === ann.device.userId) throw new Error("storage said no");
    return real(userId, fp);
  });
  await prune("on");
  const [bobUpload] = await db
    .select()
    .from(versions)
    .innerJoin(characters, eq(characters.id, versions.characterId))
    .where(and(eq(characters.userId, bob.device.userId), eq(versions.kind, "upload")));
  expect(bobUpload!.versions.prunedAt).not.toBeNull();
  expect(await stored(bob.device.userId, bobUpload!.versions.fingerprint)).toBe(false);
});
