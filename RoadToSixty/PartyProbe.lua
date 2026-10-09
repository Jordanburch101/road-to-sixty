local _, ns = ...

-- /rts partyprobe: tests portraits of party members for issue #16. Each row
-- is a unit (you, then party1-4) drawn several ways: the live portrait
-- (SetPortraitTexture, which only exists while the game runs and the unit is
-- known), and ways that need only what can be saved (race, sex, class):
-- the client's race portrait files and race icon atlases, and the class
-- icon. Below, the party stacked as on the map, slightly overlapped, both
-- live and from saved data. "Snapshot" copies the live portraits into a
-- second row, to see whether they stay once someone leaves or moves away.
-- Chat lists what the unit functions return.

local SIZE = 40
local CELL = 64
local OVERLAP = 0.3         -- share of a portrait the next one covers
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DISC = 452111         -- interface/guildframe/guildlogomask_l: a white disc
local UNITS = { "player", "party1", "party2", "party3", "party4" }
local SEXES = { [2] = "Male", [3] = "Female" }
-- Made-up party members for the demo row: { race, sex, class }.
local DEMO = {
    { "Human", "Female", "PRIEST" }, { "NightElf", "Male", "DRUID" },
    { "Gnome", "Female", "MAGE" }, { "Orc", "Male", "WARRIOR" },
}

local frame

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function Info(unit)
    local _, race = UnitRace(unit)
    local _, class = UnitClass(unit)
    return {
        name = table.concat({ UnitName(unit) }, "-"), race = race, sex = SEXES[UnitSex(unit)], class = class,
        level = UnitLevel(unit), guid = UnitGUID(unit), visible = UnitIsVisible(unit),
    }
end

-- A round portrait: a disc in the class colour behind, the picture masked
-- round on top. draw(tex) fills the picture and returns false if it cannot.
local function Portrait(parent, size, class, draw)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    local ring = f:CreateTexture(nil, "BORDER")
    ring:SetTexture(DISC)
    ring:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ring:SetAllPoints()
    ring:SetVertexColor(ns.ClassColor(class))
    local pic = f:CreateTexture(nil, "ARTWORK")
    pic:SetPoint("CENTER")
    pic:SetSize(size * 0.86, size * 0.86)
    local mask = f:CreateMaskTexture()
    mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(pic)
    pic:AddMaskTexture(mask)
    local ok = draw(pic)
    f.pic = pic
    return f, ok ~= false
end

-- Ways to draw a portrait: { label, function(tex, unit, info) }.
local WAYS = {
    { "live", function(tex, unit, _)
        if not UnitExists(unit) then return false end
        SetPortraitTexture(tex, unit)
    end },
    { "race file", function(tex, _, i)
        if not (i.race and i.sex) then return false end
        tex:SetTexture(("Interface\\CharacterFrame\\TemporaryPortrait-%s-%s"):format(i.sex, i.race))
    end },
    { "raceicon128", function(tex, _, i)
        local atlas = i.race and i.sex and ("raceicon128-%s-%s"):format(i.race:lower(), i.sex:lower())
        if not (atlas and HasAtlas(atlas)) then return false end
        tex:SetAtlas(atlas)
    end },
    { "raceicon", function(tex, _, i)
        local atlas = i.race and i.sex and ("raceicon-%s-%s"):format(i.race:lower(), i.sex:lower())
        if not (atlas and HasAtlas(atlas)) then return false end
        tex:SetAtlas(atlas)
    end },
    { "class", function(tex, _, i)
        if not i.class then return false end
        ns.SetClassIcon(tex, i.class)
    end },
}

