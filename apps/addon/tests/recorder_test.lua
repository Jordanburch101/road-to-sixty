-- Offline test of Recorder.lua with a fake WoW API. Run with LuaJIT from the
-- repo root: luajit tests/recorder_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

-- Fake game state the API reads from.
local game = { c = 0, x = 0, y = 0, taxi = false, ghost = false, instance = false, now = 1000000 }

local handlers, commands, tickFn = {}, {}, nil
local ns = {
    char = { segments = {}, events = {}, totals = { distance = 0, flown = 0 } },
    errors = { count = 0 },
}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
function ns.Command(name, _, fn) commands[name] = fn end
function ns.Print() end
function ns.SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        ns.errors.count = ns.errors.count + 1
        print("error in SafeCall: " .. tostring(err))
    end
end

local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end

-- The map position API: one map per continent, identity transform.
C_Map = {
    GetBestMapForUnit = function() return game.instance and 999 or 1415 end,
    GetPlayerMapPosition = function(mapID)
        if game.instance then return nil end
        return { x = game.x, y = game.y, mapID = mapID }
    end,
    GetWorldPosFromMapPos = function(_, pos) return game.c, { x = pos.x, y = pos.y } end,
    GetMapInfo = function() return { name = "Test Zone" } end,
}
C_Timer = {
    NewTicker = function(_, fn)
        tickFn = fn
        return { Cancel = function() end, IsCancelled = function() return false end }
    end,
}
UnitOnTaxi = function() return game.taxi end
UnitIsGhost = function() return game.ghost end
IsInInstance = function() return game.instance end
-- The server clock gives whole seconds; GetTime has fractions.
time = function() return math.floor(game.now) end
GetTime = function() return game.now end

ns.Now = function() return time() end
assert(loadfile("RoadToSixty/Packed.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Recorder.lua"))("RoadToSixty", ns)
local Recorder = ns.Recorder

-- Every sample the game reached, for comparing with what was decoded.
local SAMPLE_INTERVAL = 0.25

local function Tick()
    game.now = game.now + SAMPLE_INTERVAL
    assert(tickFn, "the recorder never started its ticker")()
end

Fire("PLAYER_LOGIN")
Fire("PLAYER_ENTERING_WORLD")

-- 1. Walk east 8 yards a second (2 a sample) for 60 s. A point is stored at
-- the first sample at least 20 yards on, so every tenth sample: the start
-- plus 239 / 10 more.
for _ = 1, 240 do
    game.x = game.x + 2
    Tick()
