-- Offline test of Crafts.lua on Classic Era's APIs (#72), with a fake skill
-- list and profession windows: professions come from the lines under the
-- Professions and Secondary Skills headers (riding, weapons and languages
-- left out), nothing is read while a profession header is collapsed, and
-- the trade skill and craft windows' recipes are counted, but not a
-- hunter's pet training in the craft window.
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
function ns.ChatMatcher() return function() end end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end
local function RunTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

GetTime = function() return 0 end
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

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("Crafts tests passed.")
