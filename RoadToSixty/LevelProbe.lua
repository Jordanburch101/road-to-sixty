local _, ns = ...

-- /rts levelprobe: candidate animations for reaching a level on the journey
-- map, looping side by side, to pick from a screenshot like the guild join's
-- (GuildPop.lua). Level ups come 59 times on the way to 60, so they are
-- short; D is meant for every tenth level only. /rts levelprobe <level>
-- shows reaching that level (19 by default).

local GLOW = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local STAR = "Interface\\Cooldown\\star4"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local BADGE_ATLAS = "UI-HUD-UnitFrame-SmallCircle"      -- the map's level marker

local ANIM_W, ANIM_H = 190, 210
local BADGE = 40
local LOOP = 2.6            -- seconds per loop: about 2 on show, then a pause
local GOLD = { 1, 0.82, 0.25 }
local PALE = { 1, 0.95, 0.7 }
local CONFETTI = 18

local frame

local function Clamp(p) return math.max(0, math.min(1, p)) end

local function EaseOutBack(p)
    local c = 1.7
    p = p - 1
    return 1 + (c + 1) * p * p * p + c * p * p
end

local function EaseOut(p)
    return 1 - (1 - p) ^ 3
end

local function Tex(parent, file, layer, blend, color)
    local tex = parent:CreateTexture(nil, layer or "ARTWORK")
    tex:SetTexture(file)
    if blend then tex:SetBlendMode(blend) end
    if color then tex:SetVertexColor(unpack(color)) end
    return tex
end

-- The level marker: the map's circle with the number on it. Returns the
-- frame and its number.
local function Badge(cell)
    local badge = CreateFrame("Frame", nil, cell)
    badge:SetSize(BADGE, BADGE)
    badge:SetFrameLevel(cell:GetFrameLevel() + 2)
    local circle = badge:CreateTexture(nil, "ARTWORK")
    circle:SetAllPoints()
    circle:SetAtlas(BADGE_ATLAS)
    local number = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    number:SetPoint("CENTER", 0.5, 0)
    number:SetTextColor(1, 1, 1)
    number:SetShadowOffset(1, -1)
    return badge, number
end

local function Caption(cell, level)
    local title = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetText("Level " .. level)
    title:SetShadowOffset(1, -1)
    title:SetTextColor(ns.LevelColor(level))
    return title
end

-- Fade of the whole thing at the end of its time on show.
local function OutAlpha(a)
    return 1 - Clamp((a - 1.7) / 0.4)
end

-- The number flips like a card: the old one squashes flat, the new one
-- opens out, around time at, over 0.24 seconds.
local function Flip(number, a, at, level)
    local f = Clamp((a - at) / 0.24)
    number:SetText(f < 0.5 and (level - 1) or level)
    number:SetScale(math.max(0.05, math.abs(1 - 2 * f)) * (f < 0.5 and 1 or 1.15 - 0.15 * f))
end

-- A: the badge pops up, its number flips to the new level with a golden
-- ring flash, and "Level N" springs in underneath.
local function DingFlip(cell, level)
    local badge, number = Badge(cell)
    local flash = Tex(cell, GLOW, "BORDER", "ADD", PALE)
    flash:SetPoint("CENTER", 0, 10)
    local title = Caption(cell, level)
    return function(a)
        local out = OutAlpha(a)
        local s = EaseOutBack(Clamp(a / 0.3))
        badge:SetScale(math.max(0.05, s))
        badge:ClearAllPoints()
        badge:SetPoint("CENTER", cell, "CENTER", 0, 10 / math.max(0.05, s))
        badge:SetAlpha(Clamp(a / 0.1) * out)
        Flip(number, a, 0.35, level)
        local f = Clamp((a - 0.47) / 0.45)
        flash:SetSize(30 + 110 * f, 30 + 110 * f)
        flash:SetAlpha(a > 0.47 and (1 - f) or 0)
        local t = EaseOutBack(Clamp((a - 0.55) / 0.3))
        title:ClearAllPoints()
        title:SetPoint("TOP", cell, "CENTER", 0, -16 - 10 * (1 - t))
        title:SetAlpha(Clamp((a - 0.55) / 0.15) * out)
    end
