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
check(all.dungeons == 1, "a battleground is not a dungeon run, got " .. all.dungeons)
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
check(rows[2].current and rows[2].time == 900 and rows[2].kills == 0 and rows[2].gold == 500 and rows[2].flown == 50,
    "the level now runs to now")

-- 8. The index knows when the journey has changed.
check(not Stats.Changed(index, journey), "an unchanged journey keeps its index")
table.insert(journey.events, { 6100, "die", 0, 0, 0 })
check(Stats.Changed(index, journey), "a new event changes it")

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
