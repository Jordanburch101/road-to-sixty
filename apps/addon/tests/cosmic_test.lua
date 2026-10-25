-- Offline test of Cosmic.lua (#75) with a made-up map API: only a world
-- map on a Cosmic map with Outland gets the Cosmic layer; the view's area
-- and least zoom take in the whole Cosmic art round Azeroth's world map;
-- world 530 points land on the Blood Elf zone map that holds them, else on
-- Outland; and the world layer fades in as the view closes in.
-- Run with LuaJIT from the repo root: luajit tests/cosmic_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

Enum = { UIMapType = { Zone = 3 } }
local outlandOnCosmic = true
C_Map = {
    GetMapInfo = function(id)
        if id == 947 then return { mapID = 947, parentMapID = 946 } end
    end,
    GetMapChildrenInfo = function(id)
        if id == 946 then
            return outlandOnCosmic and { { mapID = 947 }, { mapID = 1945 } } or { { mapID = 947 } }
        end
        if id == 1415 then return { { mapID = 1429 }, { mapID = 1941 } } end
        return {}
    end,
    -- Eversong covers the top fifth of the Eastern Kingdoms' map.
    GetMapRectOnMap = function(id, parent)
        if id == 1941 and parent == 1415 then return 0.4, 0.6, 0, 0.2 end
        if id == 1429 and parent == 1415 then return 0.2, 0.4, 0.6, 0.8 end
    end,
}

local ns = { Gaps = { FEATHER = "feather", Mask = function() return "mask" end } }
assert(loadfile("RoadToSixty/Cosmic.lua"))("RoadToSixty", ns)
local Cosmic = ns.Cosmic

check(Cosmic:Available(947), "Azeroth on a Cosmic map with Outland has the Cosmic layer")
check(not Cosmic:Available(1415), "a map without a Cosmic parent has not")
outlandOnCosmic = false
check(not Cosmic:Available(947), "a Cosmic map without Outland (Era) has not")
outlandOnCosmic = true

-- World 530 transforms: Eversong's map spans world x 0 to 100; Outland's 1000 to 2000.
local transforms = {
    [1941] = { 530, function(x, y) return x / 100, y / 100 end },
    [1429] = { 0, function(x, y) return x / 50, y / 50 end },
    [1945] = { 530, function(x, y) return (x - 1000) / 1000, (y - 1000) / 1000 end },
}
local art, added = {}, {}
local layer = { SetAlpha = function(self, a) self.alpha = a end }
local state = { toContent = {} }
Cosmic:Add(947, 1000, 600, {
    state = state,
    AddArt = function(parent, id, x1, y1, x2, y2, mask) art[id] = { parent, x1, y1, x2, y2, mask } end,
    MapTransform = function(id) local t = transforms[id]; if t then return t[1], t[2] end end,
    zoneView = { AddContinent = function(_, id, x, y, w, h) added[id] = { x, y, w, h } end },
    cosmicLayer = "cosmic", worldLayer = layer,
    continents = { { 1415, 600, 100, 300, 400 } },
})

-- The Cosmic art: Azeroth's world map (0, 0 to 1000, 600) is 0.34 of it, centred at 0.775, 0.61.
local a = state.area
check(near(state.minZoom, 0.34), "least zoom shows the whole Cosmic art")
check(near(a[3] - a[1], 1000 / 0.34) and near(a[4] - a[2], 600 / 0.34), "area is the Cosmic art's size")
check(near((0 - a[1]) / (a[3] - a[1]) + 0.17, 0.775), "the world map sits on the globe")
check(art[946] and art[946][1] == "cosmic", "Cosmic art drawn on its own layer")
check(art[1945] and art[1945][1] == layer and art[1945][6] == "mask", "Outland drawn on the world layer, feathered")
check(added[1945] and added[1945][1] < 0 and added[1945][2] < 0, "Outland's zones sit top left, outside Azeroth")

-- World 530: Eversong's middle goes to the middle of Eversong's rect on the
-- Eastern Kingdoms; a point in Outland goes onto Outland.
local toContent = state.toContent[530]
check(toContent ~= nil, "world 530 is placed")
local x, y = toContent(50, 50)
check(near(x, 600 + 0.5 * 300) and near(y, 100 + 0.1 * 400), ("Eversong's middle at %.1f, %.1f"):format(x, y))
local o = added[1945]
x, y = toContent(1500, 1500)
check(near(x, o[1] + o[3] / 2) and near(y, o[2] + o[4] / 2), "Outland's middle in Outland's place")

-- Fading: hidden zoomed out on the Cosmic map, whole at the Azeroth view.
Cosmic:SetZoom(0.34)
check(layer.alpha == 0, "world layer hidden at the least zoom")
Cosmic:SetZoom(1)
check(layer.alpha == 1, "world layer whole at zoom 1")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("Cosmic tests passed.")
