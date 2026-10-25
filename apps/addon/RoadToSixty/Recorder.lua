local _, ns = ...

-- Records the player's path as segments of world coordinates (yards; X runs
-- north and Y runs west, as the client's world positions do).
--
-- A segment is one unbroken line: { m = mode, c = continentID, t = startTime,
-- x = startX, y = startY, d = "dt,dx,dy;dt,dx,dy;..." } where each step is
-- a delta from the previous point, all integers, and the string is empty
-- for a segment with only its start point. A new segment starts on loading screens,
-- teleports, instance entry and mode changes, so the map never draws a line
-- across a hearthstone or a dungeon.
--
-- seg.j says why the path jumped to this segment, when known:
--   h hearthstone, p teleport spell, d died (sent to a graveyard),
--   di died inside an instance (sent to a graveyard outside it),
--   i left an instance through its door, it sent out of an instance far
--   from where the player went in (left the group), b boat or zeppelin (new
--   continent), l logged in.

local Recorder = {}
ns.Recorder = Recorder

local SAMPLE_INTERVAL = 0.25    -- seconds between position checks
local FLUSH_SAMPLES = 240       -- samples between writes of the open segment into its string (a minute)
local STALE_SECONDS = 5         -- no sample for this long means the sampler has stopped
local TELEPORT_DIST = 300       -- yards; a bigger jump between two samples is a teleport

-- Modes: w = on foot or mounted, t = flight path, g = ghost (corpse run).
-- A point is stored once the player is MAX_STEP yards from the last one, or
-- sooner where the path bends (#57): when the straight line from the last
-- point to here passes more than BEND yards from a position checked on the
-- way, the position before this one is stored, if it is at least MIN_STEP
-- from the last point, so standing still or fighting in place adds nothing.
-- Straight runs cost what they always did; circling a tree keeps its shape.
-- Flights follow fixed routes and have no bend check. The steps are what a
-- sample a second at 15 and 60 yards gave in practice, overshoot included.
local MAX_STEP = { w = 20, g = 20, t = 75 }
local MIN_STEP = { w = 3, g = 3 }
local BEND = { w = 2, g = 2 }
local MAX_HELD = 120            -- positions held for the bend check (30 seconds)

-- Spells that move the player, for seg.j.
local HEARTH_SPELLS = { [8690] = true, [556] = true }  -- Hearthstone, Astral Recall
local TELEPORT_SPELLS = {   -- mage city teleports
    [3561] = true, [3562] = true, [3563] = true, [3565] = true, [3566] = true, [3567] = true,
}
local PENDING_SECONDS = 60  -- a cast or login explains a jump within this long
-- Yards from where the player went into an instance that they can come out
-- of its door. Further, they were sent out (left the group, say), and the
-- jump is a teleport.
local INSTANCE_DOOR = 150

local current           -- open segment: { seg, buf, mode, c, x, y, t, n, hx, hy, ht }
                        -- (x, y, t: the last stored point; n positions since, in hx, hy, ht)
local prev              -- previous sample, stored or not
local lastKnown = {}    -- last outdoor position, used to place indoor events
local ticker
local pending, pendingAt    -- jump reason from a cast or login, waiting for the jump
local leftInstance          -- position was hidden by an instance since the last segment
local entered               -- { c, x, y } where the player went into that instance
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

-- Squared distance from px, py to the line from ax, ay to bx, by. To the
-- line between the ends, not beyond them, so going back on oneself counts
-- as a bend.
local function OffLineSq(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local lengthSq = dx * dx + dy * dy
    local u = 0
    if lengthSq > 0 then
        u = math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSq))
    end
    local ex, ey = ax + u * dx - px, ay + u * dy - py
    return ex * ex + ey * ey
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

-- Out of an instance: through its door ("i"), or sent away from where the
-- player went in at c1, x1, y1 to c2, x2, y2 ("it").
local function InstanceExit(c1, x1, y1, c2, x2, y2)
    return (c1 ~= c2 or Dist(x1, y1, x2, y2) > INSTANCE_DOOR) and "it" or "i"
end

