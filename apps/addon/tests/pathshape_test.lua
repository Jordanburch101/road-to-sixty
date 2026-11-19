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

-- Merging (MergeLines): three walks east along y = 0, then y = 0.3 (within
-- 0.5 of the first), then y = 3 (far from both), and a flight back along
-- y = 0.1. Each walk is its own segment, so the lines are 2 to 5, 7 to 10,
-- 12 to 15 and 17 to 20 (the line into a segment's start is a jump).
do
    local px, py, pm, brk = {}, {}, {}, {}
    local function Walk(y, mode, back)
        for s = 0, 4 do
            local n = #px + 1
            px[n], py[n], pm[n], brk[n] = back and 4 - s or s, y, mode, s == 0
        end
    end
    Walk(0, "w")
    Walk(0.3, "w")
    Walk(3, "w")
    Walk(0.1, "t", true)
    local track = { px = px, py = py, pm = pm, brk = brk, n = #px }
    local idx = {}
    for i = 1, #px do idx[i] = i end
    local hid = ns.MergeLines(track, idx, #idx, 0.5)
    local merged = {}
    for j = 2, #idx do if hid[j] then merged[#merged + 1] = j end end
    check(table.concat(merged, " ") == "2 3 4 5", "only the first walk merged, got " .. table.concat(merged, " "))
    -- Covered from the point the second walk covers all of it: its last line
    -- (point 10) covers the first walk's last stretch.
    check(hid[2] == 7 and hid[5] == 10, ("covered from the newer walk's lines, got %s and %s"):format(
        tostring(hid[2]), tostring(hid[5])))
    -- Nearer than the merge distance only to a flight, nothing merges.
    local far = ns.MergeLines(track, idx, #idx, 0.2)
    check(next(far) == nil, "a flight within reach merged a walk")
    -- Kept between sessions (PackMerged, UnpackMerged): the same level takes
    -- its merged lines back; one with more points after takes them for the
    -- points it had; one whose points differ takes none.
    local saved = ns.PackMerged(idx, #idx, hid, 0.5)
    local back, upTo = ns.UnpackMerged(saved, idx, 0.5)
    check(upTo == #idx - 1 and back and back[2] == hid[2] and back[5] == hid[5] and next(back, nil) ~= nil,
        "a level's merged lines not kept")
    local same = 0
    for j in pairs(back or {}) do if back[j] == hid[j] then same = same + 1 end end
    check(same == 4, ("all four merged lines kept, got %d"):format(same))
    local longer = {}
    for i = 1, #idx + 3 do longer[i] = i end
    check(ns.UnpackMerged(saved, longer, 0.5) ~= nil, "a level with points after not given its merged lines")
    local function Moved(changes)
        local other = {}
        for i = 1, #idx do other[i] = idx[i] end
        for j, by in pairs(changes) do other[j] = other[j] + by end
        return ns.UnpackMerged(saved, other, 0.5)
    end
    check(Moved({ [3] = 1 }) == nil, "a level whose points differ given another's merged lines")
    -- Points moved a little either way don't cancel out in the check (a
    -- weighted sum let these through).
    check(Moved({ [1] = 2, [3] = -1 }) == nil and Moved({ [4] = 1, [5] = -1 }) == nil,
        "a level with points moved both ways given another's merged lines")
    check(ns.UnpackMerged(saved, idx, 0.25) == nil, "merged lines taken for another distance")
    check(ns.UnpackMerged(saved, { 1, 2 }, 0.5) == nil, "a shorter level given merged lines past its end")
    check(ns.UnpackMerged({ n = 1, sum = 0, d = 5 }, idx, 0.5) == nil, "a damaged entry taken")
    check(ns.UnpackMerged({ n = 1.5, sum = 0, d = "", dist = 0.5 }, idx, 0.5) == nil, "a damaged count taken")

    -- Merges lines from a position on could undo are dropped: their own, and
    -- those of lines only they cover. Walk 1 is covered by walk 2's lines
    -- ending at points 7 to 10, so from line 9 (points 8 to 9) on, the lines
    -- covered from 9 or 10 lose theirs.
    local copy = {}
    for j, h in pairs(hid) do copy[j] = h end
    ns.DropMergedAfter(copy, idx, 9)
    local left = {}
    for j = 2, #idx do if copy[j] then left[#left + 1] = j .. ">" .. copy[j] end end
    check(table.concat(left, " ") == "2>7 3>8", "merges only the tail covers dropped, got " .. table.concat(left, " "))

    -- Merging can be given a time each frame instead of a line count: asked
    -- once enough points along lines were looked at, on a walk there and
    -- back of 100 points each way.
    local long = { px = {}, py = {}, pm = {}, brk = {}, n = 200 }
    local longIdx = {}
    for i = 1, 200 do
        long.px[i], long.py[i] = i <= 100 and i or 201 - i, i <= 100 and 0 or 0.2
        long.pm[i], long.brk[i], longIdx[i] = "w", i == 1 or i == 101, i
    end
    local asked = 0
    local co = coroutine.create(function()
        return ns.MergeLines(long, longIdx, 200, 0.5, function() asked = asked + 1; return true end)
    end)
    local yields = 0
    while coroutine.status(co) ~= "dead" do
        local ok, result = coroutine.resume(co)
        assert(ok, result)
        if coroutine.status(co) ~= "dead" then yields = yields + 1 end
    end
    check(asked > 0 and yields == asked, ("a time limit not asked or kept to: asked %d, yielded %d"):format(asked, yields))

    -- Chunks count lines drawn, and every line in the eighth field.
    local chunks = ns.LodChunks(track, idx, #idx, {}, 1, 64, hid)
    check(chunks[1][7] == chunks[1][8] - 4, ("merged lines left out of the count, got %d of %d"):format(
        chunks[1][7], chunks[1][8]))
end

-- Packed merges come back as they were: runs of lines one after another,
-- gaps between them, and covers moving either way (a walk back covers a
-- run from its far end), as made up at random here.
do
    math.randomseed(152)
    for _ = 1, 50 do
        local idx, hid = {}, {}
        local count = math.random(5, 400)
        local i = 0
        for j = 1, count do
            i = i + math.random(1, 5)
            idx[j] = i
        end
        local cover = idx[count]
        for j = 2, count - 1 do
            if math.random() < 0.4 then
                -- Within the checked part (n = count - 1): newer than the line.
                cover = math.max(idx[j] + 1, math.min(idx[count - 1], cover + math.random(-30, 30)))
                if cover > idx[j] and cover <= idx[count - 1] then hid[j] = cover end
            end
        end
        local saved = ns.PackMerged(idx, count, hid, 1)
        local back, n = ns.UnpackMerged(saved, idx, 1)
        local same = back ~= nil and n == count - 1
        for j, h in pairs(hid) do if not back or back[j] ~= h then same = false end end
        for j, h in pairs(back or {}) do if hid[j] ~= h then same = false end end
        check(same, "packed merges not given back as they were: " .. saved.d)
    end
    local saved = ns.PackMerged({ 1, 2, 3, 4, 5 }, 5, { [2] = 4 }, 1)
    saved.d = saved.d .. "!"
    check(ns.UnpackMerged(saved, { 1, 2, 3, 4, 5 }, 1) == nil, "a damaged packed merge taken")
end

-- A short line isn't merged into the line carrying on from its end, which
-- left a notch in a straight walk and a corner (a review found both).
do
    local function Merged(xs, ys)
        local track = { px = xs, py = ys, pm = {}, brk = {}, n = #xs }
        local idx = {}
        for i = 1, #xs do track.pm[i], track.brk[i], idx[i] = "w", i == 1, i end
        local hid = ns.MergeLines(track, idx, #idx, 1)
        return next(hid) == nil
    end
    check(Merged({ 0, 10, 10.5, 20 }, { 0, 0, 0, 0 }), "a short line in a straight walk merged")
    check(Merged({ 0, 10, 10.5, 10.5 }, { 0, 0, 0, 10 }), "a short line before a corner merged")
end

if failures == 0 then
    print("PathShape tests passed.")
else
    print(failures .. " path shape test(s) failed.")
    os.exit(1)
end
