-- Offline test of the zone overlay tables (#72, #75): Forever keeps
-- ZoneOverlays.lua's file IDs, Classic Era gets ZoneOverlaysEra.lua's
-- (Forever's draw green there), Anniversary ZoneOverlaysAnniversary.lua's
-- with masks for its own zones, and all keep the zone masks.
-- Run with LuaJIT from the repo root: luajit tests/zoneoverlays_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local function Load(interface)
    GetBuildInfo = function() return "1.0.0", "1", "Jan 1 2026", interface end
    local ns = {}
    -- (as Core.lua sets them, before the files that use them)
    ns.Classic = interface < 16000 or interface >= 17000
    ns.Anniversary = interface >= 20000 and interface < 30000
    assert(loadfile("RoadToSixty/ZoneOverlays.lua"))("RoadToSixty", ns)
    local forever = ns.ZoneOverlayData
    assert(loadfile("RoadToSixty/ZoneOverlaysEra.lua"))("RoadToSixty", ns)
    local era = ns.ZoneOverlayData
    assert(loadfile("RoadToSixty/ZoneOverlaysAnniversary.lua"))("RoadToSixty", ns)
    return ns, forever, era
end

-- Every overlay has a file for each 256x256 piece.
local function Whole(data, name)
    for uiMap, list in pairs(data) do
        for _, o in ipairs(list) do
            local pieces = math.ceil(o[1] / 256) * math.ceil(o[2] / 256)
            check(#o - 4 == pieces, ("%s map %d: %d files for %d pieces"):format(name, uiMap, #o - 4, pieces))
        end
    end
end

local ns, forever = Load(16001)
check(ns.ZoneOverlayData == forever, "Forever keeps its own overlays")
check(not ns.ZoneMasks[1941], "Forever has no Eversong mask")

local era
ns, forever, era = Load(20506)
check(ns.ZoneOverlayData ~= forever and ns.ZoneOverlayData ~= era, "Anniversary gets its own overlays")
for _, uiMap in ipairs({ 1941, 1942, 1943, 1950, 1957, 1944, 1951 }) do
    check(ns.ZoneOverlayData[uiMap], ("Anniversary has overlays for map %d"):format(uiMap))
    check(ns.ZoneMasks[uiMap], ("Anniversary has a mask for map %d"):format(uiMap))
end
check(not ns.ZoneMasks[1954] and not ns.ZoneMasks[1955], "cities have no mask")
check(ns.CityMasks[1955], "Shattrath has a city mask, so its plan shows")
check(ns.ZoneMasks[1429], "Anniversary keeps the zone masks")
Whole(ns.ZoneOverlayData, "Anniversary")

ns, forever = Load(11509)
check(ns.ZoneOverlayData ~= forever, "Era gets its own overlays")
check(ns.ZoneMasks and ns.ZoneMasks[1429], "Era keeps the zone masks")
check(not ns.ZoneMasks[1941], "Era has no Eversong mask")
check(not ns.CityMasks[1955], "Era has no Shattrath")
Whole(ns.ZoneOverlayData, "Era")

-- Every classic zone Forever has overlays for is in Era's.
local FOREVER_ONLY = { [2482] = true, [2521] = true, [2548] = true, [2652] = true }
for uiMap in pairs(forever) do
    check(FOREVER_ONLY[uiMap] or ns.ZoneOverlayData[uiMap], ("map %d has no Era overlays"):format(uiMap))
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("ZoneOverlays tests passed.")
