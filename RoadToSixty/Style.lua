local _, ns = ...

-- How the journey looks, shared by the map, the side panel and the replay
-- effects: path colours by level, jump arc styles, event icons, class
-- icons, History categories, boat docks and small formatting helpers. No
-- state lives here. Everything other files use is on ns; the tables stay
-- local.

-- Path colour by level, after item quality: common, uncommon, rare, epic,
-- legendary, artifact. { first level of the next band, r, g, b }
local LEVEL_COLORS = {
    { 10, 1, 1, 1 },
    { 20, 0.12, 1, 0 },
    { 30, 0.25, 0.6, 1 },       -- lighter than item blue, so it shows on terrain
    { 40, 0.64, 0.21, 0.93 },
    { 50, 1, 0.5, 0 },
    { math.huge, 0.9, 0.8, 0.5 },
}
local MODE_ALPHA = { w = 0.95, t = 0.5 }     -- on foot or mounted, flight path

local FLIGHT_COLOR = { 0.35, 0.75, 1, 0.9 }  -- flight paths, whatever the level

-- Jumps between segments are drawn as arcs, styled by why the path jumped
-- (seg.j in Recorder.lua): { label, r, g, b, a, style = "dots", "dash" or
-- "solid", icon = atlas at the top of the arc }.
local JUMP_STYLES = {
    h = { "Hearthstone", 0.3, 1, 0.45, 1, style = "dots", icon = "Innkeeper" },
    p = { "Teleport", 0.8, 0.45, 1, 1, style = "solid", icon = "MagePortalAlliance" },
    d = { "Died - to the graveyard", 0.85, 0.85, 0.95, 0.9, style = "dots" },
    i = { "Through an instance", 1, 0.6, 0.2, 1, style = "dash" },
    b = { "Boat or zeppelin", 0.3, 0.85, 0.85, 1, style = "dash", icon = "poi-islands-table" },
    l = { "Logged in", 1, 1, 1, 0.7, style = "dots" },
}
local JUMP_UNKNOWN = { "Teleported", 1, 1, 1, 0.8, style = "dots" }

-- Style of a jump by its reason (seg.j), or the unknown style.
function ns.JumpStyle(reason)
    return JUMP_STYLES[reason] or JUMP_UNKNOWN
end

-- Colour of a level band's path: r, g, b.
function ns.BandColor(band)
    local entry = LEVEL_COLORS[band]
    return entry[2], entry[3], entry[4]
end

local GHOST_COLOR = { 0.85, 0.85, 0.95, 0.5 }   -- corpse runs
local CLASS_ICONS = "Interface\\TargetingFrame\\UI-Classes-Circles"

-- Event icons, shared with the side panel. { atlas, size }
-- { atlas = name } or { file = texture path }, and size. Spell and item icons
-- (file) are cropped to hide their border.
local EVENT_ICONS = {
    lvl = { atlas = "UI-HUD-UnitFrame-SmallCircle", size = 22 },
    die = { atlas = "DungeonSkull", size = 16 },
    ["in"] = { atlas = "Dungeon", size = 20 },
    run = { atlas = "Dungeon", size = 20 },
    zone = { atlas = "Waypoint-MapPin-Untracked", size = 16 },
    flight = { atlas = "TaxiNode_Neutral", size = 18 },
    hearth = { atlas = "Innkeeper", size = 18 },
    teleport = { atlas = "MagePortalAlliance", size = 20 },
    boat = { atlas = "poi-islands-table", size = 20 },
    loot = { file = "Interface\\Icons\\INV_Misc_QuestionMark", size = 18 },
    qd = { atlas = "QuestTurnin", fallback = "Interface\\GossipFrame\\ActiveQuestIcon", size = 18 },
    prof = { file = "Interface\\Icons\\INV_Misc_Book_11", size = 18 },
    rec = { file = "Interface\\Icons\\INV_Scroll_03", size = 16 },
}

local INSTANCE_TYPES = {
    party = "Dungeon",
    raid = "Raid",
    pvp = "Battleground",
    arena = "Arena",
}
ns.InstanceTypes = INSTANCE_TYPES

function ns.LevelBand(level)
    for band, entry in ipairs(LEVEL_COLORS) do
        if level < entry[1] then return band end
    end
    return #LEVEL_COLORS
end

function ns.LevelColor(level)
    local entry = LEVEL_COLORS[ns.LevelBand(level)]
    return entry[2], entry[3], entry[4]
end

function ns.ClassColor(class)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color then
        return color.r, color.g, color.b
    end
    return 0.8, 0.8, 0.8
end

function ns.SetClassIcon(texture, class)
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then
        texture:SetTexture(CLASS_ICONS)
        texture:SetTexCoord(unpack(coords))
    else
        texture:SetTexture(nil)
    end
end

