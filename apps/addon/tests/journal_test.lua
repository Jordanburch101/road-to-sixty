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
-- Links as Forever writes them: the player's level in field 9, a spec in
-- field 10. suffixes[slot] puts a random suffix (field 7) on a slot's item.
local suffixes = {}
GetInventoryItemLink = function(unit, slot)
    local id = GetInventoryItemID(unit, slot)
    return id and ("|cff1eff00|Hitem:%d::::::%s::%d:1491:::::::::|h[Item]|h|r"):format(id, suffixes[slot] or "", game.level)
end
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

-- 0. Nothing is logged before PLAYER_LOGIN: the sync folder is brought in
-- then (Sync.lua), and an event logged earlier would make this PC's older
-- copy look like the one played last. A profession raised on another PC
-- and gear changed there are both seen again after login.
assert(loadfile("RoadToSixty/Crafts.lua"))("RoadToSixty", ns)
GetProfessions = function() return 1 end
GetProfessionInfo = function() return "Cooking", 133971, 50, 150 end
ns.char.skills = { Cooking = { 50, 75 } }
ns.char.gear = { [1] = 99 }
Fire("SKILL_LINES_CHANGED")
Fire("CHAT_MSG_SKILL")
Fire("PLAYER_EQUIPMENT_CHANGED", 1)
check(#ns.char.events == 0, "nothing logged before login, got " .. #ns.char.events)

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

-- After login a raised profession is logged as before.
Fire("SKILL_LINES_CHANGED")
local last = ns.char.events[#ns.char.events]
check(last[2] == "prof" and last[6] == "Cooking" and last[8] == 150, "a profession raised elsewhere is logged after login")

-- 8. Equipped items are not readable yet at login on Forever (issue #63):
-- the login gear is read again until they show, then fills in the snapshot
-- taken at login and the gear last seen, without logging them as changes.
local timers = {}
local realAfter = C_Timer.After
C_Timer.After = function(_, fn) timers[#timers + 1] = fn end   ---@diagnostic disable-line: duplicate-set-field
local function RunTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end
local wearing = { [1] = 102, [5] = 200 }   -- slot 1 changed on another PC
local readable = false
GetInventoryItemID = function(_, slot) return readable and wearing[slot] or nil end
game.level = 7
Fire("PLAYER_LOGIN")
check(next(ns.char.levels[7].gear) == nil, "the first gear read at login is empty")
check(ns.char.gear[1] == 101, "while waiting, the gear last seen is still the saved one")
check(#timers > 0, "the login gear is read again later")
local function EqCount()
    local n = 0
    for _, e in ipairs(ns.char.events) do if e[2] == "eq" then n = n + 1 end end
    return n
end
local eqLogged = EqCount()
readable = true
Fire("PLAYER_EQUIPMENT_CHANGED", 1)
check(EqCount() == eqLogged, "items turning up while waiting are not logged as changes")
RunTimers()
local late = ns.char.events[#ns.char.events]
check(EqCount() == eqLogged + 1 and late[2] == "eq" and late[6] == 1 and late[7] == 102 and late[9] == true,
    "gear changed while away (slot 1 on another PC) is logged once read, marked late")
check(late[8] == "item:102", "with its item string")
eqLogged = EqCount()
check(ns.char.levels[7].gear[1] == 102 and ns.char.levels[7].gear[5] == 200, "the login snapshot gets the gear once readable")
check(ns.char.gear[1] == 102 and ns.char.levels[7].gear ~= ns.char.gear, "the gear last seen is set too, as its own table")
Fire("PLAYER_EQUIPMENT_CHANGED", 1)
check(EqCount() == eqLogged, "after the wait an unchanged slot still logs nothing")

-- A slot missing from the gear last seen is unknown, not empty, so it is
-- not logged (before 1.10.3 the gear last seen was often empty, #63).
ns.char.gear = { [5] = 200 }
Fire("PLAYER_LOGIN")
RunTimers()
check(EqCount() == eqLogged, "a slot the gear last seen had nothing for logs nothing at login")
ns.char.gear = {}
Fire("PLAYER_LOGIN")
RunTimers()
check(EqCount() == eqLogged, "an empty gear last seen logs nothing at login")

-- A login whose snapshot already has gear keeps it; one with nothing on
-- stops reading after a while and stays empty.
readable = false
Fire("PLAYER_LOGIN")
for _ = 1, 100 do RunTimers() end   -- also runs the other modules' login timers
check(ns.char.levels[7].gear[1] == 102, "a snapshot that has gear is left alone")
check(next(ns.char.gear) == nil and #timers == 0, "a character wearing nothing stops being read and stays empty")
C_Timer.After = realAfter
readable = true

-- 9. Item strings: the suffix, enchant and context kept; the link level
-- and spec left out, so a level up changes nothing.
local ItemString = ns.ItemString
check(ItemString("|cnIQ1:|Hitem:6070::::::::2:1491::11:::::::|h[Wolfskin Bracers]|h|r") == "item:6070:::::::::::11",
    "the link level and spec are left out, the context kept")
check(ItemString("|Hitem:6070::::::::12:1491::11:::::::|h[x]|h") == ItemString("|Hitem:6070::::::::2:1491::11|h[x]|h"),
    "the same item reads the same at any level")
check(ItemString("|Hitem:15210:41:::::1017::20:1491:::::|h[x]|h") == "item:15210:41:::::1017",
    "the enchant and the random suffix are kept")
check(ItemString("|Hitem:15210:41:::::1017::20:1491:::::|h[x]|h", true) == "item:15210::::::1017",
    "without the enchant when asked")
check(ItemString("item:25") == "item:25" and ItemString(nil) == nil and ItemString("Linen Cloth") == nil,
    "a bare item string reads as itself; anything else is not an item")

-- 10. The snapshot keeps item strings, and an eq event carries one. A
-- suffix changing while the item ID stays is a change; a level up is not.
-- (The login before ended with nothing worn, so slot 1 is put on first.)
Fire("PLAYER_EQUIPMENT_CHANGED", 1)
game.level = 8
Fire("PLAYER_LEVEL_UP", 8)
check(ns.char.levels[8].links[1] == "item:102" and ns.char.levels[8].links[5] == "item:200",
    "the level snapshot holds each slot's item string")
local function LastEq()
    for i = #ns.char.events, 1, -1 do
        if ns.char.events[i][2] == "eq" then return ns.char.events[i], i end
    end
end
local _, before = LastEq()
Fire("PLAYER_EQUIPMENT_CHANGED", 1)
check(select(2, LastEq()) == before, "re-equipping the same item at a new level logs nothing")
suffixes[1] = "1017"
Fire("PLAYER_EQUIPMENT_CHANGED", 1)
local eq9 = LastEq()
check(eq9[6] == 1 and eq9[7] == 102 and eq9[8] == "item:102::::::1017", "the same item with another suffix is logged, with its item string")
wearing[1] = nil
Fire("PLAYER_EQUIPMENT_CHANGED", 1)
eq9 = LastEq()
check(eq9[7] == 0 and eq9[8] == nil, "an emptied slot has no item string")

if failures == 0 then
    print("Journal tests passed.")
else
    print(failures .. " journal test(s) failed.")
    os.exit(1)
end
