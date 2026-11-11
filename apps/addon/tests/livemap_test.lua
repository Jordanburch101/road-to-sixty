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

-- Map.lua's GetLod and its constants, as the reference.
local MIN_PIXELS, MAX_ZOOM, LOD_STEP, CHUNK = 2, 64, 2, 64
local function LodDistance(k) return MIN_PIXELS / MAX_ZOOM * LOD_STEP ^ k end
local function GetLod(track, k)
    local lod = track.lods[k]
    if lod then return lod end
    local px, py, brk = track.px, track.py, track.brk
    local source = track.lods[k - 1] and track.lods[k - 1].idx
    local length = source and #source or track.n
    local minSq = LodDistance(k) ^ 2
    local idx, count, lx, ly = {}, 0, 0, 0
    for j = 1, length do
        local i = source and source[j] or j
        local x, y = px[i], py[i]
        local dx, dy = x - lx, y - ly
        if brk[i] or brk[i + 1] ~= false or dx * dx + dy * dy >= minSq then
            count = count + 1
            idx[count] = i
            lx, ly = x, y
        end
    end
    local chunks = {}
    for first = 1, count, CHUNK do
        local last = math.min(count, first + CHUNK - 1)
        local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
        for j = math.max(1, first - 1), last do
            local x, y = px[idx[j]], py[idx[j]]
            if x < x1 then x1 = x end
            if x > x2 then x2 = x end
            if y < y1 then y1 = y end
            if y > y2 then y2 = y end
        end
        chunks[#chunks + 1] = { first, last, x1, y1, x2, y2 }
    end
    lod = { idx = idx, chunks = chunks }
    track.lods[k] = lod
    return lod
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

-- The levels' kept points: exactly those of a fresh build.
local function SameLevels(grown, fresh, label)
    for k, lod in pairs(grown.lods) do
        local want = GetLod(fresh, k).idx
        local extra, missing = {}, 0
        local inGrown = {}
        for _, i in ipairs(lod.idx) do inGrown[i] = true end
        for _, i in ipairs(want) do
            if not inGrown[i] then missing = missing + 1 end
        end
        local inFresh = {}
        for _, i in ipairs(want) do inFresh[i] = true end
        for _, i in ipairs(lod.idx) do
            if not inFresh[i] then extra[#extra + 1] = i end
        end
        check(missing == 0 and #extra == 0, ("%s, level %d: %d points missing, %d extra"):format(label, k, missing, #extra))
        -- In order, and the chunks cover them in runs of at most CHUNK,
        -- each box around its points and the one before.
        local ordered = true
        for j = 2, #lod.idx do ordered = ordered and lod.idx[j] > lod.idx[j - 1] end
        check(ordered, label .. ", level " .. k .. ": kept points out of order")
        local next, boxed = 1, true
        for _, ch in ipairs(lod.chunks) do
            boxed = boxed and ch[1] == next and ch[2] >= ch[1] and ch[2] - ch[1] + 1 <= CHUNK
            for j = math.max(1, ch[1] - 1), ch[2] do
                local x, y = grown.px[lod.idx[j]], grown.py[lod.idx[j]]
                boxed = boxed and x >= ch[3] and x <= ch[5] and y >= ch[4] and y <= ch[6]
            end
            next = ch[2] + 1
        end
        check(boxed and next == #lod.idx + 1, label .. ", level " .. k .. ": chunks don't cover the kept points")
    end
end

-- The map opened on a journey of three segments, with levels 0, 5, 6, 7
-- and 9 made (the zooms looked at so far): 6 and 7 are made from the level
-- below, 0, 5 and 9 from every point. Steps here are 0.3 to 2.5 units, so
-- levels 5 (1 unit) and up leave points out.
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
for _, k in ipairs({ 0, 5, 6, 7, 9 }) do GetLod(grown, k) end

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
SameLevels(grown, fresh, "grown live")

-- The old end dropped from a level is dropped from the one made from it,
-- even where that level alone would keep it. Level 5 keeps points 1 unit
-- apart and level 6, made from it, 2: A at 0, B at 1.5 and C, the end, at
-- 2. Level 5 keeps C only as the end; level 6 keeps C, 2 from A. Then D
-- comes at 2.6: level 5 drops C (0.5 from B) and keeps D, so level 6,
-- made from A, B and D, has A and D only.
local small = NewTrack()
local line = { m = "w", c = 0, t = { 1, 2, 3 }, x = { 0, 15, 20 }, y = { 0, 0, 0 } }
LiveMap.Append(small, line, 1, ToContent, 1, nil, false)
GetLod(small, 5)
GetLod(small, 6)
check(#small.lods[6].idx == 2 and small.lods[6].idx[2] == 3, "level 6 keeps the end before it grows")
line.t[4], line.x[4], line.y[4] = 4, 26, 0
LiveMap.ExtendLods(small, LiveMap.Append(small, line, 4, ToContent, 1, nil, false), LodDistance, CHUNK)
local smallFresh = NewTrack()
LiveMap.Append(smallFresh, line, 1, ToContent, 1, nil, false)
GetLod(smallFresh, 5)
SameLevels(small, smallFresh, "the old end and the level below")

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