-- Why a new segment starts here at c, x, y (see seg.j), or nil if unknown.
-- previousMode and previousC are from the last sample that had a position.
-- Dying inside an instance puts the ghost at a graveyard outside: a death,
-- not a walk out. That holds even when the last sample outside was a ghost
-- too (a corpse run back in, revived inside, then died again): ghosts are
-- revived on entering, so a ghost coming out has died in there.
local function JumpReason(mode, c, x, y, previousMode, previousC)
    local reason
    if pending and GetTime() - pendingAt < PENDING_SECONDS then
        reason = pending
    elseif mode == "g" and leftInstance then
        reason = "di"
    elseif mode == "g" and previousMode and previousMode ~= "g" then
        reason = "d"
    elseif leftInstance then
        reason = entered and InstanceExit(entered.c, entered.x, entered.y, c, x, y) or "i"
    elseif previousC and c ~= previousC then
        reason = "b"
    end
    pending, leftInstance, entered = nil, false, nil
    return reason
end

local function OpenSegment(mode, c, x, y, t, reason)
    local seg = { m = mode, c = c, t = t, x = x, y = y, d = "", j = reason }
    table.insert(ns.char.segments, seg)
    current = { seg = seg, buf = {}, mode = mode, c = c, x = x, y = y, t = t, n = 0, hx = {}, hy = {}, ht = {} }
end

-- Stores x, y at time t as the open segment's next point.
local function Store(x, y, t)
    local dist = Dist(current.x, current.y, x, y)
    table.insert(current.buf, (t - current.t) .. "," .. (x - current.x) .. "," .. (y - current.y))
    current.x, current.y, current.t, current.n = x, y, t, 0
    Recorder.stored = Recorder.stored + 1

    local totals = ns.char.totals
    if current.mode == "t" then
        totals.flown = totals.flown + dist
    else
        totals.distance = totals.distance + dist
    end
end

-- True if the line from the last stored point to x, y passes more than
-- limit yards from any position held since.
local function Bent(x, y, limit)
    local limitSq = limit * limit
    local ax, ay, hx, hy = current.x, current.y, current.hx, current.hy
    for i = 1, current.n do
        if OffLineSq(hx[i], hy[i], ax, ay, x, y) > limitSq then
            return true
        end
    end
    return false
end

-- Holds a position not stored, for the bend check. Standing still holds
-- nothing new; a full hold stores its last position, or drops them all
-- when the player has stayed near the last point.
local function Hold(x, y, t, mode)
    local n = current.n
    if n > 0 and current.hx[n] == x and current.hy[n] == y then return end
    if n >= MAX_HELD then
        if Dist(current.x, current.y, current.hx[n], current.hy[n]) >= MIN_STEP[mode] then
            Store(current.hx[n], current.hy[n], current.ht[n])
        end
        n = 0
    end
    n = n + 1
    current.hx[n], current.hy[n], current.ht[n], current.n = x, y, t, n
end

local function Sample()
    Recorder.lastSample = GetTime()
    Recorder.samples = Recorder.samples + 1

    -- The open segment's points sit in a buffer until Flush writes them into
    -- its string. Logout flushes, but a session that ends without that event
    -- would lose everything since the segment opened, so flush every minute.
    if Recorder.samples % FLUSH_SAMPLES == 0 then
        Flush()
    end

    -- Instances are logged as enter/leave events only, never as path.
    local c, x, y
    if not IsInInstance() then
        c, x, y = ns.GetWorldPosition()
    end
    if not c then
        if IsInInstance() then
            -- The last outdoor position is where the player went in.
            if not leftInstance and lastKnown.c then
                entered = { c = lastKnown.c, x = lastKnown.x, y = lastKnown.y }
            end
            leftInstance = true
        end
        CloseSegment()
        prev = nil
        return
    end
    lastKnown.c, lastKnown.x, lastKnown.y = c, x, y

    local t, mode = ns.Now(), Recorder:Mode()
    local previousMode, previousC = lastMode, lastC
    lastMode, lastC = mode, c
    local jumped = prev and (prev.c ~= c or Dist(prev.x, prev.y, x, y) > TELEPORT_DIST)
    prev = prev or {}
    prev.c, prev.x, prev.y = c, x, y

    if current and (jumped or current.mode ~= mode or current.c ~= c) then
        CloseSegment()
    end
    if not current then
        OpenSegment(mode, c, x, y, t, JumpReason(mode, c, x, y, previousMode, previousC))
        return
    end

    local bend, n = BEND[mode], current.n
    if bend and n > 0 and Bent(x, y, bend)
        and Dist(current.x, current.y, current.hx[n], current.hy[n]) >= MIN_STEP[mode] then
        Store(current.hx[n], current.hy[n], current.ht[n])
    end
    if Dist(current.x, current.y, x, y) >= MAX_STEP[mode] then
        Store(x, y, t)
    elseif bend then
        Hold(x, y, t, mode)
    end
