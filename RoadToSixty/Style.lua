local addonName, ns = ...

-- How the journey looks, shared by the map, the side panel and the replay
-- effects: path colours by level band, jump styles, event and class icons,
-- History filter categories and small formatting helpers. No state lives
-- here. Map.lua reaches the tables and helpers it needs through ns.Style.

local Style = {}
ns.Style = Style

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
local GHOST_COLOR = { 0.85, 0.85, 0.95, 0.5 }

-- Jumps between segments are drawn as arcs, styled by why the path jumped
-- (seg.j in Recorder.lua): { label, r, g, b, a, style = "dots", "dash",
-- "solid" or "ribbon", icon = atlas at the top of the arc, dot / spacing =
-- dot size and spacing in screen pixels, start / finish = texture at the
-- arc's start or end and its size, bend = how far the arc bends (JUMP_ARC
-- if unset), plain = a "solid" line as thin as the path with no outline }.
-- A ribbon is a band width pixels wide
-- in a deep shade of the colour, with effects flowing inside it: { texture
-- in Travel\ (scripts/lane-textures.py), its length over its height, speed
-- in repeats a second }. A "portal" jump has no line but a portal at each
-- end, which the replay's arrow dives through (Portals.lua); its pace times
-- the flight between. replay = seconds the replay's arrow takes along the
-- jump at normal speed (1 if unset); without, a jump would pass in a frame.
-- instant = the arrow does not travel the jump but appears at its end, for
-- jumps nobody travelled (logging out in one place and in at another).
-- With pace (map units a second; the world map is about 1000 wide) the time
-- follows the jump's length instead, replay being the least: a crossing by
-- sea takes a while, so the camera following it can load the terrain.
local JUMP_STYLES = {
    -- Portals in nature green for hearthstones and arcane blue for
    -- teleports, like a mage's. They were ribbons (vines or wisps with
    -- sparkles, { "vines", 8, 0.12 }, { "wisps", 8, 0.2 }, { "sparkles", 4, 0.3 })
    -- and may be again, see issue #18.
    h = { "Hearthstone", 0.4, 1, 0.45, 1, style = "portal", pace = 80 },
    p = { "Teleport", 0.35, 0.65, 1, 1, style = "portal", pace = 80 },
    d = { "Died - to the graveyard", 0.85, 0.85, 0.95, 0.9, style = "dots", replay = 0.6 },
    -- From the instance's door, where the path stopped, to the graveyard:
    -- drawn like the ghost's run back that follows it.
    di = { "Died in an instance - to the graveyard", GHOST_COLOR[1], GHOST_COLOR[2], GHOST_COLOR[3], GHOST_COLOR[4],
        style = "solid", plain = true, bend = 0, replay = 0.6 },
    i = { "Through an instance", 1, 0.6, 0.2, 1, style = "dash" },
    -- Sent out of an instance to a graveyard (left the group): portals, in grey.
    it = { "Teleported out of an instance", 0.75, 0.75, 0.8, 1, style = "portal", pace = 80 },
    -- Like a travel map in an adventure film: red dots from a target ring to
    -- an X where it lands.
    b = { "Boat or zeppelin", 0.9, 0.1, 0.08, 1, style = "dots", dot = 6, spacing = 11, replay = 2.5, pace = 60,
        start = { "Interface\\AddOns\\" .. addonName .. "\\Travel\\ring", 18 },
        finish = { "Interface\\AddOns\\" .. addonName .. "\\Travel\\cross", 22 } },
    l = { "Logged in", 1, 1, 1, 0.7, style = "dots", instant = true },
}
local JUMP_UNKNOWN = { "Teleported", 1, 1, 1, 0.8, style = "dots" }

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
    gj = { file = "Interface\\Icons\\INV_Shirt_GuildTabard_01", size = 20 },
    gl = { file = "Interface\\Icons\\INV_Shirt_GuildTabard_01", size = 18 },
    gr = { file = "Interface\\Icons\\INV_Shirt_GuildTabard_01", size = 18 },
    rep = { file = "Interface\\Icons\\Achievement_Reputation_01", size = 18 },
    ride = { file = "Interface\\Icons\\Ability_Mount_RidingHorse", size = 20 },
    mount = { file = "Interface\\Icons\\Ability_Mount_RidingHorse", size = 20 },
    rare = { atlas = "nameplates-icon-elite-silver", fallback = "Interface\\Icons\\INV_Misc_Head_Dragon_01", size = 20 },
    grp = { atlas = "socialqueuing-icon-group", size = 20 },
}

local INSTANCE_TYPES = {
    party = "Dungeon",
    raid = "Raid",
    pvp = "Battleground",
    arena = "Arena",
}
ns.InstanceTypes = INSTANCE_TYPES

local function LevelBand(level)
    for band, entry in ipairs(LEVEL_COLORS) do
        if level < entry[1] then return band end
    end
    return #LEVEL_COLORS
end

function ns.LevelColor(level)
    local entry = LEVEL_COLORS[LevelBand(level)]
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
local JUMP_CATEGORY = { h = "hearths", p = "teleports", b = "boats", d = "deaths", di = "deaths", i = "dungeons", it = "dungeons" }
local MARKER_CATEGORY = {
    lvl = "levels", die = "deaths", ["in"] = "dungeons", qd = "quests", prof = "professions", rec = "recipes",
    gj = "guilds", gl = "guilds", gr = "guilds", grp = "groups", rep = "reps",
    ride = "mounts", mount = "mounts", rare = "rares",
}

-- False if the player has turned this History filter category off.
function ns.FilterShown(category)
    return not category or ns.db.historyFilter[category] ~= false
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
local function LineColor(mode, band)
    if mode == "g" then
        return unpack(GHOST_COLOR)
    elseif mode == "t" then
        return unpack(FLIGHT_COLOR)
    end
    local entry = LEVEL_COLORS[band]
    return entry[2], entry[3], entry[4], MODE_ALPHA[mode]
end

-- Style of a jump by why the path jumped (seg.j), or the unknown style.
function Style.Jump(reason)
    return JUMP_STYLES[reason] or JUMP_UNKNOWN
end

Style.LEVEL_COLORS = LEVEL_COLORS
Style.JUMP_CATEGORY, Style.MARKER_CATEGORY = JUMP_CATEGORY, MARKER_CATEGORY
Style.LevelBand, Style.LineColor = LevelBand, LineColor
