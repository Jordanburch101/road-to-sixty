local _, ns = ...

-- Quest turn-ins popping up on the journey map as the replay passes them:
-- the game's turn-in "?" with a golden glow, a ray burst and sparks, then
-- the quest's name and experience. One turn-in on its own takes its time;
-- several close together play one after another, each new one sending the
-- last on its way faster, so a run of five ripples through quickly.

local QuestPop = {}
ns.QuestPop = QuestPop

local ICON_ATLAS = "QuestTurnin"
local ICON_FILE = "Interface\\GossipFrame\\ActiveQuestIcon"
local GLOW = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local STAR = "Interface\\Cooldown\\star4"

local IN = 0.35          -- seconds to pop in
local HOLD = 1.8         -- on show when nothing else is waiting
local OUT = 0.5          -- seconds to fade out, alone
local OUT_FAST = 0.22    -- fading out to make way for the next one
local MAX_WAITING = 6    -- more than this and the oldest waiting are skipped
local SPARKS = 6
local GOLD = { 1, 0.82, 0.25 }

local parent             -- the map's overlay
local turnins = {}       -- { t, c, x, y, id, xp, title } in time order
local waiting = {}       -- turn-ins passed but not shown yet
local active = {}        -- pops on screen, oldest first
local pool = {}

local function EaseOutBack(p)
    local c = 1.7
    p = p - 1
    return 1 + (c + 1) * p * p * p + c * p * p
end

local function NewPop()
    local pop = CreateFrame("Frame", nil, parent)
    pop:SetSize(32, 32)
    pop:SetFrameLevel(parent:GetFrameLevel() + 30)

    pop.glow = pop:CreateTexture(nil, "BACKGROUND")
    pop.glow:SetTexture(GLOW)
    pop.glow:SetBlendMode("ADD")
    pop.glow:SetVertexColor(unpack(GOLD))
    pop.glow:SetPoint("CENTER")

    pop.rays = pop:CreateTexture(nil, "BORDER")
    pop.rays:SetTexture(STAR)
    pop.rays:SetBlendMode("ADD")
    pop.rays:SetVertexColor(unpack(GOLD))
    pop.rays:SetPoint("CENTER")

    pop.burst = pop:CreateTexture(nil, "BORDER")
    pop.burst:SetTexture(GLOW)
    pop.burst:SetBlendMode("ADD")
    pop.burst:SetVertexColor(1, 0.95, 0.7)
    pop.burst:SetPoint("CENTER")

    pop.sparks = {}
    for i = 1, SPARKS do
        local spark = pop:CreateTexture(nil, "ARTWORK")
        spark:SetTexture(STAR)
        spark:SetBlendMode("ADD")
        spark:SetVertexColor(1, 0.9, 0.5)
        spark:SetSize(10, 10)
        pop.sparks[i] = spark
    end

    pop.icon = pop:CreateTexture(nil, "OVERLAY")
    pop.icon:SetPoint("CENTER")
    if not pop.icon:SetAtlas(ICON_ATLAS) then
        pop.icon:SetTexture(ICON_FILE)
    end

    pop.title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pop.title:SetPoint("TOP", pop, "BOTTOM", 0, -4)
    pop.title:SetShadowOffset(1, -1)
    pop.xp = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pop.xp:SetPoint("TOP", pop.title, "BOTTOM", 0, -1)
    pop.xp:SetShadowOffset(1, -1)
    return pop
end

