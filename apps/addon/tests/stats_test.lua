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
check(rec.richest and rec.richest.level == 13 and rec.richest.money == 2500, "most gold held, the gold held now too")
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

-- 8c. Life at the window's end.
local lj = {
    events = {
        { 0, "on", 0, 0, 0, 10 },
        { 0, "prof", 0, 0, 0, "Mining", 1, 75, true },
        { 100, "skill", 0, 0, 0, "Mining", 2, 1 },
        { 200, "rep", 0, 0, 0, 72, 6, "Stormwind", true },
        { 300, "gj", 0, 0, 0, "The Raiders", "Member" },
        { 400, "prof", 0, 0, 0, "Mining", 60, 150 },
        { 450, "skill", 0, 0, 0, "Mining", 61, 60 },
        { 500, "ride", 0, 0, 0, 33388 },
        { 600, "mount", 0, 0, 0, 6 },
        { 700, "rep", 0, 0, 0, 47, 5, "Ironforge", true },
        { 800, "gl", 0, 0, 0, "The Raiders" },
        { 900, "off", 0, 0, 0 },
    },
    levels = { [10] = { t = 0, skills = { Mining = { 1, 75 } } } },
    skills = { Mining = { 61, 150 }, Cooking = { 30, 75 } },
    reps = { [72] = { 6, "Stormwind" }, [47] = { 5, "Ironforge" }, [69] = { 4, "Darnassus" } },
}
local li = Stats.Index(lj, 900)
local life = Stats.Life(li, nil, 350)
local mining = life.professions[1]
check(mining and mining.name == "Mining" and mining.rank == 2 and mining.max == 75 and mining.gained == 1,
    "a profession's rank at the window's end, its cap carried from the prof before")
check(#life.professions == 1, "a profession first seen at the end is not there before")
check(life.reputation[1].name == "Stormwind" and life.reputation[1].standing == 6 and life.reputation[1].reached == 200,
    "a standing reached inside the window")
local ironforge, darnassus
for _, f in ipairs(life.reputation) do
    if f.name == "Ironforge" then ironforge = f elseif f.name == "Darnassus" then darnassus = f end
end
check(ironforge and ironforge.standing == 4 and not ironforge.reached, "before its first change, one below it")
check(darnassus and darnassus.standing == 4, "a faction never changed stands as last seen")
check(life.guild == "The Raiders", "in the guild by then")
life = Stats.Life(li, 350, 900)
check(life.professions[1].rank == 61 and life.professions[1].max == 150 and life.professions[1].gained == 59
    and #life.professions == 2, "the professions last seen count at the end")
check(life.guild == nil, "left the guild")

-- 8d. Zones keep where they were first entered in the window.
check(all.zones[1][3] and all.zones[1][3].t == 1500, "a zone's first entry")
check(all.zones[1][4][10] == 600 and all.zones[1][4][11] == 900 and all.zones[2][4][10] == 500,
    "a zone's time split at the level ups in it")

-- 8e. The endgame: raids apart from dungeons, gold at logins and logouts
-- (#86), the first epic, and weeks since the cap.
local WEEK = 7 * 86400
local ej = {
    events = {
        { 0, "on", 0, 0, 0, 59, 1000 },
        { 100, "lvl", 0, 5, 5, 60 },
        { 200, "in", 0, 0, 0, 409, "Molten Core", "raid" },
        { 300, "loot", 0, 7, 7, "|cffa335ee|Hitem:17076::::::::60:::::|h[Bonereaver's Edge]|h|r", 4 },
        { 400, "in", 0, 0, 0, 329, "Stratholme", "party" },
        { 500, "off", 0, 0, 0, 9000 },
        { WEEK + 100, "on", 0, 0, 0, 60, 9000 },
        { WEEK + 200, "in", 0, 0, 0, 409, "Molten Core", "raid" },
        { WEEK + 300, "in", 0, 0, 0, 249, "Onyxia's Lair", "raid" },
        { WEEK + 350, "out", 0, 9, 9, 249, { name = "Onyxia's Lair", type = "raid", deaths = 4, duration = 50 } },
        { WEEK + 400, "in", 0, 0, 0, 329, "Stratholme", "party" },
        { WEEK + 3000, "off", 0, 0, 0, 4000 },
    },
    levels = { [59] = { t = 0, money = 1000 }, [60] = { t = 100, money = 1500 } },
}
local ei = Stats.Index(ej, WEEK + 3000)
local ew = Stats.Window(ei)
check(ew.dungeons == 5 and ew.raids == 3, "raids are dungeons too, and counted apart")
check(Stats.Window(ei, 0, 600).gold == 8000 and Stats.Window(ei, WEEK, WEEK + 3000).gold == -5000,
    "gold over time from the logins and logouts")
local weeks = Stats.Weeks(ei, 100)
check(#weeks == 2 and weeks[1].from == 100 and weeks[2].from == 100 + WEEK and weeks[2].week == 2, "weeks since the cap")
check(#Stats.Weeks(ei, nil) == 0, "no weeks without the cap")
local er = Stats.Records(ei, nil, nil, Stats.Levels(ej, 60), nil, 100)
check(er.favouriteRaid and er.favouriteRaid.name == "Molten Core" and er.favouriteRaid.count == 2, "favourite raid")
check(er.favouriteDungeon and er.favouriteDungeon.name == "Stratholme" and er.favouriteDungeon.count == 2,
    "favourite dungeon, raids left out")
check(er.firstEpic and er.firstEpic.link:find("Bonereaver", 1, true) and er.firstEpic.x == 7, "first epic, where it dropped")
check(er.busiestWeek and er.busiestWeek.week == 2 and er.mostRaidsWeek and er.mostRaidsWeek.week == 2
    and er.mostRaidsWeek.count == 2, "the busiest week and the one with the most raids")
check(er.richest and er.richest.money == 9000 and er.richest.level == 60, "most gold held, at a logout too")
check(er.deadliestRaid and er.deadliestRaid.name == "Onyxia's Lair" and er.deadliestRaid.deaths == 4
    and er.deadliestRaid.x == 9, "the deadliest raid, from its summary")

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
