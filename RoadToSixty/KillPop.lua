local _, ns = ...

-- Kills popping up at the replay's arrow as it passes them: crossed swords
-- with a red hit flash, and the experience floating up like combat text,
-- with the mob's name. Kills in a row add up into a counter (x5), so a fast
-- replay or a dungeon run does not flood the map.

local KillPop = {}
ns.KillPop = KillPop

local GLOW = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local SWORDS = "Interface\\Cursor\\Attack"

local LIFE = 0.9          -- seconds on screen
local RISE = 26           -- pixels the text floats up
local GAP = 0.12          -- least time between two pops
local MAX_WAITING = 3     -- more than this and the oldest waiting are skipped
local COMBO_WINDOW = 1.2  -- seconds; kills closer than this count up together
local XP_SIZE = 14
local HIT_COLOR = { 1, 0.3, 0.15 }

local parent
local kills = {}          -- { t, xp, name } in time order
local waiting, active, pool = {}, {}, {}
local clock, lastLaunch = 0, -math.huge
local combo, comboAt = 0, -math.huge

-- Outlined text, so it reads on any terrain. The size is the starting one.
local function OutlinedText(pop, template, size)
    local text = pop:CreateFontString(nil, "OVERLAY", template)
    local font = text:GetFont()
    text:SetFont(font, size, "OUTLINE")
    text:SetShadowOffset(1, -1)
    text:SetShadowColor(0, 0, 0, 0.8)
    return text
end

local function NewPop()
    local pop = CreateFrame("Frame", nil, parent)
    pop:SetSize(24, 24)
    pop:SetFrameLevel(parent:GetFrameLevel() + 28)

    pop.flash = pop:CreateTexture(nil, "BACKGROUND")
    pop.flash:SetTexture(GLOW)
    pop.flash:SetBlendMode("ADD")
    pop.flash:SetVertexColor(unpack(HIT_COLOR))
    pop.flash:SetPoint("CENTER")

    pop.icon = pop:CreateTexture(nil, "ARTWORK")
    pop.icon:SetTexture(SWORDS)
    pop.icon:SetPoint("CENTER")

    pop.xp = OutlinedText(pop, "GameFontHighlightLarge", XP_SIZE)
    pop.xp:SetPoint("LEFT", pop.icon, "RIGHT", 2, 0)
    pop.name = OutlinedText(pop, "GameFontHighlightSmall", 10)
    pop.name:SetPoint("TOPLEFT", pop.xp, "BOTTOMLEFT", 0, -1)
    pop.name:SetTextColor(0.9, 0.9, 0.9)
    return pop
end

local function Launch(kill)
    local pop = table.remove(pool) or NewPop()
    pop.age, pop.settled = 0, false
    pop.x, pop.y = ns.Map:ReplayPosition()
    if not pop.x then
        pool[#pool + 1] = pop
        return
    end
    local text = "+" .. kill.xp .. " xp"
    if combo >= 2 then
        text = text .. ("  |cffffd100x%d|r"):format(combo)
    end
    pop.xp:SetText(text)
    pop.name:SetText(kill.name or "")
    pop:Show()
    active[#active + 1] = pop
    lastLaunch = clock
end

local function Draw(pop)
    local a = pop.age
    local x, y = ns.Map:ContentToCanvas(pop.x, pop.y)
    local p = a / LIFE
    local ease = 1 - (1 - p) * (1 - p)
    pop:ClearAllPoints()
    pop:SetPoint("CENTER", parent, "TOPLEFT", x, y + 6 + RISE * ease)
    -- Full for most of its life, fading at the end.
    pop:SetAlpha(p < 0.6 and 1 or 1 - (p - 0.6) / 0.4)

    -- A punch in: big, then settling.
    local punch = a < 0.12 and 1.5 - 0.5 * a / 0.12 or 1
    if punch > 1 or not pop.settled then
        local font = pop.xp:GetFont()
        pop.xp:SetFont(font, XP_SIZE * punch, "OUTLINE")
        pop.settled = punch == 1
    end
    pop.icon:SetSize(20 * punch, 20 * punch)
    local f = math.min(1, a / 0.3)
    pop.flash:SetSize(20 + 40 * f, 20 + 40 * f)
    pop.flash:SetAlpha(1 - f)
end

-- Reads the journey's kills again; call when the map opens.
function KillPop:Rebuild()
    self:Clear()
    kills = ns.Journal:Kills()
end

-- The replay moved forward from time from to time to: queue what it passed.
function KillPop:Passed(from, to)
    if not (parent and ns.db.killPops) or to <= from then return end
    local lo, hi = 1, #kills + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if kills[mid].t <= from then lo = mid + 1 else hi = mid end
    end
    for i = lo, #kills do
        local kill = kills[i]
        if kill.t > to then break end
        combo = clock - comboAt <= COMBO_WINDOW and combo + 1 or 1
        comboAt = clock
        waiting[#waiting + 1] = kill
    end
    while #waiting > MAX_WAITING do
        table.remove(waiting, 1)
    end
end

-- Moves the animations on; call every frame while the map is open.
function KillPop:Update(elapsed)
    if not parent then return end
    clock = clock + elapsed
    if #waiting > 0 and clock - lastLaunch >= GAP then
        Launch(table.remove(waiting, 1))
    end
    for i = #active, 1, -1 do
        local pop = active[i]
        pop.age = pop.age + elapsed
        if pop.age >= LIFE then
            pop:Hide()
            table.remove(active, i)
            pool[#pool + 1] = pop
        else
            Draw(pop)
        end
    end
end

-- Removes every pop at once, such as when the map closes.
function KillPop:Clear()
    wipe(waiting)
    combo = 0
    for i = #active, 1, -1 do
        active[i]:Hide()
        pool[#pool + 1] = active[i]
        active[i] = nil
    end
end

-- Draws the pops on frame (the map's overlay).
function KillPop:Attach(frame)
    parent = frame
end