-- The party side by side, each OVERLAP under the next, the first on top.
local function Stack(parent, units, infos, way)
    local f = CreateFrame("Frame", nil, parent)
    local step = SIZE * (1 - OVERLAP)
    f:SetSize(SIZE + step * (#units - 1), SIZE)
    for k, unit in ipairs(units) do
        local p = Portrait(f, SIZE, infos[unit].class, function(tex) return way(tex, unit, infos[unit]) end)
        p:SetPoint("LEFT", (k - 1) * step, 0)
        p:SetFrameLevel(f:GetFrameLevel() + #units - k + 1)
    end
    return f
end

local function Label(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Build()
    if frame then frame:Hide() end
    local units, infos = {}, {}
    for _, unit in ipairs(UNITS) do
        if UnitExists(unit) then
            units[#units + 1] = unit
            infos[unit] = Info(unit)
            local i = infos[unit]
            ns.Print(("%s: %s, %s %s %s, level %s, visible %s, %s"):format(unit, tostring(i.name),
                tostring(i.race), tostring(i.sex), tostring(i.class), tostring(i.level),
                tostring(i.visible), tostring(i.guid)))
        end
    end

    frame = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    local left = 110
    frame:SetSize(left + #WAYS * CELL + 60, 70 + #units * CELL + 240)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.TitleText:SetText("Party portrait probe")

    for w, way in ipairs(WAYS) do
        local fs = Label(frame, way[1], left + (w - 1) * CELL, -30)
        fs:SetWidth(CELL)
        fs:SetJustifyH("CENTER")
    end
    for r, unit in ipairs(units) do
        local y = -46 - (r - 1) * CELL
        Label(frame, ("%s\n%s"):format(unit, infos[unit].name or "?"), 12, y - 12)
        for w, way in ipairs(WAYS) do
            local p, ok = Portrait(frame, SIZE, infos[unit].class,
                function(tex) return way[2](tex, unit, infos[unit]) end)
            p:SetPoint("TOPLEFT", left + (w - 1) * CELL + (CELL - SIZE) / 2, y)
            if not ok then
                local x = p:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
                x:SetPoint("CENTER")
                x:SetText("missing")
            end
        end
    end

    local y = -56 - #units * CELL
    Label(frame, "Stacked, live:", 12, y - 12)
    Stack(frame, units, infos, WAYS[1][2]):SetPoint("TOPLEFT", left, y)
    Label(frame, "Stacked, race file:", 12, y - 62)
    Stack(frame, units, infos, WAYS[2][2]):SetPoint("TOPLEFT", left, y - 50)

    -- A made-up party from saved data alone, for judging the stack solo:
    -- you and up to four others, at 2, 3 and 5 members.
    local demo = { "player" }
    for k, d in ipairs(DEMO) do
        demo[k + 1] = "demo" .. k
        infos["demo" .. k] = { race = d[1], sex = d[2], class = d[3] }
    end
    local x = left
    for _, count in ipairs({ 2, 3, 5 }) do
        local stack = Stack(frame, { unpack(demo, 1, count) }, infos, WAYS[2][2])
        stack:SetPoint("TOPLEFT", x, y - 170)
        x = x + stack:GetWidth() + 16
    end
    Label(frame, "Demo party:", 12, y - 182)

    -- Live portraits copied once; the copies are not redrawn, so they show
    -- whether a portrait stays after its unit leaves or goes out of range.
    Label(frame, "Snapshot:", 12, y - 112)
    local snaps = CreateFrame("Frame", nil, frame)
    snaps:SetSize(#WAYS * CELL, SIZE)
    snaps:SetPoint("TOPLEFT", left, y - 100)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(90, 22)
    button:SetPoint("TOPLEFT", 12, y - 140)
    button:SetText("Snapshot")
    button:SetScript("OnClick", function()
        for _, child in ipairs({ snaps:GetChildren() }) do child:Hide() end
        local stack = Stack(snaps, units, infos, WAYS[1][2])
        stack:SetPoint("LEFT")
        ns.Print("Snapshot taken at " .. date("%H:%M:%S") .. ". Leave the party or move away and see if it stays.")
    end)
    frame:Show()
end

ns.Command("partyprobe", "test party member portraits (developer)", Build)

-- /rts raiddemo: a made-up raid of 40 as the map shows it, the stack on
-- the left (hover it to spread it) and its card beside it. Four of the
-- raid are players the character has partied with before, one levelled
-- in the raid, one came late and one left early. Nothing is saved.
local RAID_CLASSES = {
    { "WARRIOR", 8 }, { "PRIEST", 6 }, { "MAGE", 5 }, { "ROGUE", 5 }, { "WARLOCK", 4 },
    { "HUNTER", 4 }, { "DRUID", 4 }, { "PALADIN", 3 },
}
local RAID_RACES = {
    WARRIOR = "Human", PRIEST = "Dwarf", MAGE = "Gnome", ROGUE = "NightElf", WARLOCK = "Human",
    HUNTER = "NightElf", DRUID = "NightElf", PALADIN = "Dwarf",
}
local RAID_KNOWN = {    -- index in the raid -> { groups, seconds, dungeons, raids }
    [2] = { 14, 9 * 3600, 6, 3 }, [9] = { 6, 4 * 3600, 2, 2 }, [15] = { 3, 2 * 3600, 1, 1 },
    [22] = { 1, 1800, 0, 0 },
}
local demoFrame
ns.Command("raiddemo", "show a made-up raid of 40 on its card (developer)", function()
    local start = time() - 3 * 3600
    local e = { start, "grp", 0, 0, 0, "raid", {}, true }
    local info = { kind = "raid", leader = true, start = start, finish = start + 3 * 3600 + 720, members = {},
        mySub = 1, instances = { { "Molten Core", "raid" } } }
    local people = {}
    local n = 0
    for _, c in ipairs(RAID_CLASSES) do
        for _ = 1, c[2] do
            n = n + 1
            if n <= 39 then
                local guid = "Player-0-DEMO" .. n
                local m = { guid, ("Raider%d"):format(n), RAID_RACES[c[1]], n % 2 == 0 and "Female" or "Male",
                    c[1], 60, nil, math.floor((n - 1) / 5) + 1 }
                local entry = { m = m }
                local known = RAID_KNOWN[n]
                if known then
                    people[guid] = { name = m[2], class = c[1], first = start - 20 * 86400,
                        groups = known[1], seconds = known[2], dungeons = known[3], raids = known[4] }
                end
                if n == 9 then m[6], entry.endLevel = 59, 60 end
                if n == 15 then entry.joined = start + 1800 end
                if n == 22 then entry.left = start + 2 * 3600 end
                info.members[#info.members + 1] = entry
            end
        end
    end
    info.summary = { duration = 3 * 3600 + 720, kills = 412, xp = 0, quests = 0, deaths = 7, instances = 1 }
    ns.Parties:SetDemo(e, info, people)

    if not demoFrame then
        demoFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        demoFrame:SetSize(200, 70)
        demoFrame:SetPoint("CENTER", -200, 120)
        demoFrame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
        demoFrame:SetBackdropColor(0.15, 0.13, 0.1, 0.9)
        demoFrame.stack = ns.Parties:CreateStack(demoFrame, 24)
        demoFrame.stack:SetPoint("CENTER")
        demoFrame.stack:EnableMouse(true)
        demoFrame.stack:SetScript("OnEnter", function(self) ns.Parties:Spread(self, true) end)
        demoFrame.stack:SetScript("OnLeave", function(self) ns.Parties:Spread(self, false) end)
        demoFrame:EnableMouse(true)
        demoFrame:SetScript("OnMouseDown", function(self)
            self:Hide()
            ns.Parties:HideCard()
            ns.Parties.demoPeople = nil
            ns.Parties:Reset()
        end)
    end
    ns.Parties:SetStack(demoFrame.stack, info)
    demoFrame:Show()
    ns.Parties:ShowCard(demoFrame, e)
    ns.Print("Raid demo: hover the stack to spread it, click the box beside it to close.")
end)
