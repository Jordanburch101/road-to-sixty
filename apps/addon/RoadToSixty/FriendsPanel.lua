local _, ns = ...

-- The side panel's Friends tab: add friends, sync them, choose how
-- often that happens by itself, and show a friend's journey or path. The
-- syncing itself is in Friends.lua. Rows look like the Characters tab's:
-- the class icon, the name and BattleTag over the sync status, and Sync and
-- the path box on the right. Sync shows only for a friend who may be online:
-- one known to be offline has grey "Offline" in its place (#92). Removing is on the right-click menu, behind a
-- question, as it deletes the friend's journey.

local FriendsPanel = {}
ns.FriendsPanel = FriendsPanel

local ROW = 40
local TOP = 62                  -- height of the add and auto-sync lines above the list
local TIP = "Add a friend and have them add you. Friends are shared by every character on this account: "
    .. "whichever of your characters is online shares its journey with them, with your BattleTag and who you grouped with."

local pane, list, empty, autoButton

StaticPopupDialogs.ROADTOSIXTY_REMOVE_FRIEND = {
    text = "Remove %s?\n\nTheir journey is deleted here, and you stop sharing yours with them.",
    button1 = "Remove",
    button2 = CANCEL or "Cancel",
    OnAccept = function(_, name) ns.Friends:Remove(name) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function AskRemove(rec)
    StaticPopup_Show("ROADTOSIXTY_REMOVE_FRIEND", rec.name, nil, rec.name)
end

local function SetPath(rec, on)
    ns.db.showPaths[rec.key] = on or nil
    ns.Map:RefreshCharacters()
    ns.Panel:RefreshCharacters()
end

local function ShowTip(owner, title, text, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_LEFT")
    GameTooltip:AddLine(title)
    if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
    GameTooltip:Show()
end

local function AutoLabel(minutes)
    return minutes == 0 and "Off" or ("Every %d min"):format(minutes)
end

-- The right-click menu: sync, show, remove. Without the menu, a right click
-- asks about removing straight away.
local function OpenMenu(row)
    local rec = row.rec
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        AskRemove(rec)
        return
    end
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(rec.name)
        local sync = root:CreateButton("Sync now", function() ns.Friends:Sync(rec.name) end)
        if ns.Friends:Busy() then sync:SetEnabled(false) end
        if rec.journey and rec.key then
            root:CreateButton("Show journey", function() ns.Map:ShowJourney(rec) end)
        end
        root:CreateDivider()
        root:CreateButton("|cffff6060Remove friend|r", function() AskRemove(rec) end)
    end)
end

local function CreateRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Marks the friend whose journey the map shows.
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.12)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 3, 0)

    row.path = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.path:SetSize(22, 22)
    row.path:SetPoint("RIGHT", -2, 0)
    row.path:SetScript("OnClick", function(self) SetPath(row.rec, self:GetChecked() and true or false) end)
    row.path:SetScript("OnEnter", function(self) ShowTip(self, "Show this friend's path", nil, "ANCHOR_RIGHT") end)
    row.path:SetScript("OnLeave", GameTooltip_Hide)

    row.sync = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.sync:SetSize(44, 20)
    row.sync:SetPoint("RIGHT", row.path, "LEFT", -2, 0)
    row.sync:SetText("Sync")
    row.sync:SetNormalFontObject("GameFontNormalSmall")
    row.sync:SetHighlightFontObject("GameFontHighlightSmall")
    row.sync:SetDisabledFontObject("GameFontDisableSmall")
    row.sync:SetScript("OnClick", function() ns.Friends:Sync(row.rec.name) end)
    row.sync:SetScript("OnEnter", function(self)
        ShowTip(self, "Sync " .. row.rec.name, "Brings their journey up to date. They must be online.")
    end)
    row.sync:SetScript("OnLeave", GameTooltip_Hide)

    row.offline = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.offline:SetPoint("CENTER", row.sync)
    row.offline:SetText("Offline")

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.title:SetPoint("TOPLEFT", 30, -3)
    row.title:SetPoint("RIGHT", row.sync, "LEFT", -4, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
    row.detail:SetPoint("RIGHT", row.sync, "LEFT", -4, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            OpenMenu(self)
        elseif self.rec.journey and self.rec.key then
            ns.Map:ShowJourney(self.rec)
        end
    end)
    row:SetScript("OnEnter", function(self)
        local rec = self.rec
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(rec.name)
        local online = ns.Friends:Online(rec)
        if online ~= nil then
            GameTooltip:AddLine(online and "Online" or "Offline", online and 0.25 or 0.6, online and 0.88 or 0.6,
                online and 0.25 or 0.6)
        end
        GameTooltip:AddLine(ns.Friends:Status(rec), 1, 1, 1, true)
        if rec.journey then GameTooltip:AddLine("Click to show their journey.", 0.6, 0.8, 1) end
        GameTooltip:AddLine("Right-click to sync or remove.", 0.6, 0.8, 1)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

local function UpdateRow(row, rec)
    row.rec = rec
    ns.SetClassIcon(row.icon, rec.class)
    local r, g, b = ns.ClassColor(rec.class)
    local level = rec.level and ("  |cffffffff%d|r"):format(rec.level) or ""
    local tag = rec.battleTag and ("  |cff82c5ff%s|r"):format(rec.battleTag) or ""
    row.title:SetText(rec.name .. level .. tag)
    row.title:SetTextColor(r, g, b)
    row.detail:SetText(ns.Friends:Status(rec))
    local offline = ns.Friends:Online(rec) == false
    row.sync:SetShown(not offline)
    row.offline:SetShown(offline)
    row.sync:SetEnabled(not ns.Friends:Busy())
    -- The shown friend's path is the main one on the map already.
    local shown = rec.key ~= nil and ns.Roster:ViewEntry() == rec
    row.selected:SetShown(shown)
    row.path:SetShown(rec.key ~= nil and not shown)
    row.path:SetChecked(rec.key ~= nil and ns.db.showPaths[rec.key] == true)
end

function FriendsPanel:Refresh()
    if not pane then return end
    autoButton:Update()
    list.data = ns.Friends:List()
    list:Refresh()
    empty:SetShown(#list.data == 0)
end

function FriendsPanel:Create(parent)
    pane = parent

    local add = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    add:SetSize(56, 22)
    add:SetPoint("TOPRIGHT", -2, -4)
    add:SetText("Add")
    add:SetScript("OnEnter", function(self) ShowTip(self, "Friends", TIP) end)
    add:SetScript("OnLeave", GameTooltip_Hide)

    -- The input box's art reaches 5 to the left of its text, so it starts in by that.
    local box = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    box:SetHeight(22)
    box:SetPoint("TOPLEFT", 12, -4)
    box:SetPoint("RIGHT", add, "LEFT", -8, 0)
    box:SetAutoFocus(false)
    local hint = box:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    hint:SetPoint("LEFT", 0, 0)
    hint:SetText(ns.Friends.Surnames() and "Friend's full name" or "Friend's character name")
    local function ShowHint() hint:SetShown(box:GetText() == "" and not box:HasFocus()) end
    local function Add()
        local name = box:GetText() or ""
        box:SetText("")
        box:ClearFocus()
        if strtrim(name) ~= "" then ns.Friends:Add(name) end
    end
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", Add)
    box:SetScript("OnEditFocusGained", ShowHint)
    box:SetScript("OnEditFocusLost", ShowHint)
    box:SetScript("OnTextChanged", ShowHint)
    add:SetScript("OnClick", Add)

    -- Auto-sync: a label and the game's dropdown of the choices. A client
    -- without that dropdown gets a button with the same menu, or without the
    -- menu either, each click the next choice.
    local function BuildAutoMenu(_, root)
        for _, minutes in ipairs(ns.Friends.AUTO_MINUTES) do
            root:CreateRadio(AutoLabel(minutes), function() return ns.Friends:AutoSync() == minutes end,
                function() ns.Friends:SetAutoSync(minutes) end)
        end
    end
    local ok, dropdown = pcall(CreateFrame, "DropdownButton", nil, pane, "WowStyle1DropdownTemplate")
    if ok and dropdown and dropdown.SetupMenu then
        autoButton = dropdown
        autoButton:SetWidth(130)
        autoButton:SetupMenu(BuildAutoMenu)
        autoButton.Update = function(self) self:GenerateMenu() end
    else
        autoButton = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
        autoButton:SetSize(130, 22)
        autoButton:SetNormalFontObject("GameFontHighlightSmall")
        autoButton:SetScript("OnClick", function(self)
            if MenuUtil and MenuUtil.CreateContextMenu then
                MenuUtil.CreateContextMenu(self, BuildAutoMenu)
            else
                ns.Friends:NextAutoSync()
            end
        end)
        autoButton.Update = function(self) self:SetText(AutoLabel(ns.Friends:AutoSync())) end
    end
    autoButton:SetPoint("TOPRIGHT", -2, -32)
    autoButton:HookScript("OnEnter", function(self)
        ShowTip(self, "Automatic sync", "Syncs with every friend who is online, on a timer, while you play.")
    end)
    autoButton:HookScript("OnLeave", GameTooltip_Hide)

    -- Lined up with the name box's text, and centred on the dropdown.
    local autoLabel = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    autoLabel:SetPoint("LEFT", box, "LEFT", 0, 0)
    autoLabel:SetPoint("TOP", autoButton, "TOP")
    autoLabel:SetPoint("BOTTOM", autoButton, "BOTTOM")
    autoLabel:SetJustifyV("MIDDLE")
    autoLabel:SetText("Auto-sync")

    local line = pane:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.12)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 4, -(TOP - 4))
    line:SetPoint("TOPRIGHT", -4, -(TOP - 4))

    -- The Characters tab's list, whose scroll bar shows only when the rows don't fit.
    list = ns.Panel.CreateList(pane, ROW, CreateRow, UpdateRow)
    list:SetPoint("TOPLEFT", 0, -TOP)
    list:SetPoint("BOTTOMRIGHT")

    empty = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", 8, -(TOP + 8))
    empty:SetPoint("RIGHT", -8, 0)
    empty:SetJustifyH("LEFT")
    empty:SetJustifyV("TOP")
    empty:SetText(TIP)

    ns.Friends.OnChange = function() FriendsPanel:Refresh() end
    -- Friends not heard from for a while are asked again as the tab opens.
    pane:HookScript("OnShow", function() ns.Friends:CheckOnline() end)
    self:Refresh()
end
