# Merge.lua Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `RoadToSixty/Merge.lua` merges two copies of one character's journey into one, following the spec's merge rules, so the sync server and the addon can combine play from several PCs.

**Architecture:** One pure Lua 5.1 file. `Merge.Merge(a, b)` builds a new journey field by field: a table of rules says how each top-level field merges, any field without a rule is "current state" taken from the copy seen last, and a final recount rebuilds the totals and level snapshot counts from the merged data. `Merge.Prepare` brings a layout 2 upload up to layout 3, and `Merge.Check` is the server's check of a result. A generic `Join` (everything either copy has) underlies most rules.

**Tech Stack:** Lua 5.1 (WoW, PUC `lua5.1` on the server), LuaJIT for the offline tests.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`, sections "The merge rules", "Counts that can't be recounted" and "Testing".

## Global Constraints

- Three properties hold, and the tests check them: `Merge(a, b)` equals `Merge(b, a)`; `Merge(a, a)` equals `a`; `Merge(Merge(a, b), c)` equals `Merge(a, Merge(b, c))` (spec). "Equals a" is exact for any merge result, and for a raw copy up to event order and whole yards (see below).
- The rules for the pure files: no WoW globals, no LuaJIT extras, never depend on the order `pairs` returns (sort keys where order matters), never use `#` on tables with holes. `table.sort` is not stable, so every comparator breaks ties fully.
- The merge refuses, with a reason, a seeded test journey (`seeded`) and a `version` newer than it knows (spec).
- Merge never changes its inputs. The result may share tables with them.
- `distance` and `flown` come out in whole yards (`math.floor(x + 0.5)`), and leftovers are whole numbers, because sums of decimals in another order differ in the last digit and would break the grouping property. Snapshots already hold whole yards (`Journal.lua` Snapshot floors them).
- Comments are plain sentences that explain why, British spelling. Commit subjects `Area: what changed (#1)`.

## Decisions the spec leaves open

