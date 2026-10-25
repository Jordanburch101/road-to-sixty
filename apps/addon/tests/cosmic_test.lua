-- Offline test of Cosmic.lua (#75) with a made-up map API: only a world
-- map on a Cosmic map with Outland gets the Cosmic layer; the view's area
-- and least zoom take in the whole Cosmic art round Azeroth's world map;
-- world 530 points land on the Blood Elf zone map that holds them, else on
-- Outland; the world layer fades in as the view closes in; and Outland's
-- zones have a view of their own whose fades are scaled to Outland's size.
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

local function Frame()
    return { SetAllPoints = function() end, SetFrameLevel = function(self, l) self.level = l end,
        SetAlpha = function(self, a) self.alpha = a end, GetParent = function() return "content" end,
        GetFrameLevel = function() return 5 end }
end
CreateFrame = function() return Frame() end
local views = {}
local ns = { Gaps = { FEATHER = "feather", Mask = function() return "mask" end }, db = { terrain = false },
    Command = function() end, Print = function() end }
ns.CreateZoneView = function(layer, stable)
    local view = { layer = layer, stable = stable, zooms = {}, areas = {} }
    function view:AddContinent(id, x, y, w, h) self.continent = { id, x, y, w, h } end
    function view:SetZoom(z) table.insert(self.zooms, z) end
    function view:Update(...) table.insert(self.areas, { ... }) end
    table.insert(views, view)
    return view
end
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
local art = {}
local layer = { SetAlpha = function(self, a) self.alpha = a end }
local state = { toContent = {} }
Cosmic:Add(947, 1000, 600, {
    state = state,
    AddArt = function(parent, id, x1, y1, x2, y2, mask) art[id] = { parent, x1, y1, x2, y2, mask } end,
    MapTransform = function(id) local t = transforms[id]; if t then return t[1], t[2] end end,
    zoneView = { layer = Frame(), FADE = { 4, 6 }, PLAN_FADE = { 9, 12 }, wideEdge = "wide", rimEdge = "rim" },
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
local outland = views[1]
check(outland and outland.stable and outland.continent and outland.continent[1] == 1945, "Outland's zones have a stable view of their own")
check(outland.continent[2] < 0 and outland.continent[3] < 0, "Outland's zones sit top left, outside Azeroth")
check(outland.wideEdge == "wide" and outland.rimEdge == "rim", "Outland's view takes the journey map's edge masks")
-- Outland is 0.355 / 0.34 of the world map wide, the Eastern Kingdoms 300 of 1000.
local k = (0.355 / 0.34 * 1000) / 300
check(near(outland.FADE[1], 4 / k) and near(outland.FADE[2], 6 / k), ("Outland's zones fade in from %.2f"):format(outland.FADE[1]))
check(near(outland.PLAN_FADE[1], 9 / k), "Outland's city plans scale too")

-- World 530: Eversong's middle goes to the middle of Eversong's rect on the
-- Eastern Kingdoms; a point in Outland goes onto Outland.
local toContent = state.toContent[530]
check(toContent ~= nil, "world 530 is placed")
local x, y = toContent(50, 50)
check(near(x, 600 + 0.5 * 300) and near(y, 100 + 0.1 * 400), ("Eversong's middle at %.1f, %.1f"):format(x, y))
local o = outland.continent
x, y = toContent(1500, 1500)
check(near(x, o[2] + o[4] / 2) and near(y, o[3] + o[5] / 2), "Outland's middle in Outland's place")

-- Fading: hidden zoomed out on the Cosmic map, whole at the Azeroth view.
Cosmic:SetZoom(0.34)
check(layer.alpha == 0, "world layer hidden at the least zoom")
Cosmic:SetZoom(1)
check(layer.alpha == 1, "world layer whole at zoom 1")
Cosmic:SetZoom(2, 0, 0, 10, 10)
check(outland.layer.alpha == 1 and #outland.areas == 1, "Outland's zones whole and fitted to the view at zoom 2")
ns.db.terrain = true
Cosmic:SetZoom(2, 0, 0, 10, 10)
check(outland.layer.alpha == 0, "Outland's zone art hidden with terrain on")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("Cosmic tests passed.")
