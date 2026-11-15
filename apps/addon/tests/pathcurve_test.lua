-- Offline test of PathCurve.lua: walked lines cut into pieces along a curve
-- through the recorded points when zoomed in. Run with LuaJIT from the repo
-- root: luajit tests/pathcurve_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
ns.Now = function() return time() end
assert(loadfile("RoadToSixty/PathCurve.lua"))("RoadToSixty", ns)

-- A zig-zag stretch of path, then a jump, then a short stretch on its own.
local function Line(x1, y1, x2, y2, mode, i) return { x1, y1, x2, y2, mode, i } end
local lines = {
    Line(0, 0, 10, 5, "w", 2), Line(10, 5, 20, 0, "w", 3), Line(20, 0, 30, 5, "w", 4),
    Line(30, 5, 80, 60, "j", 5),
    Line(80, 60, 80.5, 60.25, "w", 6),
}

-- Zoomed out, nothing changes.
check(ns.CurveLines(lines, 1, 3000) == lines, "zoomed out the lines are kept as they are")

local out = ns.CurveLines(lines, 8, 3000)
check(#out > #lines, "zoomed in the lines are cut into pieces")

-- Pieces run on from one to the next, keep their line's mode and point,
-- and every recorded point is still on the path.
local points = {}
for k, l in ipairs(out) do
    local nxt = out[k + 1]
    if nxt and l[5] ~= "j" and nxt[5] ~= "j" and l[6] == nxt[6] then
        check(l[3] == nxt[1] and l[4] == nxt[2], "pieces of a line join up")
    end
    points[l[1] .. "," .. l[2]] = true
    points[l[3] .. "," .. l[4]] = true
end
for _, l in ipairs(lines) do
    check(points[l[1] .. "," .. l[2]] and points[l[3] .. "," .. l[4]], "recorded point kept: " .. l[1] .. "," .. l[2])
end
local lastPoint = 0
for _, l in ipairs(out) do
    check(l[6] >= lastPoint, "pieces stay in point order")
    lastPoint = l[6]
end

-- The jump is left alone, and so is the line too short on screen to cut.
local jumps, short = 0, 0
for _, l in ipairs(out) do
    if l[5] == "j" then jumps = jumps + 1 end
    if l[6] == 6 then short = short + 1 end
end
check(jumps == 1, "the jump stays one line")
check(short == 1, "a line under the piece length stays one line")

-- The curve bends between the points: a corner's piece leaves the straight line.
local bent = false
for _, l in ipairs(out) do
    if l[6] == 3 and l[3] ~= 20 then
        -- On the straight line from (10, 5) to (20, 0), y = 5 - (x - 10) / 2.
        bent = bent or math.abs(l[4] - (5 - (l[3] - 10) / 2)) > 0.01
    end
end
check(bent, "pieces follow a curve, not the straight line")

-- Over budget, fewer pieces a line; with no room at all, the lines as given.
local tight = ns.CurveLines(lines, 8, 8)
check(#tight <= 8 and #tight >= #lines, "kept to the budget, got " .. #tight)
check(ns.CurveLines(lines, 8, #lines) == lines, "no room for pieces: the lines as given")

-- Short of room, the pieces go to the longest lines first, and with a view
-- only to lines in it.
local long = {
    Line(0, 0, 2, 0, "w", 2), Line(2, 0, 10, 1, "w", 3), Line(10, 1, 13, 2, "w", 4),
    Line(13, 2, 30, 0, "w", 5),
}
local function PiecesOf(out, point)
    local n = 0
    for _, l in ipairs(out) do
        if l[6] == point then n = n + 1 end
    end
    return n
end
local some = ns.CurveLines(long, 8, #long + 3)
check(#some == #long + 3, "the room left is all used, got " .. #some)
check(PiecesOf(some, 5) == 4, "the longest line gets its pieces first")
check(PiecesOf(some, 2) == 1 and PiecesOf(some, 4) == 1, "short lines stay whole when room runs out")
local inView = ns.CurveLines(long, 8, #long + 3, { 0, -1, 11, 3 })
check(PiecesOf(inView, 5) == 1, "a line outside the view gets no pieces")
check(PiecesOf(inView, 3) == 4, "the room goes to the lines in view")
local points2 = {}
for _, l in ipairs(inView) do points2[l[3] .. "," .. l[4]] = true end
for _, l in ipairs(long) do
    check(points2[l[3] .. "," .. l[4]], "recorded point kept when short of room: " .. l[3] .. "," .. l[4])
end
local last2 = 0
for _, l in ipairs(inView) do
    check(l[6] >= last2, "pieces stay in point order when short of room")
    last2 = l[6]
end
-- Under budget, a view changes nothing: every line gets what it wants.
check(#ns.CurveLines(long, 8, 3000, { 0, -1, 11, 3 }) == #ns.CurveLines(long, 8, 3000), "under budget the view is not used")

-- A long straight line stays one line, with no pieces that would show
-- nothing; next to a sharp corner its curve keeps close to it.
local straight = { Line(0, 0, 1, 0, "w", 2), Line(1, 0, 2, 0, "w", 3), Line(2, 0, 3, 0, "w", 4) }
check(#ns.CurveLines(straight, 8, 3000) == 3, "lines on a straight path are left whole")
local corner = { Line(0, 0, 100, 0, "w", 2), Line(100, 0, 100, 3, "w", 3) }
local worst = 0
for _, l in ipairs(ns.CurveLines(corner, 8, 3000)) do
    if l[6] == 2 then worst = math.max(worst, math.abs(l[4]) * 8) end
end
check(worst <= 2.01, ("a long line by a corner bows at most 2 px, got %.2f"):format(worst))

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
    print("PathCurve tests passed.")
else
    print(failures .. " path curve test(s) failed.")
    os.exit(1)
end
