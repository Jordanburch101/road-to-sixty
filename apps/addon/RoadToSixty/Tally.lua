local _, ns = ...

-- Counts the merge can't rebuild from events, kept per PC so two PCs'
-- copies of one journey can be merged (#1). A tally is { [PC ID] = count }:
-- each PC adds only to its own part, a merge keeps the higher part for each
-- PC, and the count shown is the sum. Plain functions with no game calls,
-- so the sync server uses them too.
--
-- Tallies since layout 3 (DATA_VERSION in Core.lua):
--   people[guid].groups, seconds, raids, raidSeconds, dungeons, raidRuns
--   (Groups.lua), nil for none
--   rares[key][1], the times that rare was killed (Rares.lua)

local Tally = {}
ns.Tally = Tally

Tally.PEOPLE = { "groups", "seconds", "raids", "raidSeconds", "dungeons", "raidRuns" }

-- The count a tally shows. Another character's journey copy in the roster
-- stays at the layout it was saved in until that character logs in, so a
-- plain number from layout 2 reads as it is.
function Tally.Total(t)
    if type(t) ~= "table" then return t or 0 end
    local n = 0
    for _, part in pairs(t) do n = n + part end
    return n
end

function Tally.Add(owner, key, pc, n)
    local t = owner[key] or {}
    owner[key] = t
    t[pc] = (t[pc] or 0) + n
end

-- Turns a journey's layout 2 counts into tallies, all counted as pc's.
-- Counts that are already tallies are left alone, so running it again, or
-- on a half-converted journey, is safe.
function Tally.Upgrade(char, pc)
    for _, p in pairs(char.people or {}) do
        for _, key in ipairs(Tally.PEOPLE) do
            if type(p[key]) == "number" then
                p[key] = p[key] ~= 0 and { [pc] = p[key] } or nil
            end
        end
    end
    for _, r in pairs(char.rares or {}) do
        if type(r[1]) == "number" then r[1] = { [pc] = r[1] } end
    end
end
