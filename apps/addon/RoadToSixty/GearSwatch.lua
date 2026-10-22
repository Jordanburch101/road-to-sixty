local _, ns = ...

-- /rts gearswatch: candidate looks for the gear timeline screen (issue #64),
-- built from the Forever client's own character sheet art (its Camelot
-- PaperDollFrame and CharacterFrame) and other game art, so Jordan can pick
-- from a screenshot. Uses the items the character is wearing, with their
-- real icons; hovering one shows the full item tooltip from the saved item
-- string (ns.ItemString), as the screen would, with the journey's lines
-- under it. Atlases the client does not know are labelled missing.

local W, H = 980, 720
local LABEL_W = 96
local SLOT = 37                 -- an ItemButton's size
local BAR_H = 18
local STATUS_BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local SKILL_BAR = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar"
local SKILL_BORDER = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-BarBorder"
local CAST_BORDER = "Interface\\CastingBar\\UI-CastingBar-Border-Small"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local STAR = "Interface\\Cooldown\\star4"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUICKSLOT = "Interface\\Buttons\\UI-Quickslot2"
local ROCK = "Interface\\FrameGeneral\\UI-Background-Rock"
local LOOT_BORDERS = {
    [2] = "loottoast-itemborder-green", [3] = "loottoast-itemborder-blue",
    [4] = "loottoast-itemborder-purple", [5] = "loottoast-itemborder-orange",
}

local frame, content

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function Named(name)
    return HasAtlas(name) and name or (name .. " (missing)")
end

local function QualityColor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- The worn items, best first: { link, icon, quality, name }; at least three
-- (repeated if fewer are worn), so every sample has something to show.
local function WornItems()
    local list = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then
            list[#list + 1] = {
                link = link, icon = GetInventoryItemTexture("player", slot),
                quality = GetInventoryItemQuality("player", slot) or 1, name = link:match("%[(.-)%]") or "?",
            }
        end
    end
    table.sort(list, function(a, b) return a.quality > b.quality end)
    if #list == 0 then
        list[1] = { icon = 134400, quality = 1, name = "Nothing worn" }
    end
    while #list < 3 do list[#list + 1] = list[#list] end
    return list
end

