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

-- /rts modelprobe: ways to show another character's body on a gear card,
-- which can only be a model of the player turned into another race and sex,
-- or a model from a display ID saved while that character played. Each
-- candidate wears the gear on now; the chat lists which APIs exist.

local modelProbe

local MODEL_PROBE_SLOTS = {
    "HeadSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot", "WristSlot",
    "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

local function ProbeDress(model)
    pcall(model.Undress, model)
    for _, name in ipairs(MODEL_PROBE_SLOTS) do
        local ok, slot = pcall(GetInventorySlotInfo, name)
        local id = ok and slot and GetInventoryItemID("player", slot)
        if id then pcall(model.TryOn, model, "item:" .. id) end
    end
end

-- Every function name a table or a widget's metatable has, sorted.
local function FunctionNames(t)
    local names = {}
    local index = getmetatable(t) and getmetatable(t).__index
    for _, source in ipairs({ t, type(index) == "table" and index or {} }) do
        for k, v in pairs(source) do
            if type(v) == "function" and type(k) == "string" then names[#names + 1] = k end
        end
    end
    table.sort(names)
    return table.concat(names, " ")
end

-- /rts modelprobe api: lists every method of the model widgets and model
-- scene actors, and every function of the model related namespaces, into
-- RoadToSixtyDB.modelApi, saved on /reload, for reading outside the game.
local function DumpModelApi()
    local api = {}
    for _, kind in ipairs({ "PlayerModel", "DressUpModel", "CinematicModel", "TabardModel", "ModelScene" }) do
        local ok, widget = pcall(CreateFrame, kind)
        api[kind] = ok and FunctionNames(widget) or ("not available: " .. tostring(widget))
        if ok and kind == "ModelScene" then
            local made, actor = pcall(widget.CreateActor, widget)
            api.ModelSceneActor = made and actor and FunctionNames(actor) or ("not available: " .. tostring(actor))
        end
    end
    for name, t in pairs(_G) do
        if type(name) == "string" and type(t) == "table" and name:match("^C_")
            and (name:match("Model") or name:match("Barber") or name:match("PlayerInfo")
                or name:match("Transmog") or name:match("Character") or name:match("Customiz")) then
            api[name] = FunctionNames(t)
        end
    end
    ns.db.modelApi = api
    local count = 0
    for _ in pairs(api) do count = count + 1 end
    ns.Print(("Model API: %d tables listed. Type /reload to save them."):format(count))
end

-- Round 2: a display ID model with the wardrobe's neutral skin, and model
-- scene actors. Each candidate is a cell { frame, label } in a new window.
local modelProbe2

local function ProbeScene(parent)
    local scene = CreateFrame("ModelScene", nil, parent)
    scene:SetCameraPosition(4, 0, 0.9)
    scene:SetCameraOrientationByYawPitchRoll(math.pi, 0, 0)
    scene:SetCameraFieldOfView(0.6)
    scene:SetLightVisible(true)
    scene:SetLightType(1)
    scene:SetLightDirection(-1, 0.3, -0.5)
    scene:SetLightAmbientColor(0.7, 0.7, 0.7)
    scene:SetLightDiffuseColor(0.8, 0.8, 0.8)
    local actor = scene:CreateActor()
    actor:SetPosition(0, 0, 0)
    actor:SetYaw(0)
    return scene, actor
end

local function ProbeActorDress(actor)
    pcall(actor.Undress, actor)
    for _, name in ipairs(MODEL_PROBE_SLOTS) do
        local ok, slot = pcall(GetInventorySlotInfo, name)
        local id = ok and slot and GetInventoryItemID("player", slot)
        if id then pcall(actor.TryOn, actor, "item:" .. id) end
    end
end

-- Readable copy of a value for the saved variables.
local function Plain(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return v end
    if depth > 4 then return "..." end
    local copy = {}
    for k, x in pairs(v) do
        if type(x) ~= "function" and type(x) ~= "userdata" then copy[k] = Plain(x, depth + 1) end
    end
    return copy
end

local function ModelProbe2()
    local displayID = C_PlayerInfo.GetDisplayID()
    local data = {}
    for _, call in ipairs({
        { "GetPlayerCharacterData", C_PlayerInfo.GetPlayerCharacterData },
        { "BarberGetCurrentCharacterData", C_BarberShop.GetCurrentCharacterData },
        { "BarberGetAvailableCustomizations", C_BarberShop.GetAvailableCustomizations },
        { "BarberGetViewingChrModel", C_BarberShop.GetViewingChrModel },
    }) do
        local ok, value = pcall(call[2])
        data[call[1]] = ok and Plain(value) or ("error: " .. tostring(value))
        Report(call[1], ok and value ~= nil, ok and type(value) or tostring(value))
    end
    ns.db.modelData = data

    if not modelProbe2 then
        local f = CreateFrame("Frame", "RoadToSixtyModelProbe2", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(5 * 170 + 30, 330)
        f:SetPoint("CENTER", 0, -40)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f.TitleText:SetText("Road to Sixty: model probe 2")
        modelProbe2 = f
    end
    local f = modelProbe2
    f:Show()
    local function Cell(i, frame, text)
        frame:SetParent(f)
        frame:SetSize(160, 260)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", 15 + (i - 1) * 170, -32)
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.12, 0.12, 0.15)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOP", frame, "BOTTOM", 0, -4)
        label:SetWidth(160)
        label:SetText(text)
    end

    -- C2: display ID with the wardrobe's neutral skin.
    local c2 = CreateFrame("DressUpModel")
    Cell(1, c2, "C2: SetDisplayInfo + TransmogSkin")
    c2:SetUseTransmogSkin(true)
    c2:SetDisplayInfo(displayID)
    C_Timer.After(0.5, function() ProbeDress(c2) end)

    -- C3: as C2, with transmog choices on and the skin set after loading.
    local c3 = CreateFrame("DressUpModel")
    Cell(2, c3, "C3: as C2, skin after load")
    c3:SetDisplayInfo(displayID)
    C_Timer.After(0.5, function()
        pcall(c3.SetUseTransmogChoices, c3, true)
        pcall(c3.SetUseTransmogSkin, c3, true)
        ProbeDress(c3)
    end)

    -- E: scene actor from the live unit, to prove the scene's camera works.
    local sceneE, actorE = ProbeScene(f)
    Cell(3, sceneE, "E: scene, SetModelByUnit (control)")
    local okE, errE = pcall(actorE.SetModelByUnit, actorE, "player", false, true)
    Report("E SetModelByUnit", okE, tostring(errE))

    -- F: the character select loader, character 1.
    local sceneF, actorF = ProbeScene(f)
    Cell(4, sceneF, "F: SetPlayerModelFromGlues(1)")
    local okF, errF = pcall(actorF.SetPlayerModelFromGlues, actorF, 1, false, true)
    Report("F SetPlayerModelFromGlues", okF, tostring(errF))

    -- G: scene actor from the display ID, dressed.
    local sceneG, actorG = ProbeScene(f)
    Cell(5, sceneG, "G: scene, CreatureDisplayID + skin")
    pcall(actorG.SetUseTransmogSkin, actorG, true)
    local okG, errG = pcall(actorG.SetModelByCreatureDisplayID, actorG, displayID)
    Report("G SetModelByCreatureDisplayID", okG, tostring(errG))
    C_Timer.After(0.5, function() ProbeActorDress(actorG) end)
    ns.Print("Model probe 2: type /reload afterwards to save the character data.")
end

-- Round 3: round 2's scene actors came out black, the live one too, so the
-- scene's light or fog was wrong. Each cell tries one setup.
local modelProbe3

local LIGHT_SETUPS = {
    { "1: fog cleared, no light set", fog = true },
    { "2: fog cleared, light type 0", fog = true, type = 0 },
    { "3: fog cleared, type 1 from front", fog = true, type = 1, dir = { -1, 0, -0.5 } },
    { "4: fog cleared, type 1 from behind", fog = true, type = 1, dir = { 1, 0, -0.5 } },
    { "5: setup 1, neutral skin off", fog = true, skin = false },
    { "6: setup 1, live unit (control)", fog = true, unit = true },
}

local function ModelProbe3()
    local enum = Enum and Enum.ModelLightType
    local types = {}
    for k, v in pairs(enum or {}) do types[#types + 1] = k .. "=" .. tostring(v) end
    ns.Print("Enum.ModelLightType: " .. (enum and table.concat(types, ", ") or "missing"))

    local displayID = C_PlayerInfo.GetDisplayID()
    if not modelProbe3 then
        local f = CreateFrame("Frame", "RoadToSixtyModelProbe3", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(#LIGHT_SETUPS * 150 + 30, 320)
        f:SetPoint("CENTER", 0, -40)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f.TitleText:SetText("Road to Sixty: model probe 3")
        modelProbe3 = f
    end
    local f = modelProbe3
    f:Show()
    for i, setup in ipairs(LIGHT_SETUPS) do
        local scene = CreateFrame("ModelScene", nil, f)
        scene:SetSize(140, 250)
        scene:SetPoint("TOPLEFT", 15 + (i - 1) * 150, -32)
        local bg = scene:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.12, 0.12, 0.15)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOP", scene, "BOTTOM", 0, -4)
        label:SetWidth(140)
        label:SetText(setup[1])

        scene:SetCameraPosition(4, 0, 0.9)
        scene:SetCameraOrientationByYawPitchRoll(math.pi, 0, 0)
        scene:SetCameraFieldOfView(0.6)
        if setup.fog then pcall(scene.ClearFog, scene) end
        if setup.type then
            scene:SetLightVisible(true)
            scene:SetLightType(setup.type)
            if setup.dir then scene:SetLightDirection(unpack(setup.dir)) end
            scene:SetLightPosition(4, 0, 2)
            scene:SetLightAmbientColor(1, 1, 1)
            scene:SetLightDiffuseColor(1, 1, 1)
        end
        local actor = scene:CreateActor()
        actor:SetPosition(0, 0, 0)
        if setup.unit then
            actor:SetModelByUnit("player", false, true)
        else
            if setup.skin ~= false then pcall(actor.SetUseTransmogSkin, actor, true) end
            actor:SetModelByCreatureDisplayID(displayID)
            C_Timer.After(0.5, function() ProbeActorDress(actor) end)
        end
    end
end

ns.Command("modelprobe", "test showing another race on the gear card model (developer)", function(arg)
    if arg == "api" then
        DumpModelApi()
        return
    elseif arg == "2" then
        ModelProbe2()
        return
    elseif arg == "3" then
        ModelProbe3()
        return
    end
    local _, race, raceID = UnitRace("player")
    local sex = UnitSex("player")
    -- A race and sex unlike the player's, so a working candidate stands out.
    local otherRace = raceID == 4 and 3 or 4
    local otherSex = sex == 3 and 0 or 1
    ns.Print(("Model probe: you are %s (raceID %s), UnitSex %s; candidates aim for raceID %d, sex %d.")
        :format(tostring(race), tostring(raceID), tostring(sex), otherRace, otherSex))

    local probe = CreateFrame("DressUpModel")
    for _, name in ipairs({ "SetCustomRace", "SetDisplayInfo", "SetUnit", "TryOn", "Undress",
        "SetModelByUnit", "SetCreature", "SetCustomCamera" }) do
        Report("DressUpModel:" .. name, probe[name] ~= nil)
    end
    local displayAPIs = {
        { "C_PlayerInfo.GetDisplayID", C_PlayerInfo and C_PlayerInfo.GetDisplayID },
        { "C_PlayerInfo.GetNativeDisplayID", C_PlayerInfo and C_PlayerInfo.GetNativeDisplayID },
    }
    local displayID
    for _, api in ipairs(displayAPIs) do
        local ok, value = false, nil
        if api[2] then ok, value = pcall(api[2]) end
        Report(api[1], api[2] ~= nil and ok and value ~= nil, tostring(value))
        displayID = displayID or (ok and value) or nil
    end
    Report("C_ModelInfo", C_ModelInfo ~= nil)
    Report("C_BarberShop", C_BarberShop ~= nil)

    if not modelProbe then
        modelProbe = CreateFrame("Frame", "RoadToSixtyModelProbe", UIParent, "BasicFrameTemplateWithInset")
        modelProbe:SetSize(4 * 170 + 30, 330)
        modelProbe:SetPoint("CENTER")
        modelProbe:SetMovable(true)
        modelProbe:EnableMouse(true)
        modelProbe:RegisterForDrag("LeftButton")
        modelProbe:SetScript("OnDragStart", modelProbe.StartMoving)
        modelProbe:SetScript("OnDragStop", modelProbe.StopMovingOrSizing)
        modelProbe.TitleText:SetText("Road to Sixty: model probe")
        modelProbe.cells = {}
        for i = 1, 4 do
            local cell = CreateFrame("DressUpModel", nil, modelProbe)
            cell:SetSize(160, 260)
            cell:SetPoint("TOPLEFT", 15 + (i - 1) * 170, -32)
            local bg = cell:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.12, 0.12, 0.15)
            cell.label = modelProbe:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cell.label:SetPoint("TOP", cell, "BOTTOM", 0, -4)
            cell.label:SetWidth(160)
            modelProbe.cells[i] = cell
        end
    end
    modelProbe:Show()
    local cells = modelProbe.cells

    -- A: the card's current way, race set straight after the unit.
    local a = cells[1]
    a.label:SetText("A: SetUnit + SetCustomRace now")
    a:SetUnit("player")
    local okA, errA = pcall(a.SetCustomRace, a, otherRace, otherSex)
    Report("A SetCustomRace now", okA, errA and tostring(errA))
    ProbeDress(a)

    -- B: race set once the model has loaded.
    local b = cells[2]
    b.label:SetText("B: SetCustomRace after 0.5 s")
    b:SetUnit("player")
    C_Timer.After(0.5, function()
        local ok, err = pcall(b.SetCustomRace, b, otherRace, otherSex)
        Report("B SetCustomRace after load", ok, err and tostring(err))
        ProbeDress(b)
    end)

    -- C: the player's own display ID, as it would be saved for each character.
    local c = cells[3]
    c.label:SetText("C: SetDisplayInfo(your display ID)")
    if displayID then
        local ok, err = pcall(c.SetDisplayInfo, c, displayID)
        Report("C SetDisplayInfo", ok, err and tostring(err))
        C_Timer.After(0.5, function() ProbeDress(c) end)
    else
        c:ClearModel()
        c.label:SetText("C: no display ID API")
    end

    -- D: for comparison, the player as the card shows it now.
    local d = cells[4]
    d.label:SetText("D: SetUnit only (control)")
    d:SetUnit("player")
    C_Timer.After(0.1, function() ProbeDress(d) end)
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
