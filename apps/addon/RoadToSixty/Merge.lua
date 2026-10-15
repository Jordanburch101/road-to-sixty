local _, ns = ...

-- Merges two copies of one character's journey into one (#1), as plain
-- functions with no game calls: the sync server runs it on uploads, and the
-- addon on what the sync folder brings. The rules are the sync spec's
-- (docs/superpowers/specs/2026-10-12-sync-and-backup-design.md, "The merge
-- rules"). Three properties hold, and tests/merge_test.lua checks them:
-- Merge(a, b) equals Merge(b, a), Merge(m, m) equals m for any merge result,
-- and Merge(Merge(a, b), c) equals Merge(a, Merge(b, c)). That is what makes
-- repeated syncs, uploads out of order and stale copies safe.
--
-- What it relies on:
-- - One character is online on one PC at a time, so the events of any one
--   second come from one PC, and a copy that is behind holds the start of
--   what the other holds. Open runs and groups are the exception: they are
--   kept until the events show them ended.
-- - Both copies are at layout 4 (Prepare brings older uploads up) and
--   tidied as a login would (Tidy.lua). The caller does both.
-- - Both are copies of the same character: the caller checks the name (the
--   server from the upload's, the addon from the sync folder's key). Two
--   journeys of one name that are stamped differently (journeyId, Core.lua)
--   are refused here.
--
-- Merge never changes its inputs; the result may share tables with them.
-- distance and flown come out in whole yards: sums of decimals added in
-- another order differ in the last digit, which would make two ways of
-- grouping three merges differ.

local Merge = {}
ns.Merge = Merge

Merge.VERSION = 4   -- the layout it merges, DATA_VERSION in Core.lua

local RANK = { boolean = 1, number = 2, string = 3, table = 4 }

-- Everything either value has: two tables key by key, otherwise the larger
-- value (true over false, a table over anything else). Made for two copies
-- of one thing where one was filled in more; for two different values it
-- is only a fixed choice, the same whichever way round.
local function Join(a, b)
    if a == nil then return b end
    if b == nil then return a end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return RANK[ta] > RANK[tb] and a or b end
    if ta == "table" then
        local out = {}
        for k, v in pairs(a) do out[k] = Join(v, b[k]) end
        for k, v in pairs(b) do
            if a[k] == nil then out[k] = v end
        end
        return out
    end
    if ta == "boolean" then return a or b end
    return a >= b and a or b
end
Merge.Join = Join

-- Calls fn(key) once for each key in a or b.
local function EachKey(a, b, fn)
    for k in pairs(a or {}) do fn(k) end
    for k in pairs(b or {}) do
        if a == nil or a[k] == nil then fn(k) end
    end
end

-- Two maps merged key by key: a key in one only keeps its value, a key in
-- both gets pick(value in x, value in y).
local function MergeMap(x, y, pick)
    if x == nil or y == nil then return x or y end
    local out = {}
    EachKey(x, y, function(k)
        local p, q = x[k], y[k]
        if p == nil then
            out[k] = q
        elseif q == nil then
            out[k] = p
        else
            out[k] = pick(p, q)
        end
    end)
    return out
end

local function Refused(char)
    if type(char) ~= "table" then return "not a journey" end
    if char.seeded then return "a seeded test journey" end
    local version = tonumber(char.version) or 0
    if version > Merge.VERSION then return "a newer layout than this merge knows" end
    if version < Merge.VERSION then return "an older layout: Prepare it first" end
end

local function LastSeen(char)
    local last = -math.huge
    for _, e in ipairs(char.events or {}) do
        if e[1] > last then last = e[1] end
    end
    return last
end

-- The copy seen last, by its latest event; nil when both were seen last at
-- the same time.
local function Latest(a, b)
    local la, lb = LastSeen(a), LastSeen(b)
    if la == lb then return nil end
    return la > lb and a or b
end

-- How each top-level field merges, given both copies' values (either may be
-- nil). A field not listed is current state, from the copy seen last.
local RULES = {
    clockFrom = Join,   -- the later switch to the realm's clock: times before it may be by a PC's clock
    played = Join,
    skills = Join,      -- profession -> { rank, max, icon }: the higher rank
    recipes = Join,
    journeyId = Join,   -- the stamp, kept from whichever copy has one (Merge refuses two that differ)
}

