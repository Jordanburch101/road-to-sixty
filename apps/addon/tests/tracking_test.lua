-- Offline test of Tracking.lua: what it records, the switches that stop it,
-- both shapes of the talent API, a secret value, and the empty row logging
-- out would otherwise save.
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
C_Timer = { After = function(_, fn) fn() end, NewTicker = function() return {} end }
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
xp, xpMax, money = 0, 0, 0
Fire("PLAYER_LOGOUT")
local rows = select(2, me.stats:gsub(";", ""))
check(rows == 2, "wrong stats rows: " .. me.stats)
check(not me.stats:find(",0,0,0,0;", 1, true), "logout row saved")

if failures > 0 then os.exit(1) end
print("tracking_test: all passed")
