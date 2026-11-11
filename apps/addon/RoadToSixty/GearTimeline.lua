local _, ns = ...

-- The gear worn over a journey, for the gear screen (GearScreen.lua, issue
-- #64): which item each slot held, from when to when, read from the level
-- snapshots and "eq" events (Journal.lua), with enchants ("ench",
-- Enchants.lua) and sources (Sources.lua). No game calls, so it is tested
-- offline (tests/geartimeline_test.lua).
--
--   GearTimeline.Build(journey, now) -> timeline:
--     slots[slot]  spans in time order: { t, endT, id, item, source, late,
--                  prev, next, brief, closed, seenAt }; item is the item string when known,
--                  endT the next change (or the journey's end); brief marks
--                  a span hidden from "kept gear" (see MarkBrief); closed: the
--                  slot was left empty after it; seenAt: first seen then, but
--                  worn from t, the snapshot before with no gear (#63)
--     kept[slot]   the same, kept gear only (GearTimeline.Kept), with
--                  weapons swapped back and forth shown as the one held
--                  most (GearTimeline.Swaps): such spans have swap = true,
--                  shares = { { id, item, seconds }, ... } most first, and
--                  badges = { t, ... } where swapping starts or the item
--                  shown changes to one already in use
--     levels       { { level, t }, ... } in level order: when each was first seen
--     start, finish  the first and last time
--     capAt        when level CAP was reached, or nil
--     enchants     "itemID:enchantID" -> the last ench event for it
--     zones        { { t, uiMapID }, ... } in time order
--     quests       questID -> the qd event that turned it in
--   GearTimeline.Kept(spans)   the spans without brief ones, the ones around
--                              them stretched over the gap, or joined if the
--                              same item came back
--   GearTimeline.Swaps(spans, sessions, bounds)  kept spans with swapping
--                              shown as the item held most, cell by cell
--                              (bounds: each cell's start time, the levels'
--                              and then the weeks' past the cap; see Swaps)
--     sessions     { { from, to, played before }, ... }: the time logged in,
--                  from the on and off events
--   GearTimeline.LevelAt(timeline, t)  the level at t as a fraction (5.5 is
--                              halfway through level 5, in time played, so
--                              days logged out take no room); CAP from capAt
--                              on. Levels not recorded share the time between
--                              the ones around them; the last runs to finish
--   GearTimeline.U(timeline, t, weekWidth)  the gear screen's axis: LevelAt,
--                              then CAP plus weekWidth a week; TimeAt(timeline,
--                              u, weekWidth) runs it backwards
--   GearTimeline.WornAt(timeline, t, every)  slot -> the span worn at t, kept
--                              gear only unless every
--   GearTimeline.ZoneAt(timeline, t)  the uiMapID of the zone at t, or nil

local GearTimeline = {}
ns.GearTimeline = GearTimeline

-- The level cap; the gear screen sets the client's own (70 on the
-- Anniversary realms) before each Build, as this file makes no game calls.
GearTimeline.CAP = 60
-- Kept gear leaves out swapping noise. A run of spans each shorter than
-- SWAP is noise when an item comes back within it or right around it (A, B,
-- A, or A, B, A, B): only the item that stays counts, from the first time
-- it was put on. A quick run of real upgrades (A, B, C) stays; in it only a
-- span shorter than MOMENT (a misclick) is left out. Clock time for now;
-- played time would be fairer (#64).
GearTimeline.MOMENT = 60
GearTimeline.SWAP = 600
-- An item put away and taken out again within this many seconds played is
-- still in use (#137): a two-hander kept for dungeons between sword and
-- board, say.
GearTimeline.SWAP_GAP = 2 * 3600
GearTimeline.SWAP_SHARE = 0.25

local function ItemID(item)
    return item and tonumber(item:match("^item:(%-?%d+)"))
end

-- The item string without the enchant field: the same item, enchanted or not.
local function Plain(item)
    if not item then return nil end
    return (item:gsub("^(item:%-?%d+):%-?%d*", "%1:"))
end

function GearTimeline.Build(journey, now)
    local changes, levels, zones, quests, enchants = {}, {}, {}, {}, {}
    local start, finish = math.huge, 0
    local function Seen(t)
        if t < start then start = t end
        if t > finish then finish = t end
    end
    local firstLevel = {}
    local emptyFrom, firstGear      -- the first snapshot without gear (#63), and with
    local function Level(level, t)
        if level and t and (not firstLevel[level] or t < firstLevel[level]) then firstLevel[level] = t end
    end

    -- Snapshots set every slot, empty ones included. One with no gear at all
    -- was taken before the client gave the gear (#63) and says nothing.
    for level, s in pairs(journey.levels or {}) do
        if type(s) == "table" and s.t then
            Level(level, s.t)
            Seen(s.t)
            if not (s.gear and next(s.gear)) then
                emptyFrom = math.min(emptyFrom or s.t, s.t)
            else
                firstGear = math.min(firstGear or s.t, s.t)
                for slot = 1, 19 do
                    local id = s.gear[slot]
                    changes[#changes + 1] = { t = s.t, slot = slot, id = id, item = id and s.links and s.links[slot], order = 0 }
                end
            end
        end
    end
    for i, e in ipairs(journey.events or {}) do
        local t, kind = e[1], e[2]
        Seen(t)
        if kind == "eq" and type(e[6]) == "number" then
            local id = e[7] ~= 0 and e[7] or nil
            changes[#changes + 1] = { t = t, slot = e[6], id = id, item = id and e[8], late = e[9] or nil,
                source = type(e[10]) == "table" and e[10] or nil, order = i }
        elseif kind == "lvl" or kind == "on" then
            Level(e[6], t)
        elseif kind == "zone" then
            zones[#zones + 1] = { t, e[6] }
        elseif kind == "qd" then
            quests[e[6]] = e
        elseif kind == "ench" then
            enchants[e[6] .. ":" .. e[7]] = e
        end
    end
    table.sort(changes, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.order < b.order
    end)
    if now and now > finish then finish = now end
    if start == math.huge then start = finish end

    local slots = {}
    for slot = 1, 19 do slots[slot] = {} end
    local open = {}
    for _, c in ipairs(changes) do
        local spans, cur = slots[c.slot], open[c.slot]
        if not spans then
            spans = {}
            slots[c.slot] = spans
        end
        local same = cur and cur.id == c.id and (not c.item or not cur.item or Plain(c.item) == Plain(cur.item))
        if same then
            -- A snapshot or event saying again what is worn: keep what it adds.
            cur.item = c.item or cur.item
            cur.source = cur.source or c.source
        elseif c.id or cur then
            if cur then cur.endT = c.t end
            if c.id then
                local span = { t = c.t, id = c.id, item = c.item, source = c.source, late = c.late, prev = cur }
                if cur then cur.next = span end
                spans[#spans + 1] = span
                open[c.slot] = span
            else
                cur.closed = true       -- taken off, the slot left empty
                open[c.slot] = nil
            end
        end
    end
    -- Snapshots taken at login before 1.10.3 have no gear (#63). Gear the
    -- first snapshot with gear shows, in a slot nothing was seen in before,
    -- was worn from the empty one on.
    if emptyFrom and firstGear and emptyFrom < firstGear then
        for _, spans in pairs(slots) do
            local first = spans[1]
            if first and first.t == firstGear then
                first.seenAt, first.t = first.t, emptyFrom
            end
        end
    end
    for level, t in pairs(firstLevel) do levels[#levels + 1] = { level, t } end
    table.sort(levels, function(a, b) return a[1] < b[1] end)
    table.sort(zones, function(a, b) return a[1] < b[1] end)
    local sessions = GearTimeline.Sessions(journey.events or {}, finish)
    local capAt = firstLevel[GearTimeline.CAP]

    -- Swapping is shown cell by cell: a level (from when it was first seen),
    -- then past the cap a week, as the gear screen's axis runs.
    local bounds = {}
    for _, entry in ipairs(levels) do
        if not capAt or entry[2] < capAt then bounds[#bounds + 1] = entry[2] end
    end
    if capAt then
        for t = capAt, finish, GearTimeline.WEEK do bounds[#bounds + 1] = t end
    end
    table.sort(bounds)

    local kept = {}
    for slot, spans in pairs(slots) do
        for _, span in ipairs(spans) do span.endT = span.endT or finish end
        GearTimeline.MarkBrief(spans)
        kept[slot] = GearTimeline.Swaps(GearTimeline.Kept(spans), sessions, bounds)
    end
    return {
        slots = slots, kept = kept, levels = levels, start = start, finish = finish, capAt = capAt,
        enchants = enchants, zones = zones, quests = quests, sessions = sessions,
    }
end

-- The time logged in: { from, to, played before } for each session, in
-- order. A session runs from an on event to the next off; one with no off
-- (a crash) ends at its last event, and the one still open at finish.
-- Something recorded with no session open (journeys from before on events)
-- opens one there.
function GearTimeline.Sessions(events, finish)
    local sessions, played, open, last = {}, 0, nil, nil
    local function Close(to)
        if open and to > open then
            sessions[#sessions + 1] = { open, to, played }
            played = played + to - open
        end
        open = nil
    end
    for _, e in ipairs(events) do
        local t, kind = e[1], e[2]
        if kind == "on" then
            Close(last or t)
            open = t
        elseif kind == "off" then
            Close(t)
        elseif not open then
            open = t
        end
        last = t
    end
    Close(finish)
    return sessions
end

-- Seconds played by time t (sessions as Sessions gives them). Logged-out
-- time adds nothing; before the first session and after the last, clock
-- time counts, so the measure keeps growing.
local function Played(sessions, t)
    local first, lastSession = sessions[1], sessions[#sessions]
    if not first or t < first[1] then return t - (first and first[1] or 0) end
    local lo, hi = 1, #sessions
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if sessions[mid][1] <= t then lo = mid else hi = mid - 1 end
    end
    local s = sessions[lo]
    if t <= s[2] then return s[3] + t - s[1] end
    if s == lastSession then return s[3] + (s[2] - s[1]) + (t - s[2]) end
    return s[3] + s[2] - s[1]
end
GearTimeline.Played = Played    -- for Stats.lua

-- The time at which played seconds were reached: Played run backwards. A
-- moment between sessions is the end of the one before.
local function TimePlayed(sessions, played)
    local first = sessions[1]
    if not first then return played end
    if played < 0 then return first[1] + played end
    for _, s in ipairs(sessions) do
        if played <= s[3] + s[2] - s[1] then return s[1] + played - s[3] end
    end
    local last = sessions[#sessions]
    return last[2] + played - (last[3] + last[2] - last[1])
end

local function Short(span)
    return span.next ~= nil and span.endT - span.t < GearTimeline.SWAP
end

-- Sets brief on each span of one slot: true for swapping noise (see above).
function GearTimeline.MarkBrief(spans)
    local i = 1
    while i <= #spans do
        if Short(spans[i]) then
            local j = i
            while spans[j + 1] and Short(spans[j + 1]) do j = j + 1 end
            local seen, repeats = {}, false
            for k = math.max(1, i - 1), math.min(#spans, j + 1) do
                local key = spans[k].id .. "|" .. tostring(Plain(spans[k].item))
                if seen[key] then repeats = true end
                seen[key] = true
            end
            for k = i, j do
                spans[k].brief = repeats or spans[k].endT - spans[k].t < GearTimeline.MOMENT
            end
            i = j + 1
        else
            spans[i].brief = false
            i = i + 1
        end
    end
end

local function SameItem(a, b)
    return a.id == b.id and Plain(a.item) == Plain(b.item)
end

function GearTimeline.Kept(spans)
    local out = {}
    for i, span in ipairs(spans) do
        if not span.brief then
            local copy = {}
            for k, v in pairs(span) do copy[k] = v end
            -- Swapped in and out just before it stayed: it counts from the
            -- first time, with where that copy came from.
            local k = i - 1
            while k >= 1 and spans[k].brief do
                if SameItem(spans[k], span) then
                    copy.t, copy.source, copy.late = spans[k].t, spans[k].source or copy.source, spans[k].late
                end
                k = k - 1
            end
            -- The one before stretches over the noise between them, unless the
            -- slot was left empty after it (a two-hander put away the shield).
            local last = out[#out]
            if last and not last.closed and SameItem(last, copy) then
                last.endT, last.next, last.closed = copy.endT, copy.next, copy.closed
            else
                if last and not last.closed then last.endT = copy.t end
                out[#out + 1] = copy
            end
        end
    end
    return out
end

-- Weapons swapped back and forth (#137): a warrior's sword and board and a
-- two-hander, each kept on for a while, made a row of slivers and an off
-- hand that emptied whenever the two-hander went on. In kept gear:
--   1. An item is in use from the first time it goes on to the last time it
--      comes off; taken out again within SWAP_GAP played, the stretch goes
--      on. The end is its last use, as the journey is read looking back.
--   2. Where two or more items for the slot are in use at once, it swaps.
--   3. A cell (bounds: each one's start time) in which the slot swaps shows
--      the item in hand most over the whole cell. Elsewhere each stretch
--      shows whole, so a lone off hand item is one bar, its gaps while a
--      two-hander was on included. Neighbours showing the same item join.
--   4. A badge where the item shown changes to one that was in use the
--      cell before (the player came to favour it), and where swapping
--      starts with the others in hand for at least SWAP_SHARE of the cell.
--      None where the item before stopped being in use (a replacement), nor
--      for a moment's swap in a long cell (a quest's weapon taken out once).
-- Spans are Kept's, in time order; sessions as Sessions gives them.
function GearTimeline.Swaps(spans, sessions, bounds)
    if #spans < 2 then return spans end
    -- 1. Stretches in use, per item.
    local stretches, open = {}, {}
    for _, span in ipairs(spans) do
        local key = span.id .. "|" .. tostring(Plain(span.item))
        local last = open[key]
        if last and Played(sessions, span.t) - Played(sessions, last.endT) <= GearTimeline.SWAP_GAP then
            last.endT = span.endT
            last.worn[#last.worn + 1] = span
        else
            last = { key = key, t = span.t, endT = span.endT, worn = { span } }
            open[key] = last
            stretches[#stretches + 1] = last
        end
    end
    -- 2. Pieces between every stretch's ends and every cell's start, with
    -- the stretches in use in each, so no piece runs over two cells.
    local edges, seen = {}, {}
    local first, last = math.huge, -math.huge
    for _, st in ipairs(stretches) do
        for _, e in ipairs({ st.t, st.endT }) do
            if not seen[e] then seen[e] = true; edges[#edges + 1] = e end
        end
        first, last = math.min(first, st.t), math.max(last, st.endT)
    end
    for _, e in ipairs(bounds) do
        if e > first and e < last and not seen[e] then seen[e] = true; edges[#edges + 1] = e end
    end
    table.sort(edges)
    local pieces = {}
    for i = 1, #edges - 1 do
        local a, b = edges[i], edges[i + 1]
        local active = {}
        for _, st in ipairs(stretches) do
            if st.t < b and st.endT > a then active[#active + 1] = st end
        end
        if #active > 0 then pieces[#pieces + 1] = { a = a, b = b, active = active } end
    end

    local function Worn(st, a, b)
        local total = 0
        for _, w in ipairs(st.worn) do
            total = total + math.max(0, math.min(b, w.endT) - math.max(a, w.t))
        end
        return total
    end
    local function CellOf(t)
        local cell = 0
        for i, start in ipairs(bounds) do
            if start <= t then cell = i else break end
        end
        return cell
    end

    -- 3. What shows, piece by piece, a swapping cell as one.
    local shown = {}        -- { a, b, st, swap, inUse = { st = true }, worn = { [st] = seconds } }
    local i = 1
    while i <= #pieces do
        local cell = CellOf(pieces[i].a)
        local j, swapping = i, false
        while pieces[j] and CellOf(pieces[j].a) == cell do
            swapping = swapping or #pieces[j].active > 1
            j = j + 1
        end
        if swapping then
            local from = math.max(bounds[cell] or -math.huge, pieces[i].a)
            local to = math.min(bounds[cell + 1] or math.huge, pieces[j - 1].b)
            local inUse, worn, best = {}, {}, nil
            for k = i, j - 1 do
                for _, st in ipairs(pieces[k].active) do
                    if not inUse[st] then
                        inUse[st] = true
                        worn[st] = Worn(st, from, to)
                        if not best or worn[st] > worn[best] then best = st end
                    end
                end
            end
            shown[#shown + 1] = { a = pieces[i].a, b = pieces[j - 1].b, st = best, swap = true, inUse = inUse, worn = worn }
        else
            for k = i, j - 1 do
                local p = pieces[k]
                shown[#shown + 1] = { a = p.a, b = p.b, st = p.active[1], inUse = { [p.active[1]] = true } }
            end
        end
        i = j
    end

    -- 4. Spans: neighbours with the same item joined, each a copy of the
    -- worn span it starts in (or the stretch's next one), with the badges
    -- and the shares of the cells it swapped in.
    local out, before = {}, nil
    for _, sh in ipairs(shown) do
        local last = out[#out]
        local badge = false
        if sh.swap then
            local starts = not (before and before.swap and before.b == sh.a)
            if before and before.b == sh.a and before.st ~= sh.st and sh.inUse[before.st] then
                badge = true
            elseif starts then
                local total = 0
                for _, seconds in pairs(sh.worn) do total = total + seconds end
                badge = total > 0 and 1 - sh.worn[sh.st] / total >= GearTimeline.SWAP_SHARE
            end
        end
        if last and last.key == sh.st.key and last.endT == sh.a then
            last.endT = sh.b
        else
            local from = sh.st.worn[#sh.st.worn]
            for _, w in ipairs(sh.st.worn) do
                if w.endT > sh.a then from = w break end
            end
            last = {}
            for k, v in pairs(from) do last[k] = v end
            last.t, last.endT, last.key, last.badges, last.byItem = sh.a, sh.b, sh.st.key, {}, {}
            if from ~= sh.st.worn[1] or sh.a > from.t then last.seenAt = nil end
            out[#out + 1] = last
        end
        if sh.swap then
            last.swap = true
            for st, seconds in pairs(sh.worn) do
                local share = last.byItem[st.key]
                if not share then
                    share = { id = st.worn[1].id, item = st.worn[1].item, seconds = 0 }
                    last.byItem[st.key] = share
                end
                share.seconds = share.seconds + seconds
            end
        end
        if badge then last.badges[#last.badges + 1] = sh.a end
        before = sh
    end
    for k, span in ipairs(out) do
        local nextSpan = out[k + 1]
        span.prev = out[k - 1] and out[k - 1].endT == span.t and out[k - 1] or nil
        span.next = nextSpan and nextSpan.t == span.endT and nextSpan or nil
        -- Left empty after it when nothing follows straight on, but the
        -- last keeps what the slot did at the end.
        if nextSpan then span.closed = not span.next or nil end
        span.shares = nil
        if span.swap then
            local shares = {}
            for _, share in pairs(span.byItem) do shares[#shares + 1] = share end
            table.sort(shares, function(a, b) return a.seconds > b.seconds end)
            span.shares = shares
        end
        span.byItem, span.key = nil, nil
        if #span.badges == 0 then span.badges = nil end
    end
    return out
end

-- The level entry at or before t (by time) and where it leads: level, from,
-- toLevel, to. The next entry, levels apart when some were not recorded (the
-- addon off, or played on another PC); after the last, the next level at the
-- journey's finish, so the level being played now has its width.
local function Stretch(timeline, i)
    local levels = timeline.levels
    local entry, nextEntry = levels[i], levels[i + 1]
    if nextEntry then return entry[1], entry[2], nextEntry[1], nextEntry[2] end
    return entry[1], entry[2], entry[1] + 1, timeline.finish
end

function GearTimeline.LevelAt(timeline, t)
    local levels = timeline.levels
    if timeline.capAt and t >= timeline.capAt then return GearTimeline.CAP end
    local at
    for i, entry in ipairs(levels) do
        if entry[2] <= t then at = i end
    end
    if not at then return levels[1] and levels[1][1] or 1 end
    local level, from, toLevel, to = Stretch(timeline, at)
    if to <= from or toLevel <= level then return level end
    -- How far through the level by time played; by the clock if none was.
    local sessions = timeline.sessions or {}
    local a, b = Played(sessions, from), Played(sessions, to)
    local f = b > a and (Played(sessions, t) - a) / (b - a) or (t - from) / (to - from)
    return level + (toLevel - level) * math.max(0, math.min(0.999, f))
end

-- The axis unit of the gear screen: the level as a fraction (LevelAt) up to
-- CAP, then CAP plus weekWidth for each week since reaching it. TimeAt runs
-- it backwards.
GearTimeline.WEEK = 7 * 86400

function GearTimeline.U(timeline, t, weekWidth)
    if timeline.capAt and t >= timeline.capAt then
        return GearTimeline.CAP + (t - timeline.capAt) / GearTimeline.WEEK * weekWidth
    end
    return GearTimeline.LevelAt(timeline, t)
end

function GearTimeline.TimeAt(timeline, u, weekWidth)
    if timeline.capAt and u >= GearTimeline.CAP then
        return timeline.capAt + (u - GearTimeline.CAP) / weekWidth * GearTimeline.WEEK
    end
    local levels, at = timeline.levels, nil
    for i, entry in ipairs(levels) do
        if entry[1] <= u then at = i end
    end
    if not at then return levels[1] and levels[1][2] or timeline.start end
    local level, from, toLevel, to = Stretch(timeline, at)
    if to <= from or toLevel <= level then return from end
    local f = math.max(0, math.min(1, (u - level) / (toLevel - level)))
    local sessions = timeline.sessions or {}
    local a, b = Played(sessions, from), Played(sessions, to)
    if b <= a then return from + f * (to - from) end
    return math.max(from, math.min(to, TimePlayed(sessions, a + f * (b - a))))
end

function GearTimeline.WornAt(timeline, t, every)
    local worn = {}
    for slot, spans in pairs(every and timeline.slots or timeline.kept) do
        for _, span in ipairs(spans) do
            if span.t <= t and (t < span.endT or not span.next and not span.closed) then worn[slot] = span end
        end
    end
    return worn
end

function GearTimeline.ZoneAt(timeline, t)
    local zone
    for _, z in ipairs(timeline.zones) do
        if z[1] > t then break end
        zone = z[2]
    end
    return zone
end

GearTimeline.ItemID = ItemID
GearTimeline.Plain = Plain
