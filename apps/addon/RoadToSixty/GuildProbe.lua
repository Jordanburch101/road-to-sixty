local _, ns = ...

-- /rts guildprobe: what the guild and tabard APIs return on this client, the
-- guild's tabard drawn every way the client might allow, and candidate
-- animations for joining a guild on the journey map, looping, to pick from
-- a screenshot (issue #5). /rts guildprobe large|small|files|emblem|icon
-- picks how the animations draw the tabard; by default the first way the
-- client has.

local GLOW = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local STAR = "Interface\\Cooldown\\star4"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local TABARD_ICON = "Interface\\Icons\\INV_Shirt_GuildTabard_01"

local METHOD_CELL = 96
local ANIM_W, ANIM_H = 200, 190
local BADGE = 56
local LOOP = 4.2            -- seconds per loop of each animation
local CONFETTI = 16
local FIREWORK = 12

local frame
local method

local function Plain(v)
    if type(v) == "table" then
        if v.r then return ("rgb(%.2f, %.2f, %.2f)"):format(v.r, v.g, v.b) end
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. Plain(x) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function Report()
    local P = ns.Print
    P(("IsInGuild %s, GetGuildInfo: %s"):format(tostring(IsInGuild()),
        Plain({ GetGuildInfo("player") })))
    if C_GuildInfo and C_GuildInfo.GetGuildTabardInfo then
        local ok, info = pcall(C_GuildInfo.GetGuildTabardInfo, "player")
        P("C_GuildInfo.GetGuildTabardInfo: " .. (ok and Plain(info) or ("error " .. tostring(info))))
    else
        P("C_GuildInfo.GetGuildTabardInfo: missing")
    end
    for _, name in ipairs({ "GetGuildTabardFiles", "GetGuildLogoInfo", "GetGuildTabardFileNames" }) do
        local fn = _G[name]
        if fn then
            P(name .. ": " .. Plain({ pcall(fn) }))
        else
            P(name .. ": missing")
        end
    end
    for _, name in ipairs({ "SetLargeGuildTabardTextures", "SetSmallGuildTabardTextures", "SetDoubleGuildTabardTextures" }) do
        P(name .. ": " .. (_G[name] and "exists" or "missing"))
    end
    P("Saved: " .. Plain(ns.char.guild) .. ", tabard read now: " .. Plain(ns.Guilds:ReadTabard()))
    P("Kick message: " .. tostring(ERR_GUILD_REMOVE_SELF) .. " / disband: " .. tostring(ERR_GUILD_DISBANDED))
end

-- Tabard drawing ---------------------------------------------------------------

local function Layer(badge, sublevel)
    local tex = badge:CreateTexture(nil, "ARTWORK", nil, sublevel)
    tex:SetAllPoints()
    return tex
end

-- A frame showing the guild's tabard drawn with how ("saved", "large",
-- "small", "files", "emblem" or "icon"). Returns it, and whether the client
-- let it. "saved" is the way the map draws it: Guilds:SetBadge with the
-- tabard as saved at a join, read now.
local function CreateBadge(parent, size, how)
    if how == "saved" then
        local badge = ns.Guilds:CreateBadge(parent, size)
        return badge, ns.Guilds:SetBadge(badge, ns.Guilds:ReadTabard())
    end
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetSize(size, size)
    if how == "large" or how == "small" then
        local fn = _G[how == "large" and "SetLargeGuildTabardTextures" or "SetSmallGuildTabardTextures"]
        local bg, border, emblem = Layer(badge, 0), Layer(badge, 2), Layer(badge, 1)
        local ok = fn and pcall(fn, "player", emblem, bg, border)
        return badge, ok and true or false
    elseif how == "files" then
        local files = { pcall(GetGuildTabardFiles or error) }
        if not table.remove(files, 1) or not files[1] then return badge, false end
        -- backgroundUpper, backgroundLower, emblemUpper, emblemLower, borderUpper, borderLower
        for i = 1, 6 do
            local tex = badge:CreateTexture(nil, "ARTWORK", nil, ({ 0, 0, 2, 2, 1, 1 })[i])
            tex:SetTexture(files[i] --[[@as number]])
            tex:SetPoint("LEFT")
            tex:SetPoint("RIGHT")
            tex:SetHeight(size / 2)
            tex:SetPoint(i % 2 == 1 and "TOP" or "BOTTOM")
        end
        return badge, true
    elseif how == "emblem" then
        local tabard = ns.Guilds:ReadTabard()
        if not (tabard and tabard.emblem) then return badge, false end
        local bg = Layer(badge, 0)
        bg:SetTexture(WHITE)
        bg:SetVertexColor(unpack(tabard.bg or { 0.3, 0.1, 0.1 }))
        local emblem = Layer(badge, 1)
        emblem:SetTexture(tabard.emblem)
        emblem:SetVertexColor(unpack(tabard.emblemColor or { 1, 1, 1 }))
        return badge, true
    end
    local icon = Layer(badge, 0)
    icon:SetTexture(TABARD_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return badge, true
end

-- Guild colours for effects, from the tabard when the client gives them.
local function Colors()
    local t = ns.Guilds:ReadTabard() or {}
    return t.bg or { 0.85, 0.15, 0.1 }, t.border or { 1, 0.82, 0.25 }, t.emblemColor or { 1, 1, 1 }
end

-- Animations -------------------------------------------------------------------

local function EaseOutBack(p)
    local c = 1.7
    p = p - 1
    return 1 + (c + 1) * p * p * p + c * p * p
end

local function EaseOutBounce(p)
    if p < 1 / 2.75 then return 7.5625 * p * p end
    if p < 2 / 2.75 then p = p - 1.5 / 2.75; return 7.5625 * p * p + 0.75 end
    if p < 2.5 / 2.75 then p = p - 2.25 / 2.75; return 7.5625 * p * p + 0.9375 end
    p = p - 2.625 / 2.75
    return 7.5625 * p * p + 0.984375
end

local function Clamp(p) return math.max(0, math.min(1, p)) end

local function Tex(parent, file, layer, blend, color)
    local tex = parent:CreateTexture(nil, layer or "ARTWORK")
    tex:SetTexture(file)
    if blend then tex:SetBlendMode(blend) end
    if color then tex:SetVertexColor(unpack(color)) end
    return tex
end

local function Texts(cell, name)
    local title = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetText("<" .. name .. ">")
    title:SetShadowOffset(1, -1)
    local sub = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetText("Joined the guild")
    sub:SetShadowOffset(1, -1)
    return title, sub
end

-- Fade of the whole thing at the end of a loop.
local function OutAlpha(a)
    return 1 - Clamp((a - (LOOP - 0.8)) / 0.6)
end

-- A: the tabard drops in like a banner and bounces, a golden flash and turning
-- rays behind it, and confetti in the guild's colours bursts up and flutters
-- down.
local function BannerDrop(cell, badge, name)
    local bg, border, emblem = Colors()
    local rays = Tex(cell, STAR, "BORDER", "ADD", border)
    rays:SetPoint("CENTER", 0, 10)
    local flash = Tex(cell, GLOW, "BORDER", "ADD", { 1, 0.95, 0.7 })
    flash:SetPoint("CENTER", 0, 10)
    local confetti = {}
    for i = 1, CONFETTI do
        local c = Tex(cell, WHITE, "OVERLAY", nil, ({ bg, border, emblem })[i % 3 + 1])
        c:SetSize(4, 6)
        confetti[i] = c
    end
    local title, sub = Texts(cell, name)
    title:SetPoint("TOP", cell, "CENTER", 0, -32)
    sub:SetPoint("BOTTOM", cell, "CENTER", 0, 50)
    local LAND = 0.6
    return function(a)
        local out = OutAlpha(a)
        local drop = EaseOutBounce(Clamp(a / LAND))
        badge:ClearAllPoints()
        badge:SetPoint("CENTER", cell, "CENTER", 0, 10 + 110 * (1 - drop))
        badge:SetAlpha(Clamp(a / 0.15) * out)
        local since = a - LAND * 0.36   -- first touch of the bounce
        local f = Clamp(since / 0.5)
        flash:SetSize(40 + 140 * f, 40 + 140 * f)
        flash:SetAlpha(since > 0 and (1 - f) or 0)
        rays:SetSize(130, 130)
        rays:SetRotation(a * 0.7)
        rays:SetAlpha((since > 0 and 0.7 * Clamp(since / 0.3) or 0) * out)
        for i, c in ipairs(confetti) do
            local angle = (i / CONFETTI) * math.pi + (i % 2) * 0.15
            local speed = 90 + (i * 37 % 50)
            local t = math.max(0, since)
            local x = math.cos(angle) * speed * t * 0.9
            local y = math.sin(angle) * speed * t - 160 * t * t
            c:ClearAllPoints()
            c:SetPoint("CENTER", cell, "CENTER", x, 10 + y)
            c:SetRotation(t * (4 + i % 5))
            c:SetAlpha(since > 0 and Clamp(1.6 - t) * out or 0)
        end
        local s = EaseOutBack(Clamp((a - LAND) / 0.35))
        title:SetPoint("TOP", cell, "CENTER", 0, -32 - 12 * (1 - s))
        title:SetAlpha(Clamp((a - LAND) / 0.2) * out)
        sub:SetAlpha(Clamp((a - LAND - 0.2) / 0.3) * out)
    end
end

-- B: the tabard slams down from above like a wax seal, shaking on impact,
-- with a shockwave and dust; the name types out underneath.
local function Stamp(cell, badge, name)
    local _, border = Colors()
    local ring = Tex(cell, GLOW, "BORDER", "ADD", border)
    ring:SetPoint("CENTER", 0, 10)
    local ring2 = Tex(cell, GLOW, "BORDER", "ADD", { 1, 1, 1 })
    ring2:SetPoint("CENTER", 0, 10)
    local dust = {}
    for i = 1, 10 do
        local d = Tex(cell, STAR, "OVERLAY", "ADD", { 1, 0.9, 0.6 })
        d:SetSize(12, 12)
        dust[i] = d
    end
    local title, sub = Texts(cell, name)
    title:SetPoint("TOP", cell, "CENTER", 0, -32)
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    local full = "<" .. name .. ">"
    local HIT = 0.32
    return function(a)
        local out = OutAlpha(a)
        local p = Clamp(a / HIT)
        local scale = 4 - 3 * p * p
        local shake = 0
        if a > HIT and a < HIT + 0.25 then
            shake = math.sin((a - HIT) * 90) * 5 * (1 - (a - HIT) / 0.25)
        end
        badge:SetScale(scale)
        badge:ClearAllPoints()
        badge:SetPoint("CENTER", cell, "CENTER", shake / scale, 10 / scale)
        badge:SetAlpha(p * out)
        local since = a - HIT
        local f = Clamp(since / 0.45)
        ring:SetSize(40 + 160 * f, 40 + 160 * f)
        ring:SetAlpha(since > 0 and (1 - f) * 0.9 or 0)
        local f2 = Clamp((since - 0.1) / 0.5)
        ring2:SetSize(30 + 120 * f2, 30 + 120 * f2)
        ring2:SetAlpha(since > 0.1 and (1 - f2) * 0.5 or 0)
        for i, d in ipairs(dust) do
            local angle = (i / #dust) * math.pi * 2
            local r = 26 + 40 * (1 - (1 - f) * (1 - f))
            d:ClearAllPoints()
            d:SetPoint("CENTER", cell, "CENTER", math.cos(angle) * r, 10 + math.sin(angle) * r * 0.6)
            d:SetAlpha(since > 0 and (1 - f) or 0)
            d:SetRotation(angle + a * 2)
        end
        local letters = math.floor(Clamp((since - 0.15) / 0.6) * #full + 0.5)
        title:SetText(full:sub(1, letters))
        title:SetAlpha(out)
        sub:SetAlpha(Clamp((since - 0.8) / 0.3) * out)
    end
end

-- C: a column of light, the tabard rising up it, rays turning behind and
-- three fireworks bursting overhead in the guild's colours.
local function Rally(cell, badge, name)
    local bg, border, emblem = Colors()
    local beam = Tex(cell, GLOW, "BORDER", "ADD", border)
    beam:SetPoint("BOTTOM", cell, "CENTER", 0, -40)
    local rays = Tex(cell, STAR, "BORDER", "ADD", border)
    rays:SetPoint("CENTER", 0, 10)
    local bursts = {}
    local spots = { { -50, 70, 0.55, bg }, { 45, 80, 0.85, emblem }, { 0, 95, 1.15, border } }
    for b, spot in ipairs(spots) do
        local sparks = {}
        for i = 1, FIREWORK do
            local s = Tex(cell, STAR, "OVERLAY", "ADD", spot[4])
            s:SetSize(10, 10)
            sparks[i] = s
        end
        bursts[b] = { spot = spot, sparks = sparks }
    end
    local title, sub = Texts(cell, name)
    title:SetPoint("TOP", cell, "CENTER", 0, -32)
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    return function(a)
        local out = OutAlpha(a)
        local rise = EaseOutBack(Clamp(a / 0.6))
        beam:SetSize(34, 20 + 170 * Clamp(a / 0.3))
        beam:SetAlpha((0.8 - 0.5 * Clamp((a - 0.4) / 1)) * out)
        badge:ClearAllPoints()
        badge:SetPoint("CENTER", cell, "CENTER", 0, -40 + 50 * rise)
        badge:SetAlpha(Clamp(a / 0.3) * out)
        rays:SetSize(120, 120)
        rays:SetRotation(-a * 0.6)
        rays:SetAlpha(0.6 * Clamp((a - 0.4) / 0.4) * out)
        for _, burst in ipairs(bursts) do
            local spot = burst.spot
            local t = a - spot[3]
            for i, s in ipairs(burst.sparks) do
                local angle = (i / FIREWORK) * math.pi * 2
                local r = 34 * (1 - (1 - Clamp(t / 0.5)) ^ 2)
                s:ClearAllPoints()
                s:SetPoint("CENTER", cell, "CENTER", spot[1] + math.cos(angle) * r,
                    spot[2] - 50 + math.sin(angle) * r - 25 * math.max(0, t) ^ 2)
                s:SetAlpha(t > 0 and Clamp(1 - t / 1.1) * out or 0)
            end
        end
        title:SetAlpha(Clamp((a - 0.5) / 0.3) * out)
        sub:SetAlpha(Clamp((a - 0.8) / 0.3) * out)
    end
end

local ANIMATIONS = {
    { "A: Banner drop", BannerDrop },
    { "B: Seal stamp", Stamp },
    { "C: Fireworks rally", Rally },
}

-- Window -----------------------------------------------------------------------

local function Cell(parent, x, y, w, h, label)
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetSize(w, h)
    cell:SetPoint("TOPLEFT", x, y)
    local bg = cell:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.11, 0.09)
    local text = cell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("BOTTOM", cell, "TOP", 0, 2)
    text:SetText(label)
    return cell, text
end

local function Build(how)
    if frame then frame:Hide() end
    frame = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(3 * ANIM_W + 40, METHOD_CELL + ANIM_H + 90)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.TitleText:SetText("Guild tabard probe")

    local methods = { "saved", "large", "files", "emblem", "icon" }
    local w = (3 * ANIM_W + 20) / #methods
    for i, m in ipairs(methods) do
        local cell, text = Cell(frame, 12 + (i - 1) * w, -44, w - 8, METHOD_CELL, m)
        local badge, ok = CreateBadge(cell, BADGE, m)
        badge:SetPoint("CENTER")
        if not ok then
            text:SetText(m .. " |cffff4040(failed)|r")
        end
        if not how and ok and m ~= "icon" then how = m end
    end
    how = how or "icon"

    local name = GetGuildInfo("player") or "Guild Name"
    local updaters = {}
    for i, anim in ipairs(ANIMATIONS) do
        local cell = Cell(frame, 12 + (i - 1) * (ANIM_W + 8), -(64 + METHOD_CELL), ANIM_W, ANIM_H,
            anim[1] .. " (" .. how .. ")")
        cell:SetClipsChildren(true)
        local badge = CreateBadge(cell, BADGE, how)
        updaters[i] = anim[2](cell, badge, name)
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

ns.Command("guildprobe", "check the guild tabard APIs and preview join animations (developer)", function(arg)
    method = arg ~= "" and arg or nil
    Report()
    Build(method)
end)
