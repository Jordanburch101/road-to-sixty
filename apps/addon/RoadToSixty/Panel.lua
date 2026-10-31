local _, ns = ...

-- Side panel of the journey map. History lists the journey's milestones,
-- travel, loot and dungeon runs, newest first, with a filter; clicking one
-- jumps the map and replay to that moment. Characters lists the account's
-- characters from the roster. The numbers are on the Stats screen
-- (StatsScreen.lua), a mode of the map window.

local Panel = { WIDTH = 280 }
ns.Panel = Panel

local TAB_HEIGHT = 24
local HISTORY_ROW = 32
local NEST_INDENT = 12      -- how far rows folded under a run move in when it is open
-- Runs opened to show what happened inside: run key -> true. For this
-- session only; each run starts folded (FilterHistory).
local expanded = {}
local CHARACTER_ROW = 34
local SCROLL_STEP = 3

local tabs, panes = {}, {}
local historyList, characterList
local currentTime = math.huge   -- replay time History follows; math.huge at the end
local currentIndex              -- index in historyList.data of the entry at currentTime

local function ZoneName(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and info.name or "Unknown"
end

local function FormatDuration(seconds)
    if not seconds then return "-" end
    seconds = math.floor(seconds)
    local d, h, m = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60)
    if d > 0 then return ("%dd %dh"):format(d, h) end
    if h > 0 then return ("%dh %dm"):format(h, m) end
    return ("%dm"):format(m)
end
ns.FormatDuration = FormatDuration

local function Commas(n)
    local s, count = tostring(math.floor(n)), 0
    repeat
        s, count = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until count == 0
    return s
end
ns.Commas = Commas

-- Scrolling list ---------------------------------------------------------------

-- A list that only creates enough rows to fill its height. createRow(parent)
-- makes a row; updateRow(row, item) fills it in. Set list.data, then Refresh.
local function CreateList(parent, rowHeight, createRow, updateRow)
    local list = CreateFrame("Frame", nil, parent)
    list.data = {}
    local rows, visibleRows, offset = {}, 0, 0

    local bar = CreateFrame("Slider", nil, list)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(10)
    bar:SetPoint("TOPRIGHT")
    bar:SetPoint("BOTTOMRIGHT")
    bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    bar:SetValueStep(1)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOP")
    track:SetPoint("BOTTOM")
    track:SetWidth(4)
    track:SetColorTexture(0, 0, 0, 0.5)

    local function MaxOffset()
        return math.max(0, #list.data - visibleRows)
    end

    local function Fill()
        for i = 1, visibleRows do
            local item = list.data[offset + i]
            if item then
                updateRow(rows[i], item)
            end
            rows[i]:SetShown(item ~= nil)
        end
        for i = visibleRows + 1, #rows do
            rows[i]:Hide()
        end
    end

    local function SetOffset(value)
        offset = math.max(0, math.min(MaxOffset(), math.floor(value + 0.5)))
        bar:SetValue(offset)
        Fill()
    end

    -- Makes enough rows for the current height.
    local function EnsureRows()
        visibleRows = math.max(0, math.floor(list:GetHeight() / rowHeight))
        for i = #rows + 1, visibleRows do
            local row = createRow(list)
            row:SetHeight(rowHeight)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
            row:SetPoint("RIGHT", bar, "LEFT", -2, 0)
            rows[i] = row
        end
    end

    function list:Refresh()
        EnsureRows()
        local max = MaxOffset()
        bar:SetMinMaxValues(0, max)
        bar:SetShown(max > 0)
        SetOffset(offset)
    end

    function list:ScrollToTop()
        SetOffset(0)
    end

    -- Scrolls so item index is the first row showing.
    function list:ScrollTo(index)
        SetOffset(index - 1)
    end

    bar:SetScript("OnValueChanged", function(_, value)
        if math.floor(value + 0.5) ~= offset then
            SetOffset(value)
        end
    end)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        SetOffset(offset - delta * SCROLL_STEP)
    end)
    list:SetScript("OnSizeChanged", function()
        list:Refresh()
    end)
    return list
end

-- History ------------------------------------------------------------------------