- **Events in one second.** One character is online on one PC at a time, so the events of one second come from one PC, and a copy that is behind holds the start of what the other holds. The copy with more events in that second leads and keeps its order; the other's are matched to them by key, the nth with the nth; any left over follow in their own order. Equal counts with different keys: the copy whose key list sorts first leads.
- **Event keys.** The spec's list, plus: `grp` matches on time and kind alone; `grpa` on the member's guid (`e[6][1]`); `rare` on `e[9] or e[6]` (the rares key); a `mount` with no ID (`e[6]` nil) on time and kind alone; any kind not listed on time and kind alone. Keys go through `tostring`, so nil and `false` (a `grps` guid for the player) are fine.
- **Events are arrays with holes**, so a matched pair joins through `pairs` on both, never `#`.
- **Current state** (`guild`, `reps`, `group`, `run`, `instance`, `lastZone`, `gear`, `addon`, and any field the merge doesn't know): copied whole from the copy with the latest event, nil included (if the newer copy left the instance, `instance` becomes nil). Copies seen last at the same time join.
- **Riding** entries are `{ name, time, level, base }` (time at index 2), **mounts** `{ time, c, x, y, level, base }` plus `logged` (time at index 1): the earliest note wins whole, and a mount logged in either stays logged.
- **Rares**: `r[1]` is a tally (higher part per PC), `r[2]` the earliest, the rest joins.
- **People** (spec silent on everything but tallies): `first`, `c`, `x`, `y` from the copy that met them first; `last`, `name`, `race`, `sex`, `class`, `level`, `guild` from the copy that saw them last; tallies keep the higher part per PC.
- **Snapshots**: a full one beats a partial one (`partial`, taken at a later login), then the earliest; the same snapshot in both joins (`played` is filled in after it is taken). Counts are recounted up to and including the snapshot's time, plus the leftover of the copies holding that same snapshot.
- **Not in Merge**: refusing two different characters (the data holds no name or realm: the server checks the WTF path, the addon the sync folder's character key) and tidying (the caller runs `Tidy.lua` first; on the server `Tidy.Events` needs a table of place maps).

## Review Focus

1. Journeys from before #35 by two PCs' own clocks, whose sessions seem to overlap: both sessions are kept, in time order. Task 2 tests it.
2. A copy whose events aren't in time order: the result is sorted, and merging the result with itself changes nothing. Task 2.
3. A level snapshot in one copy only, and snapshots missing some counts (older versions): kept, recounted where they have the count, never given counts they didn't have. Task 4.
4. Missing or empty parts: no kills, no segments, no `mounts` or `rares` at all. Tasks 3, 5 and 7 (copies with no sessions).
5. A copy from a newer addon at the same layout, with an event kind or a top-level field this merge doesn't know: the kind matches on time and kind alone, the field is current state. Tasks 1 and 2.

---

### Task 1: The skeleton: Join, refusals, current state

**Files:**
- Create: `RoadToSixty/Merge.lua`
- Test: `tests/merge_test.lua`

**Interfaces:**
- Produces:
  - `ns.Merge.VERSION = 3`
  - `ns.Merge.Join(a, b) -> value`: everything either has; commutative, associative, idempotent.
  - `ns.Merge.Merge(a, b) -> journey` or `nil, reason`.
  - Locals later tasks use: `Join`, `EachKey(a, b, fn)`, `MergeMap(x, y, pick)`, `RULES` (field name -> `function(x, y)`), and the line `function Merge.Merge(a, b)` that later code goes just above.

- [ ] **Step 1: Cut the branch**

```bash
git switch dev && git switch -c sync-merge && git status -sb | head -1
```
Expected: `## sync-merge`.

- [ ] **Step 2: Write the failing test**

Create `tests/merge_test.lua`:

```lua
-- Offline test of Merge.lua: each merge rule, the three properties
-- (either order, twice, any grouping) and made-up play across PCs. Run with
-- LuaJIT from the repo root: luajit tests/merge_test.lua

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
local Merge, Write = ns.Merge, ns.Parse.Write

-- Equal data writes the same text, keys sorted, so this is deep equality.
local function Same(a, b)
    if a == nil or b == nil then return a == b end
    return Write(a) == Write(b)
end

-- A journey at layout 3 with nothing in it, plus the fields given.
local function Journey(fields)
    local j = {
        version = 3, segments = {}, events = {}, levels = {}, recipes = {}, people = {},
        kills = { d = "", last = 0, names = {} },
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 },
    }
    for k, v in pairs(fields or {}) do j[k] = v end
    return j
end

local function On(t) return { t, "on", 0, 0, 0, 10 } end

-- 1. Join keeps everything either copy has.
local J = Merge.Join
check(Same(J({ 1, nil, 3, a = { x = 1 } }, { nil, 2, nil, a = { y = 2 } }), { 1, 2, 3, a = { x = 1, y = 2 } }),
    "tables join key by key, holes included")
check(J(5, 7) == 7 and J("a", "b") == "b" and J(false, true) == true, "of two values, the larger")
check(Same(J(1, { 2 }), { 2 }) and J(nil, 4) == 4, "a table over a value, a value over nothing")

math.randomseed(11)
local function Random(depth)
    local r = math.random(1, depth > 0 and 6 or 4)
    if r == 1 then return math.random(1, 5) end
    if r == 2 then return ("s%d"):format(math.random(1, 3)) end
    if r == 3 then return math.random(1, 2) == 1 end
    if r == 4 then return nil end
    local t = {}
    for _ = 1, math.random(0, 4) do
        local k = math.random(1, 2) == 1 and math.random(1, 4) or ({ "a", "b", "c" })[math.random(1, 3)]
        t[k] = Random(depth - 1)
    end
    return t
end
local joinBroken = 0
for _ = 1, 500 do
    local a, b, c = Random(3), Random(3), Random(3)
    if not Same(J(a, b), J(b, a)) or not Same(J(J(a, b), c), J(a, J(b, c))) or not Same(J(a, a), a) then
        joinBroken = joinBroken + 1
    end
end
check(joinBroken == 0, joinBroken .. " random values broke Join's properties")

-- 2. Copies the merge must not take.
local refused, why = Merge.Merge(Journey({ seeded = true }), Journey())
check(refused == nil and tostring(why):find("seeded"), "a seeded journey is refused: " .. tostring(why))
refused, why = Merge.Merge(Journey(), Journey({ version = 4 }))
check(refused == nil and tostring(why):find("newer"), "a newer layout is refused: " .. tostring(why))
refused, why = Merge.Merge(Journey({ version = 2 }), Journey())
check(refused == nil and tostring(why):find("older"), "an older layout is refused: " .. tostring(why))

-- 3. Current state comes from the copy seen last, gaps included; a tie joins.
local older = Journey({ events = { On(100) }, guild = { "Old Guild", "Member", 3 }, instance = 36, lastZone = 1429, future = "a" })
local newer = Journey({ events = { On(200) }, guild = false, lastZone = 1436, future = "b" })
local m = Merge.Merge(older, newer)
check(m.guild == false and m.instance == nil and m.lastZone == 1436, "state from the copy seen last, nil included")
check(m.future == "b", "a field this merge doesn't know is state too")
check(Same(Merge.Merge(older, newer), Merge.Merge(newer, older)), "state is the same either way round")
m = Merge.Merge(Journey({ events = { On(100) }, lastZone = 1429 }), Journey({ events = { On(100) }, gear = { [1] = 5 } }))
check(m.lastZone == 1429 and m.gear[1] == 5, "copies seen last at the same time join")

-- 4. The merge's own fields.
m = Merge.Merge(Journey({ rosterBuilt = 3, played = 50, clockFrom = 10 }),
    Journey({ played = 70, clockFrom = 20, recipes = { Cooking = { Bread = true } } }))
check(m.version == 3 and m.rosterBuilt == nil, "layout 3, and the roster copy to be rebuilt")
check(m.played == 70 and m.clockFrom == 20 and m.recipes.Cooking.Bread, "played, clockFrom and recipes keep the most")
check(older.instance == 36 and #older.events == 1 and older.guild[1] == "Old Guild", "the inputs are not changed")

if failures == 0 then
    print("Merge tests passed.")
else
    print(failures .. " merge test(s) failed.")
    os.exit(1)
end
```

- [ ] **Step 3: Run it to see it fail**

Run: `luajit tests/merge_test.lua`
Expected: an error that `RoadToSixty/Merge.lua` can't be opened.

- [ ] **Step 4: Write the skeleton**

Create `RoadToSixty/Merge.lua`:

```lua
local _, ns = ...

-- Merges two copies of one character's journey into one (#1), as plain
-- functions with no game calls: the sync server runs it on uploads, and the
-- addon on what the sync folder brings. The rules are the sync spec's
-- (docs/superpowers/specs/2026-10-12-sync-and-backup-design.md, "The merge
-- rules"). Three properties hold, and tests/merge_test.lua checks them:
-- Merge(a, b) equals Merge(b, a), Merge(m, m) equals m for any merge result,
-- and Merge(Merge(a, b), c) equals Merge(a, Merge(b, c)). That is what makes
-- repeated syncs, uploads out of order and stale copies safe.
--
-- What it relies on:
-- - One character is online on one PC at a time, so the events of any one
--   second come from one PC, and a copy that is behind holds the start of
--   what the other holds.
-- - Both copies are at layout 3 (Prepare brings a layout 2 upload up) and
--   tidied as a login would (Tidy.lua). The caller does both.
-- - Both are copies of the same character. The data doesn't say whose it
--   is, so the caller checks that: the server from the WTF path, the addon
--   from the sync folder's character key.
--
-- Merge never changes its inputs; the result may share tables with them.
-- distance and flown come out in whole yards: sums of decimals added in
-- another order differ in the last digit, which would make two ways of
-- grouping three merges differ.

local Merge = {}
ns.Merge = Merge

Merge.VERSION = 3   -- the layout it merges, DATA_VERSION in Core.lua

local RANK = { boolean = 1, number = 2, string = 3, table = 4 }

-- Everything either value has: two tables key by key, otherwise the larger
-- value (true over false, a table over anything else). Made for two copies
-- of one thing where one was filled in more; for two different values it
-- is only a fixed choice, the same whichever way round.
local function Join(a, b)
    if a == nil then return b end
    if b == nil then return a end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return RANK[ta] > RANK[tb] and a or b end
    if ta == "table" then
        local out = {}
        for k, v in pairs(a) do out[k] = Join(v, b[k]) end
        for k, v in pairs(b) do
            if a[k] == nil then out[k] = v end
        end
        return out
    end
    if ta == "boolean" then return a or b end
    return a >= b and a or b
end
Merge.Join = Join

-- Calls fn(key) once for each key in a or b.
local function EachKey(a, b, fn)
    for k in pairs(a or {}) do fn(k) end
    for k in pairs(b or {}) do
        if a == nil or a[k] == nil then fn(k) end
    end
end

-- Two maps merged key by key: a key in one only keeps its value, a key in
-- both gets pick(value in x, value in y).
local function MergeMap(x, y, pick)
    if x == nil or y == nil then return x or y end
    local out = {}
    EachKey(x, y, function(k)
        local p, q = x[k], y[k]
        if p == nil then
            out[k] = q
        elseif q == nil then
            out[k] = p
        else
            out[k] = pick(p, q)
        end
    end)
    return out
end

local function Refused(char)
    if type(char) ~= "table" then return "not a journey" end
    if char.seeded then return "a seeded test journey" end
    local version = tonumber(char.version) or 0
    if version > Merge.VERSION then return "a newer layout than this merge knows" end
    if version < Merge.VERSION then return "an older layout: Prepare it first" end
end

local function LastSeen(char)
    local last = -math.huge
    for _, e in ipairs(char.events or {}) do
        if e[1] > last then last = e[1] end
    end
    return last
end

-- The copy seen last, by its latest event; nil when both were seen last at
-- the same time.
local function Latest(a, b)
    local la, lb = LastSeen(a), LastSeen(b)
    if la == lb then return nil end
    return la > lb and a or b
end

-- How each top-level field merges, given both copies' values (either may be
-- nil). A field not listed is current state, from the copy seen last.
local RULES = {
    clockFrom = Join,   -- the later switch to the realm's clock: times before it may be by a PC's clock
    played = Join,
    skills = Join,      -- profession -> { rank, max, icon }: the higher rank
    recipes = Join,
}

function Merge.Merge(a, b)
    local refused = Refused(a) or Refused(b)
    if refused then return nil, refused end
    local out, latest = {}, Latest(a, b)
    EachKey(a, b, function(k)
        local rule = RULES[k]
        if rule then
            out[k] = rule(a[k], b[k])
        elseif latest then
            out[k] = latest[k]
        else
            out[k] = Join(a[k], b[k])
        end
    end)
    out.version, out.rosterBuilt = Merge.VERSION, nil
    return out
end
```

- [ ] **Step 5: Run the test**

Run: `luajit tests/merge_test.lua`
Expected: `Merge tests passed.`

- [ ] **Step 6: Commit**

```bash
git add RoadToSixty/Merge.lua tests/merge_test.lua
git commit -m "Merge: join, refusals and current state from the copy seen last (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Events

**Files:**
- Modify: `RoadToSixty/Merge.lua` (insert above `function Merge.Merge(a, b)`)
- Test: `tests/merge_test.lua` (insert before `if failures == 0 then`)

**Interfaces:**
- Consumes: `Join`, `RULES` from Task 1.
- Produces: locals `Group(list, keyOf) -> groups, keys` and `Union(x, y) -> keys` (Tasks 3 uses them); `RULES.events`.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/merge_test.lua` before `if failures == 0 then`:

```lua
-- 5. Events: matched by time, kind and what they're about; a matched pair
-- keeps what either has.
local e1 = Journey({ events = { On(100), { 105, "qa", 0, 1, 2, 7 }, { 110, "qd", 0, 1, 2, 7, 450 } } })
local e2 = Journey({ events = {
    On(100), { 105, "qa", 0, 1, 2, 7 }, { 110, "qd", 0, 1, 2, 7, 450, nil, "The Title" }, { 120, "off", 0, 1, 2 },
} })
m = Merge.Merge(e1, e2)
check(#m.events == 4 and m.events[3][9] == "The Title" and m.events[4][2] == "off",
    "a session in both becomes one, the fuller copy's, details from either")
local e3 = Journey({ events = { On(300), { 310, "die", 0, 5, 5 }, { 320, "off", 0, 5, 5 } } })
m = Merge.Merge(e2, e3)
check(#m.events == 7 and m.events[5][1] == 300 and m.events[6][2] == "die", "sessions in one copy only are kept, in time order")
check(Same(Merge.Merge(e2, e3), Merge.Merge(e3, e2)), "events merge the same either way round")

local loot = { 130, "loot", 0, 1, 2, "|cff1eff00|Hitem:2:0|h[Sword]|h|r", 2 }
m = Merge.Merge(Journey({ events = { loot, loot } }), Journey({ events = { loot } }))
check(#m.events == 2, "two identical events in one second stay two, never three")

m = Merge.Merge(Journey({ events = { { 140, "qd", 0, 0, 0, 1, 10 }, { 140, "lvl", 0, 0, 0, 5 } } }),
    Journey({ events = { { 140, "qd", 0, 0, 0, 1, 10 } } }))
check(#m.events == 2 and m.events[2][2] == "lvl", "within a second, the fuller copy's order")

m = Merge.Merge(Journey({ events = { { 150, "zone", 0, 0, 0, 1429 } } }), Journey({ events = { { 150, "zone", 0, 0, 0, 1436 } } }))
check(#m.events == 2, "events about different things don't match")
check(Same(m, Merge.Merge(Journey({ events = { { 150, "zone", 0, 0, 0, 1436 } } }), Journey({ events = { { 150, "zone", 0, 0, 0, 1429 } } }))),
    "and they come out in the same order either way round")

m = Merge.Merge(
    Journey({ events = {
        { 160, "grpa", 0, 0, 0, { "Player-1", "Ann" } },
        { 161, "rare", 0, 0, 0, "Mor'Ladim", "rareelite", 35, 522, "x" },
        { 162, "mount", 0, 0, 0, nil, "Brown Horse", 458, "n" },
        { 163, "grps", 0, 0, 0, false, 2 },
    } }),
    Journey({ events = {
        { 160, "grpa", 0, 0, 0, { "Player-1", "Ann", "Human" } },
        { 161, "rare", 0, 0, 0, "Mor'Ladim", "rareelite", 35, 522, "l" },
        { 162, "mount", 0, 0, 0, nil, "Brown Horse", 458, "n" },
        { 163, "grps", 0, 0, 0, false, 2 },
    } }))
check(#m.events == 4 and m.events[1][6][3] == "Human", "grpa, rare, a mount with no ID and the player's grps each match once")

m = Merge.Merge(Journey({ events = { { 170, "newkind", 0, 0, 0, "a" } } }), Journey({ events = { { 170, "newkind", 0, 0, 0, "b" } } }))
check(#m.events == 1 and m.events[1][6] == "b", "a kind this merge doesn't know matches on time and kind alone")

-- Journeys from before #35, by two PCs' own clocks, can seem to overlap:
-- both sessions stay.
m = Merge.Merge(Journey({ events = { On(1000), { 1100, "die", 0, 0, 0 }, { 1200, "off", 0, 0, 0 } } }),
    Journey({ events = { On(1050), { 1150, "off", 0, 0, 0 } } }))
check(#m.events == 5 and m.events[2][1] == 1050 and m.events[4][1] == 1150, "overlapping sessions both kept, in time order")

local unsorted = Journey({ events = { On(500), { 400, "die", 0, 0, 0 } } })
m = Merge.Merge(unsorted, unsorted)
check(m.events[1][1] == 400 and Same(Merge.Merge(m, m), m), "events come out in time order, and stay so")
check(unsorted.events[1][1] == 500, "the input's order is not changed")
```

- [ ] **Step 2: Run them to see them fail**

Run: `luajit tests/merge_test.lua`
Expected: several `FAIL:` lines from section 5 (events are still taken whole from one copy), for example `FAIL: a session in both becomes one, ...`.

- [ ] **Step 3: Write the event rules**

Insert into `RoadToSixty/Merge.lua`, just above `function Merge.Merge(a, b)`:

```lua
-- The items of list grouped by keyOf(item): groups[key] holds them in list
-- order; keys lists each key once, in order of first appearance.
local function Group(list, keyOf)
    local groups, keys = {}, {}
    for _, item in ipairs(list or {}) do
        local key = keyOf(item)
        local group = groups[key]
        if not group then
            group = {}
            groups[key], keys[#keys + 1] = group, key
        end
        group[#group + 1] = item
    end
    return groups, keys
end

-- The keys in either list, once each.
local function Union(x, y)
    local seen, out = {}, {}
    for _, list in ipairs({ x, y }) do
        for _, key in ipairs(list) do
            if not seen[key] then
                seen[key], out[#out + 1] = true, key
            end
        end
    end
    return out
end

-- Events ------------------------------------------------------------------

-- What an event is about besides its time and kind, per the spec. Kinds not
-- listed (on, off, die, grp, grpk, grpx, and kinds from a newer addon)
-- match on time and kind alone.
local function Field6(e) return e[6] end
local ABOUT = {
    qa = Field6, qd = Field6, eq = Field6, loot = Field6, ["in"] = Field6, out = Field6,
    rep = Field6, prof = Field6, rec = Field6, mount = Field6, ride = Field6,
    gj = Field6, gl = Field6, gr = Field6, lvl = Field6, zone = Field6, grpl = Field6, grps = Field6,
    grpa = function(e) return type(e[6]) == "table" and e[6][1] or nil end,
    rare = function(e) return e[9] or e[6] end,     -- the rares key: NPC ID, else name
}

local function EventKey(e)
    local about = ABOUT[e[2]]
    return tostring(e[2]) .. "|" .. tostring(about and about(e))
end

local function EventTime(e) return e[1] end

local function KeysBefore(x, y)
    for i = 1, #x do
        local kx, ky = EventKey(x[i]), EventKey(y[i])
        if kx ~= ky then return kx < ky end
    end
    return false
end

-- One second's events from both copies. They come from one PC, so the copy
-- with more of them leads and its order is kept; the other's are matched to
-- them by key, the nth with the nth, and any left over follow in their
-- order. Two of one event in a copy (two of the same green drop) stay two:
-- the larger count, never the sum.
local function MergeSecond(x, y)
    if #y > #x or (#y == #x and KeysBefore(y, x)) then x, y = y, x end
    local waiting, used, out = {}, {}, {}
    for i, e in ipairs(y) do
        local key = EventKey(e)
        waiting[key] = waiting[key] or {}
        table.insert(waiting[key], i)
    end
    for _, e in ipairs(x) do
        local queue = waiting[EventKey(e)]
        local i = queue and table.remove(queue, 1)
        if i then
            used[i] = true
            out[#out + 1] = Join(e, y[i])
        else
            out[#out + 1] = e
        end
    end
    for i, e in ipairs(y) do
        if not used[i] then out[#out + 1] = e end
    end
    return out
end

-- Both copies' events, second by second in time order. A session found in
-- one copy only is kept; one in both becomes one.
local function MergeEvents(x, y)
    local gx, kx = Group(x, EventTime)
    local gy, ky = Group(y, EventTime)
    local times = Union(kx, ky)
    table.sort(times)
    local out = {}
    for _, t in ipairs(times) do
        for _, e in ipairs(MergeSecond(gx[t] or {}, gy[t] or {})) do out[#out + 1] = e end
    end
    return out
end
RULES.events = MergeEvents
```

- [ ] **Step 4: Run the test**

Run: `luajit tests/merge_test.lua`
Expected: `Merge tests passed.`

- [ ] **Step 5: Commit**

```bash
git add RoadToSixty/Merge.lua tests/merge_test.lua
git commit -m "Merge: events matched by time, kind and what they are about (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Path segments and kills

**Files:**
- Modify: `RoadToSixty/Merge.lua` (insert above `function Merge.Merge(a, b)`)
- Test: `tests/merge_test.lua` (insert before `if failures == 0 then`)

**Interfaces:**
- Consumes: `Join`, `Group`, `Union`, `RULES`; `ns.Packed.DecodeKills(d, names, t, list)` and `ns.Packed.PackKills(list)` (Packed.lua).
- Produces: local `KillList(kills) -> { { t, xp, name }, ... }` (Task 4 uses it); `RULES.segments`, `RULES.kills`.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/merge_test.lua` before `if failures == 0 then`:

```lua
-- 6. Path segments: matched by start, continent and mode. A stale copy's
-- path is the start of the newer one, so the longer wins.
local function Seg(t, d, mode, c) return { m = mode or "w", c = c or 0, t = t, x = 10, y = 20, d = d } end
m = Merge.Merge(Journey({ segments = { Seg(100, "5,1,1"), Seg(300, "1,1,1") } }),
    Journey({ segments = { Seg(100, "5,1,1;5,2,2"), Seg(200, "", "t"), Seg(300, "1,1,1", "w", 1) } }))
check(#m.segments == 4 and m.segments[1].d == "5,1,1;5,2,2", "the longer path wins")
check(m.segments[2].m == "t" and m.segments[3].t == 300 and m.segments[3].c == 0 and m.segments[4].c == 1,
    "segments from both, sorted by start, then continent")
check(Same(Merge.Merge(Journey({ segments = { Seg(100, "9,9,9") } }), Journey()).segments, { Seg(100, "9,9,9") }),
    "a copy with no segments")

-- 7. Kills: decoded, the larger count of each kept, packed again.
local Kills = ns.Packed.PackKills
local function Decoded(kills)
    local list = {}
    ns.Packed.DecodeKills(kills.d, kills.names, 0, list)
    return list
end
local k1 = Kills({ { t = 100, xp = 50, name = "Kobold" }, { t = 110, xp = 50, name = "Kobold" } })
local k2 = Kills({ { t = 100, xp = 50, name = "Kobold" }, { t = 110, xp = 50, name = "Kobold" }, { t = 120, xp = 60, name = "Hogger" } })
local k3 = Kills({ { t = 50, xp = 10, name = "Wolf" } })
check(Same(Merge.Merge(Journey({ kills = k1 }), Journey({ kills = k2 })).kills, k2), "a stale copy's kills are the start of the newer one's")
m = Merge.Merge(Journey({ kills = k2 }), Journey({ kills = k3 }))
local list = Decoded(m.kills)
check(#list == 4 and list[1].name == "Wolf" and list[4].name == "Hogger" and m.kills.last == 120,
    "kills from both, in time order, last recomputed")
local twice = Kills({ { t = 100, xp = 50, name = "Kobold" }, { t = 100, xp = 50, name = "Kobold" } })
check(#Decoded(Merge.Merge(Journey({ kills = twice }), Journey({ kills = k1 })).kills) == 3,
    "two kills of one kind in one second stay two")
check(Same(Merge.Merge(Journey({ kills = k3 }), Journey()).kills, k3), "a copy with no kills")
```

- [ ] **Step 2: Run them to see them fail**

Run: `luajit tests/merge_test.lua`
Expected: `FAIL:` lines from sections 6 and 7, for example `FAIL: the longer path wins`.

- [ ] **Step 3: Write the segment and kill rules**

Insert into `RoadToSixty/Merge.lua`, just above `function Merge.Merge(a, b)`:

```lua
-- Path segments and kills ------------------------------------------------------

-- Orders values of one type: numbers and strings by value, booleans false first.
local function Less(a, b)
    if type(a) ~= type(b) then return RANK[type(a)] < RANK[type(b)] end
    if type(a) == "boolean" then return not a and b end
    return a < b
end

local function SegmentKey(s) return tostring(s.t) .. "|" .. tostring(s.c) .. "|" .. tostring(s.m) end

local function SegmentBefore(p, q)
    if p.t ~= q.t then return p.t < q.t end
    if p.c ~= q.c then return Less(p.c, q.c) end
    if p.m ~= q.m then return Less(p.m, q.m) end
    local dp, dq = p.d or "", q.d or ""
    if #dp ~= #dq then return #dp < #dq end
    return dp < dq
end

-- Segments matched by start time, continent and mode. A stale copy's path
-- string is always the start of the newer one, so the longer wins. Sorted by
-- start, since teleport detection compares each segment with the one before.
local function MergeSegments(x, y)
    local gx, kx = Group(x, SegmentKey)
    local gy, ky = Group(y, SegmentKey)
    local out = {}
    for _, key in ipairs(Union(kx, ky)) do
        local px, py = gx[key] or {}, gy[key] or {}
        for i = 1, math.max(#px, #py) do
            local p, q = px[i], py[i]
            local seg = p and q and Join(p, q) or p or q
            if p and q and #(p.d or "") ~= #(q.d or "") then
                seg.d = #(p.d or "") > #(q.d or "") and p.d or q.d
            end
            out[#out + 1] = seg
        end
    end
    table.sort(out, SegmentBefore)
    return out
end
RULES.segments = MergeSegments

-- A packed kills table as a list of { t, xp, name }, oldest first.
local function KillList(kills)
    local list = {}
    if kills and kills.d then ns.Packed.DecodeKills(kills.d, kills.names or {}, 0, list) end
    return list
end

local function KillKey(k) return k.t .. "|" .. k.xp .. "|" .. (k.name or "?") end

-- Both copies' kills: of each kill (time, XP, mob) the larger count is kept,
-- then all are packed again with a fresh name list and last.
local function MergeKills(x, y)
    local gx, kx = Group(KillList(x), KillKey)
    local gy, ky = Group(KillList(y), KillKey)
    local list = {}
    for _, key in ipairs(Union(kx, ky)) do
        local px, py = gx[key] or {}, gy[key] or {}
        for _, kill in ipairs(#px >= #py and px or py) do list[#list + 1] = kill end
    end
    table.sort(list, function(p, q)
        if p.t ~= q.t then return p.t < q.t end
        if p.xp ~= q.xp then return p.xp < q.xp end
        return (p.name or "?") < (q.name or "?")
    end)
    return ns.Packed.PackKills(list)
end
RULES.kills = MergeKills
```

- [ ] **Step 4: Run the test**

Run: `luajit tests/merge_test.lua`
Expected: `Merge tests passed.`

- [ ] **Step 5: Commit**

```bash
git add RoadToSixty/Merge.lua tests/merge_test.lua
git commit -m "Merge: path segments, the longer of each, and kills recombined (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Totals and level snapshots

**Files:**
- Modify: `RoadToSixty/Merge.lua` (insert above `function Merge.Merge(a, b)`, and one line in `Merge.Merge`)
- Test: `tests/merge_test.lua` (insert before `if failures == 0 then`)

**Interfaces:**
- Consumes: `Join`, `MergeMap`, `KillList`, `RULES`; `ns.Packed.DecodePath(seg) -> ts, xs, ys`.
- Produces: local `COUNTED` (the eight count fields, Task 6 uses it); `RULES.totals`, `RULES.levels`; `Recount(out, a, b)` called at the end of `Merge.Merge`.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/merge_test.lua` before `if failures == 0 then`:

```lua
-- 8. Totals are recounted from the merged data. What a copy's totals hold
-- beyond what its data recounts to (counted before the data was kept)
-- carries over, the larger of the two.
local function Totals(t)
    local totals = Journey().totals
    for k, v in pairs(t) do totals[k] = v end
    return totals
end
local A = Journey({
    events = { On(100), { 110, "qd", 0, 0, 0, 1, 300 }, { 120, "die", 0, 0, 0 } },
    kills = Kills({ { t = 105, xp = 40, name = "Kobold" } }),
    segments = { { m = "w", c = 0, t = 100, x = 0, y = 0, d = "1,3,4" }, { m = "t", c = 0, t = 130, x = 0, y = 0, d = "1,6,8" } },
    totals = Totals({ kills = 8, killXP = 40, quests = 1, questXP = 300, deaths = 1, distance = 5.4, flown = 10 }),
})
local B = Journey({
    events = { On(200), { 210, "in", 0, 0, 0, 36, "The Deadmines", "party" } },
    kills = Kills({ { t = 205, xp = 60, name = "Defias Thug" } }),
    totals = Totals({ kills = 1, killXP = 60, instances = 1 }),
})
m = Merge.Merge(A, B)
local tot = m.totals
check(tot.kills == 9 and tot.killXP == 100, "kills recounted, and the 7 counted before kills were kept carried over: " .. tot.kills)
check(tot.quests == 1 and tot.questXP == 300 and tot.deaths == 1 and tot.instances == 1, "quests, deaths and instances recounted")
check(tot.distance == 5 and tot.flown == 10, "distance from walked steps, flown from taxi steps, in whole yards")
check(Same(Merge.Merge(m, m), m) and Same(Merge.Merge(B, A), m), "totals come out the same every way")

-- 9. Level snapshots: a full one over one taken at a later login, then the
-- earliest; counts recounted at its time plus its copy's carry-over.
A.levels = { [5] = { t = 115, kills = 1, killXP = 40, quests = 1, questXP = 300, deaths = 0, instances = 0,
    distance = 5, flown = 0, money = 100, gear = { [1] = 5 } } }
A.levels[8] = { t = 300, partial = true, money = 1 }
B.levels = {
    [5] = { t = 200, partial = true, kills = 1, killXP = 60, quests = 0, questXP = 0, deaths = 0, instances = 0,
        distance = 0, flown = 0, money = 900 },
    [6] = { t = 220, kills = 1, killXP = 60, quests = 0, questXP = 0, deaths = 0, instances = 1, distance = 0, flown = 0 },
    [7] = { t = 230, kills = 1 },
    [8] = { t = 250, partial = true, money = 2 },
}
m = Merge.Merge(A, B)
local s5, s6 = m.levels[5], m.levels[6]
check(s5.money == 100 and not s5.partial and s5.kills == 1 and s5.distance == 5, "the full snapshot wins, its counts as they were")
check(s6.kills == 2 and s6.killXP == 100 and s6.quests == 1 and s6.questXP == 300 and s6.deaths == 1 and s6.instances == 1,
    "a snapshot in one copy only, recounted at its time with the other copy's play: " .. s6.kills)
check(s6.distance == 5 and s6.flown == 10, "and its distance")
check(m.levels[7].kills == 2 and m.levels[7].distance == nil, "a count a snapshot didn't have stays out")
check(m.levels[8].money == 2, "of two later-login snapshots, the earlier")
check(A.levels[5].kills == 1 and B.levels[6].kills == 1, "the inputs' snapshots are not changed")
check(Same(Merge.Merge(m, m), m) and Same(Merge.Merge(B, A), m), "snapshots come out the same every way")
```

- [ ] **Step 2: Run them to see them fail**

Run: `luajit tests/merge_test.lua`
Expected: `FAIL:` lines from sections 8 and 9, for example `FAIL: kills recounted, ...`.

- [ ] **Step 3: Write the recount**

Insert into `RoadToSixty/Merge.lua`, just above `function Merge.Merge(a, b)`:

```lua
-- Totals and level snapshots ----------------------------------------------------

local COUNTED = { "kills", "killXP", "quests", "questXP", "deaths", "instances", "distance", "flown" }

local function Round(x) return math.floor(x + 0.5) end

-- Every count in a journey's totals as { time, field, amount }, sorted so
-- the sums come out the same whatever order the data was in.
local function Marks(char)
    local marks = {}
    local function Mark(t, field, n) marks[#marks + 1] = { t, field, n } end
    for _, k in ipairs(KillList(char.kills)) do
        Mark(k.t, "kills", 1)
        Mark(k.t, "killXP", k.xp)
    end
    for _, e in ipairs(char.events or {}) do
        if e[2] == "qd" then
            Mark(e[1], "quests", 1)
            Mark(e[1], "questXP", tonumber(e[7]) or 0)
        elseif e[2] == "die" then
            Mark(e[1], "deaths", 1)
        elseif e[2] == "in" then
            Mark(e[1], "instances", 1)
        end
    end
    for _, seg in ipairs(char.segments or {}) do
        local ts, xs, ys = ns.Packed.DecodePath(seg)
        local field = seg.m == "t" and "flown" or "distance"   -- t: a taxi flight, as Recorder.lua counts it
        for i = 2, #ts do
            local dx, dy = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
            Mark(ts[i], field, math.sqrt(dx * dx + dy * dy))
        end
    end
    table.sort(marks, function(p, q)
        if p[1] ~= q[1] then return p[1] < q[1] end
        if p[2] ~= q[2] then return p[2] < q[2] end
        return p[3] < q[3]
    end)
    return marks
end

-- A journey's counts up to and including each of its snapshots' times, and
-- at math.huge for its totals: counts[time][field], distance and flown in
-- whole yards. One pass over the sorted marks, however many snapshots.
local function Counts(char)
    local times = { math.huge }
    for _, s in pairs(char.levels or {}) do
        if s.t then times[#times + 1] = s.t end
    end
    table.sort(times)
    local marks, sums, counts, i = Marks(char), {}, {}, 1
    for _, f in ipairs(COUNTED) do sums[f] = 0 end
    for _, t in ipairs(times) do
        while marks[i] and marks[i][1] <= t do
            sums[marks[i][2]] = sums[marks[i][2]] + marks[i][3]
            i = i + 1
        end
        local at = {}
        for _, f in ipairs(COUNTED) do at[f] = sums[f] end
        at.distance, at.flown = Round(at.distance), Round(at.flown)
        counts[t] = at
    end
    return counts
end

-- How far what was recorded (a copy's totals, or one of its snapshots) is
-- above what its data recounts to: counts kept before the data was.
local function Leftover(recorded, counted)
    local left = {}
    for _, f in ipairs(COUNTED) do left[f] = Round(tonumber(recorded[f]) or 0) - counted[f] end
    return left
end

local function Higher(x, y)
    if not x then return y end
    local out = {}
    for _, f in ipairs(COUNTED) do out[f] = math.max(x[f], y[f]) end
    return out
end

-- Which of two snapshots of one level to keep: a full one over one taken at
-- a later login, then the earlier. The same snapshot in both joins, since
-- played is filled in after it is taken.
local function PickSnapshot(p, q)
    if not p.partial ~= not q.partial then return p.partial and q or p end
    if p.t ~= q.t then return (p.t or 0) < (q.t or 0) and p or q end
    return Join(p, q)
end
RULES.levels = function(x, y) return MergeMap(x, y, PickSnapshot) end
RULES.totals = Join     -- the counts are redone by Recount; this keeps any other field

-- Recounts the merged journey's totals and each snapshot's counts from its
-- data, adding the larger leftover of the copies they came from. A snapshot
-- only gets back the counts it had.
local function Recount(out, a, b)
    local counts, ca, cb = Counts(out), Counts(a), Counts(b)
    local totals = {}
    for k, v in pairs(out.totals or {}) do totals[k] = v end
    local left = Higher(Leftover(a.totals or {}, ca[math.huge]), Leftover(b.totals or {}, cb[math.huge]))
    for _, f in ipairs(COUNTED) do totals[f] = counts[math.huge][f] + left[f] end
    out.totals = totals
    if not out.levels then return end
    local levels = {}
    for level, s in pairs(out.levels) do
        local snap, kept = {}, nil
        for k, v in pairs(s) do snap[k] = v end
        for _, side in ipairs({ { a, ca }, { b, cb } }) do
            local mine = side[1].levels and side[1].levels[level]
            if s.t and mine and mine.t == s.t then kept = Higher(kept, Leftover(mine, side[2][s.t])) end
        end
        if kept then
            for _, f in ipairs(COUNTED) do
                if snap[f] ~= nil then snap[f] = counts[s.t][f] + kept[f] end
            end
        end
        levels[level] = snap
    end
    out.levels = levels
end
```

Then in `Merge.Merge`, change

```lua
    out.version, out.rosterBuilt = Merge.VERSION, nil
    return out
```

to

```lua
    out.version, out.rosterBuilt = Merge.VERSION, nil
    Recount(out, a, b)
    return out
```

- [ ] **Step 4: Run the test**

Run: `luajit tests/merge_test.lua`
Expected: `Merge tests passed.`

- [ ] **Step 5: Commit**

```bash
git add RoadToSixty/Merge.lua tests/merge_test.lua
git commit -m "Merge: totals and snapshot counts recounted, older counts carried over (#1)

The recount runs once over sorted marks for all snapshots, and writes
distance and flown in whole yards so the order of merging can't change
the last digit.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Riding, mounts, people and rares

**Files:**
- Modify: `RoadToSixty/Merge.lua` (insert above `function Merge.Merge(a, b)`)
- Test: `tests/merge_test.lua` (insert before `if failures == 0 then`)

**Interfaces:**
- Consumes: `Join`, `MergeMap`, `RULES`; `ns.Tally.Total` in the tests.
- Produces: `RULES.riding`, `RULES.mounts`, `RULES.people`, `RULES.rares`.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/merge_test.lua` before `if failures == 0 then`:

```lua
-- 10. Riding and mounts: the earliest note of each wins; a mount logged in
-- either copy stays logged.
local horse = { 650, 0, 3, 4, 40 }
horse.logged = true
m = Merge.Merge(
    Journey({ riding = { [33388] = { "Apprentice Riding", 500, 40 } }, mounts = { [6] = { 600, 0, 1, 2, 40, true } } }),
    Journey({ riding = { [33388] = { "Apprentice Riding", 450, 40 } }, mounts = { [6] = horse, [7] = { 700, 0, 0, 0, 41 } } }))
check(m.riding[33388][2] == 450, "riding: the earliest note")
check(m.mounts[6][1] == 600 and m.mounts[6][6] == true and m.mounts[6].logged == true, "mounts: the earliest note, logged from either")
check(m.mounts[7][1] == 700, "a mount in one copy only")
check(Merge.Merge(Journey({ mounts = { [6] = { 600 } } }), Journey()).mounts[6][1] == 600, "a copy with no mounts at all")

-- 11. People: tallies keep the higher part per PC; where and when first
-- met from the copy that met them first, the rest from the one that saw
-- them last.
local pa = { name = "Ann", level = 10, guild = "Old", first = 100, last = 150, c = 0, x = 1, y = 1,
    groups = { pca = 2 }, seconds = { pca = 600 } }
local pb = { name = "Ann", level = 14, guild = "New", first = 200, last = 300, c = 1, x = 5, y = 5,
    groups = { pca = 1, pcb = 3 } }
m = Merge.Merge(Journey({ people = { g = pa } }), Journey({ people = { g = pb, h = { name = "Bob", first = 5, last = 5 } } }))
local p = m.people.g
check(p.groups.pca == 2 and p.groups.pcb == 3 and p.seconds.pca == 600 and ns.Tally.Total(p.groups) == 5,
    "tallies: the higher part per PC")
check(p.first == 100 and p.c == 0 and p.x == 1 and p.last == 300 and p.level == 14 and p.guild == "New",
    "first met from the earlier copy, the rest from the later")
check(m.people.h.name == "Bob", "people in one copy only are kept")

-- 12. Rares: kills tallied per PC, the first kill the earliest.
m = Merge.Merge(Journey({ rares = { [522] = { { pca = 2 }, 500, "Mor'Ladim", 522, "rareelite" } } }),
    Journey({ rares = { [522] = { { pca = 1, pcb = 1 }, 450, "Mor'Ladim", 522, "rareelite" },
        Foulmane = { { pcb = 1 }, 900, "Foulmane" } } }))
local r = m.rares[522]
check(ns.Tally.Total(r[1]) == 3 and r[2] == 450 and r[3] == "Mor'Ladim", "a rare's kills per PC, its first kill the earliest")
check(m.rares.Foulmane[2] == 900, "rares in one copy only are kept")
check(Merge.Merge(Journey(), Journey()).rares == nil, "no rares in either stays none")

-- A rare killed for the first time on two PCs before they were linked logs
-- a first kill on each. Both events stay (the merge keeps events, it can't
-- tell which first kill the player cares about); the rare's entry has the
-- earliest. A known limit, listed in the plan's notes.
m = Merge.Merge(
    Journey({ events = { { 450, "rare", 0, 0, 0, "Mor'Ladim", "rareelite", 35, 522, "x" } },
        rares = { [522] = { { pca = 1 }, 450, "Mor'Ladim", 522, "rareelite" } } }),
    Journey({ events = { { 500, "rare", 0, 0, 0, "Mor'Ladim", "rareelite", 35, 522, "x" } },
        rares = { [522] = { { pcb = 1 }, 500, "Mor'Ladim", 522, "rareelite" } } }))
check(#m.events == 2 and m.rares[522][2] == 450 and ns.Tally.Total(m.rares[522][1]) == 2,
    "two first kills of one rare from two unlinked PCs both stay")
```

- [ ] **Step 2: Run them to see them fail**

Run: `luajit tests/merge_test.lua`
Expected: `FAIL:` lines from sections 10 to 12, for example `FAIL: riding: the earliest note` (both are still taken whole from one copy).

- [ ] **Step 3: Write the rules**

Insert into `RoadToSixty/Merge.lua`, just above `function Merge.Merge(a, b)`:

```lua
-- Riding, mounts, people and rares ---------------------------------------------

-- riding (spellID -> { name, time, level, base }) and mounts (mountID ->
-- { time, c, x, y, level, base }, plus logged): the earliest note of each
-- wins, at being the index of its time. A mount logged in either copy
-- stays logged, so it is never logged again.
local function FirstNoted(at)
    return function(x, y)
        return MergeMap(x, y, function(p, q)
            local tp, tq = p[at] or 0, q[at] or 0
            local note = tp == tq and Join(p, q) or (tp < tq and p or q)
            if (p.logged or q.logged) and not note.logged then note = Join(note, { logged = true }) end
            return note
        end)
    end
end
RULES.riding = FirstNoted(2)
RULES.mounts = FirstNoted(1)

-- A player met, in both copies (Groups.lua): the tallies keep the higher
-- part per PC; where and when they were first met comes from the copy that
-- met them first, and the rest from the copy that saw them last.
local FIRST_MET = { "first", "c", "x", "y" }
local LAST_SEEN = { "last", "name", "race", "sex", "class", "level", "guild" }

local function MergePerson(p, q)
    local out = Join(p, q)
    if p.first ~= q.first then
        local first = (p.first or 0) < (q.first or 0) and p or q
        for _, f in ipairs(FIRST_MET) do out[f] = first[f] end
    end
    if p.last ~= q.last then
        local last = (p.last or 0) > (q.last or 0) and p or q
        for _, f in ipairs(LAST_SEEN) do out[f] = last[f] end
    end
    return out
end
RULES.people = function(x, y) return MergeMap(x, y, MergePerson) end

-- A rare (Rares.lua): kills tallied per PC, the higher part each; the first
-- kill the earliest.
local function MergeRare(p, q)
    local out = Join(p, q)
    if p[2] and q[2] then out[2] = math.min(p[2], q[2]) end
    return out
end
RULES.rares = function(x, y) return MergeMap(x, y, MergeRare) end
```

- [ ] **Step 4: Run the test**

Run: `luajit tests/merge_test.lua`
Expected: `Merge tests passed.`

- [ ] **Step 5: Commit**

```bash
git add RoadToSixty/Merge.lua tests/merge_test.lua
git commit -m "Merge: riding, mounts, people and rares (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Prepare and Check, for the server

**Files:**
- Modify: `RoadToSixty/Merge.lua` (append at the end)
- Test: `tests/merge_test.lua` (insert before `if failures == 0 then`)

**Interfaces:**
- Consumes: `COUNTED` (Task 4); `ns.Tally.Upgrade(char, pc)`, `ns.Tally.PEOPLE` (Tally.lua).
- Produces:
  - `ns.Merge.Prepare(char, pc) -> char` or `nil, reason`: layout 2 brought up to 3 in place, counts as pc's.
  - `ns.Merge.Check(a, b, out) -> true` or `false, reason`.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/merge_test.lua` before `if failures == 0 then`:

```lua
-- 13. Prepare brings a layout 2 upload up, its counts as the PC it came from.
local old = Journey({ version = 2, people = { g = { groups = 3 } }, rares = { [1] = { 2, 10 } } })
check(Merge.Prepare(old, "pcz") == old and old.version == 3 and old.people.g.groups.pcz == 3 and old.rares[1][1].pcz == 2,
    "a layout 2 upload is prepared")
local none, reason = Merge.Prepare(Journey({ version = 1 }), "pcz")
check(none == nil and reason, "layout 1 is refused")
none, reason = Merge.Prepare(Journey({ version = 4 }), "pcz")
check(none == nil and tostring(reason):find("newer"), "a newer layout is refused")
check(Merge.Prepare(Journey(), "pcz").version == 3, "layout 3 is left as it is")

-- 14. Check: a result holds every session and no count went down.
local function Copy(t) return ns.Parse.Read(Write(t)) end
m = Merge.Merge(A, B)
check(Merge.Check(A, B, m), "a merge passes its own check")
local bad = Copy(m)
for i = #bad.events, 1, -1 do
    if bad.events[i][2] == "on" and bad.events[i][1] == 200 then table.remove(bad.events, i) end
end
local passed, failed = Merge.Check(A, B, bad)
check(not passed and tostring(failed):find("session"), "a lost session fails: " .. tostring(failed))
bad = Copy(m)
bad.totals.kills = 1
passed, failed = Merge.Check(A, B, bad)
check(not passed and tostring(failed):find("kills"), "a lower total fails: " .. tostring(failed))
local P1, P2 = Journey({ people = { g = { groups = { pca = 2 } } } }), Journey({ people = { g = { groups = { pcb = 1 } } } })
bad = Merge.Merge(P1, P2)
bad.people.g.groups.pca = 1
passed, failed = Merge.Check(P1, P2, bad)
check(not passed and tostring(failed):find("tally"), "a lower tally fails: " .. tostring(failed))
```

- [ ] **Step 2: Run them to see them fail**

Run: `luajit tests/merge_test.lua`
Expected: an error `attempt to call field 'Prepare' (a nil value)`.

- [ ] **Step 3: Write Prepare and Check**

Append to the end of `RoadToSixty/Merge.lua`:

```lua
-- For the server -------------------------------------------------------------

-- Brings a journey saved by an older addon up to Merge.VERSION before it is
-- merged, its counts counted as pc's, the PC it came from. Changes the
-- journey in place. Returns it, or nil and why it can't be merged.
function Merge.Prepare(char, pc)
    if type(char) ~= "table" then return nil, "not a journey" end
    local version = tonumber(char.version) or 0
    if version > Merge.VERSION then return nil, "a newer layout than this merge knows" end
    if version < 2 then return nil, "a layout from before journeys used the realm's clock" end
    if version < 3 then
        ns.Tally.Upgrade(char, pc)
        char.version = 3
    end
    return char
end

local function Sessions(char)
    local on = {}
    for _, e in ipairs(char.events or {}) do
        if e[2] == "on" then on[e[1]] = (on[e[1]] or 0) + 1 end
    end
    return on
end

-- Every PC's part of every tally a journey holds, by a name for it.
local function Parts(char)
    local parts = {}
    for guid, p in pairs(char.people or {}) do
        for _, f in ipairs(ns.Tally.PEOPLE) do
            if type(p[f]) == "table" then
                for pc, n in pairs(p[f]) do parts["people " .. guid .. " " .. f .. " " .. pc] = n end
            end
        end
    end
    for key, r in pairs(char.rares or {}) do
        if type(r[1]) == "table" then
            for pc, n in pairs(r[1]) do parts["rares " .. tostring(key) .. " " .. pc] = n end
        end
    end
    return parts
end

-- The server's check of a merge result against its two inputs: every
-- session in either is there, and no total or tally went down (distance and
-- flown may lose an input's decimals). Returns true, or false and why.
function Merge.Check(a, b, out)
    local sessions, parts = Sessions(out), Parts(out)
    for _, copy in ipairs({ a, b }) do
        for t, n in pairs(Sessions(copy)) do
            if (sessions[t] or 0) < n then return false, "the session at " .. t .. " is missing" end
        end
        for _, f in ipairs(COUNTED) do
            local was = math.floor(tonumber(copy.totals and copy.totals[f]) or 0)
            if (tonumber(out.totals and out.totals[f]) or 0) < was then return false, "totals." .. f .. " went down" end
        end
        for name, n in pairs(Parts(copy)) do
            if (parts[name] or 0) < n then return false, "the tally " .. name .. " went down" end
        end
    end
    return true
end
```

- [ ] **Step 4: Run the test**

Run: `luajit tests/merge_test.lua`
Expected: `Merge tests passed.`

- [ ] **Step 5: Commit**

```bash
git add RoadToSixty/Merge.lua tests/merge_test.lua
git commit -m "Merge: Prepare a layout 2 upload, and Check a result, for the server (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Made-up play across PCs, and the three properties

**Files:**
- Test: `tests/merge_test.lua` (insert before `if failures == 0 then`)
- Modify: `RoadToSixty/Merge.lua` only if these tests find a fault (fix the code, never the test; ledger a ruling)

**Interfaces:**
- Consumes: everything above; `Copy`, `Same`, `Journey` from the test file.

- [ ] **Step 1: Write the tests**

Insert into `tests/merge_test.lua` before `if failures == 0 then`:

```lua
-- 15. Made-up play: twelve sessions, each on one PC, never overlapping. A
-- copy is built by playing its sessions the way the addon records them:
-- snapshot counts from that copy's own totals, tallies under its PC.
-- Merging the copies must give the journey that played every session.
math.randomseed(5)
local GUIDS = { "Player-1-0001", "Player-1-0002", "Player-1-0003", "Player-1-0004" }
local MOBS = { "Kobold Vermin", "Young Wolf", "Defias Thug" }
local COUNTS = { "kills", "killXP", "quests", "questXP", "deaths", "instances", "distance", "flown" }
local SESSIONS, startLevel = {}, 1
for n = 1, 12 do
    local t0 = n * 10000
    local s = { level = startLevel, levelUp = n % 2 == 0, die = n % 4 == 0, instance = n % 5 == 0,
        meet = GUIDS[n % 4 + 1], rare = n % 3 == 1 and 1000 + n or nil, zone = 1429 + n % 3, kills = {}, paths = {} }
    for i = 1, 4 do s.kills[i] = { t0 + 10 * i, math.random(20, 80), MOBS[math.random(1, 3)] } end
    local walk = { m = "w", t = t0 + 50, x = math.random(-500, 500), y = math.random(-500, 500), steps = {} }
    for i = 1, 3 do walk.steps[i] = { 5, math.random(-30, 30), math.random(-30, 30) } end
    s.paths[1] = walk
    if n % 3 == 0 then s.paths[2] = { m = "t", t = t0 + 100, x = 0, y = 0, steps = { { 5, 300, 40 }, { 5, 250, -60 } } } end
    if s.levelUp then startLevel = startLevel + 1 end
    SESSIONS[n] = s
end

local function Play(copy, n, pc)
    local s, t0, totals = SESSIONS[n], n * 10000, copy.totals
    local function Log(t, kind, ...) copy.events[#copy.events + 1] = { t, kind, 0, 0, 0, ... } end
    local function Snapshot(level, t, partial)
        local snap = { t = t, partial = partial or nil, money = level * 100, gear = { [1] = level } }
        for _, f in ipairs(COUNTS) do snap[f] = math.floor(totals[f]) end
        copy.levels[level] = snap
    end
    Log(t0, "on", s.level)
    if not copy.levels[s.level] then Snapshot(s.level, t0, s.level > 1) end
    local kills = {}
    ns.Packed.DecodeKills(copy.kills.d, copy.kills.names, 0, kills)
    for _, k in ipairs(s.kills) do
        kills[#kills + 1] = { t = k[1], xp = k[2], name = k[3] }
        totals.kills, totals.killXP = totals.kills + 1, totals.killXP + k[2]
    end
    copy.kills = ns.Packed.PackKills(kills)
    for _, path in ipairs(s.paths) do
        local parts, field = {}, path.m == "t" and "flown" or "distance"
        for i, step in ipairs(path.steps) do
            parts[i] = table.concat(step, ",")
            totals[field] = totals[field] + math.sqrt(step[2] * step[2] + step[3] * step[3])
        end
        copy.segments[#copy.segments + 1] = { m = path.m, c = 0, t = path.t, x = path.x, y = path.y, d = table.concat(parts, ";") }
    end
    Log(t0 + 150, "qa", n)
    Log(t0 + 160, "qd", n, 300)
    totals.quests, totals.questXP = totals.quests + 1, totals.questXP + 300
    if s.levelUp then
        Snapshot(s.level + 1, t0 + 160)
        Log(t0 + 160, "lvl", s.level + 1)
    end
    if s.die then
        Log(t0 + 170, "die")
        totals.deaths = totals.deaths + 1
    end
    if s.instance then
        Log(t0 + 180, "in", 36, "The Deadmines", "party")
        totals.instances = totals.instances + 1
        Log(t0 + 190, "out", 36)
    end
    local met = copy.people[s.meet] or { first = t0 + 200, c = 0, x = n, y = n }
    copy.people[s.meet] = met
    met.name, met.level, met.last = "Name " .. s.meet, s.level, t0 + 200
    ns.Tally.Add(met, "groups", pc, 1)
    ns.Tally.Add(met, "seconds", pc, 300)
    if s.rare then
        copy.rares = copy.rares or {}
        copy.rares[s.rare] = { { [pc] = 1 }, t0 + 210, "Rare " .. s.rare, s.rare, "rare" }
        Log(t0 + 210, "rare", "Rare " .. s.rare, "rare", s.level, s.rare, "x")
    end
    Log(t0 + 220, "zone", s.zone)
    copy.lastZone, copy.guild, copy.played = s.zone, { "Guild " .. n, "Member", 3 }, n * 300
    Log(t0 + 300, "off")
end

-- A copy that played these { session, pc } in order.
local function Played(list)
    local copy = Journey()
    for _, step in ipairs(list) do Play(copy, step[1], step[2]) end
    return copy
end

local function With(list, more)
    local all = {}
    for _, x in ipairs(list) do all[#all + 1] = x end
    for _, x in ipairs(more) do all[#all + 1] = x end
    return all
end

-- Whether a merge result is the journey that played everything: exact,
-- except distance and flown, which the merge gives in whole yards.
local function Matches(m, truth)
    local want = Copy(truth)
    for _, f in ipairs({ "distance", "flown" }) do
        if math.abs(m.totals[f] - want.totals[f]) > 1 then return false end
        want.totals[f] = m.totals[f]
        for level, s in pairs(want.levels) do
            local got = m.levels[level]
            if not got or math.abs(got[f] - s[f]) > 1 then return false end
            s[f] = got[f]
        end
    end
    return Same(m, want)
end

-- The spec's four cases.
local truth = Played({ { 1, "pca" }, { 2, "pca" }, { 3, "pca" }, { 4, "pcb" }, { 5, "pcb" } })
check(Matches(Merge.Merge(Played({ { 1, "pca" }, { 2, "pca" }, { 3, "pca" } }), Played({ { 4, "pcb" }, { 5, "pcb" } })), truth),
    "a new PC with no data")

local base = { { 1, "pca" }, { 2, "pca" } }
local onA = Played(With(base, { { 3, "pca" }, { 5, "pca" } }))
local onB = Played(With(base, { { 4, "pcb" }, { 6, "pcb" } }))
local both = Merge.Merge(onA, onB)
check(Matches(both, Played(With(base, { { 3, "pca" }, { 4, "pcb" }, { 5, "pca" }, { 6, "pcb" } }))),
    "shared history, then new play on both PCs")
check(Merge.Check(onA, onB, both), "which passes the server's check")
check(Same(Merge.Merge(Played(base), both), both), "an old pre-sync copy against the newer merged one changes nothing")

-- A WTF folder copied by hand keeps the PC ID, so both PCs add to one part
-- and the merge keeps the higher part, not both: one meeting goes
-- uncounted. Events and totals still add up. A known limit, listed in the
-- plan's notes.
local original = Played(base)
local copied = Copy(original)
Play(original, 3, "pca")
Play(copied, 7, "pca")
local handled = Merge.Merge(original, copied)
truth = Played(With(base, { { 3, "pca" }, { 7, "pca" } }))
check(Same(handled.events, truth.events) and handled.totals.kills == truth.totals.kills, "a hand-copied WTF folder: events and totals add up")
check(ns.Tally.Total(handled.people[GUIDS[4]].groups) == ns.Tally.Total(truth.people[GUIDS[4]].groups) - 1,
    "a hand-copied WTF folder: one meeting goes uncounted")

-- 16. The three properties, on made-up copies: a shared start played
-- everywhere, then each session on one of three PCs.
local broken = {}
for seed = 1, 12 do
    math.randomseed(seed)
    local shared, plays, all = math.random(0, 3), { pca = {}, pcb = {}, pcc = {} }, {}
    for n = 1, 12 do
        local pc = n <= shared and "pca" or ({ "pca", "pcb", "pcc" })[math.random(1, 3)]
        all[#all + 1] = { n, pc }
        for name, list in pairs(plays) do
            if n <= shared or name == pc then list[#list + 1] = { n, pc } end
        end
    end
    local a, b, c = Played(plays.pca), Played(plays.pcb), Played(plays.pcc)
    local ab = Merge.Merge(a, b)
    if not Same(ab, Merge.Merge(b, a)) then broken[#broken + 1] = seed .. " either order" end
    if not Same(Merge.Merge(ab, ab), ab) then broken[#broken + 1] = seed .. " twice" end
    local left = Merge.Merge(ab, c)
    if not Same(left, Merge.Merge(a, Merge.Merge(b, c))) then broken[#broken + 1] = seed .. " grouping" end
    if not Matches(left, Played(all)) then broken[#broken + 1] = seed .. " every session" end
    if not Merge.Check(a, b, ab) then broken[#broken + 1] = seed .. " check" end
end
check(#broken == 0, "properties broken (seed, which): " .. table.concat(broken, ", "))
```

- [ ] **Step 2: Run them**

Run: `luajit tests/merge_test.lua`
Expected: `Merge tests passed.`

These tests check behaviour already built, so they may pass at once. To prove they can fail, break the merge on purpose and watch them catch it: in `MergePerson`, change `local first = (p.first or 0) < (q.first or 0) and p or q` to use `>`, run, and expect `FAIL: a new PC with no data` and `FAIL: properties broken (seed, which): ...` naming `every session` (a player met on two PCs gets the later meeting as their first). Then change it back and run again: `Merge tests passed.` If a seed fails without the deliberate break, find the cause with superpowers:systematic-debugging, fix `Merge.lua`, and ledger a ruling.

- [ ] **Step 3: Commit**

```bash
git add tests/merge_test.lua
git commit -m "Tests: made-up play across PCs, and the merge's three properties (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(Add `RoadToSixty/Merge.lua` to the commit if step 2 found and fixed a fault.)

---

### Task 8: Load it with the addon, keep it pure, check standard Lua 5.1

**Files:**
- Modify: `RoadToSixty/RoadToSixty.toc` (after `Tally.lua`), `tests/pure_test.lua`, `CLAUDE.md` (layout table)

- [ ] **Step 1: pure_test**

In `tests/pure_test.lua`, change the bytecode list to:

```lua
for _, name in ipairs({ "Packed.lua", "Tidy.lua", "Parse.lua", "Tally.lua", "Merge.lua" }) do
```

after `Load("Tally.lua", ns)` add `Load("Merge.lua", ns)`, and before `print("Pure tests passed.")` add:

```lua
local merged = ns.Merge.Merge({ version = 3, events = { { 1, "on", 0, 0, 0, 1 } } }, { version = 3, events = {} })
assert(#merged.events == 1 and merged.totals.kills == 0)
```

Run: `luajit tests/pure_test.lua`
Expected: `Pure tests passed.`

- [ ] **Step 2: toc and layout table**

In `RoadToSixty/RoadToSixty.toc`, add the line `Merge.lua` after `Tally.lua`.

In `CLAUDE.md`, change the Tally row and add a Merge row after it:

```markdown
| Tally.lua | counts kept per PC so journeys from two PCs can merge (no game calls) |
| Merge.lua | merges two copies of one character's journey, for the sync (no game calls); its rules are in its header and the sync spec; `tests/pure_test.lua` keeps Packed, Tidy, Parse, Tally and Merge pure |
```

Run: `luajit tests/release_load.lua RoadToSixty && luajit tests/clock_test.lua`
Expected: `Release load test passed: 47 files loaded from RoadToSixty.` and `Clock tests passed.`

- [ ] **Step 3: Standard Lua 5.1**

The server runs PUC Lua 5.1. It was built in this session's scratchpad for the Parse plan; if `$SCRATCH/lua-5.1.5/src/lua` is gone, build it again:

```bash
cd "$SCRATCH" && curl -sLO https://www.lua.org/ftp/lua-5.1.5.tar.gz && tar xzf lua-5.1.5.tar.gz && make -C lua-5.1.5 posix >/dev/null
```

From the repo root:

```bash
"$SCRATCH/lua-5.1.5/src/lua" tests/merge_test.lua && "$SCRATCH/lua-5.1.5/src/lua" tests/pure_test.lua && "$SCRATCH/lua-5.1.5/src/lua" tests/tally_test.lua
```
Expected: `Merge tests passed.`, `Pure tests passed.`, `Tally tests passed.` A check that fails only here is a difference the server would hit: fix it in `Merge.lua`.

- [ ] **Step 4: Run every test and commit**

Run: `for t in tests/*_test.lua; do luajit "$t" >/dev/null || echo "FAILED: $t"; done; echo done`
Expected: `done` with no `FAILED` line.

```bash
git add RoadToSixty/RoadToSixty.toc tests/pure_test.lua CLAUDE.md
git commit -m "Merge: load it with the addon and keep it free of game calls (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Notes for later steps

- **Events that mean "first"** can appear twice after merging copies recorded independently, before two PCs were linked: a rare's first kill on each PC, and the `baseline` `gj` and `prof` events each PC logs at its first read. The merge keeps both (Task 5 pins the rare case). Open a follow-up issue: a later tidy step could drop the later of two first kills of one rare, and a baseline event after the same thing was already logged.
- **A hand-copied WTF folder** shares the PC ID; the merge keeps the higher part, so one side's tallied play since the copy goes uncounted (Task 7 pins it). Step 3's sync-folder PC ID avoids this from then on.
- **The caller tidies and checks identity**: Sync.lua (step 3) and the server's `runner.lua` (step 4) run `Tidy.Runs`, `Tidy.Events` and `Tidy.Guilds` on both copies first, check both are the same character, `Prepare` each upload with its device ID, merge, then `Check`.
- **Speed**: the recount decodes every path three times (both copies and the result). The spec makes a full-size merge in game a step 3 test item; measure it there.
- **Strings in the game's Lua**: when two copies hold different strings for one field, Join keeps the larger by `<`, which follows the locale in the game's Lua. Only a tie-break for data that shouldn't differ; the server, in the C locale, is what decides stored versions.
