local _, ns = ...

-- Gear cards: a character model wearing recorded gear, turning slowly, with
-- the item icons laid out as on the character sheet.
--   GearCard:Show(level, owner)   beside a tooltip: the gear on reaching a
--                                 level (ns.char.levels[level].gear)
--   GearCard:Dock(parent)         a card in the corner of the journey map that
--   GearCard:Follow(t)            follows the replay: the gear worn at time t,
--                                 from level snapshots plus "eq" events, with
--                                 a flash on each slot that changed

local GearCard = {}
ns.GearCard = GearCard

local ICON = 26
local GAP = 3
local MODEL_W = 150
local PAD = 8
local TITLE_H = 22
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

function Card:CreateCell(name)
    local id, empty = SlotInfo(name)
    if not id then return end
    local frame = self.frame
    local cell = { slot = id, empty = empty, name = name }
    cell.icon = frame:CreateTexture(nil, "ARTWORK")
    cell.icon:SetSize(ICON, ICON)
    cell.border = frame:CreateTexture(nil, "OVERLAY")
    cell.border:SetAllPoints(cell.icon)
    local back = frame:CreateTexture(nil, "BORDER")
    back:SetPoint("TOPLEFT", cell.icon, -1, 1)
    back:SetPoint("BOTTOMRIGHT", cell.icon, 1, -1)
    back:SetColorTexture(0, 0, 0, 0.8)

    -- A gold flash when the slot's item changes during a replay.
    cell.flash = frame:CreateTexture(nil, "OVERLAY", nil, 2)
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

-- parent and strata: where the card lives.
local function NewCard(parent, strata)
    local self = setmetatable({ cells = {} }, Card)
    local height = TITLE_H + #LEFT * (ICON + GAP) + ICON + GAP + PAD * 2
    local width = PAD * 2 + ICON * 2 + GAP * 2 + MODEL_W
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    self.frame = frame
    frame:SetSize(width, height)
    frame:SetFrameStrata(strata)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.6)
    frame:Hide()

    self.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.title:SetPoint("TOP", 0, -PAD)

    local top = -(PAD + TITLE_H)
    for i, name in ipairs(LEFT) do
        local cell = self:CreateCell(name)
        if cell then cell.icon:SetPoint("TOPLEFT", PAD, top - (i - 1) * (ICON + GAP)) end
    end
    for i, name in ipairs(RIGHT) do
        local cell = self:CreateCell(name)
        if cell then cell.icon:SetPoint("TOPRIGHT", -PAD, top - (i - 1) * (ICON + GAP)) end
    end
    local bottomY = top - #LEFT * (ICON + GAP)
    local bottomW = #BOTTOM * ICON + (#BOTTOM - 1) * GAP
    for i, name in ipairs(BOTTOM) do
        local cell = self:CreateCell(name)
        if cell then
            cell.icon:SetPoint("TOPLEFT", frame, "TOP", -bottomW / 2 + (i - 1) * (ICON + GAP), bottomY)
        end
    end

    -- The model fills the space between the columns, above the weapons.
    local stage = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    stage:SetPoint("TOPLEFT", PAD + ICON + GAP, top)
    stage:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -(PAD + ICON + GAP), bottomY - GAP)
    stage:SetColorTexture(1, 1, 1, 1)
    if stage.SetGradient and CreateColor then
        stage:SetGradient("VERTICAL", CreateColor(0.02, 0.02, 0.03, 1), CreateColor(0.16, 0.14, 0.12, 1))
    else
        stage:SetColorTexture(0.08, 0.07, 0.06, 1)
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

    self.note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.note:SetPoint("BOTTOM", stage, "BOTTOM", 0, 4)
    self.note:SetWidth(MODEL_W - 8)
    return self
end

-- Puts gear on the model. The first dress after showing sets the unit and is
-- repeated a moment later, as the model may still be loading.
function Card:Dress(gear)
    local model = self.model
    local first = not model.ready
    if first then
        model:SetUnit("player")
        model.ready = true
    end
    model:Undress()
    for _, cell in ipairs(self.cells) do
        local itemID = gear[cell.slot]
        if itemID and VISIBLE[cell.name] then
            model:TryOn("item:" .. itemID)
        end
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

-- Places the card beside owner (the tooltip), on whichever side has room.
local function Anchor(frame, owner)
    frame:ClearAllPoints()
    local right = owner:GetRight() or 0
    if right + frame:GetWidth() + 8 < UIParent:GetRight() then
        frame:SetPoint("TOPLEFT", owner, "TOPRIGHT", 4, 0)
    else
        frame:SetPoint("TOPRIGHT", owner, "TOPLEFT", -4, 0)
    end
end

-- Shows the gear for level beside owner (usually GameTooltip, after Show).
-- Levels without recorded gear show nothing.
function GearCard:Show(level, owner)
    local snapshot = ns.char.levels[level]
    local gear = snapshot and snapshot.gear
    if not gear or not next(gear) then
        self:Hide()
        return
    end
    hoverCard = hoverCard or NewCard(UIParent, "TOOLTIP")
    Anchor(hoverCard.frame, owner)
    hoverCard.model.facing = 0
    hoverCard:Render(gear, ("Gear at level %d"):format(level), snapshot.gearLater and "Recorded at a later login")
end

function GearCard:Hide()
    if hoverCard then hoverCard.frame:Hide() end
end

-- Replay card -------------------------------------------------------------------

local dockCard, dockParent
local timeline          -- { t, level, gear } in time order, see Rebuild
local shownIndex

local function Copy(gear)
    local copy = {}
    for slot, id in pairs(gear) do
        copy[slot] = id
    end
    return copy
end

-- Builds the gear worn over time: each level snapshot sets the whole gear
-- (and the level), each "eq" event changes one slot.
function GearCard:Rebuild()
    local changes = {}
    for level, snapshot in pairs(ns.char.levels) do
        if snapshot.gear and snapshot.t then
            changes[#changes + 1] = { t = snapshot.t, level = level, gear = snapshot.gear, order = 0 }
        end
    end
    for i, e in ipairs(ns.char.events) do
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
    local gear, level
    for _, change in ipairs(changes) do
        if change.gear then
            gear, level = Copy(change.gear), change.level
        elseif gear then
            gear = Copy(gear)
            gear[change.slot] = change.id ~= 0 and change.id or nil
        end
        if gear then
            timeline[#timeline + 1] = { t = change.t, level = level, gear = gear }
        end
    end
    shownIndex = nil
end

-- Index of the last timeline entry at or before t, or nil.
local function IndexAt(t)
    local lo, hi = 0, #timeline
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if timeline[mid].t <= t then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo > 0 and lo or nil
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
        dockCard = NewCard(dockParent, "HIGH")
        dockCard.frame:SetFrameLevel(dockParent:GetFrameLevel() + 20)
        dockCard.frame:SetPoint("BOTTOMLEFT", dockParent, "BOTTOMLEFT", 12, 12)
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
    dockCard:Render(entry.gear, title, not index and "Before the first recorded gear" or nil, wasShown)
end

function GearCard:Undock()
    shownIndex = nil
    if dockCard then dockCard.frame:Hide() end
end
