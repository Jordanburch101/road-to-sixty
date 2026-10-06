local _, ns = ...

-- Gear card: what the player wore on reaching a level, shown beside the
-- tooltip of a level up on the map or in History. The character model in the
-- middle wears the recorded items and turns slowly; the item icons sit around
-- it as on the character sheet. Gear comes from ns.char.levels[level].gear.

local GearCard = {}
ns.GearCard = GearCard

local ICON = 26
local GAP = 3
local MODEL_W = 150
local PAD = 8
local TITLE_H = 22
local TURN_SPEED = 0.5          -- radians per second
local QUALITY_BORDER_MIN = 2    -- green and better get a coloured border

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

local card, model, cells, title, note
local shownLevel

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

local function CreateCell(name)
    local id, empty = SlotInfo(name)
    if not id then return end
    local cell = { slot = id, empty = empty }
    cell.icon = card:CreateTexture(nil, "ARTWORK")
    cell.icon:SetSize(ICON, ICON)
    cell.border = card:CreateTexture(nil, "OVERLAY")
    cell.border:SetAllPoints(cell.icon)
    local back = card:CreateTexture(nil, "BORDER")
    back:SetPoint("TOPLEFT", cell.icon, -1, 1)
    back:SetPoint("BOTTOMRIGHT", cell.icon, 1, -1)
    back:SetColorTexture(0, 0, 0, 0.8)
    cells[name] = cell
    return cell
end

local function Create()
    local height = TITLE_H + #LEFT * (ICON + GAP) + ICON + GAP + PAD * 2
    local width = PAD * 2 + ICON * 2 + GAP * 2 + MODEL_W
    card = CreateFrame("Frame", "RoadToSixtyGearCard", UIParent, "BackdropTemplate")
    card:SetSize(width, height)
    card:SetFrameStrata("TOOLTIP")
    card:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    card:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    card:SetBackdropBorderColor(0.6, 0.6, 0.6)
    card:Hide()

    title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -PAD)

    cells = {}
    local top = -(PAD + TITLE_H)
    for i, name in ipairs(LEFT) do
        local cell = CreateCell(name)
        if cell then cell.icon:SetPoint("TOPLEFT", PAD, top - (i - 1) * (ICON + GAP)) end
    end
    for i, name in ipairs(RIGHT) do
        local cell = CreateCell(name)
        if cell then cell.icon:SetPoint("TOPRIGHT", -PAD, top - (i - 1) * (ICON + GAP)) end
    end
    local bottomY = top - #LEFT * (ICON + GAP)
    local bottomW = #BOTTOM * ICON + (#BOTTOM - 1) * GAP
    for i, name in ipairs(BOTTOM) do
        local cell = CreateCell(name)
        if cell then
            cell.icon:SetPoint("TOPLEFT", card, "TOP", -bottomW / 2 + (i - 1) * (ICON + GAP), bottomY)
        end
    end

    -- The model fills the space between the columns, above the weapons.
    local stage = card:CreateTexture(nil, "BACKGROUND", nil, 1)
    stage:SetPoint("TOPLEFT", PAD + ICON + GAP, top)
    stage:SetPoint("BOTTOMRIGHT", card, "TOPRIGHT", -(PAD + ICON + GAP), bottomY - GAP)
    stage:SetColorTexture(1, 1, 1, 1)
    if stage.SetGradient and CreateColor then
        stage:SetGradient("VERTICAL", CreateColor(0.02, 0.02, 0.03, 1), CreateColor(0.16, 0.14, 0.12, 1))
    else
        stage:SetColorTexture(0.08, 0.07, 0.06, 1)
    end

    model = CreateFrame("DressUpModel", nil, card)
    model:SetAllPoints(stage)
    model:SetScript("OnUpdate", function(self, elapsed)
        self.facing = ((self.facing or 0) + elapsed * TURN_SPEED) % (2 * math.pi)
        self:SetFacing(self.facing)
    end)

    note = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOM", stage, "BOTTOM", 0, 4)
    note:SetWidth(MODEL_W - 8)
end

-- Puts the recorded items on the model. Called again a moment later, as the
-- model may still be loading on the first call.
local function Dress(gear)
    model:SetUnit("player")
    model:Undress()
    for name, cell in pairs(cells) do
        local itemID = gear[cell.slot]
        if itemID and VISIBLE[name] then
            model:TryOn("item:" .. itemID)
        end
    end
end

-- Places the card beside owner (the tooltip), on whichever side has room.
local function Anchor(owner)
    card:ClearAllPoints()
    local right = owner:GetRight() or 0
    if right + card:GetWidth() + 8 < UIParent:GetRight() then
        card:SetPoint("TOPLEFT", owner, "TOPRIGHT", 4, 0)
    else
        card:SetPoint("TOPRIGHT", owner, "TOPLEFT", -4, 0)
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
    if not card then Create() end
    shownLevel = level

    title:SetText(("Gear at level %d"):format(level))
    for _, cell in pairs(cells) do
        local itemID = gear[cell.slot]
        if itemID then
            cell.icon:SetTexture(ItemIcon(itemID))
            cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            cell.icon:SetDesaturated(false)
            local quality = ItemQuality(itemID)
            ns.SetQualityOverlay(cell.border, quality and quality >= QUALITY_BORDER_MIN and quality or nil)
        else
            cell.icon:SetTexture(cell.empty)
            cell.icon:SetTexCoord(0, 1, 0, 1)
            cell.border:Hide()
        end
    end
    note:SetText(snapshot.gearLater and "Recorded at a later login" or "")

    Anchor(owner)
    card:Show()
    model.facing = 0
    Dress(gear)
    C_Timer.After(0.1, function()
        if card:IsShown() and shownLevel == level then Dress(gear) end
    end)
end

function GearCard:Hide()
    shownLevel = nil
    if card then card:Hide() end
end
