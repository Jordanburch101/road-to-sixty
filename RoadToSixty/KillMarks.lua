local addonName, ns = ...

-- Kill marks (issue #8): a faint stain on the journey map where each kill
-- happened, so one kill barely shows but an area ground for an hour stands
-- out. Kills have no position (see Journal.lua), so each is placed where the
-- path was at its time; kills inside instances are left out, or a dungeon's
-- would all pile up at its entrance. Kills are counted per cell of the map's
-- content coordinates and each cell draws one soft blob, overlapping its
-- neighbours, darker the more kills it holds. The marks follow the replay.

local KillMarks = {}
ns.KillMarks = KillMarks

local TEXTURE = "Interface\\AddOns\\" .. addonName .. "\\killmark"   -- soft round blob, white
-- Sizes in world yards, turned into content units with the map's scale. Kills
-- spread over a grinding area, so cells are wide enough to collect them and
-- blobs wider still, so neighbouring cells blend into one stain.
local CELL_YARDS, BLOB_YARDS = 35, 80
-- Zoom where the marks start to fade in and are fully shown, around where
-- quest markers appear; further out they would only blur the map.
local ZOOM_FADE = { 4, 5.5 }
local cellSize, blobSize = 1, 1     -- in content units, set by Rebuild
local COLOR = { 0.75, 0.08, 0.05 }     -- darker reds vanish on brown and gold land
-- A cell's opacity for n kills: MAX_ALPHA * (1 - exp(-n * PER_KILL)), about
-- 0.15 for one kill, 0.36 for three, 0.55 for six, close to MAX_ALPHA by fifteen.
local MAX_ALPHA, PER_KILL = 0.75, 0.22

local layer
local kills = {}            -- { t, cell } in time order
local cells = {}            -- key -> { x, y, count, tex }
local shown = 0             -- kills[1..shown] are counted in their cells
local pool = {}

function KillMarks:Attach(parent)
    layer = parent
end

local function Draw(cell)
    local tex = cell.tex
    if cell.count == 0 then
        if tex then tex:Hide() end
        return
    end
    if not tex then
        tex = table.remove(pool) or layer:CreateTexture(nil, "ARTWORK")
        tex:SetSize(blobSize, blobSize)
        tex:ClearAllPoints()
        tex:SetPoint("CENTER", layer, "TOPLEFT", cell.x, -cell.y)
        cell.tex = tex
    end
    --@debug@
    if KillMarks.test then
        -- /rts killmarks test: solid squares, then the blob at full strength,
        -- to tell placement, the texture file and faintness apart.
        if KillMarks.test == "squares" then
            tex:SetColorTexture(1, 0, 0)
        else
            tex:SetTexture(TEXTURE)
            tex:SetVertexColor(1, 0, 0)
        end
        tex:SetAlpha(1)
        tex:Show()
        return
    end
    --@end-debug@
    tex:SetTexture(TEXTURE)
    tex:SetVertexColor(COLOR[1], COLOR[2], COLOR[3])
    tex:SetAlpha(MAX_ALPHA * (1 - math.exp(-cell.count * PER_KILL)))
    tex:Show()
end

-- Times between entering and leaving an instance: { from, to } pairs.
local function InstanceTimes()
    local spans, entered = {}, nil
    for _, e in ipairs(ns.char.events) do
        if e[2] == "in" then
            entered = entered or e[1]
        elseif e[2] == "out" and entered then
            spans[#spans + 1] = { entered, e[1] }
            entered = nil
        end
    end
    if entered then
        spans[#spans + 1] = { entered, math.huge }
    end
    return spans
end

-- Places every kill again, after the map has loaded the path.
function KillMarks:Rebuild()
    for _, cell in pairs(cells) do
        if cell.tex then
            cell.tex:Hide()
            pool[#pool + 1] = cell.tex
        end
    end
    wipe(kills)
    wipe(cells)
    shown = 0

    local perYard = ns.Map:ContentPerYard() or 0.025
    cellSize, blobSize = CELL_YARDS * perYard, BLOB_YARDS * perYard
    local spans, span = InstanceTimes(), 1
    KillMarks.skipped = 0
    for _, kill in ipairs(ns.Journal:Kills()) do
        local t = kill.t
        while spans[span] and spans[span][2] < t do
            span = span + 1
        end
        local x, y
        if not (spans[span] and t >= spans[span][1]) then
            x, y = ns.Map:PositionAt(t)
        end
        if x and y then
            local cx, cy = math.floor(x / cellSize), math.floor(y / cellSize)
            local key = cx .. "," .. cy
            if not cells[key] then
                cells[key] = { x = (cx + 0.5) * cellSize, y = (cy + 0.5) * cellSize, count = 0 }
            end
            kills[#kills + 1] = { t, cells[key] }
        else
            KillMarks.skipped = KillMarks.skipped + 1
        end
    end
end

--@debug@
-- /rts killmarks: how the kills were placed, to tell missing marks from faint ones.
ns.Command("killmarks", "report how kills are placed on the map; 'test' draws solid squares (developer)", function(arg)
    if arg == "test" then
        KillMarks.test = (KillMarks.test == nil and "squares") or (KillMarks.test == "squares" and "blobs") or nil
        for _, cell in pairs(cells) do
            Draw(cell)
        end
        ns.Print("Test: " .. (KillMarks.test == "squares" and "solid squares"
            or KillMarks.test == "blobs" and "blob texture at full strength" or "off"))
    end
    local count, busiest, drawn, top = 0, 0, 0, nil
    for _, cell in pairs(cells) do
        count = count + 1
        if cell.count > busiest then
            busiest, top = cell.count, cell
        end
        if cell.tex and cell.tex:IsShown() then drawn = drawn + 1 end
    end
    ns.Print(("Setting killMarks = %s."):format(tostring(ns.db.killMarks)))
    if top and top.tex then
        local tex = top.tex
        local w, h = tex:GetSize()
        local cx, cy = ns.Map:ContentToCanvas(top.x, top.y)
        ns.Print(("Busiest cell at content %.1f, %.1f (canvas %.0f, %.0f): size %.2f x %.2f, alpha %.2f, %s, texture %s."):format(
            top.x, top.y, cx or -1, cy or -1, w, h, tex:GetAlpha(),
            tex:IsVisible() and "visible" or "not visible", tostring(tex:GetTexture())))
    end
    ns.Print(("Kills recorded %d: placed %d, skipped %d (in instances or far from the path)."):format(
        #ns.Journal:Kills(), #kills, KillMarks.skipped or 0))
    ns.Print(("Cells %d, drawn now %d, busiest %d kills; replay counts %d kills. Layer %s."):format(
        count, drawn, busiest, shown, layer and (layer:IsVisible() and "visible" or "hidden") or "missing"))
    local perYard = ns.Map:ContentPerYard()
    ns.Print(("Scale: %s yards per content unit; cells %d yd, blobs %d yd."):format(
        perYard and ("%.1f"):format(1 / perYard) or "?", CELL_YARDS, BLOB_YARDS))
end)
--@end-debug@

-- Fades the marks with the map's zoom, on a log scale like the map's layers.
function KillMarks:SetZoom(zoom)
    if not layer then return end
    local f = math.log(zoom / ZOOM_FADE[1]) / math.log(ZOOM_FADE[2] / ZOOM_FADE[1])
    f = math.max(0, math.min(1, f))
    layer:SetAlpha(f)
    layer:SetShown(ns.db.killMarks and f > 0)
end

-- Counts the kills up to time now (the replay's) and redraws the cells
-- that changed.
function KillMarks:SetTime(now)
    if not layer then return end
    local changed = {}
    while shown < #kills and kills[shown + 1][1] <= now do
        shown = shown + 1
        local cell = kills[shown][2]
        cell.count = cell.count + 1
        changed[cell] = true
    end
    while shown > 0 and kills[shown][1] > now do
        local cell = kills[shown][2]
        cell.count = cell.count - 1
        changed[cell] = true
        shown = shown - 1
    end
    for cell in pairs(changed) do
        Draw(cell)
    end
end
