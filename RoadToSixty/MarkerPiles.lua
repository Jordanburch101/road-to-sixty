local _, ns = ...

-- Markers that would cover each other on the journey map (issue #19). Worked
-- out on screen at the current zoom each time the map places its markers,
-- so zooming in splits piles again:
-- 1. Markers of one category close together show as one, the newest, with
--    a count: a guild joined and left three times by the bank, two groups
--    formed at a dungeon's door. A pile of groups shows everyone met there
--    once. Hovering a pile fans it out, so each can be hovered (Fan).
-- 2. Markers of different categories that still overlap are pushed apart,
--    a little way from where they belong.
-- Markers come in time order, so a pile's newest is its last.

local MarkerPiles = {}
ns.MarkerPiles = MarkerPiles

-- Sizes in screen pixels.
local MERGE = 18                -- a marker this close to a pile's first joins it
local GAP = 2                   -- kept between markers pushed apart
local MAX_PUSH = 40             -- how far a marker may be pushed from its place
local PUSH_STEPS = 6
local CELL = 100                -- grid for finding neighbours; wider than any marker
local BADGE = 14
-- An open fan: markers wider than WIDE go in a column, FAN_GAP apart, the
-- rest in a ring at least FAN_RADIUS round; lifted FAN_LEVEL frame levels
-- above the map's markers; closing FAN_LINGER seconds after the mouse leaves.
local WIDE, FAN_GAP, FAN_RADIUS, FAN_LEVEL, FAN_LINGER = 40, 4, 30, 40, 0.3
local FAN_SECONDS = 0.18         -- to glide open or shut

-- Reused on each Place: piles and items to spread, and grids to find them
-- by (per category for piles). seen: what the last Place showed; dirty:
-- place again even so (a fan opened or closed).
local piles, items, grids, grid = {}, {}, {}, {}
local seen, dirty = {}, false
-- The open fan: { first = its pile's first marker, members, parent, radius
-- (pixels round its face it covers) }; its lines, and a frame checking for
-- the mouse leaving it.
local fan
local lines = {}
local lineFrame = CreateFrame("Frame")
lineFrame:Hide()
local watcher = CreateFrame("Frame")

local function Badge(m)
    local badge = m.pileBadge
    if not badge then
        badge = CreateFrame("Frame", nil, m)
        badge:SetSize(BADGE, BADGE)
        badge:SetPoint("CENTER", m, "BOTTOMRIGHT", -2, 2)
        badge.disc = badge:CreateTexture(nil, "ARTWORK")
        badge.disc:SetAllPoints()
        badge.disc:SetAtlas("WhiteCircle-RaidBlips")
        badge.disc:SetVertexColor(0.08, 0.06, 0.04, 0.92)
        badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        badge.text:SetPoint("CENTER", 0.5, 0)
        m.pileBadge = badge
    end
    -- Above a group's portraits and a guild's banner.
    badge:SetFrameLevel(m:GetFrameLevel() + 20)
    return badge
end

-- A pile of groups shows everyone in any of them, once each, in the order
-- they were first met; a raid if any of them was.
local function GroupsInfo(members)
    local info, seen = { kind = "party", members = {} }, {}
    for _, m in ipairs(members) do
        local one = ns.Parties:Info(m.group)
        if one.kind == "raid" then info.kind = "raid" end
        for _, entry in ipairs(one.members) do
            if not seen[entry.m[1]] then
                seen[entry.m[1]] = true
                info.members[#info.members + 1] = entry
            end
        end
    end
    return info
end

-- Shows marker m as the face of its pile (members, in time order, it being
-- the last), or of just itself when members is nil.
local function SetPile(m, members)
    local first = members and members[1]
    -- Redone only when the pile changes: the portraits are rebuilt for it.
    if m.pileFirst == first and m.pileCount == (members and #members) then return end
    m.pileFirst, m.pileCount = first, members and #members
    -- Its own copy: Place reuses its tables.
    m.pile = members and { unpack(members) }
    if m.group and m.stack then
        ns.Parties:SetStack(m.stack, members and GroupsInfo(members) or ns.Parties:Info(m.group))
    end
    if members then
        local badge = Badge(m)
        badge.text:SetText(tostring(#members))
        badge:Show()
    elseif m.pileBadge then
        m.pileBadge:Hide()
    end
end

-- Forgets the piles, for markers rebuilt for other events.
function MarkerPiles:Reset(m)
    m.pileFirst, m.pileCount, m.pile = nil, nil, nil
    dirty = true
    if m.pileBadge then
        m.pileBadge:Hide()
    end
    -- Out of an open fan: back among the rest, fully shown.
    if m.fanLevel then
        m:SetFrameLevel(m.fanLevel)
        m.fanLevel = nil
    end
    m:SetAlpha(1)
    if fan and fan.first == m then
        fan = nil
        lineFrame:Hide()
        watcher:SetScript("OnUpdate", nil)
    end
end

-- Fans -----------------------------------------------------------------------------
-- Hovering a pile opens it: its face stays where it is, the others glide
-- out from behind it to places round it (in a column above it when they
-- are wide, like a group's portraits), each with a line back to the spot,
-- and each shows its own tooltip. Once the mouse has been away from it for
-- a moment the fan glides shut, and the pile closes up again.

local function Line(k)
    local line = lines[k]
    if not line then
        line = lineFrame:CreateLine(nil, "ARTWORK")
        line:SetThickness(1.5)
        line:SetColorTexture(1, 1, 1, 1)
        lines[k] = line
    end
    return line
end

-- Eases 0-1, quick at first and settling gently.
local function Ease(f)
    return 1 - (1 - f) ^ 3
end

-- Puts the fan's markers and lines where its opening (fan.open, 0-1) has
-- them: from its face's spot out to their places.
local function ShowFan()
    local e, parent, x, y = Ease(fan.open), fan.parent, fan.x, fan.y
    for k, place in ipairs(fan.places) do
        local m = fan.members[k]
        local px, py = x + (place[1] - x) * e, y + (place[2] - y) * e
        m:ClearAllPoints()
        m:SetPoint("CENTER", parent, "TOPLEFT", px, py)
        m:SetAlpha(e)
        local line = Line(k)
        line:SetStartPoint("TOPLEFT", parent, x, y)
        line:SetEndPoint("TOPLEFT", parent, px, py)
        line:SetAlpha(0.55 * e)
        line:Show()
    end
    for k = #fan.places + 1, #lines do
        lines[k]:Hide()
    end
end

-- Works out the fan's places round its face at x, y (canvas, y up), lifts
-- its markers above the rest, and shows it as far open as it is.
local function LayFan(x, y)
    local members, parent = fan.members, fan.parent
    local face = members[#members]
    local others = #members - 1
    local wide, size = false, 0
    for k = 1, others do
        local w = members[k]:GetWidth()
        wide = wide or w > WIDE
        size = math.max(size, w, members[k]:GetHeight())
    end
    local places = {}
    if wide then
        -- Newest nearest the face.
        local top = y + face:GetHeight() / 2 + FAN_GAP
        for k = others, 1, -1 do
            local h = members[k]:GetHeight()
            places[k] = { x, top + h / 2 }
            top = top + h + FAN_GAP
        end
        fan.radius = top - y
    else
        local r = math.max(FAN_RADIUS, others * (size + FAN_GAP) / (2 * math.pi))
        for k = 1, others do
            -- Newest at the top, the rest round clockwise.
            local a = math.pi / 2 - 2 * math.pi * (others - k) / others
            places[k] = { x + r * math.cos(a), y + r * math.sin(a) }
        end
        fan.radius = r + size / 2
    end
    fan.places, fan.x, fan.y = places, x, y
    lineFrame:SetParent(parent)
    lineFrame:SetAllPoints()
    lineFrame:SetFrameLevel(parent:GetFrameLevel() + FAN_LEVEL - 1)
    lineFrame:Show()
    -- Behind the face, so they come out from under it.
    for k = 1, others do
        local m = members[k]
        m.fanLevel = m.fanLevel or m:GetFrameLevel()
        m:SetFrameLevel(parent:GetFrameLevel() + FAN_LEVEL)
        m:Show()
    end
    face.fanLevel = face.fanLevel or face:GetFrameLevel()
    face:SetFrameLevel(parent:GetFrameLevel() + FAN_LEVEL + 1)
    ShowFan()
end

-- Puts a fan's markers back among the rest.
local function Lower(members)
    for _, m in ipairs(members) do
        if m.fanLevel then
            m:SetFrameLevel(m.fanLevel)
            m.fanLevel = nil
        end
        m:SetAlpha(1)
    end
end

-- Closes the fan at once; the pile closes up again.
local function CloseFan()
    if not fan then return end
    Lower(fan.members or {})
    fan = nil
    dirty = true
    lineFrame:Hide()
    watcher:SetScript("OnUpdate", nil)
    ns.Map:RefreshMarkers()
end

-- Whether the mouse is on the fan: over one of its markers, or inside its circle.
local function OverFan()
    for _, m in ipairs(fan.members or {}) do
        if m:IsVisible() and m:IsMouseOver(4, -4, -4, 4) then return true end
    end
    local face = fan.members and fan.members[#fan.members]
    if not (face and face:IsVisible()) then return false end
    local fx, fy = face:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = face:GetEffectiveScale()
    return (cx / scale - fx) ^ 2 + (cy / scale - fy) ^ 2 < (fan.radius + 12) ^ 2
end

-- Opens the pile whose face is m, then shows m's own tooltip. The fan
-- glides open over FAN_SECONDS, and shut the same way once the mouse has
-- been away FAN_LINGER seconds; back on it while closing, it opens again.
function MarkerPiles:Fan(m)
    if not m.pile then return end
    if fan then CloseFan() end
    fan = { first = m.pile[1], open = 0 }
    dirty = true
    ns.Map:RefreshMarkers()
    local away = 0
    watcher:SetScript("OnUpdate", function(_, elapsed)
        if not fan then return end
        local over = fan.members and OverFan()
        away = over and 0 or away + elapsed
        local opening = away <= FAN_LINGER
        local step = elapsed / FAN_SECONDS
        fan.open = math.max(0, math.min(1, fan.open + (opening and step or -step)))
        if fan.members and fan.places then
            ShowFan()
        end
        if not opening and fan.open == 0 then
            CloseFan()
        end
    end)
    local enter = m:GetScript("OnEnter")
    if enter and not m.pile then
        enter(m)
    end
end

-- A grid cell's number, for cells gx, gy (any whole numbers in range).
local function Cell(gx, gy)
    return gx * 65536 + gy
end

-- Pushes overlapping items[1..count] apart, each at most MAX_PUSH from
-- home. Items in a grid cell are chained through next.
local function Spread(count)
    for _ = 1, PUSH_STEPS do
        wipe(grid)
        for i = 1, count do
            local a = items[i]
            local key = Cell(math.floor(a.x / CELL), math.floor(a.y / CELL))
            a.next, grid[key] = grid[key], a
        end
        local moved = false
        for i = 1, count do
            local a = items[i]
            local gx, gy = math.floor(a.x / CELL), math.floor(a.y / CELL)
            for cx = gx - 1, gx + 1 do
                for cy = gy - 1, gy + 1 do
                    local b = grid[Cell(cx, cy)]
                    while b do
                        if b.i > i then
                            local dx, dy = b.x - a.x, b.y - a.y
                            local ox = a.hw + b.hw + GAP - math.abs(dx)
                            local oy = a.hh + b.hh + GAP - math.abs(dy)
                            if ox > 0 and oy > 0 then
                                -- Apart along the way that needs less.
                                if ox < oy then
                                    local s = dx < 0 and -0.5 or 0.5
                                    a.x, b.x = a.x - s * ox, b.x + s * ox
                                else
                                    local s = dy < 0 and -0.5 or 0.5
                                    a.y, b.y = a.y - s * oy, b.y + s * oy
                                end
                                moved = true
                            end
                        end
                        b = b.next
                    end
                end
            end
        end
        for i = 1, count do
            local a = items[i]
            local dx, dy = a.x - a.hx, a.y - a.hy
            local d = math.sqrt(dx * dx + dy * dy)
            if d > MAX_PUSH then
                a.x, a.y = a.hx + dx / d * MAX_PUSH, a.hy + dy / d * MAX_PUSH
            end
        end
        if not moved then break end
    end
end

-- Places the shown markers (list, in time order, each with its place on
-- the canvas in cx, cy) on parent, piling and spreading them, and hides
-- the ones a pile covers. w and h: the canvas size; markers off it are
-- placed but not spread. The map calls this every frame of a replay, so
-- it does nothing when the same markers are shown at the same places, and
-- reuses its tables.
function MarkerPiles:Place(list, parent, w, h)
    local first, last = list[1], list[#list]
    if not dirty and #list == seen.count and first == seen.first and last == seen.last
        and (not first or (first.cx == seen.x and first.cy == seen.y)) then
        return
    end
    seen.count, seen.first, seen.last = #list, first, last
    seen.x, seen.y = first and first.cx, first and first.cy
    dirty = false

    -- Piles, per category; piles in a grid cell are chained through next.
    local pileCount = 0
    for _, cells in pairs(grids) do
        wipe(cells)
    end
    for _, m in ipairs(list) do
        local key = m.category or "?"
        local cells = grids[key]
        if not cells then
            cells = {}
            grids[key] = cells
        end
        local gx, gy = math.floor(m.cx / MERGE), math.floor(m.cy / MERGE)
        local pile
        for cx = gx - 1, gx + 1 do
            for cy = gy - 1, gy + 1 do
                local p = cells[Cell(cx, cy)]
                while p and not pile do
                    if (p.x - m.cx) ^ 2 + (p.y - m.cy) ^ 2 < MERGE * MERGE then
                        pile = p
                    end
                    p = p.next
                end
            end
        end
        if pile then
            pile.members[#pile.members + 1] = m
        else
            pileCount = pileCount + 1
            pile = piles[pileCount] or { members = {} }
            piles[pileCount] = pile
            wipe(pile.members)
            pile.x, pile.y, pile.members[1] = m.cx, m.cy, m
            local cell = Cell(gx, gy)
            pile.next, cells[cell] = cells[cell], pile
        end
    end

    local count, fanFace = 0, nil
    for p = 1, pileCount do
        local members = piles[p].members
        local face = members[#members]
        -- The open fan shows each of its markers as itself.
        local open = fan and fan.first == members[1] and #members > 1
        if open then
            -- Its own copy: the pile's table is reused by the next Place.
            fan.members, fan.parent, fanFace = { unpack(members) }, parent, face
        end
        for k = 1, #members - 1 do
            SetPile(members[k], nil)
            if not open then
                members[k]:Hide()
            end
        end
        SetPile(face, #members > 1 and not open and members or nil)
        face:Show()
        local x, y = face.cx, face.cy
        local mw, mh = face:GetSize()
        if x > -mw and x < w + mw and -y > -mh and -y < h + mh then
            count = count + 1
            local a = items[count] or {}
            items[count] = a
            a.m, a.i, a.x, a.y, a.hx, a.hy, a.hw, a.hh = face, count, x, y, x, y, mw / 2, mh / 2
        else
            face:ClearAllPoints()
            face:SetPoint("CENTER", parent, "TOPLEFT", x, y)
            if face == fanFace then
                LayFan(x, y)
            end
        end
    end
    Spread(count)
    for i = 1, count do
        local a = items[i]
        a.m:ClearAllPoints()
        a.m:SetPoint("CENTER", parent, "TOPLEFT", a.x, a.y)
        if a.m == fanFace then
            LayFan(a.x, a.y)
        end
    end
    -- A fan whose pile has split or gone (zoomed, replayed back) closes.
    if fan and not fanFace and fan.members then
        Lower(fan.members)
        fan.members = nil
        lineFrame:Hide()
    end
end
