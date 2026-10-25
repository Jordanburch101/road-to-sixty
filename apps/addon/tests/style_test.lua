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

if failures == 0 then
    print("Style tests passed.")
else
    print(failures .. " style test(s) failed.")
    os.exit(1)
end
