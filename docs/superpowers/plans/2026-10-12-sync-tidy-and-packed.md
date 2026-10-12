# Sync step 2a: Tidy.lua and Packed.lua Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the login tidy-ups and the packed kill and path formats out of the game modules into two plain Lua files that the addon, the coming `Merge.lua` and the sync server can all run.

**Architecture:** A pure refactor. `Packed.lua` holds kill decoding, kill packing and path decoding. `Tidy.lua` holds the three login repairs (`TidyRuns`, `TidyEvents`, `Guilds:Tidy`) as functions that take the journey as an argument. Neither file calls the game: the continent check reaches `Tidy.Events` as a function argument. Journal.lua, Recorder.lua and Guilds.lua call the new files instead of their own copies. A new test loads both files with nothing but the standard Lua library to prove they are pure. Behaviour in game does not change.

**Tech Stack:** WoW addon Lua (5.1), offline tests under LuaJIT 2.1.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`, sections "The addon / New files" and "Rules for writing Merge.lua, Parse.lua and Tidy.lua". This is the first of four plans for build order step 2: this one, then `Parse.lua`, then layout 3 (per-PC tallies), then `Merge.lua`.

## Global Constraints

- Work on a branch cut from `sync-design` (the spec lives there): `git switch -c sync-tidy sync-design`, then `git branch --unset-upstream` if one was set.
- `Tidy.lua` and `Packed.lua` use standard Lua 5.1 only: no WoW globals (`wipe`, `strsplit`, `tinsert`, `CopyTable`, `C_Map`), no LuaJIT extras, never depend on `pairs` order, never use `#` on tables with holes.
- Each file starts with `local _, ns = ...` and puts its table on `ns`, like every other module, so the server can load it with `loadfile(path)("RoadToSixty", ns)`.
- No change to what the addon saves or shows. Existing tests must pass with only their load lines and call sites changed.
- No new top-level locals in Map.lua.
- Comments are plain sentences that explain why; British spelling.
- Commit subjects `Area: what changed (#1)`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- On this Mac, `check.ps1` can't run (no PowerShell). Use:
  - syntax: `for f in RoadToSixty/*.lua; do luajit -b "$f" /dev/null || echo "SYNTAX $f"; done`
  - tests: `for t in tests/*_test.lua; do luajit "$t" || echo "FAILED $t"; done`
  - load test: `luajit tests/release_load.lua RoadToSixty`

## Review Focus

- A kill list across the switch to the realm's clock can hold a negative gap. `Packed.DecodeKills` must read `-5` and `Packed.PackKills` must write it. Task 1's test packs and decodes a list whose times go backwards.
- A decoded kill whose name index has no entry in `names` comes back with `name = nil`. `Packed.PackKills` must pack it under the name `"?"` instead of erroring on a nil table key. Task 1's test covers it.
- An empty kill list must pack to exactly the defaults, `{ d = "", last = 0, names = {} }`, so a merged character with no kills looks like a new one. Task 1's test covers it.
- A roster copy of a journey may have no `totals`, and a character may have `guild = false` (in no guild). `Tidy.Events` and `Tidy.Guilds` must leave such journeys alone without erroring. Tasks 2 and 3 test both.
- Journal.lua reads `ns.Tidy.RUN_GAP` when it loads, so `Tidy.lua` must come before it in the toc and in every test that loads Journal.lua. Task 2 puts it there, and `release_load.lua` loads the toc in order.

---

### Task 1: Packed.lua, the kill and path formats as plain functions

**Files:**
- Create: `RoadToSixty/Packed.lua`
- Create: `tests/packed_test.lua`, `tests/pure_test.lua`
- Modify: `RoadToSixty/RoadToSixty.toc` (add `Packed.lua` after `Core.lua`)
- Modify: `RoadToSixty/Journal.lua` (`Journal:Kills`, the two `gmatch` loops)
- Modify: `RoadToSixty/Recorder.lua` (local `Decode`)
- Modify tests that load Journal.lua or Recorder.lua: `tests/journal_test.lua`, `tests/played_test.lua`, `tests/runs_test.lua`, `tests/recorder_test.lua`

**Interfaces:**
- Produces:
  - `ns.Packed.DecodeKills(d, names, t, list) -> t`: appends each kill in the packed string `d` to `list` as `{ t = time, xp = number, name = names[n] }`, starting from time `t`, and returns the time of the last kill (or `t` if there were none).
  - `ns.Packed.PackKills(list) -> kills`: `list` is `{ { t, xp, name }, ... }` oldest first (named fields `t`, `xp`, `name`); returns a new `{ d = string, last = number, names = { string, ... } }`. A nil name packs as `"?"`.
  - `ns.Packed.DecodePath(seg, d) -> ts, xs, ys`: the points of a segment `{ t, x, y }` plus its packed steps `d` (defaults to `seg.d`), as three lists.

