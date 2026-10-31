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
local MIN_PIXELS = 2            -- points closer than this on screen are merged
local MAX_LINES = 3000          -- line budget per build; past it, points merge further
local LINE_WIDTH = 2
local SPEEDS = { 1, 2, 4, 8, 16, 32 }
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
    MAX_LINES = 1500,       -- most lines per other character's path in range of the view
    LINE_WIDTH = 1.5,
    -- Alpha by movement mode, and for jumps (arcs, or a plain line when the
    -- reason is unknown, as between walking and a flight).
    ALPHA = { w = 0.55, t = 0.3, g = 0.2, j = 0.3 },
}

local HEAD = { TEXTURE = "Interface\\WorldMap\\WorldMapArrow", SIZE = 24 }   -- the replay's arrow
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
local jumpLines, jumpDots, jumpIcons = {}, {}, {}  -- pieces of jump arcs, reused
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
    lineZoom = 1,       -- zoom the line thickness was last set for
    visible = {},       -- indexes into drawn of lines inside the view
    built = nil,        -- area and zoom of the last path build
    terrainBuilt = nil, -- area of the last terrain build
    terrainCapped = false,

    cur = 0,            -- replay position as a fractional point index
    playing = false,
    speedIndex = 1,

    -- Timings in ms for /rts perf
    perf = { world = 0, decode = 0, setup = 0, build = 0, lod = 0, place = 0, terrain = 0, view = 0 },
    charCount = 0,      -- other characters' markers in use
    jumps = {},         -- built jump arcs: { index into drawn, parts, icon, x, y }
    boats = {},         -- point index -> "Dock to dock" for boat jumps near known docks
    seaTrips = {},      -- point index -> how a jump across the sea is drawn, see BuildPoints
    ribbons = {},       -- ribbon effect lines to scroll, see BuildJumps
    ribbonClock = 0,    -- seconds the ribbon effects have flowed
    otherTracks = {},   -- tracks of other characters whose path is turned on
    otherDrawn = {},    -- their built lines, like drawn, each with .track
    hover = nil,        -- line spec under the mouse, with a tooltip showing
    otherLineCount = 0, -- lines of other characters' paths in use
    otherZoom = 1,      -- zoom their line thickness was last set for
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

local function ZoneAt(t)
    local tl = state.timelines
    return ZoneName(tl.zones[ns.LastIndex(tl.zoneTimes, t)])
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

