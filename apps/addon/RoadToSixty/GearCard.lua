local _, ns = ...

-- Gear cards: a character model wearing recorded gear, turning slowly, with
-- the item icons laid out as on the character sheet.
--   GearCard:Show(level, owner)   beside a tooltip: the gear on reaching a
--                                 level (ns.view.levels[level].gear)
--   GearCard:Dock(parent)         a card in the corner of the journey map that
--   GearCard:Follow(t)            follows the replay: the gear worn at time t,
--                                 from level snapshots plus "eq" events, with
--                                 a flash on each slot that changed

local GearCard = {}
ns.GearCard = GearCard

local ICON = 26
local GAP = 3
local MODEL_W = 150
local TITLE_H = 22             -- room for the title when there is no banner
local TURN_SPEED = 0.5          -- radians per second
local QUALITY_BORDER_MIN = 2    -- green and better get a coloured border
local FLASH_SECONDS = 0.9

-- Character sheet layout: left column, right column, weapons along the bottom.
local LEFT = { "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot", "WristSlot" }
local RIGHT = { "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot" }
local BOTTOM = { "MainHandSlot", "SecondaryHandSlot", "RangedSlot" }

-- Slots that show on the model.
local VISIBLE = {
    HeadSlot = true, ShoulderSlot = true, BackSlot = true, ChestSlot = true, ShirtSlot = true,
    TabardSlot = true, WristSlot = true, HandsSlot = true, WaistSlot = true, LegsSlot = true,
    FeetSlot = true, MainHandSlot = true, SecondaryHandSlot = true, RangedSlot = true,
}

-- Slot name -> inventory slot ID and empty slot texture, or nil if this client
-- has no such slot.
local function SlotInfo(name)
    local ok, id, texture = pcall(GetInventorySlotInfo, name)
    if ok and id then return id, texture end
end

local function ItemIcon(itemID)
    if C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(itemID)
    end
    ---@diagnostic disable-next-line: deprecated
    return select(5, GetItemInfoInstant(itemID))
end

local function ItemQuality(itemID)
    if C_Item and C_Item.GetItemQualityByID then
        return C_Item.GetItemQualityByID(itemID)
    end
    return select(3, GetItemInfo(itemID))
end

-- Card --------------------------------------------------------------------------

local Card = {}
Card.__index = Card

-- The card's look. header: the dialog title banner; slotFrame: inventory
-- button frames around the slots; raceBackground: the dressing room scene
-- for the player's race behind the model.
local STYLE = {
    backdrop = {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    },
    bgColor = { 1, 1, 1, 1 }, borderColor = { 1, 1, 1 },
    pad = 14, header = true, slotFrame = true, raceBackground = true,
}
local SLOT_FRAME = "Interface\\Buttons\\UI-Quickslot2"
local SLOT_FRAME_SCALE = 64 / 36    -- the frame art is 64 px around a 36 px icon
local HEADER = "Interface\\DialogFrame\\UI-DialogBox-Header"
local RACE_BACKGROUND = "Interface\\DressUpFrame\\DressUpBackground-"
local RACE_BACKGROUND_SHADE = 0.75

-- Item tooltip for a slot, or the slot's name when it is empty.
local function ShowSlotTooltip(button)
    local cell = button.cell
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if cell.itemID then
        if GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(cell.itemID)
        else
            GameTooltip:SetHyperlink("item:" .. cell.itemID)
        end
    else
        GameTooltip:SetText(_G[cell.name:upper()] or cell.name)
    end
    GameTooltip:Show()
end

-- The dressing room scene for the player's race over region: a modern atlas
-- if the client has one, else the classic top pieces (256 + 64 wide)
-- stretched over the whole height. The classic bottom pieces end in a dark
-- band that showed as a black bar under the model's feet.
local function RaceBackground(frame, region)
    local _, race = UnitRace("player")
    race = race or "Human"
    local atlas = "dressingroom-background-" .. race:lower()
    local pieces = {}
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        local tex = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
        tex:SetAllPoints(region)
        tex:SetAtlas(atlas)
        pieces[1] = tex
    else
        local w, h = region:GetWidth(), region:GetHeight()
        local cols = { 256 / 320, 64 / 320 }
        for i = 1, 2 do
            local tex = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
            tex:SetTexture(RACE_BACKGROUND .. race .. i)
            tex:SetSize(w * cols[i], h)
            tex:SetPoint("TOPLEFT", region, "TOPLEFT", (i - 1) * w * cols[1], 0)
            pieces[i] = tex
        end
    end
    for _, tex in ipairs(pieces) do
        tex:SetVertexColor(RACE_BACKGROUND_SHADE, RACE_BACKGROUND_SHADE, RACE_BACKGROUND_SHADE)
    end
    return pieces
