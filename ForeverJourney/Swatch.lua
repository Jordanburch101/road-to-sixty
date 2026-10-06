local _, ns = ...

-- /fm swatch: shows candidate Blizzard textures and line styles for the
-- journey map side by side, over terrain, parchment or a dark background,
-- so the map can use art this client actually has. Atlases the client does
-- not know are labelled missing; textures that fail to load show blank.

local CELL_W, CELL_H = 84, 74
local ICON = 32
local LABEL_W = 86
local COLUMNS = 8
local TILE_YARDS = 533.33333
local WORLD_MAP = 947

-- Icon candidates, one row of up to COLUMNS per section: { title, entries }.
-- Entries: { kind, name, label, number = show "14", numberColor = { r, g, b },
-- tint = { r, g, b }, crop = cut a spell or item icon's border,
-- overlay = { kind, name, tint, blend, scale } drawn on top }. kind is
-- "atlas", "file" or "none" (just the number). Empty while no icon choice
-- is open (level ups now use the player frame's level badge).
local SECTIONS = {}

-- Replay timeline candidates, four cells wide, each a still bar 60% played
-- with level bands and ticks. fill: texture for the bands (flat colour if
-- unset); edge: backdrop border file, edgeColor tints it; skill / cast: the
-- classic skill bar or cast bar border around it; atlasTrack: the settings
-- slider track under thinner bands; knob: "minimal" or "spark".
local STATUS_BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local TOOLTIP_EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"
local TOOLTIP_BG = "Interface\\Tooltips\\UI-Tooltip-Background"
local SKILL_BORDER = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-BarBorder"
local CAST_BORDER = "Interface\\CastingBar\\UI-CastingBar-Border-Small"
local TIMELINE_SPAN = 4
local TIMELINE_H = 10
local TIMELINE_PLAYED = 0.6
local TIMELINE_BANDS = {   -- { share of the bar, r, g, b }
    { 0.3, 1, 1, 1 }, { 0.35, 0.12, 1, 0 }, { 0.35, 0.25, 0.6, 1 },
}
local TIMELINE_SAMPLES = {
    { "Current", knob = "minimal" },
    { "Status bar fill", fill = STATUS_BAR, knob = "spark" },
    { "Tooltip frame", fill = STATUS_BAR, edge = TOOLTIP_EDGE, knob = "minimal" },
    { "Gold tooltip frame", fill = STATUS_BAR, edge = TOOLTIP_EDGE, edgeColor = { 1, 0.82, 0 }, knob = "spark" },
    { "Skill bar border", fill = STATUS_BAR, skill = true, knob = "spark" },
    { "Cast bar border", fill = STATUS_BAR, cast = true, knob = "spark" },
    { "Settings slider track", atlasTrack = true, knob = "minimal" },
    { "Tooltip frame, gold labels", fill = STATUS_BAR, edge = TOOLTIP_EDGE, knob = "minimal", goldLabels = true },
}

local TAXI_LINE = "Interface\\TaxiFrame\\UI-Taxi-Line"

-- Each line sample is a list of strokes drawn in order:
-- { thickness, r, g, b, a, texture = optional file, dashes = optional count }
local LINE_SAMPLES = {
    { "Current gold", { { 2, 1, 0.82, 0, 0.9 } } },
    { "Gold, outline", { { 5, 0, 0, 0, 0.55 }, { 2, 1, 0.82, 0, 1 } } },
    { "Soft gold ink", { { 2, 0.93, 0.76, 0.38, 0.85 } } },
    { "Soft gold, outline", { { 4.5, 0.1, 0.06, 0, 0.5 }, { 2, 0.93, 0.76, 0.38, 0.95 } } },
    { "Thin, outline", { { 3.5, 0, 0, 0, 0.5 }, { 1.5, 1, 0.82, 0, 1 } } },
    { "Taxi texture", { { 10, 1, 1, 1, 1, texture = TAXI_LINE } } },
    { "Flight, outline", { { 4.5, 0, 0, 0, 0.5 }, { 2, 0.4, 0.8, 1, 0.95 } } },
    { "Ghost dashed", { { 2, 0.85, 0.85, 0.95, 0.6, dashes = 5 } } },
}

local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local STAR = "Interface\\Cooldown\\star4"
local GOLD = { 0.93, 0.76, 0.38 }
local ARCANE = { 0.7, 0.45, 1 }

-- Animated effect samples, each two cells wide. Options:
-- glow = color (pulsing soft glow under the line), flat = true (glow drawn
-- with a plain wide line, in case the spark texture looks wrong),
-- motes = color (sparkles drifting along), pulse = true (spark running
-- along), dots = true (scrolling dotted line).
local MAGIC_SAMPLES = {
    { "Glow pulse", glow = GOLD },
    { "Glow pulse (flat)", glow = GOLD, flat = true },
    { "Motes", motes = GOLD },
    { "Energy pulse", pulse = true },
    { "Flowing dots", dots = true },
    { "Arcane glow + motes", glow = ARCANE, motes = ARCANE, color = ARCANE },
    { "Glow + motes", glow = GOLD, motes = GOLD },
    { "Glow + pulse", glow = GOLD, pulse = true },
}
local MOTES = 6
local MAGIC_SPAN = 2

-- Jump line candidates (hearthstone, teleport, boat), two cells wide like
-- the magic samples. style: "solid", "dash" or "dots"; arc bends the line;
-- icon is drawn at the middle of it.
local JUMP_COLOR = { 0.3, 1, 0.45 }
local JUMP_SAMPLES = {
    { "Solid + outline", style = "solid" },
    { "Dashes + outline", style = "dash" },
    { "Dots + outline", style = "dots" },
    { "Dashes, arc", style = "dash", arc = true },
    { "Dots, arc", style = "dots", arc = true },
    { "Dots, arc + icon", style = "dots", arc = true, icon = "Innkeeper" },
    { "Dashes, arc + icon", style = "dash", arc = true, icon = "Innkeeper" },
    { "Solid arc + icon", style = "solid", arc = true, icon = "Innkeeper" },
}
local DASH, GAP = 7, 5          -- pixels
local DOT_SIZE, DOT_SPACING = 5, 8
local ARC_BEND = 0.25           -- control point offset, as a share of the length
local OUTLINE = { 0, 0, 0, 0.6 }

local frame, content, backgrounds, backgroundIndex
local animated = {}   -- per-frame updaters for the magic samples
local BACKGROUND_NAMES = { "Terrain", "Parchment", "Dark" }

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- span: how many columns wide; index counts in single columns.
local function CreateCell(index, title, span)
    span = span or 1
    local col, row = (index - 1) % COLUMNS, math.floor((index - 1) / COLUMNS)
    local cell = CreateFrame("Frame", nil, content)
    cell:SetSize(CELL_W * span, CELL_H)
    cell:SetPoint("TOPLEFT", LABEL_W + col * CELL_W, -row * CELL_H)
    cell.label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.label:SetPoint("TOP", 0, -ICON - 12)
    cell.label:SetWidth(CELL_W * span - 4)
    cell.label:SetText(title)
    return cell
end

local function AddIconCell(index, entry)
    local kind, name = entry[1], entry[2]
    local short = entry.label or name:match("([^\\]+)$")
    local cell = CreateCell(index, short)
    local tex = cell:CreateTexture(nil, "ARTWORK")
    tex:SetSize(ICON, ICON)
    tex:SetPoint("TOP", 0, -6)

    local ok
    if kind == "none" then
        ok = true
    elseif kind == "atlas" then
        ok = HasAtlas(name)
        if ok then tex:SetAtlas(name) end
    else
        ok = tex:SetTexture(name) ~= false
    end
    if entry.tint then
        tex:SetVertexColor(unpack(entry.tint))
    end
    if entry.crop then
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    local over = entry.overlay
    if ok and over then
        local layer = cell:CreateTexture(nil, "OVERLAY")
        local size = ICON * (over.scale or 1)
        layer:SetSize(size, size)
        layer:SetPoint("CENTER", tex)
        if over[1] == "atlas" then
            ok = HasAtlas(over[2])
            if ok then layer:SetAtlas(over[2]) end
        else
            layer:SetTexture(over[2])
        end
        if over.tint then
            layer:SetVertexColor(unpack(over.tint))
        end
        if over.blend then
            layer:SetBlendMode(over.blend)
        end
        name = name .. " + " .. over[2]
    end
    if not ok then
        cell.label:SetText("|cffff4040" .. short .. "\n(missing)|r")
    elseif entry.number then
        local number = cell:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        number:SetDrawLayer("OVERLAY", 7)
        number:SetPoint("CENTER", tex)
        number:SetText("14")
        number:SetTextColor(unpack(entry.numberColor or { 1, 1, 1 }))
        number:SetShadowOffset(1, -1)
    end

    -- Hover shows the full name and kind; click copies the name.
    cell:EnableMouse(true)
    cell:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(name)
        GameTooltip:AddLine(kind, 1, 1, 1)
        GameTooltip:AddLine("Click to copy", 0.5, 1, 0.5)
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", GameTooltip_Hide)
    cell:SetScript("OnMouseUp", function()
        ns.ShowCopyBox(name)
    end)
end

local function AddStroke(cell, stroke)
    local x1, y1, x2, y2 = 8, -ICON - 4, CELL_W - 8, -6
    local dashes = stroke.dashes or 1
    for d = 0, dashes - 1 do
        local f1, f2 = d / dashes, (d + (stroke.dashes and 0.55 or 1)) / dashes
        local line = cell:CreateLine(nil, "ARTWORK")
        line:SetThickness(stroke[1])
        line:SetStartPoint("TOPLEFT", cell, x1 + (x2 - x1) * f1, y1 + (y2 - y1) * f1)
        line:SetEndPoint("TOPLEFT", cell, x1 + (x2 - x1) * f2, y1 + (y2 - y1) * f2)
        if stroke.texture then
            line:SetTexture(stroke.texture)
            line:SetVertexColor(stroke[2], stroke[3], stroke[4], stroke[5])
        else
            line:SetColorTexture(stroke[2], stroke[3], stroke[4], stroke[5])
        end
    end
end

local function AddLineCell(index, sample)
    local cell = CreateCell(index, sample[1])
    for _, stroke in ipairs(sample[2]) do
        AddStroke(cell, stroke)
    end
end

local function NewLine(parent, x1, y1, x2, y2, thickness)
    local line = parent:CreateLine(nil, "ARTWORK")
    line:SetThickness(thickness)
    line:SetStartPoint("TOPLEFT", parent, x1, y1)
    line:SetEndPoint("TOPLEFT", parent, x2, y2)
    return line
end

-- Breathing alpha, run by the client rather than per-frame Lua.
local function Pulse(region, from, to, seconds)
    local group = region:CreateAnimationGroup()
    group:SetLooping("BOUNCE")
    local alpha = group:CreateAnimation("Alpha")
    alpha:SetFromAlpha(from)
    alpha:SetToAlpha(to)
    alpha:SetDuration(seconds)
    alpha:SetSmoothing("IN_OUT")
    group:Play()
end

local function AddMagicCell(index, sample)
    local cell = CreateCell(index, sample[1], MAGIC_SPAN)
    local w = CELL_W * MAGIC_SPAN
    local x1, y1, x2, y2 = 10, -ICON + 2, w - 10, -12
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    local color = sample.color or GOLD

    -- Glow in its own frame so one animation pulses it, under everything else.
    local top = CreateFrame("Frame", nil, cell)
    top:SetAllPoints()
    top:SetFrameLevel(cell:GetFrameLevel() + 2)

    if sample.glow then
        local glowFrame = CreateFrame("Frame", nil, cell)
        glowFrame:SetAllPoints()
        glowFrame:SetFrameLevel(cell:GetFrameLevel() + 1)
        local glow = NewLine(glowFrame, x1, y1, x2, y2, sample.flat and 7 or 14)
        local r, g, b = unpack(sample.glow)
        if sample.flat then
            glow:SetColorTexture(r, g, b, 0.35)
        else
            glow:SetTexture(SPARK)
            -- The spark fades left to right; turn it so it fades across the line.
            if not pcall(glow.SetTexCoord, glow, 0, 0, 1, 0, 0, 1, 1, 1) then
                cell.label:SetText(sample[1] .. "\n|cffff4040(no rotated tex coords)|r")
            end
            glow:SetVertexColor(r, g, b, 1)
        end
        glow:SetBlendMode("ADD")
        Pulse(glowFrame, 0.35, 1, 1.2)
    end

    if sample.dots then
        NewLine(top, x1, y1, x2, y2, 4):SetColorTexture(0, 0, 0, 0.45)
        local dots = NewLine(top, x1, y1, x2, y2, 10)
        dots:SetTexture(TAXI_LINE, "REPEAT", "REPEAT")
        dots:SetVertexColor(color[1], color[2], color[3], 1)
        local repeats = length / 24
        local offset = 0
        table.insert(animated, function(elapsed)
            offset = (offset - elapsed * 0.8) % 1
            dots:SetTexCoord(offset, offset + repeats, 0, 1)
        end)
    else
        NewLine(top, x1, y1, x2, y2, 2):SetColorTexture(color[1], color[2], color[3], 0.95)
    end

    if sample.motes then
        local r, g, b = unpack(sample.motes)
        local motes = {}
        for i = 1, MOTES do
            local tex = top:CreateTexture(nil, "OVERLAY")
            tex:SetTexture(STAR)
            tex:SetBlendMode("ADD")
            tex:SetVertexColor(r, g, b)
            motes[i] = {
                tex = tex,
                phase = (i - 1) / MOTES + math.random() * 0.1,
                wobble = math.random() * 6.28,
            }
        end
        table.insert(animated, function(elapsed)
            for _, mote in ipairs(motes) do
                mote.phase = (mote.phase + elapsed * 0.18) % 1
                local f = mote.phase
                local side = math.sin(f * 12 + mote.wobble) * 3
                local px, py = x1 + dx * f - dy / length * side, y1 + dy * f + dx / length * side
                local size = 6 + 6 * math.sin(f * math.pi)
                mote.tex:SetSize(size, size)
                mote.tex:SetAlpha(math.sin(f * math.pi))
                mote.tex:SetPoint("CENTER", cell, "TOPLEFT", px, py)
            end
        end)
    end

    if sample.pulse then
        local spark = top:CreateTexture(nil, "OVERLAY")
        spark:SetTexture(SPARK)
        spark:SetBlendMode("ADD")
        spark:SetSize(16, 24)
        spark:SetRotation(math.atan2(-dy, dx))
        local f = 0
        table.insert(animated, function(elapsed)
            f = (f + elapsed * 0.6) % 1.3
            spark:SetShown(f <= 1)
            spark:SetPoint("CENTER", cell, "TOPLEFT", x1 + dx * f, y1 + dy * f)
        end)
    end
end

-- Points along a straight or bent line from (x1, y1) to (x2, y2): a list of
-- { x, y } with the distance along the line in [3].
local function JumpCurve(x1, y1, x2, y2, arc)
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    -- Bend towards the top of the screen (y is negative downwards here).
    local cx, cy = (x1 + x2) / 2 - dy / length * length * ARC_BEND, (y1 + y2) / 2 + math.abs(dx) / length * length * ARC_BEND
    local steps = arc and 24 or 1
    local points, along = {}, 0
    for i = 0, steps do
        local f = i / steps
        local x, y
        if arc then
            x = (1 - f) ^ 2 * x1 + 2 * (1 - f) * f * cx + f * f * x2
            y = (1 - f) ^ 2 * y1 + 2 * (1 - f) * f * cy + f * f * y2
        else
            x, y = x1 + dx * f, y1 + dy * f
        end
        if i > 0 then
            local p = points[i]
            along = along + math.sqrt((x - p[1]) ^ 2 + (y - p[2]) ^ 2)
        end
        points[i + 1] = { x, y, along }
    end
    return points
end

-- Position at distance d along the curve.
local function PointAlong(points, d)
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if d <= b[3] then
            local f = (d - a[3]) / math.max(b[3] - a[3], 1e-6)
            return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
        end
    end
    local last = points[#points]
    return last[1], last[2]
end

local function AddJumpCell(index, sample)
    local cell = CreateCell(index, sample[1], MAGIC_SPAN)
    local points = JumpCurve(12, -ICON + 2, CELL_W * MAGIC_SPAN - 12, -10, sample.arc)
    local total = points[#points][3]
    local r, g, b = unpack(JUMP_COLOR)

    local function Stroke(ax, ay, bx, by)
        NewLine(cell, ax, ay, bx, by, 5):SetColorTexture(unpack(OUTLINE))
        NewLine(cell, ax, ay, bx, by, 2.5):SetColorTexture(r, g, b, 1)
    end

    if sample.style == "solid" then
        for i = 2, #points do
            Stroke(points[i - 1][1], points[i - 1][2], points[i][1], points[i][2])
        end
    elseif sample.style == "dash" then
        local d = 0
        while d < total do
            local ax, ay = PointAlong(points, d)
            local bx, by = PointAlong(points, math.min(d + DASH, total))
            Stroke(ax, ay, bx, by)
            d = d + DASH + GAP
        end
    else
        for d = 0, total, DOT_SPACING do
            local x, y = PointAlong(points, d)
            local back = cell:CreateTexture(nil, "ARTWORK")
            back:SetAtlas("WhiteCircle-RaidBlips")
            back:SetVertexColor(unpack(OUTLINE))
            back:SetSize(DOT_SIZE + 2, DOT_SIZE + 2)
            back:SetPoint("CENTER", cell, "TOPLEFT", x, y)
            local dot = cell:CreateTexture(nil, "OVERLAY")
            dot:SetAtlas("WhiteCircle-RaidBlips")
            dot:SetVertexColor(r, g, b)
            dot:SetSize(DOT_SIZE, DOT_SIZE)
            dot:SetPoint("CENTER", cell, "TOPLEFT", x, y)
        end
    end

    if sample.icon then
        local x, y = PointAlong(points, total / 2)
        local icon = cell:CreateTexture(nil, "OVERLAY", nil, 7)
        icon:SetAtlas(sample.icon)
        icon:SetSize(18, 18)
        icon:SetPoint("CENTER", cell, "TOPLEFT", x, y)
    end
end

local function AddTimelineCell(index, sample)
    local cell = CreateCell(index, sample[1], TIMELINE_SPAN)
    local w = CELL_W * TIMELINE_SPAN - 40
    local bar = CreateFrame("Frame", nil, cell)
    bar:SetSize(w, TIMELINE_H)
    bar:SetPoint("TOP", 0, -14)
    local missing

    if sample.edge then
        local box = CreateFrame("Frame", nil, cell, "BackdropTemplate")
        box:SetPoint("TOPLEFT", bar, -4, 4)
        box:SetPoint("BOTTOMRIGHT", bar, 4, -4)
        box:SetFrameLevel(bar:GetFrameLevel() + 1)
        box:SetBackdrop({ edgeFile = sample.edge, edgeSize = 10 })
        if sample.edgeColor then
            box:SetBackdropBorderColor(unpack(sample.edgeColor))
        else
            box:SetBackdropBorderColor(0.6, 0.6, 0.6)
        end
        local bg = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        bg:SetPoint("TOPLEFT", -2, 2)
        bg:SetPoint("BOTTOMRIGHT", 2, -2)
        bg:SetTexture(TOOLTIP_BG)
        bg:SetVertexColor(0, 0, 0, 0.9)
    elseif sample.skill then
        local border = bar:CreateTexture(nil, "OVERLAY")
        border:SetTexture(SKILL_BORDER)
        border:SetSize(w + 12, TIMELINE_H * 2.2)
        border:SetPoint("CENTER")
    elseif sample.cast then
        -- As the target frame's cast bar: a 150x10 bar in a 197x49 border.
        local border = bar:CreateTexture(nil, "OVERLAY")
        border:SetTexture(CAST_BORDER)
        border:SetSize(w * 197 / 150, 49 * TIMELINE_H / 10)
        border:SetPoint("TOP", 0, 20 * TIMELINE_H / 10)
    elseif not sample.atlasTrack then
        local edge = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        edge:SetPoint("TOPLEFT", -1, 1)
        edge:SetPoint("BOTTOMRIGHT", 1, -1)
        edge:SetColorTexture(0, 0, 0, 0.9)
    end

    local bandH = TIMELINE_H
    if sample.atlasTrack then
        local function Part(atlas)
            local tex = bar:CreateTexture(nil, "BACKGROUND")
            if HasAtlas(atlas) then
                tex:SetAtlas(atlas, true)
            else
                missing = atlas
            end
            return tex
        end
        local left, middle, right = Part("Minimal_SliderBar_Left"),
            Part("_Minimal_SliderBar_Middle"), Part("Minimal_SliderBar_Right")
        left:SetPoint("LEFT", -4, 0)
        right:SetPoint("RIGHT", 4, 0)
        middle:SetPoint("LEFT", left, "RIGHT")
        middle:SetPoint("RIGHT", right, "LEFT")
        bandH = 4
    end

    -- Bands: dim ahead of the knob, bright behind it.
    local x = 0
    for _, band in ipairs(TIMELINE_BANDS) do
        local bw = band[1] * w
        local played = math.max(0, math.min(bw, TIMELINE_PLAYED * w - x))
        for _, part in ipairs({ { x, bw, 0.35 }, { x, played, 1 } }) do
            if part[2] > 0.5 then
                local tex = bar:CreateTexture(nil, part[3] == 1 and "ARTWORK" or "BORDER")
                tex:SetPoint("LEFT", part[1], 0)
                tex:SetSize(part[2], bandH)
                local k = part[3]
                if sample.fill then
                    tex:SetTexture(sample.fill)
                    tex:SetVertexColor(band[2] * k, band[3] * k, band[4] * k)
                else
                    tex:SetColorTexture(band[2] * k, band[3] * k, band[4] * k)
                end
            end
        end
        x = x + bw
    end

    -- Ticks for levels 2-30, labels at 10, 20 and 30.
    for level = 2, 30 do
        local tx = math.floor((level - 1) / 29 * w) + 0.5
        local major = level % 10 == 0
        local tick = bar:CreateTexture(nil, "OVERLAY")
        tick:SetSize(1, major and bandH + 6 or bandH)
        tick:SetPoint("CENTER", bar, "LEFT", tx, 0)
        tick:SetColorTexture(0, 0, 0, major and 0.9 or 0.45)
        if major then
            local label = cell:CreateFontString(nil, "OVERLAY",
                sample.goldLabels and "GameFontNormalSmall" or "GameFontHighlightSmall")
            label:SetPoint("TOP", tick, "BOTTOM", 0, -2)
            label:SetText(tostring(level))
            if not sample.goldLabels then
                label:SetTextColor(ns.LevelColor(level))
            end
        end
    end

    local knobFrame = CreateFrame("Frame", nil, cell)
    knobFrame:SetAllPoints(bar)
    knobFrame:SetFrameLevel(bar:GetFrameLevel() + 3)
    local knob = knobFrame:CreateTexture(nil, "OVERLAY")
    knob:SetPoint("CENTER", bar, "LEFT", TIMELINE_PLAYED * w, 0)
    if sample.knob == "spark" then
        knob:SetTexture(SPARK)
        knob:SetBlendMode("ADD")
        knob:SetSize(16, TIMELINE_H * 3)
    else
        knob:SetSize(16, 16)
        if not knob:SetAtlas("Minimal_SliderBar_Button") then
            missing = "Minimal_SliderBar_Button"
        end
    end
    if missing then
        cell.label:SetText(sample[1] .. " |cffff4040(" .. missing .. " missing)|r")
    end
end

local function AddSectionLabel(row, text)
    local label = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 4, -row * CELL_H - 18)
    label:SetText(text)
end

-- Terrain: minimap tiles around the player, or none if not outdoors.
local function TerrainBackground(parent, w, h)
    local c, x, y = ns.GetWorldPosition()
    local ids = c and ns.MinimapTiles[ns.MinimapDirs[c] or ""]
    local textures = {}
    if not ids then return textures end
    local col, row = math.floor(32 - y / TILE_YARDS), math.floor(32 - x / TILE_YARDS)
    local size = 192
    for ty = 0, math.ceil(h / size) - 1 do
        for tx = 0, math.ceil(w / size) - 1 do
            local fileID = ids[(col - 1 + tx) .. "_" .. (row - 1 + ty)]
            if fileID then
                local tex = parent:CreateTexture(nil, "BACKGROUND", nil, -7)
                tex:SetTexture(fileID)
                tex:SetSize(size, size)
                tex:SetPoint("TOPLEFT", tx * size, -ty * size)
                textures[#textures + 1] = tex
            end
        end
    end
    return textures
end

-- Parchment: one world map art tile, stretched.
local function ParchmentBackground(parent)
    local art = C_Map.GetMapArtLayerTextures(WORLD_MAP, 1)
    local tex = parent:CreateTexture(nil, "BACKGROUND", nil, -7)
    tex:SetAllPoints()
    if art and art[6] then
        tex:SetTexture(art[6])
    else
        tex:SetColorTexture(0.45, 0.36, 0.22)
    end
    return { tex }
end

local function ShowBackground(index)
    backgroundIndex = index
    for i, textures in ipairs(backgrounds) do
        for _, tex in ipairs(textures) do
            tex:SetShown(i == index)
        end
    end
    frame.backgroundButton:SetText("Background: " .. BACKGROUND_NAMES[index])
end

local function CreateWindow()
    local rows = math.ceil(#TIMELINE_SAMPLES * TIMELINE_SPAN / COLUMNS)
    for _, section in ipairs(SECTIONS) do
        rows = rows + math.ceil(#section[2] / COLUMNS)
    end
    rows = rows + math.ceil(#LINE_SAMPLES / COLUMNS)
    rows = rows + math.ceil(#MAGIC_SAMPLES * MAGIC_SPAN / COLUMNS)
    rows = rows + math.ceil(#JUMP_SAMPLES * MAGIC_SPAN / COLUMNS)
    local w, h = LABEL_W + COLUMNS * CELL_W, rows * CELL_H

    frame = CreateFrame("Frame", "ForeverModSwatchFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(w + 24, h + 68)
    -- Shrink to fit the screen, as the window can be taller than it.
    frame:SetScale(math.min(1, UIParent:GetHeight() * 0.95 / (h + 68)))
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "ForeverModSwatchFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Journey map art candidates")

    content = CreateFrame("Frame", nil, frame)
    content:SetSize(w, h)
    content:SetPoint("TOPLEFT", 12, -30)
    content:SetClipsChildren(true)

    local dark = content:CreateTexture(nil, "BACKGROUND", nil, -8)
    dark:SetAllPoints()
    dark:SetColorTexture(0.05, 0.05, 0.05)

    local row = 0
    AddSectionLabel(row, "Timeline")
    for i, sample in ipairs(TIMELINE_SAMPLES) do
        AddTimelineCell(row * COLUMNS + (i - 1) * TIMELINE_SPAN + 1, sample)
    end
    row = row + math.ceil(#TIMELINE_SAMPLES * TIMELINE_SPAN / COLUMNS)
    for _, section in ipairs(SECTIONS) do
        AddSectionLabel(row, section[1])
        for i, entry in ipairs(section[2]) do
            AddIconCell(row * COLUMNS + i, entry)
        end
        row = row + math.ceil(#section[2] / COLUMNS)
    end
    AddSectionLabel(row, "Lines")
    for i, sample in ipairs(LINE_SAMPLES) do
        AddLineCell(row * COLUMNS + i, sample)
    end
    row = row + math.ceil(#LINE_SAMPLES / COLUMNS)
    AddSectionLabel(row, "Magic")
    for i, sample in ipairs(MAGIC_SAMPLES) do
        AddMagicCell(row * COLUMNS + (i - 1) * MAGIC_SPAN + 1, sample)
    end
    row = row + math.ceil(#MAGIC_SAMPLES * MAGIC_SPAN / COLUMNS)
    AddSectionLabel(row, "Jumps")
    for i, sample in ipairs(JUMP_SAMPLES) do
        AddJumpCell(row * COLUMNS + (i - 1) * MAGIC_SPAN + 1, sample)
    end
    frame:SetScript("OnUpdate", function(_, elapsed)
        for _, update in ipairs(animated) do
            update(elapsed)
        end
    end)

    backgrounds = { TerrainBackground(content, w, h), ParchmentBackground(content), {} }

    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(170, 22)
    button:SetPoint("BOTTOMLEFT", 12, 10)
    button:SetScript("OnClick", function()
        ShowBackground(backgroundIndex % #BACKGROUND_NAMES + 1)
    end)
    frame.backgroundButton = button

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", -14, 16)
    hint:SetText("Hover an icon for its full name")

    ShowBackground(#backgrounds[1] > 0 and 1 or 2)
end

ns.Command("swatch", "compare candidate map icons and line styles", function()
    if not frame then
        CreateWindow()
    end
    frame:Show()
end)