local function BuildPoints(paths)
    local px, py, pt, pm, pb, brk, pj, pd = {}, {}, {}, {}, {}, {}, {}, {}

    -- Level changes in time order, walked alongside the points. The same
    -- pass builds the level and zone timelines.
    local changes = {}
    local tl = { levelTimes = {}, levels = {}, zoneTimes = {}, zones = {} }
    for _, e in ipairs(ns.view.events) do
        if e[2] == "on" or e[2] == "lvl" then
            changes[#changes + 1] = e
            tl.levelTimes[#tl.levelTimes + 1], tl.levels[#tl.levels + 1] = e[1], e[6]
        elseif e[2] == "zone" then
            tl.zoneTimes[#tl.zoneTimes + 1], tl.zones[#tl.zones + 1] = e[1], e[6]
        end
    end
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
    state.pj, state.pd = pj, pd
    state.bounds = { x1, y1, x2, y2 }
    state.lods = {}
end

local function GetMarker(i)
    local m = markers[i]
    -- A marker reused for another kind of event loses a guild banner or a
    -- group's portraits it had.
    if m and m.badge then
        m.badge:Hide()
        m.icon:Show()
    end
    if m and m.stack then
        m.stack:Hide()
        m.group = nil
        m.icon:Show()
    end
    if m then m.rare, m.node = nil, nil end
    if m and m.gather then
        m.gather:Hide()
        m.icon:Show()
    end
    if m then
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
        -- A group spreads its portraits out and shows its card.
        if self.group then
            ns.Parties:Spread(self.stack, true)
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
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.title)
        GameTooltip:AddLine(self.detail, 1, 1, 1)
        GameTooltip:Show()
    end)
    m:SetScript("OnLeave", function(self)
        GameTooltip_Hide()
        ns.GearCard:Hide()
        ns.Rares:HideCard()
        if self.group then
            ns.Parties:Spread(self.stack, false)
            ns.Parties:HideCard()
        end
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
            or kind == "rep" or kind == "ride" or kind == "mount" or kind == "rare") then
            local guild = kind == "gj" or kind == "gl" or kind == "gr"
            local mount = kind == "ride" or kind == "mount"
            local source = guild and ns.Guilds or kind == "rep" and ns.Reputation or mount and ns.Mounts
                or kind == "rare" and ns.Rares or ns.Crafts
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
                    or kind == "prof" and MARKER_ZOOM.profession or MARKER_ZOOM.recipe
                local size = ns.SetEventIcon(m.icon, m.text, kind, nil, icon)
                m:SetSize(size, size)
                -- Rares show a card with their portrait when hovered.
                m.rare = kind == "rare" and { e, Where(inside, zone) } or nil
                m.title = title
                m.detail = ("%s\n%s\n%s"):format(detail, Where(inside, zone), FormatTime(t))
            end
        elseif toContent and kind == "grp" then
            -- The group's portraits, overlapping; the marker grows with them.
            count = count + 1
            local m = GetMarker(count)
            m.t, m.popping, m.level, m.group = t, nil, nil, e
            m.x, m.y = toContent(x, y)
            m.c = c
            m.category = Style.CATEGORY[kind]
            m.minZoom = MARKER_ZOOM.group
            m.title, m.detail = ns.Parties:Describe(e)
            if not m.stack then
                m.stack = ns.Parties:CreateStack(m, 24)
                m.stack:SetPoint("CENTER")
                m.stack.onResize = function(stack)
                    m:SetSize(stack:GetWidth(), stack:GetHeight())
                end
            end
            m.icon:Hide()
            m.stack:Show()
            ns.Parties:SetStack(m.stack, ns.Parties:Info(e))
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

-- Merge distance in content units of detail level k. Level 0 is fine enough
-- for full zoom; each level up doubles it.
local function LodDistance(k)
    return MIN_PIXELS / MAX_ZOOM * LOD_STEP ^ k
end

-- A track is a path to draw with detail levels: { n, px, py, brk, lods } and
-- optionally pm (movement mode per point). The player's own path is state
-- itself; other characters' paths are built from the roster.
--
-- The track simplified at detail level k, made on first use: idx lists the
-- points kept, each at least LodDistance(k) from the last one kept, plus every
-- segment's first and last point. Built from level k - 1 when that exists,
-- which is much shorter than the full path. chunks are boxes over runs of
-- CHUNK kept points: { first, last, x1, y1, x2, y2 }, first and last being
-- indexes into idx; each box includes the point before its run, where its
-- first line starts. With background set, it runs inside the warm-up
-- coroutine and yields every LOD_YIELD points.
local function GetLod(track, k, background)
    local lod = track.lods[k]
    if lod then return lod end
    local started = debugprofilestop()

    local px, py, brk = track.px, track.py, track.brk
    local source = track.lods[k - 1] and track.lods[k - 1].idx
    local length = source and #source or track.n
    local minSq = LodDistance(k) ^ 2
    local idx, count, lx, ly = {}, 0, 0, 0
    for j = 1, length do
        local i = source and source[j] or j
        local x, y = px[i], py[i]
        local dx, dy = x - lx, y - ly
        -- brk[i + 1] ~= false: last point of a segment, always keep it
        if brk[i] or brk[i + 1] ~= false or dx * dx + dy * dy >= minSq then
            count = count + 1
            idx[count] = i
            lx, ly = x, y
        end
        if background and j % LOD_YIELD == 0 then
            coroutine.yield()
        end
    end
    -- A build that needed this level may have made it while we yielded.
    if track.lods[k] then return track.lods[k] end

    local chunks = {}
    for first = 1, count, CHUNK do
        local last = math.min(count, first + CHUNK - 1)
        local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
        for j = math.max(1, first - 1), last do
            local x, y = px[idx[j]], py[idx[j]]
            if x < x1 then x1 = x end
            if x > x2 then x2 = x end
            if y < y1 then y1 = y end
            if y > y2 then y2 = y end
        end
        chunks[#chunks + 1] = { first, last, x1, y1, x2, y2 }
    end

    lod = { idx = idx, chunks = chunks }
    track.lods[k] = lod
    if not background then
        state.perf.lod = state.perf.lod + debugprofilestop() - started
    end
    return lod
end

-- Pre-builds detail levels finest first, each from the one before, a little
-- each frame, so zooming in later does not stop to build them.
local function StartWarmUp()
    state.warm = coroutine.create(function()
        for k = 0, WARM_LODS do
            GetLod(state, k, true)
        end
    end)
end

local function StepWarmUp()
    local ok, err = coroutine.resume(state.warm)
    if not ok then
        state.warm = nil
        geterrorhandler()(err)
    elseif coroutine.status(state.warm) == "dead" then
        state.warm = nil
    end
end

-- Chunks of a detail level that overlap the area, and how many points they hold.
local function ChunksIn(lod, x1, y1, x2, y2)
    local list, total = {}, 0
    for _, ch in ipairs(lod.chunks) do
        if ch[5] >= x1 and ch[3] <= x2 and ch[6] >= y1 and ch[4] <= y2 then
            list[#list + 1] = ch
            total = total + ch[2] - ch[1] + 1
        end
    end
    return list, total
end

-- Detail level of a track for the area at zoom z: the finest whose merge
-- distance is at least MIN_PIXELS on screen, made coarser until the points in
-- range fit the budget. Returns the level, its chunks in range, and k.
local function PickLod(track, x1, y1, x2, y2, z, budget)
    local k = math.max(0, math.ceil(math.log(MAX_ZOOM / z) / math.log(LOD_STEP) - 1e-9))
    local lod, list, total
    repeat
        lod = GetLod(track, k)
        list, total = ChunksIn(lod, x1, y1, x2, y2)
        k = k + 1
    until total <= budget or k > MAX_LOD
    return lod, list, k - 1
end

-- Lines of a track's detail level inside the area, in point order:
-- { x1, y1, x2, y2, mode, pointIndex }. mode is nil for tracks without pm.
-- With jumps set, the gap before each segment (hearthstone, teleport, boat,
-- graveyard) is a line too, with mode "j". A jump drawn on a sea course or
-- lane counts as inside wherever its curve is (track.seaTrips).
local function LinesIn(track, lod, list, x1, y1, x2, y2, jumps)
    local idx, px, py, pm, brk = lod.idx, track.px, track.py, track.pm, track.brk
    local seaTrips = jumps and track.seaTrips or {}
    local drawn, count = {}, 0
    for _, ch in ipairs(list) do
        for j = math.max(2, ch[1]), ch[2] do
            local i = idx[j]
            if jumps or not brk[i] then
                local p = idx[j - 1]
                local ax, ay, bx, by = px[p], py[p], px[i], py[i]
                local box = brk[i] and seaTrips[i] and seaTrips[i].box
                local outside
                if box then
                    outside = box[3] < x1 or box[1] > x2 or box[4] < y1 or box[2] > y2
                else
                    outside = math.max(ax, bx) < x1 or math.min(ax, bx) > x2
                        or math.max(ay, by) < y1 or math.min(ay, by) > y2
                end
                if (ax ~= bx or ay ~= by) and not outside then
                    count = count + 1
                    drawn[count] = { ax, ay, bx, by, brk[i] and "j" or pm and pm[i], i }
                end
            end
        end
    end
    return drawn
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

local jumpLineCount, jumpDotCount, jumpIconCount = 0, 0, 0

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
local function ShowJumps(shown)
    for _, jump in ipairs(state.jumps) do
        local visible = jump.index <= shown
        if visible ~= jump.visible then
            jump.visible = visible
            for _, part in ipairs(jump.parts) do
                part:SetShown(visible)
            end
        end
    end
    ShowJumpIcons()
end

-- A line piece of a jump, in a flat colour on OVERLAY sublayer layer (one
-- per stacked line: in one sublayer the drawing order is not kept). width is
-- in screen pixels and kept on the line for zoom changes. Lines are reused,
-- so a ribbon's texture and blend are undone here.
local function JumpLine(jump, ax, ay, bx, by, width, r, g, b, a, layer)
    jumpLineCount = jumpLineCount + 1
    local line = jumpLines[jumpLineCount]
    if not line then
        line = pathLayer:CreateLine(nil, "OVERLAY")
        jumpLines[jumpLineCount] = line
    end
    line:SetStartPoint("TOPLEFT", pathLayer, ax, -ay)
    line:SetEndPoint("TOPLEFT", pathLayer, bx, -by)
    line:SetColorTexture(r, g, b, a)
    line:SetBlendMode("BLEND")
    line:SetTexCoord(0, 1, 0, 1)
    line:SetDrawLayer("OVERLAY", layer or 0)
    line.width = width
    line:SetThickness(width / state.zoom)
    table.insert(jump.parts, line)
    return line
end

local function JumpStroke(jump, style, ax, ay, bx, by)
    if not style.plain then
        JumpLine(jump, ax, ay, bx, by, JUMP_OUTLINE, unpack(JUMP_OUTLINE_COLOR))
    end
    JumpLine(jump, ax, ay, bx, by, style.plain and LINE_WIDTH or JUMP_LINE, style[2], style[3], style[4], style[5], 1)
end

-- A dot of a jump. size is in screen pixels. file, if given, replaces the
-- round dot and is drawn above the dots, uncoloured (finish marks). Round
-- dots go on sublayer 0; the caller lifts coloured ones above their outline.
local function JumpDot(jump, x, y, size, r, g, b, a, file)
    jumpDotCount = jumpDotCount + 1
    local dot = jumpDots[jumpDotCount]
    if not dot then
        dot = pathLayer:CreateTexture(nil, "OVERLAY")
        jumpDots[jumpDotCount] = dot
    end
    if file then
        dot:SetTexture(file)
        dot:SetDrawLayer("OVERLAY", 2)
    else
        dot:SetAtlas("WhiteCircle-RaidBlips")
        dot:SetDrawLayer("OVERLAY", 0)
    end
    dot:SetVertexColor(r, g, b, a)
    dot:ClearAllPoints()
    dot:SetPoint("CENTER", pathLayer, "TOPLEFT", x, -y)
    dot.size = size
    dot:SetSize(size / state.zoom, size / state.zoom)
    dot.fade, dot.target, dot.alpha, dot.key = nil, nil, nil, nil
    dot:SetAlpha(1)
    table.insert(jump.parts, dot)
    return dot
end

-- Draws an arc for each jump in drawn, in the style of its reason, with the
-- reason's icon at the top. Sizes and spacing are in screen pixels at zoom
-- z; zoom changes resize them (SetLineThickness) until the next build.
-- Dashes and dots are only placed inside area { x1, y1, x2, y2 }, so a long
-- boat trip seen close up keeps its spacing instead of hitting
-- JUMP_MAX_PIECES across the whole sea.
local function BuildJumps(drawn, shown, z, area)
    -- Dots still fading carry their alpha over, by place, so a rebuild in
    -- the middle of a zoom does not cut the fade short.
    local fadingAlpha = {}
    if state.dotsFading then
        for i = 1, jumpDotCount do
            local dot = jumpDots[i]
            if dot.key then
                fadingAlpha[dot.key] = dot.alpha
            end
        end
    end
    jumpLineCount, jumpDotCount, jumpIconCount = 0, 0, 0
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
    -- this one would.
    local placed = {}
    local function Taken(style, x, y, row, near)
        local grid = placed[style]
        if not grid then
            grid = {}
            placed[style] = grid
        end
        local cx, cy = math.floor(x / near), math.floor(y / near)
        for gx = cx - 1, cx + 1 do
            for gy = cy - 1, cy + 1 do
                for _, d in ipairs(grid[gx .. ":" .. gy] or {}) do
                    if d[3] >= row and (d[1] - x) ^ 2 + (d[2] - y) ^ 2 < near * near then
                        return true
                    end
                end
            end
        end
        local key = cx .. ":" .. cy
        grid[key] = grid[key] or {}
        table.insert(grid[key], { x, y, row })
        return false
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
            -- Dots are counted from anchor, so trips on one route share them:
            -- a boat course's middle waypoint, or the middle of the arc.
            local anchor = ends and (ends.anchor or total / 2) or 0
            -- Marks at the curve's ends: a boat route drawn the other way
            -- round from how it was sailed has its X at the start.
            local head, tail = style.start, style.finish
            if ends and ends.flip then
                head, tail = tail, head
            end
            local jump = { index = i, parts = {}, spec = spec }
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
                -- A lane's trunk is drawn by its first trip only: the same band
                -- again on top would add its glowing effects up.
                local trunk = ends and ends.trunk
                local skip = trunk and lanesDrawn[ends.lane]
                if trunk then
                    lanesDrawn[ends.lane] = true
                end
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
                            -- One texture repeat along the band keeps the texture's
                            -- shape at this zoom; OnUpdate scrolls it.
                            ribbons[#ribbons + 1] = {
                                line = line, jump = jump, from = pa[3], to = pb[3],
                                span = w * effect[2] / z, speed = effect[3],
                            }
                        end
                    end
                end
            elseif style.style == "dash" then
                local spans, length = Spans(curve)
                -- Steps from the start of the curve, so dashes stay put as the view moves.
                local period = Snap((JUMP_DASH + JUMP_GAP) / z, length / JUMP_MAX_PIECES)
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
                local spans, length = Spans(curve)
                local size = style.dot or JUMP_DOT
                local px = style.spacing or JUMP_DOT_SPACING
                local fine = 2 ^ math.ceil(math.log(px / z) / math.log(2)) / 4
                while length / fine > JUMP_MAX_PIECES * 2 do
                    fine = fine * 2
                end
                -- Dots keep clear of start and finish marks rather than run under them.
                local first = head and (head[2] / 2 + px / 3) / z or 0
                local last = total - (tail and (tail[2] / 2 + px / 3) / z or 0)
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
                        if not Taken(style, x, y, row, 0.6 * px / z) then
                            for layer, dot in ipairs({
                                JumpDot(jump, x, y, size + 2, unpack(JUMP_OUTLINE_COLOR)),
                                JumpDot(jump, x, y, size, style[2], style[3], style[4], style[5]),
                            }) do
                                -- The coloured dot on a sublayer above its outline: in one
                                -- sublayer the order is not kept, and the outline can cover it.
                                dot:SetDrawLayer("OVERLAY", layer - 1)
                                local key = x .. ":" .. y .. ":" .. layer
                                local alpha = fadingAlpha[key] or target
                                dot.fade, dot.fadePx, dot.target, dot.alpha, dot.key = row, px, target, alpha, key
                                dot:SetAlpha(alpha)
                            end
                        end
                    end
                end
            end
            -- A trip out and back can put an X on a ring, so the X (where the
            -- player landed) draws above.
            if head then
                JumpDot(jump, curve[1][1], curve[1][2], head[2], 1, 1, 1, 1, head[1])
                    :SetDrawLayer("OVERLAY", head == style.finish and 3 or 2)
            end
            if tail then
                local p = curve[#curve]
                JumpDot(jump, p[1], p[2], tail[2], 1, 1, 1, 1, tail[1])
                    :SetDrawLayer("OVERLAY", tail == style.finish and 3 or 2)
            end

            if style.icon then
                jumpIconCount = jumpIconCount + 1
                local icon = jumpIcons[jumpIconCount]
                if not icon then
                    icon = overlay:CreateTexture(nil, "OVERLAY", nil, 5)
                    icon:SetSize(JUMP_ICON, JUMP_ICON)
                    jumpIcons[jumpIconCount] = icon
                end
                icon:SetAtlas(style.icon)
                jump.icon = icon
                -- On a lane, at its middle, where every trip on it puts its icon.
                jump.x, jump.y = PointAlong(curve, ends and ends.anchor or total / 2)
            end
            jumps[#jumps + 1] = jump
        end
    end
    for i = jumpLineCount + 1, #jumpLines do
        jumpLines[i]:Hide()
    end
    for i = jumpDotCount + 1, #jumpDots do
        jumpDots[i]:Hide()
    end
    for i = jumpIconCount + 1, #jumpIcons do
        jumpIcons[i]:Hide()
    end
    ns.Portals:Finish()
    state.jumps = jumps
    ShowJumps(shown)
end

local function SetLineThickness()
    local z = state.zoom
    local thickness = LINE_WIDTH / z
    for i = 1, state.lineCount do
        lines[i]:SetThickness(thickness)
    end
    for i = 1, jumpLineCount do
        local line = jumpLines[i]
        line:SetThickness(line.width / z)
    end
    for i = 1, jumpDotCount do
        local dot = jumpDots[i]
        dot:SetSize(dot.size / z, dot.size / z)
        if dot.fade then
            local target = dot.fade * z >= dot.fadePx and 1 or 0
            if target ~= dot.target then
                dot.target = target
                state.dotsFading = true
            end
        end
    end
    ns.Portals:SetZoom(z)
    state.lineZoom = z
end

-- Tracks for the characters whose path is turned on, from the roster's paths
-- in content units, breaking where each piece starts. Like the player's own
-- track they carry pm (mode per point) and pj (jump reason at a piece's
-- first point), and colors holds a colour per mode and for jumps.
local function BuildOtherTracks()
    local tracks = {}
    local shown = ns.Roster:ViewEntry()
    for _, e in ipairs(ns.Roster:Entries()) do
        if ns.db.showPaths[e.key] and e ~= shown then
            local px, py, pm, pj, brk, n = {}, {}, {}, {}, {}, 0
            -- This character's own journey is live, its roster copy as of logout.
            local paths = ns.Roster:IsMe(e) and ns.Recorder:GetPaths() or ns.Roster:Paths(e)
            local previous
            for _, path in ipairs(paths) do
                local toContent = state.toContent[path.c]
                if toContent and #path.x > 0 then
                    local continues = ns.Recorder:Continues(previous, path)
                    for i = 1, #path.x do
                        n = n + 1
                        px[n], py[n] = toContent(path.x[i], path.y[i])
                        pm[n], brk[n] = path.m, i == 1 and not continues
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
            tracks[#tracks + 1] = {
                n = n, px = px, py = py, pm = pm, pj = pj, brk = brk, lods = {}, colors = colors,
                entry = e,
            }
        end
    end
    state.otherTracks = tracks
end

-- Lines of the other characters' tracks in the area, built with the player's
-- own path and the same way, but each within OTHER.MAX_LINES: every line
-- costs time on each zoom frame. Jumps with a known reason are arcs, made of
-- several lines that share the jump's spec fields.
local function BuildOtherLines(x1, y1, x2, y2, z)
    local count, thickness = 0, OTHER.LINE_WIDTH / z
    local otherDrawn = {}
    local function Add(track, spec, mode)
        count = count + 1
        otherDrawn[count] = spec
        local line = otherLines[count]
        if not line then
            line = othersLayer:CreateLine(nil, "ARTWORK")
            otherLines[count] = line
        end
        line:SetStartPoint("TOPLEFT", othersLayer, spec[1], -spec[2])
        line:SetEndPoint("TOPLEFT", othersLayer, spec[3], -spec[4])
        local color = track.colors[mode] or track.colors.w
        if line.color ~= color then
            line:SetColorTexture(unpack(color))
            line.color = color
        end
        line:SetThickness(thickness)
        line:Show()
    end
    for _, track in ipairs(state.otherTracks) do
        if track.n > 1 then
            local lod, list = PickLod(track, x1, y1, x2, y2, z, OTHER.MAX_LINES)
            for _, spec in ipairs(LinesIn(track, lod, list, x1, y1, x2, y2, true)) do
                spec.track = track
                if spec[5] == "j" and track.pj[spec[6]] then
                    local curve = JumpCurve(spec[1], spec[2], spec[3], spec[4],
                        Style.Jump(track.pj[spec[6]]).bend)
                    for p = 2, #curve do
                        local a, b = curve[p - 1], curve[p]
                        Add(track, { a[1], a[2], b[1], b[2], "j", spec[6], track = track, curve = curve }, "j")
                    end
                else
                    Add(track, spec, spec[5])
                end
            end
        end
    end
    for i = count + 1, state.otherLineCount do
        otherLines[i]:Hide()
    end
    -- Lines cannot be deleted, so with no path shown the whole layer is
    -- hidden, keeping leftover lines out of every zoom frame's work.
    othersLayer:SetShown(count > 0)
    state.otherLineCount, state.otherZoom = count, z
    state.otherDrawn = otherDrawn
end

local function BuildPath()
    local started = debugprofilestop()
    state.perf.lod = 0
    local z = state.zoom
    local x1, y1, x2, y2 = ViewArea(PATH_MARGIN)

    local lod, list
    lod, list, state.lodLevel = PickLod(state, x1, y1, x2, y2, z, MAX_LINES)
    -- Zoomed in, walked and flown lines curve through their points (PathCurve.lua).
    local drawn = ns.CurveLines(LinesIn(state, lod, list, x1, y1, x2, y2, true), z, MAX_LINES)
    state.drawn = drawn
    BuildOtherLines(x1, y1, x2, y2, z)

    local placeStarted = debugprofilestop()
    local shown = CountUpTo(math.floor(state.cur))
    local thickness = LINE_WIDTH / z
    local pb = state.pb
    for i, spec in ipairs(drawn) do
        local line = lines[i]
        if not line then
            line = pathLayer:CreateLine(nil, "ARTWORK")
            lines[i] = line
        end
        line:SetStartPoint("TOPLEFT", pathLayer, spec[1], -spec[2])
        line:SetEndPoint("TOPLEFT", pathLayer, spec[3], -spec[4])
        local mode, band = spec[5], pb[spec[6]]
        -- Lines the filter hides get no tooltip, motes or arc either, nor do
        -- repeats of a boat trip, which the route's first trip stands for.
        local boat = mode == "j" and state.seaTrips[spec[6]]
        spec.hidden = mode == "t" and not ns.FilterShown("flights")
            or mode == "j" and not ns.FilterShown(Style.JUMP_CATEGORY[state.pj[spec[6]]])
            or boat and boat.dupe or false
        -- A jump's own line stays invisible; BuildJumps draws its arc.
        local colorKey = (mode == "j" or spec.hidden) and "none"
            or (mode == "g" or mode == "t") and mode or mode .. band
        if line.colorKey ~= colorKey then
            if colorKey == "none" then
                line:SetColorTexture(0, 0, 0, 0)
            else
                line:SetColorTexture(Style.LineColor(mode, band))
            end
            line.colorKey = colorKey
        end
        line:SetThickness(thickness)
        line:SetShown(i <= shown)
    end
    for i = #drawn + 1, state.lineCount do
        lines[i]:Hide()
    end
    state.lineCount, state.shown, state.lineZoom = #drawn, shown, z
    BuildJumps(drawn, shown, z, { x1, y1, x2, y2 })
    state.built = { x1, y1, x2, y2, zoom = z }
    -- Mote line indexes point into the old list, so respawn them all.
    for _, m in ipairs(motes) do
        m.line = nil
    end
    state.perf.place = debugprofilestop() - placeStarted
    state.perf.build = debugprofilestop() - started
end

local function NeedsPathBuild()
    local built = state.built
    if not built or not ViewInside(built) then return true end
    -- Mid-animation, only rebuild when lines would be missing.
    if state.zoom ~= state.targetZoom then return false end
    return math.abs(math.log(state.zoom / built.zoom)) > REBUILD_ZOOM
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
    -- own colour joins its end to the gliding arrow.
    local spec = gliding and state.shown > 0 and state.drawn[state.shown]
    local mode = state.pm[seq]
    if spec and spec[5] ~= "j" and not spec.hidden and (mode ~= "t" or ns.FilterShown("flights")) then
        lead:SetStartPoint("TOPLEFT", pathLayer, spec[3], -spec[4])
        lead:SetEndPoint("TOPLEFT", pathLayer, x, -y)
        lead:SetColorTexture(Style.LineColor(mode, state.pb[seq]))
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

local function SetOtherThickness()
    local thickness = OTHER.LINE_WIDTH / state.zoom
    for i = 1, state.otherLineCount do
        otherLines[i]:SetThickness(thickness)
    end
    state.otherZoom = state.zoom
end

-- Finds the built lines inside the view, for motes to spawn on.
local function UpdateVisible()
    local visible, drawn = {}, state.drawn
    local x1, y1 = state.ox, state.oy
    local x2, y2 = x1 + state.W / state.zoom, y1 + state.H / state.zoom
    for i = 1, state.lineCount do
        local s = drawn[i]
        if not (math.max(s[1], s[3]) < x1 or math.min(s[1], s[3]) > x2
            or math.max(s[2], s[4]) < y1 or math.min(s[2], s[4]) > y2) then
            visible[#visible + 1] = i
        end
    end
    state.visible = visible
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
    perfText:SetText(("World %.0f ms, decode %.0f ms, setup %.0f ms, build %.1f ms (lod %.1f, place %.1f), terrain %.1f ms, view %.1f ms - %d points, %d lines at detail %d, %d terrain tiles (%d outside zones skipped), zoom %.1f"):format(
        p.world, p.decode, p.setup, p.build, p.lod, p.place, p.terrain, p.view, state.n, state.lineCount,
        state.lodLevel, TerrainCount(), state.tilesSkipped, state.zoom))
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

    -- Resizing every line each frame is most of the cost of zooming, so
    -- while the zoom animates it only happens after a tenth of drift, and
    -- once more when the animation settles.
    local settled = z == state.targetZoom
    if NeedsPathBuild() then
        BuildPath()
    elseif z ~= state.lineZoom and (settled or math.abs(z / state.lineZoom - 1) > 0.1) then
        SetLineThickness()
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
    if z ~= state.otherZoom and (settled or math.abs(z / state.otherZoom - 1) > 0.1) then
        SetOtherThickness()
    end

    state.perf.view = debugprofilestop() - started
    UpdatePerf()
end

-- Timeline -------------------------------------------------------------------------
-- The replay bar under the map: the journey's level bands in their path
-- colours, dim ahead of the replay position and bright behind it, with a
-- tick per level up and a label every 10 levels. scrub is the bar's frame;
-- scrub.track is the coloured strip.

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
    for k = 1, scrub.tickCount do
        local tick = ticks[k]
        tick.tex:SetPoint("CENTER", scrub.track, "LEFT", math.floor(ScrubX(tick.seq)) + 0.5, 0)
        tick.label:SetPoint("TOP", tick.tex, "BOTTOM", 0, -1)
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
    if state.n > 0 then
        for _, e in ipairs(ns.view.events) do
            if e[2] == "lvl" and ns.Range:Has(e[1]) then
                count = count + 1
                local tick = scrub.ticks[count] or NewScrubTick()
                scrub.ticks[count] = tick
                tick.seq = SeqAt(e[1])
                local major = e[6] % SCRUB.LABEL_EVERY == 0
                tick.tex:SetHeight(major and SCRUB.TRACK + 6 or SCRUB.TRACK)
                tick.tex:SetColorTexture(0, 0, 0, major and 0.9 or 0.45)
                tick.tex:Show()
                tick.label:SetText(e[6])
                tick.label:SetShown(major)
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
        GameTooltip:AddLine(("Level %d"):format(LevelAt(t)), ns.LevelColor(LevelAt(t)))
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
    for i = state.shown + 1, count do
        lines[i]:Show()
    end
    for i = count + 1, state.shown do
        lines[i]:Hide()
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
    for _, s in ipairs(state.otherDrawn) do
        local d = DistSqToSegment(x, y, s[1], s[2], s[3], s[4])
        if d < bestD then
            best, bestD = s, d
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
            GameTooltip:AddLine(state.boats[i] or ("%s to %s"):format(ZoneAt(pt[i - 1]), ZoneAt(pt[i])), 1, 1, 1)
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
local function UpdateHover()
    local spec
    if not drag and canvas:IsMouseOver() and MouseFocus() == canvas then
        spec = LineAt(CursorOnCanvas())
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

-- While zoomed in, keep the star on screen during a replay.
local function FollowHead()
    local seq = math.floor(state.cur)
    if state.zoom <= state.minZoom or seq < 1 or not state.headX then return end
    local x, y = state.headX, state.headY
    local fx = (x - state.ox) * state.zoom / state.W
    local fy = (y - state.oy) * state.zoom / state.H
    if fx < 0.1 or fx > 0.9 or fy < 0.1 or fy > 0.9 then
        CenterOn(x, y)
        ApplyView()
    end
end

local function OnUpdate(_, elapsed)
    local moved = false
    -- Jump dots the zoom has shown or hidden fade over a quarter second.
    if state.dotsFading then
        local step, fading = elapsed * 4, false
        for i = 1, jumpDotCount do
            local dot = jumpDots[i]
            local alpha = dot.alpha
            if alpha and alpha ~= dot.target then
                alpha = dot.target > alpha and math.min(dot.target, alpha + step) or math.max(dot.target, alpha - step)
                dot.alpha = alpha
                dot:SetAlpha(alpha)
                fading = fading or alpha ~= dot.target
            end
        end
        state.dotsFading = fading
    end
    -- Ribbon effects flow along the jumps the replay has reached, each piece
    -- carrying on the texture where the one before it left off.
    if state.ribbons[1] then
        state.ribbonClock = state.ribbonClock + elapsed
        local clock = state.ribbonClock
        for _, rb in ipairs(state.ribbons) do
            if rb.jump.visible then
                local u = (rb.from / rb.span - clock * rb.speed) % 1
                rb.line:SetTexCoord(u, u + (rb.to - rb.from) / rb.span, 0, 1)
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
        local ox, oy = drag.ox - (cx - drag.x) / state.zoom, drag.oy - (cy - drag.y) / state.zoom
        if ox ~= state.ox or oy ~= state.oy then
            state.ox, state.oy = ox, oy
            ClampView()
            moved = true
        end
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
    end
    if state.tileQueue then
        ShowQueuedTiles()
    end
    hoverElapsed = hoverElapsed + elapsed
    if hoverElapsed >= HOVER_INTERVAL then
        hoverElapsed = 0
        UpdateHover()
    end

    if state.playing then
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
        FollowHead()
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
    ns.QuestPop:Update(elapsed)
    ns.GuildPop:Update(elapsed)
    ns.LevelPop:Update(elapsed)
    ns.KillPop:Update(elapsed)
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
            -- Zoomed in, the map follows the arrow as the replay does.
            FollowHead()
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
        drag = nil
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
    overlay:SetFrameLevel(content:GetFrameLevel() + 10)

    canvas:SetScript("OnMouseWheel", function(_, delta)
        local factor = delta > 0 and ZOOM_STEP or 1 / ZOOM_STEP
        state.targetZoom = math.max(state.minZoom, math.min(MAX_ZOOM, state.targetZoom * factor))
        state.anchorX, state.anchorY = CursorOnCanvas()
    end)
    canvas:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            local cx, cy = CursorOnCanvas()
            drag = { x = cx, y = cy, ox = state.ox, oy = state.oy }
            state.targetZoom = state.zoom
        end
    end)
    canvas:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            drag = nil
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
    ns.Portals:Attach(pathLayer)

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

    speedButton = CreateButton(44, "1x", function(self)
        state.speedIndex = state.speedIndex % #SPEEDS + 1
        self:SetText(SPEEDS[state.speedIndex] .. "x")
    end)
    speedButton:SetPoint("LEFT", playButton, "RIGHT", 4, 0)

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

function Map:OpenNow()
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
    -- The range's start moves only at midnight (Range.lua), so the cache holds through the day.
    local journey = table.concat({ tostring(view), ns.Range:Key(), ns.Range.from or 0, ns.Range.to or 0, #view.segments,
        ns.Recorder.stored,
        #view.events, view.kills and #view.kills.d or 0, view.totals and view.totals.kills or 0,
        ns.Gathering.changes }, ":")
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
    drag = nil
    state.built = nil
    state.cur = state.n
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
    if last and last.view == ns.view and last.range == ns.Range:Key() then
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
    drag = nil
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
            GameTooltip:AddLine("Back to " .. UnitName("player") .. "'s journey")
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
    drag = nil

    state.cur = SeqAt(t)

    local toContent = state.toContent[continentID]
    if toContent then
        SetZoomNow(math.max(state.zoom, JUMP_ZOOM))
        CenterOn(toContent(x, y))
    end
    ApplyView()
    ApplyCursor()
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
--@end-debug@

ns.Command("motes", "toggle sparkles drifting along the journey map path", function()
    ns.db.motes = not ns.db.motes
    if not ns.db.motes then
        HideMotes()
    end
    ns.Options:Refresh()
    ns.Print("Path sparkles " .. (ns.db.motes and "on" or "off") .. ".")
end)