end

-- B: a column of golden light shoots up like the game's own level up,
-- sparks drift up it, the badge rides up and its number changes at the top
-- with a flash.
local function Pillar(cell, level)
    local beam = Tex(cell, GLOW, "BORDER", "ADD", GOLD)
    beam:SetPoint("BOTTOM", cell, "CENTER", 0, -30)
    local core = Tex(cell, GLOW, "BORDER", "ADD", PALE)
    core:SetPoint("BOTTOM", cell, "CENTER", 0, -30)
    local sparks = {}
    for i = 1, 10 do
        local s = Tex(cell, STAR, "OVERLAY", "ADD", PALE)
        s:SetSize(10, 10)
        sparks[i] = s
    end
    local badge, number = Badge(cell)
    local flash = Tex(cell, GLOW, "OVERLAY", "ADD", PALE)
    local title = Caption(cell, level)
    return function(a)
        local out = OutAlpha(a)
        local up = Clamp(a / 0.25)
        beam:SetSize(40, 10 + 170 * EaseOut(up))
        beam:SetAlpha((0.9 - 0.6 * Clamp((a - 0.5) / 1)) * out)
        core:SetSize(14, 10 + 170 * EaseOut(up))
        core:SetAlpha((0.8 - 0.6 * Clamp((a - 0.5) / 1)) * out)
        for i, s in ipairs(sparks) do
            local t = (a * 0.9 + i / #sparks) % 1
            s:ClearAllPoints()
            s:SetPoint("CENTER", cell, "CENTER", math.sin(i * 2.3 + a * 3) * 12, -30 + 170 * t)
            s:SetAlpha(a > 0.15 and math.sin(math.pi * t) * out or 0)
        end
        local rise = EaseOutBack(Clamp((a - 0.1) / 0.5))
        badge:ClearAllPoints()
        badge:SetPoint("CENTER", cell, "CENTER", 0, -30 + 70 * rise)
        badge:SetAlpha(Clamp((a - 0.1) / 0.15) * out)
        Flip(number, a, 0.55, level)
        local f = Clamp((a - 0.67) / 0.4)
        flash:ClearAllPoints()
        flash:SetPoint("CENTER", badge, "CENTER")
        flash:SetSize(30 + 90 * f, 30 + 90 * f)
        flash:SetAlpha(a > 0.67 and (1 - f) or 0)
        title:ClearAllPoints()
        title:SetPoint("TOP", cell, "CENTER", 0, -40)
        title:SetAlpha(Clamp((a - 0.7) / 0.2) * out)
    end
end

-- C: the badge slams down from large, two golden rings spread out from it
-- and eight stars burst round it; the number changes on impact.
local function Shockwave(cell, level)
    local rings = {}
    for i = 1, 2 do
        local r = Tex(cell, GLOW, "BORDER", "ADD", i == 1 and GOLD or PALE)
        r:SetPoint("CENTER", 0, 10)
        rings[i] = r
    end
    local stars = {}
    for i = 1, 8 do
        local s = Tex(cell, STAR, "OVERLAY", "ADD", GOLD)
        stars[i] = s
    end
    local badge, number = Badge(cell)
    local title = Caption(cell, level)
    local HIT = 0.25
    return function(a)
        local out = OutAlpha(a)
        local p = Clamp(a / HIT)
        local scale = 3 - 2 * p * p
        badge:SetScale(scale)
        badge:ClearAllPoints()
        badge:SetPoint("CENTER", cell, "CENTER", 0, 10 / scale)
        badge:SetAlpha(p * out)
        number:SetText(a < HIT and (level - 1) or level)
        local since = a - HIT
        for i, r in ipairs(rings) do
            local f = Clamp((since - (i - 1) * 0.12) / 0.5)
            r:SetSize(30 + 150 * f, 30 + 150 * f)
            r:SetAlpha(since > (i - 1) * 0.12 and (1 - f) * (i == 1 and 1 or 0.6) or 0)
        end
        local f = EaseOut(Clamp(since / 0.6))
        for i, s in ipairs(stars) do
            local angle = (i / #stars) * math.pi * 2
            local r = 22 + 50 * f
            s:ClearAllPoints()
            s:SetPoint("CENTER", cell, "CENTER", math.cos(angle) * r, 10 + math.sin(angle) * r)
            s:SetSize(14 - 6 * f, 14 - 6 * f)
            s:SetRotation(angle + a * 3)
            s:SetAlpha(since > 0 and (1 - Clamp(since / 0.7)) or 0)
        end
        title:ClearAllPoints()
        title:SetPoint("TOP", cell, "CENTER", 0, -16)
        title:SetAlpha(Clamp((since - 0.1) / 0.2) * out)
    end
end

-- D, for every tenth level: A's flip with turning golden rays behind it and
-- confetti bursting up and fluttering down, as for joining a guild.
local function Milestone(cell, level)
    local rays = Tex(cell, STAR, "BORDER", "ADD", GOLD)
    rays:SetPoint("CENTER", 0, 10)
    rays:SetSize(130, 130)
    local confetti = {}
    local colors = { GOLD, { 1, 1, 1 }, { ns.LevelColor(level) } }
    for i = 1, CONFETTI do
        local c = Tex(cell, WHITE, "OVERLAY", nil, colors[i % 3 + 1])
        c:SetSize(4, 6)
        confetti[i] = c
    end
    local flip = DingFlip(cell, level)
    return function(a)
        flip(a)
        local out = OutAlpha(a)
        local since = a - 0.47
        rays:SetRotation(a * 0.7)
        rays:SetAlpha(since > 0 and 0.7 * Clamp(since / 0.3) * out or 0)
        local t = math.max(0, since)
        for i, c in ipairs(confetti) do
            local angle = (i / CONFETTI) * math.pi + (i % 2) * 0.15
            local speed = 90 + (i * 37 % 50)
            c:ClearAllPoints()
            c:SetPoint("CENTER", cell, "CENTER", math.cos(angle) * speed * t * 0.9,
                10 + math.sin(angle) * speed * t - 160 * t * t)
            c:SetRotation(t * (4 + i % 5))
            c:SetAlpha(since > 0 and Clamp(1.4 - t) * out or 0)
        end
    end
end

local ANIMATIONS = {
    { "A: Ding flip", DingFlip },
    { "B: Golden pillar", Pillar },
    { "C: Shockwave", Shockwave },
    { "D: Milestone (every 10th)", Milestone, 20 },
}

local function Cell(parent, x, y, label)
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetSize(ANIM_W, ANIM_H)
    cell:SetPoint("TOPLEFT", x, y)
    cell:SetClipsChildren(true)
    -- Map colours behind, as the pop plays over the map.
    local bg = cell:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.45, 0.36, 0.22)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("BOTTOM", cell, "TOP", 0, 2)
    text:SetText(label)
    return cell
end

local function Build(level)
    if frame then frame:Hide() end
    frame = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(#ANIMATIONS * (ANIM_W + 8) + 16, ANIM_H + 60)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.TitleText:SetText("Level up candidates")
    local updaters = {}
    for i, anim in ipairs(ANIMATIONS) do
        local cell = Cell(frame, 12 + (i - 1) * (ANIM_W + 8), -44, anim[1])
        updaters[i] = anim[2](cell, anim[3] or level)
    end
    local age = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        age = (age + elapsed) % LOOP
        for _, update in ipairs(updaters) do
            update(age)
        end
    end)
    frame:Show()
end

ns.Command("levelprobe", "preview level up animations for the journey map (developer)", function(arg)
    local level = tonumber(arg) or 19
    Build(math.max(2, math.min(60, level)))
end)
