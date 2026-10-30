local _, ns = ...

-- The numbers the Stats screen shows (issue #83), for any stretch of a
-- journey: the map's date range, up to the replay's moment. No game calls,
-- so it is tested offline (tests/stats_test.lua).
--
--   Stats.Index(journey, now, money) -> index
--     Running totals over the whole journey, built once and kept while the
--     journey does not change (Stats.Changed says when it has): kills and
--     their XP (packed kills), quests turned in with their XP and money
--     ("qd"), deaths ("die"), dungeon and raid runs ("in"; battlegrounds and
--     arenas left out), yards walked and flown (the path segments, counted
--     as the recorder counts them: flight paths are flown, the rest walked),
--     the play sessions ("on" and "off"), level ups (the level snapshots),
--     zones entered ("zone") and gold held (each snapshot's, then money, the
--     gold held now, when given). now is the journey's end: ns.Now() for the
--     character playing, its last event for another's copy.
--   Stats.Window(index, from, to) -> totals
--     What happened from time from to time to (Unix seconds; nil for the
--     journey's start and end), each a binary search, so the replay can ask
--     every frame: { from, to, played (seconds logged in), kills, killXP,
--     quests, questXP, questMoney, deaths, dungeons, walked, flown, gold
--     (change in gold held; nil before the first snapshot), levelFrom,
--     levelTo (level at from and at to), zones = { { uiMapID, seconds
--     played }, ... } most first }.
--   Stats.LevelAt(index, t) -> level, fraction
--     The level at t, and how far through it by time played (0 to 1).
--   Stats.Levels(journey, current, now) -> rows
--     One row per level with a snapshot, its numbers the change from
--     reaching it to reaching the next; the level now (current, with now's
--     totals: { played, money }) runs to now: { level, partial, time, kills,
--     deaths, quests, xp, killXP, questXP, dungeons, walked, flown, gold }.
--     Fields a snapshot lacks are nil.

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
        entries[i] = { t = k.t, kills = 1, killXP = k.xp }
    end
    return entries
end

local PVP = { pvp = true, arena = true }

function Stats.Index(journey, now, money)
    local quests, deaths, runs, zones = {}, {}, {}, {}
    local first, last
    for _, e in ipairs(journey.events or {}) do
        local t, kind = e[1], e[2]
        first, last = first or t, t
        if kind == "qd" then
            quests[#quests + 1] = { t = t, quests = 1, questXP = e[7], questMoney = e[8] }
        elseif kind == "die" then
            deaths[#deaths + 1] = { t = t, deaths = 1 }
        elseif kind == "in" and not PVP[e[8]] then
            runs[#runs + 1] = { t = t, dungeons = 1 }
        elseif kind == "zone" then
            zones[#zones + 1] = { t = t, id = e[6] }
        end
    end
    now = now or last or 0

    -- Level ups and gold held, from the snapshots in time order.
    local levels, gold = {}, {}
    for level, s in pairs(journey.levels or {}) do
        if s.t then
            levels[#levels + 1] = { t = s.t, level = level }
            if s.money then gold[#gold + 1] = { t = s.t, money = s.money } end
        end
    end
    table.sort(levels, function(a, b) return a.t < b.t end)
    table.sort(gold, function(a, b) return a.t < b.t end)
    if money then gold[#gold + 1] = { t = now, money = money } end
    table.sort(zones, function(a, b) return a.t < b.t end)

    local index = {
        start = first or now, finish = now, levels = levels, gold = gold, zones = zones,
        sessions = ns.GearTimeline.Sessions(journey.events or {}, now),
        kills = Build({ "kills", "killXP" }, Kills(journey.kills)),
        quests = Build({ "quests", "questXP", "questMoney" }, quests),
        deaths = Build({ "deaths" }, deaths),
        runs = Build({ "dungeons" }, runs),
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

-- Seconds played in each zone between from and to: each zone entry lasts
-- until the next.
local function Zones(index, from, to)
    local seconds, list = {}, index.zones
    local _, i = At(list, from)
    i = math.max(i, 1)
    while list[i] and list[i].t <= to do
        local a = math.max(list[i].t, from)
        local b = math.min(list[i + 1] and list[i + 1].t or index.finish, to)
        if b > a then
            local id = list[i].id
            seconds[id] = (seconds[id] or 0) + Played(index, b) - Played(index, a)
        end
        i = i + 1
    end
    local out = {}
    for id, s in pairs(seconds) do
        if s > 0 then out[#out + 1] = { id, s } end
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
        { index.deaths, { "deaths" } }, { index.runs, { "dungeons" } }, { index.path, { "walked", "flown" } } }) do
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
    w.zones = Zones(index, from, to)
    return w
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
    local rows = {}
    for _, level in ipairs(keys) do
        local s = levels[level]
        local after = levels[level + 1] or (level == current and live)
        local row = { level = level, partial = s.partial, current = level == current or nil }
        if after then
            row.time = Diff(s, after, "played")
            row.kills, row.deaths, row.quests = Diff(s, after, "kills"), Diff(s, after, "deaths"), Diff(s, after, "quests")
            row.killXP, row.questXP = Diff(s, after, "killXP"), Diff(s, after, "questXP")
            row.xp = row.killXP and row.questXP and row.killXP + row.questXP or nil
            row.dungeons = Diff(s, after, "instances")
            row.walked, row.flown = Diff(s, after, "distance"), Diff(s, after, "flown")
            row.gold = Diff(s, after, "money")
        end
        rows[#rows + 1] = row
    end
    return rows
end
