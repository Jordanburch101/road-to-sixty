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
--     kept[slot]   the same, kept gear only (GearTimeline.Kept)
--     levels       { { level, t }, ... } in level order: when each was first seen
--     start, finish  the first and last time
--     capAt        when level CAP was reached, or nil
--     enchants     "itemID:enchantID" -> the last ench event for it
--     zones        { { t, uiMapID }, ... } in time order
--     quests       questID -> the qd event that turned it in
--   GearTimeline.Kept(spans)   the spans without brief ones, the ones around
--                              them stretched over the gap, or joined if the
--                              same item came back
--   GearTimeline.LevelAt(timeline, t)  the level at t as a fraction (5.5 is
--                              halfway through level 5); CAP from capAt on
--   GearTimeline.WornAt(timeline, t, every)  slot -> the span worn at t, kept
--                              gear only unless every
--   GearTimeline.ZoneAt(timeline, t)  the uiMapID of the zone at t, or nil

local GearTimeline = {}
ns.GearTimeline = GearTimeline

GearTimeline.CAP = 60
-- Kept gear leaves out swapping noise. A run of spans each shorter than
-- SWAP is noise when an item comes back within it or right around it (A, B,
-- A, or A, B, A, B): only the item that stays counts, from the first time
-- it was put on. A quick run of real upgrades (A, B, C) stays; in it only a
-- span shorter than MOMENT (a misclick) is left out. Clock time for now;
-- played time would be fairer (#64).
GearTimeline.MOMENT = 60
GearTimeline.SWAP = 600

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
    local kept = {}
    for slot, spans in pairs(slots) do
        for _, span in ipairs(spans) do span.endT = span.endT or finish end
        GearTimeline.MarkBrief(spans)
        kept[slot] = GearTimeline.Kept(spans)
    end

    for level, t in pairs(firstLevel) do levels[#levels + 1] = { level, t } end
    table.sort(levels, function(a, b) return a[1] < b[1] end)
    table.sort(zones, function(a, b) return a[1] < b[1] end)
    return {
        slots = slots, kept = kept, levels = levels, start = start, finish = finish, capAt = firstLevel[GearTimeline.CAP],
        enchants = enchants, zones = zones, quests = quests,
    }
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
            local last = out[#out]
            if last and SameItem(last, copy) then
                last.endT, last.next, last.closed = copy.endT, copy.next, copy.closed
            else
                if last then last.endT = copy.t end
                out[#out + 1] = copy
            end
        end
    end
    return out
end

function GearTimeline.LevelAt(timeline, t)
    local levels = timeline.levels
    if timeline.capAt and t >= timeline.capAt then return GearTimeline.CAP end
    local level, from, to
    for i, entry in ipairs(levels) do
        if entry[2] <= t then
            level, from = entry[1], entry[2]
            to = levels[i + 1] and levels[i + 1][1] == level + 1 and levels[i + 1][2] or nil
        end
    end
    if not level then return levels[1] and levels[1][1] or 1 end
    if not to or to <= from then return level end
    return level + math.min(0.999, (t - from) / (to - from))
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
