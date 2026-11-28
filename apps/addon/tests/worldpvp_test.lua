-- Offline test of WorldPvP.lua with the honorable kill strings as the
-- classic clients have them: a kill with a rank and one without, the player
-- killed described from the target or from a nameplate seen before, a name
-- with a surname, other honor messages, a kill inside a battleground, enemies
-- seen too long ago, the line, tooltip and record, and a seeded journey. Run
-- with LuaJIT from apps/addon: luajit tests/worldpvp_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers = {}
local clock = 1000
local ns = { char = { events = {} } }
ns.Now = function() return 1793240000 + clock end
function ns.On(event, fn) handlers[event] = fn return true end
function ns.SafeCall(fn, ...) fn(...) end
function ns.Command() end
ns.Commas = function(n) return tostring(n) end
ns.Journal = { Log = function(_, kind, ...)
    local e = { ns.Now(), kind, 0, 1, 2, ... }
    table.insert(ns.char.events, e)
    return e
end }
GetTime = function() return clock end
date = os.date

COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (%d Honor Points)"
COMBATLOG_HONORGAIN_NO_RANK = "%s dies, honorable kill (%d Honor Points)"

-- Units: whoever is targeted, moused over or on a nameplate.
local units = {}
local instance = { false, "none" }
local surnames = false
IsInInstance = function() return instance[1], instance[2] end
RegionalUniqueNamesEnabled = function() return surnames end
UnitName = function(unit) local u = units[unit] return u and u.name, u and u.second end
UnitExists = function(unit) return units[unit] ~= nil end
UnitIsPlayer = function(unit) return units[unit] ~= nil and not units[unit].npc end
UnitIsEnemy = function(_, unit) return units[unit] ~= nil and not units[unit].friend end
UnitLevel = function(unit) return units[unit] and units[unit].level or 0 end
UnitClass = function(unit) local u = units[unit] return u and u.class, u and u.class end
UnitRace = function(unit) local u = units[unit] return u and u.race, u and u.race end
GetGuildInfo = function(unit) return units[unit] and units[unit].guild end
hooksecurefunc = function() end

assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Battlegrounds.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Duels.lua"))("RoadToSixty", ns)
local battlegroundHonor = handlers.CHAT_MSG_COMBAT_HONOR_GAIN
assert(loadfile("RoadToSixty/WorldPvP.lua"))("RoadToSixty", ns)
local WorldPvP = ns.WorldPvP
check(handlers.CHAT_MSG_COMBAT_HONOR_GAIN ~= battlegroundHonor, "WorldPvP listens to the honor messages")

local function Say(msg)
    local before = #ns.char.events
    handlers.CHAT_MSG_COMBAT_HONOR_GAIN(msg)
    return #ns.char.events > before and ns.char.events[#ns.char.events] or nil
end

-- A targeted orc with a rank.
units.target = { name = "Gorehowl", class = "WARRIOR", level = 24, race = "Orc", guild = "Blood Moon" }
local e = Say("Gorehowl dies, honorable kill Rank: Scout (50 Honor Points)")
check(e and e[2] == "hk" and e[6] == "Gorehowl" and e[7] == "Scout" and e[8] == 50, "a kill with a rank")
check(e and e[9] == "WARRIOR" and e[10] == 24 and e[11] == "Orc" and e[12] == "Blood Moon",
    "the player killed described from the target")
check(e and WorldPvP:Title(e) == "Killed Gorehowl", "its title: " .. tostring(e and WorldPvP:Title(e)))

-- Seen on a nameplate, gone from the target by the kill, and no rank.
units.target = nil
units.nameplate3 = { name = "Zuljin", class = "HUNTER", level = 30, race = "Troll" }
handlers.NAME_PLATE_UNIT_ADDED("nameplate3")
units.nameplate3 = nil
clock = clock + 40
e = Say("Zuljin dies, honorable kill (12 Honor Points)")
check(e and e[6] == "Zuljin" and e[7] == nil and e[8] == 12 and e[9] == "HUNTER" and e[11] == "Troll",
    "a kill without a rank, described from a nameplate seen before")

-- Never seen: the name and honor alone.
e = Say("Rexxar dies, honorable kill (8 Honor Points)")
check(e and e[6] == "Rexxar" and e[8] == 8 and e[9] == nil and e[10] == nil, "a player never seen")

-- Seen too long ago.
units.mouseover = { name = "Thrall", class = "SHAMAN", level = 60 }
handlers.UPDATE_MOUSEOVER_UNIT()
units.mouseover = nil
clock = clock + 600
e = Say("Thrall dies, honorable kill (5 Honor Points)")
check(e and e[6] == "Thrall" and e[9] == nil, "a player seen too long ago is not used")

-- Friends and NPCs are not kept.
units.target = { name = "Ally", class = "MAGE", level = 30, friend = true }
handlers.PLAYER_TARGET_CHANGED()
units.target = nil
e = Say("Ally dies, honorable kill (5 Honor Points)")
check(e and e[9] == nil, "a friendly player is not kept")