function ns.ClassName(class)
    return LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class or "?"
end

-- The History filter applies to the map too. Category of each jump reason
-- (seg.j); reasons without one are always shown.
ns.JUMP_CATEGORY = { h = "hearths", p = "teleports", b = "boats", d = "deaths", i = "dungeons" }
ns.MARKER_CATEGORY = {
    lvl = "levels", die = "deaths", ["in"] = "dungeons", qd = "quests", prof = "professions", rec = "recipes",
}

-- False if the player has turned this History filter category off.
function ns.FilterShown(category)
    return not category or ns.db.historyFilter[category] ~= false
end

-- Boat and zeppelin docks, in world yards: { name, continentID, x, y }. A
-- boat jump is named after the docks nearest its two ends. Stormwind Harbor
-- and Auberdine come from a recorded trip; the others are estimates, hence
-- the generous range.
local DOCKS = {
    { "Stormwind Harbor", 0, -8550, 1450 },
    { "Menethil Harbor", 0, -3800, -700 },
    { "Booty Bay", 0, -14350, 450 },
    { "Undercity zeppelin", 0, 2070, 290 },
    { "Grom'gol zeppelin", 0, -12410, 210 },
    { "Auberdine", 1, 6650, 950 },
    { "Rut'theran Village", 1, 8450, 1000 },
    { "Theramore", 1, -3900, -4600 },
    { "Ratchet", 1, -950, -3750 },
    { "Orgrimmar zeppelin", 1, 1330, -4650 },
}
local DOCK_RANGE = 2500

-- The dock nearest a world position, or nil if none is within DOCK_RANGE.
function ns.DockName(c, x, y)
    local best, bestD = nil, DOCK_RANGE * DOCK_RANGE
    for _, dock in ipairs(DOCKS) do
        if dock[2] == c then
            local d = (dock[3] - x) ^ 2 + (dock[4] - y) ^ 2
            if d < bestD then
                best, bestD = dock[1], d
            end
        end
    end
    return best
end

-- "Stormwind Harbor to Auberdine" for a boat trip between two world
-- positions, or nil unless both ends are near a dock.
function ns.BoatRoute(c1, x1, y1, c2, x2, y2)
    local from, to = ns.DockName(c1, x1, y1), ns.DockName(c2, x2, y2)
    return from and to and (from .. " to " .. to)
end

-- "5m ago", "3h ago", "2d ago".
function ns.FormatAgo(t)
    local seconds = time() - (t or 0)
    if seconds < 3600 then return ("%dm ago"):format(math.max(1, math.floor(seconds / 60))) end
    if seconds < 86400 then return ("%dh ago"):format(math.floor(seconds / 3600)) end
    return ("%dd ago"):format(math.floor(seconds / 86400))
end

-- Quality borders over item icons, by item quality (2 green to 5 orange),
-- for looted items in the History list and the loot filters.
local QUALITY_BORDERS = {
    [2] = "loottoast-itemborder-green", [3] = "loottoast-itemborder-blue",
    [4] = "loottoast-itemborder-purple", [5] = "loottoast-itemborder-orange",
}

-- Shows overlay (a texture over an icon) as the quality's border, or hides
-- it when quality is nil or below green.
function ns.SetQualityOverlay(overlay, quality)
    local atlas = quality and QUALITY_BORDERS[math.min(quality, 5)]
    if atlas then
        overlay:SetAtlas(atlas)
    end
    overlay:SetShown(atlas ~= nil)
end

-- Sets icon (a texture) and text (a font string on top of it) for an event
-- kind. file, if given, replaces the kind's own icon (an item's icon for
-- loot). Level icons are the player frame's level badge with the level
-- number in white on top. Returns the icon size.
function ns.SetEventIcon(icon, text, kind, level, file)
    local style = EVENT_ICONS[kind]
    if file or style.file then
        icon:SetTexture(file or style.file)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    elseif not icon:SetAtlas(style.atlas) and style.fallback then
        icon:SetTexture(style.fallback)
        icon:SetTexCoord(0, 1, 0, 1)
    end
    icon:SetVertexColor(1, 1, 1)
    text:SetText("")
    if kind == "lvl" then
        text:SetText(level)
        text:SetTextColor(1, 1, 1)
        text:SetShadowOffset(1, -1)
    end
    return style.size
end

-- Colour of a line for movement mode and level band: r, g, b, a.
function ns.LineColor(mode, band)
    if mode == "g" then
        return unpack(GHOST_COLOR)
    elseif mode == "t" then
        return unpack(FLIGHT_COLOR)
    end
    local entry = LEVEL_COLORS[band]
    return entry[2], entry[3], entry[4], MODE_ALPHA[mode]
end

-- Movement mode names for tooltips.
ns.MODE_NAMES = { w = "On foot", t = "Flight path", g = "Ghost" }
