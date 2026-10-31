local _, ns = ...

-- The numbers the Stats screen shows (issue #83), for any stretch of a
-- journey: the map's date range, up to the replay's moment. No game calls,
-- so it is tested offline (tests/stats_test.lua).
--
--   Stats.Index(journey, now, money) -> index
--     Running totals over the whole journey, built once and kept while the
--     journey does not change (Stats.Changed says when it has): kills and
--     their XP (packed kills), quests turned in with their XP and money
--     ("qd"), deaths ("die"), dungeon and raid runs ("in", raids counted
--     apart too) and battlegrounds and arenas apart from them, yards walked
--     and flown (the path segments, counted as the recorder counts them:
--     flight paths are flown, the rest walked), the play sessions ("on" and
--     "off"), level ups (the level snapshots), zones entered ("zone"), epics
--     looted ("loot") and gold held (each snapshot's, each login's and
--     logout's from #86, then money, the gold held now, when given). now is the journey's end: ns.Now() for the
--     character playing, its last event for another's copy.
--   Stats.Window(index, from, to) -> totals
--     What happened from time from to time to (Unix seconds; nil for the
--     journey's start and end), each a binary search, so the replay can ask
--     every frame: { from, to, played (seconds logged in), kills, killXP,
--     quests, questXP, questMoney, deaths, dungeons (raids among them),
--     raids, battlegrounds, walked, flown, gold (change in gold held; nil
--     before the first snapshot or login with it), levelFrom,
--     levelTo (level at from and at to), zones = { { uiMapID, seconds
--     played, entry, levels }, ... } most first, entry the first "zone"
--     event in the window for it (or the one before it): { t, c, x, y },
--     levels the seconds played there at each level: level -> seconds }.
--   Stats.LevelAt(index, t) -> level, fraction
--     The level at t, and how far through it by time played (0 to 1).
--   Stats.ZoneAt(index, t) -> uiMapID of the zone at t, or nil
--   Stats.Weeks(index, capAt) -> { { week, from, to }, ... }
--     The weeks from capAt (when the level cap was reached) to the journey's
--     end, for the endgame: week 1 starts at capAt.
--   Stats.Records(index, from, to, rows, timeline, capAt) -> records
--     The bests and worsts inside the window, each nil when nothing in it
--     makes one, and each with t (when) and, when known, c, x, y (where):
--       slowest, bestRate   { level, seconds or perHour }: levels 10 and
--                     up begun and finished inside it (rows from Stats.Levels,
--                     their time played)
--       bestSession   { xp, seconds, from, to }: the most XP from kills and
--                     quests in one session (the part inside the window)
--       deadliest     { level, deaths }
--       nemesis       { name, count }: the killer named most (#81)
--       mostKilled    { name, count }: no place, kills keep none
--       longestSession { seconds }
--       longestWorn   { slot, id, item, seconds }: the kept gear from
--                     GearTimeline (timeline, when given), shirt and tabard
--                     left out, by time played worn inside the window
--       richest       { level, money }: the most gold held at a level up
--       deathless     { seconds, from, to, ongoing }: the most time played
--                     between deaths (or the window's ends)
--       favouriteDungeon, favouriteRaid { name, count, first, last }: the
--                     5-man dungeon and the raid entered most, by name
--       firstEpic     { link }: the first epic looted
--       deadliestRaid { name, deaths }: the raid run with the most deaths,
--                     from its summary ("out"), placed where it was left
--       busiestWeek, mostRaidsWeek  { week, seconds or count, from }: with
--                     capAt, the week since it with the most time played, and
--                     with the most raids
--       mostGathered  { item, count }: the resource gathered most (#78)
--   Stats.Life(index, from, to) -> life
--     The character at the window's end, and what changed inside it:
--       professions   { { name, rank, max, gained }, ... } highest first:
--                     from the level snapshots, "prof" and "skill" events
--                     (#84) and the professions last seen at the end
--       reputation    { { id, name, standing, reached }, ... } highest
--                     first: the last "rep" change by then; a faction with
--                     none yet stands one below its first change after (one
--                     above for a drop), or as last seen; reached when a
--                     change up came inside the window
--       guild         the guild's name by then ("gj", "gl"), or nil
--   Stats.Levels(journey, current, now) -> rows
--     One row per level with a snapshot, its numbers the change from
--     reaching it to reaching the next; the level now (current, with now's
--     totals: { played, money }) runs to now: { level, t, c, x, y, partial,
--     current, time, kills, deaths, quests, xp, killXP, questXP, dungeons,
--     walked, flown, gold }; t is when it was reached, c, x, y where (its
--     "lvl" event's place). Fields a snapshot lacks are nil.

local Stats = {}
ns.Stats = Stats

-- Running totals ----------------------------------------------------------------

-- A series of timed entries with running sums: s.t[i] is the ith time in
-- order, s[key][i] the sum of key over entries 1 to i.
local function Series(keys)
    local s = { t = {}, keys = keys }
    for _, key in ipairs(keys) do s[key] = {} end
    return s
end

-- Entries as { t, key = value, ... }, sorted by time (kills can step back a
-- second, Packed.lua), summed into a series.
local function Build(keys, entries)
    table.sort(entries, function(a, b) return a.t < b.t end)
    local s = Series(keys)
    s.entries = entries     -- in the same order, with whatever else they hold
    for i, entry in ipairs(entries) do
        s.t[i] = entry.t
        for _, key in ipairs(keys) do
            s[key][i] = (s[key][i - 1] or 0) + (entry[key] or 0)
        end
    end
    return s
end

-- How many entries come before time t (at or before it when inclusive).
local function Count(s, t, inclusive)
    local times = s.t
    local lo, hi = 0, #times
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local at = times[mid]
        if at < t or (inclusive and at == t) then lo = mid else hi = mid - 1 end
    end
    return lo
end

-- The sum of key over entries from time from to time to, both included.
local function Between(s, key, from, to)
    local a, b = Count(s, from, false), Count(s, to, true)
    if b <= a then return 0 end
    return s[key][b] - (a > 0 and s[key][a] or 0)
end

-- The path's steps: yards walked or flown, at the time each step ended.
-- Teleports and loading screens start a new segment, so no step crosses
-- one. A journey has a hundred thousand steps, nearly always in time order,
-- so they go straight into the series; only steps out of order (a clock
-- put right, #35) take the slower way through Build.
local function Path(segments)
    local s = Series({ "walked", "flown" })
    local times, walked, flown = s.t, s.walked, s.flown
    local decode, sqrt = ns.Packed.DecodePath, math.sqrt
    local n, w, f, last = 0, 0, 0, -math.huge
    for _, seg in ipairs(segments or {}) do
        if seg.t and seg.x and seg.y then
            local ts, xs, ys = decode(seg)
            local fly = seg.m == "t"
            for i = 2, #ts do
                if ts[i] < last then
                    local entries = {}
                    for _, again in ipairs(segments) do
                        if again.t and again.x and again.y then
                            local ats, axs, ays = decode(again)
                            local key = again.m == "t" and "flown" or "walked"
                            for k = 2, #ats do
                                local dx, dy = axs[k] - axs[k - 1], ays[k] - ays[k - 1]
                                entries[#entries + 1] = { t = ats[k], [key] = sqrt(dx * dx + dy * dy) }
                            end
                        end
                    end
                    return Build({ "walked", "flown" }, entries)
                end
                local dx, dy = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
                local d = sqrt(dx * dx + dy * dy)
                if fly then f = f + d else w = w + d end
                n, last = n + 1, ts[i]
                times[n], walked[n], flown[n] = last, w, f
            end
        end
    end
    return s
end

local function Kills(kills)
    local list, entries = {}, {}
    if kills and kills.d then
        ns.Packed.DecodeKills(kills.d, kills.names or {}, 0, list)
    end
    for i, k in ipairs(list) do
        entries[i] = { t = k.t, kills = 1, killXP = k.xp, name = k.name }
    end
    return entries
end

local PVP = { pvp = true, arena = true }
local WEEK = 7 * 86400

function Stats.Index(journey, now, money)
    local quests, deaths, runs, zones, gathers, places, purses, epics, raidsLeft = {}, {}, {}, {}, {}, {}, {}, {}, {}
    local skills, reps, guilds = {}, {}, {}
    local first, last
    for _, e in ipairs(journey.events or {}) do
        local t, kind = e[1], e[2]
        first, last = first or t, t
        if kind == "qd" then
            quests[#quests + 1] = { t = t, quests = 1, questXP = e[7], questMoney = e[8] }
        elseif kind == "die" then
            deaths[#deaths + 1] = { t = t, deaths = 1, killer = e[6], c = e[3], x = e[4], y = e[5] }
        elseif kind == "in" then
            local pvp = PVP[e[8]]
            runs[#runs + 1] = { t = t, [pvp and "battlegrounds" or "dungeons"] = 1, raids = e[8] == "raid" and 1 or nil,
                name = not pvp and e[7] or nil, raid = e[8] == "raid", c = e[3], x = e[4], y = e[5] }
        elseif kind == "zone" then
            zones[#zones + 1] = { t = t, id = e[6], c = e[3], x = e[4], y = e[5] }
        elseif (kind == "prof" or kind == "skill") and e[6] then
            local list = skills[e[6]] or {}
            list[#list + 1] = { t = t, rank = e[7], max = kind == "prof" and e[8] or nil }
            skills[e[6]] = list
        elseif kind == "rep" and e[6] then
            local list = reps[e[6]] or { name = e[8] }
            list[#list + 1] = { t = t, standing = e[7], up = e[9] }
            list.name = e[8] or list.name
            reps[e[6]] = list
        elseif kind == "gj" or kind == "gl" then
            guilds[#guilds + 1] = { t = t, name = kind == "gj" and e[6] or nil }
        elseif kind == "gath" then
            gathers[#gathers + 1] = { t = t, item = e[7], c = e[3], x = e[4], y = e[5] }
        elseif kind == "lvl" and e[6] then
            places[e[6]] = e
        elseif kind == "out" and type(e[7]) == "table" and e[7].type == "raid" then
            raidsLeft[#raidsLeft + 1] = { t = t, name = e[7].name, deaths = e[7].deaths or 0, c = e[3], x = e[4], y = e[5] }
        elseif kind == "loot" and e[7] == 4 then
            epics[#epics + 1] = { t = t, link = e[6], c = e[3], x = e[4], y = e[5] }
        end
        -- The gold held at each login and logout (#86).
        local purse = kind == "on" and e[7] or kind == "off" and e[6] or nil
        if type(purse) == "number" then purses[#purses + 1] = { t = t, money = purse, c = e[3], x = e[4], y = e[5] } end
    end
    now = now or last or 0

    -- Level ups and gold held, from the snapshots in time order.
    local levels, gold = {}, {}
    for level, s in pairs(journey.levels or {}) do
        if s.t then
            local place = places[level]
            local c, x, y = place and place[3], place and place[4], place and place[5]
            levels[#levels + 1] = { t = s.t, level = level, c = c, x = x, y = y }
            for name, rank in pairs(s.skills or {}) do
                local list = skills[name] or {}
                list[#list + 1] = { t = s.t, rank = rank[1], max = rank[2] }
                skills[name] = list
            end
            if s.money then gold[#gold + 1] = { t = s.t, money = s.money, level = level, c = c, x = x, y = y } end
        end
    end
    table.sort(levels, function(a, b) return a.t < b.t end)
    for _, purse in ipairs(purses) do gold[#gold + 1] = purse end
    table.sort(gold, function(a, b) return a.t < b.t end)
    table.sort(epics, function(a, b) return a.t < b.t end)
    if money then gold[#gold + 1] = { t = now, money = money } end
    table.sort(zones, function(a, b) return a.t < b.t end)
    table.sort(gathers, function(a, b) return a.t < b.t end)
    -- The professions last seen count at the journey's end.
    for name, rank in pairs(journey.skills or {}) do
        local list = skills[name] or {}
        list[#list + 1] = { t = now, rank = rank[1], max = rank[2] }
        skills[name] = list
    end
    for _, list in pairs(skills) do table.sort(list, function(a, b) return a.t < b.t end) end
    for _, list in pairs(reps) do table.sort(list, function(a, b) return a.t < b.t end) end
    table.sort(guilds, function(a, b) return a.t < b.t end)

    local index = {
        start = first or now, finish = now, levels = levels, gold = gold, zones = zones, gathers = gathers, epics = epics,
        raidsLeft = raidsLeft,
        skills = skills, reps = reps, repsNow = journey.reps or {}, guilds = guilds,
        sessions = ns.GearTimeline.Sessions(journey.events or {}, now),
        kills = Build({ "kills", "killXP" }, Kills(journey.kills)),
        quests = Build({ "quests", "questXP", "questMoney" }, quests),
        deaths = Build({ "deaths" }, deaths),
        runs = Build({ "dungeons", "raids", "battlegrounds" }, runs),
        path = Path(journey.segments),
    }
    local firsts = { levels[1] and levels[1].t or nil, index.kills.t[1], index.path.t[1] }
    for k = 1, 3 do
        if firsts[k] and firsts[k] < index.start then index.start = firsts[k] end
    end
    index.key = Stats.Key(journey)
    return index
end

-- What the index was built from, to tell when a journey has changed: the
-- events and segments only grow, and the kills' packed string with them.
function Stats.Key(journey)
    local segments = journey.segments or {}
    local open = segments[#segments]
    return ("%d|%d|%d|%d"):format(#(journey.events or {}), #segments, open and #(open.d or "") or 0,
        #(journey.kills and journey.kills.d or ""))
end

function Stats.Changed(index, journey)
    return not index or index.key ~= Stats.Key(journey)
end

-- Windows -------------------------------------------------------------------------

local function Played(index, t)
    return ns.GearTimeline.Played(index.sessions, t)
end

-- The entry of a time-ordered list at or before t, or nil.
local function At(list, t)
    local lo, hi = 0, #list
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if list[mid].t <= t then lo = mid else hi = mid - 1 end
    end
    return list[lo], lo
end

function Stats.ZoneAt(index, t)
    local entry = At(index.zones, t)
    return entry and entry.id
end

function Stats.LevelAt(index, t)
    local entry, i = At(index.levels, t)
    if not entry then
        local firstLevel = index.levels[1]
        return firstLevel and firstLevel.level, 0
    end
    local nextEntry = index.levels[i + 1]
    local stop = nextEntry and nextEntry.t or index.finish
    local span = Played(index, stop) - Played(index, entry.t)
    local fraction = span > 0 and (Played(index, math.min(t, stop)) - Played(index, entry.t)) / span or 0
    return entry.level, math.max(0, math.min(1, fraction))
end

-- Calls add(level, seconds played) for each level's part of a to b, split
-- at the level ups between them.
local function ByLevel(index, a, b, add)
    local levels = index.levels
    local entry, i = At(levels, a)
    local level = entry and entry.level or (levels[1] and levels[1].level)
    if not level then return end
    local t = a
    i = i + 1
    while levels[i] and levels[i].t < b do
        add(level, Played(index, levels[i].t) - Played(index, t))
        t, level = levels[i].t, levels[i].level
        i = i + 1
    end
    add(level, Played(index, b) - Played(index, t))
end

-- Seconds played in each zone between from and to, and at each level
-- there: each zone entry lasts until the next.
local function Zones(index, from, to)
    local seconds, byLevel, list = {}, {}, index.zones
    local _, i = At(list, from)
    i = math.max(i, 1)
    local entries = {}
    while list[i] and list[i].t <= to do
        local a = math.max(list[i].t, from)
        local b = math.min(list[i + 1] and list[i + 1].t or index.finish, to)
        if b > a then
            local id = list[i].id
            seconds[id] = (seconds[id] or 0) + Played(index, b) - Played(index, a)
            entries[id] = entries[id] or list[i]
            local levels = byLevel[id] or {}
            byLevel[id] = levels
            ByLevel(index, a, b, function(level, s) levels[level] = (levels[level] or 0) + s end)
        end
        i = i + 1
    end
    local out = {}
    for id, s in pairs(seconds) do
        if s > 0 then out[#out + 1] = { id, s, entries[id], byLevel[id] } end
    end
    table.sort(out, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    return out
end

function Stats.Window(index, from, to)
    from = math.max(from or index.start, index.start)
    to = math.max(from, math.min(to or index.finish, index.finish))
    local w = { from = from, to = to }
    w.played = Played(index, to) - Played(index, from)
    for _, part in ipairs({ { index.kills, { "kills", "killXP" } }, { index.quests, { "quests", "questXP", "questMoney" } },
        { index.deaths, { "deaths" } }, { index.runs, { "dungeons", "raids", "battlegrounds" } }, { index.path, { "walked", "flown" } } }) do
        for _, key in ipairs(part[2]) do
            w[key] = Between(part[1], key, from, to)
        end
    end
    local after = At(index.gold, to)
    if after then
        -- Before the first snapshot nothing is known, so the first one counts as the start.
        w.gold = after.money - (At(index.gold, from) or index.gold[1]).money
    end
    w.levelFrom = Stats.LevelAt(index, from)
    w.levelTo = Stats.LevelAt(index, to)
    -- The zones cost the most, and most windows (a card's, a week's) never
    -- read them, so they are worked out when first read.
    return setmetatable(w, { __index = function(_, key)
        if key ~= "zones" then return nil end
        local zones = Zones(index, from, to)
        rawset(w, "zones", zones)
        return zones
    end })
end

-- Records -------------------------------------------------------------------------

local function Bounds(index, from, to)
    from = math.max(from or index.start, index.start)
    return from, math.max(from, math.min(to or index.finish, index.finish))
end

-- The first and last entry of a series from time from to time to, both included.
local function Inside(s, from, to)
    return Count(s, from, false) + 1, Count(s, to, true)
end

-- The tally counted most; ties go to the one reached first.
local function Most(counts)
    local best
    for _, c in pairs(counts) do
        if not best or c.count > best.count or (c.count == best.count and c.first < best.first) then best = c end
    end
    return best
end

local function Place(record, entry)
    record.t, record.c, record.x, record.y = entry.t, entry.c, entry.x, entry.y
    return record
end

-- Levels 10 and up whose whole time lies inside the window.
local function LevelRecords(out, rows, from, to)
    local byLevel = {}
    for _, row in ipairs(rows or {}) do byLevel[row.level] = row end
    for _, row in ipairs(rows or {}) do
        local nextRow = byLevel[row.level + 1]
        if row.level >= 10 and row.t and nextRow and nextRow.t and row.t >= from and nextRow.t <= to
            and row.time and row.time > 0 and not row.partial then
            local perHour = row.xp and row.xp / row.time * 3600
            if not out.slowest or row.time > out.slowest.seconds then
                out.slowest = Place({ level = row.level, seconds = row.time }, row)
            end
            if perHour and (not out.bestRate or perHour > out.bestRate.perHour) then
                out.bestRate = Place({ level = row.level, perHour = perHour }, row)
            end
        end
    end
end

local function Worn(index, timeline, from, to)
    local best
    for slot, spans in pairs(timeline and timeline.kept or {}) do
        if slot ~= 4 and slot ~= 19 then
            for _, span in ipairs(spans) do
                local a, b = math.max(span.t, from), math.min(span.endT or to, to)
                if span.id and span.id ~= 0 and b > a then
                    local seconds = Played(index, b) - Played(index, a)
                    if not best or seconds > best.seconds then
                        best = { slot = slot, id = span.id, item = span.item, seconds = seconds, t = span.t }
                    end
                end
            end
        end
    end
    return best
end

-- Weeks start the second after the cap, as the endgame does (Range.lua).
function Stats.Weeks(index, capAt)
    local weeks = {}
    if not capAt then return weeks end
    local start, week = capAt + 1, 0
    while start + week * WEEK <= index.finish do
        weeks[#weeks + 1] = { week = week + 1, from = start + week * WEEK, to = start + (week + 1) * WEEK - 1 }
        week = week + 1
    end
    return weeks
end

function Stats.Records(index, from, to, rows, timeline, capAt)
    from, to = Bounds(index, from, to)
    local out = {}
    LevelRecords(out, rows, from, to)

    -- Deaths: by level, by killer, and the time played between them.
    local a, b = Inside(index.deaths, from, to)
    local byLevel, byKiller = {}, {}
    local marks = { from }
    for i = a, b do
        local d = index.deaths.entries[i]
        marks[#marks + 1] = d.t
        local level = Stats.LevelAt(index, d.t)
        if level then
            local l = byLevel[level] or { level = level, count = 0, first = d.t, entry = d }
            l.count = l.count + 1
            byLevel[level] = l
        end
        if d.killer then
            local k = byKiller[d.killer] or { name = d.killer, count = 0, first = d.t }
            k.count, k.entry = k.count + 1, d
            byKiller[d.killer] = k
        end
    end
    local l = Most(byLevel)
    if l then out.deadliest = Place({ level = l.level, deaths = l.count }, l.entry) end
    local k = Most(byKiller)
    if k then out.nemesis = Place({ name = k.name, count = k.count }, k.entry) end
    marks[#marks + 1] = to
    for i = 2, #marks do
        local seconds = Played(index, marks[i]) - Played(index, marks[i - 1])
        if seconds > 0 and (not out.deathless or seconds > out.deathless.seconds) then
            out.deathless = { seconds = seconds, from = marks[i - 1], to = marks[i], ongoing = i == #marks or nil,
                t = marks[i - 1] }
        end
    end

    a, b = Inside(index.kills, from, to)
    local byName = {}
    for i = a, b do
        local kill = index.kills.entries[i]
        if kill.name and kill.name ~= "?" then
            local n = byName[kill.name] or { name = kill.name, count = 0, first = kill.t }
            n.count, n.last = n.count + 1, kill.t
            byName[kill.name] = n
        end
    end
    local n = Most(byName)
    if n then out.mostKilled = { name = n.name, count = n.count, t = n.last } end

    for _, s in ipairs(index.sessions) do
        local sa, sb = math.max(s[1], from), math.min(s[2], to)
        if sb - sa > 0 then
            if not out.longestSession or sb - sa > out.longestSession.seconds then
                out.longestSession = { seconds = sb - sa, t = sa }
            end
            local xp = Between(index.kills, "killXP", sa, sb) + Between(index.quests, "questXP", sa, sb)
            if xp > 0 and (not out.bestSession or xp > out.bestSession.xp) then
                out.bestSession = { xp = xp, seconds = sb - sa, from = sa, to = sb, t = sa }
            end
        end
    end

    out.longestWorn = Worn(index, timeline, from, to)

    for _, g in ipairs(index.gold) do
        if g.t >= from and g.t <= to and (not out.richest or g.money > out.richest.money) then
            out.richest = Place({ level = g.level or Stats.LevelAt(index, g.t), money = g.money }, g)
        end
    end

    a, b = Inside(index.runs, from, to)
    local byDungeon, byRaid = {}, {}
    for i = a, b do
        local run = index.runs.entries[i]
        if run.name then
            local tally = run.raid and byRaid or byDungeon
            local d = tally[run.name] or { name = run.name, count = 0, first = run.t, entry = run }
            d.count, d.last = d.count + 1, run.t
            tally[run.name] = d
        end
    end
    local d = Most(byDungeon)
    if d then out.favouriteDungeon = Place({ name = d.name, count = d.count, first = d.first, last = d.last }, d.entry) end
    d = Most(byRaid)
    if d then out.favouriteRaid = Place({ name = d.name, count = d.count, first = d.first, last = d.last }, d.entry) end

    for _, run in ipairs(index.raidsLeft) do
        if run.t >= from and run.t <= to and run.deaths > 0
            and (not out.deadliestRaid or run.deaths > out.deadliestRaid.deaths) then
            out.deadliestRaid = Place({ name = run.name, deaths = run.deaths }, run)
        end
    end

    for _, epic in ipairs(index.epics) do
        if epic.t >= from and epic.t <= to then
            out.firstEpic = Place({ link = epic.link }, epic)
            break
        end
    end

    -- At the cap, by week: the one played most, and the one with the most raids.
    for _, week in ipairs(Stats.Weeks(index, capAt)) do
        local wa, wb = math.max(week.from, from), math.min(week.to, to)
        if wb >= wa then
            local w = Stats.Window(index, wa, wb)
            if w.played > 0 and (not out.busiestWeek or w.played > out.busiestWeek.seconds) then
                out.busiestWeek = { week = week.week, seconds = w.played, from = week.from, t = wa }
            end
            if w.raids > 0 and (not out.mostRaidsWeek or w.raids > out.mostRaidsWeek.count) then
                out.mostRaidsWeek = { week = week.week, count = w.raids, from = week.from, t = wa }
            end
        end
    end

    local byItem = {}
    for _, g in ipairs(index.gathers) do
        if g.item and g.t >= from and g.t <= to then
            local item = byItem[g.item] or { item = g.item, count = 0, first = g.t }
            item.count, item.entry = item.count + 1, g
            byItem[g.item] = item
        end
    end
    local gathered = Most(byItem)
    if gathered then out.mostGathered = Place({ item = gathered.item, count = gathered.count }, gathered.entry) end
    return out
end

-- Life ------------------------------------------------------------------------------

-- The last entry of a time-ordered list at or before t, and its position.
local function Last(list, t)
    local found, at
    for i, entry in ipairs(list) do
        if entry.t > t then break end
        found, at = entry, i
    end
    return found, at
end

-- A profession's rank and cap at t; points carry the cap they were given
-- last, as "skill" events have none.
local function SkillAt(list, t)
    local rank, max
    for _, p in ipairs(list) do
        if p.t > t then break end
        rank, max = p.rank or rank, p.max or max
    end
    return rank, max
end

local function StandingAt(index, id, list, t)
    local last = Last(list, t)
    if last then return last.standing end
    local nextChange = list[1]
    if nextChange then return nextChange.standing + (nextChange.up and -1 or 1) end
    local now = index.repsNow[id]
    return now and now[1]
end

function Stats.Life(index, from, to)
    from, to = Bounds(index, from, to)
    local life = { professions = {}, reputation = {} }
    for name, list in pairs(index.skills) do
        local rank, max = SkillAt(list, to)
        if rank then
            life.professions[#life.professions + 1] = { name = name, rank = rank, max = max,
                gained = rank - (SkillAt(list, from) or 0) }
        end
    end
    table.sort(life.professions, function(a, b) return a.rank > b.rank or (a.rank == b.rank and a.name < b.name) end)

    local ids = {}
    for id in pairs(index.reps) do ids[id] = true end
    for id in pairs(index.repsNow) do ids[id] = true end
    for id in pairs(ids) do
        local list = index.reps[id] or {}
        local standing = StandingAt(index, id, list, to)
        if standing then
            local reached
            for _, change in ipairs(list) do
                if change.t > from and change.t <= to and change.up then reached = change.t end
            end
            local now = index.repsNow[id]
            life.reputation[#life.reputation + 1] = { id = id, name = list.name or (now and now[2]) or "?",
                standing = standing, reached = reached }
        end
    end
    table.sort(life.reputation, function(a, b)
        return a.standing > b.standing or (a.standing == b.standing and a.name < b.name)
    end)

    local guild = Last(index.guilds, to)
    life.guild = guild and guild.name
    return life
end

-- Level rows ----------------------------------------------------------------------

local function Diff(a, b, key)
    return a[key] and b[key] and b[key] - a[key] or nil
end

function Stats.Levels(journey, current, now)
    local levels, totals = journey.levels or {}, journey.totals or {}
    local keys = {}
    for level in pairs(levels) do keys[#keys + 1] = level end
    table.sort(keys)
    local live = {
        played = now and now.played, money = now and now.money, kills = totals.kills, deaths = totals.deaths,
        quests = totals.quests, killXP = totals.killXP, questXP = totals.questXP, instances = totals.instances,
        distance = totals.distance, flown = totals.flown,
    }
    -- Where each level up happened, from its "lvl" event.
    local places = {}
    for _, e in ipairs(journey.events or {}) do
        if e[2] == "lvl" and e[6] then places[e[6]] = e end
    end
    local rows = {}
    for _, level in ipairs(keys) do
        local s = levels[level]
        local after = levels[level + 1] or (level == current and live)
        local place = places[level]
        local row = { level = level, t = s.t, partial = s.partial, current = level == current or nil,
            c = place and place[3], x = place and place[4], y = place and place[5] }
        if after then
            row.time = Diff(s, after, "played")
            row.kills, row.deaths, row.quests = Diff(s, after, "kills"), Diff(s, after, "deaths"), Diff(s, after, "quests")
            row.killXP, row.questXP = Diff(s, after, "killXP"), Diff(s, after, "questXP")
            row.xp = row.killXP and row.questXP and row.killXP + row.questXP or nil
            row.dungeons = Diff(s, after, "instances")
            row.walked, row.flown = Diff(s, after, "distance"), Diff(s, after, "flown")
            row.gold = Diff(s, after, "money")
            -- A next level first seen at a login (levelled without the addon)
            -- has its time played and gold from then, so the difference
            -- holds some of that level too; the counts are recorded ones.
            if after.partial then row.time, row.gold = nil, nil end
        end
        rows[#rows + 1] = row
    end
    return rows
end