end
check(#ns.char.segments == 1, "walking makes one segment, got " .. #ns.char.segments)
check(Recorder:OpenPoints() == 24, "24 points while walking, got " .. Recorder:OpenPoints())
check(ns.char.segments[1].d ~= "", "a minute of walking is written into the segment before logout")

-- 2. Teleport 5000 yards: new segment, no line across.
game.x = game.x + 5000
Tick()
check(#ns.char.segments == 2, "teleport starts a new segment")

-- 3. Take a flight path: new segment in mode t.
game.taxi = true
for _ = 1, 20 do
    game.y = game.y + 30
    Tick()
end
check(#ns.char.segments == 3 and ns.char.segments[3].m == "t", "flight gets its own segment")
check(ns.char.totals.flown > 0, "flight distance counted")
game.taxi = false
Tick()

-- 4. Enter a dungeon: segment closes, nothing recorded inside.
local before = #ns.char.segments
game.instance = true
for _ = 1, 10 do
    game.x = game.x + 50
    Tick()
end
check(#ns.char.segments == before, "no segments inside an instance")
check(Recorder:OpenPoints() == 0, "segment closed in instance")
local _, lx = Recorder:Position()
check(lx ~= nil, "last outdoor position kept for indoor events")
game.instance = false
Tick()
check(#ns.char.segments == before + 1, "new segment after leaving the instance")

-- 5. Loading screen closes the segment.
Fire("PLAYER_ENTERING_WORLD")
game.x = game.x + 20
Tick()
check(#ns.char.segments == before + 2, "loading screen starts a new segment")

-- 6. Logout flushes the open segment into its string.
for _ = 1, 10 do
    game.y = game.y - 20
    Tick()
end
Fire("PLAYER_LOGOUT")
local last = ns.char.segments[#ns.char.segments]
check(last.d ~= "", "logout writes the open segment")

-- 7. Saved data decodes back to points the player actually stood on, in time order.
local paths = Recorder:GetPaths()
check(#paths == #ns.char.segments, "one decoded path per segment")
local lastT = 0
for i, path in ipairs(paths) do
    check(#path.x == #path.y and #path.x == #path.t, "path " .. i .. " arrays line up")
    for j = 1, #path.t do
        check(path.t[j] >= lastT, "times never go backwards")
        lastT = path.t[j]
    end
end
local final = paths[#paths]
check(final.x[#final.x] == game.x and final.y[#final.y] == game.y,
    ("last decoded point is where the player stopped: got %s, %s want %s, %s"):format(
        final.x[#final.x], final.y[#final.y], game.x, game.y))

-- 8. Stats agree with the decoded paths.
local segments, points = Recorder:Stats()
local decodedPoints = 0
for _, path in ipairs(paths) do decodedPoints = decodedPoints + #path.x end
check(segments == #paths and points == decodedPoints,
    ("stats count %d points, decoded %d"):format(points, decodedPoints))

-- 9. After a wipe (/rts reset, /rts seed) the open segment is dropped and
-- recording carries on into the new segments table.
ns.char.segments = {}
Recorder:Reset()
check(Recorder:OpenPoints() == 0, "reset drops the open segment")
game.x = game.x + 20
Tick()
check(#ns.char.segments == 1, "recording continues after a reset")

-- 10. Jump reasons on new segments.
local function lastJump()
    return ns.char.segments[#ns.char.segments].j
end
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-guid", 8690)   -- Hearthstone
game.x = game.x + 5000
Tick()
check(lastJump() == "h", "hearthstone jump, got " .. tostring(lastJump()))

game.instance = true
Tick()
game.instance = false
Tick()
check(lastJump() == "i", "left an instance, got " .. tostring(lastJump()))

-- Sent out of an instance far from its door (left the group): a teleport.
game.instance = true
Tick()
game.instance = false
game.x = game.x + 1000
Tick()
check(lastJump() == "it", "sent out of an instance, got " .. tostring(lastJump()))

-- Old saves have that as "i"; read back, it is marked by distance.
local function Seg(x, j)
    return { m = "w", c = 0, t = 1, x = x, y = 0, d = "", j = j }
end
local marked = Recorder:MarkTeleportsOut({
    Recorder:Decode(Seg(0)), Recorder:Decode(Seg(1000, "i")), Recorder:Decode(Seg(1050, "i")),
})
check(marked[2].j == "it" and marked[3].j == "i", ("old exits marked by distance, got %s, %s"):format(
    tostring(marked[2].j), tostring(marked[3].j)))

game.ghost = true
game.x = game.x + 500
Tick()
check(lastJump() == "d", "died, got " .. tostring(lastJump()))
game.ghost = false
Tick()

-- Dying inside an instance: the ghost appears at a graveyard outside.
game.instance = true
Tick()
game.instance = false
game.ghost = true
game.x = game.x + 800
Tick()
check(lastJump() == "di", "died in an instance, got " .. tostring(lastJump()))
game.ghost = false
Tick()

-- A corpse run back in as a ghost, revived inside, died again: still a death.
game.ghost = true
game.x = game.x + 200
Tick()
game.instance = true
Tick()
game.ghost = false
Tick()
game.instance = false
game.ghost = true
game.x = game.x + 800
Tick()
check(lastJump() == "di", "died again after a corpse run in, got " .. tostring(lastJump()))
game.ghost = false
Tick()

-- Old saves have such deaths as "i"; they decode as deaths.
local old = Recorder:Decode({ m = "g", c = 0, t = 1, x = 0, y = 0, d = "", j = "i" })
check(old.j == "di", "old death in an instance decodes as a death, got " .. tostring(old.j))
check(Recorder:Decode({ m = "w", c = 0, t = 1, x = 0, y = 0, d = "", j = "i" }).j == "i",
    "walking out of an instance stays as leaving it")

game.x = game.x + 5000
Tick()
check(lastJump() == nil, "unexplained teleport has no reason, got " .. tostring(lastJump()))

Fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "cast-guid", 8690)
game.x = game.x + 5000
Tick()
check(lastJump() == nil, "someone else's hearthstone is ignored")

-- Reading back: a far jump with no saved reason is an unnamed teleport.
local function P(c, m, j, x, y) return { c = c, m = m, j = j, x = { x }, y = { y } } end
local JR = function(a, b) return Recorder:JumpReason(a, b) end
check(JR(P(0, "w", nil, 0, 0), P(0, "w", nil, 5000, 0)) == "u", "a far unexplained jump reads as a teleport")
check(JR(P(0, "w", nil, 0, 0), P(0, "t", nil, 20, 0)) == nil, "a mode change in place stays unexplained")
check(JR(P(0, "w", nil, 0, 0), P(0, "g", nil, 5000, 0)) == nil, "a ghost's jump is not a teleport")
check(JR(P(0, "w", nil, 0, 0), P(0, "w", "h", 5000, 0)) == "h", "a saved reason is kept")
check(JR(nil, P(0, "w", nil, 5000, 0)) == nil, "the first segment has no jump")
check(JR({ c = 0, m = "w", x = {}, y = {} }, P(0, "w", nil, 5000, 0)) == nil, "an empty segment before is skipped")

-- 11. Bends keep their shape (#57). Each walk is a segment of its own, one
-- position a sample, rounded to whole yards as the game's are.
local function Walk(points)
    Fire("PLAYER_ENTERING_WORLD")
    for _, p in ipairs(points) do
        game.x, game.y = math.floor(p[1] + 0.5), math.floor(p[2] + 0.5)
        Tick()
    end
    return Recorder:GetPath(#ns.char.segments)
end

-- The furthest any walked position is from the stored line, with the last
-- position joined on (the part since the last stored point).
local function Worst(points, path)
    local xs, ys = { unpack(path.x) }, { unpack(path.y) }
    xs[#xs + 1], ys[#ys + 1] = game.x, game.y
    local worst = 0
    for _, p in ipairs(points) do
        local best = math.huge
        for i = 2, #xs do
            local ax, ay, dx, dy = xs[i - 1], ys[i - 1], xs[i] - xs[i - 1], ys[i] - ys[i - 1]
            local lengthSq = dx * dx + dy * dy
            local u = lengthSq > 0 and math.max(0, math.min(1, ((p[1] - ax) * dx + (p[2] - ay) * dy) / lengthSq)) or 0
            local ex, ey = ax + u * dx - p[1], ay + u * dy - p[2]
            best = math.min(best, math.sqrt(ex * ex + ey * ey))
        end
        worst = math.max(worst, best)
    end
    return worst
end

local function Line(points, x1, y1, x2, y2, step)
    local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    for k = 1, math.floor(length / step) do
        local f = k * step / length
        points[#points + 1] = { x1 + (x2 - x1) * f, y1 + (y2 - y1) * f }
    end
    return points
end

-- Twice round a tree, 5 yards out, at 7 yards a second.
local cx, cy = game.x + 5000, game.y
local tree = {}
for k = 0, 36 do
    local a = k * 1.75 / 5
    tree[#tree + 1] = { cx + 5 * math.cos(a), cy + 5 * math.sin(a) }
end
local path = Walk(tree)
local worst = Worst(tree, path)
check(worst <= 3, ("circling a tree stays within 3 yards, strays %.1f"):format(worst))
check(#path.x <= 16, "circling a tree twice stores at most 16 points, got " .. #path.x)

-- Along a fence and round its corner.
local fence = Line({ { cx, cy } }, cx, cy, cx + 30, cy, 1.75)
Line(fence, cx + 30, cy, cx + 30, cy + 30, 1.75)
path = Walk(fence)
worst = Worst(fence, path)
check(worst <= 3, ("a fence corner stays within 3 yards, strays %.1f"):format(worst))

-- Out 10 yards and back: the turn is kept.
local back = Line({ { cx, cy } }, cx, cy, cx + 10, cy, 1.75)
Line(back, cx + 10, cy, cx, cy, 1.75)
path = Walk(back)
worst = Worst(back, path)
check(worst <= 3, ("going back on oneself stays within 3 yards, strays %.1f"):format(worst))

-- Standing still, or fighting in place within a yard, for two minutes: only the start.
local still = {}
for k = 1, 480 do
    still[k] = { cx + (k % 3) - 1, cy + (k % 2) }
end
path = Walk(still)
check(#path.x == 1, "fighting in place stores no points, got " .. (#path.x - 1))

-- A straight run stores no more than before: about every 20 yards.
local run = Line({ { cx, cy } }, cx, cy, cx + 300, cy + 100, 1.75)
path = Walk(run)
check(#path.x <= 17, "a 316-yard run stores at most 17 points, got " .. #path.x)

check(ns.errors.count == 0, "no errors while recording")

if failures == 0 then
    print("Recorder tests passed.")
else
    print(failures .. " recorder test(s) failed.")
    os.exit(1)
end
