local addonName, ns = ...

-- Map art drawing shared by the journey map and the debug probes: alpha
-- gradients, and zone map art with its explored-area overlays.

local ZONE_EDGE = 0.1   -- part of the zone art at each side that fades into the continent

-- Older clients have SetGradientAlpha; newer ones take colour objects.
-- tint is an optional { r, g, b }.
local function SetAlphaGradient(tex, orientation, minAlpha, maxAlpha, tint)
    local r, g, b = 1, 1, 1
    if tint then
        r, g, b = tint[1], tint[2], tint[3]
    end
    if tex.SetGradientAlpha then
        tex:SetGradientAlpha(orientation, r, g, b, minAlpha, r, g, b, maxAlpha)
    else
        tex:SetGradient(orientation, CreateColor(r, g, b, minAlpha), CreateColor(r, g, b, maxAlpha))
    end
end
ns.SetAlphaGradient = SetAlphaGradient

-- Zone art: a zone's base map art plus every explored-area overlay, so the
-- zone shows fully revealed. Overlays come from ZoneOverlays.lua; a zone
-- missing there shows what this character has explored instead. Edges fade
-- out so the art blends into the continent art under it.

-- Overlays for uiMap: { width, height, offsetX, offsetY, fileID... } in map
-- art pixels. explored = true lists only what this character has explored.
local function ZoneOverlays(uiMap, explored)
    local data = not explored and ns.ZoneOverlayData and ns.ZoneOverlayData[uiMap]
    if data then return data end
    local list = {}
    local explore = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
    for _, info in ipairs(explore and explore(uiMap) or {}) do
        list[#list + 1] = { info.textureWidth, info.textureHeight, info.offsetX, info.offsetY,
            unpack(info.fileDataIDs) }
    end
    return list
end
ns.ZoneOverlays = ZoneOverlays

-- Size of the last piece in a row or column of overlay pieces, and of the
-- power-of-two file it is stored in, as Blizzard's MapExplorationPinMixin has it.
local function LastPiece(full, tile)
    local pixels = full % tile
    if pixels == 0 then pixels = tile end
    local file = 16
    while file < pixels do file = file * 2 end
    return pixels, file
end

