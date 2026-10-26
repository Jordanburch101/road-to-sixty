-- Offline test of the terrain tile lists: Forever keeps MinimapTiles.lua's;
-- Era and the Anniversary realms each get their own (MinimapTilesEra.lua,
-- MinimapTilesAnniversary.lua), as Forever's hold tiles they lack, drawn
-- green or as another place's ground there; only Anniversary has world 530's.
-- Run with LuaJIT from the repo root: luajit tests/minimaptiles_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function Load(classic, anniversary)
    local ns = { Classic = classic, Anniversary = anniversary, Era = classic and not anniversary }
    for _, file in ipairs({ "MinimapTiles", "MinimapTilesAnniversary", "MinimapTilesEra" }) do
        assert(loadfile("RoadToSixty/" .. file .. ".lua"))("RoadToSixty", ns)
    end
    return ns.MinimapTiles
end

local forever, era, anniversary = Load(false, false), Load(true, false), Load(true, true)
check(Count(forever.Azeroth) > Count(anniversary.Azeroth), "Forever has terrain the classic clients lack")
check(era.Azeroth ~= forever.Azeroth and anniversary.Azeroth ~= forever.Azeroth, "each classic client has its own Eastern Kingdoms list")
check(era.Kalimdor ~= forever.Kalimdor and anniversary.Kalimdor ~= forever.Kalimdor, "and its own Kalimdor list")
check(Count(anniversary.Expansion01) > 0 and not era.Expansion01 and not forever.Expansion01, "only Anniversary has world 530's tiles")
check(forever["2991"] ~= nil, "Forever keeps Zephras Isle's tiles")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("MinimapTiles tests passed.")
