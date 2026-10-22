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

-- 2. Today: from the player's midnight to now.
Range:Set("today")
check(Range.from == midnight and Range.to == clock, "today starts at midnight")
check(not Range:Has(midnight - 1) and Range:Has(midnight) and Range:Has(clock) and not Range:Has(clock + 1), "today's bounds")
check(Range:Label() == "Today", "label")
local trimmed = Range:TrimPaths(paths)
check(#trimmed == 2, "two paths reach into today, got " .. #trimmed)
check(trimmed[1] ~= paths[1] and #trimmed[1].x == 1 and trimmed[1].x[1] == 3, "a path cut to its points in today")
check(#paths[1].x == 3 and paths[1].t[1] == midnight - 2 * DAY, "the path itself is not changed")
check(trimmed[2].j == "h" and #trimmed[2].x == 2, "a path wholly inside keeps its jump")

-- 3. Yesterday: the whole day before, not today.
Range:Set("yesterday")
check(Range.from == midnight - DAY and Range.to == midnight - 1, "yesterday is the day before midnight")
trimmed = Range:TrimPaths(paths)
check(#trimmed == 1 and #trimmed[1].x == 1 and trimmed[1].x[1] == 2 and trimmed[1].j == nil, "only yesterday's point, no jump into it")

-- 4. Last 7 and 30 days, and Refresh after the clock moves on.
Range:Set("week")
check(Range.from == clock - 7 * DAY and Range.to == clock, "last 7 days")
Range:Set("month")
check(Range:Has(clock - 29 * DAY) and not Range:Has(clock - 31 * DAY), "last 30 days")
Range:Set("today")
clock = clock + DAY
Range:Refresh()
check(Range.from == midnight + DAY, "today moves on after midnight")

-- 5. Back to all time.
Range:Set("all")
check(Range:IsAll() and Range:TrimPaths(paths) == paths and Range:Has(nil), "all time again")

if failures == 0 then
    print("Range tests passed.")
else
    print(failures .. " range test(s) failed.")
    os.exit(1)
end
