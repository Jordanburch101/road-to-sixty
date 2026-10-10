-- Offline test of dungeon runs in Journal.lua with a fake WoW API: dying and
-- running back in is one run, and runs earlier versions split that way are
-- joined. Run with LuaJIT from the repo root: luajit tests/runs_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, timers = {}, {}
local now = 1000
local inside, instanceID = false, 36

local function NewChar()
    return {
        events = {}, levels = {}, kills = { d = "", last = 0, names = {} },
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0 },
    }
end

local ns = { char = NewChar() }
ns.view = ns.char
ns.Recorder = { Position = function() return 0, 10, 20 end }
ns.Groups = { Current = function() return nil end, CountRun = function() end }
ns.IsPlaceMap = function(mapID) return mapID ~= 1415 end   -- as Core.lua: Eastern Kingdoms is a continent
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
function ns.SafeCall(fn, ...) fn(...) end
function ns.Command() end
function ns.Print() end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end

time = function() return now end
GetTime = function() return now end
GetMoney = function() return 0 end
UnitLevel = function() return 20 end
IsInInstance = function() return inside, inside and "party" or "none" end
GetInstanceInfo = function() return "Deadmines", nil, nil, nil, nil, nil, nil, instanceID end
C_Map = { GetBestMapForUnit = function() return 1436 end }
C_Timer = { After = function(seconds, fn) timers[#timers + 1] = { now + seconds, fn } end }
GetInventoryItemID = function() return nil end
GetInventorySlotInfo = function() return 1 end
UnitXP, UnitXPMax = function() return 0 end, function() return 1 end

assert(loadfile("RoadToSixty/Journal.lua"))("RoadToSixty", ns)
local Journal = ns.Journal

local function Kinds()
    local list = {}
    for _, e in ipairs(ns.char.events) do
        if e[2] == "in" or e[2] == "out" then list[#list + 1] = e[2] .. "@" .. e[1] end
    end
    return table.concat(list, " ")
end

-- Live: dying inside and running back in keeps one run.
inside = true
Fire("PLAYER_ENTERING_WORLD")
ns.char.totals.kills = 10
now = 1300
inside = false
Fire("PLAYER_ENTERING_WORLD")      -- released at the graveyard outside
check(Kinds() == "in@1000", "leaving logs nothing yet: " .. Kinds())
now = 1500
inside = true
Fire("PLAYER_ENTERING_WORLD")      -- ran back in
ns.char.totals.kills = 25
check(Kinds() == "in@1000", "back in is the same run: " .. Kinds())
now = 2000
inside = false
Fire("PLAYER_ENTERING_WORLD")
ns.char.totals.kills = 40          -- questing outside afterwards
now = 2000 + 31 * 60
Fire("PLAYER_ENTERING_WORLD")
check(Kinds() == "in@1000 out@2000", "the run ends when it was left: " .. Kinds())
local out = ns.char.events[#ns.char.events][2] == "out" and ns.char.events[#ns.char.events] or nil
for _, e in ipairs(ns.char.events) do
    if e[2] == "out" then out = e end
end
check(out and out[7].kills == 25, "kills outside after leaving do not count: " .. tostring(out and out[7].kills))
check(out and out[7].duration == 1000, "duration up to leaving: " .. tostring(out and out[7].duration))
check(ns.char.totals.instances == 1, "one instance counted: " .. ns.char.totals.instances)

-- Another instance right after leaving ends the first run there.
ns.char = NewChar()
ns.view = ns.char
now, inside, instanceID = 5000, true, 36
Fire("PLAYER_ENTERING_WORLD")
now, inside = 5100, false
Fire("PLAYER_ENTERING_WORLD")
now, inside, instanceID = 5200, true, 34
Fire("PLAYER_ENTERING_WORLD")
check(Kinds() == "in@5000 out@5100 in@5200", "a different instance is a new run: " .. Kinds())

-- Going back in with a new group is a new run, even soon after.
ns.char = NewChar()
ns.view = ns.char
now, inside, instanceID = 8000, true, 36
ns.char.group = { t = 7900 }
Fire("PLAYER_ENTERING_WORLD")
now, inside = 8100, false
Fire("PLAYER_ENTERING_WORLD")
ns.char.group = { t = 8200 }
now, inside = 8300, true
Fire("PLAYER_ENTERING_WORLD")
check(Kinds() == "in@8000 out@8100 in@8300", "a new group going back in is a new run: " .. Kinds())
ns.char.group = nil

-- Old split runs are joined.
local function Summary(duration, kills, item, party)
    return { name = "Deadmines", duration = duration, kills = kills, xp = kills * 10, deaths = 1, money = 5,
        levels = 0, items = { item }, party = party }
end
ns.char = NewChar()
ns.view = ns.char
ns.char.totals.instances = 2
ns.char.events = {
    { 100, "in", 0, 0, 0, 36, "Deadmines", "party" },
    { 400, "out", 0, 0, 0, 36, Summary(300, 10, "a", { "tank", "healer" }) },
    { 410, "die", 0, 0, 0 },
    { 500, "in", 0, 0, 0, 36, "Deadmines", "party" },
    { 900, "out", 0, 0, 0, 36, Summary(400, 5, "b", { "healer", "new tank" }) },
    { 5000, "in", 0, 0, 0, 36, "Deadmines", "party" },   -- a later, separate run
    { 5100, "out", 0, 0, 0, 36, Summary(100, 1, "c") },
}
Journal:TidyRuns()
check(Kinds() == "in@100 out@900 in@5000 out@5100", "split run joined, later run kept: " .. Kinds())
local joined = ns.char.events[3] ---@type table
check(joined[2] == "out" and joined[7].duration == 800, "joined duration covers both parts: " .. tostring(joined[7].duration))
check(joined[7].kills == 15 and joined[7].xp == 150 and joined[7].deaths == 2, "joined counts add up")
check(table.concat(joined[7].items, ",") == "a,b", "joined loot in order: " .. table.concat(joined[7].items, ","))
check(ns.char.totals.instances == 1, "instance count corrected: " .. ns.char.totals.instances)
check(table.concat(joined[7].party, ",") == "tank,healer,new tank",
    "joined party has everyone once: " .. table.concat(joined[7].party or {}, ","))

-- Not when the group changed between leaving and going back in.
ns.char = NewChar()
ns.view = ns.char
ns.char.events = {
    { 100, "in", 0, 0, 0, 36, "Deadmines", "party" },
    { 400, "out", 0, 0, 0, 36, Summary(300, 10, "a") },
    { 410, "grpx", 0, 0, 0, {} },
    { 450, "grp", 0, 0, 0, "party", {} },
    { 500, "in", 0, 0, 0, 36, "Deadmines", "party" },
}
ns.char.instance = 36
ns.char.run = { t = 500, name = "Deadmines", kills = 10, xp = 100, deaths = 1, money = 5, level = 20, items = { "b" } }
Journal:TidyRuns()
check(Kinds() == "in@100 out@400 in@500", "runs of different groups stay apart: " .. Kinds())

-- A split run still going on folds its first part into the run.
ns.char = NewChar()
ns.view = ns.char
ns.char.events = {
    { 100, "in", 0, 0, 0, 36, "Deadmines", "party" },
    { 400, "out", 0, 0, 0, 36, Summary(300, 10, "a") },
    { 500, "in", 0, 0, 0, 36, "Deadmines", "party" },
}
ns.char.instance = 36
ns.char.run = { t = 500, name = "Deadmines", kills = 10, xp = 100, deaths = 1, money = 5, level = 20, items = { "b" } }
Journal:TidyRuns()
check(Kinds() == "in@100", "ongoing split run joined: " .. Kinds())
check(ns.char.run.t == 100 and ns.char.run.kills == 0, "run starts at the first entry with its kills")
check(table.concat(ns.char.run.items, ",") == "a,b", "run loot in order")

-- Wrongly saved events are tidied out: continent "zone" events, and a death
-- logged twice in one second, which the totals counted twice.
ns.char = NewChar()
ns.char.totals.deaths = 3
ns.char.events = {
    { 100, "zone", 0, 0, 0, 1436 },
    { 110, "zone", 0, 0, 0, 1415 },
    { 120, "die", 0, 0, 0 },
    { 120, "die", 0, 0, 0 },
    { 130, "zone", 0, 0, 0, 1436 },
    { 140, "die", 0, 0, 0 },
}
Journal:TidyEvents(ns.char)
local kept = {}
for _, e in ipairs(ns.char.events) do kept[#kept + 1] = e[2] .. "@" .. e[1] end
local left = table.concat(kept, " ")
check(left =="zone@100 die@120 zone@130 die@140", "continent zone and doubled death tidied: " .. left)
check(ns.char.totals.deaths == 2, "doubled death taken off the totals, got " .. ns.char.totals.deaths)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("Runs tests passed.")
