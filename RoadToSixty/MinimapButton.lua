local addonName, ns = ...

-- Minimap button: the addon icon on the minimap's edge in the usual round
-- tracking border. Left-click opens the journey map; drag moves it around the
-- minimap. /rts minimap shows or hides it. Also the click handler for the
-- addon compartment menu, on clients that have one (see the toc).

local ICON = "Interface\\AddOns\\" .. addonName .. "\\icon"
local button

local function Place()
    local angle = math.rad(ns.db.minimap.angle)
    local radius = Minimap:GetWidth() / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- While dragging, follow the cursor's angle around the minimap's centre.
local function FollowCursor()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
    Place()
end

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("Road to Sixty")
    GameTooltip:AddLine("Left-click: open the journey map", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function Create()
    button = CreateFrame("Button", "RoadToSixtyMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(18, 18)
    icon:SetPoint("TOPLEFT", 7, -6)
    -- Cut the icon's own square border so it sits inside the round frame.
    icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function()
        ns.Map:Toggle()
    end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
    -- Nudge the icon while pressed, like Blizzard's buttons.
    button:SetScript("OnMouseDown", function() icon:SetPoint("TOPLEFT", 8, -7) end)
    button:SetScript("OnMouseUp", function() icon:SetPoint("TOPLEFT", 7, -6) end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", FollowCursor)
        GameTooltip_Hide()
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        icon:SetPoint("TOPLEFT", 7, -6)
    end)

    Place()
end

local function Refresh()
    if ns.db.minimap.hide then
        if button then button:Hide() end
        return
    end
    if not button then Create() end
    button:Show()
end

ns.On("PLAYER_LOGIN", Refresh)

ns.Command("minimap", "show or hide the minimap button", function()
    ns.db.minimap.hide = not ns.db.minimap.hide
    Refresh()
    ns.Print("Minimap button " .. (ns.db.minimap.hide and "hidden." or "shown."))
end)

-- Named in the toc (AddonCompartmentFunc) for the addon compartment menu.
function RoadToSixty_OnAddonCompartmentClick()
    ns.Map:Toggle()
end