-- Surnames: the unit gives "First", "Last", and the message only the first
-- name, or the full name.
surnames = true
units.target = { name = "Hollow", second = "Grimtusk", class = "ROGUE", level = 22 }
handlers.PLAYER_TARGET_CHANGED()
units.target = nil
e = Say("Hollow dies, honorable kill (9 Honor Points)")
check(e and e[6] == "Hollow Grimtusk" and e[9] == "ROGUE", "the full name kept when the message gives the first")
e = Say("Hollow Grimtusk dies, honorable kill (9 Honor Points)")
check(e and e[6] == "Hollow Grimtusk" and e[9] == "ROGUE", "a message with the full name")

-- Two players of one first name seen lately: the first name alone gives
-- neither one's details, the full name still does.
units.target = { name = "Ann", second = "Smith", class = "MAGE", level = 20 }
handlers.PLAYER_TARGET_CHANGED()
units.mouseover = { name = "Ann", second = "Jones", class = "PRIEST", level = 21 }
handlers.UPDATE_MOUSEOVER_UNIT()
units.target, units.mouseover = nil, nil
e = Say("Ann dies, honorable kill (9 Honor Points)")
check(e and e[6] == "Ann" and e[9] == nil, "a shared first name gives no one's details: " .. tostring(e and e[6]))
e = Say("Ann Smith dies, honorable kill (9 Honor Points)")
check(e and e[6] == "Ann Smith" and e[9] == "MAGE", "the full name still finds the right one")
surnames = false

-- Other honor messages log nothing.
check(Say("You have been awarded 126 honor points.") == nil, "bonus honor is no kill")
check(Say("Gorehowl dies, dishonorable kill.") == nil, "a dishonorable kill is none")

-- Inside a battleground the run counts them, and nothing is logged.
instance = { true, "pvp" }
check(Say("Gorehowl dies, honorable kill Rank: Scout (50 Honor Points)") == nil, "nothing logged in a battleground")
instance = { true, "arena" }
check(Say("Gorehowl dies, honorable kill (50 Honor Points)") == nil, "nothing logged in an arena")
instance = { false, "none" }

-- History's and the map's line.
ns.ClassName = function(class) return ({ WARRIOR = "Warrior" })[class] or class end
local _, detail, icon = WorldPvP:Describe({ 0, "hk", 0, 0, 0, "Gorehowl", "Scout", 50, "WARRIOR", 24, "Orc", "Blood Moon" })
check(detail == "Level 24 Orc Warrior <Blood Moon>, Scout, 50 honor", "the detail: " .. tostring(detail))
check(type(icon) == "string", "an icon")
_, detail = WorldPvP:Describe({ 0, "hk", 0, 0, 0, "Rexxar" })
check(detail == "Honorable kill", "nothing known: " .. tostring(detail))

-- The record against one player: kills, and deaths to them.
table.insert(ns.char.events, { ns.Now(), "die", 0, 0, 0, "Gorehowl", "p" })
table.insert(ns.char.events, { ns.Now(), "die", 0, 0, 0, "Gorehowl" })      -- a creature of that name
table.insert(ns.char.events, { ns.Now(), "hk", 0, 0, 0, "Gorehowl" })
local kills, deaths = WorldPvP.Record(ns.char.events, "Gorehowl")
check(kills == 2 and deaths == 1, ("the record: %d kills, %d deaths"):format(kills, deaths))

-- The tooltip.
ns.ClassColor = function() return 1, 1, 1 end
ns.view = ns.char
CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 } }
local shown = {}
GameTooltip = {
    SetOwner = function() shown = {} end, Show = function() end,
    AddLine = function(_, text) shown[#shown + 1] = text end,
    AddDoubleLine = function(_, left, right) shown[#shown + 1] = left .. " = " .. right end,
}
WorldPvP:ShowTooltip({}, { 1793240000, "hk", 0, 0, 0, "Gorehowl", "Scout", 50, "WARRIOR", 24, "Orc" }, "Hillsbrad Foothills")
local text = table.concat(shown, " | ")
check(shown[1] == "Killed Gorehowl" and shown[2]:find("Gorehowl = Level 24", 1, true)
    and shown[2]:find("UI-Classes-Circles", 1, true) and shown[3] == "Orc Warrior"
    and text:find("Rank = Scout", 1, true) and text:find("Honor = 50", 1, true)
    and text:find("You killed them = 2 times", 1, true) and text:find("They killed you = once", 1, true)
    and text:find("Where = Hillsbrad Foothills", 1, true) and text:find("When = ", 1, true), "the tooltip: " .. text)
WorldPvP:ShowTooltip({}, { 1793240000, "hk", 0, 0, 0, "Rexxar" })
text = table.concat(shown, " | ")
check(not text:find("Rank", 1, true) and not text:find("You killed", 1, true) and not text:find("Where", 1, true),
    "a kill known by name only leaves out what is not known: " .. text)

-- A crowd of enemies seen at once stays bounded.
for i = 1, 300 do
    units["nameplate" .. i] = { name = "Grunt" .. i, class = "WARRIOR", level = 30 }
    handlers.NAME_PLATE_UNIT_ADDED("nameplate" .. i)
end
units.target = nil
e = Say("Grunt300 dies, honorable kill (5 Honor Points)")
check(e and e[9] == "WARRIOR", "the enemy seen last is kept in a crowd")

-- A seeded journey is left alone.
ns.char.seeded = true
check(Say("Gorehowl dies, honorable kill (50 Honor Points)") == nil, "a seeded journey is left alone")

if failures > 0 then
    print(failures .. " world PvP test(s) failed.")
    os.exit(1)
end
print("World PvP tests passed.")
