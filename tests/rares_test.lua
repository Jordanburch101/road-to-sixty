-- Offline test of Rares.lua with a fake target whose name is secret, as on
-- Forever: a rare targeted alive whose XP message comes just before the
-- target is cleared is logged once with the message's name, and counted
-- after; adds killed while the rare stays targeted, a target cleared or
-- switched later, a corpse, normal mobs and secret classifications log
-- nothing.
-- Run with LuaJIT from the repo root: luajit tests/rares_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers = {}
local now = 1000
local ns = { char = { events = {} } }
ns.view = ns.char
ns.Journal = {
    Log = function(_, kind, ...)
        table.insert(ns.char.events, { now, kind, 0, 0, 0, ... })
    end,
}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
function ns.SafeCall(fn, ...) fn(...) end
function ns.Command() end
function ns.Print() end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end

time = function() return now end
GetTime = function() return now end

-- The target: { classification, level, dead }; its name is always secret.
local SECRET = {}
local target
issecretvalue = function(v) return v == SECRET end
UnitExists = function(u) return u == "target" and target ~= nil end
UnitIsPlayer = function() return false end
UnitName = function() return SECRET end
UnitClassification = function() return target[1] end
UnitLevel = function() return target[2] end
UnitIsDead = function() return target[3] end

assert(loadfile("RoadToSixty/Rares.lua"))("RoadToSixty", ns)
local Rares = ns.Rares

local function Target(class, level)
    target = { class, level, false }
    Fire("PLAYER_TARGET_CHANGED")
end
-- As on Forever: the XP message comes while the target still shows alive,
-- then the target is cleared.
local function KillTarget(name)
    Rares:Killed(name)
    now = now + 0.1
    target = nil
    Fire("PLAYER_TARGET_CHANGED")
end

-- A rare elite: an add dies first while the rare stays targeted, then the rare.
Target("rareelite", 35)
Rares:Killed("Skeletal Fiend")
now = now + 5
check(#ns.char.events == 0, "an add killed while the rare stays targeted is not the rare")
KillTarget("Mor'Ladim")
check(#ns.char.events == 1 and ns.char.events[1][6] == "Mor'Ladim" and ns.char.events[1][7] == "rareelite"
    and ns.char.events[1][8] == 35, "rare kill logged with the message's name")
check((Rares:Describe(ns.char.events[1])) == "Killed Mor'Ladim", "title")
check(select(2, Rares:Describe(ns.char.events[1])) == "Rare elite, level 35", "detail")

-- An add's kill message, then the player clears the target seconds later:
-- too late to be the add's death clearing it.
Target("rare", 20)
Rares:Killed("Murloc Forager")
now = now + 3
target = nil
Fire("PLAYER_TARGET_CHANGED")
check(#ns.char.events == 1, "target cleared long after a kill message is not the rare")

-- The add's kill message, then tab to another mob at once: not the rare.
Target("rare", 20)
Rares:Killed("Murloc Forager")
Target("normal", 20)
check(#ns.char.events == 1, "switching to another mob is not the rare dying")

-- The same rare killed again later: counted, not logged.
Target("rareelite", 35)
KillTarget("Mor'Ladim")
check(#ns.char.events == 1 and ns.char.rares["Mor'Ladim"][1] == 2, "second kill counted only")

-- A client that shows the target dead when the message comes: logged at once.
Target("rare", -1)
target[3] = true
Rares:Killed("Gruff Swiftbite")
check(#ns.char.events == 2 and select(2, Rares:Describe(ns.char.events[2])) == "Rare, level ??",
    "target already dead at the message, skull level")

-- Or seen dead by a health event just after the message.
Target("rare", 30)
Rares:Killed("Foulmane")
target[3] = true
Fire("UNIT_HEALTH", "target")
check(#ns.char.events == 3, "health event just after the message confirms it")

-- A corpse targeted after it died is not engaged.
target = { "rare", 20, true }
Fire("PLAYER_TARGET_CHANGED")
KillTarget("Old Murk-Eye")
check(#ns.char.events == 3, "a rare targeted already dead is not logged")

-- Normal mobs, elites and secret classifications are not rares.
for _, class in ipairs({ "normal", "elite", SECRET }) do
    Target(class, 12)
    KillTarget("Some Mob")
end
check(#ns.char.events == 3, "normal, elite and secret not logged")

-- The target cleared just before the XP message: still the rare's kill.
Target("rare", 28)
target = nil
Fire("PLAYER_TARGET_CHANGED")
now = now + 0.2
Rares:Killed("Ressan the Needler")
check(#ns.char.events == 4 and ns.char.events[4][6] == "Ressan the Needler", "message just after the target went")

-- But not a message long after.
Target("rare", 28)
target = nil
Fire("PLAYER_TARGET_CHANGED")
now = now + 5
Rares:Killed("Some Mob")
check(#ns.char.events == 4, "message long after the target went is not the rare")

-- Stats list, first killed first.
local list = Rares:List()
check(#list == 4 and list[1][1] == "Mor'Ladim" and list[1][2] == 2, "list")

-- A seeded journey is left alone.
ns.char.seeded = true
Target("rare", 10)
KillTarget("Seeded Rare")
check(#ns.char.events == 4, "seeded journey not recorded")

if failures > 0 then
    print(("rares_test: %d failure(s)"):format(failures))
    os.exit(1)
end
print("rares_test: ok")
