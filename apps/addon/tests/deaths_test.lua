-- Offline test of Deaths.lua with a fake death recap, read as Forever's own
-- death dialog reads it (#81): the killing blow is event 1 of the latest
-- recap. Covers a player's spell, a creature's melee, falling, a recap that
-- fills a moment late, the recap of the death before (or of the session
-- before), and names that come back secret. Run with LuaJIT from
-- apps/addon: luajit tests/deaths_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, timers = {}, {}
local now = 1793240000
local ns = { char = { events = {} } }
ns.Now = function() return now end
local pcAhead = 0   -- how far the PC's clock is ahead of the realm's
ns.PCTime = function() return now + pcAhead end
function ns.On(event, fn) handlers[event] = fn return true end
function ns.SafeCall(fn, ...) fn(...) end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function RunTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end
local SECRET = {}
issecretvalue = function(v) return v == SECRET end
ACTION_ENVIRONMENTAL_DAMAGE_FALLING = "Falling"

local recap = {}            -- the latest recap's events, newest (the killing blow) first
C_DeathRecap = { GetRecapEvents = function() return recap end }

assert(loadfile("RoadToSixty/Deaths.lua"))("RoadToSixty", ns)
local Deaths = ns.Deaths

-- A recap from the session before is there at login.
recap = { { timestamp = now - 3600, event = "SWING_DAMAGE", sourceName = "Old Murk-Eye" } }
handlers.PLAYER_LOGIN()

-- Journal.lua logs the death, then Deaths.lua fills it in.
local function Die(seconds)
    now = now + seconds
    local e = { now, "die", 0, 0, 0 }
    table.insert(ns.char.events, e)
    handlers.PLAYER_DEAD()
    return e
end

-- Killed by a player's spell.
recap = { { timestamp = now + 10, event = "SPELL_DAMAGE", sourceName = "Gorehowl", sourceGUID = "Player-4395-01A2B3C4",
    spellName = "Mortal Strike", amount = 1200 }, { timestamp = now + 8, event = "SWING_DAMAGE", sourceName = "Gorehowl" } }
local e = Die(10)
check(e[6] == "Gorehowl" and e[7] == "p" and e[8] == "Mortal Strike", "a player's spell: " .. tostring(e[6]))
check(Deaths:Title(e) == "Killed by Gorehowl (Mortal Strike)", "its title: " .. Deaths:Title(e))

-- Killed by a creature's melee: no spell, kind not known.
recap = { { timestamp = now + 60, event = "SWING_DAMAGE", sourceName = "Defias Pillager",
    sourceGUID = "Creature-0-4170-0-12-589-00005A" } }
e = Die(60)
check(e[6] == "Defias Pillager" and e[7] == nil and e[8] == nil, "a creature's melee")
check(Deaths:Title(e) == "Killed by Defias Pillager", "its title: " .. Deaths:Title(e))

-- Killed by a hunter's pet, as seen in Warsong Gulch: the recap gives the pet's GUID and name.
recap = { { timestamp = now + 60, event = "SPELL_DAMAGE", sourceName = "Yshaarj",
    sourceGUID = "Pet-0-6263-489-28360-19350-0200C90F48", spellName = "Kill Command" } }
e = Die(60)
check(e[7] == "pet" and Deaths:Title(e) == "Killed by Yshaarj (pet, Kill Command)", "a pet: " .. Deaths:Title(e))

-- Falling.
recap = { { timestamp = now + 60, event = "ENVIRONMENTAL_DAMAGE", environmentalType = "Falling" } }
e = Die(60)
check(e[6] == "Falling" and e[7] == "e" and Deaths:Title(e) == "Died: Falling", "falling: " .. Deaths:Title(e))

-- The recap still holds the death before when the player dies: read again
-- a moment later, when it has this one.
local before = recap
e = Die(60)
check(e[6] == nil and #timers == 1, "the recap of the death before is not this one's")
recap = { { timestamp = now + 1, event = "SPELL_DAMAGE", sourceName = "Ragepaw", spellName = "Rend" } }
RunTimers()
check(e[6] == "Ragepaw" and e[8] == "Rend", "read again once the recap has it")
check(before ~= recap, "(the test swapped the recap)")

-- Nothing comes: given up after a few tries, the death stays a plain one.
e = Die(60)
for _ = 1, 10 do RunTimers() end
check(e[6] == nil and #timers == 0 and Deaths:Title(e) == "Died", "no recap: a plain death, no endless retries")

-- A secret name (a mob inside an instance, on Forever) is left out.
recap = { { timestamp = now + 60, event = "SWING_DAMAGE", sourceName = SECRET } }
e = Die(60)
check(e[6] == nil and Deaths:Title(e) == "Died", "a secret name is left out")

-- A client without the recap: nothing, no error.
C_DeathRecap = nil
e = Die(60)
for _ = 1, 10 do RunTimers() end
check(e[6] == nil, "no death recap on this client")

C_DeathRecap = { GetRecapEvents = function() return recap end }

-- The recap's time is by the PC's clock (#100): a PC two minutes fast still
-- gets the killer; a recap two minutes old by both clocks does not.
pcAhead = 120
recap = { { timestamp = now + 60 + 120, event = "SWING_DAMAGE", sourceName = "Bellygrub" } }
e = Die(60)
check(e[6] == "Bellygrub", "a PC with its clock off still gets the killer: " .. tostring(e[6]))
recap = { { timestamp = now - 120, event = "SWING_DAMAGE", sourceName = "Old Kill" } }
e = Die(60)
for _ = 1, 10 do RunTimers() end
check(e[6] == nil, "a recap stale by both clocks is the death before's")
pcAhead = 0

-- A recap the client keeps from addons is not read, and raises nothing.
canaccesstable = function(t) return t ~= recap end
recap = { { timestamp = now + 60, event = "SWING_DAMAGE", sourceName = "Hidden" } }
e = Die(60)
for _ = 1, 10 do RunTimers() end
check(e[6] == nil, "an inaccessible recap is left alone")
canaccesstable = function() return true end
-- One that errors when read is left alone too, at a death and at login.
C_DeathRecap = { GetRecapEvents = function() return setmetatable({}, { __index = function() error("secret") end }) end }
e = Die(60)
for _ = 1, 10 do RunTimers() end
check(e[6] == nil, "a recap that errors when read is left alone")
check(pcall(handlers.PLAYER_LOGIN), "and logging in with one raises nothing")
C_DeathRecap = { GetRecapEvents = function() return recap end }

-- A death by a player or a player's pet has its own look; any other, the plain one.
check(Deaths.Look({ 0, "die", 0, 0, 0, "Gorehowl", "p" }) == "diePvP"
    and Deaths.Look({ 0, "die", 0, 0, 0, "Yshaarj", "pet" }) == "diePvP", "a death by a player looks its own")
check(Deaths.Look({ 0, "die", 0, 0, 0, "Defias Pillager" }) == "die" and Deaths.Look({ 0, "die", 0, 0, 0, "Falling", "e" }) == "die"
    and Deaths.Look({ 0, "die", 0, 0, 0 }) == "die", "other deaths look plain")

-- The player's own explosive backfiring: no player's kill, saved before 1.21
-- as "p" with the player's own name, from then on as "self".
local me = Deaths.OwnNames({ rosterKey = "Hollow Grimtusk-Some Realm" })
check(me["Hollow Grimtusk"], "the journey's own name")
-- A friend's journey has no roster key: its entry's name; a key saved
-- before the surname loaded has the first name only, the entry the full one.
check(Deaths.OwnNames({}, { name = "Ann Smith" })["Ann Smith"], "a friend's journey, by its entry")
local both = Deaths.OwnNames({ rosterKey = "Hollow-Some Realm" }, { name = "Hollow Grimtusk" })
check(both.Hollow and both["Hollow Grimtusk"], "both names")
local backfire = { 0, "die", 0, 0, 0, "Hollow Grimtusk", "p", "Dynamite Backfire" }
check(not Deaths.ByPlayer(backfire, me) and Deaths.BySelf(backfire, me), "an old death by the player's own blow")
check(Deaths.ByPlayer({ 0, "die", 0, 0, 0, "Gorehowl", "p" }, me), "another player's still counts")
check(not Deaths.ByPlayer({ 0, "die", 0, 0, 0, "Hollow Grimtusk", "self", "Dynamite Backfire" }, me), "a self death")
ns.view = { rosterKey = "Hollow Grimtusk-Some Realm" }
check(Deaths.Look(backfire) == "die" and Deaths:Title(backfire) == "Died: Dynamite Backfire",
    "it looks plain, by the spell: " .. Deaths:Title(backfire))
ns.view = nil
UnitGUID = function() return "Player-4395-0SELF" end
recap = { { timestamp = now + 120, event = "SPELL_DAMAGE", sourceName = "Hollow Grimtusk", sourceGUID = "Player-4395-0SELF",
    spellName = "Dynamite Backfire" } }
e = Die(120)
check(e[7] == "self" and e[8] == "Dynamite Backfire", "a new one is saved as the player's own: " .. tostring(e[7]))
UnitGUID = function() return "Player-4395-0OTHER" end

-- A seeded journey is left alone.
ns.char.seeded = true
recap = { { timestamp = now + 60, event = "SWING_DAMAGE", sourceName = "Hogger" } }
e = Die(60)
check(e[6] == nil, "a seeded journey is left alone")

if failures > 0 then
    print(failures .. " death test(s) failed.")
    os.exit(1)
end
print("Deaths tests passed.")
