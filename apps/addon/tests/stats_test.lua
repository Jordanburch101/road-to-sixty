-- Offline test of Stats.lua (#83): running totals over a small made-up
-- journey, asked for windows of it: all of it, a moment, logged-out time,
-- zones, the level at a time, the level rows, and that all time matches the
-- journey's own totals. Run with LuaJIT from apps/addon:
-- luajit tests/stats_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Packed.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/GearTimeline.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Stats.lua"))("RoadToSixty", ns)
local Stats = ns.Stats

-- Two sessions, 1000 to 2000 and 5000 to 6000: level 10 at the start, 11 at 5100.
local journey = {
    events = {
        { 1000, "on", 0, 0, 0, 10 },
        { 1000, "zone", 0, 0, 0, 1429 },
        { 1100, "qd", 0, 0, 0, 7, 500, 100 },
        { 1200, "die", 0, 0, 0 },
        { 1300, "in", 0, 0, 0, 36, "Deadmines", "party" },
        { 1500, "zone", 0, 0, 0, 1436 },
        { 1600, "in", 0, 0, 0, 489, "Warsong Gulch", "pvp" },
        { 2000, "off", 0, 0, 0 },
        { 5000, "on", 0, 0, 0, 10 },
        { 5100, "qd", 0, 0, 0, 8, 300 },
        { 5100, "lvl", 0, 0, 0, 11 },
        { 6000, "off", 0, 0, 0 },
    },
    kills = ns.Packed.PackKills({
        { t = 1050, xp = 50, name = "Kobold" }, { t = 1150, xp = 60, name = "Wolf" }, { t = 5050, xp = 70, name = "Kobold" },
    }),
    segments = {
        { m = "w", c = 0, t = 1000, x = 0, y = 0, d = "10,3,4;10,6,8" },   -- 5 and 10 yards
        { m = "t", c = 0, t = 5200, x = 0, y = 0, d = "100,30,40" },        -- 50 yards flown
    },
    levels = {
        [10] = { t = 1000, played = 0, money = 1000, kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0,
            instances = 0, distance = 0, flown = 0, partial = true },
        [11] = { t = 5100, played = 1100, money = 3000, kills = 3, killXP = 180, questXP = 800, deaths = 1, quests = 2,
            instances = 2, distance = 15, flown = 0 },
    },
    totals = { kills = 3, killXP = 180, questXP = 800, deaths = 1, quests = 2, instances = 2, distance = 15, flown = 50 },
}

local index = Stats.Index(journey, 6000, 3500)

-- 1. All of it.
local all = Stats.Window(index)
check(all.played == 2000, "played is the time logged in, got " .. all.played)
check(all.kills == 3 and all.killXP == 180, "kills and their XP")
check(all.quests == 2 and all.questXP == 800 and all.questMoney == 100, "quests, their XP and money")
check(all.deaths == 1, "deaths")
check(all.dungeons == 1 and all.battlegrounds == 1, "a battleground is counted apart from dungeon runs")
check(all.walked == 15 and all.flown == 50, "yards walked and flown, got " .. all.walked .. " and " .. all.flown)
check(all.gold == 2500, "gold is the change in gold held, up to the gold held now, got " .. tostring(all.gold))
check(all.levelFrom == 10 and all.levelTo == 11, "the levels at its start and end")
local t = journey.totals
check(all.kills == t.kills and all.killXP == t.killXP and all.questXP == t.questXP and all.deaths == t.deaths
    and all.quests == t.quests and all.walked == t.distance and all.flown == t.flown,
    "all time matches the journey's own totals")

-- 2. A window: both ends count.
local w = Stats.Window(index, 1100, 1200)
check(w.played == 100 and w.kills == 1 and w.killXP == 60 and w.quests == 1 and w.deaths == 1,
    "a window counts what is inside it, both ends included")
check(w.walked == 0 and w.gold == 0, "nothing walked and no snapshot inside it")

-- 3. Logged-out time adds nothing.
w = Stats.Window(index, 2000, 5000)
check(w.played == 0 and w.kills == 0, "logged out from 2000 to 5000")

-- 4. Windows outside the journey are cut to it; one ending before it starts is empty.
w = Stats.Window(index, 0, 99999)
check(w.from == 1000 and w.to == 6000 and w.played == 2000, "a window is cut to the journey")
w = Stats.Window(index, 5500, 5400)
check(w.played == 0 and w.kills == 0, "a window ending before it starts is empty")

-- 5. Zones: each entry lasts until the next, in time played, most first.
check(#all.zones == 2 and all.zones[1][1] == 1436 and all.zones[1][2] == 1500 and all.zones[2][2] == 500,
    "time played per zone, most first")
w = Stats.Window(index, 1400, 1600)
check(#w.zones == 2 and w.zones[1][2] == 100 and w.zones[2][2] == 100, "the zone already entered counts from the window's start")

-- 6. The level at a time, and how far through it by time played.
local level, fraction = Stats.LevelAt(index, 3000)
check(level == 10 and math.abs(fraction - 1000 / 1100) < 1e-9, "level 10, 1000 of its 1100 seconds played")
level, fraction = Stats.LevelAt(index, 5550)
check(level == 11 and math.abs(fraction - 0.5) < 1e-9, "level 11, halfway to the journey's end")

-- 7. Level rows: the change from one snapshot to the next; the level now runs to now.
local rows = Stats.Levels(journey, 11, { played = 2000, money = 3500 })
check(#rows == 2 and rows[1].partial and rows[1].time == 1100 and rows[1].kills == 3 and rows[1].xp == 980
    and rows[1].gold == 2000 and rows[1].dungeons == 2 and rows[1].walked == 15, "level 10's row")
check(rows[2].t == 5100 and rows[2].c == 0 and rows[1].t == 1000 and rows[1].c == nil,
    "each row has when its level was reached, and where when its lvl event says")
check(Stats.ZoneAt(index, 1499) == 1429 and Stats.ZoneAt(index, 1500) == 1436 and Stats.ZoneAt(index, 999) == nil,
    "the zone at a time")
check(rows[2].current and rows[2].time == 900 and rows[2].kills == 0 and rows[2].gold == 500 and rows[2].flown == 50,
    "the level now runs to now")

-- 8. The index knows when the journey has changed.
check(not Stats.Changed(index, journey), "an unchanged journey keeps its index")
table.insert(journey.events, { 6100, "die", 0, 0, 0 })
check(Stats.Changed(index, journey), "a new event changes it")

-- 8a. Records: one session from 0 to 10000, levels 10 to 13.
local rj = {
    events = {
        { 0, "on", 0, 0, 0, 10 },
        { 500, "die", 0, 0, 0, "Wolf" },
        { 1000, "lvl", 0, 10, 20, 11 },
        { 1500, "die", 0, 30, 40, "Wolf" },
        { 1600, "die", 0, 0, 0, "Bear" },
        { 2000, "gath", 0, 0, 0, "m", 2770 },
        { 2100, "gath", 0, 0, 0, "m", 2770 },
        { 2200, "gath", 0, 0, 0, "h", 2447 },
        { 2500, "in", 0, 0, 0, 36, "Deadmines", "party" },
        { 3000, "lvl", 0, 0, 0, 12 },
        { 3500, "in", 0, 0, 0, 36, "Deadmines", "party" },
        { 4000, "lvl", 0, 0, 0, 13 },
        { 4500, "in", 0, 0, 0, 34, "The Stockade", "party" },
        { 4600, "in", 0, 0, 0, 489, "Warsong Gulch", "pvp" },
        { 5000, "die", 0, 0, 0 },
        { 10000, "off", 0, 0, 0 },
    },
    kills = ns.Packed.PackKills({
        { t = 100, xp = 10, name = "Kobold" }, { t = 200, xp = 10, name = "Wolf" },
        { t = 1200, xp = 10, name = "Kobold" }, { t = 2600, xp = 10, name = "Kobold" },
    }),
    levels = {
        [10] = { t = 0, played = 0, killXP = 0, questXP = 0, money = 100 },
        [11] = { t = 1000, played = 1000, killXP = 500, questXP = 500, money = 900 },
        [12] = { t = 3000, played = 3000, killXP = 600, questXP = 400, money = 500 },
        [13] = { t = 4000, played = 4000, killXP = 1500, questXP = 1000, money = 2000 },
    },
}
local ri = Stats.Index(rj, 10000, 2500)
local rrows = Stats.Levels(rj, 13, { played = 10000, money = 2500 })
local timeline = { kept = {
    [1] = { { t = 0, endT = 6000, id = 100 }, { t = 6000, endT = 10000, id = 101 } },
    [4] = { { t = 0, endT = 10000, id = 5 } },     -- a shirt, left out
} }
local rec = Stats.Records(ri, nil, nil, rrows, timeline)
check(rec.bestSession and rec.bestSession.xp == 40 and rec.bestSession.from == 0 and rec.bestSession.to == 10000,
    "best session, by XP from kills and quests")
check(rec.slowest and rec.slowest.level == 11 and rec.slowest.seconds == 2000 and rec.slowest.c == 0 and rec.slowest.x == 10,
    "slowest level, placed at its level up")
check(rec.bestRate and rec.bestRate.level == 12 and rec.bestRate.perHour == 5400, "best XP per hour")
check(rec.deadliest and rec.deadliest.level == 11 and rec.deadliest.deaths == 2, "deadliest level")
check(rec.nemesis and rec.nemesis.name == "Wolf" and rec.nemesis.count == 2 and rec.nemesis.x == 30,
    "nemesis, placed at its last kill of you")
check(rec.mostKilled and rec.mostKilled.name == "Kobold" and rec.mostKilled.count == 3 and rec.mostKilled.t == 2600,
    "most killed")
check(rec.longestSession and rec.longestSession.seconds == 10000, "longest session")
check(rec.longestWorn and rec.longestWorn.id == 100 and rec.longestWorn.seconds == 6000, "longest worn, shirts left out")
check(rec.richest and rec.richest.level == 13 and rec.richest.money == 2000, "most gold held at a level up")
check(rec.deathless and rec.deathless.seconds == 5000 and rec.deathless.from == 5000 and rec.deathless.ongoing,
    "longest without dying, still going at the end")
check(rec.favouriteDungeon and rec.favouriteDungeon.name == "Deadmines" and rec.favouriteDungeon.count == 2,
    "favourite dungeon, battlegrounds left out")
check(rec.mostGathered and rec.mostGathered.item == 2770 and rec.mostGathered.count == 2, "most gathered")

rec = Stats.Records(ri, 1100, 2900, rrows, timeline)
check(not rec.slowest and not rec.richest, "no level begun and finished inside a narrow window")
check(rec.bestSession.xp == 20 and rec.bestSession.from == 1100, "best session, the part inside the window")
check(rec.deadliest.deaths == 2 and rec.deathless.seconds == 1300 and rec.deathless.ongoing,
    "deaths and the time between them inside the window")
check(rec.mostKilled.count == 2 and rec.favouriteDungeon.count == 1 and rec.longestWorn.seconds == 1800,
    "kills, runs and gear counted inside the window only")

-- 8b. Path steps out of time order (a clock put right) still count once each.
local stepped = Stats.Index({ events = {}, segments = {
    { m = "w", c = 0, t = 100, x = 0, y = 0, d = "10,3,4" }, { m = "t", c = 0, t = 50, x = 0, y = 0, d = "10,6,8" },
} }, 200)
w = Stats.Window(stepped)
check(w.walked == 5 and w.flown == 10, "steps out of order are sorted, not lost")
check(Stats.Window(stepped, 0, 70).flown == 10 and Stats.Window(stepped, 0, 70).walked == 0, "and kept at their own times")

-- 9. A full-size journey (as parse_test.lua makes one): the index is built
-- once, and a window is cheap enough for the replay to ask every frame.
math.randomseed(7)
local big = { segments = {}, events = {}, levels = {} }
local steps = {}
for i = 1, 30000 do
    steps[i] = ("%d,%d,%d"):format(math.random(1, 9), math.random(-40, 40), math.random(-40, 40))
end
for i = 1, 300 do
    local from = (i - 1) % 100 * 300 + 1
    big.segments[i] = { m = "w", c = i % 2, t = 1791712544 + i * 600, x = 0, y = 0, d = table.concat(steps, ";", from, from + 299) }
end
for i = 1, 30000 do
    big.events[i] = { 1791712544 + i * 7, i % 3 == 0 and "die" or "qd", 0, 0, 0, i, 100 }
end
for level = 2, 60 do
    big.levels[level] = { t = 1791712544 + level * 3500, played = level * 3600, money = level * 1000 }
end
local packed = {}
for i = 1, 20000 do packed[i] = ("%d,%d,%d;"):format(math.random(1, 60), math.random(1, 500), 1) end
big.kills = { d = table.concat(packed), names = { "Mob" } }
local started = os.clock()
local bigIndex = Stats.Index(big, 1791712544 + 210000)
local built = os.clock()
for i = 1, 1000 do Stats.Window(bigIndex, 1791712544 + i * 50, 1791712544 + i * 200) end
local asked = os.clock()
print(("Stats on a full-size journey: index in %d ms, 1000 windows in %d ms."):format(
    math.floor((built - started) * 1000), math.floor((asked - built) * 1000)))
check(asked - built < 1, "1000 windows take under a second")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("Stats tests passed.")
