local _, ns = ...

-- The Stats screen (issue #83): a mode of the journey map window, beside
-- Map and Gear (Screens.lua), that puts the journey's numbers where the map
-- and the side panel were. Everything on it counts only what is inside the
-- map's date range (Range.lua), up to the replay's moment, so the numbers
-- grow as the replay plays. The numbers come from Stats.lua.
--
-- Built so far: the headline row (time played, yards travelled, kills,
-- quests, deaths, gold, dungeons) and the range and moment it covers.

local StatsScreen = {}
ns.StatsScreen = StatsScreen

local Stats = ns.Stats
local Pane = ns.Screens.Pane

local PAD = 12
local TOP = 40              -- below the mode switch
local TILE_H = 62
local TILE_GAP = 8
local REBUILD_SECONDS = 10  -- while the journey grows, the index is built again at most this often

local view, viewEdges
local ui = {}
local index, builtAt, builtFor
local dirty = true
local followT = math.huge   -- the replay's moment

local Commas = function(n) return ns.Commas(n) end
local Duration = function(s) return ns.FormatDuration(s) end

local function Money(copper)
    if not copper then return "-" end
    local sign = copper < 0 and "-" or ""
    copper = math.abs(math.floor(copper))
    if GetMoneyString then return sign .. GetMoneyString(copper, true) end
    return ("%s%dg %ds"):format(sign, math.floor(copper / 10000), math.floor(copper / 100) % 100)
end

local function Percent(part, whole)
    return whole > 0 and math.floor(part / whole * 100 + 0.5) or 0
end

-- The index for the journey shown: built when the journey or the range
-- changed, and again while the character plays, at most every
-- REBUILD_SECONDS, as building one takes a moment on a long journey.
local function Index()
    local journey = ns.view
    local fresh = index and builtFor == journey and not dirty
    if fresh and (not Stats.Changed(index, journey) or GetTime() - builtAt < REBUILD_SECONDS) then
        return index
    end
    local isMe = journey == ns.char
    index = Stats.Index(journey, isMe and ns.Now() or nil, isMe and GetMoney() or nil)
    builtAt, builtFor, dirty = GetTime(), journey, false
    return index
end

-- What the screen covers: the date range, up to the replay's moment.
local function Window()
    local from, to = ns.Range.from, ns.Range.to
    if followT ~= math.huge then to = math.min(to or followT, followT) end
    return Stats.Window(Index(), from, to)
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

local function LayoutTiles()
    local width = view:GetWidth() - 2 * PAD
    local tileW = (width - (#ui.tiles - 1) * TILE_GAP) / #ui.tiles
    for i, tile in ipairs(ui.tiles) do
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", PAD + (i - 1) * (tileW + TILE_GAP), -TOP)
        tile:SetWidth(tileW)
    end
end

local function SetTile(i, value, sub)
    ui.tiles[i].value:SetText(value)
    ui.tiles[i].sub:SetText(sub or "")
end

local function FillTiles(w)
    local travelled = w.walked + w.flown
    SetTile(1, Duration(w.played), ("%s xp"):format(Commas(w.killXP + w.questXP)))
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
    local levels = w.levelFrom and w.levelTo and w.levelTo > w.levelFrom
        and ("levels %d to %d"):format(w.levelFrom, w.levelTo) or w.levelTo and ("level %d"):format(w.levelTo)
    SetTile(7, Commas(w.dungeons), levels)
end

-- The screen -------------------------------------------------------------------------

local function Day(t)
    return (tostring(date("%d %b", t)):gsub("^0", ""))
end

function StatsScreen:Redraw()
    if not (view and view:IsVisible()) then return end
    local w = Window()
    FillTiles(w)
    local covers = ("%s to %s"):format(Day(w.from), Day(w.to))
    if followT < index.finish then covers = covers .. ", up to the replay's moment" end
    ui.range:SetText(("|cffffd100%s|r  %s"):format(ns.Range:Label(), covers))
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

    view:SetScript("OnShow", function() ns.SafeShow(StatsScreen.Redraw, StatsScreen) end)
    view:SetScript("OnSizeChanged", function()
        ns.SafeShow(function()
            LayoutTiles()
            StatsScreen:Redraw()
        end)
    end)
end

function StatsScreen:Show(frames)
    if not view then CreateView(frames) end
    viewEdges:Show()
    if view:IsShown() then
        LayoutTiles()
        self:Redraw()
    else
        view:Show()
        LayoutTiles()
    end
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
