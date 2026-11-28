local _, ns = ...

-- Where the player fought other players in the open world, on the journey
-- map zoomed out: players killed ("hk", WorldPvP.lua) and deaths by players
-- (Deaths.ByPlayer) close together on screen show as one battle, a framed
-- icon with how many there were, over a glow on the land that grows with
-- them: amber where the player killed at least as often as they died, red
-- where they died more (look C of the mock-ups, Jordan's pick). Grouped on
-- screen each time the map places its markers, so a battle splits as the
-- map zooms in, and from HIDE_ZOOM on the battles go and each kill and death
-- shows as its own marker (Map.lua shows those only from there). Nothing is
-- saved: they are worked out from the events.
--
-- Events inside battlegrounds and arenas are left out: their place is where
-- the player queued from (Collect says why dungeons are not). They follow the replay, the
-- date range and the History filters ("worldPvP" for kills, "pvpDeaths"
-- for deaths). Hovering one lists what happened there; a click zooms in on
-- it.
--
-- The pure part, tested offline (tests/battles_test.lua):
--   Battles.Collect(events, toContent, me) -> entries (me: the journey's own
--     names as a set, Deaths.OwnNames, so a death by the player's own blow is left out), each { t, c, wx, wy, x, y,
--     kill, death, honor, name, class, zone }: wx, wy the world yards, x, y
--     the map's content units (toContent[c]), zone the uiMapID last entered.
--   Battles.Group(entries, place, radius) -> battles, each { x, y (screen),
--     kills, deaths, honor, first, last, entries }: entries place(entry)
--     puts on screen (nil leaves one out), each joining the battle whose
--     middle is nearest within radius pixels, in time order.
--   Battles.Summary(battle) -> { zone, victim, killer } (most often, each
--     { name, class, count }).

local Battles = {}
ns.Battles = Battles

Battles.HIDE_ZOOM = 6       -- from this zoom on, the kills and deaths show one by one (Map.lua's MARKER_ZOOM.hk)
local RADIUS = 44           -- screen pixels: kills and deaths this near one battle's middle join it
local ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"    -- a placeholder until Jordan picks from /rts swatch icons
local GLOW = "Interface\\AddOns\\RoadToSixty\\killmark"         -- the kill marks' soft round blob, white
local AMBER, RED = { 1, 0.55, 0.15 }, { 1, 0.18, 0.12 }
local FRAME_RED = { 1, 0.4, 0.35 }

-- Collecting and grouping ------------------------------------------------------

-- As Deaths.ByPlayer: a player's or a pet's killing blow, not the player's
-- own (an explosive backfiring; me, the journey's own names as a set, for
-- deaths saved before "self").
local function ByPlayer(e, me)
    if e[7] == "pet" then return true end
    return e[7] == "p" and not (type(me) == "table" and me[e[6]] == true)
end

-- Only battlegrounds and arenas are left out: no enemy player can reach the
-- player inside a dungeon or raid, and a dungeon's "out" can come long after
-- it was left (Journal.lua waits RUN_GAP for a run back in, and logs none
-- when there is one), which would leave out the fighting at its door.
local PVP = { pvp = true, arena = true }

function Battles.Collect(events, toContent, me)
    local entries, inside, zone = {}, false, nil
    for _, e in ipairs(events or {}) do
        local kind = e[2]
        if kind == "in" then
            inside = PVP[e[8]] == true
        elseif kind == "out" then
            inside = false
        elseif kind == "zone" then
            zone = e[6]
        elseif not inside and (kind == "hk" or kind == "die" and ByPlayer(e, me)) then
            local to = toContent[e[3]]
            if to then
                local x, y = to(e[4], e[5])
                local kill = kind == "hk"
                entries[#entries + 1] = {
                    t = e[1], c = e[3], wx = e[4], wy = e[5], x = x, y = y, kill = kill, death = not kill,
                    honor = kill and tonumber(e[8]) or 0, name = e[6], class = kill and e[9] or nil, zone = zone,
                }
            end
        end
    end
    return entries
end

-- Every battle is looked at for each entry: there are few, and a battle's
-- middle moves as it grows, so a grid by where it started would miss it.
function Battles.Group(entries, place, radius)
    local battles = {}
    for _, entry in ipairs(entries) do
        local x, y = place(entry)
        if x then
            local best, bestD = nil, radius * radius
            for _, b in ipairs(battles) do
                local d = (b.x - x) ^ 2 + (b.y - y) ^ 2
                if d <= bestD then best, bestD = b, d end
            end
            if not best then
                best = { x = x, y = y, sx = 0, sy = 0, kills = 0, deaths = 0, honor = 0, first = entry.t, entries = {} }
                battles[#battles + 1] = best
            end
            local list = best.entries
            list[#list + 1] = entry
            best.sx, best.sy = best.sx + x, best.sy + y
            best.x, best.y = best.sx / #list, best.sy / #list
            best.kills = best.kills + (entry.kill and 1 or 0)
            best.deaths = best.deaths + (entry.death and 1 or 0)
            best.honor = best.honor + (entry.honor or 0)
            best.last = entry.t
        end
    end
    return battles
end

-- The one counted most; ties go to the one reached first.
local function Most(counts)
    local best
    for _, c in pairs(counts) do
        if not best or c.count > best.count or (c.count == best.count and c.first < best.first) then best = c end
    end
    return best
end

function Battles.Summary(battle)
    local zones, victims, killers = {}, {}, {}
    for _, entry in ipairs(battle.entries) do
        if entry.zone then
            local z = zones[entry.zone] or { name = entry.zone, count = 0, first = entry.t }
            z.count = z.count + 1
            zones[entry.zone] = z
        end
        if type(entry.name) == "string" then
            local list = entry.kill and victims or killers
            local who = list[entry.name] or { name = entry.name, count = 0, first = entry.t }
            who.count, who.class = who.count + 1, entry.class or who.class
            list[entry.name] = who
        end
    end
    local zone = Most(zones)
    return { zone = zone and zone.name, victim = Most(victims), killer = Most(killers) }
end

-- On the map -------------------------------------------------------------------

local layer
local entries = {}
local frames = {}

-- parent: the map's marker overlay. The battles sit at its markers' level,
-- not above them, as their glow would wash over the markers.
function Battles:Attach(parent)
    layer = CreateFrame("Frame", nil, parent)
    layer:SetAllPoints()
    layer:SetFrameLevel(parent:GetFrameLevel())
end

-- Every kill and death by a player that can show, after the map has built
-- its markers (toContent: the map's, by continent).
function Battles:Rebuild(toContent)
    entries = Battles.Collect(ns.view and ns.view.events, toContent or {}, ns.Deaths.OwnNames())
end

local GREY = { 0.6, 0.6, 0.6 }

local function Day(t)
    return tostring(date("%d %b", t)):gsub("^0", "")
end

local function ZoneName(id)
    local info = id and C_Map and C_Map.GetMapInfo(id)
    return info and info.name
end

local function Times(n)
    return n == 1 and "once" or ("%d times"):format(n)
end

-- The battle's tooltip: where, how many kills and deaths, the honor, when,
-- and who the player killed most and was killed by most there.
local function ShowTooltip(f)
    local b = f.battle
    local summary = Battles.Summary(b)
    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
    local zone = ZoneName(summary.zone)
    GameTooltip:AddLine(zone and ("Battle in %s"):format(zone) or "Battle", 1, 1, 1)
    GameTooltip:AddLine(" ")
    if b.kills > 0 then
        GameTooltip:AddDoubleLine("You killed", ("%d player%s"):format(b.kills, b.kills == 1 and "" or "s"),
            GREY[1], GREY[2], GREY[3], 0.93, 0.74, 0.3)
    end
    if b.deaths > 0 then
        GameTooltip:AddDoubleLine("They killed you", Times(b.deaths), GREY[1], GREY[2], GREY[3], 1, 0.42, 0.33)
    end
    if b.honor > 0 then
        GameTooltip:AddDoubleLine("Honor", ns.Commas(b.honor), GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    local first, last = Day(b.first), Day(b.last)
    GameTooltip:AddDoubleLine("Fought here", first == last and first or (first .. " to " .. last),
        GREY[1], GREY[2], GREY[3], 1, 1, 1)
    local victim, killer = summary.victim, summary.killer
    if victim and victim.count > 1 or killer and killer.count > 1 then GameTooltip:AddLine(" ") end
    if victim and victim.count > 1 then
        local r, g, bl = ns.ClassColor(victim.class)
        GameTooltip:AddDoubleLine("Killed most", ("%s, %s"):format(victim.name, Times(victim.count)),
            GREY[1], GREY[2], GREY[3], r, g, bl)
    end
    if killer and killer.count > 1 then
        GameTooltip:AddDoubleLine("Killed you most", ("%s, %s"):format(killer.name, Times(killer.count)),
            GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to zoom in", 0.25, 1, 0.25)
    GameTooltip:Show()
end

-- Zooms in on the battle, to its last kill or death, so all of it shows: on
-- a left click only, not at the end of a drag that began on it.
local CLICK_MOVE = 4        -- pixels the cursor may move between press and release
local function Pressed(f, button)
    f.pressed = button == "LeftButton" and { GetCursorPosition() } or nil
end

local function ZoomIn(f, button)
    local at = f.pressed
    f.pressed = nil
    if button ~= "LeftButton" or not at then return end
    local x, y = GetCursorPosition()
    local scale = f:GetEffectiveScale()
    if ((x - at[1]) ^ 2 + (y - at[2]) ^ 2) / (scale * scale) > CLICK_MOVE * CLICK_MOVE then return end
    local b = f.battle
    local c, sx, sy, n = b.entries[1].c, 0, 0, 0
    for _, entry in ipairs(b.entries) do
        if entry.c == c then sx, sy, n = sx + entry.wx, sy + entry.wy, n + 1 end
    end
    GameTooltip_Hide()
    ns.Map:JumpTo(b.last, c, sx / n, sy / n)
end

local function GetFrame(i)
    local f = frames[i]
    if f then return f end
    f = CreateFrame("Frame", nil, layer)
    f:EnableMouse(true)
    f.glow = f:CreateTexture(nil, "BACKGROUND")
    f.glow:SetTexture(GLOW)
    f.glow:SetBlendMode("ADD")
    f.glow:SetPoint("CENTER")
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetAllPoints()
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f:SetScript("OnEnter", ShowTooltip)
    f:SetScript("OnLeave", GameTooltip_Hide)
    f:SetScript("OnMouseDown", Pressed)
    f:SetScript("OnMouseUp", ZoomIn)
    frames[i] = f
    return f
end

-- Draws one battle: its glow's size and colour from how many kills and deaths
-- it holds; the icon at the size of every framed marker (#110), with the count.
local function Draw(f, b)
    local n = b.kills + b.deaths
    local g = ns.Style.Frame(f, ICON, ns.Style.MARKER_ICON)
    local lost = b.deaths > b.kills
    g.frame:SetVertexColor(unpack(lost and FRAME_RED or { 1, 1, 1 }))
    g.count:ClearAllPoints()
    g.count:SetPoint("BOTTOMRIGHT", g.icon, "BOTTOMRIGHT", 3, -2)
    g.count:SetText(n)
    g.count:SetShown(n > 1)
    local glow = math.min(150, 36 + 16 * math.sqrt(n))
    f.glow:SetSize(glow, glow)
    local color = lost and RED or AMBER
    f.glow:SetVertexColor(color[1], color[2], color[3], math.min(0.85, 0.45 + 0.06 * n))
    f.battle = b
    f:ClearAllPoints()
    f:SetPoint("CENTER", layer, "TOPLEFT", b.x, -b.y)
    f:Show()
end

-- Places the battles for the replay's time now and the zoom; toCanvas puts
-- content units on the map's canvas (Map.lua's UpdateMarkers calls this).
function Battles:Place(now, zoom, toCanvas)
    if not layer then return end
    local count = 0
    if zoom < Battles.HIDE_ZOOM then
        local kills, deaths = ns.FilterShown("worldPvP"), ns.FilterShown("pvpDeaths")
        local battles = Battles.Group(entries, function(entry)
            if entry.t > now or not ns.Range:Has(entry.t) then return end
            if entry.kill and not kills or entry.death and not deaths then return end
            return toCanvas(entry.x, entry.y)
        end, RADIUS)
        for i, b in ipairs(battles) do
            Draw(GetFrame(i), b)
        end
        count = #battles
    end
    for i = count + 1, #frames do
        frames[i]:Hide()
    end
end
