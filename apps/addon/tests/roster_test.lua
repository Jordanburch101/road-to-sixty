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
    db = { showPaths = {} },
    char = { segments = {}, events = { { 100, "lvl" } }, kills = { d = "" }, totals = { kills = 3 } },
}
ns.view = ns.char
-- As Core.lua's, which also refuses a secret value.
ns.PlayerGUID = function() return UnitGUID("player") end
ns.Recorder = {
    GetPath = function(_, i) return recorded[i] end,
    GetPaths = function() return recorded end,
    MarkTeleportsOut = function(_, paths) return paths end,
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
local GUID = "Player-1-0000000E"
UnitGUID = function() return GUID end
UnitClass = function() return "Mage", "MAGE" end
UnitLevel = function() return 12 end
IsInInstance = function() return false end
C_Map = { GetBestMapForUnit = function() return 1436 end }
time = function() return now end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

ns.Now = function() return time() end
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
-- in a camp. The copy must keep every corner.
local zig = {}
for i = 0, 10 do
    zig[#zig + 1], zig[#zig + 2] = i * 40, (i % 2) * 100
end

-- A corpse run that circles a tree 5 yards out, as the recorder keeps it
-- (#57): eight points round. The copy must keep the loop.
local loop = { 500, 900 }
for k = 0, 8 do
    local a = k * math.pi / 4
    loop[#loop + 1], loop[#loop + 2] = math.floor(510 + 5 * math.cos(a) + 0.5), math.floor(900 + 5 * math.sin(a) + 0.5)
end

-- An existing journey, with a roster entry from before the journey copy
-- and before entries were keyed by GUID, its path drawn on the map.
ns.char.rosterBuilt = true
ns.db.roster = { ["Eagin-Test"] = { path = { { c = 0, d = "0,0;150,0" } }, played = 99 } }
ns.db.showPaths["Eagin-Test"] = true
Record({
    line("w", 0, "l", 100, 0, 0, 51),          -- 1000 yards east, straight
    path("g", 0, "d", 300, loop),
    path("w", 0, nil, 400, zig),
    line("t", 1, "b", 500, 6000, 0, 11),       -- boat to Kalimdor, then a flight
})

Fire("PLAYER_LOGIN")
local e = ns.db.roster[GUID]
check(e and ns.db.roster["Eagin-Test"] == nil, "the Name-Realm entry moves under the GUID")
check(e.guid == GUID and e.name == "Eagin" and e.realm == "Test", "entry has the GUID, name and realm")
check(e.played == nil, "starting afresh, as a shared entry may hold another character's journey")
check(ns.db.showPaths[GUID] and ns.db.showPaths["Eagin-Test"] == nil, "its path toggle moves too")
check(e.class == "MAGE" and e.level == 12 and e.zone == 1436, "entry has class, level and zone")
check(ns.char.class == "MAGE", "the character's own file keeps its class, for the sync server")
check(ns.char.rosterBuilt == 5, "journey copied on first login")
check(ns.char.rosterKey == "Eagin-Test", "the journey records its roster key, for the app")
check(e.path == nil and e.journey ~= nil, "old coarse path replaced by the journey copy")
check(e.journey.events == ns.char.events and e.journey.kills == ns.char.kills, "copy shares the journey's tables")
check(e.journey.rosterBuilt == nil, "copy leaves out the roster's own flag")

local paths = Roster:Paths(e)
check(#paths == 4, "one path per segment, got " .. #paths)
check(#paths[1].x == 51 and paths[1].x[51] == 1000 and paths[1].t[51] == 200, "straight line keeps every point, with times")
-- The copy is the recorded path, point for point (#57).
local same = #paths == #recorded
for i = 1, math.min(#paths, #recorded) do
    for k = 1, #recorded[i].x do
        same = same and paths[i].x[k] == recorded[i].x[k] and paths[i].y[k] == recorded[i].y[k]
            and paths[i].t[k] == recorded[i].t[k]
    end
    same = same and #paths[i].x == #recorded[i].x
end
check(same, "the copy holds every recorded point")
check(#paths[3].x == 11, "zigzag keeps every corner, got " .. #paths[3].x)
check(paths[2].m == "g" and paths[2].j == "d", "ghost run kept with its mode and reason")
check(#paths[2].x == 10, "a loop round a tree is kept, got " .. #paths[2].x .. " points")
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
check(entries[1].key == GUID and entries[2].key == "Alt-Test", "this character listed first")

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

-- Two characters with one Name-Realm (#56): the second gets an entry of its
-- own, with its own journey copy, and the first keeps its own.
local first = e
GUID = "Player-1-0000000F"
Fire("PLAYER_LOGIN")
local second = ns.db.roster[GUID]
check(second and second ~= first and ns.db.roster["Player-1-0000000E"] == first, "a namesake gets its own entry")
check(second.journey and #Roster:Entries() == 3, "with a journey copy of its own, and both are listed")
GUID = "Player-1-0000000E"
Fire("PLAYER_LOGIN")

-- On Forever, characters have surnames (UnitName's second value) and full
-- names are unique across the region: the list shows "First Last", as an
-- account's characters can share a first name (#125), and the app, the sync
-- server and the sync folder know it by "First Last-Realm" (#141).
UnitName = function() return "Eagin", "Stormbrew" end
Fire("PLAYER_LOGIN")
check(e.name == "Eagin", "without regional names the surname is left out, got " .. tostring(e.name))
RegionalUniqueNamesEnabled = function() return true end
Fire("PLAYER_LOGIN")
check(e.name == "Eagin Stormbrew" and Roster:FullName() == "Eagin Stormbrew", "on Forever the full name, got " .. tostring(e.name))
UnitGUID = function() return nil end
check(Roster:Key() == "Eagin-Test", "without a GUID the roster's key is still the first name")
UnitGUID = function() return GUID end
check(ns.char.rosterKey == "Eagin Stormbrew-Test" and Roster:Name() == "Eagin Stormbrew-Test",
    "the roster key is the full name, got " .. tostring(ns.char.rosterKey))
check(Roster:Key() == GUID, "the roster's own key is still the GUID")
-- A disguise changes UnitName but not UnitNameUnmodified, Blizzard's source.
UnitNameUnmodified = function() return "Eagin", "Stormbrew" end
UnitName = function() return "Disguised", "Stranger" end
Fire("PLAYER_LOGIN")
check(e.name == "Eagin Stormbrew", "the unmodified name is the one kept, got " .. tostring(e.name))
---@diagnostic disable-next-line: assign-type-mismatch
UnitNameUnmodified = nil
-- A surname that arrives after login is caught at logout.
UnitName = function() return "Eagin" end
Fire("PLAYER_LOGIN")
check(e.name == "Eagin", "no surname yet at login, got " .. tostring(e.name))
check(ns.char.rosterKey == "Eagin-Test", "no surname yet: the first name for now")
UnitName = function() return "Eagin", "Stormbrew" end
Fire("PLAYER_LOGOUT")
check(e.name == "Eagin Stormbrew", "logout saves the surname that came late, got " .. tostring(e.name))
check(ns.char.rosterKey == "Eagin Stormbrew-Test", "and the roster key with it, for the upload")
UnitName = function() return "Eagin" end
Fire("PLAYER_LOGOUT")
check(ns.char.rosterKey == "Eagin Stormbrew-Test", "a surname missing at logout doesn't take the full name away")
UnitName = function() return "Eagin", "Stormbrew" end
UnitName = function() return "Eagin", "" end
Fire("PLAYER_LOGIN")
check(e.name == "Eagin", "an empty surname adds nothing, got " .. tostring(e.name))
RegionalUniqueNamesEnabled = function() return false end
UnitName = function() return "Eagin", "Stormbrew" end
Fire("PLAYER_LOGIN")
check(e.name == "Eagin" and ns.char.rosterKey == "Eagin-Test", "regional names off keeps the name, got " .. tostring(e.name))
RegionalUniqueNamesEnabled = function() error("not on this client") end
UnitName = function() return "Eagin", "Stormbrew" end
Fire("PLAYER_LOGIN")
check(e.name == "Eagin", "a client without the call keeps the name, got " .. tostring(e.name))
RegionalUniqueNamesEnabled = function() return false end
UnitName = function() return "Eagin" end
Fire("PLAYER_LOGIN")

-- Without a GUID from the client, the key is Name-Realm and nothing moves.
UnitGUID = function() return nil end
check(Roster:Key() == "Eagin-Test" and Roster:Name() == "Eagin-Test", "Name-Realm when the client gives no GUID")
UnitGUID = function() return GUID end

-- Forever's client 71037 gives an empty realm (2026-11-21). It is no realm:
-- the one saved stands, and the names the app reads keep it.
GetRealmName = function() return "" end
Fire("PLAYER_LOGIN")
check(ns.RealmName() == "Test" and ns.char.rosterKey == "Eagin-Test" and e.realm == "Test" and not ns.char.realmKept,
    ("an empty realm from the client: the realm as saved, got %s, %s"):format(tostring(ns.char.rosterKey), tostring(e.realm)))
Fire("PLAYER_LOGOUT")
check(ns.char.rosterKey == "Eagin-Test", "and the logout keeps it, got " .. tostring(ns.char.rosterKey))
-- 1.20.11 saved it empty everywhere: a character of the account on the same
-- server (the GUID's server ID) gives it back.
local ALT = "Player-1-00000099"
ns.db.roster[ALT] = { guid = ALT, realm = "Test", name = "Alt" }
e.realm, ns.char.rosterKey = "", "Eagin-"
Fire("PLAYER_LOGIN")
check(ns.char.rosterKey == "Eagin-Test" and e.realm == "Test" and not ns.char.realmKept,
    "an empty realm saved before is put right from a character on the same server (and not kept), got " .. tostring(ns.char.rosterKey))
-- Nothing knows it (the only other character on another server): the
-- names saved are kept, never made emptier.
ns.db.roster[ALT] = nil
local others = {}
for key, entry in pairs(ns.db.roster) do
    if key ~= GUID then others[key], ns.db.roster[key] = entry, nil end
end
ns.db.roster[ALT] = { guid = "Player-2-00000099", realm = "Test", name = "Alt" }
e.realm, ns.char.rosterKey = "", "Eagin-"
Fire("PLAYER_LOGIN")
Fire("PLAYER_LOGOUT")
check(ns.RealmName() == nil and Roster:Name() == nil and ns.char.rosterKey == "Eagin-" and Roster:Key() == GUID,
    "a realm nothing knows: no name made, the saved one kept, got " .. tostring(ns.char.rosterKey))
-- Where the client has game rules (Forever, ids as seen in game): the
-- realm's ruleset names it as a last resort, and the character keeps that
-- name even once the client gives realms again.
local active = { [213] = true }
C_GameRules = { IsGameRuleActive = function(id) return active[id] == true end }
Enum = { GameRule = { PvPRuleset = 213, RPRuleset = 214, HardcoreRuleset = 10 } }
check(select(2, ns.RealmName()) == "rules" and ns.RealmName(true) == nil, "the ruleset only as a last resort")
Fire("PLAYER_LOGIN")
check(ns.char.rosterKey == "Eagin-PvP" and e.realm == "PvP" and ns.char.realmKept,
    "nothing else known: named by the realm's ruleset, got " .. tostring(ns.char.rosterKey))
active = { [213] = true, [214] = true }
check(ns.RealmName() == "PvP", "once named by it, the name stays")
-- After /rts reset the logout saves the name, not that it is kept.
ns.char.realmKept = nil
Fire("PLAYER_LOGIN")
check(ns.char.realmKept and ns.char.rosterKey == "Eagin-PvP", "a ruleset's name saved is kept again")
active = { [213] = true, [214] = true }
-- Friends and Duels compare realms: a ruleset names none, kept or not.
check(ns.RealmName(true) == nil, "never a ruleset's name with noRules, got " .. tostring((ns.RealmName(true))))
active = { [214] = true }
ns.char.realmKept = nil
ns.char.rosterKey, e.realm = "Eagin-", ""
check(ns.RealmName() == "RP", "an RP realm")
active = { [213] = true, [214] = true }
check(ns.RealmName() == "RP-PvP", "an RP-PvP realm, as the app shows it")
active = { [10] = true, [213] = true }
check(ns.RealmName() == "Hardcore", "Hardcore before the rest")
active = {}
check(ns.RealmName() == "Normal", "and a normal realm")
active = { [213] = true }
Fire("PLAYER_LOGIN")
GetRealmName = function() return "Test" end
Fire("PLAYER_LOGIN")
check(ns.char.rosterKey == "Eagin-PvP" and ns.RealmName() == "PvP",
    "named by its ruleset, it keeps that name when the client gives realms again, got " .. tostring(ns.char.rosterKey))
ns.Classic = true
check(ns.RealmName() == "Test", "but where the client always names the realm (Classic), the client's stands")
ns.Classic = nil
-- Another character of the account on that server doesn't take it from
-- this one: it would be no ruleset name of its own, and change later.
GetRealmName = function() return "" end
local SIB = "Player-1-00000077"
ns.db.roster[SIB] = { guid = SIB, realm = "RP", name = "Sib" }
ns.char.realmKept, ns.char.rosterKey = nil, "Eagin-"
e.realm = ""
check(ns.RealmName() == "PvP" and select(2, ns.RealmName()) == "rules", "a realm named by its ruleset is not borrowed")
-- Once the sibling's real realm is known (the sync folder's, Sync.lua),
-- it is lent, whatever named it before.
ns.db.roster[SIB].realm = "Test"
check(ns.RealmName() == "Test", "its realm's own name is, got " .. tostring(ns.RealmName()))
ns.db.roster[SIB] = nil
C_GameRules, Enum = nil, nil
ns.char.realmKept = nil
ns.db.roster[ALT] = nil
for key, entry in pairs(others) do ns.db.roster[key] = entry end
GetRealmName = function() return "Test" end
Fire("PLAYER_LOGIN")
check(ns.char.rosterKey == "Eagin-Test" and e.realm == "Test", "a realm from the client again puts both right")

-- On Forever, characters last seen before launch (the beta's, the stress
-- test's) are not listed; this one always is, and friends are not touched.
ns.Forever = true
local LAUNCH = 1793815200
ns.db.roster["Player-2-00000001"] = { name = "Beta", seen = LAUNCH - 86400 * 12 }
ns.db.roster["Player-2-00000002"] = { name = "Stress", seen = LAUNCH - 86400 * 7 }
ns.db.roster["Player-2-00000003"] = { name = "Live", seen = LAUNCH + 3600 }
ns.db.roster["Player-2-00000004"] = { name = "Unseen" }
ns.db.friends = { ["Player-3-00000001"] = { name = "Pal", key = "Player-3-00000001", journey = {}, seen = 100 } }
local names = {}
for _, entry in ipairs(Roster:Entries()) do names[#names + 1] = entry.name end
check(table.concat(names, ",") == "Eagin,Live,Pal", "on Forever, characters gone with the test realms are hidden, got " .. table.concat(names, ","))
ns.Forever = nil
check(#Roster:Entries() == 8, "on other clients every character is listed, got " .. #Roster:Entries())
ns.db.friends = nil
for i = 1, 4 do ns.db.roster["Player-2-0000000" .. i] = nil end

-- Hiding and deleting (#147): a hidden character or friend leaves Entries
-- but not Entries(true); this character can be neither hidden nor deleted;
-- a friend can be hidden but not deleted; deleting takes the roster entry
-- and its settings; either puts the map back on this character's journey.
local me = Roster:ViewEntry()
local testy = { name = "Testy", seen = 500, journey = { events = {}, segments = {} } }
ns.db.roster["Player-2-00000005"] = testy
local pal = { name = "Pal", key = "Player-3-00000001", friend = true, journey = {}, seen = 100 }
ns.db.friends = { [pal.key] = pal }
local function Listed(withHidden)
    local list = {}
    for _, entry in ipairs(Roster:Entries(withHidden)) do list[entry.name] = true end
    return list
end
check(Listed().Testy and Listed().Pal and not Roster:IsHidden(testy), "listed before hiding")
check(Roster:SetView(testy) and ns.view == testy.journey, "Testy's journey shown")
check(Roster:SetHidden(testy, true) and Roster:IsHidden(testy), "Testy hidden")
check(not Listed().Testy and Listed(true).Testy, "a hidden character leaves the list but not the Hidden group")
check(ns.view == ns.char and ns.viewEntry == nil, "hiding the character shown goes back to this one's journey")
check(not Roster:SetHidden(me, true) and not Roster:IsHidden(me) and Listed()[me.name], "this character can't be hidden")
ns.db.hidden[me.key] = true
check(Listed()[me.name] and not Roster:IsHidden(me), "this character is listed even if saved as hidden")
ns.db.hidden[me.key] = nil
check(Roster:SetHidden(pal, true) and not Listed().Pal and Listed(true).Pal, "a friend can be hidden")
check(Roster:SetHidden(pal, false) and Listed().Pal and ns.db.hidden[pal.key] == nil, "and shown again")
check(not Roster:Delete(pal) and ns.db.friends[pal.key] == pal, "a friend is never deleted here")
check(not Roster:Delete(me) and ns.db.roster[me.key] == me, "this character is never deleted")
ns.db.showPaths["Player-2-00000005"], ns.db.compare = true, { ["Player-2-00000005"] = true }
Roster:SetView(testy)
check(Roster:Delete(testy), "Testy deleted")
check(ns.db.roster["Player-2-00000005"] == nil and not Listed(true).Testy, "the entry and its copy are gone")
check(ns.db.hidden["Player-2-00000005"] == nil and ns.db.showPaths["Player-2-00000005"] == nil
    and ns.db.compare["Player-2-00000005"] == nil, "and its settings with it")
check(ns.view == ns.char, "deleting the character shown goes back to this one's journey")
check(not Roster:Delete(testy), "deleting twice does nothing")
ns.db.friends, ns.db.compare = nil, nil

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
