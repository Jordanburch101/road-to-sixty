-- Offline test of Routes.lua: docks, route names and sea courses. Run with
-- LuaJIT from the repo root: luajit tests/routes_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Routes.lua"))("RoadToSixty", ns)

-- Docks: the nearest pier by continent, nothing far from any.
check(ns.DockName(0, -8540, 1460) == "Stormwind Harbor", "Stormwind Harbor by its pier")
check(ns.DockName(1, -8540, 1460) == nil, "no dock across the sea on the other continent")
check(ns.DockName(0, -6000, -3000) == nil, "no dock far from every pier")
check(ns.Dock(1, 6550, 940) == ns.Dock(1, 6540, 950), "one pier gives one dock table")
check(ns.BoatRoute(0, -8550, 1450, 1, 6547, 944) == "Stormwind Harbor to Auberdine", "route name")

-- Sea courses: either way round, in sailing order.
local out, back = ns.SeaCourse("Stormwind Harbor", "Auberdine"), ns.SeaCourse("Auberdine", "Stormwind Harbor")
check(out and back and #out == #back, "course both ways")
if out and back then
    check(out[1][1] == back[#back][1] and out[1][2] == back[#back][2], "the way back is the way out reversed")
    check(out[1][1] > out[#out][1], "out from Stormwind starts in the east")
end
check(ns.SeaCourse("Orgrimmar", "Undercity") == nil, "zeppelins have no sea course")

-- The curve runs from the first point to the last, through every waypoint,
-- with the distance along it growing.
local points = { { 0, 0 }, { 10, 0 }, { 10, 10 }, { 20, 10 } }
local curve = ns.CourseCurve(points)
check(curve[1][1] == 0 and curve[1][2] == 0 and curve[1][3] == 0, "curve starts at the first point")
local last = curve[#curve]
check(last[1] == 20 and last[2] == 10, "curve ends at the last point")
local through, growing = 0, true
for i, p in ipairs(curve) do
    for _, w in ipairs(points) do
        if math.abs(p[1] - w[1]) < 1e-9 and math.abs(p[2] - w[2]) < 1e-9 then
            through = through + 1
        end
    end
    if i > 1 and p[3] <= curve[i - 1][3] then growing = false end
end
check(through == #points, "curve passes through every waypoint")
check(growing, "distance along the curve grows")

-- Boat trips: each from its own ends, the same way round for one route, the
-- dots' anchor on the same spot out at sea both ways.
local W, H = 1002, 668
local sw, aub = ns.Dock(0, -8550, 1450), ns.Dock(1, 6547, 944)
local swPier, aubPier = { 0.6971 * W, 0.6191 * H }, { 0.1734 * W, 0.2767 * H }
local outward = ns.BoatTrip(sw, aub, { 0.6936 * W, 0.6170 * H }, { 0.1725 * W, 0.2704 * H }, swPier, aubPier, W, H)
local homeward = ns.BoatTrip(aub, sw, { 0.1593 * W, 0.2804 * H }, { 0.6995 * W, 0.6235 * H }, aubPier, swPier, W, H)
check(outward.curve and homeward.curve, "Stormwind Harbor and Auberdine have a sea course")
check(outward.flip ~= homeward.flip, "the trip back is drawn the same way round")
if outward.curve and homeward.curve then
    local function Near(p, x, y) return math.abs(p[1] - x) < 1e-6 and math.abs(p[2] - y) < 1e-6 end
    check(Near(outward.curve[1], outward[1], outward[2]) and Near(outward.curve[#outward.curve], outward[3], outward[4]),
        "a trip's curve runs between its own ends")
    local function At(trip)
        for i = 2, #trip.curve do
            local a, b = trip.curve[i - 1], trip.curve[i]
            if trip.anchor <= b[3] then
                local f = (trip.anchor - a[3]) / (b[3] - a[3])
                return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
            end
        end
    end
    local ox, oy = At(outward)
    local hx, hy = At(homeward)
    check(ox and hx and math.abs(ox - hx) < 1e-6 and math.abs(oy - hy) < 1e-6, "both ways anchor their dots on one spot")
end
check(ns.BoatTrip(ns.Dock(1, 1361, -4633), ns.Dock(0, 2063, 236), { 1, 1 }, { 2, 2 }, { 0, 0 }, { 3, 3 }, W, H).curve == nil,
    "zeppelins keep the arc")

-- Hearthstone and teleport lanes: only between Kalimdor and the Eastern
-- Kingdoms, each trip from its own ends, the trunk shared both ways.
check(ns.SeaLane("h", 0, { 1, 1 }, 0, { 2, 2 }, W, H) == nil, "no lane on one continent")
check(ns.SeaLane("h", 1, { 1, 1 }, 2991, { 2, 2 }, W, H) == nil, "no lane to Zephras Isle")
check(ns.SeaLane("d", 1, { 1, 1 }, 0, { 2, 2 }, W, H) == nil, "no lane for deaths")
local west, east = { 0.19 * W, 0.52 * H }, { 0.74 * W, 0.53 * H }
local there = ns.SeaLane("h", 1, west, 0, east, W, H)
local back = ns.SeaLane("h", 0, { 0.70 * W, 0.62 * H }, 1, { 0.17 * W, 0.21 * H }, W, H)
check(there and back, "hearthstones across the sea take the lane")
if there and back then
    local first, last = there.curve[1], there.curve[#there.curve]
    check(first[1] == west[1] and first[2] == west[2] and last[1] == east[1] and last[2] == east[2],
        "a lane trip runs between its own ends")
    local function At(trip)
        for _, p in ipairs(trip.curve) do
            if math.abs(p[3] - trip.anchor) < 1e-9 then return p[1], p[2] end
        end
    end
    local tx, ty = At(there)
    local bx, by = At(back)
    check(tx and bx and math.abs(tx - bx) < 1e-6 and math.abs(ty - by) < 1e-6, "both ways anchor on the lane's middle")
    check(tx and math.abs(tx - 0.5 * W) < 1e-6 and math.abs(ty - 0.42 * H) < 1e-6, "the anchor is the lane's middle")
end
local teleport = ns.SeaLane("p", 1, west, 0, east, W, H)
check(teleport and there and teleport.box[4] > there.box[4], "teleports keep a lane of their own, south of the hearthstones")

if failures == 0 then
    print("Routes tests passed.")
else
    print(failures .. " routes test(s) failed.")
    os.exit(1)
end