local function CreateHistoryRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetPoint("CENTER", row, "LEFT", 14, 0)
    row.quality = row:CreateTexture(nil, "OVERLAY")
    row.quality:SetAllPoints(row.icon)
    row.number = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.number:SetPoint("CENTER", row.icon, 0.5, 0)

    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.time:SetPoint("TOPRIGHT", -4, -5)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", 30, -3)
    row.title:SetPoint("RIGHT", row.time, "LEFT", -4, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
    row.detail:SetPoint("RIGHT", -4, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    -- Day headers: gold text over a thin gold rule.
    row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.header:SetPoint("BOTTOMLEFT", 4, 6)
    row.rule = row:CreateTexture(nil, "ARTWORK")
    row.rule:SetPoint("BOTTOMLEFT", 2, 3)
    row.rule:SetPoint("BOTTOMRIGHT", -2, 3)
    row.rule:SetHeight(1)
    row.rule:SetColorTexture(1, 0.82, 0, 0.35)

    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 1, 1, 0.08)

    -- Marks the entry the replay is at: a gold bar and a faint gold wash.
    row.current = row:CreateTexture(nil, "BACKGROUND")
    row.current:SetAllPoints()
    row.current:SetColorTexture(1, 0.82, 0, 0.12)
    row.currentBar = row:CreateTexture(nil, "ARTWORK")
    row.currentBar:SetPoint("TOPLEFT")
    row.currentBar:SetPoint("BOTTOMLEFT")
    row.currentBar:SetWidth(2)
    row.currentBar:SetColorTexture(1, 0.82, 0, 0.9)

    -- A run with rows folded under it: a plus or minus over its icon, as the
    -- classic quest log has; the rows under it are moved in, by a thin line.
    row.expand = row:CreateTexture(nil, "OVERLAY", nil, 2)
    row.expand:SetSize(12, 12)
    row.expand:SetPoint("CENTER", row.icon, "BOTTOMRIGHT", -1, 2)
    row.nest = row:CreateTexture(nil, "ARTWORK")
    row.nest:SetPoint("TOPLEFT", 10, 0)
    row.nest:SetPoint("BOTTOMLEFT", 10, 0)
    row.nest:SetWidth(1)
    row.nest:SetColorTexture(1, 0.6, 0.2, 0.45)

    row:SetScript("OnClick", function(self)
        local item = self.item
        if item.header then return end
        if (item.children or 0) > 0 then Panel:ToggleRun(item.key) end
        ns.Map:JumpTo(item.t, item.c, item.x, item.y)
    end)
    -- Loot shows the item's own tooltip; dungeon runs list their summary.
    row:SetScript("OnEnter", function(self)
        local item = self.item
        if item.link then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink(item.link)
            GameTooltip:Show()
        elseif item.group then
            ns.Parties:ShowCard(self, item.group, "left")
        elseif item.rare then
            ns.Rares:ShowCard(self, item.rare, item.where, "left")
        elseif item.run then
            ns.Parties:ShowRunCard(self, item.run, item.entered, "left")
        elseif item.lines then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(item.title)
            for _, line in ipairs(item.lines) do
                GameTooltip:AddLine(line, 1, 1, 1)
            end
            GameTooltip:Show()
        elseif item.kind == "lvl" then
            -- The row shows the place only; its tooltip also says if a screenshot was taken.
            local detail = ns.LevelShot:Detail(item.level, item.detail)
            if not ns.GearCard:Show(item.level, self, item.title, detail) then
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:AddLine(item.title)
                GameTooltip:AddLine(detail, 1, 1, 1)
                GameTooltip:Show()
            end
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip_Hide()
        ns.GearCard:Hide()
        ns.Parties:HideCard()
        ns.Rares:HideCard()
    end)
    return row
end

-- Title colour per kind; loot keeps its link's quality colour.
local TITLE_COLORS = {
    lvl = { 1, 0.82, 0 },
    die = { 0.9, 0.45, 0.45 },
    ["in"] = { 1, 0.6, 0.2 },
    run = { 1, 0.6, 0.2 },
    hearth = { 0.55, 0.85, 1 },
    teleport = { 0.55, 0.85, 1 },
    boat = { 0.55, 0.85, 1 },
    flight = { 0.55, 0.85, 1 },
    qd = { 1, 0.9, 0.55 },
    prof = { 0.6, 0.9, 1 },
    rec = { 0.8, 0.9, 1 },
    gj = { 0.25, 1, 0.25 },
    gl = { 0.25, 1, 0.25 },
    gr = { 0.25, 1, 0.25 },
    grp = { 0.67, 0.67, 1 },
    ride = { 1, 0.75, 0.45 },
    mount = { 1, 0.75, 0.45 },
    rare = { 0.85, 0.88, 1 },
}

local function UpdateHistoryRow(row, item)
    row.item = item
    -- Follow the replay: the current entry is marked, later ones are dimmed.
    local current = item == historyList.data[currentIndex] and currentTime ~= math.huge
    row.current:SetShown(current)
    row.currentBar:SetShown(current)
    row:SetAlpha((item.t > currentTime and not current) and 0.35 or 1)
    local header = item.header ~= nil
    if row.badge then row.badge:Hide() end
    if row.stack then row.stack:Hide() end
    row.header:SetShown(header)
    row.rule:SetShown(header)
    row.highlight:SetShown(not header)
    for _, part in ipairs({ row.icon, row.number, row.title, row.detail, row.time }) do
        part:SetShown(not header)
    end
    local folds = not header and (item.children or 0) > 0 and item.key
    row.expand:SetShown(folds and true or false)
    if folds then
        row.expand:SetTexture(expanded[item.key] and "Interface\\Buttons\\UI-MinusButton-Up"
            or "Interface\\Buttons\\UI-PlusButton-Up")
    end
    row.nest:SetShown(not header and item.nested or false)
    local indent = (not header and item.nested) and NEST_INDENT or 0
    row.icon:SetPoint("CENTER", row, "LEFT", 14 + indent, 0)
    row.title:SetPoint("TOPLEFT", 30 + indent, -3)
    if header then
        row.quality:Hide()
        row.header:SetText(item.header)
        return
    end

    local size = ns.SetEventIcon(row.icon, row.number, item.kind, item.level, item.iconFile)
    row.icon:SetSize(size, size)
    -- Guild entries show the guild's banner instead.
    if item.guild then
        if not row.badge then
            row.badge = ns.Guilds:CreateBadge(row, HISTORY_ROW - 4)
            row.badge:SetPoint("CENTER", row.icon)
        end
        ns.Guilds:SetBadge(row.badge, item.tabard)
        row.badge:Show()
        row.icon:Hide()
    end
    -- Groups show the first member's portrait.
    if item.group then
        if not row.stack then
            row.stack = ns.Parties:CreateStack(row, HISTORY_ROW - 8)
            row.stack:SetPoint("CENTER", row.icon)
        end
        local members = ns.Parties:Info(item.group).members
        ns.Parties:SetStack(row.stack, { members = { members[1] } })
        row.stack:SetShown(members[1] ~= nil)
        row.icon:SetShown(members[1] == nil)
    end
    ns.SetQualityOverlay(row.quality, item.kind == "loot" and item.quality or nil)
    row.title:SetText(item.title)
    row.title:SetTextColor(unpack(item.color or TITLE_COLORS[item.kind] or { 1, 1, 1 }))
    row.detail:SetText(item.detail)
    row.time:SetText(date("%H:%M", item.t))
end

-- Filter groups above the list, one icon each: { label, icon, members },
-- icon as { kind, level } for ns.SetEventIcon or { atlas = name }, members as
-- { key, label }. Left-click turns a whole group on or off, right-click picks
-- its members. ns.db.historyFilter[key] is false when hidden; the map's
-- markers follow the same keys.
local HISTORY_FILTERS = {
    { "Levels", { "lvl", 10 }, { { "levels", "Levels" } } },
    { "Deaths", { "die" }, { { "deaths", "Deaths" } } },
    { "Rare mobs", { "rare" }, { { "rares", "Rare mobs killed" } } },
    { "Dungeons", { "run" }, { { "dungeons", "Dungeons" }, { "battlegrounds", "Battlegrounds" } } },
    { "Travel", { "flight" }, {
        { "flights", "Flight paths" }, { "hearths", "Hearthstones" },
        { "teleports", "Teleports" }, { "boats", "Boats and zeppelins" },
    } },
    { "New zones", { "zone" }, { { "zones", "New zones" } } },
    { "Quests", { "qd" }, { { "quests", "Quests turned in" } } },
    { "Loot", { atlas = "Banker" }, {
        { "greens", "Green items" }, { "blues", "Blue items and better" },
        { "enchants", "Enchants" },
    } },
    { "Learned", { atlas = "Profession" }, {
        { "professions", "Professions" }, { "recipes", "Recipes" },
        { "mining", "Mining" }, { "herbs", "Herbalism" }, { "fishing", "Fishing" },
        { "reps", "Reputation" }, { "mounts", "Riding and mounts" },
    } },
    { "Social", { atlas = "socialqueuing-icon-group" }, { { "groups", "Groups" }, { "guilds", "Guild" } } },
}
-- Buttons are spread evenly across the pane; every icon is drawn the same
-- size, whatever its size on the map, so the row looks even.
local FILTER_SIZE, FILTER_ICON, FILTER_MARGIN = 28, 24, 4

-- Shorter flight segments are left out: stray samples around take-off and landing.
local MIN_FLIGHT_SECONDS = 15

-- Jump reasons (seg.j in Recorder.lua) listed as travel, and their kind.
-- The title is the jump's label in Style.lua.
local TRAVEL_JUMPS = { h = "hearth", p = "teleport", u = "teleport", b = "boat" }

local historyItems = {}     -- every history item, before the filter

local function Category(item)
    if item.kind == "loot" then
        return item.quality >= 3 and "blues" or "greens"
    end
    if item.kind == "gath" then
        return ns.Gathering.CATEGORY[item.prof]
    end
    if item.battleground then
        return "battlegrounds"
    end
    return ns.Style.CATEGORY[item.kind]
end

-- Shows the items the filter allows, with a header row starting each day.
-- What happened inside an instance folds under its run's row (counted in
-- its children) unless the run is opened; without a run row shown (still
-- inside, or dungeons filtered out) it shows as any other row.
local function FilterHistory()
    local shown, day, runs = {}, nil, {}
    for _, item in ipairs(historyItems) do
        if item.key and ns.db.historyFilter[Category(item)] ~= false then
            runs[item.key] = item
            item.children = 0
        end
    end
    for _, item in ipairs(historyItems) do
        if ns.db.historyFilter[Category(item)] ~= false then
            local run = item.parent and runs[item.parent]
            item.nested = run ~= nil
            if run then run.children = run.children + 1 end
            if not run or expanded[item.parent] then
                local itemDay = tostring(date("%A %d %B", item.t)):gsub(" 0", " ")
                if itemDay ~= day then
                    day = itemDay
                    -- A header takes its day's newest time, keeping the list in time order.
                    shown[#shown + 1] = { header = itemDay, t = item.t }
                end
                shown[#shown + 1] = item
            end
        end
    end
    historyList.data = shown
    -- The current entry's index changed with the list, so find it again.
    currentIndex = nil
    Panel:SetTime(currentTime, true)
    historyList:Refresh()
end

-- Opens or folds the run with this key.
function Panel:ToggleRun(key)
    expanded[key] = not expanded[key] or nil
    FilterHistory()
end

local function FormatMoney(copper)
    local sign = copper < 0 and "-" or ""
    copper = math.abs(copper)
    return ("%s%dg %ds %dc"):format(sign, math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

-- Returns a function giving the zone (uiMapID) the player was in at a time.
local function ZoneTimeline()
    local times, zones = {}, {}
    for _, e in ipairs(ns.view.events) do
        if e[2] == "zone" then
            times[#times + 1], zones[#zones + 1] = e[1], e[6]
        end
    end
    return function(t)
        return zones[ns.LastIndex(times, t)]
    end
end

-- Everything for the History tab, newest first: from the journal (levels,
-- deaths, instances and their summaries, first visits to zones, loot) and
-- from the recorded path (hearthstones, teleports, boats, flight paths).
-- Zones first seen during a flight are listed with the flight instead of on
-- their own. Each item: { kind, title, detail, t, c, x, y } plus level,
-- quality, link, iconFile or lines where they apply. Rows that fold others
-- under them have key, and from, when what they hold began; the rows under
-- them have parent, that key, so FilterHistory can fold them: what happens
-- inside a dungeon, raid or battleground (its "Entered" row included) under
-- its run ("run:" and when it was entered), and the green and better items
-- a gather gave (silver ore, a gem) under the gather ("gath:" and its time).
local function BuildHistory()
    local items, seenZones, instanceNames, flights = {}, {}, {}, {}
    local entered = {}      -- instance ID -> when it was last entered
    ns.Parties:Reset()
    local zoneAt = ZoneTimeline()
    local level
    local parent            -- while inside: the run's key
    -- The last gather outdoors, for the loot it gave: { key, t, ids = { [itemID] = true } }.
    -- Its loot comes as each slot is taken, at most the visit's time later (a vein's next charge).
    local gather

    -- Only what is inside the map's date range (Range.lua) is listed.
    local function Add(item, t, c, x, y, detail)
        item.detail = detail or ""
        item.t, item.c, item.x, item.y = t, c, x, y
        item.parent = parent
        if ns.Range:Has(t) then items[#items + 1] = item end
        return item
    end

    -- Travel from the recorded path first, so zone discoveries can join flights.
    local previous
    for _, path in ipairs(ns.Roster:ViewPaths()) do
        local startT, endT = path.t[1], path.t[#path.t]
        local reason = ns.Recorder:JumpReason(previous, path)
        local jump = TRAVEL_JUMPS[reason]
        if jump then
            local from = ZoneName(zoneAt(previous and previous.t[#previous.t] or startT))
            local to = ZoneName(zoneAt(startT))
            local route = from == to and ("In " .. to) or (from .. " to " .. to)
            -- Boats are named after their docks when both ends are near one.
            if path.j == "b" and previous then
                local last = #previous.x
                route = ns.BoatRoute(previous.c, previous.x[last], previous.y[last],
                    path.c, path.x[1], path.y[1]) or route
            end
            Add({ kind = jump, title = ns.Style.Jump(reason)[1] }, startT, path.c, path.x[1], path.y[1], route)
        end
        if path.m == "t" and endT - startT >= MIN_FLIGHT_SECONDS then
            local flight = Add({ kind = "flight", title = "Flight path" }, startT, path.c, path.x[1], path.y[1])
            flight.from, flight.to = ZoneName(zoneAt(startT)), ZoneName(zoneAt(endT))
            flight.endT, flight.zones = endT, {}
            flights[#flights + 1] = flight
        end
        previous = path
    end

    local function FlightAt(t)
        for _, flight in ipairs(flights) do
            if t >= flight.t and t <= flight.endT then
                return flight
            end
        end
    end

    -- The instance the player is inside, between its "in" and "out": what
    -- happens there is named by it, as the map's markers are, not by the
    -- zone outside its door. A run left lately has no "out" yet: it ends
    -- at leftAt, when it was left.
    local inside
    local ownRun = ns.view == ns.char and ns.char.run
    local leftAt = ownRun and ownRun.left and ownRun.left.t or nil
    for _, e in ipairs(ns.view.events) do
        local kind, t, c, x, y = e[2], e[1], e[3], e[4], e[5]
        if kind == "on" or kind == "lvl" then
            level = e[6]
        end
        local runKey
        if kind == "out" then
            inside, runKey, parent = nil, parent, nil
        elseif leftAt and parent and t >= leftAt then
            -- Left, its "out" not logged yet (Journal.lua waits in case of a run back in).
            inside, parent, leftAt = nil, nil, nil
        end
        local where = inside and ("Inside " .. inside) or ZoneName(zoneAt(t))
        if kind == "in" then
            inside, parent = e[7] or "an instance", "run:" .. t
        end

        if kind == "lvl" then
            Add({ kind = kind, level = e[6], title = "Reached level " .. e[6] }, t, c, x, y, where)
        elseif kind == "die" then
            Add({ kind = kind, title = ns.Deaths:Title(e) }, t, c, x, y, ("Level %s - %s"):format(level or "?", where))
        elseif kind == "in" then
            instanceNames[e[6]] = e[7]
            entered[e[6]] = t
            Add({ kind = kind, title = "Entered " .. (e[7] or "an instance"),
                battleground = ns.Battlegrounds.IsPvP(e[8]) }, t, c, x, y,
                ("%s, level %s"):format(ns.InstanceTypes[e[8]] or "Instance", level or "?"))
        elseif kind == "out" and type(e[7]) == "table" then
            local s = e[7]
            local lines = {
                "Time inside: " .. FormatDuration(s.duration),
                ("Kills: %d   XP: %s"):format(s.kills, Commas(s.xp)),
                ("Deaths: %d   Money: %s"):format(s.deaths, FormatMoney(s.money)),
            }
            if s.levels > 0 then
                lines[#lines + 1] = ("Levels gained: %d"):format(s.levels)
            end
            for _, link in ipairs(s.items) do
                lines[#lines + 1] = link
            end
            -- The run's card shows it with who was in it; lines are for runs
            -- saved without their own name, which have no card.
            local battleground = ns.Battlegrounds.IsPvP(s.type)
            Add({ kind = "run", title = s.name or instanceNames[e[6]] or "Instance", lines = lines,
                run = s.name and e or nil, entered = entered[e[6]] or (t - s.duration), battleground = battleground,
                key = runKey, from = runKey and tonumber(runKey:match("%d+")) },
                t, c, x, y, battleground and ns.Battlegrounds:Detail(s, FormatDuration)
                    or ("%s, %d kills, %d items"):format(FormatDuration(s.duration), s.kills, #s.items))
        elseif kind == "zone" and not seenZones[e[6]] then
            seenZones[e[6]] = true
            local flight = FlightAt(t)
            if flight then
                table.insert(flight.zones, ZoneName(e[6]))
            else
                Add({ kind = kind, title = "Discovered " .. ZoneName(e[6]) }, t, c, x, y, "First visit")
            end
        elseif kind == "qd" then
            local title = ns.Journal:QuestName(e) or ("Quest " .. tostring(e[6]))
            local reward = e[7] and e[7] > 0 and ("+%s xp"):format(Commas(e[7])) or "Turned in"
            if e[8] and e[8] > 0 then
                reward = reward .. ", " .. FormatMoney(e[8])
            end
            Add({ kind = kind, title = title }, t, c, x, y, where .. " - " .. reward)
        elseif kind == "loot" then
            ---@diagnostic disable-next-line: deprecated
            local getIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
            local item = Add({ kind = kind, quality = e[7], link = e[6], title = e[6], iconFile = getIcon and getIcon(e[6]) },
                t, c, x, y, e[8] and (instanceNames[e[8]] or "Instance") or where)
            -- An item the last gather gave, in its visit's time: folded under it.
            local id = tonumber(tostring(e[6]):match("item:(%d+)"))
            if gather and not parent and id and gather.ids[id] and t - gather.t <= ns.Gathering.VISIT_SECONDS then
                item.parent = gather.key
                -- The gather's row goes at its last pickup, so what it folds is under it, not above.
                gather.row.t = math.max(gather.row.t, t)
            end
        elseif kind == "prof" or kind == "rec" then
            local title, detail, icon = ns.Crafts:Describe(e)
            if title then
                Add({ kind = kind, title = title, iconFile = icon }, t, c, x, y, detail .. " - " .. where)
            end
        elseif kind == "grp" then
            local title, detail = ns.Parties:Describe(e)
            Add({ kind = kind, title = title, group = e }, t, c, x, y, detail .. " - " .. where)
        elseif kind == "gj" or kind == "gl" or kind == "gr" then
            local title, detail, icon, tabard = ns.Guilds:Describe(e)
            if title then
                Add({ kind = kind, title = title, iconFile = icon, guild = true, tabard = tabard }, t, c, x, y,
                    detail .. " - " .. where)
            end
        elseif kind == "rep" then
            -- In the colour of the standing reached, as the reputation bars show it.
            local title, detail, icon = ns.Reputation:Describe(e)
            Add({ kind = kind, title = title, iconFile = icon, color = { ns.Reputation:Color(e[7]) } }, t, c, x, y,
                detail .. " - " .. where)
        elseif kind == "ride" or kind == "mount" then
            local title, detail, icon = ns.Mounts:Describe(e)
            Add({ kind = kind, title = title, iconFile = icon }, t, c, x, y,
                ("%s, level %s - %s"):format(detail, level or "?", where))
        elseif kind == "ench" then
            local title, detail, icon = ns.Enchants:Describe(e)
            Add({ kind = kind, title = title, iconFile = icon }, t, c, x, y, detail .. " - " .. where)
        elseif kind == "rare" then
            local title, detail = ns.Rares:Describe(e)
            Add({ kind = kind, title = title, rare = e, where = where }, t, c, x, y, detail .. " - " .. where)
        elseif kind == "gath" and ns.Range:Has(t) then
            -- (checked before Add does: describing asks for each item, and there can be thousands)
            local title, detail, icon, lines = ns.Gathering:Describe(e)
            lines[#lines + 1] = where
            local key = not parent and ("gath:" .. t) or nil
            local row = Add({ kind = kind, prof = e[6], title = title, iconFile = icon, lines = lines, key = key,
                from = t }, t, c, x, y, detail .. " - " .. where)
            -- (inside an instance it is folded under the run, its loot with it)
            gather = key and { key = key, t = t, row = row, ids = ns.Gathering.ParseLoot(e[9]) } or nil
        end
    end

    for _, flight in ipairs(flights) do
        flight.detail = ("%s to %s, %s"):format(flight.from, flight.to, FormatDuration(flight.endT - flight.t))
        local zones = flight.zones
        if #zones > 0 then
            flight.detail = flight.detail .. (", +%d new zone%s"):format(#zones, #zones > 1 and "s" or "")
            flight.lines = { flight.detail, "Discovered on the way: " .. table.concat(zones, ", ") }
        end
    end

    -- At the same second, a row that folds others goes first, above them.
    table.sort(items, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.key ~= nil and b.key == nil
    end)
    return items
end

local function Shown(key)
    return ns.db.historyFilter[key] ~= false
end

local function FiltersChanged()
    FilterHistory()
    ns.Map:RefreshFilters()
end

-- The right-click menu: a check box per member of one group.
local filterMenu

local function ShowFilterMenu(button, group, onChange)
    if not filterMenu then
        filterMenu = CreateFrame("Frame", nil, button:GetParent(), "BackdropTemplate")
        filterMenu:SetFrameStrata("DIALOG")
        filterMenu:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        filterMenu:SetBackdropColor(0, 0, 0, 0.92)
        filterMenu:EnableMouse(true)
        filterMenu.title = filterMenu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        filterMenu.title:SetPoint("TOPLEFT", 10, -8)
        filterMenu.boxes = {}
        -- Closes once the mouse has been away from it and its button for a moment.
        filterMenu:SetScript("OnUpdate", function(self, elapsed)
            if self:IsMouseOver() or (self.owner and self.owner:IsMouseOver()) then
                self.away = 0
            else
                self.away = (self.away or 0) + elapsed
                if self.away > 0.6 then self:Hide() end
            end
        end)
    end
    local menu = filterMenu
    menu.owner, menu.away = button, 0
    menu.title:SetText(group[1])
    for _, box in ipairs(menu.boxes) do
        box:Hide()
    end
    local width = menu.title:GetStringWidth()
    for i, member in ipairs(group[3]) do
        local box = menu.boxes[i]
        if not box then
            box = CreateFrame("CheckButton", nil, menu, "UICheckButtonTemplate")
            box:SetSize(20, 20)
            box:SetPoint("TOPLEFT", 6, -6 - i * 20)
            box.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
            menu.boxes[i] = box
        end
        local key = member[1]
        box.label:SetText(member[2])
        box:SetChecked(Shown(key))
        box:SetScript("OnClick", function(self)
            ns.db.historyFilter[key] = self:GetChecked() and true or false
            onChange()
        end)
        box:Show()
        width = math.max(width, 24 + box.label:GetStringWidth())
    end
    menu:SetSize(width + 20, 14 + (#group[3] + 1) * 20)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", button, "BOTTOMLEFT", -4, -2)
    menu:Show()
end

-- A row of group icons. A group is greyed out when all its members are
-- hidden and dimmed when only some are. Returns the row's height.
local function CreateHistoryFilters(pane)
    local buttons = {}
    -- Spread across the pane's width, first and last FILTER_MARGIN from its sides.
    local function Layout()
        local step = (pane:GetWidth() - 2 * FILTER_MARGIN - FILTER_SIZE) / (#buttons - 1)
        for i, button in ipairs(buttons) do
            button:SetPoint("TOPLEFT", math.floor(FILTER_MARGIN + (i - 1) * step + 0.5), 0)
        end
    end
    pane:HookScript("OnSizeChanged", Layout)

    for _, group in ipairs(HISTORY_FILTERS) do
        local label, look, members = group[1], group[2], group[3]
        local button = CreateFrame("Button", nil, pane)
        button:SetSize(FILTER_SIZE, FILTER_SIZE)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        buttons[#buttons + 1] = button
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("CENTER")
        icon:SetSize(FILTER_ICON, FILTER_ICON)
        local number = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        number:SetPoint("CENTER", icon, 0.5, 0)
        if look.atlas then
            icon:SetAtlas(look.atlas)
            number:SetText("")
        else
            ns.SetEventIcon(icon, number, look[1], look[2])
        end
        local highlight = button:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.12)

        local function CountShown()
            local shown = 0
            for _, member in ipairs(members) do
                if Shown(member[1]) then shown = shown + 1 end
            end
            return shown
        end
        local function Refresh()
            local shown = CountShown()
            local alpha = shown == #members and 1 or shown > 0 and 0.7 or 0.35
            icon:SetDesaturated(shown == 0)
            icon:SetAlpha(alpha)
            number:SetAlpha(alpha)
        end
        local function ShowTooltip()
            GameTooltip:SetOwner(button, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(label)
            if #members > 1 then
                for _, member in ipairs(members) do
                    local on = Shown(member[1])
                    GameTooltip:AddDoubleLine(member[2], on and "Shown" or "Hidden",
                        1, 1, 1, on and 0.4 or 0.6, on and 1 or 0.6, on and 0.4 or 0.6)
                end
                GameTooltip:AddLine(CountShown() > 0 and "Click to hide all, right-click to choose"
                    or "Click to show all, right-click to choose", 0.8, 0.8, 0.8)
            else
                GameTooltip:AddLine(Shown(members[1][1]) and "Shown - click to hide" or "Hidden - click to show",
                    0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end
        local function Changed()
            Refresh()
            FiltersChanged()
        end
        button:SetScript("OnClick", function(_, mouse)
            if mouse == "RightButton" and #members > 1 then
                GameTooltip_Hide()
                ShowFilterMenu(button, group, Changed)
                return
            end
            local show = CountShown() == 0
            for _, member in ipairs(members) do
                ns.db.historyFilter[member[1]] = show
            end
            if filterMenu then filterMenu:Hide() end
            Changed()
            ShowTooltip()
        end)
        button:SetScript("OnEnter", function()
            if not (filterMenu and filterMenu:IsShown() and filterMenu.owner == button) then
                ShowTooltip()
            end
        end)
        button:SetScript("OnLeave", GameTooltip_Hide)
        Refresh()
    end
    Layout()
    return FILTER_SIZE
end

-- Characters ---------------------------------------------------------------------

local function CreateCharacterRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 3, 0)

    row.pathToggle = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.pathToggle:SetSize(22, 22)
    row.pathToggle:SetPoint("RIGHT", -2, 0)
    row.pathToggle:SetScript("OnClick", function(self)
        ns.db.showPaths[row.entry.key] = self:GetChecked() or nil
        ns.Map:RefreshCharacters()
    end)
    row.pathToggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Show this character's path")
        GameTooltip:Show()
    end)
    row.pathToggle:SetScript("OnLeave", GameTooltip_Hide)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", 30, -3)
    row.title:SetPoint("RIGHT", row.pathToggle, "LEFT", -2, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
    row.detail:SetPoint("RIGHT", row.pathToggle, "LEFT", -2, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    -- Marks the character whose journey the map shows.
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.12)

    row:SetScript("OnClick", function(self)
        ns.Map:ShowJourney(self.entry)
    end)
    row:SetScript("OnEnter", function(self)
        local e = self.entry
        if ns.Roster:ViewEntry() == e then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if ns.Roster:IsMe(e) then
            GameTooltip:AddLine("Click to show your own journey again")
        elseif e.journey then
            GameTooltip:AddLine("Click to show " .. (e.name or "?") .. "'s journey")
        else
            GameTooltip:AddLine("Log in on " .. (e.name or "?") .. " once to share its journey")
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

local function UpdateCharacterRow(row, e)
    row.entry = e
    ns.SetClassIcon(row.icon, e.class)
    local me = ns.Roster:IsMe(e)
    local r, g, b = ns.ClassColor(e.class)
    row.title:SetText(("%s  |cffffffff%d|r"):format(e.name or "?", me and UnitLevel("player") or e.level or 0))
    row.title:SetTextColor(r, g, b)

    local parts = {}
    local guild = (me and ns.char or e.journey or {}).guild
    if guild then
        parts[#parts + 1] = "<" .. guild[1] .. ">"
    end
    if e.zone then
        parts[#parts + 1] = ZoneName(e.zone)
    end
    parts[#parts + 1] = me and "playing now" or "seen " .. ns.FormatAgo(e.seen)
    if e.played then
        parts[#parts + 1] = FormatDuration(e.played) .. " played"
    end
    row.detail:SetText(table.concat(parts, " - "))

    -- The shown character's path is the main one on the map already.
    local shown = ns.Roster:ViewEntry() == e
    row.selected:SetShown(shown)
    row.pathToggle:SetShown(not shown)
    row.pathToggle:SetChecked(ns.db.showPaths[e.key] == true)
end

-- Panel --------------------------------------------------------------------------

-- The selected tab is gold and underlined, the others grey.
local function SelectTab(index)
    for i, tab in ipairs(tabs) do
        local selected = i == index
        tab.label:SetTextColor(unpack(selected and { 1, 0.82, 0 } or { 0.6, 0.6, 0.6 }))
        tab.underline:SetShown(selected)
        panes[i]:SetShown(selected)
    end
end

function Panel:Create(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetWidth(self.WIDTH)

    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.35)

    -- Text tabs over a thin divider.
    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 0, -TAB_HEIGHT)
    divider:SetPoint("TOPRIGHT", 0, -TAB_HEIGHT)
    divider:SetHeight(1)
    divider:SetColorTexture(1, 1, 1, 0.15)

    local names = { "History", "Characters" }
    local tabWidth = self.WIDTH / #names
    for i, name in ipairs(names) do
        local tab = CreateFrame("Button", nil, frame)
        tab:SetSize(tabWidth, TAB_HEIGHT)
        tab:SetPoint("TOPLEFT", (i - 1) * tabWidth, 0)
        tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tab.label:SetPoint("CENTER", 0, 1)
        tab.label:SetText(name)
        tab.underline = tab:CreateTexture(nil, "OVERLAY")
        tab.underline:SetPoint("BOTTOMLEFT", 12, 0)
        tab.underline:SetPoint("BOTTOMRIGHT", -12, 0)
        tab.underline:SetHeight(2)
        tab.underline:SetColorTexture(1, 0.82, 0, 0.9)
        local highlight = tab:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.06)
        tab:SetScript("OnClick", function()
            SelectTab(i)
        end)
        tabs[i] = tab

        local pane = CreateFrame("Frame", nil, frame)
        pane:SetPoint("TOPLEFT", 6, -TAB_HEIGHT - 8)
        pane:SetPoint("BOTTOMRIGHT", -6, 6)
        panes[i] = pane
    end

    local filterHeight = CreateHistoryFilters(panes[1])
    historyList = CreateList(panes[1], HISTORY_ROW, CreateHistoryRow, UpdateHistoryRow)
    historyList:SetPoint("TOPLEFT", 0, -filterHeight - 4)
    historyList:SetPoint("BOTTOMRIGHT")
    characterList = CreateList(panes[2], CHARACTER_ROW, CreateCharacterRow, UpdateCharacterRow)
    characterList:SetAllPoints()

    SelectTab(1)
    return frame
end

-- Rebuilds both tabs from the saved journey; called when the map opens.
-- Follows the replay at time t (math.huge at the end of the journey): marks
-- the newest entry at or before t, dims later ones and scrolls to it. Cheap
-- when nothing changed, as the map calls it every replay frame. force finds
-- the entry again even if t is unchanged, after the list itself changed.
function Panel:SetTime(t, force)
    t = t or math.huge
    if (t == currentTime and not force) or not historyList then return end
    local wasEnd = currentTime == math.huge
    currentTime = t
    -- Entries are newest first: find the first one at or before t.
    local data = historyList.data
    local lo, hi = 1, #data + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if data[mid].t <= t then
            hi = mid
        else
            lo = mid + 1
        end
    end
    if data[lo] and data[lo].header then
        lo = lo + 1
    end
    -- Inside a folded run (entered at its key, left at its t), the run is
    -- the entry: what happened in it is hidden under it.
    local above = data[lo - 1]
    if above and above.key and (above.children or 0) > 0 and not expanded[above.key] and (above.from or math.huge) <= t then
        lo = lo - 1
    end
    local index = data[lo] and lo or nil
    -- Same entry: the same rows are dimmed, so nothing to redraw, unless the
    -- replay just left or reached the end (the mark shows only before it).
    if index == currentIndex and wasEnd == (t == math.huge) then return end
    currentIndex = index
    if index then
        -- Leave the row above in view, often the day's header.
        historyList:ScrollTo(t == math.huge and 1 or math.max(1, index - 1))
    end
    historyList:Refresh()
end

function Panel:Refresh()
    historyItems = BuildHistory()
    FilterHistory()
    historyList:ScrollToTop()
    characterList.data = ns.Roster:Entries()
    characterList:Refresh()
end
