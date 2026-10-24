-- Offline test of the zone overlay tables (#72): Forever keeps
-- ZoneOverlays.lua's file IDs, Classic Era gets ZoneOverlaysEra.lua's
-- (Forever's draw green there), and both keep the zone masks.
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
    assert(loadfile("RoadToSixty/ZoneOverlays.lua"))("RoadToSixty", ns)
    local forever = ns.ZoneOverlayData
    assert(loadfile("RoadToSixty/ZoneOverlaysEra.lua"))("RoadToSixty", ns)
    return ns, forever
end

local ns, forever = Load(16001)
check(ns.ZoneOverlayData == forever, "Forever keeps its own overlays")
ns, forever = Load(11509)
check(ns.ZoneOverlayData ~= forever, "Era gets its own overlays")
check(ns.ZoneMasks and ns.ZoneMasks[1429], "Era keeps the zone masks")

-- Every Era overlay has a file for each 256x256 piece, and every classic
-- zone Forever has overlays for is there.
for uiMap, list in pairs(ns.ZoneOverlayData) do
    for _, o in ipairs(list) do
        local pieces = math.ceil(o[1] / 256) * math.ceil(o[2] / 256)
        check(#o - 4 == pieces, ("map %d: %d files for %d pieces"):format(uiMap, #o - 4, pieces))
    end
end
local FOREVER_ONLY = { [2482] = true, [2521] = true, [2548] = true, [2652] = true }
for uiMap in pairs(forever) do
    check(FOREVER_ONLY[uiMap] or ns.ZoneOverlayData[uiMap], ("map %d has no Era overlays"):format(uiMap))
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("ZoneOverlays tests passed.")
