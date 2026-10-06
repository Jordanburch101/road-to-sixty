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
