local _, ns = ...

-- /fm icons: browses every icon the client offers for macros (thousands of
-- spell and item icons), previews any atlas, texture path or file ID typed
-- in, and copies the one clicked for use in code. Atlases cannot be listed
-- by the client, hence the preview box.

local COLUMNS, ROWS = 12, 9
local SIZE, GAP = 36, 4
local SCROLL_ROWS = 3

local frame, scrollBar, countText, preview, previewStatus, previewValue
local buttons, icons, offset = {}, {}, 0
local copyFrame

-- Addons cannot write to the clipboard, so this shows the text selected in
-- an edit box for the player to copy with Ctrl+C.
function ns.ShowCopyBox(text)
    text = tostring(text)
    if not copyFrame then
        copyFrame = CreateFrame("Frame", "ForeverModCopyFrame", UIParent, "BasicFrameTemplateWithInset")
        copyFrame:SetSize(340, 84)
        copyFrame:SetPoint("CENTER", 0, 220)
        copyFrame:SetFrameStrata("DIALOG")
        tinsert(UISpecialFrames, "ForeverModCopyFrame")

        local hint = copyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOP", 0, -30)
        hint:SetText("Press Ctrl+C to copy, then Escape to close")

        local box = CreateFrame("EditBox", nil, copyFrame, "InputBoxTemplate")
        box:SetSize(300, 20)
        box:SetPoint("BOTTOM", 0, 14)
        box:SetAutoFocus(false)
        box:SetScript("OnEscapePressed", function()
            copyFrame:Hide()
        end)
        -- Typing would change what gets copied, so put it back.
        box:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                self:SetText(copyFrame.text)
                self:HighlightText()
            end
        end)
        copyFrame.box = box
    end
    copyFrame.text = text
    copyFrame.box:SetText(text)
    copyFrame:Show()
    copyFrame.box:SetFocus()
    copyFrame.box:HighlightText()
end

-- Older clients list icon names without their folder.
local function IconPath(icon)
    if type(icon) == "string" and not icon:find("\\") then
        return "Interface\\Icons\\" .. icon
    end
    return icon
end

local function LoadIcons()
    local list, seen = {}, {}
    -- pairs skips either function if this client lacks it.
    for _, source in pairs({ GetMacroIcons, GetMacroItemIcons }) do
        local found = {}
        source(found)
        for _, icon in ipairs(found) do
            if not seen[icon] then
                seen[icon] = true
                list[#list + 1] = icon
            end
        end
    end
    return list
end

local function MaxOffset()
    return math.max(0, math.ceil(#icons / COLUMNS) - ROWS)
end

local function Refresh()
    offset = math.max(0, math.min(MaxOffset(), offset))
    for i, button in ipairs(buttons) do
        local icon = icons[offset * COLUMNS + i]
        button.value = icon and IconPath(icon)
        if icon then
            button.icon:SetTexture(button.value)
        end
        button:SetShown(icon ~= nil)
    end
    scrollBar:SetMinMaxValues(0, MaxOffset())
    scrollBar:SetValue(offset)
    countText:SetText(("%d icons - row %d of %d"):format(
        #icons, offset + 1, math.max(1, math.ceil(#icons / COLUMNS))))
end

local function ShowValueTooltip(owner, value, kind)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(tostring(value))
    GameTooltip:AddLine(kind, 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Click to copy", 0.5, 1, 0.5)
    GameTooltip:Show()
end

local function CreateIconButton(i)
    local button = CreateFrame("Button", nil, frame)
    button:SetSize(SIZE, SIZE)
    local col, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
    button:SetPoint("TOPLEFT", 14 + col * (SIZE + GAP), -96 - row * (SIZE + GAP))
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.2)
    button:SetScript("OnClick", function(self)
        ns.ShowCopyBox(self.value)
    end)
    button:SetScript("OnEnter", function(self)
        ShowValueTooltip(self, self.value, type(self.value) == "number" and "File ID" or "Texture path")
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

-- Shows whatever was typed: an atlas if the client knows the name, else a
-- texture path or file ID (blank if it does not exist).
local function ShowPreview(text)
    text = strtrim(text or "")
    if text == "" then return end
    previewValue = text
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(text) then
        preview:SetAtlas(text)
        previewStatus:SetText("|cff80ff80Atlas|r - click the preview to copy")
    else
        preview:SetTexCoord(0, 1, 0, 1)
        preview:SetTexture(tonumber(text) or text)
        previewStatus:SetText("Texture - blank means the client has no such file")
    end
end

local function CreateWindow()
    local width = 28 + COLUMNS * (SIZE + GAP)
    local height = 110 + ROWS * (SIZE + GAP)
    frame = CreateFrame("Frame", "ForeverModIconFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(width, height)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "ForeverModIconFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Icon browser")

    -- Preview: type an atlas name, texture path or file ID.
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 16, -36)
    label:SetText("Atlas, path or file ID:")
    local input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    input:SetSize(220, 20)
    input:SetPoint("LEFT", label, "RIGHT", 10, 0)
    input:SetAutoFocus(false)
    input:SetScript("OnEnterPressed", function(self)
        ShowPreview(self:GetText())
        self:ClearFocus()
    end)
    input:SetScript("OnEscapePressed", input.ClearFocus)

    local previewButton = CreateFrame("Button", nil, frame)
    previewButton:SetSize(40, 40)
    previewButton:SetPoint("TOPRIGHT", -18, -30)
    preview = previewButton:CreateTexture(nil, "ARTWORK")
    preview:SetAllPoints()
    local previewBack = previewButton:CreateTexture(nil, "BACKGROUND")
    previewBack:SetAllPoints()
    previewBack:SetColorTexture(1, 1, 1, 0.08)
    previewButton:SetScript("OnClick", function()
        if previewValue then
            ns.ShowCopyBox(previewValue)
        end
    end)
    previewStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    previewStatus:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -10)
    previewStatus:SetText("Press Enter to preview. Click any icon to copy it.")

    countText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countText:SetPoint("BOTTOMLEFT", 16, 10)

    for i = 1, COLUMNS * ROWS do
        buttons[i] = CreateIconButton(i)
    end

    scrollBar = CreateFrame("Slider", nil, frame)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetWidth(10)
    scrollBar:SetPoint("TOPRIGHT", -10, -96)
    scrollBar:SetPoint("BOTTOMRIGHT", -10, 28)
    scrollBar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    scrollBar:SetValueStep(1)
    local track = scrollBar:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOP")
    track:SetPoint("BOTTOM")
    track:SetWidth(4)
    track:SetColorTexture(0, 0, 0, 0.5)
    scrollBar:SetScript("OnValueChanged", function(_, value)
        local row = math.floor(value + 0.5)
        if row ~= offset then
            offset = row
            Refresh()
        end
    end)

    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta * SCROLL_ROWS
        Refresh()
    end)

    icons = LoadIcons()
    Refresh()
end

ns.Command("icons", "browse icons and preview atlases, click to copy a name", function()
    if not frame then
        CreateWindow()
    end
    frame:Show()
end)