-- The full tooltip: the item's own, read from the saved form of its link,
-- then the journey's part.
local function ShowTip(owner, item)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local saved = item.link and ns.ItemString(item.link)
    local ok = saved and pcall(GameTooltip.SetHyperlink, GameTooltip, saved)
    if not ok then GameTooltip:AddLine(item.name) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Road to Sixty", 1, 0.82, 0)
    GameTooltip:AddLine("Dropped by Kobold Vermin", 1, 1, 1)
    GameTooltip:AddLine("Northshire Valley, got at level 3", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Worn until level 9, replaced by Wolfskin Bracers", 0.7, 0.7, 0.7)
    GameTooltip:AddLine(ok and ("From the saved item string " .. saved) or "SetHyperlink failed on the saved item string", 0.4, 0.8, 1)
    GameTooltip:Show()
    -- The game adds its "Equipped" comparison to item tooltips; a past item
    -- compared with today's gear only confuses.
    if GameTooltip_HideShoppingTooltips then GameTooltip_HideShoppingTooltips(GameTooltip) end
end

local function Hover(region, item)
    region:EnableMouse(true)
    region:SetScript("OnEnter", function(self) ShowTip(self, item) end)
    region:SetScript("OnLeave", GameTooltip_Hide)
end

local function Label(parent, text, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

local function Section(text, y)
    local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 4, y - 10)
    fs:SetWidth(LABEL_W - 8)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
end

-- Animations ---------------------------------------------------------------------------

local function Spin(texture, seconds, degrees)
    local group = texture:CreateAnimationGroup()
    local turn = group:CreateAnimation("Rotation")
    turn:SetDegrees(degrees)
    turn:SetDuration(seconds)
    group:SetLooping("REPEAT")
    group:Play()
end

-- Alpha from a to b and back, forever, starting after delay.
local function Pulse(texture, a, b, seconds, delay)
    local group = texture:CreateAnimationGroup()
    local fade = group:CreateAnimation("Alpha")
    fade:SetFromAlpha(a)
    fade:SetToAlpha(b)
    fade:SetDuration(seconds)
    fade:SetStartDelay(delay or 0)
    fade:SetSmoothing("IN_OUT")
    group:SetLooping("BOUNCE")
    group:Play()
end

-- A texture moving dx, dy over seconds, fading in and out, then waiting
-- rest seconds before going again; first after delay.
local function Drift(texture, dx, dy, seconds, rest, delay)
    texture:SetAlpha(0)
    local group = texture:CreateAnimationGroup()
    local move = group:CreateAnimation("Translation")
    move:SetOffset(dx, dy)
    move:SetDuration(seconds)
    move:SetStartDelay(delay or 0)
    move:SetEndDelay(rest)
    local fadeIn = group:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(seconds * 0.25)
    fadeIn:SetStartDelay(delay or 0)
    local fadeOut = group:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(seconds * 0.35)
    fadeOut:SetStartDelay((delay or 0) + seconds * 0.65)
    group:SetLooping("REPEAT")
    group:Play()
end

-- A square mask over frame f: everything outside it is hidden.
local function SquareMask(f)
    local mask = f:CreateMaskTexture()
    mask:SetTexture(WHITE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(f)
    return mask
end

-- Slots ----------------------------------------------------------------------------

-- An ItemButton (the game's own item slot, with its quality border).
local function NewItemButton(parent, item)
    local ok, button = pcall(CreateFrame, "ItemButton", nil, parent)
    if not ok then button = CreateFrame("Button", nil, parent, "ItemButtonTemplate") end
    button:SetSize(SLOT, SLOT)
    SetItemButtonTexture(button, item.icon)
    if item.link then SetItemButtonQuality(button, item.quality, item.link) end
    Hover(button, item)
    return button
end

-- The character sheet's slot: its frame behind an ItemButton. Returns the button.
local function SheetSlot(cell, item, x, y)
    local back = cell:CreateTexture(nil, "BACKGROUND")
    back:SetAtlas("UI-Character-Info-GearSlot", true)
    back:SetPoint("CENTER", cell, "TOPLEFT", x + SLOT / 2, y - SLOT / 2)
    local button = NewItemButton(cell, item)
    button:SetPoint("TOPLEFT", x, y)
    return button
end

-- Each draws one slot holding item at x, y in cell.
local SLOT_STYLES = {
    { "S1 ItemButton (game's border)", function(cell, item, x, y)
        NewItemButton(cell, item):SetPoint("TOPLEFT", x, y)
    end },
    { "S2 " .. Named("UI-Character-Info-GearSlot"), SheetSlot },
    { "S3 " .. Named("UI-Character-Info-GearSlotSmall"), function(cell, item, x, y)
        local back = cell:CreateTexture(nil, "BACKGROUND")
        back:SetAtlas("UI-Character-Info-GearSlotSmall", true)
        back:SetPoint("CENTER", cell, "TOPLEFT", x + SLOT / 2, y - SLOT / 2)
        local b = NewItemButton(cell, item)
        b:SetSize(SLOT - 8, SLOT - 8)
        b:SetPoint("TOPLEFT", x + 4, y - 4)
    end },
    { "S4 UI-Quickslot2 (classic)", function(cell, item, x, y)
        local icon = cell:CreateTexture(nil, "ARTWORK")
        icon:SetSize(SLOT - 4, SLOT - 4)
        icon:SetPoint("TOPLEFT", x + 2, y - 2)
        icon:SetTexture(item.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local border = cell:CreateTexture(nil, "OVERLAY")
        border:SetTexture(QUICKSLOT)
        border:SetSize(SLOT * 1.75, SLOT * 1.75)
        border:SetPoint("CENTER", icon, "CENTER", 0, -1)
        Hover(icon, item)
    end },
    { "S5 loottoast border (History now)", function(cell, item, x, y)
        local icon = cell:CreateTexture(nil, "ARTWORK")
        icon:SetSize(SLOT - 4, SLOT - 4)
        icon:SetPoint("TOPLEFT", x + 2, y - 2)
        icon:SetTexture(item.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local atlas = LOOT_BORDERS[item.quality]
        if atlas then
            local border = cell:CreateTexture(nil, "OVERLAY")
            border:SetAtlas(atlas)
            border:SetPoint("TOPLEFT", icon, -3, 3)
            border:SetPoint("BOTTOMRIGHT", icon, 3, -3)
        end
        Hover(icon, item)
    end },
}

-- Enchant glows -----------------------------------------------------------------------

-- The character sheet's enchant swirl (GearEnchantFX), turning behind a
-- slot and cut to a square a little bigger than it, so only a thin rim
-- shows around the icon. rim: pixels showing on each side; tint: colour.
local function Rim(cell, button, rim, tint, seconds)
    local fx = CreateFrame("Frame", nil, cell)
    fx:SetPoint("TOPLEFT", button, -rim, rim)
    fx:SetPoint("BOTTOMRIGHT", button, rim, -rim)
    fx:SetFrameLevel(button:GetFrameLevel() - 1)
    local mask = SquareMask(fx)
    local swirl = fx:CreateTexture(nil, "ARTWORK")
    swirl:SetAtlas("GearEnchantFX_CharUI_Gold")
    local size = (SLOT + 2 * rim) * 1.6
    swirl:SetSize(size, size)
    swirl:SetPoint("CENTER")
    swirl:SetBlendMode("ADD")
    if tint then swirl:SetVertexColor(unpack(tint)) end
    swirl:AddMaskTexture(mask)
    Spin(swirl, seconds or 6, 360)
    return fx, swirl
end

-- Sparkles over the icon itself, cut to it, faint.
local function IconSparkles(cell, button, alpha)
    local fx = CreateFrame("Frame", nil, cell)
    fx:SetAllPoints(button)
    fx:SetFrameLevel(button:GetFrameLevel() + 2)
    local mask = SquareMask(fx)
    local sparkles = fx:CreateTexture(nil, "OVERLAY")
    sparkles:SetAtlas("GearEnchantFX_CharUI_Sparkles")
    sparkles:SetSize(SLOT * 2, SLOT * 2)
    sparkles:SetPoint("CENTER")
    sparkles:SetBlendMode("ADD")
    sparkles:SetAlpha(alpha)
    sparkles:AddMaskTexture(mask)
    Spin(sparkles, 9, -360)
end

local ENCHANT_GREEN = { 0.25, 1, 0.25 }

-- Each draws an enchanted sheet slot at x, y.
local GLOWS = {
    { "E0 none", function(cell, item, x, y) SheetSlot(cell, item, x, y) end },
    { "G1 gold rim, turning", function(cell, item, x, y)
        Rim(cell, SheetSlot(cell, item, x, y), 4)
    end },
    { "G2 enchant-green rim", function(cell, item, x, y)
        Rim(cell, SheetSlot(cell, item, x, y), 4, ENCHANT_GREEN)
    end },
    { "G3 gold rim + sparkles on icon", function(cell, item, x, y)
        local button = SheetSlot(cell, item, x, y)
        Rim(cell, button, 4)
        IconSparkles(cell, button, 0.7)
    end },
    { "G4 gold rim, breathing", function(cell, item, x, y)
        local _, swirl = Rim(cell, SheetSlot(cell, item, x, y), 5, nil, 14)
        Pulse(swirl, 0.35, 1, 1.6)
    end },
}

-- Timeline bars -----------------------------------------------------------------------

-- Fills a bar for quality q: a texture, tinted.
local function Fill(bar, q, file)
    local fill = bar:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    fill:SetTexture(file)
    fill:SetVertexColor(QualityColor(q))
    return fill
end

-- A spark sweeping across the bar now and then; delay staggers bars.
local function Shine(bar, delay)
    local fx = CreateFrame("Frame", nil, bar)
    fx:SetAllPoints()
    fx:SetClipsChildren(true)
    local holder = CreateFrame("Frame", nil, fx)
    holder:SetAllPoints()
    local spark = holder:CreateTexture(nil, "OVERLAY")
    spark:SetTexture(SPARK)
    spark:SetBlendMode("ADD")
    spark:SetSize(20, BAR_H * 2.2)
    spark:SetPoint("CENTER", fx, "LEFT", -10, 0)
    Drift(spark, bar:GetWidth() + 20, 0, 1.4, 4, delay)
end

-- Stars drifting up through the bar: count of them, staggered.
local function Stars(bar, count, texture, atlas)
    local fx = CreateFrame("Frame", nil, bar)
    fx:SetAllPoints()
    fx:SetClipsChildren(true)
    local w = bar:GetWidth()
    for k = 1, count do
        local star = fx:CreateTexture(nil, "OVERLAY")
        if atlas then star:SetAtlas(atlas) else star:SetTexture(texture) end
        star:SetBlendMode("ADD")
        local size = atlas and 26 or 9
        star:SetSize(size, size)
        star:SetPoint("CENTER", fx, "BOTTOMLEFT", w * (k - 0.5) / count + (k % 2) * 7, -2)
        Drift(star, 6, BAR_H + 4, 1.8 + (k % 3) * 0.4, 0.6 * k, k * 0.45)
    end
end

-- Each fills bar for quality q and colours its name text; index staggers the effects.
local BAR_STYLES = {
    { "B2 status bar (plain, for reference)", function(bar, q, text)
        Fill(bar, q, STATUS_BAR)
        text:SetTextColor(1, 1, 1)
    end },
    { "F1 shine: a spark sweeps across now and then", function(bar, q, text, index)
        Fill(bar, q, STATUS_BAR)
        text:SetTextColor(1, 1, 1)
        Shine(bar, index * 1.3)
    end },
    { "F2 glow + stars: blue and epic pulse, epic sparkles", function(bar, q, text, index)
        Fill(bar, q, STATUS_BAR)
        text:SetTextColor(1, 1, 1)
        if q >= 3 then
            local glow = bar:CreateTexture(nil, "ARTWORK")
            glow:SetAllPoints()
            glow:SetTexture(STATUS_BAR)
            glow:SetBlendMode("ADD")
            glow:SetVertexColor(QualityColor(q))
            Pulse(glow, 0, q >= 4 and 0.55 or 0.35, 1.4, index * 0.3)
        end
        if q >= 4 then Stars(bar, 5, STAR) end
    end },
    { "F3 profession bar, its border, shine", function(bar, q, text, index)
        Fill(bar, q, SKILL_BAR)
        text:SetTextColor(1, 1, 1)
        local border = bar:CreateTexture(nil, "OVERLAY", nil, 1)
        border:SetTexture(SKILL_BORDER)
        border:SetPoint("TOPLEFT", -5, 7)
        border:SetPoint("BOTTOMRIGHT", 5, -7)
        Shine(bar, index * 1.3 + 0.6)
    end },
    { "F4 cast bar: its border and a spark at the end", function(bar, q, text)
        Fill(bar, q, STATUS_BAR)
        text:SetTextColor(1, 1, 1)
        local border = bar:CreateTexture(nil, "OVERLAY", nil, 1)
        border:SetTexture(CAST_BORDER)
        border:SetPoint("TOPLEFT", -8, 12)
        border:SetPoint("BOTTOMRIGHT", 8, -12)
        local spark = bar:CreateTexture(nil, "OVERLAY", nil, 2)
        spark:SetTexture(SPARK)
        spark:SetBlendMode("ADD")
        spark:SetSize(16, BAR_H * 2)
        spark:SetPoint("CENTER", bar, "RIGHT", -2, 0)
        Pulse(spark, 0.4, 1, 0.9)
    end },
    { "F5 arcane: dark, quality edge, enchant sparkles", function(bar, q, text, index)
        local fill = bar:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetColorTexture(0, 0, 0, 0.6)
        local r, g, b = QualityColor(q)
        local wash = bar:CreateTexture(nil, "BORDER")
        wash:SetAllPoints()
        wash:SetTexture(STATUS_BAR)
        wash:SetVertexColor(r, g, b, 0.25)
        local edge = bar:CreateTexture(nil, "ARTWORK")
        edge:SetPoint("TOPLEFT")
        edge:SetPoint("BOTTOMLEFT")
        edge:SetWidth(3)
        edge:SetColorTexture(r, g, b)
        text:SetTextColor(r, g, b)
        if q >= 3 then Stars(bar, q >= 4 and 4 or 2, nil, "GearEnchantFX_CharUI_Sparkles") end
        Shine(bar, index * 1.7)
    end },
}

-- A lane of three bars, green, blue and purple, over width: the real icons
-- and tooltips of the worn items, with the colours set for the sample.
local function Lane(parent, style, items, x, y, width)
    local shares, left = { 0.3, 0.35, 0.35 }, 0
    for i, q in ipairs({ 2, 3, 4 }) do
        local item = items[i]
        local bar = CreateFrame("Frame", nil, parent)
        bar:SetPoint("TOPLEFT", x + left * width + 1, y)
        bar:SetSize(shares[i] * width - 2, BAR_H)
        local icon = bar:CreateTexture(nil, "OVERLAY", nil, 3)
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", 2, 0)
        icon:SetTexture(item.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local text = bar:CreateFontString(nil, "OVERLAY")
        text:SetFontObject("GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        text:SetPoint("RIGHT", -2, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        text:SetText(item.name)
        style[2](bar, q, text, i)
        -- Above any effects, so the name stays readable.
        local top = CreateFrame("Frame", nil, bar)
        top:SetAllPoints()
        top:SetFrameLevel(bar:GetFrameLevel() + 5)
        icon:SetParent(top)
        text:SetParent(top)
        Hover(bar, item)
        left = left + shares[i]
    end
end

-- Backgrounds -------------------------------------------------------------------------

local BACKGROUNDS = {
    { Named("UI-Character-Info-General-BG"), function(t) t:SetAtlas("UI-Character-Info-General-BG") end },
    { Named("UI-Character-Info-Stat-StoneBG3"), function(t) t:SetAtlas("UI-Character-Info-Stat-StoneBG3") end },
    { "UI-Background-Rock, tiled", function(t)
        t:SetTexture(ROCK, "REPEAT", "REPEAT")
        t:SetHorizTile(true)
        t:SetVertTile(true)
    end },
    { "Dark (the map panel now)", function(t) t:SetColorTexture(0.05, 0.05, 0.05) end },
}

local function CreateWindow()
    frame = CreateFrame("Frame", "RoadToSixtyGearSwatchFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(W + 24, H + 44)
    frame:SetScale(math.min(1, UIParent:GetHeight() * 0.95 / (H + 44)))
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "RoadToSixtyGearSwatchFrame")
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Gear screen candidates (#64): hover an item for its tooltip")
    content = CreateFrame("Frame", nil, frame)
    content:SetSize(W, H)
    content:SetPoint("TOPLEFT", 12, -30)
    local dark = content:CreateTexture(nil, "BACKGROUND", nil, -8)
    dark:SetAllPoints()
    dark:SetColorTexture(0.06, 0.05, 0.04)

    local items = WornItems()
    local cellW = (W - LABEL_W) / #SLOT_STYLES

    -- Slots: three worn items each.
    Section("Slots", 0)
    for i, style in ipairs(SLOT_STYLES) do
        local x = LABEL_W + (i - 1) * cellW
        for k = 1, 3 do style[2](content, items[k], x + 10 + (k - 1) * (SLOT + 12), -10) end
        Label(content, style[1], x + 4, -10 - SLOT - 12, cellW - 8)
    end

    -- Enchant glows on the character sheet's slot.
    Section("Enchant glow", -90)
    for i, glow in ipairs(GLOWS) do
        local x = LABEL_W + (i - 1) * cellW + cellW / 2 - SLOT / 2
        glow[2](content, items[1], x, -100)
        Label(content, glow[1], LABEL_W + (i - 1) * cellW + 4, -100 - SLOT - 12, cellW - 8)
    end

    -- Timeline bars, two to a row.
    Section("Timeline bars", -180)
    local laneW = (W - LABEL_W - 30) / 2
    for i, style in ipairs(BAR_STYLES) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local x, y = LABEL_W + col * (laneW + 20), -196 - row * 60
        Lane(content, style, items, x, y, laneW)
        Label(content, style[1], x, y - 26, laneW)
    end

    -- Backgrounds, each with a slot and two lanes on it.
    Section("Backgrounds", -380)
    local bgW = (W - LABEL_W - 30) / #BACKGROUNDS
    for i, bg in ipairs(BACKGROUNDS) do
        local x = LABEL_W + (i - 1) * (bgW + 10)
        local panel = CreateFrame("Frame", nil, content)
        panel:SetPoint("TOPLEFT", x, -390)
        panel:SetSize(bgW, 120)
        panel:SetClipsChildren(true)
        local t = panel:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        bg[2](t)
        SheetSlot(panel, items[1], 8, -8)
        SheetSlot(panel, items[2], 8, -8 - SLOT - 10)
        Lane(panel, BAR_STYLES[2], items, SLOT + 18, -18, bgW - SLOT - 26)
        Lane(panel, BAR_STYLES[6], items, SLOT + 18, -66, bgW - SLOT - 26)
        Label(content, bg[1], x, -390 - 124, bgW)
    end

    -- Headings, divider, tabs and the item level badge.
    Section("Headings", -550)
    local heading = content:CreateTexture(nil, "ARTWORK")
    heading:SetAtlas("UI-Character-Info-Title")
    heading:SetSize(197, 40)
    heading:SetPoint("TOPLEFT", LABEL_W, -556)
    local headingText = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headingText:SetPoint("CENTER", heading)
    headingText:SetText("Endgame")
    Label(content, Named("UI-Character-Info-Title"), LABEL_W, -600, 200)

    local divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetAtlas("common-framedivider")
    divider:SetSize(220, 8)
    divider:SetPoint("TOPLEFT", LABEL_W + 220, -572)
    Label(content, Named("common-framedivider"), LABEL_W + 220, -600, 220)

    local tabX = LABEL_W + 460
    for k, atlas in ipairs({ "UI-Character-Info-StatTab", "UI-Character-Info-StatTab-Selected" }) do
        local tab = content:CreateTexture(nil, "ARTWORK")
        tab:SetAtlas(atlas)
        tab:SetSize(96, 30)
        tab:SetPoint("TOPLEFT", tabX + (k - 1) * 100, -560)
        local text = content:CreateFontString(nil, "OVERLAY", k == 2 and "GameFontHighlightSmall" or "GameFontNormalSmall")
        text:SetPoint("CENTER", tab)
        text:SetText(k == 1 and "Levelling" or "Endgame")
    end
    Label(content, Named("UI-Character-Info-StatTab") .. ", -Selected", tabX, -600, 200)

    local badge = content:CreateTexture(nil, "ARTWORK")
    badge:SetAtlas("UI-Character-Info-ItemLevel-Bounce", true)
    badge:SetPoint("TOPLEFT", LABEL_W + 680, -550)
    local ilvl = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    ilvl:SetPoint("CENTER", badge)
    ilvl:SetText("Item level 72")
    Label(content, Named("UI-Character-Info-ItemLevel-Bounce"), LABEL_W + 680, -600, 200)

    Label(content, "Bars use the worn items' icons and tooltips with their colours set to green, blue and purple for the sample.",
        LABEL_W, -650, W - LABEL_W - 10):SetTextColor(0.7, 0.7, 0.7)
end

ns.Command("gearswatch", "compare candidate looks for the gear screen (developer)", function()
    if not frame then CreateWindow() end
    frame:Show()
end)
