local _, ns = ...

-- /rts portraitprobe [npcID]: draws a creature from its NPC ID every way the
-- client might allow, to see which works on Forever for rare portraits
-- (issue #6): a 3D model by SetCreature on each model frame type, zoomed to
-- the head, next to the live 2D portrait of the target (which cannot be
-- saved, so only for comparison). The NPC ID is the one given, else the
-- target's, else the latest rare recorded.

local SIZE = 96
local GAP = 12
local KINDS = { "PlayerModel", "DressUpModel", "CinematicModel" }

local frame

local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function TargetNpc()
    local ok, guid = pcall(UnitGUID, "target")
    if not ok or Secret(guid) then return end
    return tonumber(tostring(guid or ""):match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
end

local function LastRareNpc()
    local events = ns.char.events
    for i = #events, 1, -1 do
        local e = events[i]
        if e[2] == "rare" and e[9] then return e[9], e[6] end
    end
end

-- A labelled square in the window, at column i.
local function Cell(i, label)
    local cell = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    cell:SetSize(SIZE, SIZE)
    cell:SetPoint("TOPLEFT", 16 + (i - 1) * (SIZE + GAP), -40)
    cell:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    cell:SetBackdropColor(0.08, 0.08, 0.1, 1)
    cell.label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.label:SetPoint("TOP", cell, "BOTTOM", 0, -4)
    cell.label:SetWidth(SIZE + GAP)
    cell.label:SetText(label)
    return cell
end

local function Build()
    frame = CreateFrame("Frame", "RoadToSixtyPortraitProbe", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(16 * 2 + 4 * SIZE + 3 * GAP, SIZE + 90)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.cells = {}
    for i, kind in ipairs(KINDS) do
        local cell = Cell(i, ("%s. %s"):format(string.char(64 + i), kind))
        local ok, model = pcall(CreateFrame, kind, nil, cell)
        if ok and model then
            model:SetPoint("TOPLEFT", 3, -3)
            model:SetPoint("BOTTOMRIGHT", -3, 3)
            cell.model = model
        end
        frame.cells[i] = cell
    end
    local live = Cell(#KINDS + 1, "D. live target 2D")
    live.tex = live:CreateTexture(nil, "ARTWORK")
    live.tex:SetPoint("TOPLEFT", 3, -3)
    live.tex:SetPoint("BOTTOMRIGHT", -3, 3)
    frame.live = live
end

local function Show(npc, name)
    if not frame then Build() end
    frame.title:SetText(("NPC %d%s"):format(npc, name and (" - " .. name) or ""))
    local report = {}
    for i, cell in ipairs(frame.cells) do
        local model, result = cell.model, nil
        if not model then
            result = "frame type missing"
        elseif not model.SetCreature then
            result = "no SetCreature"
        else
            model:ClearModel()
            local ok, err = pcall(model.SetCreature, model, npc)
            if ok then
                pcall(model.SetPortraitZoom, model, 1)
                pcall(model.SetCamDistanceScale, model, 1)
                result = "SetCreature ok"
            else
                result = "error: " .. tostring(err)
            end
        end
        report[#report + 1] = ("%s %s"):format(string.char(64 + i), result)
    end
    if UnitExists("target") then
        SetPortraitTexture(frame.live.tex, "target")
        report[#report + 1] = "D live portrait set"
    else
        frame.live.tex:SetTexture(nil)
        report[#report + 1] = "D no target"
    end
    frame:Show()
    ns.Print(("Portrait probe for NPC %d: %s. A model may need a moment, or the creature seen first."):format(
        npc, table.concat(report, ", ")))
end

ns.Command("portraitprobe", "draw a creature from its NPC ID every way the client allows (developer)", function(arg)
    local npc, name = tonumber(arg), nil
    if not npc then npc = TargetNpc() end
    if not npc then npc, name = LastRareNpc() end
    if not npc then
        ns.Print("Give an NPC ID (/rts portraitprobe 30), target a mob in the open world, or record a rare first.")
        return
    end
    Show(npc, name)
end)
