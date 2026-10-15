import { beforeEach, expect, test } from "bun:test";
import { eq, inArray } from "drizzle-orm";
import { client, db } from "../src/db";
import { prune } from "../src/prune";
import { characters, versions } from "../src/schema";
import { remove } from "../src/storage";
import { journey, newDevice, reset, savedFile, session, stored, upload, workAll } from "./helpers";

beforeEach(reset);

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

test("versions from the last 30 days stay; older, the newest of each week and the head stay", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  const [a, b, c, d, head] = await play(token, 5);
  await at(a!, "2025-01-06T10:00Z"); // Monday
  await at(b!, "2025-01-08T10:00Z"); // same week, newer: kept
  await at(c!, "2025-01-13T10:00Z"); // the next week's only one: kept
  await at(head!, "2025-01-01T10:00Z"); // the head stays at any age
  await prune("on");
  expect((await row(a!)).prunedAt).not.toBeNull();
  expect(await stored(device.userId, (await row(a!)).fingerprint)).toBe(false);
  for (const id of [b!, c!, d!, head!]) expect((await row(id)).prunedAt).toBeNull();
  expect([(await row(b!)).weekly, (await row(c!)).weekly]).toEqual([true, true]);
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
  await at(b!, "2025-01-07T10:00Z"); // b is that week's keeper, a is pruned
  const shared = await row(a!);
  await db.insert(versions).values({ ...shared, id: undefined, weekly: false, createdAt: new Date() });
  await prune("on");
  expect((await row(a!)).prunedAt).not.toBeNull();
  expect(await stored(device.userId, shared.fingerprint)).toBe(true);
});

test("dry deletes nothing and says what it would; a second run finds nothing; a missing file doesn't stop it", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  const [a] = await play(token, 2);
  await at(a!, "2025-01-06T10:00Z");
  await db.update(versions).set({ weekly: true }).where(eq(versions.id, a!)); // not the one tested here
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
