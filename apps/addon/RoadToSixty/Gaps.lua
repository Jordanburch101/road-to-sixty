local addonName, ns = ...

-- Gap art (#73, from Smooth Map, #71): land and sea no zone map covers
-- (north of Stormwind, say) showed the continent art blown up, its big
-- lettering and its sea's strokes a blur. They are painted as the zone maps
-- paint theirs, on a layer under every zone's art that fades in with it, so
-- this shows only where no zone draws. Bottom to top:
--   * zone map sea (Gaps/sea.tga) near the coast (sea_<uiMapID>), and the
--     brown strokes zone maps draw off a coast (hatch.tga, hatch_<uiMapID>)
--   * on the land (land_<uiMapID>), blank parchment cut from a zone map
--     (parchment.tga) in the colour of the zone maps nearest each place:
--     a copy of the parchment, the colour field (field_<uiMapID>) over it
--     at MIX[1], a second copy over that at MIX[2]
--   * mountains (mountains.tga) a little in from the coast
--     (mountains_<uiMapID>): a gap is nearly always the range between two
--     zones; ours are quilted from zone maps' ranges
--   * the coast's light blue-grey shoreline (shore_<uiMapID>)
-- Every tile is at the zone art's scale (its pixels are a zone map's). Each
-- is drawn twice, the second COPY.size times larger and shifted: one tile
-- repeated shows its blotches in rows; two of sizes that never line up do
-- not. Made by scripts/gap-textures.py and scripts/gap-masks.py; MIX must
-- match the latter's, which works out the field for it.
--
-- Each game paints its maps its own way, so each has its own set: Forever's
-- in Gaps/, Era's in Gaps/Era/, and the Anniversary realms' in
-- Gaps/Anniversary/ (their continents were repainted for the Blood Elf and
-- Draenei lands under Era's file IDs: Era's masks put mountains on their sea). Gaps/feather.tga and rim.tga, the soft
-- masks Map.lua and ZoneArt.lua use (scripts/feather-mask.py), serve both.

local Gaps = {}
ns.Gaps = Gaps

local ROOT = "Interface\\AddOns\\" .. addonName .. "\\Gaps\\"
local MEDIA = ns.Anniversary and ROOT .. "Anniversary\\" or ns.Classic and ROOT .. "Era\\" or ROOT
Gaps.FEATHER = ROOT .. "feather"
Gaps.RIM = ROOT .. "rim"

local CONTINENTS = { [1414] = true, [1415] = true }
local ZONE_ART = 1002           -- a zone map's art width, in its pixels
local COPY = { size = 1.618, shift = 0.37 }
local MIX = { 0.5, 1 / 3 }
local SHORE = { 0.62, 0.66, 0.62, 0.85 }
-- (the mountains a touch see-through, so the parchment's colour of the
-- place under them comes through a little)
local MOUNTAIN_ALPHA = 0.9

-- A mask over parent's content x1, y1 - x2, y2.
local function Mask(parent, file, x1, y1, x2, y2)
    local mask = parent:CreateMaskTexture()
    mask:SetTexture(file, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetPoint("TOPLEFT", parent, "TOPLEFT", x1, -y1)
    mask:SetPoint("BOTTOMRIGHT", parent, "TOPLEFT", x2, -y2)
    return mask
end
Gaps.Mask = Mask

-- texture over x1, y1 - x2, y2, its file repeated every tw by th content units
local function Tile(tex, file, x1, y1, x2, y2, tw, th, shift)
    tex:SetTexture(file, "REPEAT", "REPEAT", "TRILINEAR")
    tex:SetPoint("TOPLEFT", tex:GetParent(), "TOPLEFT", x1, -y1)
    tex:SetPoint("BOTTOMRIGHT", tex:GetParent(), "TOPLEFT", x2, -y2)
    tex:SetTexCoord(shift, shift + (x2 - x1) / tw, shift, shift + (y2 - y1) / th)
end

-- Paints the gaps of continent uiMap, laid out at x1, y1 - x2, y2 in
-- content units, on layer. zones is the ZoneView's, to size the tiles.
function Gaps:Add(layer, uiMap, x1, y1, x2, y2, zones)
    if not CONTINENTS[uiMap] then return end
    -- (content units per zone art pixel: zone maps differ in scale, so the middle width)
    local widths = {}
    for _, z in pairs(zones) do
        if z.outline and z[1] >= x1 and z[3] <= x2 then widths[#widths + 1] = z[3] - z[1] end
    end
    table.sort(widths)
    local px = (widths[math.ceil(#widths / 2)] or (x2 - x1) / 10) / ZONE_ART
    local sublevel = -8
    local function Next()
        sublevel = sublevel + 1
        return sublevel - 1
    end
    -- two copies of a tile (pixels w by h) through mask, the first at alpha, the second at alpha2
    local function Twice(file, w, h, mask, alpha, alpha2, between)
        for copy = 0, 1 do
            if copy == 1 and between then between() end
            local k = copy == 1 and COPY.size or 1
            local tex = layer:CreateTexture(nil, "BACKGROUND", nil, Next())
            Tile(tex, file, x1, y1, x2, y2, w * px * k, h * px * k, copy == 1 and COPY.shift or 0)
            tex:SetAlpha(copy == 1 and alpha2 or alpha)
            tex:AddMaskTexture(mask)
        end
    end

    Twice(MEDIA .. "sea", 128, 128, Mask(layer, MEDIA .. "sea_" .. uiMap, x1, y1, x2, y2), 1, 0.5)
    local hatch = layer:CreateTexture(nil, "BACKGROUND", nil, Next())
    Tile(hatch, MEDIA .. "hatch", x1, y1, x2, y2, 128 * px, 64 * px, 0)
    hatch:AddMaskTexture(Mask(layer, MEDIA .. "hatch_" .. uiMap, x1, y1, x2, y2))

    local land = Mask(layer, MEDIA .. "land_" .. uiMap, x1, y1, x2, y2)
    Twice(MEDIA .. "parchment", 256, 256, land, 1, MIX[2], function()
        local field = layer:CreateTexture(nil, "BACKGROUND", nil, Next())
        field:SetTexture(MEDIA .. "field_" .. uiMap, "CLAMP", "CLAMP", "TRILINEAR")
        field:SetPoint("TOPLEFT", layer, "TOPLEFT", x1, -y1)
        field:SetPoint("BOTTOMRIGHT", layer, "TOPLEFT", x2, -y2)
        field:SetAlpha(MIX[1])
        field:AddMaskTexture(land)
    end)

    local mountains = layer:CreateTexture(nil, "BACKGROUND", nil, Next())
    Tile(mountains, MEDIA .. "mountains", x1, y1, x2, y2, 512 * px, 512 * px, 0)
    mountains:SetAlpha(MOUNTAIN_ALPHA)
    mountains:AddMaskTexture(Mask(layer, MEDIA .. "mountains_" .. uiMap, x1, y1, x2, y2))

    local shore = layer:CreateTexture(nil, "BACKGROUND", nil, Next())
    shore:SetColorTexture(SHORE[1], SHORE[2], SHORE[3], SHORE[4])
    shore:SetPoint("TOPLEFT", layer, "TOPLEFT", x1, -y1)
    shore:SetPoint("BOTTOMRIGHT", layer, "TOPLEFT", x2, -y2)
    shore:AddMaskTexture(Mask(layer, MEDIA .. "shore_" .. uiMap, x1, y1, x2, y2))
end
