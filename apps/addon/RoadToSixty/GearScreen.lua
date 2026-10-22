local _, ns = ...

-- The gear screen (issue #64): a mode of the journey map window that puts
-- the whole gearing story where the map and the side panel were. A row per
-- slot with a bar per item from when it was put on to when it was replaced,
-- levels along the bottom and then weeks at 60; a paperdoll beside it with
-- the gear worn at the moment under the cursor, or at the pinned one, which
-- is the replay's moment (a click pins it and moves the replay there).
--
-- The timeline is a window onto the whole journey: the mouse wheel zooms
-- around the cursor, dragging moves it, the strip at the bottom shows where
-- it is (and can be dragged too), and Whole journey, Levelling and Endgame
-- jump to those parts. It opens on the last part of the journey.
--
-- The look is Forever's own character sheet art (picked in /rts gearswatch):
-- its slots and background, the status bar texture tinted by item quality,
-- stars drifting through epics, and the sheet's
-- gold enchant swirl as a breathing rim around enchanted items. Hovering an
-- item shows the game's item tooltip from the saved item string, then where
-- and how it was got, how long it was worn and who enchanted it.
--
-- The data comes from GearTimeline.lua. Item names, qualities and levels
-- need the game's item cache; items not cached yet are asked for and the
-- screen redrawn when they arrive.

local GearScreen = {}
ns.GearScreen = GearScreen
local G = ns.GearTimeline

local DOLL_W = 268
local SLOT = 40
local SLOT_STEP = SLOT + 7       -- slot to slot down a column, as on the character sheet
local NAME_W = 74
local HEADER_H = 40
local FLAGS_H = 60              -- milestone labels in up to three rows
local FLAG_ROW = 15
local AXIS_H = 34
local CURVE_H = 92
local CURVE_STEPS = 80
local OVERVIEW_H = 18
local STRIP_STEPS = 120
local WEEK = 7 * 86400
local WEEK_WIDTH = 2            -- a week at 60 is as wide as this many levels
local MIN_WEEKS = 4             -- the endgame part is at least this long
local MIN_SPAN = 3              -- the closest zoom, in levels
local OPEN_SPAN = 24            -- how much the screen opens on, in levels
local ZOOM_STEP = 1.25
local STATUS_BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local STAR = "Interface\\Cooldown\\star4"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local GOLD = { 1, 0.82, 0 }

-- Lanes, top to bottom (shirt and tabard are left out: cosmetic).
local LANES = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
-- Slot ID -> the client's slot name (for its empty slot art).
local SLOT_KEYS = {
    [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [4] = "ShirtSlot", [5] = "ChestSlot", [6] = "WaistSlot",
    [7] = "LegsSlot", [8] = "FeetSlot", [9] = "WristSlot", [10] = "HandsSlot", [11] = "Finger0Slot", [12] = "Finger1Slot",
    [13] = "Trinket0Slot", [14] = "Trinket1Slot", [15] = "BackSlot", [16] = "MainHandSlot", [17] = "SecondaryHandSlot",
    [18] = "RangedSlot", [19] = "TabardSlot",
}
local SLOT_LABELS = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [5] = "Chest", [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist",
    [10] = "Hands", [11] = "Ring", [12] = "Ring", [13] = "Trinket", [14] = "Trinket", [15] = "Back", [16] = "Main hand",
    [17] = "Off hand", [18] = "Ranged",
}
local DOLL_LEFT = { 1, 2, 3, 15, 5, 4, 19, 9 }
local DOLL_RIGHT = { 10, 6, 7, 8, 11, 12, 13, 14 }
local DOLL_BOTTOM = { 16, 17, 18 }

local window, canvas, panel, panelEdges, view, viewEdges
local modeTabs = {}
local mode = "map"
---@type table the built timeline (GearTimeline.Build); nil until first shown
local timeline
local dirty = true
local every = false
local hoverT, pinT = nil, math.huge
-- The axis in u (see U): first and last of the whole journey, and the
-- window shown, lo to hi.
local axis = { first = 1, last = 2, lo = 1, hi = 2 }
local ui = {}                   -- frames made once: doll, lanes, header, ...
local bars, flags, ticks, curve = {}, {}, {}, {}
local flagLabels, tickLabels = {}, {}
local flagStems, flagPlates = {}, {}
local info, loading = {}, {}
local drag                      -- { x, lo, moved, overview } while the left button is down
local curveScale                -- { bottom, top, points } of the item level curve, for the markers
local stripDirty = true         -- the strip's colours need working out again
local curveFill, curveGuides, guideLabels, curveDiamonds, stripSlices = {}, {}, {}, {}, {}
local QueueRedraw     -- defined below; items arriving redraw the screen

-- Items -------------------------------------------------------------------------------

local function ItemKey(span)
    return span.item or ("item:" .. span.id)
end

-- name, quality, icon and item level of a span's item, from the game's cache;
-- asks for it when not cached, and the screen is redrawn when it comes.
local function Info(span)
    local key = ItemKey(span)
    local known = info[key]
    if known then return known end
    ---@diagnostic disable-next-line: deprecated
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local name, _, quality = getInfo(key)
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(span.id)
    if not name then
        -- Ask the game for it once; the screen is redrawn when it comes.
        if not loading[span.id] and Item and Item.CreateFromItemID then
            loading[span.id] = true
            Item:CreateFromItemID(span.id):ContinueOnItemLoad(function()
                loading[span.id] = nil
                QueueRedraw()
            end)
        end
        return { name = "...", quality = 1, icon = icon, pending = true }
    end
    ---@diagnostic disable-next-line: deprecated
    local levelOf = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo
    known = { name = name, quality = quality or 1, icon = icon, ilvl = levelOf and levelOf(key) }
    info[key] = known
    return known
end

local function QualityColor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function EnchantOf(span)
    local enchant = span.item and tonumber(span.item:match("^item:%-?%d+:(%-?%d+)"))
    return enchant and enchant > 0 and enchant or nil
end

local function Clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- The average item level and quality of the gear worn at t: only items
-- whose level is known (not empty slots, not ones still loading), so the
-- curve does not dip while items load. nil when nothing known is worn.
local function Average(t)
    local sum, quality, n = 0, 0, 0
    for slot, span in pairs(G.WornAt(timeline, t, false)) do
        if slot ~= 4 and slot ~= 19 then
            local item = Info(span)
            if item.ilvl then
                sum, quality, n = sum + item.ilvl, quality + item.quality, n + 1
            end
        end
    end
    if n == 0 then return nil end
    return sum / n, quality / n
end

-- A colour between the quality colours for an average quality (2.5 is
-- halfway from green to blue); common gear in a soft grey, not white.
local function BlendQuality(q)
    q = Clamp(q, 1, 4)
    local function Stop(k)
        if k <= 1 then return 0.55, 0.55, 0.55 end
        return QualityColor(k)
    end
    local low = math.floor(q)
    local f = q - low
    local r1, g1, b1 = Stop(low)
    local r2, g2, b2 = Stop(math.min(4, low + 1))
    return r1 + (r2 - r1) * f, g1 + (g2 - g1) * f, b1 + (b2 - b1) * f
end

-- A switch on the character sheet's title plaque; SetTabOn lights it.
local function Tab(parent, text, width, onClick)
    local tab = CreateFrame("Button", nil, parent)
    tab:SetSize(width, 28)
    tab.bg = tab:CreateTexture(nil, "BACKGROUND")
    tab.bg:SetAllPoints()
    tab.bg:SetAtlas("UI-Character-Info-Title")
    tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tab.text:SetPoint("CENTER", 0, 1)
    tab.text:SetText(text)
    tab:SetScript("OnClick", onClick)
    return tab
end

local function SetTabOn(tab, on)
    tab.bg:SetDesaturated(not on)
    tab.bg:SetAlpha(on and 1 or 0.7)
    tab.text:SetFontObject(on and "GameFontHighlight" or "GameFontNormal")
end

-- The axis ---------------------------------------------------------------------------
-- u is the axis unit: the level as a fraction up to 60 (GearTimeline.LevelAt),
-- then 60 plus WEEK_WIDTH for each week since reaching it.

local function U(t)
    if timeline.capAt and t >= timeline.capAt then return G.CAP + (t - timeline.capAt) / WEEK * WEEK_WIDTH end
    return G.LevelAt(timeline, t)
end

-- The time at u: U run backwards.
local function TimeAt(u)
    if timeline.capAt and u >= G.CAP then return timeline.capAt + (u - G.CAP) / WEEK_WIDTH * WEEK end
    local levels, level = timeline.levels, math.floor(u)
    for i, entry in ipairs(levels) do
        if entry[1] == level then
            local nextEntry = levels[i + 1]
            if nextEntry and nextEntry[1] == level + 1 then return entry[2] + (u - level) * (nextEntry[2] - entry[2]) end
            return entry[2]
        end
    end
    return levels[1] and levels[1][2] or timeline.start
end

-- The whole journey's extent, after a new timeline.
local function SetExtent()
    axis.first = timeline.levels[1] and timeline.levels[1][1] or 1
    if timeline.capAt then
        local weeks = math.max(MIN_WEEKS, (timeline.finish - timeline.capAt) / WEEK)
        axis.last = G.CAP + weeks * WEEK_WIDTH
    else
        axis.last = math.max(axis.first + 1, U(timeline.finish))
    end
end

-- Shows lo to hi, kept inside the journey and no closer than MIN_SPAN.
local function SetWindow(lo, hi)
    local whole = axis.last - axis.first
    local span = Clamp(hi - lo, math.min(MIN_SPAN, whole), whole)
    lo = Clamp(lo, axis.first, axis.last - span)
    axis.lo, axis.hi = lo, lo + span
end

-- 0-1 across the track for u (outside it when u is outside the window).
local function X(u)
    return (u - axis.lo) / (axis.hi - axis.lo)
end

local function UAt(x)
    return axis.lo + x * (axis.hi - axis.lo)
end

local function When(t)
    if timeline.capAt and t >= timeline.capAt then
        return ("week %d at %d"):format(math.floor((t - timeline.capAt) / WEEK) + 1, G.CAP)
    end
    return ("level %d"):format(math.floor(G.LevelAt(timeline, t)))
end

-- The tooltip --------------------------------------------------------------------------

local function ZoneName(uiMapID)
    local mapInfo = uiMapID and C_Map.GetMapInfo(uiMapID)
    return mapInfo and mapInfo.name
end

local function SourceText(span)
    local s = span.source
    if not s then return nil end
    local how = s.how
    if how == "drop" then
        if s.kind == "GameObject" then return "Found in a chest" end
        if s.kind == "Item" then return "Found in a container" end
        if s.kind then return "Dropped by " .. (s.name or "a mob") end
        return "Looted"
    elseif how == "quest" then
        local e = s.id and timeline.quests[s.id]
        local title = e and ns.Journal:QuestName(e) or (s.id and ("quest " .. s.id))
        return "Quest reward" .. (title and (": " .. title) or "")
    elseif how == "vendor" then return "Bought from " .. (s.name or "a vendor")
    elseif how == "trade" then return "Traded by " .. (s.name or "another player")
    elseif how == "mail" then return "Mailed by " .. (s.name or "someone")
    elseif how == "ah" then return "Won at the auction house"
    elseif how == "craft" then return "Made it yourself"
    elseif how == "roll" then return "Won in a roll"
    elseif how == "start" then return "Starting gear"
    end
    return "Where it came from was not seen"
end

local function ShowTip(owner, span)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if not pcall(GameTooltip.SetHyperlink, GameTooltip, ItemKey(span)) then
        GameTooltip:AddLine(Info(span).name)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Road to Sixty", unpack(GOLD))
    local got = span.source and span.source.t or span.t
    local source = SourceText(span)
    if source then GameTooltip:AddLine(source, 1, 1, 1) end
    GameTooltip:AddLine(("%s, %s"):format(ZoneName(G.ZoneAt(timeline, got)) or "Got", When(got)), 0.75, 0.75, 0.75)
    if span.late then GameTooltip:AddLine("Put on while the addon was off", 0.75, 0.75, 0.75) end
    if span.seenAt then
        GameTooltip:AddLine(("Worn from the start; first seen at %s"):format(When(span.seenAt)), 0.75, 0.75, 0.75)
    end
    local enchant = EnchantOf(span)
    local e = enchant and timeline.enchants[span.id .. ":" .. enchant]
    if e then
        local by = e[10] == "self" and "Enchanted it yourself" or e[10] and ("Enchanted by " .. e[10]) or "Enchanted"
        GameTooltip:AddLine(("%s, %s"):format(by, When(e[1])), 0.12, 1, 0.12)
    end
    local worn = span.next and ("Worn until %s, replaced by %s"):format(When(span.endT), Info(span.next).name)
        or span.closed and ("Worn until %s"):format(When(span.endT)) or "Still worn"
    GameTooltip:AddLine(worn, 0.75, 0.75, 0.75)
    GameTooltip:Show()
    -- A past item compared with today's gear only confuses.
    if GameTooltip_HideShoppingTooltips then GameTooltip_HideShoppingTooltips(GameTooltip) end
end

-- Effects ------------------------------------------------------------------------------

local function Pulse(texture, from, to, seconds, delay)
    local group = texture:CreateAnimationGroup()
    local fade = group:CreateAnimation("Alpha")
    fade:SetFromAlpha(from)
    fade:SetToAlpha(to)
    fade:SetDuration(seconds)
    fade:SetStartDelay(delay or 0)
    fade:SetSmoothing("IN_OUT")
    group:SetLooping("BOUNCE")
    return group
end

local function Spin(texture, seconds)
    local group = texture:CreateAnimationGroup()
    local turn = group:CreateAnimation("Rotation")
    turn:SetDegrees(360)
    turn:SetDuration(seconds)
    group:SetLooping("REPEAT")
    group:Play()
end

-- A star drifting up through a bar, fading in and out, now and then.
local function Drift(texture, rise, seconds, rest, delay)
    texture:SetAlpha(0)
    local group = texture:CreateAnimationGroup()
    local move = group:CreateAnimation("Translation")
    move:SetOffset(5, rise)
    move:SetDuration(seconds)
    move:SetStartDelay(delay)
    move:SetEndDelay(rest)
    local fadeIn = group:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(seconds * 0.25)
    fadeIn:SetStartDelay(delay)
    local fadeOut = group:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(seconds * 0.35)
    fadeOut:SetStartDelay(delay + seconds * 0.65)
    group:SetLooping("REPEAT")
    return group
end

-- The paperdoll ----------------------------------------------------------------------

local function NewItemButton(parent)
    local ok, button = pcall(CreateFrame, "ItemButton", nil, parent)
    if not ok then button = CreateFrame("Button", nil, parent, "ItemButtonTemplate") end
    button:SetSize(SLOT, SLOT)
    return button
end

-- The sheet's enchant swirl, turning and breathing behind the slot, cut to
-- a square a little bigger than it so only a rim shows (G4).
local function EnchantRim(parent, button)
    local fx = CreateFrame("Frame", nil, parent)
    fx:SetPoint("TOPLEFT", button, -5, 5)
    fx:SetPoint("BOTTOMRIGHT", button, 5, -5)
    fx:SetFrameLevel(button:GetFrameLevel() - 1)
    local mask = fx:CreateMaskTexture()
    mask:SetTexture(WHITE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(fx)
    local swirl = fx:CreateTexture(nil, "ARTWORK")
    swirl:SetAtlas("GearEnchantFX_CharUI_Gold")
    swirl:SetSize((SLOT + 10) * 1.6, (SLOT + 10) * 1.6)
    swirl:SetPoint("CENTER")
    swirl:SetBlendMode("ADD")
    swirl:AddMaskTexture(mask)
    Spin(swirl, 14)
    Pulse(swirl, 0.35, 1, 1.6):Play()
    fx:Hide()
    return fx
end

local function DollSlot(parent, slot)
    local back = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
    back:SetAtlas("UI-Character-Info-GearSlot", true)
    local button = NewItemButton(parent)
    button:SetFrameLevel(parent:GetFrameLevel() + 3)
    button.back = back
    button.rim = EnchantRim(parent, button)
    local ok, _, empty = pcall(GetInventorySlotInfo, SLOT_KEYS[slot])
    button.empty = ok and empty or nil
    button:SetScript("OnEnter", function(self)
        if self.span then ShowTip(self, self.span) end
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    ui.doll[slot] = button
end

local function PlaceSlot(slot, x, y)
    local button = ui.doll[slot]
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", ui.sheet, "TOPLEFT", x, y)
    button.back:ClearAllPoints()
    button.back:SetPoint("CENTER", button)
end

-- A panel in the map's frame style: the tooltip border on a dark ground.
local function Panel(parent)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    panel:SetBackdropColor(0, 0, 0, 0.6)
    panel:SetBackdropBorderColor(0.6, 0.6, 0.6)
    return panel
end

local STAT_ROWS = { "Epic pieces", "Rare pieces", "Enchanted", "Pieces worn so far" }

-- Laid out as the character sheet: a framed pane with the slot columns
-- close together, the model on a dark ground between them and the weapons
-- along the bottom; under it a pane with the moment on the sheet's title
-- plaque, the average item level, and a few counts as the sheet's rows.
local function CreateDoll()
    local doll = CreateFrame("Frame", nil, view)
    doll:SetPoint("TOPLEFT", 0, -HEADER_H)
    doll:SetPoint("BOTTOMLEFT")
    doll:SetWidth(DOLL_W)
    ui.dollFrame, ui.doll = doll, {}

    local sheetW = DOLL_W - 12
    local sheet = Panel(doll)
    sheet:SetPoint("TOPLEFT", 6, 0)
    sheet:SetSize(sheetW, 8 + 8 * SLOT_STEP + SLOT + 10)
    ui.sheet = sheet
    for _, list in ipairs({ DOLL_LEFT, DOLL_RIGHT, DOLL_BOTTOM }) do
        for _, slot in ipairs(list) do DollSlot(sheet, slot) end
    end
    for i, slot in ipairs(DOLL_LEFT) do PlaceSlot(slot, 8, -8 - (i - 1) * SLOT_STEP) end
    for i, slot in ipairs(DOLL_RIGHT) do PlaceSlot(slot, sheetW - 8 - SLOT, -8 - (i - 1) * SLOT_STEP) end
    for i, slot in ipairs(DOLL_BOTTOM) do
        PlaceSlot(slot, sheetW / 2 - SLOT * 1.5 - 6 + (i - 1) * (SLOT + 6), -8 - 8 * SLOT_STEP + 2)
    end

    -- The 3D model between the columns, on a dark ground with the sheet's
    -- overlay, for the character being played only: other characters'
    -- models show untextured on this client.
    local modelLeft, modelRight = 8 + SLOT + 6, sheetW - 8 - SLOT - 6
    local ground = sheet:CreateTexture(nil, "BACKGROUND", nil, 2)
    ground:SetPoint("TOPLEFT", modelLeft, -8)
    ground:SetPoint("BOTTOMRIGHT", sheet, "TOPLEFT", modelRight, -8 - 8 * SLOT_STEP + 7)
    ground:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    local overlay = sheet:CreateTexture(nil, "BACKGROUND", nil, 3)
    overlay:SetAllPoints(ground)
    overlay:SetAtlas("UI-Character-Info-RaceBG-Overlay")
    ui.model = CreateFrame("DressUpModel", nil, sheet)
    ui.model:SetAllPoints(ground)
    ui.modelNote = sheet:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.modelNote:SetPoint("CENTER", ground)
    ui.modelNote:SetWidth(modelRight - modelLeft - 12)
    ui.modelNote:SetText("The model shows for the character you are playing")

    local stats = Panel(doll)
    stats:SetPoint("TOPLEFT", sheet, "BOTTOMLEFT", 0, -8)
    stats:SetPoint("TOPRIGHT", sheet, "BOTTOMRIGHT", 0, -8)
    stats:SetHeight(44 + 46 + #STAT_ROWS * 20 + 8)
    local plaque = stats:CreateTexture(nil, "ARTWORK")
    plaque:SetAtlas("UI-Character-Info-Title")
    plaque:SetPoint("TOPLEFT", 8, -8)
    plaque:SetPoint("TOPRIGHT", -8, -8)
    plaque:SetHeight(32)
    ui.when = stats:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.when:SetPoint("CENTER", plaque, 0, 1)
    ui.ilvl = stats:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    ui.ilvl:SetPoint("TOP", plaque, "BOTTOM", 0, -6)
    local caption = stats:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    caption:SetPoint("TOP", ui.ilvl, "BOTTOM", 0, -2)
    caption:SetText("Average item level")
    ui.statRows = {}
    for i, name in ipairs(STAT_ROWS) do
        local y = -44 - 46 - (i - 1) * 20
        local stripe = stats:CreateTexture(nil, "BACKGROUND", nil, 1)
        stripe:SetPoint("TOPLEFT", 8, y)
        stripe:SetPoint("TOPRIGHT", -8, y)
        stripe:SetHeight(20)
        stripe:SetColorTexture(1, 1, 1, i % 2 == 1 and 0.06 or 0.02)
        local label = stats:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", stripe, "LEFT", 6, 0)
        label:SetText(name .. ":")
        local value = stats:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        value:SetPoint("RIGHT", stripe, "RIGHT", -6, 0)
        ui.statRows[i] = value
    end
end

-- The doll is laid out once, as the sheet is; nothing to do for a resize.
local function LayoutDoll()
end

local lastDressed
local function UpdateDoll(t)
    local worn = G.WornAt(timeline, t, every)
    local epics, rares, enchanted = 0, 0, 0
    local dressed = {}
    for slot, button in pairs(ui.doll) do
        local span = worn[slot]
        button.span = span
        if span then
            local item = Info(span)
            SetItemButtonTexture(button, item.icon)
            SetItemButtonQuality(button, item.quality, ItemKey(span))
            button.rim:SetShown(EnchantOf(span) ~= nil)
            if item.quality >= 4 then epics = epics + 1 elseif item.quality == 3 then rares = rares + 1 end
            if EnchantOf(span) then enchanted = enchanted + 1 end
            dressed[#dressed + 1] = ItemKey(span)
        else
            SetItemButtonTexture(button, button.empty)
            SetItemButtonQuality(button, nil)
            button.rim:Hide()
        end
    end
    ui.when:SetText(t >= timeline.finish and "Now" or ("At " .. When(t)))
    -- The item level big, in the colour of the gear's average quality.
    local average, quality = Average(t)
    ui.ilvl:SetText(average and tostring(math.floor(average + 0.5)) or "...")
    if quality then ui.ilvl:SetTextColor(BlendQuality(quality)) end
    local changes = 0
    for _, slot in ipairs(LANES) do
        for _, span in ipairs((every and timeline.slots or timeline.kept)[slot] or {}) do
            if span.t <= t then changes = changes + 1 end
        end
    end
    for i, v in ipairs({ epics, rares, enchanted, changes }) do ui.statRows[i]:SetText(tostring(v)) end
    -- Dressing the model costs, so only when the gear changed.
    table.sort(dressed)
    local signature = table.concat(dressed, ",")
    if ui.model:IsShown() and signature ~= lastDressed then
        lastDressed = signature
        ui.model:Undress()
        for _, item in ipairs(dressed) do pcall(ui.model.TryOn, ui.model, item) end
    end
end

-- The lanes ----------------------------------------------------------------------------

local function NewBar()
    local bar = CreateFrame("Frame", nil, ui.track)
    bar.fill = bar:CreateTexture(nil, "BACKGROUND")
    bar.fill:SetAllPoints()
    bar.fill:SetTexture(STATUS_BAR)
    bar.top = CreateFrame("Frame", nil, bar)
    bar.top:SetAllPoints()
    bar.top:SetFrameLevel(bar:GetFrameLevel() + 3)
    bar.icon = bar.top:CreateTexture(nil, "OVERLAY")
    bar.icon:SetPoint("LEFT", 1, 0)
    bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar.text = bar.top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("LEFT", bar.icon, "RIGHT", 4, 0)
    bar.text:SetPoint("RIGHT", -2, 0)
    bar.text:SetJustifyH("LEFT")
    bar.text:SetWordWrap(false)
    bar.outline = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
    bar.outline:SetPoint("TOPLEFT", -1, 1)
    bar.outline:SetPoint("BOTTOMRIGHT", 1, -1)
    bar.outline:SetColorTexture(1, 0.82, 0, 0.9)
    bar.outline:Hide()
    bar:EnableMouse(true)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnEnter", function(self) ShowTip(self, self.span) end)
    bar:SetScript("OnLeave", GameTooltip_Hide)
    bar:SetScript("OnMouseDown", function(_, button) GearScreen:MouseDown(button) end)
    bar:SetScript("OnMouseUp", function(_, button) GearScreen:MouseUp(button) end)
    bar:SetScript("OnMouseWheel", function(_, delta) GearScreen:Zoom(delta) end)
    return bar
end

-- Stars drifting through an epic bar, made the first time one needs them.
local function Stars(bar)
    if bar.stars then return bar.stars end
    local fx = CreateFrame("Frame", nil, bar)
    fx:SetAllPoints()
    fx:SetClipsChildren(true)
    fx:SetFrameLevel(bar:GetFrameLevel() + 1)
    fx.anims = {}
    for k = 1, 4 do
        local star = fx:CreateTexture(nil, "OVERLAY")
        star:SetTexture(STAR)
        star:SetBlendMode("ADD")
        star:SetSize(9, 9)
        fx.anims[k] = Drift(star, 30, 1.8 + (k % 3) * 0.4, 0.6 * k, k * 0.45)
        fx[k] = star
    end
    bar.stars = fx
    return fx
end

-- left and right are where the span starts and ends across the track; the
-- bar is cut to the track, so its icon and name stay in sight.
local function PlaceBar(bar, span, left, right, laneY, barH, w)
    local item = Info(span)
    local r, g, b = QualityColor(item.quality)
    left, right = math.max(left, 0), math.min(right, w)
    bar.span = span
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", ui.track, "TOPLEFT", left + 1, laneY)
    bar:SetSize(math.max(2, right - left - 2), barH)
    bar.fill:SetVertexColor(r, g, b)
    local width = right - left
    bar.icon:SetSize(barH - 2, barH - 2)
    bar.icon:SetShown(width > barH + 2)
    bar.icon:SetTexture(item.icon)
    bar.text:SetFontObject(barH >= 22 and "GameFontHighlight" or "GameFontHighlightSmall")
    bar.text:SetShown(width > barH + 40)
    bar.text:SetText(item.name)
    if item.quality >= 4 and width > 24 then
        local stars = Stars(bar)
        for k = 1, 4 do
            local star = stars[k]
            star:ClearAllPoints()
            star:SetPoint("CENTER", stars, "BOTTOMLEFT", width * (k - 0.5) / 4, -2)
            if not stars.anims[k]:IsPlaying() then stars.anims[k]:Play() end
        end
        stars:Show()
    elseif bar.stars then
        for k = 1, 4 do bar.stars.anims[k]:Stop() end
        bar.stars:Hide()
    end
    bar:Show()
end

local function AxisLine(index)
    local line = ticks[index]
    if not line then
        line = ui.track:CreateTexture(nil, "BACKGROUND", nil, -2)
        tickLabels[index] = ui.lanes:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        ticks[index] = line
    end
    return line
end

-- A milestone: a diamond on the lanes' top edge, a label on a dark plate,
-- and a stem joining them.
local function Flag(index)
    local flag = flags[index]
    if not flag then
        flag = ui.flags:CreateTexture(nil, "OVERLAY")
        flag:SetTexture(WHITE)
        flag:SetVertexColor(unpack(GOLD))
        flag:SetSize(8, 8)
        flag:SetRotation(math.rad(45))
        -- A line, as a crowded label sits to the side of its diamond.
        flagStems[index] = ui.flags:CreateLine(nil, "ARTWORK")
        flagStems[index]:SetThickness(1)
        flagStems[index]:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.6)
        flagPlates[index] = ui.flags:CreateTexture(nil, "ARTWORK", nil, 1)
        flagPlates[index]:SetColorTexture(0, 0, 0, 0.75)
        flagLabels[index] = ui.flags:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        flags[index] = flag
    end
    return flag
end

-- Milestones: the first green, blue and epic, level 60, and the first visit
-- to each raid.
local function Milestones()
    local list, firstOf = {}, {}
    for _, slot in ipairs(LANES) do
        for _, span in ipairs(timeline.kept[slot] or {}) do
            local q = Info(span).quality
            for _, want in ipairs({ 2, 3, 4 }) do
                if q == want and (not firstOf[want] or span.t < firstOf[want]) then firstOf[want] = span.t end
            end
        end
    end
    -- { time, text, r, g, b }: the firsts in their quality's colour, 60 in
    -- gold, raids in white.
    local names = { [2] = "First green", [3] = "First blue", [4] = "First epic" }
    for q = 2, 4 do
        if firstOf[q] then list[#list + 1] = { firstOf[q], names[q], QualityColor(q) } end
    end
    if timeline.capAt then list[#list + 1] = { timeline.capAt, "Level " .. G.CAP, GOLD[1], GOLD[2], GOLD[3] } end
    local raids = {}
    for _, e in ipairs(ns.view.events) do
        if e[2] == "in" and e[8] == "raid" and not raids[e[6]] then
            raids[e[6]] = true
            list[#list + 1] = { e[1], e[7] or "Raid", 1, 1, 1 }
        end
    end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    return list
end

-- Axis marks for the window: levels every 1, 2, 5 or 10 and weeks every 1,
-- 2 or 4, by how much is shown.
local function Marks()
    local marks, span = {}, axis.hi - axis.lo
    if axis.lo < G.CAP then
        local step = span <= 8 and 1 or span <= 20 and 2 or span <= 40 and 5 or 10
        for level = math.ceil(axis.lo / step) * step, math.min(G.CAP, math.floor(axis.hi)), step do
            if level >= 1 then
                marks[#marks + 1] = { level, level == G.CAP and tostring(G.CAP) or ("Lv " .. level) }
            end
        end
        if marks[1] == nil or marks[1][1] > axis.lo + step / 2 then
            table.insert(marks, 1, { axis.lo, "Lv " .. math.floor(axis.lo) })
        end
    end
    if timeline.capAt and axis.hi > G.CAP then
        local weeks = span / WEEK_WIDTH
        local step = weeks <= 6 and 1 or weeks <= 16 and 2 or 4
        for week = step, math.floor((axis.hi - G.CAP) / WEEK_WIDTH), step do
            local u = G.CAP + week * WEEK_WIDTH
            if u >= axis.lo then marks[#marks + 1] = { u, "Week " .. week } end
        end
        if axis.lo >= G.CAP and (marks[1] == nil or marks[1][1] > axis.lo + step) then
            table.insert(marks, 1, { axis.lo, axis.lo == G.CAP and ("Hit " .. G.CAP) or When(TimeAt(axis.lo)) })
        end
    end
    return marks
end

-- Sizes from the space there is: lanes fill the height between the header
-- and the axis, curve and strip under them.
local function Layout()
    local h = ui.lanes:GetHeight()
    local laneH = Clamp(math.floor((h - FLAGS_H - AXIS_H - CURVE_H - OVERVIEW_H - 40) / #LANES), 20, 36)
    ui.track:SetHeight(laneH * #LANES)
    LayoutDoll()
    return laneH, Clamp(laneH - 6, 16, 28)
end

function GearScreen:Redraw()
    if not (view and view:IsShown()) then return end
    if dirty or not timeline then
        local now = ns.Roster:IsMe(ns.Roster:ViewEntry()) and ns.Now() or nil
        timeline = G.Build(ns.view, now)
        dirty = false
        SetExtent()
        stripDirty = true
        -- Open on the map's date range (Range.lua), or else the last part of
        -- the journey.
        local range = ns.Range
        if range and not range:IsAll() and range.from < timeline.finish then
            SetWindow(U(math.max(range.from, timeline.start)), U(math.min(range.to, timeline.finish)))
        else
            SetWindow(axis.last - OPEN_SPAN, axis.last)
        end
    end
    -- The part lit is the part the window is in: all of it, or across
    -- both, lights the whole journey.
    local part = "all"
    local whole = axis.lo <= axis.first + 0.01 and axis.hi >= axis.last - 0.01
    if not whole and timeline.capAt and axis.lo >= G.CAP - 0.01 then
        part = "end"
    elseif not whole and (not timeline.capAt or axis.hi <= G.CAP + 0.01) then
        part = "lvl"
    end
    for _, tab in ipairs(ui.phaseTabs) do
        SetTabOn(tab, tab.phase == part)
        tab:SetEnabled(tab.phase ~= "end" or timeline.capAt ~= nil)
    end
    for _, tab in ipairs(ui.swapTabs) do SetTabOn(tab, tab.every == every) end

    local laneH, barH = Layout()
    local w = ui.track:GetWidth()
    local count = 0
    for i, slot in ipairs(LANES) do
        local y = -(i - 1) * laneH - (laneH - barH) / 2
        local label = ui.labels[i]
        label:SetPoint("RIGHT", ui.track, "TOPLEFT", -8, -(i - 0.5) * laneH)
        local stripe = ui.stripes[i]
        stripe:SetPoint("TOPLEFT", ui.track, "TOPLEFT", 0, y)
        stripe:SetPoint("RIGHT", ui.track)
        stripe:SetHeight(barH)
        for _, span in ipairs((every and timeline.slots or timeline.kept)[slot] or {}) do
            local left, right = w * X(U(span.t)), w * X(U(span.endT))
            if right > 0 and left < w then
                count = count + 1
                local bar = bars[count] or NewBar()
                bars[count] = bar
                PlaceBar(bar, span, left, right, y, barH, w)
                bar:SetAlpha(span.brief and 0.4 or 1)
            end
        end
    end
    for k = count + 1, #bars do
        bars[k]:Hide()
        if bars[k].stars then
            for s = 1, 4 do bars[k].stars.anims[s]:Stop() end
        end
    end

    local marks = Marks()
    for k, m in ipairs(marks) do
        local line = AxisLine(k)
        local x = w * X(m[1])
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", ui.track, "TOPLEFT", x, 0)
        line:SetPoint("BOTTOMLEFT", ui.track, "BOTTOMLEFT", x, -6)
        line:SetWidth(1)
        line:SetColorTexture(1, 1, 1, m[1] == G.CAP and 0.35 or 0.12)
        line:Show()
        local label = tickLabels[k]
        label:ClearAllPoints()
        if x > w - 24 then
            label:SetPoint("TOPRIGHT", ui.track, "BOTTOMRIGHT", 0, -8)
        elseif x < 24 then
            label:SetPoint("TOPLEFT", ui.track, "BOTTOMLEFT", 0, -8)
        else
            label:SetPoint("TOP", ui.track, "BOTTOMLEFT", x, -8)
        end
        label:SetText(m[2])
        label:Show()
    end
    for k = #marks + 1, #ticks do
        ticks[k]:Hide()
        tickLabels[k]:Hide()
    end

    -- Flags above the lanes: each label goes in the lowest of three rows
    -- where it fits beside the labels already there (kept inside the
    -- screen), joined to its diamond by a stem. When none has room at the
    -- diamond, the label moves right in the row where it moves least, and
    -- the stem slants to it.
    local rowEnds = {}              -- row -> right edge of its last label
    local shown = 0
    for _, m in ipairs(Milestones()) do
        local x = w * X(U(m[1]))
        if x >= 0 and x <= w then
            shown = shown + 1
            local flag = Flag(shown)
            local label, stem, plate = flagLabels[shown], flagStems[shown], flagPlates[shown]
            label:SetText(m[2])
            label:SetTextColor(m[3], m[4], m[5])
            local width = label:GetStringWidth() + 10
            local want = Clamp(x, width / 2, w - width / 2)
            local row, cx
            for r = 1, 3 do
                local at = math.max(want, (rowEnds[r] or -math.huge) + 4 + width / 2)
                if not cx or at < cx then row, cx = r, at end
            end
            cx = math.min(cx, w - width / 2)
            rowEnds[row] = cx + width / 2
            local y = 13 + (row - 1) * FLAG_ROW
            flag:ClearAllPoints()
            flag:SetPoint("BOTTOM", ui.track, "TOPLEFT", x, 2)
            plate:ClearAllPoints()
            plate:SetPoint("BOTTOM", ui.track, "TOPLEFT", cx, y)
            plate:SetSize(width, FLAG_ROW - 2)
            label:ClearAllPoints()
            label:SetPoint("CENTER", plate, 0, 0)
            stem:SetStartPoint("TOPLEFT", ui.track, x, 8)
            stem:SetEndPoint("TOPLEFT", ui.track, cx, y)
            flag:Show()
            label:Show()
            stem:Show()
            plate:Show()
        end
    end
    for k = shown + 1, #flags do
        flags[k]:Hide()
        flagLabels[k]:Hide()
        flagStems[k]:Hide()
        flagPlates[k]:Hide()
    end

    -- Average item level across the window: a gold line over an area fading
    -- down, a few guide lines with their values, and a diamond in the
    -- item's colour where a blue or epic went on.
    local h = ui.curve:GetHeight() - 16
    local points, lowest, highest = {}, math.huge, 0
    for k = 0, CURVE_STEPS do
        local v = Average(TimeAt(UAt(k / CURVE_STEPS)))
        points[k] = v
        if v then lowest, highest = math.min(lowest, v), math.max(highest, v) end
    end
    if highest == 0 then lowest, highest = 0, 10 end
    local stepV = highest - lowest > 30 and 20 or 10
    local bottom = math.floor(lowest / stepV) * stepV
    local top = math.max(bottom + stepV, math.ceil(highest / stepV) * stepV)
    curveScale = { bottom = bottom, top = top, points = points }
    local function Y(v) return 8 + (v - bottom) / (top - bottom) * h end
    local guides = 0
    for v = bottom, top, stepV do
        guides = guides + 1
        local guide = curveGuides[guides]
        if not guide then
            guide = ui.curve:CreateTexture(nil, "BACKGROUND", nil, 1)
            guide:SetHeight(1)
            guideLabels[guides] = ui.curve:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            curveGuides[guides] = guide
        end
        guide:ClearAllPoints()
        guide:SetPoint("BOTTOMLEFT", ui.curve, "BOTTOMLEFT", 0, Y(v))
        guide:SetPoint("RIGHT", ui.curve)
        guide:SetColorTexture(1, 1, 1, v == bottom and 0.18 or 0.07)
        local label = guideLabels[guides]
        label:ClearAllPoints()
        label:SetPoint("BOTTOMLEFT", ui.curve, "BOTTOMLEFT", 3, Y(v) + 1)
        label:SetText(tostring(v))
        guide:Show()
        label:Show()
    end
    for k = guides + 1, #curveGuides do
        curveGuides[k]:Hide()
        guideLabels[k]:Hide()
    end
    for k = 1, CURVE_STEPS do
        local a, b = points[k - 1], points[k]
        local line, fill = curve[k], curveFill[k]
        if not line then
            line = ui.curve:CreateLine(nil, "ARTWORK")
            line:SetThickness(2)
            line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
            curve[k] = line
            fill = ui.curve:CreateTexture(nil, "BORDER")
            fill:SetColorTexture(1, 1, 1, 1)
            ns.SetAlphaGradient(fill, "VERTICAL", 0.03, 0.3, GOLD)
            curveFill[k] = fill
        end
        if a and b then
            line:SetStartPoint("BOTTOMLEFT", ui.curve, w * (k - 1) / CURVE_STEPS, Y(a))
            line:SetEndPoint("BOTTOMLEFT", ui.curve, w * k / CURVE_STEPS, Y(b))
            -- Whole pixels, edge to edge: overlaps or gaps show as stripes.
            local x1, x2 = math.floor(w * (k - 1) / CURVE_STEPS), math.floor(w * k / CURVE_STEPS)
            fill:ClearAllPoints()
            fill:SetPoint("BOTTOMLEFT", ui.curve, "BOTTOMLEFT", x1, Y(bottom))
            fill:SetSize(math.max(1, x2 - x1), math.max(1, Y((a + b) / 2) - Y(bottom)))
        end
        line:SetShown(a ~= nil and b ~= nil)
        fill:SetShown(a ~= nil and b ~= nil)
    end
    local diamonds = 0
    for _, slot in ipairs(LANES) do
        for _, span in ipairs(timeline.kept[slot] or {}) do
            local x = w * X(U(span.t))
            local quality = Info(span).quality
            local f = x / w * CURVE_STEPS
            local v = quality >= 3 and x >= 0 and x <= w and points[math.floor(f + 0.5)]
            if v then
                diamonds = diamonds + 1
                -- Hovering one shows the item that went on there.
                local diamond = curveDiamonds[diamonds]
                if not diamond then
                    diamond = CreateFrame("Frame", nil, ui.curve)
                    diamond:SetSize(14, 14)
                    diamond:SetFrameLevel(ui.curve:GetFrameLevel() + 3)
                    diamond.mark = diamond:CreateTexture(nil, "OVERLAY")
                    diamond.mark:SetTexture(WHITE)
                    diamond.mark:SetSize(7, 7)
                    diamond.mark:SetPoint("CENTER")
                    diamond.mark:SetRotation(math.rad(45))
                    diamond:EnableMouse(true)
                    diamond:SetScript("OnEnter", function(self)
                        self.mark:SetSize(10, 10)
                        ShowTip(self, self.span)
                    end)
                    diamond:SetScript("OnLeave", function(self)
                        self.mark:SetSize(7, 7)
                        GameTooltip_Hide()
                    end)
                    curveDiamonds[diamonds] = diamond
                end
                diamond.span = span
                diamond:ClearAllPoints()
                diamond:SetPoint("CENTER", ui.curve, "BOTTOMLEFT", x, Y(v))
                diamond.mark:SetVertexColor(QualityColor(quality))
                diamond:Show()
            end
        end
    end
    for k = diamonds + 1, #curveDiamonds do curveDiamonds[k]:Hide() end

    -- Levelling and Endgame under the parts of the axis shown.
    local levelLo, levelHi = math.max(axis.lo, axis.first), math.min(axis.hi, G.CAP)
    ui.phaseLevel:SetShown(levelHi > levelLo)
    ui.phaseLevel:ClearAllPoints()
    ui.phaseLevel:SetPoint("TOP", ui.track, "BOTTOMLEFT", w * X((levelLo + levelHi) / 2), -22)
    local endLo = math.max(axis.lo, G.CAP)
    ui.phaseEnd:SetShown(timeline.capAt ~= nil and axis.hi > endLo)
    ui.phaseEnd:ClearAllPoints()
    ui.phaseEnd:SetPoint("TOP", ui.track, "BOTTOMLEFT", w * X((endLo + axis.hi) / 2), -22)

    -- The strip: the whole journey, coloured by the gear worn at each point,
    -- with the rest dimmed around the window shown and a frame on it.
    local whole = axis.last - axis.first
    local strip = ui.stripInner
    local sw = strip:GetWidth()
    for k = 1, STRIP_STEPS do
        local slice = stripSlices[k]
        if not slice then
            slice = strip:CreateTexture(nil, "ARTWORK")
            slice:SetTexture(STATUS_BAR)
            stripSlices[k] = slice
        end
        if stripDirty then
            local _, quality = Average(TimeAt(axis.first + (k - 0.5) / STRIP_STEPS * whole))
            if quality then
                slice:SetVertexColor(BlendQuality(quality))
            else
                slice:SetVertexColor(0.2, 0.2, 0.2)
            end
        end
        slice:ClearAllPoints()
        slice:SetPoint("TOPLEFT", strip, "TOPLEFT", sw * (k - 1) / STRIP_STEPS, 0)
        slice:SetSize(sw / STRIP_STEPS + 0.5, strip:GetHeight())
    end
    stripDirty = false
    local x1, x2 = sw * (axis.lo - axis.first) / whole, sw * (axis.hi - axis.first) / whole
    ui.stripDimLeft:SetWidth(math.max(0.01, x1))
    ui.stripDimRight:SetWidth(math.max(0.01, sw - x2))
    ui.stripWindow:ClearAllPoints()
    ui.stripWindow:SetPoint("TOPLEFT", strip, "TOPLEFT", x1 - 4, 4)
    ui.stripWindow:SetPoint("BOTTOMRIGHT", strip, "BOTTOMLEFT", math.max(x2, x1 + 6) + 4, -4)
    ui.stripStart:SetText("Lv " .. math.floor(axis.first))
    if timeline.capAt then
        local cx = sw * (G.CAP - axis.first) / whole
        ui.stripCap:ClearAllPoints()
        ui.stripCap:SetPoint("TOP", strip, "TOPLEFT", cx, 0)
        ui.stripCap:SetPoint("BOTTOM", strip, "BOTTOMLEFT", cx, 0)
        ui.stripCapLabel:ClearAllPoints()
        ui.stripCapLabel:SetPoint("TOP", strip, "BOTTOMLEFT", cx, -6)
        ui.stripEnd:SetText(("Week %d"):format(math.floor((axis.last - G.CAP) / WEEK_WIDTH + 0.5)))
    else
        ui.stripEnd:SetText("Lv " .. math.floor(axis.last))
    end
    ui.stripCap:SetShown(timeline.capAt ~= nil)
    ui.stripCapLabel:SetShown(timeline.capAt ~= nil)
    self:ShowMoment()
end

-- The moment's line and the paperdoll: the hovered moment, else the pinned one.
function GearScreen:ShowMoment()
    if not timeline then return end
    local w = ui.track:GetWidth()
    local function Place(line, t)
        local x = w * X(U(math.min(t, timeline.finish)))
        line:SetShown(x >= 0 and x <= w)
        line:ClearAllPoints()
        line:SetPoint("TOP", ui.track, "TOPLEFT", Clamp(x, 0, w), 0)
        line:SetPoint("BOTTOM", ui.track, "BOTTOMLEFT", Clamp(x, 0, w), 0)
    end
    Place(ui.pin, pinT)
    if hoverT then
        Place(ui.hover, hoverT)
        ui.hoverLabel:SetText(When(hoverT))
    else
        ui.hover:Hide()
    end
    ui.hoverLabel:SetShown(hoverT ~= nil)

    -- On the curve: a line, a dot and the value, for the pin and the cursor.
    local h = ui.curve:GetHeight() - 16
    local function ShowMarker(marker, shown)
        marker.line:SetShown(shown)
        marker.dot:SetShown(shown)
        marker.text:SetShown(shown)
    end
    local function Mark(marker, t)
        local x = w * X(U(math.min(t, timeline.finish)))
        local v = curveScale and x >= 0 and x <= w and Average(math.min(t, timeline.finish))
        ShowMarker(marker, v and true or false)
        if not v then return end
        local y = 8 + (v - curveScale.bottom) / (curveScale.top - curveScale.bottom) * h
        marker.line:ClearAllPoints()
        marker.line:SetPoint("BOTTOM", ui.curve, "BOTTOMLEFT", x, 0)
        marker.line:SetHeight(ui.curve:GetHeight())
        marker.dot:ClearAllPoints()
        marker.dot:SetPoint("CENTER", ui.curve, "BOTTOMLEFT", x, y)
        marker.text:SetText(tostring(math.floor(v + 0.5)))
    end
    Mark(ui.curvePin, pinT)
    if hoverT then Mark(ui.curveHover, hoverT) else ShowMarker(ui.curveHover, false) end
    local whole = axis.last - axis.first
    ui.stripPin:ClearAllPoints()
    ui.stripPin:SetPoint("TOP", ui.stripInner, "TOPLEFT", ui.stripInner:GetWidth() * (U(math.min(pinT, timeline.finish)) - axis.first) / whole, 3)
    ui.stripPin:SetHeight(ui.stripInner:GetHeight() + 6)
    local t = hoverT or pinT
    for _, bar in ipairs(bars) do
        if bar:IsShown() then
            local span = bar.span
            bar.outline:SetShown(span.t <= t and (t < span.endT or not span.next and not span.closed) and not span.brief)
        end
    end
    UpdateDoll(math.min(t, timeline.finish))
end

-- Mouse ------------------------------------------------------------------------------

-- The cursor across a frame, 0 to 1 (outside that when off it), or nil.
local function CursorFraction(frame)
    local left, w = frame:GetLeft(), frame:GetWidth()
    if not left or w <= 0 then return nil end
    return (GetCursorPosition() / frame:GetEffectiveScale() - left) / w
end

-- The time under the cursor on the track, or nil off it.
local function CursorTime()
    local f = CursorFraction(ui.track)
    if not f or f < 0 or f > 1 then return nil end
    return TimeAt(UAt(f))
end

-- The mouse wheel zooms around the cursor: what is under it stays put.
-- centred: around the middle of the window (the wheel over the strip).
function GearScreen:Zoom(delta, centred)
    local f = centred and 0.5 or Clamp(CursorFraction(ui.track) or 0.5, 0, 1)
    local u = UAt(f)
    local span = (axis.hi - axis.lo) * (delta > 0 and 1 / ZOOM_STEP or ZOOM_STEP)
    SetWindow(u - f * span, u - f * span + span)
    self:Redraw()
end

-- Left button down on the track or a bar: a drag moves the window, a click
-- (no drag) pins the moment.
function GearScreen:MouseDown(button)
    if button ~= "LeftButton" then return end
    drag = { x = GetCursorPosition(), lo = axis.lo, moved = false }
end

function GearScreen:MouseUp(button)
    if button ~= "LeftButton" or not drag then return end
    local clicked = not drag.moved and not drag.overview
    drag = nil
    if clicked then self:PinAtCursor() end
end

-- While the button is down: moves the window with the cursor.
local function Dragging()
    if not IsMouseButtonDown("LeftButton") then
        drag = nil
        return
    end
    if drag.overview then
        local f = Clamp(CursorFraction(ui.overview) or 0, 0, 1)
        local span = axis.hi - axis.lo
        local centre = axis.first + f * (axis.last - axis.first)
        SetWindow(centre - span / 2, centre + span / 2)
        GearScreen:Redraw()
        return
    end
    local dx = (GetCursorPosition() - drag.x) / ui.track:GetEffectiveScale()
    if not drag.moved and math.abs(dx) < 4 then return end
    drag.moved = true
    local span = axis.hi - axis.lo
    local lo = drag.lo - dx / ui.track:GetWidth() * span
    if math.abs(lo - axis.lo) > span / 2000 then
        SetWindow(lo, lo + span)
        GearScreen:Redraw()
    end
end

function GearScreen:PinAtCursor()
    local t = CursorTime()
    if not t then return end
    -- The replay goes to the same moment. It stops at the path's last point
    -- before it, which can be long before when standing still, so the pin
    -- keeps the time clicked.
    ns.Map:JumpTo(t)
    pinT = t
    self:ShowMoment()
end

-- Map.lua calls this whenever the replay moment changes. The moment stays in
-- view: when it passes the window's edge (a replay playing, History jumping),
-- the window moves on and puts it a fifth of the way in. Not while the player
-- is dragging the window, and not at the journey's end when the window
-- already reaches it.
function GearScreen:Follow(t)
    pinT = t
    if mode ~= "gear" or not (view and view:IsShown()) or not timeline then return end
    local u = U(math.min(t, timeline.finish))
    local span = axis.hi - axis.lo
    local atEnd = u >= axis.last - 1e-6 and axis.hi >= axis.last - 1e-6
    if not drag and not atEnd and (u < axis.lo or u > axis.hi - span * 0.05) then
        SetWindow(u - span * 0.2, u + span * 0.8)
        self:Redraw()
        return
    end
    self:ShowMoment()
end

-- Building -----------------------------------------------------------------------------

local function CreateView()
    view = CreateFrame("Frame", nil, window)
    view:SetPoint("TOPLEFT", canvas)
    view:SetPoint("BOTTOMLEFT", canvas)
    view:SetPoint("TOPRIGHT", panel)
    view:SetFrameLevel(canvas:GetFrameLevel() + 60)
    -- The map's frame style around the whole screen.
    viewEdges = CreateFrame("Frame", nil, window, "BackdropTemplate")
    viewEdges:SetPoint("TOPLEFT", view, -4, 4)
    viewEdges:SetPoint("BOTTOMRIGHT", view, 4, -4)
    viewEdges:SetFrameLevel(view:GetFrameLevel() + 30)
    viewEdges:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
    viewEdges:SetBackdropBorderColor(0.6, 0.6, 0.6)
    viewEdges:Hide()
    view:EnableMouse(true)
    view:Hide()
    local bg = view:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetAtlas("UI-Character-Info-General-BG")

    CreateDoll()

    -- Header: where to look (whole, levelling, endgame), kept gear or every
    -- swap, and how to move around.
    ui.phaseTabs, ui.swapTabs = {}, {}
    local presets = {
        { "all", "Whole journey", 124, function() return axis.first, axis.last end },
        { "lvl", "Levelling", 100, function() return axis.first, timeline.capAt and G.CAP or axis.last end },
        { "end", "Endgame", 100, function() return timeline.capAt and G.CAP or axis.first, axis.last end },
    }
    local x = DOLL_W + 8
    for _, p in ipairs(presets) do
        local tab = Tab(view, p[2], p[3], function()
            SetWindow(p[4]())
            GearScreen:Redraw()
        end)
        tab.phase = p[1]
        tab:SetPoint("TOPLEFT", x, -6)
        x = x + p[3] + 4
        ui.phaseTabs[#ui.phaseTabs + 1] = tab
    end
    local help = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:SetPoint("LEFT", view, "TOPLEFT", x + 12, -21)
    help:SetText("Wheel: zoom   Drag: move   Click: pin the moment")
    local right = -10
    for _, s in ipairs({ { true, "Every swap", 108 }, { false, "Kept gear", 100 } }) do
        local tab = Tab(view, s[2], s[3], function()
            every = s[1]
            GearScreen:Redraw()
        end)
        tab.every = s[1]
        tab:SetPoint("TOPRIGHT", right, -6)
        right = right - s[3] - 4
        ui.swapTabs[#ui.swapTabs + 1] = tab
    end

    -- Lanes: labels on the left, the track the bars sit on.
    local lanes = CreateFrame("Frame", nil, view)
    lanes:SetPoint("TOPLEFT", DOLL_W, -HEADER_H)
    lanes:SetPoint("BOTTOMRIGHT", -14, 10)
    ui.lanes = lanes
    ui.flags = CreateFrame("Frame", nil, lanes)
    ui.flags:SetPoint("TOPLEFT", NAME_W, 0)
    ui.flags:SetPoint("TOPRIGHT")
    ui.flags:SetHeight(FLAGS_H)
    ui.flags:SetFrameLevel(lanes:GetFrameLevel() + 6)
    ui.flags:SetClipsChildren(true)
    local track = CreateFrame("Frame", nil, lanes)
    track:SetPoint("TOPLEFT", NAME_W, -FLAGS_H)
    track:SetPoint("TOPRIGHT", 0, -FLAGS_H)
    track:SetHeight(#LANES * 22)
    track:SetClipsChildren(true)
    track:EnableMouse(true)
    track:EnableMouseWheel(true)
    track:SetScript("OnMouseDown", function(_, button) GearScreen:MouseDown(button) end)
    track:SetScript("OnMouseUp", function(_, button) GearScreen:MouseUp(button) end)
    track:SetScript("OnMouseWheel", function(_, delta) GearScreen:Zoom(delta) end)
    ui.track = track
    ui.labels, ui.stripes = {}, {}
    for i, slot in ipairs(LANES) do
        local label = lanes:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetJustifyH("RIGHT")
        label:SetText(SLOT_LABELS[slot])
        ui.labels[i] = label
        local stripe = track:CreateTexture(nil, "BACKGROUND", nil, -4)
        stripe:SetColorTexture(0, 0, 0, 0.35)
        ui.stripes[i] = stripe
    end
    ui.curve = CreateFrame("Frame", nil, lanes)
    ui.curve:SetPoint("TOPLEFT", track, "BOTTOMLEFT", 0, -AXIS_H)
    ui.curve:SetPoint("TOPRIGHT", track, "BOTTOMRIGHT", 0, -AXIS_H)
    ui.curve:SetHeight(CURVE_H)
    ui.curve:SetClipsChildren(true)
    local curveBack = ui.curve:CreateTexture(nil, "BACKGROUND")
    curveBack:SetAllPoints()
    curveBack:SetColorTexture(0, 0, 0, 0.3)
    local curveLabel = lanes:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    curveLabel:SetPoint("RIGHT", ui.curve, "LEFT", -8, 0)
    curveLabel:SetJustifyH("RIGHT")
    curveLabel:SetText("Item\nlevel")
    -- A marker on the curve: a thin line, a dot on the curve, the value by it.
    local function CurveMarker(r, g, b, thick)
        local marker = { line = ui.curve:CreateTexture(nil, "OVERLAY", nil, 1) }
        marker.line:SetWidth(thick)
        marker.line:SetColorTexture(r, g, b, 0.5)
        marker.dot = ui.curve:CreateTexture(nil, "OVERLAY", nil, 3)
        marker.dot:SetTexture(WHITE)
        marker.dot:SetSize(9, 9)
        marker.dot:SetRotation(math.rad(45))
        marker.dot:SetVertexColor(r, g, b)
        marker.text = ui.curve:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        marker.text:SetPoint("BOTTOMLEFT", marker.dot, "TOPRIGHT", 2, 0)
        return marker
    end
    ui.curvePin = CurveMarker(GOLD[1], GOLD[2], GOLD[3], 2)
    ui.curveHover = CurveMarker(1, 1, 1, 1)
    ui.phaseLevel = lanes:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.phaseLevel:SetText("Levelling")
    ui.phaseEnd = lanes:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.phaseEnd:SetText("Endgame")

    -- The strip: the whole journey in the replay bar's frame, coloured by
    -- the gear worn, the window framed in gold; drag it or wheel over it.
    local overview = CreateFrame("Frame", nil, lanes, "BackdropTemplate")
    overview:SetPoint("TOPLEFT", ui.curve, "BOTTOMLEFT", 0, -10)
    overview:SetPoint("TOPRIGHT", ui.curve, "BOTTOMRIGHT", 0, -10)
    overview:SetHeight(OVERVIEW_H)
    overview:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    overview:SetBackdropColor(0, 0, 0, 0.9)
    overview:SetBackdropBorderColor(0.6, 0.6, 0.6)
    overview:EnableMouse(true)
    overview:EnableMouseWheel(true)
    local inner = CreateFrame("Frame", nil, overview)
    inner:SetPoint("TOPLEFT", 3, -3)
    inner:SetPoint("BOTTOMRIGHT", -3, 3)
    ui.stripInner = inner
    local dimFrame = CreateFrame("Frame", nil, inner)
    dimFrame:SetAllPoints()
    dimFrame:SetFrameLevel(inner:GetFrameLevel() + 2)
    ui.stripDimLeft = dimFrame:CreateTexture(nil, "OVERLAY")
    ui.stripDimLeft:SetPoint("TOPLEFT")
    ui.stripDimLeft:SetPoint("BOTTOMLEFT")
    ui.stripDimLeft:SetColorTexture(0, 0, 0, 0.6)
    ui.stripDimRight = dimFrame:CreateTexture(nil, "OVERLAY")
    ui.stripDimRight:SetPoint("TOPRIGHT")
    ui.stripDimRight:SetPoint("BOTTOMRIGHT")
    ui.stripDimRight:SetColorTexture(0, 0, 0, 0.6)
    ui.stripCap = dimFrame:CreateTexture(nil, "OVERLAY", nil, 1)
    ui.stripCap:SetWidth(1)
    ui.stripCap:SetColorTexture(1, 1, 1, 0.6)
    ui.stripPin = dimFrame:CreateTexture(nil, "OVERLAY", nil, 2)
    ui.stripPin:SetWidth(2)
    ui.stripPin:SetColorTexture(unpack(GOLD))
    ui.stripWindow = CreateFrame("Frame", nil, inner, "BackdropTemplate")
    ui.stripWindow:SetFrameLevel(inner:GetFrameLevel() + 4)
    ui.stripWindow:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
    ui.stripWindow:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3])
    ui.stripStart = lanes:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.stripStart:SetPoint("TOPLEFT", overview, "BOTTOMLEFT", 2, -3)
    ui.stripEnd = lanes:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.stripEnd:SetPoint("TOPRIGHT", overview, "BOTTOMRIGHT", -2, -3)
    ui.stripCapLabel = lanes:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.stripCapLabel:SetText(tostring(G.CAP))
    overview:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then drag = { overview = true } end
    end)
    overview:SetScript("OnMouseUp", function(_, button) GearScreen:MouseUp(button) end)
    overview:SetScript("OnMouseWheel", function(_, delta) GearScreen:Zoom(delta, true) end)
    local stripLabel = lanes:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stripLabel:SetPoint("RIGHT", overview, "LEFT", -8, 0)
    stripLabel:SetText("Journey")
    ui.overview = overview

    -- The pinned moment (the replay's) and the one under the cursor.
    local lines = CreateFrame("Frame", nil, track)
    lines:SetAllPoints()
    lines:SetFrameLevel(track:GetFrameLevel() + 20)
    ui.pin = lines:CreateTexture(nil, "OVERLAY")
    ui.pin:SetWidth(2)
    ui.pin:SetColorTexture(unpack(GOLD))
    ui.hover = lines:CreateTexture(nil, "OVERLAY")
    ui.hover:SetWidth(1)
    ui.hover:SetColorTexture(1, 1, 1, 0.7)
    ui.hoverLabel = lines:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.hoverLabel:SetPoint("BOTTOMLEFT", ui.hover, "TOPRIGHT", 3, -12)

    -- Follow the cursor over the track; move the window while dragging.
    local lastX
    view:SetScript("OnUpdate", function()
        if not timeline then return end
        if drag then Dragging() end
        local over = track:IsMouseOver()
        local x = over and GetCursorPosition() or nil
        if x == lastX then return end
        lastX = x
        hoverT = over and CursorTime() or nil
        GearScreen:ShowMoment()
    end)
    view:SetScript("OnSizeChanged", function() GearScreen:Redraw() end)
end

-- Map | Gear, on the character sheet's title plaque, over the top left corner.
local function CreateModeTabs()
    for k, m in ipairs({ { "map", "Map" }, { "gear", "Gear" } }) do
        local tab = Tab(window, m[2], 94, function() GearScreen:SetMode(m[1]) end)
        tab:SetFrameLevel(canvas:GetFrameLevel() + 100)
        tab:SetPoint("TOPLEFT", canvas, "TOPLEFT", 6 + (k - 1) * 98, -6)
        tab.mode = m[1]
        modeTabs[k] = tab
    end
end

local function UpdateModeTabs()
    for _, tab in ipairs(modeTabs) do SetTabOn(tab, tab.mode == mode) end
end

function GearScreen:Attach(frame, mapCanvas, sidePanel, sidePanelEdges)
    window, canvas, panel, panelEdges = frame, mapCanvas, sidePanel, sidePanelEdges
    CreateModeTabs()
    UpdateModeTabs()
end

function GearScreen:SetMode(newMode)
    mode = newMode
    UpdateModeTabs()
    if mode == "gear" then
        if not view then CreateView() end
        local isMe = ns.Roster:IsMe(ns.Roster:ViewEntry())
        ui.model:SetShown(isMe)
        ui.modelNote:SetShown(not isMe)
        if isMe then
            ui.model:SetUnit("player")
            lastDressed = nil
        end
        panel:Hide()
        panelEdges:Hide()
        view:Show()
        viewEdges:Show()
        self:Redraw()
    else
        panel:Show()
        panelEdges:Show()
        if view then
            view:Hide()
            viewEdges:Hide()
            GameTooltip_Hide()
        end
    end
end

-- The journey shown changed (Map:Open): build again when next shown.
function GearScreen:Rebuild()
    dirty = true
    if mode == "gear" and view and view:IsShown() then self:SetMode("gear") end
end

-- Items asked for arrive one by one; redraw once a burst of them is in.
local redrawQueued = false
QueueRedraw = function()
    if redrawQueued or not (view and view:IsShown()) then return end
    redrawQueued = true
    C_Timer.After(0.3, function()
        redrawQueued = false
        stripDirty = true
        ns.SafeCall(GearScreen.Redraw, GearScreen)
    end)
end
