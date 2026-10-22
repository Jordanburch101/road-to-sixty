local _, ns = ...

-- The date range the journey map shows (issue #66): all time, or a part of
-- the journey such as today or the last seven days. Map.lua builds its path,
-- replay and replay bar from the paths inside it and shows only the markers
-- in it, History lists only what is in it, and the gear screen opens on it.
-- It lasts the session; nothing saved changes, and paths are copied when
-- cut, never changed in place.
--
--   Range:Set(key)          one of the PRESETS keys; the bounds are worked
--                           out from now (Refresh does it again)
--   Range:Has(t)            whether time t is inside
--   Range:IsAll()           true for all time
--   Range:TrimPaths(paths)  the paths cut to the range (Recorder.lua's format)
--
-- Days start at the player's own midnight (times are Unix seconds, ns.Now).
-- No game calls but date, so it is tested offline (tests/range_test.lua).

local Range = { key = "all" }
ns.Range = Range

Range.PRESETS = {
    { "all", "All time" }, { "today", "Today" }, { "yesterday", "Yesterday" },
    { "week", "Last 7 days" }, { "month", "Last 30 days" },
}

local DAY = 86400

-- The last midnight at or before now, by the player's clock.
local function Midnight(now)
    local d = date("*t", now)
    return now - (d.hour * 3600 + d.min * 60 + d.sec)
end

-- from and to for a preset at time now; nil for all time.
function Range.Bounds(key, now)
    if key == "today" then return Midnight(now), now end
    if key == "yesterday" then
        local midnight = Midnight(now)
        return midnight - DAY, midnight - 1
    end
    if key == "week" then return now - 7 * DAY, now end
    if key == "month" then return now - 30 * DAY, now end
    return nil, nil
end

function Range:Set(key, now)
    self.key = key
    self.from, self.to = Range.Bounds(key, now or ns.Now())
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
