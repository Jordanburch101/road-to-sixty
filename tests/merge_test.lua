-- Offline test of Merge.lua: each merge rule, the three properties
-- (either order, twice, any grouping) and made-up play across PCs. Run with
-- LuaJIT from the repo root: luajit tests/merge_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
for _, name in ipairs({ "Packed.lua", "Tally.lua", "Parse.lua", "Merge.lua" }) do
    assert(loadfile("RoadToSixty/" .. name))("RoadToSixty", ns)
end
local Merge, Write = ns.Merge, ns.Parse.Write

-- Equal data writes the same text, keys sorted, so this is deep equality.
local function Same(a, b)
    if a == nil or b == nil then return a == b end
    return Write(a) == Write(b)
end

-- A journey at layout 3 with nothing in it, plus the fields given.
local function Journey(fields)
    local j = {
        version = 3, segments = {}, events = {}, levels = {}, recipes = {}, people = {},
        kills = { d = "", last = 0, names = {} },
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 },
    }
    for k, v in pairs(fields or {}) do j[k] = v end
    return j
end

local function On(t) return { t, "on", 0, 0, 0, 10 } end

-- 1. Join keeps everything either copy has.
local J = Merge.Join
check(Same(J({ 1, nil, 3, a = { x = 1 } }, { nil, 2, nil, a = { y = 2 } }), { 1, 2, 3, a = { x = 1, y = 2 } }),
    "tables join key by key, holes included")
check(J(5, 7) == 7 and J("a", "b") == "b" and J(false, true) == true, "of two values, the larger")
check(Same(J(1, { 2 }), { 2 }) and J(nil, 4) == 4, "a table over a value, a value over nothing")

math.randomseed(11)
local function Random(depth)
    local r = math.random(1, depth > 0 and 6 or 4)
    if r == 1 then return math.random(1, 5) end
    if r == 2 then return ("s%d"):format(math.random(1, 3)) end
    if r == 3 then return math.random(1, 2) == 1 end
    if r == 4 then return nil end
    local t = {}
    for _ = 1, math.random(0, 4) do
        local k = math.random(1, 2) == 1 and math.random(1, 4) or ({ "a", "b", "c" })[math.random(1, 3)]
        t[k] = Random(depth - 1)
    end
    return t
end
local joinBroken = 0
for _ = 1, 500 do
    local a, b, c = Random(3), Random(3), Random(3)
    if not Same(J(a, b), J(b, a)) or not Same(J(J(a, b), c), J(a, J(b, c))) or not Same(J(a, a), a) then
        joinBroken = joinBroken + 1
    end
end
check(joinBroken == 0, joinBroken .. " random values broke Join's properties")

-- 2. Copies the merge must not take.
local refused, why = Merge.Merge(Journey({ seeded = true }), Journey())
check(refused == nil and tostring(why):find("seeded"), "a seeded journey is refused: " .. tostring(why))
refused, why = Merge.Merge(Journey(), Journey({ version = 4 }))
check(refused == nil and tostring(why):find("newer"), "a newer layout is refused: " .. tostring(why))
refused, why = Merge.Merge(Journey({ version = 2 }), Journey())
check(refused == nil and tostring(why):find("older"), "an older layout is refused: " .. tostring(why))

-- 3. Current state comes from the copy seen last, gaps included; a tie joins.
local older = Journey({ events = { On(100) }, guild = { "Old Guild", "Member", 3 }, instance = 36, lastZone = 1429, future = "a" })
local newer = Journey({ events = { On(200) }, guild = false, lastZone = 1436, future = "b" })
local m = Merge.Merge(older, newer)
check(m.guild == false and m.instance == nil and m.lastZone == 1436, "state from the copy seen last, nil included")
check(m.future == "b", "a field this merge doesn't know is state too")
check(Same(Merge.Merge(older, newer), Merge.Merge(newer, older)), "state is the same either way round")
m = Merge.Merge(Journey({ events = { On(100) }, lastZone = 1429 }), Journey({ events = { On(100) }, gear = { [1] = 5 } }))
check(m.lastZone == 1429 and m.gear[1] == 5, "copies seen last at the same time join")

-- 4. The merge's own fields.
m = Merge.Merge(Journey({ rosterBuilt = 3, played = 50, clockFrom = 10 }),
    Journey({ played = 70, clockFrom = 20, recipes = { Cooking = { Bread = true } } }))
check(m.version == 3 and m.rosterBuilt == nil, "layout 3, and the roster copy to be rebuilt")
check(m.played == 70 and m.clockFrom == 20 and m.recipes.Cooking.Bread, "played, clockFrom and recipes keep the most")
check(older.instance == 36 and #older.events == 1 and older.guild[1] == "Old Guild", "the inputs are not changed")

if failures == 0 then
    print("Merge tests passed.")
else
    print(failures .. " merge test(s) failed.")
    os.exit(1)
end
