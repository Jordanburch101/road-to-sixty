local _, ns = ...

-- Smooths the journey map's walked and flown lines into curves when zoomed
-- in (picked from /rts swatch as "curve"). Each line is cut into a few
-- pieces along a centripetal Catmull-Rom curve through the recorded points:
-- unlike the plain curve it makes no loops or overshoots where a short
-- stretch meets a long one, and it passes through every point. Lines are
-- given in point order, as the map builds them (Map.lua's LinesIn):
-- { x1, y1, x2, y2, mode, pointIndex }, in content units. A line whose
-- start is the previous one's end is the same stretch of path carried on;
-- jumps (mode "j") are drawn as arcs by the map and are left as they are.

local CURVE_ZOOM = 4            -- zoom from which lines are curved
local PIECE_PIXELS = 10         -- a piece for about every this many pixels of line on screen
local MAX_PIECES = 4            -- pieces per line at most

local function Joined(a, b)
    return a and b and a[5] ~= "j" and b[5] ~= "j" and a[3] == b[1] and a[4] == b[2]
end

-- The point at time t on the centripetal curve from p1 to p2, with p0 and
-- p3 the points before and after (Barry and Goldman's form). t0 to t3 are
-- the knots, spaced by the square root of each stretch's length.
local function At(t, t0, t1, t2, t3, x0, y0, x1, y1, x2, y2, x3, y3)
    local function Mix(ta, tb, xa, ya, xb, yb)
        local f = (t - ta) / (tb - ta)
        return xa + (xb - xa) * f, ya + (yb - ya) * f
    end
    local ax1, ay1 = Mix(t0, t1, x0, y0, x1, y1)
    local ax2, ay2 = Mix(t1, t2, x1, y1, x2, y2)
    local ax3, ay3 = Mix(t2, t3, x2, y2, x3, y3)
    local bx1, by1 = Mix(t0, t2, ax1, ay1, ax2, ay2)
    local bx2, by2 = Mix(t1, t3, ax2, ay2, ax3, ay3)
    return Mix(t1, t2, bx1, by1, bx2, by2)
end

local function Knot(xa, ya, xb, yb)
    return math.max(((xb - xa) ^ 2 + (yb - ya) ^ 2) ^ 0.25, 1e-6)
end

-- The lines with each walked or flown one cut into pieces along the curve,
-- at zoom z, keeping to budget lines in all; the lines as given when
-- zoomed out, or when even one extra piece a line would go over it.
function ns.CurveLines(lines, z, budget)
    if z < CURVE_ZOOM or #lines == 0 then return lines end
    -- Pieces per line by its length on screen, fewer if over budget.
    local wanted, total = {}, 0
    for k, l in ipairs(lines) do
        local n = 1
        if l[5] ~= "j" then
            local px = math.sqrt((l[3] - l[1]) ^ 2 + (l[4] - l[2]) ^ 2) * z
            n = math.max(1, math.min(MAX_PIECES, math.floor(px / PIECE_PIXELS)))
        end
        wanted[k], total = n, total + n
    end
    local most = MAX_PIECES
    while total > budget and most > 1 do
        most, total = most - 1, 0
        for k = 1, #wanted do
            wanted[k] = math.min(wanted[k], most)
            total = total + wanted[k]
        end
    end
    if total > budget or total == #lines then return lines end

    local out = {}
    for k, l in ipairs(lines) do
        local n = wanted[k]
        if n == 1 then
            out[#out + 1] = l
        else
            local x1, y1, x2, y2 = l[1], l[2], l[3], l[4]
            -- The points before and after on the same stretch, or mirrored
            -- past the end where the stretch starts or stops here.
            local before, after = lines[k - 1], lines[k + 1]
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
            local t3 = t2 + Knot(x2, y2, x3, y3)
            local px, py = x1, y1
            for p = 1, n do
                local qx, qy = x2, y2
                if p < n then
                    qx, qy = At(t1 + (t2 - t1) * p / n, 0, t1, t2, t3, x0, y0, x1, y1, x2, y2, x3, y3)
                end
                out[#out + 1] = { px, py, qx, qy, l[5], l[6] }
                px, py = qx, qy
            end
        end
    end
    return out
end
