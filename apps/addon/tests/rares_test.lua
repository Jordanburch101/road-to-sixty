-- Offline test of Rares.lua with fake units, as Forever shows them: names
-- and GUIDs readable in the open world, secret inside instances. Covers
-- kills with XP and without (loot, corpse), adds, a target dropped, someone
-- else's kill, counting a rare killed again, and the NPC ID added by loot
-- inside an instance. Run with LuaJIT from the repo root:
-- luajit tests/rares_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers = {}
local now = 1000
local ns = { char = { events = {} } }
ns.view = ns.char
local kills = {}     -- the kill list, as Journal:Kills gives it
ns.Journal = {
    Log = function(_, kind, ...)
        table.insert(ns.char.events, { now, kind, 0, 0, 0, ... })
    end,
    Kills = function() return kills end,
}
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

-- Units by token: { name, classification, level, guid, dead, tapDenied }.
-- Inside an instance names and GUIDs come back secret.
local SECRET = {}
local units, inside = {}, false
issecretvalue = function(v) return v == SECRET end
local function Field(i) return function(u) local x = units[u] return x and x[i] end end
UnitExists = function(u) return units[u] ~= nil end
UnitIsPlayer = function() return false end
UnitName = function(u) return inside and SECRET or Field(1)(u) end
UnitClassification = Field(2)
UnitLevel = Field(3)
UnitGUID = function(u) return inside and SECRET or Field(4)(u) end
UnitIsDead = function(u) return units[u] and units[u][5] or false end
UnitIsTapDenied = function(u) return units[u] and units[u][6] or false end

