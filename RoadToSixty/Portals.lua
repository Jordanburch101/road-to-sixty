local addonName, ns = ...

-- Portals for hearthstones and teleports on the journey map (issue #18), in
-- place of a line between where the player left and where they arrived: a
-- swirling portal over a dark hole where they left, and a bright one where
-- they arrived, swirling the other way round a star (LOOKS). In the replay the arrow
-- spins down into the first, which flares; a comet with a trail of stars
-- flies the jump's arc while the second portal opens; and the arrow spins up
-- out of the second. Portals of one kind and end that would overlap on screen
-- draw once (a home inn used fifty times is one portal), keeping the earliest, as
-- the replay reaches it first. Hovering a portal lights it and its partner,
-- and a comet flies from the first to the second over and over, so the
-- other end of a jump can be found.
-- Map.lua builds them with the jumps (BuildJumps) and runs the crossing from
-- PlaceHead. Textures from scripts/portal-textures.py, white, tinted here.

local Portals = {}
ns.Portals = Portals

local TRAVEL = "Interface\\AddOns\\" .. addonName .. "\\Travel\\portal-"
local STAR_TEXTURE = "Interface\\Cooldown\\star4"
-- How each end looks, layers bottom to top: { texture, size as a share of
-- the portal }. dark: a deep shade of the colour rather than added light;
-- shade: a softer one; spin: turns with the portal's angle times this;
-- core: breathing once every BREATH seconds; alpha: at most this opaque.
-- Added light on bright parchment soon turns white, so the exit sits on a
-- shade and its core and star keep the colour, dimmed.
local LOOKS = {
    -- Where the player left: a swirl over a dark hole, with a rim.
    from = { { TRAVEL .. "hole", 0.9, dark = true }, { TRAVEL .. "swirl", 1, spin = 1 }, { TRAVEL .. "rim", 1 } },
    -- Where they arrived: brighter, swirling the other way round a
    -- breathing core and a slower star.
    to = { { TRAVEL .. "hole", 0.85, shade = true }, { TRAVEL .. "swirl", 1, spin = -1 }, { TRAVEL .. "rim", 1 },
        { TRAVEL .. "glow", 0.55, core = true, alpha = 0.5 }, { STAR_TEXTURE, 0.6, spin = -0.5, alpha = 0.6 } },
}
local BREATH = 1.2
-- Sizes in screen pixels.
local SIZE = 22
local COMET, STAR = 22, 10
Portals.RADIUS = SIZE / 2       -- the mouse within this far is over a portal
local FLARE = 2.2               -- flare size, as a share of the portal
local GROW = 0.35               -- how much a flaring portal grows
local SPIN = 2                  -- radians a second, four times that while flaring
local OPEN_SECONDS = 0.35
-- Portals show from this zoom, as group markers do (Map.lua's MARKER_ZOOM);
-- further out only the pair the replay is going through shows.
Portals.ZOOM = 2.5
local MERGE = 0.6               -- portals closer than this share of SIZE draw once
local ASIDE = 0.9               -- other portals closer than this share of SIZE gather round their spot
local CLUSTER = 0.9             -- the ring they gather in, as a share of SIZE across
local RELAYOUT = 1.1            -- zoom change, as a factor, that lays the portals out again
-- The replay through a jump, in seconds at normal speed: diving into the
-- first portal and coming out of the second, the flight between taking at
-- least MIN_FLIGHT. ARRIVE: share of the flight after which the second opens.
local DIVE, EMERGE, MIN_FLIGHT = 0.5, 0.5, 0.6
local ARRIVE = 0.65
local TURNS = 2                 -- turns the arrow spins going in and coming out
local TRAIL, TRAIL_GAP = 5, 0.05    -- stars behind the comet, apart by this share of the flight
-- The comet shown while hovering: screen pixels a second, the least and most
-- seconds a flight takes, and the pause after each as the second portal flares.
local HOVER_SPEED, HOVER_FLIGHT, HOVER_PAUSE = 300, { 0.5, 1.5 }, 0.4

local layer
local zoom = 1
-- Portal objects per end ("from", "to"); pools[end][1..used[end]] are in this build.
local pools, used = { from = {}, to = {} }, { from = 0, to = 0 }
local ends = {}                 -- point index of a jump -> { first portal, second portal }
local grid = {}                 -- per end and style, portals by merge cell
local added = {}                -- the jumps given to this build: { jump, style, x1, y1, x2, y2 }
local laidAt = 1                -- the zoom the portals were laid out at
local clock = 0                 -- for the exit's breathing core
local crossing                  -- the jump the replay is going through, see Cross
local hovered                   -- the jump under the mouse: { pair, curve, style, clock }
local comets = {}               -- the replay's and the hover's

-- Eases 0-1 with a little overshoot, for portals opening.
local function Pop(f)
    f = math.max(0, math.min(1, f))
    return 1 + 2.2 * (f - 1) ^ 3 + 1.2 * (f - 1) ^ 2
end

-- Rises and falls back over f from 0 to 1, 0 outside.
local function Bump(f)
    return (f > 0 and f < 1) and math.sin(math.pi * f) or 0
end

-- Position at share f of the way along a curve ({ x, y, distance along }).
local function PointAt(curve, f)
    local d = f * curve[#curve][3]
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        if d <= b[3] then
            local k = (d - a[3]) / math.max(b[3] - a[3], 1e-9)
            return a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k
        end
    end
    local last = curve[#curve]
    return last[1], last[2]
end

local function Lighter(style)
    return math.min(1, style[2] + 0.3), math.min(1, style[3] + 0.3), math.min(1, style[4] + 0.3)
end

-- A comet: a glow with a trail of stars behind it. Place puts it share g of
-- the way along curve, its trail on the part already flown; Hide hides it.
local function NewComet()
    local glow = layer:CreateTexture(nil, "OVERLAY", nil, 7)
    glow:SetTexture(TRAVEL .. "glow")
    glow:SetBlendMode("ADD")
    glow:Hide()
    local stars = {}
    for i = 1, TRAIL do
        local star = layer:CreateTexture(nil, "OVERLAY", nil, 7)
        star:SetTexture(STAR_TEXTURE)
        star:SetBlendMode("ADD")
        star:SetAlpha(1 - i / (TRAIL + 1))
        star:Hide()
        stars[i] = star
    end
    local comet = {}

    function comet:Place(curve, g, style)
        local x, y = PointAt(curve, g)
        glow:SetVertexColor(style[2], style[3], style[4])
        glow:SetSize(COMET / zoom, COMET / zoom)
        glow:ClearAllPoints()
        glow:SetPoint("CENTER", layer, "TOPLEFT", x, -y)
        glow:Show()
        for k, star in ipairs(stars) do
            local f = g - k * TRAIL_GAP
            star:SetShown(f > 0)
            if f > 0 then
                star:SetVertexColor(Lighter(style))
                local sx, sy = PointAt(curve, f)
                local size = (STAR - k) / zoom
                star:SetSize(size, size)
                star:ClearAllPoints()
                star:SetPoint("CENTER", layer, "TOPLEFT", sx, -sy)
            end
        end
        return x, y
    end

    function comet:Hide()
        glow:Hide()
        for _, star in ipairs(stars) do
            star:Hide()
        end
    end
    return comet
end

-- Textures go on the map's path layer, in content units like the jump dots.
function Portals:Attach(parent)
    layer = parent
    comets.replay, comets.hover = NewComet(), NewComet()
end

local function NewPortal(look)
    local p = { layers = {}, look = look, angle = math.random() * 2 * math.pi }
    for i, def in ipairs(look) do
        local tex = layer:CreateTexture(nil, "OVERLAY", nil, 2 + i)
        tex:SetTexture(def[1])
        if not def.dark then
            tex:SetBlendMode("ADD")
        end
        p.layers[i] = tex
    end
    p.flare = layer:CreateTexture(nil, "OVERLAY", nil, 7)
    p.flare:SetTexture(TRAVEL .. "glow")
    p.flare:SetBlendMode("ADD")
    return p
end

local function Hide(p)
    for _, tex in ipairs(p.layers) do
        tex:Hide()
    end
    p.flare:Hide()
    p.drawn = false
end

-- Starts a build at zoom z; Add then places each jump's portals.
function Portals:Begin(z)
    zoom, laidAt = z, z
    used.from, used.to = 0, 0
    wipe(ends)
    wipe(grid)
    wipe(added)
    -- The hovered jump's portals are rebuilt; the map hovers it again
    -- (UpdateHover), and its comet carries on.
    if hovered then
        hovered.pair = nil
    end
end

-- Puts portal p's textures at its place, p.x, p.y.
local function PlaceTextures(p)
    for _, tex in ipairs(p.layers) do
        tex:ClearAllPoints()
        tex:SetPoint("CENTER", layer, "TOPLEFT", p.x, -p.y)
    end
    p.flare:ClearAllPoints()
    p.flare:SetPoint("CENTER", layer, "TOPLEFT", p.x, -p.y)
end

-- Portals of different kinds or ends at one spot (issue #19) gather round
-- it in a small ring, CLUSTER of SIZE across, so each shows and the spot
-- stays in the middle; a portal alone sits on its spot. In build order, a
-- portal within ASIDE of SIZE of a cluster's first joins it.
local function Settle()
    local near, clusters = ASIDE * SIZE / zoom, {}
    for side, pool in pairs(pools) do
        for i = 1, used[side] do
            local p = pool[i]
            local home
            for _, c in ipairs(clusters) do
                if not home and (c[1].ox - p.ox) ^ 2 + (c[1].oy - p.oy) ^ 2 < near * near then
                    home = c
                end
            end
            if home then
                home[#home + 1] = p
            else
                clusters[#clusters + 1] = { p }
            end
        end
    end
    local r = CLUSTER * SIZE / 2 / zoom
    for _, c in ipairs(clusters) do
        local x, y = c[1].ox, c[1].oy
        for k, p in ipairs(c) do
            if #c == 1 then
                p.x, p.y = p.ox, p.oy
            else
                -- The first at the top, the rest round clockwise (y runs down).
                local a = -math.pi / 2 + 2 * math.pi * (k - 1) / #c
                p.x, p.y = x + r * math.cos(a), y + r * math.sin(a)
            end
            PlaceTextures(p)
        end
    end
end

-- A portal of style at x, y for jump, at its end side ("from" or "to"), or
-- the earlier one of the style and side it would overlap (at the place it
-- belongs, ox, oy; x, y is where it is drawn). open: shown at once, without
-- opening.
local function Portal(jump, style, side, x, y, open)
    local near = MERGE * SIZE / zoom
    local key = side .. ":" .. style[1]
    local cells = grid[key]
    if not cells then
        cells = {}
        grid[key] = cells
    end
    local cx, cy = math.floor(x / near), math.floor(y / near)
    for gx = cx - 1, cx + 1 do
        for gy = cy - 1, cy + 1 do
            for _, p in ipairs(cells[gx .. ":" .. gy] or {}) do
                if (p.ox - x) ^ 2 + (p.oy - y) ^ 2 < near * near then
                    return p
                end
            end
        end
    end

    local pool = pools[side]
    used[side] = used[side] + 1
    local p = pool[used[side]] or NewPortal(LOOKS[side])
    pool[used[side]] = p
    -- Drawn at its spot until Settle gathers portals that share one.
    p.jump, p.ox, p.oy, p.x, p.y, p.open = jump, x, y, x, y, open and 1 or 0
    local r, g, b = style[2], style[3], style[4]
    for i, tex in ipairs(p.layers) do
        local def = p.look[i]
        if def.dark then
            tex:SetVertexColor(r * 0.12, g * 0.12, b * 0.12, 0.92)
        elseif def.shade then
            tex:SetVertexColor(r * 0.25, g * 0.25, b * 0.25, 0.75)
        else
            -- A core's alpha is set as it breathes (Draw).
            tex:SetVertexColor(r, g, b, not def.core and def.alpha or 1)
        end
    end
    p.flare:SetVertexColor(style[2], style[3], style[4])
    PlaceTextures(p)
    local cell = cx .. ":" .. cy
    cells[cell] = cells[cell] or {}
    table.insert(cells[cell], p)
    return p
end

-- The portals of a jump from x1, y1 to x2, y2 (content units). jump is
-- BuildJumps' jump, whose visible field says whether the replay has reached
-- it; open: it has already, so its portals show without opening.
function Portals:Add(jump, style, x1, y1, x2, y2, open)
    added[#added + 1] = { jump, style, x1, y1, x2, y2 }
    ends[jump.spec[6]] = { Portal(jump, style, "from", x1, y1, open), Portal(jump, style, "to", x2, y2, open) }
end

-- Ends a build or a layout: gathers portals sharing a spot, and hides the
-- ones it did not use.
function Portals:Finish()
    Settle()
    for side, pool in pairs(pools) do
        for i = used[side] + 1, #pool do
            if pool[i].drawn then
                Hide(pool[i])
            end
        end
    end
end

-- Merging and gathering go by distances on screen, worked out at the
-- zoom the portals were laid out at. Zooming between builds lays them out
-- again once the zoom is RELAYOUT times off, or portals gathered when
-- zoomed out would end up far from their spot when zoomed in.
function Portals:SetZoom(z)
    zoom = z
    if #added == 0 or math.abs(math.log(z / laidAt)) < math.log(RELAYOUT) then return end
    laidAt = z
    used.from, used.to = 0, 0
    wipe(ends)
    wipe(grid)
    for _, a in ipairs(added) do
        local jump, style = a[1], a[2]
        ends[jump.spec[6]] = { Portal(jump, style, "from", a[3], a[4], jump.visible),
            Portal(jump, style, "to", a[5], a[6], jump.visible) }
    end
    self:Finish()
    if hovered then
        hovered.pair = ends[hovered.i]
    end
end

-- Seconds at normal speed the replay spends on a jump total content units long.
function Portals:Seconds(total, pace)
    return DIVE + EMERGE + math.max(MIN_FLIGHT, total / pace)
end

-- The replay at t seconds into jump i (its point index) of style, which
-- takes seconds and follows curve. Returns the phase ("dive", "fly" or
-- "emerge"), the arrow's size (0-1), how far it is spun, and where it is
-- (the comet's place while flying, for the camera). Cross() with no jump
-- ends the crossing.
function Portals:Cross(i, style, t, seconds, curve)
    if not i then
        if crossing then
            crossing = nil
            comets.replay:Hide()
        end
        return
    end
    local pair = ends[i]
    local flight = seconds - DIVE - EMERGE
    local g = (t - DIVE) / flight
    local c = { from = pair and pair[1], to = pair and pair[2] }
    crossing = c
    -- The first flares as the arrow goes in, the second as it comes out.
    c.fromBurst = Bump((t - DIVE * 0.4) / (DIVE * 1.2))
    c.toBurst = Bump((t - DIVE - flight + EMERGE * 0.2) / (EMERGE * 1.2))
    -- The second opens as the comet nears, unless it is an earlier jump's,
    -- already there.
    if c.to and c.to.jump.spec[6] == i and g < ARRIVE then
        c.arriving = c.to
    end

    if t >= DIVE and g < 1 then
        local x, y = comets.replay:Place(curve, g, style)
        return "fly", 0, 0, x, y
    end
    comets.replay:Hide()
    -- Into and out of the portals where they are drawn, which may be off
    -- their spot in a gathering.
    local x1, y1, x2, y2 = self:Ends(i)
    if t < DIVE then
        local f = t / DIVE
        return "dive", 1 - f, f * TURNS * 2 * math.pi, x1 or curve[1][1], y1 or curve[1][2]
    end
    local f = math.min(1, (t - DIVE - flight) / EMERGE)
    local last = curve[#curve]
    return "emerge", f, (1 - f) * TURNS * 2 * math.pi, x2 or last[1], y2 or last[2]
end

-- Where jump i's (its point index) portals are drawn, if it has them in
-- this build: x1, y1, x2, y2 in content units.
function Portals:Ends(i)
    local pair = ends[i]
    if pair then
        return pair[1].x, pair[1].y, pair[2].x, pair[2].y
    end
end

-- Lights the portals of jump i (its point index) of style, along curve, and
-- starts the comet between them; Hover() for none.
function Portals:Hover(i, curve, style)
    if i and ends[i] then
        if hovered and hovered.i == i then
            hovered.pair, hovered.curve = ends[i], curve
        else
            hovered = { i = i, pair = ends[i], curve = curve, style = style, clock = 0 }
        end
    else
        hovered = nil
        comets.hover:Hide()
    end
end

-- The hover's comet, flying again and again; returns how much the second
-- portal flares, as each flight lands.
local function HoverComet(elapsed)
    local h = hovered
    h.clock = h.clock + elapsed
    local length = h.curve[#h.curve][3] * zoom
    local flight = math.max(HOVER_FLIGHT[1], math.min(HOVER_FLIGHT[2], length / HOVER_SPEED))
    local t = h.clock % (flight + HOVER_PAUSE)
    if t < flight then
        comets.hover:Place(h.curve, t / flight, h.style)
        return 0
    end
    comets.hover:Hide()
    return Bump((t - flight) / HOVER_PAUSE)
end

-- One portal's frame: it opens once the replay has reached it, spins, and
-- flares. landing: how much the hovered jump's second portal flares; breath:
-- the exit core's alpha.
local function Draw(p, elapsed, landing, breath)
    local c = crossing
    local shown = p.jump.visible and not (c and c.arriving == p)
    -- Zoomed out, only the pair the replay is going through. A portal
    -- hidden by the zoom stays open, so zooming in does not open it again.
    local inView = zoom >= Portals.ZOOM or c and (c.from == p or c.to == p)
    if not (shown and inView) then
        if not shown then
            p.open = 0
        end
        if p.drawn then
            Hide(p)
        end
        return
    end
    p.open = math.min(1, p.open + elapsed / OPEN_SECONDS)
    local burst = c and (c.from == p and c.fromBurst or c.to == p and c.toBurst) or 0
    local pair = hovered and hovered.pair
    local lit = pair and (pair[2] == p and 0.4 + 0.4 * landing or pair[1] == p and 0.4) or 0
    p.angle = (p.angle - elapsed * SPIN * (1 + 3 * burst)) % (2 * math.pi)
    local size = SIZE / zoom * Pop(p.open) * (1 + GROW * burst)
    for k, tex in ipairs(p.layers) do
        local def = p.look[k]
        local s = size * def[2]
        tex:SetSize(s, s)
        if def.spin then
            tex:SetRotation(p.angle * def.spin)
        end
        if def.core then
            tex:SetAlpha(breath * (def.alpha or 1))
        end
        tex:Show()
    end
    local glow = math.max(burst, lit)
    p.flare:SetShown(glow > 0.01)
    p.flare:SetSize(SIZE * FLARE / zoom, SIZE * FLARE / zoom)
    p.flare:SetAlpha(glow)
    p.drawn = true
end

-- Each frame: the hover's comet, and every portal in the build.
function Portals:Update(elapsed)
    local landing = hovered and HoverComet(elapsed) or 0
    clock = (clock + elapsed / BREATH) % 1
    local breath = 0.7 + 0.3 * math.sin(clock * 2 * math.pi)
    for side, pool in pairs(pools) do
        for i = 1, used[side] do
            Draw(pool[i], elapsed, landing, breath)
        end
    end
end