- [ ] **Step 1: Write the failing behaviour test**

Create `tests/packed_test.lua`:

```lua
-- Offline test of Packed.lua, the packed kill and path formats. Run with
-- LuaJIT from the repo root: luajit tests/packed_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Packed.lua"))("RoadToSixty", ns)
local Packed = ns.Packed

local function Times(list)
    local out = {}
    for i, k in ipairs(list) do out[i] = k.t .. ":" .. k.xp .. ":" .. tostring(k.name) end
    return table.concat(out, " ")
end

-- 1. Packing then decoding gives the same kills back, names shared.
local kills = {
    { t = 1000, xp = 40, name = "Kobold" },
    { t = 1012, xp = 40, name = "Kobold" },
    { t = 1012, xp = 55, name = "Hogger" },
}
local packed = Packed.PackKills(kills)
check(packed.d == "1000,40,1;12,40,1;0,55,2;", "packed string: " .. packed.d)
check(packed.last == 1012, "last is the time of the last kill, got " .. packed.last)
check(#packed.names == 2 and packed.names[1] == "Kobold" and packed.names[2] == "Hogger", "names listed once each")
local decoded = {}
local last = Packed.DecodeKills(packed.d, packed.names, 0, decoded)
check(Times(decoded) == "1000:40:Kobold 1012:40:Kobold 1012:55:Hogger", "decoded: " .. Times(decoded))
check(last == 1012, "DecodeKills returns the last time, got " .. last)

-- 2. Times that go backwards (the switch to the realm's clock) survive.
packed = Packed.PackKills({ { t = 2000, xp = 1, name = "A" }, { t = 1995, xp = 2, name = "A" } })
check(packed.d == "2000,1,1;-5,2,1;", "negative gap packed: " .. packed.d)
decoded = {}
Packed.DecodeKills(packed.d, packed.names, 0, decoded)
check(Times(decoded) == "2000:1:A 1995:2:A", "negative gap decoded: " .. Times(decoded))

-- 3. Decoding continues from a given time and appends to the list.
decoded = { { t = 1, xp = 0, name = "x" } }
last = Packed.DecodeKills("5,10,1;", { "Wolf" }, 100, decoded)
check(#decoded == 2 and decoded[2].t == 105 and decoded[2].name == "Wolf" and last == 105, "appends after t")
check(Packed.DecodeKills("", {}, 77, {}) == 77, "nothing to decode keeps t")

-- 4. A kill whose name was lost packs as "?".
packed = Packed.PackKills({ { t = 10, xp = 3, name = nil } })
check(packed.d == "10,3,1;" and packed.names[1] == "?", "a nameless kill packs as ?")

-- 5. No kills packs to the defaults a new character starts with.
packed = Packed.PackKills({})
check(packed.d == "" and packed.last == 0 and #packed.names == 0, "empty list packs to the defaults")

-- 6. A path segment decodes to its points, including negative steps.
local ts, xs, ys = Packed.DecodePath({ t = 100, x = 10, y = 20, d = "1,5,-5;2,-15,0" })
check(table.concat(ts, ",") == "100,101,103", "path times: " .. table.concat(ts, ","))
check(table.concat(xs, ",") == "10,15,0", "path x: " .. table.concat(xs, ","))
check(table.concat(ys, ",") == "20,15,15", "path y: " .. table.concat(ys, ","))
ts = Packed.DecodePath({ t = 5, x = 0, y = 0, d = "" })
check(#ts == 1, "a segment with only its start point")
ts = Packed.DecodePath({ t = 5, x = 0, y = 0, d = "" }, "3,1,1")
check(#ts == 2 and ts[2] == 8, "steps passed in place of seg.d")

if failures == 0 then
    print("Packed tests passed.")
else
    print(failures .. " packed test(s) failed.")
    os.exit(1)
end
```

- [ ] **Step 2: Write the failing purity test**

Create `tests/pure_test.lua`:

