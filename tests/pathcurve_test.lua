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
assert(loadfile("RoadToSixty/PathCurve.lua"))("RoadToSixty", ns)

-- A zig-zag stretch of path, then a jump, then a short stretch on its own.
local function Line(x1, y1, x2, y2, mode, i) return { x1, y1, x2, y2, mode, i } end
local lines = {
    Line(0, 0, 10, 5, "w", 2), Line(10, 5, 20, 0, "w", 3), Line(20, 0, 30, 5, "w", 4),
    Line(30, 5, 80, 60, "j", 5),
    Line(80, 60, 82, 61, "w", 6),
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

if failures == 0 then
    print("PathCurve tests passed.")
else
    print(failures .. " path curve test(s) failed.")
    os.exit(1)
end
