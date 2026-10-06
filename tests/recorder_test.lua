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
time = function() return game.now end
GetTime = function() return game.now end

assert(loadfile("RoadToSixty/Recorder.lua"))("RoadToSixty", ns)
local Recorder = ns.Recorder

-- Every sample the game reached, for comparing with what was decoded.
local function Tick()
    game.now = game.now + 1
    assert(tickFn, "the recorder never started its ticker")()
end

Fire("PLAYER_LOGIN")
Fire("PLAYER_ENTERING_WORLD")

-- 1. Walk east 7 yards a second for 60 s. A point is stored at the first
-- sample at least 15 yards on, so every third sample (21 yards): the start
-- plus 59 / 3 more.
for _ = 1, 60 do
    game.x = game.x + 7
    Tick()
end
check(#ns.char.segments == 1, "walking makes one segment, got " .. #ns.char.segments)
check(Recorder:OpenPoints() == 20, "20 points while walking, got " .. Recorder:OpenPoints())

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

game.ghost = true
game.x = game.x + 500
Tick()
check(lastJump() == "d", "died, got " .. tostring(lastJump()))
game.ghost = false
Tick()

game.x = game.x + 5000
Tick()
check(lastJump() == nil, "unexplained teleport has no reason, got " .. tostring(lastJump()))

Fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "cast-guid", 8690)
game.x = game.x + 5000
Tick()
check(lastJump() == nil, "someone else's hearthstone is ignored")

check(ns.errors.count == 0, "no errors while recording")

if failures == 0 then
    print("Recorder tests passed.")
else
    print(failures .. " recorder test(s) failed.")
    os.exit(1)
end
