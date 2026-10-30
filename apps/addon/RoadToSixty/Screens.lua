local _, ns = ...

-- The journey window's modes: Map, then screens that take the map's and the
-- side panel's place, Gear (GearScreen.lua, #64) and Stats (StatsScreen.lua,
-- #83). The switch sits on the character sheet's title plaque over the
-- map's top left corner; the replay bar, the date range and the line under
-- the map stay in every mode.
--
-- A screen registers with Screens:Add(key, label, screen) in the order its
-- tab shows, and has:
--   screen:Show(frames)  come into sight; frames = { window, canvas, panel },
--                        to build on and anchor to the first time
--   screen:Hide()
--   screen:Follow(t)     the replay's moment, or math.huge at its end
--   screen:Rebuild()     the journey shown or the date range changed
-- Map.lua calls Attach once, then Follow and Rebuild, which reach every
-- screen (one out of sight only notes it).

local Screens = {}
ns.Screens = Screens

local list = {}             -- { key, label, screen } in tab order, Map first
local tabs = {}
local frames                -- { window, canvas, panel, panelEdges }
local mode = "map"

-- A switch on the character sheet's title plaque; SetTabOn lights it.
function Screens.Tab(parent, text, width, onClick)
    local tab = CreateFrame("Button", nil, parent)
    tab:SetSize(width, 28)
    tab.bg = tab:CreateTexture(nil, "BACKGROUND")
    tab.bg:SetAllPoints()
    tab.bg:SetAtlas("UI-Character-Info-Title")
    tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tab.text:SetPoint("CENTER", 0, 1)
    tab.text:SetText(text)
    tab:SetScript("OnClick", onClick)
    return tab
end

function Screens.SetTabOn(tab, on)
    tab.bg:SetDesaturated(not on)
    tab.bg:SetAlpha(on and 1 or 0.7)
    tab.text:SetFontObject(on and "GameFontHighlight" or "GameFontNormal")
end

-- A panel in the map's frame style: the tooltip border on a dark ground.
function Screens.Pane(parent)
    local pane = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    pane:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    pane:SetBackdropColor(0, 0, 0, 0.6)
    pane:SetBackdropBorderColor(0.6, 0.6, 0.6)
    return pane
end

-- The game's own item button, the bags' art round an icon; the older
-- clients without the ItemButton type have its template.
function Screens.ItemButton(parent, size)
    local ok, button = pcall(CreateFrame, "ItemButton", nil, parent)
    if not ok then button = CreateFrame("Button", nil, parent, "ItemButtonTemplate") end
    button:SetSize(size, size)
    return button
end

function Screens:Add(key, label, screen)
    list[#list + 1] = { key = key, label = label, screen = screen }
end

function Screens:Mode()
    return mode
end

-- Where the mode switch ends, from the map's left edge, so a screen's own
-- tabs along the top start clear of it.
function Screens:TabsRight()
    return #tabs * 98 + 2
end

local function UpdateTabs()
    for _, tab in ipairs(tabs) do Screens.SetTabOn(tab, tab.mode == mode) end
end

function Screens:Attach(window, canvas, panel, panelEdges)
    frames = { window = window, canvas = canvas, panel = panel, panelEdges = panelEdges }
    local modes = { { key = "map", label = "Map" } }
    for _, m in ipairs(list) do modes[#modes + 1] = m end
    for k, m in ipairs(modes) do
        local tab = Screens.Tab(window, m.label, 94, function() ns.SafeShow(Screens.SetMode, Screens, m.key) end)
        tab:SetFrameLevel(canvas:GetFrameLevel() + 100)
        tab:SetPoint("TOPLEFT", canvas, "TOPLEFT", 6 + (k - 1) * 98, -6)
        tab.mode = m.key
        tabs[k] = tab
    end
    UpdateTabs()
end

-- The map's canvas is hidden under a screen, so the game does not draw its
-- paths and markers there; the replay runs on the window.
function Screens:SetMode(newMode)
    for _, m in ipairs(list) do
        if m.key ~= newMode and m.key == mode then m.screen:Hide() end
    end
    mode = newMode
    UpdateTabs()
    local shown = mode == "map"
    frames.canvas:SetShown(shown)
    frames.panel:SetShown(shown)
    frames.panelEdges:SetShown(shown)
    if shown then GameTooltip_Hide() end
    for _, m in ipairs(list) do
        if m.key == mode then m.screen:Show(frames) end
    end
end

function Screens:Follow(t)
    for _, m in ipairs(list) do ns.SafeShow(m.screen.Follow, m.screen, t) end
end

function Screens:Rebuild()
    for _, m in ipairs(list) do m.screen:Rebuild() end
end