end

-- Closed segments never change, so each is decoded once per session.
local decoded = setmetatable({}, { __mode = "k" })

local function Decode(seg, d)
    local ts, xs, ys = ns.Packed.DecodePath(seg, d)
    -- Up to 1.5.0 a death inside an instance was saved as leaving it; a
    -- ghost's segment after an instance is that death.
    local j = seg.j
    if j == "i" and seg.m == "g" then
        j = "di"
    end
    return { m = seg.m, c = seg.c, j = j, t = ts, x = xs, y = ys }
end

-- Decodes a closed segment of this format, such as the roster's copies.
function Recorder:Decode(seg)
    return Decode(seg, seg.d)
end

-- Decoded copy of segment i, which may be the one still being recorded:
-- { m = mode, c = continentID, j = jump reason, t = {...}, x = {...}, y = {...} }
function Recorder:GetPath(i)
    local seg = ns.char.segments[i]
    if current and seg == current.seg then
        return Decode(seg, table.concat(current.buf, ";"))
    end
    local path = decoded[seg]
    if not path then
        path = Decode(seg, seg.d)
        decoded[seg] = path
    end
    return path
end

-- Saves up to 1.5.0 have every way out of an instance as "i". Marks the ones
-- far from where the previous path ended, where the player went in, as
-- teleports out ("it"), in a list of decoded paths. Returns the list.
function Recorder:MarkTeleportsOut(paths)
    for i = 2, #paths do
        local path, before = paths[i], paths[i - 1]
        if path.j == "i" and #before.x > 0 and #path.x > 0 then
            path.j = InstanceExit(before.c, before.x[#before.x], before.y[#before.y], path.c, path.x[1], path.y[1])
        end
    end
    return paths
end

-- Why the path jumped to the start of path (decoded) from the end of
-- previous: its saved reason, or "u" for a jump with none that is further
-- than TELEPORT_DIST on one continent while alive. That was a teleport by
-- something the recorder does not recognise: a quest, an NPC, a spell cast
-- on the player. Not saved, so it also covers journeys recorded before.
-- True when path carries on previous's flight: both on a flight path, on
-- one continent, with no reason for a break but a login. A /reload during a
-- flight starts a new segment while the flight goes on through the loading
-- screen, so the next one starts hundreds of yards on, and read back as a
-- teleport (Jordan, 2026-10-25; that reload was saved with no reason at
-- all). The map draws it as one flight.
function Recorder:Continues(previous, path)
    return previous ~= nil and previous.m == "t" and path.m == "t" and previous.c == path.c
        and (path.j == nil or path.j == "l") and #previous.x > 0 and path.x[1] ~= nil
end

-- The last position of a decoded path, or nil.
function Recorder:LastPoint(path)
    local last = path and #path.x or 0
    if last > 0 then return path.x[last], path.y[last] end
end

-- World 530 (Outland, and on the Anniversary realms the Blood Elf and
-- Draenei lands) is reached through portals: the Dark Portal, the cities'.
-- A trip to or from it saved as a boat ("b", any continent change nothing
-- explained) without a known dock at both ends was one of those, so it is
-- a teleport ("u"), not a boat's red dots (Jordan, 2026-10-25).
local PORTAL_WORLD = 530

function Recorder:JumpReason(previous, path)
    if path.j == "b" and previous and (previous.c == PORTAL_WORLD or path.c == PORTAL_WORLD) then
        local last = #previous.x
        local docked = ns.Dock and last > 0 and path.x[1]
            and ns.Dock(previous.c, previous.x[last], previous.y[last]) and ns.Dock(path.c, path.x[1], path.y[1])
        if not docked then return "u" end
    end
    if self:Continues(previous, path) then return nil end
    if path.j or not previous or previous.c ~= path.c or path.m == "g" then
        return path.j
    end
    local last = #previous.x
    if last > 0 and path.x[1]
        and Dist(previous.x[last], previous.y[last], path.x[1], path.y[1]) > TELEPORT_DIST then
        return "u"
    end
end

-- Decoded copy of every segment, as GetPath.
function Recorder:GetPaths()
    local paths = {}
    for i = 1, #ns.char.segments do
        paths[i] = self:GetPath(i)
    end
    return self:MarkTeleportsOut(paths)
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
    local stale = not self.lastSample or GetTime() - self.lastSample > STALE_SECONDS
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