-- The loot window: slot -> { guid, ... }.
local loot = {}
GetNumLootItems = function() return #loot end
GetLootSourceInfo = function(slot)
    local out = {}
    for _, guid in ipairs(loot[slot]) do out[#out + 1] = guid; out[#out + 1] = 1 end
    return unpack(out)
end

ns.Now = function() return time() end
ns.pc = "testpc"
assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Rares.lua"))("RoadToSixty", ns)
local Rares = ns.Rares

local function Guid(npc, spawn) return ("Creature-0-4615-0-523-%d-%s"):format(npc, spawn) end
local function Target(name, class, level, guid)
    units.target = { name, class, level, guid, false, false }
    Fire("PLAYER_TARGET_CHANGED")
end
-- As on Forever: the XP message comes while the target still shows alive,
-- then the target is cleared.
local function KillTarget(name)
    Rares:Killed(name)
    now = now + 0.1
    units.target = nil
    Fire("PLAYER_TARGET_CHANGED")
end
local function Last() return ns.char.events[#ns.char.events] end
local function Count() return #ns.char.events end

-- Open world --------------------------------------------------------------------

-- A rare targeted and killed with XP: named, with its NPC ID.
local ladim = Guid(522, "A1")
Target("Mor'Ladim", "rareelite", 35, ladim)
Rares:Killed("Skeletal Fiend")      -- an add first
check(Count() == 0, "an add is not the rare")
KillTarget("Mor'Ladim")
check(Count() == 1 and Last()[6] == "Mor'Ladim" and Last()[7] == "rareelite" and Last()[8] == 35
    and Last()[9] == 522 and Last()[10] == "x", "open world rare kill with XP")
check((Rares:Describe(Last())) == "Killed Mor'Ladim", "title")
check(select(2, Rares:Describe(Last())) == "Rare elite, level 35", "detail")

-- Its corpse clicked and looted afterwards: not recorded again.
units.target = { "Mor'Ladim", "rareelite", 35, ladim, true, false }
Fire("PLAYER_TARGET_CHANGED")
loot = { { ladim } }
Fire("LOOT_OPENED")
check(Count() == 1, "corpse and loot of a recorded kill add nothing")

-- A grey rare (no XP): seen by its nameplate, then looted.
local ressan = Guid(2147, "B2")
units.nameplate3 = { "Ressan the Needler", "rare", 11, ressan, false, false }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
now = now + 30
loot = { { ressan } }
Fire("LOOT_OPENED")
check(Count() == 2 and Last()[6] == "Ressan the Needler" and Last()[9] == 2147 and Last()[10] == "l",
    "no XP: looted rare recorded")

-- Another grey rare: only its corpse clicked.
local foulmane = Guid(1847, "C3")
units.target = { "Foulmane", "rare", 52, foulmane, true, false }
Fire("PLAYER_TARGET_CHANGED")
check(Count() == 3 and Last()[6] == "Foulmane" and Last()[10] == "c", "no XP: corpse clicked recorded")

-- Someone else's kill: its corpse is tap denied.
units.target = { "Old Murk-Eye", "rareelite", 25, Guid(391, "D4"), true, true }
Fire("PLAYER_TARGET_CHANGED")
check(Count() == 3, "someone else's rare corpse is not ours")

-- A rare targeted, then dropped (Esc) with no kill: nothing.
Target("Gruff Swiftbite", "rare", 12, Guid(100, "E5"))
units.target = nil
Fire("PLAYER_TARGET_CHANGED")
now = now + 5
check(Count() == 3, "a target dropped without a kill is nothing")

-- But killed later, not targeted (say by a pet), with XP: named from the message.
now = now + 60
Rares:Killed("Gruff Swiftbite")
check(Count() == 4 and Last()[6] == "Gruff Swiftbite" and Last()[10] == "x", "rare seen earlier, killed untargeted")

-- Mor'Ladim again, a new spawn: counted, not logged.
Target("Mor'Ladim", "rareelite", 35, Guid(522, "A9"))
KillTarget("Mor'Ladim")
check(Count() == 4 and ns.Tally.Total(ns.char.rares[522][1]) == 2 and ns.char.rares[522][1].testpc == 2,
    "second kill counted only, as this PC's")

-- Normal mobs and elites are not rares.
Target("Defias Thug", "normal", 12, Guid(116, "F6"))
KillTarget("Defias Thug")
Target("Hogger", "elite", 11, Guid(448, "F7"))
KillTarget("Hogger")
check(Count() == 4, "normal and elite not logged")

-- Inside an instance -----------------------------------------------------------

inside = true

-- A rare with XP: classification at the target, name from the message.
Target(nil, "rareelite", 32, nil)
Rares:Killed("Kraul Bat")           -- an add, the rare still targeted
now = now + 4
KillTarget("Blind Hunter")
check(Count() == 5 and Last()[6] == "Blind Hunter" and Last()[9] == nil and Last()[10] == "x",
    "instance rare with XP, named from the message")

-- Its corpse clicked soon after: the same kill, nothing new.
units.target = { nil, "rareelite", 32, nil, true, false }
Fire("PLAYER_TARGET_CHANGED")
check(Count() == 5, "instance corpse of a recorded kill adds nothing")

-- Looting it gives the NPC ID to the kill.
loot = { { Guid(4425, "G8") } }
Fire("LOOT_OPENED")
check(Last()[9] == 4425, "loot adds the NPC ID inside an instance")

-- A rare killed while not targeted (say by a pet), with XP, then its corpse
-- clicked: named from the kill list's only kill in the last seconds.
now = now + 20 * 60
kills[#kills + 1] = { t = now - 2, xp = 76, name = "Tormented Soul" }
units.target = { nil, "rare", 14, nil, true, false }
Fire("PLAYER_TARGET_CHANGED")
check(Count() == 6 and Last()[6] == "Tormented Soul" and Last()[10] == "c", "corpse named from the kill list")

-- Two kills just before (area damage): no guess.
now = now + 20 * 60
kills[#kills + 1] = { t = now - 3, xp = 70, name = "Kraul Bat" }
kills[#kills + 1] = { t = now - 1, xp = 90, name = "Agathelos the Raging" }
units.target = { nil, "rareelite", 33, nil, true, false }
Fire("PLAYER_TARGET_CHANGED")
check(Count() == 7 and Last()[6] == nil, "several kills just before: left nameless")

-- A rare with no XP: its corpse clicked records it without a name.
now = now + 20 * 60
units.target = { nil, "rare", 28, nil, true, false }
Fire("PLAYER_TARGET_CHANGED")
check(Count() == 8 and Last()[6] == nil and Last()[10] == "c", "instance rare with no XP, nameless")
check((Rares:Describe(Last())) == "Killed a rare", "nameless title")

-- The target cleared just before the XP message: still the rare's kill.
now = now + 20 * 60
Target(nil, "rare", 30, nil)
units.target = nil
Fire("PLAYER_TARGET_CHANGED")
now = now + 0.2
Rares:Killed("Aggem Thorncurse")
check(Count() == 9 and Last()[6] == "Aggem Thorncurse", "message just after the target went")

-- Stats list.
local list = Rares:List()
check(#list == 9 and list[1][1] == "Mor'Ladim" and list[1][2] == 2, "list, first killed first")

-- A rare killed before, killed again unseen (no target, never looked at):
-- counted by name, as this PC's.
now = now + 600
Rares:Killed("Foulmane")
local foulmane
for _, r in pairs(ns.char.rares) do
    if r[3] == "Foulmane" then foulmane = r end
end
check(Count() == 9 and foulmane and ns.Tally.Total(foulmane[1]) == 2 and foulmane[1].testpc == 2,
    "a known rare killed unseen is counted")

-- A rare in an alt's roster copy, still at layout 2, lists with its count.
local shown = ns.view
ns.view = { rares = { [1] = { 3, 50, "Old Rare", 1, "rare" } } }
local old = Rares:List()
check(old[1][1] == "Old Rare" and old[1][2] == 3, "a layout 2 count still lists")
ns.view = shown

-- A seeded journey is left alone.
inside = false
ns.char.seeded = true
Target("Seeded Rare", "rare", 10, Guid(9, "H9"))
KillTarget("Seeded Rare")
check(Count() == 9, "seeded journey not recorded")

if failures > 0 then
    print(("rares_test: %d failure(s)"):format(failures))
    os.exit(1)
end
print("rares_test: ok")
