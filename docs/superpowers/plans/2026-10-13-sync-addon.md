# Sync.lua Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At login the addon brings in the journey the app left in the `RoadToSixty_Sync` folder: merged into what this PC has, or put in its place for a restore.

**Architecture:** The app's folder sets one global, `RoadToSixtySync`, before the addon loads. Core takes this PC's ID from it. `Sync.lua` has one function, `Sync.Apply(char, entry)`, that parses, prepares, tidies, merges and checks without touching the game, plus a `PLAYER_LOGIN` handler. That handler runs before every other module's login work and copies the result into the character's own saved table. `/rts check` shows what happened and how long it took. A LuaJIT script makes a sync folder by hand so this can be tried in game before the app exists.

**Tech Stack:** Lua 5.1 (WoW), LuaJIT for the offline tests, PUC Lua 5.1 for the timing run.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`, sections "The sync folder", "At login", "Testing" (Sync, addon side; In game), and the risk "Login merge time".

## Global Constraints

- The app owns `Interface/AddOns/RoadToSixty_Sync/`: `RoadToSixty_Sync.toc` (its `Interface` copied from `RoadToSixty.toc`) and `data.lua`, setting one global with the PC's ID and, per character, the version ID, a replace flag and the journey as one long string (spec).
- `RoadToSixty.toc` lists `RoadToSixty_Sync` under `## OptionalDeps` (spec).
- At login: only a version newer than `ns.char.syncedVersion` is used; replace flag means replace, otherwise merge; then `syncedVersion` is set; then the usual login tidy runs over the result (spec).
- The addon never runs code from outside: the journey is text, read only by `Parse.Read` (spec, "The addon").
- Nothing the sync brings in may lose this PC's journey. If the entry can't be read, is refused, or the merge fails its check, the character's data stays exactly as it was and the player is told.
- Use `ns.Now()`, never `time()`, outside developer tools. Wrap handlers through `ns.On`. Comments are plain sentences that explain why, in British spelling. Commit subjects are `Area: what changed (#1)`.
- Never commit a real SavedVariables file or anything made from one. They hold other players' names and GUIDs, and the repo is public.

## Decisions the spec leaves open

- **The `data.lua` format**, which step 5's app writes:
  ```lua
  RoadToSixtySync = {
      pc = "3f9a1c2b7d4e",        -- optional: this PC's ID, letters, digits and '-', at most 64
      chars = {
          ["Name-Realm"] = {        -- Roster:Key(): UnitName("player") .. "-" .. GetRealmName()
              version = 42,         -- the server's version number for this character; higher is newer
              replace = true,       -- optional: a restore
              journey = "...",      -- Parse.Write text of the journey
          },
      },
  }
  ```
- **"Newer" means a larger number.** `version` is a number. It is used when it is above `syncedVersion` (or when there is none). Step 4's server must give each character's versions increasing numbers (Postgres `bigserial` ids do).
- **When: `PLAYER_LOGIN`, first after Core.** `Sync.lua` loads just after `Merge.lua`, so its `PLAYER_LOGIN` handler runs before the tidy (`Journal.lua:258`), the roster rebuild (`Roster.lua:133`) and the recorder's start (`Recorder.lua:317`). The name and realm, and `C_Map` for the tidy, are sure to be ready by then. The loading screen is still up, so a slow merge lengthens it rather than freezing play. This goes on the in-game check list.
- **The PC ID** from the folder replaces `ns.db.pc` for good, in Core, before `Upgrade` uses it. Without the app the addon keeps the ID it made. Parts counted under an old ID stay in the tallies and still add up.
- **The character's table is kept.** The result is copied into `ns.char` (`wipe` and copy, as `ResetCharacter` does), so `RoadToSixtyCharDB`, `ns.char` and `ns.view` stay one table. The copy keeps this addon's `addon` value, and sets `syncedVersion` and clears `rosterBuilt` so the roster copy is rebuilt.
- **Before merging, both copies are tidied the way a login does** (`Tidy.Runs` and `Tidy.Guilds` unless seeded, and `Tidy.Events` with `ns.IsPlaceMap`). The incoming copy is also put through `Merge.Prepare`. The merge copes with missing parts, and the login fills in the character defaults after copying the result in.
- **`Merge.Check` runs on every login merge.** A failed check is a problem, never a half-applied result.
- **A problem leaves `syncedVersion` alone**, so the next login tries again (after an addon update, say). The red line shows at every login until then. A crash before logout redoes a successful merge at the next login, which is harmless because merging the same version twice changes nothing.
- **`syncedVersion` doesn't bump `DATA_VERSION`.** It's a field added as nil, which older addons and `Merge.lua` ignore. The merge treats it as current state, and the login sets it anyway. No release has layout 3 yet. The header lists the field.
- **`Tidy.Runs` looked ahead from every event**, so a long stretch without dungeons took time that grows with the square of its length: 5 s per copy on a made-up 3 MB journey in PUC Lua 5.1, at every login, before sync existed. Only leaving an instance can start a split run, so Task 2 makes it look ahead only from there. The result is the same.
- **Merge time:** the login records the milliseconds and `/rts check` shows them. A PUC Lua 5.1 run on a made-up 3 MB journey gives the first number. Spreading the work over frames waits until a measured time calls for it.

## Review Focus

