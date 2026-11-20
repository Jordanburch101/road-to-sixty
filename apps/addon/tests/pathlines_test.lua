-- Offline test of PathLines.lua: lines kept from one build to the next,
-- found in view through their boxes, and sized only when in view and not
-- sized for the zoom yet. Run with LuaJIT from apps/addon:
-- luajit tests/pathlines_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/PathLines.lua"))("RoadToSixty", ns)
local PathLines = ns.PathLines

-- A line object that counts the calls made on it.
local calls = 0
local function NewLine()
    local line = {}
    function line:SetThickness(t) calls = calls + 1; self.thickness = t end
    function line:SetShown(on) calls = calls + 1; self.shown = on end
    function line:SetSize(w) calls = calls + 1; self.w = w end
    function line:SetAlpha(a) calls = calls + 1; self.a = a end
    return line
end

-- A zig-zag path of n lines along x, one content unit per line.
local function Path(n, from)
    local specs = {}
    for i = 1, n do
        local x = (from or 0) + i
        specs[i] = { x - 1, (i % 2) * 0.5, x, ((i + 1) % 2) * 0.5, "w", i + 1 }
    end
    return specs
end

-- Boxes and InView find exactly the lines a plain test of every line finds.
local specs = Path(200)
local boxes = PathLines.Boxes(specs)
check(#boxes == math.ceil(200 / 32), "a box per 32 lines, got " .. #boxes)
for _, area in ipairs({ { 10.5, -1, 20.2, 1 }, { -5, -5, 500, 5 }, { 300, 0, 400, 1 }, { 63.9, 0.4, 64.1, 0.6 } }) do
    local want = {}
    for i, s in ipairs(specs) do
        if math.max(s[1], s[3]) >= area[1] and math.min(s[1], s[3]) <= area[3]
            and math.max(s[2], s[4]) >= area[2] and math.min(s[2], s[4]) <= area[4] then
            want[#want + 1] = i
        end
    end
    local out, n = PathLines.InView(specs, boxes, area[1], area[2], area[3], area[4], { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25 })
    local same = n == #want and #out == n
    for k = 1, n do same = same and out[k] == want[k] end
    check(same, ("InView finds the lines in %s, %s, %s, %s: got %d, want %d"):format(area[1], area[2], area[3], area[4], n, #want))
end
check(#PathLines.Boxes({}) == 0, "no lines, no boxes")

-- Reuse keeps the line of every stretch drawn again, at its new index,
-- and hands out the others as spare, those in use last.
local lines = {}
for i = 1, 200 do lines[i] = NewLine(); lines[i].was = i end
local pool = NewLine()
lines[201] = pool
-- Panned on: the first 50 lines are gone and 30 new ones follow.
local panned = {}
for i = 51, 200 do
    local s = specs[i]
    panned[#panned + 1] = { s[1], s[2], s[3], s[4], s[5], s[6] }
end
for _, s in ipairs(Path(30, 200)) do panned[#panned + 1] = s end
local order, spare = PathLines.Reuse(specs, lines, 200, panned)
local kept = 0
for i = 1, #panned do
    if order[i] then
        kept = kept + 1
        check(order[i].was == i + 50, "a kept line drew the same stretch")
    end
end
check(kept == 150, "every stretch drawn again keeps its line, got " .. kept)
check(#spare == 51 and spare[1] == pool and spare[#spare].was == 1, "the lines no stretch kept are spare, the pool's first")
-- The same lines again keep every line; another character's do not.
order = PathLines.Reuse(specs, lines, 200, specs)
local all = true
for i = 1, 200 do all = all and order[i] == lines[i] end
check(all, "a build of the same lines keeps all of them in place")
local theirs = {}
for i, s in ipairs(specs) do theirs[i] = { s[1], s[2], s[3], s[4], s[5], s[6], track = {} } end
order = PathLines.Reuse(specs, lines, 200, theirs)
check(next(order) == nil, "a line of another track is not taken for one of the path")
-- A stretch drawn twice (there and back on the same points) keeps two lines.
local twice = { { 0, 0, 1, 1 }, { 1, 1, 0, 0 }, { 0, 0, 1, 1 } }
order, spare = PathLines.Reuse(twice, { NewLine(), NewLine(), NewLine() }, 3, twice)
check(order[1] and order[3] and order[1] ~= order[3] and #spare == 0, "repeated stretches each keep a line of their own")

-- Fit sizes only lines shown and not sized for the zoom yet, once.
for i = 1, 200 do lines[i].on, lines[i].tz = i % 2 == 0, 1 end
local idx = { 1, 2, 3, 4, 5, 6 }
calls = 0
check(PathLines.Fit(lines, idx, 6, 2, 2) == 3 and calls == 3, "Fit sizes the shown lines in view")
check(lines[2].thickness == 1 and lines[2].tz == 2 and lines[1].tz == 1, "sized for the zoom, in content units")
calls = 0
check(PathLines.Fit(lines, idx, 6, 2, 2) == 0 and calls == 0, "lines sized for the zoom are left alone")
calls = 0
check(PathLines.Fit(lines, nil, 10, 2, 2) == 7 and calls == 7, "with no indexes, every line is sized, shown or not")

-- Reveal shows or hides only on a change, and sizes a line coming into
-- sight in view first; one out of view waits for Fit.
local line = NewLine()
line.on, line.tz = false, 1
local fit = { 0, 0, 10, 10 }
calls = 0
PathLines.Reveal(line, { 1, 1, 2, 2 }, true, 4, 2, fit)
check(line.shown == true and line.on and line.tz == 4 and line.thickness == 0.5 and calls == 2, "a line shown in view is sized first")
calls = 0
PathLines.Reveal(line, { 1, 1, 2, 2 }, true, 4, 2, fit)
check(calls == 0, "showing a shown line again does nothing")
line.on, line.tz = false, 1
calls = 0
PathLines.Reveal(line, { 20, 20, 30, 30 }, true, 4, 2, fit)
check(line.on and line.tz == 1 and calls == 1, "a line shown out of view is not sized")
PathLines.Reveal(line, nil, false)
check(line.on == false and line.shown == false, "hidden")

-- FitJump sizes every piece and moves dots to the rows the zoom shows:
-- fading in view, at once with snap.
local stroke, dot = NewLine(), NewLine()
stroke.width = 5
dot.size, dot.fade, dot.fadePx, dot.target, dot.alpha = 6, 4, 8, 0, 0
local jump = { parts = { stroke, dot }, tz = 1 }
local sized, fading = PathLines.FitJump(jump, 2, false)
check(sized == 2 and stroke.thickness == 2.5 and dot.w == 3 and jump.tz == 2, "a jump's pieces are sized for the zoom")
check(fading and dot.target == 1 and dot.alpha == 0, "in view, a dot whose row shows fades in")
dot.target, dot.alpha = 0, 0
sized, fading = PathLines.FitJump(jump, 2, true)
check(not fading and dot.target == 1 and dot.alpha == 1 and dot.a == 1, "out of view, it takes its row at once")
check(dot.alphaSet == 1 and dot.sz == 2 and stroke.sz == 2, "each piece keeps the alpha and zoom set on it")
-- A chunk of the pieces only (the ones in view): the others and the jump's
-- zoom are left alone.
calls = 0
sized = PathLines.FitJump(jump, 4, true, 2, 2)
check(sized == 1 and calls == 1 and dot.w == 1.5 and stroke.thickness == 2.5 and jump.tz == 2,
    "a chunk of a jump's pieces is sized alone")

if failures > 0 then
    print(failures .. " PathLines test(s) failed.")
    os.exit(1)
end
print("PathLines tests passed.")
