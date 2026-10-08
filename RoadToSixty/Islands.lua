local addonName, ns = ...

-- Islands with a map of their own that the world map art leaves out, such
-- as Zephras Isle: a zone of Azeroth on its own map (continent ID 2991),
-- placed on no continent and drawn nowhere on the world map. Each is drawn
-- at a spot in the sea chosen here, at the continents' scale, cut to the
-- shape of its land by ZoneMasks\island_<uiMapID>.tga (made by
-- scripts/zone-overlays.py), so the path recorded there has land under it.
--
-- The continent maps reach far out to sea, both of them over the middle of
-- the world, so their art and the zone paper over them would cover an
-- island drawn with the world art. Islands get a layer of their own above
-- the zone art instead, at the terrain's level: minimap terrain lies only
-- inside zones, never out at sea.
--
-- Zoomed out, an island shows its map as before it is explored (the base
-- art alone, muted like the world map); its explored art, every overlay
-- included, fades in over it as the continent art fades in.
--
-- ISLANDS: { uiMapID, x, y } where x, y is where the middle of the island's
-- map goes, as shares of the world map art.
local ISLANDS = {
    -- Open sea north of the Maelstrom, between its zeppelin ports, Thunder
    -- Bluff and Dalaran.
    { 2521, 0.48, 0.3 },
}
local LAYER_ABOVE_WORLD = 3     -- frame levels above the world art layer
local EXPLORED_FADE = { 1.6, 2.6 }  -- zoom where explored art starts to fade in and is fully shown, as the continent art
local EXPLORED_SUBLEVEL = 2     -- above the unexplored art; its overlays go one above
local MASK_PATH = "Interface\\AddOns\\" .. addonName .. "\\ZoneMasks\\island_"

local Islands = {
    explored = {},      -- textures of the explored art, faded by zoom
    alpha = nil,        -- their current opacity
}
ns.Islands = Islands

local function Yards(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- Draws each island over worldLayer, the world art of W by H content units,
-- and adds its continent to toContent (continentID -> function(worldX,
-- worldY) -> content x, y). Called once the continents are on the map, for
-- their scale.
function Islands:Add(worldLayer, toContent, W, H)
    local perYard = ns.Map:ContentPerYard()
    if not perYard then return end
    local layer = CreateFrame("Frame", nil, worldLayer:GetParent())
    layer:SetAllPoints()
    layer:SetFrameLevel(worldLayer:GetFrameLevel() + LAYER_ABOVE_WORLD)
    for _, island in ipairs(ISLANDS) do
        local uiMap = island[1]
        local c, toMap = ns.MapTransform(uiMap)
        local _, o = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(0, 0))
        local _, eu = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(1, 0))
        local _, ev = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(0, 1))
        if c and toMap and o and eu and ev and not toContent[c] then
            local w, h = Yards(o, eu) * perYard, Yards(o, ev) * perYard
            local x1, y1 = island[2] * W - w / 2, island[3] * H - h / 2
            toContent[c] = function(x, y)
                local u, v = toMap(x, y)
                return x1 + u * w, y1 + v * h
            end
            local mask = layer:CreateMaskTexture()
            mask:SetTexture(MASK_PATH .. uiMap, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetPoint("TOPLEFT", layer, "TOPLEFT", x1, -y1)
            mask:SetPoint("BOTTOMRIGHT", layer, "TOPLEFT", x1 + w, -(y1 + h))
            -- Land can reach the edge of the art (Zephras Isle's skydocks
            -- run off its bottom), so the art's edge fades out as well.
            local masks = { mask, ns.EdgeMask(layer, x1, y1, x1 + w, y1 + h) }
            local unexplored = ns.AddZoneArt(layer, uiMap, x1, y1, x1 + w, y1 + h, {}, 0, masks)
            local explored = ns.AddZoneArt(layer, uiMap, x1, y1, x1 + w, y1 + h,
                ns.ZoneOverlays(uiMap), 0, masks, EXPLORED_SUBLEVEL)
            for _, list in ipairs({ unexplored, explored }) do
                for _, tex in ipairs(list) do
                    -- Shown at every zoom, so kept smooth close up as the world art is.
                    tex:SetSnapToPixelGrid(false)
                    tex:SetTexelSnappingBias(0)
                end
            end
            for _, tex in ipairs(explored) do
                self.explored[#self.explored + 1] = tex
            end
        end
    end
    self.alpha = nil
end

-- Fades the explored art for zoom z.
function Islands:SetZoom(z)
    local f = math.log(z / EXPLORED_FADE[1]) / math.log(EXPLORED_FADE[2] / EXPLORED_FADE[1])
    f = math.max(0, math.min(1, f))
    if f == self.alpha then return end
    self.alpha = f
    for _, tex in ipairs(self.explored) do
        tex:SetAlpha(f)
        tex:SetShown(f > 0)
    end
end
