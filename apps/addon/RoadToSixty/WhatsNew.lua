local addonName, ns = ...

-- The in-game changelog (#132): once per account for each release, its own
-- window with the notes of every version the account hasn't seen, newest
-- first, a few seconds after login and never in combat. /rts changes opens
-- it again. The notes are CHANGELOG.md's, in WhatsNewData.lua, which the
-- release build writes (scripts/whatsnew-data.lua); a dev install has none
-- until that script is run by hand.
--
--   RoadToSixtyDB.whatsNewSeen = the newest version the window has shown, or
--                                the version a new account started on
--
-- Only a full release (X.Y.Z) shows it at login, never a beta or a dev
-- build. A brand-new account shows nothing: its first version is noted
-- quietly. An account that already has characters but no whatsNewSeen
-- (updating into the first version with the window) sees that version's notes.

local WhatsNew = {}
ns.WhatsNew = WhatsNew

local DELAY = 6             -- seconds after login before it shows
local MOST = 8              -- versions shown at most; the rest are in the release notes
local WIDTH, HEIGHT = 440, 420
local PAD = 14

-- A version's three numbers, or nil for anything but X.Y.Z.
local function Parts(version)
    local a, b, c = tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    if a then return tonumber(a), tonumber(b), tonumber(c) end
end

-- Whether version a is newer than b; false when either isn't X.Y.Z.
function WhatsNew.Newer(a, b)
    local a1, a2, a3 = Parts(a)
    local b1, b2, b3 = Parts(b)
    if not a1 or not b1 then return false end
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end

-- The versions of data (newest first) after seen, up to current, at most
-- MOST; list.cut when there were more.
function WhatsNew.Unseen(data, current, seen)
    local list = {}
    for _, v in ipairs(data) do
        if not WhatsNew.Newer(v.version, current) and WhatsNew.Newer(v.version, seen) then
            if #list >= MOST then
                list.cut = true
                break
            end
            list[#list + 1] = v
        end
    end
    return list
end

-- What a login shows, and the seen version to keep once it has: the list
-- may be nil or empty, when nothing shows. known: the account had
-- characters before this login.
function WhatsNew.AtLogin(data, current, seen, known)
    if not Parts(current) then return nil, seen end
    if not seen then
        if not known then return nil, current end
        for _, v in ipairs(data) do
            if v.version == current then return { v }, current end
        end
        return nil, current
    end
    if not WhatsNew.Newer(current, seen) then return nil, seen end
    return WhatsNew.Unseen(data, current, seen), current
end

local function Version()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return get and get(addonName, "Version")
end

-- The window ---------------------------------------------------------------------

local ART = "Interface\\AddOns\\" .. addonName .. "\\"
local GOLD = { 1, 0.82, 0 }
local SECTION_COLOURS = { New = { 0.45, 0.9, 0.45 }, Fixed = { 0.5, 0.78, 1 } }

-- Three looks for Jordan to pick from (#132): "a" Blizzard's window with the
-- logo in its round portrait, "b" a header with the logo and the name, "c"
-- the CurseForge banner across the top. /rts changes test a, b or c.
local LOOKS = { a = true, b = true, c = true }
local look = "b"

local frames = {}           -- look -> its window, made once

local function Title(f, text)
    if f.SetTitle then f:SetTitle(text) elseif f.TitleText then f.TitleText:SetText(text) end
end

-- Font strings and lines from f's pools, reused each fill.
local function Text(f, font, used)
    local pool = f.pools[font] or {}
    f.pools[font] = pool
    used[font] = (used[font] or 0) + 1
    local fs = pool[used[font]]
    if not fs then
        fs = f.child:CreateFontString(nil, "OVERLAY", font)
        fs:SetJustifyH("LEFT")
        pool[used[font]] = fs
    end
    fs:ClearAllPoints()
    fs:SetTextColor(1, 1, 1)
    fs:Show()
    return fs
end

local function Rule(f, used)
    used.rules = (used.rules or 0) + 1
    local line = f.rules[used.rules]
    if not line then
        line = f.child:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        f.rules[used.rules] = line
    end
    line:ClearAllPoints()
    line:Show()
    return line
end

local function Create(which)
    local f
    if which == "a" then
        f = CreateFrame("Frame", "RoadToSixtyWhatsNewA", UIParent, "ButtonFrameTemplate")
        f:SetSize(WIDTH + 20, HEIGHT + 40)
        if f.SetPortraitToAsset then
            f:SetPortraitToAsset(ART .. "logo")
        elseif f.portrait then
            SetPortraitToTexture(f.portrait, ART .. "logo")
        end
        f.top = -64
    else
        f = CreateFrame("Frame", "RoadToSixtyWhatsNew" .. which:upper(), UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(WIDTH + 20, HEIGHT + (which == "c" and 120 or 70))
        if which == "b" then
            local logo = f:CreateTexture(nil, "ARTWORK")
            logo:SetTexture(ART .. "logo")
            logo:SetSize(64, 64)
            logo:SetPoint("TOPLEFT", 16, -32)
            local name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
            name:SetPoint("TOPLEFT", logo, "TOPRIGHT", 12, -8)
            name:SetText("Road to Sixty")
            f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            f.subtitle:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -6)
            local rule = f:CreateTexture(nil, "ARTWORK")
            rule:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.5)
            rule:SetHeight(1)
            rule:SetPoint("TOPLEFT", 16, -104)
            rule:SetPoint("TOPRIGHT", -16, -104)
            f.top = -112
        else
            local w = WIDTH + 12
            local banner = f:CreateTexture(nil, "ARTWORK")
            banner:SetTexture(ART .. "banner")
            banner:SetTexCoord(0, 1, 0, 171 / 256)
            banner:SetSize(w, w * 171 / 512)
            banner:SetPoint("TOP", 0, -26)
            f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            f.subtitle:SetPoint("TOP", banner, "BOTTOM", 0, -8)
            f.top = -26 - w * 171 / 512 - 34
        end
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.title:SetPoint("TOP", 0, -5)
    end
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, f:GetName())

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD + 4, f.top)
    scroll:SetPoint("BOTTOMRIGHT", -32, 44)
    f.child = CreateFrame("Frame", nil, scroll)
    f.child:SetSize(WIDTH + 20 - PAD - 4 - 32, 1)
    scroll:SetScrollChild(f.child)
    f.scroll = scroll
    f.pools, f.rules = {}, {}

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(96, 22)
    close:SetPoint("BOTTOMRIGHT", -PAD, which == "a" and 4 or 12)
    close:SetText("Close")
    close:SetScript("OnClick", function() f:Hide() end)

    local map = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    map:SetSize(120, 22)
    map:SetPoint("RIGHT", close, "LEFT", -8, 0)
    map:SetText("Open the map")
    map:SetScript("OnClick", function()
        f:Hide()
        ns.Map:Open()
    end)
    frames[which] = f
    return f