end

-- interactive: slots show item tooltips on hover (not for the hover card,
-- whose owner would lose the mouse to it).
function Card:CreateCell(name, interactive)
    local id, empty = SlotInfo(name)
    if not id then return end
    local frame, style = self.frame, self.style
    local cell = { slot = id, empty = empty, name = name }
    local button = CreateFrame("Frame", nil, frame)
    button:SetSize(ICON, ICON)
    button.cell = cell
    if interactive then
        button:EnableMouse(true)
        button:SetScript("OnEnter", ShowSlotTooltip)
        button:SetScript("OnLeave", GameTooltip_Hide)
    end
    cell.button = button
    cell.icon = button:CreateTexture(nil, "ARTWORK")
    cell.icon:SetAllPoints()
    if style.slotFrame then
        local slotFrame = button:CreateTexture(nil, "OVERLAY")
        slotFrame:SetTexture(SLOT_FRAME)
        slotFrame:SetSize(ICON * SLOT_FRAME_SCALE, ICON * SLOT_FRAME_SCALE)
        slotFrame:SetPoint("CENTER")
    else
        local back = button:CreateTexture(nil, "BORDER")
        back:SetPoint("TOPLEFT", -1, 1)
        back:SetPoint("BOTTOMRIGHT", 1, -1)
        back:SetColorTexture(0, 0, 0, 0.8)
    end
    cell.border = button:CreateTexture(nil, "OVERLAY", nil, 1)
    cell.border:SetAllPoints(cell.icon)

    -- A gold flash when the slot's item changes during a replay.
    cell.flash = button:CreateTexture(nil, "OVERLAY", nil, 2)
    cell.flash:SetPoint("TOPLEFT", cell.icon, -3, 3)
    cell.flash:SetPoint("BOTTOMRIGHT", cell.icon, 3, -3)
    cell.flash:SetColorTexture(1, 0.8, 0.25, 0.7)
    cell.flash:SetBlendMode("ADD")
    cell.flash:SetAlpha(0)
    local fade = cell.flash:CreateAnimationGroup()
    local alpha = fade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetDuration(FLASH_SECONDS)
    alpha:SetSmoothing("OUT")
    cell.fade = fade

    self.cells[#self.cells + 1] = cell
    return cell
end

-- parent and strata: where the card lives; interactive: item tooltips on
-- the slots.
local function NewCard(parent, strata, interactive)
    local style = STYLE
    local self = setmetatable({ cells = {}, style = style }, Card)
    local pad = style.pad
    local titleH = style.header and 6 or TITLE_H
    local height = titleH + #LEFT * (ICON + GAP) + ICON + GAP + pad * 2
    local width = pad * 2 + ICON * 2 + GAP * 2 + MODEL_W
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    self.frame = frame
    frame:SetSize(width, height)
    frame:SetFrameStrata(strata)
    frame:SetBackdrop(style.backdrop)
    frame:SetBackdropColor(unpack(style.bgColor))
    frame:SetBackdropBorderColor(unpack(style.borderColor))
    frame:Hide()

    self.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if style.header then
        -- The dialog banner sits on the top edge, the title inside it.
        local header = frame:CreateTexture(nil, "ARTWORK")
        header:SetTexture(HEADER)
        header:SetSize(220, 56)
        header:SetPoint("TOP", 0, 14)
        self.title:SetPoint("TOP", header, "TOP", 0, -14)
    else
        self.title:SetPoint("TOP", 0, -pad)
    end

    local top = -(pad + titleH)
    for i, name in ipairs(LEFT) do
        local cell = self:CreateCell(name, interactive)
        if cell then cell.button:SetPoint("TOPLEFT", pad, top - (i - 1) * (ICON + GAP)) end
    end
    for i, name in ipairs(RIGHT) do
        local cell = self:CreateCell(name, interactive)
        if cell then cell.button:SetPoint("TOPRIGHT", -pad, top - (i - 1) * (ICON + GAP)) end
    end
    local bottomY = top - #LEFT * (ICON + GAP)
    local bottomW = #BOTTOM * ICON + (#BOTTOM - 1) * GAP
    for i, name in ipairs(BOTTOM) do
        local cell = self:CreateCell(name, interactive)
        if cell then
            cell.button:SetPoint("TOPLEFT", frame, "TOP", -bottomW / 2 + (i - 1) * (ICON + GAP), bottomY)
        end
    end

    -- The model fills the space between the columns, above the weapons.
    local stage = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    stage:SetPoint("TOPLEFT", pad + ICON + GAP, top)
    stage:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -(pad + ICON + GAP), bottomY - GAP)
    stage:SetColorTexture(1, 1, 1, 1)
    if stage.SetGradient and CreateColor then
        stage:SetGradient("VERTICAL", CreateColor(0.02, 0.02, 0.03, 1), CreateColor(0.16, 0.14, 0.12, 1))
    else
        stage:SetColorTexture(0.08, 0.07, 0.06, 1)
    end
    if style.raceBackground then
        -- Sizes are known once anchored; the stage's are fixed by the layout.
        local stageFrame = CreateFrame("Frame", nil, frame)
        stageFrame:SetPoint("TOPLEFT", stage)
        stageFrame:SetSize(MODEL_W, -(bottomY - GAP) + top)
        self.raceBackground = RaceBackground(frame, stageFrame)
    end

    local model = CreateFrame("DressUpModel", nil, frame)
    model:SetAllPoints(stage)
    model:SetScript("OnUpdate", function(m, elapsed)
        m.facing = ((m.facing or 0) + elapsed * TURN_SPEED) % (2 * math.pi)
        m:SetFacing(m.facing)
    end)
    -- A hidden model forgets its unit; set it again on the next dress.
    model:SetScript("OnShow", function(m) m.ready = nil end)
    self.model = model

    -- In the model's place for another character's journey: the client can
    -- only draw the logged-in character (see CLAUDE.md), so that character's
    -- class icon and name instead.
    local portrait = CreateFrame("Frame", nil, frame)
    portrait:SetAllPoints(stage)
    portrait:Hide()
    portrait.icon = portrait:CreateTexture(nil, "ARTWORK")
    portrait.icon:SetSize(56, 56)
    portrait.icon:SetPoint("CENTER", 0, 18)
    portrait.name = portrait:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    portrait.name:SetPoint("TOP", portrait.icon, "BOTTOM", 0, -8)
    portrait.name:SetWidth(MODEL_W - 8)
    portrait.class = portrait:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    portrait.class:SetPoint("TOP", portrait.name, "BOTTOM", 0, -3)
    self.portrait = portrait

    self.note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.note:SetShadowOffset(1, -1)
    self.note:SetPoint("BOTTOM", stage, "BOTTOM", 0, 4)
    self.note:SetWidth(MODEL_W - 8)
    return self
