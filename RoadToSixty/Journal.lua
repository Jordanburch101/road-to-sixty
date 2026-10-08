local addonName, ns = ...

-- Records what happened along the path, plus a stats snapshot at each level
-- (ns.char.levels[level], including the equipped gear: slot -> item ID, and
-- gearLater = true when it was taken at a later login, not at the level up).
--
-- Each event: { time, kind, continentID, x, y, ... }. Kinds and extra fields:
--   on   level                     session start
--   off                            session end
--   lvl  level                     level reached
--   die                            death
--   qa   questID                   quest accepted
--   qd   questID, xp, money, title quest turned in; title from 1.1 on, when
--                                  the client knows it
--   zone uiMapID                   entered a new zone
--   in   instanceID, name, type    entered a dungeon, raid or battleground
--   out  instanceID, summary       left it; summary of the run, see EndRun
--   loot itemLink, quality, instanceID   looted an item of green quality or
--                                  better; instanceID if inside one
--   eq   slot, itemID              equipment changed; itemID 0 when emptied
--   prof, rec                      professions and recipes, see Crafts.lua
--   gj, gl, gr                     guild joined, left, rank changed, see Guilds.lua
-- Events inside instances use the last outdoor position.

local Journal = {}
ns.Journal = Journal

local pendingPlayedLevel

function Journal:Log(kind, ...)
    local c, x, y = ns.Recorder:Position()
    table.insert(ns.char.events, { time(), kind, c or -1, x or 0, y or 0, ... })
end

