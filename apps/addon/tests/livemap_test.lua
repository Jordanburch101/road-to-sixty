-- Offline test of LiveMap.lua's pure parts. Run with LuaJIT from apps/addon:
-- luajit tests/livemap_test.lua
--
-- While the map is open, points the recorder stores are added to the map's
-- points (LiveMap.Append) and to the detail levels already made
-- (LiveMap.ExtendLods) instead of building the map again (#136). This
-- builds a path's detail levels as Map.lua's GetLod does, grows the path
-- live, and checks the levels against ones built afresh for the whole path:
-- the same points kept, and chunks that cover them as GetLod's do.

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/LiveMap.lua"))("RoadToSixty", ns)
local LiveMap = ns.LiveMap

-- The detail levels as Map.lua's GetLod makes them (PathCurve.lua's
-- MakeLevel), at Map.lua's tolerances (LodDistance), as the reference.
assert(loadfile("RoadToSixty/PathCurve.lua"))("RoadToSixty", ns)
local SHAPE_PIXELS, MAX_ZOOM, LOD_STEP, CHUNK = 1, 64, 2, 64
local function LodDistance(k) return SHAPE_PIXELS / MAX_ZOOM * LOD_STEP ^ k end
local function GetLod(track, k)
    return track.lods[k] or ns.MakeLevel(track, k, LodDistance(k), CHUNK)
end

local function NewTrack()
    return { n = 0, px = {}, py = {}, pt = {}, pm = {}, pb = {}, brk = {}, pj = {}, pd = {},
        bounds = { 0, 0, 0, 0 }, lods = {} }
end

-- Content units are world yards over 10 here.
local function ToContent(x, y) return x / 10, y / 10 end

-- A walk: steps of 3 to 25 yards with turns, as the recorder stores them.
math.randomseed(136)
local function Walk(count, x, y, t, m)
    local path = { m = m or "w", c = 0, t = {}, x = {}, y = {} }
    local heading = 0
    for i = 1, count do
        heading = heading + (math.random() - 0.5)
        local step = 3 + math.random() * 22
        x, y, t = x + math.floor(step * math.cos(heading)), y + math.floor(step * math.sin(heading)), t + math.random(1, 4)
        path.t[i], path.x[i], path.y[i] = t, x, y
    end
    return path
end

