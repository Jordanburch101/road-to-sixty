local _, ns = ...

-- The Cosmic map (#75): on a client whose Cosmic map holds Outland (the
-- Anniversary realms), the journey map's outermost layer is that art, with
-- Azeroth's world map in its globe (bottom right) and Outland's map in its
-- painting of Outland (top left); zooming into either takes you there.
--
-- Content units stay Azeroth's world map art (0, 0 to W, H, zoom 1 fitting
-- it), so nothing laid out on Azeroth moves: the Cosmic art is drawn round
-- it, larger, and zoom goes below 1 (state.minZoom) to show it whole. The
-- view's limits become the Cosmic art's (state.area). Azeroth's world art
-- and Outland's map sit on the world layer, which fades in as you zoom in
-- (WORLD_FADE), each through the soft feather mask (Gaps.lua).
--
-- Outland's map is drawn about as large as Azeroth's whole world, so its
-- zones are several times larger on screen than Azeroth's at the same zoom:
-- they have a zone view of their own, whose fades are the journey map's
-- divided by how much wider Outland's zones are than Azeroth's (the middle
-- width of the outlined ones), so a zone comes in at the same size on
-- screen either side (Jordan, 2026-10-25: they needed far too much zooming;
-- scaling by the continents' widths was not enough, as the continent maps
-- reach far past their land).
--
-- World 530 holds Outland and also the Blood Elf and Draenei lands, which
-- the maps show on the Eastern Kingdoms and Kalimdor: state.toContent[530]
-- places a point by the first of those zone maps that holds it, else on
-- Outland.

local Cosmic = {}
ns.Cosmic = Cosmic

local COSMIC_MAP = 946
local OUTLAND = 1945
local OUTLAND_WORLD = 530
-- Where each map sits on the Cosmic art: its centre and width, in shares of
-- the art (all three are 1002 x 668, so the height share is the same). By
-- eye: Azeroth's continents over the globe's, Outland's land over its
-- painting.
local PLACES = { [947] = { 0.775, 0.61, 0.34 }, [OUTLAND] = { 0.317, 0.35, 0.355 } }
local WORLD_FADE = { 0.55, 0.85 }   -- zoom where the world layer starts to show and is whole

local worldLayer   -- set while the Cosmic map is in use
local outlandView  -- Outland's zones (ZoneArt.lua's ZoneView)

-- 0 below range[1], 1 above range[2], smooth in between on a log scale.
local function Fade(zoom, range)
    local f = math.log(zoom / range[1]) / math.log(range[2] / range[1])
    return math.max(0, math.min(1, f))
end

