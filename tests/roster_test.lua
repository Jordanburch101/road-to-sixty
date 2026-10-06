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
local recorded = {}     -- full journey the fake recorder returns
local ns = {
    db = {},
    char = {},
    Recorder = { GetPaths = function() return recorded end },
}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
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

assert(loadfile("ForeverJourney/Roster.lua"))("ForeverJourney", ns)
local Roster = ns.Roster

-- An existing journey: two pieces, the second after a 5000 yard teleport.
local function line(c, x0, y0, dx, count)
    local xs, ys = {}, {}
    for i = 0, count - 1 do
        xs[#xs + 1], ys[#ys + 1] = x0 + dx * i, y0
    end
    return { m = "w", c = c, x = xs, y = ys, t = {} }
end
recorded = {
    line(0, 0, 0, 20, 51),          -- 1000 yards east, a point every 20
    { m = "g", c = 0, x = { 500, 520 }, y = { 900, 900 }, t = {} },   -- ghost run, left out
    line(0, 6000, 0, 20, 11),       -- teleport, then 200 yards
}

Fire("PLAYER_LOGIN")
local e = ns.db.roster["Eagin-Test"]
check(e ~= nil, "login creates a roster entry")
check(e.class == "MAGE" and e.level == 12 and e.zone == 1436, "entry has class, level and zone")
check(ns.char.rosterBuilt, "existing journey converted on first login")

local paths = Roster:Paths(e)
check(#paths == 2, "teleport splits the coarse path, got " .. #paths .. " pieces")
check(#paths[1].x == 7, "about one point per 150 yards over 1000, got " .. #paths[1].x)
for _, p in ipairs(paths) do
    for i = 2, #p.x do
        check(p.x[i] - p.x[i - 1] >= 150, "coarse points at least 150 yards apart")
    end
end

-- Live tracking after login continues the last piece, and Paths sees the
-- points before they are flushed.
for i = 1, 20 do
    Roster:Track(0, 6200 + i * 20, 0)
end
local live = Roster:Paths(e)
check(#live == 2 and #live[2].x > #paths[2].x, "live points show up before logout")
check(e.x == 6600, "last position follows tracking")

-- Logout writes the buffered points and the time.
now = 5000
Fire("PLAYER_LOGOUT")
check(e.seen == 5000, "logout sets last seen")
local saved = Roster:Paths(e)
check(#saved[2].x == #live[2].x, "logout keeps every live point")

-- A second character appears in Entries, this one stays first.
ns.db.roster["Alt-Test"] = { name = "Alt", class = "WARRIOR", seen = 9999, path = {} }
local entries = Roster:Entries()
check(entries[1].key == "Eagin-Test" and entries[2].key == "Alt-Test", "this character listed first")

-- Next login does not rebuild (rosterBuilt), so the saved path is kept.
Fire("PLAYER_LOGIN")
check(#Roster:Paths(e)[2].x == #saved[2].x, "path kept across logins")

if failures == 0 then
    print("Roster tests passed.")
else
    print(failures .. " roster test(s) failed.")
    os.exit(1)
end
