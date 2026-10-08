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
