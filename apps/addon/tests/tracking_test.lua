-- Offline test of Tracking.lua: what it records, the switches that stop it
-- (all off by default, Core.lua), both shapes of the talent API, a secret
-- value, the empty row logging out would otherwise save, and the limits.
-- Run with LuaJIT from apps/addon: luajit tests/tracking_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, commands, printed = {}, {}, {}
local clock = 1785000000
local ns = {
    db = { tracking = { off = {}, maps = {}, chars = {} } },
    Now = function() return clock end,
    Print = function(text) printed[#printed + 1] = text end,
    SafeCall = function(fn, ...) return fn(...) end,
    PlayerGUID = function() return "Player-1-ME" end,
}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
function ns.Command(name, _, fn) commands[name] = fn end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end

local sub, secret = "Goldshire", "shh"
local xp, xpMax, money = 10, 400, 25
local talents = { "Arcane", "ico", 0, "file" }
issecretvalue = function(v) return v == secret end
UnitName = function() return "Zed" end
GetRealmName = function() return "Era" end
UnitRace = function() return "Human", "Human" end
UnitClass = function() return "Mage", "MAGE" end
UnitFactionGroup = function() return "Alliance" end
UnitSex = function() return 2 end
UnitLevel = function() return 5 end
UnitXP = function() return xp end
UnitXPMax = function() return xpMax end
GetMoney = function() return money end
GetXPExhaustion = function() end
GetBuildInfo = function() return "1.15.9", "70003", "x", 11509 end
GetZoneText = function() return "Elwynn Forest" end
GetSubZoneText = function() return sub end
GetBindLocation = function() return "Goldshire" end
IsInInstance = function() return false end
IsInGroup = function() return false end
GetNumTalentTabs = function() return 1 end
GetTalentTabInfo = function() return unpack(talents) end
CreateVector2D = function(x, y) return { x = x, y = y } end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
local tickers = {}
C_Timer = { After = function(_, fn) fn() end, NewTicker = function(s, fn) tickers[s] = fn return {} end }
local level, cap = 5, 60
UnitLevel = function() return level end
GetMaxPlayerLevel = function() return cap end
local members = {}      -- party unit -> GUID
IsInRaid = function() return false end
GetNumSubgroupMembers = function() return #members end
UnitGUID = function(unit) return members[tonumber(unit:match("%d+") or 0)] end
UnitIsConnected = function() return true end
C_Map = {
    GetBestMapForUnit = function() return 1429 end,
    GetPlayerMapPosition = function() return { x = .5, y = .5 } end,
    GetWorldPosFromMapPos = function() return 0, { x = -9000.4, y = 100.6 } end,
    GetMapInfo = function(id) return { name = "Map" .. id, parentMapID = 947, mapType = 3 } end,
    GetMapChildrenInfo = function() return { { mapID = 1429 } } end,
}

assert(loadfile("RoadToSixty/Tracking.lua"))("RoadToSixty", ns)
Fire("PLAYER_LOGIN")

local db = ns.db.tracking
local me = db.chars["Player-1-ME"]
local function count(kind)
    local n = 0
    for _, e in ipairs(me.events) do
        if e[2] == kind then n = n + 1 end
    end
    return n
end

check(me and me.name == "Zed" and me.class == "MAGE" and me.faction == "Alliance", "character not saved")
check(count("env") == 1 and db.interface == 11509, "session not logged")
check(me.events[2][2] == "sub" and me.events[2][7] == "Goldshire" and me.events[2][8] == true, "first visit not marked")
check(me.events[1][4] == -9000 and me.events[1][5] == 101, "position not rounded to yards")
check(db.maps[1429] and db.maps[1429][1] == "Map1429" and db.build == "70003", "maps not read")
check(me.talents == "Arcane 0" and count("tal") == 0, "the first talents read is a baseline")
check(count("bind") == 1, "hearthstone not logged")

-- Moving on, and back again.
sub = "Northshire"
Fire("ZONE_CHANGED")
check(count("sub") == 2, "subzone not logged")
sub = "Goldshire"
Fire("ZONE_CHANGED")
check(count("sub") == 3 and me.events[#me.events][8] == nil, "a second visit marked as the first")

-- The newer talent shape, then a secret value recording nothing.
talents = { 1, "Arcane", "text", "ico", 5 }
Fire("CHARACTER_POINTS_CHANGED")
check(me.talents == "Arcane 5" and count("tal") == 1, "newer talent shape not read")
sub = secret
GetSubZoneText = function() return secret end
Fire("ZONE_CHANGED")
check(me.events[#me.events][2] ~= "sub" or me.events[#me.events][7] ~= secret, "kept a secret value")
GetSubZoneText = function() return sub end
sub = "Goldshire"

-- The switches stop recording, but never a note.
db.off.sub = true
sub = "Westbrook"
local before = count("sub")
Fire("ZONE_CHANGED")
check(count("sub") == before, "logged while off")
db.off.sub = nil
check(not me.seen["Elwynn Forest/Westbrook"], "a place marked seen while subzones were off")
sub = "Goldshire"
Fire("ZONE_CHANGED")
sub = "Westbrook"
Fire("ZONE_CHANGED")
check(me.events[#me.events][7] == "Westbrook" and me.events[#me.events][8] == true, "first visit lost while subzones were off")
commands.note("Finally got my mount!")
check(count("note") == 1 and printed[#printed]:find("Finally got my mount!", 1, true), "note lost")
commands.note("")
check(count("note") == 1, "an empty note saved")

-- XP and gold only write what changed, and logging out adds no empty row.
clock = clock + 60
Fire("PLAYER_LEVEL_UP")
xp = 20
clock = clock + 60
Fire("PLAYER_LEVEL_UP")
for _, fn in pairs(tickers) do fn() end
check(me.stats == "", "stats copied into the saved string before logout")
xp, xpMax, money = 0, 0, 0
Fire("PLAYER_LOGOUT")
local rows = select(2, me.stats:gsub(";", ""))
check(rows == 2, "wrong stats rows: " .. me.stats)
check(not me.stats:find(",0,0,0,0;", 1, true), "logout row saved")

-- A secret read counts as nothing rather than erroring.
xp, xpMax, money = 30, 400, secret
Fire("PLAYER_LEVEL_UP")
Fire("PLAYER_LOGOUT")
check(me.stats:find(",30,400,0,0;", 1, true), "secret gold not read as 0: " .. me.stats)

-- Party positions, each member's rows capped.
IsInGroup = function() return true end
members[1] = "Player-1-PAL"
tickers[15]()
Fire("PLAYER_LOGOUT")
local pal = me.people["Player-1-PAL"]
check(pal and pal.d:find("^%d+,0,%-9000,101,5;$") and pal.class == "MAGE", "party member not tracked")
members[1] = "Player-1-OLD"
local full = string.rep("1,0,0,0,1;", 5000)
me.people["Player-1-OLD"] = { name = "Old", d = full }
tickers[15]()
Fire("PLAYER_LOGOUT")
check(me.people["Player-1-OLD"].d == full, "a member's rows grew past the cap")

-- At the level cap: one last stats row, then no more stats or party rows.
level, xp, money = 60, 0, 99
Fire("PLAYER_LEVEL_UP")
money = 100
clock = clock + 60
Fire("PLAYER_LEVEL_UP")
members[1] = "Player-1-NEW"
tickers[15]()
Fire("PLAYER_LOGOUT")
check(select(2, me.stats:gsub(";%d+,60,", "")) == 1 and me.stats:find(",60,0,400,0,99;", 1, true), "stats not stopped at the cap: " .. me.stats)
check(not me.people["Player-1-NEW"], "party tracked at the level cap")

-- Core.lua: every switch in Options.lua starts off, for new and existing
-- files, and one turned on (false) stays on.
do
    CreateFrame = function() return { RegisterEvent = function() end, SetScript = function(_, _, fn) ns.script = fn end } end
    SlashCmdList = {}
    CopyTable = function(t)
        local copy = {}
        for k, v in pairs(t) do copy[k] = type(v) == "table" and CopyTable(v) or v end
        return copy
    end
    GetServerTime = function() return clock end
    C_AddOns = { GetAddOnMetadata = function() end }
    local keys = {}
    for key in assert(io.open("RoadToSixty/Options.lua")):read("*a"):gmatch('Track%("(%w+)"') do keys[#keys + 1] = key end
    check(#keys == 10, "switches not found in Options.lua")
    for _, saved in ipairs({ {}, { tracking = { off = {} } }, { tracking = { off = { party = false } } } }) do
        RoadToSixtyDB, RoadToSixtyCharDB = saved, nil
        local core = {}
        assert(loadfile("RoadToSixty/Core.lua"))("RoadToSixty", core)
        assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", core)
        ns.script(nil, "ADDON_LOADED", "RoadToSixty")
        local off = core.db.tracking.off
        for _, key in ipairs(keys) do
            local want = not (key == "party" and saved.tracking and saved.tracking.off.party == false)
            check(off[key] == want, "default for " .. key .. " should be " .. tostring(want))
        end
    end
end

if failures > 0 then os.exit(1) end
print("tracking_test: all passed")
