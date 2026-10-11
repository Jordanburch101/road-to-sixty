local _, ns = ...

-- A summary in chat of the level just finished, at each level up (issue
-- #28), unless turned off (ns.db.levelChat):
--
--   Road to Sixty: Level 21 reached in Westfall [Open map]
--     Level 20 took 1h 12m, 6m faster than level 19
--     84 kills · 9 quests · 1 death · 4,210 yd walked · +3g 12s
--
-- The numbers are the new level's snapshot (Journal.lua) minus the one
-- before. Money is the change in the balance, everything earned minus
-- everything spent, so it can be negative. It prints once the time played
-- answer has come, so the time can be in it, or after WAIT seconds without
-- it. Parts that are not known are left out: the level before was only
-- partly tracked, or its time played never came. [Open map] is a chat link
-- that opens the journey map at the level up.

local LevelChat = {}
ns.LevelChat = LevelChat

local WAIT = 5              -- seconds to wait for the time played answer
local SAME = 60             -- seconds within which two levels took about as long
local PREFIX = "|cff33ff99Road to Sixty|r: "
local LINK = "|Haddon:RoadToSixty:level:%d|h|cff71d5ff[Open map]|r|h"

local pending   -- { level, zone } of a level up waiting for its time played

-- What is known about reaching level: { level, took, diff, kills, quests,
-- deaths, walked, money }, each nil when not known. took is the seconds the
-- level before took, diff how much faster (positive) or slower than the
-- one before that.
function LevelChat:Facts(level)
    local levels = ns.char.levels
    local now, before = levels[level], levels[level - 1]
    local f = { level = level }
    if not (now and before) or before.partial then return f end
    if now.played and before.played then
        f.took = now.played - before.played
        local earlier = levels[level - 2]
        if earlier and not earlier.partial and earlier.played then
            f.diff = (before.played - earlier.played) - f.took
        end
    end
    local function Delta(key)
        if now[key] and before[key] then return now[key] - before[key] end
    end
    f.kills = ns.killsTracked and Delta("kills") or nil
    f.quests, f.deaths, f.walked, f.money = Delta("quests"), Delta("deaths"), Delta("distance"), Delta("money")
    return f
end

local function Color(hex, text)
    return "|cff" .. hex .. text .. "|r"
end

-- Money as coloured text: "+6s 80c".
local function MoneyText(copper)
    local c = math.abs(copper)
    local g, si, co = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = Color("ffd700", g .. "g") end
    if si > 0 or g > 0 then parts[#parts + 1] = Color("c7c7cf", si .. "s") end
    parts[#parts + 1] = Color("eda55f", co .. "c")
    return (copper < 0 and "-" or "+") .. table.concat(parts, " ")
end

local GREY, WHITE, GOLD, GREEN, RED = "a0a0a0", "ffffff", "ffd100", "40ff40", "ff5050"

-- The lines summing up reaching level, zone the place's name if known: the
-- level in gold, the place and numbers in white, the words in grey, the
-- pace green when faster and red when slower, deaths red. Picked from
-- candidates on a screenshot.
function LevelChat:Lines(level, zone)
    local f = self:Facts(level)
    local lines = { ("%s %s%s %s"):format(Color(GOLD, "Level " .. level), Color(GREY, "reached"),
        zone and (Color(GREY, " in ") .. Color(WHITE, zone)) or "", LINK:format(level)) }
    if f.took then
        local line = Color(GREY, ("Level %d took "):format(level - 1)) .. Color(WHITE, ns.FormatDuration(f.took))
        if f.diff then
            if math.abs(f.diff) < SAME then
                line = line .. Color(GREY, (", about as long as level %d"):format(level - 2))
            else
                line = line .. Color(GREY, ", ") .. Color(f.diff > 0 and GREEN or RED, ("%s %s"):format(
                    ns.FormatDuration(math.abs(f.diff)), f.diff > 0 and "faster" or "slower"))
                    .. Color(GREY, (" than level %d"):format(level - 2))
            end
        end
        lines[#lines + 1] = line
    end
    local parts = {}
    local function Part(n, one, many, hex)
        if n then
            parts[#parts + 1] = Color(hex or WHITE, ns.Commas(n)) .. Color(GREY, " " .. (n == 1 and one or many))
        end
    end
    Part(f.kills, "kill", "kills")
    Part(f.quests, "quest", "quests")
    Part(f.deaths, "death", "deaths", f.deaths and f.deaths > 0 and RED or nil)
    Part(f.walked, "yd walked", "yd walked")
    if f.money then parts[#parts + 1] = MoneyText(f.money) end
    if #parts > 0 then lines[#lines + 1] = table.concat(parts, Color(GREY, " · ")) end
    return lines
end

function LevelChat:Print(level, zone)
    for i, line in ipairs(self:Lines(level, zone)) do
        print(i == 1 and (PREFIX .. line) or ("    " .. line))
    end
end

local function Flush()
    if not pending then return end
    local level, zone = pending[1], pending[2]
    pending = nil
    LevelChat:Print(level, zone)
end

-- The name of the place the player is in.
local function ZoneName()
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and info.name
end

-- Journal.lua's handlers run first (it loads first), so the snapshot is
-- taken, and its time played saved, before these.
ns.On("PLAYER_LEVEL_UP", function(level)
    if not ns.db.levelChat or ns.char.seeded then return end
    pending = { level, ZoneName() }
    C_Timer.After(WAIT, function() ns.SafeCall(Flush) end)
end)

ns.On("TIME_PLAYED_MSG", function() Flush() end)

-- [Open map]: this character's journey, at that level up.
local function OpenAt(level)
    local found
    for _, e in ipairs(ns.char.events) do
        if e[2] == "lvl" and e[6] == level then found = e end
    end
    if ns.viewEntry then
        ns.Map:ShowJourney(nil)
    end
    ns.Map:Open()
    if found then
        ns.Map:JumpTo(found[1], found[3], found[4], found[5])
    end
end

hooksecurefunc("SetItemRef", function(link)
    local level = type(link) == "string" and link:match("^addon:RoadToSixty:level:(%d+)")
    if level then
        ns.SafeCall(OpenAt, tonumber(level))
    end
end)

--@debug@
-- /rts levelchat [level]: prints the summary of a level up already
-- recorded (the last one by default), to try it without levelling.
ns.Command("levelchat", "print the level up summary for a level (developer)", function(arg)
    local level = tonumber(arg)
    if not level then
        for l in pairs(ns.char.levels) do
            if not level or l > level then level = l end
        end
    end
    if not level then
        ns.Print("No level ups recorded yet.")
        return
    end
    LevelChat:Print(level, ZoneName())
end)
--@end-debug@
