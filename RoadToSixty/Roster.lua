local _, ns = ...

-- Account-wide list of this account's characters, so the journey map can show
-- the others. A character's full journey lives in its own per-character
-- SavedVariables, which only load for that character, so the roster keeps a
-- summary and a copy of each journey:
--
--   RoadToSixtyDB.roster["Name-Realm"] = {
--     name, realm, class (class file, e.g. "MAGE"), level, zone (uiMapID),
--     c, x, y (last outdoor position, world yards), seen (time), played,
--     journey = copy of RoadToSixtyCharDB as of the last logout,
--   }
--
-- The copy shares every table with the character's own data except
-- segments: those are the recorder's segments (same format and index, see
-- Recorder.lua) with their points simplified to keep the shape within
-- SIMPLIFY_YARDS. Segments before the last never change, so on logout only
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

local VERSION = 3           -- of the copy's layout; ns.char.rosterBuilt holds the one built
local SIMPLIFY_YARDS = 8    -- simplified paths stay this close to the recorded one

local entry     -- this character's roster entry
local decoded = setmetatable({}, { __mode = "k" })  -- copied segment -> decoded path

function Roster:Key()
    return UnitName("player") .. "-" .. GetRealmName()
end

-- Indexes of the points to keep so the line through them stays within
-- SIMPLIFY_YARDS of every point (Douglas-Peucker), in order.
local function Simplify(xs, ys)
    local n = #xs
    local keep = { [1] = true, [n] = true }
    local stack = { 1, n }
    local limit = SIMPLIFY_YARDS * SIMPLIFY_YARDS
    while #stack > 0 do
        local b = table.remove(stack)
        local a = table.remove(stack)
        local ax, ay = xs[a], ys[a]
        local dx, dy = xs[b] - ax, ys[b] - ay
        local lengthSq = dx * dx + dy * dy
        local worst, worstAt = limit, nil
        for i = a + 1, b - 1 do
            local px, py = xs[i] - ax, ys[i] - ay
            local d
            if lengthSq > 0 then
                local cross = dy * px - dx * py
                d = cross * cross / lengthSq
            else
                d = px * px + py * py
            end
            if d > worst then
                worst, worstAt = d, i
            end
        end
        if worstAt then
            keep[worstAt] = true
            stack[#stack + 1], stack[#stack + 2] = a, worstAt
            stack[#stack + 1], stack[#stack + 2] = worstAt, b
        end
    end
    local idx = {}
    for i = 1, n do
        if keep[i] then idx[#idx + 1] = i end
    end
    return idx
end

-- A simplified copy of a recorder segment, from its decoded path.
local function Copy(path)
    local ts, xs, ys = path.t, path.x, path.y
    local idx = Simplify(xs, ys)
    local steps = {}
    for k = 2, #idx do
        local i, p = idx[k], idx[k - 1]
        steps[k - 1] = (ts[i] - ts[p]) .. "," .. (xs[i] - xs[p]) .. "," .. (ys[i] - ys[p])
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
    ns.db.roster = ns.db.roster or {}
    local key = Roster:Key()
    entry = ns.db.roster[key] or {}
    ns.db.roster[key] = entry
    entry.name, entry.realm = UnitName("player"), GetRealmName()
    entry.class = select(2, UnitClass("player"))
    entry.level = UnitLevel("player")
    entry.seen = time()
    entry.played = ns.char.played or entry.played
    if ns.char.rosterBuilt ~= VERSION then
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
    entry.seen = time()
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