```lua
-- The files the sync server runs must work with nothing but standard Lua
-- 5.1: no game API. This loads each one in an environment holding only the
-- standard library, then calls what it defines, so a game call anywhere in
-- them fails here. Run with LuaJIT from the repo root: luajit tests/pure_test.lua

local STANDARD = {
    "assert", "error", "ipairs", "next", "pairs", "pcall", "select", "setmetatable",
    "getmetatable", "tonumber", "tostring", "type", "unpack", "string", "table", "math",
}

local function Load(name, ns)
    local env = {}
    for _, key in ipairs(STANDARD) do env[key] = _G[key] end
    local chunk = assert(loadfile("RoadToSixty/" .. name))
    setfenv(chunk, env)
    chunk("RoadToSixty", ns)
end

local ns = {}
Load("Packed.lua", ns)

local packed = ns.Packed.PackKills({ { t = 1, xp = 2, name = "A" } })
local list = {}
ns.Packed.DecodeKills(packed.d, packed.names, 0, list)
assert(list[1].name == "A")
assert(#ns.Packed.DecodePath({ t = 1, x = 0, y = 0, d = "1,1,1" }) == 2)

print("Pure tests passed.")
```

- [ ] **Step 3: Run both to make sure they fail**

Run: `luajit tests/packed_test.lua; luajit tests/pure_test.lua`
Expected: both stop with `cannot open RoadToSixty/Packed.lua`.

- [ ] **Step 4: Create Packed.lua**

```lua
local _, ns = ...

-- The packed formats the journey is saved in, as plain functions with no
-- game calls, so the recorder, the journal, the merge and the sync server
-- read and write them the same way.
--
-- Kills: { d = "dt,xp,n;...", last = time of the last kill, names = { mob
-- name, ... } }. dt is seconds since the kill before, the first kill's dt
-- is its full time, and n indexes names. dt can be negative: kills saved
-- just before and after the switch to the realm's clock (#35) can step back.
--
-- Path segments: { t, x, y, d = "dt,dx,dy;..." }, each step a difference
-- from the point before. Recorder.lua's header has the whole segment.

local Packed = {}
ns.Packed = Packed

-- Appends each kill packed in d to list as { t, xp, name }, counting from
-- time t, and returns the time of the last one.
function Packed.DecodeKills(d, names, t, list)
    for dt, xp, n in d:gmatch("(-?%d+),(%d+),(%d+);") do
        t = t + tonumber(dt)
        list[#list + 1] = { t = t, xp = tonumber(xp), name = names[tonumber(n)] }
    end
    return t
end

-- A new kills table holding list ({ t, xp, name }, oldest first). A kill
-- whose name was lost packs as "?", since a name can't be a nil key.
function Packed.PackKills(list)
    local names, index, parts, last = {}, {}, {}, 0
    for i, kill in ipairs(list) do
        local name = kill.name or "?"
        local n = index[name]
        if not n then
            n = #names + 1
            names[n], index[name] = name, n
        end
        parts[i] = ("%d,%d,%d;"):format(kill.t - last, kill.xp, n)
        last = kill.t
    end
    return { d = table.concat(parts), last = last, names = names }
end

-- The points of a segment as three lists: times, x and y. d is its packed
-- steps, seg.d unless given (the recorder passes the open segment's buffer).
function Packed.DecodePath(seg, d)
    local t, x, y = seg.t, seg.x, seg.y
    local ts, xs, ys = { t }, { x }, { y }
    for dt, dx, dy in (d or seg.d or ""):gmatch("(-?%d+),(-?%d+),(-?%d+)") do
        t, x, y = t + tonumber(dt), x + tonumber(dx), y + tonumber(dy)
        ts[#ts + 1], xs[#xs + 1], ys[#ys + 1] = t, x, y
    end
    return ts, xs, ys
end
```

- [ ] **Step 5: Run both tests to make sure they pass**

Run: `luajit tests/packed_test.lua; luajit tests/pure_test.lua`
Expected: `Packed tests passed.` and `Pure tests passed.`

- [ ] **Step 6: Use Packed.lua from Journal.lua and Recorder.lua**

Add `Packed.lua` to `RoadToSixty/RoadToSixty.toc` on the line after `Core.lua`.

In `RoadToSixty/Journal.lua`, `Journal:Kills`, replace the first decoding loop:

```lua
        for dt, xp, n in kills.d:sub(cache.length + 1):gmatch("(-?%d+),(%d+),(%d+);") do
            t = t + tonumber(dt)
            saved[#saved + 1] = { t = t, xp = tonumber(xp), name = kills.names[tonumber(n)] }
        end
```

with:

```lua
        t = ns.Packed.DecodeKills(kills.d:sub(cache.length + 1), kills.names, t, saved)
```

and the second, for the buffered kills:

