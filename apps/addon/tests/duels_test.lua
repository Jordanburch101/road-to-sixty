-- Offline test of Duels.lua with the client's own duel strings, as Forever's
-- launch build has them (#88): a duel won and lost, fled either way, a
-- challenge received and one sent (the StartDuel hook), a duel to the death,
-- someone else's duel nearby, a player from another realm, a challenge too
-- old to be this duel's, and a seeded journey. Run with LuaJIT from
-- apps/addon: luajit tests/duels_test.lua

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
ns.Journal = { Log = function(_, kind, ...)
    local e = { ns.Now(), kind, 0, 1, 2, ... }
    table.insert(ns.char.events, e)
    return e
end }
GetTime = function() return clock end
date = os.date

DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"

-- Units: the player, and whoever is targeted.
local units = { player = { name = "Jethil" } }
GetNormalizedRealmName = function() return "Dreamscythe" end
UnitName = function(unit) local u = units[unit] return u and u.name, u and u.realm end
UnitExists = function(unit) return units[unit] ~= nil end
UnitIsPlayer = function(unit) return units[unit] ~= nil end
UnitLevel = function(unit) return units[unit] and units[unit].level or 0 end
UnitClass = function(unit) local u = units[unit] return u and u.className, u and u.class end
UnitRace = function(unit) local u = units[unit] return u and u.raceName, u and u.race end
GetGuildInfo = function(unit) return units[unit] and units[unit].guild end
local hooked
hooksecurefunc = function(name, fn) if name == "StartDuel" then hooked = fn end end
StartDuel = function() end

assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Duels.lua"))("RoadToSixty", ns)
local Duels = ns.Duels
check(hooked ~= nil, "StartDuel is hooked")

local function Say(msg)
    local before = #ns.char.events
    handlers.CHAT_MSG_SYSTEM(msg)
    return #ns.char.events > before and ns.char.events[#ns.char.events] or nil
end

-- Challenged by a targeted warrior, and won.
units.target = { name = "Gorehowl", class = "WARRIOR", className = "Warrior", level = 24, race = "Orc", raceName = "Orc",
    guild = "Blood Moon" }
handlers.DUEL_REQUESTED("Gorehowl")
clock = clock + 60
local e = Say("Jethil has defeated Gorehowl in a duel")
check(e and e[2] == "duel" and e[6] == "Gorehowl" and e[7] == "won" and e[8] == "them", "a duel won, challenged")
check(e and e[9] == "WARRIOR" and e[10] == 24 and e[11] == "Orc" and e[12] == "Blood Moon" and e[13] == nil,
    "the opponent described from the target")
check(e and Duels:Title(e) == "Defeated Gorehowl in a duel", "its title: " .. tostring(e and Duels:Title(e)))

-- Challenging the target from its menu, and losing.
units.target = { name = "Thrall", class = "SHAMAN", level = 30, race = "Orc" }
hooked("target", true)
units.target = nil      -- the target changed before the end: what the challenge read stays
clock = clock + 90
e = Say("Thrall has defeated Jethil in a duel")
check(e and e[6] == "Thrall" and e[7] == "lost" and e[8] == "me" and e[9] == "SHAMAN" and e[10] == 30,
    "a duel lost, challenged by the player, described from the challenge")
check(e and Duels:Title(e) == "Lost a duel to Thrall", "its title: " .. tostring(e and Duels:Title(e)))

-- Fleeing, and the opponent fleeing; /duel with a name, nobody targeted.
hooked("Varian")
clock = clock + 30
e = Say("Jethil has fled from Varian in a duel")
check(e and e[6] == "Varian" and e[7] == "fled" and e[8] == "me" and e[9] == nil, "the player fled, /duel by name")
e = Say("Varian has fled from Jethil in a duel")
check(e and e[7] == "theyFled" and e[8] == nil, "the opponent fled; the challenge was used already")
check(e and Duels:Title(e) == "Varian fled a duel", "its title: " .. tostring(e and Duels:Title(e)))

-- Someone else's duel nearby: nothing.
check(Say("Gorehowl has defeated Thrall in a duel") == nil, "a duel nearby the player was not in")
check(Say("You have requested a duel.") == nil, "other system messages")

-- A player from another realm, challenged to the death.
handlers.DUEL_TO_THE_DEATH_REQUESTED("Anduin-Stormrage")
units.target = { name = "Anduin", realm = "Stormrage", class = "PRIEST", level = 60, race = "Human" }
clock = clock + 120
e = Say("Anduin-Stormrage has defeated Jethil in a duel")
check(e and e[6] == "Anduin-Stormrage" and e[8] == "them" and e[13] == true and e[9] == "PRIEST",
    "a duel to the death, another realm")
check(e and Duels:Title(e) == "Lost a duel to the death to Anduin-Stormrage", "its title: " .. tostring(e and Duels:Title(e)))

-- The player's own name with the realm added still counts.
units.target = nil
e = Say("Jethil-Dreamscythe has defeated Gorehowl in a duel")
check(e and e[7] == "won", "the player's name with its realm")

-- A challenge declined long ago is not this duel's.
handlers.DUEL_REQUESTED("Gorehowl")
clock = clock + 3600
e = Say("Gorehowl has defeated Jethil in a duel")
check(e and e[8] == nil, "a stale challenge is left out")

-- History's and the map's line: the opponent as far as known, who challenged.
ns.ClassName = function(class) return ({ WARRIOR = "Warrior", PRIEST = "Priest" })[class] or class end
local _, detail, icon = Duels:Describe({ 0, "duel", 0, 0, 0, "Gorehowl", "won", "them", "WARRIOR", 24, "Orc", "Blood Moon" })
check(detail == "Level 24 Orc Warrior <Blood Moon>, they challenged", "the detail: " .. tostring(detail))
check(type(icon) == "string", "an icon")
_, detail = Duels:Describe({ 0, "duel", 0, 0, 0, "Sylvanas", "lost", "me", nil, nil, "Scourge" })
check(detail == "Undead, you challenged", "the race named as the game names it: " .. tostring(detail))
_, detail = Duels:Describe({ 0, "duel", 0, 0, 0, "Tyrande", "lost", nil, nil, nil, "NightElf" })
check(detail == "Night Elf", "two-word race: " .. tostring(detail))
_, detail = Duels:Describe({ 0, "duel", 0, 0, 0, "Varian", "fled" })
check(detail == "Duel", "nothing known: " .. tostring(detail))
check(select(2, Duels:Color({ 0, "duel", 0, 0, 0, "A", "theyFled" })) > 0.9, "an opponent fleeing reads as a win")
-- The player's record against one opponent, for the tooltip.
local record = Duels.Record(ns.char.events, "Gorehowl")
check(record.count == 3 and record.won == 2 and record.lost == 1, "the record against one player: "
    .. record.count .. " duels, " .. record.won .. " won, " .. record.lost .. " lost")

-- The tooltip: the result's colour, the opponent with their level, who
-- challenged, the record, where and when.
ns.ClassColor = function() return 1, 1, 1 end
ns.view = ns.char
CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 } }
local shown = {}
GameTooltip = {
    SetOwner = function() shown = {} end, Show = function() end,
    AddLine = function(_, text) shown[#shown + 1] = text end,
    AddDoubleLine = function(_, left, right) shown[#shown + 1] = left .. " = " .. right end,
}
Duels:ShowTooltip({}, { 1793240000, "duel", 0, 0, 0, "Gorehowl", "lost", "them", "WARRIOR", 24, "Orc", nil, true },
    "Elwynn Forest")
local text = table.concat(shown, " | ")
check(shown[1] == "Lost a duel to the death to Gorehowl" and shown[2]:find("Gorehowl = Level 24", 1, true)
    and shown[2]:find("UI-Classes-Circles", 1, true) and shown[3] == "Orc Warrior"
    and text:find("A duel to the death", 1, true) and text:find("Challenged by = Them", 1, true)
    and text:find("Your duels with them = 2 won, 1 lost", 1, true) and text:find("Where = Elwynn Forest", 1, true)
    and text:find("When = ", 1, true), "the tooltip: " .. text)
Duels:ShowTooltip({}, { 1793240000, "duel", 0, 0, 0, "Tyrande", "fled" })
text = table.concat(shown, " | ")
check(not text:find("Challenged by", 1, true) and not text:find("Your duels", 1, true) and not text:find("Where", 1, true),
    "a duel known by name only leaves out what is not known: " .. text)

-- A seeded journey is left alone.
ns.char.seeded = true
check(Say("Jethil has defeated Gorehowl in a duel") == nil, "a seeded journey is left alone")

if failures > 0 then
    print(failures .. " duel test(s) failed.")
    os.exit(1)
end
print("Duels tests passed.")