end

-- Shows the model, or for another character's journey the portrait in its
-- place. Returns whether the model is shown.
function Card:ShowModel()
    local e = ns.viewEntry
    self.model:SetShown(not e)
    self.portrait:SetShown(e ~= nil)
    for _, tex in ipairs(self.raceBackground or {}) do
        tex:SetShown(not e)
    end
    if e then
        local portrait = self.portrait
        ns.SetClassIcon(portrait.icon, e.class)
        portrait.name:SetText(e.name or "?")
        portrait.name:SetTextColor(ns.ClassColor(e.class))
        portrait.class:SetText(ns.ClassName(e.class))
    end
    return not e
end

-- Puts gear on the model. The first dress after showing sets the unit and is
-- repeated a moment later, as the model may still be loading.
function Card:Dress(gear)
    if not self:ShowModel() then return end
    local model = self.model
    local first = not model.ready
    if first then
        model:SetUnit("player")
        model.ready = true
    end
    model:Undress()
    -- A ranged weapon tried on takes the main hand's place on the model, so
    -- the weapon that matters goes on last: the ranged one for hunters, the
    -- hand weapons for everyone else, who show a ranged weapon only with no
    -- main hand weapon.
    local ranged, mainHand
    for _, cell in ipairs(self.cells) do
        if cell.name == "RangedSlot" then ranged = gear[cell.slot] end
        if cell.name == "MainHandSlot" then mainHand = gear[cell.slot] end
    end
    local hunter = select(2, UnitClass("player")) == "HUNTER"
    if ranged and not hunter and not mainHand then
        model:TryOn("item:" .. ranged)
    end
    for _, cell in ipairs(self.cells) do
        local itemID = gear[cell.slot]
        if itemID and VISIBLE[cell.name] and cell.name ~= "RangedSlot" then
            model:TryOn("item:" .. itemID)
        end
    end
    if ranged and hunter then
        model:TryOn("item:" .. ranged)
    end
    if first then
        C_Timer.After(0.1, function()
            if self.frame:IsShown() and self.gear == gear then self:Dress(gear) end
        end)
    end
