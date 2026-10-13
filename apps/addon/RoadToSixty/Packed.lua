local _, ns = ...

-- The packed formats the journey is saved in, as plain functions with no
-- game calls, so the recorder, the journal, the merge and the sync server
-- read and write them the same way.
--
-- Kills: { d = "dt,xp,n;...", last = time of the last kill, names = { mob
-- name, ... } }. dt is seconds since the kill before, the first kill's dt
-- is its full time, and n indexes names. dt can be negative: kills saved
-- just before and after the switch to the realm's clock (#35) can step back.
--
-- Path segments: { t, x, y, d = "dt,dx,dy;..." }, each step a difference
-- from the point before. Recorder.lua's header has the whole segment.

local Packed = {}
ns.Packed = Packed

-- Appends each kill packed in d to list as { t, xp, name }, counting from
-- time t, and returns the time of the last one.
function Packed.DecodeKills(d, names, t, list)
    for dt, xp, n in d:gmatch("(-?%d+),(%d+),(%d+);") do
        t = t + tonumber(dt)
        list[#list + 1] = { t = t, xp = tonumber(xp), name = names[tonumber(n)] }
    end
    return t
end

-- A new kills table holding list ({ t, xp, name }, oldest first). A kill
-- whose name was lost packs as "?", since a name can't be a nil key.
function Packed.PackKills(list)
    local names, index, parts, last = {}, {}, {}, 0
    for i, kill in ipairs(list) do
        local name = kill.name or "?"
        local n = index[name]
        if not n then
            n = #names + 1
            names[n], index[name] = name, n
        end
        parts[i] = ("%d,%d,%d;"):format(kill.t - last, kill.xp, n)
        last = kill.t
    end
    return { d = table.concat(parts), last = last, names = names }
end

-- The points of a segment as three lists: times, x and y. d is its packed
-- steps, seg.d unless given (the recorder passes the open segment's buffer).
function Packed.DecodePath(seg, d)
    local t, x, y = seg.t, seg.x, seg.y
    local ts, xs, ys = { t }, { x }, { y }
    for dt, dx, dy in (d or seg.d or ""):gmatch("(-?%d+),(-?%d+),(-?%d+)") do
        t, x, y = t + tonumber(dt), x + tonumber(dx), y + tonumber(dy)
        ts[#ts + 1], xs[#xs + 1], ys[#ys + 1] = t, x, y
    end
    return ts, xs, ys
end
