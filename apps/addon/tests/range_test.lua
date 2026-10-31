-- Offline test of Range.lua. Run with LuaJIT from apps/addon:
-- luajit tests/range_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

date = os.date
local ns = {}
local clock = os.time({ year = 2026, month = 10, day = 22, hour = 15, min = 30, sec = 10 })
ns.Now = function() return clock end
assert(loadfile("RoadToSixty/Range.lua"))("RoadToSixty", ns)
local Range = ns.Range
local DAY = 86400
local midnight = os.time({ year = 2026, month = 10, day = 22, hour = 0, min = 0, sec = 0 })

-- 1. All time by default: everything is in, paths are not copied.
check(Range:IsAll() and Range:Has(0) and Range:Has(clock), "all time holds everything")
local paths = {
    { c = 0, m = "w", x = { 1, 2, 3 }, y = { 1, 2, 3 }, t = { midnight - 2 * DAY, midnight - 3600, midnight + 60 } },
    { c = 0, m = "t", j = "h", x = { 4, 5 }, y = { 4, 5 }, t = { midnight + 120, midnight + 180 } },
    { c = 1, m = "w", x = { 6 }, y = { 6 }, t = {} },     -- from before the journey copy: no times
}
check(Range:TrimPaths(paths) == paths, "all time returns the paths themselves")

-- A deep copy of the paths, to prove trimming changes none of them.
local function Snapshot(list)
    local copy = {}
    for k, v in pairs(list) do copy[k] = type(v) == "table" and Snapshot(v) or v end
    return copy
end
local function Same(a, b)
    for k, v in pairs(a) do
        if type(v) == "table" then
            if type(b[k]) ~= "table" or not Same(v, b[k]) then return false end
        elseif b[k] ~= v then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
local before = Snapshot(paths)

-- 2. Today: from the player's midnight to now.
Range:Set("today")
check(Range.from == midnight and Range.to == clock, "today starts at midnight")
check(not Range:Has(midnight - 1) and Range:Has(midnight) and Range:Has(clock) and not Range:Has(clock + 1), "today's bounds")
check(Range:Label() == "Today", "label")
local trimmed = Range:TrimPaths(paths)
check(#trimmed == 2, "two paths reach into today, got " .. #trimmed)
check(trimmed[1] ~= paths[1] and #trimmed[1].x == 1 and trimmed[1].x[1] == 3, "a path cut to its points in today")
check(Same(paths, before), "trimming changes none of the paths")
check(trimmed[2].j == "h" and #trimmed[2].x == 2, "a path wholly inside keeps its jump")

-- 3. Yesterday: the whole day before, not today.
Range:Set("yesterday")
check(Range.from == midnight - DAY and Range.to == midnight - 1, "yesterday is the day before midnight")
trimmed = Range:TrimPaths(paths)
check(#trimmed == 1 and #trimmed[1].x == 1 and trimmed[1].x[1] == 2 and trimmed[1].j == nil, "only yesterday's point, no jump into it")

-- 4. Last 7 and 30 days: today and the days before it, from a midnight, so
-- the start moves only once a day; and Refresh after the clock moves on.
Range:Set("week")
-- Midnights by the calendar: a clock change in between makes a day 23 or 25 hours.
local function MidnightOf(day) return os.time({ year = 2026, month = 10, day = day, hour = 0 }) end
check(Range.from == MidnightOf(22 - 6) and Range.to == clock, "last 7 days from midnight six days back")
Range:Set("week", clock + 3600)
check(Range.from == MidnightOf(22 - 6), "the start stays put through the day")
Range:Set("month")
check(Range.from == MidnightOf(22 - 29) and not Range:Has(MidnightOf(22 - 29) - 1), "last 30 days")
Range:Set("today")
clock = clock + DAY
Range:Refresh()
check(Range.from == midnight + DAY, "today moves on after midnight")

-- 5. A range with nothing in it trims to no paths; a missing time is
-- outside any range but all time.
Range:Set("yesterday", clock - 100 * DAY)
check(#Range:TrimPaths(paths) == 0 and not Range:Has(nil), "nothing in the range")
check(Same(paths, before), "still unchanged")

-- 6. Back to all time.
Range:Set("all")
check(Range:IsAll() and Range:TrimPaths(paths) == paths and Range:Has(nil), "all time again")

-- 7. A day the clocks go forward an hour at 02:00 (a 23 hour day): the
-- midnight is still that day's, and yesterday is still a whole day.
local dayStart = math.floor(1790000000 / DAY) * DAY     -- a midnight, in the made-up zone's time
local switch = dayStart + 2 * 3600
date = function(format, t)
    assert(format == "*t")
    return os.date("!*t", t + (t >= switch and 3600 or 0))
end
local afternoon = dayStart + 15 * 3600                   -- 16:00 there
Range:Set("today", afternoon)
check(Range.from == dayStart, "today from that day's midnight, got " .. (Range.from - dayStart))
Range:Set("yesterday", afternoon)
check(Range.from == dayStart - DAY and Range.to == dayStart - 1, "yesterday is the whole day before")
date = os.date

-- Phases: levelling up to the cap, the endgame after it, and with a date range both.
Range:SetCap(midnight - DAY)
Range:SetPhase("end", clock)
Range:Set("all", clock)
check(not Range:IsAll() and Range.from == midnight - DAY and Range.to == math.huge, "the endgame runs from the cap")
check(Range:Has(clock) and not Range:Has(midnight - DAY - 1), "the endgame holds only what came after the cap")
Range:SetPhase("lvl", clock)
check(Range.from == 0 and Range.to == midnight - DAY and Range:Has(0) and not Range:Has(clock), "levelling runs to the cap")
local today = Range.Bounds("today", clock)
Range:Set("today", clock)
check(Range.from == today and Range.to == midnight - DAY and not Range:Has(clock), "levelling today, after the cap, holds nothing")
Range:SetPhase("end", clock)
check(Range.from == today and Range.to == clock, "the endgame today is today")
check(Range:Key() == "today|end" and Range:PhaseLabel() == "Endgame", "the key and the label")
Range:SetCap(nil)
Range:Set("all", clock)
check(Range:IsAll() and Range:Key() == "all|all" and Range:PhaseLabel() == "Whole journey",
    "without the cap, every phase is the whole journey")
Range:SetPhase("all", clock)

if failures == 0 then
    print("Range tests passed.")
else
    print(failures .. " range test(s) failed.")
    os.exit(1)
end