end

-- Shows gear (slot -> item ID). flash: light up slots that differ from the
-- gear shown before.
function Card:Render(gear, title, note, flash)
    local before = self.gear
    self.gear = gear
    self.title:SetText(title)
    self.note:SetText(note or "")
    for _, cell in ipairs(self.cells) do
        local itemID = gear[cell.slot]
        cell.itemID = itemID
        if itemID then
            cell.icon:SetTexture(ItemIcon(itemID))
            cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local quality = ItemQuality(itemID)
            ns.SetQualityOverlay(cell.border, quality and quality >= QUALITY_BORDER_MIN and quality or nil)
        else
            cell.icon:SetTexture(cell.empty)
            cell.icon:SetTexCoord(0, 1, 0, 1)
            cell.border:Hide()
        end
        if flash and before and before[cell.slot] ~= itemID then
            cell.fade:Stop()
            cell.fade:Play()
        end
    end
    self.frame:Show()
    self:Dress(gear)
end

-- Hover card --------------------------------------------------------------------

local hoverCard

-- Places the card beside owner. For a tooltip, it goes on the side the
-- tooltip opened towards (away from what the tooltip belongs to), so the card
-- never covers the row or marker being hovered; for anything else, towards
-- the middle of the screen. Either way it flips if there is no room.
local function Anchor(frame, owner)
    frame:ClearAllPoints()
    local toLeft
    local tooltipOwner = owner.GetOwner and owner:GetOwner()
    local ox = owner:GetCenter()
    if tooltipOwner and tooltipOwner.GetCenter and tooltipOwner:GetCenter() and ox then
        toLeft = ox < tooltipOwner:GetCenter()
    else
        toLeft = (ox or 0) > UIParent:GetWidth() / 2
    end
    local width = frame:GetWidth() + 8
    if toLeft and (owner:GetLeft() or 0) - width < 0 then
        toLeft = false
    elseif not toLeft and (owner:GetRight() or 0) + width > UIParent:GetRight() then
        toLeft = true
    end
    if toLeft then
        frame:SetPoint("TOPRIGHT", owner, "TOPLEFT", -4, 0)
    else
        frame:SetPoint("TOPLEFT", owner, "TOPRIGHT", 4, 0)
    end
end

local function Copy(gear)
    local copy = {}
    for slot, id in pairs(gear) do
        copy[slot] = id
    end
    return copy
end

local GUESSED_NOTE = "Gear seen later in this level"

