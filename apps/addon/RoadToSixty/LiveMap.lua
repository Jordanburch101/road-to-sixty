local _, ns = ...

-- The journey map kept up to date while it is open (#136): the arrow at the
-- player's position now, gliding along a flight as it goes, and the line
-- growing as the recorder stores points, without building the map again.
--
-- Live only when the map shows this character's own journey, in a range
-- that runs to now (All time, Today, the last 7 or 30 days), with the replay
-- at its end and not replaying together. Then, each frame, the arrow sits
-- at Recorder:Position() with a short line from the last stored point to
-- it. Points stored since the map was built are added to the map's points
-- (Map.lua's state, see its header) as they come: those of the segment
-- being recorded, and of new segments that start where the last one ended
-- (a flight taking off or landing). A segment that jumps (a hearthstone, a
-- death, a boat, another continent) builds the map again; new events
-- (markers, kills, History, the gear card, the pops) are put on it at most
-- every MARKER_SECONDS. Neither happens in combat. Points on a continent the
-- map doesn't draw are passed over, as BuildPoints passes over them.
--
-- Map.lua hands over what it needs through Map.inner (end of Map.lua).
-- LiveMap.Append and LiveMap.ExtendLods make no game calls, for the tests
-- (tests/livemap_test.lua).

local LiveMap = {}
ns.LiveMap = LiveMap

local MARKER_SECONDS = 30       -- new events are put on the map at most this often; each time goes through them all
local CHECK_SECONDS = 0.25      -- how often to look for points stored, as the recorder samples

-- Adds the points of decoded path (Recorder.lua's format) from its index
-- first on to track (Map.lua's state: n, px, py, pt, pm, pb, brk, pj, pd,
-- bounds), placed by toContent, in level band band (or band(t), a function
-- of the point's time). first == 1 starts a new segment, after previous
-- (the path before it) unless it carries on from it (Recorder:Continues),
-- as does the track's first point. pj stays nil: a segment with a jump
-- reason is built again instead. Returns the index of the first point
-- added, or nil if none was.
function LiveMap.Append(track, path, first, toContent, band, previous, continues)
    local n, from = track.n, nil
    local b = track.bounds
    for i = first, #path.x do
        n = n + 1
        from = from or n
        local x, y = toContent(path.x[i], path.y[i])
        track.px[n], track.py[n], track.pt[n], track.pm[n] = x, y, path.t[i], path.m
        track.pb[n] = type(band) == "function" and band(path.t[i]) or band
        track.brk[n] = i == 1 and not continues or n == 1
        track.pj[n] = nil
        local bx, by = path.x[i - 1], path.y[i - 1]
        if i == 1 then
            bx, by = nil, nil
            if continues and previous then bx, by = previous.x[#previous.x], previous.y[#previous.y] end
        end
        track.pd[n] = bx and math.sqrt((path.x[i] - bx) ^ 2 + (path.y[i] - by) ^ 2) or 0
        if n == 1 then
            b[1], b[2], b[3], b[4] = x, y, x, y
        else
            if x < b[1] then b[1] = x end
            if y < b[2] then b[2] = y end
            if x > b[3] then b[3] = x end
            if y > b[4] then b[4] = y end
        end
    end
    track.n = n
    return from
end

-- Where in list (a level's kept points) the first point after point i is:
-- near the end, as only the last few are ever looked for.
local function After(list, i)
    local j = #list + 1
    while j > 1 and list[j - 1] > i do j = j - 1 end
    return j
end

-- Carries the detail levels already made (Map.lua's GetLod, PathShape.lua's
-- MakeLevel) on to points from to track.n, so they hold what MakeLevel
-- would make for the whole path, made in the same order. What KeepShape
-- keeps depends only on the points since the last one kept, so each level
-- drops the old last point (kept for being the end; kept again below if it
-- is still needed) and goes on from its last point kept before it, through
-- what it was made from (the new points of the finer level, or every new
-- point), keeping what the coarser level it keeps all of has newly kept.
-- Levels are carried on in the order they were made, as each is made from
-- ones made before it. The chunks from the first one changed are made again.
function LiveMap.ExtendLods(track, from, lodDistance, chunk)
    local lods, n = track.lods, track.n
    if not lods.order then return end
    local oldEnd, top = from - 1, lods.top
    -- The old last point was kept by every level for being the end.
    lods.ends = lods.ends - 1 + ns.AlwaysKept(track, oldEnd, n)
    -- The point each level went on from: what it keeps up to there is as it
    -- was, the rest may have changed.
    local went, least = {}, oldEnd
    for _, k in ipairs(lods.order) do
        local lod = lods[k]
        local idx = lod.idx
        local count = #idx
        -- A level made from a finer one saw the old end as the point after
        -- that level's last before it, and may have kept that one only
        -- because the line couldn't reach the end; and whether it keeps the
        -- point the finer level went on from was decided by the point after
        -- it, which may be another now. So it goes on from before that
        -- point, and from no further than the coarser level it keeps all of
        -- went on from, as that one's points past there may be gone.
        local before = lod.from and went[lod.from] or oldEnd
        local upTo = lod.keep and went[lod.keep] or oldEnd
        while count > 0 and (idx[count] >= before or idx[count] > upTo) do
            idx[count] = nil
            count = count - 1
        end
        local kept, last = count, idx[count] or 0
        -- Lines merged (MergeLines) stay merged, but for those the lines
        -- carried on from here covered; new lines are drawn until the level
        -- is merged again, as the newest are never covered.
        local hid = lod.hid
        if hid then ns.DropMergedAfter(hid, idx, kept + 1) end
        went[k] = last
        if last < least then least = last end
        local source = lod.from and lods[lod.from].idx
        local forced = lod.keep and lods[lod.keep].idx
        count = ns.KeepShape(track, source, source and After(source, last) or last + 1, source and #source or n,
            lodDistance(k), idx, count, forced, forced and After(forced, last))
        ns.LodChunks(track, idx, count, lod.chunks, math.floor(kept / chunk) + 1, chunk, hid)
    end
    -- The coarsest level keeping each point, from the first that may have changed.
    for i = least + 1, n do top[i] = nil end
    for _, k in ipairs(lods.order) do
        local idx = lods[k].idx
        for j = After(idx, least), #idx do
            local i = idx[j]
            if not top[i] or top[i] < k then top[i] = k end
        end
    end
end

-- In game ---------------------------------------------------------------------------

local inner             -- Map.inner
local live              -- { seg = segment index, have = its points handled, stored, segments } while live
local checkElapsed, markersAt, rebuildWanted, markersWanted = 0, 0, false, false
local seen = {}         -- the counts new events change, as last put on the map

local function Counts()
    local view = ns.view
    return #view.events, view.kills and #view.kills.d or 0, ns.Gathering.changes
end

-- Whether the map shows this character's journey up to now, at the replay's
-- end: a range ending now, or none (All time, and the endgame with it).
local function Live(state)
    local range = ns.Range
    return ns.view == ns.char and not state.playing and not state.clock
        and state.cur >= state.n and (range:IsAll() or range.toNow or range.to == math.huge)
        and ns.Screens:Mode() == "map"
end

-- Called once the map's points are built: what of this character's path is
-- on the map, so what is stored later can be added.
function LiveMap:Built(state)
    inner = ns.Map.inner
    live, rebuildWanted, markersWanted = nil, false, false
    if ns.view ~= ns.char then return end
    local segments = #ns.char.segments
    local path = segments > 0 and ns.Recorder:GetPath(segments)
    -- With nothing recorded yet, the first segment is the one to watch.
    live = { seg = math.max(1, segments), have = path and #path.x or 0,
        stored = ns.Recorder.stored, segments = segments }
    seen[1], seen[2], seen[3] = Counts()
    markersAt = GetTime()
end

-- The level band at a time from the level ups in the events (as
-- BuildPoints colours its points), for points from time t0 on: they may
-- have waited while the map wasn't live, across a level up.
local function Bands(t0)
    local events, changes, base = ns.view.events, {}, nil
    for i = #events, 1, -1 do
        local e = events[i]
        if e[2] == "lvl" or e[2] == "on" then
            if e[1] <= t0 then base = e[6] break end
            changes[#changes + 1] = e
        end
    end
    return function(t)
        local level = base
        for j = #changes, 1, -1 do
            if changes[j][1] <= t then level = changes[j][6] else break end
        end
        return ns.Style.LevelBand(level or UnitLevel("player"))
    end
end

-- Adds what the recorder stored since. Returns the box around the points
-- added ({ x1, y1, x2, y2 }), or nil if none were; sets rebuildWanted for a
-- segment that can't just be added.
local function Catch(state)
    local segments = ns.char.segments
    -- Nothing stored and no new segment: nothing to decode.
    if ns.Recorder.stored == live.stored and #segments == live.segments then return end
    live.stored, live.segments = ns.Recorder.stored, #segments
    local box
    for s = live.seg, #segments do
        local path = ns.Recorder:GetPath(s)
        local first = s == live.seg and live.have + 1 or 1
        if first <= #path.x then
            local previous = s > 1 and ns.Recorder:GetPath(s - 1) or nil
            local continues = first == 1 and ns.Recorder:Continues(previous, path)
            local toContent = state.toContent[path.c]
            local last = state.n
            -- A new segment that jumps, or one after a continent change, is
            -- built again. One on a map not drawn is passed over.
            if toContent and first == 1 and not continues
                and (ns.Recorder:JumpReason(previous, path) ~= nil or (last > 0 and previous and previous.c ~= path.c)) then
                rebuildWanted = true
                return box
            end
            local from = toContent and LiveMap.Append(state, path, first, toContent, Bands(path.t[first]), previous, continues)
            if from then
                LiveMap.ExtendLods(state, from, inner.LodDistance, inner.CHUNK)
                box = box or { math.huge, math.huge, -math.huge, -math.huge }
                for i = from, state.n do
                    local x, y = state.px[i], state.py[i]
                    if x < box[1] then box[1] = x end
                    if y < box[2] then box[2] = y end
                    if x > box[3] then box[3] = x end
                    if y > box[4] then box[4] = y end
                end
            end
        end
        live.seg, live.have = s, #path.x
    end
    return box
end

-- The player's world position now, not rounded to yards as the recorder
-- stores it, so the arrow moves smoothly; the recorder's outdoors, where
-- the client hides it.
local function WorldPosition()
    if not IsInInstance() then
        local mapID = C_Map.GetBestMapForUnit("player")
        local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
        if pos then
            local c, world = C_Map.GetWorldPosFromMapPos(mapID, pos)
            if c and world then return c, world.x, world.y end
        end
    end
    return ns.Recorder:Position()
end

local SMOOTH = 20           -- higher follows the position faster; it eases out the client's small steps
local SNAP = 50             -- content units: further than this (a teleport) the arrow jumps there
local shown                 -- { x, y, at }: where the arrow was put last

-- The arrow's place while live: at the player's position now, eased so it
-- doesn't shake, facing the way the character faces (GetPlayerFacing, in
-- radians anticlockwise from north as the arrow turns; nil where the
-- client hides it, and then the last way it faced), with the mode and band
-- for the line from the last point stored. Facing rather than the way from
-- that point, which a yard or two after a point is stored swung with every
-- small step (Jordan, 2026-11-11). Nil when not live or nowhere to put it.
function LiveMap:Head(state)
    -- Waiting to build again (in combat), the arrow stays on the last point
    -- rather than draw the line from it across a jump.
    if not (live and inner and Live(state)) or rebuildWanted then return end
    local c, x, y = WorldPosition()
    local toContent = c and state.toContent[c]
    if not toContent then return end
    local hx, hy = toContent(x, y)
    local now = GetTime()
    if shown and shown.c == c then
        local dx, dy = hx - shown.x, hy - shown.y
        if dx * dx + dy * dy < SNAP * SNAP then
            local f = 1 - math.exp(-SMOOTH * math.max(0, now - shown.at))
            hx, hy = shown.x + dx * f, shown.y + dy * f
        end
    end
    local facing = GetPlayerFacing and GetPlayerFacing()
    if type(facing) ~= "number" then facing = shown and shown.facing end
    shown = shown or {}
    shown.x, shown.y, shown.c, shown.at, shown.facing = hx, hy, c, now, facing
    return hx, hy, facing, ns.Recorder:Mode(), ns.Style.LevelBand(UnitLevel("player"))
end

-- Each frame while the map is open.
function LiveMap:Update(elapsed)
    if not (live and inner) then return end
    local state = inner.state
    if not Live(state) then return end
    checkElapsed = checkElapsed + elapsed
    if checkElapsed >= CHECK_SECONDS then
        checkElapsed = 0
        local busy = UnitAffectingCombat("player")
        -- Midnight moved the range's start: built again.
        local key = ns.Range:CacheKey()
        ns.Range:Refresh()
        if ns.Range:CacheKey() ~= key then rebuildWanted = true end
        if not rebuildWanted then
            local box = Catch(state)
            if box then inner.PointsAdded(box) end
        end
        local events, kills, gathers = Counts()
        if events ~= seen[1] or kills ~= seen[2] or gathers ~= seen[3] then markersWanted = true end
        if rebuildWanted and not busy then
            inner.Rebuild()     -- calls Built again
            return
        end
        if markersWanted and not busy and GetTime() - markersAt >= MARKER_SECONDS then
            markersWanted, markersAt = false, GetTime()
            seen[1], seen[2], seen[3] = Counts()
            inner.MarkersChanged()
        end
    end
    inner.HeadMoved()
end
