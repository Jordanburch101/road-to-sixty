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

-- A journey at layout 4 with nothing in it, plus the fields given.
local function Journey(fields)
    local j = {
        version = 4, segments = {}, events = {}, levels = {}, recipes = {}, people = {},
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
refused, why = Merge.Merge(Journey(), Journey({ version = 5 }))
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
check(m.version == 4 and m.rosterBuilt == nil, "layout 4, and the roster copy to be rebuilt")
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
m = Merge.Merge(Journey({ events = { { 151, "skill", 0, 0, 0, "Mining", 120, 119 }, { 151, "skill", 0, 0, 0, "Cooking", 80, 79 } } }),
    Journey({ events = { { 151, "skill", 0, 0, 0, "Cooking", 80, 79 } } }))
check(#m.events == 2 and m.events[1][6] ~= m.events[2][6], "skill points of two professions in one second are matched by name")

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

-- Two segments opened in one second with the same continent and mode (the
-- clock stepping back at the switch to the realm's clock) are told apart by
-- where they start, which never changes as a path grows.
local function At(x, d) return { m = "w", c = 0, t = 100, x = x, y = x, d = d } end
local staleSegs = Journey({ segments = { At(0, "1,5,5;1,5,5;1,5,5"), At(900, "") } })
local newerSegs = Journey({ segments = { At(0, "1,5,5;1,5,5;1,5,5"), At(900, "1,1,1") } })
m = Merge.Merge(Merge.Merge(staleSegs, newerSegs), staleSegs)
check(Same(m.segments, { At(0, "1,5,5;1,5,5;1,5,5"), At(900, "1,1,1") }), "segments in one second are matched by where they start")
local empties = Journey({ segments = { At(5, ""), At(1, ""), At(3, "") } })
m = Merge.Merge(empties, empties)
check(Same(Merge.Merge(m, m), m) and m.segments[1].x == 1, "and sorted by where they start")

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

-- 10. Riding and mounts: the earliest note of each wins; a mount logged in
-- either copy stays logged.
local horse = { 650, 0, 3, 4, 40 }
horse.logged = true
m = Merge.Merge(
    Journey({ riding = { [33388] = { "Apprentice Riding", 500, 40 } }, mounts = { [6] = { 600, 0, 1, 2, 40, true } } }),
    Journey({ riding = { [33388] = { "Apprentice Riding", 450, 40 } }, mounts = { [6] = horse, [7] = { 700, 0, 0, 0, 41 } } }))
check(m.riding[33388][2] == 450, "riding: the earliest note")
check(m.mounts[6][1] == 600 and m.mounts[6][6] == true and m.mounts[6].logged == true, "mounts: the earliest note, logged from either")
check(m.mounts[7][1] == 700, "a mount in one copy only")
check(Merge.Merge(Journey({ mounts = { [6] = { 600 } } }), Journey()).mounts[6][1] == 600, "a copy with no mounts at all")

-- 11. People: tallies keep the higher part per PC; where and when first
-- met from the copy that met them first, the rest from the one that saw
-- them last.
local pa = { name = "Ann", level = 10, guild = "Old", first = 100, last = 150, c = 0, x = 1, y = 1,
    groups = { pca = 2 }, seconds = { pca = 600 } }
local pb = { name = "Ann", level = 14, guild = "New", first = 200, last = 300, c = 1, x = 5, y = 5,
    groups = { pca = 1, pcb = 3 } }
m = Merge.Merge(Journey({ people = { g = pa } }), Journey({ people = { g = pb, h = { name = "Bob", first = 5, last = 5 } } }))
local p = m.people.g
check(p.groups.pca == 2 and p.groups.pcb == 3 and p.seconds.pca == 600 and ns.Tally.Total(p.groups) == 5,
    "tallies: the higher part per PC")
check(p.first == 100 and p.c == 0 and p.x == 1 and p.last == 300 and p.level == 14 and p.guild == "New",
    "first met from the earlier copy, the rest from the later")
check(m.people.h.name == "Bob", "people in one copy only are kept")

-- 12. Rares: kills tallied per PC, the first kill the earliest.
m = Merge.Merge(Journey({ rares = { [522] = { { pca = 2 }, 500, "Mor'Ladim", 522, "rareelite" } } }),
    Journey({ rares = { [522] = { { pca = 1, pcb = 1 }, 450, "Mor'Ladim", 522, "rareelite" },
        Foulmane = { { pcb = 1 }, 900, "Foulmane" } } }))
local r = m.rares[522]
check(ns.Tally.Total(r[1]) == 3 and r[2] == 450 and r[3] == "Mor'Ladim", "a rare's kills per PC, its first kill the earliest")
check(m.rares.Foulmane[2] == 900, "rares in one copy only are kept")
check(Merge.Merge(Journey(), Journey()).rares == nil, "no rares in either stays none")

-- A rare killed for the first time on two PCs before they were linked logs
-- a first kill on each. Both events stay (the merge keeps events, it can't
-- tell which first kill the player cares about); the rare's entry has the
-- earliest. A known limit, listed in the plan's notes.
m = Merge.Merge(
    Journey({ events = { { 450, "rare", 0, 0, 0, "Mor'Ladim", "rareelite", 35, 522, "x" } },
        rares = { [522] = { { pca = 1 }, 450, "Mor'Ladim", 522, "rareelite" } } }),
    Journey({ events = { { 500, "rare", 0, 0, 0, "Mor'Ladim", "rareelite", 35, 522, "x" } },
        rares = { [522] = { { pcb = 1 }, 500, "Mor'Ladim", 522, "rareelite" } } }))
check(#m.events == 2 and m.rares[522][2] == 450 and ns.Tally.Total(m.rares[522][1]) == 2,
    "two first kills of one rare from two unlinked PCs both stay")

-- 13. Prepare brings a layout 2 upload up, its counts as the PC it came from.
local old = Journey({ version = 2, people = { g = { groups = 3 } }, rares = { [1] = { 2, 10 } } })
check(Merge.Prepare(old, "pcz") == old and old.version == 4 and old.people.g.groups.pcz == 3 and old.rares[1][1].pcz == 2,
    "a layout 2 upload is prepared")
local none, reason = Merge.Prepare(Journey({ version = 1 }), "pcz")
check(none == nil and reason, "layout 1 is refused")
none, reason = Merge.Prepare(Journey({ version = 5 }), "pcz")
check(none == nil and tostring(reason):find("newer"), "a newer layout is refused")
check(Merge.Prepare(Journey(), "pcz").version == 4, "layout 4 is left as it is")
check(Merge.Prepare(Journey({ version = 3 }), "pcz").version == 4, "layout 3 comes up to 4 as it is: it has no stamp yet")
for _, bad in ipairs({ { totals = 5 }, { kills = "x" }, { levels = 1 }, { events = { 1 } }, { events = { { "t", "on" } } },
    { totals = { kills = "many" } }, { kills = { d = 5 } } }) do
    local damaged = Journey()
    for k, v in pairs(bad) do damaged[k] = v end
    none, reason = Merge.Prepare(damaged, "pcz")
    check(none == nil and tostring(reason):find("damaged"), "a damaged journey is refused: " .. Write(bad) .. " " .. tostring(reason))
end

-- 14. Check: a result holds every session and no count went down.
local function Copy(t) return ns.Parse.Read(Write(t)) end
m = Merge.Merge(A, B)
check(Merge.Check(A, B, m), "a merge passes its own check")
local bad = Copy(m)
for i = #bad.events, 1, -1 do
    if bad.events[i][2] == "on" and bad.events[i][1] == 200 then table.remove(bad.events, i) end
end
local passed, failed = Merge.Check(A, B, bad)
check(not passed and tostring(failed):find("session"), "a lost session fails: " .. tostring(failed))
bad = Copy(m)
bad.totals.kills = 1
passed, failed = Merge.Check(A, B, bad)
check(not passed and tostring(failed):find("kills"), "a lower total fails: " .. tostring(failed))
local P1, P2 = Journey({ people = { g = { groups = { pca = 2 } } } }), Journey({ people = { g = { groups = { pcb = 1 } } } })
bad = Merge.Merge(P1, P2)
bad.people.g.groups.pca = 1
passed, failed = Merge.Check(P1, P2, bad)
check(not passed and tostring(failed):find("tally"), "a lower tally fails: " .. tostring(failed))

-- 15. Made-up play: twelve sessions, each on one PC, never overlapping. A
-- copy is built by playing its sessions the way the addon records them:
-- snapshot counts from that copy's own totals, tallies under its PC.
-- Merging the copies must give the journey that played every session.
math.randomseed(5)
local GUIDS = { "Player-1-0001", "Player-1-0002", "Player-1-0003", "Player-1-0004" }
local MOBS = { "Kobold Vermin", "Young Wolf", "Defias Thug" }
local COUNTS = { "kills", "killXP", "quests", "questXP", "deaths", "instances", "distance", "flown" }
local SESSIONS, startLevel = {}, 1
for n = 1, 12 do
    local t0 = n * 10000
    local s = { level = startLevel, levelUp = n % 2 == 0, die = n % 4 == 0, instance = n % 5 == 0,
        meet = GUIDS[n % 4 + 1], rare = n % 3 == 1 and 1000 + n or nil, zone = 1429 + n % 3, kills = {}, paths = {} }
    for i = 1, 4 do s.kills[i] = { t0 + 10 * i, math.random(20, 80), MOBS[math.random(1, 3)] } end
    local walk = { m = "w", t = t0 + 50, x = math.random(-500, 500), y = math.random(-500, 500), steps = {} }
    for i = 1, 3 do walk.steps[i] = { 5, math.random(-30, 30), math.random(-30, 30) } end
    s.paths[1] = walk
    if n % 3 == 0 then s.paths[2] = { m = "t", t = t0 + 100, x = 0, y = 0, steps = { { 5, 300, 40 }, { 5, 250, -60 } } } end
    if s.levelUp then startLevel = startLevel + 1 end
    SESSIONS[n] = s
end

local function Play(copy, n, pc)
    local s, t0, totals = SESSIONS[n], n * 10000, copy.totals
    local function Log(t, kind, ...) copy.events[#copy.events + 1] = { t, kind, 0, 0, 0, ... } end
    local function Snapshot(level, t, partial)
        local snap = { t = t, partial = partial or nil, money = level * 100, gear = { [1] = level } }
        for _, f in ipairs(COUNTS) do snap[f] = math.floor(totals[f]) end
        copy.levels[level] = snap
    end
    Log(t0, "on", s.level)
    if not copy.levels[s.level] then Snapshot(s.level, t0, s.level > 1) end
    local kills = {}
    ns.Packed.DecodeKills(copy.kills.d, copy.kills.names, 0, kills)
    for _, k in ipairs(s.kills) do
        kills[#kills + 1] = { t = k[1], xp = k[2], name = k[3] }
        totals.kills, totals.killXP = totals.kills + 1, totals.killXP + k[2]
    end
    copy.kills = ns.Packed.PackKills(kills)
    for _, path in ipairs(s.paths) do
        local parts, field = {}, path.m == "t" and "flown" or "distance"
        for i, step in ipairs(path.steps) do
            parts[i] = table.concat(step, ",")
            totals[field] = totals[field] + math.sqrt(step[2] * step[2] + step[3] * step[3])
        end
        copy.segments[#copy.segments + 1] = { m = path.m, c = 0, t = path.t, x = path.x, y = path.y, d = table.concat(parts, ";") }
    end
    Log(t0 + 150, "qa", n)
    Log(t0 + 160, "qd", n, 300)
    totals.quests, totals.questXP = totals.quests + 1, totals.questXP + 300
    if s.levelUp then
        Snapshot(s.level + 1, t0 + 160)
        Log(t0 + 160, "lvl", s.level + 1)
    end
    if s.die then
        Log(t0 + 170, "die")
        totals.deaths = totals.deaths + 1
    end
    if s.instance then
        Log(t0 + 180, "in", 36, "The Deadmines", "party")
        totals.instances = totals.instances + 1
        Log(t0 + 190, "out", 36)
    end
    local met = copy.people[s.meet] or { first = t0 + 200, c = 0, x = n, y = n }
    copy.people[s.meet] = met
    met.name, met.level, met.last = "Name " .. s.meet, s.level, t0 + 200
    ns.Tally.Add(met, "groups", pc, 1)
    ns.Tally.Add(met, "seconds", pc, 300)
    if s.rare then
        copy.rares = copy.rares or {}
        copy.rares[s.rare] = { { [pc] = 1 }, t0 + 210, "Rare " .. s.rare, s.rare, "rare" }
        Log(t0 + 210, "rare", "Rare " .. s.rare, "rare", s.level, s.rare, "x")
    end
    Log(t0 + 220, "zone", s.zone)
    copy.lastZone, copy.guild, copy.played = s.zone, { "Guild " .. n, "Member", 3 }, n * 300
    Log(t0 + 300, "off")
end

-- A copy that played these { session, pc } in order.
local function Played(list)
    local copy = Journey()
    for _, step in ipairs(list) do Play(copy, step[1], step[2]) end
    return copy
end

local function With(list, more)
    local all = {}
    for _, x in ipairs(list) do all[#all + 1] = x end
    for _, x in ipairs(more) do all[#all + 1] = x end
    return all
end

-- Whether a merge result is the journey that played everything: exact,
-- except distance and flown, which the merge gives in whole yards.
local function Matches(m, truth)
    local want = Copy(truth)
    for _, f in ipairs({ "distance", "flown" }) do
        if math.abs(m.totals[f] - want.totals[f]) > 1 then return false end
        want.totals[f] = m.totals[f]
        for level, s in pairs(want.levels) do
            local got = m.levels[level]
            if not got or math.abs(got[f] - s[f]) > 1 then return false end
            s[f] = got[f]
        end
    end
    return Same(m, want)
end

-- The spec's four cases.
local truth = Played({ { 1, "pca" }, { 2, "pca" }, { 3, "pca" }, { 4, "pcb" }, { 5, "pcb" } })
check(Matches(Merge.Merge(Played({ { 1, "pca" }, { 2, "pca" }, { 3, "pca" } }), Played({ { 4, "pcb" }, { 5, "pcb" } })), truth),
    "a new PC with no data")

local base = { { 1, "pca" }, { 2, "pca" } }
local onA = Played(With(base, { { 3, "pca" }, { 5, "pca" } }))
local onB = Played(With(base, { { 4, "pcb" }, { 6, "pcb" } }))
local both = Merge.Merge(onA, onB)
check(Matches(both, Played(With(base, { { 3, "pca" }, { 4, "pcb" }, { 5, "pca" }, { 6, "pcb" } }))),
    "shared history, then new play on both PCs")
check(Merge.Check(onA, onB, both), "which passes the server's check")
check(Same(Merge.Merge(Played(base), both), both), "an old pre-sync copy against the newer merged one changes nothing")

-- A WTF folder copied by hand keeps the PC ID, so both PCs add to one part
-- and the merge keeps the higher part, not both: one meeting goes
-- uncounted. Events and totals still add up. A known limit, listed in the
-- plan's notes.
local original = Played(base)
local copied = Copy(original)
Play(original, 3, "pca")
Play(copied, 7, "pca")
local handled = Merge.Merge(original, copied)
truth = Played(With(base, { { 3, "pca" }, { 7, "pca" } }))
check(Same(handled.events, truth.events) and handled.totals.kills == truth.totals.kills, "a hand-copied WTF folder: events and totals add up")
check(ns.Tally.Total(handled.people[GUIDS[4]].groups) == ns.Tally.Total(truth.people[GUIDS[4]].groups) - 1,
    "a hand-copied WTF folder: one meeting goes uncounted")

-- 16. The three properties, on made-up copies: a shared start played
-- everywhere, then each session on one of three PCs.
local broken = {}
for seed = 1, 12 do
    math.randomseed(seed)
    local shared, plays, all = math.random(0, 3), { pca = {}, pcb = {}, pcc = {} }, {}
    for n = 1, 12 do
        local pc = n <= shared and "pca" or ({ "pca", "pcb", "pcc" })[math.random(1, 3)]
        all[#all + 1] = { n, pc }
        for name, list in pairs(plays) do
            if n <= shared or name == pc then list[#list + 1] = { n, pc } end
        end
    end
    local a, b, c = Played(plays.pca), Played(plays.pcb), Played(plays.pcc)
    local ab = Merge.Merge(a, b)
    if not Same(ab, Merge.Merge(b, a)) then broken[#broken + 1] = seed .. " either order" end
    if not Same(Merge.Merge(ab, ab), ab) then broken[#broken + 1] = seed .. " twice" end
    local left = Merge.Merge(ab, c)
    if not Same(left, Merge.Merge(a, Merge.Merge(b, c))) then broken[#broken + 1] = seed .. " grouping" end
    if not Matches(left, Played(all)) then broken[#broken + 1] = seed .. " every session" end
    if not Merge.Check(a, b, ab) then broken[#broken + 1] = seed .. " check" end
end
check(#broken == 0, "properties broken (seed, which): " .. table.concat(broken, ", "))

-- 17. A run or group still open at logout is work for whichever PC logs in
-- next. A copy that never saw it (played on a stale copy) doesn't drop it,
-- and once the merged events show it ended, it isn't brought back.
do
    local run = { t = 900, name = "Deadmines", type = "party", pc = "pcA",
        left = { t = 1000, c = 0, x = 0, y = 0, id = 36, summary = { duration = 100 } } }
    local group = { t = 950, kind = "party", pc = "pcA", members = {}, everMet = {}, levels = {}, subs = {},
        seen = 1100, met = 1, kills = 0, xp = 0, quests = 0, deaths = 0, instances = 0 }
    local a = Journey({ events = { On(800) }, run = run, group = group })
    local b = Journey({ events = { On(2000) } })   -- played later on a copy from before the run
    local m = Merge.Merge(a, b)
    check(m.run and m.run.t == 900, "an open run survives a later copy that never saw it")
    check(m.group and m.group.t == 950, "an open group survives a later copy that never saw it")
    check(Same(m, Merge.Merge(b, a)), "keeping an open run or group works either way round")

    local ended = Journey({ events = { On(800), { 1000, "out", 0, 0, 0, 36, { duration = 100 } },
        { 1100, "grpx", 0, 0, 0, { duration = 150 } }, On(2000) } })
    local done = Merge.Merge(a, ended)
    check(done.run == nil, "a run whose out event is in the merged events is not brought back")
    check(done.group == nil, "a group whose grpx event is in the merged events is not brought back")
    check(Same(done, Merge.Merge(ended, a)), "dropping an ended run works either way round")
end

-- The journey stamp (Core.lua): two different journeys never merge, and a
-- copy that has one keeps it whichever copy was seen last.
do
    local a = Journey({ journeyId = "Player-1-0A:0", events = { On(1000) } })
    local erased = Journey({ journeyId = "Player-1-0A:7000", events = { On(8000) } })
    local bare = Journey({ events = { On(2000) } })
    local out, why = Merge.Merge(a, erased)
    check(out == nil and why == "these are two different journeys", "two stamps that differ are refused: " .. tostring(why))
    check(Merge.Merge(a, bare).journeyId == "Player-1-0A:0", "a lone stamp is kept though the other copy was seen last")
    check(Merge.Merge(bare, a).journeyId == "Player-1-0A:0", "and either way round")
    check(Merge.Merge(a, a).journeyId == "Player-1-0A:0", "the same stamp stays")

    local SameJourney = Merge.SameJourney
    check(SameJourney(Journey(), bare), "a journey with no events yet is anyone's start")
    check(SameJourney(Journey({ events = { On(1000), On(3000) } }), Journey({ events = { On(1000), On(5000) } })),
        "two copies that begin with the same event are one journey")
    check(not SameJourney(Journey({ events = { On(1000) } }), Journey({ events = { On(9000) } })),
        "a namesake begins later")
    check(not SameJourney(Journey({ events = { On(1000) } }), Journey({ events = { { 1000, "die", 0, 0, 0 } } })),
        "the same second but another kind of event is another journey")
    check(not SameJourney(Journey({ events = { On(1000) } }), Journey()), "an upload with no events doesn't continue one that has some")
end

-- DATA_VERSION in Core.lua and Merge.VERSION must move together: one
-- without the other refuses every journey.
do
    local core = assert(io.open("RoadToSixty/Core.lua")):read("*a")
    check(tonumber(core:match("local DATA_VERSION = (%d+)")) == Merge.VERSION, "Merge.VERSION matches DATA_VERSION")
end

if failures == 0 then
    print("Merge tests passed.")
else
    print(failures .. " merge test(s) failed.")
    os.exit(1)
end
