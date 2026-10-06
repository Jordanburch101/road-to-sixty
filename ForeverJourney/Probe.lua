local _, ns = ...

-- /fm probe reports which APIs this client provides, so the recorder and the
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

-- /fm terrain: can addons load minimap terrain tiles by path on this client?
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
        terrainFrame = CreateFrame("Frame", "ForeverModTerrainTest", UIParent, "BasicFrameTemplateWithInset")
        terrainFrame:SetSize(3 * 128 + 24, 3 * 128 + 40)
        terrainFrame:SetPoint("CENTER")
        terrainFrame:SetFrameStrata("HIGH")
        terrainFrame:SetMovable(true)
        terrainFrame:EnableMouse(true)
        terrainFrame:RegisterForDrag("LeftButton")
        terrainFrame:SetScript("OnDragStart", terrainFrame.StartMoving)
        terrainFrame:SetScript("OnDragStop", terrainFrame.StopMovingOrSizing)
        tinsert(UISpecialFrames, "ForeverModTerrainTest")
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

-- /fm levelart: lists the player frame textures under the level number, to
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
