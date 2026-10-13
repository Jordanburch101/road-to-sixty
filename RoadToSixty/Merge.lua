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
--   what the other holds.
-- - Both copies are at layout 3 (Prepare brings a layout 2 upload up) and
--   tidied as a login would (Tidy.lua). The caller does both.
-- - Both are copies of the same character. The data doesn't say whose it
--   is, so the caller checks that: the server from the WTF path, the addon
--   from the sync folder's character key.
--
-- Merge never changes its inputs; the result may share tables with them.
-- distance and flown come out in whole yards: sums of decimals added in
-- another order differ in the last digit, which would make two ways of
-- grouping three merges differ.

local Merge = {}
ns.Merge = Merge

Merge.VERSION = 3   -- the layout it merges, DATA_VERSION in Core.lua

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
}

function Merge.Merge(a, b)
    local refused = Refused(a) or Refused(b)
    if refused then return nil, refused end
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
    out.version, out.rosterBuilt = Merge.VERSION, nil
    return out
end