```lua
    for dt, xp, n in table.concat(killBuffer):gmatch("(-?%d+),(%d+),(%d+);") do
        t = t + tonumber(dt)
        list[#list + 1] = { t = t, xp = tonumber(xp), name = kills.names[tonumber(n)] }
    end
```

with:

```lua
    ns.Packed.DecodeKills(table.concat(killBuffer), kills.names, t, list)
```

In `RoadToSixty/Recorder.lua`, the local `Decode` keeps its legacy rule and leaves the decoding to `Packed`:

```lua
local function Decode(seg, d)
    local ts, xs, ys = ns.Packed.DecodePath(seg, d)
    -- Up to 1.5.0 a death inside an instance was saved as leaving it; a
    -- ghost's segment after an instance is that death.
    local j = seg.j
    if j == "i" and seg.m == "g" then
        j = "di"
    end
    return { m = seg.m, c = seg.c, j = j, t = ts, x = xs, y = ys }
end
```

- [ ] **Step 7: Run the tests and watch the ones that load these modules break**

Run: `for t in tests/*_test.lua; do luajit "$t" >/dev/null 2>&1 || echo "FAILED $t"; done`
Expected: `FAILED` for journal_test, played_test, runs_test and recorder_test, each with `attempt to index field 'Packed' (a nil value)` when run alone.

- [ ] **Step 8: Load Packed.lua in those tests**

Each of these tests loads modules with `assert(loadfile("RoadToSixty/X.lua"))("RoadToSixty", ns)`. Add Packed.lua before the first such line:

```bash
for t in journal_test played_test runs_test recorder_test; do
  perl -0pi -e 's/(assert\(loadfile\("RoadToSixty\/)/assert(loadfile("RoadToSixty\/Packed.lua"))("RoadToSixty", ns)\n$1/' "tests/$t.lua"
done
grep -n 'Packed.lua' tests/*_test.lua
```

Expected from the grep: one line in each of the four tests, plus the lines in `packed_test.lua` and `pure_test.lua`. The `-0` makes perl replace only the first load line in each file.

- [ ] **Step 9: Run every check**

Run:
```bash
for f in RoadToSixty/*.lua; do luajit -b "$f" /dev/null || echo "SYNTAX $f"; done
for t in tests/*_test.lua; do luajit "$t" || echo "FAILED $t"; done
luajit tests/release_load.lua RoadToSixty
```
Expected: no `SYNTAX` or `FAILED` lines, every test prints its "passed" line, and `Release load test passed: 43 files loaded from RoadToSixty.` (one more file than before).

- [ ] **Step 10: Commit**

