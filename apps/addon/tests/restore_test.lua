-- Offline test of Merge.Windows and Merge.Strip: an upload made before a
-- restore reached its PC loses only the play the restore took out. Run
-- with LuaJIT from apps/addon: luajit tests/restore_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
for _, name in ipairs({ "Packed.lua", "Tally.lua", "Parse.lua", "Merge.lua" }) do
    assert(loadfile("RoadToSixty/" .. name))("RoadToSixty", ns)
end
local Merge = ns.Merge

local function Journey(fields)
    local j = {
        version = 3, segments = {}, events = {}, levels = {}, recipes = {}, people = {},
        kills = { d = "", last = 0, names = {} },
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 },
    }
    for k, v in pairs(fields or {}) do j[k] = v end
    return j
end

-- One session: on, a death, off.
local function Session(t)
    return { { t, "on", 0, 0, 0, 10 }, { t + 60, "die", 0, 0, 0 }, { t + 120, "off", 0, 0, 0 } }
end
local function Events(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, e in ipairs(list) do out[#out + 1] = e end
    end
    return out
end
local function Times(char, kind)
    local out = {}
    for _, e in ipairs(char.events) do
        if e[2] == kind then out[#out + 1] = e[1] end
    end
    return table.concat(out, ",")
end

-- 1. Windows: the old journey's sessions the kept one lacks.
local old = Journey({ events = Events(Session(1000), Session(5000), Session(9000)) })
local kept = Journey({ events = Events(Session(1000)) })
local w = Merge.Windows(old, kept)
check(#w == 2 and w[1][1] == 5000 and w[1][2] == 5120 and w[2][1] == 9000 and w[2][2] == 9120,
    "windows are the sessions only the old journey has, on to off")

local noOff = Journey({ events = { { 1000, "on", 0, 0, 0, 10 }, { 1050, "die", 0, 0, 0 }, { 2000, "on", 0, 0, 0, 10 }, { 2030, "die", 0, 0, 0 } } })
w = Merge.Windows(noOff, Journey())
check(#w == 2 and w[1][2] == 1999 and w[2][2] == 2030,
    "a session with no off ends a second before the next on, or at the last event")

-- 2. Strip: events, segments, kills and snapshots inside a window go, and
-- the totals and later snapshots come down by what went.
local function Upload()
    return Journey({
        events = Events(Session(1000), Session(5000), Session(9000)),
        segments = {
            { m = "w", c = 0, t = 1000, x = 0, y = 0, d = "10,3,4" },
            { m = "w", c = 0, t = 5000, x = 0, y = 0, d = "10,30,40" },
            { m = "w", c = 0, t = 9000, x = 0, y = 0, d = "10,6,8" },
        },
        kills = ns.Packed.PackKills({ { t = 1010, xp = 5, name = "Kobold" }, { t = 5010, xp = 7, name = "Murloc" }, { t = 9010, xp = 9, name = "Gnoll" } }),
        levels = { [3] = { t = 5050, kills = 2 }, [4] = { t = 9050, kills = 3, deaths = 3 } },
        totals = { kills = 3, killXP = 21, questXP = 0, deaths = 3, quests = 0, instances = 0, distance = 65, flown = 0 },
    })
end
local up = Merge.Strip(Upload(), { { 5000, 5120 } }, Journey({ events = Events(Session(1000)) }))
check(Times(up, "on") == "1000,9000", "the removed session's events go")
check(#up.segments == 2 and up.segments[2].t == 9000, "the removed session's path goes")
check(#up.kills.names == 2 and up.kills.names[1] ~= "Murloc" and up.kills.names[2] ~= "Murloc", "the removed session's kills go")
check(up.levels[3] == nil, "a level reached in the removed session goes")
check(up.totals.kills == 2 and up.totals.killXP == 14 and up.totals.deaths == 2 and up.totals.distance == 15,
    "the totals come down by what was removed")
check(up.levels[4].kills == 2 and up.levels[4].deaths == 2, "a later snapshot comes down too")

-- 3. Merged with the journey, the stripped upload brings its new play and
-- nothing the restore took out.
local head = Journey({
    events = Events(Session(1000)),
    segments = { { m = "w", c = 0, t = 1000, x = 0, y = 0, d = "10,3,4" } },
    kills = ns.Packed.PackKills({ { t = 1010, xp = 5, name = "Kobold" } }),
    totals = { kills = 1, killXP = 5, questXP = 0, deaths = 1, quests = 0, instances = 0, distance = 5, flown = 0 },
})
local out = Merge.Merge(head, Merge.Strip(Upload(), { { 5000, 5120 } }, head))
check(Times(out, "on") == "1000,9000", "the merge keeps the new session and not the removed one")
check(out.totals.kills == 2 and out.totals.deaths == 2, "and its totals hold no trace of the removed one")
check(Merge.Check(head, Merge.Strip(Upload(), { { 5000, 5120 } }, head), out), "the server's check passes on the stripped upload")

-- 4. A window the journey has again (the restore was undone) is skipped.
local undone = Journey({ events = Events(Session(1000), Session(5000)) })
check(Times(Merge.Strip(Upload(), { { 5000, 5120 } }, undone), "on") == "1000,5000,9000", "a session the journey has again stays")

-- 5. Tallies: a PC the journey knows can't go above the journey's count; a
-- PC it doesn't know keeps its own.
local headTallies = Journey({ events = Events(Session(1000)), people = { ["Player-1-01"] = { groups = { pcA = 2 } } } })
local copied = Journey({
    events = Events(Session(1000), Session(5000)),
    people = {
        ["Player-1-01"] = { groups = { pcA = 5, pcB = 1 } },
        ["Player-1-02"] = { groups = { pcA = 1 } },
    },
    rares = { ["Old Murk-Eye"] = { { pcA = 2, pcB = 1 } } },
})
local capped = Merge.Strip(copied, { { 5000, 5120 } }, headTallies)
check(capped.people["Player-1-01"].groups.pcA == 2 and capped.people["Player-1-01"].groups.pcB == 1,
    "a known PC's tally comes down to the journey's; an unknown PC's stays")
check(capped.people["Player-1-02"].groups == nil, "a known PC's tally the journey doesn't have goes")
check(capped.rares["Old Murk-Eye"][1].pcA == nil and capped.rares["Old Murk-Eye"][1].pcB == 1, "rares the same way")

-- 6. No windows: nothing changes.
local same = Upload()
Merge.Strip(same, {}, head)
check(Times(same, "on") == "1000,5000,9000" and same.totals.kills == 3, "no windows, nothing stripped")

if failures == 0 then
    print("Restore tests passed.")
else
    print(failures .. " restore test(s) failed.")
    os.exit(1)
end
