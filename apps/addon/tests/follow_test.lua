-- Offline test of the view panning with the replay's arrow, run from the
-- real Map.lua (HEAD, ClampView, CenterOn and FollowHead) on a stand-in
-- state: still while the arrow is in the middle, a glide after it past
-- that, never letting it nearer an edge than HEAD.EDGE, a cut to an arrow
-- far off screen, and stopping at the map's edge or a drag.
-- Run with LuaJIT from apps/addon: luajit tests/follow_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local file = assert(io.open("RoadToSixty/Map.lua", "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

-- The source between two markers, the first included.
local function Slice(from, to)
    local a = assert(source:find(from, 1, true), from)
    local b = assert(source:find(to, a, true), to)
    return source:sub(a, b - 1)
end

local body = "local T = ...\nlocal state, drag = T.state, nil\n"
    .. Slice("-- The replay's arrow, and how the view pans", "local JUMP_ZOOM")
    .. Slice("local function ClampView()", "-- The view, plus margin views")
    .. Slice("local function FollowHead(elapsed)", "-- Replaying together")
    .. "\nreturn FollowHead, HEAD, function(d) drag = d end\n"

-- A 1000 by 500 view at zoom 10 over content 0..1000 by 0..1000: a view is
-- 100 by 50 content units, so fractions of it are easy to read.
-- The chunk keeps the one state table it was loaded with, so each case
-- fills that table afresh.
local T = { state = {} }
local function Fresh(hx, hy)
    local s = T.state
    for k in pairs(s) do s[k] = nil end
    s.W, s.H, s.zoom, s.minZoom, s.area = 1000, 500, 10, 1, { 0, 0, 1000, 1000 }
    s.ox, s.oy, s.cur, s.headX, s.headY, s.following = 400, 400, 5, hx, hy, true
    return s
end
Fresh(450, 425)
local FollowHead, HEAD, SetDrag = assert(loadstring(body, "follow"))(T)

local function Fraction(s)
    local vw, vh = s.W / s.zoom, s.H / s.zoom
    return (s.headX - s.ox) / vw, (s.headY - s.oy) / vh
end
local function Near(a, b) return math.abs(a - b) < 1e-6 end

-- In the middle: nothing moves, and following ends.
local s = Fresh(450, 425)
check(FollowHead(0.016) == false and s.ox == 400 and s.oy == 400, "moved with the arrow in the middle")
check(s.following == nil, "still following with the arrow in the middle")

-- Past the middle part: a glide, a share of the way per frame, towards it.
s = Fresh(480, 425)                         -- fx 0.8, the middle part ends at 0.7
check(FollowHead(0.016) == true, "no glide past the middle")
local fx = Fraction(s)
check(fx < 0.8 and fx > 0.7, "not a share of the way: " .. fx)
check(s.following == true, "stopped before arriving")
local frames = 0
while s.following and frames < 600 do
    FollowHead(0.016)
    frames = frames + 1
end
fx = Fraction(s)
check(Near(fx, 1 - HEAD.ZONE), "did not arrive on the middle part's edge: " .. fx)
check(frames > 30 and frames < 300, "glide took " .. frames .. " frames")

-- A glide never leaves the arrow nearer an edge than HEAD.EDGE, even
-- when a fast replay carried it past the edge in one frame.
for _, start in ipairs({ 495, 503, 520 }) do     -- fx 0.95, 1.03, 1.2: on screen and just off it
    s = Fresh(start, 425)
    check(FollowHead(0.016) == true, "no move for an arrow at " .. start)
    fx = Fraction(s)
    check(fx <= 1 - HEAD.EDGE + 1e-9, "arrow left at fx " .. fx .. " from " .. start)
end
s = Fresh(450, 398)                         -- fy -0.04, just above the top
FollowHead(0.016)
local _, fy = Fraction(s)
check(fy >= HEAD.EDGE - 1e-9, "arrow left at fy " .. fy)

-- Far off screen: centred at once.
s = Fresh(700, 425)                         -- fx 3
check(FollowHead(0.016) == true and s.following == nil, "a far arrow was not cut to")
fx, fy = Fraction(s)
check(Near(fx, 0.5) and Near(fy, 0.5), "a far arrow was not centred: " .. fx .. ", " .. fy)

-- At the map's edge the view cannot move: following ends without a move.
s = Fresh(995, 425)
s.ox = 900                                  -- the view already at the right edge, fx 0.95
check(FollowHead(0.016) == false and s.following == nil and s.ox == 900, "pushed past the map's edge")

-- A drag, zoomed out, or no arrow: nothing moves and following ends.
s = Fresh(480, 425)
SetDrag({})
check(FollowHead(0.016) == false and s.following == nil and s.ox == 400, "followed during a drag")
SetDrag(nil)
s = Fresh(480, 425)
s.zoom = s.minZoom
check(FollowHead(0.016) == false and s.following == nil, "followed zoomed out")
s = Fresh(nil, nil)
check(FollowHead(0.016) == false and s.following == nil, "followed with no arrow")

-- A slow frame glides further than a fast one, but never past the middle part.
s = Fresh(480, 425)
FollowHead(0.016)
local short = s.ox - 400
s = Fresh(480, 425)
FollowHead(0.5)
local long = s.ox - 400
check(short > 0 and long > short and Fraction(s) >= 1 - HEAD.ZONE - 1e-9,
    "frame time not used: " .. short .. ", " .. long)

if failures > 0 then os.exit(1) end
print("follow_test: all passed")
