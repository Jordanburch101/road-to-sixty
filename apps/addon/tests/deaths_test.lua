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

-- A seeded journey is left alone.
C_DeathRecap = { GetRecapEvents = function() return recap end }
ns.char.seeded = true
recap = { { timestamp = now + 60, event = "SWING_DAMAGE", sourceName = "Hogger" } }
e = Die(60)
check(e[6] == nil, "a seeded journey is left alone")

if failures > 0 then
    print(failures .. " death test(s) failed.")
    os.exit(1)
end
print("Deaths tests passed.")
