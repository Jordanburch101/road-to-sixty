local addonName, ns = ...

-- /rts probe reports which APIs this client provides, so the recorder and the
-- map UI are built on what the Forever client actually supports.

local function Report(label, ok, detail)
    local status = ok and "|cff00ff00OK|r" or "|cffff4040NO|r"
    ns.Print(("%s %s%s"):format(status, label, detail and (" - " .. detail) or ""))
end

local function FindContinent(mapID)
    while mapID and mapID > 0 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then return end
        if info.mapType == Enum.UIMapType.Continent then
            return mapID, info.name
        end
        mapID = info.parentMapID
    end
end

ns.Command("probe", "check which APIs this client supports", function()
    local _, build, _, interface = GetBuildInfo()
    ns.Print(("Probe on build %s, interface %d:"):format(build, interface))

    local mapID = C_Map and C_Map.GetBestMapForUnit("player")
    Report("C_Map.GetBestMapForUnit", mapID ~= nil, mapID and tostring(mapID))
    if not mapID then return end

    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    Report("C_Map.GetPlayerMapPosition", pos ~= nil,
        pos and ("%.4f, %.4f"):format(pos.x, pos.y))

    local continentID, world
    if pos then
        continentID, world = C_Map.GetWorldPosFromMapPos(mapID, pos)
    end
    Report("C_Map.GetWorldPosFromMapPos", world ~= nil,
        world and ("continent %d, %.1f, %.1f"):format(continentID, world.x, world.y))

    local uy, ux, _, uinstance = UnitPosition("player")
    Report("UnitPosition", uy ~= nil,
        uy and ("instance %d, %.1f, %.1f"):format(uinstance, ux, uy))

    local continentMap, continentName = FindContinent(mapID)
    Report("Continent map", continentMap ~= nil,
        continentMap and ("%s (%d)"):format(continentName, continentMap))

    if continentMap then
        local back
        if world then
            back = select(2, C_Map.GetMapPosFromWorldPos(continentID, world, continentMap))
        end
        Report("C_Map.GetMapPosFromWorldPos", back ~= nil,
            back and ("%.4f, %.4f on continent"):format(back.x, back.y))

        local layers = C_Map.GetMapArtLayers and C_Map.GetMapArtLayers(continentMap)
        local textures = C_Map.GetMapArtLayerTextures and C_Map.GetMapArtLayerTextures(continentMap, 1)
        Report("Continent map art", textures and #textures > 0,
            layers and layers[1] and ("%d tiles, %dx%d tile size"):format(
                textures and #textures or 0, layers[1].tileWidth, layers[1].tileHeight))
    end

    Report("Frame:CreateLine", UIParent.CreateLine ~= nil)
    Report("Kill counting (XP messages)", ns.killsTracked)
    Report("C_QuestLog.GetTitleForQuestID", C_QuestLog and C_QuestLog.GetTitleForQuestID ~= nil)
    Report("WorldMapFrame", WorldMapFrame ~= nil)
end)

-- /rts terrain: can addons load minimap terrain tiles by path on this client?
-- Tiles follow the ADT grid: 64x64 tiles of 533.33 yards, named mapCOL_ROW,
-- where columns run east and rows run south from world origin at 32, 32.

local TILE_YARDS = 533.33333
local terrainFrame

ns.Command("terrain", "test showing minimap terrain tiles around you", function()
    local c, x, y = ns.GetWorldPosition()
    if not c then
        ns.Print("No position available. Go outside and try again.")
        return
    end
    local dir = ns.MinimapDirs[c]
    if not dir then
        ns.Print(("No minimap folder known for continent %d."):format(c))
        return
    end

    local colF, rowF = 32 - y / TILE_YARDS, 32 - x / TILE_YARDS
    local col, row = math.floor(colF), math.floor(rowF)

    if not terrainFrame then
        terrainFrame = CreateFrame("Frame", "RoadToSixtyTerrainTest", UIParent, "BasicFrameTemplateWithInset")
        terrainFrame:SetSize(3 * 128 + 24, 3 * 128 + 40)
        terrainFrame:SetPoint("CENTER")
        terrainFrame:SetFrameStrata("HIGH")
        terrainFrame:SetMovable(true)
        terrainFrame:EnableMouse(true)
        terrainFrame:RegisterForDrag("LeftButton")
        terrainFrame:SetScript("OnDragStart", terrainFrame.StartMoving)
        terrainFrame:SetScript("OnDragStop", terrainFrame.StopMovingOrSizing)
        tinsert(UISpecialFrames, "RoadToSixtyTerrainTest")
        terrainFrame.tiles = {}
        for i = 0, 8 do
            local tile = terrainFrame:CreateTexture(nil, "ARTWORK")
            tile:SetSize(128, 128)
            tile:SetPoint("TOPLEFT", 12 + (i % 3) * 128, -28 - math.floor(i / 3) * 128)
            terrainFrame.tiles[i] = tile
        end
        terrainFrame.dot = terrainFrame:CreateTexture(nil, "OVERLAY")
        terrainFrame.dot:SetSize(6, 6)
        terrainFrame.dot:SetColorTexture(1, 0.2, 0.2)
    end

    -- Paths are blocked on Forever, so use file IDs from the community listfile.
    local ids = ns.MinimapTiles and ns.MinimapTiles[dir] or {}
    local known = 0
    for i = 0, 8 do
        local tc, tr = col - 1 + i % 3, row - 1 + math.floor(i / 3)
        local tile = terrainFrame.tiles[i]
        local fileID = ids[tc .. "_" .. tr]
        if fileID then
            known = known + 1
            tile:SetTexture(fileID)
        else
            tile:SetTexture(nil)
        end
    end

    terrainFrame.dot:ClearAllPoints()
    terrainFrame.dot:SetPoint("CENTER", terrainFrame.tiles[0], "TOPLEFT",
        (colF - col + 1) * 128, -(rowF - row + 1) * 128)
    terrainFrame:Show()

    ns.Print(("Tile map%d_%d in %s. %d of 9 tiles have a known file ID."):format(col, row, dir, known))
end)

-- /rts zoneprobe [mapID]: checks the zone art the journey map fades into.
-- Shows a zone (yours, or the map ID given) four ways:
--   1 the zone's shipped mask, in red, where the game places its outline
--   2 base art + every overlay from ZoneOverlays.lua (should be fully revealed)
--   3 the continent art cropped to the zone
--   4 panel 2 masked to the outline, over panel 3, as the journey map shows it

local ZONE_PANEL_W, ZONE_PANEL_H = 480, 320
local zoneFrame, zonePanels

local function CreateZoneFrame()
    zoneFrame = CreateFrame("Frame", "RoadToSixtyZoneProbe", UIParent, "BasicFrameTemplateWithInset")
    zoneFrame:SetSize(2 * (ZONE_PANEL_W + 10) + 18, 2 * (ZONE_PANEL_H + 26) + 40)
    zoneFrame:SetScale(math.min(1, UIParent:GetHeight() * 0.95 / (2 * (ZONE_PANEL_H + 26) + 40)))
    zoneFrame:SetPoint("CENTER")
    zoneFrame:SetFrameStrata("HIGH")
    zoneFrame:SetClampedToScreen(true)
    zoneFrame:SetMovable(true)
    zoneFrame:EnableMouse(true)
    zoneFrame:RegisterForDrag("LeftButton")
    zoneFrame:SetScript("OnDragStart", zoneFrame.StartMoving)
    zoneFrame:SetScript("OnDragStop", zoneFrame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "RoadToSixtyZoneProbe")
    zoneFrame.title = zoneFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    zoneFrame.title:SetPoint("TOP", 0, -5)
end

-- A clipped panel at grid position i (1-4) with a dark back and a label.
local function ZonePanel(parent, i, text)
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetSize(ZONE_PANEL_W, ZONE_PANEL_H)
    panel:SetPoint("TOPLEFT", 14 + col * (ZONE_PANEL_W + 10), -30 - row * (ZONE_PANEL_H + 26))
    panel:SetClipsChildren(true)
    local back = panel:CreateTexture(nil, "BACKGROUND", nil, -8)
    back:SetAllPoints()
    back:SetColorTexture(0.15, 0.15, 0.15)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOP", panel, "BOTTOM", 0, -4)
    label:SetText(text)
    return panel
end

local function ParentOfType(mapID, mapType)
    while mapID and mapID > 0 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then return end
        if info.mapType == mapType then return mapID end
        mapID = info.parentMapID
    end
end

ns.Command("zoneprobe", "test fading the journey map into zone map art (/rts zoneprobe [mapID])", function(arg)
    local zone = tonumber(arg) or ParentOfType(C_Map.GetBestMapForUnit("player"), Enum.UIMapType.Zone)
    local info = zone and C_Map.GetMapInfo(zone)
    if not (zone and info) then
        ns.Print("No zone found. Stand in a zone or give a map ID, e.g. /rts zoneprobe 1436 (Westfall).")
        return
    end
    local continent = ParentOfType(info.parentMapID, Enum.UIMapType.Continent)
    local layer = (C_Map.GetMapArtLayers(zone) or {})[1]
    local textures = C_Map.GetMapArtLayerTextures(zone, 1)
    ns.Print(("Zone %s (%d), continent %s."):format(info.name, zone, tostring(continent)))
    ns.Print(layer and ("Zone art %dx%d in %d tiles of %dx%d."):format(layer.layerWidth, layer.layerHeight,
        textures and #textures or 0, layer.tileWidth, layer.tileHeight) or "No zone art layer.")

    if not zoneFrame then CreateZoneFrame() end
    if zonePanels then zonePanels:Hide() end
    zonePanels = CreateFrame("Frame", nil, zoneFrame)
    zonePanels:SetAllPoints()
    zoneFrame.title:SetText(("Zone art test: %s (%d)"):format(info.name, zone))
    local W, H = ZONE_PANEL_W, ZONE_PANEL_H

    local explored, all = ns.ZoneOverlays(zone, true), ns.ZoneOverlayData[zone]
    ns.Print(("%d explored overlays, %s in the shipped data."):format(#explored,
        all and tostring(#all) or "none"))

    local minX, maxX, minY, maxY
    if continent then
        minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(zone, continent)
    end
    local outlinePanel = ZonePanel(zonePanels, 1, "1  Zone outline over continent art")
    ns.AddZoneArt(ZonePanel(zonePanels, 2, "2  All overlays (shipped data)"), zone, 0, 0, W, H, all or explored, 0)
    local cropped = ZonePanel(zonePanels, 3, "3  Continent art cropped to zone")
    local masked = ZonePanel(zonePanels, 4, "4  Panel 2 masked to the outline, over panel 3")
    if not (continent and minX and maxX > minX and maxY > minY) then
        ns.Print("No zone rectangle on the continent (C_Map.GetMapRectOnMap).")
        zoneFrame:Show()
        return
    end

    -- Whole continent sized so the zone's rectangle fills the panel.
    local cw, ch = W / (maxX - minX), H / (maxY - minY)
    for _, panel in ipairs({ outlinePanel, cropped, masked }) do
        ns.AddMapArt(panel, continent, -minX * cw, -minY * ch, (1 - minX) * cw, (1 - minY) * ch)
    end
    local clayer = (C_Map.GetMapArtLayers(continent) or {})[1]
    if clayer then
        local pw, ph = (maxX - minX) * clayer.layerWidth, (maxY - minY) * clayer.layerHeight
        ns.Print(("Zone covers %.0fx%.0f continent pixels (aspect %.3f; zone art aspect %.3f). Zone art is %.1fx sharper."):format(
            pw, ph, pw / ph, layer and layer.layerWidth / layer.layerHeight or 0,
            layer and layer.layerWidth / pw or 0))
    end

    local fileID, u1, v1, u2, v2 = ns.ZoneOutline(continent, zone, minX, maxX, minY, maxY)
    local top = CreateFrame("Frame", nil, masked)
    top:SetAllPoints()
    top:SetFrameLevel(masked:GetFrameLevel() + 1)
    if fileID then
        ns.Print(("Outline file %d covers continent %.3f, %.3f to %.3f, %.3f."):format(fileID, u1, v1, u2, v2))
        local ox1, oy1, ox2, oy2 = (u1 - minX) * cw, (v1 - minY) * ch, (u2 - minX) * cw, (v2 - minY) * ch
        local shape = outlinePanel:CreateTexture(nil, "ARTWORK")
        shape:SetTexture("Interface\\AddOns\\" .. addonName .. "\\ZoneMasks\\" .. zone)
        shape:SetPoint("TOPLEFT", ox1, -oy1)
        shape:SetPoint("BOTTOMRIGHT", outlinePanel, "TOPLEFT", ox2, -oy2)
        shape:SetVertexColor(1, 0.2, 0.2, 0.6)
        local mask = ns.OutlineMask(top, zone, ox1, oy1, ox2, oy2)
        ns.AddZoneArt(top, zone, 0, 0, W, H, all or explored, 0, { mask, ns.EdgeMask(top, 0, 0, W, H) })
    else
        ns.Print("No zone outline (C_Map.GetMapHighlightInfoAtPosition); the map uses faded edges instead.")
        ns.AddZoneArt(top, zone, 0, 0, W, H, all or explored)
    end

    zoneFrame:Show()
end)

-- /rts levelart: lists the player frame textures under the level number, to
-- find the art behind the level badge. Some frames (health bars) have secret
-- rects that addons may not compare; those are skipped.
local function Contains(region, x, y)
    local left, bottom, w, h = region:GetRect()
    return left and x >= left and x <= left + w and y >= bottom and y <= bottom + h
end

local function ListTexturesAt(frame, x, y, found)
    for _, region in ipairs({ frame:GetRegions() }) do
        if region:IsObjectType("Texture") and region:IsShown() then
            local ok, inside = pcall(Contains, region, x, y)
            if ok and inside then
                local _, _, w, h = region:GetRect()
                found[#found + 1] = ("%s  %dx%d"):format(
                    region:GetAtlas() or tostring(region:GetTexture()), w, h)
            end
        end
    end
    for _, child in ipairs({ frame:GetChildren() }) do
        ListTexturesAt(child, x, y, found)
    end
    return found
end

ns.Command("levelart", "list the player frame art under the level number", function()
    local text = PlayerLevelText
    if not (PlayerFrame and text) then
        ns.Print("No player frame level text found.")
        return
    end
    local x, y = text:GetCenter()
    local found = ListTexturesAt(PlayerFrame, x, y, {})
    ns.Print(("%d textures under the level number:"):format(#found))
    for _, line in ipairs(found) do
        ns.Print("  " .. line)
    end
end)

-- /rts shots: can an addon show screenshots? Switches screenshots to TGA (the
-- only screenshot format a texture could load), takes one, then shows it from
-- several paths into the Screenshots folder; a picture means that path works.
-- The last cell tries shots\test.tga in this addon's folder, to learn whether
-- an image added while the game runs loads without a restart.

local SHOT_W, SHOT_H = 192, 108
local SHOT_BASES = { "Screenshots\\", "..\\Screenshots\\", "Interface\\..\\Screenshots\\",
    "Interface\\AddOns\\..\\..\\Screenshots\\" }
local shotFrame, shotWaiting

local function CreateShotFrame()
    shotFrame = CreateFrame("Frame", "RoadToSixtyShotTest", UIParent, "BasicFrameTemplateWithInset")
    shotFrame:SetSize(3 * (SHOT_W + 10) + 18, 3 * (SHOT_H + 34) + 34)
    shotFrame:SetPoint("CENTER")
    shotFrame:SetFrameStrata("HIGH")
    shotFrame:SetMovable(true)
    shotFrame:EnableMouse(true)
    shotFrame:RegisterForDrag("LeftButton")
    shotFrame:SetScript("OnDragStart", shotFrame.StartMoving)
    shotFrame:SetScript("OnDragStop", shotFrame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "RoadToSixtyShotTest")
    local title = shotFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Screenshot test: a picture means that path loads")
    shotFrame.cells = {}
    for i = 1, 9 do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local back = shotFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
        back:SetSize(SHOT_W, SHOT_H)
        back:SetPoint("TOPLEFT", 14 + col * (SHOT_W + 10), -32 - row * (SHOT_H + 34))
        back:SetColorTexture(0.15, 0.15, 0.15)
        local tex = shotFrame:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(back)
        local label = shotFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOP", back, "BOTTOM", 0, -3)
        label:SetWidth(SHOT_W)
        shotFrame.cells[i] = { tex = tex, label = label }
    end
end

-- t: when the screenshot was taken. Its file name has the time to the second,
-- so both t and the second before are tried.
local function ShowShots(t)
    if not shotFrame then CreateShotFrame() end
    local paths = {}
    for _, at in ipairs({ t, t - 1 }) do
        local name = tostring(date("WoWScrnShot_%m%d%y_%H%M%S", at))
        for _, base in ipairs(SHOT_BASES) do
            paths[#paths + 1] = base .. name .. ".tga"
        end
    end
    paths[#paths + 1] = "Interface\\AddOns\\" .. addonName .. "\\shots\\test.tga"
    for i, cell in ipairs(shotFrame.cells) do
        local path = paths[i]
        cell.tex:SetTexture(nil)
        local ok = cell.tex:SetTexture(path)
        cell.label:SetText(path:gsub("WoWScrnShot_", ""))
        ns.Print(("%s  SetTexture returned %s"):format(path, tostring(ok)))
    end
    shotFrame:Show()
end

ns.Command("shots", "test whether screenshots can be shown in game", function()
    local format = GetCVar("screenshotFormat")
    if format ~= "tga" then
        SetCVar("screenshotFormat", "tga")
        ns.Print(("Screenshot format was %s, now tga. Type /console screenshotFormat %s to change it back.")
            :format(tostring(format), tostring(format)))
    end
    shotWaiting = true
    if not pcall(Screenshot) then
        ns.Print("Could not take a screenshot from the addon. Press Print Screen.")
    end
end)

ns.On("SCREENSHOT_SUCCEEDED", function()
    if not shotWaiting then return end
    shotWaiting = false
    local t = time()
    -- Give the client a moment to finish writing the file.
    C_Timer.After(1, function() ShowShots(t) end)
end)

-- /rts survey: collects game facts for building realistic seed data, into
-- RoadToSixtyDB.survey (saved on /reload) as "|"-separated strings:
--   items       id|name|quality|minLevel|equipLoc|subType for warrior gear
--               (mail, shields, weapons, cloaks, rings, necks, trinkets) up to
--               SURVEY_MAX_LEVEL
--   entrances   name|mapID|mapX|mapY|continent|worldX|worldY, dungeon
--               entrances, if the client offers them
--   taxi        the same for flight masters on both continents

local SURVEY_MAX_ID = 25000
local SURVEY_MAX_LEVEL = 32
local SURVEY_BATCH = 100            -- item loads asked for per tick
local SURVEY_TIMEOUT = 90           -- seconds to wait for item data
local SURVEY_CONTINENTS = { 1414, 1415 }
local SURVEY_ZONES = { 1414, 1415, 1436, 1453, 1440, 1426, 1421, 1413, 1454, 1437, 1431, 1433, 1432 }

-- Warrior-usable gear worth listing: weapons except wands and fishing poles,
-- mail and shields, and slots any class wears.
local function SurveyWanted(classID, subClassID, equipLoc)
    if not equipLoc or equipLoc == "" then return false end
    if classID == 2 then return subClassID ~= 19 and subClassID ~= 20 end
    if classID == 4 then
        return subClassID == 3 or subClassID == 6 or equipLoc == "INVTYPE_CLOAK"
            or equipLoc == "INVTYPE_NECK" or equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_TRINKET"
    end
    return false
end

-- "name|mapID|mapX|mapY|continent|worldX|worldY" for a map position.
local function SurveyPlace(name, mapID, position)
    local x, y = position.x or position[1], position.y or position[2]
    local c, world = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
    return ("%s|%d|%.4f|%.4f|%s|%s|%s"):format(name, mapID, x, y, tostring(c),
        world and ("%.0f"):format(world.x) or "", world and ("%.0f"):format(world.y) or "")
end

local function SurveyPlaces(survey)
    local ej = C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap
    local seen = {}
    for _, mapID in ipairs(SURVEY_ZONES) do
        local ok, list = pcall(ej or error, mapID)
        for _, e in ipairs(ok and list or {}) do
            if e.position and not seen[e.name] then
                seen[e.name] = true
                table.insert(survey.entrances, SurveyPlace(e.name, mapID, e.position))
            end
        end
    end
    local taxi = C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap
    for _, mapID in ipairs(SURVEY_CONTINENTS) do
        local ok, list = pcall(taxi or error, mapID)
        for _, node in ipairs(ok and list or {}) do
            if node.position then
                table.insert(survey.taxi, SurveyPlace(node.name, mapID, node.position))
            end
        end
    end
    ns.Print(("Survey: %d dungeon entrances (%s), %d flight masters (%s)."):format(
        #survey.entrances, ej and "API found" or "no API", #survey.taxi, taxi and "API found" or "no API"))
end

local function SurveyItems(survey)
    ---@diagnostic disable-next-line: deprecated
    local instant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    ---@diagnostic disable-next-line: deprecated
    local info = C_Item and C_Item.GetItemInfo or GetItemInfo
    local exists = C_Item and C_Item.DoesItemExistByID
    local candidates = {}
    for id = 1, SURVEY_MAX_ID do
        local _, _, _, equipLoc, _, classID, subClassID = instant(id)
        if equipLoc and SurveyWanted(classID, subClassID, equipLoc) and (not exists or exists(id)) then
            candidates[#candidates + 1] = id
        end
    end
    ns.Print(("Survey: loading %d items, this takes a minute..."):format(#candidates))

    local loaded, nextIndex, finished = 0, 1, false
    local started = GetTime()
    local function Record(id)
        local name, _, quality, _, minLevel, _, subType, _, equipLoc = info(id)
        if name and minLevel and minLevel <= SURVEY_MAX_LEVEL then
            table.insert(survey.items, ("%d|%s|%d|%d|%s|%s"):format(id, name, quality or 0, minLevel, equipLoc or "", subType or ""))
        end
    end
    local ticker
    local function Finish()
        if finished then return end
        finished = true
        ticker:Cancel()
        survey.items = {}
        for _, id in ipairs(candidates) do
            Record(id)
        end
        table.sort(survey.items)
        ns.Print(("Survey done: %d items up to level %d (%d of %d loaded). Type /reload to save it."):format(
            #survey.items, SURVEY_MAX_LEVEL, loaded, #candidates))
    end
    ticker = C_Timer.NewTicker(0.1, function()
        for _ = 1, SURVEY_BATCH do
            local id = candidates[nextIndex]
            if not id then break end
            nextIndex = nextIndex + 1
            Item:CreateFromItemID(id):ContinueOnItemLoad(function()
                loaded = loaded + 1
                if loaded == #candidates then Finish() end
            end)
        end
        if GetTime() - started > SURVEY_TIMEOUT then Finish() end
    end)
end

-- /rts itemcheck: loads a fixed list of item IDs (expected dungeon drops and
-- quest rewards) and saves what each really is into RoadToSixtyDB.itemcheck:
-- id|name|quality|minLevel|equipLoc|subType, or id|missing.
local ITEMCHECK_IDS = {
    -- start
    38, 39, 40, 45, 25, 2362, 2504, 6125, 6126, 6127,
    -- Deadmines
    5191, 7230, 5193, 5192, 5196, 5197, 5198, 5199, 5200, 5201, 5202, 872, 1937, 1156, 2169, 1951, 10399,
    -- Stockade
    2941, 2942, 3228, 1076, 2943, 3400,
    -- Blackfathom Deeps
    6901, 6902, 6903, 6904, 6905, 6906, 6907, 6908, 6909, 6910, 6911, 888, 1486, 3416, 3413, 2567,
    3417, 1454, 1481, 3414, 2271, 6898, 7003, 7001,
    -- quest rewards along the human route
    6087, 6086, 2042, 2374, 2955, 6084, 6085, 1893, 2091, 4977, 6070, 6092, 6093,
}

ns.Command("itemcheck", "check what a list of item IDs really are (developer)", function()
    ---@diagnostic disable-next-line: deprecated
    local info = C_Item and C_Item.GetItemInfo or GetItemInfo
    local exists = C_Item and C_Item.DoesItemExistByID
    for _, id in ipairs(ITEMCHECK_IDS) do
        if not exists or exists(id) then
            Item:CreateFromItemID(id):ContinueOnItemLoad(function() end)
        end
    end
    ns.Print("Checking " .. #ITEMCHECK_IDS .. " items...")
    C_Timer.After(10, function()
        local out = {}
        for _, id in ipairs(ITEMCHECK_IDS) do
            local name, _, quality, _, minLevel, _, subType, _, equipLoc = info(id)
            out[#out + 1] = name and ("%d|%s|%d|%d|%s|%s"):format(id, name, quality or 0, minLevel or 0,
                equipLoc or "", subType or "") or (id .. "|missing")
        end
        ns.db.itemcheck = out
        ns.Print("Item check done. Type /reload to save it.")
    end)
end)

ns.Command("survey", "collect item, dungeon and flight data for the seeds (developer)", function()
    local survey = { when = time(), build = select(2, GetBuildInfo()), items = {}, entrances = {}, taxi = {} }
    ns.db.survey = survey
    SurveyPlaces(survey)
    SurveyItems(survey)
end)
