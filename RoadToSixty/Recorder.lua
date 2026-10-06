local _, ns = ...

-- Records the player's path as segments of world coordinates (yards).
--
-- A segment is one unbroken line: { m = mode, c = continentID, t = startTime,
-- x = startX, y = startY, d = "dt,dx,dy;dt,dx,dy;..." } where each step is
-- a delta from the previous point. A new segment starts on loading screens,
-- teleports, instance entry and mode changes, so the map never draws a line
-- across a hearthstone or a dungeon.
--
-- seg.j says why the path jumped to this segment, when known:
--   h hearthstone, p teleport spell, d died (sent to a graveyard),
--   i left an instance, b boat or zeppelin (new continent), l logged in.

local Recorder = {}
ns.Recorder = Recorder

local SAMPLE_INTERVAL = 1   -- seconds between position checks
local TELEPORT_DIST = 300   -- yards; a bigger jump between two samples is a teleport

-- Modes: w = on foot or mounted, t = flight path, g = ghost (corpse run).
-- Yards moved before another point is stored, per mode.
local MIN_STEP = { w = 15, g = 15, t = 60 }

-- Spells that move the player, for seg.j.
local HEARTH_SPELLS = { [8690] = true, [556] = true }  -- Hearthstone, Astral Recall
local TELEPORT_SPELLS = {   -- mage city teleports
    [3561] = true, [3562] = true, [3563] = true, [3565] = true, [3566] = true, [3567] = true,
}
local PENDING_SECONDS = 60  -- a cast or login explains a jump within this long

local current           -- open segment: { seg, buf, mode, c, x, y, t }
local prev              -- previous sample, stored or not
local lastKnown = {}    -- last outdoor position, used to place indoor events
local ticker
local pending, pendingAt    -- jump reason from a cast or login, waiting for the jump
local leftInstance          -- position was hidden by an instance since the last segment
local lastMode, lastC       -- mode and continent of the last sample with a position

-- Health for /rts check: GetTime() of the last sample, and counts this session.
Recorder.lastSample = nil
Recorder.samples = 0
Recorder.stored = 0

local function round(v)
    return math.floor(v + 0.5)
end

