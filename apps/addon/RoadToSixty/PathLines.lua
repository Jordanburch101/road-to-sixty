local _, ns = ...

-- Keeps down what the journey map's lines cost (Map.lua). Every call on a
-- line crosses from Lua into the client, and the map draws thousands of
-- them, so it touches as few as it can:
--
-- - A build keeps the line already drawn for each stretch the last build
--   drew too (Reuse), so panning, or the live map adding a point, only
--   places the lines that changed.
-- - Lines keep a constant width on screen by their thickness, which is in
--   the zoomed content's units (Line:SetThickness takes uiUnits, and there
--   is no width in pixels), so a zoom resizes them. Only lines in view are
--   resized (Fit): the rest keep the width they had until they come into
--   view or the next build. The view's lines are found through boxes over
--   runs of them (Boxes, InView), as they come in point order and a run
--   stays close together.
-- - Each line remembers what was last set on it, so nothing is set twice:
--   on (shown or not), tz (the zoom its thickness is for), and in Map.lua
--   colorKey or color, and void for a line that is never shown (a jump's,
--   whose arc is drawn instead, or one the filters hide).
--
-- Lines are given as Map.lua builds them: { x1, y1, x2, y2, mode,
-- pointIndex }, other characters' with .track. Boxes, InView and Reuse
-- make no game calls; Fit, FitJump and Reveal call only the line objects
-- they are given (tests/pathlines_test.lua).

local PathLines = {}
ns.PathLines = PathLines

local BOX = 32                  -- lines per box
-- Screen pixels a jump's pieces reach past its curve at most (its finish
-- mark is 22 across, Style.lua), for finding jumps in view.
PathLines.JUMP_PAD = 32

-- Calls made on lines, for /rts perf: thickness or size set, shown or
-- hidden, placed, and kept from the last build. Map.lua resets them.
PathLines.count = { thick = 0, show = 0, place = 0, kept = 0 }
local count = PathLines.count

