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
-- With terrain on, the island's own minimap tiles (MinimapTiles.lua) fade in
-- over its art as the continents' terrain does, cut to the same shape. They
-- sit on the island's layer, as the terrain layer is below it, and load the
-- first time they show.
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
local TERRAIN_SUBLEVEL = 4      -- above the explored art and its overlays
local TILE_YARDS = 533.33333    -- one minimap tile
local MASK_PATH = "Interface\\AddOns\\" .. addonName .. "\\ZoneMasks\\island_"

local Islands = {
    explored = {},      -- textures of the explored art, faded by zoom
    alpha = nil,        -- their current opacity
    tiles = {},         -- terrain tiles: { fileID, texture }, the texture set once shown
    terrainAlpha = nil, -- their current opacity
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
            -- Minimap tile mapCOL_ROW covers world X (north) from
            -- (32 - row) * TILE_YARDS down one tile, and world Y (west) from
            -- (32 - col) * TILE_YARDS down one tile, as on the continents.
            for key, fileID in pairs(ns.MinimapTiles[ns.MinimapDirs[c] or ""] or {}) do
                local col, row = key:match("^(%d+)_(%d+)$")
                local north, west = (32 - tonumber(row)) * TILE_YARDS, (32 - tonumber(col)) * TILE_YARDS
                local ax, ay = toContent[c](north, west)
                local bx, by = toContent[c](north - TILE_YARDS, west - TILE_YARDS)
                local tex = layer:CreateTexture(nil, "BACKGROUND", nil, TERRAIN_SUBLEVEL)
                tex:SetPoint("TOPLEFT", layer, "TOPLEFT", math.min(ax, bx), -math.min(ay, by))
                tex:SetPoint("BOTTOMRIGHT", layer, "TOPLEFT", math.max(ax, bx), -math.max(ay, by))
                for _, m in ipairs(masks) do
                    tex:AddMaskTexture(m)
                end
                tex:Hide()
                self.tiles[#self.tiles + 1] = { fileID, tex }
            end
        end
    end
    self.alpha, self.terrainAlpha = nil, nil
end

-- Shows the terrain tiles at opacity a, loading their files the first time.
function Islands:SetTerrain(a)
    if a == self.terrainAlpha then return end
    self.terrainAlpha = a
    for _, tile in ipairs(self.tiles) do
        local tex = tile[2]
        if a > 0 and not tile.loaded then
            tex:SetTexture(tile[1])
            tile.loaded = true
        end
        tex:SetAlpha(a)
        tex:SetShown(a > 0)
    end
end

-- Fades the explored art for zoom z, and the terrain to terrainAlpha.
function Islands:SetZoom(z, terrainAlpha)
    self:SetTerrain(terrainAlpha or 0)
    local f = math.log(z / EXPLORED_FADE[1]) / math.log(EXPLORED_FADE[2] / EXPLORED_FADE[1])
    f = math.max(0, math.min(1, f))
    if f == self.alpha then return end
    self.alpha = f
    for _, tex in ipairs(self.explored) do
        tex:SetAlpha(f)
        tex:SetShown(f > 0)
    end
end
