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
--   rep                            reputation standing changed, see Reputation.lua
--   ride, mount                    riding learned, new mount, see Mounts.lua
--   grp, grpa, grpx                group joined, member joined, group ended, see Groups.lua
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
    if mapID and mapID ~= ns.char.lastZone and ns.IsPlaceMap(mapID) then
        ns.char.lastZone = mapID
        Journal:Log("zone", mapID)
    end
end

-- A run is one visit to an instance. ns.char.run holds the totals at entry,
-- so leaving can log what happened inside. It is saved, so a run survives a
-- logout inside the instance.
--
-- Dungeons have no run ID, only the instance's map ID, and dying means
-- coming back to life at a graveyard outside. So leaving does not end a
-- run at once: run.left keeps when and where it was left and the summary
-- then. Back into the same instance within RUN_GAP and with the same group
-- (or still without one), the run carries on; otherwise it ends as it was
-- when left, so what happens outside does not count towards it. A new
-- group going back in is a new run, even minutes later.
local RUN_GAP = 30 * 60

-- Puts event e into the journal in time order (it can be from the past).
local function Insert(e)
    local events = ns.char.events
    local at = #events + 1
    while at > 1 and events[at - 1][1] > e[1] do
        at = at - 1
    end
    table.insert(events, at, e)
end

local function StartRun(name, instanceType)
    local t = ns.char.totals
    ns.char.run = {
        t = time(), name = name, type = instanceType, level = UnitLevel("player"),
        kills = t.kills, xp = t.killXP + t.questXP, deaths = t.deaths, money = GetMoney(),
        items = {}, party = {},
    }
    for _, guid in ipairs(ns.Groups:Current() or {}) do
        ns.char.run.party[guid] = true
    end
end

-- Notes that the player with guid was in the group during the run, so the
-- run lists everyone who was there at any point, not only those left at
-- the end (Groups.lua calls this on every roster update).
function Journal:JoinRun(guid)
    local run = ns.char.run
    if run and not run.left then
        run.party = run.party or {}
        run.party[guid] = true
    end
end

