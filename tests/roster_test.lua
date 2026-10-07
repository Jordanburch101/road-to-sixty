-- Offline test of Roster.lua with a fake WoW API. Run with LuaJIT from the
-- repo root: luajit tests/roster_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers = {}
local recorded = {}     -- full journey the fake recorder returns, one path per segment
local ns = {
    db = {},
    char = { segments = {}, events = { { 100, "lvl" } }, kills = { d = "" }, totals = { kills = 3 } },
}
ns.view = ns.char
ns.Recorder = {
    GetPath = function(_, i) return recorded[i] end,
    GetPaths = function() return recorded end,
    -- As Recorder.lua's Decode.
    Decode = function(_, seg)
        local t, x, y = seg.t, seg.x, seg.y
        local ts, xs, ys = { t }, { x }, { y }
        for dt, dx, dy in seg.d:gmatch("(-?%d+),(-?%d+),(-?%d+)") do
            t, x, y = t + tonumber(dt), x + tonumber(dx), y + tonumber(dy)
            ts[#ts + 1], xs[#xs + 1], ys[#ys + 1] = t, x, y
        end
        return { m = seg.m, c = seg.c, j = seg.j, t = ts, x = xs, y = ys }
    end,
}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end
-- Sets the fake journey; the roster only counts ns.char.segments.
local function Record(paths)
    recorded = paths
    ns.char.segments = {}
    for i = 1, #paths do ns.char.segments[i] = {} end
end

local now = 1000
UnitName = function() return "Eagin" end
GetRealmName = function() return "Test" end
UnitClass = function() return "Mage", "MAGE" end
UnitLevel = function() return 12 end
IsInInstance = function() return false end
C_Map = { GetBestMapForUnit = function() return 1436 end }
time = function() return now end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

assert(loadfile("RoadToSixty/Roster.lua"))("RoadToSixty", ns)
local Roster = ns.Roster

-- A path from a list of x, y pairs, a point every 2 seconds from t0.
local function path(m, c, j, t0, points)
    local ts, xs, ys = {}, {}, {}
    for i = 1, #points, 2 do
        xs[#xs + 1], ys[#ys + 1] = points[i], points[i + 1]
        ts[#ts + 1] = t0 + 2 * (#ts)
    end
    return { m = m, c = c, j = j, t = ts, x = xs, y = ys }
end
-- A straight line east with a point every 20 yards.
local function line(m, c, j, t0, x0, y0, count)
    local points = {}
    for i = 0, count - 1 do
        points[#points + 1], points[#points + 2] = x0 + 20 * i, y0
    end
    return path(m, c, j, t0, points)
end

-- A zigzag: 100 yards north and back every 40 yards east, as when fighting
-- in a camp. Simplifying must keep every corner.
local zig = {}
for i = 0, 10 do
    zig[#zig + 1], zig[#zig + 2] = i * 40, (i % 2) * 100
end

-- An existing journey, with a roster entry from before the journey copy.
ns.char.rosterBuilt = true
ns.db.roster = { ["Eagin-Test"] = { path = { { c = 0, d = "0,0;150,0" } } } }
Record({
    line("w", 0, "l", 100, 0, 0, 51),          -- 1000 yards east, straight
    path("g", 0, "d", 300, { 500, 900, 520, 900 }),
    path("w", 0, nil, 400, zig),
    line("t", 1, "b", 500, 6000, 0, 11),       -- boat to Kalimdor, then a flight
})

Fire("PLAYER_LOGIN")
local e = ns.db.roster["Eagin-Test"]
check(e.class == "MAGE" and e.level == 12 and e.zone == 1436, "entry has class, level and zone")
check(ns.char.rosterBuilt == 3, "journey copied on first login")
check(e.path == nil and e.journey ~= nil, "old coarse path replaced by the journey copy")
check(e.journey.events == ns.char.events and e.journey.kills == ns.char.kills, "copy shares the journey's tables")
check(e.journey.rosterBuilt == nil, "copy leaves out the roster's own flag")

local paths = Roster:Paths(e)
check(#paths == 4, "one path per segment, got " .. #paths)
check(#paths[1].x == 2 and paths[1].x[2] == 1000 and paths[1].t[2] == 200, "straight line keeps only its ends, with times")
check(#paths[3].x == 11, "zigzag keeps every corner, got " .. #paths[3].x)
check(paths[2].m == "g" and paths[2].j == "d", "ghost run kept with its mode and reason")
check(paths[4].m == "t" and paths[4].j == "b" and paths[4].c == 1, "flight keeps mode, reason and continent")
check(e.c == 1 and e.x == 6200 and e.y == 0, "last position from the last point")

-- Playing on: the last segment grows and a new one starts; logout brings
-- the copy up to date.
table.insert(recorded[4].t, 600)
table.insert(recorded[4].x, 6400)
table.insert(recorded[4].y, 300)
recorded[5] = line("w", 1, "h", 700, -3000, 50, 3)
ns.char.segments[5] = {}
ns.char.played = 4321
now = 5000
Fire("PLAYER_LOGOUT")
check(e.seen == 5000, "logout sets last seen")
check(e.journey.played == 4321, "logout copies new values")
paths = Roster:Paths(e)
check(#paths == 5 and paths[5].j == "h", "new segment added on logout")
local last = paths[4]
check(last.x[#last.x] == 6400 and last.y[#last.y] == 300 and last.t[#last.t] == 600, "grown segment redone on logout")
check(e.x == -2960, "last position follows the journey")

-- An entry saved before the journey copy still shows its coarse path.
ns.db.roster["Alt-Test"] = {
    name = "Alt", class = "WARRIOR", seen = 9999, level = 30,
    path = { { c = 0, d = "100,200;300,-400" } },
}
local alt = ns.db.roster["Alt-Test"]
local old = Roster:Paths(alt)
check(old[1].m == "w" and old[1].x[2] == 300 and old[1].y[2] == -400, "old absolute pieces still decode")

local entries = Roster:Entries()
check(entries[1].key == "Eagin-Test" and entries[2].key == "Alt-Test", "this character listed first")

-- Views: an alt without a journey copy cannot be shown; one with it can.
check(not Roster:SetView(alt) and ns.view == ns.char, "no view of a character without a copy")
alt.journey = { segments = { { m = "w", c = 0, t = 10, x = 1, y = 2, d = "5,10,0" } }, events = {} }
check(Roster:SetView(alt) and ns.view == alt.journey and Roster:ViewEntry() == alt, "view switches to the alt")
check(Roster:ViewLevel() == 30, "view level is the alt's")
local viewPaths = Roster:ViewPaths()
check(#viewPaths == 1 and viewPaths[1].x[2] == 11 and viewPaths[1].t[2] == 15, "view paths are the alt's")
check(not Roster:SetView(e) and ns.view == ns.char and Roster:ViewEntry() == e, "own entry goes back to this journey")
check(Roster:ViewLevel() == 12 and Roster:ViewPaths() == recorded, "own view is live")

-- Next login does not rebuild, so the saved copy is kept.
local before = e.journey.segments[1]
Fire("PLAYER_LOGIN")
check(e.journey.segments[1] == before and #Roster:Paths(e) == 5, "copy kept across logins")

-- A reset journey empties the copy.
Record({})
Roster:Rebuild()
check(#e.journey.segments == 0, "rebuild of an empty journey empties the path")

if failures == 0 then
    print("Roster tests passed.")
else
    print(failures .. " roster test(s) failed.")
    os.exit(1)
end
