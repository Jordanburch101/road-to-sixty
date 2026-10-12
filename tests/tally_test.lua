-- Offline test of Tally.lua: counts kept per PC add up, and layout 2
-- counts become tallies. Run with LuaJIT from the repo root:
-- luajit tests/tally_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", ns)
local Tally = ns.Tally

-- 1. The count shown is the sum of the PCs' parts. An alt's roster copy may
-- still hold a plain number from layout 2, which reads as it is.
check(Tally.Total(nil) == 0, "no tally reads as 0")
check(Tally.Total({}) == 0, "an empty tally reads as 0")
check(Tally.Total(7) == 7, "a layout 2 number reads as it is")
check(Tally.Total({ a = 2, b = 3 }) == 5, "the PCs' parts add up")

-- 2. Each PC adds to its own part.
local p = {}
Tally.Add(p, "groups", "a", 1)
Tally.Add(p, "groups", "a", 1)
Tally.Add(p, "groups", "b", 1)
check(p.groups.a == 2 and p.groups.b == 1 and Tally.Total(p.groups) == 3, "adds go to each PC's own part")
local rare = { { a = 1 }, 100, "Mor'Ladim" }
Tally.Add(rare, 1, "a", 1)
check(rare[1].a == 2 and rare[3] == "Mor'Ladim", "a rare's count is slot 1")

-- 3. Layout 2 counts become this PC's tallies; tallies already there, and
-- everything else, are left alone.
local char = {
    people = {
        g = { name = "A", groups = 3, seconds = 600, raids = 0, raidSeconds = 0, dungeons = 2, raidRuns = 1 },
        h = { name = "B", groups = { b = 4 }, seconds = 60 },
    },
    rares = { [522] = { 2, 100, "Mor'Ladim", 522, "rare" } },
}
Tally.Upgrade(char, "a")
local g, h, r = char.people.g, char.people.h, char.rares[522]
check(g.groups.a == 3 and g.seconds.a == 600 and g.dungeons.a == 2 and g.raidRuns.a == 1, "counts become this PC's")
check(g.raids == nil and Tally.Total(g.raids) == 0, "a zero count reads as 0")
check(g.name == "A", "the rest of a player is untouched")
check(h.groups.b == 4 and h.groups.a == nil and h.seconds.a == 60, "a half-converted player: numbers convert, tallies stay")
check(type(r[1]) == "table" and Tally.Total(r[1]) == 2, "a rare's count becomes a tally in its place")
check(r[2] == 100 and r[3] == "Mor'Ladim" and r[4] == 522 and r[5] == "rare", "the rest of a rare is untouched")
Tally.Upgrade(char, "b")
check(g.groups.a == 3 and g.groups.b == nil and r[1].b == nil and Tally.Total(r[1]) == 2, "upgrading again changes nothing")
check(pcall(Tally.Upgrade, {}, "a"), "a journey with no people or rares upgrades")

if failures == 0 then
    print("Tally tests passed.")
else
    print(failures .. " tally test(s) failed.")
    os.exit(1)
end
