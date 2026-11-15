local _, ns = ...

-- The shape of the journey map's path: which recorded points each detail
-- level keeps (ns.MakeLevel and ns.KeepShape, with the boxes over them,
-- ns.LodChunks), and the walked and flown lines curved through them when
-- zoomed in (ns.CurveLines). Map.lua's GetLod makes the levels and
-- LiveMap.lua's ExtendLods carries them on as points are added; both go
-- through these, so the two always agree. No game calls, for the tests.
--
-- A level keeps the points that matter for the path's shape: a straight
-- road is drawn as one line from end to end, a winding street keeps its
-- corners. It used to keep a point once it was far enough from the last
-- one, every few yards even on a dead straight road, which spent the line
-- budget where it showed nothing, and in towns walked through many times
-- left the map to coarse levels that cut every corner.
--
-- Curves (picked from /rts swatch as "curve"): each line is cut into a few
-- pieces along a centripetal Catmull-Rom curve through the points kept:
-- unlike the plain curve it makes no loops or overshoots where a short
-- stretch meets a long one, and it passes through every point. Lines are
-- given in point order, as the map builds them (Map.lua's LinesIn):
-- { x1, y1, x2, y2, mode, pointIndex }, in content units. A line whose
-- start is the previous one's end is the same stretch of path carried on;
-- jumps (mode "j") are drawn as arcs by the map and are left as they are.

local CURVE_ZOOM = 4            -- zoom from which lines are curved
local PIECE_PIXELS = 5          -- a piece for about every this many pixels of line on screen (#57: small loops stay round)
local MAX_PIECES = 4            -- pieces per line at most
local LONGEST = 1000            -- lines longer than this many pixels share their turn for pieces
local FLAT_PIXELS = 0.5         -- a curve straying less than this from its line on screen is left straight
local BULGE_PIXELS = 2          -- curves stray at most about this far from their line on screen

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

local function Joined(a, b)
    return a and b and a[5] ~= "j" and b[5] ~= "j" and a[3] == b[1] and a[4] == b[2]
end

-- The point at time t on the centripetal curve from p1 to p2, with p0 and
-- p3 the points before and after (Barry and Goldman's form). t0 is 0 and t1
-- to t3 are the knots, spaced by the square root of each stretch's length.
local function At(t, t1, t2, t3, x0, y0, x1, y1, x2, y2, x3, y3)
    local f = t / t1
    local ax1, ay1 = x0 + (x1 - x0) * f, y0 + (y1 - y0) * f
    f = (t - t1) / (t2 - t1)
    local ax2, ay2 = x1 + (x2 - x1) * f, y1 + (y2 - y1) * f
    f = (t - t2) / (t3 - t2)
    local ax3, ay3 = x2 + (x3 - x2) * f, y2 + (y3 - y2) * f
    f = t / t2
    local bx1, by1 = ax1 + (ax2 - ax1) * f, ay1 + (ay2 - ay1) * f
    f = (t - t1) / (t3 - t1)
    local bx2, by2 = ax2 + (ax3 - ax2) * f, ay2 + (ay3 - ay2) * f
    f = (t - t1) / (t2 - t1)
    return bx1 + (bx2 - bx1) * f, by1 + (by2 - by1) * f
end

local function Knot(xa, ya, xb, yb)
    return math.max(((xb - xa) ^ 2 + (yb - ya) ^ 2) ^ 0.25, 1e-6)
end

-- The curve through line k of lines: the points before and after on the
-- same stretch, or mirrored past the end where the stretch starts or stops
-- there, and the knots.
local function Around(lines, k)
    local l, before, after = lines[k], lines[k - 1], lines[k + 1]
    local x1, y1, x2, y2 = l[1], l[2], l[3], l[4]
    local x0, y0, x3, y3
    if Joined(before, l) then
        x0, y0 = before[1], before[2]
    else
        x0, y0 = 2 * x1 - x2, 2 * y1 - y2
    end
    if Joined(l, after) then
        x3, y3 = after[3], after[4]
    else
        x3, y3 = 2 * x2 - x1, 2 * y2 - y1
    end
    local t1 = Knot(x0, y0, x1, y1)
    local t2 = t1 + Knot(x1, y1, x2, y2)
    return t1, t2, t2 + Knot(x2, y2, x3, y3), x0, y0, x1, y1, x2, y2, x3, y3
end

-- The lines with each walked or flown one cut into pieces along the curve,
-- at zoom z, keeping to budget lines in all; the lines as given when
-- zoomed out, or when there is no room for a single extra piece. Over
-- budget, every line keeps one piece and the room left goes to the lines
-- longest on screen, where a straight line shows most: those in view
-- (x1, y1, x2, y2 in content units) when it is given, as the map draws
-- lines past the view too. Detail comes first, curves get what is left
-- (#152): a curve through points 25 yards apart cut across every corner.
--
-- A line whose curve keeps within FLAT_PIXELS of it stays whole, as pieces
-- there would cost lines and show nothing, and a curve is flattened to
-- keep within BULGE_PIXELS of its line: the detail levels keep a long line
-- where the path ran straight (KeepShape), and a curve bowing out from it
-- towards a corner at its end strayed from where the path went.
function ns.CurveLines(lines, z, budget, view)
    if z < CURVE_ZOOM or #lines == 0 then return lines end
    local spare = budget - #lines
    if spare <= 0 then return lines end
    -- Pieces per line by its length on screen.
    local wanted, length, total = {}, {}, 0
    for k, l in ipairs(lines) do
        local n = 1
        if l[5] ~= "j" then
            local px = math.sqrt((l[3] - l[1]) ^ 2 + (l[4] - l[2]) ^ 2) * z
            n = math.max(1, math.min(MAX_PIECES, math.floor(px / PIECE_PIXELS)))
            length[k] = px
        end
        wanted[k], total = n, total + n
    end
    -- How far each curve strays from its line: ox and oy hold its offsets a
    -- quarter, half and three quarters along, kept for the pieces (a curve
    -- bending one way and then the other strays most near the quarters).
    -- False for a curve that stays within FLAT_PIXELS of its line.
    local bulge, ox, oy = {}, {}, {}
    local function Bends(k)
        local t1, t2, t3, x0, y0, x1, y1, x2, y2, x3, y3 = Around(lines, k)
        local off = 0
        for m = 1, 3 do
            local f = m / 4
            local cx, cy = At(t1 + (t2 - t1) * f, t1, t2, t3, x0, y0, x1, y1, x2, y2, x3, y3)
            local dx, dy = cx - x1 - (x2 - x1) * f, cy - y1 - (y2 - y1) * f
            ox[3 * k + m], oy[3 * k + m] = dx, dy
            off = math.max(off, dx * dx + dy * dy)
        end
        off = math.sqrt(off) * z
        bulge[k] = off
        return off >= FLAT_PIXELS
    end
    if total <= budget then
        total = 0
        for k = 1, #lines do
            if wanted[k] > 1 and not Bends(k) then wanted[k] = 1 end
            total = total + wanted[k]
        end
    else
        -- Over budget, every line keeps one piece and the room left goes to
        -- the lines longest on screen, those in view when it is given. The
        -- lines that may get pieces are put in lists by their whole length
        -- in pixels (all past LONGEST together; counted rather than sorted,
        -- as sorting them took a quarter of a build), each list in point
        -- order, and only measured as their turn comes, until the room is
        -- used up: measuring every line took most of a build that had room
        -- for a few dozen pieces.
        local head, nextIn = {}, {}
        for k = #lines, 1, -1 do
            if wanted[k] > 1 then
                local l = lines[k]
                if not view or (math.max(l[1], l[3]) >= view[1] and math.min(l[1], l[3]) <= view[3]
                    and math.max(l[2], l[4]) >= view[2] and math.min(l[2], l[4]) <= view[4]) then
                    local b = math.floor(length[k])
                    if b > LONGEST then b = LONGEST end
                    nextIn[k], head[b] = head[b], k
                end
            end
        end
        local give = {}
        for b = LONGEST, 0, -1 do
            local k = head[b]
            while k and spare > 0 do
                if Bends(k) then
                    local n = 1 + math.min(wanted[k] - 1, spare)
                    give[k], spare = n, spare - (n - 1)
                end
                k = nextIn[k]
            end
            if spare <= 0 then break end
        end
        total = 0
        for k = 1, #lines do
            wanted[k] = give[k] or 1
            total = total + wanted[k]
        end
    end
    if total == #lines then return lines end

    local out = {}
    for k, l in ipairs(lines) do
        local n = wanted[k]
        if n == 1 then
            out[#out + 1] = l
        else
            local x1, y1, x2, y2 = l[1], l[2], l[3], l[4]
            local keep = math.min(1, BULGE_PIXELS / bulge[k])
            local px, py = x1, y1
            for p = 1, n do
                local qx, qy = x2, y2
                if p < n then
                    -- Along the line, and out from it as far as the curve,
                    -- flattened; at the quarters, as measured above.
                    local f = p / n
                    local dx, dy
                    if n == 3 then
                        local t1, t2, t3, x0, y0, _, _, _, _, x3, y3 = Around(lines, k)
                        local cx, cy = At(t1 + (t2 - t1) * f, t1, t2, t3, x0, y0, x1, y1, x2, y2, x3, y3)
                        dx, dy = cx - x1 - (x2 - x1) * f, cy - y1 - (y2 - y1) * f
                    else
                        dx, dy = ox[3 * k + f * 4], oy[3 * k + f * 4]
                    end
                    qx, qy = x1 + (x2 - x1) * f + dx * keep, y1 + (y2 - y1) * f + dy * keep
                end
                out[#out + 1] = { px, py, qx, qy, l[5], l[6] }
                px, py = qx, qy
            end
        end
    end
    return out
end
