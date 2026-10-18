local _, ns = ...

-- Account-wide list of this account's characters, so the journey map can show
-- the others. A character's full journey lives in its own per-character
-- SavedVariables, which only load for that character, so the roster keeps a
-- summary and a copy of each journey:
--
--   RoadToSixtyDB.roster[GUID] = {
--     name, realm, guid, class (class file, e.g. "MAGE"), level, zone (uiMapID),
--     c, x, y (last outdoor position, world yards), seen (time), played,
--     journey = copy of RoadToSixtyCharDB as of the last logout,
--   }
--
-- Entries are keyed by the character's GUID (Roster:Key()), as two
-- characters can share a Name-Realm (#56). Entries saved before then are
-- keyed by Name-Realm and have no guid; the first character of that name
-- to log in takes its place under its GUID, starting afresh, as a shared
-- entry may hold the other character's journey. ns.db.showPaths uses the
-- same keys.
--
-- The copy shares every table with the character's own data except
-- segments: those are copies of the recorder's segments (same format and
-- index, see Recorder.lua) with every point, so another character's path
-- shows as recorded (#57); the map thins it by zoom as it does the
-- player's own. Segments before the last never change, so on logout only
-- the last one and any new ones are redone.
--
-- Entries saved before the journey copy have path = { { c, d = "x,y;..." } }
-- instead: absolute points, one every 150 yards. Their path still shows
-- until that character logs in and replaces it.
--
-- The map and side panel read ns.view, the journey being shown: ns.char, or
-- another character's copy picked with Roster:SetView.

local Roster = {}
ns.Roster = Roster

local VERSION = 5           -- of the copy's layout; ns.char.rosterBuilt holds the one built

local entry     -- this character's roster entry
local decoded = setmetatable({}, { __mode = "k" })  -- copied segment -> decoded path

-- Name-Realm, the name the app and the sync folder know the character by.
function Roster:Name()
    return UnitName("player") .. "-" .. GetRealmName()
end

-- This character's roster key: its GUID, or Name-Realm if the client gives none.
function Roster:Key()
    return ns.PlayerGUID() or self:Name()
end

-- A copy of a recorder segment, from its decoded path: the open segment's
-- latest points are in the recorder's buffer, not yet in its string.
local function Copy(path)
    local ts, xs, ys = path.t, path.x, path.y
    local steps = {}
    for i = 2, #xs do
        steps[i - 1] = (ts[i] - ts[i - 1]) .. "," .. (xs[i] - xs[i - 1]) .. "," .. (ys[i] - ys[i - 1])
    end
    return { m = path.m, c = path.c, j = path.j, t = ts[1], x = xs[1], y = ys[1], d = table.concat(steps, ";") }
end

-- Brings the copy up to date with the journey: every table but segments is
-- shared, the last segment may have grown since the last sync, later ones
-- are new.
function Roster:Sync()
    if not entry then return end
    local journey = entry.journey or { segments = {} }
    entry.journey, entry.path = journey, nil
    local segments = journey.segments
    for k, v in pairs(ns.char) do
        if k ~= "segments" and k ~= "rosterBuilt" then
            journey[k] = v
        end
    end
    local count = #ns.char.segments
    for i = math.max(1, math.min(#segments, count)), count do
        segments[i] = Copy(ns.Recorder:GetPath(i))
    end
    for i = #segments, count + 1, -1 do
        segments[i] = nil
    end
    local last = count > 0 and ns.Recorder:GetPath(count)
    if last then
        entry.c, entry.x, entry.y = last.c, last.x[#last.x], last.y[#last.y]
    end
end

-- Makes the copy from the whole journey: on the first login with this
-- version, and after /rts reset or /rts seed replaced the journey.
function Roster:Rebuild()
    if not entry then return end
    entry.journey = nil
    Roster:Sync()
    ns.char.rosterBuilt = VERSION
end

local function UpdateZone()
    if entry and not IsInInstance() then
        entry.zone = C_Map.GetBestMapForUnit("player") or entry.zone
    end
end

ns.On("PLAYER_LOGIN", function()
    local roster = ns.db.roster or {}
    ns.db.roster = roster
    local key, name = Roster:Key(), Roster:Name()
    if key ~= name and roster[name] and not roster[name].guid then
        roster[name] = nil
        ns.db.showPaths[key], ns.db.showPaths[name] = ns.db.showPaths[name], nil
    end
    entry = roster[key] or {}
    roster[key] = entry
    ns.char.rosterKey = name
    entry.name, entry.realm, entry.guid = UnitName("player"), GetRealmName(), ns.PlayerGUID()
    entry.class = select(2, UnitClass("player"))
    ns.char.class = entry.class
    entry.level = UnitLevel("player")
    entry.seen = ns.Now()
    entry.played = ns.char.played or entry.played
    if ns.char.rosterBuilt ~= VERSION or not entry.journey then
        Roster:Rebuild()
    end
    UpdateZone()
end)

ns.On("ZONE_CHANGED_NEW_AREA", UpdateZone)

ns.On("PLAYER_LEVEL_UP", function(level)
    entry.level = level
end)

ns.On("TIME_PLAYED_MSG", function(total)
    entry.played = total
end)

ns.On("PLAYER_LOGOUT", function()
    Roster:Sync()
    entry.seen = ns.Now()
end)

-- Every character, this one first, then the most recently seen.
-- Each entry gets its key as entry.key.
function Roster:Entries()
    local list, me = {}, self:Key()
    for key, e in pairs(ns.db.roster or {}) do
        e.key = key
        list[#list + 1] = e
    end
    table.sort(list, function(a, b)
        if a.key == me or b.key == me then
            return a.key == me
        end
        return (a.seen or 0) > (b.seen or 0)
    end)
    return list
end

function Roster:IsMe(e)
    return e == entry
end

-- A character's path as saved at its last logout, decoded like
-- Recorder:GetPaths. Pieces from before the journey copy have no times
-- (t is empty) and count as walking. This character's live path is in
-- Recorder.
function Roster:Paths(e)
    local paths = {}
    if e.journey then
        for i, seg in ipairs(e.journey.segments) do
            local path = decoded[seg]
            if not path then
                path = ns.Recorder:Decode(seg)
                decoded[seg] = path
            end
            paths[i] = path
        end
        return ns.Recorder:MarkTeleportsOut(paths)
    end
    for _, piece in ipairs(e.path or {}) do
        local xs, ys = {}, {}
        for x, y in piece.d:gmatch("(-?%d+),(-?%d+)") do
            xs[#xs + 1], ys[#ys + 1] = tonumber(x), tonumber(y)
        end
        paths[#paths + 1] = { c = piece.c, m = "w", x = xs, y = ys, t = {} }
    end
    return paths
end

-- Character view -------------------------------------------------------------------

-- Shows another character's journey on the map and side panel, or this
-- one's again for nil, this character's entry, or a character with no
-- journey copy yet. Returns whether the view is another character.
function Roster:SetView(e)
    if e and e ~= entry and e.journey then
        ns.view, ns.viewEntry = e.journey, e
    else
        ns.view, ns.viewEntry = ns.char, nil
    end
    return ns.viewEntry ~= nil
end

-- The roster entry of the journey shown: another character's, or this one's.
function Roster:ViewEntry()
    return ns.viewEntry or entry
end

-- The shown journey's path, decoded like Recorder:GetPaths.
function Roster:ViewPaths()
    if ns.viewEntry then
        return self:Paths(ns.viewEntry)
    end
    return ns.Recorder:GetPaths()
end

-- The shown character's level: live for this one, as last seen for others.
function Roster:ViewLevel()
    if ns.viewEntry then
        return ns.viewEntry.level or 1
    end
    return UnitLevel("player")
end
