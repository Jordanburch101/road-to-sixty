-- Offline test of ChatPatterns.lua: English formats, German ones with
-- numbered arguments, arguments in another order, magic characters and
-- whole-message matching. Run with LuaJIT from the repo root:
-- luajit tests/chatpatterns_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)

local function same(format, msg, ...)
    local want = { ... }
    local got = { ns.ChatMatcher(format)(msg) }
    for i = 1, math.max(#want, #got) do
        if want[i] ~= got[i] then
            return false
        end
    end
    return true
end

-- English kill and loot.
check(same("%s dies, you gain %d experience.", "Kobold Miner dies, you gain 45 experience.",
    "Kobold Miner", "45"), "English kill")
check(same("You receive loot: %sx%d.", "You receive loot: [Linen Cloth]x3.", "[Linen Cloth]", "3"),
    "English stacked loot")
check(same("You receive loot: %s.", "You receive loot: [Linen Cloth].", "[Linen Cloth]"), "English loot")
check(same("You receive loot: %s.", "Something else.") , "English loot mismatch")

-- German numbers its arguments; the plain gsub version raised
-- "invalid capture index" here.
check(same("%1$s stirbt, Ihr bekommt %2$d Erfahrung.", "Koboldminenarbeiter stirbt, Ihr bekommt 45 Erfahrung.",
    "Koboldminenarbeiter", "45"), "German kill")

-- Arguments in another order come back in argument order.
check(same("Ihr seid jetzt bei %2$s %1$s.", "Ihr seid jetzt bei Sturmwind wohlwollend.",
    "wohlwollend", "Sturmwind"), "reordered arguments")

-- An argument left out comes back nil, in its place.
check(same("Ruf bei %2$s.", "Ruf bei Sturmwind.", nil, "Sturmwind"), "skipped argument")
local first, second = ns.ChatMatcher("Ruf bei %2$s.")("Ruf bei Sturmwind.")
check(first == nil and second == "Sturmwind", "skipped argument keeps its place")

-- Other conversions capture too, numbered or not; a width is not a position.
check(same("%2$i Erfahrung von %1$s.", "45 Erfahrung von Wolf.", "Wolf", "45"), "numbered %i")
check(same("%5d items, %.1f%% done", "12 items, 40.5% done", "12", "40.5"),"width and precision")
check(same("Gained %.1f yards", "Gained 12.5 yards", "12.5"), "%f")

-- An argument used twice comes from its first place.
check(same("%1$s und %1$s", "a und b", "a"), "repeated argument")

-- A literal percent sign before s or d is not a conversion.
check(same("50%%s mehr: %s", "50%s mehr: x", "x"), "literal percent before s")

-- Magic characters in the format are literal.
check(same("(%s) +%d%%? [x]", "(Gold) +5%? [x]", "Gold", "5"), "magic characters")

-- Whole matching, and formats with no arguments.
local whole = ns.ChatMatcher("You have learned a new spell: %s.", true)
check(whole("You have learned a new spell: Riding.") == "Riding", "whole match")
check(whole("You have learned a new spell: Riding. Extra") == nil, "whole match anchored at end")
check(whole("Oh. You have learned a new spell: Riding.") == nil, "whole match anchored at start")
local kicked = ns.ChatMatcher("You have been kicked out of the guild.", true)
check(kicked("You have been kicked out of the guild.") == true, "no arguments")
check(kicked("You have been kicked out of the guild. Again.") == nil, "no arguments, whole")

-- A missing global string never matches.
check(ns.ChatMatcher(nil)("anything") == nil, "missing format")

if failures > 0 then
    print(failures .. " chat pattern check(s) failed.")
    os.exit(1)
end
print("Chat pattern tests passed.")