-- A level snapshot's gear, and whether it is a guess. Snapshots taken at
-- login used to have no gear, as the client did not give it yet (issue
-- #63). For those the best guess is the next snapshot with gear, less the
-- slots an "eq" event changed in between (what they held before is unknown).
local function SnapshotGear(level)
    local snapshot = ns.view.levels[level]
    local gear = snapshot and snapshot.gear
    if not gear or next(gear) or not snapshot.t then return gear, false end
    local nextT, nextGear
    for _, s in pairs(ns.view.levels) do
        if s.t and s.t > snapshot.t and s.gear and next(s.gear) and (not nextT or s.t < nextT) then
            nextT, nextGear = s.t, s.gear
        end
    end
    if not nextGear then return gear, false end
    local guess = Copy(nextGear)
    for _, e in ipairs(ns.view.events) do
        if e[2] == "eq" and e[1] >= snapshot.t and e[1] <= nextT then
            guess[e[6]] = nil
        end
    end
    return guess, true
end

-- Shows the gear for level beside owner, in place of a tooltip: title
-- (default "Gear at level N") on the banner, detail (such as zone and date)
-- under the model. Returns false, showing nothing, for levels without
-- recorded gear, so the caller can show a plain tooltip instead.
function GearCard:Show(level, owner, title, detail)
    local snapshot = ns.view.levels[level]
    local gear, guessed = SnapshotGear(level)
    if not gear or not next(gear) then
        self:Hide()
        return false
    end
    hoverCard = hoverCard or NewCard(UIParent, "TOOLTIP", false)
    Anchor(hoverCard.frame, owner)
    hoverCard.model.facing = 0
    local note = detail
    if guessed then
        note = (note and note .. "\n" or "") .. GUESSED_NOTE
    elseif snapshot.gearLater then
        note = (note and note .. "\n" or "") .. "Gear recorded at a later login"
    end
    hoverCard:Render(gear, title or ("Gear at level %d"):format(level), note)
    return true
end

function GearCard:Hide()
    if hoverCard then hoverCard.frame:Hide() end
end

-- Replay card -------------------------------------------------------------------

local dockCard, dockParent
local timeline          -- { t, level, gear } in time order, see Rebuild
local shownIndex

-- Builds the gear worn over time: each level snapshot sets the whole gear
-- (and the level), each "eq" event changes one slot.
function GearCard:Rebuild()
    local changes = {}
    for level, snapshot in pairs(ns.view.levels) do
        local gear, guessed = SnapshotGear(level)
        if gear and snapshot.t then
            changes[#changes + 1] = { t = snapshot.t, level = level, gear = gear, guessed = guessed, order = 0 }
        end
    end
    for i, e in ipairs(ns.view.events) do
        if e[2] == "eq" then
            changes[#changes + 1] = { t = e[1], slot = e[6], id = e[7], order = i }
        end
    end
    -- Snapshots first at equal times, then events in logged order.
    table.sort(changes, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.order < b.order
    end)

    timeline = {}
    local gear, level, guessed
    for _, change in ipairs(changes) do
        if change.gear then
            gear, level, guessed = Copy(change.gear), change.level, change.guessed
        elseif gear then
            gear = Copy(gear)
            gear[change.slot] = change.id ~= 0 and change.id or nil
        end
        if gear then
            timeline[#timeline + 1] = { t = change.t, level = level, gear = gear, guessed = guessed }
        end
    end
    shownIndex = nil
end

-- Index of the last timeline entry at or before t, or nil.
local function IndexAt(t)
    local i = ns.LastIndex(timeline, t, "t")
    return i > 0 and i or nil
end

-- parent: the map's overlay frame; the card sits in its bottom-left corner.
function GearCard:Dock(parent)
    dockParent = parent
end

-- Shows the replay card at time t (math.huge for now), or updates it when the
-- gear at t differs from what it shows.
function GearCard:Follow(t)
    if not dockParent then return end
    if not timeline then self:Rebuild() end
    if not dockCard then
        dockCard = NewCard(dockParent, "HIGH", true)
        dockCard.frame:SetFrameLevel(dockParent:GetFrameLevel() + 20)
        dockCard.frame:SetPoint("BOTTOMLEFT", dockParent, "BOTTOMLEFT", 12, 40)   -- above the map's buttons
    end
    local index = IndexAt(t)
    if index == shownIndex and dockCard.frame:IsShown() then return end
    local wasShown = dockCard.frame:IsShown() and shownIndex
    shownIndex = index
    local entry = timeline[index or 1]
    if not entry then
        dockCard:Render({}, "Gear", "No gear recorded yet")
        return
    end
    local title = entry.level and ("Gear at level %d"):format(entry.level) or "Gear"
    local note = not index and "Before the first recorded gear" or entry.guessed and GUESSED_NOTE or nil
    dockCard:Render(entry.gear, title, note, wasShown)
end

function GearCard:Undock()
    shownIndex = nil
    if dockCard then dockCard.frame:Hide() end
end

