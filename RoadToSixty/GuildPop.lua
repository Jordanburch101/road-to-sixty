local _, ns = ...

-- Joining a guild, played on the journey map as the replay passes it (picked
-- from /rts guildprobe as "banner drop"): the guild's tabard drops in from
-- above and bounces, a golden flash and turning rays light up behind it,
-- confetti in the tabard's colours bursts up and flutters down, and the
-- guild's name springs in underneath. Joins are rare, so they play one at a
-- time, each in full.

local GuildPop = {}
ns.GuildPop = GuildPop

local GLOW = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local STAR = "Interface\\Cooldown\\star4"
local WHITE = "Interface\\Buttons\\WHITE8X8"

local BADGE = 48
local DROP = 110            -- pixels above its spot the tabard falls from
local LAND = 0.6            -- seconds for the fall and bounce
local TOUCH = LAND * 0.36   -- first touch of the bounce, when the burst starts
local LENGTH = 3.6          -- seconds on show
local OUT = 0.6             -- of which fading out
local LIFT = 22             -- the badge sits this far above the spot
local CONFETTI = 20
local MAX_WAITING = 2
local GOLD = { 1, 0.82, 0.25 }

local parent                -- the map's overlay
local joins = {}            -- { t, c, x, y, name, rank, tabard } in time order
local waiting = {}
local pop                   -- the one pop, made on first use

local function Clamp(p) return math.max(0, math.min(1, p)) end

local function EaseOutBack(p)
    local c = 1.7
    p = p - 1
    return 1 + (c + 1) * p * p * p + c * p * p
end

local function EaseOutBounce(p)
    if p < 1 / 2.75 then return 7.5625 * p * p end
    if p < 2 / 2.75 then
        p = p - 1.5 / 2.75
        return 7.5625 * p * p + 0.75
    end
    if p < 2.5 / 2.75 then
        p = p - 2.25 / 2.75
        return 7.5625 * p * p + 0.9375
    end
    p = p - 2.625 / 2.75
    return 7.5625 * p * p + 0.984375
end

local function Tex(file, layer, blend, color)
    local tex = pop:CreateTexture(nil, layer)
    tex:SetTexture(file)
    if blend then tex:SetBlendMode(blend) end
    if color then tex:SetVertexColor(unpack(color)) end
    return tex
end

local function NewPop()
    pop = CreateFrame("Frame", nil, parent)
    pop:SetSize(1, 1)
    pop:SetFrameLevel(parent:GetFrameLevel() + 32)
    pop.rays = Tex(STAR, "BORDER", "ADD", GOLD)
    pop.rays:SetSize(130, 130)
    pop.flash = Tex(GLOW, "BORDER", "ADD", { 1, 0.95, 0.7 })
    pop.badge = ns.Guilds:CreateBadge(pop, BADGE)
    pop.badge:SetFrameLevel(pop:GetFrameLevel() + 1)
    pop.confetti = {}
    for i = 1, CONFETTI do
        local c = Tex(WHITE, "OVERLAY")
        c:SetSize(4, 6)
        -- Spread over the upper half, alternating a little, each its own speed.
        c.angle = (i / CONFETTI) * math.pi + (i % 2) * 0.15
        c.speed = 90 + (i * 37 % 50)
        c.spin = 4 + i % 5
        pop.confetti[i] = c
    end
    pop.title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    pop.title:SetShadowOffset(1, -1)
    pop.sub = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pop.sub:SetShadowOffset(1, -1)
    pop.sub:SetText("Joined the guild")
end

local function Launch(join)
    if not pop then NewPop() end
    pop.join, pop.age = join, 0
    ns.Guilds:SetBadge(pop.badge, join.tabard)
    local tabard = join.tabard or {}
    local colors = { tabard.bg or { 0.85, 0.15, 0.1 }, tabard.border or GOLD, tabard.emblemColor or { 1, 1, 1 } }
    for i, c in ipairs(pop.confetti) do
        c:SetVertexColor(unpack(colors[i % 3 + 1]))
    end
    pop.title:SetText("<" .. join.name .. ">")
    pop:Show()
