-- Offline test of Style.lua. Run with LuaJIT from apps/addon:
-- luajit tests/style_test.lua
--
-- Every event kind History lists has an icon of its own. In 1.11.0 the
-- enchant kind had none, and History, Stats and Characters stayed empty for
-- any character with an enchant. Style.lua now falls back to a question
-- mark, so this test is what notices a new kind without one.

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Style.lua"))("RoadToSixty", ns)
local icons = ns.Style.EVENT_ICONS

-- The kinds Panel.lua's BuildHistory reads, from its source. "on" and "out"
-- only set things for other entries (the level, the run's summary).
local source = assert(io.open("RoadToSixty/Panel.lua")):read("*a")
local body = source:match("\nlocal function BuildHistory%(%).-\nend\n")
check(body ~= nil, "found BuildHistory in Panel.lua")
local quiet = { on = true, out = true }
local seen = 0
for kind in (body or ""):gmatch('kind ==? "(%a+)"') do
    seen = seen + 1
    if not quiet[kind] then
        check(icons[kind] ~= nil, "History kind " .. kind .. " has an icon in Style.lua's EVENT_ICONS")
    end
end
check(seen >= 20, "read the kinds History lists, found " .. seen)

-- Every icon is drawable: a file or an atlas, and a size.
for kind, style in pairs(icons) do
    check((style.file or style.atlas) and style.size, "the icon for " .. kind .. " has art and a size")
end

-- The replay skips long teleports and boat trips and travels short ones;
-- instant jumps (logins) are always skipped, deaths never.
local Style = ns.Style
check(Style.Instant(Style.Jump("h"), 0, 0, 400, 0), "a long hearthstone passes at once")
check(not Style.Instant(Style.Jump("h"), 0, 0, 40, 0), "a short hearthstone is travelled")
check(Style.Instant(Style.Jump("b"), 0, 0, 0, 300), "a long boat trip passes at once")
check(not Style.Instant(Style.Jump("b"), 0, 0, 20, 20), "a short boat ride is travelled")
check(Style.Instant(Style.Jump("l"), 0, 0, 1, 0), "a login is always instant")
check(not Style.Instant(Style.Jump("d"), 0, 0, 900, 0), "a death's run to the graveyard is never skipped")

-- Where the client lacks the kind's own atlas (Era, Anniversary), its classic
-- stand-in is used; where it has it (Forever), its own.
local function FakeIcon(known)
    return { SetAtlas = function(self, name) if known[name] then self.atlas = name return true end return false end,
        SetTexture = function(self, file) self.file = file end, SetTexCoord = function() end,
        SetVertexColor = function() end }
end
local text = { SetText = function() end, SetTextColor = function() end, SetShadowOffset = function() end }
local classic = FakeIcon({ ["poi-town"] = true })
ns.SetEventIcon(classic, text, "zone")
check(classic.atlas == "poi-town", "zone discovered shows poi-town without Forever's pin")
local forever = FakeIcon({ ["Waypoint-MapPin-Untracked"] = true, ["poi-town"] = true })
ns.SetEventIcon(forever, text, "zone")
check(forever.atlas == "Waypoint-MapPin-Untracked", "Forever keeps its pin")
local level = FakeIcon({ ["collections-levelplate-black"] = true })
ns.SetEventIcon(level, text, "lvl", 14)
check(level.atlas == "collections-levelplate-black", "a level up shows the black plate without Forever's badge")
local boat = FakeIcon({ flightmaster = true })
ns.SetEventIcon(boat, text, "boat")
check(boat.atlas == "flightmaster", "a boat trip shows the flight master without Forever's boat")

-- Map markers drawn from game icon art sit in the item button frame, one
-- look made in one place (#110): made once per marker, the icon at the size
-- asked and the frame around it, and taken off when the marker is reused.
local function Region()
    local r = { shown = true }
    function r:Hide() self.shown = false end
    function r:Show() self.shown = true end
    function r:SetShown(on) self.shown = on end
    function r:SetSize(w, h) self.w, self.h = w, h end
    function r:SetTexture(t) self.texture = t return true end
    function r:SetAtlas(a) self.atlas = a return true end
    function r:SetText(t) self.text = t end
    function r:SetTexCoord() end
    function r:SetPoint() end
    function r:ClearAllPoints() end
    function r:SetAllPoints() end
    function r:SetDrawLayer() end
    function r:SetVertexColor() end
    function r:CreateTexture() return Region() end
    function r:CreateFontString() return Region() end
    return r
end
local made = 0
CreateFrame = function() made = made + 1 return Region() end
local Style = ns.Style
local marker = Region()
marker.icon, marker.text = Region(), Region()
marker.text.text = "14"
local framed = Style.Frame(marker, "Interface\\Icons\\INV_Scroll_03", Style.MARKER_ICON)
check(Style.MARKER_ICON == 16 and Style.NODE_ICON == 12, "the picked sizes")
check(marker.framed == framed and framed.shown and not marker.icon.shown and marker.text.text == "",
    "the marker's own icon and text give way to the frame")
check(framed.icon.w == 16 and framed.icon.texture == "Interface\\Icons\\INV_Scroll_03" and marker.w == 18,
    "icon at the size asked, the marker a little larger")
check(math.abs(framed.frame.w - 16 * 64 / 37) < 1e-9 and framed.frame.texture == "Interface\\Buttons\\UI-Quickslot2",
    "the item button frame around it")
check(not framed.count.shown, "no count but a node's")
Style.Frame(marker, "Interface\\Icons\\INV_Ore_Copper_01", Style.NODE_ICON)
check(made == 1 and framed.icon.w == 12 and marker.w == 14, "made once per marker, resized for a node")
framed.count:Show()
Style.Frame(marker, "Interface\\Icons\\INV_Scroll_03", Style.MARKER_ICON)
check(not framed.count.shown, "a node's count left on a marker framed again")
Style.Unframe(marker)
check(not framed.shown and marker.icon.shown, "taken off for a marker drawn otherwise")
Style.Unframe(Region())

-- SetEventIcon says which icons are game icon art, to be framed: a file
-- given or the kind's own, and an atlas the client lacks falling back to one.
local icon, text = Region(), Region()
local size, art = ns.SetEventIcon(icon, text, "prof", nil, "Interface\\Icons\\Trade_Mining")
check(size == 18 and art == "Interface\\Icons\\Trade_Mining", "a file given is art")
size, art = ns.SetEventIcon(icon, text, "rep")
check(art == icons.rep.file, "a kind's own file is art")
size, art = ns.SetEventIcon(icon, text, "die")
check(size == 16 and art == nil, "an atlas is not")
icon.SetAtlas = function() return false end
size, art = ns.SetEventIcon(icon, text, "rare")
check(art == icons.rare.fallback, "an atlas the client lacks falls back to art")
-- A group shows one icon on the map: a party's, or a raid's (Map.lua).
check(icons.grp.atlas == "socialqueuing-icon-group" and icons.grpRaid.atlas == "Raid", "the party and raid icons")
-- Other art isn't framed: the quest turn-in's fallback is a gossip glyph.
size, art = ns.SetEventIcon(icon, text, "qd")
check(icons.qd.fallback and art == nil, "a fallback that isn't icon art taken as art")
size, art = ns.SetEventIcon(icon, text, "prof", nil, 136240)
check(art == 136240, "an icon by file ID not taken as art")

-- Lists in our windows show game icon art in one small item button
-- (Screens.lua, #131): made at the bags' 37 and scaled, so its border art
-- fits; the row keeps the mouse; an item's quality border over the icon.
assert(loadfile("RoadToSixty/Screens.lua"))("RoadToSixty", ns)
CreateFrame = function(kind)
    local b = Region()
    b.kind = kind
    b.icon = Region()
    function b:SetScale(s) self.scale = s end
    function b:EnableMouse(on) self.mouse = on end
    return b
end
SetItemButtonTexture = function(button, file) button.icon.texture = file end
local button = ns.Screens.IconButton(Region(), 22)
check(button.kind == "ItemButton" and button.w == 37 and math.abs(button.scale - 22 / 37) < 1e-9,
    "an item button at 37, scaled to the size asked")
check(button.mouse == false, "the row under it keeps the mouse")
ns.Screens.SetIcon(button, "Interface\\Icons\\INV_Sword_04", 3)
check(button.icon.texture == "Interface\\Icons\\INV_Sword_04", "the icon set")
check(button.lootBorder.shown and button.lootBorder.atlas == "loottoast-itemborder-blue", "a blue item's border")
ns.Screens.SetIcon(button, "Interface\\Icons\\INV_Scroll_03")
check(not button.lootBorder.shown, "no border without a quality")
ns.Screens.SetIcon(button, "Interface\\Icons\\INV_Misc_Pelt_Wolf_01", 1)
check(not button.lootBorder.shown, "no border for a white item")

-- And they are made only there: a file the release ships that makes an
-- item button, draws the item button frame, or a quality border of its own
-- would drift from the one look. GearCard.lua's slots draw their own frame
-- round bigger icons, from before (#131 leaves it).
local OWN = {      -- { pattern, what, files allowed }
    { 'CreateFrame%(%s*"ItemButton"', "item button", { ["Screens.lua"] = true } },
    { "ItemButtonTemplate", "item button", { ["Screens.lua"] = true } },
    { "UI%-Quickslot2", "item button frame", { ["Style.lua"] = true, ["GearCard.lua"] = true } },
    { "loottoast%-itemborder", "quality border", { ["Style.lua"] = true } },
}
local shipped, debug = {}, false
for line in io.lines("RoadToSixty/RoadToSixty.toc") do
    if line:find("#@debug@", 1, true) then
        debug = true
    elseif line:find("#@end-debug@", 1, true) then
        debug = false
    elseif not debug and line:match("^[%w_/]+%.lua%s*$") then
        shipped[#shipped + 1] = line:match("^(%S+)")
    end
end
check(#shipped > 20, "read the shipped files from the toc, found " .. #shipped)
for _, file in ipairs(shipped) do
    local f = io.open("RoadToSixty/" .. file)
    if f then
        local code = f:read("*a")
        f:close()
        for _, own in ipairs(OWN) do
            check(own[3][file] or not code:find(own[1]), file .. " makes its own " .. own[2]
                .. "; use Screens.IconButton, Screens.ItemButton or Style.Frame")
        end
    end
end

if failures == 0 then
    print("Style tests passed.")
else
    print(failures .. " style test(s) failed.")
    os.exit(1)
end