local function Launch(turnin)
    local pop = table.remove(pool) or NewPop()
    pop.turnin = turnin
    pop.age, pop.outAt, pop.outTime = 0, nil, OUT
    pop.spin = math.random() * math.pi * 2
    for i, spark in ipairs(pop.sparks) do
        spark.angle = (i / SPARKS + math.random() * 0.12) * math.pi * 2
        spark.reach = 26 + math.random() * 14
    end
    pop.title:SetText(turnin.title or "Quest complete")
    pop.xp:SetText(turnin.xp and turnin.xp > 0 and ("+" .. ns.Commas(turnin.xp) .. " xp") or "")
    pop:Show()
    active[#active + 1] = pop
end

-- Starts the fade, now or soon: fast when making way for the next one.
local function SendOut(pop, fast)
    local at = math.max(pop.age, IN)
    if not pop.outAt or at < pop.outAt then
        pop.outAt = at
    end
    if fast then pop.outTime = OUT_FAST end
end

-- Time on show before the next waiting one may come in.
local function Gap()
    return math.max(0.14, 0.6 - 0.09 * #waiting)
end

local function Draw(pop)
    local a = pop.age
    local x, y = ns.Map:WorldToCanvas(pop.turnin.c, pop.turnin.x, pop.turnin.y)
    if not x then
        pop:Hide()
        return
    end

    local scale, alpha, rise = 1, 1, 0
    if a < IN then
        local p = a / IN
        scale, alpha = 0.3 + 0.7 * EaseOutBack(p), p
    end
    if pop.outAt and a > pop.outAt then
        local p = math.min(1, (a - pop.outAt) / pop.outTime)
        alpha = 1 - p
        scale = 1 - 0.15 * p
        rise = 14 * p
    end
    pop:ClearAllPoints()
    pop:SetPoint("CENTER", parent, "TOPLEFT", x, y + 18 + rise)
    pop:SetAlpha(alpha)

    pop.icon:SetSize(24 * scale, 24 * scale)
    -- Soft glow that swells in, then breathes.
    local breathe = 0.85 + 0.15 * math.sin(a * 5)
    local glow = 56 * scale * (a < IN and 1.3 or breathe)
    pop.glow:SetSize(glow, glow)
    pop.glow:SetAlpha(0.9)
    -- Slowly turning rays.
    pop.rays:SetSize(64 * scale, 64 * scale)
    pop.rays:SetRotation(pop.spin + a * 0.8)
    pop.rays:SetAlpha(0.55 * breathe)
    -- A bright flash that rings outwards at the start.
    local b = math.min(1, a / 0.45)
    pop.burst:SetSize(30 + 90 * b, 30 + 90 * b)
    pop.burst:SetAlpha(1 - b)
    -- Sparks flying out and fading.
    local s = math.min(1, a / 0.7)
    for _, spark in ipairs(pop.sparks) do
        local r = spark.reach * (1 - (1 - s) * (1 - s))
        spark:ClearAllPoints()
        spark:SetPoint("CENTER", math.cos(spark.angle) * r, math.sin(spark.angle) * r)
        spark:SetAlpha(1 - s)
        spark:SetRotation(spark.angle + a * 3)
    end
    pop:Show()
end

-- Reads the journey's turn-ins again; call when the map opens.
function QuestPop:Rebuild()
    self:Clear()
    wipe(turnins)
    for _, e in ipairs(ns.char.events) do
        if e[2] == "qd" then
            turnins[#turnins + 1] = { t = e[1], c = e[3], x = e[4], y = e[5], id = e[6], xp = e[7], title = e[9] }
        end
    end
end

-- The replay moved forward from time from to time to: queue what it passed.
function QuestPop:Passed(from, to)
    if not (parent and ns.db.questPops) or to <= from then return end
    -- First turn-in after from.
    local lo, hi = 1, #turnins + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if turnins[mid].t <= from then lo = mid + 1 else hi = mid end
    end
    for i = lo, #turnins do
        local turnin = turnins[i]
        if turnin.t > to then break end
        if not turnin.title then
            local ok, title = pcall(C_QuestLog.GetTitleForQuestID, turnin.id)
            turnin.title = ok and title ~= "" and title or nil
        end
        waiting[#waiting + 1] = turnin
    end
    while #waiting > MAX_WAITING do
        table.remove(waiting, 1)
    end
end

-- Moves the animations on; call every frame while the map is open.
function QuestPop:Update(elapsed)
    if not parent then return end
    local newest = active[#active]
    if #waiting > 0 and (not newest or newest.age >= Gap()) then
        if newest then SendOut(newest, true) end
        Launch(table.remove(waiting, 1))
    elseif newest and not newest.outAt and newest.age >= IN + HOLD then
        SendOut(newest, false)
    end
    for i = #active, 1, -1 do
        local pop = active[i]
        pop.age = pop.age + elapsed
        if pop.outAt and pop.age >= pop.outAt + pop.outTime then
            pop:Hide()
            table.remove(active, i)
            pool[#pool + 1] = pop
        else
            Draw(pop)
        end
    end
end

-- Removes every pop at once, such as when the map closes.
function QuestPop:Clear()
    wipe(waiting)
    for i = #active, 1, -1 do
        active[i]:Hide()
        pool[#pool + 1] = active[i]
        active[i] = nil
    end
end

-- Draws the pops on frame (the map's overlay).
function QuestPop:Attach(frame)
    parent = frame
end
