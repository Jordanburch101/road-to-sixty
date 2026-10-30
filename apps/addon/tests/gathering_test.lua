-- Offline test of Gathering.lua with fake loot windows: a vein mined over
-- two charges, herbs with a secondary herb, a window closed with full bags
-- and opened again, loot from a mob or a chest, resources known only by
-- their item class, a vein inside an instance, fishing at one spot and then
-- another, and the nodes the map makes of it all. Run with LuaJIT from the
-- repo root: luajit tests/gathering_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers = {}
local now = 1000
local pos = { 0, 100, 100 }     -- continent, x, y in world yards
local ns = { char = { events = {} } }
ns.view = ns.char
ns.Now = function() return now end
ns.Recorder = { Position = function() return pos[1], pos[2], pos[3] end }
ns.Journal = {
    Log = function(_, kind, ...)
        local e = { now, kind, pos[1], pos[2], pos[3], ... }
        table.insert(ns.char.events, e)
        return e
    end,
}
ns.Range = { Has = function() return true end }
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
end
function ns.Command() end
function ns.Print() end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end

-- The loot window: { { itemID, count }, ... } from source, fishing or not.
local window, source, fishing = {}, nil, false
GetNumLootItems = function() return #window end
GetLootSlotLink = function(slot) return ("|cffffffff|Hitem:%d::::::::|h[x]|h|r"):format(window[slot][1]) end
GetLootSlotInfo = function(slot) return "icon", "name", window[slot][2] end
GetLootSourceInfo = function() return source, 1 end
IsFishingLoot = function() return fishing end
-- Item classes for items not in the lists: 99001 a new herb, 99002 cloth,
-- 99003 a new ore, 2835 Rough Stone (Metal & Stone like any ore).
local CLASSES = { [99001] = { 7, 9 }, [99002] = { 7, 5 }, [99003] = { 7, 7 }, [2835] = { 7, 7 } }
GetItemInfoInstant = function(id)
    local class = CLASSES[id] or { 7, 0 }
    return id, "type", "subtype", "slot", "icon", class[1], class[2]
end

assert(loadfile("RoadToSixty/Gathering.lua"))("RoadToSixty", ns)
local Gathering = ns.Gathering

local function Object(id, spawn) return ("GameObject-0-4170-0-12-%d-%s"):format(id, spawn) end
-- A loot window as the client shows it: ready, opened, each slot taken
-- (unless leave, as with full bags), closed.
local function Loot(items, from, fish, leave)
    window, source, fishing = items, from, fish or false
    Fire("LOOT_READY")
    Fire("LOOT_OPENED")
    if not leave then
        for slot = 1, #items do Fire("LOOT_SLOT_CLEARED", slot) end
    end
    Fire("LOOT_CLOSED")
