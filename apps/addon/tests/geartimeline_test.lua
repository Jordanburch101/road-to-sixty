-- Offline test of GearTimeline.lua. Run with LuaJIT from apps/addon:
-- luajit tests/geartimeline_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/GearTimeline.lua"))("RoadToSixty", ns)
local G = ns.GearTimeline

-- A made-up journey: levels 1 to 3 (and 60 later), starting gear, a quest
-- reward, a quick A-B-A swap, an enchant, a slot emptied, a suffix change.
local H = 3600
local journey = {
    levels = {
        [1] = { t = 1000, gear = {}, },                                 -- before #63's fix: no gear, says nothing
        [2] = { t = 1000 + H, gear = { [5] = 200, [9] = 300, [16] = 25 }, links = { [9] = "item:300", [16] = "item:25" } },
        [3] = { t = 1000 + 3 * H, gear = { [5] = 200, [9] = 310, [16] = 25 } },
        [60] = { t = 1000 + 100 * H, gear = { [5] = 201, [9] = 310 } },
    },
    events = {
        { 1000, "on", -1, 0, 0, 1 },
        { 1100, "eq", 0, 0, 0, 5, 200, "item:200", nil, { how = "start" } },
        { 1000 + H, "lvl", 0, 0, 0, 2 },
        { 1000 + H + 60, "zone", 0, 0, 0, 1429 },
        { 1000 + 2 * H, "qd", 0, 0, 0, 33, 170, 0, "Wolves Across the Border" },
        { 1000 + 2 * H + 1, "eq", 0, 0, 0, 9, 310, "item:310::::::::::::11", nil, { how = "quest", id = 33 } },
        { 1000 + 2 * H + 100, "eq", 0, 0, 0, 9, 300, "item:300" },               -- swapped back for 2 minutes
        { 1000 + 2 * H + 220, "eq", 0, 0, 0, 9, 310, "item:310::::::::::::11" },
        { 1000 + 3 * H, "lvl", 0, 0, 0, 3 },
        { 1000 + 3 * H + 10, "ench", 0, 0, 0, 310, 41, 0, 9, "Enchanter", "Player-1-0000000A" },
        { 1000 + 4 * H, "eq", 0, 0, 0, 16, 0 },                                  -- weapon taken off
        { 1000 + 5 * H, "eq", 0, 0, 0, 13, 15210, "item:15210::::::1017" },
        { 1000 + 5 * H + 30, "eq", 0, 0, 0, 13, 15210, "item:15210::::::1018" },  -- the same item, another suffix
        { 1000 + 100 * H, "lvl", 0, 0, 0, 60 },
    },
}
local finish = 1000 + 110 * H
local tl = G.Build(journey, finish)

-- 1. Levels and the axis.
check(tl.start == 1000 and tl.finish == finish, "start and finish")
check(tl.capAt == 1000 + 100 * H, "level 60 reached")
check(G.LevelAt(tl, 1000) == 1, "level 1 at the start")
check(math.abs(G.LevelAt(tl, 1000 + 2 * H) - 2.5) < 1e-9, "halfway through level 2, got " .. G.LevelAt(tl, 1000 + 2 * H))
-- Levels 4 to 59 were not recorded: they share the time from 3 to 60.
local mid = G.LevelAt(tl, 1000 + 50 * H)
check(math.abs(mid - (3 + 57 * 47 / 97)) < 1e-9, "levels not recorded share the gap, got " .. mid)
check(G.LevelAt(tl, finish) == 60, "60 from reaching it on")
check(G.ZoneAt(tl, 1000) == nil and G.ZoneAt(tl, 1000 + 2 * H) == 1429, "zone over time")
check(tl.quests[33] and tl.enchants["310:41"], "quests and enchants by key")

