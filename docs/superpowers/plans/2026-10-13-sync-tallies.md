# Per-PC Tallies (Layout 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The counts the merge can't rebuild from events (time and groups shared with each player met, and how often each rare was killed) are kept per PC, so two PCs' copies of a journey can later be merged by keeping the higher number for each PC.

**Architecture:** Each such count becomes a tally, `{ [PC ID] = count }`, in the place where the number was. A new pure file, `RoadToSixty/Tally.lua`, holds the field list and three plain functions: `Total` (the count shown, the sum of the parts), `Add` (add to one PC's part), and `Upgrade` (turn layout 2 counts into tallies under a given PC). Merge (step 2d) and the server will use the same file. Core.lua makes a random PC ID once, keeps it in the account's saved variables, and moves `DATA_VERSION` to 3.

**Tech Stack:** Lua 5.1 (WoW), LuaJIT for the offline tests.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`, section "Counts that can't be recounted".

## Global Constraints

- Per the spec: "each PC keeps its own numbers under its PC ID, a merge keeps the higher tally for each PC, and the number shown is the sum across PCs." "Without the app, the addon makes a random ID once and keeps it in the account saved variables." "Code that reads these counts goes through one helper that sums the tallies." "This is a data layout change, so `version` goes up with it."
- `Tally.lua` follows the rules for the pure files: plain Lua 5.1, no game calls, never depend on `pairs` order, no `#` on tables with holes. `tests/pure_test.lua` checks it.
- CLAUDE.md: bump `DATA_VERSION` at every change to what is saved, list the change there, and bring older files up in `Upgrade`. Wrap handlers in `ns.SafeCall` (they already are). Comments are plain sentences that explain why, British spelling. Commit subjects `Area: what changed (#1)`.

## The shape, and why

A tally replaces each counted number in place:

- `people[guid].groups`, `seconds`, `raids`, `raidSeconds`, `dungeons`, `raidRuns`: each a tally, or nil for none.
- `rares[key][1]`: a tally. `rares[key]` is an array (`{ count, first kill time, name, npcID, classification }`), so slot 1 always holds a table, never nil.

One small table per field rather than one record per PC: every reader changes by one call (`Tally.Total(p.groups)`), and the merge needs one rule for every field. The cost is size: about 150 bytes more per player met. #36's real level 20 file is 103 KB, so this only matters for players met in raids by the hundred.

`Total` also takes a plain number. Another character's journey copy in the roster (`ns.db.roster[key].journey`) stays at the layout it was saved in until that character logs in, and the map and side panel read it through `ns.view`. Only the logged-in character's copy shares tables with `ns.char`.

## Review Focus

1. Viewing an alt whose roster copy is still layout 2: the side panel's people list, the party card and the rare card must show its counts, not error. Task 1 tests `Total` on a number; Task 3 reads one through `Rares:List`.
2. A file that is part tallies and part numbers (a crash mid-upgrade, or a hand-edited file): `Upgrade` converts the numbers and leaves the tallies alone. Task 1.
3. A rare whose count was 2 at layout 2 must still show "Killed 2 times" and stay first killed first in the list. Task 3, through `rares_test`.
4. The PC ID must survive a reload; a new one each login would split one PC's counts across many IDs. Task 2.
5. A seeded journey (`/rts seed`) must build at the new layout without errors. Task 3, through `seed_test`.

---

### Task 1: Tally.lua

**Files:**
- Create: `RoadToSixty/Tally.lua`
- Test: `tests/tally_test.lua`
- Modify: `tests/pure_test.lua`, `RoadToSixty/RoadToSixty.toc` (after `Parse.lua`), `CLAUDE.md` (layout table), `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`

**Interfaces:**
- Produces:
  - `ns.Tally.PEOPLE`: `{ "groups", "seconds", "raids", "raidSeconds", "dungeons", "raidRuns" }`
  - `ns.Tally.Total(t) -> number`: t a tally, a plain number, or nil
  - `ns.Tally.Add(owner, key, pc, n)`: adds n to `owner[key][pc]`, making the tally if needed
  - `ns.Tally.Upgrade(char, pc)`: layout 2 counts in `char.people` and `char.rares` become tallies under pc. Running it twice changes nothing.

- [ ] **Step 1: Cut the branch**

```bash
git switch dev && git switch -c sync-tallies && git status -sb | head -1
```
Expected: `## sync-tallies`.

- [ ] **Step 2: Write the failing test**

Create `tests/tally_test.lua`:

```lua
-- Offline test of Tally.lua: counts kept per PC add up, and layout 2
-- counts become tallies. Run with LuaJIT from the repo root:
-- luajit tests/tally_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", ns)
local Tally = ns.Tally

-- 1. The count shown is the sum of the PCs' parts. An alt's roster copy may
-- still hold a plain number from layout 2, which reads as it is.
check(Tally.Total(nil) == 0, "no tally reads as 0")
check(Tally.Total({}) == 0, "an empty tally reads as 0")
check(Tally.Total(7) == 7, "a layout 2 number reads as it is")
check(Tally.Total({ a = 2, b = 3 }) == 5, "the PCs' parts add up")

-- 2. Each PC adds to its own part.
local p = {}
Tally.Add(p, "groups", "a", 1)
Tally.Add(p, "groups", "a", 1)
Tally.Add(p, "groups", "b", 1)
check(p.groups.a == 2 and p.groups.b == 1 and Tally.Total(p.groups) == 3, "adds go to each PC's own part")
local rare = { { a = 1 }, 100, "Mor'Ladim" }
Tally.Add(rare, 1, "a", 1)
check(rare[1].a == 2 and rare[3] == "Mor'Ladim", "a rare's count is slot 1")

-- 3. Layout 2 counts become this PC's tallies; tallies already there, and
-- everything else, are left alone.
local char = {
    people = {
        g = { name = "A", groups = 3, seconds = 600, raids = 0, raidSeconds = 0, dungeons = 2, raidRuns = 1 },
        h = { name = "B", groups = { b = 4 }, seconds = 60 },
    },
    rares = { [522] = { 2, 100, "Mor'Ladim", 522, "rare" } },
}
Tally.Upgrade(char, "a")
local g, h, r = char.people.g, char.people.h, char.rares[522]
check(g.groups.a == 3 and g.seconds.a == 600 and g.dungeons.a == 2 and g.raidRuns.a == 1, "counts become this PC's")
check(g.raids == nil and Tally.Total(g.raids) == 0, "a zero count reads as 0")
check(g.name == "A", "the rest of a player is untouched")
check(h.groups.b == 4 and h.groups.a == nil and h.seconds.a == 60, "a half-converted player: numbers convert, tallies stay")
check(type(r[1]) == "table" and Tally.Total(r[1]) == 2, "a rare's count becomes a tally in its place")
check(r[2] == 100 and r[3] == "Mor'Ladim" and r[4] == 522 and r[5] == "rare", "the rest of a rare is untouched")
Tally.Upgrade(char, "b")
check(g.groups.a == 3 and g.groups.b == nil and r[1].b == nil and Tally.Total(r[1]) == 2, "upgrading again changes nothing")
check(pcall(Tally.Upgrade, {}, "a"), "a journey with no people or rares upgrades")

if failures == 0 then
    print("Tally tests passed.")
else
    print(failures .. " tally test(s) failed.")
    os.exit(1)
end
```

- [ ] **Step 3: Run it to see it fail**

Run: `luajit tests/tally_test.lua`
Expected: an error that `RoadToSixty/Tally.lua` can't be opened.

- [ ] **Step 4: Write Tally.lua**

Create `RoadToSixty/Tally.lua`:

```lua
local _, ns = ...

-- Counts the merge can't rebuild from events, kept per PC so two PCs'
-- copies of one journey can be merged (#1). A tally is { [PC ID] = count }:
-- each PC adds only to its own part, a merge keeps the higher part for each
-- PC, and the count shown is the sum. Plain functions with no game calls,
-- so the sync server uses them too.
--
-- Tallies since layout 3 (DATA_VERSION in Core.lua):
--   people[guid].groups, seconds, raids, raidSeconds, dungeons, raidRuns
--   (Groups.lua), nil for none
--   rares[key][1], the times that rare was killed (Rares.lua)

local Tally = {}
ns.Tally = Tally

Tally.PEOPLE = { "groups", "seconds", "raids", "raidSeconds", "dungeons", "raidRuns" }

-- The count a tally shows. Another character's journey copy in the roster
-- stays at the layout it was saved in until that character logs in, so a
-- plain number from layout 2 reads as it is.
function Tally.Total(t)
    if type(t) ~= "table" then return t or 0 end
    local n = 0
    for _, part in pairs(t) do n = n + part end
    return n
end

function Tally.Add(owner, key, pc, n)
    local t = owner[key] or {}
    owner[key] = t
    t[pc] = (t[pc] or 0) + n
end

-- Turns a journey's layout 2 counts into tallies, all counted as pc's.
-- Counts that are already tallies are left alone, so running it again, or
-- on a half-converted journey, is safe.
function Tally.Upgrade(char, pc)
    for _, p in pairs(char.people or {}) do
        for _, key in ipairs(Tally.PEOPLE) do
            if type(p[key]) == "number" then
                p[key] = p[key] ~= 0 and { [pc] = p[key] } or nil
            end
        end
    end
    for _, r in pairs(char.rares or {}) do
        if type(r[1]) == "number" then r[1] = { [pc] = r[1] } end
    end
end
```

- [ ] **Step 5: Run the test**

Run: `luajit tests/tally_test.lua`
Expected: `Tally tests passed.`

- [ ] **Step 6: Keep it pure, load it, list it**

In `tests/pure_test.lua`, change the bytecode list to:

```lua
for _, name in ipairs({ "Packed.lua", "Tidy.lua", "Parse.lua", "Tally.lua" }) do
```

after `Load("Parse.lua", ns)` add `Load("Tally.lua", ns)`, and before `print("Pure tests passed.")` add:

```lua
local counted = { people = { g = { groups = 2 } } }
ns.Tally.Upgrade(counted, "a")
assert(ns.Tally.Total(counted.people.g.groups) == 2)
```

In `RoadToSixty/RoadToSixty.toc`, add the line `Tally.lua` after `Parse.lua`.

In `CLAUDE.md`, change the Parse row and add a Tally row after it:

```markdown
| Parse.lua | reads and writes saved data in the game's format, refusing anything that isn't data (no game calls) |
| Tally.lua | counts kept per PC so journeys from two PCs can merge (no game calls); `tests/pure_test.lua` keeps Packed, Tidy, Parse and Tally pure |
```

In the spec, add `Tally.lua` wherever the pure files are listed:
- under "New files", after the `Tidy.lua` item: ``- `Tally.lua` holds the per-PC tallies (see "Counts that can't be recounted"): the list of tallied fields, the sum shown, and turning older counts into tallies, as plain functions.``
- the heading `### Rules for writing \`Merge.lua\`, \`Parse.lua\`, \`Tidy.lua\` and \`Packed.lua\`` becomes `### Rules for writing \`Merge.lua\`, \`Parse.lua\`, \`Tidy.lua\`, \`Packed.lua\` and \`Tally.lua\``
- the Dockerfile sentence: "copies `Merge.lua`, `Parse.lua`, `Tidy.lua`, `Packed.lua` and `Tally.lua` from"
- the repo tree line: "the addon; Merge.lua, Parse.lua, Tidy.lua, Packed.lua, Tally.lua, Sync.lua added"
- build step 2: "`Packed.lua`, `Tidy.lua`, `Parse.lua`, `Tally.lua` and `Merge.lua` with their tests."
- in "Counts that can't be recounted", the sentence "Code that reads these counts goes through one helper that sums the tallies." becomes "Code that reads these counts goes through `Tally.Total`, which sums the tallies."

Run: `luajit tests/pure_test.lua && luajit tests/release_load.lua RoadToSixty && grep -c "Tally.lua" docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`
Expected: `Pure tests passed.`, `Release load test passed: 46 files loaded from RoadToSixty.`, `5`.

- [ ] **Step 7: Commit**

```bash
git add RoadToSixty/Tally.lua tests/tally_test.lua tests/pure_test.lua RoadToSixty/RoadToSixty.toc CLAUDE.md docs/superpowers/specs/2026-10-12-sync-and-backup-design.md
git commit -m "Tally: counts kept per PC, as plain functions (#1)

The counts the merge can't rebuild from events (time and groups with
each player met, kills of each rare) become { [PC ID] = count }, so a
merge can keep the higher part for each PC. Total also reads a plain
number, since an alt's roster copy stays at its old layout until that
character logs in.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The PC ID and layout 3

**Files:**
- Modify: `RoadToSixty/Core.lua` (header, `DATA_VERSION` and `Upgrade`, the `ADDON_LOADED` handler)
- Test: `tests/core_test.lua`

**Interfaces:**
- Consumes: `ns.Tally.Upgrade(char, pc)` from Task 1.
- Produces: `ns.pc`, this PC's ID (12 hex characters), set at `ADDON_LOADED` before the character file is upgraded and kept in `ns.db.pc`. Step 3 may later set it from the sync folder instead. `DATA_VERSION` is 3.

- [ ] **Step 1: Write the failing tests**

In `tests/core_test.lua`, change `Load` so the account's saved variables can be kept across loads, and load Tally.lua with Core.lua:

```lua
local function Load(saved, db)
    RoadToSixtyDB, RoadToSixtyCharDB = db, saved
    local ns = {}
    assert(loadfile("RoadToSixty/Core.lua"))("RoadToSixty", ns)
    assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", ns)
    script(nil, "ADDON_LOADED", "RoadToSixty")
    return ns
end
```

Change the first check so it pins the new layout:

```lua
check(current == 3, "a new character is on layout 3, got " .. tostring(current))
```

and insert before the summary at the end:

```lua
-- 4. Each PC gets an ID once, kept with the account's saved variables.
ns = Load(nil)
local pc = ns.pc
check(type(pc) == "string" and #pc == 12 and ns.db.pc == pc, "a PC ID is made: " .. tostring(pc))
local db = ns.db
ns = Load(nil, db)
check(ns.pc == pc, "the PC ID is kept across loads")

-- 5. A layout 2 file's counts become this PC's tallies.
ns = Load({
    version = 2,
    people = { g = { name = "A", groups = 3, seconds = 600, raids = 0 } },
    rares = { [522] = { 2, 100, "Mor'Ladim" } },
}, db)
local p, r = ns.char.people.g, ns.char.rares[522]
check(ns.char.version == 3, "a layout 2 file is brought up to layout 3")
check(p.groups[pc] == 3 and p.seconds[pc] == 600 and p.raids == nil and p.name == "A", "a player's counts become tallies")
check(r[1][pc] == 2 and r[3] == "Mor'Ladim", "a rare's count becomes a tally")
check(ns.char.clockFrom == nil, "a layout 2 file was already on the realm's clock")

-- 6. A layout 1 file gets both upgrades at once.
ns = Load({ version = 1, people = { g = { groups = 1 } } }, db)
check(ns.char.clockFrom == 2000 and ns.char.people.g.groups[pc] == 1, "layout 1 gets clockFrom and tallies")
```

- [ ] **Step 2: Run them to see them fail**

Run: `luajit tests/core_test.lua`
Expected: `FAIL: a new character is on layout 3, got 2`, `FAIL: a PC ID is made: nil`, and failures for checks 5 and 6 (or an error in 5 indexing `p.groups[pc]` with pc nil).

- [ ] **Step 3: Make the PC ID and layout 3**

In `RoadToSixty/Core.lua`:

In the header, change "RoadToSixtyDB (ns.db) is account-wide: the settings in defaults below, plus roster (Roster.lua)." to:

```lua
-- Saved variables. RoadToSixtyDB (ns.db) is account-wide: the settings in
-- defaults below, plus roster (Roster.lua) and pc, this PC's ID (ns.pc), which
-- counts the merge can't rebuild are kept under (Tally.lua).
```

(keep the rest of that header paragraph as it is).

Change the layout history, `DATA_VERSION` and `Upgrade`:

```lua
-- Layout of RoadToSixtyCharDB; bump it at every change to what is saved
-- or what it means, and bring older files up in Upgrade.
--   1  everything up to 1.8.0 (fields were only ever added)
--   2  times are by the realm's clock (ns.Now). Times in a journey begun
--      earlier are by that PC's clock before clockFrom.
--   3  the counts the merge can't rebuild are tallies by PC (Tally.lua):
--      people[guid] groups, seconds, raids, raidSeconds, dungeons and
--      raidRuns, and rares[key][1]. Older counts become this PC's.
local DATA_VERSION = 3

-- Brings a character file saved by an older layout up to DATA_VERSION.
local function Upgrade(char)
    if char.version < 2 then
        char.clockFrom = ns.Now()
    end
    if char.version < 3 then
        ns.Tally.Upgrade(char, ns.pc)
    end
    char.version = DATA_VERSION
end
```

In the `ADDON_LOADED` handler, after `ns.db = RoadToSixtyDB`, add:

```lua
    ns.db.pc = ns.db.pc or ("%06x%06x"):format(math.random(0, 0xffffff), math.random(0, 0xffffff))
    ns.pc = ns.db.pc
```

- [ ] **Step 4: Run the tests**

Run: `luajit tests/core_test.lua && luajit tests/clock_test.lua`
Expected: `Core tests passed.` and `Clock tests passed.`

- [ ] **Step 5: Commit**

```bash
git add RoadToSixty/Core.lua tests/core_test.lua
git commit -m "Core: a PC ID, and layout 3 with counts as tallies by PC (#1)

Each PC makes a random ID once and keeps it with the account's saved
variables. Older files' counts become that PC's tallies.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Count and read through tallies

**Files:**
- Modify: `RoadToSixty/Groups.lua` (header lines 28-32, `Meet` 98-118, `Part` 120-131, `CountRun` 309-320, the `/rts people` debug command 349-367)
- Modify: `RoadToSixty/Rares.lua` (header line 11, `Record` 141-153, the card at 442-443, `Rares:List` 479-486)
- Modify: `RoadToSixty/Parties.lua` (187, 286-288, 438, 476), `RoadToSixty/Panel.lua` (929), `RoadToSixty/Seed.lua` (995-999, 1019, 1034)
- Test: `tests/rares_test.lua`, `tests/seed_test.lua`

**Interfaces:**
- Consumes: `ns.Tally.Total`, `ns.Tally.Add` from Task 1; `ns.pc` from Task 2.

- [ ] **Step 1: Make rares_test expect tallies (failing)**

In `tests/rares_test.lua`, just before `assert(loadfile("RoadToSixty/Rares.lua"))("RoadToSixty", ns)`, add:

```lua
ns.pc = "testpc"
assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", ns)
```

Change the check at line 142 to:

```lua
check(Count() == 4 and ns.Tally.Total(ns.char.rares[522][1]) == 2 and ns.char.rares[522][1].testpc == 2,
    "second kill counted only, as this PC's")
```

Before the summary at the end, add a rare from an alt's layout 2 roster copy:

```lua
-- A rare in an alt's roster copy, still at layout 2, lists with its count.
local shown = ns.view
ns.view = { rares = { [1] = { 3, 50, "Old Rare", 1, "rare" } } }
local old = Rares:List()
check(old[1][1] == "Old Rare" and old[1][2] == 3, "a layout 2 count still lists")
ns.view = shown
```

In `tests/seed_test.lua`, after `ns.Now = function() return time() end`, add `ns.pc = "seedpc"`.

Run: `luajit tests/rares_test.lua`
Expected: `FAIL: second kill counted only, as this PC's` (Rares.lua still adds to a number).

- [ ] **Step 2: Rares.lua**

Header, line 11-12: change "key -> { count, first kill time, name, npcID, classification }" to "key -> { count (a tally by PC, see Tally.lua), first kill time, name, npcID, classification }".

In `Record`, change

```lua
    if known then
        known[1] = known[1] + 1
```

to

```lua
    if known then
        ns.Tally.Add(known, 1, ns.pc, 1)
```

and the new entry to

```lua
    rares[key] = { { [ns.pc] = 1 }, ns.Now(), name, info.npc, info.class }
```

The card (line 442-443):

```lua
    local known = ns.view.rares and ns.view.rares[e[9] or e[6] or ""]
    local kills = known and ns.Tally.Total(known[1]) or 0
    if kills > 1 then lines[#lines + 1] = ("Killed %d times"):format(kills) end
```

`Rares:List`: change `r[1]` in the list entry to `ns.Tally.Total(r[1])`.

Run: `luajit tests/rares_test.lua`
Expected: `rares_test: ok`.

- [ ] **Step 3: Groups.lua**

Header (lines 28-32): change the people line so it reads:

```lua
-- ns.char.people is everyone grouped with: guid -> { name, race, sex,
-- class, level, guild (last seen), first, last (times), c, x, y (where first
-- met), and these tallies by PC (Tally.lua), nil for none: groups, seconds
-- (party groups shared, time in them), raids, raidSeconds (the same for
-- raids), dungeons, raidRuns (dungeon and raid instances run together, by
-- the instance's type) }.
```

In `Meet`, delete the two lines

```lua
    p.groups, p.seconds, p.dungeons = p.groups or 0, p.seconds or 0, p.dungeons or 0
    p.raids, p.raidSeconds, p.raidRuns = p.raids or 0, p.raidSeconds or 0, p.raidRuns or 0
```

and change the count at the end to

```lua
    if newGroup == "raid" then
        ns.Tally.Add(p, "raids", ns.pc, 1)
    elseif newGroup then
        ns.Tally.Add(p, "groups", ns.pc, 1)
    end
```

In `Part`:

```lua
        if kind == "raid" then
            ns.Tally.Add(p, "raidSeconds", ns.pc, seconds)
        else
            ns.Tally.Add(p, "seconds", ns.pc, seconds)
        end
```

In `Groups:CountRun`:

```lua
            if raid then
                ns.Tally.Add(p, "raidRuns", ns.pc, 1)
            else
                ns.Tally.Add(p, "dungeons", ns.pc, 1)
            end
```

In the `/rts people` command, add `local T = ns.Tally.Total` as its first line and change the format arguments to

```lua
            tostring(p.level), T(p.groups), math.floor(T(p.seconds) / 60), T(p.dungeons),
            T(p.raids), math.floor(T(p.raidSeconds) / 60), T(p.raidRuns), date("%d %b %H:%M", p.first)))
```

- [ ] **Step 4: Parties.lua and Panel.lua**

Parties.lua line 187:

```lua
            return p and ns.Tally.Total(p.groups) or 0
```

Parties.lua `Parties:People`, the sort:

```lua
    local Total = ns.Tally.Total
    -- Parties first: raid members are mostly people met once.
    table.sort(list, function(a, b)
        local pa, pb = a[2], b[2]
        if Total(pa.groups) ~= Total(pb.groups) then return Total(pa.groups) > Total(pb.groups) end
        if Total(pa.seconds) ~= Total(pb.seconds) then return Total(pa.seconds) > Total(pb.seconds) end
        return Total(pa.raids) > Total(pb.raids)
    end)
```

Parties.lua line 438:

```lua
        local groups = p and (ns.Tally.Total(p.groups) + ns.Tally.Total(p.raids)) or 0
```

Parties.lua line 476:

```lua
            if p and ns.Tally.Total(p.groups) > 0 then list[#list + 1] = entry end
```

Panel.lua line 929:

```lua
            GameTooltip:AddDoubleLine(p.name or "?", ("%d groups, %s"):format(ns.Tally.Total(p.groups),
                FormatDuration(ns.Tally.Total(p.seconds))), r, g, b, 1, 1, 1)
```

This replaces both lines of the original call (929-930).

- [ ] **Step 5: Seed.lua**

Lines 995-999, the seeded party members:

```lua
                G.char.people[guid] = {
                    name = d[1], race = d[2], sex = d[3], class = d[4], level = G.level,
                    first = G.t, last = G.t, c = G.c, x = round(G.x), y = round(G.y),
                    groups = { [ns.pc] = 1 },
                }
```

Line 1019:

```lua
            G.char.rares = { ["Seeded Dreadmaw"] = { { [ns.pc] = 1 }, G.t, "Seeded Dreadmaw", nil, "rareelite" } }
```

Line 1034:

```lua
                p.seconds, p.last = { [ns.pc] = duration }, G.t
```

- [ ] **Step 6: No raw reads left**

Run: `grep -nE "\.(groups|seconds|raids|raidSeconds|dungeons|raidRuns)\b|known\[1\]|r\[1\]" RoadToSixty/Groups.lua RoadToSixty/Parties.lua RoadToSixty/Panel.lua RoadToSixty/Rares.lua RoadToSixty/Seed.lua`
Expected: every line found passes the value to `ns.Tally.Total`, `ns.Tally.Add` or `T(...)`, builds a new tally (`{ [ns.pc] = ... }`), or is a different table's field (in Seed.lua, `G.party`-style or event fields). Any other hit is a missed reader: fix it.

- [ ] **Step 7: Run every test and commit**

Run: `for t in tests/*_test.lua; do luajit "$t" >/dev/null || echo "FAILED: $t"; done; luajit tests/release_load.lua RoadToSixty; echo done`
Expected: `Release load test passed: 46 files loaded from RoadToSixty.` and `done`, with no `FAILED` line.

```bash
git add RoadToSixty/Groups.lua RoadToSixty/Rares.lua RoadToSixty/Parties.lua RoadToSixty/Panel.lua RoadToSixty/Seed.lua tests/rares_test.lua tests/seed_test.lua
git commit -m "Groups, Rares: count per PC and read counts through Tally.Total (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 8: In game (Jordan)**

`/reload` on the beta with the dev install on `dev`. Check: the side panel's "Grouped with most" tooltip shows the same counts as before; a party card lists the players grouped with before; a rare killed twice shows "Killed 2 times"; viewing an alt that hasn't logged in since shows its people and rares without errors. `/rts people` lists the same numbers as before the update.

---

## Notes for later steps

- Copying a WTF folder by hand copies the account file, and with it the PC ID. Two PCs then share one ID, and a merge keeps the higher of their parts, so the counts from one of them after the copy are lost. Step 3, where the PC ID comes from the sync folder, fixes this going forward; the Merge plan (2d) should say so.
- The server has to bring layout 2 uploads up to layout 3 before merging, with `Tally.Upgrade(char, pc)`. It needs that upload's device ID as `pc`, so the device ID has to reach `runner.lua` in step 4.
- Merge (2d) keeps the higher part per PC for every field in `Tally.PEOPLE` and for `rares[key][1]`, and the server's check that no tally went down compares parts per PC, not totals.
