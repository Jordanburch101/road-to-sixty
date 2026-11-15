-- Offline test of PathShape.lua: the points each detail level keeps for
-- the path's shape. Run with LuaJIT from apps/addon:
-- luajit tests/pathshape_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
ns.Now = function() return time() end
assert(loadfile("RoadToSixty/PathShape.lua"))("RoadToSixty", ns)

-- Detail levels keep what the path's shape needs (KeepShape).
local function Track(xs, ys, brk, pb)
    local t = { px = xs, py = ys, brk = {}, pb = pb, n = #xs }
    for i = 1, #xs do t.brk[i] = brk and brk[i] or i == 1 end
    return t
end
local function Kept(track, tol, forced)
    local idx = {}
    local count = ns.KeepShape(track, nil, 1, track.n, tol, idx, 0, forced, 1)
    return idx, count
end
local function DistToSegment(x, y, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l = dx * dx + dy * dy
    local u = l > 0 and math.max(0, math.min(1, ((x - ax) * dx + (y - ay) * dy) / l)) or 0
    return math.sqrt((ax + u * dx - x) ^ 2 + (ay + u * dy - y) ^ 2)
end

-- A straight road, wobbling less than the tolerance, keeps only its ends.
local xs, ys = {}, {}
for i = 1, 100 do xs[i], ys[i] = i, (i % 3 - 1) * 0.04 end
local road = Kept(Track(xs, ys), 0.1)
check(#road == 2 and road[1] == 1 and road[2] == 100, "a straight road keeps its ends, got " .. #road .. " points")

-- A square walk keeps its corners and nothing else.
xs, ys = {}, {}
for i = 0, 39 do
    local side, f = math.floor(i / 10), i % 10
    local x, y = ({ f, 10, 10 - f, 0 })[side + 1], ({ 0, f, 10, 10 - f })[side + 1]
    xs[i + 1], ys[i + 1] = x, y
end
xs[41], ys[41] = 0, 0
local square = Kept(Track(xs, ys), 0.1)
check(table.concat(square, " ") == "1 11 21 31 41", "a square keeps its corners, got " .. table.concat(square, " "))

-- A winding walk: every point stays within about the tolerance of the
-- lines kept (a point a little past a line's end is up to its square root
-- of 2 times off), and far fewer points are kept than were recorded.
math.randomseed(57)
xs, ys = { 0 }, { 0 }
local heading = 0
for i = 2, 3000 do
    heading = heading + (math.random() - 0.5) * (i % 200 < 100 and 0.05 or 1)
    xs[i], ys[i] = xs[i - 1] + math.cos(heading), ys[i - 1] + math.sin(heading)
end
local tol = 0.3
local walk = Kept(Track(xs, ys), tol)
local off = 0
for j = 2, #walk do
    local a, b = walk[j - 1], walk[j]
    for i = a + 1, b - 1 do
        off = math.max(off, DistToSegment(xs[i], ys[i], xs[a], ys[a], xs[b], ys[b]))
    end
end
check(off <= tol * 1.42, ("every point within the tolerance of the lines kept, worst %.3f"):format(off))
check(#walk < 3000 / 2 and walk[1] == 1 and walk[#walk] == 3000, "a winding walk keeps fewer points, and its ends: " .. #walk)

-- Segments' first and last points, a change of level band and the points
-- of a coarser level (forced) are always kept, even on a straight line.
xs, ys = {}, {}
local brk, pb = {}, {}
for i = 1, 30 do xs[i], ys[i], brk[i], pb[i] = i, 0, i == 1 or i == 11, i <= 20 and 1 or 2 end
local marks = Kept(Track(xs, ys, brk, pb), 0.1, { 1, 5, 25, 30 })
check(table.concat(marks, " ") == "1 5 10 11 20 25 30", "segment ends, band changes and forced points kept, got "
    .. table.concat(marks, " "))

if failures == 0 then
    print("PathShape tests passed.")
else
    print(failures .. " path shape test(s) failed.")
    os.exit(1)
end
