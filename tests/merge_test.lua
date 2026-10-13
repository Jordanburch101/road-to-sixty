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

-- 5. Events: matched by time, kind and what they're about; a matched pair
-- keeps what either has.
local e1 = Journey({ events = { On(100), { 105, "qa", 0, 1, 2, 7 }, { 110, "qd", 0, 1, 2, 7, 450 } } })
local e2 = Journey({ events = {
    On(100), { 105, "qa", 0, 1, 2, 7 }, { 110, "qd", 0, 1, 2, 7, 450, nil, "The Title" }, { 120, "off", 0, 1, 2 },
} })
m = Merge.Merge(e1, e2)
check(#m.events == 4 and m.events[3][9] == "The Title" and m.events[4][2] == "off",
    "a session in both becomes one, the fuller copy's, details from either")
local e3 = Journey({ events = { On(300), { 310, "die", 0, 5, 5 }, { 320, "off", 0, 5, 5 } } })
m = Merge.Merge(e2, e3)
check(#m.events == 7 and m.events[5][1] == 300 and m.events[6][2] == "die", "sessions in one copy only are kept, in time order")
check(Same(Merge.Merge(e2, e3), Merge.Merge(e3, e2)), "events merge the same either way round")

local loot = { 130, "loot", 0, 1, 2, "|cff1eff00|Hitem:2:0|h[Sword]|h|r", 2 }
m = Merge.Merge(Journey({ events = { loot, loot } }), Journey({ events = { loot } }))
check(#m.events == 2, "two identical events in one second stay two, never three")

m = Merge.Merge(Journey({ events = { { 140, "qd", 0, 0, 0, 1, 10 }, { 140, "lvl", 0, 0, 0, 5 } } }),
    Journey({ events = { { 140, "qd", 0, 0, 0, 1, 10 } } }))
check(#m.events == 2 and m.events[2][2] == "lvl", "within a second, the fuller copy's order")

m = Merge.Merge(Journey({ events = { { 150, "zone", 0, 0, 0, 1429 } } }), Journey({ events = { { 150, "zone", 0, 0, 0, 1436 } } }))
check(#m.events == 2, "events about different things don't match")
check(Same(m, Merge.Merge(Journey({ events = { { 150, "zone", 0, 0, 0, 1436 } } }), Journey({ events = { { 150, "zone", 0, 0, 0, 1429 } } }))),
    "and they come out in the same order either way round")

m = Merge.Merge(
    Journey({ events = {
        { 160, "grpa", 0, 0, 0, { "Player-1", "Ann" } },
        { 161, "rare", 0, 0, 0, "Mor'Ladim", "rareelite", 35, 522, "x" },
        { 162, "mount", 0, 0, 0, nil, "Brown Horse", 458, "n" },
        { 163, "grps", 0, 0, 0, false, 2 },
    } }),
    Journey({ events = {
        { 160, "grpa", 0, 0, 0, { "Player-1", "Ann", "Human" } },
        { 161, "rare", 0, 0, 0, "Mor'Ladim", "rareelite", 35, 522, "l" },
        { 162, "mount", 0, 0, 0, nil, "Brown Horse", 458, "n" },
        { 163, "grps", 0, 0, 0, false, 2 },
    } }))
check(#m.events == 4 and m.events[1][6][3] == "Human", "grpa, rare, a mount with no ID and the player's grps each match once")

m = Merge.Merge(Journey({ events = { { 170, "newkind", 0, 0, 0, "a" } } }), Journey({ events = { { 170, "newkind", 0, 0, 0, "b" } } }))
check(#m.events == 1 and m.events[1][6] == "b", "a kind this merge doesn't know matches on time and kind alone")

-- Journeys from before #35, by two PCs' own clocks, can seem to overlap:
-- both sessions stay.
m = Merge.Merge(Journey({ events = { On(1000), { 1100, "die", 0, 0, 0 }, { 1200, "off", 0, 0, 0 } } }),
    Journey({ events = { On(1050), { 1150, "off", 0, 0, 0 } } }))
check(#m.events == 5 and m.events[2][1] == 1050 and m.events[4][1] == 1150, "overlapping sessions both kept, in time order")

local unsorted = Journey({ events = { On(500), { 400, "die", 0, 0, 0 } } })
m = Merge.Merge(unsorted, unsorted)
check(m.events[1][1] == 400 and Same(Merge.Merge(m, m), m), "events come out in time order, and stay so")
check(unsorted.events[1][1] == 500, "the input's order is not changed")

-- 6. Path segments: matched by start, continent and mode. A stale copy's
-- path is the start of the newer one, so the longer wins.
local function Seg(t, d, mode, c) return { m = mode or "w", c = c or 0, t = t, x = 10, y = 20, d = d } end
m = Merge.Merge(Journey({ segments = { Seg(100, "5,1,1"), Seg(300, "1,1,1") } }),
    Journey({ segments = { Seg(100, "5,1,1;5,2,2"), Seg(200, "", "t"), Seg(300, "1,1,1", "w", 1) } }))
check(#m.segments == 4 and m.segments[1].d == "5,1,1;5,2,2", "the longer path wins")
check(m.segments[2].m == "t" and m.segments[3].t == 300 and m.segments[3].c == 0 and m.segments[4].c == 1,
    "segments from both, sorted by start, then continent")
check(Same(Merge.Merge(Journey({ segments = { Seg(100, "9,9,9") } }), Journey()).segments, { Seg(100, "9,9,9") }),
    "a copy with no segments")

-- 7. Kills: decoded, the larger count of each kept, packed again.
local Kills = ns.Packed.PackKills
local function Decoded(kills)
    local list = {}
    ns.Packed.DecodeKills(kills.d, kills.names, 0, list)
    return list
end
local k1 = Kills({ { t = 100, xp = 50, name = "Kobold" }, { t = 110, xp = 50, name = "Kobold" } })
local k2 = Kills({ { t = 100, xp = 50, name = "Kobold" }, { t = 110, xp = 50, name = "Kobold" }, { t = 120, xp = 60, name = "Hogger" } })
local k3 = Kills({ { t = 50, xp = 10, name = "Wolf" } })
check(Same(Merge.Merge(Journey({ kills = k1 }), Journey({ kills = k2 })).kills, k2), "a stale copy's kills are the start of the newer one's")
m = Merge.Merge(Journey({ kills = k2 }), Journey({ kills = k3 }))
local list = Decoded(m.kills)
check(#list == 4 and list[1].name == "Wolf" and list[4].name == "Hogger" and m.kills.last == 120,
    "kills from both, in time order, last recomputed")
local twice = Kills({ { t = 100, xp = 50, name = "Kobold" }, { t = 100, xp = 50, name = "Kobold" } })
check(#Decoded(Merge.Merge(Journey({ kills = twice }), Journey({ kills = k1 })).kills) == 3,
    "two kills of one kind in one second stay two")
check(Same(Merge.Merge(Journey({ kills = k3 }), Journey()).kills, k3), "a copy with no kills")

-- 8. Totals are recounted from the merged data. What a copy's totals hold
-- beyond what its data recounts to (counted before the data was kept)
-- carries over, the larger of the two.
local function Totals(t)
    local totals = Journey().totals
    for k, v in pairs(t) do totals[k] = v end
    return totals
end
local A = Journey({
    events = { On(100), { 110, "qd", 0, 0, 0, 1, 300 }, { 120, "die", 0, 0, 0 } },
    kills = Kills({ { t = 105, xp = 40, name = "Kobold" } }),
    segments = { { m = "w", c = 0, t = 100, x = 0, y = 0, d = "1,3,4" }, { m = "t", c = 0, t = 130, x = 0, y = 0, d = "1,6,8" } },
    totals = Totals({ kills = 8, killXP = 40, quests = 1, questXP = 300, deaths = 1, distance = 5.4, flown = 10 }),
})
local B = Journey({
    events = { On(200), { 210, "in", 0, 0, 0, 36, "The Deadmines", "party" } },
    kills = Kills({ { t = 205, xp = 60, name = "Defias Thug" } }),
    totals = Totals({ kills = 1, killXP = 60, instances = 1 }),
})
m = Merge.Merge(A, B)
local tot = m.totals
check(tot.kills == 9 and tot.killXP == 100, "kills recounted, and the 7 counted before kills were kept carried over: " .. tot.kills)
check(tot.quests == 1 and tot.questXP == 300 and tot.deaths == 1 and tot.instances == 1, "quests, deaths and instances recounted")
check(tot.distance == 5 and tot.flown == 10, "distance from walked steps, flown from taxi steps, in whole yards")
check(Same(Merge.Merge(m, m), m) and Same(Merge.Merge(B, A), m), "totals come out the same every way")

-- 9. Level snapshots: a full one over one taken at a later login, then the
-- earliest; counts recounted at its time plus its copy's carry-over.
A.levels = { [5] = { t = 115, kills = 1, killXP = 40, quests = 1, questXP = 300, deaths = 0, instances = 0,
    distance = 5, flown = 0, money = 100, gear = { [1] = 5 } } }
A.levels[8] = { t = 300, partial = true, money = 1 }
B.levels = {
    [5] = { t = 200, partial = true, kills = 1, killXP = 60, quests = 0, questXP = 0, deaths = 0, instances = 0,
        distance = 0, flown = 0, money = 900 },
    [6] = { t = 220, kills = 1, killXP = 60, quests = 0, questXP = 0, deaths = 0, instances = 1, distance = 0, flown = 0 },
    [7] = { t = 230, kills = 1 },
    [8] = { t = 250, partial = true, money = 2 },
}
m = Merge.Merge(A, B)
local s5, s6 = m.levels[5], m.levels[6]
check(s5.money == 100 and not s5.partial and s5.kills == 1 and s5.distance == 5, "the full snapshot wins, its counts as they were")
check(s6.kills == 2 and s6.killXP == 100 and s6.quests == 1 and s6.questXP == 300 and s6.deaths == 1 and s6.instances == 1,
    "a snapshot in one copy only, recounted at its time with the other copy's play: " .. s6.kills)
check(s6.distance == 5 and s6.flown == 10, "and its distance")
check(m.levels[7].kills == 2 and m.levels[7].distance == nil, "a count a snapshot didn't have stays out")
check(m.levels[8].money == 2, "of two later-login snapshots, the earlier")
check(A.levels[5].kills == 1 and B.levels[6].kills == 1, "the inputs' snapshots are not changed")
check(Same(Merge.Merge(m, m), m) and Same(Merge.Merge(B, A), m), "snapshots come out the same every way")

if failures == 0 then
    print("Merge tests passed.")
else
    print(failures .. " merge test(s) failed.")
    os.exit(1)
end