1. A `/reload` after a restore, with the same `data.lua` still there: nothing is replaced again, so play since the restore stays. Task 4 tests it.
2. A journey string that is broken, holds code, or crashes the merge: the character is untouched, the player sees one red line, nothing is raised into the game's error frame, and the next login tries again. Tasks 3 and 4.
3. A sync folder for other characters only, or with no `chars`: nothing changes, and `/rts check` says so. Task 4.
4. A journey from a newer layout (a newer addon elsewhere): refused with "Update the addon on this PC". Task 3.
5. A seeded test character on this PC: the merge is refused and the fake journey stays as it is. Task 3.

---

### Task 1: Core: the PC ID from the sync folder, and character defaults for Sync

**Files:**
- Modify: `RoadToSixty/Core.lua` (header, the PC ID lines in `ADDON_LOADED`, a new `ns.CharDefaults`), `.luarc.json`
- Test: `tests/core_test.lua` (insert before `if failures == 0 then`)

**Interfaces:**
- Produces: `ns.CharDefaults(char)`, which fills in a journey's missing parts as a new character's; `ns.pc` taken from `RoadToSixtySync.pc` when it is valid.

- [ ] **Step 1: Cut the branch**

```bash
git switch dev && git switch -c sync-addon && git status -sb | head -1
```
Expected: `## sync-addon`.

- [ ] **Step 2: Write the failing tests**

Insert into `tests/core_test.lua` before `if failures == 0 then`:

```lua
-- 7. The app's sync folder names the PC, and that ID is kept even without it.
RoadToSixtySync = { pc = "app-000000000001" }
ns = Load({ version = 2, people = { g = { groups = 2 } } }, db)
check(ns.pc == "app-000000000001" and ns.db.pc == ns.pc, "the sync folder's PC ID is used: " .. tostring(ns.pc))
check(ns.char.people.g.groups["app-000000000001"] == 2, "and an upgrade counts under it")
RoadToSixtySync = { pc = "not an ID!" }
ns = Load(nil, db)
check(ns.pc == "app-000000000001", "a PC ID with other characters is ignored")
RoadToSixtySync = { pc = ("a"):rep(65) }
ns = Load(nil, db)
check(ns.pc == "app-000000000001", "a PC ID over 64 characters is ignored")
RoadToSixtySync = nil
ns = Load(nil, db)
check(ns.pc == "app-000000000001", "the ID is kept without the folder")

-- 8. CharDefaults fills in a journey's missing parts, keeping what it has.
local bare = { version = 3, events = { { 1, "on" } } }
ns.CharDefaults(bare)
check(bare.totals.kills == 0 and bare.kills.d == "" and bare.people and #bare.events == 1 and bare.version == 3,
    "CharDefaults fills in a journey")
```

- [ ] **Step 3: Run them to see them fail**

Run: `luajit tests/core_test.lua`
Expected: the five `FAIL:` lines of section 7, from `FAIL: the sync folder's PC ID is used: ...` to `FAIL: the ID is kept without the folder`, then an error calling `CharDefaults`, a nil value.

- [ ] **Step 4: Write it**

In `RoadToSixty/Core.lua`:

In the header, change

```lua
-- Saved variables. RoadToSixtyDB (ns.db) is account-wide: the settings in
-- defaults below, plus roster (Roster.lua) and pc, this PC's ID (ns.pc),
-- which counts the merge can't rebuild are kept under (Tally.lua).
```

to

```lua
-- Saved variables. RoadToSixtyDB (ns.db) is account-wide: the settings in
-- defaults below, plus roster (Roster.lua) and pc, this PC's ID (ns.pc),
-- which counts the merge can't rebuild are kept under (Tally.lua). The
-- app's sync folder gives the ID; without the app the addon makes one.
```

and after the `clockFrom` lines

```lua
--   clockFrom  when a journey begun before layout 2 moved to the realm's
--              clock (see DATA_VERSION)
```

add

```lua
--   syncedVersion  the sync folder version last brought in (Sync.lua)
```

In the `ADDON_LOADED` handler, change

```lua
    ns.db.pc = ns.db.pc or ("%06x%06x"):format(math.random(0, 0xffffff), math.random(0, 0xffffff))
```

to

```lua
    local synced = type(RoadToSixtySync) == "table" and RoadToSixtySync.pc
    if type(synced) == "string" and #synced <= 64 and synced:match("^[%w%-]+$") then
        ns.db.pc = synced
    end
    ns.db.pc = ns.db.pc or ("%06x%06x"):format(math.random(0, 0xffffff), math.random(0, 0xffffff))
```

After the `ADDON_LOADED` handler's closing `end)`, add

```lua
-- Fills in what a journey is missing as a new character's would have, for
-- a journey that came from the sync folder.
function ns.CharDefaults(char)
    ApplyDefaults(char, charDefaults)
end
```

In `.luarc.json`, add `"RoadToSixtySync",` after `"RoadToSixtyCharDB",` in `diagnostics.globals`.

- [ ] **Step 5: Run the test**

Run: `luajit tests/core_test.lua`
Expected: `Core tests passed.`

- [ ] **Step 6: Commit**

