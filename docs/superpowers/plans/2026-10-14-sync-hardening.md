# Sync Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the gaps the six-way review (#40) and Jordan's Windows test found before testers use sync: backups that silently stop, play that is lost or counted twice across PCs, server faults that turn into permanent refusals, stuck merge jobs, and a status that hides failures.

**Architecture:** Three parts change, each in its own tasks. The addon's merge keeps a dungeon run or group that was still open at logout until one PC finishes it, and counts it under the PC that started it. The server tells a deliberate refusal from its own fault, retries faults for about a day, takes back jobs left running, and tells each PC when its latest upload was refused. The app looks for game folders again whenever something changes or every few minutes, keeps a refused file's problem until it is fixed, names it in plain words against the character, and says in the tray when a character isn't backed up.

**Tech Stack:** Lua 5.1/LuaJIT (addon, offline tests), Bun + Elysia + Drizzle + Postgres (server), Rust 1.99 (engine `rts-sync`, app `road-to-sixty-app` on Tauri 2.12.3), React (window).

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md` ("The merge rules", "The backend", "Merge jobs", "The desktop app"). The findings this plan fixes are in issue #40 and its comment from the Windows test.

## Out of scope (where it goes)

- Unlink that revokes the token, and typing the link code instead of prefilling it (#40 items 4 and 5): the account API plan, which builds unlink and the PC list.
- The restore id on the wire (#40 item 7): with restore.
- Rate limits and quotas (#40 item 9): before the public release.
- Speeding up the login merge (#40 item 8): only if the two-PC test shows a noticeable freeze (Windows showed 82 ms for Liairene).

## Global Constraints

- Subagents use at most `model: "opus"`, never Fable.
- No real SavedVariables in tests: made-up journeys and names only.
- The addon's pure files (`Packed`, `Tidy`, `Parse`, `Tally`, `Merge`) make no game calls; `tests/pure_test.lua` checks.
- `run.pc` and `group.pc` are new optional fields. `DATA_VERSION` stays 3: layout 1's note in Core.lua records that adding fields never needed a bump, and a missing `pc` falls back to `ns.pc`, as today.
- Merge properties must still hold: either order, twice, any grouping (`merge_test.lua` section 16).
- Words shown to players are plain English, British spelling, no file paths or codes.
- Every app and package's `AGENTS.md` is updated in the same commit as the change it describes.
- Commits `Area: what changed (#40)`, on a branch `sync-hardening` off `dev`, merged locally into `dev`, never pushed to `main`.

## Review Focus

1. Two PCs both finishing the same open run or group (the stale copy problem in reverse): the "out" and "grpx" events come out once and the tallies count once. Task 1 tests it in the merge and in Journal and Groups.
2. A server fault that never clears (a bug in `Merge.lua` that fails on one journey every time): it is retried for about a day, then marked as the server's failure, never as the upload's, and the player sees "not backed up" for that character. Task 2 tests the retries; Task 3 the report.
3. WoW creating the `WTF` folder, or a new game folder appearing, after the app started: it is watched and its files go up without restarting the app. Task 5 tests it with a real watcher.
4. A file refused once (no rosterKey, too big, refused by the merge): the character stays flagged on every later pass, and in the tray, until the file changes and goes up. Task 4 and Task 6 test it.
5. A damaged `state.json`: the app opens and says so instead of failing to start. Task 6 tests it.

---

### Task 1: Addon: a run or group open at logout survives a stale copy and counts once

**Files:**
- Modify: `apps/addon/RoadToSixty/Merge.lua` (after the field loop in `Merge.Merge`, two helpers above it)
- Modify: `apps/addon/RoadToSixty/Journal.lua:142-151` (`StartRun`), `:195-202` (`FinishRun`)
- Modify: `apps/addon/RoadToSixty/Groups.lua:120-131` (`Part`), `:133-150` (`Start`), `:152-160` (`End`), `:281-294` (`Resume`), `:309-320` (`CountRun`)
- Test: `apps/addon/tests/merge_test.lua` (new section 17), `apps/addon/tests/runs_test.lua` (one case), `apps/addon/tests/groups_test.lua` (new)

**Interfaces:**
- Produces: `ns.char.run.pc` and `ns.char.group.pc` (string, the PC that started it); `Groups:CountRun(guids, raid, pc)` (pc optional, defaults to `ns.pc`).

- [ ] **Step 1: Write the failing merge tests.** In `tests/merge_test.lua`, before the final `if failures == 0`, add:

```lua
-- 17. A run or group still open at logout is work for whichever PC logs in
-- next. A copy that never saw it (played on a stale copy) doesn't drop it,
-- and once the merged events show it ended, it isn't brought back.
do
    local run = { t = 900, name = "Deadmines", type = "party", pc = "pcA",
        left = { t = 1000, c = 0, x = 0, y = 0, id = 36, summary = { duration = 100 } } }
    local group = { t = 950, kind = "party", pc = "pcA", members = {}, everMet = {}, levels = {}, subs = {},
        seen = 1100, met = 1, kills = 0, xp = 0, quests = 0, deaths = 0, instances = 0 }
    local a = Journey({ events = { On(800) }, run = run, group = group })
    local b = Journey({ events = { On(2000) } })   -- played later on a copy from before the run
    local m = Merge.Merge(a, b)
    check(m.run and m.run.t == 900, "an open run survives a later copy that never saw it")
    check(m.group and m.group.t == 950, "an open group survives a later copy that never saw it")
    check(Same(m, Merge.Merge(b, a)), "keeping an open run or group works either way round")

    local ended = Journey({ events = { On(800), { 1000, "out", 0, 0, 0, 36, { duration = 100 } },
        { 1100, "grpx", 0, 0, 0, { duration = 150 } }, On(2000) } })
    local done = Merge.Merge(a, ended)
    check(done.run == nil, "a run whose out event is in the merged events is not brought back")
    check(done.group == nil, "a group whose grpx event is in the merged events is not brought back")
    check(Same(done, Merge.Merge(ended, a)), "dropping an ended run works either way round")
end

-- DATA_VERSION in Core.lua and Merge.VERSION must move together: one
-- without the other refuses every journey.
do
    local core = assert(io.open("RoadToSixty/Core.lua")):read("*a")
    check(tonumber(core:match("local DATA_VERSION = (%d+)")) == Merge.VERSION, "Merge.VERSION matches DATA_VERSION")
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/addon && luajit tests/merge_test.lua`
Expected: FAIL lines "an open run survives…" and "an open group survives…" (the version check passes already).

- [ ] **Step 3: Keep open runs and groups in the merge.** In `Merge.lua`, above `function Merge.Merge`, add:

```lua
-- Whether events hold one of kind at time t.
local function Logged(events, kind, t)
    for _, e in ipairs(events or {}) do
        if e[1] == t and e[2] == kind then return true end
    end
    return false
end

-- Whether events hold the end of the group that began at t: its "grpx",
-- whose summary says how long it lasted.
local function GroupEnded(events, t)
    for _, e in ipairs(events or {}) do
        if e[2] == "grpx" and type(e[6]) == "table" and e[1] - (tonumber(e[6].duration) or 0) == t then return true end
    end
    return false
end
```

and in `Merge.Merge`, right after the `EachKey(a, b, function(k) … end)` call:

```lua
    -- A run or group still open at logout is work for whichever PC logs in
    -- next, so a copy that never saw it doesn't drop it; once the merged
    -- events show it ended, it's done.
    for _, k in ipairs({ "run", "group" }) do
        if out[k] == nil then out[k] = a[k] or b[k] end
    end
    if out.run and out.run.left and Logged(out.events, "out", out.run.left.t) then out.run = nil end
    if out.group and GroupEnded(out.events, out.group.t) then out.group = nil end
```

`a[k] or b[k]` only runs when the latest copy had none, so at most one copy has one there and the choice doesn't depend on order. Update the "What it relies on" bullet "a copy that is behind holds the start of what the other holds" by adding: "Open runs and groups are the exception: they are kept until the events show them ended."

- [ ] **Step 4: Run the merge tests**

Run: `cd apps/addon && luajit tests/merge_test.lua`
Expected: "Merge tests passed." (section 16's properties included).

- [ ] **Step 5: Write the failing count tests.** In `tests/runs_test.lua`, change the Groups stub (line 27) to record what it was given:

```lua
local countedFor
ns.Groups = { Current = function() return nil end, CountRun = function(_, _, _, pc) countedFor = pc end }
```

and before the final summary at the end of the file add:

```lua
-- A run is counted under the PC that started it, so two PCs finishing the
-- same run from their copies count it once (the merge keeps the higher part).
ns.char = NewChar()
ns.view = ns.char
ns.pc = "pcA"
now, inside, instanceID = 9000, true, 36
Fire("PLAYER_ENTERING_WORLD")
now, inside = 9100, false
Fire("PLAYER_ENTERING_WORLD")
ns.pc = "pcB"                       -- the copy carried on on another PC
now = 9100 + 31 * 60
Fire("PLAYER_ENTERING_WORLD")
check(countedFor == "pcA", "a run counts under the PC that started it: " .. tostring(countedFor))
```

Create `tests/groups_test.lua`:

```lua
-- Offline test of Groups.lua with a fake WoW API: a group open at logout
-- and found gone at login counts its time under the PC that started it, so
-- two PCs ending the same group count it once. Run with LuaJIT from
-- apps/addon: luajit tests/groups_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = { pc = "pcB" }
ns.Now = function() return 1000 end
ns.On = function() return true end
ns.Command = function() end
ns.SafeCall = function(fn, ...) fn(...) end
ns.Recorder = { Position = function() return 0, 10, 20 end }
ns.Journal = { Log = function() end, JoinRun = function() end }
LE_PARTY_CATEGORY_HOME = 1
IsInGroup = function() return false end
assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Groups.lua"))("RoadToSixty", ns)

ns.char = {
    events = {}, people = { G1 = {} },
    totals = { kills = 0, killXP = 0, questXP = 0, quests = 0, deaths = 0, instances = 0 },
    group = { t = 100, kind = "party", pc = "pcA", members = { G1 = 100 }, everMet = { G1 = true },
        levels = {}, subs = {}, seen = 400, met = 1, kills = 0, xp = 0, quests = 0, deaths = 0, instances = 0 },
}
ns.Groups:Resume()
local seconds = ns.char.people.G1.seconds or {}
check(ns.char.group == nil, "a group gone at login ends")
check(seconds.pcA == 300 and seconds.pcB == nil, "its time counts under the PC that started it: " .. tostring(seconds.pcA) .. "/" .. tostring(seconds.pcB))

-- A group from before this change has no pc: it counts as this PC's, as before.
ns.char.people.G1 = {}
ns.char.group = { t = 100, kind = "party", members = { G1 = 100 }, everMet = { G1 = true },
    levels = {}, subs = {}, seen = 200, met = 1, kills = 0, xp = 0, quests = 0, deaths = 0, instances = 0 }
ns.Groups:Resume()
check((ns.char.people.G1.seconds or {}).pcB == 100, "an older group without a pc counts as this PC's")

if failures == 0 then
    print("Groups tests passed.")
else
    print(failures .. " groups test(s) failed.")
    os.exit(1)
end
```

- [ ] **Step 6: Run them to see them fail**

Run: `cd apps/addon && luajit tests/runs_test.lua; luajit tests/groups_test.lua`
Expected: runs_test FAIL "a run counts under the PC that started it: nil"; groups_test FAIL "its time counts under the PC that started it: nil/300". If groups_test errors on a missing global while loading Groups.lua, add the smallest stub for it (Groups.lua's handlers only run on events this test never fires).

- [ ] **Step 7: Count under the starting PC.** `Journal.lua` `StartRun`: add `pc = ns.pc,` to the new `ns.char.run` table (after `items = {}, party = {},`). `FinishRun`: `ns.Groups:CountRun(left.summary.party, run.type == "raid", run.pc)`.

`Groups.lua`: `Start` adds `pc = ns.pc,` to `ns.char.group`. `Part` takes a fifth argument and uses it:

```lua
-- Adds the time a member spent in a group of kind up to t to their total,
-- under pc: the PC that started the group, so two PCs ending it count once.
local function Part(guid, since, t, kind, pc)
    local p = ns.char.people[guid]
    if p and since then
        local seconds = math.max(0, t - since)
        pc = pc or ns.pc
        if kind == "raid" then
            ns.Tally.Add(p, "raidSeconds", pc, seconds)
        else
            ns.Tally.Add(p, "seconds", pc, seconds)
        end
        p.last = t
    end
end
```

Every call to `Part` passes the group's: `Part(guid, since, t, g.kind, g.pc)` in `End`, `Part(guid, since, g.seen, g.kind, g.pc)` in `Resume`, and any other caller of `Part` in the file the same way (search for `Part(`). `CountRun`:

```lua
-- Counts a dungeon or raid run (raid true) for everyone in it, under pc
-- (the PC that started the run; this PC when not given).
function Groups:CountRun(guids, raid, pc)
    pc = pc or ns.pc
    for _, guid in ipairs(guids or {}) do
        local p = ns.char.people[guid]
        if p then
            if raid then
                ns.Tally.Add(p, "raidRuns", pc, 1)
            else
                ns.Tally.Add(p, "dungeons", pc, 1)
            end
        end
    end
end
```

Update `Groups.lua`'s header line about `ns.char.group` to list `pc = the PC that started it (its time counts under it)`, and Journal's run comment to say the run keeps `pc`, the PC it counts under.

- [ ] **Step 8: Run every addon test**

Run: `cd apps/addon && bun run test`
Expected: every test file passes under LuaJIT (and Lua 5.1 if installed), including the new `groups_test.lua`.

- [ ] **Step 9: Commit**

```bash
git add apps/addon
git commit -m "Merge: keep a run or group open at logout until a PC ends it, and count it under the PC that started it (#40)"
```

---

### Task 2: Server: a fault in the merge is retried, never a refusal, and a stuck job is taken back

**Files:**
- Modify: `apps/server/src/runner.lua` (load files outside `pcall`; faults as tables; the result line)
- Modify: `apps/server/src/lua.ts` (throw on a fault)
- Modify: `apps/server/src/worker.ts` (retries with a doubling wait; reclaim stale jobs; guard `work`)
- Modify: `apps/server/src/schema.ts` (`jobs.claimedAt`), new migration in `apps/server/drizzle/`
- Test: `apps/server/test/lua.test.ts`, `apps/server/test/sync.test.ts`

**Interfaces:**
- Produces: `runMerge` resolves `{ ok: false, reason }` only for a refusal by the merge rules and throws for anything else. `worker.ts` exports `MAX_ATTEMPTS` (12) and `RETRY_SECONDS` (30).

- [ ] **Step 1: Write the failing tests.** In `test/lua.test.ts`, replace the two limit tests with:

```ts
test("over the memory or time limit is the server's fault, not the upload's", async () => {
  const upload = savedFile(journey({ events: session(1000) }));
  expect(runMerge(upload, null, "pc-1", { mb: 0.05, seconds: 30 })).rejects.toThrow("over the memory limit");
  expect(runMerge(upload, null, "pc-1", { mb: 512, seconds: 0 })).rejects.toThrow("over the time limit");
});

test("a runner that never ends is killed, and that is the server's fault", async () => {
  const started = Date.now();
  await expect(
    runMerge(savedFile(journey()), null, "pc-1", { mb: 512, seconds: 1 }, `${import.meta.dir}/fixtures/hang.lua`),
  ).rejects.toThrow("didn't finish in time");
  expect(Date.now() - started).toBeLessThan(10_000);
});

test("a stored journey the merge can't read is the server's fault, not the upload's", async () => {
  const damaged = text(journey({ totals: 5 }));
  await expect(runMerge(savedFile(journey({ events: session(5000) })), damaged, "pc-2")).rejects.toThrow(/damaged/);
});
```

In `test/sync.test.ts`, replace the retry test (`"a job that throws waits before its next try…"`) with:

```ts
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
      lastWait = Math.min(wait, 5 * 3600 * 1000); // the wait stops growing at six hours
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
```

and import `MAX_ATTEMPTS` and `SERVER_FAILED` from `../src/worker` beside `work`. The `"a seeded journey is refused…"` style tests (refusals by the merge rules) stay as they are: they must still come out `rejected` on the first try.

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && docker compose up -d && bun test` (with `LUA51` naming Lua 5.1 if `lua5.1` isn't on the path)
Expected: the four new tests fail (the runner's limits still resolve, `MAX_ATTEMPTS` isn't exported, `claimedAt` doesn't exist).

- [ ] **Step 3: The runner tells a refusal from a fault.** In `runner.lua`:

Above `local started, …`, add:

```lua
-- A fault is the server's problem, not the upload's: raised as a table so
-- it can't be mistaken for a refusal, which the merge raises as text with
-- error(why, 0). lua.ts retries faults and rejects only refusals.
local function Fault(why) error({ fault = why }) end
```

The hook raises faults: `if collectgarbage("count") > limitKB then Fault("over the memory limit") end` and the same for `"over the time limit"`. In `Read`, `local f = io.open(path, "rb") if not f then Fault("couldn't open " .. path) end`.

Move `local ns = {}` and the `for _, name in ipairs(…) do assert(loadfile(…)) end` loop out of `Run` to just above `local function Run()`, so a missing or broken addon file stops the runner with no result line (a fault). Inside `Run`, the stored journey: 

```lua
        local current, bad = ns.Merge.Prepare(ns.Parse.Read(Read(currentPath)), "server")
        if not current then Fault("the stored journey can't be merged: " .. bad) end
```

and the output: `local file = io.open(outPath, "wb") if not file then Fault("couldn't write the result") end`.

Replace the result lines at the end with:

```lua
local ok, result = pcall(Run)
debug.sethook()
if ok then
    io.write(result, "\n")
elseif type(result) == "string" and not result:find("^[^\n]-%.lua:%d+: ") then
    -- Raised on purpose with error(why, 0): the merge refuses this upload.
    io.write("rejected ", from, " ", (result:gsub("\n", " ")), "\n")
else
    -- A fault, or a bug (an error with a file and line): try again later.
    local why = type(result) == "table" and result.fault or tostring(result)
    io.write("failed ", (why:gsub("\n", " ")), "\n")
end
```

Update the header's output list with `failed <why>   the server's fault; lua.ts throws and the job is tried again`.

- [ ] **Step 4: lua.ts throws on a fault.** Replace the three outcomes after `await proc.exited`:

```ts
    // A signal means it was stopped for running too long: the server's fault.
    if (proc.signalCode) throw new Error("the merge didn't finish in time and was stopped");
    const [word, from, ...rest] = (stdout.trim().split("\n").pop() ?? "").split(" ");
    if (word === "ok") {
      …as before…
    }
    if (word === "rejected") return { ok: false, from: num(from), reason: rest.join(" ") };
    // "failed", or no result at all: the server's fault, tried again later.
    const why = word === "failed" ? [from, ...rest].join(" ") : (stderr || stdout).trim().split("\n")[0];
    throw new Error(`the merge failed: ${why || `exit code ${proc.exitCode}`}`);
```

Change the `MergeResult` comment to say `ok: false` means the merge rules refused the upload, and that faults throw.

- [ ] **Step 5: The worker waits longer each time and takes back stale jobs.** In `schema.ts`, `jobs` gains:

```ts
  // When the worker took it. A job left running past the time limit (the
  // worker died, or the database failed under it) is taken back.
  claimedAt: timestamp("claimed_at", { withTimezone: true }),
```

Run `cd apps/server && bun run db:generate` and commit the new migration it writes in `drizzle/`.

In `worker.ts`:

```ts
// Tries for about a day, waiting twice as long each time up to six hours,
// so an outage or a server bug fixed by the next deploy doesn't cost uploads.
export const MAX_ATTEMPTS = 12;
export const RETRY_SECONDS = 30;
const MAX_WAIT_SECONDS = 6 * 3600;
// A running job older than this was abandoned: the merge's own limit plus margin.
const STALE_SECONDS = LIMITS.seconds + 240;
```

(import `LIMITS` from `./lua`). `claim()`:

```ts
async function claim(): Promise<number | null> {
  const [row] = await client`
    UPDATE jobs SET state = 'running', attempts = attempts + 1, claimed_at = now()
    WHERE id = (
      SELECT id FROM jobs
      WHERE (state = 'queued' AND run_after <= now())
         OR (state = 'running' AND (claimed_at IS NULL OR claimed_at < now() - ${STALE_SECONDS} * interval '1 second'))
      ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
    RETURNING id`;
  return row ? Number(row.id) : null;
}
```

`work()`:

```ts
// Runs the oldest due job. False when there was none. A job that throws
// goes back in the queue with a longer wait, up to MAX_ATTEMPTS. If the
// database fails even for that, the job stays running and is taken back
// once it is stale.
export async function work(): Promise<boolean> {
  const id = await claim();
  if (id === null) return false;
  try {
    const [job] = await db.select().from(jobs).where(eq(jobs.id, id));
    try {
      await runJob(job!);
    } catch (e) {
      const error = String(e);
      if (job!.attempts >= MAX_ATTEMPTS) {
        await db.update(jobs).set({ state: "failed", error, finishedAt: new Date() }).where(eq(jobs.id, id));
        await db
          .update(versions)
          .set({ status: "rejected", rejectReason: SERVER_FAILED })
          .where(eq(versions.id, job!.versionId));
      } else {
        const wait = Math.min(RETRY_SECONDS * 2 ** (job!.attempts - 1), MAX_WAIT_SECONDS);
        await db
          .update(jobs)
          .set({ state: "queued", error, runAfter: new Date(Date.now() + wait * 1000) })
          .where(eq(jobs.id, id));
      }
    }
  } catch (e) {
    console.error(`worker: job ${id}:`, e);
  }
  return true;
}
```

In `startWorker`, delete the startup line that puts every running job back in the queue (and its comment): stale jobs are taken back by `claim()`, and a fresh one may belong to a worker in the old container during a deploy.

- [ ] **Step 6: Run the server tests**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass, the refusal tests included.

- [ ] **Step 7: Update `apps/server/AGENTS.md`** (the worker bullet): faults (a table from the runner, a bug with a file and line, a kill, no result) are retried for about a day with a doubling wait; only the merge rules' own refusals reject an upload; a job running past `STALE_SECONDS` is taken back. Commit:

```bash
git add apps/server
git commit -m "Server: a fault in the merge is retried for a day instead of refusing the upload, and a stuck job is taken back (#40)"
```

---

### Task 3: Server and API: the check tells a PC when its latest upload was refused

**Files:**
- Modify: `packages/api/src/index.ts` (`CheckEntry.rejected`)
- Modify: `apps/server/src/sync.ts` (`/check`: characters without a head, and `rejected`)
- Modify: `apps/desktop/engine/src/api.rs` (`CheckEntry.rejected`)
- Test: `apps/server/test/sync.test.ts`

**Interfaces:**
- Produces: `CheckEntry.rejected: string | null` (TypeScript) and `CheckEntry.rejected: Option<String>` (Rust, `#[serde(default)]`): why the server refused this PC's newest upload of that character, or null when it wasn't refused. A character whose only uploads were refused is listed with `version: null` and `fingerprint: ""`.

- [ ] **Step 1: Write the failing test** in `test/sync.test.ts`:

```ts
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
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/server && bun test sync.test.ts`
Expected: FAIL: the check lists no character (the only upload was refused, so there is no head), or `rejected` is undefined.

- [ ] **Step 3: The shared type.** In `packages/api/src/index.ts`, `CheckEntry` gains after `updateAddon`:

```ts
  // Why the server refused this PC's newest upload of this character, or
  // null. The app shows it against the character until a newer upload goes in.
  rejected: string | null;
```

and the `version` comment adds "or when it has no merged version yet".

- [ ] **Step 4: The check.** In `sync.ts` `/check`, the head becomes a left join and the newest upload from this PC is looked up per character:

```ts
    const rows = await db
      .select({ c: characters, head: versions })
      .from(characters)
      .leftJoin(versions, eq(versions.id, characters.headVersionId))
      .where(eq(characters.userId, device!.userId))
      .orderBy(characters.id);
```

```ts
    // This PC's newest upload of each character: if the merge refused it,
    // the app says so until a newer one goes in.
    const newest = new Map(
      (
        await db
          .selectDistinctOn([versions.characterId], {
            characterId: versions.characterId,
            status: versions.status,
            reason: versions.rejectReason,
          })
          .from(versions)
          .where(and(eq(versions.deviceId, device!.id), eq(versions.kind, "upload")))
          .orderBy(versions.characterId, desc(versions.id))
      ).map((r) => [r.characterId, r]),
    );
```

and in the mapping (import `desc` from drizzle-orm):

```ts
      characters: rows.map(({ c, head }) => {
        const updateAddon = head !== null && device!.dataLayout !== null && (head.dataVersion ?? 0) > device!.dataLayout;
        const last = newest.get(c.id);
        return {
          game: c.game,
          realm: c.realm,
          name: c.name,
          version: head === null || updateAddon ? null : head.id,
          fingerprint: head?.fingerprint ?? "",
          replace: head !== null && (applied.get(c.id) ?? 0) < (lastRestore.get(c.id) ?? 0),
          updateAddon,
          rejected: last?.status === "rejected" ? (last.reason ?? "refused") : null,
        };
      }),
```

- [ ] **Step 5: The Rust mirror.** In `apps/desktop/engine/src/api.rs` `CheckEntry`, after `update_addon`:

```rust
    /// Why the server refused this PC's newest upload of this character.
    #[serde(default)]
    pub rejected: Option<String>,
```

- [ ] **Step 6: Run the tests**

Run: `cd apps/server && bun test && bun run typecheck` and `. ~/.cargo/env && cd apps/desktop && cargo test -p rts-sync`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add packages/api apps/server apps/desktop/engine/src/api.rs
git commit -m "Server: the check tells a PC why its latest upload of a character was refused (#40)"
```

---

### Task 4: Engine: problems name a character in plain words and stay until fixed

**Files:**
- Modify: `apps/desktop/engine/src/sync.rs` (`Problem`, `Report.problems`, `upload`'s outcome, `pass`, `deliver`)
- Modify: `apps/desktop/engine/src/state.rs` (`State.refused`)
- Modify: `apps/desktop/engine/src/api.rs` (`Display` for a status with no code)
- Modify: `apps/desktop/engine/src/bin/rts-sync.rs` (prints problems)
- Test: `apps/desktop/engine/src/sync.rs` tests

**Interfaces:**
- Consumes: `CheckEntry.rejected` (Task 3).
- Produces: `pub struct Problem { pub who: String, pub why: String }` (`who` is `Name-Realm`, or a character's folder name like `Beagen` when the file has no rosterKey, or empty for a problem that isn't one character's); `Report.problems: Vec<Problem>`; `State.refused: BTreeMap<PathBuf, Refused>` with `pub struct Refused { pub fingerprint: String, pub who: String, pub why: String }`; `pub fn folder_name(path: &Path) -> String`.

- [ ] **Step 1: Write the failing tests.** In `sync.rs` tests, change `a_file_from_an_older_addon_is_a_problem_and_not_sent`'s assertion to:

```rust
        assert_eq!(
            report.problems,
            [Problem {
                who: "Ann".into(),
                why: "Log in once with the updated addon, then log out, so this character can be backed up".into()
            }]
        );
```

change `a_refused_file_is_a_problem_but_unlinked_stops_the_pass`'s `assert_eq!(report.problems.len(), 1);` to:

```rust
        assert_eq!(report.problems, [Problem { who: "Ann-Test Realm".into(), why: "Too big to back up".into() }]);
```

and add:

```rust
    #[test]
    fn a_refused_file_stays_a_problem_without_asking_again_until_it_changes() {
        let (dir, game) = game();
        let refused = fake::serve(|_, url| {
            if url.starts_with("/v1/upload") {
                (400, b"the server refuses this".to_vec())
            } else {
                (200, br#"{"characters":[]}"#.to_vec())
            }
        });
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let client = Client::new(&refused.url, Some("t".into()));
        let (s, j) = (dir.path().join("s.json"), dir.path().join("j"));
        pass(&client, &mut state, &s, std::slice::from_ref(&game), &j, |_| true).unwrap();
        let again = pass(&client, &mut state, &s, std::slice::from_ref(&game), &j, |_| false).unwrap();
        assert_eq!(again.problems.len(), 1, "still shown on a pass that sends nothing");
        assert_eq!(again.problems[0].why, "The server refused it: the server refuses this");
        let uploads = || refused.seen.lock().unwrap().iter().filter(|s| s.url.starts_with("/v1/upload")).count();
        pass(&client, &mut state, &s, std::slice::from_ref(&game), &j, |_| true).unwrap();
        assert_eq!(uploads(), 1, "the same file isn't sent again");

        let file = installs::saved_files(&game).remove(0);
        fs::write(&file.path, FILE.replace("[\"version\"] = 3", "[\"version\"] = 3, [\"x\"] = 1")).unwrap();
        let fixed = fake::serve(|_, url| {
            if url.starts_with("/v1/upload") {
                (200, br#"{"version":9,"status":"queued"}"#.to_vec())
            } else {
                (200, br#"{"characters":[]}"#.to_vec())
            }
        });
        let report = pass(&Client::new(&fixed.url, Some("t".into())), &mut state, &s, &[game], &j, |_| true).unwrap();
        assert!(report.problems.is_empty(), "{:?}", report.problems);
        assert!(state.refused.is_empty());
    }

    #[test]
    fn a_refusal_by_the_server_after_upload_is_a_problem_for_that_character() {
        let (dir, game) = game();
        let fake = fake::serve(|_, url| {
            if url == "/v1/check" {
                (200, br#"{"characters":[{"game":"_classic_beta_","realm":"Test Realm","name":"Ann","version":null,"fingerprint":"","replace":false,"updateAddon":false,"rejected":"a seeded test journey"}]}"#.to_vec())
            } else {
                (200, br#"{"version":8,"status":"queued"}"#.to_vec())
            }
        });
        let mut state = State {
            pc: Some("pc-1".into()),
            ..State::default()
        };
        let report = pass(&Client::new(&fake.url, Some("t".into())), &mut state, &dir.path().join("s.json"), &[game], &dir.path().join("j"), |_| false).unwrap();
        assert_eq!(
            report.problems,
            [Problem {
                who: "Ann-Test Realm".into(),
                why: "Your last session here isn't backed up: the server couldn't take it (a seeded test journey)".into()
            }]
        );
    }

    #[test]
    fn a_character_without_a_roster_key_is_named_by_its_folder() {
        assert_eq!(folder_name(Path::new("/wow/WTF/Account/A1/70/Beagen-Ironhewer/SavedVariables/RoadToSixty.lua")), "Beagen");
        assert_eq!(folder_name(Path::new("RoadToSixty.lua")), "A character");
    }
```

In `api.rs` tests:

```rust
    #[test]
    fn a_status_without_a_code_reads_as_plain_words() {
        assert_eq!(ApiError::Status(0, "couldn't keep version 7".into()).to_string(), "couldn't keep version 7");
        assert_eq!(ApiError::Status(413, "too big".into()).to_string(), "the server answered 413: too big");
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `. ~/.cargo/env && cd apps/desktop && cargo test -p rts-sync`
Expected: compile errors: `Problem`, `folder_name`, `state.refused` don't exist.

- [ ] **Step 3: The problem type and what's remembered.** In `state.rs`, `State` gains:

```rust
    /// Saved files that were refused, by path. Each stays a problem, without
    /// being sent again, until the file changes and goes up.
    #[serde(default)]
    pub refused: BTreeMap<PathBuf, Refused>,
```

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Refused {
    pub fingerprint: String,
    /// The character, as the app shows it.
    pub who: String,
    /// Why, in words for the player.
    pub why: String,
}
```

In `sync.rs`, replace `Report.problems` with `pub problems: Vec<Problem>` (its comment: "What kept a character, or the whole pass when `who` is empty, from being backed up. The rest of the pass goes on.") and add:

```rust
/// Something the player should know: `who` names the character (empty when
/// it isn't one character's), `why` says what's wrong in plain words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    pub who: String,
    pub why: String,
}

impl Problem {
    fn general(why: impl Into<String>) -> Problem {
        Problem { who: String::new(), why: why.into() }
    }
}

/// A character's name from its folder (`.../70/Beagen-Ironhewer/SavedVariables/RoadToSixty.lua`),
/// for a file that doesn't name its character yet.
pub fn folder_name(path: &Path) -> String {
    path.parent()
        .and_then(Path::parent)
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .and_then(|n| n.split('-').next())
        .filter(|n| !n.is_empty())
        .unwrap_or("A character")
        .to_string()
}

/// What happened to one saved file in a pass.
#[derive(Debug, PartialEq, Eq)]
pub enum Sent {
    /// Uploaded, as `Name-Realm`.
    Uploaded(String),
    /// The same file went up before.
    Unchanged,
    /// Refused now or before; it's in `State::refused`.
    Refused,
    /// Couldn't be read (the game may be writing it); tried again when it changes.
    Unreadable(Problem),
}
```

- [ ] **Step 4: Upload and pass use them.** Replace `upload`:

```rust
/// Uploads one saved file unless this exact file went up, or was refused, before.
pub fn upload(client: &Client, state: &mut State, file: &SavedFile, addon: Option<&str>) -> Result<Sent, ApiError> {
    let bytes = match fs::read(&file.path) {
        Ok(bytes) => bytes,
        Err(_) => {
            return Ok(Sent::Unreadable(Problem {
                who: folder_name(&file.path),
                why: "Couldn't read the saved file; trying again when it changes".into(),
            }));
        }
    };
    let print = fingerprint(&bytes);
    if state.uploaded.get(&file.path) == Some(&print) {
        return Ok(Sent::Unchanged);
    }
    if state.refused.get(&file.path).is_some_and(|r| r.fingerprint == print) {
        return Ok(Sent::Refused);
    }
    let mut refuse = |who: String, why: String| {
        state.refused.insert(file.path.clone(), Refused { fingerprint: print.clone(), who, why });
        Ok(Sent::Refused)
    };
    let Some((name, realm)) = roster_key(&bytes) else {
        return refuse(
            folder_name(&file.path),
            "Log in once with the updated addon, then log out, so this character can be backed up".into(),
        );
    };
    match client.upload(&file.game, &realm, &name, addon, synced_version(&bytes), &bytes) {
        Ok(_) => {}
        Err(ApiError::Status(413, _)) => return refuse(key(&name, &realm), "Too big to back up".into()),
        Err(ApiError::Status(code, body)) if code != 0 => {
            let why = if body.trim().is_empty() { format!("The server refused it ({code})") } else { format!("The server refused it: {}", body.trim()) };
            return refuse(key(&name, &realm), why);
        }
        Err(e) => return Err(e),
    }
    state.uploaded.insert(file.path.clone(), print);
    state.refused.remove(&file.path);
    Ok(Sent::Uploaded(key(&name, &realm)))
}
```

(If the borrow checker refuses the `refuse` closure while `state` is also used afterwards, make it a small `fn refuse(state: &mut State, path: &Path, print: &str, who: String, why: String) -> Result<Sent, ApiError>` instead.)

In `pass`, the loop:

```rust
        for file in installs::saved_files(game).iter().filter(|f| ready(f)) {
            match upload(client, state, file, addon.as_deref()) {
                Ok(Sent::Uploaded(sent)) => {
                    report.uploaded.push(sent);
                    state.save(state_path).map_err(|e| ApiError::Status(0, e.to_string()))?;
                }
                Ok(Sent::Unreadable(problem)) => report.problems.push(problem),
                Ok(Sent::Unchanged | Sent::Refused) => {}
                Err(e @ (ApiError::Unauthorized | ApiError::Network(_))) => return Err(e),
                Err(e) => report.problems.push(Problem::general(e.to_string())),
            }
        }
```

and before `let pc = …`:

```rust
    // Refusals stay shown until their file changes and goes up; a file
    // that's gone takes its refusal with it.
    state.refused.retain(|path, _| path.exists());
    let _ = state.save(state_path);
    report
        .problems
        .extend(state.refused.values().map(|r| Problem { who: r.who.clone(), why: r.why.clone() }));
```

In `deliver`, for each entry, right after `report.characters.push(…)`:

```rust
        if let Some(why) = &entry.rejected {
            report.problems.push(Problem {
                who: key(&entry.name, &entry.realm),
                why: format!("Your last session here isn't backed up: the server couldn't take it ({why})"),
            });
        }
```

and its other two problem pushes become `Problem { who, why: e.to_string() }` (the download one, `who` is the character) and `Problem::general(format!("Couldn't write the sync folder in {}: {e}", game.name))` (the folder's name, not its full path).

- [ ] **Step 5: Plain words for a status with no code.** In `api.rs` `Display`:

```rust
            ApiError::Status(0, why) => write!(f, "{why}"),
            ApiError::Status(code, body) => write!(f, "the server answered {code}: {body}"),
```

`rts-sync.rs` `show` prints `problem: {who}: {why}` (or just `{why}` when `who` is empty).

- [ ] **Step 6: Run the engine tests, clippy and formatting**

Run: `. ~/.cargo/env && cd apps/desktop && cargo test -p rts-sync && cargo clippy -p rts-sync --all-targets -- -D warnings && cargo fmt --check`
Expected: all pass. (The app crate won't build until Task 6; that's expected.)

- [ ] **Step 7: Commit**

```bash
git add apps/desktop/engine
git commit -m "Desktop: problems name the character in plain words and stay until the file goes up (#40)"
```

---

### Task 5: Engine: game folders are found again, and other small fixes

**Files:**
- Modify: `apps/desktop/engine/src/watch.rs` (`run` takes `find`; rescans; watcher rebuilt; one failing folder doesn't stop it)
- Modify: `apps/desktop/engine/src/sync.rs` (`Report.games`)
- Modify: `apps/desktop/engine/src/installs.rs` (`installs_in_product_db` keeps accented paths)
- Modify: `apps/desktop/engine/src/api.rs` (timeouts)
- Modify: `apps/desktop/engine/src/state.rs` (`data_dir` is the local folder)
- Modify: `apps/desktop/engine/src/bin/rts-sync.rs` (passes `find`)
- Test: `watch.rs`, `installs.rs` tests

**Interfaces:**
- Produces: `watch::run(client: &Client, state: &mut State, state_path: &Path, cache: &Path, find: &dyn Fn() -> Vec<GameFolder>, stop: &AtomicBool, report: impl FnMut(&Result<Report, ApiError>)) -> notify::Result<()>`; `Report.games: Vec<GameFolder>` (the game folders the pass used).

- [ ] **Step 1: Write the failing tests.** In `watch.rs` tests:

```rust
    #[test]
    fn a_wtf_folder_made_after_the_start_is_watched_and_its_file_goes_up() {
        use crate::api::{Client, fake};
        use std::sync::Arc;
        let dir = tempfile::tempdir().unwrap();
        let game = dir.path().join("wow/_classic_beta_");
        let toc = crate::installs::addon_toc(&game);
        std::fs::create_dir_all(toc.parent().unwrap()).unwrap();
        std::fs::write(&toc, "## Interface: 16001\n## Version: 1.9.0\n").unwrap();
        // canonicalize: the watcher reports real paths (on a Mac /var is /private/var).
        let game = std::fs::canonicalize(&game).unwrap();
        let fake = fake::serve(|_, url| match url {
            "/v1/check" => (200, br#"{"characters":[]}"#.to_vec()),
            _ => (200, br#"{"version":8,"status":"queued"}"#.to_vec()),
        });
        let seen = fake.seen.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (stop, url, data) = (stop.clone(), fake.url.clone(), dir.path().join("data"));
            let game = game.clone();
            std::thread::spawn(move || {
                let mut state = State { pc: Some("pc-1".into()), ..State::default() };
                let find = || vec![GameFolder { path: game.clone(), name: "_classic_beta_".into() }];
                run(&Client::new(&url, Some("t".into())), &mut state, &data.join("s.json"), &data.join("j"), &find, &stop, |_| {})
            })
        };
        std::thread::sleep(Duration::from_secs(2)); // started, with no WTF to watch
        let saved = game.join("WTF/Account/A1/70/Ann-Stormfist/SavedVariables");
        std::fs::create_dir_all(&saved).unwrap();
        std::fs::write(saved.join("RoadToSixty.lua"), "RoadToSixtyCharDB = {\r\n[\"rosterKey\"] = \"Ann-Test Realm\",\r\n}\r\n").unwrap();
        let until = Instant::now() + Duration::from_secs(30);
        let uploaded = || seen.lock().unwrap().iter().any(|s| s.url.starts_with("/v1/upload"));
        while !uploaded() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(200));
        }
        stop.store(true, Ordering::Relaxed);
        thread.join().unwrap().unwrap();
        assert!(uploaded(), "the file in the new WTF folder went up");
    }
```

In `installs.rs` tests:

```rust
    #[test]
    fn product_db_paths_may_have_accents() {
        let mut bytes = b"\x0a\x22".to_vec();
        bytes.extend_from_slice("D:/Jeux vidéo/World of Warcraft".as_bytes());
        bytes.extend_from_slice(b"\x12\x05other");
        assert!(installs_in_product_db(&bytes).contains(&PathBuf::from("D:/Jeux vidéo/World of Warcraft")));
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `. ~/.cargo/env && cd apps/desktop && cargo test -p rts-sync -- a_wtf_folder product_db_paths_may`
Expected: compile error (`run` still takes `games`), then once compiling, the WTF test times out and the accents test fails.

- [ ] **Step 3: Accented install paths.** Replace `installs_in_product_db`'s body:

```rust
    let mut found: Vec<PathBuf> = Vec::new();
    // Text runs end at control bytes; UTF-8 letters (é is two bytes over
    // 0x7f) stay in the run.
    for run in bytes.split(|b| *b < 0x20 || *b == 0x7f) {
        // A length byte before the text can itself read as a letter, or as
        // an invalid character, so the path may start a little way in.
        let text = String::from_utf8_lossy(run);
        let drive = text
            .char_indices()
            .find(|&(i, c)| c.is_ascii_alphabetic() && (text[i + 1..].starts_with(":/") || text[i + 1..].starts_with(":\\")))
            .map(|(i, _)| i);
        let Some(start) = drive.or_else(|| text.find('/')) else { continue };
        let path = PathBuf::from(text[start..].trim_end_matches('\u{FFFD}'));
        if !found.contains(&path) {
            found.push(path);
        }
    }
    found
```

- [ ] **Step 4: Find again in the watch loop.** In `watch.rs`, add above `run`:

```rust
/// Size and change time of each saved file, to notice changes the watcher missed.
fn stamps(games: &[GameFolder]) -> BTreeMap<PathBuf, (u64, Option<std::time::SystemTime>)> {
    games
        .iter()
        .flat_map(installs::saved_files)
        .map(|f| {
            let meta = std::fs::metadata(&f.path).ok();
            let stamp = (meta.as_ref().map_or(0, |m| m.len()), meta.and_then(|m| m.modified().ok()));
            (f.path, stamp)
        })
        .collect()
}

/// Watches each game folder's WTF for saved files, and each game folder and
/// install folder for new folders (WoW making WTF, a new game folder), which
/// set `lost` so the loop looks again. Problems watching one folder are
/// returned; the others are still watched.
fn watcher(games: &[GameFolder], tx: mpsc::Sender<PathBuf>, lost: Arc<AtomicBool>) -> (Option<notify::RecommendedWatcher>, Vec<Problem>) {
    let lost_too = lost.clone();
    let handler = move |event: notify::Result<notify::Event>| match event {
        Ok(event) if event.need_rescan() => lost_too.store(true, Ordering::Relaxed),
        Ok(event) => {
            for path in event.paths {
                if path.file_name().is_some_and(|n| n == "RoadToSixty.lua") {
                    let _ = tx.send(path);
                } else if !path.components().any(|c| c.as_os_str() == "WTF") {
                    lost_too.store(true, Ordering::Relaxed);
                }
            }
        }
        // A watcher error may mean missed events: look again.
        Err(_) => lost_too.store(true, Ordering::Relaxed),
    };
    let mut watcher = match notify::recommended_watcher(handler) {
        Ok(w) => w,
        Err(e) => return (None, vec![Problem { who: String::new(), why: format!("Couldn't watch for saved games: {e}") }]),
    };
    let mut problems = Vec::new();
    for wtf in sync::watched(games) {
        if let Err(e) = watcher.watch(&wtf, RecursiveMode::Recursive) {
            problems.push(Problem { who: String::new(), why: format!("Couldn't watch {}: {e}", wtf.display()) });
        }
    }
    let mut folders: Vec<PathBuf> = games.iter().flat_map(|g| [Some(g.path.clone()), g.path.parent().map(Path::to_path_buf)]).flatten().collect();
    folders.sort();
    folders.dedup();
    for folder in folders {
        let _ = watcher.watch(&folder, RecursiveMode::NonRecursive);
    }
    drop(lost);
    (Some(watcher), problems)
}
```

and rewrite `run`:

```rust
/// Watches the WTF folders of the game folders `find` returns and syncs
/// until `stop` is set, calling `report` after each pass. It looks for game
/// folders and changed files again every few minutes and whenever a folder
/// appears or the watcher may have missed something, so WoW creating its
/// WTF folder after the app started is noticed. Every saved journey counts
/// as changed at the start (an unchanged file is skipped by its fingerprint).
pub fn run(
    client: &Client,
    state: &mut State,
    state_path: &Path,
    cache: &Path,
    find: &dyn Fn() -> Vec<GameFolder>,
    stop: &AtomicBool,
    mut report: impl FnMut(&Result<Report, ApiError>),
) -> notify::Result<()> {
    let (tx, rx) = mpsc::channel();
    let lost = Arc::new(AtomicBool::new(false));
    let mut games = find();
    let (mut _watching, mut watch_problems) = watcher(&games, tx.clone(), lost.clone());
    let mut seen = stamps(&games);

    let mut schedule = Schedule::default();
    let start = Instant::now();
    for path in seen.keys() {
        schedule.changed(path.clone(), start.checked_sub(SETTLE).unwrap_or(start));
    }
    let mut system = sysinfo::System::new();
    let mut last_pass: Option<Instant> = None;
    let mut wait_until = start;
    while !stop.load(Ordering::Relaxed) {
        let now = Instant::now();
        let check_due = last_pass.is_none_or(|t| now.duration_since(t) >= CHECK_EVERY);
        if lost.swap(false, Ordering::Relaxed) || (check_due && last_pass.is_some()) {
            let found = find();
            if found != games {
                games = found;
                (_watching, watch_problems) = watcher(&games, tx.clone(), lost.clone());
            }
            let now_seen = stamps(&games);
            for (path, stamp) in &now_seen {
                if seen.get(path) != Some(stamp) {
                    schedule.changed(path.clone(), now);
                }
            }
            seen = now_seen;
        }
        for path in rx.try_iter() {
            schedule.changed(path, now);
        }
        let programs = if schedule.settled(now) { running_programs(&mut system) } else { Vec::new() };
        let playing = |file: &Path| games.iter().any(|g| file.starts_with(&g.path) && game_running(&g.path, &programs));
        let due = schedule.due(now, playing);
        if now >= wait_until && (!due.is_empty() || check_due) {
            let result = sync::pass(client, state, state_path, &games, cache, |f| due.contains(&f.path)).map(|mut r| {
                r.problems.extend(watch_problems.iter().cloned());
                r
            });
            match &result {
                Ok(_) => {
                    schedule.sent(&due, now);
                    last_pass = Some(now);
                }
                Err(_) => wait_until = now + RETRY,
            }
            report(&result);
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    Ok(())
}
```

Add `use std::sync::Arc;`, `use crate::sync::Problem;` and `use crate::installs::GameFolder;` as needed. In `sync.rs`, `Report` gains `pub games: Vec<GameFolder>` ("The game folders this pass looked at, for the app to show.") and `pass` sets `report.games = games.to_vec();` at its start.

`rts-sync.rs`'s `run` arm: `let find = || sync::games(&State { picked: state.picked.clone(), ..State::default() });` then `watch::run(&client, &mut state, &state_path, &cache, &find, &stop, show)` (take `picked` before the call so `state` isn't borrowed twice).

- [ ] **Step 5: Timeouts and the data folder.** In `api.rs` `Client::new`, replace `.timeout_global(Some(Duration::from_secs(120)))` with:

```rust
            // Each step has its own limit, so a slow connection can still send
            // a large journey; a server that stops answering still times out.
            .timeout_connect(Some(Duration::from_secs(30)))
            .timeout_recv_response(Some(Duration::from_secs(120)))
            .timeout_send_body(Some(Duration::from_secs(30 * 60)))
            .timeout_recv_body(Some(Duration::from_secs(30 * 60)))
```

In `state.rs`, `data_dir` uses `dirs::data_local_dir()`, with the comment "On Windows the local folder, not the roaming one: a roaming profile would copy the token and the PC's identity to other PCs." (The same folder on a Mac and on Linux. On Jordan's Windows PC the app will ask to link again once.)

- [ ] **Step 6: Run the engine tests**

Run: `. ~/.cargo/env && cd apps/desktop && cargo test -p rts-sync && cargo clippy -p rts-sync --all-targets -- -D warnings && cargo fmt --check`
Expected: all pass; the WTF test takes about 12 seconds (the 10-second settle).

- [ ] **Step 7: Commit**

```bash
git add apps/desktop/engine
git commit -m "Desktop: look for game folders again when they change, and keep watching if one folder fails (#40)

Also accented install paths in product.db, per-step timeouts so slow
connections can send a large journey, and the local data folder on Windows."
```

---

### Task 6: App: show problems against characters, look again when idle, survive a damaged state file

**Files:**
- Modify: `apps/desktop/src-tauri/src/status.rs` (`Character.problem`, the tray line, problems from the engine)
- Modify: `apps/desktop/src-tauri/src/runner.rs` (games from each report, `rescan`, a damaged `state.json`)
- Modify: `apps/desktop/src-tauri/src/main.rs` (the ticker rescans)
- Modify: `apps/desktop/src/api.ts`, `Characters.tsx`, `FirstRun.tsx` (problem rows; the drag strip only on a Mac)
- Test: `status.rs`, `runner.rs` tests

**Interfaces:**
- Consumes: `Problem`, `Report.problems`, `Report.games`, `watch::run(…, find, …)` (Tasks 4 and 5).
- Produces: `Character.problem: Option<String>` (`problem: string | null` in `api.ts`); `Runner::rescan(&mut self) -> Result<(), String>`; `Status.problems` holds only the problems that aren't one character's.

- [ ] **Step 1: Write the failing tests.** In `status.rs` tests, add (and change `report`'s `..Report::default()` callers as needed):

```rust
    #[test]
    fn a_character_that_isnt_backed_up_says_why_and_the_tray_counts_it() {
        let mut s = linked();
        let mut r = Report {
            characters: vec!["Ann-Test".into()],
            ..Report::default()
        };
        r.problems = vec![
            Problem { who: "Ann-Test".into(), why: "Too big to back up".into() },
            Problem { who: "Beagen".into(), why: "Log in once with the updated addon".into() },
            Problem { who: String::new(), why: "Couldn't write the sync folder in _classic_beta_".into() },
        ];
        apply(&mut s, &Ok(r), &["Ann-Test".into()], 100);
        refresh(&mut s, 100);
        let rows: Vec<_> = s.characters.iter().map(|c| (c.key.as_str(), c.note.as_str())).collect();
        assert_eq!(rows, [("Ann-Test", "Too big to back up"), ("Beagen", "Log in once with the updated addon")]);
        assert_eq!(s.problems, ["Couldn't write the sync folder in _classic_beta_"]);
        assert_eq!(s.line, "2 characters not backed up");
    }

    #[test]
    fn a_problem_that_isnt_a_characters_is_still_in_the_tray() {
        let mut s = linked();
        let r = Report {
            problems: vec![Problem { who: String::new(), why: "Couldn't watch for saved games".into() }],
            ..Report::default()
        };
        apply(&mut s, &Ok(r), &[], 100);
        refresh(&mut s, 100);
        assert_eq!(s.line, "Needs a look: open Road to Sixty");
    }
```

In `runner.rs` tests, add:

```rust
    #[test]
    fn a_damaged_settings_file_is_a_problem_not_a_crash() {
        let mut t = setup(true);
        std::fs::write(t.dir.path().join("data/state.json"), "{ not json").unwrap();
        assert!(t.runner.start().is_ok());
        assert!(t.notifier.get().problems[0].contains("settings file is damaged"), "{:?}", t.notifier.get().problems);
        assert!(!t.runner.is_running());
    }

    #[test]
    fn looking_again_while_idle_finds_a_game_installed_since() {
        let mut t = setup(false);
        let empty = t.dir.path().join("elsewhere");
        std::fs::create_dir_all(&empty).unwrap();
        t.runner.start().unwrap();
        assert!(t.runner.rescan().is_ok());
        assert_eq!(t.notifier.get().games.len(), 1);
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `. ~/.cargo/env && cd apps/desktop && bun run build && cargo test -p road-to-sixty-app`
Expected: compile errors (`Problem` not imported, `rescan` missing, `Report.problems` now `Vec<Problem>`).

- [ ] **Step 3: Status.** In `status.rs`: `use rts_sync::sync::{Problem, Report};`. `Character` gains:

```rust
    /// Why it isn't backed up, if it isn't.
    pub problem: Option<String>,
```

`Status.problems`' comment: "Problems that aren't one character's, for the window." In `apply`'s `Ok` arm:

```rust
            status.problems = report.problems.iter().filter(|p| p.who.is_empty()).map(|p| p.why.clone()).collect();
            let problem = |key: &str| report.problems.iter().find(|p| p.who == key).map(|p| p.why.clone());
            let mut keys: Vec<String> = report
                .characters
                .iter()
                .chain(local)
                .cloned()
                .chain(report.problems.iter().filter(|p| !p.who.is_empty()).map(|p| p.who.clone()))
                .collect();
```

(sort and dedup as before) and each `Character` gets `problem: problem(&key),` and `here: local.contains(&key) || report.problems.iter().any(|p| p.who == key && !report.characters.contains(&key)),`. The `Err(e)` arm stays `status.problems = vec![e.to_string()]`.

In `refresh`, the note puts the problem first: `c.note = if let Some(why) = &c.problem { why.clone() } else if c.update_addon { … }`. The line, after the `offline` branch:

```rust
    } else if let n @ 1.. = status.characters.iter().filter(|c| c.problem.is_some()).count() {
        if n == 1 { "1 character not backed up".into() } else { format!("{n} characters not backed up") }
    } else if !status.problems.is_empty() {
        "Needs a look: open Road to Sixty".into()
```

Update the tests that build `Character` or `Report` by hand (`linked()` is unaffected; `Report { … }` literals need `..Report::default()`).

- [ ] **Step 4: Runner.** In `runner.rs`:

`start()` loads the state without failing:

```rust
        let state = match State::load(&self.state_path) {
            Ok(state) => state,
            Err(e) => {
                self.notifier.update(|s| {
                    s.problems = vec![format!(
                        "The app's settings file is damaged ({e}). Unlink this PC on the Account tab and link it again to start fresh."
                    )]
                });
                return Ok(());
            }
        };
```

`unlink()` writes a fresh state even when the old one can't be read: `let picked = State::load(&self.state_path).map(|s| s.picked).unwrap_or_default();` then `State { picked, ..State::default() }.save(…)`.

The thread passes a `find` closure and shows the games each pass used:

```rust
        let picked = state.picked.clone();
        let find = self.find.clone();
        self.thread = Some(std::thread::spawn(move || {
            let client = Client::new(&server, token);
            let mut state = state;
            let lookup = || find(&State { picked: picked.clone(), ..State::default() });
            let report = |result: &Result<Report, ApiError>| {
                let local = result.as_ref().map(|r| local_keys(&r.games)).unwrap_or_default();
                notifier.update(|s| {
                    if let Ok(r) = result {
                        s.games = shown(&r.games);
                    }
                    apply(s, result, &local, now());
                });
            };
            if let Err(e) = watch::run(&client, &mut state, &state_path, &cache, &lookup, &stop, report) {
                notifier.update(|s| s.problems = vec![format!("Couldn't watch the game folders: {e}")]);
            }
        }));
```

with `shown` the existing `games.iter().map(|g| Game { … })` from `start()` moved into `fn shown(games: &[GameFolder]) -> Vec<Game>` and used in both places. Drop `games` from the thread's captures (the closure finds them). `is_running` loses `#[cfg(test)]`, and:

```rust
    /// Looks for game folders again when nothing is syncing (not linked, or
    /// no WoW found yet); a running sync looks for itself.
    pub fn rescan(&mut self) -> Result<(), String> {
        if self.is_running() { Ok(()) } else { self.start() }
    }
```

`add_folder`'s problem and the commands' `s.problems = vec![…]` lines stay as they are (general problems).

- [ ] **Step 5: The ticker looks again.** In `main.rs`, the 30-second thread becomes:

```rust
            // "Synced 2 min ago" has to keep counting, and while nothing syncs
            // (not linked, or no WoW yet) the app looks for WoW again.
            let ticker = app.handle().clone();
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(Duration::from_secs(30));
                    notifier.update(|_| {});
                    commands::with_runner(ticker.clone(), |r| r.rescan());
                }
            });
```

- [ ] **Step 6: The window.** In `api.ts`, `Character` gains `problem: string | null;` and add:

```ts
// Only a Mac draws its window buttons over the window; Windows has a title bar.
export const isMac = navigator.userAgent.includes("Mac");
```

In `Characters.tsx`, a row warns when `c.updateAddon || c.problem` (both the border and the note's colour), and the drag strip is `{isMac && <div data-tauri-drag-region className="h-9 shrink-0 border-b border-line-soft" />}`; the same for `FirstRun.tsx`'s strip. The status pill's dot is blue only when `!status.paused && !status.offline && status.problems.length === 0 && !status.characters.some((c) => c.problem)`.

- [ ] **Step 7: Run everything**

Run: `. ~/.cargo/env && cd apps/desktop && bun run build && bun run typecheck && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check`
Expected: all pass.

- [ ] **Step 8: Update `apps/desktop/AGENTS.md`** (the runner and watch bullets: the app looks again on folder changes, every 5 minutes while syncing and every 30 seconds while idle; refusals stay in `state.json`'s `refused` until the file goes up; problems carry `who`) and commit:

```bash
git add apps/desktop
git commit -m "Desktop: show what isn't backed up against each character and in the tray, look for WoW again while idle, and open with a damaged settings file (#40)"
```

---

### Task 7: Docs, merge, and the 0.1.1 release

**Files:**
- Modify: `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md` ("The merge rules": open runs and groups; "Merge jobs": faults retried for a day, refusals rejected; "While running": looks for game folders again)
- Modify: `apps/addon/AGENTS.md` (run and group carry `pc`), `apps/desktop/src-tauri/tauri.conf.json` and `src-tauri/Cargo.toml` (`version` 0.1.1)

- [ ] **Step 1: Spec and docs.** Add to "The merge rules" a bullet: "A dungeon run or group still open at logout (`run`, `group`) is kept from whichever copy has it until the merged events hold its end (the run's `out`, the group's `grpx`); it counts under the PC that started it (`pc`), so two PCs finishing it count it once." In "Merge jobs", replace "A failed check, a crash or a timeout marks the job and the upload rejected" with "A refusal by the merge rules marks the upload rejected with the reason. A fault (a crash, a timeout, a bug, storage down) is retried with a doubling wait for about a day before the upload is marked as the server's failure; the PC is told on its next check." In "While running", add "Look for game folders and changed files again every few minutes, and whenever a game or install folder changes."

- [ ] **Step 2: Whole-branch review, then merge.** Run the final review (executing-plans), fix what it finds, then from the repo root: `bun run test` (with Docker up for the server), merge `sync-hardening` into `dev`, push `dev`, and watch CI (`gh run watch <id> --exit-status`). Dokploy deploys the server from `dev` and its migration adds `jobs.claimed_at` at start; check `https://api.rts.everhold.online` answers afterwards.

- [ ] **Step 3: Release 0.1.1 (needs Jordan's go-ahead: it publishes).** Bump `version` to 0.1.1 in `tauri.conf.json` and `src-tauri/Cargo.toml`, commit `Desktop: 0.1.1 (#40)`, push `dev`, tag `app-v0.1.1` and push the tag, watch the Desktop release workflow. This is also the self-update test: the installed 0.1.0 on the Mac and the Windows PC should offer 0.1.1 from "Check for updates", restart into it, and stay linked (on Windows, the local data folder means linking once more).

- [ ] **Step 4: Comment on #40** with what was fixed (items 1, 2, 3 and 6, the Windows findings, and the small items), and what's left and where it goes.
