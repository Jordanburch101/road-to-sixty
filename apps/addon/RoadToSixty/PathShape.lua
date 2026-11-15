local _, ns = ...

-- The shape of the journey map's path: which recorded points each detail
-- level keeps (ns.MakeLevel and ns.KeepShape, with the boxes over them,
-- ns.LodChunks). The map draws them as straight lines: curves through
-- them were dropped (#152), as the levels already keep the shape to half
-- a pixel, and a curve only guessed between recorded points at the cost
-- of lines and build time. Map.lua's GetLod makes the levels and
-- LiveMap.lua's ExtendLods carries them on as points are added; both go
-- through these, so the two always agree. No game calls, for the tests.
--
-- A level keeps the points that matter for the path's shape: a straight
-- road is drawn as one line from end to end, a winding street keeps its
-- corners. It used to keep a point once it was far enough from the last
-- one, every few yards even on a dead straight road, which spent the line
-- budget where it showed nothing, and in towns walked through many times
-- left the map to coarse levels that cut every corner.

-- Keeps, of the points source[first] to source[last] (indexes into the
-- track's px and py; first to last themselves without a source), those a
-- line through the points kept can't do without at tolerance tol: each line
-- from one kept point to the next passes within tol of every point between
-- them. idx[1] to idx[count] are the points kept before, the last of them
-- where the next line starts; the new ones are added after them and the new
-- count returned. A segment's first and last points are always kept (jumps
-- and the replay start and end there), and so is a point where the level
-- band changes (track.pb, where the track has one), so a line's colour
-- changes where the level did.
--
-- It goes through the points once, as a sleeve fit (Zhao and Saalfeld):
-- from the last point kept, each point allows the directions within tol of
-- it, and a line can carry on to the next point while that point's
-- direction lies in what every point since has allowed and it reaches as
-- far as they did. Where it can't, the point before is kept and the line
-- starts again from there. So what a point decides depends only on the
-- points since the last kept, which is what lets ExtendLods carry a level
-- on from its last point kept and get what a build of the whole path gets.
-- The directions allowed are kept as two vectors, so each step is a few
-- products and two square roots, no trigonometry: about one and a half
-- times what the distance merge cost. forced[f] on are points to keep
-- whatever their shape (a coarser level's, MakeLevel), in order. With
-- yieldEvery set, it yields every that many points (the map's warm-up
-- coroutine).
local function KeepShape(track, source, first, last, tol, idx, count, forced, f, yieldEvery)
    local px, py, brk, pb = track.px, track.py, track.brk, track.pb
    local tolSq = tol * tol
    local sqrt = math.sqrt
    local a = idx[count]        -- where the line starts
    local ax, ay = 0, 0
    if a then ax, ay = px[a], py[a] end
    -- The directions allowed, from (rx, ry) round anticlockwise to (lx, ly),
    -- and the furthest a point has been from a; open is false until a
    -- point lies past tol, as until then every direction is.
    local open, rx, ry, lx, ly, reach = false, 0, 0, 0, 0, 0
    local q                     -- the point before, kept if the line can't reach this one
    local keepAt = forced and forced[f]     -- the next point to keep whatever its shape
    for j = first, last do
        local i = source and source[j] or j
        local x, y = px[i], py[i]
        if not a or brk[i] then
            count = count + 1
            idx[count] = i
            a, ax, ay, open = i, x, y, false
        else
            local dx, dy = x - ax, y - ay
            local dSq = dx * dx + dy * dy
            if open and (rx * dy - ry * dx < 0 or dx * ly - dy * lx < 0 or sqrt(dSq) < reach - tol) then
                count = count + 1
                idx[count] = q
                a, ax, ay, open = q, px[q], py[q], false
                dx, dy = x - ax, y - ay
                dSq = dx * dx + dy * dy
            end
            -- The directions within tol of this point: its own turned each
            -- way by the angle whose sine is tol / d.
            if dSq > tolSq then
                local d = sqrt(dSq)
                local s = tol / d
                local c = sqrt(1 - s * s)
                local r1, r2 = c * dx + s * dy, c * dy - s * dx
                local l1, l2 = c * dx - s * dy, c * dy + s * dx
                if not open then
                    open, rx, ry, lx, ly, reach = true, r1, r2, l1, l2, d
                else
                    if rx * r2 - ry * r1 > 0 then rx, ry = r1, r2 end
                    if l1 * ly - l2 * lx > 0 then lx, ly = l1, l2 end
                    if d > reach then reach = d end
                end
            end
        end
        if keepAt and keepAt < i then
            while forced[f] and forced[f] < i do f = f + 1 end
            keepAt = forced[f]
        end
        -- brk[i + 1] ~= false: the last point of a segment, or of the track.
        if a ~= i and (keepAt == i or brk[i + 1] ~= false or pb and pb[i + 1] and pb[i + 1] ~= pb[i]) then
            count = count + 1
            idx[count] = i
            a, ax, ay, open = i, x, y, false
        end
        q = i
        if yieldEvery and j % yieldEvery == 0 then
            coroutine.yield()
        end
    end
    return count
end
ns.KeepShape = KeepShape

-- How many of points first to last every level keeps whatever their shape
-- (KeepShape): a segment's first and last, and where the level band changes.
-- A level with no more points than that (lods.ends, for the whole track) is
-- as coarse as any can be: Map.lua's PickLod stops there.
function ns.AlwaysKept(track, first, last)
    local brk, pb, count = track.brk, track.pb, 0
    for i = first, last do
        if brk[i] or brk[i + 1] ~= false or pb and pb[i + 1] and pb[i + 1] ~= pb[i] then
            count = count + 1
        end
    end
    return count
end

-- The levels made nearest below and above level k: lods.order lists the
-- levels in the order they were made.
local function Neighbours(lods, k)
    local below, above
    for _, j in ipairs(lods.order or {}) do
        if j < k and (not below or j > below) then below = j end
        if j > k and (not above or j < above) then above = j end
    end
    return below, above
end

-- Makes detail level k of a track at tolerance tol (Map.lua's GetLod):
-- track.lods[k] = { idx, chunks, from, keep }. idx lists the points kept,
-- in order (KeepShape). Each level keeps a part of what every finer level
-- made keeps, and all of what every coarser one does, whatever order they
-- are made in: it is made from the nearest finer level made (from), or
-- from every point, and keeps every point of the nearest coarser one made
-- (keep). So the far part of a build can take a coarser level's points
-- out of a finer one: lods.top[i] is the coarsest level made that keeps
-- point i. Being made from the level below, a level strays at most about
-- twice its tolerance from the recorded path; but a level wanted before
-- those below it, as when the map opens on the whole world, costs one
-- pass over the points rather than one for each level under it.
-- chunks are boxes over runs of chunk kept points (LodChunks). With
-- yieldEvery set it runs in a coroutine, yielding every that many points,
-- and starts again if a level was made next to it meanwhile.
function ns.MakeLevel(track, k, tol, chunk, yieldEvery)
    local lods = track.lods
    while true do
        local below, above = Neighbours(lods, k)
        local source = below and lods[below].idx
        local idx = {}
        local count = KeepShape(track, source, 1, source and #source or track.n, tol, idx, 0,
            above and lods[above].idx, 1, yieldEvery)
        -- A build that needed this level may have made it while we yielded.
        if lods[k] then return lods[k] end
        local nowBelow, nowAbove = Neighbours(lods, k)
        if nowBelow == below and nowAbove == above then
            local lod = { idx = idx, chunks = ns.LodChunks(track, idx, count, {}, 1, chunk), from = below, keep = above }
            lods[k] = lod
            lods.order = lods.order or {}
            lods.order[#lods.order + 1] = k
            lods.top = lods.top or {}
            lods.ends = lods.ends or ns.AlwaysKept(track, 1, track.n)
            local top = lods.top
            for j = 1, count do
                local i = idx[j]
                if not top[i] or top[i] < k then top[i] = k end
            end
            return lod
        end
    end
end

-- Boxes over runs of chunk kept points, as the map culls a level by them:
-- { first, last, x1, y1, x2, y2 }, first and last being indexes into idx,
-- each box taking in the point before its run, where its first line starts.
-- Made from chunks[from] on (the chunks before it are kept), so the runs
-- always start at 1, chunk + 1, ... and a level carried on has the boxes a
-- build of the whole path has.
function ns.LodChunks(track, idx, count, chunks, from, chunk)
    local px, py = track.px, track.py
    for c = #chunks, from, -1 do chunks[c] = nil end
    for start = (from - 1) * chunk + 1, count, chunk do
        local stop = math.min(count, start + chunk - 1)
        local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
        for j = math.max(1, start - 1), stop do
            local x, y = px[idx[j]], py[idx[j]]
            if x < x1 then x1 = x end
            if x > x2 then x2 = x end
            if y < y1 then y1 = y end
            if y > y2 then y2 = y end
        end
        -- The lines it draws, those of any length, for counting a box
        -- that lies wholly in an area without going through them.
        local lines = 0
        for j = math.max(2, start), stop do
            local a, b = idx[j - 1], idx[j]
            if px[a] ~= px[b] or py[a] ~= py[b] then lines = lines + 1 end
        end
        chunks[#chunks + 1] = { start, stop, x1, y1, x2, y2, lines }
    end
    return chunks
end
