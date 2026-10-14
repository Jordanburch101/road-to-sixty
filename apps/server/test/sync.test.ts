import type { CheckResponse, RestoreResponse, UploadResponse } from "@road-to-sixty/api";
import { beforeEach, expect, test } from "bun:test";
import { eq } from "drizzle-orm";
import { app } from "../src/app";
import { config } from "../src/config";
import { client, db } from "../src/db";
import { newDevice as linkDevice } from "../src/devices";
import { characters, devices, jobs, versions } from "../src/schema";
import { pack, unpack } from "../src/storage";
import { MAX_ATTEMPTS, SERVER_FAILED, work } from "../src/worker";
import { CHAR, call, check, journey, newDevice, reset, savedFile, session, sessions, upload, workAll } from "./helpers";

beforeEach(reset);

test("a PC needs a token that is known and not revoked", async () => {
  expect((await app.handle(new Request("http://local/v1/check"))).status).toBe(401);
  expect((await call("nope", "/v1/check")).status).toBe(401);
  const { device, token } = await newDevice("user-1", "Desk");
  expect((await call(token, "/v1/check")).status).toBe(200);
  await db.update(devices).set({ revokedAt: new Date() }).where(eq(devices.id, device.id));
  expect((await call(token, "/v1/check")).status).toBe(401);
});

test("an upload is refused when it isn't zstd, is too large, or is compiled Lua", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const query = new URLSearchParams(CHAR);
  expect((await call(token, `/v1/upload?${query}`, { method: "POST", body: "plain text" })).status).toBe(413);
  expect((await call(token, `/v1/upload?${query}`, { method: "POST", body: pack(new Uint8Array(33 * 1024 * 1024)) })).status).toBe(413);
  expect((await upload(token, new Uint8Array([0x1b, 0x4c, 0x75, 0x61]))).status).toBe(400);
  expect((await call(token, "/v1/upload", { method: "POST", body: pack(savedFile(journey())) })).status).toBe(400);
});

test("the first upload becomes the character's journey, and the same file again is known", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const file = savedFile(journey({ events: session(1000), levels: { 4: { t: 900 } }, played: 600, class: "PRIEST" }));
  const first = (await (await upload(token, file)).json()) as UploadResponse;
  expect(first.status).toBe("queued");
  expect(((await (await upload(token, file)).json()) as UploadResponse).status).toBe("known");
  expect((await check(token)).characters).toEqual([]); // nothing merged yet

  await workAll();
  const [entry] = (await check(token)).characters;
  expect(entry).toMatchObject({ ...CHAR, replace: false, updateAddon: false });
  const [c] = await db.select().from(characters);
  expect(c).toMatchObject({ level: 4, played: 600, class: "PRIEST", headVersionId: entry!.version });
  const [merged] = await db.select().from(versions).where(eq(versions.id, entry!.version!));
  expect(merged!.level).toBe(4);

  const download = await call(token, `/v1/versions/${entry!.version}`);
  expect(download.headers.get("content-type")).toBe("application/zstd");
  expect(sessions(unpack(new Uint8Array(await download.arrayBuffer())))).toBe(1);
});

test("two PCs' play becomes one journey that both can download, and only their own user's", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  const other = await newDevice("user-2", "Elsewhere");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(laptop.token, savedFile(journey({ events: session(5000) })));
  await workAll();

  const [entry] = (await check(laptop.token)).characters;
  const text = unpack(new Uint8Array(await (await call(desk.token, `/v1/versions/${entry!.version}`)).arrayBuffer()));
  expect(sessions(text)).toBe(2);
  expect((await call(other.token, `/v1/versions/${entry!.version}`)).status).toBe(404);
  expect((await check(other.token)).characters).toEqual([]);
  const parents = await db.select().from(versions).where(eq(versions.kind, "merged"));
  expect(parents).toHaveLength(2);
});

test("an upload the merge refuses is rejected with its reason, and the journey stays", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const before = (await check(token)).characters[0]!.version;
  await upload(token, savedFile(journey({ events: session(5000), seeded: true })));
  await workAll();
  const [rejected] = await db.select().from(versions).where(eq(versions.status, "rejected"));
  expect(rejected?.rejectReason).toMatch(/seeded/);
  expect((await check(token)).characters[0]!.version).toBe(before);
});