-- The middle width of a zone view's outlined zones, in content units.
local function MiddleWidth(zones)
    local widths = {}
    for _, zone in pairs(zones) do
        if zone.outline then widths[#widths + 1] = zone[3] - zone[1] end
    end
    table.sort(widths)
    return widths[math.ceil(#widths / 2)]
end

-- True if this client's world map world sits on a Cosmic map with Outland.
function Cosmic:Available(world)
    local info = C_Map.GetMapInfo(world)
    if not (info and info.parentMapID == COSMIC_MAP and PLACES[world]) then return false end
    for _, child in ipairs(C_Map.GetMapChildrenInfo(COSMIC_MAP) or {}) do
        if child.mapID == OUTLAND then return true end
    end
    return false
end

-- Lays out the Cosmic art and Outland round Azeroth's world map, which is
-- at 0, 0 to W, H. m holds what Map.lua lends: state, AddArt, MapTransform,
-- zoneView, the layers, and continents ({ uiMapID, x1, y1, w, h } each).
function Cosmic:Add(world, W, H, m)
    local place = PLACES[world]
    local share = place[3]
    local cw, ch = W / share, H / share
    local x0, y0 = -(place[1] - share / 2) * cw, -(place[2] - share / 2) * ch
    m.AddArt(m.cosmicLayer, COSMIC_MAP, x0, y0, x0 + cw, y0 + ch)
    m.state.area = { x0, y0, x0 + cw, y0 + ch }
    m.state.minZoom = share
    worldLayer = m.worldLayer

    -- Outland, on the world layer like Azeroth's world map, and its zones.
    local o = PLACES[OUTLAND]
    local ox, oy, ow, oh = x0 + (o[1] - o[3] / 2) * cw, y0 + (o[2] - o[3] / 2) * ch, o[3] * cw, o[3] * ch
    m.AddArt(m.worldLayer, OUTLAND, ox, oy, ox + ow, oy + oh,
        ns.Gaps.Mask(m.worldLayer, ns.Gaps.FEATHER, ox, oy, ox + ow, oy + oh))
    local layer = CreateFrame("Frame", nil, m.zoneView.layer:GetParent())
    layer:SetAllPoints()
    layer:SetFrameLevel(m.zoneView.layer:GetFrameLevel())
    outlandView = ns.CreateZoneView(layer, true)
    outlandView.wideEdge, outlandView.rimEdge = m.zoneView.wideEdge, m.zoneView.rimEdge
    outlandView:AddContinent(OUTLAND, ox, oy, ow, oh)
    local azeroth, outland = MiddleWidth(m.zoneView.zones), MiddleWidth(outlandView.zones)
    local k = azeroth and outland and outland / azeroth or 1
    local zf, pf = m.zoneView.FADE, m.zoneView.PLAN_FADE
    outlandView.FADE = { zf[1] / k, zf[2] / k }
    outlandView.PLAN_FADE = { pf[1] / k, pf[2] / k }

    -- World 530: each Blood Elf or Draenei zone map, placed on its continent,
    -- then Outland for everything else.
    local regions = {}
    for _, c in ipairs(m.continents) do
        for _, zone in ipairs(C_Map.GetMapChildrenInfo(c[1], Enum.UIMapType.Zone) or {}) do
            local id, toMap = m.MapTransform(zone.mapID)
            local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(zone.mapID, c[1])
            if id == OUTLAND_WORLD and toMap and minX then
                regions[#regions + 1] = { toMap, c[2] + minX * c[4], c[3] + minY * c[5],
                    (maxX - minX) * c[4], (maxY - minY) * c[5] }
            end
        end
    end
    local id, toOutland = m.MapTransform(OUTLAND)
    if id == OUTLAND_WORLD and toOutland then
        regions[#regions + 1] = { toOutland, ox, oy, ow, oh, whole = true }
    end
    if #regions == 0 then return end
    m.state.toContent[OUTLAND_WORLD] = function(x, y)
        for _, r in ipairs(regions) do
            local u, v = r[1](x, y)
            if r.whole or (u >= 0 and u <= 1 and v >= 0 and v <= 1) then
                return r[2] + u * r[4], r[3] + v * r[5]
            end
        end
        local r = regions[#regions]
        local u, v = r[1](x, y)
        return r[2] + u * r[4], r[3] + v * r[5]
    end
end

-- Fades the world layer in as the view closes in on a world, and fits
-- Outland's zones to the view, x1, y1 to x2, y2 in content units.
local lastZoom
function Cosmic:SetZoom(zoom, x1, y1, x2, y2)
    lastZoom = zoom
    if not worldLayer then return end
    worldLayer:SetAlpha(Fade(zoom, WORLD_FADE))
    if outlandView then
        outlandView.layer:SetAlpha(not ns.db.terrain and Fade(zoom, outlandView.FADE) or 0)
        if not ns.db.terrain and zoom >= outlandView.FADE[1] and x1 then
            outlandView:SetZoom(zoom)
            outlandView:Update(x1, y1, x2, y2)
        end
    end
end

--@debug@
-- /rts cosmic: what the Outland zone view does at the map's current zoom.
ns.Command("cosmic", "show the Cosmic layer and Outland zone view state (developer)", function()
    if not worldLayer then
        ns.Print("No Cosmic layer on this client (or the map has not been opened).")
        return
    end
    ns.Print(("Zoom %.2f, world layer alpha %.2f."):format(lastZoom or 0, worldLayer:GetAlpha()))
    if not outlandView then
        ns.Print("No Outland zone view.")
        return
    end
    local zones, together, outlined, built, shown = 0, 0, 0, 0, 0
    for _, zone in pairs(outlandView.zones) do
        zones = zones + 1
        if zone.together then together = together + 1 end
        if zone.outline then outlined = outlined + 1 end
        if zone.textures then built = built + 1 end
        if zone.alpha and zone.alpha > 0 then shown = shown + 1 end
    end
    ns.Print(("Outland zones: fade %.2f to %.2f, layer alpha %.2f, level %d; %d zones, %d outlined, %d shown together, %d built, %d at full alpha."):format(
        outlandView.FADE[1], outlandView.FADE[2], outlandView.layer:GetAlpha(), outlandView.layer:GetFrameLevel(),
        zones, outlined, together, built, shown))
end)
--@end-debug@
