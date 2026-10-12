-- Offline test of Journal.lua with a fake WoW API. Run with LuaJIT from the
-- repo root: luajit tests/journal_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

-- Fake game state the API reads from.
local game = { now = 1000000, level = 5, money = 1234, instance = false, map = 1429, position = true }

local handlers, commands, tickers = {}, {}, {}
local ns = {
    char = {
        events = {}, levels = {}, totals = {
            kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0,
        },
        kills = { d = "", last = 0, names = {} },
        recipes = {},
    },
    db = {},
    errors = { count = 0 },
    Groups = { Current = function() return nil end, CountRun = function() end },
    IsPlaceMap = function(mapID) return mapID ~= 1415 end,
    Recorder = { Position = function()
        if game.position then return 0, -8900, 500 end
    end },
}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
function ns.Command(name, _, fn) commands[name] = fn end
function ns.Print() end
function ns.SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        ns.errors.count = ns.errors.count + 1
        print("error in SafeCall: " .. tostring(err))
    end
end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end

time = function() return game.now end
GetTime = function() return game.now end
UnitLevel = function() return game.level end
GetMoney = function() return game.money end
IsInInstance = function() return game.instance, game.instance and "party" or "none" end
GetInstanceInfo = function() return "Deadmines", nil, nil, nil, nil, nil, nil, 36 end
RequestTimePlayed = function() end
CopyTable = function(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = type(v) == "table" and CopyTable(v) or v end
    return copy
end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
local SLOT_IDS = { HeadSlot = 1, ChestSlot = 5, MainHandSlot = 16 }
GetInventorySlotInfo = function(name)
    local id = SLOT_IDS[name]
    if not id then error("unknown slot " .. name) end
    return id
end
GetInventoryItemID = function(_, slot) return ({ [1] = 100, [5] = 200 })[slot] end
GetItemInfo = function(link) return nil end     -- never cached, so quality comes from the link colour
C_Map = { GetBestMapForUnit = function() return game.map end }
C_QuestLog = { GetTitleForQuestID = function(id) return "Quest " .. id end }
C_Timer = { NewTicker = function(_, fn) tickers[#tickers + 1] = fn end, After = function() end }
UnitXP, UnitXPMax = function() return 0 end, function() return 1 end

-- The client's real format strings, not the fallbacks.
COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."

ns.Now = function() return time() end
assert(loadfile("RoadToSixty/Packed.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Tidy.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Journal.lua"))("RoadToSixty", ns)
ns.view = ns.char
local Journal = ns.Journal

Fire("PLAYER_LOGIN")
Fire("PLAYER_ENTERING_WORLD")

-- 1. Event shape: time, kind, position, then the kind's own fields from index 6.
local on = ns.char.events[1]
check(on[2] == "on" and on[6] == 5, "login logs an on event with the level at index 6")
check(on[3] == 0 and on[4] == -8900 and on[5] == 500, "events carry the recorder's position")
game.position = false
Journal:Log("die")
local die = ns.char.events[#ns.char.events]
check(die[3] == -1 and die[4] == 0 and die[5] == 0, "unknown position is stored as -1, 0, 0")
local rec = Journal:Log("rec", "Linen Bandage", nil, nil, "t")
check(rec == ns.char.events[#ns.char.events], "Log returns the event it logged")
Journal:Amend(rec, "Other", 3275, "First Aid")
check(rec[6] == "Linen Bandage" and rec[7] == 3275 and rec[8] == "First Aid" and rec[9] == "t",
    "Amend fills only the fields the event lacks")
game.position = true

-- 2. Kills: the chat pattern against real messages, including a rested bonus suffix.
Fire("CHAT_MSG_COMBAT_XP_GAIN", "Young Nightsaber dies, you gain 45 experience.")
game.now = game.now + 30
Fire("CHAT_MSG_COMBAT_XP_GAIN", "Webwood Lurker dies, you gain 50 experience. (+25 exp Rested bonus)")
game.now = game.now + 10
Fire("CHAT_MSG_COMBAT_XP_GAIN", "Young Nightsaber dies, you gain 45 experience.")
Fire("CHAT_MSG_COMBAT_XP_GAIN", "You gain 200 experience.")   -- not a kill
check(ns.char.totals.kills == 3, "three kills counted, got " .. ns.char.totals.kills)
check(ns.char.totals.killXP == 140, "kill xp summed, got " .. ns.char.totals.killXP)
check(#ns.char.kills.names == 2, "a mob name is stored once")

-- 3. Kill packing round trip: the list reads the same before and after the
-- buffer is packed, and the first kill's time is absolute.
local function KillsText()
    local parts = {}
    for _, k in ipairs(Journal:Kills()) do parts[#parts + 1] = k.t .. ":" .. k.xp .. ":" .. k.name end
    return table.concat(parts, " ")
end
local before = KillsText()
check(Journal:Kills()[1].t == 1000000, "first kill keeps its full timestamp")
check(ns.char.kills.d == "", "kills wait in the buffer until packed")
check(#tickers == 1, "the journal packs kills on a ticker")
tickers[1]()
check(ns.char.kills.d ~= "", "the ticker packs the buffer into the saved string")
check(KillsText() == before, "kills read the same after packing: " .. KillsText())
game.now = game.now + 5
Fire("CHAT_MSG_COMBAT_XP_GAIN", "Grell dies, you gain 60 experience.")
Fire("PLAYER_LOGOUT")
local kills = Journal:Kills()
check(#kills == 4 and kills[4].t == 1000045 and kills[4].name == "Grell",
    "a kill after a pack is appended with the right time")
check(Journal:Kills() == kills, "with nothing buffered, the decoded list is reused")
local savedKills = ns.char.kills.d
ns.char.kills.d = "1000500,70,1;"
check(#Journal:Kills() == 1 and Journal:Kills()[1].t == 1000500, "a replaced kill string is read afresh")
ns.char.kills.d = savedKills
check(#Journal:Kills() == 4, "and read afresh again when put back")

-- 4. Loot: green or better from the real message, grey left out, stacks handled.
Fire("CHAT_MSG_LOOT", "You receive loot: |cff9d9d9d|Hitem:2589::::::::5:::::|h[Linen Cloth]|h|rx3.")
Fire("CHAT_MSG_LOOT", "You receive loot: |cff1eff00|Hitem:3182::::::::5:::::|h[Spiked Club]|h|r.")
local loot = ns.char.events[#ns.char.events]
check(loot[2] == "loot" and loot[6]:find("Spiked Club") and loot[7] == 2, "green loot is logged with its quality")
local lootCount = 0
for _, e in ipairs(ns.char.events) do if e[2] == "loot" then lootCount = lootCount + 1 end end
check(lootCount == 1, "grey loot is not logged")

-- 5. Level up: a snapshot with the totals, gear and played time.
Fire("QUEST_TURNED_IN", 783, 250, 50)
game.level = 6
Fire("PLAYER_LEVEL_UP", 6)
Fire("TIME_PLAYED_MSG", 3600, 1800)
local snap = ns.char.levels[6]
check(snap and snap.kills == 4 and snap.questXP == 250 and snap.quests == 1, "snapshot copies the totals")
check(snap.gear[1] == 100 and snap.gear[5] == 200 and snap.gear[16] == nil, "snapshot holds the equipped gear by slot")
check(snap.played == 3600, "played time is attached to the level just reached")
check(snap.money == 1234 and snap.t == game.now, "snapshot has money and time")
local qd
for _, e in ipairs(ns.char.events) do if e[2] == "qd" then qd = e end end
check(qd and qd[6] == 783 and qd[7] == 250 and qd[9] == "Quest 783", "turn-in logs id, xp and title")

-- 6. Entering a dungeon logs it. Leaving, and the run's summary, wait in
-- case the player runs back in; tests/runs_test.lua covers those.
game.instance = true
Fire("PLAYER_ENTERING_WORLD")
local inEvent = ns.char.events[#ns.char.events]
check(inEvent[2] == "in" and inEvent[6] == 36 and inEvent[7] == "Deadmines", "entering logs the instance")
game.instance = false
Fire("PLAYER_ENTERING_WORLD")

-- 7. Equipment changes log only real changes.
local eqBefore = #ns.char.events
Fire("PLAYER_EQUIPMENT_CHANGED", 1)        -- same item as at login
check(#ns.char.events == eqBefore, "re-equipping the same item logs nothing")
GetInventoryItemID = function(_, slot) return ({ [1] = 101, [5] = 200 })[slot] end
Fire("PLAYER_EQUIPMENT_CHANGED", 1)
local eq = ns.char.events[#ns.char.events]
check(eq[2] == "eq" and eq[6] == 1 and eq[7] == 101, "a new item in a slot is logged")

check(ns.errors.count == 0, "no errors while journaling")

if failures == 0 then
    print("Journal tests passed.")
else
    print(failures .. " journal test(s) failed.")
    os.exit(1)
end