test("a PC whose addon writes an older layout is told to update instead of given a newer one", async () => {
  const fresh = await newDevice("user-1", "Desk");
  const old = await newDevice("user-1", "Old laptop");
  await upload(fresh.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await upload(old.token, savedFile(journey({ version: 2, events: session(5000) })));
  await workAll();
  expect((await check(fresh.token)).characters[0]).toMatchObject({ updateAddon: false });
  expect((await check(old.token)).characters[0]).toMatchObject({ version: null, updateAddon: true });
});

test("a restore is delivered as a replace, and an upload made before it arrived doesn't undo it", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const merged = (await check(token)).characters[0]!;
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(3000)] })), { received: String(merged.version) });
  await workAll();
  const restore = { id: await restoreTo(token, merged.version!) };
  expect((await check(token)).characters[0]).toMatchObject({ version: restore!.id, restore: restore!.id, replace: true });

  // Made before the restore arrived: merged, but without the session the
  // restore took out.
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(5000)] })), { received: String(merged.version) });
  await workAll();
  const head = (await check(token)).characters[0]!;
  const text = new TextDecoder().decode(unpack(new Uint8Array(await (await call(token, `/v1/versions/${head.version}`)).arrayBuffer())));
  expect(text).toContain("5000");
  expect(text).not.toContain("3000");
  expect(head.restore).toBe(restore!.id);

  await upload(token, savedFile(journey({ events: session(9000) })), { received: String(restore!.id) });
  await workAll();
  expect((await check(token)).characters[0]).toMatchObject({ restore: null, replace: false });
});

// Restores the given version, as the app's history screen does.
async function restoreTo(token: string, version: number) {
  const [c] = await db.select().from(characters);
  const r = await call(token, `/v1/characters/${c!.id}/restore`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ version }),
  });
  return ((await r.json()) as RestoreResponse).version;
}

// One more session from token's PC, then a restore of the journey as it
// was before it.
async function restoreHead(token: string) {
  const [c] = await db.select().from(characters);
  const before = c!.headVersionId!;
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(20000)] })));
  await workAll();
  return restoreTo(token, before);
}

test("a PC that hasn't applied a restore gets a replace, even once new play is merged on top of it", async () => {
  const desk = await newDevice("user-1", "Desk");
  const laptop = await newDevice("user-1", "Laptop");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const restore = await restoreHead(desk.token);
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000)] })), { received: String(restore) });
  await workAll();

  const onTop = (await check(desk.token)).characters[0]!;
  expect(onTop.version).toBeGreaterThan(restore);
  expect(onTop.replace).toBe(false);
  expect((await check(laptop.token)).characters[0]).toMatchObject({ version: onTop.version, replace: true });

  await upload(laptop.token, savedFile(journey({ events: [...session(1000), ...session(5000), ...session(9000)] })), {
    received: String(onTop.version),
  });
  expect((await check(laptop.token)).characters[0]!.replace).toBe(false);
});

test("a PC that never received anything after a restore: what the restore took out stays out, its own play is merged", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await restoreHead(desk.token); // plays a session at 20000, then restores the journey from before it
  const copied = await newDevice("user-1", "Copied WTF folder");
  await upload(copied.token, savedFile(journey({ events: [...session(1000), ...session(20000), ...session(30000)] })));
  await workAll();
  const [entry] = (await check(desk.token)).characters;
  const text = new TextDecoder().decode(unpack(new Uint8Array(await (await call(desk.token, `/v1/versions/${entry!.version}`)).arrayBuffer())));
  expect(text).toContain("30000");
  expect(text).not.toContain("20000");
  expect(await db.select().from(versions).where(eq(versions.status, "superseded"))).toEqual([]);
});

test("a copy taken after its PC applied the restore merges cleanly", async () => {
  const desk = await newDevice("user-1", "Desk");
  await upload(desk.token, savedFile(journey({ events: session(1000) })));
  await workAll();
  await restoreHead(desk.token);
  const copied = await newDevice("user-1", "Copied WTF folder");
  await upload(copied.token, savedFile(journey({ events: [...session(1000), ...session(40000)] })));
  await workAll();
  const [entry] = (await check(desk.token)).characters;
  const text = new TextDecoder().decode(unpack(new Uint8Array(await (await call(desk.token, `/v1/versions/${entry!.version}`)).arrayBuffer())));
  expect(text).toContain("40000");
});

const s3 = new Bun.S3Client(config.s3);

