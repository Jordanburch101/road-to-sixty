-- Offline test of time played in Journal.lua with a fake WoW API: the time
-- played at any moment of a journey from its level ups and play sessions
-- (a session cut short by a crash included), and the chat windows not
-- showing the game's time played lines for the addon's own request. Run with LuaJIT from the repo root:
-- luajit tests/played_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, timers = {}, {}
local now = 100000

local ns = {
    char = {
        events = {}, levels = {}, kills = { d = "", last = 0, names = {} },
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 },
    },
    db = {},
}
ns.view = ns.char
ns.Recorder = { Position = function() return 0, 10, 20 end }
ns.Groups = { Current = function() return nil end, CountRun = function() end }
ns.IsPlaceMap = function() return true end
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
local function RunTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

time = function() return now end
GetTime = function() return now end
GetMoney = function() return 0 end
UnitLevel = function() return 20 end
IsInInstance = function() return false, "none" end
C_Map = { GetBestMapForUnit = function() return 1436 end }
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
GetInventoryItemID = function() return nil end
GetInventorySlotInfo = function() return 1 end
UnitXP, UnitXPMax = function() return 0 end, function() return 1 end
CopyTable = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end

-- Two chat windows that show the game's time played answer.
local requests = 0
RequestTimePlayed = function() requests = requests + 1 end
local function Chat()
    local chat = { listening = true }
    function chat:IsEventRegistered() return self.listening end
    function chat:UnregisterEvent() self.listening = false end
    function chat:RegisterEvent() self.listening = true end
    return chat
end
ChatFrame1, ChatFrame2 = Chat(), Chat()
NUM_CHAT_WINDOWS = 2

assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Journal.lua"))("RoadToSixty", ns)
local Journal = ns.Journal

-- Time played at a moment ------------------------------------------------------

local function Event(t, kind) return { t, kind, 0, 0, 0 } end
ns.char.events = {
    Event(900, "on"),           -- tracking began partway through level 4
    Event(1500, "lvl"),
    Event(2000, "off"),
    Event(5000, "on"),
    Event(5600, "zone"),        -- then the game crashed: no "off"
    Event(9000, "on"),
    Event(9200, "lvl"),
    Event(9400, "lvl"),
    Event(9500, "off"),
}
ns.char.levels = {
    [4] = { t = 900, partial = true },              -- no time played saved
    [5] = { t = 1500, played = 10000 },
    [6] = { t = 9200, played = 11400 },
    [7] = { t = 9400 },                              -- its answer never came
}

check(Journal:PlayedAt(950) == nil, "nothing before the first level up with a time")
local total, level = Journal:PlayedAt(1800)
check(total == 10300 and level == 300, ("level 5, first session: %s %s"):format(tostring(total), tostring(level)))
total, level = Journal:PlayedAt(7000)
check(total == 11100 and level == 1100, ("after the crashed session: %s %s"):format(tostring(total), tostring(level)))
total, level = Journal:PlayedAt(9300)
check(total == 11500 and level == 100, ("level 6: %s %s"):format(tostring(total), tostring(level)))
total, level = Journal:PlayedAt(9450)
check(total == 11650 and level == nil, ("level 7 without its time: %s %s"):format(tostring(total), tostring(level)))

-- This character's session still going runs to now.
table.insert(ns.char.events, Event(99000, "on"))
total = Journal:PlayedAt(now + 500)
check(total == 11400 + 300 + 1000, ("current session to now: %s"):format(tostring(total)))

-- Chat ----------------------------------------------------------------------------

-- The answer to the addon's request does not show in chat.
Fire("PLAYER_LEVEL_UP", 8)
check(requests == 1, "time played asked for at the level up")
check(not ChatFrame1.listening and not ChatFrame2.listening, "chat windows not listening for the answer")
Fire("TIME_PLAYED_MSG", 12000, 0)
check(ns.char.levels[8].played == 12000, "time played saved in the level's snapshot")
RunTimers()
check(ChatFrame1.listening and ChatFrame2.listening, "chat windows listen again after the answer")

if failures > 0 then
    print(("played_test: %d failure(s)"):format(failures))
    os.exit(1)
end
print("played_test: ok")
