-- Offline test of the realistic seed in Seed.lua with a fake WoW API. Run
-- with LuaJIT from the repo root: luajit tests/seed_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

math.randomseed(42)
local printed = {}
local commands = {}
local ns = {}
ns.Print = function(msg) printed[#printed + 1] = msg end
ns.Command = function(name, _, fn) commands[name] = fn end
ns.ResetCharacter = function()
    ns.char = { segments = {}, events = {}, levels = {},
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 } }
end
ns.Roster = { Rebuild = function() end }
ns.MinimapDirs = { [0] = "Azeroth", [1] = "Kalimdor" }

-- The Human route's zones (and Stormwind City, for the Stockade) as
-- 2000-yard squares around their rough real world positions, so flight
-- masters and docks in Seed.lua are a realistic distance away:
-- { continent, centre x, centre y }.
local ZONES = {
    [1429] = { 0, -9300, -300 },    -- Elwynn Forest
    [1436] = { 0, -10600, 1100 },   -- Westfall
    [1432] = { 0, -5400, -3000 },   -- Loch Modan
    [1433] = { 0, -9400, -2300 },   -- Redridge Mountains
    [1439] = { 1, 6200, 500 },      -- Darkshore
    [1437] = { 0, -3500, -1500 },   -- Wetlands
    [1431] = { 0, -10600, -800 },   -- Duskwood
    [1440] = { 1, 2500, -800 },     -- Ashenvale
    [1453] = { 0, -8800, 600 },     -- Stormwind City
}
function CreateVector2D(x, y) return { x = x, y = y } end
C_Map = {
    GetWorldPosFromMapPos = function(mapID, pos)
        local zone = ZONES[mapID]
        if not zone then return end
        return zone[1], { x = zone[2] - 1000 + pos.x * 2000, y = zone[3] - 1000 + pos.y * 2000 }
    end,
}
UnitRace = function() return "Human", "Human" end
UnitFactionGroup = function() return "Alliance" end
time = os.time
debugprofilestop = function() return os.clock() * 1000 end
C_Timer = { After = function(_, fn) fn() end }
local QUALITIES = { [15210] = 2, [15211] = 2, [1121] = 3, [2244] = 4, [7230] = 3, [6909] = 3 }
GetItemInfo = function(id)
    local quality = QUALITIES[id]
    if quality then return "Item " .. id, "|cff1eff00|Hitem:" .. id .. "|h[Item]|h|r", quality end
end

-- Equip locations for some of the realistic seed's gear.
local EQUIP_LOCS = {
    [38] = "INVTYPE_BODY", [39] = "INVTYPE_LEGS", [40] = "INVTYPE_FEET", [25] = "INVTYPE_WEAPONMAINHAND",
    [2362] = "INVTYPE_SHIELD", [15268] = "INVTYPE_2HWEAPON", [1893] = "INVTYPE_2HWEAPON",
    [6084] = "INVTYPE_LEGS", [7230] = "INVTYPE_2HWEAPON", [6087] = "INVTYPE_LEGS",
    [3228] = "INVTYPE_WRIST", [6909] = "INVTYPE_2HWEAPON", [6907] = "INVTYPE_CHEST",
}
GetItemInfoInstant = function(id)
    return id, nil, nil, EQUIP_LOCS[id]
end

assert(loadfile("RoadToSixty/Seed.lua"))("RoadToSixty", ns)
local started = os.clock()
commands.seed("confirm")
local seconds = os.clock() - started

local char = ns.char
local counts = {}
for _, e in ipairs(char.events) do
    counts[e[2]] = (counts[e[2]] or 0) + 1
end
local points = 0
for _, seg in ipairs(char.segments) do
    points = points + 1 + (seg.d == "" and 0 or select(2, seg.d:gsub(";", "")) + 1)
end
local reasons = {}
for _, seg in ipairs(char.segments) do
    if seg.j then reasons[seg.j] = (reasons[seg.j] or 0) + 1 end
end

print(("realistic seed: %d points, %d segments, %.2f s"):format(points, #char.segments, seconds))
print(("levels %d, deaths %d, quests %d, kills %d, dungeons %d, loot %d"):format(
    counts.lvl or 0, char.totals.deaths, char.totals.quests, char.totals.kills, counts["in"] or 0, counts.loot or 0))
print(("jumps: hearth %d, boat %d, death %d, instance %d, login %d"):format(
    reasons.h or 0, reasons.b or 0, reasons.d or 0, reasons.i or 0, reasons.l or 0))

check(char.seeded, "seed finished")
check(counts.lvl == 29, "levels 2-30 reached, got " .. tostring(counts.lvl))
check(char.levels[30] ~= nil, "level 30 snapshot")
check(points > 25000 and points < 40000, "about 28000 points, got " .. points)
check(char.totals.deaths >= 10 and char.totals.deaths <= 60, "about a death a level, got " .. char.totals.deaths)
check((reasons.b or 0) >= 2, "boats between continents on the Human route")
check((counts.loot or 0) > 5, "some loot")

-- Dungeons: the three Alliance ones in order, each entered at its real
-- entrance, then a hearthstone home.
local ENTRANCES = {
    { "The Deadmines", 1436, 0.426, 0.720 }, { "The Stockade", 1453, 0.405, 0.558 },
    { "Blackfathom Deeps", 1440, 0.143, 0.139 },
}
local runs = {}
for _, e in ipairs(char.events) do
    if e[2] == "in" then runs[#runs + 1] = e end
end
check(#runs == 3, "three Alliance dungeons, got " .. #runs)
for i, expected in ipairs(ENTRANCES) do
    local e = runs[i]
    local c, pos = C_Map.GetWorldPosFromMapPos(expected[2], CreateVector2D(expected[3], expected[4]))
    check(e and e[7] == expected[1], expected[1] .. " is run " .. i)
    check(e and e[3] == c and math.abs(e[4] - pos.x) < 30 and math.abs(e[5] - pos.y) < 30,
        expected[1] .. " entered at its entrance")
end
check((reasons.h or 0) >= 3, "a hearthstone home after each dungeon, got " .. tostring(reasons.h))
local flights = 0
for _, seg in ipairs(char.segments) do
    if seg.m == "t" then flights = flights + 1 end
end
check(flights >= 3, "flights between flight masters, got " .. flights)

-- Gear: the starting kit at level 1, upgrades logged as "eq" events, each
-- level snapshot holding the gear worn then, and the dungeon loot worn.
local g1, g30 = char.levels[1].gear, char.levels[30].gear
check(g1 and g1[4] == 38 and g1[16] == 25 and g1[17] == 2362, "starting gear at level 1")
check(g30 and g30[16] == 6909 and g30[17] == nil, "Strike of the Hydra in both hands by 30")
check(g30 and g30[7] == 6087, "Chausses of Westfall from the Deadmines quest")
check(g30 and g30[9] == 3228, "Jimmied Handcuffs from the Stockade")
check(g30 and g30[5] == 6907, "Tortoise Armor from Blackfathom Deeps")
check((counts.eq or 0) >= 8, "gear changes logged, got " .. tostring(counts.eq))

-- Time only moves forward.
local last = 0
for _, e in ipairs(char.events) do
    check(e[1] >= last, "event times in order")
    last = e[1]
end

if failures == 0 then
    print("Seed tests passed.")
else
    print(failures .. " seed test(s) failed.")
    os.exit(1)
end
