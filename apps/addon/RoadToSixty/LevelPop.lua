local _, ns = ...

-- Reaching a level, played on the journey map as the replay passes it
-- (issue #21, picked from /rts levelprobe as "ding flip"): the level badge
-- pops up, its number flips from the old level to the new one with a golden
-- ring flash, and "Level N" springs in underneath in the level's colour.
-- Levels come often, so a pop is short, and when the replay passes several
-- at once only the newest plays. A level reached inside an instance plays
-- at the door the player went in by, where its marker is.

local LevelPop = {}
ns.LevelPop = LevelPop

local GLOW = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local BADGE_ATLAS = "UI-HUD-UnitFrame-SmallCircle"      -- the map's level marker
local PALE = { 1, 0.95, 0.7 }

local BADGE = 40
local LENGTH = 2.1          -- seconds on show
local OUT = 0.4             -- of which fading out
local FLIP = 0.35           -- when the number flips
local LIFT = 18             -- the badge sits this far above the spot

local parent                -- the map's overlay
local levels = {}           -- { t, c, x, y, level } in time order
local waiting               -- the newest level passed, waiting to play
local pop                   -- the one pop, made on first use

local function Clamp(p) return math.max(0, math.min(1, p)) end

local function EaseOutBack(p)
    local c = 1.7
    p = p - 1
    return 1 + (c + 1) * p * p * p + c * p * p
end

local function NewPop()
    pop = CreateFrame("Frame", nil, parent)
    pop:SetSize(1, 1)
    pop:SetFrameLevel(parent:GetFrameLevel() + 32)
    pop.flash = pop:CreateTexture(nil, "BORDER")
    pop.flash:SetTexture(GLOW)
    pop.flash:SetBlendMode("ADD")
    pop.flash:SetVertexColor(unpack(PALE))
    pop.flash:SetPoint("CENTER")
    pop.badge = CreateFrame("Frame", nil, pop)
    pop.badge:SetSize(BADGE, BADGE)
    pop.badge:SetFrameLevel(pop:GetFrameLevel() + 1)
    local circle = pop.badge:CreateTexture(nil, "ARTWORK")
    circle:SetAllPoints()
    circle:SetAtlas(BADGE_ATLAS)
    pop.number = pop.badge:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    pop.number:SetPoint("CENTER", 0.5, 0)
    pop.number:SetTextColor(1, 1, 1)
    pop.number:SetShadowOffset(1, -1)
    pop.title = pop:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    pop.title:SetShadowOffset(1, -1)
end

local function Launch(entry)
    if not pop then NewPop() end
    pop.entry, pop.age = entry, 0
    pop.title:SetText("Level " .. entry.level)
    pop.title:SetTextColor(ns.LevelColor(entry.level))
    -- The level's marker stays hidden until the pop has finished.
    pop.marker = ns.Map:LevelMarker(entry.t)
    if pop.marker then
        pop.marker.popping = (pop.marker.popping or 0) + 1
        ns.Map:RefreshMarkers()
    end
    pop:Show()
end

-- Takes the pop off the map and gives its marker back.
local function Release()
    pop.entry = nil
    pop:Hide()
    local m = pop.marker
    if m then
        m.popping = m.popping and m.popping > 1 and m.popping - 1 or nil
        pop.marker = nil
        ns.Map:RefreshMarkers()
    end
end

local function Draw()
    local a, entry = pop.age, pop.entry
    local x, y = ns.Map:WorldToCanvas(entry.c, entry.x, entry.y)
    if not x then
        pop:Hide()
        return
    end
    pop:Show()
    pop:ClearAllPoints()
    pop:SetPoint("CENTER", parent, "TOPLEFT", x, y + LIFT)
    local out = 1 - Clamp((a - (LENGTH - OUT)) / OUT)

    -- Pops up from small, overshooting a little.
    local s = math.max(0.05, EaseOutBack(Clamp(a / 0.3)))
    pop.badge:SetScale(s)
    pop.badge:ClearAllPoints()
    pop.badge:SetPoint("CENTER", pop, "CENTER", 0, 0)
    pop.badge:SetAlpha(Clamp(a / 0.1) * out)

    -- The number flips like a card: the old one squashes flat, the new one
    -- opens out a little large and settles.
    local f = Clamp((a - FLIP) / 0.24)
    pop.number:SetText(f < 0.5 and (entry.level - 1) or entry.level)
    pop.number:SetScale(math.max(0.05, math.abs(1 - 2 * f)) * (f < 0.5 and 1 or 1.15 - 0.15 * f))

    local since = a - FLIP - 0.12
    local g = Clamp(since / 0.45)
    pop.flash:SetSize(30 + 110 * g, 30 + 110 * g)
    pop.flash:SetAlpha(since > 0 and (1 - g) or 0)

    local t = EaseOutBack(Clamp((a - 0.55) / 0.3))
    pop.title:ClearAllPoints()
    pop.title:SetPoint("TOP", pop, "CENTER", 0, -BADGE / 2 - 6 - 10 * (1 - t))
    pop.title:SetAlpha(Clamp((a - 0.55) / 0.15) * out)
end

-- Reads the journey's levels again; call when the map opens. The level the
-- character had when tracking began has no "lvl" event, so no pop.
function LevelPop:Rebuild()
    self:Clear()
    wipe(levels)
    local door
    for _, e in ipairs(ns.view.events) do
        if e[2] == "in" and e[3] ~= -1 then
            door = e
        elseif e[2] == "lvl" then
            local c, x, y = e[3], e[4], e[5]
            if c == -1 and door then
                c, x, y = door[3], door[4], door[5]
            end
            levels[#levels + 1] = { t = e[1], c = c, x = x, y = y, level = e[6] or 0 }
        end
    end
end

-- The replay moved forward from time from to time to: the newest level it
-- passed waits to play, in place of any older one still waiting.
function LevelPop:Passed(from, to)
    if not parent or to <= from or not ns.FilterShown("levels") then return end
    for _, entry in ipairs(levels) do
        if entry.t > from and entry.t <= to then
            waiting = entry
        end
    end
end

-- Moves the animation on; call every frame while the map is open.
function LevelPop:Update(elapsed)
    if not parent then return end
    if pop and pop.entry then
        pop.age = pop.age + elapsed
        -- A newer level cuts a pop short once its number has flipped.
        if pop.age >= LENGTH or (waiting and pop.age > FLIP + 0.3) then
            Release()
        else
            Draw()
            return
        end
    end
    if waiting then
        Launch(waiting)
        waiting = nil
        Draw()
    end
end

-- Takes the pop off the map at once, such as when the map closes.
function LevelPop:Clear()
    waiting = nil
    if pop and pop.entry then
        Release()
    end
end

-- Draws the pop on frame (the map's overlay).
function LevelPop:Attach(frame)
    parent = frame
end