```bash
git add RoadToSixty/Packed.lua RoadToSixty/RoadToSixty.toc RoadToSixty/Journal.lua RoadToSixty/Recorder.lua tests/
git commit -m "Packed: kill and path formats as plain functions for the merge (#1)

Journal and Recorder decoded the packed kills and path in their own code.
The merge and the sync server need the same decoding plus packing, so it
moves to Packed.lua, which calls nothing from the game.
tests/pure_test.lua loads it with only the standard library.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Tidy.lua, the run and event repairs

**Files:**
- Create: `RoadToSixty/Tidy.lua`
- Modify: `RoadToSixty/RoadToSixty.toc` (add `Tidy.lua` after `Packed.lua`)
- Modify: `RoadToSixty/Journal.lua` (remove `MergeParty`, `Journal:TidyRuns`, `Journal:TidyEvents`; `RUN_GAP`; the `PLAYER_LOGIN` handler's tidy calls)
- Modify: `tests/runs_test.lua` (calls and load line), `tests/pure_test.lua`, `tests/journal_test.lua`, `tests/played_test.lua` (load line)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `ns.Tidy.RUN_GAP`: `30 * 60`, seconds between leaving an instance and going back in that still count as one run.
  - `ns.Tidy.Runs(char)`: Journal's `TidyRuns`, working on `char` (its `events`, `run`, `instance`, `totals`) instead of `ns.char`.
  - `ns.Tidy.Events(journey, isPlace)`: Journal's `TidyEvents`; `isPlace(mapID)` returns true for a zone, city or dungeon and false for a continent or the world.

- [ ] **Step 1: Point the existing run tests at the new functions**

`tests/runs_test.lua` already pins the behaviour. Change its calls so it tests `Tidy`:

```bash
perl -pi -e 's/^Journal:TidyRuns\(\)$/ns.Tidy.Runs(ns.char)/; s/^Journal:TidyEvents\(ns\.char\)$/ns.Tidy.Events(ns.char, ns.IsPlaceMap)/' tests/runs_test.lua
grep -n "Tidy" tests/runs_test.lua
```

Expected: three `ns.Tidy.Runs(ns.char)` lines and one `ns.Tidy.Events(ns.char, ns.IsPlaceMap)`.

Then add two cases before the `if failures > 0` line at the end:

```lua
-- A roster copy may have no totals; tidying it still works.
local copy = { events = { { 5, "die", 0, 0, 0 }, { 5, "die", 0, 0, 0 } } }
ns.Tidy.Events(copy, ns.IsPlaceMap)
check(#copy.events == 1, "a journey without totals is tidied too")

-- The continent check comes from the caller, as the server has no map API.
local journey = { events = { { 1, "zone", 0, 0, 0, 7 }, { 2, "zone", 0, 0, 0, 8 } }, totals = { deaths = 0 } }
ns.Tidy.Events(journey, function(mapID) return mapID == 8 end)
check(#journey.events == 1 and journey.events[1][6] == 8, "isPlace decides which zones stay")
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `luajit tests/runs_test.lua`
Expected: an error `attempt to index field 'Tidy' (a nil value)` at the first `ns.Tidy.Runs` line.

- [ ] **Step 3: Create Tidy.lua with the run and event repairs**

```lua
local _, ns = ...

-- Repairs to saved journeys that the addon makes at every login, as plain
-- functions of the data with no game calls, so the merge and the sync
-- server tidy both copies of a journey exactly as a login would before
-- merging them. Each changes the journey it is given in place.

local Tidy = {}
ns.Tidy = Tidy

-- Seconds between leaving an instance and going back in that still count
-- as one run.
Tidy.RUN_GAP = 30 * 60

-- Everyone in either list of guids, once each, in order; nil if no one.
local function MergeParty(a, b)
    local seen, list = {}, {}
    for _, party in ipairs({ a or {}, b or {} }) do
        for _, guid in ipairs(party) do
            if not seen[guid] then
                seen[guid] = true
                list[#list + 1] = guid
            end
        end
    end
    return #list > 0 and list or nil
end

-- Joins runs that earlier versions split in two when the character died
-- and ran back in: an "out" followed within RUN_GAP by an "in" to the same
-- instance, with no other instance and no group starting or ending
-- between, becomes one run.
function Tidy.Runs(char)
    local events = char.events
    local i = 1
    while i <= #events do
        local out = events[i]
        local back = events[i + 1]
        local k = i + 1
        local regrouped = false
        while back and back[2] ~= "in" and back[2] ~= "out" do
            regrouped = regrouped or back[2] == "grp" or back[2] == "grpx"
            k = k + 1
            back = events[k]
        end
        if out[2] == "out" and not regrouped and back and back[2] == "in" and back[6] == out[6]
            and back[1] - out[1] < Tidy.RUN_GAP and type(out[7]) == "table" then
            local first = out[7]
            -- Where the second part's summary goes: its own "out", or the
            -- run still going on.
            local j = k + 1
            while events[j] and events[j][2] ~= "out" and events[j][2] ~= "in" do
                j = j + 1
            end
            local second = events[j]
            local merged = true
            if second and second[2] == "out" and second[6] == out[6] and type(second[7]) == "table" then
                local s = second[7]
                s.duration = s.duration + first.duration + (back[1] - out[1])
                s.kills, s.xp, s.deaths = s.kills + first.kills, s.xp + first.xp, s.deaths + first.deaths
                s.money, s.levels = s.money + first.money, s.levels + first.levels
                for n, link in ipairs(first.items) do
                    table.insert(s.items, n, link)
                end
                s.party = MergeParty(first.party, s.party)
            elseif not second and char.run and char.instance == out[6] then
                local run = char.run
                run.t = run.t - first.duration - (back[1] - out[1])
                run.kills, run.xp, run.deaths = run.kills - first.kills, run.xp - first.xp, run.deaths - first.deaths
                run.money, run.level = run.money - first.money, run.level - first.levels
                for n, link in ipairs(first.items) do
                    table.insert(run.items, n, link)
                end
                run.party = run.party or {}
                for _, guid in ipairs(first.party or {}) do
                    run.party[guid] = true
                end
            else
                merged = false
            end
            if merged then
                table.remove(events, k)
                table.remove(events, i)
                char.totals.instances = math.max(0, char.totals.instances - 1)
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

-- Takes out events that versions up to 1.5.0 saved wrongly, from a journey
-- (a character's, or a roster copy): "zone" events for a continent, and a
-- death logged a second time in the same second (the client fired
-- PLAYER_DEAD twice), which the totals counted too. isPlace(mapID) says
-- whether a map is a place rather than a continent: ns.IsPlaceMap in game,
-- a table from the map data on the server.
function Tidy.Events(journey, isPlace)
    local events, kept, lastDeath = journey.events or {}, 0, nil
    local doubled = 0
    for i = 1, #events do
        local e = events[i]
        local keep = true
        if e[2] == "zone" then
            keep = isPlace(e[6])
        elseif e[2] == "die" then
            keep = e[1] ~= lastDeath
            doubled = doubled + (keep and 0 or 1)
            lastDeath = e[1]
        end
        if keep then
            kept = kept + 1
            events[kept] = e
        end
    end
    for i = #events, kept + 1, -1 do
        events[i] = nil
    end
    if doubled > 0 and journey.totals then
        journey.totals.deaths = math.max(0, journey.totals.deaths - doubled)
    end
end
```

Add `Tidy.lua` to the toc on the line after `Packed.lua`.

- [ ] **Step 4: Load Tidy.lua in the tests that load Journal.lua**

```bash
for t in journal_test played_test runs_test; do
  perl -0pi -e 's/(assert\(loadfile\("RoadToSixty\/Packed\.lua"\)\)\("RoadToSixty", ns\)\n)/$1assert(loadfile("RoadToSixty\/Tidy.lua"))("RoadToSixty", ns)\n/' "tests/$t.lua"
done
grep -n 'Tidy.lua' tests/*_test.lua
```

Expected: one line in each of the three tests.

- [ ] **Step 5: Run the run tests to make sure they pass**

Run: `luajit tests/runs_test.lua`
Expected: `Runs tests passed.` Journal.lua still has its own copies at this point; the test now exercises `Tidy`.

- [ ] **Step 6: Remove Journal's copies and call Tidy**

In `RoadToSixty/Journal.lua`:

- Delete `local function MergeParty`, `function Journal:TidyRuns` and `function Journal:TidyEvents` with their comments (the block from `-- Everyone in either list of guids` down to the end of `TidyEvents`).
- Change `local RUN_GAP = 30 * 60` to:

```lua
local RUN_GAP = ns.Tidy.RUN_GAP
```

- In the `PLAYER_LOGIN` handler, replace the three tidy calls:

```lua
    if not ns.char.seeded then ns.SafeCall(Journal.TidyRuns, Journal) end
    ns.SafeCall(Journal.TidyEvents, Journal, ns.char)
    for _, e in pairs(ns.db.roster or {}) do
        if e.journey and e.journey.events ~= ns.char.events then
            ns.SafeCall(Journal.TidyEvents, Journal, e.journey)
        end
    end
```

with:

```lua
    if not ns.char.seeded then ns.SafeCall(ns.Tidy.Runs, ns.char) end
    ns.SafeCall(ns.Tidy.Events, ns.char, ns.IsPlaceMap)
    for _, e in pairs(ns.db.roster or {}) do
        if e.journey and e.journey.events ~= ns.char.events then
            ns.SafeCall(ns.Tidy.Events, e.journey, ns.IsPlaceMap)
        end
    end
```

Check nothing else used them: `grep -n "TidyRuns\|TidyEvents\|MergeParty" RoadToSixty/*.lua` should print only lines in `Tidy.lua`'s comments, if any.

- [ ] **Step 7: Add Tidy.lua to the purity test**

In `tests/pure_test.lua`, after `Load("Packed.lua", ns)`, add:

```lua
Load("Tidy.lua", ns)

local char = {
    events = { { 1, "zone", 0, 0, 0, 1415 }, { 2, "die", 0, 0, 0 }, { 2, "die", 0, 0, 0 } },
    totals = { deaths = 2, instances = 0 },
}
ns.Tidy.Runs(char)
ns.Tidy.Events(char, function(mapID) return mapID ~= 1415 end)
assert(#char.events == 1 and char.totals.deaths == 1)
```

- [ ] **Step 8: Run every check**

Run:
```bash
for f in RoadToSixty/*.lua; do luajit -b "$f" /dev/null || echo "SYNTAX $f"; done
for t in tests/*_test.lua; do luajit "$t" || echo "FAILED $t"; done
luajit tests/release_load.lua RoadToSixty
```
Expected: no `SYNTAX` or `FAILED` lines, `Pure tests passed.`, and `Release load test passed: 44 files loaded from RoadToSixty.`

- [ ] **Step 9: Commit**

```bash
git add RoadToSixty/Tidy.lua RoadToSixty/RoadToSixty.toc RoadToSixty/Journal.lua tests/
git commit -m "Tidy: the login repairs of runs and events as plain functions (#1)

The merge has to tidy both copies of a journey the way a login would, or
events a login removed come back and its totals get lowered twice. The
repairs move out of Journal.lua into Tidy.lua and take the journey as an
argument. The continent check is passed in, because the sync server has
no map API.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Tidy.Guilds, the guild repair

**Files:**
- Modify: `RoadToSixty/Tidy.lua` (add `Tidy.TabardComplete`, `Tidy.Guilds`)
- Modify: `RoadToSixty/Guilds.lua` (local `Complete`, remove `Guilds:Tidy`, its call site)
- Create: `tests/tidy_test.lua`
- Modify: `tests/pure_test.lua`

**Interfaces:**
- Consumes: `ns.Tidy` from Task 2.
- Produces:
  - `ns.Tidy.TabardComplete(tabard) -> boolean`: true when the tabard has `bg` and `border`, which drawing it needs.
  - `ns.Tidy.Guilds(char)`: Guilds' `Tidy`, working on `char.events` and `char.guild` instead of `ns.char`.

- [ ] **Step 1: Write the failing test**

Guilds.lua has no test, so this one pins the repair's behaviour. Create `tests/tidy_test.lua`:

```lua
-- Offline test of the guild repair in Tidy.lua. Run with LuaJIT from the
-- repo root: luajit tests/tidy_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Tidy.lua"))("RoadToSixty", ns)
local Tidy = ns.Tidy

local FULL = { bg = { 1, 0, 0 }, border = { 0, 0, 1 }, emblem = 5 }

local function Kinds(events)
    local out = {}
    for i, e in ipairs(events) do out[i] = e[2] .. "@" .. e[1] end
    return table.concat(out, " ")
end

-- 1. A rank change where only the rank number flickered is dropped; a real
-- one stays.
local char = {
    guild = { "Knights", "Member", 3, FULL },
    events = {
        { 100, "gj", 0, 0, 0, "Knights", "Initiate", 4, FULL },
        { 200, "gr", 0, 0, 0, "Knights", "Initiate", 4 },   -- same rank name: a flicker
        { 300, "gr", 0, 0, 0, "Knights", "Member", 3 },     -- a real promotion
        { 400, "gr", 0, 0, 0, "Knights", "Member", 3 },     -- flicker again
    },
}
Tidy.Guilds(char)
check(Kinds(char.events) == "gj@100 gr@300", "flickers dropped, promotion kept: " .. Kinds(char.events))

-- 2. A join saved without the tabard's colours gets the current guild's.
char = {
    guild = { "Knights", "Member", 3, FULL },
    events = { { 100, "gj", 0, 0, 0, "Knights", "Member", 3, { emblem = 5 } } },
}
Tidy.Guilds(char)
check(char.events[1][9] == FULL, "an incomplete tabard on the join is filled from the current guild")

-- 3. An incomplete tabard on the current guild is dropped, so it is read again.
char = { guild = { "Knights", "Member", 3, { emblem = 5 } }, events = {} }
Tidy.Guilds(char)
check(char.guild[4] == nil, "an incomplete current tabard is cleared")

-- 4. In no guild (false) or not read yet (nil): rank flickers still go, nothing errors.
for _, guild in ipairs({ false, "unread" }) do
    char = {
        guild = guild ~= "unread" and guild or nil,
        events = {
            { 100, "gj", 0, 0, 0, "Old", "Member", 3 },
            { 200, "gr", 0, 0, 0, "Old", "Member", 3 },
            { 300, "gl", 0, 0, 0, "Old" },
        },
    }
    Tidy.Guilds(char)
    check(Kinds(char.events) == "gj@100 gl@300", "works with guild = " .. tostring(guild) .. ": " .. Kinds(char.events))
end

check(Tidy.TabardComplete(FULL) == true and Tidy.TabardComplete({ bg = {} }) == false
    and Tidy.TabardComplete(nil) == false, "TabardComplete needs bg and border")

if failures == 0 then
    print("Tidy tests passed.")
else
    print(failures .. " tidy test(s) failed.")
    os.exit(1)
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `luajit tests/tidy_test.lua`
Expected: an error `attempt to call field 'Guilds' (a nil value)` at the first `Tidy.Guilds` call.

- [ ] **Step 3: Add the guild repair to Tidy.lua**

Append to `RoadToSixty/Tidy.lua`:

```lua
-- True if a guild tabard has what drawing it needs (see Guilds:ReadTabard).
function Tidy.TabardComplete(tabard)
    return tabard and tabard.bg and tabard.border and true or false
end

-- Repairs what earlier versions saved wrongly in guild events: rank
-- changes logged when only the rank number flickered (the rank name the
-- same as before), and joins saved with a tabard missing its colours,
-- filled from the current guild's when it has them. char.guild is
-- { name, rank, rankIndex, tabard }, false in no guild, or nil unread.
function Tidy.Guilds(char)
    local events, ranks = char.events, {}
    local known = char.guild
    local Complete = Tidy.TabardComplete
    for i = #events, 1, -1 do
        local e = events[i]
        if e[2] == "gj" and known and e[6] == known[1] and not Complete(e[9]) and Complete(known[4]) then
            e[9] = known[4]
        end
    end
    local i = 1
    while i <= #events do
        local e = events[i]
        if e[2] == "gj" then
            ranks[e[6]] = e[7]
        elseif e[2] == "gr" then
            if ranks[e[6]] == e[7] then
                table.remove(events, i)
                i = i - 1
            else
                ranks[e[6]] = e[7]
            end
        end
        i = i + 1
    end
    if known and not Complete(known[4]) then
        known[4] = nil
    end
end
```

- [ ] **Step 4: Run it to make sure it passes**

Run: `luajit tests/tidy_test.lua`
Expected: `Tidy tests passed.`

- [ ] **Step 5: Remove Guilds' copy and call Tidy**

In `RoadToSixty/Guilds.lua`:

- Replace the local function

```lua
-- True if tabard has what drawing it needs (see ReadTabard).
local function Complete(tabard)
    return tabard and tabard.bg and tabard.border and true or false
end
```

with:

```lua
local Complete = ns.Tidy.TabardComplete
```

- Delete `function Guilds:Tidy()` and its comment (from `-- Repairs what earlier versions saved wrongly` to its closing `end`).
- In the `PLAYER_LOGIN` handler, change `if not ns.char.seeded then Guilds:Tidy() end` to:

```lua
            if not ns.char.seeded then ns.Tidy.Guilds(ns.char) end
```

Check: `grep -n "Guilds:Tidy\|local function Complete" RoadToSixty/*.lua` prints nothing.

- [ ] **Step 6: Add the guild repair to the purity test**

In `tests/pure_test.lua`, after the `ns.Tidy.Events` assertion, add:

```lua
local guilded = { guild = false, events = { { 1, "gj", 0, 0, 0, "G", "M", 1 }, { 2, "gr", 0, 0, 0, "G", "M", 1 } } }
ns.Tidy.Guilds(guilded)
assert(#guilded.events == 1)
```

- [ ] **Step 7: Run every check**

Run:
```bash
for f in RoadToSixty/*.lua; do luajit -b "$f" /dev/null || echo "SYNTAX $f"; done
for t in tests/*_test.lua; do luajit "$t" || echo "FAILED $t"; done
luajit tests/release_load.lua RoadToSixty
```
Expected: no `SYNTAX` or `FAILED` lines, `Tidy tests passed.`, `Pure tests passed.`, and the load test passes with 44 files.

- [ ] **Step 8: Commit**

```bash
git add RoadToSixty/Tidy.lua RoadToSixty/Guilds.lua tests/tidy_test.lua tests/pure_test.lua
git commit -m "Tidy: the guild repair as a plain function (#1)

Guilds:Tidy dropped rank flickers and filled in tabards on ns.char. It
moves to Tidy.Guilds, taking the character as an argument, so the merge
can repair both copies the same way. tests/tidy_test.lua pins it, as
Guilds.lua had no test.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Docs and a check in game

**Files:**
- Modify: `CLAUDE.md` (the Layout table)

- [ ] **Step 1: Add the two files to the Layout table**

In `CLAUDE.md`, add after the `Core.lua` row:

```markdown
| Packed.lua | the packed kill and path formats as plain functions (no game calls) |
| Tidy.lua | the login repairs of saved journeys as plain functions (no game calls); `tests/pure_test.lua` keeps both pure |
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Docs: Packed.lua and Tidy.lua in the layout table (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Ask Jordan for a quick check in game**

With this branch in the dev install, on a character with a real journey: `/reload`, then check that no error appears, `/rts check` reports no errors, the journey map draws the path, kill marks show, and History lists guild and dungeon entries as before. This proves the moved code runs in the client, which the offline tests stub around.
