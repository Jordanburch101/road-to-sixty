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
