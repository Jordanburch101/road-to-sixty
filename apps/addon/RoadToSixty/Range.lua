local _, ns = ...

-- The part of the journey every mode of the map window shows (issue #66):
-- a date range (all time, or a part such as today or the last seven days)
-- and a phase (the whole journey, levelling up to the level cap, or the
-- endgame after it), the two together. Map.lua builds its path, replay
-- and replay bar from the paths inside it and shows only the markers in
-- it, History lists only what is in it, the gear screen opens on it and
-- the Stats screen counts only what is in it. It lasts the session;
-- nothing saved changes, and paths are copied when cut, never changed in
-- place.
--
--   Range.Bounds(key, now)  from and to of a preset at time now; nil for all time
--   Range:Set(key, now)     one of the PRESETS keys; the bounds are worked
--                           out from now (ns.Now() if not given), cut to
--                           the phase
--   Range:SetCap(t)         when the journey shown reached the level cap, or
--                           nil: where levelling ends and the endgame starts.
--                           Without it every phase is the whole journey
--   Range:SetPhase(key, now)  one of the PHASES keys
--   Range:Refresh(now)      the bounds again, for "today" after midnight
--   Range:Has(t)            whether time t is inside
--   Range:IsAll()           true for all time and the whole journey; from and
--                           to are both nil then, else both numbers
--   Range:Label()           the preset's name, for the map's button
--   Range:PhaseLabel()      the phase's name, for its button
--   Range:Key()             the preset and the phase in force, for caches
--   Range:TrimPaths(paths)  the paths cut to the range (Recorder.lua's format)
--
-- Days start at the player's own midnight (times are Unix seconds, ns.Now),
-- found again on days the clocks change. The last 7 and 30 days are today
-- and the days before it, from a midnight, so their start only moves once
-- a day. No game calls but date, so it is tested offline (tests/range_test.lua).

local Range = { key = "all", phase = "all" }
ns.Range = Range

Range.PRESETS = {
    { "all", "All time" }, { "today", "Today" }, { "yesterday", "Yesterday" },
    { "week", "Last 7 days" }, { "month", "Last 30 days" },
}
Range.PHASES = { { "all", "Whole journey" }, { "lvl", "Levelling" }, { "end", "Endgame" } }

-- The last midnight at or before now, by the player's clock. Taking the
-- hours off is an hour out on a day the clocks change, so the hour it gives
-- is checked and put right.
local function Midnight(now)
    local d = date("*t", now)
    local midnight = now - (d.hour * 3600 + d.min * 60 + d.sec)
    local hour = date("*t", midnight).hour
    if hour ~= 0 then
        midnight = midnight - (hour < 12 and hour or hour - 24) * 3600
    end
    return midnight
end

-- The midnight days whole days before the last one, a day at a time, so a
-- 23 or 25 hour day in between counts as one.
local function DaysBack(now, days)
    local midnight = Midnight(now)
    for _ = 1, days do midnight = Midnight(midnight - 1) end
    return midnight
end

function Range.Bounds(key, now)
    if key == "today" then return Midnight(now), now end
    if key == "yesterday" then
        local midnight = Midnight(now)
        return DaysBack(now, 1), midnight - 1
    end
    if key == "week" then return DaysBack(now, 6), now end
    if key == "month" then return DaysBack(now, 29), now end
    return nil, nil
end

-- The phase in force: the one chosen, or the whole journey for a journey
-- that has not reached the cap.
local function Phase(self)
    return self.capAt and self.phase or "all"
end

function Range:Set(key, now)
    self.key = key
    local from, to = Range.Bounds(key, now or ns.Now())
    local phase = Phase(self)
    -- The second the cap was reached (the kill that gave it, the level up)
    -- is the levelling's; the endgame starts the second after.
    if phase == "lvl" then
        to = to and math.min(to, self.capAt) or self.capAt
    elseif phase == "end" then
        from = from and math.max(from, self.capAt + 1) or self.capAt + 1
    end
    -- Code reading the bounds takes both or neither.
    if from or to then from, to = from or 0, to or math.huge end
    self.from, self.to = from, to
end

function Range:SetCap(t)
    self.capAt = t
end

function Range:SetPhase(key, now)
    self.phase = key
    self:Set(self.key, now)
end

function Range:PhaseLabel()
    local phase = Phase(self)
    for _, p in ipairs(Range.PHASES) do
        if p[1] == phase then return p[2] end
    end
    return "Whole journey"
end

function Range:Key()
    return self.key .. "|" .. Phase(self)
end

-- Works the bounds out again from now, for "today" after midnight.
function Range:Refresh(now)
    self:Set(self.key, now)
end

function Range:IsAll()
    return self.from == nil
end

function Range:Has(t)
    return self.from == nil or (t ~= nil and t >= self.from and t <= self.to)
end

function Range:Label()
    for _, preset in ipairs(Range.PRESETS) do
        if preset[1] == self.key then return preset[2] end
    end
    return "All time"
end

-- The paths with only their points inside the range: copies, never the
-- paths themselves. A path cut at its start loses its jump, as what came
-- before it is not shown. Pieces without times (from before the journey
-- copy) are left out of any range but all time.
function Range:TrimPaths(paths)
    if self:IsAll() then return paths end
    local out = {}
    for _, path in ipairs(paths) do
        local x, y, t = {}, {}, {}
        local first
        for i = 1, #path.x do
            if path.t[i] and self:Has(path.t[i]) then
                first = first or i
                x[#x + 1], y[#y + 1], t[#t + 1] = path.x[i], path.y[i], path.t[i]
            end
        end
        if #x > 0 then
            local copy = {}
            for k, v in pairs(path) do copy[k] = v end
            copy.x, copy.y, copy.t = x, y, t
            if first > 1 then copy.j = nil end
            out[#out + 1] = copy
        end
    end
    return out
end