-- Boxes over runs of BOX lines: { first, last, x1, y1, x2, y2 }.
function PathLines.Boxes(specs)
    local boxes = {}
    local n = #specs
    for first = 1, n, BOX do
        local last = math.min(n, first + BOX - 1)
        local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
        for i = first, last do
            local s = specs[i]
            local ax, bx, ay, by = s[1], s[3], s[2], s[4]
            if ax > bx then ax, bx = bx, ax end
            if ay > by then ay, by = by, ay end
            if ax < x1 then x1 = ax end
            if bx > x2 then x2 = bx end
            if ay < y1 then y1 = ay end
            if by > y2 then y2 = by end
        end
        boxes[#boxes + 1] = { first, last, x1, y1, x2, y2 }
    end
    return boxes
end

-- Indexes of the lines that reach into the area x1, y1, x2, y2, in order,
-- written into out (a table to reuse, or nil). Returns out and how many.
function PathLines.InView(specs, boxes, x1, y1, x2, y2, out)
    out = out or {}
    local n = 0
    for _, b in ipairs(boxes) do
        if b[5] >= x1 and b[3] <= x2 and b[6] >= y1 and b[4] <= y2 then
            if b[3] >= x1 and b[5] <= x2 and b[4] >= y1 and b[6] <= y2 then
                -- The whole box is inside: every line in it is.
                for i = b[1], b[2] do
                    n = n + 1
                    out[n] = i
                end
            else
                for i = b[1], b[2] do
                    local s = specs[i]
                    local ax, bx, ay, by = s[1], s[3], s[2], s[4]
                    if ax > bx then ax, bx = bx, ax end
                    if ay > by then ay, by = by, ay end
                    if bx >= x1 and ax <= x2 and by >= y1 and ay <= y2 then
                        n = n + 1
                        out[n] = i
                    end
                end
            end
        end
    end
    for i = #out, n + 1, -1 do
        out[i] = nil
    end
    return out, n
end

-- The lines to draw specs with, from the last build's: lines[k] drew
-- old[k] for k up to used, and lines past used are spare. Where a spec has
-- the same ends (and track) as an old one, order[i] is that line, already
-- in place; else order[i] is nil and the caller places one from spare: the
-- lines no spec kept, to be taken from the end, where the ones that were
-- in use come.
function PathLines.Reuse(old, lines, used, specs)
    -- Old lines by their end's x, chained where several share it.
    local byEnd, nextSame = {}, {}
    for k = used, 1, -1 do
        local key = old[k][3]
        nextSame[k] = byEnd[key]
        byEnd[key] = k
    end
    local order, taken = {}, {}
    for i, s in ipairs(specs) do
        local k = byEnd[s[3]]
        while k do
            local o = old[k]
            if not taken[k] and o[1] == s[1] and o[2] == s[2] and o[4] == s[4] and o.track == s.track then
                taken[k] = true
                order[i] = lines[k]
                break
            end
            k = nextSame[k]
        end
    end
    local spare = {}
    for k = #lines, used + 1, -1 do
        spare[#spare + 1] = lines[k]
    end
    for k = used, 1, -1 do
        if not taken[k] then
            spare[#spare + 1] = lines[k]
        end
    end
    return order, spare
end

-- Sizes for zoom tz, width screen pixels wide, the lines at indexes
-- idx[1..n] that are shown and sized for another zoom; with idx nil,
-- lines 1 to n, shown or not (as every line was before, for comparing in
-- /rts perf all). Returns how many it resized.
function PathLines.Fit(lines, idx, n, tz, width)
    local touched, thickness = 0, width / tz
    for k = 1, n do
        local line = lines[idx and idx[k] or k]
        if line.tz ~= tz and (line.on or not idx) then
            line:SetThickness(thickness)
            line.tz = tz
            touched = touched + 1
        end
    end
    count.thick = count.thick + touched
    return touched
end

-- Sizes a jump's pieces for zoom z: lines by their width, dots by their
-- size, both in screen pixels (Map.lua's JumpLine and JumpDot), and works
-- out which rows of dots the zoom shows. A dot whose row changed fades to
-- it, or with snap (the jump was out of view) takes it at once. Only pieces
-- from to to, if given (a chunk in view, Map.lua's AddPart). Each piece
-- keeps the zoom it is sized for (sz) and the alpha set on it (alphaSet),
-- so Map.lua sets neither again on reuse. Returns how many pieces it
-- resized and whether any dot is fading.
function PathLines.FitJump(jump, z, snap, from, to)
    local fading, parts = false, jump.parts
    for k = from or 1, to or #parts do
        local part = parts[k]
        if part.width then
            part:SetThickness(part.width / z)
            part.sz = z
        elseif part.size then
            part:SetSize(part.size / z, part.size / z)
            part.sz = z
            if part.fade then
                local target = part.fade * z >= part.fadePx and 1 or 0
                if target ~= part.target then
                    part.target = target
                    if snap then
                        part.alpha, part.alphaSet = target, target
                        part:SetAlpha(target)
                    else
                        fading = true
                    end
                end
            end
        end
    end
    local n = (to or #parts) - (from or 1) + 1
    if not from then
        jump.tz = z
    end
    count.thick = count.thick + n
    return n, fading
end

-- Shows or hides a line, unless it already is. One shown inside fit
-- ({ x1, y1, x2, y2 }: the view and a margin) is first sized for zoom tz,
-- width screen pixels wide, if it is sized for another; one outside waits
-- for Fit, as it comes into view.
function PathLines.Reveal(line, spec, on, tz, width, fit)
    if line.on == on then return end
    if on and line.tz ~= tz and fit
        and math.max(spec[1], spec[3]) >= fit[1] and math.min(spec[1], spec[3]) <= fit[3]
        and math.max(spec[2], spec[4]) >= fit[2] and math.min(spec[2], spec[4]) <= fit[4] then
        line:SetThickness(width / tz)
        line.tz = tz
        count.thick = count.thick + 1
    end
    line:SetShown(on)
    line.on = on
    count.show = count.show + 1
end
