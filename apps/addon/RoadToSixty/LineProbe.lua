local _, ns = ...

-- /rts lineprobe [lines]: what a zooming map's lines cost on this client,
-- to decide how many the journey map can afford and whether resizing them
-- (Line:SetThickness, PathLines.lua) can go. A window draws a random path
-- of that many lines (3000 unless given) on a content frame that zooms in
-- and out without stopping, as the journey map's does, and times each way
-- of drawing it for a few seconds:
--
--   still     no zoom: the frame time with the lines just drawn
--   resize    zooming, every line resized every frame (the map before)
--   noresize  zooming, no line resized (wrong widths: the client's own
--             cost of moving the lines as the content scales)
--   hidden    zooming, every line hidden one by one (do hidden lines cost?)
--   anchored  zooming, lines on a frame that doesn't scale, each end
--             anchored to a small clear texture on the content: the width
--             stays in screen pixels with no call a frame. Check by eye that
--             these lines follow the zoom and keep their width.
--
-- For each it prints the mean and worst frame time (the time between
-- frames, which includes the client's layout and drawing) and the Lua time
-- a frame spent in our calls. Run it with the journey map closed.

local LINES = 3000
local W, H = 640, 420               -- the canvas, in pixels
local SIZE = 640                    -- the content, in content units
local SECONDS = 4                   -- each mode; the first half second is left out
local MODES = { "still", "resize", "noresize", "hidden", "anchored" }

local frame, canvas, content, onContent, flat, points
local lines, flatLines, dots = {}, {}, {}
local run

local function Build(n)
    for _, line in ipairs(lines) do line:Hide() end
    for _, line in ipairs(flatLines) do line:Hide() end
    -- A random walk, kept inside the content, reaching its corners.
    local x, y, angle = SIZE / 2, SIZE / 2, 0
    local xs, ys = { x }, { y }
    for i = 1, n do
        angle = angle + (math.random() - 0.5) * 1.2
        local step = 2 + math.random() * 6
        x = math.max(0, math.min(SIZE, x + math.cos(angle) * step))
        y = math.max(0, math.min(SIZE, y + math.sin(angle) * step))
        if x == 0 or x == SIZE or y == 0 or y == SIZE then angle = angle + math.pi / 2 end
        xs[i + 1], ys[i + 1] = x, y
    end
    for i = 1, n + 1 do
        local dot = dots[i] or points:CreateTexture(nil, "ARTWORK")
        dots[i] = dot
        dot:SetColorTexture(1, 1, 1, 0)
        dot:SetSize(0.5, 0.5)
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", points, "TOPLEFT", xs[i], -ys[i])
        dot:Show()
    end
    for i = 1, n do
        local line = lines[i] or onContent:CreateLine(nil, "ARTWORK")
        lines[i] = line
        line:SetStartPoint("TOPLEFT", onContent, xs[i], -ys[i])
        line:SetEndPoint("TOPLEFT", onContent, xs[i + 1], -ys[i + 1])
        line:SetColorTexture(0.2, 0.8, 1, 0.9)
        line:SetThickness(2)
        line:Show()
        local fl = flatLines[i] or flat:CreateLine(nil, "ARTWORK")
        flatLines[i] = fl
        fl:SetStartPoint("CENTER", dots[i], 0, 0)
        fl:SetEndPoint("CENTER", dots[i + 1], 0, 0)
        fl:SetColorTexture(1, 0.7, 0.2, 0.9)
        fl:SetThickness(2)
        fl:Show()
    end
end

local function SetZoom(z)
    content:SetScale(z)
    -- Centred: the content coordinate at the view's top left, in content units.
    content:ClearAllPoints()
    content:SetPoint("TOPLEFT", canvas, "TOPLEFT", -(SIZE / 2 - W / (2 * z)), SIZE / 2 - H / (2 * z))
end

-- Sets up mode k of the run.
local function StartMode(k)
    local mode = MODES[k]
    run.k, run.mode, run.t, run.frames, run.total, run.worst, run.lua = k, mode, 0, 0, 0, 0, 0
    onContent:SetShown(mode ~= "anchored")
    flat:SetShown(mode == "anchored")
    points:SetShown(mode == "anchored")
    for i = 1, run.n do
        lines[i]:SetShown(mode ~= "hidden")
        lines[i]:SetThickness(2)
    end
    SetZoom(1)
    frame.title:SetText(("Line probe: %s, %d lines"):format(mode, run.n))
end

local function Report()
    local mean = run.total / math.max(1, run.frames)
    local lua = run.lua / math.max(1, run.frames)
    local text = ("%-9s frame %.2f ms (worst %.2f), %.0f fps; Lua %.3f ms a frame"):format(
        run.mode, mean, run.worst, 1000 / math.max(mean, 0.01), lua)
    if run.mode == "resize" then
        text = text .. (" (%.2f us a SetThickness)"):format(lua * 1000 / run.n)
    end
    ns.Print(text)
    run.lines[#run.lines + 1] = text
    frame.results:SetText(table.concat(run.lines, "\n"))
end

local function OnUpdate(_, elapsed)
    if not run then return end
    run.t = run.t + elapsed
    if run.t > 0.5 then
        run.frames, run.total = run.frames + 1, run.total + elapsed * 1000
        run.worst = math.max(run.worst, elapsed * 1000)
    end
    local started = debugprofilestop()
    if run.mode ~= "still" then
        local z = 2 ^ (1 + math.sin(run.t * 2.5))     -- 1 to 4 and back, about twice a second
        SetZoom(z)
        if run.mode == "resize" then
            local thickness = 2 / z
            for i = 1, run.n do
                lines[i]:SetThickness(thickness)
            end
        end
    end
    if run.t > 0.5 then
        run.lua = run.lua + debugprofilestop() - started
    end
    if run.t >= SECONDS then
        Report()
        if run.k < #MODES then
            StartMode(run.k + 1)
        else
            run = nil
            ns.Print("Line probe done.")
        end
    end
end

local function Create()
    frame = CreateFrame("Frame", "RoadToSixtyLineProbe", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(W + 24, H + 150)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    canvas = CreateFrame("Frame", nil, frame)
    canvas:SetSize(W, H)
    canvas:SetPoint("TOPLEFT", 12, -30)
    canvas:SetClipsChildren(true)
    local back = canvas:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0.05, 0.05, 0.08, 1)
    content = CreateFrame("Frame", nil, canvas)
    content:SetSize(SIZE, SIZE)
    onContent = CreateFrame("Frame", nil, content)
    onContent:SetAllPoints()
    points = CreateFrame("Frame", nil, content)
    points:SetAllPoints()
    -- Not a child of content, so its lines don't scale; above it.
    flat = CreateFrame("Frame", nil, canvas)
    flat:SetAllPoints()
    flat:SetFrameLevel(content:GetFrameLevel() + 5)
    frame.results = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.results:SetPoint("TOPLEFT", canvas, "BOTTOMLEFT", 0, -8)
    frame.results:SetJustifyH("LEFT")
    frame:SetScript("OnUpdate", OnUpdate)
    frame:SetScript("OnHide", function() run = nil end)
end

ns.Command("lineprobe", "time zooming lines drawn several ways: resized, not, hidden, anchored [lines] (developer)", function(arg)
    if not frame then Create() end
    local n = math.max(1, math.min(20000, tonumber(arg) or LINES))
    Build(n)
    frame:Show()
    run = { n = n, lines = {} }
    ns.Print(("Line probe: %d lines, %d modes of %d s each."):format(n, #MODES, SECONDS))
    StartMode(1)
end)
