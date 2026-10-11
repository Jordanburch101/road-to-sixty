local _, ns = ...

-- Records rare mobs (issue #6) as journal events:
--   rare  name, classification, level   the first kill of a rare: "rare" or
--                                       "rareelite"; level -1 when shown as
--                                       a skull
--
-- ns.char.rares is the rares killed: name -> { count, first kill time },
-- nil until the first.
--
-- The combat log is blocked on Forever, so kills come from the XP message,
-- which names the mob (Journal.lua passes each one to Rares:Killed). Mob
-- names on units are secret values there, so a rare cannot be remembered by
-- name; classification and level can be read. On Forever the XP message
-- comes while the dying target still shows as alive, and the target is
-- cleared at the same moment. So a kill is a rare's when a rare targeted
-- while alive is the target when the XP message comes, and the target is
-- gone (or dead) within KILL_SECONDS after it. An add killed while the rare
-- stays targeted does not clear the target, so it is not taken for the
-- rare. The name comes from the message. A rare that dies while not
-- targeted is missed, but every kill is also saved with its name in the
-- kill list, so rares can still be found there later by name.

local Rares = {}
ns.Rares = Rares

local KILL_SECONDS = 1      -- the target is gone this soon after its XP message

local Log = function(...) ns.Journal:Log(...) end

local RARE = { rare = true, rareelite = true }

-- The rare targeted while alive: { classification, level }.
local engaged
-- A kill message that came while a rare was engaged: { name, GetTime() },
-- waiting for the target to go.
local pending
-- The engaged rare whose target just went with no kill message yet:
-- { engaged, GetTime() }, in case the message comes just after.
local lost

--@debug@
-- /rts rareprobe elites counts elites as rares too, to try the whole path
-- without finding a rare.
local testElites = false
-- The last target looked at and the last kill, and what became of them, for the probe.
local lastLook, lastKill = "none", "none"
-- What happened lately, in order, with times, for the probe: target
-- changes, the target dying, kill messages.
local trace = {}
local function Trace(text)
    trace[#trace + 1] = ("%.1f %s"):format(GetTime(), text)
    if #trace > 12 then table.remove(trace, 1) end
end
--@end-debug@

local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

-- The target's classification, if it is a mob and the client lets it be read.
local function TargetClass()
    if not UnitExists("target") or UnitIsPlayer("target") then return end
    local ok, class = pcall(UnitClassification, "target")
    if ok and not Secret(class) then return class end
end

local function TargetDead()
    local ok, dead = pcall(UnitIsDead, "target")
    return ok and not Secret(dead) and dead == true
end

-- Whether this journey records rares now: not a seeded one, unless testing.
local function Recording()
    local skip = ns.char.seeded
    --@debug@
    -- Testing with elites records into a seeded journey too.
    skip = skip and not testElites
    --@end-debug@
    return not skip
end

-- The engaged rare died with the kill message pending: logs its first kill.
local function Confirm()
    local name, rare = pending[1], engaged
    pending, engaged = nil, nil
    --@debug@
    lastKill = name .. (Recording() and ", logged" or ", not recorded (seeded journey)")
    --@end-debug@
    if not Recording() then return end
    Log("rare", name, rare[1], rare[2])
    ns.char.rares = ns.char.rares or {}
    ns.char.rares[name] = { 1, time() }
end

local function Fresh()
    return pending and engaged and GetTime() - pending[2] <= KILL_SECONDS
end

-- A new target: if the engaged rare's target went just after its kill
-- message, that was its kill. Then engaged if the new target is a rare (or,
-- testing, an elite) still alive.
function Rares:Target()
    local gone = not UnitExists("target") or TargetDead()
    if Fresh() and gone then
        Confirm()
    end
    lost = engaged and not pending and gone and { engaged, GetTime() } or nil
    pending, engaged = nil, nil
    local class = TargetClass()
    local rare = RARE[class]
    --@debug@
    rare = rare or (testElites and class == "elite")
    lastLook = ("%s, %s"):format(tostring(class), not rare and "not a rare" or TargetDead() and "dead already"
        or "engaged")
    Trace(("target %s, dead %s"):format(UnitExists("target") and tostring(class) or "none", tostring(TargetDead())))
    --@end-debug@
    if rare and not TargetDead() then
        local ok, level = pcall(UnitLevel, "target")
        engaged = { class, ok and not Secret(level) and level or nil }
    end
end

-- The target's health changed: a target seen dead just after its kill
-- message also confirms it.
function Rares:Health(unit)
    if unit ~= "target" or not TargetDead() then return end
    --@debug@
    if trace[#trace] and not trace[#trace]:find("target died", 1, true) then
        Trace("target died")
    end
    --@end-debug@
    if Fresh() then Confirm() end
end

-- A kill from the XP message: counts a rare killed before, or holds the
-- name until the engaged rare is seen gone (see the header).
function Rares:Killed(name)
    if not name then return end
    --@debug@
    Trace(("kill %s (target %s, dead %s, engaged %s)"):format(name, UnitExists("target") and "yes" or "none",
        tostring(TargetDead()), engaged and "yes" or "no"))
    --@end-debug@
    local known = ns.char.rares and ns.char.rares[name]
    if known then
        --@debug@
        lastKill = name .. ", counted again"
        --@end-debug@
        if Recording() then known[1] = known[1] + 1 end
        return
    end
    -- The rare's target went just before its message.
    if not engaged and lost and GetTime() - lost[2] <= KILL_SECONDS then
        engaged, pending, lost = lost[1], { name, GetTime() }, nil
        Confirm()
        return
    end
    --@debug@
    lastKill = name .. (engaged and ", waiting for the target to go" or ", not a rare target")
    --@end-debug@
    if engaged then
        pending = { name, GetTime() }
        if TargetDead() then Confirm() end
    end
end

-- Showing them ------------------------------------------------------------------

local CLASSES = { rare = "Rare", rareelite = "Rare elite", elite = "Elite (test)" }

-- How to show a rare event: title and detail (what kind of entry, to go
-- before the place).
function Rares:Describe(e)
    local level = e[8]
    local detail = CLASSES[e[7]] or "Rare"
    if level then
        detail = detail .. (level < 0 and ", level ??" or (", level " .. level))
    end
    return "Killed " .. (e[6] or "?"), detail
end

-- Rares killed in the journey shown: { name, count, first time }, first killed first.
function Rares:List()
    local list = {}
    for name, r in pairs(ns.view.rares or {}) do
        list[#list + 1] = { name, r[1], r[2] }
    end
    table.sort(list, function(a, b) return a[3] < b[3] end)
    return list
end

-- Listening ---------------------------------------------------------------------

ns.On("PLAYER_TARGET_CHANGED", function() Rares:Target() end)
ns.On("UNIT_HEALTH", function(unit) Rares:Health(unit) end)

--@debug@
-- /rts rareprobe: what the client tells about the target, and what the
-- recorder made of the last target and kill. /rts rareprobe elites toggles
-- test mode.
ns.Command("rareprobe", "check rare mob detection; elites to count elites as rares (developer)", function(arg)
    local P = ns.Print
    if arg == "elites" then
        testElites = not testElites
        P("Elites count as rares: " .. (testElites and "on (target one, then kill it; it is recorded)" or "off") .. ".")
        return
    end
    if UnitExists("target") then
        local ok, class = pcall(UnitClassification, "target")
        local okName, name = pcall(UnitName, "target")
        P(("Target: name %s, classification %s, level %s, dead %s."):format(
            okName and (Secret(name) and "(secret)" or tostring(name)) or "error",
            ok and (Secret(class) and "(secret)" or tostring(class)) or "error",
            tostring(UnitLevel("target")), tostring(TargetDead())))
        -- Other ways the name might be read, and whether health can be (to
        -- tell a death from Esc when there is no XP message).
        local function Show(label, fn, ...)
            local okCall, value = pcall(fn, ...)
            return ("%s %s"):format(label, not okCall and "error" or Secret(value) and "(secret)" or tostring(value))
        end
        local parts = {
            Show("UnitNameUnmodified", UnitNameUnmodified or function() return "missing" end, "target"),
            Show("GetUnitName", _G["GetUnitName"] or function() return "missing" end, "target", false),
            Show("UnitHealth", UnitHealth, "target"),
            Show("UnitHealthMax", UnitHealthMax, "target"),
        }
        if C_TooltipInfo and C_TooltipInfo.GetUnit then
            parts[#parts + 1] = Show("tooltip line 1", function()
                local data = C_TooltipInfo.GetUnit("target")
                local line = data and data.lines and data.lines[1]
                return line and line.leftText
            end)
        end
        local frame = _G["TargetFrame"]
        local frameName = frame and (frame.name or (frame.TargetFrameContent
            and frame.TargetFrameContent.TargetFrameContentMain
            and frame.TargetFrameContent.TargetFrameContentMain.Name))
        if frameName and frameName.GetText then
            parts[#parts + 1] = Show("target frame text", frameName.GetText, frameName)
        end
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:SetUnit("target")
        local left = _G["GameTooltipTextLeft1"]
        if left then parts[#parts + 1] = Show("GameTooltip line 1", left.GetText, left) end
        GameTooltip:Hide()
        P(table.concat(parts, ", ") .. ".")
    else
        P("No target.")
    end
    P(("Engaged: %s. Test mode %s.%s"):format(
        engaged and ("%s level %s%s"):format(engaged[1], tostring(engaged[2]),
            engaged[3] and (", died %ds ago"):format(math.floor(GetTime() - engaged[3])) or "") or "none",
        testElites and "on" or "off", ns.char.seeded and not testElites
            and " This journey is seeded: nothing is recorded outside test mode." or ""))
    P("Last target: " .. lastLook .. ". Last kill: " .. lastKill .. ".")
    for _, line in ipairs(trace) do P("  " .. line) end
end)
--@end-debug@