-- The items of list grouped by keyOf(item): groups[key] holds them in list
-- order; keys lists each key once, in order of first appearance.
local function Group(list, keyOf)
    local groups, keys = {}, {}
    for _, item in ipairs(list or {}) do
        local key = keyOf(item)
        local group = groups[key]
        if not group then
            group = {}
            groups[key], keys[#keys + 1] = group, key
        end
        group[#group + 1] = item
    end
    return groups, keys
end

-- The keys in either list, once each.
local function Union(x, y)
    local seen, out = {}, {}
    for _, list in ipairs({ x, y }) do
        for _, key in ipairs(list) do
            if not seen[key] then
                seen[key], out[#out + 1] = true, key
            end
        end
    end
    return out
end

-- Events ------------------------------------------------------------------

-- What an event is about besides its time and kind, per the spec. Kinds not
-- listed (on, off, die, grp, grpk, grpx, and kinds from a newer addon)
-- match on time and kind alone.
local function Field6(e) return e[6] end
local ABOUT = {
    qa = Field6, qd = Field6, eq = Field6, loot = Field6, ["in"] = Field6, out = Field6,
    rep = Field6, prof = Field6, rec = Field6, mount = Field6, ride = Field6,
    gj = Field6, gl = Field6, gr = Field6, lvl = Field6, zone = Field6, grpl = Field6, grps = Field6,
    grpa = function(e) return type(e[6]) == "table" and e[6][1] or nil end,
    rare = function(e) return e[9] or e[6] end,     -- the rares key: NPC ID, else name
}

local function EventKey(e)
    local about = ABOUT[e[2]]
    return tostring(e[2]) .. "|" .. tostring(about and about(e))
end

local function EventTime(e) return e[1] end

local function KeysBefore(x, y)
    for i = 1, #x do
        local kx, ky = EventKey(x[i]), EventKey(y[i])
        if kx ~= ky then return kx < ky end
    end
    return false
end

-- One second's events from both copies. They come from one PC, so the copy
-- with more of them leads and its order is kept; the other's are matched to
-- them by key, the nth with the nth, and any left over follow in their
-- order. Two of one event in a copy (two of the same green drop) stay two:
-- the larger count, never the sum.
local function MergeSecond(x, y)
    if #y > #x or (#y == #x and KeysBefore(y, x)) then x, y = y, x end
    local waiting, used, out = {}, {}, {}
    for i, e in ipairs(y) do
        local key = EventKey(e)
        waiting[key] = waiting[key] or {}
        table.insert(waiting[key], i)
    end
    for _, e in ipairs(x) do
        local queue = waiting[EventKey(e)]
        local i = queue and table.remove(queue, 1)
        if i then
            used[i] = true
            out[#out + 1] = Join(e, y[i])
        else
            out[#out + 1] = e
        end
    end
    for i, e in ipairs(y) do
        if not used[i] then out[#out + 1] = e end
    end
    return out
end

-- Both copies' events, second by second in time order. A session found in
-- one copy only is kept; one in both becomes one.
local function MergeEvents(x, y)
    local gx, kx = Group(x, EventTime)
    local gy, ky = Group(y, EventTime)
    local times = Union(kx, ky)
    table.sort(times)
    local out = {}
    for _, t in ipairs(times) do
        for _, e in ipairs(MergeSecond(gx[t] or {}, gy[t] or {})) do out[#out + 1] = e end
    end
    return out
end
RULES.events = MergeEvents

-- Path segments and kills ------------------------------------------------------

-- Orders values of one type: numbers and strings by value, booleans false first.
local function Less(a, b)
    if type(a) ~= type(b) then return RANK[type(a)] < RANK[type(b)] end
    if type(a) == "boolean" then return not a and b end
    return a < b
end

local function SegmentKey(s)
    return tostring(s.t) .. "|" .. tostring(s.c) .. "|" .. tostring(s.m) .. "|" .. tostring(s.x) .. "|" .. tostring(s.y)
end

local function SegmentBefore(p, q)
    if p.t ~= q.t then return p.t < q.t end
    if p.c ~= q.c then return Less(p.c, q.c) end
    if p.m ~= q.m then return Less(p.m, q.m) end
    if p.x ~= q.x then return Less(p.x, q.x) end
    if p.y ~= q.y then return Less(p.y, q.y) end
    local dp, dq = p.d or "", q.d or ""
    if #dp ~= #dq then return #dp < #dq end
    return dp < dq
end

-- Segments matched by start time, continent, mode and start point (two can
-- open in one second when the clock steps back). A stale copy's path
-- string is always the start of the newer one, so the longer wins. Sorted by
-- start, since teleport detection compares each segment with the one before.
local function MergeSegments(x, y)
    local gx, kx = Group(x, SegmentKey)
    local gy, ky = Group(y, SegmentKey)
    local out = {}
    for _, key in ipairs(Union(kx, ky)) do
        local px, py = gx[key] or {}, gy[key] or {}
        for i = 1, math.max(#px, #py) do
            local p, q = px[i], py[i]
            local seg = p and q and Join(p, q) or p or q
            if p and q and #(p.d or "") ~= #(q.d or "") then
                seg.d = #(p.d or "") > #(q.d or "") and p.d or q.d
            end
            out[#out + 1] = seg
        end
    end
    table.sort(out, SegmentBefore)
    return out
end
RULES.segments = MergeSegments

-- A packed kills table as a list of { t, xp, name }, oldest first.
local function KillList(kills)
    local list = {}
    if kills and kills.d then ns.Packed.DecodeKills(kills.d, kills.names or {}, 0, list) end
    return list
end

local function KillKey(k) return k.t .. "|" .. k.xp .. "|" .. (k.name or "?") end

-- Both copies' kills: of each kill (time, XP, mob) the larger count is kept,
-- then all are packed again with a fresh name list and last.
local function MergeKills(x, y)
    local gx, kx = Group(KillList(x), KillKey)
    local gy, ky = Group(KillList(y), KillKey)
    local list = {}
    for _, key in ipairs(Union(kx, ky)) do
        local px, py = gx[key] or {}, gy[key] or {}
        for _, kill in ipairs(#px >= #py and px or py) do list[#list + 1] = kill end
    end
    table.sort(list, function(p, q)
        if p.t ~= q.t then return p.t < q.t end
        if p.xp ~= q.xp then return p.xp < q.xp end
        return (p.name or "?") < (q.name or "?")
    end)
    return ns.Packed.PackKills(list)
end
RULES.kills = MergeKills

-- Totals and level snapshots ----------------------------------------------------

local COUNTED = { "kills", "killXP", "quests", "questXP", "deaths", "instances", "distance", "flown" }

local function Round(x) return math.floor(x + 0.5) end

-- Every count in a journey's totals as { time, field, amount }, sorted so
-- the sums come out the same whatever order the data was in.
local function Marks(char)
    local marks = {}
    local function Mark(t, field, n) marks[#marks + 1] = { t, field, n } end
    for _, k in ipairs(KillList(char.kills)) do
        Mark(k.t, "kills", 1)
        Mark(k.t, "killXP", k.xp)
    end
    for _, e in ipairs(char.events or {}) do
        if e[2] == "qd" then
            Mark(e[1], "quests", 1)
            Mark(e[1], "questXP", tonumber(e[7]) or 0)
        elseif e[2] == "die" then
            Mark(e[1], "deaths", 1)
        elseif e[2] == "in" then
            Mark(e[1], "instances", 1)
        end
    end
    for _, seg in ipairs(char.segments or {}) do
        local ts, xs, ys = ns.Packed.DecodePath(seg)
        local field = seg.m == "t" and "flown" or "distance"   -- t: a taxi flight, as Recorder.lua counts it
        for i = 2, #ts do
            local dx, dy = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
            Mark(ts[i], field, math.sqrt(dx * dx + dy * dy))
        end
    end
    table.sort(marks, function(p, q)
        if p[1] ~= q[1] then return p[1] < q[1] end
        if p[2] ~= q[2] then return p[2] < q[2] end
        return p[3] < q[3]
    end)
    return marks
end

-- A journey's counts up to and including each of its snapshots' times, and
-- at math.huge for its totals: counts[time][field], distance and flown in
-- whole yards. One pass over the sorted marks, however many snapshots.
local function Counts(char)
    local times = { math.huge }
    for _, s in pairs(char.levels or {}) do
        if s.t then times[#times + 1] = s.t end
    end
    table.sort(times)
    local marks, sums, counts, i = Marks(char), {}, {}, 1
    for _, f in ipairs(COUNTED) do sums[f] = 0 end
    for _, t in ipairs(times) do
        while marks[i] and marks[i][1] <= t do
            sums[marks[i][2]] = sums[marks[i][2]] + marks[i][3]
            i = i + 1
        end
        local at = {}
        for _, f in ipairs(COUNTED) do at[f] = sums[f] end
        at.distance, at.flown = Round(at.distance), Round(at.flown)
        counts[t] = at
    end
    return counts
end

-- How far what was recorded (a copy's totals, or one of its snapshots) is
-- above what its data recounts to: counts kept before the data was.
local function Leftover(recorded, counted)
    local left = {}
    for _, f in ipairs(COUNTED) do left[f] = Round(tonumber(recorded[f]) or 0) - counted[f] end
    return left
end

local function Higher(x, y)
    if not x then return y end
    local out = {}
    for _, f in ipairs(COUNTED) do out[f] = math.max(x[f], y[f]) end
    return out
end

-- Which of two snapshots of one level to keep: a full one over one taken at
-- a later login, then the earlier. The same snapshot in both joins, since
-- played is filled in after it is taken.
local function PickSnapshot(p, q)
    if not p.partial ~= not q.partial then return p.partial and q or p end
    if p.t ~= q.t then return (p.t or 0) < (q.t or 0) and p or q end
    return Join(p, q)
end
RULES.levels = function(x, y) return MergeMap(x, y, PickSnapshot) end
RULES.totals = Join     -- the counts are redone by Recount; this keeps any other field

-- Recounts the merged journey's totals and each snapshot's counts from its
-- data, adding the larger leftover of the copies they came from. A snapshot
-- only gets back the counts it had.
local function Recount(out, a, b)
    local counts, ca, cb = Counts(out), Counts(a), Counts(b)
    local totals = {}
    for k, v in pairs(out.totals or {}) do totals[k] = v end
    local left = Higher(Leftover(a.totals or {}, ca[math.huge]), Leftover(b.totals or {}, cb[math.huge]))
    for _, f in ipairs(COUNTED) do totals[f] = counts[math.huge][f] + left[f] end
    out.totals = totals
    if not out.levels then return end
    local levels = {}
    for level, s in pairs(out.levels) do
        local snap, kept = {}, nil
        for k, v in pairs(s) do snap[k] = v end
        for _, side in ipairs({ { a, ca }, { b, cb } }) do
            local mine = side[1].levels and side[1].levels[level]
            if s.t and mine and mine.t == s.t then kept = Higher(kept, Leftover(mine, side[2][s.t])) end
        end
        if kept then
            for _, f in ipairs(COUNTED) do
                if snap[f] ~= nil then snap[f] = counts[s.t][f] + kept[f] end
            end
        end
        levels[level] = snap
    end
    out.levels = levels
end

-- Riding, mounts, people and rares ---------------------------------------------

-- riding (spellID -> { name, time, level, base }) and mounts (mountID ->
-- { time, c, x, y, level, base }, plus logged): the earliest note of each
-- wins, at being the index of its time. A mount logged in either copy
-- stays logged, so it is never logged again.
local function FirstNoted(at)
    return function(x, y)
        return MergeMap(x, y, function(p, q)
            local tp, tq = p[at] or 0, q[at] or 0
            local note = tp == tq and Join(p, q) or (tp < tq and p or q)
            if (p.logged or q.logged) and not note.logged then note = Join(note, { logged = true }) end
            return note
        end)
    end
end
RULES.riding = FirstNoted(2)
RULES.mounts = FirstNoted(1)

-- A player met, in both copies (Groups.lua): the tallies keep the higher
-- part per PC; where and when they were first met comes from the copy that
-- met them first, and the rest from the copy that saw them last.
local FIRST_MET = { "first", "c", "x", "y" }
local LAST_SEEN = { "last", "name", "race", "sex", "class", "level", "guild" }

local function MergePerson(p, q)
    local out = Join(p, q)
    if p.first ~= q.first then
        local first = (p.first or 0) < (q.first or 0) and p or q
        for _, f in ipairs(FIRST_MET) do out[f] = first[f] end
    end
    if p.last ~= q.last then
        local last = (p.last or 0) > (q.last or 0) and p or q
        for _, f in ipairs(LAST_SEEN) do out[f] = last[f] end
    end
    return out
end
RULES.people = function(x, y) return MergeMap(x, y, MergePerson) end

-- A rare (Rares.lua): kills tallied per PC, the higher part each; the first
-- kill the earliest.
local function MergeRare(p, q)
    local out = Join(p, q)
    if p[2] and q[2] then out[2] = math.min(p[2], q[2]) end
    return out
end
RULES.rares = function(x, y) return MergeMap(x, y, MergeRare) end

-- Whether events hold one of kind at time t.
local function Logged(events, kind, t)
    for _, e in ipairs(events or {}) do
        if e[1] == t and e[2] == kind then return true end
    end
    return false
end

-- Whether events hold the end of the group that began at t: its "grpx",
-- whose summary says how long it lasted.
local function GroupEnded(events, t)
    for _, e in ipairs(events or {}) do
        if e[2] == "grpx" and type(e[6]) == "table" and e[1] - (tonumber(e[6].duration) or 0) == t then return true end
    end
    return false
end

function Merge.Merge(a, b)
    local refused = Refused(a) or Refused(b)
    if refused then return nil, refused end
    if a.journeyId and b.journeyId and a.journeyId ~= b.journeyId then
        return nil, "these are two different journeys"
    end
    local out, latest = {}, Latest(a, b)
    EachKey(a, b, function(k)
        local rule = RULES[k]
        if rule then
            out[k] = rule(a[k], b[k])
        elseif latest then
            out[k] = latest[k]
        else
            out[k] = Join(a[k], b[k])
        end
    end)
    -- A run or group still open at logout is work for whichever PC logs in
    -- next, so a copy that never saw it doesn't drop it; once the merged
    -- events show it ended, it's done.
    for _, k in ipairs({ "run", "group" }) do
        if out[k] == nil then out[k] = a[k] or b[k] end
    end
    if out.run and out.run.left and Logged(out.events, "out", out.run.left.t) then out.run = nil end
    if out.group and GroupEnded(out.events, out.group.t) then out.group = nil end
    out.version, out.rosterBuilt = Merge.VERSION, nil
    Recount(out, a, b)
    return out
end

-- Restores -----------------------------------------------------------------------

-- The "on" times of a journey's sessions, as a set.
local function OnTimes(char)
    local on = {}
    for _, e in ipairs(char.events or {}) do
        if e[2] == "on" then on[e[1]] = true end
    end
    return on
end

-- The sessions of old whose "on" isn't in kept, as { from, to }, oldest
-- first: what a restore from old to kept takes out. A session runs from
-- its "on" to the next "off"; with none, to a second before the next
-- "on", or to the last event. One character plays on one PC at a time, so
-- these stretches of time hold that play and nothing else.
function Merge.Windows(old, kept)
    local keep, events, windows = OnTimes(kept), old.events or {}, {}
    for i, e in ipairs(events) do
        if e[2] == "on" and not keep[e[1]] then
            local to = LastSeen(old)
            for j = i + 1, #events do
                if events[j][2] == "off" then
                    to = events[j][1]
                    break
                elseif events[j][2] == "on" then
                    to = events[j][1] - 1
                    break
                end
            end
            windows[#windows + 1] = { e[1], to }
        end
    end
    return windows
end

-- Every PC id with a part in one of a journey's tallies.
local function TallyPCs(char)
    local pcs = {}
    for _, p in pairs(char.people or {}) do
        for _, f in ipairs(ns.Tally.PEOPLE) do
            if type(p[f]) == "table" then
                for pc in pairs(p[f]) do pcs[pc] = true end
            end
        end
    end
    for _, r in pairs(char.rares or {}) do
        if type(r[1]) == "table" then
            for pc in pairs(r[1]) do pcs[pc] = true end
        end
    end
    return pcs
end

-- A tally's parts under the PCs head knows, no higher than head's.
local function Cap(t, theirs, known)
    if type(t) ~= "table" then return t end
    local out = {}
    for pc, n in pairs(t) do
        if known[pc] then
            local most = type(theirs) == "table" and theirs[pc] or 0
            n = math.min(n, most)
        end
        if n > 0 then out[pc] = n end
    end
    return next(out) and out or nil
end

-- Takes out of char (an upload made before a restore reached its PC) its
-- play inside windows, the sessions the restore removed, so merging it
-- can't bring them back. Only windows whose session char holds count: one
-- whose "on" head (the current journey) has is skipped, as head holds that
-- session again, and so is one char never had, so its tallies stay. The totals and later
-- snapshots come down by what was taken out, or the recount would put it
-- back as counts kept before the data. Tallies carry no times, so parts
-- under a PC head knows are held to head's; a new PC's parts stay. Changes
-- char in place and returns it.
function Merge.Strip(char, windows, head)
    local has, mine, live = OnTimes(head), OnTimes(char), {}
    for _, w in ipairs(windows) do
        if mine[w[1]] and not has[w[1]] then live[#live + 1] = w end
    end
    if #live == 0 then return char end
    local function Inside(t)
        if type(t) ~= "number" then return false end
        for _, w in ipairs(live) do
            if t >= w[1] and t <= w[2] then return true end
        end
        return false
    end
    local gone = { events = {}, segments = {}, levels = {} }
    local function Split(list, timeOf, into)
        local stay = {}
        for _, item in ipairs(list or {}) do
            if Inside(timeOf(item)) then into[#into + 1] = item else stay[#stay + 1] = item end
        end
        return stay
    end
    char.events = Split(char.events, function(e) return e[1] end, gone.events)
    char.segments = Split(char.segments, function(s) return s.t end, gone.segments)
    local kills, goneKills = {}, {}
    for _, k in ipairs(KillList(char.kills)) do
        if Inside(k.t) then goneKills[#goneKills + 1] = k else kills[#kills + 1] = k end
    end
    if #goneKills > 0 then char.kills = ns.Packed.PackKills(kills) end
    gone.kills = ns.Packed.PackKills(goneKills)
    for level, s in pairs(char.levels or {}) do
        if Inside(s.t) then char.levels[level] = nil end
    end
    -- Its end was in the removed session too, so the merge would keep it open.
    for _, k in ipairs({ "run", "group" }) do
        if type(char[k]) == "table" and Inside(char[k].t) then char[k] = nil end
    end
    -- What was taken out, counted up to each snapshot that stays and to the end.
    for level, s in pairs(char.levels or {}) do gone.levels[level] = { t = s.t } end
    local removed = Counts(gone)
    for _, f in ipairs(COUNTED) do
        if char.totals and tonumber(char.totals[f]) then
            char.totals[f] = char.totals[f] - removed[math.huge][f]
        end
    end
    for _, s in pairs(char.levels or {}) do
        local at = s.t and removed[s.t]
        if at then
            for _, f in ipairs(COUNTED) do
                if tonumber(s[f]) then s[f] = s[f] - at[f] end
            end
        end
    end
    local known = TallyPCs(head)
    for guid, p in pairs(char.people or {}) do
        local theirs = head.people and head.people[guid] or {}
        for _, f in ipairs(ns.Tally.PEOPLE) do p[f] = Cap(p[f], theirs[f], known) end
    end
    for key, r in pairs(char.rares or {}) do
        local theirs = head.rares and head.rares[key]
        r[1] = Cap(r[1], theirs and theirs[1], known)
    end
    return char
end

-- For the server -------------------------------------------------------------

-- The parts the addon adds to or indexes. A journey with one of the wrong
-- shape would stop the recording once the addon took it in, and the server
-- would hand it to every PC.
local TABLES = { "segments", "events", "levels", "kills", "recipes", "people", "totals" }

local function Misshapen(j)
    for _, k in ipairs(TABLES) do
        if j[k] ~= nil and type(j[k]) ~= "table" then return k .. " isn't a table" end
    end
    for _, e in ipairs(j.events or {}) do
        if type(e) ~= "table" or type(e[1]) ~= "number" then return "an event has no time" end
    end
    for k, v in pairs(j.totals or {}) do
        if type(v) ~= "number" then return "totals." .. tostring(k) .. " isn't a number" end
    end
    if j.kills and j.kills.d ~= nil and type(j.kills.d) ~= "string" then return "the kills aren't packed text" end
end

-- Brings a journey saved by an older addon up to Merge.VERSION before it is
-- merged, its counts counted as pc's, the PC it came from, and refuses one
-- that is damaged. Changes the journey in place. Returns it, or nil and why
-- it can't be merged.
function Merge.Prepare(char, pc)
    if type(char) ~= "table" then return nil, "not a journey" end
    local version = tonumber(char.version) or 0
    if version > Merge.VERSION then return nil, "a newer layout than this merge knows" end
    if version < 2 then return nil, "a layout from before journeys used the realm's clock" end
    local damaged = Misshapen(char)
    if damaged then return nil, "a damaged journey: " .. damaged end
    if version < 3 then
        ns.Tally.Upgrade(char, pc)
        char.version = 3
    end
    -- Layout 4 only adds the stamp, which the login writes.
    if version < 4 then char.version = 4 end
    return char
end

-- Whether upload continues head, a journey from before stamps, when upload
-- has a stamp: head has nothing yet, or both begin with the same event. A
-- namesake made later begins later. Both prepared and tidied first.
function Merge.SameJourney(head, upload)
    local h, u = (head.events or {})[1], (upload.events or {})[1]
    if not h then return true end
    return u ~= nil and h[1] == u[1] and h[2] == u[2]
end

local function Sessions(char)
    local on = {}
    for _, e in ipairs(char.events or {}) do
        if e[2] == "on" then on[e[1]] = (on[e[1]] or 0) + 1 end
    end
    return on
end

-- Every PC's part of every tally a journey holds, by a name for it.
local function Parts(char)
    local parts = {}
    for guid, p in pairs(char.people or {}) do
        for _, f in ipairs(ns.Tally.PEOPLE) do
            if type(p[f]) == "table" then
                for pc, n in pairs(p[f]) do parts["people " .. guid .. " " .. f .. " " .. pc] = n end
            end
        end
    end
    for key, r in pairs(char.rares or {}) do
        if type(r[1]) == "table" then
            for pc, n in pairs(r[1]) do parts["rares " .. tostring(key) .. " " .. pc] = n end
        end
    end
    return parts
end

-- The server's check of a merge result against its two inputs: every
-- session in either is there, and no total or tally went down (distance and
-- flown may lose an input's decimals). Returns true, or false and why.
function Merge.Check(a, b, out)
    local sessions, parts = Sessions(out), Parts(out)
    for _, copy in ipairs({ a, b }) do
        for t, n in pairs(Sessions(copy)) do
            if (sessions[t] or 0) < n then return false, "the session at " .. t .. " is missing" end
        end
        for _, f in ipairs(COUNTED) do
            local was = math.floor(tonumber(copy.totals and copy.totals[f]) or 0)
            if (tonumber(out.totals and out.totals[f]) or 0) < was then return false, "totals." .. f .. " went down" end
        end
        for name, n in pairs(Parts(copy)) do
            if (parts[name] or 0) < n then return false, "the tally " .. name .. " went down" end
        end
    end
    return true
end
