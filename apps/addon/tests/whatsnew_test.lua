-- Offline test of the in-game changelog (#132): scripts/whatsnew-data.lua
-- turns CHANGELOG.md into WhatsNewData.lua, and WhatsNew.lua picks which
-- versions a login shows, once per account. Run with LuaJIT from apps/addon:
-- luajit tests/whatsnew_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

-- The changelog, read as the release build reads it ----------------------------

local Data = dofile("scripts/whatsnew-data.lua")
local versions = Data.Parse(table.concat({
    "# Changelog",
    "",
    "Player-facing notes. Sections are `### New` and `### Fixed`.",
    "",
    "## 2.1.0",
    "",
    "### New",
    "- One line.",
    "- A note that goes on",
    "  over two lines, with `/rts friend Ann Lee` and **bold**.",
    "",
    "### Fixed",
    "- Fixed it.",
    "",
    "## 2.0.10",
    "",
    "### Fixed",
    "- Ten.",
    "",
    "## Unreleased",
    "",
    "### New",
    "- Not a version.",
    "",
    "## 2.0.9",
    "### New",
    "- Nine.",
}, "\r\n"))
check(#versions == 3, "versions read: " .. #versions)
check(versions[1].version == "2.1.0" and versions[2].version == "2.0.10" and versions[3].version == "2.0.9",
    "versions in the file's order")
local new = versions[1].sections[1]
check(new[1] == "New" and #new[2] == 2 and versions[1].sections[2][1] == "Fixed", "sections by heading")
check(new[2][1] == "One line.", "a one-line note: " .. tostring(new[2][1]))
check(new[2][2] == "A note that goes on over two lines, with /rts friend Ann Lee and bold.",
    "a note's lines joined, Markdown marks dropped: " .. tostring(new[2][2]))
check(#versions[2].sections == 1 and versions[2].sections[1][2][1] == "Ten.", "a heading that isn't a version ends one")

-- The file it writes loads, and keeps the newest versions only.
local ns = {}
local lua = Data.Lua(versions, 2)
assert(loadstring(lua))("RoadToSixty", ns)
check(#ns.WhatsNewData == 2 and ns.WhatsNewData[1].version == "2.1.0", "the data file loads, newest first")
check(ns.WhatsNewData[1].sections[1][2][2] == new[2][2], "notes kept as read")
local sample = ns.WhatsNewData

-- The real changelog reads, with a note in every section.
local file = assert(io.open("../../CHANGELOG.md", "rb"))
local real = Data.Parse(file:read("*a"))
file:close()
check(#real >= 10, "the real changelog's versions: " .. #real)
for _, v in ipairs(real) do
    check(#v.sections > 0, v.version .. " has sections")
    for _, section in ipairs(v.sections) do
        check(#section[2] > 0 and not section[2][1]:find("`"), v.version .. " " .. section[1] .. " has plain notes")
    end
end

-- Which versions a login shows -------------------------------------------------

local handlers, timers, printed = {}, {}, nil
ns = { db = {} }
function ns.On(event, fn) handlers[event] = fn return true end
function ns.Command(name, _, fn) ns.command = fn end
function ns.SafeCall(fn, ...) return fn(...) end
function ns.Print(text) printed = text end
local version, combat = "2.1.0", false
C_AddOns = { GetAddOnMetadata = function(_, field) return field == "Version" and version or nil end }
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
InCombatLockdown = function() return combat end
assert(loadfile("RoadToSixty/WhatsNew.lua"))("RoadToSixty", ns)
local WhatsNew = ns.WhatsNew
local shown
WhatsNew.Show = function(_, list) shown = list end

check(WhatsNew.Newer("2.0.10", "2.0.9") and not WhatsNew.Newer("2.0.9", "2.0.10"), "numbers, not text")
check(not WhatsNew.Newer("2.1.0", "2.1.0") and not WhatsNew.Newer("2.1.0-beta1", "2.0.0")
    and not WhatsNew.Newer("@project-version@", "1.0.0"), "only X.Y.Z is newer")

local data = {}
for i = 20, 1, -1 do data[#data + 1] = { version = "1.0." .. i, sections = {} } end
local list, seen = WhatsNew.AtLogin(data, "1.0.20", "1.0.17", true)
check(#list == 3 and list[1].version == "1.0.20" and list[3].version == "1.0.18" and seen == "1.0.20",
    "every version since the last one seen, newest first")
list = WhatsNew.AtLogin(data, "1.0.20", "1.0.2", true)
check(#list == 8 and list.cut and list[8].version == "1.0.13", "at most eight, the rest noted")
list = WhatsNew.AtLogin(data, "1.0.18", "1.0.17", true)
check(#list == 1 and list[1].version == "1.0.18", "nothing newer than the version running")
list, seen = WhatsNew.AtLogin(data, "1.0.20", "1.0.20", true)
check(list == nil and seen == "1.0.20", "nothing twice")
list, seen = WhatsNew.AtLogin(data, "1.0.19", "1.0.20", true)
check(list == nil and seen == "1.0.20", "an older version after a newer one shows nothing, and keeps the newer")
list, seen = WhatsNew.AtLogin(data, "1.0.20", nil, false)
check(list == nil and seen == "1.0.20", "a new account notes its first version quietly")
list, seen = WhatsNew.AtLogin(data, "1.0.20", nil, true)
check(#list == 1 and list[1].version == "1.0.20" and seen == "1.0.20",
    "an account from before the window sees this version's notes")
list, seen = WhatsNew.AtLogin(data, "1.0.21-beta1", "1.0.20", true)
check(list == nil and seen == "1.0.20", "a beta shows nothing")
list, seen = WhatsNew.AtLogin(data, "@project-version@", nil, true)
check(list == nil and seen == nil, "a dev build shows nothing and notes nothing")

-- At login: noted as seen when it shows, a few seconds in, and after combat.
ns.WhatsNewData = sample
local function Login(roster)
    ns.db.roster = roster
    handlers.ADDON_LOADED("RoadToSixty")
    handlers.PLAYER_LOGIN()
end
ns.db.whatsNewSeen = "2.0.9"
Login({ a = {} })
check(shown == nil and ns.db.whatsNewSeen == "2.0.9" and #timers == 1, "shown at once, or seen before it shows")
combat = true
timers[1]()
check(shown == nil and ns.db.whatsNewSeen == "2.0.9", "shown in combat")
combat = false
handlers.PLAYER_REGEN_ENABLED()
check(shown and #shown == 2 and shown[2].version == "2.0.10" and ns.db.whatsNewSeen == "2.1.0",
    "not shown after combat, or not noted")
shown, timers = nil, {}
Login({ a = {} })
check(#timers == 0 and shown == nil, "shown again for the same version")
ns.db.whatsNewSeen = nil
Login(nil)
check(#timers == 0 and ns.db.whatsNewSeen == "2.1.0", "a new account not noted quietly")

-- /rts changes: the newest versions, whatever was seen.
ns.command("")
check(shown and shown[1].version == "2.1.0" and #shown == 2 and not shown.cut, "/rts changes")
ns.WhatsNewData, shown = nil, nil
ns.command("")
check(shown == nil and printed and printed:find("no changelog"), "/rts changes without notes")

if failures == 0 then
    print("WhatsNew tests passed.")
else
    print(failures .. " whatsnew test(s) failed.")
    os.exit(1)
end
