// Shared by the server tests: a clean database and bucket, and made-up
// journeys in the game's saved format. Never a real save: those hold other
// players' names.
import type { CheckResponse } from "@road-to-sixty/api";
import { app } from "../src/app";
import { config } from "../src/config";
import { client, db, migrateDb } from "../src/db";
import { newDevice as linkDevice } from "../src/devices";
import { user } from "../src/schema";
import { pack } from "../src/storage";
import { clearLimits } from "../src/limits";
import { work } from "../src/worker";

export async function reset() {
  clearLimits();
  await migrateDb();
  await client`TRUNCATE jobs, version_parents, versions, characters, devices, "user", session, account, verification, device_code RESTART IDENTITY CASCADE`;
  // SeaweedFS makes a bucket on an unsigned PUT (409 once it exists); it
  // takes a few seconds to start in CI. R2's bucket is made once by hand.
  for (let tries = 0; ; tries++) {
    const put = fetch(`${config.s3.endpoint}/${config.s3.bucket}`, { method: "PUT" });
    const ok = await put.then((r) => r.ok || r.status === 409, () => false);
    if (ok) return;
    if (tries === 40) throw new Error(`no S3 store at ${config.s3.endpoint}: run docker compose up -d in apps/server`);
    await Bun.sleep(500);
  }
}

// A player, as signing in would make one.
export async function addUser(id: string) {
  await db.insert(user).values({ id, name: `${id}#1234`, email: `${id}@battlenet.invalid` }).onConflictDoNothing();
  return id;
}

// A value as Lua table text the addon's Parse.lua reads. Arrays become the
// array part, null a gap; object keys made of digits become number keys.
export function lua(v: unknown): string {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return `{${v.map((x) => `${lua(x)},`).join("")}}`;
  const entries = Object.entries(v as Record<string, unknown>);
  return `{${entries.map(([k, x]) => `[${/^\d+$/.test(k) ? k : JSON.stringify(k)}] = ${lua(x)},`).join("")}}`;
}

export type Event = (string | number | boolean | null | object)[];

// A journey at layout 4 with nothing in it but what is given.
export function journey(fields: Record<string, unknown> = {}) {
  return {
    version: 4,
    segments: [],
    events: [] as Event[],
    levels: {},
    recipes: {},
    people: {},
    kills: { d: "", last: 0, names: [] },
    totals: { kills: 0, killXP: 0, questXP: 0, deaths: 0, quests: 0, instances: 0, distance: 0, flown: 0 },
    ...fields,
  };
}

// One session: logged on, died, logged off.
export const session = (t: number): Event[] => [
  [t, "on", 0, 0, 0, 10],
  [t + 60, "die", 0, 0, 0],
  [t + 120, "off", 0, 0, 0],
];

// The character's SavedVariables file as the game writes it.
export const savedFile = (j: object) => new TextEncoder().encode(`\r\nRoadToSixtyCharDB = ${lua(j)}\r\n`);

// How many sessions a journey's text holds, by its "on" events.
export const sessions = (text: Uint8Array | string) =>
  (typeof text === "string" ? text : new TextDecoder().decode(text)).split('"on"').length - 1;

// Calls the server as a linked PC, as the app does.
export const newDevice = async (userId: string, name: string) => linkDevice(await addUser(userId), name);

export const CHAR = { game: "_classic_beta_", realm: "Test Realm", name: "Ann" };

export function call(token: string, path: string, init: RequestInit = {}) {
  return app.handle(
    new Request(`http://local${path}`, { ...init, headers: { authorization: `Bearer ${token}`, ...init.headers } }),
  );
}

export async function upload(token: string, file: Uint8Array, extra: Record<string, string> = {}) {
  const query = new URLSearchParams({ ...CHAR, addon: "1.9.0", ...extra });
  return call(token, `/v1/upload?${query}`, { method: "POST", body: pack(file) });
}

export const check = async (token: string) => (await (await call(token, "/v1/check")).json()) as CheckResponse;

export async function workAll() {
  while (await work()) {}
}

const s3 = new Bun.S3Client(config.s3);
// Whether a journey file is in the bucket.
export const stored = (userId: string, fp: string) => s3.exists(`${userId}/${fp}.zst`);