```bash
git add RoadToSixty/Core.lua tests/core_test.lua .luarc.json
git commit -m "Core: take the PC ID from the sync folder, and share character defaults (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Tidy.Runs looks ahead only from leaving an instance

**Files:**
- Modify: `RoadToSixty/Tidy.lua` (`Tidy.Runs`)
- Test: `tests/tidy_test.lua` (insert before `if failures == 0 then`)

**Interfaces:**
- Produces: `Tidy.Runs(char)`, unchanged in what it does.

- [ ] **Step 1: Write the failing test**

Insert into `tests/tidy_test.lua` before `if failures == 0 then`:

```lua
-- 5. Runs looks ahead only from leaving an instance, so a long journey with
-- no dungeons tidies at once. Looking ahead from every event took time
-- growing with the square of the journey's length: seconds at every login.
local long = { events = {} }
for i = 1, 100000 do long.events[i] = { i, "loot", 0, 0, 0, i } end
local started = os.clock()
Tidy.Runs(long)
local took = os.clock() - started
check(took < 0.5 and #long.events == 100000, ("100,000 events without dungeons tidied in %.2f s"):format(took))
```

- [ ] **Step 2: Run it to see it fail**

Run: `luajit tests/tidy_test.lua`
Expected: `FAIL: 100,000 events without dungeons tidied in ... s`, with several seconds.

- [ ] **Step 3: Look ahead only from an "out"**

In `RoadToSixty/Tidy.lua`, in `Tidy.Runs`, change

```lua
        local out = events[i]
        local back = events[i + 1]
```

to

```lua
        local out = events[i]
        -- Only leaving an instance can start a split run.
        local back = out[2] == "out" and events[i + 1] or nil
```

With `back` nil, the scan is skipped and the `if` below goes to its `i = i + 1`, as it did for these events before.

- [ ] **Step 4: Run the tests**

Run: `luajit tests/tidy_test.lua && luajit tests/runs_test.lua && luajit tests/journal_test.lua`
Expected: `Tidy tests passed.` and the other two pass as before.

- [ ] **Step 5: Commit**

```bash
git add RoadToSixty/Tidy.lua tests/tidy_test.lua
git commit -m "Tidy: look for split runs only from leaving an instance (#1)

Runs looked ahead from every event to the next instance event, so a
long stretch without dungeons took time growing with its length
squared: about 5 s at every login on a made-up 3 MB journey in
standard Lua 5.1. Only an out can start a split run, and the result is
the same.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Sync.Apply: what a sync folder entry does to a journey

**Files:**
- Create: `RoadToSixty/Sync.lua`, `tests/sync_test.lua`
- Modify: `RoadToSixty/RoadToSixty.toc` (`Sync.lua` after `Merge.lua`)

**Interfaces:**
- Consumes: `ns.Parse.Read(s)` (errors on bad input); `ns.Merge.VERSION`, `ns.Merge.Prepare(char, pc) -> char | nil, why`, `ns.Merge.Merge(a, b) -> journey | nil, why`, `ns.Merge.Check(a, b, out) -> true | false, why`; `ns.Tidy.Runs(char)`, `ns.Tidy.Events(journey, isPlace)`, `ns.Tidy.Guilds(char)`; `ns.IsPlaceMap`, `ns.pc`.
- Produces: `ns.Sync`, and `Sync.Apply(char, entry) -> what, value`, where `what` is `"same"`, `"merged"` (value: the merged journey), `"replaced"` (value: the incoming journey) or `"problem"` (value: why, a sentence without a final full stop). `Sync.Apply` tidies `char` in place and changes nothing else in it.

- [ ] **Step 1: Write the failing tests**

Create `tests/sync_test.lua`:

```lua
-- Offline test of Sync.lua with a fake WoW API: what an entry in the app's
-- sync folder does to a journey (merged, replaced, already brought in or
-- refused), and the login that applies it. Run with LuaJIT from the repo
-- root: luajit tests/sync_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        io.write("FAIL: ", message, "\n")
    end
end

-- The game API the loaded files use, faked.
local script
CreateFrame = function()
    return {
        RegisterEvent = function() end,
        SetScript = function(_, _, fn) script = fn end,
    }
end
SlashCmdList = {}
CopyTable = function(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = type(v) == "table" and CopyTable(v) or v end
    return copy
end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
time = function() return 1000 end
GetServerTime = function() return 2000 end
C_AddOns = { GetAddOnMetadata = function(_, field) return field == "Version" and "9.9.9" or nil end }
C_Map = { GetMapInfo = function(mapID) return { mapType = mapID == 1415 and 2 or 3 } end }
Enum = { UIMapType = { Continent = 2 } }
UnitName = function() return "Ann" end
GetRealmName = function() return "Test Realm" end
local clock = 0
debugprofilestop = function() clock = clock + 7 return clock end
local raised = {}
geterrorhandler = function() return function(err) raised[#raised + 1] = err end end
local said = {}
print = function(text) said[#said + 1] = text end

local FILES = { "Core.lua", "Packed.lua", "Tidy.lua", "Parse.lua", "Tally.lua", "Merge.lua", "Sync.lua" }

-- Loads the addon's files with these saved variables and sync folder, as
-- the game does up to ADDON_LOADED.
local function Load(saved, sync)
    RoadToSixtyDB, RoadToSixtyCharDB, RoadToSixtySync = { greet = false }, saved, sync
    local ns = {}
    for _, name in ipairs(FILES) do assert(loadfile("RoadToSixty/" .. name))("RoadToSixty", ns) end
    -- Roster.lua needs much more of the game to load; this is its Key.
    ns.Roster = { Key = function() return UnitName("player") .. "-" .. GetRealmName() end }
    script(nil, "ADDON_LOADED", "RoadToSixty")
    return ns
end

local ns = Load(nil)
local Sync, Write = ns.Sync, ns.Parse.Write

local function Same(a, b) return Write(a) == Write(b) end

-- A journey at layout 3, with the defaults and the fields given.
local function Journey(fields)
    local j = { version = 3 }
    ns.CharDefaults(j)
    for k, v in pairs(fields or {}) do j[k] = v end
    return j
end

local function Session(t) return { { t, "on", 0, 0, 0, 10 }, { t + 60, "die", 0, 0, 0 }, { t + 120, "off", 0, 0, 0 } } end
local function Both(a, b)
    local all = {}
    for _, e in ipairs(a) do all[#all + 1] = e end
    for _, e in ipairs(b) do all[#all + 1] = e end
    return all
end
local here = Session(1000)       -- played on this PC
local there = Session(5000)      -- played on another PC

-- 1. Merged: play from both PCs, checked, and the totals recounted.
local char = Journey({ events = Session(1000), totals = { deaths = 1 } })
local what, out = Sync.Apply(char, { version = 5, journey = Write(Journey({ events = Session(5000), totals = { deaths = 1 } })) })
check(what == "merged" and #out.events == 6 and out.totals.deaths == 2, "a newer version is merged: " .. tostring(what) .. " " .. tostring(out))
check(Same(out.events, Both(here, there)), "both PCs' sessions, in time order")
check(#char.events == 3, "the journey given is not changed")

-- 2. Replaced: a restore takes the incoming journey whole.
what, out = Sync.Apply(Journey({ events = Both(here, there) }), { version = 6, replace = true, journey = Write(Journey({ events = Session(1000) })) })
check(what == "replaced" and Same(out.events, here), "a restore replaces: " .. tostring(what))

-- 3. Already brought in: the same version, or an older one.
char = Journey({ events = Session(1000), syncedVersion = 6 })
check(Sync.Apply(char, { version = 6, journey = "not even read" }) == "same", "the version already brought in")
check(Sync.Apply(char, { version = 4, replace = true, journey = "not even read" }) == "same", "an older version")

-- 4. Entries that can't be used, each with a reason.
local function Problem(entry, local_)
    local w, why = Sync.Apply(local_ or Journey({ events = Session(1000) }), entry)
    return w == "problem" and type(why) == "string" and why or nil
end
check(Problem({ journey = Write(Journey()) }), "an entry without a version")
check(Problem({ version = "7", journey = Write(Journey()) }), "a version that isn't a number")
check(Problem({ version = 7 }), "an entry without a journey")
check(Problem({ version = 7, journey = "{ [1] = 1" }), "a cut-off journey")
check(Problem({ version = 7, journey = '{ ["x"] = os.exit() }' }), "a journey holding code")
check(Problem({ version = 7, journey = '"just a string"' }), "a journey that isn't a table")
local newer = Problem({ version = 7, journey = Write(Journey({ version = 4 })) })
check(newer and newer:find("Update the addon on this PC"), "a newer layout asks for an update: " .. tostring(newer))
check(Problem({ version = 7, journey = Write(Journey({ version = 1 })) }), "a layout from before the realm's clock")
local seeded = Journey({ events = Session(1000), seeded = true })
check(Problem({ version = 7, journey = Write(Journey({ events = Session(5000) })) }, seeded), "a seeded character is not merged into")
check(#seeded.events == 3 and seeded.seeded, "and keeps its fake journey")
local realCheck = ns.Merge.Check
ns.Merge.Check = function() return false, "the session at 1000 is missing" end
check(Problem({ version = 7, journey = Write(Journey({ events = Session(5000) })) }) == "the session at 1000 is missing",
    "a merge that fails its check is not used")
ns.Merge.Check = realCheck

-- 5. Both copies are tidied as a login would before merging: a continent
-- logged as a zone goes, and a death logged twice in one second counts once.
char = Journey({ events = { { 1000, "on", 0, 0, 0, 10 }, { 1010, "zone", 0, 0, 0, 1415 } } })
what, out = Sync.Apply(char, { version = 8, journey = Write(Journey({
    events = { { 5000, "on", 0, 0, 0, 10 }, { 5060, "die", 0, 0, 0 }, { 5060, "die", 0, 0, 0 } },
    totals = { deaths = 2 },
})) })
check(what == "merged" and #out.events == 3 and out.totals.deaths == 1, "both copies tidied before the merge")

-- 6. An incoming journey at layout 2 is brought up, its counts under this PC.
what, out = Sync.Apply(Journey({ events = Session(1000) }), { version = 9, journey = Write({ version = 2, events = Session(5000),
    people = { g = { groups = 2 } } }) })
check(what == "merged" and out.people.g.groups[ns.pc] == 2, "a layout 2 journey is prepared")

if failures == 0 then
    io.write("Sync tests passed.\n")
else
    io.write(failures, " sync test(s) failed.\n")
    os.exit(1)
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `luajit tests/sync_test.lua`
Expected: an error that `RoadToSixty/Sync.lua` can't be opened.

- [ ] **Step 3: Write Sync.Apply**

Create `RoadToSixty/Sync.lua`:

```lua
local _, ns = ...

-- Brings in the journey the Road to Sixty app left in the sync folder
-- (#1): merged into what this PC has, or, for a restore picked on the
-- website, put in its place. The app owns Interface/AddOns/RoadToSixty_Sync,
-- which RoadToSixty.toc lists under OptionalDeps so it loads first. Its
-- data.lua sets one global:
--
--   RoadToSixtySync = {
--       pc = "3f9a1c2b7d4e",       -- optional: this PC's ID (Core.lua uses it)
--       chars = {
--           ["Name-Realm"] = {     -- Roster:Key()
--               version = 42,      -- the server's version number; higher is newer
--               replace = true,    -- optional: a restore
--               journey = "...",   -- the journey as Parse.Write text
--           },
--       },
--   }
--
-- The journey is text read only by Parse.Read, which refuses code, so
-- nothing from outside ever runs.

local Sync = {}
ns.Sync = Sync

-- The repairs a login makes (Journal.lua and Guilds.lua run the same),
-- done to both copies first so the merge compares like with like.
local function TidyUp(char)
    if not char.seeded then ns.Tidy.Runs(char) end
    ns.Tidy.Events(char, ns.IsPlaceMap)
    if not char.seeded then ns.Tidy.Guilds(char) end
end

-- What a sync folder entry does to char, the journey this PC saved: "same"
-- when that version was already brought in; "merged" or "replaced" with
-- the journey to keep; "problem" with why it can't be used. Tidies char in
-- place, as the login would anyway, and changes nothing else in it.
function Sync.Apply(char, entry)
    if type(entry) ~= "table" or type(entry.version) ~= "number" then
        return "problem", "the sync folder's entry has no version number"
    end
    if char.syncedVersion and entry.version <= char.syncedVersion then return "same" end
    if type(entry.journey) ~= "string" then return "problem", "the sync folder's entry has no journey" end
    local ok, journey = pcall(ns.Parse.Read, entry.journey)
    if not ok then return "problem", "the synced journey can't be read (" .. tostring(journey) .. ")" end
    if type(journey) ~= "table" then return "problem", "the synced journey isn't a journey" end
    if (tonumber(journey.version) or 0) > ns.Merge.VERSION then
        return "problem", "it was saved by a newer Road to Sixty. Update the addon on this PC"
    end
    local why
    journey, why = ns.Merge.Prepare(journey, ns.pc)
    if not journey then return "problem", why end
    TidyUp(char)
    TidyUp(journey)
    if entry.replace then return "replaced", journey end
    local out
    out, why = ns.Merge.Merge(char, journey)
    if not out then return "problem", why end
    local passed, failed = ns.Merge.Check(char, journey, out)
    if not passed then return "problem", failed end
    return "merged", out
end
```

In `RoadToSixty/RoadToSixty.toc`, add the line `Sync.lua` after `Merge.lua`.

- [ ] **Step 4: Run the test**

Run: `luajit tests/sync_test.lua && luajit tests/release_load.lua RoadToSixty`
Expected: `Sync tests passed.` and `Release load test passed: 48 files loaded from RoadToSixty.`

- [ ] **Step 5: Commit**

```bash
git add RoadToSixty/Sync.lua RoadToSixty/RoadToSixty.toc tests/sync_test.lua
git commit -m "Sync: what an entry in the sync folder does to a journey (#1)

Parsed, prepared, tidied as a login would, then merged and checked, or
taken whole for a restore. Anything it can't use comes back as a
problem with a reason, and the journey is left as it was.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The login: apply it, say so, and show it in /rts check

**Files:**
- Modify: `RoadToSixty/Sync.lua` (append), `RoadToSixty/Health.lua`, `RoadToSixty/RoadToSixty.toc` (`## OptionalDeps`), `CLAUDE.md`
- Test: `tests/sync_test.lua` (insert before `if failures == 0 then`)

**Interfaces:**
- Consumes: `Sync.Apply` (Task 3); `ns.CharDefaults` (Task 1); `ns.Roster:Key()`; `ns.Print`; `debugprofilestop`.
- Produces: `Sync.found` (a sync folder was there), `Sync.status` (`{ what, version, ms, why }`, nil when the folder had nothing for this character), `Sync:Describe() -> string` for `/rts check`.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/sync_test.lua` before `if failures == 0 then`:

```lua
-- 7. At login: the entry for this character is applied into the same
-- table, so everything holding ns.char keeps seeing it.
local function Login() script(nil, "PLAYER_LOGIN") end
local function Folder(entry, key) return { chars = { [key or "Ann-Test Realm"] = entry } } end

local saved = Journey({ events = Session(1000), totals = { deaths = 1 }, rosterBuilt = 3 })
local folder = Folder({ version = 5, journey = Write(Journey({ events = Session(5000), totals = { deaths = 1 }, addon = "1.0.0" })) })
ns = Load(saved, folder)
said = {}
Login()
check(ns.char == saved and RoadToSixtyCharDB == saved and ns.view == saved, "the result goes into the same table")
check(Same(saved.events, Both(here, there)) and saved.totals.deaths == 2, "this PC's play and the other PC's, merged")
check(saved.syncedVersion == 5 and saved.rosterBuilt == nil and saved.addon == "9.9.9",
    "syncedVersion set, the roster copy to be rebuilt, this addon's version kept")
check(RoadToSixtySync == nil, "the folder's data is let go once read")
check(said[1] and said[1]:find("other PCs"), "the player is told: " .. tostring(said[1]))
check(ns.Sync:Describe():find("merged version 5") and ns.Sync:Describe():find("7 ms"), "/rts check says what happened: " .. ns.Sync:Describe())

-- 8. A /reload with the same folder changes nothing, even after a restore.
local after = Write(saved)
ns = Load(saved, folder)
Login()
check(Write(saved) == after and ns.Sync:Describe():find("already brought in"), "the same version again changes nothing")
saved.lastZone = 1429
local restore = Folder({ version = 6, replace = true, journey = Write({ version = 3, events = Session(1000) }) })
ns = Load(saved, restore)
Login()
check(ns.char == saved and Same(saved.events, here) and saved.syncedVersion == 6, "a restore replaces, in the same table")
check(saved.lastZone == nil and saved.totals.kills == 0 and saved.recipes, "nothing kept from before it, and the defaults filled in")
table.insert(saved.events, { 9000, "on", 0, 0, 0, 10 })
ns = Load(saved, restore)
Login()
check(#saved.events == 4, "play after a restore survives a /reload with the restore still in the folder")

-- 9. Nothing to do: no folder, or nothing for this character.
local untouched = Journey({ events = Session(1000), addon = "9.9.9" })   -- as the load leaves it
local before = Write(untouched)
ns = Load(untouched, nil)
Login()
check(Write(untouched) == before and ns.Sync:Describe():find("no sync folder"), "no sync folder")
ns = Load(untouched, Folder({ version = 5, journey = Write(Journey()) }, "Bob-Test Realm"))
Login()
check(Write(untouched) == before and ns.Sync:Describe():find("nothing for this character"), "a folder for other characters only")
ns = Load(untouched, { pc = "abc" })
Login()
check(Write(untouched) == before and ns.Sync:Describe():find("nothing for this character"), "a folder with no characters")

-- 10. A problem leaves the journey exactly as it was, says so once, and
-- raises nothing into the game's error frame.
-- The second reads fine but crashes the tidy.
for _, broken in ipairs({ '{ ["x"] = os.exit() }', Write({ version = 3, events = 5 }) }) do
    raised, said = {}, {}
    ns = Load(untouched, Folder({ version = 7, journey = broken }))
    Login()
    check(Write(untouched) == before and untouched.syncedVersion == nil, "a broken journey leaves the data alone: " .. broken)
    check(#said == 1 and said[1]:find("Could not bring in"), "and the player is told: " .. tostring(said[1]))
    check(#raised == 0 and ns.Sync:Describe():find("could not bring in version 7"), "and /rts check shows why: " .. ns.Sync:Describe())
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `luajit tests/sync_test.lua`
Expected: several `FAIL:` lines from section 7 (nothing applies the entry at login yet), for example `FAIL: this PC's play and the other PC's, merged`, then an error `attempt to call method 'Describe' (a nil value)`.

- [ ] **Step 3: Write the login**

Append to `RoadToSixty/Sync.lua`:

```lua
-- At login, first after Core: before the tidy, the roster and the recorder
-- read the journey, and while the loading screen still hides any wait.
ns.On("PLAYER_LOGIN", function()
    local data = RoadToSixtySync
    RoadToSixtySync = nil   -- the journey text is large; the game runs data.lua again at every load
    Sync.found = type(data) == "table"
    local entry = Sync.found and type(data.chars) == "table" and data.chars[ns.Roster:Key()]
    if not entry then return end
    local started = debugprofilestop()
    local ok, what, value = pcall(Sync.Apply, ns.char, entry)
    if not ok then what, value = "problem", value end
    local status = { what = what, version = type(entry) == "table" and entry.version or nil }
    if what == "merged" or what == "replaced" then
        local char, addon = ns.char, ns.char.addon
        wipe(char)
        for k, v in pairs(value) do char[k] = v end
        ns.CharDefaults(char)
        char.addon, char.syncedVersion, char.rosterBuilt = addon, entry.version, nil
        ns.Print(what == "merged" and "Brought in your journey from your other PCs."
            or "Restored this character's journey to the version picked on the website.")
    elseif what == "problem" then
        status.why = tostring(value)
        ns.Print("|cffff4040Could not bring in the synced journey: " .. status.why .. ". Type /rts check.|r")
    end
    status.ms = debugprofilestop() - started
    Sync.status = status
end)

-- One line for /rts check.
function Sync:Describe()
    local s = self.status
    if not self.found then return "Sync: no sync folder. The Road to Sixty app makes one." end
    if not s then return "Sync: nothing for this character in the sync folder." end
    if s.what == "same" then return ("Sync: version %s was already brought in."):format(tostring(s.version)) end
    if s.what == "problem" then
        return ("|cffff4040Sync: could not bring in version %s: %s.|r"):format(tostring(s.version), s.why)
    end
    return ("Sync: %s version %s at login in %d ms."):format(
        s.what == "merged" and "merged" or "restored", tostring(s.version), s.ms)
end
```

In `RoadToSixty/Health.lua`, after

```lua
    Line(("Journal: %d events since load. Kill counting %s."):format(
        sessionEvents, ns.killsTracked and "on" or "|cffff4040unavailable|r"))
```

add

```lua
    Line(ns.Sync:Describe())
```

In `RoadToSixty/RoadToSixty.toc`, after `## SavedVariablesPerCharacter: RoadToSixtyCharDB`, add:

```
## OptionalDeps: RoadToSixty_Sync
```

In `CLAUDE.md`'s layout table, after the `Merge.lua` row, add:

```markdown
| Sync.lua | at login, brings in the journey the app left in `RoadToSixty_Sync`: merged, or replaced for a restore; the sync folder's format is in its header |
```

- [ ] **Step 4: Run the tests**

Run: `luajit tests/sync_test.lua && luajit tests/release_load.lua RoadToSixty && luajit tests/core_test.lua`
Expected: `Sync tests passed.`, `Release load test passed: 48 files loaded from RoadToSixty.`, `Core tests passed.`

- [ ] **Step 5: Run every test and commit**

Run: `for t in tests/*_test.lua; do luajit "$t" >/dev/null || echo "FAILED: $t"; done; echo done`
Expected: `done` with no `FAILED` line.

```bash
git add RoadToSixty/Sync.lua RoadToSixty/Health.lua RoadToSixty/RoadToSixty.toc CLAUDE.md tests/sync_test.lua
git commit -m "Sync: bring in the synced journey at login, and show it in /rts check (#1)

The result is copied into the character's own table, so everything
holding ns.char sees it, and the time it took is shown in /rts check.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: A sync folder made by hand, and the merge time

**Files:**
- Create: `scripts/sync-folder.lua`
- Modify: `CLAUDE.md` (Commands)

**Interfaces:**
- Consumes: `ns.Parse.File(s) -> { [Name] = value }`, `ns.Parse.Write(v)`; the data format in Sync.lua's header.

- [ ] **Step 1: Write the script**

Create `scripts/sync-folder.lua`:

```lua
-- Makes a sync folder by hand, as the Road to Sixty app will (#1), to try
-- the addon's login merge without the app. Run from the repo root:
--
--   luajit scripts/sync-folder.lua <saved file> <sync folder> <Name-Realm> [replace]
--
-- <saved file> is a character's WTF/.../SavedVariables/RoadToSixty.lua, and
-- <sync folder> is Interface/AddOns/RoadToSixty_Sync, made beforehand. The
-- game reads a new addon folder only when it starts; after that, a /reload
-- picks up a new data.lua. Each run gets a higher version, from the clock.
-- What it writes holds other players' names: never put it in the repo.

local saved, folder, key, replace = arg[1], arg[2], arg[3], arg[4] == "replace"
assert(saved and folder and key, "usage: luajit scripts/sync-folder.lua <saved file> <sync folder> <Name-Realm> [replace]")

local ns = {}
assert(loadfile("RoadToSixty/Parse.lua"))("RoadToSixty", ns)

local function Read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local function Save(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local journey = assert(ns.Parse.File(Read(saved)).RoadToSixtyCharDB, "no RoadToSixtyCharDB in " .. saved)
local interface = assert(Read("RoadToSixty/RoadToSixty.toc"):match("## Interface: (%d+)"), "no Interface in the toc")
local version = os.time()

Save(folder .. "/RoadToSixty_Sync.toc", ("## Interface: %s\n## Title: Road to Sixty Sync\n## Notes: Journeys from your other PCs, written by the Road to Sixty app\ndata.lua\n"):format(interface))
Save(folder .. "/data.lua", ("RoadToSixtySync = { chars = { [%q] = { version = %d, replace = %s, journey = %q } } }\n"):format(
    key, version, tostring(replace), ns.Parse.Write(journey)))
print(("Wrote version %d for %s%s."):format(version, key, replace and ", as a restore" or ""))
```

- [ ] **Step 2: Try it on a made-up character**

From the repo root:

```bash
S=$(mktemp -d) && mkdir "$S/RoadToSixty_Sync"
luajit - "$S/RoadToSixty.lua" <<'EOF'
local ns = {}
assert(loadfile("RoadToSixty/Parse.lua"))("RoadToSixty", ns)
local f = assert(io.open(arg[1], "wb"))
f:write("\r\nRoadToSixtyCharDB = " .. ns.Parse.Write({ version = 3, events = { { 1, "on", 0, 0, 0, 1, "Café \"quoted\"\n" } } }) .. "\r\n")
f:close()
EOF
luajit scripts/sync-folder.lua "$S/RoadToSixty.lua" "$S/RoadToSixty_Sync" "Ann-Test Realm" replace
luajit - "$S/RoadToSixty_Sync" <<'EOF'
dofile(arg[1] .. "/data.lua")
local ns = {}
assert(loadfile("RoadToSixty/Parse.lua"))("RoadToSixty", ns)
local e = RoadToSixtySync.chars["Ann-Test Realm"]
local j = ns.Parse.Read(e.journey)
assert(e.replace == true and type(e.version) == "number" and j.events[1][7] == "Café \"quoted\"\n")
print("sync folder ok")
EOF
head -1 "$S/RoadToSixty_Sync/RoadToSixty_Sync.toc"; rm -r "$S"
```
Expected: `Wrote version ... for Ann-Test Realm, as a restore.`, `sync folder ok`, `## Interface: 16001`.

- [ ] **Step 3: Measure the merge on a full-size journey**

The game's Lua is close to PUC Lua 5.1 in speed, not LuaJIT. This step uses the PUC build from the Parse plan at `$SCRATCH/lua-5.1.5/src/lua`, where `$SCRATCH` is the session scratchpad. If it's gone, build it again:

```bash
cd "$SCRATCH" && curl -sLO https://www.lua.org/ftp/lua-5.1.5.tar.gz && tar xzf lua-5.1.5.tar.gz && make -C lua-5.1.5 posix >/dev/null
```

Write `$SCRATCH/merge_time.lua` (a throwaway, not committed):

```lua
-- Times the login's work on a made-up journey of about 3 MB: read the
-- synced text, tidy both copies, merge, check. Run from the repo root.
local ns = {}
for _, name in ipairs({ "Packed.lua", "Tidy.lua", "Parse.lua", "Tally.lua", "Merge.lua" }) do
    assert(loadfile("RoadToSixty/" .. name))("RoadToSixty", ns)
end
local KINDS = { "qa", "qd", "loot", "zone" }
local function Journey(sessions)
    math.randomseed(1)
    local j = { version = 3, segments = {}, events = {}, levels = {}, recipes = {}, people = {},
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 } }
    local kills = {}
    for s = 1, sessions do
        local t0 = s * 20000
        j.events[#j.events + 1] = { t0, "on", 0, 1, 2, 30 }
        for i = 1, 40 do
            j.events[#j.events + 1] = { t0 + i * 100, KINDS[i % 4 + 1], 0, math.random(-9000, 9000), math.random(-9000, 9000),
                math.random(1, 9000), 300 }
        end
        for i = 1, 30 do kills[#kills + 1] = { t = t0 + i * 120, xp = math.random(20, 300), name = "Mob " .. math.random(1, 300) } end
        for k = 1, 8 do
            local steps = {}
            for i = 1, 50 do steps[i] = ("%d,%d,%d"):format(math.random(1, 5), math.random(-40, 40), math.random(-40, 40)) end
            j.segments[#j.segments + 1] = { m = "w", c = 0, t = t0 + k * 500, x = math.random(-9000, 9000),
                y = math.random(-9000, 9000), d = table.concat(steps, ";") }
        end
        j.events[#j.events + 1] = { t0 + 19000, "off", 0, 1, 2 }
    end
    for i = 1, 800 do
        j.people["Player-1-" .. i] = { name = "P" .. i, first = i, last = i * 2, groups = { pca = 3 }, seconds = { pca = 900 } }
    end
    for level = 2, 60 do
        j.levels[level] = { t = level * 1000, kills = level, killXP = level, quests = level, questXP = level, deaths = 0,
            instances = 0, distance = level, flown = 0 }
    end
    j.kills = ns.Packed.PackKills(kills)
    return j
end
local function Place() return true end
local here, text = Journey(480), ns.Parse.Write(Journey(500))
local c = os.clock()
local synced = ns.Parse.Read(text)
local read = os.clock() - c
c = os.clock()
for _, j in ipairs({ here, synced }) do
    ns.Tidy.Runs(j)
    ns.Tidy.Events(j, Place)
    ns.Tidy.Guilds(j)
end
local tidy = os.clock() - c
c = os.clock()
local out = assert(ns.Merge.Merge(here, synced))
local merge = os.clock() - c
c = os.clock()
assert(ns.Merge.Check(here, synced, out))
local checked = os.clock() - c
print(("%.2f MB: read %.2f s, tidy %.2f s, merge %.2f s, check %.2f s, all %.2f s"):format(
    #text / 1e6, read, tidy, merge, checked, read + tidy + merge + checked))
```

Run: `"$SCRATCH/lua-5.1.5/src/lua" "$SCRATCH/merge_time.lua"`
Expected: one line close to `3.03 MB: read 0.12 s, tidy 0.00 s, merge 0.92 s, check 0.00 s, all 1.05 s` (the dry run while writing this plan, on a Mac; before Task 2, tidy alone took 10 s). Write the line into the ledger. If `all` is over 3 seconds, ledger a ruling and open an issue to spread the login's work over frames, linked from #1. Don't build that here.

- [ ] **Step 4: Note the script in CLAUDE.md and commit**

In `CLAUDE.md`'s Commands block, after the `zone-overlays.py` line, add:

```
luajit scripts/sync-folder.lua <saved file> <sync folder> <Name-Realm> [replace]   # a sync folder by hand, to try the login merge
```

```bash
git add scripts/sync-folder.lua CLAUDE.md
git commit -m "Scripts: make a sync folder by hand, to try the login merge without the app (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Notes for later steps

- **In game, on the PC** (an issue for the PC agent once `dev` is pushed). Use a test character, never one whose journey matters:
  1. Check `Interface/AddOns/RoadToSixty` is still the junction to this repo's `RoadToSixty/`, on `dev`.
  2. Log in the test character, `/reload` once so its file is saved, then log out. Copy its `RoadToSixty.lua` outside the repo as copy A.
  3. Log in, kill a few mobs and turn in a quest, then log out. The saved file is now copy B.
  4. Make the folder `Interface/AddOns/RoadToSixty_Sync`, then run `luajit scripts/sync-folder.lua <copy B> <that folder> <Name-Realm>`. With the game closed, put copy A back over the saved file. Start the game and log in: the chat says "Brought in your journey from your other PCs", the play from step 3 is back in History and on the map, and `/rts check` shows "Sync: merged version ... at login in ... ms". Report the time.
  5. `/reload`: `/rts check` says the version was already brought in, and nothing is doubled in History.
  6. Run the script again with copy A and `replace`, then `/reload`: the chat says the journey was restored, and step 3's play is gone. `/reload` again: nothing changes.
  7. Delete `RoadToSixty_Sync`, restart the game: `/rts check` says there's no sync folder. Report any Lua errors.
- **Step 4 (server)** gives each character's versions increasing numbers, and sends `version` as a number in what the app writes.
- **Step 5 (app)** writes `data.lua` in the format in Sync.lua's header, `pc` included. It keys characters by `Name-Realm` from the WTF path (`<Realm>/<Character>` folders). Whether every realm's WTF folder name equals `GetRealmName()` (spaces, apostrophes, accented letters) needs checking there. A mismatch shows as "nothing for this character" in `/rts check`.
- If the measured login time is long, spread the work over frames. The journey must be in place before the recorder starts, so that means holding the login handlers back until it's done, which isn't a small change.
