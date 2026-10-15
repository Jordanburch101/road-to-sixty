// One journey per character (spec 2026-10-15, journeys): stamps, which row
// an upload goes to, current and earlier journeys, removing a character.
// GUIDs here are made up.
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { characters, jobs } from "../src/schema";
import { unpack } from "../src/storage";
import { stampOf } from "../src/sync";
import { CHAR, addUser, call, check, journey, newDevice, reset, savedFile, session, sessions, upload, workAll } from "./helpers";

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