test("a job that throws waits longer before each try, and after the last a file can be sent again", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const file = savedFile(journey({ events: session(1000) }));
  await upload(token, file);
  const [pending] = await db.select().from(versions);
  await s3.delete(`user-1/${pending!.fingerprint}.zst`); // storage lost it

  let lastWait = 0;
  for (let tries = 1; tries <= MAX_ATTEMPTS; tries++) {
    expect(await work()).toBe(true);
    const [job] = await db.select().from(jobs);
    expect(job!.attempts).toBe(tries);
    if (tries < MAX_ATTEMPTS) {
      expect(job!.state).toBe("queued");
      const wait = job!.runAfter.getTime() - Date.now();
      expect(wait).toBeGreaterThan(lastWait);
      expect(wait).toBeLessThanOrEqual(6 * 3600 * 1000);
      lastWait = wait;
      expect(await work()).toBe(false); // not yet due
      await db.update(jobs).set({ runAfter: new Date(0) });
    }
  }
  const [failed] = await db.select().from(versions);
  expect(failed!.status).toBe("rejected");
  expect(failed!.rejectReason).toBe(SERVER_FAILED);

  expect(((await (await upload(token, file)).json()) as UploadResponse).status).toBe("queued");
  await workAll();
  expect((await check(token)).characters).toHaveLength(1);
});

test("a job left running, as after a crash, is taken back once it is stale, and a fresh one isn't", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await db.update(jobs).set({ state: "running", claimedAt: new Date() });
  expect(await work()).toBe(false); // claimed a moment ago: someone is on it
  await db.update(jobs).set({ claimedAt: new Date(Date.now() - 10 * 60 * 1000) });
  expect(await work()).toBe(true);
  const [job] = await db.select().from(jobs);
  expect(job!.state).toBe("done");
});

test("a PC hears why its latest upload was refused, until it sends one that isn't", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000), seeded: true })));
  await workAll();
  const [refused] = (await check(token)).characters;
  expect(refused).toMatchObject({ name: "Ann", version: null, rejected: expect.stringMatching(/seeded/) });

  await upload(token, savedFile(journey({ events: session(5000) })));
  await workAll();
  const [fine] = (await check(token)).characters;
  expect(fine!.rejected).toBeNull();
  expect(fine!.version).not.toBeNull();

  const other = await newDevice("user-1", "Laptop");
  expect((await check(other.token)).characters[0]!.rejected).toBeNull(); // another PC's refusal isn't this one's
});

test("a merge-refused file sent again is known, not merged again", async () => {
  const { token } = await newDevice("user-1", "Desk");
  const seeded = savedFile(journey({ events: session(1000), seeded: true }));
  await upload(token, seeded);
  await workAll();
  expect(((await (await upload(token, seeded)).json()) as UploadResponse).status).toBe("known");
});

test("a stale or unreadable file doesn't make a PC look out of date", async () => {
  const { device, token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await upload(token, savedFile(journey({ version: 2, events: session(2000) })), { name: "Alt" });
  await upload(token, new TextEncoder().encode('RoadToSixtyCharDB = {["version"] = 99}'), { name: "Odd" });
  await workAll();
  expect((await check(token)).characters.find((c) => c.name === "Ann")).toMatchObject({ updateAddon: false });
  const [d] = await db.select().from(devices).where(eq(devices.id, device.id));
  expect(d!.dataLayout).toBe(3);
});

test("a merge never overwrites a head that moved while it ran", async () => {
  const { token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const [c] = await db.select().from(characters);
  const [head] = await db.select().from(versions).where(eq(versions.id, c!.headVersionId!));
  const [moved] = await db
    .insert(versions)
    .values({ characterId: c!.id, kind: "merged", fingerprint: head!.fingerprint, rawSize: 1, dataVersion: 3, status: "accepted" })
    .returning();
  await upload(token, savedFile(journey({ events: [...session(1000), ...session(5000)] })), { received: String(head!.id) });

  // Another worker moves the head while this one merges: hold the row so
  // the merge waits at its head update, then move the head and let go.
  let working: Promise<boolean> | undefined;
  await client.begin(async (tx) => {
    await tx`SELECT id FROM characters WHERE id = ${c!.id} FOR NO KEY UPDATE`;
    working = work();
    for (let i = 0; ; i++) {
      const [w] = await client`SELECT count(*)::int AS n FROM pg_stat_activity WHERE wait_event_type = 'Lock'`;
      if (w.n > 0) break;
      if (i === 200) throw new Error("the merge never reached the head update");
      await Bun.sleep(25);
    }
    await tx`UPDATE characters SET head_version_id = ${moved!.id} WHERE id = ${c!.id}`;
  });
  await working;

  const [after] = await db.select().from(characters);
  expect(after!.headVersionId).toBe(moved!.id);
  const [job] = await db.select().from(jobs).where(eq(jobs.state, "queued"));
  expect(job).toBeDefined();
});
