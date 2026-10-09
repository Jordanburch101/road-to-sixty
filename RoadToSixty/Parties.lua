local _, ns = ...

-- Shows the groups recorded by Groups.lua (issue #16): who was in each,
-- as a row of portraits drawn from saved data (the client's portrait for
-- the member's race and sex, in a ring of their class colour), overlapping
-- tightly and spreading out when hovered, with a tooltip of who they were,
-- how often the character grouped with each, and what the group did.
--
-- Live portraits of the real faces exist only while the game runs, so the
-- map uses the race portraits throughout and always looks the same.

local Parties = {}
ns.Parties = Parties

local RACE_PORTRAIT = "Interface\\CharacterFrame\\TemporaryPortrait-%s-%s"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DISC = 452111         -- interface/guildframe/guildlogomask_l: a white disc
local MAX_SHOWN = 5         -- portraits in a row; more shows as "+N"
local FORMING = 10          -- seconds after a group starts in which members count as there from its start
local OVERLAP = 0.45        -- share of a portrait the next one covers, at rest
local SPREAD = 0.3          -- and when hovered
local SPREAD_SPEED = 12     -- higher settles the spreading faster
local MAX_KNOWN = 10        -- players listed in a raid's tooltip
local BIG_RAID = 4          -- raids with more others than this are summed up by class

-- Race file names as players know them.
local RACE_NAMES = { NightElf = "Night Elf", Scourge = "Undead" }

local function RaceName(race)
    return race and (RACE_NAMES[race] or race:gsub("(%l)(%u)", "%1 %2")) or "?"
end
Parties.RaceName = RaceName

-- Everything about the group a grp event started: { kind (at its end),
-- leader, start, finish (nil while it lasts), members, summary (from its
-- grpx) }. members lists everyone who was ever in it, once each, in the
-- order they came: { m = member as they joined, joined = time they came
-- for those who came after it formed, left = time they last left (nil if
-- there at the end), endLevel = their level when they left or it ended, sub = their
-- raid subgroup at the end }, mySub = the player's, and instances = the
-- dungeons and raids entered while in it: { name, type }, each once.
local cache = setmetatable({}, { __mode = "k" })
function Parties:Info(e)
    local info = cache[e]
    if info then return info end
    info = { kind = e[6], leader = e[8], start = e[1], members = {}, mySub = e[9], instances = {} }
    local byGuid = {}
    local function Add(m, joined)
        local entry = byGuid[m[1]]
        if entry then
            entry.left = nil
        else
            entry = { m = m, joined = joined, sub = m[8] }
            byGuid[m[1]] = entry
            info.members[#info.members + 1] = entry
        end
    end
    for _, m in ipairs(e[7] or {}) do
        Add(m, nil)
    end
    local found = false
    for _, other in ipairs(ns.view.events) do
        local kind = other[2]
        if other == e then
            found = true
        elseif found then
            if kind == "grpa" then
                -- In its first seconds the client was still loading who was
                -- in it (see Groups.lua); those were there from the start.
                Add(other[6], other[1] - e[1] > FORMING and other[1] or nil)
            elseif kind == "grpl" then
                local entry = byGuid[other[6]]
                if entry then
                    entry.left, entry.endLevel = other[1], other[7] or entry.endLevel
                end
            elseif kind == "grpk" then
                info.kind = other[6]
            elseif kind == "grps" then
                if other[6] == false then
                    info.mySub = other[7]
                elseif byGuid[other[6]] then
                    byGuid[other[6]].sub = other[7]
                end
            elseif kind == "in" then
                -- Instances entered while grouped, by name, each once.
                local name = other[7] or "an instance"
                if not info.instances[name] then
                    info.instances[name] = true
                    info.instances[#info.instances + 1] = { name, other[8] }
                end
            elseif kind == "grpx" then
                info.summary, info.finish = other[6], other[1]
                for guid, level in pairs(other[6].levels or {}) do
                    if byGuid[guid] then byGuid[guid].endLevel = level end
                end
                break
            elseif kind == "grp" then
                break
            end
        end
    end
    cache[e] = info
    return info
end

-- Forgets what Info worked out, after the journey shown changed.
function Parties:Reset()
    wipe(cache)
end

-- The players met in the journey shown (Groups.lua's ns.char.people), or
-- the made-up ones a developer demo set in Parties.demoPeople.
function Parties:PeopleTable()
    return self.demoPeople or ns.view.people or {}
end

-- Shows info (as Info builds it) for the made-up grp event e, for demos.
function Parties:SetDemo(e, info, people)
    cache[e] = info
    self.demoPeople = people
end

-- Portraits -----------------------------------------------------------------------

local function NewPortrait(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.ring = f:CreateTexture(nil, "BORDER")
    f.ring:SetTexture(DISC)
    f.ring:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.ring:SetAllPoints()
    f.pic = f:CreateTexture(nil, "ARTWORK")
    f.pic:SetPoint("CENTER")
    local mask = f:CreateMaskTexture()
    mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(f.pic)
    f.pic:AddMaskTexture(mask)
    return f
end

-- Draws member m ({ guid, name, race, sex, class, level }) on a portrait.
local function SetPortrait(f, m)
    f.ring:SetVertexColor(ns.ClassColor(m[5]))
    if m[3] and m[4] then
        f.pic:SetTexture(RACE_PORTRAIT:format(m[4], m[3]))
        f.pic:SetTexCoord(0, 1, 0, 1)
    else
        -- Race not known: the class icon instead.
        ns.SetClassIcon(f.pic, m[5])
    end
end

-- A row of portraits size pixels high, for SetStack.
function Parties:CreateStack(parent, size)
    local stack = CreateFrame("Frame", nil, parent)
    stack.size, stack.portraits = size, {}
    stack.overlap, stack.target = OVERLAP, OVERLAP
    stack.more = stack:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stack.more:SetShadowOffset(1, -1)
    return stack
end

-- Lays the row out at its current overlap, the first portrait on top.
local function Layout(stack)
    local size, count = stack.size, stack.count or 0
    local step = size * (1 - stack.overlap)
    local width = size + step * math.max(0, count - 1)
    stack:SetSize(width + (stack.more:IsShown() and 18 or 0), size)
    for k = 1, count do
        local f = stack.portraits[k]
        f:ClearAllPoints()
        f:SetPoint("LEFT", (k - 1) * step, 0)
    end
    stack.more:ClearAllPoints()
    stack.more:SetPoint("LEFT", width + 2, 0)
    if stack.onResize then stack.onResize(stack) end
end

-- Fills the row with the members of info (from Info), the first ones on
-- top. A raid shows first the players grouped with most in parties.
function Parties:SetStack(stack, info)
    local size = stack.size
    local members = info.members
    if info.kind == "raid" then
        local people = Parties:PeopleTable()
        local function Groups(entry)
            local p = people[entry.m[1]]
            return p and p.groups or 0
        end
        members = { unpack(members) }
        table.sort(members, function(a, b) return Groups(a) > Groups(b) end)
    end
    local shown = math.min(#members, MAX_SHOWN)
    for k = 1, shown do
        local f = stack.portraits[k] or NewPortrait(stack)
        stack.portraits[k] = f
        f:SetSize(size, size)
        f.pic:SetSize(size * 0.86, size * 0.86)
        f:SetFrameLevel(stack:GetFrameLevel() + MAX_SHOWN - k + 1)
        SetPortrait(f, members[k].m)
        f:Show()
    end
    for k = shown + 1, #stack.portraits do
        stack.portraits[k]:Hide()
    end
    stack.count = shown
    stack.more:SetShown(#info.members > shown)
    stack.more:SetText("+" .. (#info.members - shown))
    stack.overlap, stack.target = OVERLAP, OVERLAP
    stack:SetScript("OnUpdate", nil)
    Layout(stack)
end

-- Spreads the row out (true) or closes it up again, animated.
function Parties:Spread(stack, open)
    stack.target = open and SPREAD or OVERLAP
    stack:SetScript("OnUpdate", function(self, elapsed)
        local d = self.target - self.overlap
        if math.abs(d) < 0.002 then
            self.overlap = self.target
            self:SetScript("OnUpdate", nil)
        else
            self.overlap = self.overlap + d * math.min(1, elapsed * SPREAD_SPEED)
        end
        Layout(self)
    end)
end

-- Text ------------------------------------------------------------------------------

local function Duration(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 60 then return "under a minute" end
    local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if h > 0 then return ("%dh %dm"):format(h, m) end
    return ("%dm"):format(m)
end

-- "1 group", "3 groups".
local function Count(n, word)
    return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

local function Names(info, most)
    local names = {}
    for k = 1, math.min(#info.members, most) do
        names[k] = info.members[k].m[2] or "?"
    end
    local text = table.concat(names, ", ")
    if #info.members > most then
        text = text .. (" and %d more"):format(#info.members - most)
    end
    return text
end

-- A raid too big to list everyone: more than a party holds.
local function Big(info)
    return info.kind == "raid" and #info.members > BIG_RAID
end

-- How to show a grp event: title and detail (what kind of group).
function Parties:Describe(e)
    local info = self:Info(e)
    local raid = info.kind == "raid"
    local detail = raid and "Raid" or "Party"
    if info.summary then
        detail = detail .. ", " .. Duration(info.summary.duration)
    end
    if #info.members == 0 then
        return raid and "Joined a raid" or "Joined a group", detail
    elseif Big(info) then
        return ("Raided with %d players"):format(#info.members), detail
    end
    return "Grouped with " .. Names(info, 3), detail
end

-- Players met in the journey shown, the ones grouped with most in parties
-- first: { guid, p }.
function Parties:People()
    local list = {}
    for guid, p in pairs(Parties:PeopleTable()) do
        list[#list + 1] = { guid, p }
    end
    -- Parties first: raid members are mostly people met once.
    table.sort(list, function(a, b)
        local pa, pb = a[2], b[2]
        if (pa.groups or 0) ~= (pb.groups or 0) then return (pa.groups or 0) > (pb.groups or 0) end
        if (pa.seconds or 0) ~= (pb.seconds or 0) then return (pa.seconds or 0) > (pb.seconds or 0) end
        return (pa.raids or 0) > (pb.raids or 0)
    end)
    return list
end

-- Card -------------------------------------------------------------------------------

-- Hovering a group shows a card (picked over a compact tooltip): a row per
-- member with their portrait, name, level, race and class, how often the
-- character grouped with them and what happened to them in this group,
-- then what the group did. A big raid counts its classes and lists only
-- the players the character has also grouped with in parties.

local LIGHT = { 0.82, 0.82, 0.82 }
local CARD_WIDTH, CARD_ROW, CARD_PORTRAIT, CARD_PAD = 300, 38, 30, 10
local CARD_HEADER = 40      -- title and date

local card

local function Clock(t)
    return tostring(date("%H:%M", t))
end

-- Short notes on a member in this group: met here, levelled, and when they
-- came and went if not there from start to end.
local function Tags(entry, p, e, info)
    local tags = {}
    if p and p.first == e[1] then
        tags[#tags + 1] = "|cff73ff73new|r"
    end
    local m = entry.m
    if m[6] and entry.endLevel and entry.endLevel > m[6] then
        tags[#tags + 1] = ("|cffffd100%d to %d|r"):format(m[6], entry.endLevel)
    end
    local sub = entry.sub or m[8]
    if sub and info and info.kind == "raid" then
        tags[#tags + 1] = sub == info.mySub and "|cff73ff73your group|r" or ("group " .. sub)
    end
    if entry.joined and entry.left then
        tags[#tags + 1] = Clock(entry.joined) .. " - " .. Clock(entry.left)
    elseif entry.joined then
        tags[#tags + 1] = "joined " .. Clock(entry.joined)
    elseif entry.left then
        tags[#tags + 1] = "left " .. Clock(entry.left)
    end
    return tags
end

-- What the group did, on one line: the instances it went into by name.
local function Did(s, info)
    local parts = {}
    for _, instance in ipairs(info.instances) do
        parts[#parts + 1] = instance[1]
    end
    if s.kills > 0 then parts[#parts + 1] = Count(s.kills, "kill") end
    if s.quests > 0 then parts[#parts + 1] = Count(s.quests, "quest") end
    if s.deaths > 0 then parts[#parts + 1] = Count(s.deaths, "death") end
    if s.xp > 0 then parts[#parts + 1] = ns.Commas(s.xp) .. " xp" end
    return table.concat(parts, ", ")
end

-- A big raid's classes, most first, each in its colour: "8 Warrior, 5 Priest".
local function Classes(info)
    local classes, order = {}, {}
    for _, entry in ipairs(info.members) do
        local class = entry.m[5] or "?"
        if not classes[class] then order[#order + 1] = class end
        classes[class] = (classes[class] or 0) + 1
    end
    table.sort(order, function(a, b) return classes[a] > classes[b] end)
    local parts = {}
    for _, class in ipairs(order) do
        local r, g, b = ns.ClassColor(class)
        parts[#parts + 1] = ("|cff%02x%02x%02x%d %s|r"):format(r * 255, g * 255, b * 255,
            classes[class], ns.ClassName(class))
    end
    return table.concat(parts, ", ")
end

local function CreateCard()
    card = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    card:SetFrameStrata("TOOLTIP")
    card:SetClampedToScreen(true)
    card:SetWidth(CARD_WIDTH)
    card:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    card:SetBackdropColor(0.04, 0.04, 0.05, 0.94)
    card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    card.title:SetPoint("TOPLEFT", CARD_PAD, -CARD_PAD)
    card.led = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.led:SetPoint("TOPRIGHT", -CARD_PAD, -CARD_PAD - 3)
    card.led:SetTextColor(unpack(LIGHT))
    card.when = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.when:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -3)
    card.when:SetTextColor(unpack(LIGHT))
    card.classes = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.classes:SetPoint("TOPLEFT", CARD_PAD, -CARD_HEADER - CARD_PAD + 4)
    card.classes:SetWidth(CARD_WIDTH - 2 * CARD_PAD)
    card.classes:SetJustifyH("LEFT")
    card.known = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.rows = {}
    card.rule = card:CreateTexture(nil, "ARTWORK")
    card.rule:SetHeight(1)
    card.rule:SetColorTexture(1, 0.82, 0, 0.35)
    card.footer = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.footer:SetJustifyH("LEFT")
    card.footer:SetWidth(CARD_WIDTH - 2 * CARD_PAD)
end

local function CardRow(k)
    local row = card.rows[k]
    if row then return row end
    row = CreateFrame("Frame", nil, card)
    row:SetSize(CARD_WIDTH - 2 * CARD_PAD, CARD_ROW)
    row.portrait = NewPortrait(row)
    row.portrait:SetSize(CARD_PORTRAIT, CARD_PORTRAIT)
    row.portrait.pic:SetSize(CARD_PORTRAIT * 0.86, CARD_PORTRAIT * 0.86)
    row.portrait:SetPoint("LEFT")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row.portrait, "TOPRIGHT", 8, -1)
    row.what = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.what:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.count:SetPoint("TOPRIGHT", 0, -2)
    row.tags = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.tags:SetPoint("TOPRIGHT", row.count, "BOTTOMRIGHT", 0, -3)
    row.tags:SetTextColor(unpack(LIGHT))
    card.rows[k] = row
    return row
end

local function FillCard(e)
    local info = Parties:Info(e)
    local people = Parties:PeopleTable()
    card.title:SetText(("%s of %d"):format(info.kind == "raid" and "Raid" or "Party", #info.members + 1))
    card.led:SetText(info.leader and "you led it" or "")
    card.when:SetText((tostring(date("%A %d %B, %H:%M", info.start)):gsub(" 0", " ")))
    local y = CARD_PAD + CARD_HEADER
    local list = info.members
    if Big(info) then
        card.classes:SetText(Classes(info))
        card.classes:Show()
        y = y + card.classes:GetStringHeight() + 8
        list = {}
        for _, entry in ipairs(info.members) do
            local p = people[entry.m[1]]
            if p and (p.groups or 0) > 0 then list[#list + 1] = entry end
        end
        -- The rows are only the players also grouped with in parties.
        card.known:ClearAllPoints()
        card.known:SetPoint("TOPLEFT", CARD_PAD, -y)
        card.known:SetText(#list == 0 and "No one you have grouped with before"
            or ("%d you have grouped with before"):format(#list))
        card.known:Show()
        y = y + card.known:GetStringHeight() + 6
    else
        card.classes:Hide()
        card.known:Hide()
    end
    local shown = math.min(#list, MAX_KNOWN)
    for k = 1, shown do
        local entry = list[k]
        local m, p = entry.m, people[entry.m[1]]
        local row = CardRow(k)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", CARD_PAD, -y)
        SetPortrait(row.portrait, m)
        row.name:SetText(m[2] or "?")
        row.name:SetTextColor(ns.ClassColor(m[5]))
        row.what:SetText(("%s %s %s"):format(m[6] and ("Level " .. m[6]) or "", RaceName(m[3]), ns.ClassName(m[5])))
        local groups = p and ((p.groups or 0) + (p.raids or 0)) or 0
        row.count:SetText(groups > 1 and Count(groups, "group") or "")
        row.tags:SetText(table.concat(Tags(entry, p, e, info), ", "))
        row:Show()
        y = y + CARD_ROW
    end
    for k = shown + 1, #card.rows do
        card.rows[k]:Hide()
    end
    local s = info.summary
    local did = s and Did(s, info) or ""
    local footer = s and ("|cffffd100Together %s|r%s"):format(Duration(s.duration),
        did ~= "" and ("\n" .. did) or "") or "|cffffd100Still together|r"
    card.rule:ClearAllPoints()
    card.rule:SetPoint("TOPLEFT", CARD_PAD, -(y + 4))
    card.rule:SetPoint("TOPRIGHT", -CARD_PAD, -(y + 4))
    card.footer:ClearAllPoints()
    card.footer:SetPoint("TOPLEFT", CARD_PAD, -(y + 12))
    card.footer:SetText(footer)
    card:SetHeight(y + 16 + card.footer:GetStringHeight() + CARD_PAD)
end

-- Shows the card of the group grp event e next to owner, on its right, or
-- on its left with side "left".
function Parties:ShowCard(owner, e, side)
    if not card then CreateCard() end
    FillCard(e)
    card:ClearAllPoints()
    if side == "left" then
        card:SetPoint("TOPRIGHT", owner, "TOPLEFT", -4, 0)
    else
        card:SetPoint("TOPLEFT", owner, "TOPRIGHT", 4, 0)
    end
    card:Show()
end

function Parties:HideCard()
    if card then card:Hide() end
end
