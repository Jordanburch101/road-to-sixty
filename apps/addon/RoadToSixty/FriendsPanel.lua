local _, ns = ...

-- The side panel's Synced friends tab: add friends, sync them, choose how
-- often that happens by itself, and show a friend's journey or path. The
-- syncing itself is in Friends.lua.

local FriendsPanel = {}
ns.FriendsPanel = FriendsPanel

local ROW = 70
local TIP = "Add a friend and have them add you. Your current character's journey is shared with friends you add, "
    .. "with your BattleTag and who you grouped with."

local pane, list, empty, autoButton
local rows = {}

local function SetPath(rec, on)
    ns.db.showPaths[rec.key] = on or nil
    ns.Map:RefreshCharacters()
    ns.Panel:RefreshCharacters()
end

local function ShowTip(owner, title, text)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine(title)
    if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
    GameTooltip:Show()
end

local function CreateRow()
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW - 4)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", 4, -3)
    row.title:SetPoint("RIGHT", -4, 0)
    row.title:SetJustifyH("LEFT")

    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
    row.detail:SetPoint("RIGHT", -4, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    row.sync = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.sync:SetSize(58, 20)
    row.sync:SetPoint("BOTTOMLEFT", 2, 3)
    row.sync:SetText("Sync")
    row.sync:SetScript("OnClick", function() ns.Friends:Sync(row.rec.name) end)

    row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.remove:SetSize(70, 20)
    row.remove:SetPoint("LEFT", row.sync, "RIGHT", 4, 0)
    row.remove:SetText("Remove")
    row.remove:SetScript("OnClick", function() ns.Friends:Remove(row.rec.name) end)
    row.remove:SetScript("OnEnter", function(self)
        ShowTip(self, "Delete their journey here and stop sharing with them")
    end)
    row.remove:SetScript("OnLeave", GameTooltip_Hide)

    row.path = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.path:SetSize(22, 22)
    row.path:SetPoint("BOTTOMRIGHT", -2, 2)
    row.path:SetScript("OnClick", function(self) SetPath(row.rec, self:GetChecked() and true or false) end)
    row.path:SetScript("OnEnter", function(self) ShowTip(self, "Show this friend's path") end)
    row.path:SetScript("OnLeave", GameTooltip_Hide)

    row:SetScript("OnClick", function(self)
        if self.rec.journey and self.rec.key then ns.Map:ShowJourney(self.rec) end
    end)
    row:SetScript("OnEnter", function(self)
        if self.rec.journey then ShowTip(self, "Click to show " .. self.rec.name .. "'s journey") end
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

function FriendsPanel:Refresh()
    if not pane then return end
    local friends = ns.Friends:List()
    local busy = ns.Friends:Busy()
    local minutes = ns.Friends:AutoSync()
    autoButton:SetText(minutes == 0 and "Auto-sync: Off" or ("Auto-sync: %d min"):format(minutes))
    for i, rec in ipairs(friends) do
        local row = rows[i]
        if not row then
            row = CreateRow()
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
            row:SetPoint("RIGHT")
            rows[i] = row
        end
        row.rec = rec
        local r, g, b = ns.ClassColor(rec.class)
        row.title:SetText(rec.level and ("%s  |cffffffff%d|r"):format(rec.name, rec.level) or rec.name)
        row.title:SetTextColor(r, g, b)
        row.detail:SetText(ns.Friends:Status(rec))
        row.sync:SetEnabled(not busy)
        row.path:SetShown(rec.key ~= nil)
        row.path:SetChecked(rec.key ~= nil and ns.db.showPaths[rec.key] == true)
        row:Show()
    end
    for i = #friends + 1, #rows do rows[i]:Hide() end
    list:SetHeight(math.max(1, #friends * ROW))
    empty:SetShown(#friends == 0)
end

function FriendsPanel:Create(parent)
    pane = parent

    local box = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    box:SetSize(170, 22)
    box:SetPoint("TOPLEFT", 8, -2)
    box:SetAutoFocus(false)
    local function Add()
        local name = box:GetText() or ""
        box:SetText("")
        box:ClearFocus()
        ns.Friends:Add(name)
    end
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", Add)

    local add = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    add:SetSize(70, 22)
    add:SetPoint("TOPRIGHT", 0, -2)
    add:SetText("Add")
    add:SetScript("OnClick", Add)
    add:SetScript("OnEnter", function(self) ShowTip(self, "Synced friends", TIP) end)
    add:SetScript("OnLeave", GameTooltip_Hide)

    autoButton = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    autoButton:SetSize(150, 22)
    autoButton:SetPoint("TOPLEFT", 2, -28)
    autoButton:SetScript("OnClick", function() ns.Friends:NextAutoSync() end)
    autoButton:SetScript("OnEnter", function(self)
        ShowTip(self, "Automatic sync", "Syncs with every friend who is online, on a timer, while you play. Click for the next choice.")
    end)
    autoButton:SetScript("OnLeave", GameTooltip_Hide)

    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, pane, "ScrollFrameTemplate")
    if not ok then
        scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    end
    scroll:SetPoint("TOPLEFT", 0, -56)
    scroll:SetPoint("BOTTOMRIGHT", -24, 0)
    list = CreateFrame("Frame", nil, scroll)
    list:SetSize(ns.Panel.WIDTH - 36, 1)
    scroll:SetScrollChild(list)
    scroll:SetScript("OnSizeChanged", function(_, width) list:SetWidth(width) end)

    empty = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", 8, -64)
    empty:SetPoint("RIGHT", -8, 0)
    empty:SetJustifyH("LEFT")
    empty:SetJustifyV("TOP")
    empty:SetText(TIP)

    ns.Friends.OnChange = function() FriendsPanel:Refresh() end
    self:Refresh()
end
