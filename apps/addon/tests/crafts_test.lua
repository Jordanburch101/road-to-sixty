-- Offline test of Crafts.lua on Classic Era's APIs (#72), with a fake skill
-- list and profession windows: professions come from the lines under the
-- Professions and Secondary Skills headers (riding, weapons and languages
-- left out), nothing is read while a profession header is collapsed, and
-- the trade skill and craft windows' recipes are counted, but not a
-- hunter's pet training in the craft window. Skill points (#84) and things
-- made (#85) are logged.
-- Run with LuaJIT from the repo root: luajit tests/crafts_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, timers = {}, {}
local ns = { char = { events = {}, recipes = {} } }
ns.view = ns.char
ns.Journal = {
    Log = function(_, kind, ...)
        local e = { 0, kind, 0, 0, 0, ... }
        table.insert(ns.char.events, e)
        return e
    end,
    Amend = function() end,
}
ns.Mounts = { IsRidingName = function(name) return name:lower():find("riding", 1, true) ~= nil end }
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

local clock = 0
GetTime = function() return clock end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
TRADE_SKILLS = "Professions"
-- Era has GetProfessions as well, but it lists nothing there.
GetProfessions = function() end
GetProfessionInfo = function() end

-- The skill list: name, header, expanded, rank, max, abandonable.
local lines = {
    { "Class Skills", true, true },
    { "Defense", false, nil, 40, 50 },
    { "Professions", true, true },
    { "Tailoring", false, nil, 1, 75, true },
    { "Secondary Skills", true, true },
    { "Cooking", false, nil, 30, 75 },
    { "Horse Riding", false, nil, 75, 75 },
    { "Weapon Skills", true, true },
    { "Swords", false, nil, 40, 50 },
    { "Languages", true, true },
    { "Language: Common", false, nil, 300, 300 },
}
GetNumSkillLines = function() return #lines end
GetSkillLineInfo = function(i)
    local l = lines[i]
    return l[1], l[2], l[3], l[4] or 0, 0, 0, l[5] or 0, l[6] or false
end

-- The windows: the trade skill window's list, and the craft window's.
local trade = { { "Cloth", "header" }, { "Linen Cloak", "trivial" }, { "Brown Linen Vest", "easy" } }
GetTradeSkillLine = function() return "Tailoring", 1, 75 end
GetNumTradeSkills = function() return #trade end
GetTradeSkillInfo = function(i) return trade[i][1], trade[i][2] end
local craftSkill = "Enchanting" ---@type string?
local crafts = { { "Enchant Bracer - Minor Health", "optimal" } }
GetCraftDisplaySkillLine = function() return craftSkill, 5, 75 end
GetNumCrafts = function() return #crafts end
GetCraftInfo = function(i) return crafts[i][1], "", crafts[i][2] end

assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Items.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Crafts.lua"))("RoadToSixty", ns)
local Crafts = ns.Crafts

-- 1. Professions from the skill lines.
local skills = Crafts:ReadSkills()
check(skills and skills.Tailoring and skills.Tailoring[1] == 1 and skills.Tailoring[2] == 75, "Tailoring read")
check(skills and skills.Cooking and skills.Cooking[1] == 30, "Cooking read from Secondary Skills")
local others = {}
for name in pairs(skills or {}) do
    if name ~= "Tailoring" and name ~= "Cooking" then others[#others + 1] = name end
end
check(#others == 0, "only professions read, also got " .. table.concat(others, ", "))

-- 2. The first check logs them as baseline; a new tier logs a prof event.
Fire("PLAYER_LOGIN")
RunTimers()
check(#ns.char.events == 2 and ns.char.events[1][9] == true, "professions known at the start are baseline")
lines[4][5] = 150
Fire("SKILL_LINES_CHANGED")
local last = ns.char.events[#ns.char.events]
check(#ns.char.events == 3 and last[6] == "Tailoring" and last[8] == 150, "a new tier is logged")

-- 3. A collapsed profession header hides its lines: nothing is read, so
-- nothing is logged when they show again.
lines[3][3] = false
check(Crafts:ReadSkills() == nil, "nothing read under a collapsed profession header")
lines[3][3] = true
lines[5][3] = false
Fire("SKILL_LINES_CHANGED")
lines[5][3] = true
Fire("SKILL_LINES_CHANGED")
check(#ns.char.events == 3, "no prof events from a collapsed header, got " .. #ns.char.events)

-- 3b. Each rise in skill is a skill event (#84), with the rank it rose from;
-- weapon skills log nothing, and a check that changes nothing logs nothing.
lines[4][4] = 2
Fire("CHAT_MSG_SKILL")
last = ns.char.events[#ns.char.events]
check(#ns.char.events == 4 and last[2] == "skill" and last[6] == "Tailoring" and last[7] == 2 and last[8] == 1
    and last[9] == nil, "a skill point is logged with the rank it rose from")
lines[6][4] = 45
Fire("SKILL_LINES_CHANGED")
last = ns.char.events[#ns.char.events]
check(#ns.char.events == 5 and last[6] == "Cooking" and last[7] == 45 and last[8] == 30, "a jump of several points is one event")
lines[10][4] = 41
Fire("SKILL_LINES_CHANGED")
Fire("SKILL_LINES_CHANGED")
check(#ns.char.events == 5, "weapon skills and repeated checks log nothing, got " .. #ns.char.events)
-- A new tier and a point in one read log both.
lines[4][4], lines[4][5] = 3, 225
Fire("SKILL_LINES_CHANGED")
check(#ns.char.events == 7 and ns.char.events[6][2] == "prof" and ns.char.events[7][2] == "skill"
    and ns.char.events[7][7] == 3, "a new tier and a point in one read are both logged")
-- A rise found before the check at login settles happened while the addon was not running.
Crafts.settled = false
lines[6][4] = 50
Fire("SKILL_LINES_CHANGED")
Crafts.settled = true
last = ns.char.events[#ns.char.events]
check(#ns.char.events == 8 and last[6] == "Cooking" and last[8] == 45 and last[9] == true, "a rise found at login is late")
-- So is one the check 5 seconds after login finds, though settled by then.
lines[6][4] = 52
Crafts:CheckSkills(true)
last = ns.char.events[#ns.char.events]
check(#ns.char.events == 9 and last[7] == 52 and last[8] == 50 and last[9] == true, "a rise the login check finds is late")

-- 4. Recipes from the trade skill window, headers left out.
Fire("TRADE_SKILL_SHOW")
local tailoring = ns.char.recipes.Tailoring
check(tailoring and tailoring["Linen Cloak"] and tailoring["Brown Linen Vest"] and not tailoring.Cloth,
    "trade skill window's recipes counted, headers left out")
trade[#trade + 1] = { "White Linen Shirt", "easy" }
Fire("TRADE_SKILL_UPDATE")
RunTimers()
check(tailoring["White Linen Shirt"], "a recipe added while the window is open is counted")
Fire("TRADE_SKILL_CLOSE")

-- 5. The craft window: Enchanting counts, pet training does not.
Fire("CRAFT_SHOW")
check(ns.char.recipes.Enchanting and ns.char.recipes.Enchanting["Enchant Bracer - Minor Health"],
    "craft window's Enchanting recipes counted")
Fire("CRAFT_CLOSE")
craftSkill = nil
crafts = { { "Bite", "" } }
Fire("CRAFT_SHOW")
local count = 0
for _ in pairs(ns.char.recipes) do count = count + 1 end
check(count == 2, "pet training is not a profession, got " .. count .. " professions")

-- 6. Things made (#85): with the recipe cast just before and the profession
-- window open; Create All is one event; something made with no profession
-- (conjured food, a battleground's mark) is not logged.
local function Made(name, id, count)
    local link = ("|cffffffff|Hitem:%d::::::::20:::::|h[%s]|h|r"):format(id, name)
    Fire("CHAT_MSG_LOOT", count and ("You create: %sx%d."):format(link, count) or ("You create: %s."):format(link))
end
-- How high items stack, by item ID; gear doesn't.
local STACK = { [1251] = 20, [2996] = 10, [2568] = 1, [5349] = 20, [20558] = 100 }
C_Item = { GetItemMaxStackSizeByID = function(link) return STACK[tonumber(link:match("item:(%d+)"))] end }
local before = #ns.char.events
clock = 100
Fire("TRADE_SKILL_SHOW")
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 3275)
Made("Linen Bandage", 1251)
local made = ns.char.events[#ns.char.events]
check(#ns.char.events == before + 1 and made[2] == "craft" and made[6]:find("Linen Bandage", 1, true) and made[7] == 1
    and made[9] == "Tailoring" and made[10] == 3275, "a thing made is logged with its recipe and profession")
for _ = 1, 3 do
    clock = clock + 3
    Made("Linen Bandage", 1251)
end
check(#ns.char.events == before + 1 and made[7] == 4, "the same item made again a moment later adds to its count")
clock = clock + 3
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 2963)
Made("Linen Bolt", 2996, 2)
check(#ns.char.events == before + 2 and ns.char.events[#ns.char.events][7] == 2, "a stack made counts its size")
clock = clock + 30
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 2963)
Made("Linen Bolt", 2996, 2)
check(#ns.char.events == before + 3, "the same item made long after is a new craft")
-- Gear doesn't stack, so each piece is a craft of its own however quickly
-- it's made; a stackable item the client doesn't know yet still joins.
clock = clock + 30
for _ = 1, 3 do
    clock = clock + 3
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 2385)
    Made("Brown Linen Vest", 2568)
end
local vests = ns.char.events[#ns.char.events]
check(#ns.char.events == before + 6 and vests[7] == 1, "each piece of gear made is its own craft, got " .. (#ns.char.events - before))
clock = clock + 30
for _ = 1, 3 do
    clock = clock + 3
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 2963)
    Made("Bolt of Unknown Cloth", 99999)
end
check(#ns.char.events == before + 7 and ns.char.events[#ns.char.events][7] == 3, "an item not known yet still joins")
-- One the client learns about after the first craft is asked again: gear
-- not known at the first piece is still a craft each once it is.
clock = clock + 30
for _ = 1, 3 do
    clock = clock + 3
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 2386)
    Made("Linen Boots", 2569)
    STACK[2569] = 1     -- not known at the first pair, known after
end
check(#ns.char.events == before + 10, "gear the client learns about after the first piece is a craft each, got "
    .. (#ns.char.events - before))
before = before + 7
-- Each cast makes one thing (#142): a mark a moment after a craft, with
-- the window still open, can't take that craft's cast.
clock = clock + 1
Made("Warsong Gulch Mark of Honor", 20558)
check(#ns.char.events == before + 3, "a mark just after a craft is not a craft")
-- A Create All goes on after the window closes: the window open at the
-- first cast is the profession, and the rest join it.
clock = clock + 30
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 3275)
Fire("TRADE_SKILL_CLOSE")
Made("Linen Bandage", 1251)
for _ = 1, 2 do
    clock = clock + 3
    Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 3275)
    Made("Linen Bandage", 1251)
end
local all = ns.char.events[#ns.char.events]
check(#ns.char.events == before + 4 and all[9] == "Tailoring" and all[7] == 3,
    "a Create All whose window closed after the first cast is still one craft")
-- Not crafting (#142): conjured food is a spell of no profession, and a
-- battleground's mark comes with "You create" and no cast at all, even
-- with a profession window open.
clock = clock + 60
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 587)
Made("Conjured Muffin", 5349, 20)
check(#ns.char.events == before + 4, "conjured food with no profession window open is not a craft")
clock = clock + 60
Made("Warsong Gulch Mark of Honor", 20558)
check(#ns.char.events == before + 4, "a battleground's mark is not a craft")
Fire("TRADE_SKILL_SHOW")
clock = clock + 60
Made("Warsong Gulch Mark of Honor", 20558)
check(#ns.char.events == before + 4, "nor with a profession window open")
Fire("TRADE_SKILL_CLOSE")
Fire("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:2589::::::::20:::::|h[Linen Cloth]|h|r.")
check(#ns.char.events == before + 4, "loot is not a craft")

-- Forever: no skill lines, and GetProfessions gives its five slots by place
-- (prof1, prof2, first aid, fishing, cooking), nil for one not learned.
GetNumSkillLines, GetSkillLineInfo = nil, nil   ---@diagnostic disable-line: assign-type-mismatch
local slots = { 1, nil, nil, 4, 5 }
local PROFESSIONS = { [1] = { "Mining", 136248, 20, 75 }, [4] = { "Fishing", 136245, 1, 75 }, [5] = { "Cooking", 133971, 15, 75 } }
GetProfessions = function() return slots[1], slots[2], slots[3], slots[4], slots[5] end
GetProfessionInfo = function(index)
    local p = PROFESSIONS[index]
    return p[1], p[2], p[3], p[4]
end
local read = Crafts:ReadSkills()
check(read.Mining and read.Fishing and read.Cooking, "every slot after one not learned is read")
slots = { nil, nil, nil, nil, 5 }
read = Crafts:ReadSkills()
check(read.Cooking and next(read, next(read)) == nil, "Cooking alone is read")

-- A character from before the fix knew only Mining; Fishing and Cooking
-- show now, may have been known all along, and are logged as baseline.
slots = { 1, nil, nil, 4, 5 }
ns.char.events, ns.char.skills, ns.char.profSlots = {}, { Mining = { 20, 75 } }, nil
Crafts:CheckSkills(true)
local profs = {}
for _, e in ipairs(ns.char.events) do
    if e[2] == "prof" then profs[e[6]] = e end
end
check(profs.Fishing and profs.Fishing[9] == true and profs.Cooking and profs.Cooking[9] == true,
    "professions the old read missed are logged as baseline")
check(ns.char.profSlots == true, "the full read is remembered")
PROFESSIONS[3] = { "First Aid", 135966, 1, 75 }
slots = { 1, nil, 3, 4, 5 }
Crafts:CheckSkills()
local aid = ns.char.events[#ns.char.events]
check(aid[2] == "prof" and aid[6] == "First Aid" and aid[9] == nil, "a profession learned after that is learned")

-- Forever's crafts: the profession is the recipe's, from the cast before.
-- The lookup answers for class spells too, with their skill line (seen in
-- game: Conjure Water gave "Arcane"), so only the character's professions
-- count. Conjured water, and a battleground's mark (no cast), are not
-- crafts (#142).
local RECIPES = { [3275] = "First Aid", [5504] = "Arcane" }
C_TradeSkillUI = {
    GetBaseProfessionInfo = function() return {} end,
    GetTradeSkillLineForRecipe = function(id) return nil, RECIPES[id] end,
}
ns.char.events = {}
clock = 1000
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 3275)
Made("Linen Bandage", 1251)
made = ns.char.events[1]
check(#ns.char.events == 1 and made[9] == "First Aid" and made[10] == 3275, "Forever: a craft takes its recipe's profession")
clock = clock + 60
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 5504)
Made("Conjured Water", 2288, 20)
clock = clock + 60
Made("Warsong Gulch Mark of Honor", 20558)
check(#ns.char.events == 1, "Forever: conjured water and a battleground's mark are not crafts, got " .. #ns.char.events)
-- A profession not saved yet (a new character's first craft) is read live.
local saved = ns.char.skills
ns.char.skills = nil
clock = clock + 60
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 3275)
Made("Linen Bandage", 1251)
check(#ns.char.events == 2 and ns.char.events[2][9] == "First Aid", "Forever: a profession not saved yet is read live")
ns.char.skills = saved

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("Crafts tests passed.")