end
local function Last() return ns.char.events[#ns.char.events] end
local function Count() return #ns.char.events end

-- A copper vein: ore and a stone, then its second charge from the same GUID.
Loot({ { 2770, 2 }, { 2835, 1 } }, Object(1731, "A1"))
check(Count() == 1 and Last()[2] == "gath" and Last()[6] == "m" and Last()[7] == 2770 and Last()[8] == 1731
    and Last()[9] == "2770:2,2835:1", "copper vein recorded with its loot")
now = now + 3
Loot({ { 2770, 2 }, { 774, 1 } }, Object(1731, "A1"))
check(Count() == 1 and Last()[9] == "2770:4,2835:1,774:1", "the vein's second charge adds to the same gather")

-- Briarthorn with Swiftthistle: the main herb is Briarthorn, whatever the order.
now = now + 60
Loot({ { 2452, 1 }, { 2450, 3 } }, Object(1621, "B2"))
check(Count() == 2 and Last()[6] == "h" and Last()[7] == 2450, "secondary herb is not the main resource")

-- Bags full: Kingsblood left in the window, which is closed, then opened
-- again and taken. The herb counts once.
now = now + 60
Loot({ { 3356, 2 } }, Object(1624, "B3"), false, true)
check(Count() == 3 and Last()[9] == "", "a gather nothing was taken from yet")
now = now + 10
Loot({ { 3356, 2 } }, Object(1624, "B3"))
check(Count() == 3 and Last()[9] == "3356:2", "a window opened again counts its loot once")

-- Ore off a mob (TBC) or anything without a game object: not a gather.
now = now + 60
Loot({ { 2770, 1 } }, "Creature-0-4170-0-12-2723-C3")
check(Count() == 3, "loot from a creature is not a gather")
-- A chest of cloth: a game object, but no ore or herb.
Loot({ { 2589, 2 } }, Object(2843, "D4"))
check(Count() == 3, "a chest without ore or herbs is not a gather")

-- A herb and an ore a newer client adds, known by their item class; the
-- stone before the ore is not the main resource.
pos = { 0, 500, 500 }
Loot({ { 99001, 2 } }, Object(500000, "E5"))
check(Count() == 4 and Last()[6] == "h" and Last()[7] == 99001, "unknown herb known by its item class")
pos = { 0, 600, 600 }
Loot({ { 2835, 1 }, { 99003, 2 } }, Object(500001, "E6"))
check(Count() == 5 and Last()[6] == "m" and Last()[7] == 99003, "an unknown ore is the main resource, not the stone")

-- Fishing: two catches at one spot are one gather; 50 yards on is another.
now = now + 60
pos = { 0, 300, 300 }
Loot({ { 6291, 1 } }, Object(35591, "F6"), true)
now = now + 20
pos = { 0, 303, 301 }
Loot({ { 6303, 1 } }, Object(35591, "F7"), true)
local firstTrip = Last()
check(Count() == 6 and Last()[6] == "f" and Last()[9] == "6291:1,6303:1", "catches at one spot are one gather")
pos = { 0, 350, 300 }
now = now + 20
Loot({ { 6291, 1 } }, Object(35591, "F8"), true)
check(Count() == 7, "a new fishing spot is a new gather")

-- A vein inside an instance: recorded with its instance, at the door's place.
ns.char.instance = 230
pos = { 0, 100, 100 }
Loot({ { 11370, 3 } }, Object(165658, "I1"))
check(Count() == 8 and Last()[10] == 230, "a gather inside an instance notes the instance")
ns.char.instance = nil

-- The same copper vein much later from the other side, a new spawn (GUID),
-- and a tin vein further on.
now = now + 3600
pos = { 0, 106, 102 }
Loot({ { 2770, 1 } }, Object(1731, "G9"))
pos = { 0, 160, 100 }
Loot({ { 2771, 2 } }, Object(1732, "H1"))
check(Count() == 10, "ten gathers in all")
-- Back at the first fishing spot, a few yards off, catching something else.
pos = { 0, 315, 310 }
Loot({ { 6358, 3 } }, Object(35591, "K3"), true)
check(Count() == 11, "a later trip to a fishing spot is a gather of its own")

local nodes = Gathering:Nodes()
local copper, tin, spot, darkIron
for _, n in ipairs(nodes) do
    if n.item == 2770 then copper = n elseif n.item == 2771 then tin = n elseif n.item == 11370 then darkIron = n end
    if n.prof == "f" and n.count == 2 then spot = n end
end
check(#nodes == 8, "copper, briarthorn, kingsblood, the new herb and ore, tin and two fishing spots are the nodes ("
    .. #nodes .. ")")
check(not darkIron, "a gather inside an instance is not a node at its door")
check(spot and spot.first == firstTrip[1] and #spot.visits == 2 and spot.visits[1][2] == 2 and spot.visits[2][2] == 3
    and spot.loot[6291] == 1 and spot.loot[6358] == 3 and spot.item == 6358,
    "a fishing spot joins its trips, whatever they caught, showing the latest trip's first catch")
check(copper and copper.count == 2 and math.abs(copper.x - 103) < 0.01 and math.abs(copper.y - 101) < 0.01,
    "a vein gathered twice is one node at the middle of its gathers")
check(copper and copper.loot[2770] == 5 and copper.order[1] == 2770 and copper.loot[774] == 1, "a node adds up its loot")
check(copper and copper.first == 1000 and copper.last == now, "a node knows its first and last gather")
check(tin and tin.count == 1, "a different ore nearby is a node of its own")

-- A node whose centre drifts as gathers come in a line, each within reach
-- of the centre so far, is still found from the far side.
ns.view = { events = {} }
for i, x in ipairs({ 9, 17, 22, 25, 27, 29, 30 }) do
    ns.view.events[i] = { i, "gath", 0, x, 0, "h", 3356, nil, "3356:1" }
end
local drift = Gathering:Nodes()
check(#drift == 1 and drift[1].count == 7, "a drifting node stays one node (" .. #drift .. ")")
ns.view = ns.char

-- History: what each gather says (the client knows no item names here).
local title, detail, icon, lines = Gathering:Describe(ns.char.events[1])
check(title == "Mined Item 2770" and detail == "4 Item 2770, 1 Item 2835, 1 Item 774" and icon == "icon"
    and #lines == 3, "a vein's History entry: " .. tostring(title) .. " / " .. tostring(detail))
check(Gathering:Describe(ns.char.events[2]) == "Gathered Item 2450", "a herb's History entry")
check(Gathering:Describe(firstTrip) == "Fished 2 catches", "a fishing spot's History entry")
check(Gathering.CATEGORY.m == "mining" and Gathering.CATEGORY.h == "herbs" and Gathering.CATEGORY.f == "fishing",
    "each profession has its History filter")
check(Gathering.changes > 0, "loot taken counts as a change, so the map builds again")

-- A herb picked between two charges of a thorium vein: the vein stays one gather.
pos = { 0, 800, 800 }
Loot({ { 10620, 2 } }, Object(175404, "L1"))
Loot({ { 13464, 1 } }, Object(176583, "L2"))
Loot({ { 10620, 1 } }, Object(175404, "L1"))
check(Count() == 13 and ns.char.events[12][9] == "10620:3", "a herb between a vein's charges does not split it")

-- A chest with an Iron Bar (Metal & Stone by class) among its gear: not a vein.
CLASSES[3575], CLASSES[99010] = { 7, 7 }, { 4, 0 }
Loot({ { 3575, 1 }, { 99010, 1 } }, Object(2843, "L3"))
check(Count() == 13, "a chest with a bar among other things is not a gather")

-- Nothing taken (full bags, never opened again): History says so.
Loot({ { 2770, 1 } }, Object(1731, "M1"), false, true)
local _, nothing = Gathering:Describe(Last())
check(Count() == 14 and nothing == "Nothing taken", "a gather with nothing taken: " .. tostring(nothing))

-- A seeded journey records nothing.
ns.char.seeded = true
Loot({ { 2770, 1 } }, Object(1731, "J2"))
check(Count() == 14, "a seeded journey records no gathers")

if failures > 0 then
    print(failures .. " gathering test(s) failed.")
    os.exit(1)
end
print("Gathering tests passed.")
