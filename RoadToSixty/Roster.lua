local _, ns = ...

-- Account-wide list of this account's characters, so the journey map can show
-- where the others are. A character's full journey lives in its own
-- per-character SavedVariables, which only load for that character, so the
-- roster keeps a summary and a coarse copy of each path:
--
--   RoadToSixtyDB.roster["Name-Realm"] = {
--     name, realm, class (class file, e.g. "MAGE"), level, zone (uiMapID),
--     c, x, y (last outdoor position, world yards), seen (time), played,
--     path = { { c = continentID, d = "x,y;x,y;..." }, ... },  -- world yards
--   }
--
-- The coarse path is kept up to date while playing and saved on logout.

local Roster = {}
ns.Roster = Roster

local COARSE_YARDS = 150    -- path points closer than this to the last kept one are dropped
local JUMP_YARDS = 1000     -- a bigger gap starts a new piece (teleport, boat, new session)

local entry     -- this character's roster entry
local buf       -- coarse points of the open piece not yet written to its string
local last      -- last coarse point: { c, x, y }

function Roster:Key()
    return UnitName("player") .. "-" .. GetRealmName()
end

-- Writes buffered points into the open piece's string.
local function Flush()
    if entry and buf and #buf > 0 then
        local piece = entry.path[#entry.path]
        local d = table.concat(buf, ";")
        piece.d = piece.d == "" and d or piece.d .. ";" .. d
        wipe(buf)
    end
end

-- Adds a point the recorder stored, keeping one every COARSE_YARDS.
function Roster:Track(c, x, y)
    if not entry then return end
    entry.c, entry.x, entry.y = c, x, y
    if last and last.c == c then
        local dx, dy = x - last.x, y - last.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < COARSE_YARDS then return end
        if d <= JUMP_YARDS then
            buf[#buf + 1] = x .. "," .. y
            last.x, last.y = x, y
            return
        end
    end
    Flush()
    table.insert(entry.path, { c = c, d = "" })
    buf = { x .. "," .. y }
    last = { c = c, x = x, y = y }
end

-- Makes the coarse path from the full journey, for journeys recorded before
-- the roster existed, or replaced by /rts reset or /rts seed.
function Roster:Rebuild()
    if not entry then return end
    wipe(entry.path)
    buf, last = nil, nil
    for _, path in ipairs(ns.Recorder:GetPaths()) do
        if path.m ~= "g" then
            for i = 1, #path.x do
                Roster:Track(path.c, path.x[i], path.y[i])
            end
        end
    end
    Flush()
    ns.char.rosterBuilt = true
end

local function UpdateZone()
    if entry and not IsInInstance() then
        entry.zone = C_Map.GetBestMapForUnit("player") or entry.zone
    end
end

ns.On("PLAYER_LOGIN", function()
    ns.db.roster = ns.db.roster or {}
    local key = Roster:Key()
    entry = ns.db.roster[key] or { path = {} }
    ns.db.roster[key] = entry
    entry.name, entry.realm = UnitName("player"), GetRealmName()
    entry.class = select(2, UnitClass("player"))
    entry.level = UnitLevel("player")
    entry.seen = time()
    entry.played = ns.char.played or entry.played
    if not ns.char.rosterBuilt then
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
    Flush()
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

-- A character's coarse path decoded: { { c = continentID, x = {...}, y = {...} }, ... }
function Roster:Paths(e)
    local paths = {}
    for i, piece in ipairs(e.path or {}) do
        local d = piece.d
        if e == entry and i == #e.path and buf and #buf > 0 then
            d = (d == "" and "" or d .. ";") .. table.concat(buf, ";")
        end
        local xs, ys = {}, {}
        for x, y in d:gmatch("(-?%d+),(-?%d+)") do
            xs[#xs + 1], ys[#ys + 1] = tonumber(x), tonumber(y)
        end
        paths[#paths + 1] = { c = piece.c, x = xs, y = ys }
    end
    return paths
end
