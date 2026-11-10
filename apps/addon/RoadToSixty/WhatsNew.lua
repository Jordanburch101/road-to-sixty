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

local frame, child, more
local pools = {}            -- font -> { font strings }, reused each fill

local function Text(font, used)
    local pool = pools[font] or {}
    pools[font] = pool
    used[font] = (used[font] or 0) + 1
    local fs = pool[used[font]]
    if not fs then
        fs = child:CreateFontString(nil, "OVERLAY", font)
        fs:SetJustifyH("LEFT")
        pool[used[font]] = fs
    end
    fs:ClearAllPoints()
    fs:Show()
    return fs
end

local function Create()
    frame = CreateFrame("Frame", "RoadToSixtyWhatsNew", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", 0, 40)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "RoadToSixtyWhatsNew")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, -32)
    scroll:SetPoint("BOTTOMRIGHT", -32, 44)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(WIDTH - PAD - 32, 1)
    scroll:SetScrollChild(child)
    frame.scroll = scroll

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(96, 22)
    close:SetPoint("BOTTOMRIGHT", -PAD, 12)
    close:SetText("Close")
    close:SetScript("OnClick", function() frame:Hide() end)

    local map = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    map:SetSize(120, 22)
    map:SetPoint("RIGHT", close, "LEFT", -8, 0)
    map:SetText("Open the map")
    map:SetScript("OnClick", function()
        frame:Hide()
        ns.Map:Open()
    end)
end

-- Fills the window with list's versions: each version's number, then its
-- sections, each note a bullet with its lines hanging after the dot.
local function Fill(list)
    for _, pool in pairs(pools) do
        for _, fs in ipairs(pool) do fs:Hide() end
    end
    local used, y, width = {}, 0, child:GetWidth()
    local function Place(fs, x, gap)
        y = y + gap
        fs:SetPoint("TOPLEFT", x, -y)
        fs:SetWidth(width - x)
        y = y + fs:GetStringHeight()
    end
    for i, v in ipairs(list) do
        local head = Text("GameFontNormalLarge", used)
        head:SetText(v.version)
        Place(head, 0, i == 1 and 0 or 18)
        for _, section in ipairs(v.sections) do
            local title = Text("GameFontNormal", used)
            title:SetText(section[1])
            Place(title, 0, 8)
            for _, note in ipairs(section[2]) do
                local dot = Text("GameFontHighlight", used)
                dot:SetText("\226\128\162")     -- a bullet
                dot:SetWidth(10)
                dot:SetPoint("TOPLEFT", 4, -(y + 4))
                local line = Text("GameFontHighlight", used)
                line:SetText(note)
                Place(line, 16, 4)
            end
        end
    end
    if list.cut then
        local rest = Text("GameFontDisable", used)
        rest:SetText("Older versions' notes are in the release notes on CurseForge.")
        Place(rest, 0, 18)
    end
    child:SetHeight(math.max(y + 4, 1))
    frame.scroll:SetVerticalScroll(0)
end

-- Shows list's versions (newest first), with a line for older ones when
-- list.cut. The title names the newest.
function WhatsNew:Show(list)
    if not frame then Create() end
    frame.title:SetText(("Road to Sixty %s: what's new"):format(list[1].version))
    Fill(list)
    frame:Show()
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
    if arg == "test" and data[3] then
        WhatsNew:Show(WhatsNew.Unseen(data, data[1].version, data[3].version))
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
