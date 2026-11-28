-- Offline test of Battles.lua's pure part: which kills and deaths count
-- (players killed, deaths by players or their pets, none inside instances
-- or on continents the map lacks), grouping them by place on screen, and a
-- battle's summary. Run with LuaJIT from apps/addon: luajit tests/battles_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
-- (the drawing part calls the game only when the map uses it)
assert(loadfile("RoadToSixty/Battles.lua"))("RoadToSixty", ns)
local Battles = ns.Battles

-- Content units are world yards / 10 on continent 0; continent 1 is not on the map.
local toContent = { [0] = function(x, y) return x / 10, y / 10 end }
local events = {
    { 100, "zone", 0, 0, 0, 1424 },
    { 110, "hk", 0, 1000, 1000, "Gorehowl", "Scout", 50, "WARRIOR", 24 },
    { 120, "die", 0, 1010, 1000, "Zuljin", "p", "Aimed Shot" },
    { 130, "die", 0, 1020, 1000, "Defias Pillager" },              -- a creature: no
    { 140, "die", 0, 1000, 1010, "Falling", "e" },                 -- the world: no
    { 150, "die", 0, 1005, 1005, "Yshaarj", "pet" },               -- a player's pet: yes
    { 160, "hk", 0, 1000, 1000, "Gorehowl", nil, 40, "WARRIOR" },
    { 170, "in", 0, 1000, 1000, 489, "Warsong Gulch", "pvp" },
    { 180, "die", 0, 1000, 1000, "Thrall", "p" },                  -- inside: no
    { 190, "out", 0, 1000, 1000, 489 },
    { 200, "zone", 0, 0, 0, 1434 },
    { 210, "hk", 0, 5000, 5000, "Rexxar", nil, 12, "HUNTER" },
    { 220, "hk", 1, 1000, 1000, "Cairne", nil, 10 },               -- a continent the map lacks: no
    { 230, "die", 0, 1000, 1000, "Hollow Grimtusk", "p", "Dynamite Backfire" },  -- the player's own blow: no
    { 240, "die", 0, 1000, 1000, "Hollow Grimtusk", "self", "Dynamite Backfire" }, -- no
}
local entries = Battles.Collect(events, toContent, { ["Hollow Grimtusk"] = true })
check(#entries == 5, "kills and deaths by players outside instances: " .. #entries)
check(entries[1].kill and entries[1].x == 100 and entries[1].wx == 1000 and entries[1].honor == 50
    and entries[1].zone == 1424 and entries[1].class == "WARRIOR", "a kill, placed, with its zone")
check(entries[2].death and entries[2].name == "Zuljin" and entries[2].honor == 0, "a death by a player")
check(entries[3].death and entries[3].name == "Yshaarj", "a death by a player's pet")
check(entries[5].name == "Rexxar" and entries[5].zone == 1434, "the zone is the one last entered")

-- On screen at one content unit a pixel: the first four within a few pixels,
-- the last far off.
local function place(entry) return entry.x, entry.y end
local battles = Battles.Group(entries, place, 44)
check(#battles == 2, "two places, two battles: " .. #battles)
local b = battles[1]
check(b.kills == 2 and b.deaths == 2 and b.honor == 90 and b.first == 110 and b.last == 160 and #b.entries == 4,
    ("the first battle: %d kills, %d deaths, %d honor"):format(b.kills, b.deaths, b.honor))
check(math.abs(b.x - 100.375) < 0.01 and math.abs(b.y - 100.125) < 0.01, "its middle is the mean of its places")
check(battles[2].kills == 1 and battles[2].deaths == 0, "the second battle")

-- Zoomed out, everything joins one battle; zoomed in far, the first place splits.
battles = Battles.Group(entries, function(e) return e.x / 100, e.y / 100 end, 44)
check(#battles == 1 and battles[1].kills == 3 and battles[1].deaths == 2, "zoomed out, one battle")
-- (a hundred pixels a content unit: the two kills on one spot stay one, the deaths 7 and 10 yards off split)
battles = Battles.Group(entries, function(e) return e.x * 100, e.y * 100 end, 44)
check(#battles == 4 and battles[1].kills == 2 and battles[1].deaths == 0, "zoomed in, the first place splits: " .. #battles)

-- Entries place leaves out (the replay's time, the filters) count nowhere.
battles = Battles.Group(entries, function(e) if e.kill then return e.x, e.y end end, 44)
check(#battles == 2 and battles[1].kills == 2 and battles[1].deaths == 0, "deaths left out")
check(#Battles.Group({}, place, 44) == 0, "nothing to group")

-- Left a dungeon, its "out" not logged yet (Journal.lua waits for a run back
-- in): a fight at its door counts. Inside a battleground nothing does.
local door = Battles.Collect({
    { 100, "in", 0, 1000, 1000, 36, "The Deadmines", "party" },
    { 110, "die", 0, 1000, 1000, "Gorehowl", "p" },
    { 120, "in", 0, 1000, 1000, 489, "Warsong Gulch", "pvp" },
    { 130, "die", 0, 1000, 1000, "Thrall", "p" },
}, toContent)
check(#door == 1 and door[1].name == "Gorehowl", "a fight at a dungeon's door counts, one in a battleground not")

-- A battle whose middle has moved as it grew still takes what is near its
-- middle now, however far that is from where it began.
-- (each 40 pixels past the middle so far, so its middle creeps several radii from where it began)
local drift, sum = {}, 0
for i = 1, 30 do
    local x = i == 1 and 0 or sum / (i - 1) + 40
    drift[i], sum = { t = i, x = x, y = 0, kill = true, honor = 0 }, sum + x
end
local grown = Battles.Group(drift, place, 44)
check(#grown == 1 and grown[1].x > 88, "a battle whose middle moved is still found: " .. #grown)

-- The summary: the zone most of it was in, who was killed most, who killed most.
battles = Battles.Group(entries, place, 44)
local s = Battles.Summary(battles[1])
check(s.zone == 1424, "the zone of the battle")
check(s.victim and s.victim.name == "Gorehowl" and s.victim.count == 2 and s.victim.class == "WARRIOR", "killed most")
check(s.killer and s.killer.count == 1 and s.killer.name == "Zuljin", "killed by most; ties go to the first")

if failures > 0 then
    print(failures .. " battle test(s) failed.")
    os.exit(1)
end
print("Battles tests passed.")
