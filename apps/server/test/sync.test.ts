import type { CheckResponse, UploadResponse } from "@road-to-sixty/api";
import { beforeEach, expect, test } from "bun:test";
import { eq } from "drizzle-orm";
import { app } from "../src/app";
import { db } from "../src/db";
import { newDevice } from "../src/devices";
import { characters, devices, versions } from "../src/schema";
import { pack, unpack } from "../src/storage";
import { work } from "../src/worker";
import { journey, savedFile, session, sessions } from "./helpers";
import { reset } from "./helpers";

beforeEach(reset);

const CHAR = { game: "_classic_beta_", realm: "Test Realm", name: "Ann" };

function call(token: string, path: string, init: RequestInit = {}) {
  return app.handle(
    new Request(`http://local${path}`, { ...init, headers: { authorization: `Bearer ${token}`, ...init.headers } }),
  );
}

async function upload(token: string, file: Uint8Array, extra: Record<string, string> = {}) {
  const query = new URLSearchParams({ ...CHAR, addon: "1.9.0", ...extra });
  return call(token, `/v1/upload?${query}`, { method: "POST", body: pack(file) });
}

const check = async (token: string) => (await (await call(token, "/v1/check")).json()) as CheckResponse;

async function workAll() {
  while (await work()) {}
}

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
  const file = savedFile(journey({ events: session(1000), levels: { 4: { t: 900 } }, played: 600 }));
  const first = (await (await upload(token, file)).json()) as UploadResponse;
  expect(first.status).toBe("queued");
  expect(((await (await upload(token, file)).json()) as UploadResponse).status).toBe("known");
  expect((await check(token)).characters).toEqual([]); // nothing merged yet

  await workAll();
  const [entry] = (await check(token)).characters;
  expect(entry).toMatchObject({ ...CHAR, replace: false, updateAddon: false });
  const [c] = await db.select().from(characters);
  expect(c).toMatchObject({ level: 4, played: 600, headVersionId: entry!.version });

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
  const { device, token } = await newDevice("user-1", "Desk");
  await upload(token, savedFile(journey({ events: session(1000) })));
  await workAll();
  const merged = (await check(token)).characters[0]!;
  // The website's restore (a later step) adds a version like this.
  const [c] = await db.select().from(characters);
  const [restore] = await db
    .insert(versions)
    .values({ characterId: c!.id, kind: "restore", fingerprint: merged.fingerprint, rawSize: 1, dataVersion: 3, status: "accepted" })
    .returning();
  await db.update(characters).set({ headVersionId: restore!.id });
  expect((await check(token)).characters[0]).toMatchObject({ version: restore!.id, replace: true });

  await upload(token, savedFile(journey({ events: [...session(1000), ...session(5000)] })), { received: String(merged.version) });
  await workAll();
  const [superseded] = await db.select().from(versions).where(eq(versions.status, "superseded"));
  expect(superseded?.deviceId).toBe(device.id);
  expect((await check(token)).characters[0]!.version).toBe(restore!.id);
});
