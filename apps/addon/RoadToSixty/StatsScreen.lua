local addonName, ns = ...

-- The Stats screen (issue #83): a mode of the journey map window, beside
-- Map and Gear (Screens.lua), that puts the journey's numbers where the map
-- and the side panel were. Everything on it counts only what is inside the
-- map's date range (Range.lua), up to the replay's moment, so the numbers
-- grow as the replay plays. The numbers come from Stats.lua.
--
-- Built so far:
--   The headline row: time played (with all time, the game's /played at
--   that moment, and the time recorded under it), yards travelled, kills,
--   quests, deaths, gold, dungeons (battlegrounds under them), and the
--   range and moment it covers.
--   The level chart: levels 1 to the cap (60, 70 on the Anniversary
--   realms) along the bottom, so a bar keeps its width and place on any
--   character, and a bar for each level with a snapshot, in the map's level
--   colours, for time, kills, deaths, gold or XP an hour; levels outside
--   the range or past the replay's moment are dimmed. Hovering a bar shows
--   that level in the card beside it (else the card shows the replay's
--   level); clicking one moves the replay to its level up.
--   Records: ten bests and worsts inside the window (Stats.Records),
--   each opening the map where it happened, the longest worn item the gear
--   screen.
--   Compared with: time played to reach each level against four other
--   characters' (from the roster's copies: the ones ticked in the larger
--   window, else the ones played last), each in its class colour, with a
--   table of them at the replay's level or the one hovered. The chart runs
--   a little past the shown character's level, so a character far ahead
--   does not squash its curve. Its cog opens a larger window with every
--   character, time played, kills, deaths, quests or gold held, and a tick
--   for each to show in the pane (kept in RoadToSixtyDB.compare).
--   Zones by time: time played in each zone inside the window, its bar in
--   the level colours of the time spent there, each opening the map where
--   it was first entered.
--   Life (Stats.Life): professions, reputation and guild at the window's
--   end, with what changed inside it when a date range is picked; the
--   players grouped with most, kept for all time only.
--
-- With the endgame picked (the map window's phase, Range.lua) weeks since
-- the level cap take the levels' place: the tiles count raids and
-- dungeons and say how many a week (nothing gives XP at the cap, so there
-- are no kills either), the chart has a bar per week and its card that
-- week, and the records are the endgame's. With the whole journey, the
-- chart's weeks at the cap follow level 59 in the cap's place (a line
-- marks where they begin); with the levelling it stops at 59. The zones
-- and life show the whole journey for the endgame too (in the date range,
-- up to the replay's moment), and stop at the cap for the levelling; the
-- comparison is time to each level in every phase.

local StatsScreen = {}
ns.StatsScreen = StatsScreen

local Stats = ns.Stats
local Pane = ns.Screens.Pane

local PAD = 12
local TOP = 40              -- below the mode switch
local TILE_H = 62
local GAP = 8
local CHART_H = 250
local CARD_W = 300
local PLOT = { left = 50, right = 14, top = 44, bottom = 26 }
local REBUILD_SECONDS = 10  -- while the journey grows, the index is built again at most this often

local KILL_COLOR = { 0.84, 0.35, 0.29 }
local QUEST_COLOR = { 1, 0.82, 0 }
local WALK_COLOR = { 0.9, 0.8, 0.5 }
local FLY_COLOR = { 0.35, 0.75, 1 }

local RECORDS_SECONDS = 0.25   -- records go through every kill inside the window, so at most this often

local view, viewEdges
local ui = {}
local index, rows, timeline, builtAt, builtFor
local records, recordsKey, recordsAt, recordsPending
local alts                  -- the other characters to compare with (Others)
local dirty = true
local followT = math.huge   -- the replay's moment
local hoverRow              -- the chart's bar under the cursor: a level's row or a week's
local metric = 1

local Commas = function(n) return ns.Commas(n) end
local Duration = function(s) return ns.FormatDuration(s) end

local function Money(copper)
    if not copper then return "-" end
    local sign = copper < 0 and "-" or ""
    copper = math.abs(math.floor(copper))
    if GetMoneyString then return sign .. GetMoneyString(copper, true) end
    return ("%s%dg %ds"):format(sign, math.floor(copper / 10000), math.floor(copper / 100) % 100)
end

local function Short(n)
    if n >= 100000 then return ("%dk"):format(math.floor(n / 1000 + 0.5)) end
    if n >= 10000 then return ("%.1fk"):format(n / 1000) end
    return Commas(n)
end

local function Percent(part, whole)
    return whole > 0 and math.floor(part / whole * 100 + 0.5) or 0
end

local function XPPerHour(row)
    return row.xp and row.time and row.time > 0 and row.xp / row.time * 3600 or nil
end

-- The index for the journey shown, and its level rows: built when the
-- journey or the range changed, and again while the character plays, at
-- most every REBUILD_SECONDS, as building one takes a moment on a long
-- journey.
local function Index()
    local journey = ns.view
    local fresh = index and builtFor == journey and not dirty
    if fresh and (not Stats.Changed(index, journey) or GetTime() - builtAt < REBUILD_SECONDS) then
        return index
    end
    local isMe = journey == ns.char
    local now = isMe and ns.Now() or nil
    index = Stats.Index(journey, now, isMe and GetMoney() or nil)
    local played = isMe and ns.Journal:PlayedAt(now) or journey.played
    rows = Stats.Levels(journey, ns.Roster:ViewLevel(), { played = played, money = isMe and GetMoney() or nil })
    timeline = ns.GearTimeline.Build(journey, index.finish)
    alts = nil
    builtAt, builtFor, dirty, recordsKey = GetTime(), journey, false, nil
    return index
end

-- What the screen covers: the date range, up to the replay's moment.
local function Window()
    local from, to = ns.Range.from, ns.Range.to
    if followT ~= math.huge then to = math.min(to or followT, followT) end
    return Stats.Window(Index(), from, to)
end

-- The endgame: the phase picked, for a journey that has reached the cap.
local WEEK = 7 * 86400
local function Endgame()
    return ns.Range.capAt ~= nil and ns.Range:Key():sub(-4) == "|end"
end

-- The client's level cap, as the gear screen finds it.
local function Cap()
    local ok, cap = pcall(GetMaxPlayerLevel)
    return ok and type(cap) == "number" and cap >= 60 and cap or 60
end

-- A row per week since the cap, as the level rows are per level: its
-- numbers are the week's window. Built once for an index and cap.
local weekRows, weekKey
local function WeekRows()
    local key = tostring(index) .. "|" .. tostring(ns.Range.capAt)
    if key == weekKey then return weekRows end
    weekKey, weekRows = key, {}
    for _, week in ipairs(Stats.Weeks(index, ns.Range.capAt)) do
        local w = Stats.Window(index, week.from, week.to)
        weekRows[#weekRows + 1] = {
            week = true, level = week.week, t = week.from, to = week.to, time = w.played, raids = w.raids,
            dungeons = w.dungeons - w.raids, quests = w.quests, deaths = w.deaths, gold = w.gold,
        }
    end
    return weekRows
end

-- The week since the cap that time t falls in, or nil.
local function WeekAt(t)
    for _, row in ipairs(WeekRows()) do
        if t >= row.t and t <= row.to then return row.level end
    end
end

-- The chart's bars, each with its place on the axis, and how many places
-- the axis has. The endgame has its weeks alone and the levelling its
-- levels below the cap; the whole journey has the levels, then the weeks
-- at the cap in the cap's own place and after it.
local function ChartRows()
    local list = {}
    if Endgame() then
        for i, row in ipairs(WeekRows()) do list[i] = { row = row, slot = row.level } end
        return list, math.max(12, #list)
    end
    local capAt, cap = ns.Range.capAt, Cap()
    local levelling = capAt and ns.Range.phase == "lvl"
    local weeks = capAt and not levelling and WeekRows() or {}
    local cut = levelling or #weeks > 0
    local slots = cap
    for _, row in ipairs(rows or {}) do
        if not (cut and row.level >= cap) then
            list[#list + 1] = { row = row, slot = row.level }
            slots = math.max(slots, row.level)
        end
    end
    for _, row in ipairs(weeks) do list[#list + 1] = { row = row, slot = cap - 1 + row.level } end
    if #weeks > 0 then slots = cap - 1 + #weeks end
    return list, slots
end

-- Two shares side by side, in a thin bar with what each is above it.
local function CreateSplit(parent)
    local split = CreateFrame("Frame", nil, parent)
    split:SetHeight(24)
    split.left = split:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    split.left:SetPoint("TOPLEFT")
    split.right = split:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    split.right:SetPoint("TOPRIGHT")
    split.back = split:CreateTexture(nil, "BACKGROUND")
    split.back:SetPoint("BOTTOMLEFT")
    split.back:SetPoint("BOTTOMRIGHT")
    split.back:SetHeight(7)
    split.back:SetColorTexture(0, 0, 0, 0.7)
    split.a = split:CreateTexture(nil, "ARTWORK")
    split.a:SetPoint("BOTTOMLEFT", 1, 1)
    split.a:SetHeight(5)
    split.b = split:CreateTexture(nil, "ARTWORK")
    split.b:SetPoint("BOTTOMRIGHT", -1, 1)
    split.b:SetHeight(5)
    return split
end

local function SetSplit(split, aName, a, aColor, bName, b, bColor)
    a, b = a or 0, b or 0
    local total = a + b
    split:SetShown(total > 0)
    if total <= 0 then return end
    local pa = Percent(a, total)
    split.left:SetText(("%s %d%%"):format(aName, pa))
    split.right:SetText(("%s %d%%"):format(bName, 100 - pa))
    local width = split:GetWidth() - 2
    split.a:SetWidth(math.max(0.01, width * a / total))
    split.a:SetColorTexture(aColor[1], aColor[2], aColor[3])
    split.b:SetWidth(math.max(0.01, width * b / total))
    split.b:SetColorTexture(bColor[1], bColor[2], bColor[3])
end

-- Headline row -----------------------------------------------------------------------

local TILES = { "Played", "Travelled", "Kills", "Quests", "Deaths", "Gold", "Dungeons" }

local function CreateTiles()
    ui.tiles = {}
    for i, label in ipairs(TILES) do
        local tile = Pane(view)
        tile:SetHeight(TILE_H)
        tile.label = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tile.label:SetPoint("TOPLEFT", 10, -8)
        tile.label:SetText(label)
        tile.value = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        tile.value:SetPoint("TOPLEFT", tile.label, "BOTTOMLEFT", 0, -4)
        tile.sub = tile:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        tile.sub:SetPoint("TOPLEFT", tile.value, "BOTTOMLEFT", 0, -3)
        tile.sub:SetPoint("RIGHT", -8, 0)
        tile.sub:SetJustifyH("LEFT")
        tile.sub:SetWordWrap(false)
        ui.tiles[i] = tile
    end
end

local function SetTile(i, value, sub)
    ui.tiles[i].value:SetText(value)
    ui.tiles[i].sub:SetText(sub or "")
end

local ENDGAME_TILES = { "Played", "Travelled", "Raids", "Dungeons", "Quests", "Deaths", "Gold" }

-- The endgame's tiles: how many raids and dungeons, and each a week.
local function FillEndgameTiles(w)
    for i, label in ipairs(ENDGAME_TILES) do ui.tiles[i].label:SetText(label) end
    local weeks = math.max(1, (w.to - w.from) / WEEK)
    local function AWeek(n) return ("%.1f a week"):format(n / weeks) end
    SetTile(1, Duration(w.played), Duration(w.played / weeks) .. " a week")
    local travelled = w.walked + w.flown
    SetTile(2, Commas(travelled) .. " yd", travelled > 0
        and ("walked %d%%, flown %d%%"):format(Percent(w.walked, travelled), Percent(w.flown, travelled)) or nil)
    SetTile(3, Commas(w.raids), AWeek(w.raids))
    SetTile(4, Commas(w.dungeons - w.raids), AWeek(w.dungeons - w.raids))
    SetTile(5, Commas(w.quests), w.questMoney > 0 and (Money(w.questMoney) .. " from them") or AWeek(w.quests))
    SetTile(6, Commas(w.deaths), w.deaths > 0 and ("one per %s played"):format(Duration(w.played / w.deaths)) or "none")
    SetTile(7, Money(w.gold), "change in gold held")
end

local function FillTiles(w)
    if Endgame() then return FillEndgameTiles(w) end
    for i, label in ipairs(TILES) do ui.tiles[i].label:SetText(label) end
    -- With all time, the game's own time played at that moment; the time
    -- recorded is less when tracking began partway through the journey.
    local total = ns.Range:IsAll() and ns.Journal:PlayedAt(w.to)
    if total and total - w.played > 60 then
        SetTile(1, Duration(total), Duration(w.played) .. " recorded")
    else
        SetTile(1, Duration(w.played), ("%s xp"):format(Commas(w.killXP + w.questXP)))
    end
    local travelled = w.walked + w.flown
    SetTile(2, Commas(travelled) .. " yd", travelled > 0
        and ("walked %d%%, flown %d%%"):format(Percent(w.walked, travelled), Percent(w.flown, travelled)) or nil)
    if ns.killsTracked then
        SetTile(3, Commas(w.kills), ("%s xp"):format(Commas(w.killXP)))
    else
        SetTile(3, "n/a", "kills are not readable here")
    end
    SetTile(4, Commas(w.quests), ("%s xp"):format(Commas(w.questXP)))
    SetTile(5, Commas(w.deaths), w.deaths > 0 and ("one per %s played"):format(Duration(w.played / w.deaths)) or "none")
    SetTile(6, Money(w.gold), "change in gold held")
    local sub
    if w.battlegrounds > 0 then
        sub = ("%d battleground%s"):format(w.battlegrounds, w.battlegrounds == 1 and "" or "s")
    elseif w.levelFrom and w.levelTo then
        sub = w.levelTo > w.levelFrom and ("levels %d to %d"):format(w.levelFrom, w.levelTo) or ("level %d"):format(w.levelTo)
    end
    SetTile(7, Commas(w.dungeons), sub)
end

-- Level chart -----------------------------------------------------------------------

local function AxisTime(seconds)
    if seconds >= 3600 then return ("%dh"):format(math.floor(seconds / 3600 + 0.5)) end
    return ("%dm"):format(math.floor(seconds / 60 + 0.5))
end

local METRICS = {
    { "Time", function(r) return r.time end, AxisTime },
    { "Kills", function(r) return r.kills end, Short },
    { "Deaths", function(r) return r.deaths end, Commas },
    { "Gold", function(r) return r.gold and math.max(0, r.gold) end, function(v) return Short(v / 10000) .. "g" end },
    { "XP / hour", XPPerHour, Short },
}
-- The endgame's, for the weeks since the cap.
local WEEK_METRICS = {
    { "Time", function(r) return r.time end, AxisTime },
    { "Raids", function(r) return r.raids end, Commas },
    { "Dungeons", function(r) return r.dungeons end, Commas },
    { "Quests", function(r) return r.quests end, Commas },
    { "Deaths", function(r) return r.deaths end, Commas },
}

-- A round number at or above v for the top of the axis: 1, 2, 2.5 or 5 times a power of ten.
local function NiceMax(v)
    if v <= 0 then return 1 end
    local p = 10 ^ math.floor(math.log10(v))
    local f = v / p
    return (f <= 1 and 1 or f <= 2 and 2 or f <= 2.5 and 2.5 or f <= 5 and 5 or 10) * p
end

local function RowOf(level)
    for _, row in ipairs(rows or {}) do
        if row.level == level then return row end
    end
end

local function Column(i)
    local col = ui.cols[i]
    if col then return col end
    col = CreateFrame("Button", nil, ui.plot)
    col.bar = col:CreateTexture(nil, "ARTWORK")
    col.bar:SetPoint("BOTTOM")
    -- The level shown in the card: a gold outline round its bar, its value above it.
    col.edges = {}
    for k, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" },
        { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local edge = col:CreateTexture(nil, "OVERLAY")
        edge:SetColorTexture(1, 0.82, 0)
        edge:SetPoint(side[1], col.bar, side[1], k == 4 and 1 or k == 3 and -1 or 0, k == 1 and 1 or k == 2 and -1 or 0)
        edge:SetPoint(side[2], col.bar, side[2], k == 4 and 1 or k == 3 and -1 or 0, k == 1 and 1 or k == 2 and -1 or 0)
        if k <= 2 then edge:SetHeight(1) else edge:SetWidth(1) end
        col.edges[k] = edge
    end
    col.value = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    col.value:SetPoint("BOTTOM", col.bar, "TOP", 0, 4)
    col.glow = col:CreateTexture(nil, "BACKGROUND")
    col.glow:SetAllPoints()
    col.glow:SetColorTexture(1, 1, 1, 0.06)
    col:SetScript("OnEnter", function(self)
        hoverRow = self.row
        ns.SafeShow(StatsScreen.Redraw, StatsScreen)
    end)
    col:SetScript("OnLeave", function()
        hoverRow = nil
        ns.SafeShow(StatsScreen.Redraw, StatsScreen)
    end)
    -- The replay moves to the level up or the week's start, which moves the screen with it.
    col:SetScript("OnClick", function(self)
        if self.t then ns.Map:JumpTo(self.t) end
    end)
    ui.cols[i] = col
    return col
end

local function CreateChart()
    local chart = Pane(view)
    chart:SetPoint("TOPLEFT", PAD, -(TOP + TILE_H + GAP))
    chart:SetPoint("TOPRIGHT", -(PAD + CARD_W + GAP), -(TOP + TILE_H + GAP))
    chart:SetHeight(CHART_H)
    ui.chart = chart
    local title = chart:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    ui.chartTitle = title
    ui.chartNote = chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.chartNote:SetPoint("LEFT", title, "RIGHT", 10, 0)
    ui.metricTabs = {}
    local right = -8
    for i = #METRICS, 1, -1 do
        local tab = ns.Screens.Tab(chart, METRICS[i][1], 84, function()
            metric = i
            ns.SafeShow(StatsScreen.Redraw, StatsScreen)
        end)
        tab:SetPoint("TOPRIGHT", right, -6)
        right = right - 86
        tab.metric = i
        ui.metricTabs[i] = tab
    end
    local plot = CreateFrame("Frame", nil, chart)
    plot:SetPoint("TOPLEFT", PLOT.left, -PLOT.top)
    plot:SetPoint("BOTTOMRIGHT", -PLOT.right, PLOT.bottom)
    ui.plot = plot
    ui.grid, ui.gridLabels, ui.cols = {}, {}, {}
    for i = 0, 4 do
        local line = plot:CreateTexture(nil, "BACKGROUND", nil, 1)
        line:SetHeight(1)
        line:SetColorTexture(1, 1, 1, i == 0 and 0.25 or 0.08)
        ui.grid[i] = line
        local label = chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        label:SetJustifyH("RIGHT")
        ui.gridLabels[i] = label
    end
    -- Where the levels end and the weeks at the cap begin.
    ui.capLine = plot:CreateTexture(nil, "BACKGROUND", nil, 2)
    ui.capLine:SetWidth(1)
    ui.capLine:SetColorTexture(1, 0.82, 0, 0.35)
end

local function DrawChart(w, shown, list, slots)
    local endgame = Endgame()
    local metrics = endgame and WEEK_METRICS or METRICS
    local cap = Cap()
    local weeksAfter = not endgame and list[#list] and list[#list].row.week
    ui.chartTitle:SetText(endgame and "Each week at the level cap"
        or weeksAfter and "Each level, then each week at the cap" or "Each level")
    ui.chartNote:SetText(endgame and "Hover a week to see it, click to replay from its start"
        or weeksAfter and "Hover a bar to see it, click to replay from its start"
        or "Hover a level to see it, click to replay from its level up")
    for i, tab in ipairs(ui.metricTabs) do
        ns.Screens.SetTabOn(tab, i == metric)
        tab.text:SetText(metrics[i][1])
    end
    local m = metrics[metric]
    local plotW, plotH = ui.plot:GetWidth(), ui.plot:GetHeight()
    local n = #list
    local top = 0
    for _, e in ipairs(list) do top = math.max(top, m[2](e.row) or 0) end
    top = NiceMax(top)
    for i = 0, 4 do
        local y = plotH * i / 4
        ui.grid[i]:ClearAllPoints()
        ui.grid[i]:SetPoint("BOTTOMLEFT", 0, y)
        ui.grid[i]:SetPoint("BOTTOMRIGHT", 0, y)
        ui.gridLabels[i]:ClearAllPoints()
        ui.gridLabels[i]:SetPoint("RIGHT", ui.plot, "BOTTOMLEFT", -6, y)
        ui.gridLabels[i]:SetText(i % 2 == 0 and m[3](top * i / 4) or "")
    end
    -- Levels up to the client's own cap (a journey past it widens the axis),
    -- weeks as many as there are; ChartRows places them.
    local step = plotW / slots
    ui.axis = ui.axis or {}
    local marks = {}
    if endgame then
        marks[1] = { 1, "Week 1" }
        for week = 5, slots, 5 do marks[#marks + 1] = { week, "Week " .. week } end
    else
        marks[1] = { 1, "1" }
        for level = 10, weeksAfter and cap - 1 or slots, 10 do marks[#marks + 1] = { level, tostring(level) } end
        if weeksAfter then
            marks[#marks + 1] = { cap, tostring(cap) }
            for week = 5, slots - cap + 1, 5 do marks[#marks + 1] = { cap - 1 + week, "Week " .. week } end
        end
    end
    for k, mark in ipairs(marks) do
        local label = ui.axis[k] or ui.plot:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        ui.axis[k] = label
        label:ClearAllPoints()
        label:SetPoint("TOP", ui.plot, "BOTTOMLEFT", (mark[1] - 0.5) * step, -4)
        label:SetText(mark[2])
        label:Show()
    end
    for k = #marks + 1, #ui.axis do ui.axis[k]:Hide() end
    ui.capLine:ClearAllPoints()
    ui.capLine:SetPoint("TOPLEFT", (cap - 1) * step - 1, 0)
    ui.capLine:SetPoint("BOTTOMLEFT", (cap - 1) * step - 1, 0)
    ui.capLine:SetShown(weeksAfter and true or false)
    for i, e in ipairs(list) do
        local row = e.row
        local col = Column(i)
        col.row, col.t = row, row.t
        col:ClearAllPoints()
        col:SetPoint("BOTTOMLEFT", (e.slot - 1) * step, 0)
        col:SetSize(step, plotH)
        local value = m[2](row) or 0
        local r, g, b = ns.LevelColor(row.week and 60 or row.level)
        col.bar:SetWidth(math.max(1, step - (step > 8 and 3 or 1)))
        col.bar:SetHeight(math.max(value > 0 and 1 or 0.01, plotH * value / top))
        local inside
        if row.week then
            inside = row.t <= w.to and row.to >= w.from
        else
            inside = w.levelFrom and row.level >= w.levelFrom and row.level <= w.levelTo
        end
        local on = row == shown
        if on or inside then
            col.bar:SetColorTexture(r, g, b, on and 1 or row.current and 0.5 or 0.8)
        else
            -- Outside the range or past the replay's moment: grey, whatever the level's colour.
            col.bar:SetColorTexture(0.5, 0.5, 0.5, 0.25)
        end
        for _, edge in ipairs(col.edges) do edge:SetShown(on) end
        col.value:SetShown(on)
        col.value:SetText(metric == 1 and Duration(value) or m[3](value))
        col.glow:SetShown(row == hoverRow)
        col:Show()
    end
    for i = n + 1, #ui.cols do ui.cols[i]:Hide() end
end

-- The level card -----------------------------------------------------------------------

local function Day(t)
    return (tostring(date("%d %b", t)):gsub("^0", ""))
end

-- The card's numbers are a window from the level up to the next one, or to
-- the replay's moment when that comes first, so they agree with the tiles.
-- Gold is known only at level ups, so a level not finished has none yet.
local CARD_FIELDS = {
    { "Time", function(s) return Duration(s.played) end },
    { "XP / hour", function(s) return s.played > 0 and Commas((s.killXP + s.questXP) / s.played * 3600) or nil end },
    { "Kills", function(s) return ns.killsTracked and Commas(s.kills) or "n/a" end },
    { "Quests", function(s) return Commas(s.quests) end },
    { "Deaths", function(s) return Commas(s.deaths) end },
    { "Dungeons", function(s) return Commas(s.dungeons) end },
    { "Gold", function(s) return not s.soFar and Money(s.gold) or nil end },
}

local function CreateCard()
    local card = Pane(view)
    card:SetPoint("TOPRIGHT", -PAD, -(TOP + TILE_H + GAP))
    card:SetSize(CARD_W, CHART_H)
    ui.card = card
    ui.cardTitle = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.cardTitle:SetPoint("TOPLEFT", 12, -12)
    ui.cardZone = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.cardZone:SetPoint("TOPRIGHT", -12, -16)
    ui.cardZone:SetPoint("LEFT", ui.cardTitle, "RIGHT", 8, 0)
    ui.cardZone:SetJustifyH("RIGHT")
    ui.cardZone:SetWordWrap(false)
    ui.cardFields = {}
    local colW = (CARD_W - 24 - 16) / 2
    for i, f in ipairs(CARD_FIELDS) do
        local x = 12 + ((i - 1) % 2) * (colW + 16)
        local y = -42 - math.floor((i - 1) / 2) * 18
        local label = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", x, y)
        label:SetText(f[1])
        local value = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        value:SetPoint("TOPRIGHT", card, "TOPLEFT", x + colW, y)
        ui.cardFields[i] = value
        ui.cardLabels = ui.cardLabels or {}
        ui.cardLabels[i] = label
    end
    ui.xpSplit = CreateSplit(card)
    ui.xpSplit:SetPoint("TOPLEFT", 12, -124)
    ui.xpSplit:SetPoint("TOPRIGHT", -12, -124)
    ui.moveSplit = CreateSplit(card)
    ui.moveSplit:SetPoint("TOPLEFT", ui.xpSplit, "BOTTOMLEFT", 0, -8)
    ui.moveSplit:SetPoint("TOPRIGHT", ui.xpSplit, "BOTTOMRIGHT", 0, -8)
    ui.toGear = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    ui.toGear:SetSize(130, 22)
    ui.toGear:SetPoint("BOTTOMLEFT", 12, 12)
    ui.toGear:SetText("Open in Gear")
    ui.toMap = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    ui.toMap:SetSize(130, 22)
    ui.toMap:SetPoint("BOTTOMRIGHT", -12, 12)
    ui.toMap:SetText("Show on map")
    ui.toGear:SetScript("OnClick", function()
        local row = ui.cardRow
        if not row then return end
        ns.Map:JumpTo(row.t)
        ns.Screens:SetMode("gear")
    end)
    ui.toMap:SetScript("OnClick", function()
        local row = ui.cardRow
        if not row then return end
        ns.Screens:SetMode("map")
        ns.Map:JumpTo(row.t, row.c, row.x, row.y)
    end)
end

-- A week's card: its numbers from its start to its end, or to the
-- replay's moment when that comes first.
local WEEK_FIELDS = {
    { "Time", function(s) return Duration(s.played) end },
    { "Raids", function(s) return Commas(s.raids) end },
    { "Dungeons", function(s) return Commas(s.dungeons - s.raids) end },
    { "Quests", function(s) return Commas(s.quests) end },
    { "Deaths", function(s) return Commas(s.deaths) end },
    { "Quest gold", function(s) return s.questMoney > 0 and Money(s.questMoney) or nil end },
    { "Gold", function(s) return s.gold and Money(s.gold) or nil end },
}

local function ZoneName(uiMapID)
    local info = uiMapID and C_Map.GetMapInfo(uiMapID)
    return info and info.name or ""
end

local function FillWeekCard(row)
    ui.cardRow = row
    for _, part in ipairs({ ui.toGear, ui.toMap, ui.moveSplit }) do part:SetShown(row ~= nil) end
    ui.xpSplit:Hide()
    for i, f in ipairs(WEEK_FIELDS) do ui.cardLabels[i]:SetText(f[1]) end
    if not row then
        ui.cardTitle:SetText("No weeks yet")
        ui.cardZone:SetText("")
        for _, value in ipairs(ui.cardFields) do value:SetText("") end
        return
    end
    ui.cardTitle:SetText(("Week %d"):format(row.level))
    ui.cardTitle:SetTextColor(ns.LevelColor(60))
    local span = Stats.Window(index, row.t, math.min(row.to, followT))
    local note = followT < row.to and ", so far" or ""
    ui.cardZone:SetText(("%s to %s%s"):format(Day(row.t), Day(math.min(row.to, index.finish)), note))
    for i, f in ipairs(WEEK_FIELDS) do ui.cardFields[i]:SetText(f[2](span) or "-") end
    SetSplit(ui.moveSplit, "Walked", span.walked, WALK_COLOR, "flown", span.flown, FLY_COLOR)
    ui.toMap:SetEnabled(true)
end

local function FillCard(row)
    if (row and row.week) or (not row and Endgame()) then return FillWeekCard(row) end
    for i, f in ipairs(CARD_FIELDS) do ui.cardLabels[i]:SetText(f[1]) end
    ui.cardRow = row
    for _, part in ipairs({ ui.toGear, ui.toMap, ui.xpSplit, ui.moveSplit }) do part:SetShown(row ~= nil) end
    if not row then
        ui.cardTitle:SetText("No levels yet")
        ui.cardZone:SetText("")
        for _, value in ipairs(ui.cardFields) do value:SetText("") end
        return
    end
    local r, g, b = ns.LevelColor(row.level)
    ui.cardTitle:SetText(("Level %d%s"):format(row.level, row.partial and "*" or ""))
    ui.cardTitle:SetTextColor(r, g, b)
    local nextRow = RowOf(row.level + 1)
    local stop = nextRow and nextRow.t or index.finish
    local span = Stats.Window(index, row.t, math.min(stop, followT))
    span.soFar = followT < stop or row.current
    local zone = row.t and ZoneName(Stats.ZoneAt(index, row.t)) or ""
    local note = span.soFar and "so far" or row.partial and "tracking began partway" or nil
    ui.cardZone:SetText(note and (zone ~= "" and (zone .. ", " .. note) or note) or zone)
    for i, f in ipairs(CARD_FIELDS) do ui.cardFields[i]:SetText(f[2](span) or "-") end
    SetSplit(ui.xpSplit, "XP from kills", span.killXP, KILL_COLOR, "from quests", span.questXP, QUEST_COLOR)
    SetSplit(ui.moveSplit, "Walked", span.walked, WALK_COLOR, "flown", span.flown, FLY_COLOR)
    ui.toMap:SetEnabled(row.c ~= nil)
end

-- Records ----------------------------------------------------------------------------

local SLOT_NAMES = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [5] = "Chest", [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist",
    [10] = "Hands", [11] = "Ring", [12] = "Ring", [13] = "Trinket", [14] = "Trinket", [15] = "Back", [16] = "Main hand",
    [17] = "Off hand", [18] = "Ranged",
}

-- An item's name in its quality's colour and its icon; while the client has
-- not loaded it, it is asked for and the records drawn again when it comes.
local function Item(id)
    ---@diagnostic disable-next-line: deprecated
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local name, _, quality, _, _, _, _, _, _, icon = getInfo(id)
    if not name then
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        return ("Item %d"):format(id)
    end
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    return color and (color.hex .. name .. "|r") or name, icon, quality
end

local function LevelZone(t)
    local level = Stats.LevelAt(index, t)
    local zone = ZoneName(Stats.ZoneAt(index, t))
    return level and (zone ~= "" and ("Level %d, %s"):format(level, zone) or ("Level %d"):format(level)) or zone
end

local function Count(n, one, many)
    return ("%s %s"):format(Commas(n), n == 1 and one or many)
end

local function Levels(a, b)
    if not (a and b) then return nil end
    return a == b and ("Level %d"):format(a) or ("Levels %d to %d"):format(a, b)
end

-- Each record: key in Stats.Records, its name, its icon, and a function
-- giving its value (a line of its own, so names have room), the line under
-- it and, for items, the item's own icon and quality. Stats.Records also
-- finds the best and longest session; they are left off the screen for now.
local RECORDS = {
    { "slowest", "Slowest level", "Interface\\Icons\\INV_Misc_PocketWatch_01",
        function(r) return Duration(r.seconds), LevelZone(r.t) end },
    { "bestRate", "Best XP per hour", "Interface\\Icons\\Spell_Holy_SealOfWisdom",
        function(r) return Commas(r.perHour) .. " xp", LevelZone(r.t) end },
    { "deadliest", "Deadliest level", "Interface\\Icons\\Ability_Rogue_FeignDeath",
        function(r) return Count(r.deaths, "death", "deaths"), LevelZone(r.t) end },
    { "nemesis", "Nemesis", "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
        function(r) return r.name, ("Killed you %s"):format(Count(r.count, "time", "times")) end },
    { "mostKilled", "Most killed", "Interface\\Icons\\INV_Sword_04",
        function(r) return r.name, Commas(r.count) .. " killed" end },
    { "longestWorn", "Longest worn", "Interface\\Icons\\INV_Misc_QuestionMark",
        function(r)
            local name, icon, quality = Item(r.id)
            return name, ("%s worn, %s"):format(Duration(r.seconds), SLOT_NAMES[r.slot] or "gear"), icon, quality
        end, gear = true },
    { "richest", "Most gold held", "Interface\\Icons\\INV_Misc_Coin_01",
        function(r) return Money(r.money), LevelZone(r.t) end },
    { "deathless", "Longest without dying", "Interface\\Icons\\Spell_Holy_Resurrection",
        function(r)
            local levels = Levels(Stats.LevelAt(index, r.from), Stats.LevelAt(index, r.to)) or ""
            return Duration(r.seconds), r.ongoing and (levels .. ", still going") or levels
        end },
    { "favouriteDungeon", "Favourite dungeon", "Interface\\Icons\\INV_Misc_Key_03",
        function(r)
            local levels = Levels(Stats.LevelAt(index, r.first), Stats.LevelAt(index, r.last))
            return r.name, levels and ("%s, %s"):format(Count(r.count, "run", "runs"), levels:lower()) or Count(r.count, "run", "runs")
        end },
    { "mostGathered", "Most gathered", "Interface\\Icons\\INV_Pick_02",
        function(r)
            local name, icon, quality = Item(r.item)
            local zone = ZoneName(Stats.ZoneAt(index, r.t))
            return name, Commas(r.count) .. " gathered" .. (zone ~= "" and (", " .. zone) or ""), icon, quality
        end },
}

-- The endgame's own five records, before the five both have. Each can still
-- change as the weeks go on: the first epic, say, is an event, not a record.
local ENDGAME_RECORDS = {
    { "busiestWeek", "Busiest week", "Interface\\Icons\\Spell_Nature_TimeStop",
        function(r) return Duration(r.seconds), ("Week %d, from %s"):format(r.week, Day(r.from)) end },
    { "mostRaidsWeek", "Most raids in a week", "Interface\\Icons\\INV_Misc_PocketWatch_01",
        function(r) return Count(r.count, "raid", "raids"), ("Week %d, from %s"):format(r.week, Day(r.from)) end },
    { "favouriteRaid", "Favourite raid", "Interface\\Icons\\INV_Misc_Head_Dragon_01",
        function(r) return r.name, ("%s, from %s"):format(Count(r.count, "run", "runs"), Day(r.first)) end },
    { "favouriteDungeon", "Favourite dungeon", "Interface\\Icons\\INV_Misc_Key_03",
        function(r) return r.name, ("%s, from %s"):format(Count(r.count, "run", "runs"), Day(r.first)) end },
    { "deadliestRaid", "Deadliest raid", "Interface\\Icons\\Ability_Rogue_FeignDeath",
        function(r) return Count(r.deaths, "death", "deaths"), ("%s, %s"):format(r.name or "a raid", Day(r.t)) end },
}

local ICON = 36

local function OpenRecord(spec, r)
    if spec.gear then
        ns.Map:JumpTo(r.t)
        ns.Screens:SetMode("gear")
    else
        ns.Screens:SetMode("map")
        ns.Map:JumpTo(r.t, r.c, r.x, r.y)
    end
end

local function CreateRecords()
    local box = Pane(view)
    ui.records = box
    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Records")
    local note = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("LEFT", title, "RIGHT", 10, 0)
    note:SetText("Click one to see it on the map")
    ui.recordRows = {}
    for i, spec in ipairs(RECORDS) do
        local row = CreateFrame("Button", nil, box)
        -- The icon in the game's item button art, as in the bags; the row takes the mouse.
        row.frame = ns.Screens.ItemButton(row, ICON)
        row.frame:SetPoint("LEFT", 1, 0)
        row.frame:EnableMouse(false)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.label:SetPoint("TOPLEFT", row.frame, "TOPRIGHT", 9, 1)
        row.label:SetText(spec[2])
        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.value:SetPoint("LEFT", row.frame, "RIGHT", 9, 0)
        row.value:SetPoint("RIGHT", -4, 0)
        row.value:SetJustifyH("LEFT")
        row.value:SetWordWrap(false)
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sub:SetPoint("BOTTOMLEFT", row.frame, "BOTTOMRIGHT", 9, -1)
        row.sub:SetPoint("RIGHT", -4, 0)
        row.sub:SetJustifyH("LEFT")
        row.sub:SetWordWrap(false)
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.06)
        row:SetScript("OnEnter", function(self)
            if not self.record then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.spec[2])
            GameTooltip:AddLine(self.value:GetText(), 1, 1, 1)
            GameTooltip:AddLine(self.sub:GetText(), 0.7, 0.7, 0.7)
            GameTooltip:AddLine(self.spec.gear and "Click to see it on the gear screen" or "Click to see it on the map",
                1, 0.82, 0)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:SetScript("OnClick", function(self)
            if self.record then ns.SafeShow(OpenRecord, self.spec, self.record) end
        end)
        ui.recordRows[i] = row
    end
end

local function LayoutRecords()
    local box = ui.records
    local inner = box:GetWidth() - 24
    local colW = (inner - 16) / 2
    local rowH = math.max(ICON + 8, (box:GetHeight() - 44) / math.ceil(#ui.recordRows / 2))
    for i, row in ipairs(ui.recordRows) do
        local col, line = (i - 1) % 2, math.floor((i - 1) / 2)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 12 + col * (colW + 16), -38 - line * rowH)
        row:SetSize(colW, rowH - 6)
    end
end

-- Records for the window, worked out again at most every RECORDS_SECONDS;
-- one put off is done once the replay has moved on.
local function Records(w)
    local key = w.from .. ":" .. w.to .. ":" .. ns.Range:Key()
    if key == recordsKey then return records end
    if records and recordsAt and GetTime() - recordsAt < RECORDS_SECONDS then
        if not recordsPending then
            recordsPending = true
            C_Timer.After(RECORDS_SECONDS, function()
                recordsPending = false
                ns.SafeShow(StatsScreen.Redraw, StatsScreen)
            end)
        end
        return records
    end
    records = Stats.Records(index, w.from, w.to, rows, timeline, ns.Range.capAt)
    recordsKey, recordsAt = key, GetTime()
    return records
end

local function FillRecords(w)
    local found = Records(w)
    -- The endgame's five, then the five both have.
    local list = RECORDS
    if Endgame() then
        list = {}
        for _, spec in ipairs(ENDGAME_RECORDS) do list[#list + 1] = spec end
        for _, key in ipairs({ "nemesis", "longestWorn", "richest", "deathless", "mostGathered" }) do
            for _, spec in ipairs(RECORDS) do
                if spec[1] == key then list[#list + 1] = spec end
            end
        end
    end
    for i, spec in ipairs(list) do
        local row, r = ui.recordRows[i], found[spec[1]]
        row.record, row.spec = r, spec
        row.label:SetText(spec[2])
        local value, sub, icon, quality
        if r then value, sub, icon, quality = spec[4](r) end
        row.value:SetText(value or "-")
        row.sub:SetText(r and (sub or "") or "Nothing in this range yet")
        SetItemButtonTexture(row.frame, icon or spec[3])
        SetItemButtonQuality(row.frame, quality)
        -- Nothing in the range: the whole record greyed, not only its icon.
        local desaturate = _G["SetItemButtonDesaturated"]   -- the item button's own, missing from the type stubs
        if desaturate then desaturate(row.frame, not r) end
        row:SetAlpha(r and 1 or 0.45)
    end
end

ns.On("GET_ITEM_INFO_RECEIVED", function()
    if not (view and view:IsVisible()) or recordsPending then return end
    recordsPending = true
    C_Timer.After(0.3, function()
        recordsPending = false
        recordsKey = nil
        ns.SafeShow(StatsScreen.Redraw, StatsScreen)
    end)
end)

-- Compared with ----------------------------------------------------------------------

local ME_COLOR = { 1, 0.82, 0 }
local PANE_ALTS = 4         -- other characters in the pane
local WINDOW_ALTS = 14      -- other characters in the larger window
local TABLE_ROW = 15
local PAST_MINE = 5         -- levels the pane's chart runs past the shown character's highest
local SMOOTH = 4            -- pieces each level's stretch of a curve is drawn in

-- What the curves can show, from the running totals every level snapshot
-- has: field, name, a value's words, the axis's, and which way is better
-- ("lower", "higher", or nil for neither).
local CURVES = {
    { "played", "Time played", Duration, Duration, "lower" },
    { "kills", "Kills", Commas, Short },
    { "deaths", "Deaths", Commas, Short, "lower" },
    { "quests", "Quests", Commas, Short },
    { "money", "Gold held", Money, function(v) return Short(v / 10000) .. "g" end, "higher" },
}

-- A running total on reaching each level: level -> value.
local function Reached(journey, field)
    local out = {}
    for level, snap in pairs(journey.levels or {}) do
        if type(snap[field]) == "number" then out[level] = snap[field] end
    end
    return out
end

-- Every other character with at least two level ups, the ones played last
-- first (the roster's order).
local function Others()
    if alts then return alts end
    alts = {}
    local shown = ns.Roster:ViewEntry()
    for _, e in ipairs(ns.Roster:Entries()) do
        if e ~= shown and e.journey then
            local n = 0
            for _, snap in pairs(e.journey.levels or {}) do
                if snap.played then n = n + 1 end
            end
            if n >= 2 then alts[#alts + 1] = { entry = e, color = { ns.ClassColor(e.class) } } end
        end
    end
    return alts
end

-- The ones the pane shows: those ticked in the larger window, else the ones played last.
local function PaneAlts()
    local all, list = Others(), {}
    local picked = ns.db.compare
    if picked and next(picked) then
        for _, a in ipairs(all) do
            if picked[a.entry.key] and #list < PANE_ALTS then list[#list + 1] = a end
        end
    end
    if #list == 0 then
        for k = 1, math.min(PANE_ALTS, #all) do list[k] = all[k] end
    end
    return list
end

local function Hex(color)
    return ("|cff%02x%02x%02x"):format(color[1] * 255, color[2] * 255, color[3] * 255)
end

-- A point SMOOTH pieces of the way between p1 and p2 on a Catmull-Rom curve
-- through p0 to p3, its height kept between p1's and p2's so a running
-- total never seems to run backwards.
local function CurvePoint(p0, p1, p2, p3, t)
    local t2, t3 = t * t, t * t * t
    local function At(i)
        return 0.5 * (2 * p1[i] + (p2[i] - p0[i]) * t + (2 * p0[i] - 5 * p1[i] + 4 * p2[i] - p3[i]) * t2
            + (3 * p1[i] - p0[i] - 3 * p2[i] + p3[i]) * t3)
    end
    local y = math.max(math.min(At(2), math.max(p1[2], p2[2])), math.min(p1[2], p2[2]))
    return At(1), y
end

-- A chart of curves over levels, for the pane and the larger window. Its
-- frame is placed by the caller; hovering it sets chart.hover and calls
-- onHover.
local function NewChart(parent, onHover)
    local chart = { lines = {}, axis = {}, ticks = {}, dots = {} }
    local plot = CreateFrame("Frame", nil, parent)
    chart.plot = plot
    for i = 1, 3 do
        local line = plot:CreateTexture(nil, "BACKGROUND", nil, 1)
        line:SetHeight(1)
        line:SetColorTexture(1, 1, 1, i == 1 and 0.25 or 0.08)
        local label = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        label:SetJustifyH("RIGHT")
        chart.axis[i] = { line = line, label = label }
    end
    chart.mark = plot:CreateTexture(nil, "OVERLAY")
    chart.mark:SetWidth(1)
    chart.mark:SetColorTexture(1, 1, 1, 0.35)
    plot:SetScript("OnUpdate", function(self)
        local level
        if self:IsMouseOver() and chart.last then
            local x = GetCursorPosition() / self:GetEffectiveScale() - self:GetLeft()
            level = math.max(1, math.min(chart.last, math.floor(x / self:GetWidth() * (chart.last - 1) + 1.5)))
        end
        if level ~= chart.hover then
            chart.hover = level
            ns.SafeShow(onHover)
        end
    end)
    return chart
end

-- Lines off the pixel grid, so a curve's short pieces join smoothly.
local function ChartLine(chart, k)
    local line = chart.lines[k]
    if not line then
        line = chart.plot:CreateLine(nil, "ARTWORK")
        if line.SetSnapToPixelGrid then
            line:SetSnapToPixelGrid(false)
            line:SetTexelSnappingBias(0)
        end
        chart.lines[k] = line
    end
    return line
end

-- Draws series ({ reached, color, thick, mine }) from level 1 to last with
-- the line at level. The curves are drawn again only when what they show
-- changed (key): hovering and the replay move just the line and the dots.
-- The others first, then a dark edge and the shown character's gold on
-- top of it, each on its own draw level so the gold always lies over it.
local function DrawCurves(chart, series, last, level, axisWords, key)
    local plot = chart.plot
    local w, h = plot:GetWidth(), plot:GetHeight()
    chart.last = last
    local top = 0
    for _, one in ipairs(series) do
        for l, value in pairs(one.reached) do
            if l <= last then top = math.max(top, value) end
        end
    end
    if axisWords == Duration then
        local day = 86400
        top = top > 2 * day and math.ceil(top / day) * day or math.max(3600, math.ceil(top / 3600) * 3600)
    else
        top = NiceMax(top)
    end
    local function X(l) return (l - 1) / (last - 1) * w end
    local function Y(value) return value / top * h end
    for i, a in ipairs(chart.axis) do
        local value = top * (i - 1) / 2
        a.line:ClearAllPoints()
        a.line:SetPoint("BOTTOMLEFT", 0, Y(value))
        a.line:SetPoint("BOTTOMRIGHT", 0, Y(value))
        a.label:ClearAllPoints()
        a.label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, Y(value))
        a.label:SetText(i == 1 and "0" or axisWords(value))
    end
    local ticks = { 1 }
    for l = 10, last - 5, 10 do ticks[#ticks + 1] = l end
    ticks[#ticks + 1] = last
    for k, l in ipairs(ticks) do
        local label = chart.ticks[k] or plot:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        chart.ticks[k] = label
        label:ClearAllPoints()
        label:SetPoint("TOP", plot, "BOTTOMLEFT", X(l), -4)
        label:SetText(tostring(l))
        label:Show()
    end
    for k = #ticks + 1, #chart.ticks do chart.ticks[k]:Hide() end

    key = ("%s|%d|%d|%d|%d"):format(key, last, top, math.floor(w), math.floor(h))
    if key ~= chart.key then
        chart.key = key
        local n = 0
        local function Draw(one, thick, r, g, b, a, layer)
            local l = 1
            while l < last do
                if one.reached[l] and one.reached[l + 1] then
                    local pts = {}
                    while l <= last and one.reached[l] do
                        pts[#pts + 1] = { X(l), Y(one.reached[l]) }
                        l = l + 1
                    end
                    for i = 1, #pts - 1 do
                        local p0, p1, p2, p3 = pts[math.max(1, i - 1)], pts[i], pts[i + 1], pts[math.min(#pts, i + 2)]
                        local px, py = p1[1], p1[2]
                        for piece = 1, SMOOTH do
                            local x, y = CurvePoint(p0, p1, p2, p3, piece / SMOOTH)
                            n = n + 1
                            local line = ChartLine(chart, n)
                            line:SetDrawLayer("ARTWORK", layer)
                            line:SetThickness(thick)
                            line:SetStartPoint("BOTTOMLEFT", plot, px, py)
                            line:SetEndPoint("BOTTOMLEFT", plot, x, y)
                            line:SetColorTexture(r, g, b, a)
                            line:Show()
                            px, py = x, y
                        end
                    end
                else
                    l = l + 1
                end
            end
        end
        for k = #series, 1, -1 do
            local one = series[k]
            if not one.mine then Draw(one, one.thick, one.color[1], one.color[2], one.color[3], 0.85, 1) end
        end
        for _, one in ipairs(series) do
            if one.mine then
                Draw(one, one.thick + 3, 0, 0, 0, 0.6, 2)
                Draw(one, one.thick, one.color[1], one.color[2], one.color[3], 1, 3)
            end
        end
        for k = n + 1, #chart.lines do chart.lines[k]:Hide() end
    end

    level = math.max(1, math.min(last, level or 1))
    chart.mark:ClearAllPoints()
    chart.mark:SetPoint("BOTTOMLEFT", X(level), 0)
    chart.mark:SetHeight(h)
    for k, one in ipairs(series) do
        local dot = chart.dots[k] or plot:CreateTexture(nil, "OVERLAY", nil, 2)
        chart.dots[k] = dot
        local value = one.reached[level]
        dot:SetShown(value ~= nil)
        if value then
            dot:SetSize(one.mine and 7 or 6, one.mine and 7 or 6)
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", plot, "BOTTOMLEFT", X(level), Y(value))
            dot:SetColorTexture(one.color[1], one.color[2], one.color[3])
        end
    end
    for k = #series + 1, #chart.dots do chart.dots[k]:Hide() end
    return level
end

-- The difference of another character's value from yours, coloured green
-- when yours is the better one (for a curve with a better way).
local function Difference(curve, theirs, yours)
    local diff = theirs - yours
    if math.abs(diff) < (curve[1] == "played" and 60 or 1) then return "|cff999999same|r" end
    local better = curve[5]
    local color = not better and "|cffcccccc" or ((better == "lower") == (diff > 0)) and "|cff40e060" or "|cffff7a5a"
    return ("%s%s%s|r"):format(color, diff > 0 and "+" or "-", curve[3](math.abs(diff)))
end

-- The pane's series and the larger window's, for a curve: you first.
local function Series(list, field, thick)
    local series = { { reached = Reached(ns.view, field), color = ME_COLOR, name = "You", thick = 3, mine = true } }
    for _, a in ipairs(list) do
        series[#series + 1] = { reached = Reached(a.entry.journey, field), color = a.color, name = a.entry.name or "?",
            thick = thick, entry = a.entry }
    end
    return series
end

-- The larger window ----------------------------------------------------------------

local windowCurve = 1

local function CreateWindow()
    local win = CreateFrame("Frame", "RoadToSixtyCompareWindow", view, "BackdropTemplate")
    ui.window = win
    win:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
    win:SetBackdropBorderColor(0.7, 0.7, 0.7)
    win:SetPoint("TOPLEFT", 40, -36)
    win:SetPoint("BOTTOMRIGHT", -40, 36)
    win:SetFrameLevel(view:GetFrameLevel() + 90)
    win:EnableMouse(true)
    win:Hide()
    -- A solid ground, so nothing behind shows through: a plain dark colour,
    -- which draws on every client, under the stone the game's own windows
    -- have, tiled (an atlas could be missing and draw nothing).
    local solid = win:CreateTexture(nil, "BACKGROUND", nil, -8)
    solid:SetPoint("TOPLEFT", 4, -4)
    solid:SetPoint("BOTTOMRIGHT", -4, 4)
    solid:SetColorTexture(0.09, 0.085, 0.075, 1)
    local stone = win:CreateTexture(nil, "BACKGROUND", nil, -7)
    stone:SetAllPoints(solid)
    stone:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
    stone:SetHorizTile(true)
    stone:SetVertTile(true)
    -- A shade over the screen behind while it is open; a click on it closes the window.
    local shade = CreateFrame("Button", nil, view)
    shade:SetAllPoints(view)
    shade:SetFrameLevel(win:GetFrameLevel() - 2)
    local dark = shade:CreateTexture(nil, "BACKGROUND")
    dark:SetAllPoints()
    dark:SetColorTexture(0, 0, 0, 0.65)
    shade:SetScript("OnClick", function() win:Hide() end)
    shade:Hide()
    win:SetScript("OnHide", function() shade:Hide() end)
    -- Not one of UISpecialFrames: Escape closes every one of those at once,
    -- so it would close the map window too. Escape closes the map window,
    -- and this one with it; its close button closes just this one.
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Your characters")
    local note = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("LEFT", title, "RIGHT", 12, -1)
    note:SetText(("Tick up to %d to show in the Stats screen's comparison"):format(PANE_ALTS))
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    ui.windowTabs = {}
    for i, curve in ipairs(CURVES) do
        local tab = ns.Screens.Tab(win, curve[2], 110, function()
            windowCurve = i
            ns.SafeShow(StatsScreen.Redraw, StatsScreen)
        end)
        tab:SetPoint("TOPLEFT", 14 + (i - 1) * 114, -44)
        ui.windowTabs[i] = tab
    end
    ui.windowChart = NewChart(win, function() StatsScreen:Redraw() end)
    ui.windowChart.plot:SetPoint("TOPLEFT", 70, -96)
    ui.windowHead = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.windowHeads = {}
    for k, words in ipairs({ "Character", "Level", "Played", "", "Against you" }) do
        local head = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        head:SetText(words)
        ui.windowHeads[k] = head
    end
    ui.windowRows = {}
    ui.windowMore = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win:SetScript("OnShow", function()
        shade:Show()
        ns.SafeShow(StatsScreen.Redraw, StatsScreen)
    end)
end

local function WindowRow(k)
    local row = ui.windowRows[k]
    if row then return row end
    local win = ui.window
    row = { cells = {} }
    row.check = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    row.check:SetSize(22, 22)
    row.check:SetScript("OnClick", function(self)
        local key = self.key
        if not key then return end
        ns.db.compare = ns.db.compare or {}
        -- Only characters still in the roster count; a deleted one's tick is forgotten.
        local count = 0
        for _, a in ipairs(Others()) do
            if ns.db.compare[a.entry.key] then count = count + 1 end
        end
        if self:GetChecked() and count >= PANE_ALTS then
            self:SetChecked(false)
            ns.Print(("The comparison shows up to %d characters; untick one first."):format(PANE_ALTS))
            return
        end
        ns.db.compare[key] = self:GetChecked() or nil
        ns.SafeShow(StatsScreen.Redraw, StatsScreen)
    end)
    row.swatch = win:CreateTexture(nil, "ARTWORK")
    row.swatch:SetSize(8, 8)
    for c = 1, 5 do
        local cell = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetJustifyH(c == 1 and "LEFT" or "RIGHT")
        cell:SetWordWrap(false)
        row.cells[c] = cell
    end
    ui.windowRows[k] = row
    return row
end

local function DrawWindow(w)
    local win = ui.window
    for i, tab in ipairs(ui.windowTabs) do ns.Screens.SetTabOn(tab, i == windowCurve) end
    local curve = CURVES[windowCurve]
    local width, height = win:GetWidth(), win:GetHeight()
    local tableX = math.floor(width * 0.6)
    ui.windowChart.plot:SetPoint("BOTTOMRIGHT", win, "BOTTOMLEFT", tableX - 30, 40)

    local all = Others()
    local list = {}
    for k = 1, math.min(WINDOW_ALTS, #all) do list[k] = all[k] end
    local series = Series(list, curve[1], 2)
    local highest = 0
    for _, one in ipairs(series) do
        for l in pairs(one.reached) do highest = math.max(highest, l) end
    end
    local last = math.min(Cap(), math.max(10, highest))
    local key = curve[1] .. "|" .. tostring(ns.view)
    for _, a in ipairs(list) do key = key .. "|" .. tostring(a.entry) end
    local level = DrawCurves(ui.windowChart, series, last, ui.windowChart.hover or w.levelTo, curve[4], key)

    -- The table: every character, its level and time played, its value at
    -- the level shown and against yours, and whether the pane shows it.
    local cols = { tableX + 52, tableX + 210, tableX + 270, tableX + 360, width - 20 }
    ui.windowHead:ClearAllPoints()
    ui.windowHead:SetPoint("TOPLEFT", tableX, -96)
    ui.windowHead:SetText(("At level %d: %s"):format(level, curve[2]:lower()))
    for k, head in ipairs(ui.windowHeads) do
        head:ClearAllPoints()
        if k == 1 then
            head:SetPoint("TOPLEFT", win, "TOPLEFT", cols[1], -120)
        else
            head:SetPoint("TOPRIGHT", win, "TOPLEFT", cols[k], -120)
        end
        head:SetText(k == 4 and curve[2] or head:GetText())
    end
    local picked = {}
    for _, a in ipairs(PaneAlts()) do picked[a.entry] = true end
    local yours = series[1].reached[level]
    local rowH = 20
    local fits = math.max(1, math.floor((height - 160) / rowH))
    for k, one in ipairs(series) do
        local row = WindowRow(k)
        local shown = k <= fits
        local y = -140 - (k - 1) * rowH
        row.check:SetShown(shown and not one.mine)
        row.check:ClearAllPoints()
        row.check:SetPoint("LEFT", win, "TOPLEFT", tableX, y - 7)
        row.check.key = one.entry and one.entry.key
        row.check:SetChecked(one.entry and picked[one.entry] and ns.db.compare and ns.db.compare[one.entry.key] or false)
        row.swatch:SetShown(shown)
        row.swatch:ClearAllPoints()
        row.swatch:SetPoint("LEFT", win, "TOPLEFT", tableX + 34, y - 7)
        row.swatch:SetColorTexture(one.color[1], one.color[2], one.color[3])
        local entry = one.entry
        local value = one.reached[level]
        local texts = {
            Hex(one.color) .. (one.mine and "You" or one.name) .. "|r",
            tostring(one.mine and ns.Roster:ViewLevel() or entry.level or "-"),
            Duration(one.mine and (ns.view.played or 0) or (entry.played or entry.journey.played or 0)),
            value and curve[3](value) or "|cff999999-|r",
            (not one.mine and value and yours) and Difference(curve, value, yours)
                or (not one.mine and not value and "|cff999999not there yet|r" or ""),
        }
        for c, cell in ipairs(row.cells) do
            cell:SetShown(shown)
            cell:ClearAllPoints()
            if c == 1 then
                cell:SetPoint("TOPLEFT", win, "TOPLEFT", cols[1], y)
                cell:SetWidth(150)
            else
                cell:SetPoint("TOPRIGHT", win, "TOPLEFT", cols[c], y)
            end
            cell:SetText(texts[c])
        end
    end
    for k = #series + 1, #ui.windowRows do
        local row = ui.windowRows[k]
        row.check:Hide()
        row.swatch:Hide()
        for _, cell in ipairs(row.cells) do cell:Hide() end
    end
    ui.windowMore:ClearAllPoints()
    ui.windowMore:SetPoint("TOPLEFT", win, "TOPLEFT", tableX, -140 - math.min(#series, fits) * rowH - 4)
    local hidden = #all - #list + math.max(0, #series - fits)
    ui.windowMore:SetText(hidden > 0 and ("and %d more"):format(hidden) or "")
end

-- The pane ---------------------------------------------------------------------------

local function CreateCompare()
    local box = Pane(view)
    ui.compare = box
    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Compared with your characters")
    -- The cog opens the larger window: a small red button like the map window's.
    local cogButton = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    cogButton:SetSize(32, 22)
    cogButton:SetPoint("TOPRIGHT", -8, -8)
    local cog = cogButton:CreateTexture(nil, "ARTWORK")
    cog:SetSize(17, 17)
    cog:SetPoint("CENTER")
    cog:SetTexture("Interface\\AddOns\\" .. addonName .. "\\cog")
    cogButton:SetScript("OnMouseDown", function() cog:SetPoint("CENTER", 1, -1) end)
    cogButton:SetScript("OnMouseUp", function() cog:SetPoint("CENTER") end)
    cogButton:SetScript("OnClick", function()
        if not ui.window then CreateWindow() end
        ui.window:SetShown(not ui.window:IsShown())
    end)
    cogButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("All your characters")
        GameTooltip:AddLine("Compare kills, deaths, quests and gold too, and pick who shows here", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    cogButton:SetScript("OnLeave", GameTooltip_Hide)
    ui.paneChart = NewChart(box, function() StatsScreen:Redraw() end)
    ui.paneChart.plot:SetPoint("TOPLEFT", 58, -40)
    ui.cmpRows = {}
    ui.cmpHead = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ui.cmpNote = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.cmpMore = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
end

-- A row of the table under the chart: a swatch, the name, the time, the difference.
local function TableRow(k)
    local row = ui.cmpRows[k]
    if row then return row end
    local box = ui.compare
    row = {}
    row.swatch = box:CreateTexture(nil, "ARTWORK")
    row.swatch:SetSize(8, 8)
    row.name = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.time = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.time:SetJustifyH("RIGHT")
    row.diff = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.diff:SetJustifyH("RIGHT")
    ui.cmpRows[k] = row
    return row
end

local function DrawCompare(w)
    local box = ui.compare
    local list = PaneAlts()
    local series = Series(list, "played", 2)
    local more = #Others() - #list
    -- The table takes the bottom: a heading, a row for each character and,
    -- when some are left out, a line saying how many.
    local rowsH = 18 + #series * TABLE_ROW + (more > 0 and TABLE_ROW or 0)
    ui.paneChart.plot:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -14, 26 + rowsH)
    -- The levels shown: 1 to a little past the shown character's highest.
    local highest = 0
    for l in pairs(series[1].reached) do highest = math.max(highest, l) end
    local last = highest > 0 and math.min(Cap(), math.max(10, highest + PAST_MINE)) or Cap()
    local key = tostring(ns.view)
    for _, a in ipairs(list) do key = key .. "|" .. tostring(a.entry) end
    local level = DrawCurves(ui.paneChart, series, last, ui.paneChart.hover or w.levelTo, Duration, key)

    -- The table: each character's time played to reach the level, and the
    -- others' against yours (green when you were faster).
    local curve = CURVES[1]
    local tableTop = 14 + rowsH
    ui.cmpHead:ClearAllPoints()
    ui.cmpHead:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 12, tableTop - 12)
    ui.cmpHead:SetText(("Level %d"):format(level))
    ui.cmpNote:ClearAllPoints()
    ui.cmpNote:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -12, tableTop - 12)
    ui.cmpNote:SetText(#list == 0 and "no other character yet" or "time played to reach it")
    local yours = series[1].reached[level]
    local inner = box:GetWidth() - 24
    for k, one in ipairs(series) do
        local row = TableRow(k)
        local y = tableTop - 18 - (k - 1) * TABLE_ROW
        row.swatch:ClearAllPoints()
        row.swatch:SetPoint("LEFT", box, "BOTTOMLEFT", 14, y - 6)
        row.swatch:SetColorTexture(one.color[1], one.color[2], one.color[3])
        row.name:ClearAllPoints()
        row.name:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 28, y)
        row.name:SetWidth(inner * 0.42)
        row.name:SetText(Hex(one.color) .. one.name .. "|r")
        row.time:ClearAllPoints()
        row.time:SetPoint("TOPRIGHT", box, "BOTTOMLEFT", 12 + inner * 0.68, y)
        local played = one.reached[level]
        row.time:SetText(played and Duration(played) or "|cff999999-|r")
        row.diff:ClearAllPoints()
        row.diff:SetPoint("TOPRIGHT", box, "BOTTOMLEFT", 12 + inner, y)
        if one.mine then
            row.diff:SetText("")
        elseif not played or not yours then
            row.diff:SetText(not played and "|cff999999not there yet|r" or "")
        else
            row.diff:SetText(Difference(curve, played, yours))
        end
        for _, part in pairs(row) do part:Show() end
    end
    for k = #series + 1, #ui.cmpRows do
        for _, part in pairs(ui.cmpRows[k]) do part:Hide() end
    end
    ui.cmpMore:ClearAllPoints()
    ui.cmpMore:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 28, tableTop - 18 - #series * TABLE_ROW)
    ui.cmpMore:SetText(more > 0 and ("and %d more, the cog shows them all"):format(more) or "")

    if ui.window and ui.window:IsShown() then DrawWindow(w) end
end

-- Zones by time ----------------------------------------------------------------------

local ZONE_ROW = 26

local function OpenZone(zone)
    local entry = zone[3]
    if not entry then return end
    ns.Screens:SetMode("map")
    ns.Map:JumpTo(entry.t, entry.c, entry.x, entry.y)
end

local function CreateZones()
    local box = Pane(view)
    ui.zones = box
    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Zones by time")
    ui.zoneRows = {}
    ui.zoneMore = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
end

local function ZoneRow(i)
    local row = ui.zoneRows[i]
    if row then return row end
    row = CreateFrame("Button", nil, ui.zones)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", 0, -2)
    row.name:SetPoint("RIGHT", -60, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.time:SetPoint("TOPRIGHT", 0, -2)
    row.back = row:CreateTexture(nil, "BACKGROUND")
    row.back:SetPoint("BOTTOMLEFT", 0, 4)
    row.back:SetPoint("BOTTOMRIGHT", 0, 4)
    row.back:SetHeight(5)
    row.back:SetColorTexture(0, 0, 0, 0.7)
    row.parts = {}      -- the bar: a part per level band, in its colour
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.06)
    row:SetScript("OnEnter", function(self)
        if not self.zone then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.name:GetText())
        GameTooltip:AddLine(Duration(self.zone[2]) .. " played here", 1, 1, 1)
        local entry = self.zone[3]
        if entry then
            GameTooltip:AddLine(("First here at level %d"):format(Stats.LevelAt(index, entry.t) or 0), 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Click to see it on the map", 1, 0.82, 0)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", function(self)
        if self.zone then ns.SafeShow(OpenZone, self.zone) end
    end)
    ui.zoneRows[i] = row
    return row
end

local function FillZones(w)
    local box = ui.zones
    local width = box:GetWidth() - 24
    local fits = math.max(1, math.floor((box:GetHeight() - 44) / ZONE_ROW))
    local list = w.zones
    local shown = #list > fits and fits - 1 or #list
    local most = list[1] and list[1][2] or 1
    for i = 1, shown do
        local zone, row = list[i], ZoneRow(i)
        row.zone = zone
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 12, -36 - (i - 1) * ZONE_ROW)
        row:SetSize(width, ZONE_ROW)
        row.name:SetText(ZoneName(zone[1]))
        row.time:SetText(Duration(zone[2]))
        -- The bar split by level band, lowest first, each part its band's colour.
        local bands = {}
        for level, s in pairs(zone[4] or {}) do
            local band = ns.Style.LevelBand(level)
            bands[band] = bands[band] or { level = level, seconds = 0 }
            bands[band].seconds = bands[band].seconds + s
        end
        local order = {}
        for band in pairs(bands) do order[#order + 1] = band end
        table.sort(order)
        local full, x = (width - 2) * zone[2] / most, 1
        for k, band in ipairs(order) do
            local part = row.parts[k] or row:CreateTexture(nil, "ARTWORK")
            row.parts[k] = part
            local partW = full * bands[band].seconds / zone[2]
            part:ClearAllPoints()
            part:SetPoint("BOTTOMLEFT", x, 5)
            part:SetSize(math.max(0.01, partW), 3)
            local r, g, b = ns.LevelColor(bands[band].level)
            part:SetColorTexture(r, g, b, 0.9)
            part:Show()
            x = x + partW
        end
        for k = #order + 1, #row.parts do row.parts[k]:Hide() end
        row:Show()
    end
    for i = shown + 1, #ui.zoneRows do ui.zoneRows[i]:Hide() end
    ui.zoneMore:ClearAllPoints()
    ui.zoneMore:SetPoint("TOPLEFT", 12, -40 - shown * ZONE_ROW)
    if #list == 0 then
        ui.zoneMore:SetText("Nothing in this range yet")
    elseif #list > shown then
        ui.zoneMore:SetText(("and %d more"):format(#list - shown))
    else
        ui.zoneMore:SetText("")
    end
end

-- Life --------------------------------------------------------------------------------

local LIFE_LINE = 17

local function CreateLife()
    local box = Pane(view)
    ui.life = box
    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Life")
    local body = CreateFrame("Frame", nil, box)
    body:SetPoint("TOPLEFT", 12, -34)
    body:SetPoint("BOTTOMRIGHT", -12, 10)
    body:SetClipsChildren(true)
    ui.lifeBody = body
    ui.lifeLines = {}
end

-- The nth line of the life pane: text on the left, text on the right, and
-- under them a thin bar when given a share.
local function LifeLine(n)
    local line = ui.lifeLines[n]
    if line then return line end
    line = {}
    line.left = ui.lifeBody:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.left:SetJustifyH("LEFT")
    line.left:SetWordWrap(false)
    line.right = ui.lifeBody:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.right:SetJustifyH("RIGHT")
    line.back = ui.lifeBody:CreateTexture(nil, "BACKGROUND")
    line.back:SetColorTexture(0, 0, 0, 0.7)
    line.back:SetHeight(4)
    line.bar = ui.lifeBody:CreateTexture(nil, "ARTWORK")
    line.bar:SetHeight(2)
    line.bar:SetColorTexture(0.2, 0.65, 0.2)
    ui.lifeLines[n] = line
    return line
end

local function FillLife(w)
    local life = Stats.Life(index, w.from, w.to)
    local body = ui.lifeBody
    local width = body:GetWidth()
    local n, y = 0, 0
    local function Add(left, right, share, header)
        n = n + 1
        local line = LifeLine(n)
        line.left:SetFontObject(header and "GameFontDisableSmall" or "GameFontHighlightSmall")
        line.left:ClearAllPoints()
        line.left:SetPoint("TOPLEFT", 0, -y)
        line.left:SetPoint("RIGHT", body, "RIGHT", -70, 0)
        line.left:SetText(left)
        line.right:ClearAllPoints()
        line.right:SetPoint("TOPRIGHT", 0, -y)
        line.right:SetText(right or "")
        line.left:Show()
        line.right:Show()
        y = y + (header and LIFE_LINE + 2 or LIFE_LINE)
        line.back:SetShown(share ~= nil)
        line.bar:SetShown(share ~= nil)
        if share then
            line.back:ClearAllPoints()
            line.back:SetPoint("TOPLEFT", 0, -y + 3)
            line.back:SetWidth(width)
            line.bar:ClearAllPoints()
            line.bar:SetPoint("TOPLEFT", line.back, 1, -1)
            line.bar:SetWidth(math.max(0.01, (width - 2) * math.min(1, share)))
            y = y + 5
        end
    end

    -- What changed inside the window says something only for a date range
    -- picked: with all time it would repeat the rank, and the phase (the
    -- endgame, say) leaves what the character has as it is.
    local changes = ns.Range.key ~= "all"
    Add("PROFESSIONS", nil, nil, true)
    for _, p in ipairs(life.professions) do
        local gained = changes and p.gained > 0 and (" |cff40e060+%d|r"):format(p.gained) or ""
        Add(p.name .. gained, ("|cff999999%d / %s|r"):format(p.rank, p.max and tostring(p.max) or "?"),
            p.max and p.max > 0 and p.rank / p.max or nil)
    end
    if #life.professions == 0 then Add("|cff999999None yet|r") end

    Add("REPUTATION", nil, nil, true)
    for k = 1, math.min(4, #life.reputation) do
        local f = life.reputation[k]
        local r, g, b = ns.Reputation:Color(f.standing)
        local label = ("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, ns.Reputation:Label(f.standing))
        Add(f.name, (changes and f.reached and "|cff40e060+|r " or "") .. label)
    end
    if #life.reputation == 0 then Add("|cff999999None yet|r") end

    Add("GROUPED WITH MOST, ALL TIME", nil, nil, true)
    local people = ns.Parties:People()
    for k = 1, math.min(3, #people) do
        local p = people[k][2]
        local r, g, b = ns.ClassColor(p.class)
        local groups = ns.Tally.Total(p.groups)
        Add(("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, p.name or "?"),
            ("|cff999999%d group%s|r"):format(groups, groups == 1 and "" or "s"))
    end
    if #people == 0 then Add("|cff999999Nobody yet|r") end

    Add("GUILD", nil, nil, true)
    Add(life.guild and ("<%s>"):format(life.guild) or "|cff999999None|r")

    for k = n + 1, #ui.lifeLines do
        local line = ui.lifeLines[k]
        line.left:Hide()
        line.right:Hide()
        line.back:Hide()
        line.bar:Hide()
    end
end

-- The screen -------------------------------------------------------------------------

local function Layout()
    local width = view:GetWidth() - 2 * PAD
    local tileW = (width - (#ui.tiles - 1) * GAP) / #ui.tiles
    for i, tile in ipairs(ui.tiles) do
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", PAD + (i - 1) * (tileW + GAP), -TOP)
        tile:SetWidth(tileW)
    end
    -- The bottom row: records, the comparison, zones and life.
    local below = TOP + TILE_H + GAP + CHART_H + GAP
    local share = { 0.34, 0.30, 0.17, 0.19 }
    local boxes = { ui.records, ui.compare, ui.zones, ui.life }
    local x, room = PAD, width - (#boxes - 1) * GAP
    for i, box in ipairs(boxes) do
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", x, -below)
        box:SetPoint("BOTTOMLEFT", x, PAD)
        box:SetWidth(room * share[i])
        x = x + room * share[i] + GAP
    end
    LayoutRecords()
end

function StatsScreen:Redraw()
    if not (view and view:IsVisible()) then return end
    local w = Window()
    FillTiles(w)
    local covers = ("%s to %s"):format(Day(w.from), Day(w.to))
    if followT < index.finish then covers = covers .. ", up to the replay's moment" end
    local label = ns.Range:Label()
    if ns.Range:Key():find("|lvl", 1, true) or ns.Range:Key():find("|end", 1, true) then
        label = ns.Range:PhaseLabel() .. ", " .. label:lower()
    end
    ui.range:SetText(("|cffffd100%s|r  %s"):format(label, covers))
    -- The bar shown in the card: the one hovered, else the week or level
    -- the window ends in (the levelling's stops below the cap).
    local list, slots = ChartRows()
    local capAt, shown = ns.Range.capAt, hoverRow
    local last = list[#list] and list[#list].row
    if not shown and last and last.week and w.to >= capAt then
        local weeks = WeekRows()
        shown = weeks[WeekAt(math.min(w.to, index.finish)) or #weeks]
    end
    if not shown and not Endgame() then
        local level = w.levelTo
        if level and capAt and ns.Range.phase == "lvl" then level = math.min(level, Cap() - 1) end
        shown = RowOf(level) or rows[#rows]
    end
    DrawChart(w, shown, list, slots)
    FillCard(shown)
    FillRecords(w)
    -- The zones and life take the endgame as part of the whole journey:
    -- the date range alone, up to the replay's moment, cut at the cap only
    -- for the levelling. The comparison is the levels' in every phase.
    DrawCompare(w)
    local from, to = ns.Range.Bounds(ns.Range.key, ns.Now())
    if followT ~= math.huge then to = math.min(to or followT, followT) end
    local capAt = ns.Range.capAt
    if capAt and ns.Range.phase == "lvl" then to = math.min(to or capAt, capAt) end
    local whole = Stats.Window(index, from, to)
    FillZones(whole)
    FillLife(whole)
end

local function CreateView(frames)
    view = CreateFrame("Frame", nil, frames.window)
    view:SetPoint("TOPLEFT", frames.canvas)
    view:SetPoint("BOTTOMLEFT", frames.canvas)
    view:SetPoint("TOPRIGHT", frames.panel)
    view:SetFrameLevel(frames.canvas:GetFrameLevel() + 60)
    view:EnableMouse(true)
    view:Hide()
    -- The map's frame style around the whole screen.
    viewEdges = CreateFrame("Frame", nil, frames.window, "BackdropTemplate")
    viewEdges:SetPoint("TOPLEFT", view, -4, 4)
    viewEdges:SetPoint("BOTTOMRIGHT", view, 4, -4)
    viewEdges:SetFrameLevel(view:GetFrameLevel() + 30)
    viewEdges:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
    viewEdges:SetBackdropBorderColor(0.6, 0.6, 0.6)
    viewEdges:Hide()
    local bg = view:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetAtlas("UI-Character-Info-General-BG")

    ui.range = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.range:SetPoint("TOPRIGHT", -PAD, -14)
    CreateTiles()
    CreateChart()
    CreateCard()
    CreateRecords()
    CreateCompare()
    CreateZones()
    CreateLife()

    view:SetScript("OnShow", function() ns.SafeShow(StatsScreen.Redraw, StatsScreen) end)
    view:SetScript("OnSizeChanged", function()
        ns.SafeShow(function()
            Layout()
            StatsScreen:Redraw()
        end)
    end)
end

function StatsScreen:Show(frames)
    if not view then CreateView(frames) end
    viewEdges:Show()
    Layout()
    if view:IsShown() then self:Redraw() else view:Show() end
end

function StatsScreen:Hide()
    if not view then return end
    view:Hide()
    viewEdges:Hide()
    GameTooltip_Hide()
end

function StatsScreen:Follow(t)
    followT = t or math.huge
    self:Redraw()
end

function StatsScreen:Rebuild()
    dirty = true
    self:Redraw()
end

ns.Screens:Add("stats", "Stats", StatsScreen)
