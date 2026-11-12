local _, ns = ...

-- Account-wide list of this account's characters, so the journey map can show
-- the others. A character's full journey lives in its own per-character
-- SavedVariables, which only load for that character, so the roster keeps a
-- summary and a copy of each journey:
--
--   RoadToSixtyDB.roster[GUID] = {
--     name ("First Last" on Forever, Roster:FullName), realm, guid,
--     class (class file, e.g. "MAGE"), level, zone (uiMapID),
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
-- ns.db.hidden[key] = true hides a character or synced friend from the
-- lists and the map until shown again (#147): saved on this PC only, as the
-- account file is never uploaded.
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

-- The name the app, the sync server and the sync folder know the character
-- by: its full name (FullName) and realm, "First Last-Realm" on Forever,
-- "Name-Realm" elsewhere. Up to 1.20.5 it was the first name alone, so on
-- Forever an account's characters sharing one were one character to the
-- server, all but the newest listed as earlier journeys and never synced to
-- another PC (#141). The server finds a journey's row under either name by
-- its stamp, and renames it to the full one.
function Roster:Name()
    return self:FullName() .. "-" .. GetRealmName()
end

-- Name-Realm by the first name alone: the roster's keys before GUIDs, the
-- key when the client gives no GUID, and the sync folder's name for a
-- journey whose server row hasn't taken the full name yet (Sync.lua).
local function FirstName()
    -- The undisguised name, as FullName takes it.
    return ((UnitNameUnmodified or UnitName)("player")) .. "-" .. GetRealmName()
end
function Roster:FirstName()
    return FirstName()
end

-- This character's name as players see it: on Forever, where characters have
-- surnames and full names are unique across the region, "First Last", as
-- several of an account's characters can share a first name. Elsewhere the
-- name alone.
-- UnitNameUnmodified is Blizzard's own source for it (UnitPopupShared): an
-- effect that disguises the player changes UnitName, not it.
function Roster:FullName()
    local name, surname = (UnitNameUnmodified or UnitName)("player")
    local ok, on = pcall(function() return RegionalUniqueNamesEnabled() end)
    if ok and on == true and type(surname) == "string" and surname ~= "" then
        return name .. " " .. surname
    end
    return name
end

-- This character's roster key: its GUID, or Name-Realm if the client gives none.
function Roster:Key()
    return ns.PlayerGUID() or FirstName()
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
    -- What the journey no longer has (a run or group ended) goes from the copy too.
    for k in pairs(journey) do
        if k ~= "segments" and ns.char[k] == nil then
            journey[k] = nil
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
    -- An entry from before GUIDs, keyed by the first name, moves to the GUID.
    local key, old = Roster:Key(), FirstName()
    if key ~= old and roster[old] and not roster[old].guid then
        roster[old] = nil
        ns.db.showPaths[key], ns.db.showPaths[old] = ns.db.showPaths[old], nil
    end
    entry = roster[key] or {}
    roster[key] = entry
    ns.char.rosterKey = Roster:Name()
    entry.name, entry.realm, entry.guid = Roster:FullName(), GetRealmName(), ns.PlayerGUID()
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
    -- Again here, in case the surname wasn't there yet at login: the app
    -- uploads the file this writes, and the roster's copy is made from it.
    -- Never back to the first name, should the surname be missing now.
    local name = Roster:Name()
    if name ~= FirstName() or not ns.char.rosterKey then ns.char.rosterKey = name end
    Roster:Sync()
    entry.name = Roster:FullName()
    entry.seen = ns.Now()
end)

-- Forever's realms opened on 2026-11-04 (18:00 UTC is before anyone played
-- on one). The beta's characters came along into Forever's folder, and the
-- stress test was played in it, so on Forever a character of this account
-- last seen before then was on a realm that is gone, and can never be
-- logged in again. They stay saved but are not listed.
local FOREVER_LAUNCH = 1793815200

-- Whether a roster entry is one of those, left out of the lists.
function Roster:Gone(e)
    return ns.Forever and (e.seen or 0) < FOREVER_LAUNCH
end

-- Every character and synced friend, this one first, then the most recently
-- seen, leaving out hidden ones unless withHidden (the Characters list's
-- Hidden group). Each entry gets its key as entry.key.
function Roster:Entries(withHidden)
    local list, me = {}, self:Key()
    local roster = ns.db.roster or {}
    local hidden = ns.db.hidden or {}
    local function Listed(key)
        return key == me or withHidden or not hidden[key]
    end
    for key, e in pairs(roster) do
        e.key = key
        if (key == me or not self:Gone(e)) and Listed(key) then
            list[#list + 1] = e
        end
    end
    -- Synced friends (Friends.lua) list like characters, but stay out of
    -- the roster, which only holds this account's own.
    for _, e in pairs(ns.db.friends or {}) do
        if e.journey and e.key and not roster[e.key] and Listed(e.key) then
            list[#list + 1] = e
        end
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

-- Hiding and deleting (#147). A hidden character is left out of Entries, so
-- out of the Characters list, the map and the Stats screen, until shown
-- again; nothing about it changes. This character is never hidden.
function Roster:IsHidden(e)
    return e ~= nil and e.key ~= nil and not self:IsMe(e) and (ns.db.hidden or {})[e.key] == true
end

function Roster:SetHidden(e, on)
    if not (e and e.key) or self:IsMe(e) then return false end
    ns.db.hidden = ns.db.hidden or {}
    ns.db.hidden[e.key] = on and true or nil
    if on and ns.viewEntry == e then self:SetView(nil) end
    return true
end

-- Deletes another of this account's characters from the roster, with its
-- journey copy, for good: one deleted in game, which can never log in to
-- bring it back. One that still exists comes back at its next login, from
-- its own file. Friends are removed on the Friends tab instead.
function Roster:Delete(e)
    local roster = ns.db.roster or {}
    if not (e and e.key) or e.friend or self:IsMe(e) or roster[e.key] ~= e then return false end
    roster[e.key] = nil
    if ns.db.hidden then ns.db.hidden[e.key] = nil end
    ns.db.showPaths[e.key] = nil
    if ns.db.compare then ns.db.compare[e.key] = nil end
    if ns.viewEntry == e then self:SetView(nil) end
    return true
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
