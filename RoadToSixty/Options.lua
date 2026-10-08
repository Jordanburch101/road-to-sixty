local addonName, ns = ...

-- Options panel in the game's settings, under AddOns > Road to Sixty. Opened
-- with /rts options, a right-click on the minimap button or from the game
-- menu. Every change applies at once; there is nothing to save.

local Options = {}
ns.Options = Options

local TITLE = "Road to Sixty"
local LEFT = 16          -- panel's left margin
local SECTION_GAP = 18   -- space above each section heading
local ROW = 30           -- height of one checkbox row
local BUTTON_WIDTH = 160

local panel, category
local checks = {}        -- checkbox -> its option
local statusText

-- Each option reads and writes a saved setting, then brings whatever shows
-- it up to date.
local SECTIONS = {
    {
        title = "General",
        {
            label = "Show the minimap button",
            tip = "Left-click it to open the journey map, right-click for these options. Drag it to move it.",
            get = function() return not ns.db.minimap.hide end,
            set = function(on)
                ns.db.minimap.hide = not on
                ns.MinimapButton:Refresh()
            end,
        },
        {
            label = "Show the welcome message at login",
            tip = "A line in chat each login saying your journey is being recorded.",
            get = function() return ns.db.greet end,
            set = function(on) ns.db.greet = on end,
        },
    },
    {
        title = "Journey map",
        {
            label = "Show terrain",
            tip = "Draw the land under your path. Off shows the plain parchment map.",
            get = function() return ns.db.terrain end,
            set = function(on) ns.db.terrain = on end,
        },
        {
            label = "Show city street plans",
            tip = "With terrain off, the capitals show their own street plans when you zoom in. Off shows the land around them instead.",
            get = function() return ns.db.cityArt end,
            set = function(on)
                ns.db.cityArt = on
                ns.RefreshCityArt()
            end,
        },
        {
            label = "Show sparkles along the path",
            tip = "Small motes of light drifting along your journey.",
            get = function() return ns.db.motes end,
            set = function(on) ns.db.motes = on end,
        },
        {
            label = "Show quest turn-ins during the replay",
            tip = "A golden quest mark pops up where you handed in each quest, with its name and experience, as the replay passes it.",
            get = function() return ns.db.questPops end,
            set = function(on) ns.db.questPops = on end,
        },
        {
            label = "Show kills during the replay",
            tip = "Each kill pops up at the arrow with its experience and the creature's name, counting up when you kill several in a row.",
            get = function() return ns.db.killPops end,
            set = function(on) ns.db.killPops = on end,
        },
        {
            label = "Show where you killed",
            tip = "A faint mark on the map for every kill. One kill barely shows, but the places you ground for a while stand out.",
            get = function() return ns.db.killMarks end,
            set = function(on) ns.db.killMarks = on end,
        },
        {
            label = "Show gear during the replay",
            tip = "A card in the map's corner showing what you wore, changing as the replay plays. Same as the map's Gear button.",
            get = function() return ns.db.showGear end,
            set = function(on) ns.db.showGear = on end,
        },
    },
}