-- The run so far: { name, duration (seconds), kills, xp, deaths, money
-- (copper), levels, items = { itemLink, ... }, party = guids of everyone
-- else who was in the group at any point during the run, if any (see
-- Groups.lua), type = the instance type, "party" or "raid" }. This is the
-- summary its "out" event gets.
local function RunSummary(run)
    local t = ns.char.totals
    local seen, party = {}, {}
    for guid in pairs(run.party or {}) do
        seen[guid] = true
        party[#party + 1] = guid
    end
    for _, guid in ipairs(ns.Groups:Current() or {}) do
        if not seen[guid] then party[#party + 1] = guid end
    end
    return {
        name = run.name,
        duration = time() - run.t,
        kills = t.kills - run.kills,
        xp = t.killXP + t.questXP - run.xp,
        deaths = t.deaths - run.deaths,
        money = GetMoney() - run.money,
        levels = UnitLevel("player") - run.level,
        items = { unpack(run.items) },
        party = #party > 0 and party or nil,
        type = run.type,
    }
end

-- Ends the run that was left, logging "out" when and where it was left.
local function FinishRun()
    local run = ns.char.run
    ns.char.run = nil
    local left = run and run.left
    if not left then return end
    ns.Groups:CountRun(left.summary.party, run.type == "raid")
    Insert({ left.t, "out", left.c, left.x, left.y, left.id, left.summary })
end

-- Notes leaving instanceID; the run ends later unless it is entered again.
local function LeaveRun(instanceID)
    local run = ns.char.run
    if not run then
        Journal:Log("out", instanceID)
        return
    end
    local c, x, y = ns.Recorder:Position()
    run.left = {
        t = time(), c = c or -1, x = x or 0, y = y or 0, id = instanceID, summary = RunSummary(run),
        group = ns.char.group and ns.char.group.t or false,
    }
    local left = run.left
    C_Timer.After(RUN_GAP + 1, function()
        ns.SafeCall(function()
            if ns.char.run and ns.char.run.left == left then FinishRun() end
        end)
    end)
end

local function CheckInstance()
    local char = ns.char
    local run = char.run
    -- A run left too long ago, or left before a logout, has ended.
    if run and run.left and time() - run.left.t >= RUN_GAP then
        FinishRun()
        run = nil
    end
    local inInstance, instanceType = IsInInstance()
    if inInstance then
        local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
        if run and run.left then
            local group = ns.char.group and ns.char.group.t or false
            if run.left.id == instanceID and (run.left.group == nil or run.left.group == group) then
                -- Back in, after a death or a trip out: the same run.
                run.left = nil
                char.instance = instanceID
                return
            end
            FinishRun()
        end
        if char.instance ~= instanceID then
            if char.instance then
                LeaveRun(char.instance)
                FinishRun()
            end
            char.instance = instanceID
            char.totals.instances = char.totals.instances + 1
            Journal:Log("in", instanceID, name, instanceType)
            StartRun(name, instanceType)
        end
    elseif char.instance then
        LeaveRun(char.instance)
        char.instance = nil
    end
end

-- Everyone in either list of guids, once each, in order; nil if no one.
local function MergeParty(a, b)
    local seen, list = {}, {}
    for _, party in ipairs({ a or {}, b or {} }) do
        for _, guid in ipairs(party) do
            if not seen[guid] then
                seen[guid] = true
                list[#list + 1] = guid
            end
        end
    end
    return #list > 0 and list or nil
end

-- Joins runs that earlier versions split in two when the character died
-- and ran back in: an "out" followed within RUN_GAP by an "in" to the same
-- instance, with no other instance and no group starting or ending
-- between, becomes one run.
function Journal:TidyRuns()
    local events = ns.char.events
    local i = 1
    while i <= #events do
        local out = events[i]
        local back = events[i + 1]
        local k = i + 1
        local regrouped = false
        while back and back[2] ~= "in" and back[2] ~= "out" do
            regrouped = regrouped or back[2] == "grp" or back[2] == "grpx"
            k = k + 1
            back = events[k]
        end
        if out[2] == "out" and not regrouped and back and back[2] == "in" and back[6] == out[6]
            and back[1] - out[1] < RUN_GAP and type(out[7]) == "table" then
            local first = out[7]
            -- Where the second part's summary goes: its own "out", or the
            -- run still going on.
            local j = k + 1
            while events[j] and events[j][2] ~= "out" and events[j][2] ~= "in" do
                j = j + 1
            end
            local second = events[j]
            local merged = true
            if second and second[2] == "out" and second[6] == out[6] and type(second[7]) == "table" then
                local s = second[7]
                s.duration = s.duration + first.duration + (back[1] - out[1])
                s.kills, s.xp, s.deaths = s.kills + first.kills, s.xp + first.xp, s.deaths + first.deaths
                s.money, s.levels = s.money + first.money, s.levels + first.levels
                for n, link in ipairs(first.items) do
                    table.insert(s.items, n, link)
                end
                s.party = MergeParty(first.party, s.party)
            elseif not second and ns.char.run and ns.char.instance == out[6] then
                local run = ns.char.run
                run.t = run.t - first.duration - (back[1] - out[1])
                run.kills, run.xp, run.deaths = run.kills - first.kills, run.xp - first.xp, run.deaths - first.deaths
                run.money, run.level = run.money - first.money, run.level - first.levels
                for n, link in ipairs(first.items) do
                    table.insert(run.items, n, link)
                end
                run.party = run.party or {}
                for _, guid in ipairs(first.party or {}) do
                    run.party[guid] = true
                end
            else
                merged = false
            end
            if merged then
                table.remove(events, k)
                table.remove(events, i)
                ns.char.totals.instances = math.max(0, ns.char.totals.instances - 1)
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

-- Takes out events that versions up to 1.5.0 saved wrongly, from a journey
-- (this character's, or a roster copy): "zone" events for a continent (see
-- ns.IsPlaceMap), and a death logged a second time in the same second (the
-- client fired PLAYER_DEAD twice), which the totals counted too.
function Journal:TidyEvents(journey)
    local events, kept, lastDeath = journey.events or {}, 0, nil
    local doubled = 0
    for i = 1, #events do
        local e = events[i]
        local keep = true
        if e[2] == "zone" then
            keep = ns.IsPlaceMap(e[6])
        elseif e[2] == "die" then
            keep = e[1] ~= lastDeath
            doubled = doubled + (keep and 0 or 1)
            lastDeath = e[1]
        end
        if keep then
            kept = kept + 1
            events[kept] = e
        end
    end
    for i = #events, kept + 1, -1 do
        events[i] = nil
    end
    if doubled > 0 and journey.totals then
        journey.totals.deaths = math.max(0, journey.totals.deaths - doubled)
    end
end

ns.On("PLAYER_LOGIN", function()
    if not ns.char.seeded then ns.SafeCall(Journal.TidyRuns, Journal) end
    ns.SafeCall(Journal.TidyEvents, Journal, ns.char)
    for _, e in pairs(ns.db.roster or {}) do
        if e.journey and e.journey.events ~= ns.char.events then
            ns.SafeCall(Journal.TidyEvents, Journal, e.journey)
        end
    end
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

-- The client can fire PLAYER_DEAD twice for one death (seen once, both in
-- the same second). Only the same second counts as one death: a shaman's
-- Reincarnation can be followed by a real second death within moments.
local lastDeath

ns.On("PLAYER_DEAD", function()
    if time() == lastDeath then return end
    lastDeath = time()
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
    -- Not once the run has been left: loot outside is not the run's.
    if ns.char.run and not ns.char.run.left then
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
