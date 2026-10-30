local _, ns = ...

-- Who killed the player (issue #81), added to its "die" event (Journal.lua):
--   die  killer, kind, spell
-- killer the name of what dealt the killing blow; kind "p" when that was a
-- player, "pet" a player's pet (a hunter's, a warlock's: its own name, as
-- the recap gives no owner), "e" the world (falling, drowning, lava: killer
-- is then what it was), nil a creature or not known; spell the killing
-- blow's spell, nil for melee. All nil when the client told nothing. Seen
-- on Anniversary: the recap's events carry sourceGUID ("Player-...",
-- "Pet-...", "Creature-..."), sourceName with a realm for other realms'
-- players ("Name-Realm"), spellName and timestamp in Unix seconds.
--
-- From the death recap (C_DeathRecap), read as Forever's own death dialog
-- reads it: no ID is the latest death, and its event 1 the killing blow,
-- whose caster is sourceName unless hideCaster. It is the way that works on
-- Forever, which blocks the combat log for addons; Era and Anniversary have
-- the same functions. The recap may fill a moment after PLAYER_DEAD, so it
-- is read again every RETRY seconds, TRIES times; a recap whose killing
-- blow is older than STALE seconds, or the one already used, is the death
-- before's. Names that come back secret are left out.

local Deaths = {}
ns.Deaths = Deaths

local RETRY, TRIES, STALE = 1, 5, 30

local lastBlow          -- the timestamp of the killing blow last used

local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function Plain(v)
    if v ~= nil and not Secret(v) then return v end
end

-- The latest death's killing blow, from the recap: killer, kind, spell and
-- its timestamp; nil when the client gives none (yet).
local function KillingBlow()
    local recap = C_DeathRecap
    if type(recap) ~= "table" or type(recap.GetRecapEvents) ~= "function" then return end
    local ok, events = pcall(recap.GetRecapEvents)
    if not ok or type(events) ~= "table" or Secret(events) then return end
    local blow = events[1]
    if type(blow) ~= "table" then return end
    local when = Plain(blow.timestamp)
    if type(when) ~= "number" then return end
    local event = Plain(blow.event)
    if event == "ENVIRONMENTAL_DAMAGE" then
        local what = Plain(blow.environmentalType)
        what = type(what) == "string" and (_G["ACTION_ENVIRONMENTAL_DAMAGE_" .. what:upper()] or what) or nil
        return what, "e", nil, when
    end
    local killer = not Plain(blow.hideCaster) and Plain(blow.sourceName) or nil
    if type(killer) ~= "string" or killer == "" then return nil, nil, nil, when end
    local guid = Plain(blow.sourceGUID)
    local kind
    if type(guid) == "string" then
        kind = guid:match("^Player%-") and "p" or guid:match("^Pet%-") and "pet" or nil
    end
    local spell = event ~= "SWING_DAMAGE" and Plain(blow.spellName) or nil
    return killer, kind, type(spell) == "string" and spell or nil, when
end

-- Fills in death event e from the recap, retrying while it is not there yet.
-- A recap is this death's when its killing blow is not the one last seen
-- (at login, or the death before); and, when its time reads as Unix time
-- (as the combat log's), from the last STALE seconds.
local function Fill(e, tries)
    local killer, kind, spell, when = KillingBlow()
    local fresh = when and when ~= lastBlow and (when < 1e9 or math.abs(when - ns.Now()) <= STALE)
    if fresh then
        lastBlow = when
        e[6], e[7], e[8] = killer, kind, spell
        return
    end
    if tries > 1 then
        C_Timer.After(RETRY, function() ns.SafeCall(Fill, e, tries - 1) end)
    end
end

-- A recap kept from before (a death the session before) is not a new one.
ns.On("PLAYER_LOGIN", function()
    lastBlow = select(4, KillingBlow())
end)

-- Journal.lua logs the death first (it loads first): the newest event, now.
ns.On("PLAYER_DEAD", function()
    if ns.char.seeded then return end
    local e = ns.char.events[#ns.char.events]
    if e and e[2] == "die" and e[1] == ns.Now() and e[6] == nil then
        Fill(e, TRIES)
    end
end)

-- How to show a death: "Killed by Name (Mortal Strike)", "Killed by Name
-- (pet, Kill Command)", "Died: Falling", or "Died" when its killer is not known.
function Deaths:Title(e)
    local killer, kind, spell = e[6], e[7], e[8]
    if type(killer) ~= "string" then return "Died" end
    if kind == "e" then return "Died: " .. killer end
    local notes = {}
    if kind == "pet" then notes[#notes + 1] = "pet" end
    if type(spell) == "string" then notes[#notes + 1] = spell end
    return ("Killed by %s%s"):format(killer, #notes > 0 and (" (" .. table.concat(notes, ", ") .. ")") or "")
end
