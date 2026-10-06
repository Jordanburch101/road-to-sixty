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

-- Every zone is a 4000-yard square somewhere on a continent: Kalimdor for the
-- Kalimdor zones of the Human route (Darkshore 1439, Ashenvale 1440).
local KALIMDOR = { [1439] = true, [1440] = true }
function CreateVector2D(x, y) return { x = x, y = y } end
C_Map = {
    GetWorldPosFromMapPos = function(mapID, pos)
        local ox, oy = (mapID % 7) * 5000, (mapID % 5) * 5000
        return KALIMDOR[mapID] and 1 or 0, { x = ox + pos.x * 4000, y = oy + pos.y * 4000 }
    end,
}
UnitRace = function() return "Human", "Human" end
UnitFactionGroup = function() return "Alliance" end
time = os.time
debugprofilestop = function() return os.clock() * 1000 end
C_Timer = { After = function(_, fn) fn() end }
local QUALITIES = { [15210] = 2, [15211] = 2, [1121] = 3, [2244] = 4 }
GetItemInfo = function(id)
    local quality = QUALITIES[id]
    if quality then return "Item " .. id, "|cff1eff00|Hitem:" .. id .. "|h[Item]|h|r", quality end
end

-- Equip locations for some of the seed's gear pool.
local EQUIP_LOCS = {
    [38] = "INVTYPE_BODY", [39] = "INVTYPE_LEGS", [40] = "INVTYPE_FEET", [25] = "INVTYPE_WEAPON",
    [2362] = "INVTYPE_SHIELD", [10399] = "INVTYPE_CHEST", [10328] = "INVTYPE_CHEST",
    [5191] = "INVTYPE_WEAPONMAINHAND", [7717] = "INVTYPE_2HWEAPON",
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
check((counts["in"] or 0) == 4, "four Alliance dungeons, got " .. tostring(counts["in"]))
check((reasons.b or 0) >= 2, "boats between continents on the Human route")
check((counts.loot or 0) > 5, "some loot")

-- Gear: starting gear at level 1, upgrades logged as "eq" events, and each
-- level snapshot holds the gear worn then.
local g1, g30 = char.levels[1].gear, char.levels[30].gear
check(g1 and g1[4] == 38 and g1[16] == 25 and g1[17] == 2362, "starting gear at level 1")
check(g30 and g30[5] == 10328 and g30[16] == 5191, "Scarlet chest and Cruel Barb by level 30")
check(g30 and g30[17] == 2362, "a one-handed weapon keeps the shield")
check((counts.eq or 0) >= 3, "gear changes logged, got " .. tostring(counts.eq))

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
