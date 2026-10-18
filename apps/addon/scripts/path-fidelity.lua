-- Compares the recorder's rules for storing path points (#57): the old one
-- (a sample a second, a point every 15 yards) and Recorder.lua as it is now,
-- run under a fake game API. For each trace it prints the points and bytes
-- each keeps and how far the walked positions stray from each stored line,
-- and draws the three lines into an SVG. Run from apps/addon:
--
--   luajit scripts/path-fidelity.lua [--bend=2,1.5,...] [saved file] [out folder]
--
-- With no saved file (or -) it uses made-up traces. <saved file> is the
-- account's WTF/Account/<name>/SavedVariables/RoadToSixty.lua with traces
-- from /rts pathprobe. The SVGs go to build/path-fidelity unless told
-- otherwise. --bend runs the new rule with each BEND in yards instead of
-- Recorder.lua's own, an SVG each. The new line is drawn curved as the map
-- draws it (PathCurve.lua) at --zoom screen pixels a yard, 2.4 unless told.

---@type (number|false)[]
local bends = { false }     -- false: Recorder.lua's own BEND
local positional, zoom = {}, 2.4
for _, a in ipairs(arg) do
    local list = a:match("^%-%-bend=(.+)$")
    if a:match("^%-%-zoom=") then
        zoom = assert(tonumber(a:match("=(.+)")), "bad --zoom")
    elseif list then
        bends = {}
        for b in list:gmatch("[^,]+") do bends[#bends + 1] = assert(tonumber(b), "bad --bend " .. b) end
    else
        positional[#positional + 1] = a
    end
end
local saved, out = positional[1], positional[2] or "build/path-fidelity"
if saved == "-" then saved = nil end

local curve = {}
assert(loadfile("RoadToSixty/PathCurve.lua"))("RoadToSixty", curve)

local function Read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- Traces: { label, points = { { t, x, y }, ... } }, ten positions a second.
local traces = {}

local function Made(label, fn)
    local points, t = {}, 0
    fn(function(x, y)
        points[#points + 1] = { t, x, y }
        t = t + 0.1
    end)
    traces[#traces + 1] = { label = label, points = points }
end

-- Moves from the last position to x, y at speed yards a second.
local function Mover(emit, x, y)
    local at = { x, y }
    emit(x, y)
    return function(tx, ty, speed)
        local length = math.sqrt((tx - at[1]) ^ 2 + (ty - at[2]) ^ 2)
        local steps = math.max(1, math.floor(length / (speed * 0.1)))
        for k = 1, steps do
            emit(at[1] + (tx - at[1]) * k / steps, at[2] + (ty - at[2]) * k / steps)
        end
        at[1], at[2] = tx, ty
    end, at
end

if saved then
    local ns = {}
    assert(loadfile("RoadToSixty/Parse.lua"))("RoadToSixty", ns)
    local db = assert(ns.Parse.File(Read(saved)).RoadToSixtyDB, "no RoadToSixtyDB in " .. saved)
    for _, trace in ipairs(assert(db.pathProbe, "no traces: record some with /rts pathprobe")) do
        local points, c0 = {}, nil
        for t, c, x, y in trace.d:gmatch("([%d.]+),(%d+),(-?[%d.]+),(-?[%d.]+)") do
            c0 = c0 or c
            if c == c0 then points[#points + 1] = { tonumber(t), tonumber(x), tonumber(y) } end
        end
        if #points > 1 then traces[#traces + 1] = { label = trace.label, points = points } end
    end
else
    Made("tree, twice round at 5 yards", function(emit)
        for k = 0, 90 do
            local a = k * 0.7 / 5
            emit(5 * math.cos(a), 5 * math.sin(a))
        end
    end)
    Made("fence with corners", function(emit)
        local move = Mover(emit, 0, 0)
        move(30, 0, 7); move(30, 12, 7); move(10, 12, 7); move(10, 25, 7); move(40, 25, 7)
    end)
    Made("out and back", function(emit)
        local move = Mover(emit, 0, 0)
        move(10, 0, 7); move(0, 0, 7); move(0, 10, 7)
    end)
    Made("questing: wander, fight, loot", function(emit)
        local seed = 7
        local function rnd()
            seed = (seed * 1103515245 + 12345) % 2147483648
            return seed / 2147483648
        end
        local move, at = Mover(emit, 0, 0)
        local heading = 0
        for _ = 1, 40 do
            -- Run a curving stretch to the next mob, fight it in place, loot.
            for _ = 1, 3 + math.floor(rnd() * 6) do
                heading = heading + (rnd() - 0.5) * 1.2
                move(at[1] + 8 * math.cos(heading), at[2] + 8 * math.sin(heading), 7)
            end
            for _ = 1, 100 do emit(at[1] + rnd() - 0.5, at[2] + rnd() - 0.5) end
            move(at[1] + 3, at[2] + 2, 7)
            for _ = 1, 30 do emit(at[1], at[2]) end
        end
    end)
    Made("mounted, long gentle road", function(emit)
        for k = 0, 600 do
            local x = k * 1.1
            emit(x, 40 * math.sin(x / 120))
        end
    end)
end

local function Round(v) return math.floor(v + 0.5) end

-- The old rule: a sample a second, a point once 15 yards from the last.
local function OldRule(points)
    local xs, ys, ts = {}, {}, {}
    local nextT = points[1][1]
    for _, p in ipairs(points) do
        if p[1] >= nextT then
            nextT = nextT + 1
            local x, y = Round(p[2]), Round(p[3])
            local n = #xs
            if n == 0 or math.sqrt((x - xs[n]) ^ 2 + (y - ys[n]) ^ 2) >= 15 then
                xs[n + 1], ys[n + 1], ts[n + 1] = x, y, math.floor(p[1])
            end
        end
    end
    return xs, ys, ts
end

-- Recorder.lua under a fake game, sampled every 0.25 seconds.
local recorderSource = Read("RoadToSixty/Recorder.lua")

local function NewRule(points, bend)
    local game = { x = 0, y = 0, now = 1000000 }
    local handlers, tick = {}, nil
    local ns = { char = { segments = {}, events = {}, totals = { distance = 0, flown = 0 } } }
    function ns.On(event, fn) handlers[event] = handlers[event] or {}; table.insert(handlers[event], fn) end
    function ns.Command() end
    function ns.SafeCall(fn, ...) assert(pcall(fn, ...)) end
    function ns.Now() return math.floor(game.now) end
    C_Map = {
        GetBestMapForUnit = function() return 1415 end,
        GetPlayerMapPosition = function() return { x = game.x, y = game.y } end,
        GetWorldPosFromMapPos = function(_, pos) return 0, { x = pos.x, y = pos.y } end,
    }
    C_Timer = { NewTicker = function(_, fn) tick = fn; return { Cancel = function() end } end }
    UnitOnTaxi = function() return false end
    UnitIsGhost = function() return false end
    IsInInstance = function() return false end
    GetTime = function() return game.now end
    assert(loadfile("RoadToSixty/Packed.lua"))("RoadToSixty", ns)
    local source = recorderSource
    if bend then
        local count
        source, count = source:gsub("\nlocal BEND = {[^}]*}", ("\nlocal BEND = { w = %s, g = %s }"):format(bend, bend))
        assert(count == 1, "no BEND line in Recorder.lua")
    end
    assert((loadstring or load)(source, "@RoadToSixty/Recorder.lua"))("RoadToSixty", ns)
    for _, fn in ipairs(handlers.PLAYER_LOGIN) do fn() end
    assert(tick, "the recorder never started its ticker")
    local start, nextT = game.now, points[1][1]
    for _, p in ipairs(points) do
        if p[1] >= nextT then
            nextT = nextT + 0.25
            game.now = start + p[1]
            game.x, game.y = p[2], p[3]
            tick()
        end
    end
    local path = ns.Recorder:GetPath(1)
    return path.x, path.y, path.t
end

-- Bytes the points take in the saved format.
local function Bytes(xs, ys, ts)
    local n = 0
    for i = 2, #xs do
        n = n + #((ts[i] - ts[i - 1]) .. "," .. (xs[i] - xs[i - 1]) .. "," .. (ys[i] - ys[i - 1])) + 1
    end
    return n
end

-- How far each walked position is from the stored line, with the last
-- position joined on: the worst and the mean.
local function Stray(points, xs, ys)
    xs, ys = { unpack(xs) }, { unpack(ys) }
    xs[#xs + 1], ys[#ys + 1] = points[#points][2], points[#points][3]
    local worst, sum = 0, 0
    for _, p in ipairs(points) do
        local best = math.huge
        for i = 2, #xs do
            local ax, ay, dx, dy = xs[i - 1], ys[i - 1], xs[i] - xs[i - 1], ys[i] - ys[i - 1]
            local lengthSq = dx * dx + dy * dy
            local u = lengthSq > 0 and math.max(0, math.min(1, ((p[2] - ax) * dx + (p[3] - ay) * dy) / lengthSq)) or 0
            local ex, ey = ax + u * dx - p[2], ay + u * dy - p[3]
            best = math.min(best, math.sqrt(ex * ex + ey * ey))
        end
        worst, sum = math.max(worst, best), sum + best
    end
    return worst, sum / #points
end

-- The line through xs, ys as the map curves it at zoom pixels a yard.
-- CurveLines takes content units and a map zoom of at least its CURVE_ZOOM
-- (4), so yards are scaled to make the pixel lengths come out the same.
local function Curved(xs, ys)
    local k = zoom / 4
    local lines = {}
    for i = 2, #xs do
        lines[i - 1] = { xs[i - 1] * k, ys[i - 1] * k, xs[i] * k, ys[i] * k, "w", i }
    end
    local cx, cy = { xs[1] }, { ys[1] }
    for _, l in ipairs(curve.CurveLines(lines, 4, math.huge)) do
        cx[#cx + 1], cy[#cy + 1] = l[3] / k, l[4] / k
    end
    return cx, cy
end

local function Svg(path, trace, lines)
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(trace.points) do
        x1, y1, x2, y2 = math.min(x1, p[2]), math.min(y1, p[3]), math.max(x2, p[2]), math.max(y2, p[3])
    end
    local pad, size = 4, 800
    local scale = size / math.max(x2 - x1 + 2 * pad, y2 - y1 + 2 * pad)
    -- World X runs north and Y west: north up, west left.
    local function At(x, y) return ("%.1f,%.1f"):format((y2 + pad - y) * scale, (x2 + pad - x) * scale) end
    local parts = { ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" style="background:#111">'):format(size, size),
        ('<text x="8" y="20" fill="#ccc" font-family="sans-serif" font-size="14">%s</text>'):format(trace.label) }
    for k, line in ipairs(lines) do
        local pts, xs, ys = {}, line.xs, line.ys
        if line.curved then xs, ys = Curved(xs, ys) end
        for i = 1, #xs do pts[i] = At(xs[i], ys[i]) end
        parts[#parts + 1] = ('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s"/>'):format(
            table.concat(pts, " "), line.colour, line.width)
        if line.dots then
            for i = 1, #line.xs do
                local cx, cy = At(line.xs[i], line.ys[i]):match("([^,]+),(.+)")
                parts[#parts + 1] = ('<circle cx="%s" cy="%s" r="3" fill="%s"/>'):format(cx, cy, line.colour)
            end
        end
        parts[#parts + 1] = ('<text x="8" y="%d" fill="%s" font-family="sans-serif" font-size="13">%s</text>'):format(
            20 + 18 * k, line.colour, line.name)
    end
    parts[#parts + 1] = "</svg>\n"
    local f = assert(io.open(path, "wb"))
    f:write(table.concat(parts, "\n"))
    f:close()
end

os.execute(package.config:sub(1, 1) == "\\" and ('mkdir "%s" 2>nul'):format(out:gsub("/", "\\")) or ("mkdir -p '%s'"):format(out))

for _, bend in ipairs(bends) do
    local rule = bend and ("bend " .. bend) or "new"
    print(("%-34s %8s  %-26s %s: points bytes worst mean"):format("trace", "seconds", "old: points bytes worst mean", rule))
    local totals = { seconds = 0, old = 0, new = 0 }
    for k, trace in ipairs(traces) do
        local seconds = trace.points[#trace.points][1] - trace.points[1][1]
        local ox, oy, ot = OldRule(trace.points)
        local nx, ny, nt = NewRule(trace.points, bend)
        local ob, nb = Bytes(ox, oy, ot), Bytes(nx, ny, nt)
        local ow, om = Stray(trace.points, ox, oy)
        local nw, nm = Stray(trace.points, nx, ny)
        totals.seconds, totals.old, totals.new = totals.seconds + seconds, totals.old + ob, totals.new + nb
        print(("%-34s %8.0f  %6d %6d %5.1f %5.1f   %6d %6d %5.1f %5.1f"):format(
            trace.label:sub(1, 34), seconds, #ox, ob, ow, om, #nx, nb, nw, nm))
        local rx, ry = {}, {}
        for i, p in ipairs(trace.points) do rx[i], ry[i] = p[2], p[3] end
        Svg(("%s/%02d%s.svg"):format(out, k, bend and ("-bend" .. bend) or ""), trace, {
            { name = "walked", xs = rx, ys = ry, colour = "#888", width = 1 },
            { name = ("old: %d points, strays up to %.1f yd"):format(#ox, ow), xs = ox, ys = oy, colour = "#e55", width = 2, dots = true },
            { name = ("%s: %d points, strays up to %.1f yd, curved at %.1f px/yd"):format(rule, #nx, nw, zoom),
                xs = nx, ys = ny, colour = "#5d5", width = 2, dots = true, curved = true },
        })
    end
    if totals.seconds > 0 then
        print(("Bytes an hour: old %.0f, %s %.0f (x%.2f). SVGs in %s.\n"):format(
            totals.old * 3600 / totals.seconds, rule, totals.new * 3600 / totals.seconds,
            totals.new / math.max(totals.old, 1), out))
    end
end