-- Pieces of uiMap's art: { fileID, u2, v2, x1, y1, x2, y2, isOverlay },
-- showing the file from 0, 0 to u2, v2 over art pixels x1, y1 - x2, y2.
-- Returns the pieces and the art size, or nil.
local function ZoneArtPieces(uiMap, overlays)
    local layer = (C_Map.GetMapArtLayers(uiMap) or {})[1]
    local textures = C_Map.GetMapArtLayerTextures(uiMap, 1)
    if not (layer and textures) then return end
    local tw, th = layer.tileWidth, layer.tileHeight
    local pieces = {}
    local cols = math.ceil(layer.layerWidth / tw)
    for i, fileID in ipairs(textures) do
        local left, top = (i - 1) % cols * tw, math.floor((i - 1) / cols) * th
        local w, h = math.min(tw, layer.layerWidth - left), math.min(th, layer.layerHeight - top)
        pieces[#pieces + 1] = { fileID, w / tw, h / th, left, top, left + w, top + h }
    end
    for _, o in ipairs(overlays or {}) do
        local across, down = math.ceil(o[1] / tw), math.ceil(o[2] / th)
        for j = 1, down do
            local ph, fh = th, th
            if j == down then ph, fh = LastPiece(o[2], th) end
            for k = 1, across do
                local pw, fw = tw, tw
                if k == across then pw, fw = LastPiece(o[1], tw) end
                local x, y = o[3] + tw * (k - 1), o[4] + th * (j - 1)
                pieces[#pieces + 1] = { o[4 + (j - 1) * across + k], pw / fw, ph / fh, x, y, x + pw, y + ph, true }
            end
        end
    end
    return pieces, layer.layerWidth, layer.layerHeight
end

-- Draws uiMap's art with the given overlays over content x1, y1 - x2, y2 on
-- parent. The outer edge fraction of it (ZONE_EDGE unless given; 0 for none)
-- fades to transparent; corners are left out, as one texture fades one way
-- only. masks, if given, are added to every texture. sublevel (default 0)
-- is the draw sublevel of the base art; overlays go one above. Returns the
-- textures.
local function AddZoneArt(parent, uiMap, x1, y1, x2, y2, overlays, edge, masks, sublevel)
    sublevel = sublevel or 0
    local pieces, W, H = ZoneArtPieces(uiMap, overlays)
    local textures = {}
    if not pieces then return textures end
    edge = edge or ZONE_EDGE
    local sx, sy = (x2 - x1) / W, (y2 - y1) / H
    local ex, ey = edge * W, edge * H
    local xs = edge > 0 and { 0, ex, W - ex, W } or { 0, W }
    local ys = edge > 0 and { 0, ey, H - ey, H } or { 0, H }
    local faded = edge > 0
    -- Opacity at art position p along a side of length size.
    local function FadeAt(p, e, size)
        return math.max(0, math.min(1, p / e, (size - p) / e))
    end
    for _, p in ipairs(pieces) do
        local du, dv = p[2] / (p[6] - p[4]), p[3] / (p[7] - p[5])
        for i = 1, #xs - 1 do
            for j = 1, #ys - 1 do
                local cx1, cx2 = math.max(p[4], xs[i]), math.min(p[6], xs[i + 1])
                local cy1, cy2 = math.max(p[5], ys[j]), math.min(p[7], ys[j + 1])
                local corner = faded and i ~= 2 and j ~= 2
                if cx2 > cx1 and cy2 > cy1 and not corner then
                    local tex = parent:CreateTexture(nil, "BACKGROUND", nil, sublevel + (p[8] and 1 or 0))
                    tex:SetTexture(p[1])
                    tex:SetTexCoord((cx1 - p[4]) * du, (cx2 - p[4]) * du, (cy1 - p[5]) * dv, (cy2 - p[5]) * dv)
                    tex:SetPoint("TOPLEFT", parent, "TOPLEFT", x1 + cx1 * sx, -(y1 + cy1 * sy))
                    tex:SetPoint("BOTTOMRIGHT", parent, "TOPLEFT", x1 + cx2 * sx, -(y1 + cy2 * sy))
                    if faded and i ~= 2 then
                        SetAlphaGradient(tex, "HORIZONTAL", FadeAt(cx1, ex, W), FadeAt(cx2, ex, W))
                    elseif faded and j ~= 2 then
                        -- VERTICAL runs bottom to top.
                        SetAlphaGradient(tex, "VERTICAL", FadeAt(cy2, ey, H), FadeAt(cy1, ey, H))
                    end
                    for _, mask in ipairs(masks or {}) do
                        tex:AddMaskTexture(mask)
                    end
                    textures[#textures + 1] = tex
                end
            end
        end
    end
    return textures
end
ns.AddZoneArt = AddZoneArt


-- Zone outlines -----------------------------------------------------------------
-- The world map lights up the zone under the cursor with a highlight texture
-- in the zone's shape. Used as a mask, that shape trims a zone's art to the
-- zone, so the land each zone's art paints around it is cut away and
-- neighbouring zones can show side by side. Its soft edge blends into the
-- continent. The highlight files hold the shape in colour only, which masks
-- ignore, so the addon ships each as an alpha mask (ZoneMasks\<uiMapID>.tga,
-- made by scripts/zone-overlays.py) and takes only the placement from the game.

local MASK_PATH = "Interface\\AddOns\\" .. addonName .. "\\ZoneMasks\\"

-- Points inside a zone's rectangle, as fractions of it, centre first.
local OUTLINE_PROBES = {}
for _, a in ipairs({ 0.5, 0.35, 0.65, 0.2, 0.8 }) do
    for _, b in ipairs({ 0.5, 0.35, 0.65, 0.2, 0.8 }) do
        OUTLINE_PROBES[#OUTLINE_PROBES + 1] = { a, b }
    end
end

-- The zone at u, v on a continent map, climbing from dungeons and micro maps.
local function ZoneAtPosition(continentMap, u, v)
    local info = C_Map.GetMapInfoAtPosition(continentMap, u, v)
    while info and info.mapType > Enum.UIMapType.Zone do
        info = C_Map.GetMapInfo(info.parentMapID)
    end
    return info and info.mapID
end

-- The highlight file of a zone and where the zone's shipped mask lies on
-- the continent map: fileID, u1, v1, u2, v2 (the whole highlight file plus
-- the mask's empty border), or nil, also for zones without a shipped mask.
-- zx1, zx2, zy1, zy2 is the zone's rectangle on the continent.
local function ZoneOutline(continentMap, zoneMap, zx1, zx2, zy1, zy2)
    if not (ns.ZoneMasks and ns.ZoneMasks[zoneMap]) then return end
    if not (C_Map.GetMapHighlightInfoAtPosition and C_Map.GetMapInfoAtPosition) then return end
    for _, f in ipairs(OUTLINE_PROBES) do
        local u, v = zx1 + (zx2 - zx1) * f[1], zy1 + (zy2 - zy1) * f[2]
        if ZoneAtPosition(continentMap, u, v) == zoneMap then
            local fileID, _, usedX, usedY, w, h, left, top = C_Map.GetMapHighlightInfoAtPosition(continentMap, u, v)
            if fileID and fileID > 0 and usedX > 0 and usedY > 0 and w > 0 and h > 0 then
                -- Out to the empty border the shipped mask adds around the file.
                local pad = ns.ZoneMaskPad or 0
                local px, py = w / usedX * pad, h / usedY * pad
                return fileID, left - px, top - py, left + w / usedX + px, top + h / usedY + py
            end
            return
        end
    end
end
ns.ZoneOutline = ZoneOutline

-- A mask on parent in the shape of zone uiMap, covering content x1, y1 - x2, y2
-- (where ZoneOutline places it).
local function OutlineMask(parent, uiMap, x1, y1, x2, y2)
    local mask = parent:CreateMaskTexture()
    mask:SetTexture(MASK_PATH .. uiMap, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetPoint("TOPLEFT", parent, "TOPLEFT", x1, -y1)
    mask:SetPoint("BOTTOMRIGHT", parent, "TOPLEFT", x2, -y2)
    return mask
end
ns.OutlineMask = OutlineMask

-- A mask on parent covering content x1, y1 - x2, y2: solid, with a soft
-- border. Every zone map has a dark burnt edge, and some a torn parchment
-- frame, so where a zone's shape reaches the edge of its art, this fades
-- the art out before them instead of ending in a hard line.
local function EdgeMask(parent, x1, y1, x2, y2)
    local mask = parent:CreateMaskTexture()
    mask:SetTexture(MASK_PATH .. "edge", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetPoint("TOPLEFT", parent, "TOPLEFT", x1, -y1)
    mask:SetPoint("BOTTOMRIGHT", parent, "TOPLEFT", x2, -y2)
    return mask
end
ns.EdgeMask = EdgeMask

-- Zone view ---------------------------------------------------------------------
-- The journey map's zone art layer. Zones with an outline are trimmed to it
-- and all show at once. Under them each such zone's whole art is drawn too,
-- with a soft border, so land that belongs to no zone (mountains, coast,
-- the edges of cities) shows the zone art painted around it rather than the
-- far coarser continent art. Cities have no outline, and their own maps are
-- street plans, so a city shows the art of the zone around it instead,
-- trimmed to the city's rectangle and kept inside that zone's art, whose
-- edge has a burnt border; that zone's outline leaves the city out. A city
-- with a mask of where its plan has drawing (ns.CityMasks, every capital)
-- shows its plan cut to that, over the zone around it, host or not, unless
-- the city art option (ns.db.cityArt) is off. Under everything lies paper
-- over each continent, so land no zone map covers shows parchment grain
-- over the continent art below, which is far coarser than zone art.
-- Any other zone without an outline paints the land around it too, so only
-- the one under the middle of the view shows, with faded edges, and moving
-- to another cross-fades. Art is built the first time a zone is near the view.

local ZONE_SWITCH = 3   -- cross-fades per second
local ZONE_MARGIN = 0.25    -- zones this far outside the view (in views) are built too
local CITY_GROW = 0.15  -- a city's patch reaches this far (in city sizes) past its rectangle
local PAPER_ALPHA = 0.45
-- ZoneMasks\paper.tga covers 160 pixels of a 1002 pixel wide zone map, so
-- its grain matches zone art when it repeats every this much of a zone's width.
local PAPER_TILE = 160 / 1002
local PAPER_SUBLEVEL = -8

local ZoneView = {
    FADE = { 4, 6 },    -- zoom where the layer starts to fade in and is fully shown
    PLAN_FADE = { 9, 12 },  -- the same for the cities' street plans
    views = {},         -- every zone view made, for ns.RefreshCityArt
}
ZoneView.__index = ZoneView

function ns.CreateZoneView(layer)
    local view = setmetatable({
        layer = layer,
        continents = {},    -- { uiMapID, x1, y1, width, height } in content units
        -- uiMapID -> { x1, y1, x2, y2, alpha, textures, together = shown with
        -- others, outline = { fileID, x1, y1, x2, y2 } or host = uiMapID of
        -- the zone whose art covers this city }
        zones = {},
        active = nil,       -- uiMapID of the zone under the middle of the view, if any
        fading = false,     -- true while some zone art is still fading
    }, ZoneView)
    table.insert(ZoneView.views, view)
    return view
end

-- Registers a continent and its zones. Its map covers content x1, y1 by w, h.
function ZoneView:AddContinent(uiMap, x1, y1, w, h)
    table.insert(self.continents, { uiMap, x1, y1, w, h })
    local added = {}
    for _, zone in ipairs(C_Map.GetMapChildrenInfo(uiMap, Enum.UIMapType.Zone) or {}) do
        local zx1, zx2, zy1, zy2 = C_Map.GetMapRectOnMap(zone.mapID, uiMap)
        if zx1 and zx2 > zx1 and zy2 > zy1 then
            local entry = { x1 + zx1 * w, y1 + zy1 * h, x1 + zx2 * w, y1 + zy2 * h, alpha = 0 }
            local fileID, u1, v1, u2, v2 = ZoneOutline(uiMap, zone.mapID, zx1, zx2, zy1, zy2)
            if fileID then
                entry.outline = { fileID, x1 + u1 * w, y1 + v1 * h, x1 + u2 * w, y1 + v2 * h }
            end
            entry.together = entry.outline ~= nil
            self.zones[zone.mapID] = entry
            added[zone.mapID] = entry
        end
    end

    -- A city's host: of the outlined zones whose rectangle holds the city's
    -- middle, the one whose middle is nearest it.
    for cityID, city in pairs(added) do
        if not city.outline then
            local cx, cy = (city[1] + city[3]) / 2, (city[2] + city[4]) / 2
            local best
            for id, zone in pairs(added) do
                if zone.outline and cx >= zone[1] and cx <= zone[3] and cy >= zone[2] and cy <= zone[4] then
                    local d = ((zone[1] + zone[3]) / 2 - cx) ^ 2 + ((zone[2] + zone[4]) / 2 - cy) ^ 2
                    if not best or d < best then
                        city.host, best = id, d
                    end
                end
            end
            -- A city with a mask of its plan shows with the others even
            -- without a host, as its plan is cut to the city; with the city
            -- art option off, such a city shows nothing.
            city.together = city.host ~= nil or (ns.CityMasks and ns.CityMasks[cityID]) ~= nil
        end
    end

    -- Paper over the continent, its grain the size of the zone art: zone
    -- maps differ in scale, so the middle zone width is used.
    local widths = {}
    for _, zone in pairs(added) do
        if zone.outline then widths[#widths + 1] = zone[3] - zone[1] end
    end
    table.sort(widths)
    local tile = (widths[math.ceil(#widths / 2)] or w / 10) * PAPER_TILE
    local paper = self.layer:CreateTexture(nil, "BACKGROUND", nil, PAPER_SUBLEVEL)
    paper:SetTexture(MASK_PATH .. "paper", "REPEAT", "REPEAT", "TRILINEAR")
    paper:SetPoint("TOPLEFT", self.layer, "TOPLEFT", x1, -y1)
    paper:SetSize(w, h)
    paper:SetTexCoord(0, w / tile, 0, h / tile)
    paper:SetAlpha(PAPER_ALPHA)
end

-- The zone whose map covers content x, y, or nil.
function ZoneView:ZoneAt(x, y)
    if not C_Map.GetMapInfoAtPosition then return end
    for _, c in ipairs(self.continents) do
        local u, v = (x - c[2]) / c[4], (y - c[3]) / c[5]
        if u >= 0 and u <= 1 and v >= 0 and v <= 1 then
            local id = ZoneAtPosition(c[1], u, v)
            if id and self.zones[id] then return id end
        end
    end
end

-- Opacity of the cities' street plans for the zoom: they fade in only close
-- up, over the art of the zone around the city (see ZoneView:SetZoom).
ZoneView.planAlpha = 0

local function SetZoneAlpha(zone, alpha)
    zone.alpha = alpha
    for _, tex in ipairs(zone.textures or {}) do
        tex:SetAlpha(alpha)
        tex:SetShown(alpha > 0)
    end
    local plan = alpha * ZoneView.planAlpha
    for _, tex in ipairs(zone.plan or {}) do
        tex:SetAlpha(plan)
        tex:SetShown(plan > 0)
    end
end

-- Draw sublevel of the whole art under the zones trimmed to their outline.
local UNDER_SUBLEVEL = -2

-- Draw sublevel of a city's own street plan, above any zone's art.
local CITY_SUBLEVEL = 2

-- Builds a zone's art: zone.textures, and for a city with a mask of its
-- plan (unless the city art option is off) zone.plan, the plan cut to the
-- mask alone: the mask already leaves out the plan's burnt rim, and the
-- usual edge fade would cut into districts that reach the edge.
function ZoneView:Build(id, zone)
    local o = zone.outline
    local a = self.zones[id]
    zone.textures, zone.plan = {}, nil
    if o then
        local masks = { OutlineMask(self.layer, id, o[2], o[3], o[4], o[5]),
            EdgeMask(self.layer, zone[1], zone[2], zone[3], zone[4]) }
        zone.textures = AddZoneArt(self.layer, id, a[1], a[2], a[3], a[4], ZoneOverlays(id), 0, masks)
        for _, tex in ipairs(AddZoneArt(self.layer, id, a[1], a[2], a[3], a[4], ZoneOverlays(id), 0,
            { EdgeMask(self.layer, a[1], a[2], a[3], a[4]) }, UNDER_SUBLEVEL)) do
            zone.textures[#zone.textures + 1] = tex
        end
    elseif zone.host then
        local h = self.zones[zone.host]
        -- Grown past the city, but no further than the host's art reaches.
        local gx, gy = (zone[3] - zone[1]) * CITY_GROW, (zone[4] - zone[2]) * CITY_GROW
        local masks = { EdgeMask(self.layer, math.max(h[1], zone[1] - gx), math.max(h[2], zone[2] - gy),
            math.min(h[3], zone[3] + gx), math.min(h[4], zone[4] + gy)) }
        zone.textures = AddZoneArt(self.layer, zone.host, h[1], h[2], h[3], h[4], ZoneOverlays(zone.host), 0, masks)
    elseif not zone.together then
        zone.textures = AddZoneArt(self.layer, id, a[1], a[2], a[3], a[4], ZoneOverlays(id))
    end
    if not o and ns.db.cityArt and ns.CityMasks and ns.CityMasks[id] then
        local mask = self.layer:CreateMaskTexture()
        mask:SetTexture(MASK_PATH .. "city_" .. id, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetPoint("TOPLEFT", self.layer, "TOPLEFT", zone[1], -zone[2])
        mask:SetPoint("BOTTOMRIGHT", self.layer, "TOPLEFT", zone[3], -zone[4])
        zone.plan = AddZoneArt(self.layer, id, a[1], a[2], a[3], a[4], ZoneOverlays(id), 0, { mask }, CITY_SUBLEVEL)
    end
    SetZoneAlpha(zone, 0)
end

-- Sets the street plans' opacity for zoom z.
function ZoneView:SetZoom(z)
    local f = math.log(z / self.PLAN_FADE[1]) / math.log(self.PLAN_FADE[2] / self.PLAN_FADE[1])
    f = math.max(0, math.min(1, f))
    if f == ZoneView.planAlpha then return end
    ZoneView.planAlpha = f
    for _, zone in pairs(self.zones) do
        if zone.plan then SetZoneAlpha(zone, zone.alpha) end
    end
end

-- Moves the opacity of each zone shown alone towards shown for the
-- active zone and hidden for the rest, by elapsed seconds (math.huge to jump
-- straight there).
function ZoneView:Step(elapsed)
    local step, fading = elapsed * ZONE_SWITCH, false
    for id, zone in pairs(self.zones) do
        local target = id == self.active and 1 or 0
        if not zone.together and zone.alpha ~= target then
            SetZoneAlpha(zone, target > zone.alpha and math.min(target, zone.alpha + step)
                or math.max(target, zone.alpha - step))
            fading = fading or zone.alpha ~= target
        end
    end
    self.fading = fading
end

-- Shows the zones for a view of content x1, y1 - x2, y2: every zone shown
-- together near it, and the zone under its middle if shown alone. While the
-- layer is still nearly invisible a cross-fade is instant, so zooming in
-- shows the new zone without the old one.
function ZoneView:Update(x1, y1, x2, y2)
    local mx, my = (x2 - x1) * ZONE_MARGIN, (y2 - y1) * ZONE_MARGIN
    for id, zone in pairs(self.zones) do
        if zone.together then
            local near = zone[3] >= x1 - mx and zone[1] <= x2 + mx and zone[4] >= y1 - my and zone[2] <= y2 + my
            if near and not zone.textures then
                self:Build(id, zone)
            end
            if (near and 1 or 0) ~= zone.alpha then
                SetZoneAlpha(zone, near and 1 or 0)
            end
        end
    end

    local id = self:ZoneAt((x1 + x2) / 2, (y1 + y2) / 2)
    if id == self.active then return end
    self.active = id
    local zone = id and self.zones[id]
    if zone and not zone.together and not zone.textures then
        self:Build(id, zone)
    end
    if self.layer:GetAlpha() < 0.05 then
        self:Step(math.huge)
    else
        self.fading = true
    end
end

-- Builds every city again after the city art option changed. Textures
-- cannot be deleted, so the old ones are hidden.
function ns.RefreshCityArt()
    for _, view in ipairs(ZoneView.views) do
        for id, zone in pairs(view.zones) do
            if not zone.outline and zone.together and zone.textures then
                local alpha = zone.alpha
                SetZoneAlpha(zone, 0)
                view:Build(id, zone)
                SetZoneAlpha(zone, alpha)
            end
        end
    end
end
