local addonName, ns = ...

-- Journey map: one zoomable view of the whole world with the recorded path on
-- top. The world map art shows when zoomed out, continent maps fade in as you
-- zoom towards them, and minimap terrain fades in close up. Mouse wheel zooms,
-- left-drag pans, right-click zooms back out to the whole world.
--
-- Art, terrain and path lines all sit on one "content" frame laid out in world
-- map coordinates (content units: the world map art at its native size).
-- Panning and zooming only move and scale that frame, so they cost almost
-- nothing. The path and terrain are rebuilt only when the view drifts out of
-- the area they were last built for, or the zoom has changed a lot.

local Map = {}
ns.Map = Map
local Style = ns.Style   -- colours, icons and categories (Style.lua)

-- Replay pace in world yards per second at 1x, by mode (Recorder.lua), so the
-- star moves at the same map speed whatever the length of the journey: a
-- 1-10 replays in about two minutes, a 1-60 in tens of minutes. Yards rather
-- than points, as the recorder stores more points where the path bends (#57).
-- Half the 40 points a second it first went at (points were about 20 yards
-- apart walking, 80 flying): players found that too fast to follow.
-- Hearthstones, teleports and boats each take a time of their own (Style.lua,
-- Portals.lua); jumps scales that time the same way, here to half.
local REPLAY_YARDS = { w = 400, g = 400, t = 1600, jumps = 0.5 }
local SHAPE_PIXELS = 0.5        -- detail levels keep the path's shape to within this on screen at the finest level a zoom allows, up to four times it (PathShape.lua)
local MAX_LINES = 3000          -- line budget per build; past it, points merge further
-- The path is built for the view and a margin a view wide on every side, so
-- panning doesn't build it again at once: nine views, most of it unseen.
-- One detail level for all of it spent the budget there, and a town walked
-- through again and again merged its points 100 yards apart (#152). So,
-- unless all of it fits MAX_LINES as finely, the view and a little round
-- it (NEAR views past each edge) get the finest level that fits
-- NEAR_LINES, the rest keeps only a coarser level's points in what the
-- near part left (at least FAR_LINES, times FAR_SHARE; levels nest,
-- PathShape.lua's MakeLevel). Lines are drawn straight between the points
-- kept. The map builds again once the view leaves the near part:
-- when the zoom settles, and when a drag pauses for DRAG_PAUSE seconds.
-- MERGE is how near in pixels a newer walk must pass to a line for it to be
-- merged into it (PathShape.lua's MergeLines, DETAIL.Merge): the lines it
-- frees let the map draw about two levels finer at every zoom, at the same
-- cost (2026-11-19, Stormwind on a journey to 37). nil draws every line;
-- /rts merge turns it off and on in a developer build, to compare.
local DETAIL = { NEAR = 0.15, NEAR_LINES = 2700, FAR_LINES = 300, FAR_SHARE = 1, DRAG_PAUSE = 0.15, MERGE = 2 }
local LINE_WIDTH = 2
local SPEEDS = { 1, 2, 4, 8, 16, 32 }
-- Replaying together (see the Replay section), in one table as this file is
-- near Lua's limit on locals. SPEEDS are real seconds a second, and GAP how
-- long a stretch with nobody moving must be for the clock to skip it.
local Together = {}
Together.SPEEDS = {
    { 120, "2m/s" }, { 300, "5m/s" }, { 600, "10m/s" }, { 1800, "30m/s" }, { 3600, "1h/s" },
    { 7200, "2h/s" }, { 14400, "4h/s" }, { 28800, "8h/s" }, { 43200, "12h/s" }, { 86400, "1d/s" },
}
Together.GAP = 600
-- The two clocks, in the order the button goes through them.
Together.NEXT = { real = "game" }
Together.LABELS = { real = "Real Time", game = "Play Time" }
-- Saves up to 1.5.0 mark no logins: a break this long with no reason counts as one.
Together.OFFLINE_GAP = 1800
local MAX_ZOOM = 64
local ZOOM_STEP = 1.4
local ZOOM_SPEED = 12           -- higher settles the zoom animation faster
local REBUILD_ZOOM = math.log(math.sqrt(2))  -- rebuild the path after this much zoom
local PATH_MARGIN = 1           -- views of path built past each edge of the view
local TERRAIN_MARGIN = 0.25     -- same for terrain tiles
local MAX_TERRAIN_TILES = 1300  -- more tiles than this in range shows no terrain (one continent fits)
local TILES_PER_FRAME = 150     -- terrain tiles drawn in one frame; the rest follow over the next frames
local EDGE_FADE = 0.35          -- part of an edge tile that fades out where terrain ends
local CHUNK = 64                -- points per culling box in each detail level
local LOD_STEP = 2              -- merge distance grows by this much per detail level
local MAX_LOD = 20              -- coarsest detail level
local WARM_LODS = 8             -- detail levels 0 to this are pre-built in the background
local LOD_YIELD = 2048          -- points per frame when pre-building in the background
local TILE_YARDS = 533.33333    -- one ADT / minimap tile
local WORLD_MAP = 947           -- Azeroth, if it cannot be found from the player

-- Zoom levels where a layer starts to fade in and where it is fully shown.
local CONTINENT_FADE = { 1.6, 2.6 }
local TERRAIN_FADE = { 3, 5 }

-- Minimap terrain folder per continent ID, matching MinimapTiles.lua
ns.MinimapDirs = { [0] = "Azeroth", [1] = "Kalimdor", [2991] = "2991", [530] = "Expansion01" }

-- Arcane sparkles drifting along the visible path.
local MOTES = 40                -- most at once
local MOTE_SPEED = 30           -- screen pixels per second
local MOTE_TEXTURE = "Interface\\Cooldown\\star4"

-- Sizes in screen pixels.
local JUMP_LINE, JUMP_OUTLINE = 2.5, 5
local JUMP_DASH, JUMP_GAP = 7, 5
local JUMP_DOT, JUMP_DOT_SPACING = 5, 8
local JUMP_ICON = 18
local JUMP_ICON_ZOOM = 4        -- jump icons show from this zoom, or while their arc is hovered
local JUMP_ARC = 0.2            -- how far arcs bend, as a share of their length
local JUMP_ARC_STEPS = 16
local JUMP_MAX_PIECES = 150     -- dashes or dots per jump; spacing grows past this
local JUMP_OUTLINE_COLOR = { 0, 0, 0, 0.6 }

-- Hovering a line: how close the mouse must be, how often to check, and the
-- width of the highlight drawn over it.
local HOVER_PIXELS = 6
local HOVER_INTERVAL = 0.05
local HOVER_WIDTH = 5

-- Other characters from the roster: class icons at their last position and,
-- if turned on per character, their path in class colour.
local OTHER = {
    -- The same detail (DETAIL) and width as the journey shown; class colours
    -- and ALPHA tell them apart. ponytail: each ticked path can cost MAX_LINES
    -- lines a zoom frame; give them budgets of their own if several stutter.
    LINE_WIDTH = LINE_WIDTH,
    -- Alpha by movement mode, and for jumps (arcs, or a plain line when the
    -- reason is unknown, as between walking and a flight).
    ALPHA = { w = 0.55, t = 0.3, g = 0.2, j = 0.3 },
}

-- The replay's arrow, and how the view pans with it (FollowHead): parts of
-- the view's width and height, GLIDE how quickly the view catches up.
local HEAD = {
    TEXTURE = "Interface\\WorldMap\\WorldMapArrow", SIZE = 24,
    ZONE = 0.3,                 -- the view stays still while the arrow is this far or more from each edge
    EDGE = 0.1,                 -- and never lets it come nearer an edge than this
    GLIDE = 3,                  -- after t seconds, exp(-GLIDE * t) of the way to the middle part is left
    FAR = 0.5,                  -- an arrow further off screen than this is centred at once
}
local JUMP_ZOOM = 6             -- zoom the map goes to at least when jumping to an event
local MAP_BORDER = 4            -- the map's and panel's frames reach this far outside them
local MAP_SHADOW = { 18, 0.55 } -- inner edge shadow: width, darkest alpha
-- Window layout. LEFT to BOTTOM are how far the window's own border reaches in
-- from each side (the title bar for TOP); PAD is the space between that border
-- and the boxes inside, and between the boxes.
local FRAME = { LEFT = 6, RIGHT = 6, TOP = 21, BOTTOM = 6, PAD = 10 }
local PANEL_GAP = 2 * MAP_BORDER + FRAME.PAD   -- map to side panel, so their frames are PAD apart

-- Zoom at which each kind of marker appears, so the world view stays readable.
local MARKER_ZOOM = {
    dungeon = 1,
    level10 = 1,                -- levels 10, 20, ...
    level5 = 2.5,               -- levels 5, 15, ...
    level = 5,
    death = 6,
    quest = 5,
    profession = 2.5,
    recipe = 5,
    guild = 2.5,
    reputation = 2.5,
    mount = 1,                  -- riding is a milestone, like a dungeon
    rare = 2.5,
    duel = 2.5,
    group = 2.5,
    gather = 5,                 -- gathering nodes, Gathering.lua
}
-- Turn-ins this close in place and time are one visit to a quest giver,
-- shown as one marker listing them all.
local QUEST_VISIT = { yards = 30, seconds = 180 }

local frame, canvas, content, overlay, scrub, playButton, speedButton, terrainButton, gearButton

local continentLayer, terrainLayer, othersLayer, pathLayer
local zoneView  -- zone art, see ZoneArt.lua
local charMarkers, otherLines = {}, {}
local infoText, hintText, perfText, head
local lines, markers, motes = {}, {}, {}
local jumpIcons = {}  -- jump icons not in use, to reuse (BuildJumps; spare pieces are kept per arc frame, JumpSet)
local activeTiles, freeTiles = {}, {}  -- terrain: tile index -> texture, and spares
local drag
local hoverLine
local hoverElapsed = 0

local state = {
    W = 0, H = 0,       -- world map art size, which is also the content size
    toContent = {},     -- continentID -> function(worldX, worldY) -> content x, y
    tiles = {},         -- terrain tiles: { fileID, x1, y1, x2, y2 } in content units
    tilesSkipped = 0,   -- tiles left out for lying in no zone

    -- Points in time order, in content units. pb is the level band at each
    -- point. brk[i] is true where a new segment starts (no line from i - 1),
    -- and pj[i] is why the path jumped there, if known. bounds is
    -- { x1, y1, x2, y2 } around all points. lods are the path simplified at
    -- each detail level, made when first needed (see GetLod).
    n = 0, px = {}, py = {}, pt = {}, pm = {}, pb = {}, brk = {}, pj = {},
    bounds = { 0, 0, 0, 0 }, lods = {},
    -- Level and zone over time, for the info line and tooltips: the level
    -- (zone) at time t is levels[LastIndex(levelTimes, t)].
    timelines = { levelTimes = {}, levels = {}, zoneTimes = {}, zones = {} },
    markerCount = 0,
    markerNow = math.huge,      -- markers up to this time are shown

    zoom = 1, targetZoom = 1,   -- current zoom, and where the animation is heading
    minZoom = 1,                -- zoomed out to the whole area: below 1 with the Cosmic map (Cosmic.lua)
    area = { 0, 0, 0, 0 },      -- content the view keeps to: x1, y1, x2, y2 (SetupWorld)
    anchorX = 0, anchorY = 0,   -- canvas pixel kept still while zooming
    ox = 0, oy = 0,             -- content coordinate at the top left of the view

    drawn = {},         -- built lines: { x1, y1, x2, y2, mode, pointIndex }
    lineCount = 0,      -- lines placed by the last build
    shown = 0,          -- how many of those are showing
    lineZoom = 1,       -- zoom the lines in view are sized for (PathLines.lua)
    visible = {},       -- indexes into drawn of lines inside the view
    boxes = {},         -- boxes over runs of drawn, to find those (PathLines.Boxes)
    -- The view and a margin wide enough that a line sized for another zoom
    -- outside it can't reach into the view: lines in it are sized for the
    -- zoom (UpdateVisible). fitMin is the lowest zoom any line in use may
    -- still be sized for, which gives that margin.
    fit = { 0, 0, 0, 0 },
    fitMin = 1,
    builds = 0,         -- path builds so far, so hovering knows the lines changed
    built = nil,        -- area and zoom of the last path build
    terrainBuilt = nil, -- area of the last terrain build
    terrainCapped = false,

    cur = 0,            -- replay position as a fractional point index
    playing = false,
    speedIndex = 1,
    -- togetherMode is nil, or real or game: replaying together by the time
    -- each point was recorded, or by time played. clock is how far it has
    -- reached, on that mode's clock, and clockTo where it ends; togetherSpeed
    -- is an index in Together.SPEEDS.
    togetherSpeed = 5,

    -- Timings in ms for /rts perf. fit is UpdateVisible's time on the last
    -- view change and sized the lines and jump pieces it resized, with the
    -- most of each since the zoom last started moving; placed and kept
    -- are the last build's lines placed afresh and kept as they were.
    perf = { world = 0, decode = 0, setup = 0, build = 0, lod = 0, place = 0, terrain = 0, view = 0,
        fit = 0, fitMost = 0, sized = 0, sizedMost = 0, placed = 0, kept = 0 },
    charCount = 0,      -- other characters' markers in use
    jumps = {},         -- built jump arcs: { index into drawn, parts, chunks, icon, x, y, and for keeping them (BuildJumps) build, skipped, marks, ribbons }
    jumpSets = {},      -- arcs kept for the last few doublings of the zoom, each on a frame of its own (JumpSet)
    boats = {},         -- point index -> "Dock to dock" for boat jumps near known docks
    seaTrips = {},      -- point index -> how a jump across the sea is drawn, see BuildPoints
    ribbons = {},       -- ribbon effect lines to scroll, see BuildJumps
    ribbonClock = 0,    -- seconds the ribbon effects have flowed
    otherTracks = {},   -- tracks of other characters whose path is turned on
    trackOf = {},       -- roster entry -> its track
    otherDrawn = {},    -- their built lines, like drawn, each with .track
    otherBoxes = {},    -- boxes over them, and the ones inside the view
    otherVisible = {},
    hover = nil,        -- line spec under the mouse, with a tooltip showing
    otherLineCount = 0, -- lines of other characters' paths in use
    otherZoom = 1,      -- zoom those in view are sized for
    lodLevel = 0,       -- detail level of the last path build
    warm = nil,         -- coroutine pre-building detail levels, while it runs
}

local function FormatTime(t)
    return tostring(date("%d %b %Y, %H:%M", t))
end

-- 0 below range[1], 1 above range[2], smooth in between on a log scale.
local function Fade(zoom, range)
    local f = math.log(zoom / range[1]) / math.log(range[2] / range[1])
    return math.max(0, math.min(1, f))
end

-- Timeline lookups for the info line ------------------------------------------

-- Both read the timelines BuildPoints makes, as they run every replay frame.
local function LevelAt(t)
    local tl = state.timelines
    return tl.levels[ns.LastIndex(tl.levelTimes, t)] or ns.Roster:ViewLevel()
end

local function ZoneName(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and info.name or ""
end

-- The zone at time t; with landed, where a jump at t landed: the zone is
-- noted a moment after a login or a loading screen, so a jump from Redridge
-- that landed in Stormwind read "Redridge to Redridge" (2026-11-10, a zone
-- noted 2 seconds after). One noted within ns.LANDED_SECONDS is the landing's.
local function ZoneAt(t, landed)
    local tl = state.timelines
    local k = ns.LastIndex(tl.zoneTimes, t)
    local after = tl.zoneTimes[k + 1]
    if landed and after and after - t <= ns.LANDED_SECONDS then
        k = k + 1
    end
    return ZoneName(tl.zones[k])
end

-- World setup, once per session -------------------------------------------------

local function FindWorldMap()
    local mapID = C_Map.GetBestMapForUnit("player")
    while mapID and mapID > 0 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then break end
        if info.mapType == Enum.UIMapType.World then return mapID end
        mapID = info.parentMapID
    end
    return WORLD_MAP
end

-- World yards to 0-1 coordinates on uiMap. GetWorldPosFromMapPos is affine,
-- so three corners define it and the inverse is solved once.
-- Returns continentID and the transform, or nil.
local function MapTransform(uiMap)
    local c, o = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(0, 0))
    local _, eu = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(1, 0))
    local _, ev = C_Map.GetWorldPosFromMapPos(uiMap, CreateVector2D(0, 1))
    if not (c and o and eu and ev) then return end
    local ax, ay = eu.x - o.x, eu.y - o.y   -- world change per unit of u
    local bx, by = ev.x - o.x, ev.y - o.y   -- and per unit of v
    local det = ax * by - bx * ay
    if det == 0 then return end
    return c, function(x, y)
        local dx, dy = x - o.x, y - o.y
        return (dx * by - dy * bx) / det, (ax * dy - ay * dx) / det
    end
end
ns.MapTransform = MapTransform

-- Covers the content rectangle x1, y1 - x2, y2 with uiMap's art, through
-- mask if given.
local function AddArt(parent, uiMap, x1, y1, x2, y2, mask)
    local layers = C_Map.GetMapArtLayers(uiMap)
    local textures = C_Map.GetMapArtLayerTextures(uiMap, 1)
    local layer = layers and layers[1]
    if not layer or not textures then return end
    local cols = math.ceil(layer.layerWidth / layer.tileWidth)
    local sx, sy = (x2 - x1) / layer.layerWidth, (y2 - y1) / layer.layerHeight
    for i, fileID in ipairs(textures) do
        local left = (i - 1) % cols * layer.tileWidth
        local top = math.floor((i - 1) / cols) * layer.tileHeight
        -- Edge tiles hang past the layer; crop them to the part in use.
        local w = math.min(layer.tileWidth, layer.layerWidth - left)
        local h = math.min(layer.tileHeight, layer.layerHeight - top)
        local tex = parent:CreateTexture(nil, "BACKGROUND")
        tex:SetTexture(fileID, "CLAMP", "CLAMP", "TRILINEAR")
        -- Snapped to the screen's pixels, art zoomed far in draws as blocks.
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
        tex:SetTexCoord(0, w / layer.tileWidth, 0, h / layer.tileHeight)
        tex:SetPoint("TOPLEFT", parent, "TOPLEFT", x1 + left * sx, -(y1 + top * sy))
        tex:SetSize(w * sx, h * sy)
        if mask then tex:AddMaskTexture(mask) end
    end
end
ns.AddMapArt = AddArt

-- Points inside a tile, as fractions of it, tested for being in a zone:
-- a 4x4 grid reaching close to the edges, centre ones first.
local TILE_PROBES = {}
for _, a in ipairs({ 0.375, 0.625, 0.125, 0.875 }) do
    for _, b in ipairs({ 0.375, 0.625, 0.125, 0.875 }) do
        TILE_PROBES[#TILE_PROBES + 1] = { a, b }
    end
end
local SKIPPED_TINT = { 1, 0.25, 0.25 }  -- skipped tiles when shown with /rts tiles

-- True if any probe point of the tile lies in a zone of the continent. The
-- minimap files include unused and developer areas (flat green placeholder
-- tiles, unreleased land) that belong to no zone, so those are left out.
-- Without the API every tile is kept.
-- The zone must be on the tile's own world: on the Anniversary realms the
-- Blood Elf and Draenei zones are on world 530 while their continents are
-- worlds 0 and 1, whose own tiles there are open sea or blank, and drew over
-- Ghostlands and Bloodmyst (Jordan, 2026-10-26).
local function TileInZone(continentID, continentMap, toMap, north, west)
    if not C_Map.GetMapInfoAtPosition then return true end
    state.zoneWorlds = state.zoneWorlds or {}
    local worlds = state.zoneWorlds
    for _, probe in ipairs(TILE_PROBES) do
        local u, v = toMap(north - probe[2] * TILE_YARDS, west - probe[1] * TILE_YARDS)
        if u >= 0 and u <= 1 and v >= 0 and v <= 1 then
            local info = C_Map.GetMapInfoAtPosition(continentMap, u, v)
            if info and info.mapID ~= continentMap and info.mapType >= Enum.UIMapType.Zone then
                if worlds[info.mapID] == nil then
                    worlds[info.mapID] = MapTransform(info.mapID) or false
                end
                local world = worlds[info.mapID]
                if not world or world == continentID then
                    return true
                end
            end
        end
    end
    return false
end

-- Splits a tile into pieces for drawing: { u1, u2, v1, v2, orientation,
-- minAlpha, maxAlpha } in 0-1 tile coordinates. Each open side (no tile
-- beyond it) gets a band fading to transparent. A corner between two open
-- sides is left out, since one texture can only fade in one direction.
-- Gradients follow SetGradient: HORIZONTAL runs left to right, VERTICAL bottom to top.
local function TilePieces(openLeft, openRight, openTop, openBottom)
    local xs = { 0, openLeft and EDGE_FADE or 0, openRight and 1 - EDGE_FADE or 1, 1 }
    local ys = { 0, openTop and EDGE_FADE or 0, openBottom and 1 - EDGE_FADE or 1, 1 }
    local pieces = {}
    for i = 1, 3 do
        for j = 1, 3 do
            local u1, u2, v1, v2 = xs[i], xs[i + 1], ys[j], ys[j + 1]
            if u2 > u1 and v2 > v1 and (i == 2 or j == 2) then
                local piece = { u1, u2, v1, v2, "HORIZONTAL", 1, 1 }
                if i == 1 then
                    piece[6] = 0
                elseif i == 3 then
                    piece[7] = 0
                elseif j == 1 then
                    piece[5], piece[7] = "VERTICAL", 0
                elseif j == 3 then
                    piece[5], piece[6] = "VERTICAL", 0
                end
                pieces[#pieces + 1] = piece
            end
        end
    end
    return pieces
end

-- Minimap tile mapCOL_ROW covers world X (north) from (32 - row) * TILE_YARDS
-- down one tile, and world Y (west) from (32 - col) * TILE_YARDS down one tile.
--
-- Tiles at the edge of the terrain fade out on each side with no tile beyond
-- it, so terrain blends into the map art instead of ending in hard steps.
-- Columns run east (right on the map) and rows south (down).
local function AddTerrainTiles(continentID, continentMap, toMap, toContent)
    local ids = ns.MinimapTiles[ns.MinimapDirs[continentID] or ""]
    if not ids then return end

    local kept = {}
    for key in pairs(ids) do
        local col, row = key:match("^(%d+)_(%d+)$")
        local north, west = (32 - tonumber(row)) * TILE_YARDS, (32 - tonumber(col)) * TILE_YARDS
        if TileInZone(continentID, continentMap, toMap, north, west) then
            kept[key] = { tonumber(col), tonumber(row), north, west }
        else
            -- Kept in the list, but only drawn by /rts tiles, tinted.
            local ax, ay = toContent(north, west)
            local bx, by = toContent(north - TILE_YARDS, west - TILE_YARDS)
            table.insert(state.tiles, {
                ids[key], math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by),
                skipped = true, pieces = { { 0, 1, 0, 1, "HORIZONTAL", 0.6, 0.6 } },
            })
            state.tilesSkipped = state.tilesSkipped + 1
        end
    end

    for key, k in pairs(kept) do
        local col, row, north, west = k[1], k[2], k[3], k[4]
        local ax, ay = toContent(north, west)
        local bx, by = toContent(north - TILE_YARDS, west - TILE_YARDS)
        local tile = {
            ids[key], math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by),
        }
        tile.pieces = TilePieces(
            not kept[(col - 1) .. "_" .. row], not kept[(col + 1) .. "_" .. row],
            not kept[col .. "_" .. (row - 1)], not kept[col .. "_" .. (row + 1)])
        table.insert(state.tiles, tile)
    end
end

-- Sizes the content to the world map art and places every continent on it.
-- Returns false if the world map cannot be used.
local function SetupWorld(worldLayer)
    local world = FindWorldMap()
    local layers = C_Map.GetMapArtLayers(world)
    local layer = layers and layers[1]
    if not layer or not C_Map.GetMapRectOnMap then return false end

    local W, H = layer.layerWidth, layer.layerHeight
    state.W, state.H = W, H
    -- The view's limits and how far out it zooms: the world map, unless the
    -- Cosmic map holds it (Cosmic.lua).
    state.area, state.minZoom = { 0, 0, W, H }, 1
    local cosmic = ns.Cosmic:Available(world)
    AddArt(worldLayer, world, 0, 0, W, H, cosmic and ns.Gaps.Mask(worldLayer, ns.Gaps.FEATHER, 0, 0, W, H))

    local continents = {}
    for _, child in ipairs(C_Map.GetMapChildrenInfo(world, Enum.UIMapType.Continent) or {}) do
        local continentID, toMap = MapTransform(child.mapID)
        local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(child.mapID, world)
        if continentID and toMap and minX then
            local x1, y1 = minX * W, minY * H
            local sx, sy = (maxX - minX) * W, (maxY - minY) * H
            local function toContent(x, y)
                local u, v = toMap(x, y)
                return x1 + u * sx, y1 + v * sy
            end
            state.toContent[continentID] = toContent
            -- Each continent's art fades into the world map over a wide
            -- border (#73): drawn whole, its rectangle, frame and painted
            -- sea ended in a straight line across the world's sea.
            AddArt(continentLayer, child.mapID, x1, y1, x1 + sx, y1 + sy,
                ns.Gaps.Mask(continentLayer, ns.Gaps.FEATHER, x1, y1, x1 + sx, y1 + sy))
            zoneView:AddContinent(child.mapID, x1, y1, sx, sy)
            ns.Gaps:Add(zoneView.gaps, child.mapID, x1, y1, x1 + sx, y1 + sy, zoneView.zones)
            AddTerrainTiles(continentID, child.mapID, toMap, toContent)
            continents[#continents + 1] = { child.mapID, x1, y1, sx, sy }
        end
    end
    if cosmic then
        ns.Cosmic:Add(world, W, H, {
            state = state, AddArt = AddArt, MapTransform = MapTransform, zoneView = zoneView,
            AddTerrainTiles = AddTerrainTiles,
            cosmicLayer = state.cosmicLayer, worldLayer = worldLayer, continents = continents,
        })
    end
    -- Islands the world map leaves out, such as Zephras Isle (Islands.lua).
    ns.Islands:Add(worldLayer, state.toContent, W, H)
    return next(state.toContent) ~= nil
end

-- Journey data -------------------------------------------------------------------

-- Level changes in events, in time order, and the level and zone
-- timelines (state.timelines) from the same pass.
function Map.Timelines(events)
    local changes = {}
    local tl = { levelTimes = {}, levels = {}, zoneTimes = {}, zones = {} }
    for _, e in ipairs(events) do
        if e[2] == "on" or e[2] == "lvl" then
            changes[#changes + 1] = e
            tl.levelTimes[#tl.levelTimes + 1], tl.levels[#tl.levels + 1] = e[1], e[6]
        elseif e[2] == "zone" then
            tl.zoneTimes[#tl.zoneTimes + 1], tl.zones[#tl.zones + 1] = e[1], e[6]
        end
    end
    return changes, tl
end

local function BuildPoints(paths)
    local px, py, pt, pm, pb, brk, pj, pd = {}, {}, {}, {}, {}, {}, {}, {}
    -- The jump the arrow was on was the old points' (#103).
    state.headJump = nil

    -- Level changes, walked alongside the points.
    local changes, tl = Map.Timelines(ns.view.events)
    state.timelines = tl
    local nextChange = 1
    local band = Style.LevelBand(changes[1] and changes[1][6] or 1)

    local n = 0
    -- Jumps across the sea follow a line drawn in Routes.lua (seaTrips:
    -- point index -> ns.BoatTrip for boat trips between known docks,
    -- ns.SeaLane for hearthstones and teleports). Boat trips on one
    -- route the same way share a list of their point indexes in time order
    -- (trips); only the first is drawn, the rest are marked dupe, and its
    -- tooltip counts them.
    local boats, seaTrips, routeTrips, previous = {}, {}, {}, nil
    for _, path in ipairs(paths) do
        local toContent = state.toContent[path.c]
        if toContent then
            for i = 1, #path.x do
                local t = path.t[i]
                while changes[nextChange] and changes[nextChange][1] <= t do
                    band = Style.LevelBand(changes[nextChange][6])
                    nextChange = nextChange + 1
                end
                n = n + 1
                px[n], py[n] = toContent(path.x[i], path.y[i])
                -- (a flight carried on after a /reload is one line: Recorder:Continues)
                local continues = i == 1 and ns.Recorder:Continues(previous, path)
                pt[n], pm[n], pb[n], brk[n] = t, path.m, band, i == 1 and not continues
                -- Yards from the point before, for the replay's pace.
                local bx, by = path.x[i - 1], path.y[i - 1]
                if continues then bx, by = ns.Recorder:LastPoint(previous) end
                pd[n] = bx and math.sqrt((path.x[i] - bx) ^ 2 + (path.y[i] - by) ^ 2) or 0
                if i == 1 then
                    pj[n] = ns.Recorder:JumpReason(previous, path)
                    if path.j == "b" and previous then
                        local last = #previous.x
                        boats[n] = ns.BoatRoute(previous.c, previous.x[last], previous.y[last],
                            path.c, path.x[1], path.y[1])
                        local from = ns.Dock(previous.c, previous.x[last], previous.y[last])
                        local to = ns.Dock(path.c, path.x[1], path.y[1])
                        local fromContent = from and state.toContent[previous.c]
                        if fromContent and to then
                            seaTrips[n] = ns.BoatTrip(from, to,
                                { fromContent(previous.x[last], previous.y[last]) }, { px[n], py[n] },
                                { fromContent(from[3], from[4]) }, { toContent(to[3], to[4]) },
                                state.W, state.H)
                            local trips = routeTrips[boats[n]] or {}
                            routeTrips[boats[n]] = trips
                            trips[#trips + 1] = n
                            seaTrips[n].trips, seaTrips[n].dupe = trips, #trips > 1
                        end
                    elseif previous and state.toContent[previous.c]
                        and Style.Jump(pj[n]).style ~= "portal" then
                        -- Hearthstones and teleports across the sea take their
                        -- lane, when drawn as a line rather than portals.
                        local last = #previous.x
                        seaTrips[n] = ns.SeaLane(pj[n], previous.c,
                            { state.toContent[previous.c](previous.x[last], previous.y[last]) },
                            path.c, { px[n], py[n] }, state.W, state.H)
                    end
                end
            end
        end
        previous = path
    end
    state.boats, state.seaTrips = boats, seaTrips

    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, n do
        local x, y = px[i], py[i]
        if x < x1 then x1 = x end
        if x > x2 then x2 = x end
        if y < y1 then y1 = y end
        if y > y2 then y2 = y end
    end

    state.n, state.px, state.py, state.pt, state.pm, state.pb, state.brk = n, px, py, pt, pm, pb, brk
    state.pj, state.pd, state.pg, state.events = pj, pd, nil, ns.view.events
    state.bounds = { x1, y1, x2, y2 }
    state.lods = {}
    ns.LiveMap:Built(state)
end

local function GetMarker(i)
    local m = markers[i]
    -- A marker reused for another kind of event loses a guild banner it had,
    -- and what a group, rare, node or duel left on it.
    if m and m.badge then
        m.badge:Hide()
        m.icon:Show()
    end
    if m then m.rare, m.node, m.duel, m.group = nil, nil, nil, nil end
    if m then
        Style.Unframe(m)
        ns.MarkerPiles:Reset(m)
        return m
    end
    m = CreateFrame("Frame", nil, overlay)
    m:SetSize(14, 14)
    m:EnableMouse(true)
    m.icon = m:CreateTexture(nil, "OVERLAY")
    m.icon:SetAllPoints()
    m.text = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m.text:SetDrawLayer("OVERLAY", 7)
    m.text:SetPoint("CENTER", 0.5, 0)
    m:SetScript("OnEnter", function(self)
        -- A pile of markers fans out, then this one shows its own.
        if self.pile then
            ns.MarkerPiles:Fan(self)
            return
        end
        -- A group shows its card, with everyone in it.
        if self.group then
            ns.Parties:ShowCard(self, self.group)
            return
        end
        if self.node then
            ns.Gathering:ShowTooltip(self, self.node)
            return
        end
        -- Level ups with recorded gear show the gear card instead of a tooltip.
        if self.level and ns.GearCard:Show(self.level, self, self.title, self.detail) then return end
        if self.rare then
            ns.Rares:ShowCard(self, self.rare[1], self.rare[2])
            return
        end
        if self.duel then
            ns.Duels:ShowTooltip(self, self.duel[1], self.duel[2], "ANCHOR_RIGHT")
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.title)
        GameTooltip:AddLine(self.detail, 1, 1, 1)
        GameTooltip:Show()
    end)
    m:SetScript("OnLeave", function(self)
        GameTooltip_Hide()
        ns.GearCard:Hide()
        ns.Rares:HideCard()
        if self.group then ns.Parties:HideCard() end
    end)
    markers[i] = m
    return m
end

-- Events are in time order, so level and zone are tracked in the same pass
-- rather than looked up per marker. Inside an instance the client gives no
-- position (c is -1), so events there (a level reached, a death) are placed
-- at the door the player went in by, the last "in" event's place, and say
-- which instance (inside).
local function BuildMarkers()
    local count, level, zone = 0, nil, nil
    local visit     -- the quest marker turn-ins are joining: { m, c, x, y, last, names }
    local door      -- the last "in" event with a place
    local function Where(instance, zoneID)
        return instance and ("Inside " .. instance) or ZoneName(zoneID)
    end
    -- Inside a battleground, the place events have is where the player
    -- queued from, not a door to it: nothing there gets a marker but
    -- entering it (History lists them under its run).
    local inBattleground = ns.Battlegrounds.Tracker()
    ns.Parties:Reset()
    for _, e in ipairs(ns.view.events) do
        local t, kind, c, x, y = e[1], e[2], e[3], e[4], e[5]
        if kind == "in" and state.toContent[c] then
            door = e
        end
        local battleground = inBattleground(e)
        local inside
        if not state.toContent[c] and door then
            c, x, y, inside = door[3], door[4], door[5], door[7] or "an instance"
        end
        local toContent = state.toContent[c]
        if kind == "on" or kind == "lvl" then
            level = e[6]
        elseif kind == "zone" then
            zone = e[6]
        end
        if battleground then
            -- (no marker: see above)
        elseif toContent and kind == "qd" then
            local name = ns.Journal:QuestName(e) or ("Quest " .. tostring(e[6]))
            local near = visit and visit.c == c and t - visit.last <= QUEST_VISIT.seconds
                and (x - visit.x) ^ 2 + (y - visit.y) ^ 2 <= QUEST_VISIT.yards ^ 2
            if not near then
                count = count + 1
                local m = GetMarker(count)
                m.t, m.level, m.category, m.minZoom = t, nil, "quests", MARKER_ZOOM.quest
                m.x, m.y = toContent(x, y)
                m.c, m.popping = c, nil
                local size = ns.SetEventIcon(m.icon, m.text, kind)
                m:SetSize(size, size)
                visit = { m = m, c = c, x = x, y = y, names = {}, first = t }
            end
            visit.last = t
            visit.m.lastT = t
            local names, m = visit.names, visit.m
            names[#names + 1] = name
            local xp = (e[7] and e[7] > 0) and ("+" .. ns.Commas(e[7]) .. " xp") or nil
            if #names == 1 then
                m.title = name
                m.detail = ("%s%s\n%s"):format(xp and (xp .. "\n") or "", Where(inside, zone), FormatTime(t))
            else
                m.title = ("%d quests turned in"):format(#names)
                m.detail = ("%s\n%s\n%s"):format(table.concat(names, "\n"), Where(inside, zone), FormatTime(visit.first))
            end
        elseif toContent and (kind == "prof" or kind == "rec" or kind == "gj" or kind == "gl" or kind == "gr"
            or kind == "rep" or kind == "ride" or kind == "mount" or kind == "rare" or kind == "duel") then
            local guild = kind == "gj" or kind == "gl" or kind == "gr"
            local mount = kind == "ride" or kind == "mount"
            local source = guild and ns.Guilds or kind == "rep" and ns.Reputation or mount and ns.Mounts
                or kind == "rare" and ns.Rares or kind == "duel" and ns.Duels or ns.Crafts
            local title, detail, icon, tabard = source:Describe(e)
            if title then
                count = count + 1
                local m = GetMarker(count)
                -- Guild events show the guild's banner instead of the icon.
                if guild then
                    m.badge = m.badge or ns.Guilds:CreateBadge(m, 26)
                    m.badge:SetPoint("CENTER")
                    ns.Guilds:SetBadge(m.badge, tabard)
                    m.badge:Show()
                    m.icon:Hide()
                end
                m.t, m.popping, m.level = t, nil, nil
                m.x, m.y = toContent(x, y)
                m.c = c
                m.category = Style.CATEGORY[kind]
                m.minZoom = guild and MARKER_ZOOM.guild or kind == "rep" and MARKER_ZOOM.reputation
                    or mount and MARKER_ZOOM.mount or kind == "rare" and MARKER_ZOOM.rare
                    or kind == "duel" and MARKER_ZOOM.duel
                    or kind == "prof" and MARKER_ZOOM.profession or MARKER_ZOOM.recipe
                local size, art = ns.SetEventIcon(m.icon, m.text, kind, nil, icon)
                m:SetSize(size, size)
                -- Game icon art sits in the item button frame (#110).
                if art and not guild then Style.Frame(m, art, Style.MARKER_ICON) end
                -- Rares show a card with their portrait when hovered.
                m.rare = kind == "rare" and { e, Where(inside, zone) } or nil
                m.duel = kind == "duel" and { e, Where(inside, zone) } or nil
                m.title = title
                m.detail = ("%s\n%s\n%s"):format(detail, Where(inside, zone), FormatTime(t))
            end
        elseif toContent and kind == "grp" then
            -- One icon for the group, a party's or a raid's (a party can become
            -- one); its card, with everyone in it, shows on hover.
            count = count + 1
            local m = GetMarker(count)
            m.t, m.popping, m.level, m.group = t, nil, nil, e
            m.x, m.y = toContent(x, y)
            m.c = c
            m.category = Style.CATEGORY[kind]
            m.minZoom = MARKER_ZOOM.group
            m.title, m.detail = ns.Parties:Describe(e)
            local size = ns.SetEventIcon(m.icon, m.text, ns.Parties:Info(e).kind == "raid" and "grpRaid" or kind)
            m:SetSize(size, size)
        elseif toContent and (kind == "die" or kind == "lvl" or kind == "in") then
            count = count + 1
            local m = GetMarker(count)
            m.t, m.popping = t, nil
            m.x, m.y = toContent(x, y)
            m.category = kind == "in" and ns.Battlegrounds.IsPvP(e[8]) and "battlegrounds" or Style.CATEGORY[kind]
            m.level = kind == "lvl" and e[6] or nil  -- for the gear card
            local size = ns.SetEventIcon(m.icon, m.text, kind, e[6])
            m:SetSize(size, size)
            if kind == "lvl" then
                local l = e[6]
                m.minZoom = l % 10 == 0 and MARKER_ZOOM.level10
                    or l % 5 == 0 and MARKER_ZOOM.level5 or MARKER_ZOOM.level
                m.title = "Reached level " .. l
                m.detail = ns.LevelShot:Detail(l, ("%s\n%s"):format(Where(inside, zone), FormatTime(t)))
            elseif kind == "die" then
                m.minZoom = MARKER_ZOOM.death
                m.title = ns.Deaths:Title(e)
                m.detail = ("Level %d, %s\n%s"):format(
                    level or ns.Roster:ViewLevel(), Where(inside, zone), FormatTime(t))
            else
                m.minZoom = MARKER_ZOOM.dungeon
                m.title = e[7] or "Instance"
                m.detail = ("%s, level %d\n%s"):format(
                    ns.InstanceTypes[e[8]] or "Instance", level or ns.Roster:ViewLevel(), FormatTime(t))
            end
        end
    end
    -- Gathering nodes, one marker each, after the events' (Gathering.lua).
    count = ns.Gathering:AddMarkers(count, GetMarker, state.toContent, MARKER_ZOOM.gather)
    for i = count + 1, #markers do
        markers[i]:Hide()
    end
    state.markerCount = count
end

-- View ---------------------------------------------------------------------------

local function ClampView()
    local z, a = state.zoom, state.area
    state.ox = math.max(a[1], math.min(a[3] - state.W / z, state.ox))
    state.oy = math.max(a[2], math.min(a[4] - state.H / z, state.oy))
end

-- Changes zoom while keeping the content under canvas pixel ax, ay still.
local function ZoomAround(z, ax, ay)
    local x, y = state.ox + ax / state.zoom, state.oy + ay / state.zoom
    state.zoom = z
    state.ox, state.oy = x - ax / z, y - ay / z
    ClampView()
end

local function CenterOn(x, y)
    state.ox = x - state.W / (2 * state.zoom)
    state.oy = y - state.H / (2 * state.zoom)
    ClampView()
end

-- The view, plus margin views on each side, clipped to the content.
local function ViewArea(margin)
    local vw, vh, a = state.W / state.zoom, state.H / state.zoom, state.area
    return math.max(a[1], state.ox - vw * margin), math.max(a[2], state.oy - vh * margin),
        math.min(a[3], state.ox + vw * (1 + margin)), math.min(a[4], state.oy + vh * (1 + margin))
end

-- The tolerance stops rounding at the content edges from forcing rebuilds.
local function ViewInside(area)
    local vw, vh = state.W / state.zoom, state.H / state.zoom
    local e = 0.01
    return state.ox >= area[1] - e and state.oy >= area[2] - e
        and state.ox + vw <= area[3] + e and state.oy + vh <= area[4] + e
end

-- Number of built lines whose end point is at or before point index seq.
local function CountUpTo(seq)
    return ns.LastIndex(state.drawn, seq, 6)
end

-- Tolerance in content units of detail level k: its lines pass within
-- about this of the points of the level it is made from (PathShape.lua's
-- KeepShape). Level 0 is fine enough for full zoom; each level up doubles it.
local function LodDistance(k)
    return SHAPE_PIXELS / MAX_ZOOM * LOD_STEP ^ k
end

-- A track is a path to draw with detail levels: { n, px, py, brk, lods } and
-- optionally pm (movement mode per point) and pb (level band). The player's
-- own path is state itself; other characters' paths are built from the
-- roster.
--
-- The track simplified at detail level k, made on first use (PathShape.lua's
-- MakeLevel): idx lists the points kept, in order, those its shape needs at
-- LodDistance(k), every segment's first and last point among them. Levels
-- nest, whatever order they are made in, and lods.top[i] is the coarsest
-- level made that keeps point i (LinesIn). chunks are boxes over runs of
-- CHUNK kept points: { first, last, x1, y1, x2, y2 }, first and last being
-- indexes into idx; each box includes the point before its run, where its
-- first line starts. With background set, it runs inside the warm-up
-- coroutine and yields every LOD_YIELD points.
local function GetLod(track, k, background)
    local lod = track.lods[k]
    if lod then return lod end
    local started = debugprofilestop()
    -- Never merged here (DETAIL.Merge does that in the warm-up): merging a
    -- level took 1.5 s in game, too long for a build to wait.
    lod = ns.MakeLevel(track, k, LodDistance(k), CHUNK, background and LOD_YIELD)
    -- Another character's level, made for a build: merged once the warm-up
    -- is free (OnUpdate).
    if track ~= state and DETAIL.MERGE then state.mergeWanted = true end
    if not background then
        state.perf.lod = state.perf.lod + debugprofilestop() - started
    end
    return lod
end

-- Pre-builds detail levels finest first, each from the one before, a little
-- each frame, so zooming in later does not stop to build them. A build
-- wanting a level first makes it at once from the finest made below it.
local function StartWarmUp()
    state.merging = nil         -- a merge the old warm-up was doing is dropped with it
    state.warm = coroutine.create(function()
        if DETAIL.MERGE then
            DETAIL.InOrder()
            DETAIL.Merge()
        else
            for k = 0, WARM_LODS do
                GetLod(state, k, true)
            end
        end
    end)
end

-- Makes the player's levels 0 to WARM_LODS again in order, each from the one
-- before, when they weren't made so, and puts them in place of those made.
-- A level comes out a little differently by the levels made before it
-- (PathShape.lua's MakeLevel): the map opened at a middle zoom makes that
-- level first, from every point, and the finer ones keep its points. So
-- merged levels kept between sessions (DETAIL.Cache) matched only when the
-- map opened at the same zoom: four of nine didn't, in game (2026-11-20).
-- Made in order, a level is the same whatever zoom the map opens at. They are
-- made on a track of their own, so builds meanwhile use the levels already
-- made, and points the player adds meanwhile are carried on to them at the
-- end (LiveMap's ExtendLods). state.merging keeps those points from
-- starting the warm-up over.
DETAIL.InOrder = function()
    local function Made()
        for _, k in ipairs(state.lods.order or {}) do
            local lod = state.lods[k]
            if lod.keep or lod.from ~= (k > 0 and k - 1 or nil) then return false end
        end
        return true
    end
    -- Made in order so far, the rest are made after them; but a build may
    -- make a coarser level meanwhile, which the ones after then keep.
    if Made() then
        for k = 0, WARM_LODS do GetLod(state, k, true) end
        if Made() then return end
    end
    state.merging = true
    local made = setmetatable({ lods = {}, n = state.n }, { __index = state })
    for k = 0, WARM_LODS do
        ns.MakeLevel(made, k, LodDistance(k), CHUNK, LOD_YIELD)
    end
    if state.n > made.n then
        local from = made.n + 1
        made.n = state.n
        ns.LiveMap.ExtendLods(made, from, LodDistance, CHUNK)
    end
    state.lods, state.picked, state.built = made.lods, nil, nil
    state.merging = nil
end

-- Merges the lines newer walks cover (PathShape.lua's MergeLines) into the
-- player's own levels already made, inside the warm-up: the level in view
-- and the two finer ones first, as a merged level may fit the budget more
-- finely, then the rest. Each is merged within DETAIL.MERGE pixels at the
-- closest zoom it is the finest for, so within half to all of that where it
-- is drawn. The path is built again once a level near the one in view is.
-- Merging takes up to MERGE_MS of each frame (Due). Levels merged are kept
-- in RoadToSixtyCache between sessions (Cache): a level made again with the
-- same points takes them back at once, and is merged again only once
-- REMERGE of its lines are newer than those.
DETAIL.MERGE_MS = 5
DETAIL.REMERGE = { lines = 200, share = 0.05 }
DETAIL.MERGE_VERSION = 2       -- raised when what is kept changes; older entries are dropped

DETAIL.Due = function()
    return debugprofilestop() - (state.warmAt or 0) > DETAIL.MERGE_MS
end

-- The cache's levels for the journey shown: only over all its time, as a
-- date range draws other points, and only the three journeys shown last
-- are kept. nil when it can't be kept. Anything in it not shaped as it
-- writes is dropped, so a damaged file can't stop the merge each time, and
-- so is an older journey of the same character (the same GUID before the
-- stamp's start), which an erase leaves behind (Core.lua's ResetCharacter).
DETAIL.Cache = function()
    local id = ns.view and ns.view.journeyId
    if type(id) ~= "string" or not ns.Range:IsAll() then return nil end
    RoadToSixtyCache = type(RoadToSixtyCache) == "table" and RoadToSixtyCache or {}
    local all = type(RoadToSixtyCache.merged) == "table" and RoadToSixtyCache.merged or {}
    RoadToSixtyCache.merged = all
    local version = "|" .. DETAIL.MERGE_VERSION
    local key = ("%s|%s%s"):format(id, DETAIL.MERGE, version)
    local guid = id:match("^(.*):[^:]*$")
    local keys = {}
    for other, e in pairs(all) do
        local otherId = type(other) == "string" and other:match("^(.*)|[^|]*|[^|]*$")
        if type(e) ~= "table" or type(e.levels) ~= "table" or type(e.at) ~= "number"
            or not otherId or other:sub(-#version) ~= version
            or guid and otherId ~= id and otherId:match("^(.*):[^:]*$") == guid then
            all[other] = nil
        elseif other ~= key then
            keys[#keys + 1] = { other, e.at }
        end
    end
    -- Others, newest first, past the two kept beside this one.
    table.sort(keys, function(a, b) return a[2] > b[2] end)
    for i = 3, #keys do all[keys[i][1]] = nil end
    local entry = all[key] or { levels = {} }
    all[key] = entry
    entry.at = ns.Now()
    return entry.levels
end

DETAIL.Merge = function()
    local order, seen = {}, {}
    local now = state.lodLevel or 0
    for _, k in ipairs({ now, now - 1, now - 2 }) do
        if k >= 0 then order[#order + 1] = k; seen[k] = true end
    end
    for k = 0, WARM_LODS do
        if not seen[k] then order[#order + 1] = k end
    end
    local cache = DETAIL.Cache()
    local kept, merged, started = 0, 0, debugprofilestop()
    local why = {}      -- levels merged now and why: new (nothing kept), differ, or newer lines
    -- Points the player adds meanwhile carry the levels on (LiveMap's
    -- ExtendLods), which may change their last few lines, so merges those
    -- could undo are dropped (DropMergedAfter). The map picks the level up
    -- once it is built again (OnUpdate).
    local function Apply(track, k, lod, hid, count)
        ns.DropMergedAfter(hid, lod.idx, count - 2)
        lod.hid = hid
        ns.LodChunks(track, lod.idx, #lod.idx, lod.chunks, 1, CHUNK, hid)
        if track ~= state or k <= (state.lodLevel or 0) + 2 then state.built = nil end
    end
    -- Merges a level of a track afresh; false when merging stopped meanwhile.
    local function Fresh(track, k, lod)
        local dist = DETAIL.MergeDistance(k)
        local count = #lod.idx
        local hid = ns.MergeLines(track, lod.idx, count, dist, DETAIL.Due)
        -- Toggled off while it ran (a fresh warm-up drops this one).
        if not DETAIL.MERGE or track.lods[k] ~= lod then return false end
        merged = merged + 1
        Apply(track, k, lod, hid, count)
        if track == state and cache then cache[k] = ns.PackMerged(lod.idx, count - 2, hid, dist, DETAIL.Due) end
        return true
    end
    state.merging = true
    for _, k in ipairs(order) do
        local lod = state.lods[k]
        if lod and not lod.hid then
            local hid, upTo = nil, 0
            if cache then hid, upTo = ns.UnpackMerged(cache[k], lod.idx, DETAIL.MergeDistance(k), DETAIL.Due) end
            if hid then
                kept = kept + 1
                Apply(state, k, lod, hid, upTo)
            end
            local newer = #lod.idx - (upTo or 0)
            if not hid or newer > math.max(DETAIL.REMERGE.lines, #lod.idx * DETAIL.REMERGE.share) then
                why[#why + 1] = ("%d %s"):format(k, hid and newer .. " newer"
                    or (cache and cache[k]) and "differs" or "new")
                if hid then kept = kept - 1 end
                if not Fresh(state, k, lod) then state.merging = nil return end
            end
            if DETAIL.Due() then coroutine.yield() end
        end
    end
    -- Other characters' paths shown: the levels their builds made, kept for
    -- this session only, as the cache holds the journeys shown.
    local others = 0
    for _, track in ipairs(state.otherTracks or {}) do
        for k = 0, MAX_LOD do
            local lod = track.lods[k]
            if lod and not lod.hid then
                if not Fresh(track, k, lod) then state.merging = nil return end
                others = others + 1
                if DETAIL.Due() then coroutine.yield() end
            end
        end
    end
    state.merging = nil
    --@debug@
    if kept + merged > 0 then
        local seconds = (debugprofilestop() - started) / 1000
        ns.Print(("Path lines merged: %d levels kept from last time, %d merged now%s%s, %.1f s."):format(
            kept, merged - others, #why > 0 and " (" .. table.concat(why, ", ") .. ")" or "",
            others > 0 and (", %d of other characters'"):format(others) or "", seconds))
        local bytes = 0
        for _, saved in pairs(cache or {}) do bytes = bytes + #(saved.d or "") end
        DETAIL.Log(("merge,%d,%d,%d,%d,%.2f,%.0f,%s"):format(state.n, kept, merged - others, others,
            seconds, bytes / 1024, table.concat(why, " ")))
    end
    --@end-debug@
end

--@debug@
-- The merges and checks of a developer build, kept in the saved variables
-- for reading afterwards (/reload writes them): RoadToSixtyDB.mergeLog, the
-- last 200, each "kind,time,...":
--   merge,time,points,kept,merged,others,seconds,cacheKB,why (DETAIL.Merge)
--   check,time,levels,merged,failed,farthest (/rts mergecheck)
DETAIL.Log = function(line)
    local log = ns.db.mergeLog or {}
    ns.db.mergeLog = log
    local kind, rest = line:match("^(%a+),(.*)$")
    log[#log + 1] = ("%s,%d,%s"):format(kind, ns.Now(), rest)
    while #log > 200 do table.remove(log, 1) end
end

-- Checks every merged line of the player's levels and the other characters'
-- shown another way (PathShape.lua's CheckMerged). It takes a few seconds
-- on a long journey, with the game held still meanwhile.
ns.Command("mergecheck", "check the map's merged path lines another way (developer; holds the game a few seconds)", function()
    local levels, merged, failed, farthest = 0, 0, 0, 0
    local started = debugprofilestop()
    for _, track in ipairs({ state, unpack(state.otherTracks or {}) }) do
        for k = 0, MAX_LOD do
            local lod = track.lods and track.lods[k]
            if lod and lod.hid then
                local m, f, first, far = ns.CheckMerged(track, lod.idx, lod.hid, DETAIL.MergeDistance(k))
                levels, merged, failed = levels + 1, merged + m, failed + f
                farthest = math.max(farthest, far)
                if f > 0 then
                    ns.Print(("Level %d%s: %d of %d merged lines not covered (first at %d)."):format(
                        k, track == state and "" or " of another character", f, m, first))
                end
            end
        end
    end
    ns.Print(("Merge check: %d levels, %d merged lines, %d not covered, farthest %.2f of the distance, %.1f s."):format(
        levels, merged, failed, farthest, (debugprofilestop() - started) / 1000))
    DETAIL.Log(("check,%d,%d,%d,%.3f"):format(levels, merged, failed, farthest))
end)
--@end-debug@

-- The distance level k is merged within, in content units: DETAIL.MERGE
-- pixels at the closest zoom it is the finest for.
DETAIL.MergeDistance = function(k)
    return DETAIL.MERGE / math.min(MAX_ZOOM, MAX_ZOOM / LOD_STEP ^ (k - 1))
end

local function StepWarmUp()
    state.warmAt = debugprofilestop()   -- when this frame's slice began (DETAIL.Due)
    local ok, err = coroutine.resume(state.warm)
    if not ok then
        state.warm, state.merging = nil, nil
        geterrorhandler()(err)
    elseif coroutine.status(state.warm) == "dead" then
        state.warm = nil
    end
end

-- Chunks of a track's detail level that overlap the area, and how many
-- lines they draw there. Their points are counted first, as that is quick,
-- but where a town was passed through again and again most chunks reach far
-- outside the area, so their points are well over the lines: in Stormwind on
-- a journey to the 40s, the map went two levels coarser than the budget
-- needed, merging points 100 yards apart, and the curve cut across every
-- corner. Over budget, the lines are counted as LinesIn draws them (but for
-- sea courses' boxes), up to one past it.
local function ChunksIn(track, lod, x1, y1, x2, y2, budget, skip, exact)
    local list, total = {}, 0
    for _, ch in ipairs(lod.chunks) do
        if ch[5] >= x1 and ch[3] <= x2 and ch[6] >= y1 and ch[4] <= y2 then
            list[#list + 1] = ch
            total = total + ch[2] - ch[1] + 1
        end
    end
    if total <= budget and not exact then return list, total end
    local idx, px, py, lines = lod.idx, track.px, track.py, 0
    -- Lines merged (MergeLines) up to where the track is shown are not drawn,
    -- but in the far part (skip) the lines join a coarser level's points
    -- across the ones merged, so they are all drawn there (LinesIn).
    local hid, upTo = not skip and lod.hid, track.mergeUpTo or math.huge
    local whole = hid and upTo >= track.n and 7 or 8
    local s1, s2, s3, s4 = math.huge, math.huge, -math.huge, -math.huge
    if skip then s1, s2, s3, s4 = skip[1], skip[2], skip[3], skip[4] end
    for _, ch in ipairs(list) do
        if ch[3] >= s1 and ch[5] <= s3 and ch[4] >= s2 and ch[6] <= s4 then
            -- A box wholly in the part left out draws nothing.
        elseif ch[3] >= x1 and ch[5] <= x2 and ch[4] >= y1 and ch[6] <= y2
            and (ch[5] < s1 or ch[3] > s3 or ch[6] < s2 or ch[4] > s4) then
            -- A box wholly in the area draws all its lines there.
            lines = lines + (ch[whole] or ch[7])
            if lines > budget then return list, lines end
        else
            for j = math.max(2, ch[1]), ch[2] do
                local ax, ay, bx, by = px[idx[j - 1]], py[idx[j - 1]], px[idx[j]], py[idx[j]]
                -- A merged line is left out only with both ends in the area,
                -- as LinesIn leaves it out only inside the near part.
                if (ax ~= bx or ay ~= by) and math.max(ax, bx) >= x1 and math.min(ax, bx) <= x2
                    and math.max(ay, by) >= y1 and math.min(ay, by) <= y2
                    and not (ax >= s1 and ax <= s3 and ay >= s2 and ay <= s4
                        and bx >= s1 and bx <= s3 and by >= s2 and by <= s4)
                    and not (hid and hid[j] and hid[j] <= upTo
                        and ax >= x1 and ax <= x2 and ay >= y1 and ay <= y2
                        and bx >= x1 and bx <= x2 and by >= y1 and by <= y2) then
                    lines = lines + 1
                    if lines > budget then return list, lines end
                end
            end
        end
    end
    return list, lines
end

-- Detail level of a track for the area at zoom z: the finest whose
-- tolerance is at least SHAPE_PIXELS on screen (or level lowest, if that is
-- coarser), made coarser until the lines in range fit the budget, or until
-- the level keeps only what every level keeps (lods.ends), as no level
-- draws fewer. It starts looking at level start, the one picked last time:
-- most builds pick the same again, and counting each level up from the
-- finest was most of a build on a long journey. Returns the level, its
-- chunks in range, k, and the count (ChunksIn).
local function PickLod(track, x1, y1, x2, y2, z, budget, start, lowest, skip, exact, highest)
    lowest = math.max(lowest or 0, math.ceil(math.log(MAX_ZOOM / z) / math.log(LOD_STEP) - 1e-9))
    highest = math.max(lowest, highest or MAX_LOD)
    local k = math.min(highest, math.max(lowest, start or lowest))
    local lod = GetLod(track, k)
    local list, total = ChunksIn(track, lod, x1, y1, x2, y2, budget, skip, exact)
    if total <= budget then
        while k > lowest do
            local finer = GetLod(track, k - 1)
            local finerList, finerTotal = ChunksIn(track, finer, x1, y1, x2, y2, budget, skip, exact)
            if finerTotal > budget then break end
            k, lod, list, total = k - 1, finer, finerList, finerTotal
        end
    else
        while k < highest and #lod.idx > track.lods.ends do
            k = k + 1
            lod = GetLod(track, k)
            list, total = ChunksIn(track, lod, x1, y1, x2, y2, budget, skip, exact)
            if total <= budget then break end
        end
        -- Nothing fits: the count stopped at the budget, so in full now.
        if total > budget then
            list, total = ChunksIn(track, lod, x1, y1, x2, y2, math.huge, skip, true)
        end
    end
    return lod, list, k, total
end

-- Lines of a track's detail level inside the area, in point order:
-- { x1, y1, x2, y2, mode, pointIndex }. mode is nil for tracks without pm.
-- With jumps set, the gap before each segment (hearthstone, teleport, boat,
-- graveyard) is a line too, with mode "j". A jump drawn on a sea course or
-- lane counts as inside wherever its curve is (track.seaTrips).
-- With near ({ x1, y1, x2, y2 }) and far set, only points inside near
-- keep the level's detail: outside it, only those detail level far keeps
-- are, a coarser one (GetLod's top), which keeps segments' first and last
-- points too (DETAIL).
local function LinesIn(track, lod, list, x1, y1, x2, y2, jumps, near, far)
    local idx, px, py, pm, brk = lod.idx, track.px, track.py, track.pm, track.brk
    local top = track.lods.top
    local hid, mergeTo = lod.hid, track.mergeUpTo or math.huge
    -- The latest point any line left out waits for: a replay back before it
    -- must draw that line again (NeedsPathBuild).
    track.mergeMax = nil
    local seaTrips = jumps and track.seaTrips or {}
    local drawn, count = {}, 0
    local p, upTo           -- the last point kept, and the j it was kept at or passed over
    for _, ch in ipairs(list) do
        local first = math.max(2, ch[1])
        -- A chunk not following on from the last one starts from the point
        -- before its run, which its box includes.
        if upTo ~= first - 1 then p = idx[first - 1] end
        for j = first, ch[2] do
            local i = idx[j]
            local x, y = px[i], py[i]
            if not near or top[i] >= far
                or x >= near[1] and x <= near[3] and y >= near[2] and y <= near[4] then
                if jumps or not brk[i] then
                    local ax, ay, bx, by = px[p], py[p], x, y
                    local box = brk[i] and seaTrips[i] and seaTrips[i].box
                    local outside
                    if box then
                        outside = box[3] < x1 or box[1] > x2 or box[4] < y1 or box[2] > y2
                    else
                        outside = math.max(ax, bx) < x1 or math.min(ax, bx) > x2
                            or math.max(ay, by) < y1 or math.min(ay, by) > y2
                    end
                    -- A line merged into newer walks is left out, but only
                    -- the level's own line with both ends in the near part:
                    -- outside it the far part draws coarser joins, which may
                    -- pass well away from the line's cover.
                    local merged = hid and hid[j] and hid[j] <= mergeTo and p == idx[j - 1]
                        and (not near or ax >= near[1] and ax <= near[3] and ay >= near[2] and ay <= near[4]
                            and x >= near[1] and x <= near[3] and y >= near[2] and y <= near[4])
                    if merged and not outside and (ax ~= bx or ay ~= by) then
                        track.mergeMax = math.max(track.mergeMax or 0, hid[j])
                    end
                    if (ax ~= bx or ay ~= by) and not outside and not merged then
                        count = count + 1
                        drawn[count] = { ax, ay, bx, by, brk[i] and "j" or pm and pm[i], i }
                    end
                end
                p = i
            end
        end
        upTo = ch[2]
    end
    return drawn
end

-- Lines of a track for a build at zoom z over the area x1, y1, x2, y2, with
-- the view's near part (near) in more detail than the rest (DETAIL).
-- Returns the lines, the near part's detail level, and whether moving the
-- view could draw it more finely: zoned, or coarser than the zoom's finest
-- to fit the budget. A build already at the finest everywhere has nothing
-- to gain from a pan, so it waits for the view to leave the whole area
-- (NeedsPathBuild).
DETAIL.Lines = function(track, x1, y1, x2, y2, near, z)
    -- The levels picked last time, as far above the finest the zoom allows.
    local finest = math.max(0, math.ceil(math.log(MAX_ZOOM / z) / math.log(LOD_STEP) - 1e-9))
    local last = track.picked or {}
    track.picked = last
    local lod, list, k = PickLod(track, x1, y1, x2, y2, z, MAX_LINES, last[1] and finest + last[1])
    last[1] = k - finest
    local far
    -- Where the whole area fits at the finest level the zoom allows, or as
    -- finely as the near part would, it is all drawn at that level.
    if k > finest then
        local nearLod, _, nearK, nearCount = PickLod(track, near[1], near[2], near[3], near[4], z,
            DETAIL.NEAR_LINES, last[2] and finest + last[2], nil, nil, true)
        last[2] = nearK - finest
        if nearK < k then
            -- The rest gets what the near part left, counting only its
            -- lines outside the near part: the finest level that fits.
            local room = math.max(DETAIL.FAR_LINES, math.floor((MAX_LINES - nearCount) * DETAIL.FAR_SHARE))
            local _, _, farK, farCount = PickLod(track, x1, y1, x2, y2, z, room,
                finest + (last[3] or last[1]), nearK + 1, near)
            last[3] = farK - finest
            -- Segments' ends alone can be more than its room: the near
            -- part makes way, and failing that all of it is drawn at the
            -- one level it fits at, so the budget holds.
            local fits = true
            if nearCount + farCount > MAX_LINES then
                local count
                nearLod, _, nearK, count = PickLod(track, near[1], near[2], near[3], near[4], z,
                    MAX_LINES - farCount, nearK + 1, nearK + 1, nil, true, farK)
                fits = count + farCount <= MAX_LINES
            end
            if fits and nearK < farK then
                lod, k, far = nearLod, nearK, farK
                list = ChunksIn(track, lod, x1, y1, x2, y2, math.huge)
            end
        end
    end
    return LinesIn(track, lod, list, x1, y1, x2, y2, true, far and near, far), k, far ~= nil or k > finest
end

-- Jump arcs ------------------------------------------------------------------------

-- Points along an arc from (x1, y1) to (x2, y2) in content units, bent up
-- the screen by bend (JUMP_ARC if unset; 0 is straight): { x, y, distance
-- along the arc }.
local function JumpCurve(x1, y1, x2, y2, bend)
    bend = bend or JUMP_ARC
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    -- Unit normal, turned to point up the screen (content y runs down).
    local nx, ny = -dy / length, dx / length
    if ny > 0 or (ny == 0 and nx > 0) then
        nx, ny = -nx, -ny
    end
    local cx = (x1 + x2) / 2 + nx * length * bend
    local cy = (y1 + y2) / 2 + ny * length * bend
    local points, along = {}, 0
    for i = 0, JUMP_ARC_STEPS do
        local f = i / JUMP_ARC_STEPS
        local x = (1 - f) ^ 2 * x1 + 2 * (1 - f) * f * cx + f * f * x2
        local y = (1 - f) ^ 2 * y1 + 2 * (1 - f) * f * cy + f * f * y2
        if i > 0 then
            local p = points[i]
            along = along + math.sqrt((x - p[1]) ^ 2 + (y - p[2]) ^ 2)
        end
        points[i + 1] = { x, y, along }
    end
    return points
end

-- Position at distance d along a curve.
local function PointAlong(points, d)
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if d <= b[3] then
            local f = (d - a[3]) / math.max(b[3] - a[3], 1e-9)
            return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
        end
    end
    local last = points[#points]
    return last[1], last[2]
end

-- Shows jump icons for jumps the replay has reached, when zoomed in far
-- enough or when their arc is hovered.
local function ShowJumpIcons()
    local zoomedIn = state.zoom >= JUMP_ICON_ZOOM
    for _, jump in ipairs(state.jumps) do
        if jump.icon then
            jump.icon:SetShown(jump.visible and (zoomedIn or state.hover == jump.spec))
        end
    end
end

-- Shows the jumps the replay has reached (up to drawn line shown). An arc
-- can be hundreds of pieces, so only arcs whose state changed are touched.
-- One coming into sight in view has its chunks in view sized for the zoom
-- first, if they aren't (UpdateVisible sizes only those already shown).
local function ShowJumps(shown)
    for _, jump in ipairs(state.jumps) do
        local visible = jump.index <= shown
        if visible ~= jump.visible then
            jump.visible = visible
            for _, c in ipairs(visible and jump.inView and jump.chunks or {}) do
                if c.inView and c.tz ~= state.lineZoom then
                    ns.PathLines.FitJump(jump, state.lineZoom, true, c[5], c[6])
                    c.tz = state.lineZoom
                end
            end
            for _, part in ipairs(jump.parts) do
                part:SetShown(visible)
            end
        end
    end
    ShowJumpIcons()
end

-- Adds a piece to a jump, in chunks of 16 pieces in a row with a box round
-- each (in content units, from (x1, y1) to (x2, y2) for each piece), so a
-- zoom sizes only the chunks in view (UpdateVisible): an arc reaching into
-- view had every piece sized, twice the pieces in view.
DETAIL.AddPart = function(jump, part, x1, y1, x2, y2)
    local parts, chunks = jump.parts, jump.chunks
    local n = #parts + 1
    parts[n] = part
    local c = chunks[#chunks]
    if not c or n - c[5] >= 16 then
        c = { math.huge, math.huge, -math.huge, -math.huge, n, n, tz = jump.tz }
        chunks[#chunks + 1] = c
    end
    c[1], c[2] = math.min(c[1], x1, x2), math.min(c[2], y1, y2)
    c[3], c[4], c[6] = math.max(c[3], x1, x2), math.max(c[4], y1, y2), n
end

-- A line piece of a jump, in a flat colour on OVERLAY sublayer layer (one
-- per stacked line: in one sublayer the drawing order is not kept). width is
-- in screen pixels and kept on the line for zoom changes. Lines are reused:
-- only what differs from what the line has is set (colour, sublayer,
-- thickness), and a ribbon's texture, tint and blend are undone.
local function JumpLine(jump, ax, ay, bx, by, width, r, g, b, a, layer)
    local set = state.jumpSet
    ---@type any
    local line = table.remove(set.lines)
    if not line then
        line = set.frame:CreateLine(nil, "OVERLAY") --[[@as any]]
        line.isLine = true
    end
    line.spare = nil
    line:SetStartPoint("TOPLEFT", pathLayer, ax, -ay)
    line:SetEndPoint("TOPLEFT", pathLayer, bx, -by)
    if line.ribbon then
        line:SetVertexColor(1, 1, 1, 1)
        line:SetBlendMode("BLEND")
        line:SetTexCoord(0, 1, 0, 1)
        line.ribbon = nil
    end
    if line.cr ~= r or line.cg ~= g or line.cb ~= b or line.ca ~= a then
        line:SetColorTexture(r, g, b, a)
        line.cr, line.cg, line.cb, line.ca = r, g, b, a
    end
    layer = layer or 0
    if line.sublayer ~= layer then
        line:SetDrawLayer("OVERLAY", layer)
        line.sublayer = layer
    end
    if line.width ~= width or line.sz ~= state.zoom then
        line:SetThickness(width / state.zoom)
        line.width, line.sz = width, state.zoom
    end
    DETAIL.AddPart(jump, line, ax, ay, bx, by)
    return line
end

local function JumpStroke(jump, style, ax, ay, bx, by)
    if not style.plain then
        JumpLine(jump, ax, ay, bx, by, JUMP_OUTLINE, unpack(JUMP_OUTLINE_COLOR))
    end
    JumpLine(jump, ax, ay, bx, by, style.plain and LINE_WIDTH or JUMP_LINE, style[2], style[3], style[4], style[5], 1)
end

-- Spare dots of an arc frame (JumpSet) that show file, or round ones, on
-- sublayer layer: outlines, the dots over them and the finish marks each
-- keep to their own, so a reused one has its texture, and an outline its
-- colour.
DETAIL.DotPool = function(set, file, layer)
    local key = (file or "round") .. ":" .. layer
    local pool = set.dots[key]
    if not pool then
        pool = {}
        set.dots[key] = pool
    end
    return pool
end

-- A dot of a jump, on OVERLAY sublayer layer, at alpha. size is in screen
-- pixels. file, if given, replaces the round dot, uncoloured (finish marks).
-- Spare dots are kept by what they show, and only what differs from what a
-- reused dot has is set (colour, sublayer, size, alpha): set up again in
-- full, a dot took ten calls, and this saves about a third of a build's
-- (offline, #154).
local function JumpDot(jump, x, y, size, r, g, b, a, file, layer, alpha)
    local set = state.jumpSet
    ---@type any
    local dot = table.remove(DETAIL.DotPool(set, file, layer))
    if not dot then
        dot = set.frame:CreateTexture(nil, "OVERLAY") --[[@as any]]
        dot.file = file or false
        if file then
            dot:SetTexture(file)
        else
            dot:SetAtlas("WhiteCircle-RaidBlips")
        end
    end
    dot.spare = nil
    if dot.cr ~= r or dot.cg ~= g or dot.cb ~= b or dot.ca ~= a then
        dot:SetVertexColor(r, g, b, a)
        dot.cr, dot.cg, dot.cb, dot.ca = r, g, b, a
    end
    if dot.sublayer ~= layer then
        dot:SetDrawLayer("OVERLAY", layer)
        dot.sublayer = layer
    end
    -- Its only point is its centre, so setting it again moves it.
    dot:SetPoint("CENTER", pathLayer, "TOPLEFT", x, -y)
    if dot.size ~= size or dot.sz ~= state.zoom then
        dot:SetSize(size / state.zoom, size / state.zoom)
        dot.size, dot.sz = size, state.zoom
    end
    dot.fade, dot.target, dot.alpha, dot.key = nil, nil, nil, nil
    if dot.alphaSet ~= alpha then
        dot:SetAlpha(alpha)
        dot.alphaSet = alpha
    end
    DETAIL.AddPart(jump, dot, x, y, x, y)
    return dot
end

-- Jump arcs are kept for the last JUMP_SETS doublings of the zoom the map
-- was built in (JumpZoom), each doubling's on a frame of its own over the
-- path layer: zooming back to one shows its arcs with one call rather than
-- drawing them again. Zooming from a city to its continent and back drew
-- every arc at each step; kept, 3 builds in 13 drew them (offline, #154).
-- Each frame keeps its own spare pieces, as a piece stays on the frame it
-- was made on. When a doubling not kept is wanted, the one farthest from
-- it makes way: its pieces become spares as they are, and the build hides
-- those it does not use (BuildJumps).
DETAIL.JUMP_SETS = 3
DETAIL.JumpSet = function(zb)
    local current = state.jumpSet
    if current and current.zb == zb then
        return
    end
    if current then
        current.jumps, current.cache, current.key = state.jumps, state.jumpCache, state.jumpKey
        current.ribbons = state.ribbons
        current.frame:Hide()
        for _, jump in ipairs(state.jumps) do
            if jump.icon then
                jump.icon:Hide()
            end
        end
    end
    ---@type any
    local set
    local sets = state.jumpSets
    for _, s in ipairs(sets) do
        if s.zb == zb then
            set = s
        end
    end
    if not set and #sets < DETAIL.JUMP_SETS then
        local frame = CreateFrame("Frame", nil, pathLayer)
        frame:SetAllPoints()
        -- Over the path's lines, under the portals (Map's CreateMap).
        frame:SetFrameLevel(pathLayer:GetFrameLevel() + 1)
        set = { frame = frame, lines = {}, dots = {}, jumps = {}, ribbons = {} }
        sets[#sets + 1] = set
    elseif not set then
        local far = -1
        for _, s in ipairs(sets) do
            local d = math.abs(math.log(s.zb / zb))
            if d > far then
                far, set = d, s
            end
        end
        for _, jump in ipairs(set.jumps) do
            for _, part in ipairs(jump.parts) do
                -- Shown if its arc was: the build hides it if not used.
                part.spare = jump.visible
                local pool = part.isLine and set.lines or DETAIL.DotPool(set, part.file, part.sublayer)
                pool[#pool + 1] = part
            end
            if jump.icon then
                jump.icon:Hide()
                jumpIcons[#jumpIcons + 1] = jump.icon
            end
        end
        set.jumps, set.cache, set.key, set.ribbons, set.spares = {}, nil, nil, {}, true
    end
    set.zb = zb
    state.jumpSet = set
    state.jumps, state.jumpCache, state.jumpKey, state.ribbons = set.jumps, set.cache, set.key, set.ribbons
    set.frame:Show()
    -- Its arcs are sized for the zoom they were left at: UpdateVisible
    -- sizes those in view at once, as if they had come into view, and fades
    -- left unfinished finish.
    for _, jump in ipairs(state.jumps) do
        jump.inView = false
        for _, c in ipairs(jump.chunks) do
            c.inView = false
        end
    end
    state.dotsFading = true
end

-- The doubling of the zoom z is in, as the zoom it starts at (a power of
-- two): what jump arcs are drawn for (BuildJumps).
DETAIL.JumpZoom = function(z)
    return 2 ^ math.floor(math.log(z) / math.log(2) + 1e-9)
end

-- Draws an arc for each jump in drawn, in the style of its reason, with the
-- reason's icon at the top. Sizes are in screen pixels and zoom changes
-- resize them (SetLineThickness, PathLines.FitJump). Dashes and dots are
-- only placed inside area { x1, y1, x2, y2 }, so a long boat trip seen close
-- up keeps its spacing instead of hitting JUMP_MAX_PIECES across the whole
-- sea.
-- What depends on the zoom (dash and dot spacing, the dots' clearance from
-- the marks, how near a dot may sit to another) is worked out for the
-- doubling z is in (JumpZoom), not z itself, so arcs are kept as drawn while
-- the zoom stays within it: drawing every arc again after each zoom step
-- took 110 to 210 ms of a build in game (perflog, 2026-11-20, #154).
local function BuildJumps(drawn, shown, z, area)
    local zb = DETAIL.JumpZoom(z)
    DETAIL.JumpSet(zb)
    -- The middle of the doubling: spacing worked out for it is within 0.7
    -- to 1.4 times what it is meant to be on screen across the doubling.
    local zm = zb * math.sqrt(2)
    -- The same jumps over the same area in the same doubling as the last
    -- build (the live map adding a point, #136, or a zoom step) keep their
    -- arcs as drawn, as an arc of dots is hundreds of pieces: only their
    -- places in drawn move.
    ---@type any[]
    local key = { zb, area[1], area[2], area[3], area[4] }
    local found = {}
    for i, spec in ipairs(drawn) do
        if spec[5] == "j" and not spec.hidden then
            local n, p = #key, spec[6]
            found[#found + 1] = i
            key[n + 1], key[n + 2], key[n + 3], key[n + 4] = spec[1], spec[2], spec[3], spec[4]
            key[n + 5], key[n + 6], key[n + 7] = p, state.pj[p] or false, state.seaTrips[p] or false
        end
    end
    local last = state.jumpKey
    local same = last and #last == #key and #found == #state.jumps
    for k = 1, same and #key or 0 do
        if last[k] ~= key[k] then
            same = false
            break
        end
    end
    state.jumpKey = key
    if same then
        for k, jump in ipairs(state.jumps) do
            local spec = drawn[found[k]]
            spec.curve, spec.portal = jump.spec.curve, jump.spec.portal
            jump.index, jump.spec = found[k], spec
        end
        ShowJumps(shown)
        return
    end

    -- Dots still fading carry their alpha over, by place, so a rebuild in
    -- the middle of a zoom does not cut the fade short.
    local fadingAlpha = {}
    if state.dotsFading then
        for _, jump in ipairs(state.jumps) do
            for _, dot in ipairs(jump.parts) do
                if dot.key then
                    fadingAlpha[dot.key] = dot.alpha
                end
            end
        end
    end
    -- Arcs drawn last build, by what they were drawn from (cacheKey below):
    -- one drawn from the same again keeps its pieces as they are. Placing
    -- every dot of every arc again was most of a build, 30 to 80 ms in
    -- game, though few arcs change when the view moves (#152).
    local before, kept, previous = state.jumpCache or {}, {}, state.jumps
    state.jumpBuilds = (state.jumpBuilds or 0) + 1
    local build = state.jumpBuilds
    local prefix = tostring(state.journey) .. ":" .. zb
    ns.Portals:Begin(z)
    local jumps = {}
    -- Ribbon effect lines for OnUpdate to scroll, and the sea lanes whose
    -- trunk is drawn already.
    local ribbons, lanesDrawn = {}, {}
    state.ribbons = ribbons

    -- Dots already placed, per jump style, in a grid of cells: where trips
    -- run along the same line (two routes sharing a course, a trip out and
    -- back near the coast), a dot that would sit beside one of the same
    -- style is left out, so the lines merge into one row of dots. Only for
    -- an earlier dot of at least the same row, which shows at every zoom
    -- this one would. Cells are numbered, not named: a name made of two
    -- numbers for each of nine cells round every dot cost a build dearly.
    local placed = {}
    local function Cells(style)
        local grid = placed[style]
        if not grid then
            grid = {}
            placed[style] = grid
        end
        return grid
    end
    local function Covered(style, x, y, row, near)
        local grid = Cells(style)
        local cx, cy = math.floor(x / near), math.floor(y / near)
        for gx = cx - 1, cx + 1 do
            for gy = cy - 1, cy + 1 do
                for _, d in ipairs(grid[gx * 4194304 + gy] or {}) do
                    local dx, dy = d[1] - x, d[2] - y
                    if d[3] >= row and dx * dx + dy * dy < near * near then
                        return true
                    end
                end
            end
        end
        return false
    end
    local function Mark(style, x, y, row, near)
        local grid = Cells(style)
        local cell = math.floor(x / near) * 4194304 + math.floor(y / near)
        grid[cell] = grid[cell] or {}
        table.insert(grid[cell], { x, y, row })
    end
    -- Takes back the dot Mark placed last at this spot.
    local function Unmark(style, x, y, near)
        table.remove(Cells(style)[math.floor(x / near) * 4194304 + math.floor(y / near)])
    end

    -- Stretches of the curve inside the area, as { from, to } distances
    -- along it, and their total length.
    local function Spans(curve)
        local spans, length = {}, 0
        for p = 2, #curve do
            local a, b = curve[p - 1], curve[p]
            if not (math.max(a[1], b[1]) < area[1] or math.min(a[1], b[1]) > area[3]
                or math.max(a[2], b[2]) < area[2] or math.min(a[2], b[2]) > area[4]) then
                local open = spans[#spans]
                if open and open[2] == a[3] then
                    open[2] = b[3]
                else
                    spans[#spans + 1] = { a[3], b[3] }
                end
                length = length + b[3] - a[3]
            end
        end
        return spans, length
    end

    -- Spacing near wanted (content units), rounded to a power of two and
    -- doubled until it reaches the floor. Rebuilds as the zoom changes then
    -- keep most dots and dashes where they were, rather than shuffling all.
    local function Snap(wanted, floor)
        local spacing = 2 ^ math.floor(math.log(wanted) / math.log(2) + 0.5)
        while spacing < floor do
            spacing = spacing * 2
        end
        return spacing
    end
    for i, spec in ipairs(drawn) do
        if spec[5] == "j" and not spec.hidden then
            local style = Style.Jump(state.pj[spec[6]])
            local ends = state.seaTrips[spec[6]]
            local curve = ends and (ends.curve or JumpCurve(ends[1], ends[2], ends[3], ends[4]))
                or JumpCurve(spec[1], spec[2], spec[3], spec[4], style.bend)
            local total = curve[#curve][3]
            -- A lane's trunk is drawn by its first trip only: the same band
            -- again on top would add its glowing effects up.
            local trunk = style.style == "ribbon" and ends and ends.trunk
            local skip = trunk and lanesDrawn[ends.lane]
            if trunk then
                lanesDrawn[ends.lane] = true
            end
            -- Dashes and dots go only where the curve is inside the area.
            local spans, length
            if style.style ~= "portal" and style.style ~= "solid" and style.style ~= "ribbon" then
                spans, length = Spans(curve)
            end
            -- What the arc is drawn from. Portals are not kept, as
            -- Portals.lua lays all of them out again at each build.
            local cacheKey
            if style.style ~= "portal" then
                local p = spec[6]
                local from = { prefix, p, state.pj[p] or "", spec[1], spec[2], spec[3], spec[4], skip and 1 or 0 }
                for _, span in ipairs(spans or {}) do
                    from[#from + 1], from[#from + 2] = span[1], span[2]
                end
                cacheKey = table.concat(from, ":")
            end
            -- An arc drawn from the same last time is kept, unless a dot it
            -- left out for one already there has lost that one (an arc
            -- before it went). Its own dots go in first, as it leaves out
            -- some of its own finest row for them; if it is drawn again
            -- they come out, or it would leave out its own dots. Kept, its
            -- dots count as placed for the arcs after it.
            local jump = cacheKey and before[cacheKey]
            for _, d in ipairs(jump and jump.marks or {}) do
                Mark(style, d[1], d[2], d[3], d[4])
            end
            for _, d in ipairs(jump and jump.skipped or {}) do
                if not Covered(style, d[1], d[2], d[3], d[4]) then
                    for m = #jump.marks, 1, -1 do
                        local mark = jump.marks[m]
                        Unmark(style, mark[1], mark[2], mark[4])
                    end
                    jump = nil
                    break
                end
            end
            if jump then
                for _, rb in ipairs(jump.ribbons) do
                    ribbons[#ribbons + 1] = rb
                end
                jump.index, jump.spec, jump.build = i, spec, build
                spec.curve = curve
            else
                -- Dots are counted from anchor, so trips on one route share them:
                -- a boat course's middle waypoint, or the middle of the arc.
                local anchor = ends and (ends.anchor or total / 2) or 0
                -- Marks at the curve's ends: a boat route drawn the other way
                -- round from how it was sailed has its X at the start.
                local head, tail = style.start, style.finish
                if ends and ends.flip then
                    head, tail = tail, head
                end
                -- box: around the curve, for sizing only jumps in view
                -- (UpdateVisible); tz: the zoom its pieces are sized for.
                local box = { math.huge, math.huge, -math.huge, -math.huge }
                for _, c in ipairs(curve) do
                    box[1], box[2] = math.min(box[1], c[1]), math.min(box[2], c[2])
                    box[3], box[4] = math.max(box[3], c[1]), math.max(box[4], c[2])
                end
                jump = { index = i, parts = {}, chunks = {}, spec = spec, box = box, tz = z,
                    build = build, skipped = {}, marks = {}, ribbons = {} }
                spec.curve = curve

                if style.style == "portal" then
                    -- Hovered at its ends, not along the arc (LineAt).
                    spec.portal = true
                    ns.Portals:Add(jump, style, curve[1][1], curve[1][2],
                        curve[#curve][1], curve[#curve][2], i <= shown)
                elseif style.style == "solid" then
                    for p = 2, #curve do
                        JumpStroke(jump, style, curve[p - 1][1], curve[p - 1][2], curve[p][1], curve[p][2])
                    end
                elseif style.style == "ribbon" then
                    local r, g, b, w = style[2], style[3], style[4], style.width
                    for p = 2, #curve do
                        local pa, pb = curve[p - 1], curve[p]
                        local middle = (pa[3] + pb[3]) / 2
                        if not (skip and middle > trunk[1] and middle < trunk[2]) then
                            JumpLine(jump, pa[1], pa[2], pb[1], pb[2], w + 1, 0, 0, 0, 0.7, 0)
                            JumpLine(jump, pa[1], pa[2], pb[1], pb[2], w, r * 0.3, g * 0.3, b * 0.3, 0.95, 1)
                            for e, effect in ipairs(style.effects) do
                                local line = JumpLine(jump, pa[1], pa[2], pb[1], pb[2], w - 1, 1, 1, 1, 1, 1 + e)
                                line:SetTexture("Interface\\AddOns\\" .. addonName .. "\\Travel\\" .. effect[1],
                                    "REPEAT", "REPEAT")
                                line:SetVertexColor(r, g, b, 1)
                                line:SetBlendMode("ADD")
                                -- Its colour is the texture's now: JumpLine sets one again.
                                line.ribbon, line.cr = true, nil
                                -- One texture repeat along the band is px screen
                                -- pixels, which keeps the texture's shape at any
                                -- zoom; OnUpdate scrolls it.
                                local rb = {
                                    line = line, jump = jump, from = pa[3], to = pb[3],
                                    px = w * effect[2], speed = effect[3],
                                }
                                ribbons[#ribbons + 1] = rb
                                jump.ribbons[#jump.ribbons + 1] = rb
                            end
                        end
                    end
                elseif style.style == "dash" then
                    -- Steps from the start of the curve, so dashes stay put as the view moves.
                    local period = Snap((JUMP_DASH + JUMP_GAP) / zm, length / JUMP_MAX_PIECES)
                    local dash = period * JUMP_DASH / (JUMP_DASH + JUMP_GAP)
                    for _, span in ipairs(spans) do
                        for d = math.floor(span[1] / period) * period, span[2], period do
                            local ax, ay = PointAlong(curve, d)
                            local bx, by = PointAlong(curve, math.min(d + dash, total))
                            JumpStroke(jump, style, ax, ay, bx, by)
                        end
                    end
                else
                    -- Dots in rows that halve the spacing: every 4th dot, every 2nd,
                    -- every one. A row shows once zooming spreads it to px apart on
                    -- screen, fading in or out over a moment (SetLineThickness and
                    -- OnUpdate), so zooming eases dots in and out rather than
                    -- refilling the line at the next build, and at rest every dot
                    -- is either fully shown or hidden. The finest row covers
                    -- zooming in 4 times before a rebuild is needed.
                    local size = style.dot or JUMP_DOT
                    local px = style.spacing or JUMP_DOT_SPACING
                    local fine = 2 ^ math.ceil(math.log(px / zb) / math.log(2)) / 4
                    while length / fine > JUMP_MAX_PIECES * 2 do
                        fine = fine * 2
                    end
                    -- Dots keep clear of start and finish marks rather than run under them.
                    local first = head and (head[2] / 2 + px / 3) / zm or 0
                    local last = total - (tail and (tail[2] / 2 + px / 3) / zm or 0)
                    for _, span in ipairs(spans) do
                        for k = math.ceil((math.max(span[1], first) - anchor) / fine),
                            math.floor((math.min(span[2], last) - anchor) / fine) do
                            -- Spacing of the sparsest row this dot is in.
                            local row, n = k == 0 and total or fine, math.abs(k)
                            while n > 0 and n % 2 == 0 and row < total do
                                n, row = n / 2, row * 2
                            end
                            local target = row * z >= px and 1 or 0
                            local x, y = PointAlong(curve, anchor + k * fine)
                            local near = 0.6 * px / zm
                            if Covered(style, x, y, row, near) then
                                jump.skipped[#jump.skipped + 1] = { x, y, row, near }
                            else
                                Mark(style, x, y, row, near)
                                jump.marks[#jump.marks + 1] = { x, y, row, near }
                                -- The coloured dot on a sublayer above its outline: in one
                                -- sublayer the order is not kept, and the outline can cover it.
                                local oc = JUMP_OUTLINE_COLOR
                                for layer = 1, 2 do
                                    local key = x .. ":" .. y .. ":" .. layer
                                    local alpha = fadingAlpha[key] or target
                                    local dot = layer == 1
                                        and JumpDot(jump, x, y, size + 2, oc[1], oc[2], oc[3], oc[4], nil, 0, alpha)
                                        or JumpDot(jump, x, y, size, style[2], style[3], style[4], style[5], nil, 1, alpha)
                                    dot.fade, dot.fadePx, dot.target, dot.alpha, dot.key = row, px, target, alpha, key
                                end
                            end
                        end
                    end
                end
                -- A trip out and back can put an X on a ring, so the X (where the
                -- player landed) draws above.
                if head then
                    JumpDot(jump, curve[1][1], curve[1][2], head[2], 1, 1, 1, 1, head[1],
                        head == style.finish and 3 or 2, 1)
                end
                if tail then
                    local p = curve[#curve]
                    JumpDot(jump, p[1], p[2], tail[2], 1, 1, 1, 1, tail[1], tail == style.finish and 3 or 2, 1)
                end

                if style.icon then
                    local icon = table.remove(jumpIcons)
                    if not icon then
                        icon = overlay:CreateTexture(nil, "OVERLAY", nil, 5)
                        icon:SetSize(JUMP_ICON, JUMP_ICON)
                    end
                    icon:SetAtlas(style.icon)
                    jump.icon = icon
                    -- On a lane, at its middle, where every trip on it puts its icon.
                    jump.x, jump.y = PointAlong(curve, ends and ends.anchor or total / 2)
                end
            end
            if cacheKey then
                kept[cacheKey] = jump
            end
            jumps[#jumps + 1] = jump
        end
    end
    -- Arcs not kept give their pieces back for later ones, hidden, as do
    -- the spares of a doubling that made way (JumpSet) that went unused.
    local set = state.jumpSet
    if set.spares then
        for _, pool in pairs(set.dots) do
            for _, part in ipairs(pool) do
                if part.spare then
                    part:Hide()
                    part.spare = nil
                end
            end
        end
        for _, part in ipairs(set.lines) do
            if part.spare then
                part:Hide()
                part.spare = nil
            end
        end
        set.spares = nil
    end
    for _, jump in ipairs(previous) do
        if jump.build ~= build then
            for _, part in ipairs(jump.parts) do
                part:Hide()
                local pool = part.isLine and set.lines or DETAIL.DotPool(set, part.file, part.sublayer)
                pool[#pool + 1] = part
            end
            if jump.icon then
                jump.icon:Hide()
                jumpIcons[#jumpIcons + 1] = jump.icon
            end
        end
    end
    ns.Portals:Finish()
    state.jumps, state.jumpCache = jumps, kept
    ShowJumps(shown)
end

-- Lines and jumps are sized for the zoom now from here on: UpdateVisible,
-- which follows, resizes those in view, and the rest as they come into view
-- (PathLines.lua). Resizing every one of them was most of a zoom frame.
local function SetLineThickness()
    local z = state.zoom
    ns.Portals:SetZoom(z)
    state.lineZoom, state.fitMin = z, math.min(state.fitMin, z)
end

-- Tracks for the characters whose path is turned on, from the roster's paths
-- in content units, breaking where each piece starts. Like the player's own
-- track they carry pm (mode per point) and pj (jump reason at a piece's
-- first point), and colors holds a colour per mode and for jumps.
local function BuildOtherTracks()
    local tracks, trackOf = {}, {}
    local shown = ns.Roster:ViewEntry()
    for _, e in ipairs(ns.Roster:Entries()) do
        if ns.db.showPaths[e.key] and e ~= shown then
            local px, py, pm, pj, brk, pt, n = {}, {}, {}, {}, {}, {}, 0
            local timed = true      -- paths from before the journey copy have no times
            -- This character's own journey is live, its roster copy as of logout.
            local me = ns.Roster:IsMe(e)
            local paths = ns.Range:TrimPaths(me and ns.Recorder:GetPaths() or ns.Roster:Paths(e))
            local previous
            for _, path in ipairs(paths) do
                local toContent = state.toContent[path.c]
                if toContent and #path.x > 0 then
                    local continues = ns.Recorder:Continues(previous, path)
                    for i = 1, #path.x do
                        n = n + 1
                        px[n], py[n] = toContent(path.x[i], path.y[i])
                        pm[n], brk[n] = path.m, i == 1 and not continues
                        pt[n] = path.t[i]
                        timed = timed and pt[n] ~= nil
                    end
                    pj[n - #path.x + 1] = ns.Recorder:JumpReason(previous, path)
                end
                previous = path
            end
            local r, g, b = ns.ClassColor(e.class)
            local colors = {}
            for mode, a in pairs(OTHER.ALPHA) do
                colors[mode] = { r, g, b, a }
            end
            local track = {
                n = n, px = px, py = py, pm = pm, pj = pj, brk = brk, lods = {}, colors = colors,
                entry = e, pt = timed and n > 0 and pt or nil,
                events = me and ns.char.events or e.journey and e.journey.events,
            }
            tracks[#tracks + 1] = track
            trackOf[e] = track
        end
    end
    state.otherTracks, state.trackOf = tracks, trackOf
end

-- Lines of the other characters' tracks in the area, built with the player's
-- own path and the same way (DETAIL.Lines), each within MAX_LINES:
-- every line costs time on each zoom frame. Jumps with a known reason are arcs, made of
-- several lines that share the jump's spec fields.
-- Returns whether moving the view could draw any of them more finely (DETAIL.Lines).
local function BuildOtherLines(x1, y1, x2, y2, near, z)
    local otherDrawn, anyFiner = {}, false
    -- Each path's latest point a line left out waits for (LinesIn), so a
    -- replay together going back draws them again (NeedsPathBuild).
    state.otherMergeMax = {}
    for _, track in ipairs(state.otherTracks) do
        if track.n > 1 then
            track.mergeUpTo = state.clock and track.cur or math.huge
            local specs, _, finer = DETAIL.Lines(track, x1, y1, x2, y2, near, z)
            state.otherMergeMax[track] = track.mergeMax
            anyFiner = anyFiner or finer
            for _, spec in ipairs(specs) do
                spec.track = track
                local reason = spec[5] == "j" and track.pj[spec[6]]
                if reason and Style.Jump(reason).style == "none" then
                    -- (a stretch not recorded: nothing drawn, Style.lua)
                elseif reason then
                    local curve = JumpCurve(spec[1], spec[2], spec[3], spec[4],
                        Style.Jump(track.pj[spec[6]]).bend)
                    for p = 2, #curve do
                        local a, b = curve[p - 1], curve[p]
                        otherDrawn[#otherDrawn + 1] = { a[1], a[2], b[1], b[2], "j", spec[6], track = track, curve = curve }
                    end
                else
                    otherDrawn[#otherDrawn + 1] = spec
                end
            end
        end
    end
    -- Lines with the same ends as in the last build stay where they are
    -- (PathLines.Reuse); in view, UpdateVisible sizes them for the zoom.
    local order, spare = ns.PathLines.Reuse(state.otherDrawn, otherLines, state.otherLineCount, otherDrawn)
    local counts = ns.PathLines.count
    for i, spec in ipairs(otherDrawn) do
        local line = order[i]
        if line then
            counts.kept = counts.kept + 1
        else
            line = table.remove(spare)
            if not line then
                line = othersLayer:CreateLine(nil, "ARTWORK")
                line:SetThickness(OTHER.LINE_WIDTH / z)
                line.tz = z
            end
            line:SetStartPoint("TOPLEFT", othersLayer, spec[1], -spec[2])
            line:SetEndPoint("TOPLEFT", othersLayer, spec[3], -spec[4])
            counts.place = counts.place + 1
            order[i] = line
        end
        state.fitMin = math.min(state.fitMin, line.tz or z)
        local track = spec.track
        local color = track.colors[spec[5]] or track.colors.w
        if line.color ~= color then
            line:SetColorTexture(unpack(color))
            line.color = color
        end
        -- Replaying together, as far as the track has reached (Together.Apply).
        ns.PathLines.Reveal(line, spec, not (state.clock and track.cur) or spec[6] <= track.cur)
    end
    for _, line in ipairs(spare) do
        ns.PathLines.Reveal(line, nil, false)
        order[#order + 1] = line
    end
    otherLines = order
    local count = #otherDrawn
    -- Lines cannot be deleted, so with no path shown the whole layer is
    -- hidden, keeping leftover lines out of every zoom frame's work.
    othersLayer:SetShown(count > 0)
    state.otherLineCount, state.otherZoom = count, z
    state.otherDrawn = otherDrawn
    state.otherBoxes = ns.PathLines.Boxes(otherDrawn)
    if state.clock then
        Together.Apply(true)
    end
    return anyFiner
end

local function BuildPath()
    local started = debugprofilestop()
    state.perf.lod = 0
    local z = state.zoom
    local x1, y1, x2, y2 = ViewArea(PATH_MARGIN)
    local near = { ViewArea(DETAIL.NEAR) }

    local drawn, finer
    -- Lines merged into walks past the replay's point are drawn until it
    -- gets there (NeedsPathBuild builds again if it goes back).
    state.mergeUpTo = math.floor(state.cur)
    drawn, state.lodLevel, finer = DETAIL.Lines(state, x1, y1, x2, y2, near, z)
    state.perf.detail = debugprofilestop() - started
    local old = state.drawn
    local counts = ns.PathLines.count
    counts.place, counts.kept = 0, 0
    state.fitMin = z
    finer = BuildOtherLines(x1, y1, x2, y2, near, z) or finer
    state.perf.others = debugprofilestop() - started - state.perf.detail

    -- Lines with the same ends as in the last build stay where they are
    -- (PathLines.Reuse), and nothing already set on a line is set again;
    -- UpdateVisible, which follows, sizes the ones in view for the zoom.
    local placeStarted = debugprofilestop()
    -- Counted in the new lines: counted in the old ones, a build with more
    -- lines than the last left its newest hidden until the replay moved.
    state.drawn = drawn
    local shown = CountUpTo(math.floor(state.cur))
    local pb = state.pb
    local order, spare = ns.PathLines.Reuse(old, lines, state.lineCount, drawn)
    for i, spec in ipairs(drawn) do
        local line = order[i]
        if line then
            counts.kept = counts.kept + 1
        else
            line = table.remove(spare)
            if not line then
                line = pathLayer:CreateLine(nil, "ARTWORK")
                line:SetThickness(LINE_WIDTH / z)
                line.tz = z
            end
            line:SetStartPoint("TOPLEFT", pathLayer, spec[1], -spec[2])
            line:SetEndPoint("TOPLEFT", pathLayer, spec[3], -spec[4])
            counts.place = counts.place + 1
            order[i] = line
        end
        state.fitMin = math.min(state.fitMin, line.tz or z)
        local mode, band = spec[5], pb[spec[6]]
        -- Lines the filter hides get no tooltip, motes or arc either, nor do
        -- repeats of a boat trip, which the route's first trip stands for,
        -- nor jumps drawn as nothing (a stretch not recorded, Style.lua).
        local boat = mode == "j" and state.seaTrips[spec[6]]
        spec.hidden = mode == "t" and not ns.FilterShown("flights")
            or mode == "j" and not ns.FilterShown(Style.JUMP_CATEGORY[state.pj[spec[6]]])
            or mode == "j" and Style.Jump(state.pj[spec[6]]).style == "none"
            or boat and boat.dupe or false
        -- A jump's own line is never shown (void), as BuildJumps draws its
        -- arc, nor is one the filter hides: hidden rather than drawn
        -- clear, they cost nothing on a zoom.
        line.void = mode == "j" or spec.hidden
        if not line.void then
            local colorKey = (mode == "g" or mode == "t") and mode or mode .. band
            if line.colorKey ~= colorKey then
                line:SetColorTexture(Style.LineColor(mode, band))
                line.colorKey = colorKey
            end
        end
        ns.PathLines.Reveal(line, spec, i <= shown and not line.void)
    end
    for _, line in ipairs(spare) do
        ns.PathLines.Reveal(line, nil, false)
        order[#order + 1] = line
    end
    lines = order
    state.lineCount, state.shown, state.lineZoom = #drawn, shown, z
    state.boxes = ns.PathLines.Boxes(drawn)
    state.builds = state.builds + 1
    state.perf.placed, state.perf.kept = counts.place, counts.kept
    local jumpsStarted = debugprofilestop()
    -- Arcs are drawn over the area rounded out to whole views: a pan then
    -- leaves the stretch of each arc inside it as it was, and BuildJumps
    -- keeps the arc as drawn. With the area itself, every arc across its
    -- edge was drawn again at each pan, 15 to 35 ms in game (#152). Views
    -- at the zoom the doubling starts at (the widest in it), so a zoom step
    -- within it keeps the area too.
    local zb = DETAIL.JumpZoom(z)
    local vw, vh = state.W / zb, state.H / zb
    BuildJumps(drawn, shown, z, { math.floor(x1 / vw) * vw, math.floor(y1 / vh) * vh,
        math.ceil(x2 / vw) * vw, math.ceil(y2 / vh) * vh })
    state.perf.jumps = debugprofilestop() - jumpsStarted
    -- The near part only matters where a pan could draw more finely: a
    -- build at the finest level everywhere waits for the view to leave the
    -- whole area, as the replay's recentres would otherwise build each time.
    state.built = { x1, y1, x2, y2, zoom = z, near = finer and near or nil, mergeMax = state.mergeMax,
        otherMergeMax = state.otherMergeMax }
    -- Mote line indexes point into the old list: a mote keeps going where
    -- its line is the same in the new one (most of them, when the live map
    -- adds points at the end), and is spawned again elsewhere.
    for _, m in ipairs(motes) do
        local was, now = m.line and old[m.line], m.line and drawn[m.line]
        if not (was and now and was[1] == now[1] and was[2] == now[2] and was[3] == now[3] and was[4] == now[4]) then
            m.line = nil
        end
    end
    state.perf.place = debugprofilestop() - placeStarted
    state.perf.build = debugprofilestop() - started
end

local function NeedsPathBuild()
    local built = state.built
    if not built or not ViewInside(built) then return true end
    -- The replay gone back before a line left out is covered: it is drawn
    -- again (checked each frame too, as scrubbing moves no view; OnUpdate).
    if built.mergeMax and math.floor(state.cur) < built.mergeMax then return true end
    if state.clock then
        for track, latest in pairs(built.otherMergeMax or {}) do
            if (track.cur or 0) < latest then return true end
        end
    end
    local left = built.near and not ViewInside(built.near)
    -- Dragged out of the near part, the detail catches up once the mouse
    -- has held still for DRAG_PAUSE seconds: waiting for the release showed
    -- the margin's coarser lines for the whole drag, and a build every 0.2
    -- seconds while moving made the drag lag and jump, as one took 60 to
    -- 100 ms in game (Jordan's /rts perflog, 2026-11-15).
    if drag then return left and GetTime() - drag.movedAt >= DETAIL.DRAG_PAUSE end
    -- Mid-animation, only rebuild when lines would be missing.
    if state.zoom ~= state.targetZoom then return false end
    return math.abs(math.log(state.zoom / built.zoom)) > REBUILD_ZOOM or left
end

local function ReleaseTile(index)
    for _, tex in ipairs(activeTiles[index]) do
        tex:Hide()
        freeTiles[#freeTiles + 1] = tex
    end
    activeTiles[index] = nil
end

-- Draws a tile as its pieces (one, unless it is at the edge of the terrain).
local function ShowTile(index)
    local tile = state.tiles[index]
    local x1, y1 = tile[2], tile[3]
    local w, h = tile[4] - x1, tile[5] - y1
    local textures = {}
    for i, piece in ipairs(tile.pieces) do
        local tex = table.remove(freeTiles) or terrainLayer:CreateTexture(nil, "BACKGROUND")
        if tex.fileID ~= tile[1] then
            tex:SetTexture(tile[1])
            tex.fileID = tile[1]
        end
        tex:SetTexCoord(piece[1], piece[2], piece[3], piece[4])
        ns.SetAlphaGradient(tex, piece[5], piece[6], piece[7], tile.skipped and SKIPPED_TINT)
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", terrainLayer, "TOPLEFT", x1 + piece[1] * w, -(y1 + piece[3] * h))
        tex:SetPoint("BOTTOMRIGHT", terrainLayer, "TOPLEFT", x1 + piece[2] * w, -(y1 + piece[4] * h))
        tex:Show()
        textures[i] = tex
    end
    activeTiles[index] = textures
end

-- Draws up to TILES_PER_FRAME of the tiles UpdateTerrain queued, nearest
-- the view's centre first. Called again each frame until the queue is empty.
local function ShowQueuedTiles()
    local queue = state.tileQueue
    for _ = 1, TILES_PER_FRAME do
        local index = table.remove(queue)
        if not index then break end
        if not activeTiles[index] then
            ShowTile(index)
        end
    end
    if #queue == 0 then
        state.tileQueue = nil
    end
end

-- Loads terrain tiles around the view and lets go of ones out of range.
-- Zooming in far enough for terrain can bring a thousand tiles into range
-- at once, so they are queued and drawn over a few frames.
local function UpdateTerrain()
    -- (Outland's terrain comes in at its own zoom: Cosmic.lua)
    local want = ns.db.terrain and ns.Cosmic:ZoomAt(state.zoom, ViewArea(0)) >= TERRAIN_FADE[1]
    local built = state.terrainBuilt
    if want and built and ViewInside(built)
        and not (state.terrainCapped and state.zoom > built.zoom) then
        return
    end
    if not want and not built then return end

    local started = debugprofilestop()
    local wanted, count = {}, 0
    local x1, y1, x2, y2 = ViewArea(TERRAIN_MARGIN)
    if want then
        local showSkipped = ns.dev and ns.db.showSkipped
        for index, tile in ipairs(state.tiles) do
            if (showSkipped or not tile.skipped)
                and tile[4] >= x1 and tile[2] <= x2 and tile[5] >= y1 and tile[3] <= y2 then
                wanted[index] = true
                count = count + 1
            end
        end
        if count > MAX_TERRAIN_TILES then
            wanted = {}
        end
    end
    state.terrainCapped = count > MAX_TERRAIN_TILES
    hintText:SetText(state.terrainCapped and "Zoom in further to see terrain" or "")

    for index in pairs(activeTiles) do
        if not wanted[index] then
            ReleaseTile(index)
        end
    end
    local queue, cx, cy = {}, (x1 + x2) / 2, (y1 + y2) / 2
    for index in pairs(wanted) do
        if not activeTiles[index] then
            queue[#queue + 1] = index
        end
    end
    -- Farthest first, as the queue is taken from its end.
    local tiles = state.tiles
    local function Distance(index)
        local tile = tiles[index]
        local dx, dy = (tile[2] + tile[4]) / 2 - cx, (tile[3] + tile[5]) / 2 - cy
        return dx * dx + dy * dy
    end
    table.sort(queue, function(a, b) return Distance(a) > Distance(b) end)
    state.tileQueue = queue[1] and queue or nil
    if state.tileQueue then
        ShowQueuedTiles()
    end
    state.terrainBuilt = want and { x1, y1, x2, y2, zoom = state.zoom } or nil
    state.perf.terrain = debugprofilestop() - started
end

-- Canvas pixel position of content coordinate x, y.
local function ToCanvas(x, y)
    return (x - state.ox) * state.zoom, -(y - state.oy) * state.zoom
end

-- Rotation for the arrow to face the way the player was moving at point seq,
-- looking back a few points in case the last ones are in the same place.
local function HeadRotation(seq)
    local px, py = state.px, state.py
    for back = seq - 1, math.max(1, seq - 10), -1 do
        local dx, dy = px[seq] - px[back], py[seq] - py[back]
        if dx ~= 0 or dy ~= 0 then
            -- The texture points north; content y runs down the screen.
            return math.atan2(-dy, dx) - math.pi / 2
        end
    end
    return 0
end

-- Puts the arrow at the replay position, kept in state.headX, headY. Between
-- the two points of a jump it travels along the jump's curve as drawn (a sea
-- course or lane, else the arc), facing along it; through portals it dives
-- into the first, a comet flies the arc, and it comes out of the second.
local function PlaceHead()
    local seq = math.floor(state.cur)
    local lead = state.leadLine
    if not lead then
        lead = pathLayer:CreateLine(nil, "ARTWORK")
        state.leadLine = lead
    end
    if seq < 1 or seq > state.n then
        ns.Portals:Cross()
        head:Hide()
        lead:Hide()
        return
    end
    local px, py = state.px, state.py
    local x, y, rotation = px[seq], py[seq], HeadRotation(seq)
    -- Between two points of the path the arrow glides rather than hopping
    -- from point to point, facing along the path half a point behind and
    -- ahead, so it turns through bends instead of snapping at each point
    -- (Jordan, 2026-10-25: jagged at the slower 1x).
    local gliding = seq < state.n and not state.brk[seq + 1] and state.cur > seq
    if gliding then
        local function At(c)
            local s = math.max(1, math.min(state.n, math.floor(c)))
            local g = math.max(0, math.min(1, c - s))
            if s >= state.n or state.brk[s + 1] then return px[s], py[s] end
            return px[s] + (px[s + 1] - px[s]) * g, py[s] + (py[s + 1] - py[s]) * g
        end
        x, y = At(state.cur)
        local ax, ay = At(math.max(seq, state.cur - 0.5))
        local bx, by = At(math.min(seq + 1, state.cur + 0.5))
        if ax ~= bx or ay ~= by then
            rotation = math.atan2(-(by - ay), bx - ax) - math.pi / 2
        end
    end
    local size = 1
    local i = seq + 1
    local style = Style.Jump(state.pj[i])
    local portal = false
    -- A segment break without moving (a reload in place) has no curve, and
    -- the arrow skips instant jumps, long teleports and boat trips among them.
    if i <= state.n and state.brk[i] and (px[i] ~= px[seq] or py[i] ~= py[seq])
        and not Style.Instant(style, px[seq], py[seq], px[i], py[i]) then
        local trip = state.seaTrips[i]
        local curve = trip and (trip.curve or JumpCurve(trip[1], trip[2], trip[3], trip[4]))
            or JumpCurve(px[seq], py[seq], px[i], py[i], style.bend)
        -- A boat route can be drawn the other way round from how it was sailed.
        local f = state.cur - seq
        if trip and trip.flip then
            f = 1 - f
        end
        local total = curve[#curve][3]
        -- Its length and time at normal speed, for the replay's pace (OnUpdate).
        if not state.headJump or state.headJump.i ~= i then
            local seconds = style.replay or 1
            if style.style == "portal" then
                seconds = ns.Portals:Seconds(total, style.pace)
            elseif style.pace then
                seconds = math.max(seconds, total / style.pace)
            end
            state.headJump = { i = i, total = total, seconds = seconds }
        end
        if style.style == "portal" then
            portal = true
            local seconds = state.headJump.seconds
            local phase, spin
            phase, size, spin, x, y = ns.Portals:Cross(i, style, f * seconds, seconds, curve)
            -- Into the portal facing the way the player walked, out of it
            -- facing the way they walked on.
            rotation = (phase == "emerge" and HeadRotation(math.min(i + 1, state.n)) or rotation) - spin
        else
            local d, step = f * total, total * 0.01
            x, y = PointAlong(curve, d)
            local ax, ay = PointAlong(curve, math.max(0, d - step))
            local bx, by = PointAlong(curve, math.min(total, d + step))
            rotation = math.atan2(-(by - ay), bx - ax) - math.pi / 2 + (trip and trip.flip and math.pi or 0)
        end
    end
    if not portal then
        ns.Portals:Cross()
    end
    -- The trail is drawn a whole line at a time; a short line in the path's
    -- own colour joins its end to the gliding arrow. Live (LiveMap.lua, #136),
    -- the arrow is where the player is now, the line from the last point
    -- stored in the mode and band they are in now.
    local spec = gliding and state.shown > 0 and state.drawn[state.shown] or nil
    local mode, band = state.pm[seq], state.pb[seq]
    local lx, ly, lrot, lmode, lband = ns.LiveMap:Head(state)
    if lx and not portal then
        x, y, rotation, mode, band = lx, ly, lrot or rotation, lmode, lband
        spec = { nil, nil, px[seq], py[seq] }
    end
    if spec and spec[5] ~= "j" and not spec.hidden and (mode ~= "t" or ns.FilterShown("flights")) then
        lead:SetStartPoint("TOPLEFT", pathLayer, spec[3], -spec[4])
        lead:SetEndPoint("TOPLEFT", pathLayer, x, -y)
        lead:SetColorTexture(Style.LineColor(mode, band))
        lead:SetThickness(LINE_WIDTH / state.zoom)
        lead:Show()
    else
        lead:Hide()
    end
    state.headX, state.headY = x, y
    head:ClearAllPoints()
    head:SetPoint("CENTER", overlay, "TOPLEFT", ToCanvas(x, y))
    head:SetRotation(rotation)
    head:SetSize(HEAD.SIZE * size, HEAD.SIZE * size)
    head:SetShown(size > 0.05)
end

-- Shows markers the replay has reached and the zoom allows, placed on the
-- view; ones that would cover each other pile up or move apart (MarkerPiles.lua).
local function UpdateMarkers()
    local now, z = state.markerNow, state.zoom
    local shown = state.markersShown or {}
    state.markersShown = wipe(shown)
    for i = 1, state.markerCount do
        local m = markers[i]
        -- A quest marker with a pop playing on it waits for the pop to end.
        if m.t <= now and ns.Range:Has(m.t) and z >= m.minZoom and ns.FilterShown(m.category) and not m.popping then
            m.cx, m.cy = ToCanvas(m.x, m.y)
            shown[#shown + 1] = m
        else
            m:Hide()
        end
    end
    ns.MarkerPiles:Place(shown, overlay, state.W, state.H)
end

-- Other characters ---------------------------------------------------------------

local function GetCharMarker(i)
    local m = charMarkers[i]
    if m then return m end
    m = CreateFrame("Frame", nil, overlay)
    m:SetSize(20, 20)
    m:EnableMouse(true)
    m.icon = m:CreateTexture(nil, "OVERLAY")
    m.icon:SetAllPoints()
    m.label = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m.label:SetPoint("TOP", m, "BOTTOM", 0, -1)
    m.label:SetShadowOffset(1, -1)
    m:SetScript("OnEnter", function(self)
        local e = self.entry
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(e.name, ns.ClassColor(e.class))
        GameTooltip:AddLine(("Level %d %s"):format(e.level or 0, ns.ClassName(e.class)), 1, 1, 1)
        if e.zone then
            GameTooltip:AddLine(ZoneName(e.zone), 1, 1, 1)
        end
        GameTooltip:AddLine("Last seen " .. ns.FormatAgo(e.seen), 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    m:SetScript("OnLeave", GameTooltip_Hide)
    charMarkers[i] = m
    return m
end

-- Markers for the other characters at their last outdoor position.
local function BuildCharacters()
    local count = 0
    local shown = ns.Roster:ViewEntry()
    for _, e in ipairs(ns.Roster:Entries()) do
        -- This character, when another's journey is shown, is where it is now.
        local c, x, y = e.c, e.x, e.y
        if ns.Roster:IsMe(e) then
            c, x, y = ns.Recorder:Position()
        end
        local toContent = c and state.toContent[c]
        if toContent and e ~= shown then
            count = count + 1
            local m = GetCharMarker(count)
            m.entry = e
            m.x, m.y = toContent(x, y)
            ns.SetClassIcon(m.icon, e.class)
            m.label:SetText(e.name)
            m.label:SetTextColor(ns.ClassColor(e.class))
            m:Show()
        end
    end
    for i = count + 1, #charMarkers do
        charMarkers[i]:Hide()
    end
    state.charCount = count
end

local function PlaceCharacters()
    for i = 1, state.charCount do
        local m = charMarkers[i]
        m:ClearAllPoints()
        m:SetPoint("CENTER", overlay, "TOPLEFT", ToCanvas(m.x, m.y))
    end
end

-- The same for other characters' lines.
local function SetOtherThickness()
    state.otherZoom, state.fitMin = state.zoom, math.min(state.fitMin, state.zoom)
end

-- Finds the built lines inside the view (and a margin, state.fit), for
-- motes and hovering, through their boxes, and sizes for the zoom those in
-- it that are shown and sized for another (PathLines.lua): lines move into
-- view as it pans, and a zoom step only resizes what is in view. Jumps are
-- sized whole, by their curve's box. The margin is the widest a line still
-- sized for fitMin could reach past its ends; jump pieces reach further.
-- Jumps are found by their curve's box, then sized by the chunks of their
-- pieces in view (AddPart).
local function UpdateVisible()
    local started = debugprofilestop()
    local PathLines, z = ns.PathLines, state.zoom
    local x1, y1 = state.ox, state.oy
    local x2, y2 = x1 + state.W / z, y1 + state.H / z
    local pad, fit = LINE_WIDTH / state.fitMin, state.fit
    fit[1], fit[2], fit[3], fit[4] = x1 - pad, y1 - pad, x2 + pad, y2 + pad
    local n, m
    state.visible, n = PathLines.InView(state.drawn, state.boxes, fit[1], fit[2], fit[3], fit[4], state.visible)
    state.otherVisible, m = PathLines.InView(state.otherDrawn, state.otherBoxes,
        fit[1], fit[2], fit[3], fit[4], state.otherVisible)
    -- /rts perf all resizes every line and jump as before, for comparing.
    local all = ns.dev and ns.db.perfAll
    local sized = PathLines.Fit(lines, not all and state.visible or nil, all and state.lineCount or n,
        state.lineZoom, LINE_WIDTH)
    sized = sized + PathLines.Fit(otherLines, not all and state.otherVisible or nil,
        all and state.otherLineCount or m, state.otherZoom, OTHER.LINE_WIDTH)
    pad = PathLines.JUMP_PAD / state.fitMin
    local lz = state.lineZoom
    for _, jump in ipairs(state.jumps) do
        local b = jump.box
        local inView = all or b[3] >= x1 - pad and b[1] <= x2 + pad and b[4] >= y1 - pad and b[2] <= y2 + pad
        if inView or jump.inView then
            for _, c in ipairs(jump.chunks) do
                local cIn = all or inView and c[3] >= x1 - pad and c[1] <= x2 + pad and c[4] >= y1 - pad and c[2] <= y2 + pad
                if cIn and (jump.visible or all) and c.tz ~= lz then
                    local count, fading = PathLines.FitJump(jump, lz, not c.inView, c[5], c[6])
                    c.tz = lz
                    sized = sized + count
                    state.dotsFading = state.dotsFading or fading
                end
                c.inView = cIn
            end
        end
        jump.inView = inView
    end
    local p = state.perf
    p.fit, p.sized = debugprofilestop() - started, sized
    p.fitMost, p.sizedMost = math.max(p.fitMost, p.fit), math.max(p.sizedMost, sized)
end

-- Tints a mote to match the line it is on.
local function ColorMote(m)
    local spec = state.drawn[m.line]
    if spec[5] == "j" then
        local style = Style.Jump(state.pj[spec[6]])
        m.tex:SetVertexColor(style[2], style[3], style[4])
    else
        local r, g, b = Style.LineColor(spec[5], state.pb[spec[6]])
        m.tex:SetVertexColor(r, g, b)
    end
end

-- Puts a mote on a random visible line the replay has reached, or hides it.
local function SpawnMote(m)
    local visible = state.visible
    if #visible > 0 then
        for _ = 1, 4 do
            local i = visible[math.random(#visible)]
            -- Not on jumps: those are drawn as arcs, motes move in straight lines.
            if i <= state.shown and state.drawn[i][5] ~= "j" and not state.drawn[i].hidden then
                m.line, m.f, m.age, m.life = i, math.random(), 0, 2 + math.random() * 2
                ColorMote(m)
                return
            end
        end
    end
    m.line = nil
    m.tex:Hide()
end

-- Moves motes along the path in the direction of travel, carrying on to the
-- next line where the path joins up, and fading each in and out.
local function UpdateMotes(elapsed)
    local drawn, z = state.drawn, state.zoom
    for _, m in ipairs(motes) do
        if not m.line or m.age >= m.life then
            SpawnMote(m)
        end
        if m.line then
            m.age = m.age + elapsed
            local s = drawn[m.line]
            local length = math.sqrt((s[3] - s[1]) ^ 2 + (s[4] - s[2]) ^ 2) * z
            m.f = m.f + elapsed * MOTE_SPEED / math.max(length, 1)
            if m.f >= 1 then
                local nextLine = drawn[m.line + 1]
                if nextLine and m.line + 1 <= state.shown and nextLine[5] ~= "j" and not nextLine.hidden
                    and nextLine[1] == s[3] and nextLine[2] == s[4] then
                    m.line, m.f, s = m.line + 1, 0, nextLine
                    ColorMote(m)
                else
                    m.f, m.age = 1, m.life
                end
            end
            local fade = math.sin(math.pi * math.min(1, m.age / m.life))
            local size = 5 + 7 * fade
            m.tex:SetSize(size, size)
            m.tex:SetAlpha(fade)
            m.tex:SetPoint("CENTER", overlay, "TOPLEFT",
                ToCanvas(s[1] + (s[3] - s[1]) * m.f, s[2] + (s[4] - s[2]) * m.f))
            m.tex:Show()
        end
    end
end

local function HideMotes()
    for _, m in ipairs(motes) do
        m.line = nil
        m.tex:Hide()
    end
end

local function TerrainCount()
    local count = 0
    for _ in pairs(activeTiles) do
        count = count + 1
    end
    return count
end

local function UpdatePerf()
    if not (ns.dev and ns.db.perf) then
        perfText:SetText("")
        return
    end
    local p = state.perf
    -- Second row: the last view change's sizing pass (UpdateVisible) and
    -- the most of it in a frame since the zoom started moving, lines in
    -- view of all built, and the last build's lines placed and kept.
    perfText:SetText(("World %.0f ms, decode %.0f ms, setup %.0f ms, build %.1f ms (lod %.1f, place %.1f), terrain %.1f ms, view %.1f ms - %d points, %d lines at detail %d, %d terrain tiles (%d outside zones skipped), zoom %.1f"
        .. "\nSizing %.2f ms (most %.2f), %d resized (most %d)%s - in view %d of %d lines, %d of %d others, %d jumps - build placed %d, kept %d"):format(
        p.world, p.decode, p.setup, p.build, p.lod, p.place, p.terrain, p.view, state.n, state.lineCount,
        state.lodLevel, TerrainCount(), state.tilesSkipped, state.zoom,
        p.fit, p.fitMost, p.sized, p.sizedMost,
        (ns.db.perfAll and " [all, as before]" or "") .. (ns.db.perfDrift and (" [drift %s]"):format(ns.db.perfDrift) or ""),
        #state.visible, state.lineCount, #state.otherVisible, state.otherLineCount, #state.jumps, p.placed, p.kept))
end

-- Moves the content to match the view, and rebuilds what has fallen out of date.
local function ApplyView()
    local started = debugprofilestop()
    local z = state.zoom
    content:SetScale(z)
    content:SetPoint("TOPLEFT", canvas, "TOPLEFT", -state.ox, state.oy)
    continentLayer:SetAlpha(Fade(z, CONTINENT_FADE))
    zoneView.layer:SetAlpha(not ns.db.terrain and Fade(z, zoneView.FADE) or 0)
    zoneView.gaps:SetAlpha(zoneView.layer:GetAlpha())
    local tz = ns.Cosmic:ZoomAt(z, ViewArea(0))
    terrainLayer:SetAlpha(ns.db.terrain and Fade(tz, TERRAIN_FADE) or 0)
    ns.KillMarks:SetZoom(z)
    ns.Islands:SetZoom(z, ns.db.terrain and Fade(tz, TERRAIN_FADE) or 0)
    ns.Cosmic:SetZoom(z, ViewArea(0))
    if not ns.db.terrain and z >= zoneView.FADE[1] then
        zoneView:SetZoom(z)
        zoneView:Update(ViewArea(0))
    end

    -- Resizing lines is most of the cost of zooming, so while the zoom
    -- animates, the zoom lines are sized for only follows it after a tenth
    -- of drift, and once more when the animation settles; UpdateVisible
    -- then resizes only the lines in view.
    local settled = z == state.targetZoom
    if not settled and not state.zooming then
        -- A zoom starts: /rts perf's most per frame start over.
        state.perf.fitMost, state.perf.sizedMost = 0, 0
    end
    state.zooming = not settled
    -- /rts perf drift tries other amounts in a developer build.
    local drift = ns.dev and ns.db.perfDrift or 0.1
    if NeedsPathBuild() then
        BuildPath()
    elseif z ~= state.lineZoom and (settled or math.abs(z / state.lineZoom - 1) > drift) then
        SetLineThickness()
    end
    if z ~= state.otherZoom and (settled or math.abs(z / state.otherZoom - 1) > drift) then
        SetOtherThickness()
    end
    UpdateVisible()
    UpdateTerrain()

    UpdateMarkers()
    PlaceCharacters()
    PlaceHead()
    for _, jump in ipairs(state.jumps) do
        if jump.icon then
            jump.icon:SetPoint("CENTER", overlay, "TOPLEFT", ToCanvas(jump.x, jump.y))
        end
    end
    ShowJumpIcons()

    state.perf.view = debugprofilestop() - started
    UpdatePerf()
end

-- Timeline -------------------------------------------------------------------------
-- The replay bar under the map: the journey's level bands in their path
-- colours, dim ahead of the replay position and bright behind it, with a
-- tick per level up and a label every 10 levels, then past the level cap a
-- tick per week since it. scrub is the bar's frame; scrub.track is the
-- coloured strip.

local SCRUB = {
    TRACK = 10,                 -- strip height
    FILL = "Interface\\TargetingFrame\\UI-StatusBar",
    EDGE = "Interface\\Tooltips\\UI-Tooltip-Border",
    BACKGROUND = "Interface\\Tooltips\\UI-Tooltip-Background",
    KNOB = 16,
    ROW = 30,                   -- bar height, with the level labels under it
    OUTSET = 4,                 -- its frame reaches this far outside the strip
    BELOW = 6,                  -- space under the labels, which have some of their own
    LABEL_EVERY = 10,           -- levels
    WEEK = 7 * 86400,           -- past the level cap, a tick per week since it (as the Stats screen counts them)
    WEEK_LABEL_EVERY = 5,       -- weeks, once there are that many
}
-- From the map's bottom to the bar's top: the bar's frame sits PAD under the
-- map's frame, and the knob pokes out above the strip.
SCRUB.TOP = MAP_BORDER + FRAME.PAD + SCRUB.OUTSET - (SCRUB.KNOB - SCRUB.TRACK) / 2
local BUTTON_HEIGHT = 22

-- Last point at or before time t, 0 if none.
local function SeqAt(t)
    return ns.LastIndex(state.pt, t)
end

local function ScrubX(seq)
    return scrub.track:GetWidth() * seq / math.max(1, state.n)
end

-- Places the band pieces and ticks; needed after a rebuild or a resize.
local function LayoutScrub()
    local runs, ticks = scrub.runs, scrub.ticks
    for k, run in ipairs(runs) do
        local piece = scrub.pieces[k]
        local x1, x2 = ScrubX(run.first), ScrubX(run.last)
        piece.dim:SetPoint("LEFT", scrub.track, "LEFT", x1, 0)
        piece.dim:SetWidth(math.max(1, x2 - x1))
        piece.bright:SetPoint("LEFT", scrub.track, "LEFT", x1, 0)
        run.x1, run.x2 = x1, x2
    end
    -- A label that would overlap the one before it is left out, the earlier
    -- kept: weeks away from the game land on one point of the bar.
    local right = -math.huge
    for k = 1, scrub.tickCount do
        local tick = ticks[k]
        local x = math.floor(ScrubX(tick.seq)) + 0.5
        tick.tex:SetPoint("CENTER", scrub.track, "LEFT", x, 0)
        tick.label:SetPoint("TOP", tick.tex, "BOTTOM", 0, -1)
        local shown = tick.major
        if shown then
            local half = tick.label:GetStringWidth() / 2
            shown = x - half >= right + 4
            if shown then right = x + half end
        end
        tick.label:SetShown(shown and true or false)
    end
end

-- Moves the knob and the bright part to point index seq.
local function UpdateScrub(seq)
    local n = state.n
    scrub.knob:SetShown(n > 0)
    if n == 0 then return end
    local x = ScrubX(seq)
    for k, run in ipairs(scrub.runs) do
        local bright = scrub.pieces[k].bright
        local w = math.min(x, run.x2) - run.x1
        bright:SetShown(w >= 0.5)
        bright:SetWidth(math.max(0.5, w))
    end
    -- Kept within the bar's frame at the ends, in line with the map's edge.
    local reach = SCRUB.KNOB / 2 - SCRUB.OUTSET
    x = math.max(reach, math.min(scrub.track:GetWidth() - reach, x))
    scrub.knob:SetPoint("CENTER", scrub.track, "LEFT", x, 0)
end

-- A level tick: { tex, label, seq = point index }.
local function NewScrubTick()
    local tick = {
        tex = scrub.track:CreateTexture(nil, "OVERLAY"),
        label = scrub:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"),
        seq = 0,
    }
    tick.tex:SetWidth(1)
    return tick
end

-- Rebuilds the bands and level ticks for the current path.
local function BuildScrub()
    local runs, pb = {}, state.pb
    for i = 1, state.n do
        local run = runs[#runs]
        if run and run.band == pb[i] then
            run.last = i
        else
            runs[#runs + 1] = { band = pb[i], first = i - 1, last = i }
        end
    end
    for k, run in ipairs(runs) do
        local piece = scrub.pieces[k]
        if not piece then
            piece = {
                dim = scrub.track:CreateTexture(nil, "BORDER"),
                bright = scrub.track:CreateTexture(nil, "ARTWORK"),
            }
            piece.dim:SetHeight(SCRUB.TRACK)
            piece.bright:SetHeight(SCRUB.TRACK)
            scrub.pieces[k] = piece
        end
        local _, r, g, b = unpack(Style.LEVEL_COLORS[run.band])
        piece.dim:SetTexture(SCRUB.FILL)
        piece.dim:SetVertexColor(r * 0.35, g * 0.35, b * 0.35)
        piece.bright:SetTexture(SCRUB.FILL)
        piece.bright:SetVertexColor(r, g, b)
        piece.dim:Show()
    end
    for k = #runs + 1, #scrub.pieces do
        scrub.pieces[k].dim:Hide()
        scrub.pieces[k].bright:Hide()
    end
    scrub.runs = runs

    local count = 0
    local function AddTick(t, label, major)
        count = count + 1
        local tick = scrub.ticks[count] or NewScrubTick()
        scrub.ticks[count] = tick
        tick.seq = SeqAt(t)
        tick.tex:SetHeight(major and SCRUB.TRACK + 6 or SCRUB.TRACK)
        tick.tex:SetColorTexture(0, 0, 0, major and 0.9 or 0.45)
        tick.tex:Show()
        tick.label:SetText(label)
        tick.major = major
    end
    if state.n > 0 then
        for _, e in ipairs(ns.view.events) do
            if e[2] == "lvl" and ns.Range:Has(e[1]) then
                AddTick(e[1], e[6], e[6] % SCRUB.LABEL_EVERY == 0)
            end
        end
        -- Past the cap, where no more level ups come: the start of each week
        -- since it, the weeks starting the second after it as on the Stats
        -- screen. Each is labelled while the range holds few, then every
        -- fifth; LayoutScrub drops labels that would overlap.
        local capAt, last = ns.Range.capAt, state.pt[state.n]
        if capAt and last then
            local starts = {}
            for week = 2, math.floor((last - capAt - 1) / SCRUB.WEEK) + 1 do
                local t = capAt + 1 + (week - 1) * SCRUB.WEEK
                if ns.Range:Has(t) then starts[#starts + 1] = { week, t } end
            end
            for _, start in ipairs(starts) do
                local week = start[1]
                AddTick(start[2], "Week " .. week, #starts < SCRUB.WEEK_LABEL_EVERY or week % SCRUB.WEEK_LABEL_EVERY == 0)
            end
        end
    end
    for k = count + 1, #scrub.ticks do
        scrub.ticks[k].tex:Hide()
        scrub.ticks[k].label:Hide()
    end
    scrub.tickCount = count
    LayoutScrub()
end

-- Point index under the mouse.
local function ScrubSeqAtCursor()
    local x = GetCursorPosition() / scrub.track:GetEffectiveScale() - scrub.track:GetLeft()
    local f = math.max(0, math.min(1, x / math.max(1, scrub.track:GetWidth())))
    return math.floor(f * state.n + 0.5)
end

-- Tooltip above the bar for the hovered point.
local function ShowScrubTooltip(seq)
    scrub.hoverMark:SetPoint("CENTER", scrub.track, "LEFT", ScrubX(seq), 0)
    scrub.hoverMark:Show()
    GameTooltip:SetOwner(scrub, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("BOTTOM", scrub.track, "LEFT", ScrubX(seq), SCRUB.KNOB)
    if seq < 1 then
        GameTooltip:AddLine("Start of journey")
    else
        local t = state.pt[seq]
        local capAt = ns.Range.capAt
        if capAt and t > capAt then
            GameTooltip:AddLine(("Level %d, week %d at the cap"):format(LevelAt(t), math.floor((t - capAt - 1) / SCRUB.WEEK) + 1),
                ns.LevelColor(LevelAt(t)))
        else
            GameTooltip:AddLine(("Level %d"):format(LevelAt(t)), ns.LevelColor(LevelAt(t)))
        end
        GameTooltip:AddLine(ZoneAt(t), 1, 1, 1)
        GameTooltip:AddLine(FormatTime(t), 0.7, 0.7, 0.7)
        local total, level = ns.Journal:PlayedAt(t)
        if total then
            local played = "Played " .. ns.FormatDuration(total)
            if level then played = played .. ", this level " .. ns.FormatDuration(level) end
            GameTooltip:AddLine(played, 0.7, 0.7, 0.7)
        end
    end
    GameTooltip:Show()
end

-- Shows the path, markers and star up to the replay position.
local function ApplyCursor()
    local seq = math.floor(state.cur)
    -- On its way along a jump, the jump shows, so the arrow follows its line.
    local count = CountUpTo(seq >= 1 and state.brk[seq + 1] and seq + 1 or seq)
    -- Lines coming into sight in view are sized for the zoom (PathLines.Reveal).
    local drawn, Reveal = state.drawn, ns.PathLines.Reveal
    for i = state.shown + 1, count do
        Reveal(lines[i], drawn[i], not lines[i].void, state.lineZoom, LINE_WIDTH, state.fit)
    end
    for i = count + 1, state.shown do
        Reveal(lines[i], drawn[i], false)
    end
    if count ~= state.shown then
        ShowJumps(count)
    end
    state.shown = count

    -- At the end, show every marker, even ones after the last movement.
    state.markerNow = (seq >= state.n) and math.huge or (state.pt[seq] or 0)
    UpdateMarkers()
    ns.KillMarks:SetTime(state.markerNow)
    ns.Panel:SetTime(state.markerNow)
    if ns.db.showGear then
        ns.GearCard:Follow(state.markerNow)
    end
    ns.Screens:Follow(state.markerNow)

    PlaceHead()
    if seq >= 1 and seq <= state.n then
        local t = state.pt[seq]
        infoText:SetText(("Level %d - %s - %s"):format(LevelAt(t), ZoneAt(t), FormatTime(t)))
    else
        infoText:SetText(state.n == 0 and (ns.Range:IsAll() and "No path recorded yet." or "Nothing recorded in this range.")
            or "Start of journey")
    end

    UpdateScrub(seq)
end

local function SetZoomNow(z)
    state.zoom, state.targetZoom = z, z
end

-- Zooms to fit the whole path.
local function FitPath()
    if state.n == 0 then
        SetZoomNow(1)
        ClampView()
        ApplyView()
        return
    end
    local x1, y1, x2, y2 = unpack(state.bounds)
    local zx = state.W / math.max((x2 - x1) * 1.25, 1e-6)
    local zy = state.H / math.max((y2 - y1) * 1.25, 1e-6)
    SetZoomNow(math.max(state.minZoom, math.min(MAX_ZOOM, zx, zy)))
    CenterOn((x1 + x2) / 2, (y1 + y2) / 2)
    ApplyView()
end

-- Animated zoom back out to the whole world (the Cosmic map, if there is one).
local function ZoomOut()
    local w, h = canvas:GetSize()
    state.targetZoom = state.minZoom
    state.anchorX, state.anchorY = w / 2, h / 2
end

local function CursorOnCanvas()
    local x, y = GetCursorPosition()
    local scale = canvas:GetEffectiveScale()
    return x / scale - canvas:GetLeft(), canvas:GetTop() - y / scale
end

-- Hovering lines -------------------------------------------------------------------

local MODE_NAMES = { w = "On foot", t = "Flight path", g = "Ghost" }

local function DistSqToSegment(x, y, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local length = dx * dx + dy * dy
    local f = length > 0 and math.max(0, math.min(1, ((x - ax) * dx + (y - ay) * dy) / length)) or 0
    local ex, ey = ax + f * dx - x, ay + f * dy - y
    return ex * ex + ey * ey
end

-- The frame under the mouse; newer clients can report several.
local function MouseFocus()
    if GetMouseFoci then
        return GetMouseFoci()[1]
    end
    return GetMouseFocus and GetMouseFocus()
end

-- The shown line nearest the canvas pixel cx, cy within HOVER_PIXELS: the
-- player's own lines (as far as the replay has reached) and other
-- characters' lines.
local function LineAt(cx, cy)
    local z = state.zoom
    local x, y = state.ox + cx / z, state.oy + cy / z
    local best, bestD = nil, (HOVER_PIXELS / z) ^ 2
    local drawn = state.drawn
    for _, i in ipairs(state.visible) do
        if i <= state.shown and not drawn[i].hidden then
            local s = drawn[i]
            local d
            if s.portal then
                -- Portals have no line: over either one counts as on it.
                local c = s.curve
                local x1, y1, x2, y2 = ns.Portals:Ends(s[6])
                if not x1 then
                    x1, y1, x2, y2 = c[1][1], c[1][2], c[#c][1], c[#c][2]
                end
                local near = math.min((x - x1) ^ 2 + (y - y1) ^ 2, (x - x2) ^ 2 + (y - y2) ^ 2)
                -- Zoomed out the portals are hidden, so not hovered either.
                d = z >= ns.Portals.ZOOM and near < (ns.Portals.RADIUS / z) ^ 2 and 0 or math.huge
            elseif s.curve then
                -- Jumps are drawn as arcs: measure to the arc, not the straight line.
                local c = s.curve
                d = math.huge
                for p = 2, #c do
                    d = math.min(d, DistSqToSegment(x, y, c[p - 1][1], c[p - 1][2], c[p][1], c[p][2]))
                end
            else
                d = DistSqToSegment(x, y, s[1], s[2], s[3], s[4])
            end
            if d < bestD then
                best, bestD = s, d
            end
        end
    end
    -- Theirs in view and shown (replaying together hides those ahead).
    for _, i in ipairs(state.otherVisible) do
        local s = state.otherDrawn[i]
        if otherLines[i].on then
            local d = DistSqToSegment(x, y, s[1], s[2], s[3], s[4])
            if d < bestD then
                best, bestD = s, d
            end
        end
    end
    return best
end

local function ShowLineTooltip(spec)
    GameTooltip:SetOwner(canvas, "ANCHOR_CURSOR")
    if spec.track then
        local e = spec.track.entry
        GameTooltip:AddLine(e.name .. "'s journey", ns.ClassColor(e.class))
        local reason = spec[5] == "j" and spec.track.pj[spec[6]]
        if reason then
            GameTooltip:AddLine(Style.Jump(reason)[1], 1, 1, 1)
        elseif spec[5] ~= "j" and spec[5] ~= "w" then
            GameTooltip:AddLine(MODE_NAMES[spec[5]], 1, 1, 1)
        end
        GameTooltip:AddLine(("Level %d %s"):format(e.level or 0, ns.ClassName(e.class)), 0.7, 0.7, 0.7)
    else
        local i, pt = spec[6], state.pt
        if spec[5] == "j" then
            -- Point i starts the segment after the jump; i - 1 ends the one before.
            local style = Style.Jump(state.pj[i])
            GameTooltip:AddLine(style[1], style[2], style[3], style[4])
            GameTooltip:AddLine(state.boats[i] or ("%s to %s"):format(ZoneAt(pt[i - 1]), ZoneAt(pt[i], true)), 1, 1, 1)
            -- A route taken more than once, as far as the replay has reached.
            local boat = state.seaTrips[i]
            local count, last = 0, i
            for _, n in ipairs(boat and boat.trips or {}) do
                if n <= state.cur then
                    count, last = count + 1, n
                end
            end
            if count > 1 then
                GameTooltip:AddLine(("%d trips"):format(count), 1, 1, 1)
                GameTooltip:AddLine(("First: level %d - %s"):format(LevelAt(pt[i]), FormatTime(pt[i])), 0.7, 0.7, 0.7)
                GameTooltip:AddLine(("Last: level %d - %s"):format(LevelAt(pt[last]), FormatTime(pt[last])), 0.7, 0.7, 0.7)
                GameTooltip:Show()
                return
            end
        else
            local r, g, b = Style.LineColor(spec[5], state.pb[i])
            GameTooltip:AddLine(MODE_NAMES[spec[5]] or "Path", r, g, b)
            GameTooltip:AddLine(ZoneAt(pt[i]), 1, 1, 1)
        end
        GameTooltip:AddLine(("Level %d - %s"):format(LevelAt(pt[i]), FormatTime(pt[i])), 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

-- Highlights the line under the mouse and shows what it is.
-- Nothing is looked for again while the mouse, the view, the replay and
-- the lines are as they were at the last look, as it walks every line in view.
local function UpdateHover()
    local spec
    if not drag and canvas:IsMouseOver() and MouseFocus() == canvas then
        local cx, cy = CursorOnCanvas()
        local at = state.hoverAt or {}
        if at[1] == cx and at[2] == cy and at[3] == state.ox and at[4] == state.oy and at[5] == state.zoom
            and at[6] == state.shown and at[7] == state.builds and at[8] == state.clock then
            return
        end
        at[1], at[2], at[3], at[4], at[5], at[6], at[7], at[8] =
            cx, cy, state.ox, state.oy, state.zoom, state.shown, state.builds, state.clock
        state.hoverAt = at
        spec = LineAt(cx, cy)
    else
        state.hoverAt = nil
    end
    if spec == state.hover then return end
    state.hover = spec
    ShowJumpIcons()
    if spec and spec.portal then
        ns.Portals:Hover(spec[6], spec.curve, Style.Jump(state.pj[spec[6]]))
    else
        ns.Portals:Hover()
    end
    if spec then
        -- The straight highlight would not follow a jump's arc, so jumps get none.
        if spec.curve then
            hoverLine:Hide()
        else
            local layer = spec.track and othersLayer or pathLayer
            hoverLine:SetParent(layer)
            hoverLine:SetStartPoint("TOPLEFT", layer, spec[1], -spec[2])
            hoverLine:SetEndPoint("TOPLEFT", layer, spec[3], -spec[4])
            hoverLine:SetThickness(HOVER_WIDTH / state.zoom)
            hoverLine:Show()
        end
        ShowLineTooltip(spec)
    else
        hoverLine:Hide()
        if GameTooltip:IsOwned(canvas) then
            GameTooltip:Hide()
        end
    end
end

-- Replay ---------------------------------------------------------------------------

local function SetPlaying(playing)
    state.playing = playing
    playButton:SetText(playing and "Pause" or "Play")
end

-- While zoomed in, the view pans with the arrow once something moved it
-- (state.following: the replay, the scrub bar, the player on the live map).
-- It stays still while the arrow is in the middle part of the view, then
-- glides after it, so a walk pans the map along steadily instead of
-- jumping a view at a time; the arrow is never left nearer an edge than
-- HEAD.EDGE, or past it, however fast the replay. One far off screen (a
-- teleport, the scrub bar dragged a long way) is centred at once. Called
-- from OnUpdate once the replay has moved the arrow, before the view is
-- applied; returns whether it moved the view.
local function FollowHead(elapsed)
    if drag or state.zoom <= state.minZoom or math.floor(state.cur) < 1 or not state.headX then
        state.following = nil
        return false
    end
    local vw, vh = state.W / state.zoom, state.H / state.zoom
    local fx, fy = (state.headX - state.ox) / vw, (state.headY - state.oy) / vh
    local far, zone, edge = HEAD.FAR, HEAD.ZONE, HEAD.EDGE
    if fx < -far or fx > 1 + far or fy < -far or fy > 1 + far then
        CenterOn(state.headX, state.headY)
        state.following = nil
        return true
    end
    -- The view's move, in parts of a view, that brings the arrow back to
    -- the middle part: a share of it each frame, then held to the edges.
    local dx = fx < zone and fx - zone or fx > 1 - zone and fx - (1 - zone) or 0
    local dy = fy < zone and fy - zone or fy > 1 - zone and fy - (1 - zone) or 0
    if dx == 0 and dy == 0 then
        state.following = nil
        return false
    end
    local t = 1 - math.exp(-HEAD.GLIDE * elapsed)
    if math.abs(dx) * state.W < 0.5 and math.abs(dy) * state.H < 0.5 then
        t = 1       -- under half a pixel left: the rest of the way
    end
    local mx = math.max(fx - (1 - edge), math.min(fx - edge, dx * t))
    local my = math.max(fy - (1 - edge), math.min(fy - edge, dy * t))
    local ox, oy = state.ox, state.oy
    state.ox, state.oy = ox + mx * vw, oy + my * vh
    ClampView()
    -- Held by the map's edge, or arrived: nothing more to do.
    if state.ox == ox and state.oy == oy then
        state.following = nil
        return false
    end
    if t == 1 then state.following = nil end
    return true
end

-- Replaying together: every path turned on plays at once on one clock. The
-- journey shown follows it through state.cur; the others show their lines up
-- to it, with their markers at where they were then. On the real clock each
-- point is at the time it was recorded, so a character that logged off waits
-- on the map until it logs in again. On the game clock each is at its time
-- played, so every journey starts together and plays without its time away.

-- Seconds played at each point of a track: time passes between points, but
-- not across a login. With its journey's events (track.events), a gap is
-- time away when a session started in it: a logout in a dungeon or on a
-- flight leaves no login tag on the path. Older saves without sessions go
-- by the tags and long breaks (a login a few yards on carries the path on,
-- Recorder:Continues, so its time away counts as played in those: saves
-- from before October 2026 only).
function Together.PlayedTimes(track)
    local logins = {}
    for _, e in ipairs(track.events or {}) do
        if e[2] == "on" then logins[#logins + 1] = e[1] end
    end
    table.sort(logins)
    local pg, played, k = {}, 0, 1
    local pt, pj, brk = track.pt, track.pj, track.brk
    for i = 1, track.n do
        if i > 1 then
            local gap, away = pt[i] - pt[i - 1], nil
            if #logins > 0 then
                while logins[k] and logins[k] <= pt[i - 1] do k = k + 1 end
                away = logins[k] and logins[k] <= pt[i]
            else
                away = pj[i] == "l" or (brk[i] and not pj[i] and gap > Together.OFFLINE_GAP)
            end
            if not away then played = played + gap end
        end
        pg[i] = played
    end
    return pg
end

-- A track's point times on the clock in use. The journey shown is state.
function Together.ClockTimes(track)
    if state.togetherMode == "real" then return track.pt end
    track.pg = track.pg or Together.PlayedTimes(track)
    return track.pg
end

-- The first and last time of the journey shown and every timed track, or nil.
function Together.Bounds()
    local from, to
    local function Include(track)
        if track.n > 0 and track.pt then
            local times = Together.ClockTimes(track)
            local first, last = times[1], times[track.n]
            from, to = math.min(from or first, first), math.max(to or last, last)
        end
    end
    Include(state)
    for _, track in ipairs(state.otherTracks) do
        Include(track)
    end
    return from, to
end

-- The next time after t that anyone moved, or nil.
function Together.NextMove(t)
    local times = Together.ClockTimes(state)
    local soonest = times[ns.LastIndex(times, t) + 1]
    for _, track in ipairs(state.otherTracks) do
        if track.pt then
            times = Together.ClockTimes(track)
            local moves = times[ns.LastIndex(times, t) + 1]
            if moves and (not soonest or moves < soonest) then
                soonest = moves
            end
        end
    end
    return soonest
end

-- Shows the other tracks up to the clock. Only tracks that moved are
-- touched, unless all is set because their lines were just rebuilt.
function Together.Apply(all)
    local t = state.clock
    for _, track in ipairs(state.otherTracks) do
        local cur = track.pt and ns.LastIndex(Together.ClockTimes(track), t) or track.n
        track.moved = all or cur ~= track.cur
        track.cur = cur
    end
    -- Only lines whose state changes are touched (PathLines.Reveal).
    for i = 1, state.otherLineCount do
        local spec = state.otherDrawn[i]
        if spec.track.moved then
            ns.PathLines.Reveal(otherLines[i], spec, spec[6] <= spec.track.cur,
                state.otherZoom, OTHER.LINE_WIDTH, state.fit)
        end
    end
    local placed = all
    for i = 1, state.charCount do
        local m = charMarkers[i]
        local track = state.trackOf[m.entry]
        if track and track.pt and track.moved then
            m:SetShown(track.cur >= 1)
            if track.cur >= 1 then
                m.x, m.y = track.px[track.cur], track.py[track.cur]
            end
            placed = true
        end
    end
    if placed then PlaceCharacters() end
    infoText:SetText(state.togetherMode == "real" and FormatTime(t) or ns.FormatDuration(t) .. " played")
end

function Together.SetSpeedText()
    speedButton:SetText(state.clock and Together.SPEEDS[state.togetherSpeed][2]
        or SPEEDS[state.speedIndex] .. "x")
end

-- Leaves replaying together. The caller redraws the characters.
function Together.End()
    state.togetherMode, state.clock, state.clockTo = nil, nil, nil
    Together.button:SetText("Solo")
    Together.SetSpeedText()
end

-- Fits the clock to the tracks again after they change, keeping it inside
-- them. With no times left in any, goes back to the solo replay at its end
-- and returns false; the caller redraws the characters.
function Together.Rebound()
    local from, to = Together.Bounds()
    if not from then
        Together.End()
        SetPlaying(false)
        state.cur = state.n
        ApplyCursor()
        return false
    end
    state.clock, state.clockTo = math.min(math.max(state.clock, from), to), to
    state.cur = ns.LastIndex(Together.ClockTimes(state), state.clock)
    ApplyCursor()
    return true
end

function Together.Step(elapsed)
    local clock = state.clock + elapsed * Together.SPEEDS[state.togetherSpeed][1]
    local nextMove = Together.NextMove(state.clock)
    if nextMove and nextMove - state.clock > Together.GAP then
        clock = math.max(clock, nextMove)
    end
    if not nextMove or clock >= state.clockTo then
        clock = state.clockTo
        SetPlaying(false)
    end
    state.clock = clock
    state.cur = ns.LastIndex(Together.ClockTimes(state), clock)
    ApplyCursor()
    Together.Apply()
    state.following = true
end

local function OnUpdate(_, elapsed)
    --@debug@
    local logStarted = ns.PerfLog and ns.PerfLog.on and debugprofilestop()
    --@end-debug@
    local moved = false
    -- Jump dots the zoom has shown or hidden fade over a quarter second.
    if state.dotsFading then
        local step, fading = elapsed * 4, false
        for _, jump in ipairs(state.jumps) do
            for _, dot in ipairs(jump.parts) do
                local alpha = dot.alpha
                if alpha and alpha ~= dot.target then
                    alpha = dot.target > alpha and math.min(dot.target, alpha + step) or math.max(dot.target, alpha - step)
                    dot.alpha, dot.alphaSet = alpha, alpha
                    dot:SetAlpha(alpha)
                    fading = fading or alpha ~= dot.target
                end
            end
        end
        state.dotsFading = fading
    end
    -- Ribbon effects flow along the jumps the replay has reached, each piece
    -- carrying on the texture where the one before it left off. A repeat is
    -- rb.px screen pixels at the zoom now, so the texture keeps its shape as
    -- the zoom changes and a ribbon kept across zoom steps (BuildJumps) too.
    if state.ribbons[1] then
        state.ribbonClock = state.ribbonClock + elapsed
        local clock, z = state.ribbonClock, state.zoom
        for _, rb in ipairs(state.ribbons) do
            if rb.jump.visible then
                local span = rb.px / z
                local u = (rb.from / span - clock * rb.speed) % 1
                rb.line:SetTexCoord(u, u + (rb.to - rb.from) / span, 0, 1)
            end
        end
    end
    if state.zoom ~= state.targetZoom then
        local z = state.zoom * (state.targetZoom / state.zoom) ^ math.min(1, elapsed * ZOOM_SPEED)
        if math.abs(math.log(state.targetZoom / z)) < 0.01 then
            z = state.targetZoom
        end
        ZoomAround(z, state.anchorX, state.anchorY)
        moved = true
    end
    if drag then
        local cx, cy = CursorOnCanvas()
        if cx ~= drag.cx or cy ~= drag.cy then
            drag.cx, drag.cy, drag.movedAt = cx, cy, GetTime()
        end
        local ox, oy = drag.ox - (cx - drag.x) / state.zoom, drag.oy - (cy - drag.y) / state.zoom
        if ox ~= state.ox or oy ~= state.oy then
            state.ox, state.oy = ox, oy
            ClampView()
            moved = true
        end
        -- Held still mid-drag: the detail catches up (NeedsPathBuild).
        moved = moved or NeedsPathBuild()
    end
    if moved then
        ApplyView()
    end
    if ns.db.motes then
        UpdateMotes(elapsed)
    end
    ns.Portals:Update(elapsed)
    if zoneView.fading then
        zoneView:Step(elapsed)
    end
    if state.warm then
        StepWarmUp()
    elseif state.mergeWanted then
        state.mergeWanted = nil
        StartWarmUp()
    end
    -- With lines merged, the path is built again when a level finishes
    -- merging, or the replay goes back before a line left out is covered,
    -- neither of which moves the view (DETAIL.Merge, NeedsPathBuild).
    if DETAIL.MERGE and NeedsPathBuild() then
        ApplyView()
    end
    if state.tileQueue then
        ShowQueuedTiles()
    end
    hoverElapsed = hoverElapsed + elapsed
    if hoverElapsed >= HOVER_INTERVAL then
        hoverElapsed = 0
        UpdateHover()
    end

    if state.playing and state.clock then
        Together.Step(elapsed)
    elseif state.playing then
        local before = state.markerNow
        -- Along a jump, at its style's pace rather than a point at a time;
        -- a break without moving, or an instant jump, passes as any other point.
        local seq = math.floor(state.cur)
        local budget = elapsed * SPEEDS[state.speedIndex]     -- seconds of replay this frame
        local style = seq >= 1 and seq < state.n and state.brk[seq + 1]
            and Style.Jump(state.pj[seq + 1])
        local cur = state.cur
        if style and (state.px[seq + 1] ~= state.px[seq] or state.py[seq + 1] ~= state.py[seq])
            and not Style.Instant(style, state.px[seq], state.py[seq], state.px[seq + 1], state.py[seq + 1]) then
            -- Its time follows its length, known once the arrow is on the
            -- jump (PlaceHead).
            local jump = state.headJump
            local seconds = jump and jump.i == seq + 1 and jump.seconds or style.replay or 1
            cur = cur + budget * REPLAY_YARDS.jumps / seconds
        else
            -- Along the path by yards; a break passes as a point a yard on.
            -- Fast replays cover many points a frame: stop where the next
            -- jump starts, so none is skipped.
            while cur < state.n do
                local s = math.floor(cur)
                local k = s + 1
                if s > seq and state.brk[k]
                    and (state.px[k] ~= state.px[s] or state.py[k] ~= state.py[s]) then
                    cur = s
                    break
                end
                local cost = (k - cur) * math.max(state.pd[k], 1) / (REPLAY_YARDS[state.pm[k]] or REPLAY_YARDS.w)
                if budget < cost then
                    cur = cur + (k - cur) * budget / cost
                    break
                end
                budget, cur = budget - cost, k
            end
        end
        state.cur = cur
        if state.cur >= state.n then
            state.cur = state.n
            SetPlaying(false)
        end
        ApplyCursor()
        state.following = true
        -- At the end, markerNow is math.huge: everything up to now has passed.
        local now = state.markerNow == math.huge and ns.Now() or state.markerNow
        -- Only what is inside the date range pops up (Range.lua).
        if not ns.Range:IsAll() then
            before, now = math.max(before, ns.Range.from - 1), math.min(now, ns.Range.to)
        end
        ns.QuestPop:Passed(before, now)
        ns.GuildPop:Passed(before, now)
        ns.LevelPop:Passed(before, now)
        ns.KillPop:Passed(before, now)
    end
    -- The view pans after the arrow the replay just moved, in the same
    -- frame. Not while a zoom animates, which keeps the point under the
    -- cursor still (it picks up again once the zoom settles), nor while
    -- the map is hidden under the Gear or Stats screen. Zooming and
    -- dragging never pan with it, so the view is applied once a frame.
    if state.following and state.zoom == state.targetZoom and canvas:IsShown()
        and FollowHead(elapsed) then
        ApplyView()
    end
    ns.QuestPop:Update(elapsed)
    ns.GuildPop:Update(elapsed)
    ns.LevelPop:Update(elapsed)
    ns.KillPop:Update(elapsed)
    ns.LiveMap:Update(elapsed)
    --@debug@
    if logStarted then
        ns.PerfLog.Frame(elapsed, debugprofilestop() - logStarted, drag ~= nil, state)
    end
    --@end-debug@
end

-- Window ---------------------------------------------------------------------------

local function UpdateTerrainButton()
    terrainButton:SetText(ns.db.terrain and "Terrain: On" or "Terrain: Off")
end

local function UpdateGearButton()
    gearButton:SetText(ns.db.showGear and "Gear card: On" or "Gear card: Off")
    if not ns.db.showGear then
        ns.GearCard:Undock()
    elseif frame:IsShown() then
        ns.GearCard:Follow(state.markerNow)
    end
end

local function Layout()
    -- Across: map and panel. Down: title bar, map, timeline, buttons.
    local fw = FRAME.LEFT + FRAME.PAD + MAP_BORDER + state.W + PANEL_GAP + ns.Panel.WIDTH
        + MAP_BORDER + FRAME.PAD + FRAME.RIGHT
    local fh = FRAME.TOP + FRAME.PAD + MAP_BORDER + state.H + SCRUB.TOP + SCRUB.ROW + SCRUB.BELOW
        + BUTTON_HEIGHT + FRAME.PAD + FRAME.BOTTOM
    frame:SetSize(fw, fh)
    canvas:SetSize(state.W, state.H)
    content:SetSize(state.W, state.H)
    local scale = math.min(1, UIParent:GetWidth() * 0.95 / fw, UIParent:GetHeight() * 0.9 / fh)
    frame:SetScale(scale)
end

local function CreateButton(width, text, onClick)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(width, BUTTON_HEIGHT)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

-- A frame covering the content, drawn above the layers before it.
local function CreateLayer(level)
    local layer = CreateFrame("Frame", nil, content)
    layer:SetAllPoints()
    layer:SetFrameLevel(content:GetFrameLevel() + level)
    return layer
end

-- The timeline bar between the map and the buttons. Click or drag to move
-- the replay; hover for the level, zone and date at that point.
local function CreateScrub()
    scrub = CreateFrame("Frame", nil, frame)
    -- Under the map and the side panel both (its right end is set once the
    -- panel exists, in CreateWindow), wider by half a knob each side, so the
    -- strip's ends line up with their frames.
    scrub:SetPoint("TOPLEFT", canvas, "BOTTOMLEFT", -SCRUB.KNOB / 2, -SCRUB.TOP)
    scrub:SetPoint("TOPRIGHT", canvas, "BOTTOMRIGHT", SCRUB.KNOB / 2, -SCRUB.TOP)
    scrub:SetHeight(SCRUB.ROW)
    scrub:EnableMouse(true)
    scrub.pieces, scrub.ticks, scrub.runs, scrub.tickCount = {}, {}, {}, 0

    -- Strip in a tooltip-style frame, inset so the knob fits at both ends.
    local track = CreateFrame("Frame", nil, scrub)
    track:SetPoint("TOPLEFT", SCRUB.KNOB / 2, -(SCRUB.KNOB - SCRUB.TRACK) / 2)
    track:SetPoint("TOPRIGHT", -SCRUB.KNOB / 2, -(SCRUB.KNOB - SCRUB.TRACK) / 2)
    track:SetHeight(SCRUB.TRACK)
    scrub.track = track
    track:SetScript("OnSizeChanged", function()
        LayoutScrub()
        UpdateScrub(math.floor(state.cur))
    end)
    local back = track:CreateTexture(nil, "BACKGROUND", nil, -1)
    back:SetPoint("TOPLEFT", -2, 2)
    back:SetPoint("BOTTOMRIGHT", 2, -2)
    back:SetTexture(SCRUB.BACKGROUND)
    back:SetVertexColor(0, 0, 0, 0.9)
    local border = CreateFrame("Frame", nil, scrub, "BackdropTemplate")
    border:SetPoint("TOPLEFT", track, -SCRUB.OUTSET, SCRUB.OUTSET)
    border:SetPoint("BOTTOMRIGHT", track, SCRUB.OUTSET, -SCRUB.OUTSET)
    border:SetFrameLevel(track:GetFrameLevel() + 1)
    border:SetBackdrop({ edgeFile = SCRUB.EDGE, edgeSize = 10 })
    border:SetBackdropBorderColor(0.6, 0.6, 0.6)

    local knobFrame = CreateFrame("Frame", nil, scrub)
    knobFrame:SetAllPoints()
    knobFrame:SetFrameLevel(track:GetFrameLevel() + 2)
    scrub.hoverMark = knobFrame:CreateTexture(nil, "ARTWORK")
    scrub.hoverMark:SetSize(2, SCRUB.TRACK + 6)
    scrub.hoverMark:SetColorTexture(1, 1, 1, 0.7)
    scrub.hoverMark:Hide()
    scrub.knob = knobFrame:CreateTexture(nil, "OVERLAY")
    scrub.knob:SetSize(SCRUB.KNOB, SCRUB.KNOB)
    if not scrub.knob:SetAtlas("Minimal_SliderBar_Button") then
        scrub.knob:SetAtlas("UI-HUD-UnitFrame-SmallCircle")
    end

    local scrubbing, hovered = false, nil
    scrub:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" or state.n == 0 then return end
        scrubbing = true
        SetPlaying(false)
    end)
    scrub:SetScript("OnMouseUp", function()
        scrubbing = false
    end)
    scrub:SetScript("OnLeave", function()
        hovered = nil
        scrub.hoverMark:Hide()
        GameTooltip_Hide()
    end)
    scrub:SetScript("OnUpdate", function()
        if state.n == 0 then return end
        local seq = ScrubSeqAtCursor()
        if scrubbing and seq ~= math.floor(state.cur) then
            state.cur = seq
            ApplyCursor()
            if state.clock then
                state.clock = Together.ClockTimes(state)[seq] or state.clock
                Together.Apply()
            end
            -- Zoomed in, the map follows the arrow as the replay does.
            state.following = true
        end
        if scrub:IsMouseOver() and seq ~= hovered then
            hovered = seq
            ShowScrubTooltip(seq)
        end
    end)
end

-- Draws the map's frame MAP_BORDER outside target, level frame levels above
-- it. Returns the frame.
local function Outline(target, level)
    local edges = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    edges:SetPoint("TOPLEFT", target, -MAP_BORDER, MAP_BORDER)
    edges:SetPoint("BOTTOMRIGHT", target, MAP_BORDER, -MAP_BORDER)
    edges:SetFrameLevel(target:GetFrameLevel() + level)
    edges:SetBackdrop({ edgeFile = SCRUB.EDGE, edgeSize = 12 })
    edges:SetBackdropBorderColor(0.6, 0.6, 0.6)
    return edges
end

-- Returns the world art layer, which SetupWorld fills in.
local function CreateWindow()
    frame = CreateFrame("Frame", "RoadToSixtyJourneyFrame", UIParent, "ButtonFrameTemplate")
    frame:Hide()   -- before scripts are set, so OnHide does not run half-built
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnUpdate", OnUpdate)
    frame:SetScript("OnHide", function()
        -- Opening it again shows the same place at the same zoom, for the
        -- journey it was showing; only for this session, not saved.
        state.lastView = { view = ns.view, range = ns.Range:Key(), ox = state.ox, oy = state.oy, zoom = state.zoom }
        -- Opening the map again shows this character's journey.
        ns.Roster:SetView(nil)
        SetPlaying(false)
        ns.QuestPop:Clear()
        ns.GuildPop:Clear()
        ns.LevelPop:Clear()
        ns.KillPop:Clear()
        drag, state.following = nil, nil
        state.targetZoom = state.zoom
    end)
    tinsert(UISpecialFrames, "RoadToSixtyJourneyFrame")

    -- The game's own window: metal border, dark background, gold title. No
    -- portrait, no button bar, and the inset is not needed under the map.
    ButtonFrameTemplate_HidePortrait(frame)
    ButtonFrameTemplate_HideButtonBar(frame)
    if frame.Inset then frame.Inset:Hide() end
    -- Start the background below the title bar so the bar stays dark, as
    -- Baganator does on this client. Era's window has the classic border,
    -- whose inside starts at the template's own offset: 6 left a strip of
    -- the world showing down the left side there.
    local left = ns.Classic and select(4, frame.Bg:GetPoint(1)) or 6
    frame.Bg:SetPoint("TOPLEFT", left, -21)
    if frame.TopTileStreaks then frame.TopTileStreaks:SetPoint("TOPLEFT", left, -21) end

    -- Cog left of the close button, a small red button like the game's:
    -- opens or closes the options.
    local options = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    options:SetSize(32, 22)
    options:SetFrameLevel(frame.CloseButton:GetFrameLevel())
    options:SetPoint("RIGHT", frame.CloseButton, "LEFT", 0, 0)
    options:SetPoint("TOP", 0, 1)   -- Forever's title bar sits 2 px higher than retail's
    local cog = options:CreateTexture(nil, "ARTWORK")
    cog:SetSize(17, 17)
    cog:SetPoint("CENTER")
    cog:SetTexture("Interface\\AddOns\\" .. addonName .. "\\cog")
    options:SetScript("OnMouseDown", function() cog:SetPoint("CENTER", 1, -1) end)
    options:SetScript("OnMouseUp", function() cog:SetPoint("CENTER") end)
    options:SetScript("OnClick", function() ns.Options:Toggle() end)
    options:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Options")
        GameTooltip:Show()
    end)
    options:SetScript("OnLeave", GameTooltip_Hide)

    canvas = CreateFrame("Frame", nil, frame)
    canvas:SetPoint("TOPLEFT", FRAME.LEFT + FRAME.PAD + MAP_BORDER, -(FRAME.TOP + FRAME.PAD + MAP_BORDER))
    canvas:SetClipsChildren(true)
    canvas:EnableMouse(true)
    canvas:EnableMouseWheel(true)

    local background = canvas:CreateTexture(nil, "BACKGROUND", nil, -8)
    background:SetAllPoints()
    background:SetColorTexture(0.05, 0.05, 0.05)

    content = CreateFrame("Frame", nil, canvas)
    content:SetPoint("TOPLEFT")
    content:SetFrameLevel(canvas:GetFrameLevel() + 1)
    -- (under everything, the Cosmic art where the client has it: Cosmic.lua)
    state.cosmicLayer = CreateLayer(1)
    local worldLayer = CreateLayer(2)
    continentLayer = CreateLayer(3)
    -- Stable (#73): every zone without an outline always shows, so the art
    -- does not change with the zone in the middle of the view. Under the
    -- zones lies the gap art (Gaps.lua); each zone's painting round its own
    -- land fades out over the wide feather, so its darkened edge is gone
    -- before it meets that, and its own land over the rim mask, clear of
    -- its burnt frame.
    zoneView = ns.CreateZoneView(CreateLayer(5), true)
    zoneView.gaps = CreateLayer(4)
    zoneView.wideEdge, zoneView.rimEdge = ns.Gaps.FEATHER, ns.Gaps.RIM
    terrainLayer = CreateLayer(6)
    ns.KillMarks:Attach(CreateLayer(7))
    othersLayer = CreateLayer(8)
    pathLayer = CreateLayer(9)

    hoverLine = pathLayer:CreateLine(nil, "OVERLAY")
    hoverLine:SetColorTexture(1, 1, 1, 0.45)
    hoverLine:Hide()

    overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints()
    -- (over the path layer's jump arcs and portals, JumpSet)
    overlay:SetFrameLevel(content:GetFrameLevel() + 12)

    canvas:SetScript("OnMouseWheel", function(_, delta)
        local factor = delta > 0 and ZOOM_STEP or 1 / ZOOM_STEP
        state.targetZoom = math.max(state.minZoom, math.min(MAX_ZOOM, state.targetZoom * factor))
        state.anchorX, state.anchorY = CursorOnCanvas()
    end)
    canvas:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            local cx, cy = CursorOnCanvas()
            drag = { x = cx, y = cy, ox = state.ox, oy = state.oy, movedAt = GetTime() }
            state.targetZoom = state.zoom
        end
    end)
    canvas:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            drag = nil
            -- Dragged out of the near part: its detail follows the view now.
            if NeedsPathBuild() then ApplyView() end
        elseif button == "RightButton" then
            ZoomOut()
        end
    end)

    -- Frame around the map like the timeline's, with a soft shadow along the
    -- inside of each edge. Above every map layer and marker; takes no mouse.
    local edges = Outline(canvas, 40)
    -- (not the canvas's child, as the canvas clips what it holds; it goes
    -- with the canvas, which the gear screen hides, else its right edge
    -- showed as a line across the gear timeline)
    canvas:HookScript("OnHide", function() edges:Hide() end)
    canvas:HookScript("OnShow", function() edges:Show() end)
    local shadows = {
        { "TOPLEFT", "TOPRIGHT", "VERTICAL", 0, MAP_SHADOW[2] },
        { "BOTTOMLEFT", "BOTTOMRIGHT", "VERTICAL", MAP_SHADOW[2], 0 },
        { "TOPLEFT", "BOTTOMLEFT", "HORIZONTAL", MAP_SHADOW[2], 0 },
        { "TOPRIGHT", "BOTTOMRIGHT", "HORIZONTAL", 0, MAP_SHADOW[2] },
    }
    for _, s in ipairs(shadows) do
        local shadow = edges:CreateTexture(nil, "BACKGROUND")
        shadow:SetPoint(s[1], canvas)
        shadow:SetPoint(s[2], canvas)
        if s[3] == "VERTICAL" then
            shadow:SetHeight(MAP_SHADOW[1])
        else
            shadow:SetWidth(MAP_SHADOW[1])
        end
        shadow:SetColorTexture(1, 1, 1, 1)
        ns.SetAlphaGradient(shadow, s[3], s[4], s[5], { 0, 0, 0 })
    end

    hintText = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hintText:SetPoint("TOP", 0, -8)

    perfText = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    perfText:SetPoint("BOTTOMLEFT", 6, 6)

    -- Own frame, so the arrow draws above the marker frames.
    local headFrame = CreateFrame("Frame", nil, overlay)
    headFrame:SetAllPoints()
    headFrame:SetFrameLevel(overlay:GetFrameLevel() + 5)
    ns.QuestPop:Attach(overlay)
    ns.GuildPop:Attach(overlay)
    ns.LevelPop:Attach(overlay)
    ns.KillPop:Attach(overlay)
    head = headFrame:CreateTexture(nil, "OVERLAY")
    head:SetSize(HEAD.SIZE, HEAD.SIZE)
    head:SetTexture(HEAD.TEXTURE)
    -- (placed to fractions of a pixel, so its glide does not step)
    head:SetSnapToPixelGrid(false)
    head:SetTexelSnappingBias(0)
    -- Portals over the jump arcs, which are on frames of their own over
    -- the path layer (JumpSet), and under the markers.
    local portalLayer = CreateFrame("Frame", nil, pathLayer)
    portalLayer:SetAllPoints()
    portalLayer:SetFrameLevel(pathLayer:GetFrameLevel() + 2)
    ns.Portals:Attach(portalLayer)

    for i = 1, MOTES do
        local tex = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
        tex:SetTexture(MOTE_TEXTURE)
        tex:SetBlendMode("ADD")
        tex:Hide()
        motes[i] = { tex = tex }
    end

    playButton = CreateButton(70, "Play", function()
        if state.playing then
            SetPlaying(false)
            return
        end
        if state.clock and state.clock >= state.clockTo then
            state.clock = -math.huge
            if Together.Rebound() then
                state.cur = 0
            else
                Map:RefreshCharacters()
            end
        end
        if state.clock then
            SetPlaying(true)
            return
        end
        if state.cur >= state.n then
            state.cur = 0
            if state.zoom > state.minZoom and state.n > 0 then
                CenterOn(state.px[1], state.py[1])
                ApplyView()
            end
        end
        SetPlaying(state.n > 0)
    end)
    playButton:SetPoint("BOTTOMLEFT", FRAME.LEFT + FRAME.PAD, FRAME.BOTTOM + FRAME.PAD)

    -- The replay speed: a menu like the date range's, as replaying together
    -- has many speeds, or on a client without the menu, each click the next.
    speedButton = CreateButton(54, "1x", function(self)
        local together = state.clock ~= nil
        local function Choose(k)
            if together then state.togetherSpeed = k else state.speedIndex = k end
            Together.SetSpeedText()
        end
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(self, function(_, root)
                if together then
                    for k, speed in ipairs(Together.SPEEDS) do
                        root:CreateRadio(speed[2], function() return state.togetherSpeed == k end,
                            function() Choose(k) end)
                    end
                else
                    for k, speed in ipairs(SPEEDS) do
                        root:CreateRadio(speed .. "x", function() return state.speedIndex == k end,
                            function() Choose(k) end)
                    end
                end
            end)
        elseif together then
            Choose(state.togetherSpeed % #Together.SPEEDS + 1)
        else
            Choose(state.speedIndex % #SPEEDS + 1)
        end
    end)
    speedButton:SetPoint("LEFT", playButton, "RIGHT", 4, 0)

    -- Picking a mode sets the replay to its start, paused; play starts it.
    -- mode is real, game, or nil for Solo.
    local function ChooseMode(mode)
        if mode == state.togetherMode then return end
        SetPlaying(false)
        state.togetherMode = mode
        local from, to
        if mode then
            from, to = Together.Bounds()
        end
        if not from then
            Together.End()
            state.cur = state.n
            ApplyCursor()
            Map:RefreshCharacters()
            return
        end
        state.clock, state.clockTo = from, to
        state.cur = 0
        Together.button:SetText(Together.LABELS[mode])
        Together.SetSpeedText()
        ApplyCursor()
        Together.Apply()
    end
    Together.button = CreateButton(120, "Solo", function(self)
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(self, function(_, root)
                for _, mode in ipairs({ false, "real", "game" }) do
                    root:CreateRadio(mode and Together.LABELS[mode] or "Solo",
                        function() return state.togetherMode == (mode or nil) end,
                        function() ChooseMode(mode or nil) end)
                end
            end)
        elseif state.togetherMode then
            ChooseMode(Together.NEXT[state.togetherMode])
        else
            ChooseMode("real")
        end
    end)
    Together.button:SetParent(overlay)
    Together.button:SetPoint("TOPRIGHT", -8, -8)
    Together.button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Replay mode")
        GameTooltip:AddLine("Solo: the normal replay of one journey. The other two play every ticked character at once.", 1, 1, 1, true)
        GameTooltip:AddLine("Real Time: by the real time it happened, so a character that logged off waits on the map.", 1, 1, 1, true)
        GameTooltip:AddLine("Play Time: by time played, as if everyone played nonstop from the same moment.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    Together.button:SetScript("OnLeave", GameTooltip_Hide)

    terrainButton = CreateButton(90, "", function()
        ns.db.terrain = not ns.db.terrain
        UpdateTerrainButton()
        ApplyView()
    end)
    -- Terrain and the gear card only change the map, so they sit on it, in
    -- its bottom left corner (the gear screen covers them).
    terrainButton:SetParent(overlay)
    terrainButton:SetFrameLevel(overlay:GetFrameLevel() + 30)
    terrainButton:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", 8, 8)
    UpdateTerrainButton()

    -- Gear card in the map's corner, above those buttons, following the replay.
    ns.GearCard:Dock(overlay)
    gearButton = CreateButton(116, "", function()
        ns.db.showGear = not ns.db.showGear
        UpdateGearButton()
    end)
    gearButton:SetParent(overlay)
    gearButton:SetFrameLevel(overlay:GetFrameLevel() + 30)
    gearButton:SetPoint("LEFT", terrainButton, "RIGHT", 4, 0)
    gearButton:SetText(ns.db.showGear and "Gear card: On" or "Gear card: Off")

    -- The date range shown (Range.lua, #66): a menu of the presets, or on a
    -- client without the menu, each click the next one. Choosing one opens
    -- the map again on it.
    local rangeButton = CreateButton(104, ns.Range:Label(), function(self)
        local function Choose(key)
            ns.Range:Set(key)
            self:SetText(ns.Range:Label())
            Map:Open()
        end
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(self, function(_, root)
                for _, preset in ipairs(ns.Range.PRESETS) do
                    root:CreateRadio(preset[2], function() return ns.Range.key == preset[1] end,
                        function() Choose(preset[1]) end)
                end
            end)
        else
            local presets = ns.Range.PRESETS
            for k, preset in ipairs(presets) do
                if preset[1] == ns.Range.key then
                    Choose(presets[k % #presets + 1][1])
                    break
                end
            end
        end
    end)
    rangeButton:SetPoint("LEFT", speedButton, "RIGHT", 4, 0)

    CreateScrub()

    infoText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    infoText:SetPoint("LEFT", rangeButton, "RIGHT", 14, 0)
    infoText:SetJustifyH("LEFT")

    -- The phase shown in every mode (Range.lua): the whole journey, levelling
    -- or the endgame, from a menu like the date range's, or each click the
    -- next one. Shown only for a journey that has reached the level cap.
    local phaseButton = CreateButton(124, ns.Range:PhaseLabel(), function(self)
        local function Choose(key)
            ns.Range:SetPhase(key)
            self:SetText(ns.Range:PhaseLabel())
            Map:Open()
        end
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(self, function(_, root)
                for _, phase in ipairs(ns.Range.PHASES) do
                    root:CreateRadio(phase[2], function() return ns.Range.phase == phase[1] end,
                        function() Choose(phase[1]) end)
                end
            end)
        else
            local phases = ns.Range.PHASES
            for k, phase in ipairs(phases) do
                if phase[1] == ns.Range.phase then
                    Choose(phases[k % #phases + 1][1])
                    break
                end
            end
        end
    end)
    frame.phaseButton = phaseButton

    local panel = ns.Panel:Create(frame)
    panel:SetPoint("TOPLEFT", canvas, "TOPRIGHT", PANEL_GAP, 0)
    -- As tall as the map, so the timeline runs under both, the whole width
    -- of the window, and the gear screen (which covers both) has it too.
    panel:SetPoint("BOTTOMLEFT", canvas, "BOTTOMRIGHT", PANEL_GAP, 0)
    scrub:SetPoint("TOPRIGHT", panel, "BOTTOMRIGHT", SCRUB.KNOB / 2, -SCRUB.TOP)
    phaseButton:SetPoint("RIGHT", panel, "BOTTOMRIGHT", MAP_BORDER,
        -(SCRUB.TOP + SCRUB.ROW + SCRUB.BELOW + BUTTON_HEIGHT / 2))
    local panelEdges = Outline(panel, 10)
    -- Map | Gear | Stats; the screens take the map's and the panel's place (Screens.lua).
    ns.Screens:Attach(frame, canvas, panel, panelEdges)

    return worldLayer
end

-- Opening runs through SafeShow, so an error in it is counted and shown by
-- /rts check rather than lost when Lua errors are hidden.
function Map:Open()
    ns.SafeShow(Map.OpenNow, Map)
end

-- keep: built again where it is (LiveMap.lua), not fitted to the path.
function Map:OpenNow(keep)
    if not frame then
        local worldLayer = CreateWindow()
        local started = debugprofilestop()
        local ok = SetupWorld(worldLayer)
        state.perf.world = debugprofilestop() - started
        if not ok then
            ns.Print("Could not load the world map on this client.")
            frame = nil
            return
        end
    end
    Layout()
    frame:SetTitle(ns.Roster:ViewEntry().name .. "'s Journey")
    Map:UpdateViewBanner()

    -- The journey shown and how far it has grown. If nothing was recorded
    -- since the last open, the points, markers and replay effects still
    -- hold, and only the pops' animations are cleared.
    -- The date range and phase (Range.lua): the phase needs when the journey
    -- shown reached the level cap, the bounds again from now, and a rebuild
    -- whenever they change.
    local ok, cap = pcall(GetMaxPlayerLevel)
    local capSnapshot = ns.view.levels and ns.view.levels[ok and type(cap) == "number" and cap >= 60 and cap or 60]
    ns.Range:SetCap(capSnapshot and capSnapshot.t)
    ns.Range:Refresh()
    frame.phaseButton:SetShown(ns.Range.capAt ~= nil)
    frame.phaseButton:SetText(ns.Range:PhaseLabel())
    local view = ns.view
    -- The range's start moves only at midnight (Range.lua), and an end at
    -- now is left out, so the cache holds through the day.
    local journey = table.concat({ tostring(view), ns.Range:CacheKey(), #view.segments,
        ns.Recorder.stored,
        #view.events, view.kills and #view.kills.d or 0, view.totals and view.totals.kills or 0,
        ns.Gathering.changes, ns.Friends.changes }, ":")
    if journey == state.journey then
        state.perf.decode, state.perf.setup = 0, 0
        ns.QuestPop:Clear()
        ns.GuildPop:Clear()
        ns.LevelPop:Clear()
        ns.KillPop:Clear()
    else
        local started = debugprofilestop()
        local paths = ns.Range:TrimPaths(ns.Roster:ViewPaths())
        state.perf.decode = debugprofilestop() - started

        started = debugprofilestop()
        BuildPoints(paths)
        BuildMarkers()
        ns.GearCard:Rebuild()
        ns.Screens:Rebuild()
        ns.QuestPop:Rebuild()
        ns.GuildPop:Rebuild()
        ns.LevelPop:Rebuild()
        ns.KillPop:Rebuild()
        ns.KillMarks:Rebuild()
        StartWarmUp()
        state.perf.setup = debugprofilestop() - started
        state.journey = journey
    end

    SetPlaying(false)
    drag, state.following = nil, nil
    state.built, state.jumpKey = nil, nil
    for _, set in ipairs(state.jumpSets) do
        set.key = nil
    end
    state.cur = state.n
    if state.clock then
        Together.End()
    end
    -- Only an open from closed goes back to where it was; opening again on
    -- a new range (or journey) fits the path.
    local last = not frame:IsShown() and state.lastView or nil
    state.lastView = nil
    frame:Show()
    BuildScrub()
    BuildCharacters()
    BuildOtherTracks()
    -- Where it was when closed, if it shows the same journey and range;
    -- else the whole path.
    if keep then
        ClampView()
        ApplyView()
    elseif last and last.view == ns.view and last.range == ns.Range:Key() then
        SetZoomNow(math.max(state.minZoom, math.min(MAX_ZOOM, last.zoom)))
        state.ox, state.oy = last.ox, last.oy
        ClampView()
        ApplyView()
    else
        FitPath()
    end
    ApplyCursor()
    ns.Panel:Refresh()
end

-- Centres the map on a roster character: this one where it is now, others
-- where they last were outdoors.
function Map:ShowCharacter(e)
    if not (frame and frame:IsShown()) then return end
    local c, x, y = e.c, e.x, e.y
    if ns.Roster:IsMe(e) and not IsInInstance() then
        local lc, lx, ly = ns.GetWorldPosition()
        if lc then
            c, x, y = lc, lx, ly
        end
    end
    local toContent = c and state.toContent[c]
    if not toContent then return end
    drag, state.following = nil, nil
    SetZoomNow(math.max(state.zoom, JUMP_ZOOM))
    CenterOn(toContent(x, y))
    ApplyView()
end

-- Shows a roster character's whole journey on the map and side panel, as if
-- playing it; this character's again for nil or its own entry. A character
-- with no journey copy yet (not logged in since it was added) is only
-- centred on. Returns whether the view switched to e.
function Map:ShowJourney(e)
    if not (frame and frame:IsShown()) then return false end
    local was = ns.viewEntry
    local switched = ns.Roster:SetView(e)
    if switched or was then
        self:Open()
    elseif e then
        self:ShowCharacter(e)
    end
    if e and not switched and not ns.Roster:IsMe(e) then
        ns.Print(("%s's journey is not saved here yet; log in on %s once to share it."):format(e.name, e.name))
    end
    return switched
end

-- A label in the map's corner while another character's journey is shown,
-- naming it, with a button to go back to this character's.
function Map:UpdateViewBanner()
    local e = ns.viewEntry
    local banner = self.viewBanner
    if not e then
        if banner then banner:Hide() end
        return
    end
    if not banner then
        banner = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
        banner:SetPoint("TOPLEFT", 6, -40)     -- below the Map | Gear plaques
        banner:SetHeight(30)
        banner:SetFrameLevel(overlay:GetFrameLevel() + 20)
        banner:EnableMouse(true)
        banner:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        banner:SetBackdropColor(0, 0, 0, 0.75)
        banner.icon = banner:CreateTexture(nil, "ARTWORK")
        banner.icon:SetSize(20, 20)
        banner.icon:SetPoint("LEFT", 6, 0)
        banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        banner.text:SetPoint("LEFT", banner.icon, "RIGHT", 6, 0)
        banner.close = CreateFrame("Button", nil, banner, "UIPanelCloseButton")
        banner.close:SetSize(24, 24)
        banner.close:SetPoint("LEFT", banner.text, "RIGHT", 2, 0)
        banner.close:SetScript("OnClick", function()
            Map:ShowJourney(nil)
        end)
        banner.close:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Back to " .. ns.Roster:FullName() .. "'s journey")
            GameTooltip:Show()
        end)
        banner.close:SetScript("OnLeave", GameTooltip_Hide)
        self.viewBanner = banner
    end
    ns.SetClassIcon(banner.icon, e.class)
    banner.text:SetText(("Viewing %s's journey"):format(e.name))
    banner.text:SetTextColor(ns.ClassColor(e.class))
    banner:SetWidth(6 + 20 + 6 + banner.text:GetStringWidth() + 2 + 24 + 4)
    banner:Show()
end

-- Redraws other characters' markers and paths after the roster or the
-- per-character path settings change.
function Map:RefreshCharacters()
    if not (frame and frame:IsShown()) then return end
    BuildCharacters()
    BuildOtherTracks()
    if state.clock then
        Together.Rebound()
    end
    -- Their lines are built with the path, so force a path build.
    state.built = nil
    ApplyView()
end

-- Redraws the path, jumps and markers after the History filter changes.
function Map:RefreshFilters()
    if not (frame and frame:IsShown()) then return end
    state.built = nil
    ApplyView()
end

-- Moves the replay to time t and centres the map on an event's position,
-- zooming in if the map is further out than JUMP_ZOOM.
function Map:JumpTo(t, continentID, x, y)
    if not (frame and frame:IsShown()) then return end
    SetPlaying(false)
    drag, state.following = nil, nil

    -- A moment before the first point shown (a zone row on the Stats screen
    -- for a zone entered before the date range) goes to that first point,
    -- not to "Start of journey" (#103).
    state.cur = math.max(SeqAt(t), math.min(1, state.n))

    local toContent = state.toContent[continentID]
    if toContent then
        SetZoomNow(math.max(state.zoom, JUMP_ZOOM))
        CenterOn(toContent(x, y))
    end
    ApplyView()
    ApplyCursor()
    if state.clock then
        state.clock = Together.ClockTimes(state)[state.cur] or state.clock
        Together.Apply()
    end
    -- The replay stops at the last point before t; History should still mark
    -- the entry that was clicked, not the one before it.
    ns.Panel:SetTime(t)
end

-- Canvas position of world point x, y on continent c in the current view,
-- for things other files draw on the map; nil if the continent is not on it.
function Map:WorldToCanvas(c, x, y)
    local toContent = state.toContent[c]
    if not toContent then return end
    return ToCanvas(toContent(x, y))
end

-- The quest marker for a turn-in at time t on continent c, when the Quests
-- filter and the zoom show quest markers right now; nil otherwise. A quest
-- pop plays on it rather than beside it.
function Map:QuestMarker(t, c)
    if not ns.FilterShown("quests") or state.zoom < MARKER_ZOOM.quest then return end
    for i = 1, state.markerCount do
        local m = markers[i]
        if m.category == "quests" and m.c == c and t >= m.t and t <= m.lastT then
            return m
        end
    end
end

-- The marker of the guild event at time t on continent c, if there is one.
function Map:GuildMarker(t, c)
    for i = 1, state.markerCount do
        local m = markers[i]
        if m.category == "guilds" and m.c == c and m.t == t then
            return m
        end
    end
end

-- The marker of the level reached at time t, if there is one.
function Map:LevelMarker(t)
    for i = 1, state.markerCount do
        local m = markers[i]
        if m.category == "levels" and m.t == t then
            return m
        end
    end
end

-- Shows or hides the markers again, after a quest pop ended on one.
function Map:RefreshMarkers()
    if frame and frame:IsShown() then
        UpdateMarkers()
    end
end

-- Where the replay's arrow is, in content units; nil before the first point.
function Map:ReplayPosition()
    local seq = math.floor(state.cur)
    if seq < 1 or seq > state.n then return end
    return state.px[seq], state.py[seq]
end

-- Where the path was at time t, in content units: its last point at or
-- before t, if that is recent enough to stand for t; nil otherwise. The path
-- only gets points while moving, so a long fight in one spot still counts.
Map.POSITION_GAP = 900      -- seconds
function Map:PositionAt(t)
    local seq = SeqAt(t)
    if seq < 1 or t - state.pt[seq] > self.POSITION_GAP then return end
    return state.px[seq], state.py[seq]
end

-- Content units per world yard, from the first continent on the map (they
-- are drawn at about the same scale); nil before the world is set up.
function Map:ContentPerYard()
    -- (Azeroth's scale first: Outland's map is drawn at a scale of its own)
    local azeroth = state.toContent[0] or state.toContent[1]
    if azeroth then
        local x1, y1 = azeroth(0, 0)
        local x2, y2 = azeroth(1000, 0)
        return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) / 1000
    end
    for _, toContent in pairs(state.toContent) do
        local x1, y1 = toContent(0, 0)
        local x2, y2 = toContent(1000, 0)
        return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) / 1000
    end
end

-- Canvas position of a content point in the current view.
function Map:ContentToCanvas(x, y)
    return ToCanvas(x, y)
end

-- Brings the map in line with settings changed elsewhere, such as in the
-- options panel.
function Map:ApplySettings()
    if not frame then return end
    UpdateTerrainButton()
    UpdateGearButton()
    if not ns.db.motes then
        HideMotes()
    end
    if not ns.db.questPops then
        ns.QuestPop:Clear()
    end
    if not ns.db.killPops then
        ns.KillPop:Clear()
    end
    if frame:IsShown() then
        ApplyView()
    end
end

function Map:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:Open()
    end
end

ns.Command("map", "open the journey map", function()
    Map:Toggle()
end)

--@debug@
ns.Command("tiles", "toggle showing, in red, terrain tiles left out for lying in no zone", function()
    ns.db.showSkipped = not ns.db.showSkipped
    -- Drop all loaded tiles so the next view loads the new set.
    for index in pairs(activeTiles) do
        ReleaseTile(index)
    end
    state.terrainBuilt = nil
    if frame and frame:IsShown() then
        ApplyView()
    end
    ns.Print("Skipped terrain tiles " .. (ns.db.showSkipped and "shown in red." or "hidden."))
end)

-- Trying out merging lines a newer walk covers (PathShape.lua's MergeLines):
-- the detail levels are made again with or without it.
ns.Command("merge", "toggle merging path lines a newer walk covers; a number sets how near, in pixels (2) (developer)", function(arg)
    local pixels = tonumber(arg)
    if pixels then
        DETAIL.MERGE = pixels > 0 and pixels or nil
    else
        DETAIL.MERGE = not DETAIL.MERGE and 2 or nil
    end
    state.lods, state.picked, state.built = {}, nil, nil
    for _, track in ipairs(state.otherTracks or {}) do
        track.lods, track.picked = {}, nil
    end
    -- The warm-up merges the levels, so it starts again even with the map
    -- closed: it runs once the map is open, and opening it on the same
    -- journey doesn't start it.
    StartWarmUp()
    if frame and frame:IsShown() then
        ApplyView()
    end
    local open = frame and frame:IsShown()
    ns.Print(DETAIL.MERGE and ("Merging lines within %s px: %s, and says when it's done. /rts merge again turns it off."):format(
        DETAIL.MERGE, open and "it runs now in the background" or "it runs once the map is open")
        or "Not merging lines (/rts merge turns it on).")
end)
--@end-debug@

ns.Command("motes", "toggle sparkles drifting along the journey map path", function()
    ns.db.motes = not ns.db.motes
    if not ns.db.motes then
        HideMotes()
    end
    ns.Options:Refresh()
    ns.Print("Path sparkles " .. (ns.db.motes and "on" or "off") .. ".")
end)

-- What LiveMap.lua needs to keep the map up to date while it is open (#136),
-- in a table rather than more top-level locals (see the note on the limit).
Map.inner = {
    state = state,
    LodDistance = LodDistance,
    CHUNK = CHUNK,
    -- Points were added at the end: the replay stays at the end, the path
    -- is drawn again where it is, and the replay bar's last band reaches them.
    -- box: around the new points; the path is drawn again only when they
    -- fall where it was built (the view and its margin), as a pan out to
    -- them builds it anyway. Together's played times are worked out again,
    -- and the levels the warm-up was building start over, as it counted the
    -- points when it began.
    PointsAdded = function(box)
        state.cur = state.n
        state.pg = nil
        local built = state.built
        if not built or box[3] >= built[1] and box[1] <= built[3] and box[4] >= built[2] and box[2] <= built[4] then
            state.built = nil
        end
        -- Not while it merges: the levels are all made by then, and starting
        -- over each time the player moved kept the merge from ever ending.
        if state.warm and not state.merging then StartWarmUp() end
        local runs = scrub.runs
        if runs and runs[#runs] then
            runs[#runs].last = state.n
            LayoutScrub()
        else
            BuildScrub()
        end
        ApplyView()
        ApplyCursor()
    end,
    -- New events: their markers, kill marks, the replay bar's ticks and
    -- History (where it was scrolled to), the gear card, the screens and the
    -- pops, as an open builds them.
    MarkersChanged = function()
        local _, tl = Map.Timelines(ns.view.events)
        state.timelines = tl
        BuildMarkers()
        ns.KillMarks:Rebuild()
        ns.GearCard:Rebuild()
        ns.Screens:Rebuild()
        ns.QuestPop:Rebuild()
        ns.GuildPop:Rebuild()
        ns.LevelPop:Rebuild()
        ns.KillPop:Rebuild()
        BuildScrub()
        ApplyCursor()
        ns.Panel:Refresh(true)
    end,
    -- Everything built again, the view kept where it is.
    Rebuild = function()
        state.journey = nil
        Map:OpenNow(true)
    end,
    -- The arrow moved with the player: placed again. The view pans with it,
    -- as a replay's does, only when the arrow walked out of the middle part
    -- of the view (HEAD.ZONE) by itself: never while the map is dragged or
    -- zooming, and not when the view was moved away from it (it was already
    -- outside then). The middle part reaches a hair further here, as a
    -- glide leaves the arrow on its edge, give or take rounding.
    HeadMoved = function()
        local x, y = state.headX, state.headY
        PlaceHead()
        if drag or state.zoom ~= state.targetZoom or not x or not state.headX then return end
        local lo = HEAD.ZONE - 0.01
        local function Inside(hx, hy)
            local fx = (hx - state.ox) * state.zoom / state.W
            local fy = (hy - state.oy) * state.zoom / state.H
            return fx >= lo and fx <= 1 - lo and fy >= lo and fy <= 1 - lo
        end
        if Inside(x, y) and not Inside(state.headX, state.headY) then
            state.following = true
        end
    end,
}
