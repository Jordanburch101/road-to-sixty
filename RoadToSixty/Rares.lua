local _, ns = ...

-- Records rare mobs (issue #6) as journal events:
--   rare  name, classification, level, npcID, how   the first kill of a
--         rare: classification "rare" or "rareelite"; level -1 when shown as
--         a skull; how it was known: "x" its XP message, "l" its loot, "c"
--         its corpse clicked. name or npcID is nil when it could not be
--         read (a kill with no XP inside an instance has neither until it
--         is looted).
--
-- ns.char.rares is the rares killed: key -> { count, first kill time, name,
-- npcID, classification }, key the NPC ID when known, else the name, else
-- the classification and time; nil until the first.
--
-- What the client lets an addon read on Forever decides how (see CLAUDE.md):
-- - In the open world a mob's name and GUID can be read, even in combat.
--   Every rare targeted, moused over or with a nameplate is remembered by
--   GUID. A kill message naming it, its loot (loot sources are GUIDs), or
--   its corpse clicked records it, so kills with no XP count too.
-- - Inside instances names and GUIDs are secret; classification and level
--   are not. A kill there is a rare's when a rare targeted while alive is
--   the target when the XP message comes, and the target is gone (or dead)
--   within KILL_SECONDS after it, the name coming from the message; the
--   message comes while the dying target still shows alive, and the target
--   is cleared at once. With no XP, a dead rare corpse clicked records it
--   without a name, and looting it adds the NPC ID.
-- A target the player was not tapped on (someone else's kill) is not one.

local Rares = {}
ns.Rares = Rares

local KILL_SECONDS = 1          -- the target is gone this soon after its XP message
local SEEN_SECONDS = 30 * 60    -- how long a rare seen counts
local SAME_CORPSE = 10 * 60     -- a rare corpse inside an instance with the same classification
                                -- and level this soon after one recorded is the same one

local Log = function(...) ns.Journal:Log(...) end

local RARE = { rare = true, rareelite = true }

local seen = {}     -- open world: GUID -> unit info (see Read) of a rare seen alive, with t = GetTime()
local done = {}     -- GUID -> true once its kill is recorded this session
local recent = {}   -- inside instances: { classification, level, GetTime() } of kills recorded
-- The rare targeted while alive (unit info), and a kill message waiting for
-- its target to go: { name, GetTime() }. lost is the engaged rare whose
-- target went with no message yet: { info, GetTime() }.
local engaged, pending, lost

--@debug@
-- /rts rareprobe elites counts elites as rares too, to try the whole path
-- without finding a rare; /rts rareprobe all counts normal mobs as well.
local testElites, testAll = false, false
local lootWatch = false     -- /rts rareprobe loot: print where loot came from
-- The last target looked at and the last kill, and what became of them, for the probe.
local lastLook, lastKill = "none", "none"
-- What happened lately, in order, with times, for the probe: target
-- changes, the target dying, kill messages.
local trace = {}
local function Trace(text)
    trace[#trace + 1] = ("%.1f %s"):format(GetTime(), text)
    if #trace > 12 then table.remove(trace, 1) end
end
-- /rts rareprobe match: each time an elite or rare target went (cleared or
-- seen dead), whatever the test mode, to match against the kill list:
-- { time(), classification, level, GUID or false }. special is the one
-- targeted now, alive.
local moments, special = {}, nil
--@end-debug@

local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

-- A value from fn(...), or nil when it errors or is secret.
local function Read(fn, ...)
    if not fn then return end
    local ok, value = pcall(fn, ...)
    if ok and not Secret(value) then return value end
end

local function NpcID(guid)
    local kind, id = tostring(guid or ""):match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)")
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

-- What can be read of a mob unit: { class, level, guid, name, npc, dead,
-- tapDenied }, each nil when secret; nil for no unit or a player.
local function UnitInfo(unit)
    if not UnitExists(unit) or Read(UnitIsPlayer, unit) then return end
    local guid = Read(UnitGUID, unit)
    return {
        class = Read(UnitClassification, unit), level = Read(UnitLevel, unit),
        guid = guid, name = Read(UnitName, unit), npc = NpcID(guid),
        dead = Read(UnitIsDead, unit) == true, tapDenied = Read(UnitIsTapDenied, unit) == true,
    }
end

local function IsRare(info)
    if not info then return false end
    local rare = RARE[info.class] or false
    --@debug@
    rare = rare or (testElites and info.class == "elite") or (testAll and info.class == "normal")
    --@end-debug@
    return rare
end

-- Whether this journey records rares now: not a seeded one, unless testing.
local function Recording()
    local skip = ns.char.seeded
    --@debug@
    -- Testing with elites records into a seeded journey too.
    skip = skip and not (testElites or testAll)
    --@end-debug@
    return not skip
end

-- The rares entry with this name, for a kill message of a rare killed before.
local function KnownByName(name)
    for _, r in pairs(ns.char.rares or {}) do
        if r[3] == name then return r end
    end
end

-- Records a rare's kill: logs the first of each, counts the rest. info is
-- its unit info, name the best name known for it, how as in the header.
local function Record(info, name, how)
    if info.guid then
        if done[info.guid] then return end
        done[info.guid] = true
    else
        recent[#recent + 1] = { info.class, info.level, GetTime() }
    end
    name = name or info.name
    --@debug@
    lastKill = ("%s, %s (%s)"):format(tostring(name), Recording() and "recorded" or "not recorded (seeded journey)", how)
    --@end-debug@
    if not Recording() then return end
    local rares = ns.char.rares or {}
    ns.char.rares = rares
    -- One with neither (no XP inside an instance) is a kill of its own.
    local key = info.npc or name or ("%s %d"):format(tostring(info.class), time())
    local known = rares[key]
    if known then
        known[1] = known[1] + 1
        known[3] = known[3] or name
        return
    end
    Log("rare", name, info.class, info.level, info.npc, how)
    rares[key] = { 1, time(), name, info.npc, info.class }
end

-- Inside an instance (no GUID): whether a rare corpse is one recorded lately.
local function RecentCorpse(info)
    for i = #recent, 1, -1 do
        local r = recent[i]
        if GetTime() - r[3] > SAME_CORPSE then break end
        if r[1] == info.class and r[2] == info.level then return true end
    end
    return false
end

-- Remembers a rare seen alive in the open world, by GUID.
function Rares:Look(unit)
    local info = UnitInfo(unit)
    if info and info.guid and not info.dead and IsRare(info) then
        info.t = GetTime()
        seen[info.guid] = info
    end
end

-- The rare remembered by GUID, if seen lately.
local function Seen(guid)
    local s = guid and seen[guid]
    if s and GetTime() - s.t <= SEEN_SECONDS then return s end
end

local function Fresh()
    return pending and engaged and GetTime() - pending[2] <= KILL_SECONDS
end

local function Confirm()
    local name, info = pending[1], engaged
    pending, engaged = nil, nil
    Record(info, name, "x")
end

-- A new target: the engaged rare gone just after its kill message was its
-- kill; a rare corpse clicked is one (if not someone else's); a rare alive
-- is engaged (and, in the open world, remembered).
function Rares:Target()
    local info = UnitInfo("target")
    local gone = not info or info.dead
    if Fresh() and gone then
        Confirm()
    end
    lost = engaged and not pending and gone and { engaged, GetTime() } or nil
    pending, engaged = nil, nil
    local rare = info and IsRare(info) and info or nil
    --@debug@
    local what = "not a rare"
    if rare then what = rare.dead and "dead" or "engaged" end
    lastLook = ("%s, %s"):format(tostring(info and info.class), what)
    Trace(("target %s, dead %s"):format(info and tostring(info.class) or "none", tostring(info and info.dead)))
    if special and gone then
        moments[#moments + 1] = { time(), special[1], special[2], special[3] }
        if #moments > 10 then table.remove(moments, 1) end
    end
    special = nil
    if info and (info.class == "elite" or RARE[info.class]) and not info.dead then
        special = { info.class, info.level, info.guid or false }
    end
    --@end-debug@
    if not rare then return end
    if not rare.dead then
        engaged = rare
        self:Look("target")
    elseif not rare.tapDenied and (rare.guid or not RecentCorpse(rare)) then
        Record(Seen(rare.guid) or rare, nil, "c")
    end
end

-- The target's health changed: a target seen dead just after its kill
-- message also confirms it.
function Rares:Health(unit)
    if unit ~= "target" or not Read(UnitIsDead, "target") then return end
    --@debug@
    if trace[#trace] and not trace[#trace]:find("target died", 1, true) then
        Trace("target died")
    end
    --@end-debug@
    if Fresh() then Confirm() end
end

-- A kill from the XP message (Journal.lua passes each one here).
function Rares:Killed(name)
    if not name then return end
    --@debug@
    Trace(("kill %s (target %s, engaged %s)"):format(name, UnitExists("target") and "yes" or "none",
        engaged and "yes" or "no"))
    lastKill = name .. ", not a rare"
    --@end-debug@
    -- Open world: a rare seen alive with this name.
    for guid, s in pairs(seen) do
        if s.name == name and not done[guid] and Seen(guid) then
            Record(s, name, "x")
            if engaged and engaged.guid == guid then engaged = nil end
            return
        end
    end
    -- The engaged rare's target went just before its message.
    if not engaged and lost and GetTime() - lost[2] <= KILL_SECONDS then
        engaged, pending, lost = lost[1], { name, GetTime() }, nil
        Confirm()
        return
    end
    if engaged then
        --@debug@
        lastKill = name .. ", waiting for the target to go"
        --@end-debug@
        pending = { name, GetTime() }
        if Read(UnitIsDead, "target") then Confirm() end
        return
    end
    -- A rare killed before, met again unseen: counted.
    local known = KnownByName(name)
    if known and Recording() then known[1] = known[1] + 1 end
end

-- Loot: its sources are GUIDs, readable even inside instances. A rare seen
-- alive is recorded (a kill with no XP). Inside an instance, looting a rare
-- corpse targeted gives its NPC ID to the kill recorded without one.
function Rares:Looted()
    local npcs, count = {}, 0
    for slot = 1, (Read(GetNumLootItems) or 0) do
        local sources = { pcall(GetLootSourceInfo, slot) }
        if table.remove(sources, 1) then
            for i = 1, #sources, 2 do
                local guid = not Secret(sources[i]) and sources[i] or nil
                local s = Seen(guid)
                if s and not done[guid] then Record(s, s.name, "l") end
                local npc = NpcID(guid)
                if npc and not npcs[npc] then
                    npcs[npc] = true
                    count = count + 1
                end
            end
        end
    end
    local target = UnitInfo("target")
    if count ~= 1 or not (target and target.dead and IsRare(target)) or target.guid then return end
    local npc = next(npcs)
    local events = ns.char.events
    for i = #events, 1, -1 do
        local e = events[i]
        if e[1] < time() - SAME_CORPSE then break end
        if e[2] == "rare" and not e[9] and e[7] == target.class and e[8] == target.level then
            e[9] = npc
            return
        end
    end
end

-- Showing them ------------------------------------------------------------------

local CLASSES = { rare = "Rare", rareelite = "Rare elite", elite = "Elite (test)", normal = "Normal (test)" }

-- How to show a rare event: title and detail (what kind of entry, to go
-- before the place).
function Rares:Describe(e)
    local class, level = CLASSES[e[7]] or "Rare", e[8]
    local detail = class
    if level then
        detail = detail .. (level < 0 and ", level ??" or (", level " .. level))
    end
    return "Killed " .. (e[6] or ("a " .. class:lower())), detail
end

-- Rares killed in the journey shown: { name, count, first time }, first killed first.
function Rares:List()
    local list = {}
    for _, r in pairs(ns.view.rares or {}) do
        list[#list + 1] = { r[3] or ("a " .. (CLASSES[r[5]] or "Rare"):lower()), r[1], r[2] }
    end
    table.sort(list, function(a, b) return a[3] < b[3] end)
    return list
end

-- Listening ---------------------------------------------------------------------

ns.On("PLAYER_TARGET_CHANGED", function() Rares:Target() end)
ns.On("UNIT_HEALTH", function(unit) Rares:Health(unit) end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() Rares:Look("mouseover") end)
ns.On("NAME_PLATE_UNIT_ADDED", function(unit) Rares:Look(unit) end)
ns.On("LOOT_OPENED", function() Rares:Looted() end)

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
    if arg == "all" then
        testAll, testElites = not testAll, not testAll
        P("Normal mobs and elites count as rares: " .. (testAll and "on (every kill is recorded as one; "
            .. "turn it off after a few)" or "off") .. ".")
        return
    end
    if arg == "match" then
        -- Each elite or rare target that went, with the kills recorded within
        -- MATCH seconds of it: the name the kill list would give it.
        local MATCH = 2
        if #moments == 0 then
            P("No elite or rare target has gone yet. Target one, kill it, then run this again.")
            return
        end
        local kills = ns.Journal:Kills()
        for _, m in ipairs(moments) do
            local near = {}
            for k = #kills, 1, -1 do
                local kill = kills[k]
                if kill.t < m[1] - MATCH then break end
                if kill.t <= m[1] + MATCH then
                    near[#near + 1] = ("%s (%+ds, %d xp)"):format(tostring(kill.name), kill.t - m[1], kill.xp)
                end
            end
            local npc = m[4] and m[4]:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)")
            P(("%s: %s level %s, NPC %s -> %s"):format(date("%H:%M:%S", m[1]), m[2], tostring(m[3]),
                npc or "(secret)", #near > 0 and table.concat(near, ", ") or "no kill recorded (no XP?)"))
        end
        return
    end
    if arg == "loot" then
        lootWatch = not lootWatch
        P("Loot sources: " .. (lootWatch and "on (open a corpse's loot to see them)" or "off") .. ".")
        return
    end
    if UnitExists("target") then
        local ok, class = pcall(UnitClassification, "target")
        local okName, name = pcall(UnitName, "target")
        P(("Target: name %s, classification %s, level %s, dead %s."):format(
            okName and (Secret(name) and "(secret)" or tostring(name)) or "error",
            ok and (Secret(class) and "(secret)" or tostring(class)) or "error",
            tostring(UnitLevel("target")), tostring(Read(UnitIsDead, "target"))))
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
        local okGuid, guid = pcall(UnitGUID, "target")
        local npc = okGuid and not Secret(guid) and tostring(guid):match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)")
        P(("GUID %s, NPC ID %s."):format(not okGuid and "error" or Secret(guid) and "(secret)" or tostring(guid),
            tostring(npc)))
    else
        P("No target.")
    end
    -- Where: secret values may depend on the place (an instance, Zephras Isle) or combat.
    local inInstance, instanceType = IsInInstance()
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    local c = ns.GetWorldPosition and ns.GetWorldPosition()
    P(("Where: %s (map %s, continent %s), instance %s (%s), in combat %s."):format(info and info.name or "?",
        tostring(mapID), tostring(c), tostring(inInstance), tostring(instanceType),
        tostring(UnitAffectingCombat("player"))))
    local remembered = 0
    for _ in pairs(seen) do remembered = remembered + 1 end
    P(("Engaged: %s. Rares remembered: %d. Test mode %s.%s"):format(
        engaged and ("%s level %s, %s"):format(tostring(engaged.class), tostring(engaged.level),
            engaged.name or "name secret") or "none", remembered,
        testAll and "all" or testElites and "elites" or "off", ns.char.seeded and not testElites
            and " This journey is seeded: nothing is recorded outside test mode." or ""))
    P("Last target: " .. lastLook .. ". Last kill: " .. lastKill .. ".")
    for _, line in ipairs(trace) do P("  " .. line) end
end)

-- /rts rareprobe loot: when a loot window opens, what each slot says about
-- where it came from (a corpse's GUID would confirm which mob died).
ns.On("LOOT_OPENED", function()
    if not lootWatch then return end
    local count = GetNumLootItems and GetNumLootItems() or 0
    ns.Print(("Loot window: %d slot(s)."):format(count))
    for slot = 1, count do
        local sources = { pcall(GetLootSourceInfo, slot) }
        local okCall = table.remove(sources, 1)
        local shown = {}
        for i = 1, #sources, 2 do
            local guid = sources[i]
            local npc = not Secret(guid) and tostring(guid):match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)")
            shown[#shown + 1] = ("%s (NPC %s) x%s"):format(Secret(guid) and "(secret)" or tostring(guid),
                tostring(npc), Secret(sources[i + 1]) and "(secret)" or tostring(sources[i + 1]))
        end
        ns.Print(("  slot %d: %s"):format(slot, not okCall and "error" or #shown > 0 and table.concat(shown, ", ")
            or "no source"))
    end
end)
--@end-debug@