StaticPopupDialogs.ROADTOSIXTY_RESET = {
    text = "Erase the whole journey of this character?\n\nIts path, history, level ups and gear are deleted for good. The interface reloads afterwards.",
    button1 = "Erase",
    button2 = CANCEL,
    OnAccept = function()
        ns.ResetCharacter()
        ReloadUI()
    end,
    showAlert = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function Version()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = get and get(addonName, "Version")
    if not version or version:find("@", 1, true) then
        return "dev"
    end
    return version
end

-- Closes the settings window, so a window opened from it is not hidden behind.
local function CloseSettings()
    for _, window in ipairs({ SettingsPanel, InterfaceOptionsFrame }) do
        if window and window:IsShown() then
            HideUIPanel(window)
        end
    end
end

local function UpdateStatus()
    local segments, points = ns.Recorder:Stats()
    local levels = 0
    for _ in pairs(ns.char.levels) do
        levels = levels + 1
    end
    local text = ("This character: %d points in %d segments, %d events, %d level ups recorded."):format(
        points, segments, #ns.char.events, levels)
    if ns.errors.count > 0 then
        text = text .. ("\n|cffff4040%d error(s) this session. Check recording for details.|r"):format(ns.errors.count)
    end
    if ns.char.seeded then
        text = text .. "\n|cffff8040This character has fake seeded data.|r"
    end
    statusText:SetText(text)
end

-- The layout runs top to bottom: each piece is placed at y, below the
-- panel's top, and moves y down past itself.
local y

-- A gold heading with a thin rule under it.
local function Heading(text)
    y = y - SECTION_GAP
    local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    heading:SetPoint("TOPLEFT", LEFT, y)
    heading:SetText(text)

    local rule = panel:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 0.82, 0, 0.25)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", LEFT, y - 16)
    rule:SetPoint("TOPRIGHT", -LEFT, y - 16)
    y = y - 22
end

local function Check(option)
    local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    check:SetSize(26, 26)
    check:SetPoint("TOPLEFT", LEFT - 2, y)
    y = y - ROW

    local label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", check, "RIGHT", 4, 1)
    label:SetText(option.label)
    check:SetHitRectInsets(0, -label:GetStringWidth() - 8, 0, 0)

    check:SetScript("OnClick", function(self)
        option.set(self:GetChecked() and true or false)
        ns.Map:ApplySettings()
    end)
    check:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(option.label)
        GameTooltip:AddLine(option.tip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    check:SetScript("OnLeave", GameTooltip_Hide)
    checks[check] = option
    return check
end

local function Button(text, width, onClick)
    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetSize(width or BUTTON_WIDTH, 22)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function Build()
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", LEFT, -16)
    title:SetText(TITLE)

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    version:SetText(Version())

    local notes = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    notes:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    notes:SetText("Records your journey from 1 to 60 and replays it on the map.")

    y = -50
    for _, section in ipairs(SECTIONS) do
        Heading(section.title)
        for _, option in ipairs(section) do
            Check(option)
        end
    end

    -- Journey: open it, check it, and the counts so far.
    Heading("Journey")
    local mapButton = Button("Open journey map", nil, function()
        CloseSettings()
        ns.Map:Open()
    end)
    mapButton:SetPoint("TOPLEFT", LEFT, y)

    local checkButton = Button("Check recording", nil, function()
        SlashCmdList.ROADTOSIXTY("check")
        UpdateStatus()
    end)
    checkButton:SetPoint("LEFT", mapButton, "RIGHT", 8, 0)
    checkButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Check recording")
        GameTooltip:AddLine("Prints in chat whether recording is working, and restarts it if it stopped.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    checkButton:SetScript("OnLeave", GameTooltip_Hide)

    statusText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", LEFT, y - 32)
    statusText:SetPoint("TOPRIGHT", -LEFT, y - 32)
    statusText:SetJustifyH("LEFT")
    statusText:SetJustifyV("TOP")
    -- Room for three lines: the counts, errors and the seeded warning.
    y = y - 32 - 40

    -- Erasing goes last, apart from the rest, behind a confirmation.
    Heading("Erase")
    local resetButton = Button("Erase this character's journey", 220, function()
        StaticPopup_Show("ROADTOSIXTY_RESET")
    end)
    resetButton:SetPoint("TOPLEFT", LEFT, y)

    local resetNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    resetNote:SetPoint("LEFT", resetButton, "RIGHT", 10, 0)
    resetNote:SetText("Other characters' journeys are kept.")

    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    help:SetPoint("BOTTOMLEFT", LEFT, 16)
    help:SetText("Type /rts in chat for the commands.")
end

-- Updates the checkboxes and counts, after a change made somewhere else.
function Options:Refresh()
    if not (panel and statusText and panel:IsShown()) then return end
    for check, option in pairs(checks) do
        check:SetChecked(option.get())
    end
    UpdateStatus()
end

function Options:Open()
    if Settings and Settings.OpenToCategory and category then
        Settings.OpenToCategory(category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        -- The old options window often opens on the wrong page the first time.
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

-- Closes the options if they are showing, else opens them.
function Options:Toggle()
    if panel and panel:IsVisible() then
        CloseSettings()
    else
        self:Open()
    end
end

ns.On("PLAYER_LOGIN", function()
    panel = CreateFrame("Frame")
    panel:Hide()
    panel.name = TITLE
    panel:SetScript("OnShow", function()
        if not statusText then Build() end
        Options:Refresh()
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, TITLE)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end)

ns.Command("options", "open the options panel", function()
    Options:Open()
end)
