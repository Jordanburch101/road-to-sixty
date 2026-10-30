local _, ns = ...

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
local dirty = true
local followT = math.huge   -- the replay's moment
local hoverLevel            -- the level under the cursor on the chart
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
    builtAt, builtFor, dirty, recordsKey = GetTime(), journey, false, nil
    return index
end

-- What the screen covers: the date range, up to the replay's moment.
local function Window()
    local from, to = ns.Range.from, ns.Range.to
    if followT ~= math.huge then to = math.min(to or followT, followT) end
    return Stats.Window(Index(), from, to)
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

local function FillTiles(w)
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
        hoverLevel = self.level
        ns.SafeShow(StatsScreen.Redraw, StatsScreen)
    end)
    col:SetScript("OnLeave", function()
        hoverLevel = nil
        ns.SafeShow(StatsScreen.Redraw, StatsScreen)
    end)
    -- The replay moves to the level up, which moves the screen with it.
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
    title:SetText("Each level")
    ui.chartNote = chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.chartNote:SetPoint("LEFT", title, "RIGHT", 10, 0)
    ui.chartNote:SetText("Hover a level to see it, click to replay from its level up")
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
end

local function DrawChart(w, shown)
    for i, tab in ipairs(ui.metricTabs) do ns.Screens.SetTabOn(tab, i == metric) end
    local m = METRICS[metric]
    local plotW, plotH = ui.plot:GetWidth(), ui.plot:GetHeight()
    local n = #rows
    local top = 0
    for _, row in ipairs(rows) do top = math.max(top, m[2](row) or 0) end
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
    -- The client's own cap, as the gear screen finds it; a journey past it widens the axis.
    local ok, cap = pcall(GetMaxPlayerLevel)
    cap = ok and type(cap) == "number" and cap >= 60 and cap or 60
    for _, row in ipairs(rows) do cap = math.max(cap, row.level) end
    local step = plotW / cap
    ui.axis = ui.axis or {}
    local marks = { 1 }
    for level = 10, cap, 10 do marks[#marks + 1] = level end
    for k, level in ipairs(marks) do
        local label = ui.axis[k] or ui.plot:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        ui.axis[k] = label
        label:ClearAllPoints()
        label:SetPoint("TOP", ui.plot, "BOTTOMLEFT", (level - 0.5) * step, -4)
        label:SetText(tostring(level))
        label:Show()
    end
    for k = #marks + 1, #ui.axis do ui.axis[k]:Hide() end
    for i, row in ipairs(rows) do
        local col = Column(i)
        col.level, col.t = row.level, row.t
        col:ClearAllPoints()
        col:SetPoint("BOTTOMLEFT", (row.level - 1) * step, 0)
        col:SetSize(step, plotH)
        local value = m[2](row) or 0
        local r, g, b = ns.LevelColor(row.level)
        col.bar:SetWidth(math.max(1, step - (step > 8 and 3 or 1)))
        col.bar:SetHeight(math.max(value > 0 and 1 or 0.01, plotH * value / top))
        local inside = w.levelFrom and row.level >= w.levelFrom and row.level <= w.levelTo
        local on = row.level == shown
        if on or inside then
            col.bar:SetColorTexture(r, g, b, on and 1 or row.current and 0.5 or 0.8)
        else
            -- Outside the range or past the replay's moment: grey, whatever the level's colour.
            col.bar:SetColorTexture(0.5, 0.5, 0.5, 0.25)
        end
        for _, edge in ipairs(col.edges) do edge:SetShown(on) end
        col.value:SetShown(on)
        col.value:SetText(metric == 1 and Duration(value) or m[3](value))
        col.glow:SetShown(row.level == hoverLevel)
        col:Show()
    end
    for i = n + 1, #ui.cols do ui.cols[i]:Hide() end
end

-- The level card -----------------------------------------------------------------------

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

local function ZoneName(uiMapID)
    local info = uiMapID and C_Map.GetMapInfo(uiMapID)
    return info and info.name or ""
end

local function FillCard(row)
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

local function Day(t)
    return (tostring(date("%d %b", t)):gsub("^0", ""))
end

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
            GameTooltip:AddLine(spec[2])
            GameTooltip:AddLine(self.value:GetText(), 1, 1, 1)
            GameTooltip:AddLine(self.sub:GetText(), 0.7, 0.7, 0.7)
            GameTooltip:AddLine(spec.gear and "Click to see it on the gear screen" or "Click to see it on the map",
                1, 0.82, 0)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:SetScript("OnClick", function(self)
            if self.record then ns.SafeShow(OpenRecord, spec, self.record) end
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
    local key = w.from .. ":" .. w.to
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
    records = Stats.Records(index, w.from, w.to, rows, timeline)
    recordsKey, recordsAt = key, GetTime()
    return records
end

local function FillRecords(w)
    local found = Records(w)
    for i, spec in ipairs(RECORDS) do
        local row, r = ui.recordRows[i], found[spec[1]]
        row.record = r
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

-- The screen -------------------------------------------------------------------------

local function Layout()
    local width = view:GetWidth() - 2 * PAD
    local tileW = (width - (#ui.tiles - 1) * GAP) / #ui.tiles
    for i, tile in ipairs(ui.tiles) do
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", PAD + (i - 1) * (tileW + GAP), -TOP)
        tile:SetWidth(tileW)
    end
    -- The bottom row: records on the left, the rest to come beside them.
    local below = TOP + TILE_H + GAP + CHART_H + GAP
    ui.records:ClearAllPoints()
    ui.records:SetPoint("TOPLEFT", PAD, -below)
    ui.records:SetPoint("BOTTOMLEFT", PAD, PAD)
    ui.records:SetWidth(width * 0.42)
    LayoutRecords()
end

function StatsScreen:Redraw()
    if not (view and view:IsVisible()) then return end
    local w = Window()
    FillTiles(w)
    local covers = ("%s to %s"):format(Day(w.from), Day(w.to))
    if followT < index.finish then covers = covers .. ", up to the replay's moment" end
    ui.range:SetText(("|cffffd100%s|r  %s"):format(ns.Range:Label(), covers))
    local shown = hoverLevel or w.levelTo
    DrawChart(w, shown)
    FillCard(RowOf(shown) or rows[#rows])
    FillRecords(w)
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