-- 2. A snapshot with no gear (before #63's fix) says nothing; the chest
-- comes from the eq event with its source, and the next snapshot repeats it.
local chest = tl.slots[5]
check(#chest == 2 and chest[1].id == 200 and chest[1].t == 1100, "the chest from its eq event, got " .. #chest)
check(chest[1].source and chest[1].source.how == "start", "with its source")
check(chest[2].id == 201 and chest[1].endT == chest[2].t and chest[1].next == chest[2] and chest[2].prev == chest[1], "replaced at 60, linked")

-- 3. The quick swap A, B, A, B: the middle two are noise; kept gear shows
-- the reward from the first time it was put on, with its source.
local wrist = tl.slots[9]
check(#wrist == 4, "wrist: 300, 310, 300 again, 310 again, got " .. #wrist)
check(wrist[2].brief and wrist[3].brief and not wrist[1].brief and not wrist[4].brief, "A, B, A, B: the two in the middle are noise")
local kept = tl.kept[9]
check(#kept == 2 and kept[1].id == 300 and kept[2].id == 310, "kept gear: 300 then 310, got " .. #kept)
check(kept[2].t == 1000 + 2 * H + 1 and kept[2].endT == finish, "the quest reward from when it was got to now")
check(kept[2].source and kept[2].source.how == "quest", "keeping its source")
check(wrist[2].item == "item:310::::::::::::11", "the item string from the event")

-- A quick chain of real upgrades stays; a blink in it does not.
local function Span(id, t, endT) return { id = id, t = t, endT = endT } end
local list = { Span(1, 0, 100), Span(2, 100, 400), Span(3, 400, 430), Span(4, 430, 5000) }
for k = 1, #list do list[k].prev, list[k].next = list[k - 1], list[k + 1] end
G.MarkBrief(list)
check(not list[2].brief and list[3].brief, "A, B, C, D quickly: B stays, the 30 second C is a blink")
check(#G.Kept(list) == 3, "kept: A, B, D")

-- The level 1 snapshot has no gear (#63): the level 2 snapshot's gear was
-- worn from the start; gear first seen in an event keeps its own time.
check(wrist[1].t == 1000 and wrist[1].seenAt == 1000 + H, "gear first seen later reaches back to the empty snapshot")
check(chest[1].t == 1100 and chest[1].seenAt == nil, "gear seen in an event before keeps its time")

-- 4. Worn at a time; an emptied slot is empty after it.
local worn = G.WornAt(tl, 1000 + 2 * H + 150)
check(worn[9] and worn[9].id == 310, "kept gear at the swap: the reward")
worn = G.WornAt(tl, 1000 + 2 * H + 150, true)
check(worn[9] and worn[9].id == 300, "every swap at the swap: the old bracers")
check(G.WornAt(tl, 1000 + 3 * H)[16] and G.WornAt(tl, 1000 + 3 * H)[16].id == 25, "the weapon before it was taken off")
check(G.WornAt(tl, 1000 + 4 * H + 1)[16] == nil, "nothing in the weapon slot after")
check(G.WornAt(tl, 999)[5] == nil, "nothing before the first record")
check(G.WornAt(tl, math.huge)[5].id == 201, "the last item at the end")

-- 5. A suffix change is a new item; a moment-long span before it is brief.
local trinket = tl.slots[13]
check(#trinket == 2 and trinket[1].brief and not trinket[2].brief, "the same item with another suffix replaces it")
check(G.Plain("item:310:41:::::1017") == "item:310::::::1017" and G.ItemID("item:310:41") == 310, "helpers")

-- 6. A character partway through a level (the review of #67): the level
-- being played runs to now, so gear put on since the last level up has
-- its width, and U and TimeAt undo each other.
local levelling = G.Build({
    levels = {
        [36] = { t = 1000, gear = { [1] = 500 } },
        [37] = { t = 1000 + H, gear = { [1] = 500 } },
    },
    events = { { 1000 + 2 * H, "eq", 0, 0, 0, 1, 510, "item:510" } },
}, 1000 + 4 * H)
local uDing, uHelm, uNow = G.U(levelling, 1000 + H, 2), G.U(levelling, 1000 + 2 * H, 2), G.U(levelling, 1000 + 4 * H, 2)
check(uDing == 37 and math.abs(uHelm - (37 + 1 / 3)) < 1e-9 and uNow > 37.99, "the current level has width, got "
    .. uDing .. ", " .. uHelm .. ", " .. uNow)
for _, t in ipairs({ 1000, 1000 + H / 2, 1000 + H, 1000 + 2.5 * H }) do
    local back = G.TimeAt(levelling, G.U(levelling, t, 2), 2)
    check(math.abs(back - t) < 1e-6, "TimeAt undoes U at " .. t .. ", got " .. back)
end
for _, t in ipairs({ 1000 + 2 * H, 1000 + 50 * H, 1000 + 100 * H, 1000 + 105 * H }) do
    local back = G.TimeAt(tl, G.U(tl, t, 2), 2)
    check(math.abs(back - t) < 1e-6, "TimeAt undoes U across the gap and after 60 at " .. t .. ", got " .. back)
end

-- 6b. Levels are spaced by time played: nine days logged out take no room,
-- so gear put on in the next session is not squeezed to the edge (Liairene
-- on the beta: epics from an event, nine days into level 17).
local DAY = 86400
local away = G.Build({
    levels = { [17] = { t = 1000, gear = { [1] = 500 } } },
    events = {
        { 1000, "on", 0, 0, 0, 17 },
        { 1000 + 2 * H, "off" },
        { 1000 + 9 * DAY, "on", 0, 0, 0, 17 },
        { 1000 + 9 * DAY + H, "eq", 0, 0, 0, 1, 900, "item:900" },
    },
}, 1000 + 9 * DAY + 2 * H)
check(#away.sessions == 2 and away.sessions[2][3] == 2 * H, "two sessions, two hours played before the second")
local uEpic = G.U(away, 1000 + 9 * DAY + H, 2)
check(math.abs(uEpic - 17.75) < 1e-9, "the epic three quarters into level 17 by time played, got " .. uEpic)
check(math.abs(G.U(away, 1000 + 5 * DAY, 2) - 17.5) < 1e-9, "logged out: where the first session ended")
for _, t in ipairs({ 1000 + H, 1000 + 9 * DAY + H / 2, 1000 + 9 * DAY + 1.5 * H }) do
    local back = G.TimeAt(away, G.U(away, t, 2), 2)
    check(math.abs(back - t) < 1e-6, "TimeAt undoes U in a session at " .. t .. ", got " .. back)
end
check(G.TimeAt(away, 17.5, 2) == 1000 + 2 * H, "the moment between sessions is the end of the first")
local crashed = G.Sessions({ { 100, "on" }, { 150, "qd" }, { 400, "on" }, { 450, "lvl" } }, 500)
check(#crashed == 2 and crashed[1][2] == 150 and crashed[2][1] == 400 and crashed[2][2] == 500,
    "a session with no off ends at its last event; the open one at finish")

-- 7. A two-hander empties the off hand, and a shield comes back later:
-- kept gear does not stretch the first shield over the empty time.
local twoHand = G.Build({
    levels = { [10] = { t = 1000, gear = { [17] = 700 } } },
    events = {
        { 1000 + 5 * H, "eq", 0, 0, 0, 17, 0 },
        { 1000 + 40 * H, "eq", 0, 0, 0, 17, 700, "item:700" },
    },
}, 1000 + 50 * H)
local kept = twoHand.kept[17]
check(#kept == 2 and kept[1].endT == 1000 + 5 * H and kept[1].closed, "the shield ends when the slot empties, got "
    .. #kept .. " spans")
check(G.WornAt(twoHand, 1000 + 20 * H)[17] == nil, "nothing in the off hand while empty")
check(G.WornAt(twoHand, 1000 + 45 * H)[17] == kept[2], "the shield again after")

-- 8. An empty journey builds without error and wears nothing.
local empty = G.Build({}, 5000)
check(empty.start == 5000 and empty.finish == 5000 and #empty.levels == 0, "an empty journey")
check(next(G.WornAt(empty, 5000)) == nil and G.LevelAt(empty, 5000) == 1, "nothing worn, level 1")

if failures == 0 then
    print("GearTimeline tests passed.")
else
    print(failures .. " gear timeline test(s) failed.")
    os.exit(1)
end