end

local function Draw()
    local a, join = pop.age, pop.join
    local x, y = ns.Map:WorldToCanvas(join.c, join.x, join.y)
    if not x then
        pop:Hide()
        return
    end
    pop:ClearAllPoints()
    pop:SetPoint("CENTER", parent, "TOPLEFT", x, y + LIFT)
    local out = 1 - Clamp((a - (LENGTH - OUT)) / OUT)

    local drop = EaseOutBounce(Clamp(a / LAND))
    pop.badge:ClearAllPoints()
    pop.badge:SetPoint("CENTER", pop, "CENTER", 0, DROP * (1 - drop))
    pop.badge:SetAlpha(Clamp(a / 0.15) * out)

    local since = a - TOUCH
    local f = Clamp(since / 0.5)
    pop.flash:SetSize(40 + 140 * f, 40 + 140 * f)
    pop.flash:SetPoint("CENTER")
    pop.flash:SetAlpha(since > 0 and (1 - f) or 0)
    pop.rays:SetPoint("CENTER")
    pop.rays:SetRotation(a * 0.7)
    pop.rays:SetAlpha(since > 0 and 0.7 * Clamp(since / 0.3) * out or 0)

    local t = math.max(0, since)
    for _, c in ipairs(pop.confetti) do
        c:ClearAllPoints()
        c:SetPoint("CENTER", pop, "CENTER", math.cos(c.angle) * c.speed * t * 0.9,
            math.sin(c.angle) * c.speed * t - 160 * t * t)
        c:SetRotation(t * c.spin)
        c:SetAlpha(since > 0 and Clamp(1.6 - t) * out or 0)
    end

    local s = EaseOutBack(Clamp((a - LAND) / 0.35))
    pop.title:ClearAllPoints()
    pop.title:SetPoint("TOP", pop, "CENTER", 0, -BADGE / 2 - 6 - 12 * (1 - s))
    pop.title:SetAlpha(Clamp((a - LAND) / 0.2) * out)
    pop.sub:ClearAllPoints()
    pop.sub:SetPoint("TOP", pop.title, "BOTTOM", 0, -1)
    pop.sub:SetAlpha(Clamp((a - LAND - 0.2) / 0.3) * out)
end

-- Reads the journey's joins again; call when the map opens. The guild the
-- character was already in when tracking began has no join to show.
function GuildPop:Rebuild()
    self:Clear()
    wipe(joins)
    for _, e in ipairs(ns.view.events) do
        if e[2] == "gj" and not e[8] then
            joins[#joins + 1] = { t = e[1], c = e[3], x = e[4], y = e[5], name = e[6] or "?", tabard = e[9] }
        end
    end
end

-- The replay moved forward from time from to time to: queue what it passed.
function GuildPop:Passed(from, to)
    if not parent or to <= from or not ns.FilterShown("guilds") then return end
    for _, join in ipairs(joins) do
        if join.t > from and join.t <= to then
            waiting[#waiting + 1] = join
        end
    end
    while #waiting > MAX_WAITING do
        table.remove(waiting, 1)
    end
end

-- Moves the animation on; call every frame while the map is open.
function GuildPop:Update(elapsed)
    if not parent then return end
    if pop and pop.join then
        pop.age = pop.age + elapsed
        if pop.age >= LENGTH then
            pop.join = nil
            pop:Hide()
        else
            Draw()
            return
        end
    end
    if #waiting > 0 then
        Launch(table.remove(waiting, 1))
        Draw()
    end
end

-- Takes the pop off the map at once, such as when the map closes.
function GuildPop:Clear()
    wipe(waiting)
    if pop then
        pop.join = nil
        pop:Hide()
    end
end

-- Draws the pop on frame (the map's overlay).
function GuildPop:Attach(frame)
    parent = frame
end
