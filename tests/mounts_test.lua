-- Offline test of Mounts.lua with a fake spellbook and mount collection:
-- what is known at the first read logs nothing; riding is logged by spell
-- ID in any language and not while only listed as a future spell; a mount
-- only when tied to a learn signal, once, and never a burst of them; a
-- spell ID is not taken for a mount ID.
-- Run with LuaJIT from the repo root: luajit tests/mounts_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, timers = {}, {}
local now = 1000
local ns = { char = { events = {} } }
ns.view = ns.char
ns.Journal = {
    Log = function(_, kind, ...)
        table.insert(ns.char.events, { now, kind, 0, 0, 0, ... })
    end,
}
ns.Recorder = { Position = function() return 0, 10.4, 20.6 end }
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
local function RunTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

time = function() return now end
GetTime = function() return now end
UnitLevel = function() return 40 end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
ERR_LEARN_SPELL_S = "You have learned a new spell: %s."

-- Spells the player knows, and the spellbook (which can list future spells).
local known = {}
IsPlayerSpell = function(id) return known[id] == true end
local spells = { { "Attack", 6603, 1 }, { "Heroic Strike", 78, 1 } }
Enum = { SpellBookSpellBank = { Player = 0 }, SpellBookItemType = { Spell = 1, FutureSpell = 2 } }
C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { name = "General", itemIndexOffset = 0, numSpellBookItems = #spells } end,
    GetSpellBookItemInfo = function(i) return { name = spells[i][1], spellID = spells[i][2], itemType = spells[i][3] } end,
}
local spellNames = { [824] = "Reiten: Pferd", [33388] = "Apprentice Riding" }
C_Spell = { GetSpellName = function(id) return spellNames[id] end }

-- The collection: mountID -> { name, spellID, collected }. Mount 78 shares
-- its number with Heroic Strike's spell.
local journal = {
    [6] = { "Brown Horse", 458, false },
    [9] = { "Pinto", 472, true },       -- collected before tracking (or by another character)
    [11] = { "Chestnut Mare", 6648, false },
    [12] = { "Black Stallion", 470, false },
    [78] = { "Some Mount", 9999, false },
}
C_MountJournal = {
    GetMountIDs = function()
        local ids = {}
        for id in pairs(journal) do ids[#ids + 1] = id end
        return ids
    end,
    GetMountInfoByID = function(id)
        local m = journal[id]
        if not m then return nil end
        return m[1], m[2], 132226, false, true, 0, false, false, nil, false, m[3], id
    end,
    GetMountFromSpell = function(spellID)
        for id, m in pairs(journal) do
            if m[2] == spellID then return id end
        end
    end,
}

assert(loadfile("RoadToSixty/Mounts.lua"))("RoadToSixty", ns)
local Mounts = ns.Mounts

local function Kinds()
    local list = {}
    for _, e in ipairs(ns.char.events) do
        list[#list + 1] = e[2] .. " " .. tostring(e[6]) .. " " .. tostring(e[7])
    end
    return table.concat(list, ", ")
end

-- Login: the baseline logs nothing, and notes where and when.
Fire("PLAYER_LOGIN")
RunTimers()
check(#ns.char.events == 0, "baseline logs nothing: " .. Kinds())
local pinto = ns.char.mounts and ns.char.mounts[9]
check(pinto and pinto[6] == true and pinto[3] == 10, "baseline mount noted with place and base")

-- Riding listed in the spellbook before it is learned does not count.
spells[#spells + 1] = { "Apprentice Riding", 33388, 2 }
Fire("SKILL_LINES_CHANGED")
check(#ns.char.events == 0, "future riding spell not logged: " .. Kinds())

-- Learning an ordinary spell whose ID is some mount's ID logs nothing.
now = now + 100
Fire("LEARNED_SPELL_IN_TAB", 78)
RunTimers()
check(#ns.char.events == 0, "spell 78 is not mount 78: " .. Kinds())

-- Learning racial riding, named in another language: found by spell ID.
now = now + 100
known[824] = true
Fire("CHAT_MSG_SYSTEM", "You have learned a new spell: |cff71d5ff|Hspell:824:0|h[Reiten: Pferd]|h|r.")
check(Kinds() == "ride 824 Reiten: Pferd", "riding logged by ID: " .. Kinds())
check(ns.char.events[1][8] == nil, "riding at the signal is not late")
RunTimers()
check(#ns.char.events == 1, "riding logged once: " .. Kinds())

-- A mount appearing with no signal (another character's, if shared) is only noted.
now = now + 100
journal[11][3] = true
Fire("MOUNT_JOURNAL_LIST_UPDATE")
check(#ns.char.events == 1, "mount without a signal not logged: " .. Kinds())
check(ns.char.mounts[11] and not ns.char.mounts[11].logged, "but noted")

-- Buying a horse: the chat link names it; the collection lags a moment.
now = now + 100
Fire("CHAT_MSG_SYSTEM", "You have learned a new spell: |cff71d5ff|Hspell:458:0|h[Brown Horse]|h|r.")
check(#ns.char.events == 1, "not logged before it is collected: " .. Kinds())
journal[6][3] = true
RunTimers()
check(Kinds():match("mount 6 Brown Horse$"), "named mount logged: " .. Kinds())
check(ns.char.events[#ns.char.events][9] == "n", "how = named")
Fire("NEW_MOUNT_ADDED", 6)
RunTimers()
check(select(2, Kinds():gsub("mount 6", "")) == 1, "mount logged once: " .. Kinds())

-- A learn signal while two mounts appear at once (an account's arriving
-- late): neither is logged.
now = now + 100
local count = #ns.char.events
journal[78][3], journal[12][3] = true, true
Fire("COMPANION_LEARNED")
RunTimers()
check(#ns.char.events == count, "burst not logged: " .. Kinds())

-- But the client naming one of them logs that one.
Fire("NEW_MOUNT_ADDED", 12)
check(Kinds():match("mount 12 Black Stallion$"), "named mount from a burst logged: " .. Kinds())

-- Titles, and Stats.
check((Mounts:Describe(ns.char.events[1])) == "Learned Reiten: Pferd", "ride title")
check((Mounts:Describe(ns.char.events[2])) == "New mount: Brown Horse", "mount title")
table.insert(ns.char.events, 1, { 0, "lvl", 0, 0, 0, 40 })
local learnedAt, ridingKnown, events = Mounts:Summary()
check(learnedAt == 40 and ridingKnown and #events == 3, ("summary: %s %s %d"):format(
    tostring(learnedAt), tostring(ridingKnown), #events))

-- A seeded journey is left alone.
ns.char.seeded = true
known[33388] = true
Fire("LEARNED_SPELL_IN_TAB", 33388)
check(not ns.char.riding[33388], "seeded journey not read")

if failures > 0 then
    print(("mounts_test: %d failure(s)"):format(failures))
    os.exit(1)
end
print("mounts_test: ok")