-- The levels' kept points: exactly those of a fresh build, its levels made
-- in order, the order the grown track's were made in; the same chunks, the
-- same coarsest level for each point, and each level keeping a part of
-- every finer one's points and all of every coarser one's.
local function SameLevels(grown, fresh, label, order)
    for _, k in ipairs(order) do GetLod(fresh, k) end
    for _, k in ipairs(order) do
        local lod, want = grown.lods[k], fresh.lods[k]
        local same = #lod.idx == #want.idx
        for j = 1, #want.idx do same = same and lod.idx[j] == want.idx[j] end
        check(same, ("%s, level %d: %d points kept, %d in a fresh build"):format(label, k, #lod.idx, #want.idx))
        local chunks = #lod.chunks == #want.chunks
        for c, ch in ipairs(want.chunks) do
            for f = 1, 7 do chunks = chunks and lod.chunks[c] and lod.chunks[c][f] == ch[f] end
        end
        check(chunks, label .. ", level " .. k .. ": chunks differ from a fresh build's")
        local ordered = true
        for j = 2, #lod.idx do ordered = ordered and lod.idx[j] > lod.idx[j - 1] end
        check(ordered, label .. ", level " .. k .. ": kept points out of order")
    end
    local top = true
    for i = 1, fresh.n do top = top and grown.lods.top[i] == fresh.lods.top[i] end
    check(top, label .. ": coarsest levels differ from a fresh build's")
    for _, k in ipairs(order) do
        local has = {}
        for _, i in ipairs(grown.lods[k].idx) do has[i] = true end
        for _, k2 in ipairs(order) do
            if k2 > k then
                local nested = true
                for _, i in ipairs(grown.lods[k2].idx) do nested = nested and has[i] end
                check(nested, ("%s: level %d keeps a point level %d doesn't"):format(label, k2, k))
            end
        end
        for _, i in ipairs(grown.lods[k].idx) do
            check(grown.lods.top[i] >= k, label .. ": a point's coarsest level is finer than one keeping it")
        end
    end
end

-- The map opened on a journey of three segments, with levels 0, 5, 6, 7
-- and 9 made (the zooms looked at so far), in the order the map might make
-- them: 6 first, from every point (the map opened zoomed out), then 0,
-- from every point but keeping all of 6's, 9 from 6, 5 from 0 keeping 6's,
-- and 7 from 6 keeping 9's. Steps here are 0.3 to 2.5 units, so levels 5
-- (0.5 units) and up leave points out.
local paths = { Walk(300, 0, 0, 1000), Walk(200, 5000, 5000, 5000, "t") }
paths[3] = Walk(150, paths[2].x[200], paths[2].y[200], paths[2].t[200] + 5)
local function Build(list)
    local track = NewTrack()
    for s, path in ipairs(list) do
        LiveMap.Append(track, path, 1, ToContent, 2, list[s - 1], false)
    end
    return track
end
local grown = Build(paths)
local ORDER = { 6, 0, 9, 5, 7 }
for _, k in ipairs(ORDER) do GetLod(grown, k) end

-- The open segment grows, then a new one starts where it ended (landing).
local more = Walk(500, paths[3].x[150], paths[3].y[150], paths[3].t[150])
local open = paths[3]
local before = #open.x
for i = 1, 120 do
    open.t[before + i], open.x[before + i], open.y[before + i] = more.t[i], more.x[i], more.y[i]
end
-- In three batches, as the recorder stores them, each extending the levels.
local have = before
for _, upto in ipairs({ before + 1, before + 40, before + 120 }) do
    local path = { m = open.m, c = 0, t = {}, x = {}, y = {} }
    for i = 1, upto do path.t[i], path.x[i], path.y[i] = open.t[i], open.x[i], open.y[i] end
    local from = LiveMap.Append(grown, path, have + 1, ToContent, 2, paths[2], false)
    LiveMap.ExtendLods(grown, from, LodDistance, CHUNK)
    have = upto
end
-- Taking off and landing between two looks: two segments added, then the
-- levels extended once, the first segment's end kept as GetLod keeps it.
-- The landing heads far west, past every point before.
local flight = Walk(60, open.x[#open.x], open.y[#open.y], open.t[#open.t] + 2, "t")
local landing = Walk(80, flight.x[60] - 40000, flight.y[60], flight.t[60] + 2)
local from = LiveMap.Append(grown, flight, 1, ToContent, 3, open, false)
check(from == grown.n - 59 and grown.brk[from] == true and grown.pm[from] == "t" and grown.pb[from] == 3,
    "a new segment's first point starts it, in its own mode and band")
LiveMap.Append(grown, landing, 1, ToContent, 3, flight, false)
LiveMap.ExtendLods(grown, from, LodDistance, CHUNK)

local fresh = Build({ paths[1], paths[2], open, flight, landing })
check(grown.lods[0].keep == 6 and grown.lods[5].from == 0 and grown.lods[5].keep == 6 and grown.lods[7].from == 6
    and grown.lods[7].keep == 9 and grown.lods[6].from == nil, "levels made from the nearest finer, keeping the nearest coarser")
check(grown.n == fresh.n, ("as many points as a fresh build: %d and %d"):format(grown.n, fresh.n))
local same = true
for i = 1, fresh.n do
    same = same and grown.px[i] == fresh.px[i] and grown.py[i] == fresh.py[i] and grown.pt[i] == fresh.pt[i]
        and grown.brk[i] == fresh.brk[i] and grown.pm[i] == fresh.pm[i] and math.abs(grown.pd[i] - fresh.pd[i]) < 1e-9
end
check(same, "points added live are the points a fresh build has")
local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
for i = 1, grown.n do
    x1, y1 = math.min(x1, grown.px[i]), math.min(y1, grown.py[i])
    x2, y2 = math.max(x2, grown.px[i]), math.max(y2, grown.py[i])
end
local b = grown.bounds
check(b[1] == x1 and b[2] == y1 and b[3] == x2 and b[4] == y2, "bounds grown to the new points")
SameLevels(grown, fresh, "grown live", ORDER)

-- A straight line keeps only its ends, and the old end is dropped as the
-- line carries on straight, at the level and at the one made from it; a
-- corner is kept. Level 3 keeps to 0.125 units (1.25 yards here).
local small = NewTrack()
local line = { m = "w", c = 0, t = { 1, 2, 3 }, x = { 0, 10, 20 }, y = { 0, 0, 0 } }
LiveMap.Append(small, line, 1, ToContent, 1, nil, false)
GetLod(small, 3)
GetLod(small, 4)
check(#small.lods[3].idx == 2 and small.lods[3].idx[2] == 3, "a straight line keeps its ends")
local steps = { { 30, 0 }, { 30, 10 }, { 30, 20 }, { 31, 30 } }
for s, step in ipairs(steps) do
    line.t[3 + s], line.x[3 + s], line.y[3 + s] = 3 + s, step[1], step[2]
    LiveMap.ExtendLods(small, LiveMap.Append(small, line, 3 + s, ToContent, 1, nil, false), LodDistance, CHUNK)
    local smallFresh = NewTrack()
    LiveMap.Append(smallFresh, line, 1, ToContent, 1, nil, false)
    SameLevels(small, smallFresh, "a line carried on, step " .. s, { 3, 4 })
end
local kept = table.concat(small.lods[3].idx, " ")
check(kept == "1 4 7", "the straight line to the corner and on keeps its ends and the corner, got " .. kept)

-- A level made before the one below it (zoomed out first) is made from
-- every point; the one below, made after it, keeps all its points too.
local outOfOrder = Build({ paths[1], paths[2] })
GetLod(outOfOrder, 7)
GetLod(outOfOrder, 6)
check(outOfOrder.lods[7].from == nil and outOfOrder.lods[6].from == nil and outOfOrder.lods[6].keep == 7,
    "levels made from every point, keeping the coarser one's")
local tail = Walk(200, paths[2].x[200], paths[2].y[200], paths[2].t[200] + 3)
LiveMap.ExtendLods(outOfOrder, LiveMap.Append(outOfOrder, tail, 1, ToContent, 2, paths[2], false), LodDistance, CHUNK)
SameLevels(outOfOrder, Build({ paths[1], paths[2], tail }), "a level made before the one below it", { 7, 6 })

-- The warm-up making a level a little each frame starts it again when a
-- build makes a level next to it meanwhile, so levels still nest.
local warm = Build({ paths[1], paths[2] })
GetLod(warm, 0)
local co = coroutine.create(function() ns.MakeLevel(warm, 3, LodDistance(3), CHUNK, 50) end)
coroutine.resume(co)
GetLod(warm, 5)
while coroutine.status(co) ~= "dead" do assert(coroutine.resume(co)) end
check(warm.lods[3].from == 0 and warm.lods[3].keep == 5, "the warm-up's level made again with the new level above it")
SameLevels(warm, Build({ paths[1], paths[2] }), "a level the warm-up made again", { 0, 5, 3 })

-- The band can come from the point's time (a level up while points waited).
local banded = NewTrack()
local timed = { m = "w", c = 0, t = { 10, 20, 30 }, x = { 0, 10, 20 }, y = { 0, 0, 0 } }
LiveMap.Append(banded, timed, 1, ToContent, function(t) return t < 25 and 2 or 3 end, nil, false)
check(banded.pb[1] == 2 and banded.pb[2] == 2 and banded.pb[3] == 3, "each point in the band of its time")

-- The track's first point starts a segment, even partway through a path
-- (the map was empty, as Today is just after midnight).
local partway = NewTrack()
LiveMap.Append(partway, timed, 2, ToContent, 1, nil, false)
check(partway.brk[1] == true and partway.brk[2] == false, "an empty map's first point starts it")

-- A flight carried on after a reload is one line: no break, its first step measured.
local carried = Walk(10, landing.x[80] + 30, landing.y[80], landing.t[80] + 20, "t")
carried.x[1], carried.y[1] = landing.x[80] + 30, landing.y[80]
local at = LiveMap.Append(grown, carried, 1, ToContent, 3, landing, true)
check(grown.brk[at] == false and math.abs(grown.pd[at] - 30) < 1e-9, "a carried-on flight continues the line")

-- Nothing new: nothing added.
check(LiveMap.Append(grown, carried, 11, ToContent, 3, landing, false) == nil, "nothing to add adds nothing")

-- An empty map gets its first points and bounds.
local empty = NewTrack()
LiveMap.Append(empty, Walk(3, 100, 100, 0), 1, ToContent, 1, nil, false)
check(empty.n == 3 and empty.brk[1] == true and empty.bounds[1] <= empty.px[1] and empty.bounds[3] >= empty.px[1],
    "the first points on an empty map")

if failures == 0 then
    print("LiveMap tests passed.")
else
    print(failures .. " livemap test(s) failed.")
    os.exit(1)
end
