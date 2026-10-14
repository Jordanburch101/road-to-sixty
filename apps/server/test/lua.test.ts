import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { config } from "../src/config";
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

test("over the memory or time limit is the server's fault, not the upload's", async () => {
  const upload = savedFile(journey({ events: session(1000) }));
  await expect(runMerge(upload, null, "pc-1", { mb: 0.05, seconds: 30 })).rejects.toThrow("over the memory limit");
  await expect(runMerge(upload, null, "pc-1", { mb: 512, seconds: 0 })).rejects.toThrow("over the time limit");
});

test("a runner that never ends is killed, and that is the server's fault", async () => {
  const started = Date.now();
  await expect(
    runMerge(savedFile(journey()), null, "pc-1", { mb: 512, seconds: 1 }, `${import.meta.dir}/fixtures/hang.lua`),
  ).rejects.toThrow("didn't finish in time");
  expect(Date.now() - started).toBeLessThan(10_000);
});

test("a stored journey the merge can't read is the server's fault, not the upload's", async () => {
  const upload = savedFile(journey({ events: session(5000) }));
  await expect(runMerge(upload, text(journey({ totals: 5 })), "pc-2")).rejects.toThrow(/stored journey/);
  await expect(runMerge(upload, new TextEncoder().encode("{ cut short"), "pc-2")).rejects.toThrow(/stored journey/);
});

test("an upload merges into a current journey saved in an older layout", async () => {
  const current = text(journey({ version: 2, events: session(1000), totals: { ...journey().totals, deaths: 1 } }));
  const r = await runMerge(savedFile(journey({ events: session(5000) })), current, "pc-2");
  if (!r.ok) throw new Error(r.reason);
  expect(r.layout).toBe(3);
  expect(sessions(r.journey)).toBe(2);
});

test("a merge that fails its own check is the server's fault, so a fixed server tries again", async () => {
  // A Merge.lua with a bug that loses data, as Merge.Check would catch it.
  const dir = await mkdtemp(join(tmpdir(), "rts-addon-"));
  try {
    for (const name of ["Packed.lua", "Tidy.lua", "Parse.lua", "Tally.lua", "Merge.lua"]) {
      await Bun.write(join(dir, name), Bun.file(join(config.luaDir, name)));
    }
    const merge = await Bun.file(join(dir, "Merge.lua")).text();
    await Bun.write(join(dir, "Merge.lua"), `${merge}\nfunction Merge.Check() return false, "the kills went down" end\n`);
    await Bun.write(join(dir, "upload.lua"), savedFile(journey({ events: session(5000) })));
    await Bun.write(join(dir, "current.lua"), text(journey({ events: session(1000) })));
    const runner = `${import.meta.dir}/../src/runner.lua`;
    const args = [dir, join(dir, "upload.lua"), join(dir, "current.lua"), join(dir, "out.lua"), "pc-2", "512", "30"];
    const proc = Bun.spawn([config.lua51, runner, ...args], { stdout: "pipe" });
    expect((await new Response(proc.stdout).text()).trim()).toBe("failed the kills went down");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
