import { expect, test } from "bun:test";
import { runMerge } from "../src/lua";
import { journey, lua, savedFile, session, sessions } from "./helpers";

const text = (j: object) => new TextEncoder().encode(lua(j));

test("a first upload is prepared and tidied, and becomes the journey", async () => {
  const upload = journey({
    version: 2,
    events: [...session(1000), [1200, "zone", 0, 0, 0, 1415]], // a continent logged as a zone, which the tidy drops
    people: { "Player-1-0001": { name: "Ann", groups: 2 } },
    levels: { 5: { t: 900 }, 6: { t: 1100 } },
    played: 3600,
  });
  const r = await runMerge(savedFile(upload), null, "pc-1");
  if (!r.ok) throw new Error(r.reason);
  expect(r).toMatchObject({ from: 2, layout: 3, level: 6, played: 3600, lastSeen: 1120 });
  const out = new TextDecoder().decode(r.journey);
  expect(sessions(out)).toBe(1);
  expect(out).not.toContain("1415");
  expect(out).toContain('["pc-1"]=2'); // the old count, now this PC's tally
});

test("an upload merges into the current journey", async () => {
  const current = text(journey({ events: session(1000), totals: { ...journey().totals, deaths: 1 } }));
  const r = await runMerge(savedFile(journey({ events: session(5000) })), current, "pc-2");
  if (!r.ok) throw new Error(r.reason);
  expect(sessions(r.journey)).toBe(2);
  expect(r.lastSeen).toBe(5120);
});

test("uploads the merge can't take are rejected with a reason", async () => {
  const cases: [Uint8Array, RegExp][] = [
    [savedFile(journey({ seeded: true })), /seeded/],
    [savedFile(journey({ version: 4 })), /newer layout/],
    [savedFile(journey({ totals: 5 })), /damaged/],
    [new TextEncoder().encode("RoadToSixtyCharDB = { os.exit() }"), /./],
    [new TextEncoder().encode("SomethingElse = {}"), /no journey/],
  ];
  for (const [upload, why] of cases) {
    const r = await runMerge(upload, null, "pc-1");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toMatch(why);
  }
});

test("the runner stops itself over the memory or time limit", async () => {
  const upload = savedFile(journey({ events: session(1000) }));
  const memory = await runMerge(upload, null, "pc-1", { mb: 0.05, seconds: 30 });
  expect(memory).toMatchObject({ ok: false, reason: "over the memory limit" });
  const time = await runMerge(upload, null, "pc-1", { mb: 512, seconds: 0 });
  expect(time).toMatchObject({ ok: false, reason: "over the time limit" });
});

test("a runner that never ends is killed", async () => {
  const started = Date.now();
  const r = await runMerge(savedFile(journey()), null, "pc-1", { mb: 512, seconds: 1 }, `${import.meta.dir}/fixtures/hang.lua`);
  expect(r).toMatchObject({ ok: false, reason: "the merge didn't finish in time and was stopped" });
  expect(Date.now() - started).toBeLessThan(10_000);
});

test("an upload merges into a current journey saved in an older layout", async () => {
  const current = text(journey({ version: 2, events: session(1000), totals: { ...journey().totals, deaths: 1 } }));
  const r = await runMerge(savedFile(journey({ events: session(5000) })), current, "pc-2");
  if (!r.ok) throw new Error(r.reason);
  expect(r.layout).toBe(3);
  expect(sessions(r.journey)).toBe(2);
});
