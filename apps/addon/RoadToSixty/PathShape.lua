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

-- Lines of a level that a newer walk covers (Map.lua's DETAIL.MERGE and
-- DETAIL.Merge): a walking line is merged into the
-- newer ones when every point along it, each half of dist, lies within dist
-- of a newer walking line that is drawn. Repeat walks down a street lie a
-- yard or two apart, so at full zoom they drew as bundles of lines; the
-- newest on top stands for them all. Flights and ghost runs are drawn see
-- through, so they are left alone. Only lines drawn are checked against, so
-- a line merged is always within dist of one on the map, never of one
-- merged in turn; nor against the two lines after it, which go on from its
-- end, so a short line isn't taken into the one carrying on and leaves a
-- notch. Returns hid: hid[j], for the line from idx[j - 1] to idx[j], is
-- the point index from which it is covered (the last, over its points, of
-- the first newer line covering each), so with only points up to p shown
-- (the replay) a line is left out when hid[j] <= p. With yieldEvery a
-- number, it yields every sixteenth of that many lines, as a line costs far
-- more here than a point does in KeepShape; with it a function, it yields
-- when that returns true, asked after a line once 64 points along lines
-- were looked at, so the map can give it a time each frame without this
-- file making game calls. idx[1] to idx[count] are copied first, as the
-- live map may carry the level on (LiveMap's ExtendLods) while it yields.
-- The grid's cells are twice dist across, so the cells round a point's hold
-- every line within dist of it; a line goes into those its points every
-- half dist along it fall in, which a line within dist of a point can't
-- slip between.
function ns.MergeLines(track, idx, count, dist, yieldEvery)
    local px, py, pm, brk = track.px, track.py, track.pm, track.brk
    local hid, grid = {}, {}
    if not pm then return hid end
    local own = {}
    for j = 1, count do own[j] = idx[j] end
    idx = own
    local floor, ceil, sqrt, huge = math.floor, math.ceil, math.sqrt, math.huge
    local distSq, cell, step = dist * dist, dist * 2, dist / 2
    local due = type(yieldEvery) == "function" and yieldEvery
    yieldEvery = not due and yieldEvery and math.max(1, floor(yieldEvery / 16))
    local work = 0
    -- The first newer line within dist of (x, y), but those going on from
    -- line self: its last point's index, or huge. Within dist of a point
    -- means within the two cells by it on each axis, the one it is in and
    -- the one on the side it is nearer. A bucket holds its lines newest
    -- first, so from its end the first line in reach is its earliest.
    local function Covered(x, y, self)
        local fx, fy, best = x / cell, y / cell, huge
        local cx, cy = floor(fx), floor(fy)
        local ox = fx - cx < 0.5 and cx - 1 or cx + 1
        local oy = fy - cy < 0.5 and cy - 1 or cy + 1
        for gx = math.min(cx, ox), math.max(cx, ox) do
            local column = grid[gx]
            if column then
                for gy = math.min(cy, oy), math.max(cy, oy) do
                    local bucket = column[gy]
                    if bucket then
                        for b = #bucket, 1, -1 do
                            local j = bucket[b]
                            local i = idx[j]
                            if i >= best then break end
                            if j > self + 2 then
                                -- Distance from (x, y) to the line idx[j - 1] to i.
                                local a = idx[j - 1]
                                local ax, ay = px[a], py[a]
                                local dx, dy = px[i] - ax, py[i] - ay
                                local len = dx * dx + dy * dy
                                local t = len > 0 and ((x - ax) * dx + (y - ay) * dy) / len or 0
                                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                                local ex, ey = ax + t * dx - x, ay + t * dy - y
                                if ex * ex + ey * ey <= distSq then
                                    best = i
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
        return best
    end
    for j = count, 2, -1 do
        local a, i = idx[j - 1], idx[j]
        local ax, ay = px[a], py[a]
        local dx, dy = px[i] - ax, py[i] - ay
        local walk = pm[i] == "w" and (dx ~= 0 or dy ~= 0)
        -- A line across a segment's start is a jump, never merged.
        for p = a + 1, i do
            if brk[p] then walk = false break end
        end
        if walk then
            local steps = math.max(1, ceil(sqrt(dx * dx + dy * dy) / step))
            local at = 0
            for s = 0, steps do
                work = work + 1
                local covered = Covered(ax + dx * s / steps, ay + dy * s / steps, j)
                if covered == huge then at = -1 break end
                if covered > at then at = covered end
            end
            if at > 0 then
                hid[j] = at
            else
                -- Drawn: into the grid in every cell it passes through.
                for s = 0, steps do
                    local gx = floor((ax + dx * s / steps) / cell)
                    local gy = floor((ay + dy * s / steps) / cell)
                    local column = grid[gx]
                    if not column then column = {}; grid[gx] = column end
                    local bucket = column[gy]
                    if not bucket then bucket = {}; column[gy] = bucket end
                    if bucket[#bucket] ~= j then bucket[#bucket + 1] = j end
                end
                work = work + steps
            end
        end
        if due then
            if work >= 64 then
                work = 0
                if due() then coroutine.yield() end
            end
        elseif yieldEvery and j % yieldEvery == 0 then
            coroutine.yield()
        end
    end
    return hid
end

--@debug@
-- Checks merged lines (MergeLines) another way, for /rts mergecheck: every
-- point along each, each quarter of dist, must lie within 1.25 dist of a
-- walking line still drawn that is newer than the line and the two carrying
-- on from it, and ends by hid[j] (so the replay never leaves it out before
-- it is covered). MergeLines looks every half dist along a line, so a point
-- between two it looked at can lie a quarter dist further from its cover:
-- 1.25 dist is as far as a merge it made right can be. Its own grid of
-- cells that far across, with lines put in every quarter of dist, so it
-- shares nothing with MergeLines' search. Returns how many lines are
-- merged, how many fail, the first that fails, and the farthest any point
-- of a merged line lies from a cover, as a share of dist.
function ns.CheckMerged(track, idx, hid, dist)
    local px, py, pm, brk = track.px, track.py, track.pm, track.brk
    local floor, ceil, sqrt = math.floor, math.ceil, math.sqrt
    local reach = dist * 1.25
    local grid, count, farthest = {}, #idx, 0
    local function Line(j)
        local a, i = idx[j - 1], idx[j]
        for p = a + 1, i do if brk[p] then return nil end end
        if not pm or pm[i] ~= "w" then return nil end
        return px[a], py[a], px[i] - px[a], py[i] - py[a]
    end
    for j = 2, count do
        local ax, ay, dx, dy = Line(j)
        if ax and not hid[j] then
            local steps = math.max(1, ceil(sqrt(dx * dx + dy * dy) / (dist / 4)))
            for s = 0, steps do
                local key = floor((ax + dx * s / steps) / reach) .. ":" .. floor((ay + dy * s / steps) / reach)
                local bucket = grid[key] or {}
                grid[key] = bucket
                if bucket[#bucket] ~= j then bucket[#bucket + 1] = j end
            end
        end
    end
    local merged, failed, first = 0, 0, nil
    for j, h in pairs(hid) do
        merged = merged + 1
        local ax, ay, dx, dy = Line(j)
        local ok = ax ~= nil
        if ok then
            local steps = math.max(1, ceil(sqrt(dx * dx + dy * dy) / (dist / 4)))
            for s = 0, steps do
                local x, y = ax + dx * s / steps, ay + dy * s / steps
                local cx, cy, best = floor(x / reach), floor(y / reach), math.huge
                for gx = cx - 1, cx + 1 do
                    for gy = cy - 1, cy + 1 do
                        for _, o in ipairs(grid[gx .. ":" .. gy] or {}) do
                            if o > j + 2 and idx[o] <= h then
                                local bx, by, ex, ey = Line(o)
                                local len = ex * ex + ey * ey
                                local t = len > 0 and ((x - bx) * ex + (y - by) * ey) / len or 0
                                t = math.max(0, math.min(1, t))
                                local qx, qy = bx + t * ex - x, by + t * ey - y
                                best = math.min(best, qx * qx + qy * qy)
                            end
                        end
                    end
                end
                best = sqrt(best)
                if best > reach * (1 + 1e-9) then ok = false break end
                farthest = math.max(farthest, best / dist)
            end
        end
        if not ok then
            failed = failed + 1
            first = first and math.min(first, j) or j
        end
    end
    return merged, failed, first, farthest
end
--@end-debug@

-- Drops the merges that lines from position from on could undo, as the live
-- map carries a level on from there (LiveMap's ExtendLods) and a level made
-- in a later session may keep other points there: those lines' own, and
-- those of lines only they cover (covered from past idx[from - 1]).
function ns.DropMergedAfter(hid, idx, from)
    local limit = idx[from - 1] or 0
    for j, h in pairs(hid) do
        if j >= from or h > limit then hid[j] = nil end
    end
end

-- A check of a level's first count kept points, to tell whether the level
-- made now keeps the points one made in another session did: levels can
-- come out differently by the order they are made in, and a sync can put
-- older points in among them. A rolling hash, so points moved a little
-- either way don't cancel out (as they did in a weighted sum); it stays
-- below 2^53, so exact in Lua's numbers. Yields as MergeLines does.
local function IdxSum(idx, count, due)
    local sum = 0
    for j = 1, count do
        sum = (sum * 31 + idx[j]) % 2147483629
        if due and j % 4096 == 0 and due() then coroutine.yield() end
    end
    return sum
end

-- Whole numbers in base 62 for the packed merges below: about a third
-- shorter than in tens, and still plain text in the saved file.
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local DIGIT = {}
for d = 1, #DIGITS do DIGIT[DIGITS:byte(d)] = d - 1 end
local function ToBase62(n)
    if n == 0 then return "0" end
    local s = ""
    while n > 0 do
        local d = n % 62
        s = DIGITS:sub(d + 1, d + 1) .. s
        n = (n - d) / 62
    end
    return s
end
local function FromBase62(s)
    local n = 0
    for c = 1, #s do
        local d = DIGIT[s:byte(c)]
        if not d then return nil end
        n = n * 62 + d
    end
    return n
end
-- A difference either way as a whole number: 0, -1, 1, -2 ... as 0, 1, 2, 3 ...
local function Zigzag(n) return n >= 0 and n * 2 or -n * 2 - 1 end
local function Unzigzag(n) return n % 2 == 0 and n / 2 or -(n + 1) / 2 end

-- A level's merged lines (MergeLines) packed to keep between sessions
-- (Map.lua's DETAIL.Merge): { n, sum, dist, d }. n is how many kept points
-- they are for: all but the last, which a level made once more points
-- follow may no longer keep, and merges only lines from there on undo are
-- left out (DropMergedAfter). sum checks those points (IdxSum), dist is the
-- distance merged within. d holds the lines merged in runs of ones that
-- follow each other, as "gap:h,h,...;..." in base 62: gap is how far the
-- run's first line is past the last run's last, and each h how hid differs
-- from the line's before (Zigzag). Lines one after another along a street
-- are mostly covered by the same later walk, so those differences are
-- small: half the size of each line's hid, which took 200 KB for a journey
-- to level 37.
function ns.PackMerged(idx, count, hid, dist, due)
    local n, runs, run, lastJ, lastH = count - 1, {}, nil, 0, 0
    local limit = idx[n] or 0
    for j = 2, n do
        local h = hid[j]
        if h and h <= limit then
            if run and lastJ == j - 1 then
                run[#run + 1] = ToBase62(Zigzag(h - lastH))
            else
                if run then runs[#runs + 1] = table.concat(run, ",") end
                run = { ToBase62(j - lastJ) .. ":" .. ToBase62(Zigzag(h - lastH)) }
            end
            lastJ, lastH = j, h
        end
        if due and j % 4096 == 0 and due() then coroutine.yield() end
    end
    if run then runs[#runs + 1] = table.concat(run, ",") end
    return { n = n, sum = IdxSum(idx, n, due), dist = dist, d = table.concat(runs, ";") }
end

-- The merged lines a packed level (PackMerged) gives the level made now,
-- merged within dist, and how many of its kept points they are for; nil when
-- its points or distance differ, or the entry is damaged. Lines after those
-- are newer than any merged, so are drawn until it is merged again.
function ns.UnpackMerged(saved, idx, dist, due)
    if type(saved) ~= "table" or type(saved.n) ~= "number" or type(saved.d) ~= "string"
        or saved.dist ~= dist or saved.n < 1 or saved.n > #idx or saved.n % 1 ~= 0
        or IdxSum(idx, saved.n, due) ~= saved.sum then
        return nil
    end
    local hid, j, h, count = {}, 0, 0, 0
    for gap, rest in saved.d:gmatch("([^:;]+):([^;]*)") do
        local step = FromBase62(gap)
        if not step or step < 1 then return nil end
        j = j + step - 1
        for part in rest:gmatch("[^,]+") do
            local diff = FromBase62(part)
            if not diff then return nil end
            j, h = j + 1, h + Unzigzag(diff)
            -- A cover is a newer line, and lies within what was checked.
            if j > saved.n or h <= idx[j] or h > idx[saved.n] then return nil end
            hid[j] = h
            count = count + 1
            if due and count % 4096 == 0 and due() then coroutine.yield() end
        end
    end
    return hid, saved.n
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
-- chunks are boxes over runs of chunk kept points (LodChunks). With merge
-- set, lines a newer walk covers within that distance are marked (hid,
-- MergeLines). With yieldEvery set it runs in a coroutine, yielding every
-- that many points, and starts again if a level was made next to it
-- meanwhile.
function ns.MakeLevel(track, k, tol, chunk, yieldEvery, merge)
    local lods = track.lods
    while true do
        local below, above = Neighbours(lods, k)
        local source = below and lods[below].idx
        local idx = {}
        local count = KeepShape(track, source, 1, source and #source or track.n, tol, idx, 0,
            above and lods[above].idx, 1, yieldEvery)
        local hid = merge and ns.MergeLines(track, idx, count, merge, yieldEvery)
        -- A build that needed this level may have made it while we yielded.
        if lods[k] then return lods[k] end
        local nowBelow, nowAbove = Neighbours(lods, k)
        if nowBelow == below and nowAbove == above then
            local lod = { idx = idx, chunks = ns.LodChunks(track, idx, count, {}, 1, chunk, hid),
                from = below, keep = above, hid = hid }
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
-- build of the whole path has. With hid (MergeLines), lines merged are left
-- out of the count, and the count with them is the eighth field.
function ns.LodChunks(track, idx, count, chunks, from, chunk, hid)
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
        local lines, merged = 0, 0
        for j = math.max(2, start), stop do
            local a, b = idx[j - 1], idx[j]
            if px[a] ~= px[b] or py[a] ~= py[b] then
                lines = lines + 1
                if hid and hid[j] then merged = merged + 1 end
            end
        end
        chunks[#chunks + 1] = { start, stop, x1, y1, x2, y2, lines - merged, lines }
    end
    return chunks
end