local function Dist(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

-- Returns continentID, worldX, worldY, uiMapID, or nil when the client
-- hides the position (instances, loading screens).
function ns.GetWorldPosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local continentID, world = C_Map.GetWorldPosFromMapPos(mapID, pos)
    if not continentID or not world then return end
    return continentID, round(world.x), round(world.y), mapID
end

function Recorder:Mode()
    if UnitOnTaxi("player") then return "t" end
    if UnitIsGhost("player") then return "g" end
    return "w"
end

-- Live position if available, otherwise the last outdoor one.
function Recorder:Position()
    local c, x, y = ns.GetWorldPosition()
    if c then return c, x, y end
    return lastKnown.c, lastKnown.x, lastKnown.y
end

local function Flush()
    if current and #current.buf > 0 then
        current.seg.d = table.concat(current.buf, ";")
    end
end

local function CloseSegment()
    Flush()
    current = nil
end

-- Passes a stored point on to the account-wide roster's coarse path.
-- Ghost runs are left out of it.
local function TrackRoster(mode, c, x, y)
    if mode ~= "g" and ns.Roster then
        ns.Roster:Track(c, x, y)
    end
end

-- Why a new segment starts here (see seg.j), or nil if unknown. previousMode
-- and previousC are from the last sample that had a position.
local function JumpReason(mode, c, previousMode, previousC)
    local reason
    if pending and GetTime() - pendingAt < PENDING_SECONDS then
        reason = pending
    elseif leftInstance then
        reason = "i"
    elseif mode == "g" and previousMode and previousMode ~= "g" then
        reason = "d"
    elseif previousC and c ~= previousC then
        reason = "b"
    end
    pending, leftInstance = nil, false
    return reason
end

local function OpenSegment(mode, c, x, y, t, reason)
    local seg = { m = mode, c = c, t = t, x = x, y = y, d = "", j = reason }
    table.insert(ns.char.segments, seg)
    current = { seg = seg, buf = {}, mode = mode, c = c, x = x, y = y, t = t }
    TrackRoster(mode, c, x, y)
end

local function Sample()
    Recorder.lastSample = GetTime()
    Recorder.samples = Recorder.samples + 1

    -- Instances are logged as enter/leave events only, never as path.
    local c, x, y
    if not IsInInstance() then
        c, x, y = ns.GetWorldPosition()
    end
    if not c then
        if IsInInstance() then
            leftInstance = true
        end
        CloseSegment()
        prev = nil
        return
    end
    lastKnown.c, lastKnown.x, lastKnown.y = c, x, y

    local t, mode = time(), Recorder:Mode()
    local previousMode, previousC = lastMode, lastC
    lastMode, lastC = mode, c
    local jumped = prev and (prev.c ~= c or Dist(prev.x, prev.y, x, y) > TELEPORT_DIST)
    prev = prev or {}
    prev.c, prev.x, prev.y = c, x, y

    if current and (jumped or current.mode ~= mode or current.c ~= c) then
        CloseSegment()
    end
    if not current then
        OpenSegment(mode, c, x, y, t, JumpReason(mode, c, previousMode, previousC))
        return
    end

    local dist = Dist(current.x, current.y, x, y)
    if dist < MIN_STEP[mode] then return end

    table.insert(current.buf, (t - current.t) .. "," .. (x - current.x) .. "," .. (y - current.y))
    current.x, current.y, current.t = x, y, t
    Recorder.stored = Recorder.stored + 1
    TrackRoster(mode, c, x, y)

    local totals = ns.char.totals
    if mode == "t" then
        totals.flown = totals.flown + dist
    else
        totals.distance = totals.distance + dist
    end
end

-- Closed segments never change, so each is decoded once per session.
local decoded = setmetatable({}, { __mode = "k" })

local function Decode(seg, d)
    local t, x, y = seg.t, seg.x, seg.y
    local ts, xs, ys = { t }, { x }, { y }
    for dt, dx, dy in d:gmatch("(-?%d+),(-?%d+),(-?%d+)") do
        t, x, y = t + tonumber(dt), x + tonumber(dx), y + tonumber(dy)
        ts[#ts + 1], xs[#xs + 1], ys[#ys + 1] = t, x, y
    end
    return { m = seg.m, c = seg.c, j = seg.j, t = ts, x = xs, y = ys }
end

-- Decoded copy of every segment, including the one still being recorded:
-- { m = mode, c = continentID, j = jump reason, t = {...}, x = {...}, y = {...} }
function Recorder:GetPaths()
    local paths = {}
    for _, seg in ipairs(ns.char.segments) do
        local path
        if current and seg == current.seg then
            path = Decode(seg, table.concat(current.buf, ";"))
        else
            path = decoded[seg]
            if not path then
                path = Decode(seg, seg.d)
                decoded[seg] = path
            end
        end
        paths[#paths + 1] = path
    end
    return paths
end

-- Counts for /rts stats. Bytes is the size of the packed path strings.
function Recorder:Stats()
    local segments, points, bytes = 0, 0, 0
    for _, seg in ipairs(ns.char.segments) do
        segments = segments + 1
        points = points + 1
        if current and seg == current.seg then
            points = points + #current.buf
            for _, step in ipairs(current.buf) do
                bytes = bytes + #step + 1
            end
        elseif seg.d ~= "" then
            points = points + select(2, seg.d:gsub(";", "")) + 1
            bytes = bytes + #seg.d
        end
    end
    return segments, points, bytes
end

-- Forgets the open segment without saving it, after the journey has been
-- wiped (it belongs to the old data). Recording carries on with a new one.
function Recorder:Reset()
    current, prev = nil, nil
end

-- Points in the segment being recorded, or 0 if none is open.
function Recorder:OpenPoints()
    return current and #current.buf + 1 or 0
end

local function StartTicker()
    if ticker then
        ticker:Cancel()
    end
    ticker = C_Timer.NewTicker(SAMPLE_INTERVAL, function()
        ns.SafeCall(Sample)
    end)
end

-- Restarts the sampler if it has stopped. Returns true if it had to.
function Recorder:EnsureRunning()
    local stale = not self.lastSample or GetTime() - self.lastSample > SAMPLE_INTERVAL * 5
    if ticker and not ticker:IsCancelled() and not stale then
        return false
    end
    StartTicker()
    return true
end

ns.On("PLAYER_LOGIN", StartTicker)

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    CloseSegment()
    prev = nil
    if isLogin or isReload then
        pending, pendingAt = "l", GetTime()
    end
end)

-- Casts that teleport the player explain the jump that follows.
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit ~= "player" then return end
    local reason = HEARTH_SPELLS[spellID] and "h" or TELEPORT_SPELLS[spellID] and "p"
    if reason then
        pending, pendingAt = reason, GetTime()
    end
end)

ns.On("PLAYER_LOGOUT", Flush)

ns.Command("where", "show current position as the recorder sees it", function()
    local c, x, y, mapID = ns.GetWorldPosition()
    if not c then
        ns.Print("No position available (instance or loading).")
        return
    end
    local info = C_Map.GetMapInfo(mapID)
    ns.Print(("%s (map %d), continent %d, world %d, %d, mode %s."):format(
        info and info.name or "?", mapID, c, x, y, Recorder:Mode()))
end)
