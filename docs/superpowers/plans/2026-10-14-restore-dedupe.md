# Restore Dedupe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An upload made before a restore reached its PC is merged, minus the play the restore took out, instead of being set aside, so real play from another PC is never lost and a copied WTF folder can't bring restored-away play back.

**Architecture:** A character is online on one PC at a time, so each play session has its own stretch of time. When a restore is made, the server works out which sessions the old journey had and the restored one doesn't (`Merge.Windows`) and stores those time windows on the restore's row. When an upload arrives that was made before the latest restore reached its PC, the worker passes every restore's windows to the merge runner, which strips the upload's play inside them (`Merge.Strip`) before merging. Nothing changes in the addon's saved format, the sync folder, `/check` or `Sync.lua`: the addon still replaces on the restore id.

**Tech Stack:** Lua 5.1 (the addon's pure `Merge.lua`, run by the server's `runner.lua`), Bun, Elysia, Drizzle on Postgres.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md` ("Restore", "Merge jobs"). Decided with Jordan on 2026-10-14 (issue #40): dedupe by time window instead of setting such uploads aside.

## Global Constraints

- Branch `restore-dedupe` from `dev`; merged into `dev` locally at the end. Never push `main`.
- Commits: `Area: what changed (#N)`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- British spelling; comments are plain sentences that say why.
- `Merge.lua` makes no game calls (`tests/pure_test.lua` checks it). Every new function in it is pure.
- Migrations come from `bun run db:generate` in `apps/server`, never by hand.
- Test journeys are made up. Never a real saved file.
- `AGENTS.md` changes in the same commit as what it describes.
- No Rust or app changes in this plan.

Commands:

- Addon: `cd apps/addon && bun run test` (LuaJIT, and Lua 5.1 when `lua5.1` is on the path).
- Server: `cd apps/server && docker compose up -d && bun test` (`LUA51` names a standard Lua 5.1 if `lua5.1` isn't on the path), and `bun run typecheck`.

## How it works, and what it leaves

- **A window** is one session of the old journey: from its `on` event to the next `off` at or after it; with no `off`, to one second before the next `on`; with neither, to the journey's last event.
- **Which uploads are stripped:** any upload whose `received` is older than the character's latest restore, including a PC that never received anything. This covers both kinds the worker sets aside today (ruling below).
- **What is stripped from such an upload:** events, path segments (by start time), kills and level snapshots inside a window; its totals and every later snapshot's counts are lowered by what was stripped (otherwise the merge's recount puts it all back as "counts kept before the data"). A window whose `on` the current journey already has is skipped: the journey has that session now, for example after a restore was undone.
- **Counts that can't be recounted** (per-PC tallies: groups, dungeon runs, rares): parts under a PC id the current journey already holds are lowered to the journey's value, so a copied folder can't raise them; parts under a PC id the journey doesn't know (a new PC's own counts) are kept.
- **Left as they are, accepted:** recipes and profession ranks learned during a removed session, mounts and riding first noted then, people met only then, and a stale PC's own new tally increments since its last sync (tallies carry no times, so they can't be told from restored-away ones). None of these loses play.

## Rulings made while planning

- **Stale uploads from PCs that synced before get the same treatment as first uploads.** Today both are set aside, and both lose real play the same way (a PC that played while another restored). One rule for both is simpler and loses less. Cost if wrong: such a PC's own tally increments since its last sync are lowered to the journey's value.
- **Windows are kept in the database, not in the journey,** on the restore's row (`versions.removed`, JSON `[[from, to], ...]`). No saved format, sync folder or addon change. Restores made before this plan have no windows, and their stale uploads merge whole.
- **The `superseded` status stays in the schema,** for rows already marked so; nothing new is marked superseded.

## Review Focus

1. A session with no `off` event (the game closed uncleanly): its window still ends, at the next `on` or the last event. (Task 1.)
2. An upload whose level snapshot comes after a removed window: the snapshot's counts are lowered too, so the merged snapshot matches the journey's. (Task 1.)
3. A restore undone by restoring the newer version: an older stale upload holding those sessions merges them, since the journey has them again. (Task 1, the skipped window.)
4. A copied folder taken after its PC had applied the restore: nothing to strip, it merges cleanly. (Task 3.)
5. A stale upload at layout 2: `Prepare` turns its counts into the uploading PC's tallies before the cap, so they stay. (Task 2.)

---

### Task 1: `Merge.Windows` and `Merge.Strip`

**Files:**
- Modify: `apps/addon/RoadToSixty/Merge.lua` (new section before "For the server")
- Create: `apps/addon/tests/restore_test.lua`
- Modify: `apps/addon/AGENTS.md`

**Interfaces:**
- Produces: `Merge.Windows(old, kept) -> { {from, to}, ... }`, the sessions of journey `old` whose `on` time isn't an `on` in `kept`, oldest first. `Merge.Strip(char, windows, head) -> char`: removes from `char`, in place, its play inside each window whose `on` time isn't an `on` in `head`; lowers `char.totals` and its later snapshots by what was removed; caps its tally parts under PC ids `head` holds. Both pure.

- [ ] **Step 1: Write the failing tests**

Create `apps/addon/tests/restore_test.lua`:

```lua
-- Offline test of Merge.Windows and Merge.Strip: an upload made before a
-- restore reached its PC loses only the play the restore took out. Run
-- with LuaJIT from apps/addon: luajit tests/restore_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
for _, name in ipairs({ "Packed.lua", "Tally.lua", "Parse.lua", "Merge.lua" }) do
    assert(loadfile("RoadToSixty/" .. name))("RoadToSixty", ns)
end
local Merge = ns.Merge

local function Journey(fields)
    local j = {
        version = 3, segments = {}, events = {}, levels = {}, recipes = {}, people = {},
        kills = { d = "", last = 0, names = {} },
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 },
    }
    for k, v in pairs(fields or {}) do j[k] = v end
    return j
end

-- One session: on, a death, off.
local function Session(t)
    return { { t, "on", 0, 0, 0, 10 }, { t + 60, "die", 0, 0, 0 }, { t + 120, "off", 0, 0, 0 } }
end
local function Events(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, e in ipairs(list) do out[#out + 1] = e end
    end
    return out
end
local function Times(char, kind)
    local out = {}
    for _, e in ipairs(char.events) do
        if e[2] == kind then out[#out + 1] = e[1] end
    end
    return table.concat(out, ",")
end

-- 1. Windows: the old journey's sessions the kept one lacks.
local old = Journey({ events = Events(Session(1000), Session(5000), Session(9000)) })
local kept = Journey({ events = Events(Session(1000)) })
local w = Merge.Windows(old, kept)
check(#w == 2 and w[1][1] == 5000 and w[1][2] == 5120 and w[2][1] == 9000 and w[2][2] == 9120,
    "windows are the sessions only the old journey has, on to off")

local noOff = Journey({ events = { { 1000, "on", 0, 0, 0, 10 }, { 1050, "die", 0, 0, 0 }, { 2000, "on", 0, 0, 0, 10 }, { 2030, "die", 0, 0, 0 } } })
w = Merge.Windows(noOff, Journey())
check(#w == 2 and w[1][2] == 1999 and w[2][2] == 2030,
    "a session with no off ends a second before the next on, or at the last event")

-- 2. Strip: events, segments, kills and snapshots inside a window go, and
-- the totals and later snapshots come down by what went.
local function Upload()
    return Journey({
        events = Events(Session(1000), Session(5000), Session(9000)),
        segments = {
            { m = "w", c = 0, t = 1000, x = 0, y = 0, d = "10,3,4" },
            { m = "w", c = 0, t = 5000, x = 0, y = 0, d = "10,30,40" },
            { m = "w", c = 0, t = 9000, x = 0, y = 0, d = "10,6,8" },
        },
        kills = ns.Packed.PackKills({ { t = 1010, xp = 5, name = "Kobold" }, { t = 5010, xp = 7, name = "Murloc" }, { t = 9010, xp = 9, name = "Gnoll" } }),
        levels = { [3] = { t = 5050, kills = 2 }, [4] = { t = 9050, kills = 3, deaths = 3 } },
        totals = { kills = 3, killXP = 21, questXP = 0, deaths = 3, quests = 0, instances = 0, distance = 65, flown = 0 },
    })
end
local up = Merge.Strip(Upload(), { { 5000, 5120 } }, Journey({ events = Events(Session(1000)) }))
check(Times(up, "on") == "1000,9000", "the removed session's events go")
check(#up.segments == 2 and up.segments[2].t == 9000, "the removed session's path goes")
check(#up.kills.names == 2 and up.kills.names[1] ~= "Murloc" and up.kills.names[2] ~= "Murloc", "the removed session's kills go")
check(up.levels[3] == nil, "a level reached in the removed session goes")
check(up.totals.kills == 2 and up.totals.killXP == 14 and up.totals.deaths == 2 and up.totals.distance == 15,
    "the totals come down by what was removed")
check(up.levels[4].kills == 2 and up.levels[4].deaths == 2, "a later snapshot comes down too")

-- 3. Merged with the journey, the stripped upload brings its new play and
-- nothing the restore took out.
local head = Journey({
    events = Events(Session(1000)),
    segments = { { m = "w", c = 0, t = 1000, x = 0, y = 0, d = "10,3,4" } },
    kills = ns.Packed.PackKills({ { t = 1010, xp = 5, name = "Kobold" } }),
    totals = { kills = 1, killXP = 5, questXP = 0, deaths = 1, quests = 0, instances = 0, distance = 5, flown = 0 },
})
local out = Merge.Merge(head, Merge.Strip(Upload(), { { 5000, 5120 } }, head))
check(Times(out, "on") == "1000,9000", "the merge keeps the new session and not the removed one")
check(out.totals.kills == 2 and out.totals.deaths == 2, "and its totals hold no trace of the removed one")
check(Merge.Check(head, Merge.Strip(Upload(), { { 5000, 5120 } }, head), out), "the server's check passes on the stripped upload")

-- 4. A window the journey has again (the restore was undone) is skipped.
local undone = Journey({ events = Events(Session(1000), Session(5000)) })
check(Times(Merge.Strip(Upload(), { { 5000, 5120 } }, undone), "on") == "1000,5000,9000", "a session the journey has again stays")

-- 5. Tallies: a PC the journey knows can't go above the journey's count; a
-- PC it doesn't know keeps its own.
local headTallies = Journey({ events = Events(Session(1000)), people = { ["Player-1-01"] = { groups = { pcA = 2 } } } })
local copied = Journey({
    events = Events(Session(1000), Session(5000)),
    people = {
        ["Player-1-01"] = { groups = { pcA = 5, pcB = 1 } },
        ["Player-1-02"] = { groups = { pcA = 1 } },
    },
    rares = { ["Old Murk-Eye"] = { { pcA = 2, pcB = 1 } } },
})
local capped = Merge.Strip(copied, { { 5000, 5120 } }, headTallies)
check(capped.people["Player-1-01"].groups.pcA == 2 and capped.people["Player-1-01"].groups.pcB == 1,
    "a known PC's tally comes down to the journey's; an unknown PC's stays")
check(capped.people["Player-1-02"].groups == nil, "a known PC's tally the journey doesn't have goes")
check(capped.rares["Old Murk-Eye"][1].pcA == nil and capped.rares["Old Murk-Eye"][1].pcB == 1, "rares the same way")

-- 6. No windows: nothing changes.
local same = Upload()
Merge.Strip(same, {}, head)
check(Times(same, "on") == "1000,5000,9000" and same.totals.kills == 3, "no windows, nothing stripped")

if failures == 0 then
    print("Restore tests passed.")
else
    print(failures .. " restore test(s) failed.")
    os.exit(1)
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/addon && luajit tests/restore_test.lua`
Expected: an error, `attempt to call field 'Windows' (a nil value)`.

- [ ] **Step 3: Write the two functions**

In `apps/addon/RoadToSixty/Merge.lua`, before `-- For the server ---`, add (it uses the file's own `LastSeen`, `KillList`, `Counts`, `COUNTED` and `ns.Packed.PackKills`):

```lua
-- Restores -----------------------------------------------------------------------

-- The "on" times of a journey's sessions, as a set.
local function OnTimes(char)
    local on = {}
    for _, e in ipairs(char.events or {}) do
        if e[2] == "on" then on[e[1]] = true end
    end
    return on
end

-- The sessions of old whose "on" isn't in kept, as { from, to }, oldest
-- first: what a restore from old to kept takes out. A session runs from
-- its "on" to the next "off"; with none, to a second before the next
-- "on", or to the last event. One character plays on one PC at a time, so
-- these stretches of time hold that play and nothing else.
function Merge.Windows(old, kept)
    local keep, events, windows = OnTimes(kept), old.events or {}, {}
    for i, e in ipairs(events) do
        if e[2] == "on" and not keep[e[1]] then
            local to = LastSeen(old)
            for j = i + 1, #events do
                if events[j][2] == "off" then
                    to = events[j][1]
                    break
                elseif events[j][2] == "on" then
                    to = events[j][1] - 1
                    break
                end
            end
            windows[#windows + 1] = { e[1], to }
        end
    end
    return windows
end

-- Every PC id with a part in one of a journey's tallies.
local function TallyPCs(char)
    local pcs = {}
    for _, p in pairs(char.people or {}) do
        for _, f in ipairs(ns.Tally.PEOPLE) do
            if type(p[f]) == "table" then
                for pc in pairs(p[f]) do pcs[pc] = true end
            end
        end
    end
    for _, r in pairs(char.rares or {}) do
        if type(r[1]) == "table" then
            for pc in pairs(r[1]) do pcs[pc] = true end
        end
    end
    return pcs
end

-- A tally's parts under the PCs head knows, no higher than head's.
local function Cap(t, theirs, known)
    if type(t) ~= "table" then return t end
    local out = {}
    for pc, n in pairs(t) do
        if known[pc] then
            local most = type(theirs) == "table" and theirs[pc] or 0
            n = math.min(n, most)
        end
        if n > 0 then out[pc] = n end
    end
    return next(out) and out or nil
end

-- Takes out of char (an upload made before a restore reached its PC) its
-- play inside windows, the sessions the restore removed, so merging it
-- can't bring them back. A window whose "on" head (the current journey)
-- has is skipped: head holds that session again. The totals and later
-- snapshots come down by what was taken out, or the recount would put it
-- back as counts kept before the data. Tallies carry no times, so parts
-- under a PC head knows are held to head's; a new PC's parts stay. Changes
-- char in place and returns it.
function Merge.Strip(char, windows, head)
    local has, live = OnTimes(head), {}
    for _, w in ipairs(windows) do
        if not has[w[1]] then live[#live + 1] = w end
    end
    if #live == 0 then return char end
    local function Inside(t)
        if type(t) ~= "number" then return false end
        for _, w in ipairs(live) do
            if t >= w[1] and t <= w[2] then return true end
        end
        return false
    end
    local gone = { events = {}, segments = {}, levels = {} }
    local function Split(list, timeOf, into)
        local stay = {}
        for _, item in ipairs(list or {}) do
            if Inside(timeOf(item)) then into[#into + 1] = item else stay[#stay + 1] = item end
        end
        return stay
    end
    char.events = Split(char.events, function(e) return e[1] end, gone.events)
    char.segments = Split(char.segments, function(s) return s.t end, gone.segments)
    local kills, goneKills = {}, {}
    for _, k in ipairs(KillList(char.kills)) do
        if Inside(k.t) then goneKills[#goneKills + 1] = k else kills[#kills + 1] = k end
    end
    if #goneKills > 0 then char.kills = ns.Packed.PackKills(kills) end
    gone.kills = ns.Packed.PackKills(goneKills)
    for level, s in pairs(char.levels or {}) do
        if Inside(s.t) then char.levels[level] = nil end
    end
    -- What was taken out, counted up to each snapshot that stays and to the end.
    for level, s in pairs(char.levels or {}) do gone.levels[level] = { t = s.t } end
    local removed = Counts(gone)
    for _, f in ipairs(COUNTED) do
        if char.totals and tonumber(char.totals[f]) then
            char.totals[f] = char.totals[f] - removed[math.huge][f]
        end
    end
    for _, s in pairs(char.levels or {}) do
        local at = s.t and removed[s.t]
        if at then
            for _, f in ipairs(COUNTED) do
                if tonumber(s[f]) then s[f] = s[f] - at[f] end
            end
        end
    end
    local known = TallyPCs(head)
    for guid, p in pairs(char.people or {}) do
        local theirs = head.people and head.people[guid] or {}
        for _, f in ipairs(ns.Tally.PEOPLE) do p[f] = Cap(p[f], theirs[f], known) end
    end
    for key, r in pairs(char.rares or {}) do
        local theirs = head.rares and head.rares[key]
        r[1] = Cap(r[1], theirs and theirs[1], known)
    end
    return char
end
```

If `Counts` is defined after this point in the file, move the new section below the totals section instead. Every helper it calls must already be defined above it.

- [ ] **Step 4: Run the addon tests**

Run: `cd apps/addon && luajit tests/restore_test.lua && bun run test`
Expected: `Restore tests passed.`, then every test file passes under LuaJIT and Lua 5.1 (`pure_test` included).

- [ ] **Step 5: AGENTS.md and commit**

`apps/addon/AGENTS.md`, after the `Merge.lua` purity rule, add:

```markdown
- `Merge.Windows` and `Merge.Strip` serve restores on the sync server: the
  sessions a restore took out, and taking them out of an upload made before
  the restore reached its PC. `tests/restore_test.lua` covers them.
```

```bash
git add apps/addon
git commit -m "Merge: find the sessions a restore took out, and take them out of a stale upload (#40)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The runner works out windows and strips with them

**Files:**
- Modify: `apps/server/src/runner.lua` (a `windows` mode; the merge takes a windows file)
- Modify: `apps/server/src/lua.ts` (`runWindows`; `runMerge` takes windows)
- Test: `apps/server/test/lua.test.ts`

**Interfaces:**
- Consumes: `Merge.Windows`, `Merge.Strip` (Task 1).
- Produces: `type Window = [number, number]`. `runWindows(old: Uint8Array, kept: Uint8Array, limits?: Limits): Promise<Window[]>` (both are stored journeys, Parse.Write text). `runMerge(upload, current, pc, windows: Window[] = [], limits?, runner?)`. The runner's command line becomes `lua5.1 runner.lua <lua dir> merge <upload> <current or ""> <out> <pc> <windows file or ""> <max MB> <max seconds>` or `lua5.1 runner.lua <lua dir> windows <old> <kept> <max MB> <max seconds>`, which prints `windows <from> <to> <from> <to> ...` or `failed <why>`.

- [ ] **Step 1: Write the failing tests**

Append to `apps/server/test/lua.test.ts` (import `runWindows` from `../src/lua`):

```ts
test("the windows of a restore are the sessions the old journey has and the kept one doesn't", async () => {
  const old = text(journey({ events: [...session(1000), ...session(5000)] }));
  const kept = text(journey({ events: session(1000) }));
  expect(await runWindows(old, kept)).toEqual([[5000, 5120]]);
});

test("an upload is merged without the play inside the windows it is given", async () => {
  const current = text(journey({ events: session(1000) }));
  const upload = savedFile(journey({ events: [...session(1000), ...session(5000), ...session(9000)] }));
  const r = await runMerge(upload, current, "pc-2", [[5000, 5120]]);
  if (!r.ok) throw new Error(r.reason);
  const out = new TextDecoder().decode(r.journey);
  expect(sessions(out)).toBe(2);
  expect(out).not.toContain("5000");
});

test("a layout 2 upload's counts become its PC's tallies before the cap, so they stay", async () => {
  const current = text(journey({ events: session(1000), people: { "Player-1-0001": { name: "Ann", groups: { "pc-1": 1 } } } }));
  const upload = savedFile(journey({ version: 2, events: [...session(1000), ...session(5000)], people: { "Player-1-0001": { name: "Ann", groups: 3 } } }));
  const r = await runMerge(upload, current, "pc-2", [[5000, 5120]]);
  if (!r.ok) throw new Error(r.reason);
  expect(new TextDecoder().decode(r.journey)).toContain('["pc-2"]=3');
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && bun test test/lua.test.ts`
Expected: FAIL, `runWindows` is not exported.

- [ ] **Step 3: Change the runner**

In `apps/server/src/runner.lua`:

1. Header: replace the command line and its description with both modes:

```lua
--   lua5.1 runner.lua <lua dir> merge <upload> <current or ""> <out> <pc> <windows or ""> <max MB> <max seconds>
--   lua5.1 runner.lua <lua dir> windows <old> <kept> <max MB> <max seconds>
--
-- merge: <upload> is the SavedVariables file a PC uploaded, <current> the
-- character's merged journey as Parse.Write text (none for a first
-- upload), <pc> the uploading device's ID, <windows> a file of "from to"
-- lines: stretches of time a restore took out, stripped from the upload
-- before it is merged (Merge.Strip). Writes the result to <out> and prints
-- one line, - for anything unknown:
--   ok <layout uploaded> <layout> <level> <played> <last seen> <class>
--   rejected <layout uploaded> <reason>
--   failed <why>        the server's fault; lua.ts throws and the job is tried again
-- windows: <old> and <kept> are stored journeys; prints the sessions a
-- restore from old to kept takes out (Merge.Windows):
--   windows <from> <to> <from> <to> ...
```

2. Argument reading: replace `local dir, uploadPath, currentPath, outPath, pc, maxMB, maxSeconds = ...` with:

```lua
local args = { ... }
local dir, mode = args[1], args[2]
local uploadPath, currentPath, outPath, pc, windowsPath, maxMB, maxSeconds
local oldPath, keptPath
if mode == "windows" then
    oldPath, keptPath, maxMB, maxSeconds = args[3], args[4], args[5], args[6]
else
    uploadPath, currentPath, outPath, pc, windowsPath, maxMB, maxSeconds = args[3], args[4], args[5], args[6], args[7], args[8], args[9]
end
```

3. In `Run`, read the current journey before stripping, and strip the upload after `Prepare` and before `TidyUp`, so the merge and `Merge.Check` both see the stripped upload. The body from `upload, why = ns.Merge.Prepare(upload, pc)` to the `Merge.Check` call becomes:

```lua
    upload, why = ns.Merge.Prepare(upload, pc)
    if not upload then error(why, 0) end
    local current
    if currentPath ~= "" then
        -- Saved by an older server when the layout has moved on since. Its
        -- counts are every PC's, so none is named as theirs.
        local read, bad
        read, current = Try(ns.Parse.Read, Read(currentPath))
        if read then current, bad = ns.Merge.Prepare(current, "server") else current, bad = nil, current end
        if not current then Fault("the stored journey can't be merged: " .. tostring(bad)) end
    end
    if windowsPath ~= "" then
        local windows = {}
        for from, to in Read(windowsPath):gmatch("(%-?%d+) (%-?%d+)") do
            windows[#windows + 1] = { tonumber(from), tonumber(to) }
        end
        ns.Merge.Strip(upload, windows, current or {})
    end
    TidyUp(upload)
    local out = upload
    if current then
        TidyUp(current)
        out, why = ns.Merge.Merge(current, upload)
        if not out then error(why, 0) end
        local passed, failed = ns.Merge.Check(current, upload, out)
        -- Check fails only when the merge lost something: a bug in the
        -- merge, not in the upload, so a fixed server tries it again.
        if not passed then Fault(failed) end
    end
```

(Keep the existing lines after this unchanged: writing `out`, the level and last-seen scan, the `ok` line.)

4. At the bottom, run the windows mode instead of `Run` when asked. Replace `local ok, result = pcall(Run)` with:

```lua
local function Windows()
    local function Stored(path)
        local read, journey = Try(ns.Parse.Read, Read(path))
        if not read then Fault("a stored journey can't be read: " .. tostring(journey)) end
        local prepared, why = ns.Merge.Prepare(journey, "server")
        if not prepared then Fault("a stored journey can't be used: " .. tostring(why)) end
        return prepared
    end
    local parts = {}
    for _, w in ipairs(ns.Merge.Windows(Stored(oldPath), Stored(keptPath))) do
        parts[#parts + 1] = w[1] .. " " .. w[2]
    end
    return ("windows %s"):format(table.concat(parts, " "))
end

local ok, result = pcall(mode == "windows" and Windows or Run)
```

- [ ] **Step 4: Change lua.ts**

In `apps/server/src/lua.ts`:

```ts
// A stretch of time a restore took out: [from, to] in Unix seconds.
export type Window = [number, number];
```

`runMerge` gains `windows: Window[] = []` after `pc`; it writes them to `windows.txt` in its folder when there are any and passes `merge` before the paths:

```ts
    const windowsPath = join(dir, "windows.txt");
    if (windows.length > 0) await Bun.write(windowsPath, windows.map(([from, to]) => `${from} ${to}`).join("\n"));
    const args = ["merge", uploadPath, current ? currentPath : "", outPath, pc, windows.length > 0 ? windowsPath : "", String(limits.mb), String(limits.seconds)];
```

Add, sharing the process handling: move the spawn, the signal check and the stdout read into a helper `run(args: string[], limits: Limits, runner: string): Promise<{ stdout: string; stderr: string; exitCode: number | null }>` used by both, then:

```ts
// The sessions a restore from old to kept takes out (Merge.Windows), both
// stored journeys. Run under the same limits as a merge.
export async function runWindows(old: Uint8Array, kept: Uint8Array, limits: Limits = LIMITS, runner = `${import.meta.dir}/runner.lua`): Promise<Window[]> {
  const dir = await mkdtemp(join(tmpdir(), "rts-windows-"));
  try {
    await Bun.write(join(dir, "old.lua"), old);
    await Bun.write(join(dir, "kept.lua"), kept);
    const { stdout, stderr, exitCode } = await run(["windows", join(dir, "old.lua"), join(dir, "kept.lua"), String(limits.mb), String(limits.seconds)], limits, runner);
    const [word, ...rest] = (stdout.trim().split("\n").pop() ?? "").split(" ");
    if (word !== "windows") throw new Error(`the restore's sessions couldn't be worked out: ${(word === "failed" ? rest.join(" ") : stderr.trim().split("\n")[0]) || `exit code ${exitCode}`}`);
    const n = rest.filter((s) => s !== "").map(Number);
    const out: Window[] = [];
    for (let i = 0; i + 1 < n.length; i += 2) out.push([n[i]!, n[i + 1]!]);
    return out;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
```

Update every existing `runMerge(…, limits, runner)` call in `test/lua.test.ts` that passes limits to pass `[]` for windows first.

- [ ] **Step 5: Run the tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add apps/server
git commit -m "Server: the merge runner works out a restore's sessions and strips them from a stale upload (#40)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Restores keep their windows; stale uploads are merged without them

**Files:**
- Modify: `apps/server/src/schema.ts` (`versions.removed`)
- Create: `apps/server/drizzle/0004_*.sql` and its snapshot (generated)
- Modify: `apps/server/src/account.ts` (the restore route works out and stores the windows)
- Modify: `apps/server/src/worker.ts` (no more setting aside; pass the windows)
- Test: `apps/server/test/account.test.ts`, `apps/server/test/sync.test.ts`
- Modify: `apps/server/AGENTS.md`, `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`

**Interfaces:**
- Consumes: `runWindows`, `runMerge(…, windows)`, `Window` (Task 2).
- Produces: `versions.removed: string | null` (JSON `[[from, to], …]`, on restore rows).

- [ ] **Step 1: Write the failing tests**

In `apps/server/test/account.test.ts`, replace the test "an upload waiting to be merged when a restore is picked is set aside, not merged on top" with:

```ts
test("an upload waiting when a restore is picked keeps its new play, but not what the restore took out", async () => {
  const { desk, c, older } = await twoVersions();
  await upload(desk.token, savedFile(journey({ events: [...session(1000), ...session(5000), ...session(9000)] })));
  await json<RestoreResponse>(restore(desk.token, c.id, older.id));
  await workAll();
  const [entry] = (await check(desk.token)).characters;
  const text = new TextDecoder().decode(unpack(new Uint8Array(await (await call(desk.token, `/v1/versions/${entry!.version}`)).arrayBuffer())));
  expect(text).toContain("9000");
  expect(text).not.toContain("5000");
});

test("a restore keeps the sessions it took out", async () => {
  const { desk, c, older } = await twoVersions();
  const { version } = await json<RestoreResponse>(restore(desk.token, c.id, older.id));
  const [row] = await db.select().from(versions).where(eq(versions.id, version));
  expect(JSON.parse(row!.removed!)).toEqual([[5000, 5120]]);
});
```

(Import `unpack` from `../src/storage`.)

In `apps/server/test/sync.test.ts`, replace "an upload from a PC that never received anything is set aside once there is a restore" with:

```ts
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
```

In "a restore is delivered as a replace, and an upload made before it arrived doesn't undo it", the upload made with `received: merged.version` now merges minus the removed session instead of being superseded: replace its `superseded` assertions and `expect((await check(token)).characters[0]!.version).toBe(restore!.id)` with: the head's text (downloaded as above) holds `5000` and no `3000` (the session the restore took out), and `expect((await check(token)).characters[0]!.restore).toBe(restore!.id)`, since this PC still hasn't shown it took the restore in.

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/server && bun test test/account.test.ts test/sync.test.ts`
Expected: FAIL: `versions.removed` doesn't exist (a type error under `bun run typecheck`, `undefined` at runtime), and the stale uploads are set aside so 9000 and 30000 are missing.

- [ ] **Step 3: Add the column**

`apps/server/src/schema.ts`, in `versions` after `level`:

```ts
  // On a restore: the stretches of time it took out, JSON [[from, to], ...],
  // stripped from any upload made before the restore reached its PC.
  removed: text("removed"),
```

Run: `cd apps/server && bun run db:generate --name restore_removed`
Expected: `drizzle/0004_restore_removed.sql` with `ALTER TABLE "versions" ADD COLUMN "removed" text;`.

- [ ] **Step 4: The restore route stores its windows**

In `apps/server/src/account.ts` (import `runWindows` from `./lua`), in the restore route after the 400 check and before the transaction:

```ts
    // Worked out before anything is written: a fault here answers 500 and
    // leaves the journey as it was.
    const [current] = await db.select().from(versions).where(eq(versions.id, c.headVersionId!));
    const removed = await runWindows(await get(c.userId, current!.fingerprint), await get(c.userId, source.fingerprint));
```

and in the restore's `.values({ ... })` add `removed: JSON.stringify(removed),`.

- [ ] **Step 5: The worker merges stale uploads without what restores took out**

In `apps/server/src/worker.ts`, replace the block from the comment "An upload from a PC that hadn't yet applied the latest restore" to the `settle(... "superseded" ...)` return with:

```ts
  // An upload from a PC that hadn't yet taken in the latest restore (or
  // never received anything, like a copied WTF folder) may still hold what
  // restores took out. It is merged without the play inside their windows,
  // so the restore holds and the PC's own new play is kept.
  const restores = await db
    .select({ id: versions.id, removed: versions.removed })
    .from(versions)
    .where(and(eq(versions.characterId, character.id), eq(versions.kind, "restore")))
    .orderBy(desc(versions.id));
  const stale = restores.length > 0 && (upload.receivedId ?? 0) < restores[0]!.id;
  const windows: Window[] = stale ? restores.flatMap((r) => (r.removed ? (JSON.parse(r.removed) as Window[]) : [])) : [];
```

and pass `windows` as the fourth argument of `runMerge`. Import `type Window` from `./lua`.

- [ ] **Step 6: Run the tests and types**

Run: `cd apps/server && bun test && bun run typecheck`
Expected: all pass.

- [ ] **Step 7: Docs and commit**

`apps/server/AGENTS.md`, under "Rules that bite", add: "An upload made before the latest restore reached its PC is merged without the play inside every restore's windows (`versions.removed`, worked out by the restore route with `runWindows`). Nothing is set aside any more."

Spec, "Restore": replace "An upload made before the restore reached its PC is set aside, not merged on top." with: "The restore keeps the stretches of time it took out (the sessions the old journey had and the restored one doesn't). An upload made before the restore reached its PC, or from a PC that never received anything, is merged without its play inside those stretches, so the restore holds and the PC's own new play is kept (#40). Counts that carry no times (per-PC tallies) under a PC the journey knows are held to the journey's; recipes, mounts and people first noted during a removed session may come back."

```bash
git add apps/server docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
git commit -m "Server: a stale upload after a restore is merged without what the restore took out, not set aside (#40)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

After the final review: merge `restore-dedupe` into `dev`, push, watch CI and the deploy (migration `0004` runs at start), and comment on #40.