-- Equipment slots, in character sheet order, by the names the client uses.
ns.GEAR_SLOTS = {
    "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot",
    "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot",
    "Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

-- What the player is wearing: inventory slot ID -> item ID. Slots this client
-- does not have are skipped.
function ns.CaptureGear()
    local gear = {}
    for _, name in ipairs(ns.GEAR_SLOTS) do
        local ok, slot = pcall(GetInventorySlotInfo, name)
        local itemID = ok and slot and GetInventoryItemID("player", slot)
        if itemID then
            gear[slot] = itemID
        end
    end
    return gear
end

-- Logs real equipment changes, so a replay can show gear changing between
-- level ups. ns.char.gear is the gear last seen (set at login), so swapping
-- an item for the same one logs nothing.
ns.On("PLAYER_EQUIPMENT_CHANGED", function(slot)
    local gear = ns.char.gear
    if not gear or type(slot) ~= "number" or slot < 1 or slot > 19 then return end
    local itemID = GetInventoryItemID("player", slot) or 0
    if (gear[slot] or 0) ~= itemID then
        gear[slot] = itemID ~= 0 and itemID or nil
        Journal:Log("eq", slot, itemID)
    end
end)

local function Snapshot(level, partial)
    local totals = ns.char.totals
    ns.char.levels[level] = {
        gear = ns.CaptureGear(),
        t = time(),
        money = GetMoney(),
        kills = totals.kills,
        killXP = totals.killXP,
        questXP = totals.questXP,
        deaths = totals.deaths,
        quests = totals.quests,
        instances = totals.instances,
        distance = math.floor(totals.distance),
        flown = math.floor(totals.flown),
        skills = ns.char.skills and CopyTable(ns.char.skills),   -- profession -> { rank, max }
        partial = partial or nil,
    }
end

local function CheckZone()
    if IsInInstance() then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID and mapID ~= ns.char.lastZone then
        ns.char.lastZone = mapID
        Journal:Log("zone", mapID)
    end
end

-- A run is one visit to an instance. ns.char.run holds the totals at entry,
-- so leaving can log what happened inside. It is saved, so a run survives a
-- logout inside the instance.
local function StartRun(name)
    local t = ns.char.totals
    ns.char.run = {
        t = time(), name = name, level = UnitLevel("player"),
        kills = t.kills, xp = t.killXP + t.questXP, deaths = t.deaths, money = GetMoney(),
        items = {},
    }
end

-- Logs leaving the instance with a summary: { name, duration (seconds),
-- kills, xp, deaths, money (copper), levels, items = { itemLink, ... } }.
local function EndRun(instanceID)
    local run, t = ns.char.run, ns.char.totals
    local summary
    if run then
        summary = {
            name = run.name,
            duration = time() - run.t,
            kills = t.kills - run.kills,
            xp = t.killXP + t.questXP - run.xp,
            deaths = t.deaths - run.deaths,
            money = GetMoney() - run.money,
            levels = UnitLevel("player") - run.level,
            items = run.items,
        }
    end
    Journal:Log("out", instanceID, summary)
    ns.char.run = nil
end

local function CheckInstance()
    local char = ns.char
    local inInstance, instanceType = IsInInstance()
    if inInstance then
        local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
        if char.instance ~= instanceID then
            if char.instance then
                EndRun(char.instance)
            end
            char.instance = instanceID
            char.totals.instances = char.totals.instances + 1
            Journal:Log("in", instanceID, name, instanceType)
            StartRun(name)
        end
    elseif char.instance then
        EndRun(char.instance)
        char.instance = nil
    end
end

ns.On("PLAYER_LOGIN", function()
    local level = UnitLevel("player")
    local snapshot = ns.char.levels[level]
    if not snapshot then
        -- Level 1 is a clean start; anything else means tracking began mid-level.
        Snapshot(level, level > 1)
    elseif not snapshot.gear then
        -- Reached before gear was recorded: today's gear is the best guess.
        snapshot.gear = ns.CaptureGear()
        snapshot.gearLater = true
    end
    ns.char.gear = ns.CaptureGear()
    Journal:Log("on", level)
end)

ns.On("PLAYER_LOGOUT", function()
    Journal:Log("off")
end)

ns.On("PLAYER_ENTERING_WORLD", function()
    CheckInstance()
    CheckZone()
end)

ns.On("ZONE_CHANGED_NEW_AREA", CheckZone)

ns.On("PLAYER_LEVEL_UP", function(level)
    Snapshot(level)
    Journal:Log("lvl", level)
    pendingPlayedLevel = level
    RequestTimePlayed()
end)

ns.On("TIME_PLAYED_MSG", function(total)
    ns.char.played = total
    local snapshot = pendingPlayedLevel and ns.char.levels[pendingPlayedLevel]
    if snapshot then
        snapshot.played = total
    end
    pendingPlayedLevel = nil
end)

ns.On("PLAYER_DEAD", function()
    ns.char.totals.deaths = ns.char.totals.deaths + 1
    Journal:Log("die")
end)

-- Quest names seen this session, in case the client has forgotten one by
-- the time it is turned in.
local questTitles = {}

local function QuestTitle(questID)
    local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
    if ok and title and title ~= "" then
        questTitles[questID] = title
    end
    return questTitles[questID]
end

ns.On("QUEST_ACCEPTED", function(...)
    -- Classic passes (questLogIndex, questID); modern clients pass (questID).
    local questID = select(select("#", ...), ...)
    QuestTitle(questID)
    Journal:Log("qa", questID)
end)

ns.On("QUEST_TURNED_IN", function(questID, xp, money)
    local totals = ns.char.totals
    totals.quests = totals.quests + 1
    totals.questXP = totals.questXP + (xp or 0)
    Journal:Log("qd", questID, xp, money, QuestTitle(questID))
end)

-- Turns a client chat format string such as "%s dies, you gain %d experience."
-- into a Lua pattern capturing each %s and %d, matching from the start.
local function ChatPattern(format)
    local pattern = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    pattern = pattern:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. pattern
end

-- The combat log is blocked for addons on Forever, so kills are counted from
-- "X dies, you gain N experience." Kills that give no XP (gray mobs) are missed.
local killPattern = ChatPattern(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience.")

-- Loot: "You receive loot: [item]." (and "...x3." for stacks). Quest rewards
-- come as "You receive item:" and are left out, as they are not drops.
local lootPatterns = {
    ChatPattern(LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d."),
    ChatPattern(LOOT_ITEM_SELF or "You receive loot: %s."),
}
local MIN_LOOT_QUALITY = 2      -- uncommon (green)
local LINK_QUALITY = { ["1eff00"] = 2, ["0070dd"] = 3, ["a335ee"] = 4, ["ff8000"] = 5 }

-- Item quality from the client, or from the link's colour if the item is not cached yet.
local function ItemQuality(link)
    ---@diagnostic disable-next-line: deprecated
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local quality = getInfo and select(3, getInfo(link))
    if quality then return quality end
    local color = link:match("|c%x%x(%x%x%x%x%x%x)")
    return color and LINK_QUALITY[color:lower()]
end

ns.lootTracked = ns.On("CHAT_MSG_LOOT", function(msg)
    local link
    for _, pattern in ipairs(lootPatterns) do
        link = msg:match(pattern)
        if link then break end
    end
    if not link then return end
    local quality = ItemQuality(link)
    if not quality or quality < MIN_LOOT_QUALITY then return end
    Journal:Log("loot", link, quality, ns.char.instance)
    if ns.char.run then
        table.insert(ns.char.run.items, link)
    end
end)

-- Kills one by one, packed like the path to keep the file small:
-- ns.char.kills = { d = "dt,xp,n;...", last = time of the last kill,
-- names = { mob name, ... } }, where dt is seconds since the previous kill
-- and n indexes names. About 8 bytes a kill. No position: the replay puts a
-- kill where the path was at that time. This session's kills wait in
-- killBuffer and are packed in at logout (and /reload).
local killBuffer, nameIndex = {}, nil

local function AddKill(name, xp)
    local kills = ns.char.kills
    if not nameIndex then
        nameIndex = {}
        for i, n in ipairs(kills.names) do
            nameIndex[n] = i
        end
    end
    local n = nameIndex[name]
    if not n then
        n = #kills.names + 1
        kills.names[n] = name
        nameIndex[name] = n
    end
    local t = time()
    killBuffer[#killBuffer + 1] = ("%d,%d,%d;"):format(t - kills.last, xp, n)
    kills.last = t
end

ns.On("PLAYER_LOGOUT", function()
    local kills = ns.char.kills
    kills.d = kills.d .. table.concat(killBuffer)
    wipe(killBuffer)
end)

-- Every recorded kill of the journey shown (ns.view), oldest first:
-- { t, xp, name }. This session's are still buffered for this character.
function Journal:Kills()
    local kills, list, t = ns.view.kills, {}, 0
    local buffered = ns.view == ns.char and table.concat(killBuffer) or ""
    for _, chunk in ipairs({ kills.d, buffered }) do
        for dt, xp, n in chunk:gmatch("(-?%d+),(%d+),(%d+);") do
            t = t + tonumber(dt)
            list[#list + 1] = { t = t, xp = tonumber(xp), name = kills.names[tonumber(n)] }
        end
    end
    return list
end

-- Forgets this session's kills, after the character's data was erased.
function Journal:Reset()
    wipe(killBuffer)
    nameIndex = nil
end

ns.killsTracked = ns.On("CHAT_MSG_COMBAT_XP_GAIN", function(msg)
    local name, xp = msg:match(killPattern)
    if xp then
        local totals = ns.char.totals
        totals.kills = totals.kills + 1
        totals.killXP = totals.killXP + tonumber(xp)
        AddKill(name, tonumber(xp))
    end
end)

ns.Command("stats", "show journey totals and recording size", function()
    local t = ns.char.totals
    local segments, points, bytes = ns.Recorder:Stats()
    ns.Print(("Distance %d yd walked, %d yd flown."):format(math.floor(t.distance), math.floor(t.flown)))
    ns.Print(("Kills %s, deaths %d, quests %d, instances %d."):format(
        ns.killsTracked and t.kills or "n/a", t.deaths, t.quests, t.instances))
    ns.Print(("XP from kills %d, from quests %d."):format(t.killXP, t.questXP))
    ns.Print(("Path: %d segments, %d points, %.1f KB. Events: %d."):format(
        segments, points, bytes / 1024, #ns.char.events))

    local getMemory = GetAddOnMemoryUsage or (C_AddOns and C_AddOns.GetAddOnMemoryUsage)
    if UpdateAddOnMemoryUsage and getMemory then
        UpdateAddOnMemoryUsage()
        ns.Print(("Addon memory: %.1f MB."):format(getMemory(addonName) / 1024))
    end
    if ns.char.seeded then
        ns.Print("|cffff8040This character has fake seeded data. /rts reset confirm clears it.|r")
    end
end)
