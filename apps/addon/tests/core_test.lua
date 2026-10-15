-- Offline test of Core.lua's saved variable setup with a fake WoW API: a
-- new character starts on the current layout, an older file is brought up
-- to it, and the addon version is saved. Run with LuaJIT from the repo
-- root: luajit tests/core_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

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

local guid = "Player-1-0A"
UnitGUID = function() return guid end
issecretvalue = function(v) return v == "secret" end

local function Load(saved, db)
    RoadToSixtyDB, RoadToSixtyCharDB = db, saved
    local ns = {}
    assert(loadfile("RoadToSixty/Core.lua"))("RoadToSixty", ns)
    assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", ns)
    script(nil, "ADDON_LOADED", "RoadToSixty")
    return ns
end

-- 1. A new character starts on the current layout, all by the realm's clock.
local ns = Load(nil)
local current = ns.char.version
check(current == 4, "a new character is on layout 4, got " .. tostring(current))
check(ns.char.clockFrom == nil, "a new journey has no PC clock part")
check(ns.char.addon == "9.9.9", "the addon version is saved")
check(ns.Now() == 2000, "ns.Now reads the realm's clock")

-- 2. A file from layout 1 is upgraded, keeping its data, and marks when it
-- moved to the realm's clock.
ns = Load({ version = 1, events = { { 500, "on" } }, segments = {} })
check(ns.char.version == current, "an old file is brought up to the current layout")
check(ns.char.clockFrom == 2000, "an old file notes when it moved to the realm's clock")
check(#ns.char.events == 1 and ns.char.kills and ns.char.totals, "an old file keeps its data and gains defaults")

-- 3. Loading again changes nothing more.
ns = Load(ns.char)
check(ns.char.clockFrom == 2000, "clockFrom is set once")

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
check(ns.char.version == 4, "a layout 2 file is brought up to layout 4")
check(p.groups[pc] == 3 and p.seconds[pc] == 600 and p.raids == nil and p.name == "A", "a player's counts become tallies")
check(r[1][pc] == 2 and r[3] == "Mor'Ladim", "a rare's count becomes a tally")
check(ns.char.clockFrom == nil, "a layout 2 file was already on the realm's clock")

-- 6. A layout 1 file gets both upgrades at once.
ns = Load({ version = 1, people = { g = { groups = 1 } } }, db)
check(ns.char.clockFrom == 2000 and ns.char.people.g.groups[pc] == 1, "layout 1 gets clockFrom and tallies")

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
local bare = { version = 4, events = { { 1, "on" } } }
ns.CharDefaults(bare)
check(bare.totals.kills == 0 and bare.kills.d == "" and bare.people and #bare.events == 1 and bare.version == 4,
    "CharDefaults fills in a journey")

-- 9. Login stamps a file from before stamps as this character's.
ns = Load({ version = 3, events = { { 500, "on" } } }, db)
script(nil, "PLAYER_LOGIN")
check(ns.char.journeyId == "Player-1-0A:0", "a file without a stamp becomes this character's: " .. tostring(ns.char.journeyId))
check(#ns.char.events == 1, "and keeps its journey")

-- 10. This character's own stamp is kept, an erased one too.
ns = Load({ version = 4, journeyId = "Player-1-0A:3000", events = { { 500, "on" } } }, db)
script(nil, "PLAYER_LOGIN")
check(ns.char.journeyId == "Player-1-0A:3000" and #ns.char.events == 1, "the character's own stamp stays")

-- 11. Another GUID's file belongs to a deleted namesake: a fresh start.
ns = Load({ version = 4, journeyId = "Player-1-0B:0", events = { { 500, "on" } }, totals = { kills = 9 } }, db)
script(nil, "PLAYER_LOGIN")
check(ns.char.journeyId == "Player-1-0A:0", "a namesake's file starts again for this character: " .. tostring(ns.char.journeyId))
check(#ns.char.events == 0 and ns.char.totals.kills == 0 and ns.char.version == 4, "with nothing of the old journey")
check(ns.char.addon == "9.9.9", "and the addon version kept")

-- 12. A GUID the client won't give leaves the file as it is.
for _, broken in ipairs({ function() error("blocked") end, function() return "secret" end, function() return nil end }) do
    UnitGUID = broken
    ns = Load({ version = 4, journeyId = "Player-1-0B:0", events = { { 500, "on" } } }, db)
    script(nil, "PLAYER_LOGIN")
    check(ns.char.journeyId == "Player-1-0B:0" and #ns.char.events == 1, "an unreadable GUID changes nothing")
end
UnitGUID = function() return guid end

-- 13. Erase keeps the GUID with a later start, read again or from the old stamp.
local function Erase(char)
    ns = Load(char, db)
    ns.Recorder, ns.Journal, ns.Roster = { Reset = function() end }, { Reset = function() end }, { Rebuild = function() end }
    ns.ResetCharacter()
    return ns.char
end
local erased = Erase({ version = 4, journeyId = "Player-1-0A:0", events = { { 500, "on" } } })
check(erased.journeyId == "Player-1-0A:2000" and #erased.events == 0, "Erase gives the same GUID, starting now: " .. tostring(erased.journeyId))
UnitGUID = function() error("blocked") end
erased = Erase({ version = 4, journeyId = "Player-1-0A:0" })
check(erased.journeyId == "Player-1-0A:2000", "Erase without a GUID read keeps the old stamp's GUID")
UnitGUID = function() return guid end

if failures == 0 then
    print("Core tests passed.")
else
    print(failures .. " core test(s) failed.")
    os.exit(1)
end
