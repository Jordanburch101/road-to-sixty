local _, ns = ...

-- Boat and zeppelin docks, so a trip between continents (a "b" jump in
-- Recorder.lua) can be named after where it left and landed, and drawn
-- from pier to pier, round the coast where the sea course is known.
--
-- DOCKS: { name, continentID, x, y } in world yards, as
-- C_Map.GetWorldPosFromMapPos gives them. Converted from each dock's zone
-- map position in the client's UiMapAssignment table (build 1.60.1.70245),
-- except Stormwind Harbor, which comes from a recorded trip. A place with
-- several piers or zeppelin platforms has one entry per pier. Docks on one
-- continent at both ends (Rut'theran, Feathermoon, Menethil to Southshore)
-- are here for completeness; those trips are recorded as a path, not a jump.
-- Zephras Isle is a map of its own (2991), not part of either continent.

local DOCKS = {
    { "Stormwind Harbor", 0, -8550, 1450 },
    { "Menethil Harbor", 0, -3906, -584 },      -- to Theramore
    { "Menethil Harbor", 0, -3711, -576 },      -- to Southshore
    { "Southshore", 0, -1102, -556 },           -- to Auberdine
    { "Booty Bay", 0, -14279, 581 },            -- to Ratchet
    { "Powderfuse Port", 0, -8232, -5801 },     -- to Gadgetzan
    { "Undercity", 0, 2063, 236 },              -- zeppelin to Grom'gol
    { "Grom'gol", 0, -12462, 230 },             -- zeppelin to Orgrimmar
    { "Dalaran", 0, 544, 425 },                 -- zeppelin to Valanaar Skydocks
    { "Auberdine", 1, 6547, 944 },              -- to Stormwind Harbor
    { "Auberdine", 1, 6595, 761 },              -- to Rut'theran Village
    { "Rut'theran Village", 1, 8533, 1024 },    -- to Auberdine
    { "Feathermoon Ferry", 1, -4197, 3287 },
    { "Theramore", 1, -4018, -4739 },           -- to Menethil Harbor
    { "Ratchet", 1, -1009, -3842 },             -- to Booty Bay
    { "Gadgetzan", 1, -6933, -4952 },           -- to Powderfuse Port
    { "Orgrimmar", 1, 1361, -4633 },            -- zeppelin to Grom'gol
    { "Orgrimmar", 1, 1318, -4659 },            -- zeppelin to Undercity
    { "Thunder Bluff", 1, -804, 368 },          -- zeppelin to Valanaar
    { "Valanaar", 2991, 1953, 1022 },           -- zeppelin to Thunder Bluff
    { "Valanaar Skydocks", 2991, 1849, 571 },   -- zeppelin to Dalaran
}
-- How far from a dock a trip may start or end and still be named after it.
-- The arrival point is wherever the first position after the loading screen
-- was recorded, which can be some way along the pier.
local DOCK_RANGE = 2500

-- The dock nearest a world position, { name, continentID, x, y }, or nil if
-- none is within DOCK_RANGE. The same pier always gives the same table, so
-- the map can tell two trips on one route apart from different routes.
function ns.Dock(c, x, y)
    local best, bestD = nil, DOCK_RANGE * DOCK_RANGE
    for _, dock in ipairs(DOCKS) do
        if dock[2] == c then
            local d = (dock[3] - x) ^ 2 + (dock[4] - y) ^ 2
            if d < bestD then
                best, bestD = dock, d
            end
        end
    end
    return best
end

-- The name of the dock nearest a world position, or nil.
function ns.DockName(c, x, y)
    local dock = ns.Dock(c, x, y)
    return dock and dock[1]
end

-- "Stormwind Harbor to Auberdine" for a boat trip between two world
-- positions, or nil unless both ends are near a dock.
function ns.BoatRoute(c1, x1, y1, c2, x2, y2)
    local from, to = ns.DockName(c1, x1, y1), ns.DockName(c2, x2, y2)
    return from and to and (from .. " to " .. to)
end

-- Sea courses of the boats between the continents, so a trip goes round the
-- coast instead of over land: { from dock, to dock, { u1, v1, u2, v2, ... } },
-- waypoints between the two piers as 0-1 positions on the world map (uiMap
-- 947), in order from the first dock. Drafted on the world map art, keeping
-- off the coasts; zeppelins fly, so they keep the plain arc.
local COURSES = {
    -- South-west of Zephras Isle (Islands.lua puts its land at about 0.45 to
    -- 0.52 across, 0.24 to 0.36 down).
    { "Stormwind Harbor", "Auberdine", {
        0.66, 0.615, 0.55, 0.46, 0.43, 0.4, 0.38, 0.28, 0.35, 0.185, 0.27, 0.17, 0.195, 0.2,
        0.163, 0.24 } },
    -- Out of Southshore's bay to the south, under the headland, then north
    -- of Zephras Isle and round the north of Kalimdor.
    { "Southshore", "Auberdine", {
        0.735, 0.39, 0.715, 0.42, 0.665, 0.43, 0.6, 0.36, 0.56, 0.25, 0.49, 0.19, 0.4, 0.165,
        0.27, 0.165, 0.195, 0.2, 0.163, 0.24 } },
    { "Menethil Harbor", "Theramore", { 0.715, 0.47, 0.56, 0.56, 0.4, 0.615, 0.33, 0.635 } },
    -- Not in Forever's list of boats, but recorded on the beta: south-west of
    -- Zephras Isle and round the north of Kalimdor, as from Stormwind.
    { "Menethil Harbor", "Auberdine", {
        0.715, 0.47, 0.6, 0.465, 0.43, 0.4, 0.38, 0.28, 0.35, 0.185, 0.27, 0.17, 0.195, 0.2,
        0.163, 0.24 } },
    -- North of the islands in the middle of the sea, south of Ratchet's.
    { "Booty Bay", "Ratchet", {
        0.69, 0.8, 0.62, 0.72, 0.56, 0.6, 0.42, 0.565, 0.33, 0.56, 0.3, 0.545 } },
    -- South of the islands and round the tip of the Eastern Kingdoms.
    { "Gadgetzan", "Powderfuse Port", {
        0.335, 0.745, 0.5, 0.785, 0.7, 0.865, 0.8, 0.8, 0.885, 0.7, 0.885, 0.625 } },
}

-- The waypoints of the course from one dock to another by name, as a list
-- of { u, v } in sailing order, or nil if the route has none.
function ns.SeaCourse(from, to)
    for _, course in ipairs(COURSES) do
        local forward = course[1] == from and course[2] == to
        if forward or (course[1] == to and course[2] == from) then
            local points, flat = {}, course[3]
            for i = 1, #flat, 2 do
                points[#points + 1] = { flat[i], flat[i + 1] }
            end
            if not forward then
                for i = 1, math.floor(#points / 2) do
                    points[i], points[#points + 1 - i] = points[#points + 1 - i], points[i]
                end
            end
            return points
        end
    end
end

local COURSE_STEPS = 12     -- curve points between two waypoints

-- A smooth curve through points ({ x, y } in map content units), as
-- Catmull-Rom splines: { x, y, distance along the curve }, like the map's
-- jump arcs.
function ns.CourseCurve(points)
    local p = { points[1] }
    for _, point in ipairs(points) do
        p[#p + 1] = point
    end
    p[#p + 1] = points[#points]
    local curve, along = {}, 0
    local function Add(x, y)
        local last = curve[#curve]
        if last then
            along = along + math.sqrt((x - last[1]) ^ 2 + (y - last[2]) ^ 2)
        end
        curve[#curve + 1] = { x, y, along }
    end
    for i = 2, #p - 2 do
        local p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        for s = 0, COURSE_STEPS - 1 do
            local t = s / COURSE_STEPS
            local t2, t3 = t * t, t * t * t
            local function At(k)
                return 0.5 * (2 * p1[k] + (p2[k] - p0[k]) * t
                    + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2
                    + (3 * p1[k] - p0[k] - 3 * p2[k] + p3[k]) * t3)
            end
            Add(At(1), At(2))
        end
    end
    local last = points[#points]
    Add(last[1], last[2])
    return curve
end

-- How a boat trip is drawn: { x1, y1, x2, y2, flip, curve, anchor, box }.
--
-- The path is recorded on the boat until the loading screen and again after
-- it, and the boat leaves and arrives along different lines each way, so a
-- trip runs from its own ends: a (where tracking stopped, from dock from)
-- and b (where it started again, at dock to), as { x, y } on the map. With a
-- sea course it passes the course's waypoints that lie between the two, as
-- found on the course from pier to pier (pierA, pierB); waypoints are 0-1 on
-- the world map, W by H in map units.
--
-- A route is always drawn the same way round (flip: sailed from its second
-- end), and its dots are counted from anchor, the distance along curve of the
-- course's middle waypoint, so trips out and back put their dots on the same
-- spots out at sea. Without a course, curve and anchor are nil and the map
-- draws its usual arc. box is the area the curve covers.
function ns.BoatTrip(from, to, a, b, pierA, pierB, W, H)
    local flip = from[1] .. from[3] .. from[4] > to[1] .. to[3] .. to[4]
    if flip then
        from, to, a, b, pierA, pierB = to, from, b, a, pierB, pierA
    end
    local trip = { a[1], a[2], b[1], b[2], flip = flip }
    local course = ns.SeaCourse(from[1], to[1])
    if not course then return trip end

    local waypoints, full = {}, { pierA }
    for i, p in ipairs(course) do
        waypoints[i] = { p[1] * W, p[2] * H }
        full[#full + 1] = waypoints[i]
    end
    full[#full + 1] = pierB
    full = ns.CourseCurve(full)
    local da, db = ns.CurveDistance(full, a[1], a[2]), ns.CurveDistance(full, b[1], b[2])
    local points, middle, anchor = { a }, math.ceil(#waypoints / 2), nil
    for i, p in ipairs(waypoints) do
        local d = ns.CurveDistance(full, p[1], p[2])
        if d > da and d < db then
            points[#points + 1] = p
            if i == middle then anchor = p end
        end
    end
    points[#points + 1] = b

    local curve = ns.CourseCurve(points)
    local box = { math.huge, math.huge, -math.huge, -math.huge }
    for _, p in ipairs(curve) do
        box[1], box[2] = math.min(box[1], p[1]), math.min(box[2], p[2])
        box[3], box[4] = math.max(box[3], p[1]), math.max(box[4], p[2])
    end
    trip.curve, trip.box = curve, box
    trip.anchor = anchor and ns.CurveDistance(curve, anchor[1], anchor[2])
    return trip
end

-- Lanes for hearthstones and teleports between Kalimdor and the Eastern
-- Kingdoms, so the open sea shows two tidy lines rather than a tangle of
-- arcs: every such trip gathers into its kind's lane off its own coast,
-- follows it across, and fans out to where it landed. By jump reason
-- (seg.j): { west end, middle, east end } as 0-1 positions on the world
-- map, the ends out at sea so the fans spread over water. The two bow apart
-- round the Maelstrom, clear of Zephras Isle.
local LANES = {
    h = { { 0.4, 0.45 }, { 0.5, 0.42 }, { 0.6, 0.45 } },     -- hearthstones, north
    p = { { 0.4, 0.53 }, { 0.5, 0.56 }, { 0.6, 0.53 } },     -- teleports, south
}
local WEST, EAST = 1, 0     -- continent IDs: Kalimdor, the Eastern Kingdoms

local LANE_STEPS = 24      -- curve points per Bezier piece; even, so the trunk has its middle

-- How a hearthstone or teleport across the sea is drawn, as ns.BoatTrip: a
-- (on continent c1) to b (on c2), { x, y } on the map of W by H units. nil
-- unless the trip crosses between Kalimdor and the Eastern Kingdoms; trips
-- to Zephras Isle and elsewhere keep the map's arc.
--
-- Three Bezier pieces: the trunk, one bend from end to end through the
-- lane's middle, and a feather at each side from the trip's own end to the
-- lane's, arriving along the trunk's direction. Bezier curves keep inside
-- their control points, so feathers from anywhere fan in without loops, and
-- every trip runs on the very same trunk either way round. Dots are counted
-- from the lane's middle, so they fall on the same spots; trunk gives the
-- trunk's start and end as distances along the curve, so the map can draw
-- it once for every trip on the lane.
function ns.SeaLane(reason, c1, a, c2, b, W, H)
    local lane = LANES[reason]
    if not lane or c1 == c2 or not ((c1 == WEST or c1 == EAST) and (c2 == WEST or c2 == EAST)) then
        return
    end
    local from = { lane[1][1] * W, lane[1][2] * H }
    local middle = { lane[2][1] * W, lane[2][2] * H }
    local to = { lane[3][1] * W, lane[3][2] * H }
    if c1 == EAST then
        from, to = to, from
    end
    local function Lerp(p, q, f)
        return { p[1] + (q[1] - p[1]) * f, p[2] + (q[2] - p[2]) * f }
    end
    -- The trunk as a cubic with the control of the quadratic bend through
    -- middle; out of each lane end, the way the trunk leaves it, reaching
    -- half as far as the trip's end is from the lane's.
    local bend = { 2 * middle[1] - (from[1] + to[1]) / 2, 2 * middle[2] - (from[2] + to[2]) / 2 }
    local function Out(p, length)
        local dx, dy = p[1] - bend[1], p[2] - bend[2]
        local d = math.sqrt(dx * dx + dy * dy)
        return { p[1] + dx / d * length / 2, p[2] + dy / d * length / 2 }
    end
    local function Length(p, q)
        return math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2)
    end

    local curve, along = {}, 0
    local function Piece(p0, p1, p2, p3)
        for s = #curve == 0 and 0 or 1, LANE_STEPS do
            local t = s / LANE_STEPS
            local u = 1 - t
            local x = u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]
            local y = u * u * u * p0[2] + 3 * u * u * t * p1[2] + 3 * u * t * t * p2[2] + t * t * t * p3[2]
            local last = curve[#curve]
            if last then
                along = along + math.sqrt((x - last[1]) ^ 2 + (y - last[2]) ^ 2)
            end
            curve[#curve + 1] = { x, y, along }
        end
    end
    Piece(a, Lerp(a, from, 0.3), Out(from, Length(a, from)), from)
    local trunk = { along }
    Piece(from, Lerp(from, bend, 2 / 3), Lerp(to, bend, 2 / 3), to)
    trunk[2] = along
    local anchor = curve[#curve - LANE_STEPS / 2][3]
    Piece(to, Out(to, Length(b, to)), Lerp(b, to, 0.3), b)
    local box = { math.huge, math.huge, -math.huge, -math.huge }
    for _, p in ipairs(curve) do
        box[1], box[2] = math.min(box[1], p[1]), math.min(box[2], p[2])
        box[3], box[4] = math.max(box[3], p[1]), math.max(box[4], p[2])
    end
    return { a[1], a[2], b[1], b[2], curve = curve, box = box, anchor = anchor, trunk = trunk, lane = reason }
end

-- How far along a curve ({ x, y, distance along } points) the point nearest
-- to (x, y) is.
function ns.CurveDistance(curve, x, y)
    local best, bestD = 0, math.huge
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local length2 = dx * dx + dy * dy
        local f = length2 > 0 and math.max(0, math.min(1, ((x - a[1]) * dx + (y - a[2]) * dy) / length2)) or 0
        local d = (a[1] + dx * f - x) ^ 2 + (a[2] + dy * f - y) ^ 2
        if d < bestD then
            best, bestD = a[3] + (b[3] - a[3]) * f, d
        end
    end
    return best
end