end

-- Fills window f with list's versions: each version's number over a gold
-- rule, its sections in their colours, each note a gold bullet with its
-- lines hanging after it.
local function Fill(f, list)
    for _, pool in pairs(f.pools) do
        for _, fs in ipairs(pool) do fs:Hide() end
    end
    for _, line in ipairs(f.rules) do line:Hide() end
    local used, y, width = {}, 0, f.child:GetWidth()
    local function Place(fs, x, gap)
        y = y + gap
        fs:SetPoint("TOPLEFT", x, -y)
        fs:SetWidth(width - x)
        y = y + fs:GetStringHeight()
    end
    for i, v in ipairs(list) do
        local head = Text(f, "GameFontNormalLarge", used)
        head:SetText(v.version)
        head:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        Place(head, 0, i == 1 and 2 or 20)
        local rule = Rule(f, used)
        rule:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
        rule:SetPoint("TOPLEFT", 0, -(y + 4))
        rule:SetPoint("TOPRIGHT", -4, -(y + 4))
        y = y + 6
        for _, section in ipairs(v.sections) do
            local title = Text(f, "GameFontNormal", used)
            title:SetText(section[1]:upper())
            local c = SECTION_COLOURS[section[1]] or GOLD
            title:SetTextColor(c[1], c[2], c[3])
            Place(title, 0, 8)
            for _, note in ipairs(section[2]) do
                local dot = Text(f, "GameFontNormal", used)
                dot:SetText("\226\128\162")     -- a bullet
                dot:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
                dot:SetWidth(10)
                dot:SetPoint("TOPLEFT", 4, -(y + 5))
                local line = Text(f, "GameFontHighlight", used)
                line:SetText(note)
                line:SetTextColor(0.92, 0.92, 0.9)
                Place(line, 16, 5)
            end
        end
    end
    if list.cut then
        local rest = Text(f, "GameFontDisable", used)
        rest:SetText("Older versions' notes are in the release notes on CurseForge.")
        Place(rest, 0, 18)
    end
    f.child:SetHeight(math.max(y + 4, 1))
    f.scroll:SetVerticalScroll(0)
end

-- Shows list's versions (newest first), with a line for older ones when
-- list.cut. which picks the look, for the test command.
function WhatsNew:Show(list, which)
    which = LOOKS[which] and which or look
    for key, f in pairs(frames) do
        if key ~= which then f:Hide() end
    end
    local f = frames[which] or Create(which)
    local newest = list[1].version
    if which == "a" then
        Title(f, ("Road to Sixty %s: what's new"):format(newest))
    else
        f.title:SetText("What's new")
        f.subtitle:SetText(("Version %s"):format(newest))
    end
    Fill(f, list)
    f:Show()
end

-- At login -----------------------------------------------------------------------

local known                 -- the account had characters before this login
local waiting               -- { list, seen } until combat ends

local function ShowNow(list, seen)
    if InCombatLockdown and InCombatLockdown() then
        waiting = { list, seen }
        return
    end
    waiting = nil
    ns.db.whatsNewSeen = seen
    WhatsNew:Show(list)
end

ns.On("ADDON_LOADED", function(name)
    if name == addonName then known = next(ns.db.roster or {}) ~= nil end
end)

ns.On("PLAYER_LOGIN", function()
    local list, seen = WhatsNew.AtLogin(ns.WhatsNewData or {}, Version(), ns.db.whatsNewSeen, known)
    if not list or not list[1] then
        ns.db.whatsNewSeen = seen
        return
    end
    -- Noted as seen once it shows, so a /reload before then still shows it.
    C_Timer.After(DELAY, function() ns.SafeCall(ShowNow, list, seen) end)
end)

ns.On("PLAYER_REGEN_ENABLED", function()
    if waiting then ShowNow(waiting[1], waiting[2]) end
end)

ns.Command("changes", "what's new in the latest versions", function(arg)
    local data = ns.WhatsNewData or {}
    --@debug@
    -- As a login would show it after updating from the third version listed.
    -- test a, b or c picks the look.
    if arg and arg:match("^test") and data[3] then
        WhatsNew:Show(WhatsNew.Unseen(data, data[1].version, data[3].version), arg:match("^test%s+(%a)$"))
        return
    end
    --@end-debug@
    if not data[1] then
        ns.Print("This build has no changelog. Run scripts/whatsnew-data.lua to make one.")
        return
    end
    local list = { cut = #data > MOST }
    for i = 1, math.min(MOST, #data) do list[i] = data[i] end
    WhatsNew:Show(list)
end)
