local _, ns = ...

-- /rts bgprobe: what this client tells an addon about battlegrounds, to
-- plan recording them. Every battleground event the client has is logged
-- with its arguments, and at entering, every score update (at most one a
-- REREAD seconds), a winner and leaving, a read of every battleground and
-- PvP function. The log goes to chat (short) and to RoadToSixtyDB.bgProbe
-- (in full, saved at /reload), the newest MAX_LINES. Other players' names are
-- left out of score reads; chat messages are kept as they came.
--   /rts bgprobe         a read now, and how long the log is
--   /rts bgprobe quiet   stop or start printing to chat (logging goes on)
--   /rts bgprobe clear   empty the saved log

local MAX_LINES = 1500
local REREAD = 30           -- seconds between score reads on UPDATE_BATTLEFIELD_SCORE
local quiet = false
local lastScoreRead = 0

local EVENTS = {
    "UPDATE_BATTLEFIELD_STATUS", "UPDATE_BATTLEFIELD_SCORE", "PLAYER_ENTERING_BATTLEGROUND",
    "BATTLEFIELDS_SHOW", "BATTLEFIELDS_CLOSED", "BATTLEGROUND_POINTS_UPDATE", "BATTLEGROUND_OBJECTIVES_UPDATE",
    "PVP_MATCH_ACTIVE", "PVP_MATCH_COMPLETE", "PVP_MATCH_INACTIVE", "PVP_MATCH_STATE_CHANGED",
    "PLAYER_PVP_KILLS_CHANGED", "PLAYER_PVP_RANK_CHANGED", "HONOR_CURRENCY_UPDATE", "HONOR_XP_UPDATE",
    "HONOR_LEVEL_UPDATE", "CURRENCY_DISPLAY_UPDATE", "ARENA_TEAM_UPDATE", "ARENA_OPPONENT_UPDATE",
    "CHAT_MSG_COMBAT_HONOR_GAIN", "CHAT_MSG_BG_SYSTEM_ALLIANCE", "CHAT_MSG_BG_SYSTEM_HORDE",
    "CHAT_MSG_BG_SYSTEM_NEUTRAL", "CHAT_MSG_COMBAT_FACTION_CHANGE", "UPDATE_WORLD_STATES",
    "UPDATE_UI_WIDGET", "AREA_SPIRIT_HEALER_IN_RANGE", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
    "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "UPDATE_ACTIVE_BATTLEFIELD",
}
-- Events that come often: logged once a minute each, with how many came between.
local NOISY = { UPDATE_BATTLEFIELD_SCORE = true, UPDATE_WORLD_STATES = true, UPDATE_UI_WIDGET = true,
    CURRENCY_DISPLAY_UPDATE = true, BATTLEGROUND_POINTS_UPDATE = true }
local noisy = {}            -- event -> { last logged GetTime(), count since }

local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function Show(v)
    if Secret(v) then return "(secret)" end
    if type(v) == "string" then return ("%q"):format(v) end
    if type(v) == "table" then
        local parts = {}
        for k, x in pairs(v) do
            if #parts >= 12 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" .. Show(x)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function ShowAll(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = Show((select(i, ...))) end
    return table.concat(parts, ", ")
end

local function Log(text)
    local db = ns.db
    db.bgProbe = db.bgProbe or {}
    local log = db.bgProbe
    -- Full: the oldest lines go, so the newest (a death just now) are always kept.
    while #log >= MAX_LINES do table.remove(log, 1) end
    log[#log + 1] = ("%s %s"):format(date("%H:%M:%S"), text)
    if not quiet then ns.Print("|cff88ccff[bg]|r " .. (#text > 160 and text:sub(1, 160) .. "..." or text)) end
end

-- Calls fn by name (a global, or "C_PvP.Name") and logs what it returned,
-- or that it is missing or errored.
local function Try(name, ...)
    local fn
    local space, field = name:match("^([%w_]+)%.([%w_]+)$")
    if space then
        fn = _G[space] and _G[space][field]
    else
        fn = _G[name]
    end
    if type(fn) ~= "function" then
        Log(("  %s: missing"):format(name))
        return
    end
    local results = { pcall(fn, ...) }
    if not table.remove(results, 1) then
        Log(("  %s: error %s"):format(name, tostring(results[1])))
        return
    end
    Log(("  %s(%s) = %s"):format(name, ShowAll(...), ShowAll(unpack(results))))
    return unpack(results)
end

-- The score board: how many rows, per faction, and the player's own row in
-- full (every value GetBattlefieldScore gives), others' names left out.
local function ReadScores()
    local count = Try("GetNumBattlefieldScores")
    local getScore = _G["GetBattlefieldScore"]
    if type(count) ~= "number" or count == 0 or not getScore then return end
    local me, factions = UnitName("player"), {}
    for i = 1, count do
        local row = { pcall(getScore, i) }
        if row[1] then
            local name, faction = row[2], row[7]
            factions[tostring(faction)] = (factions[tostring(faction)] or 0) + 1
            if name == me or (type(name) == "string" and name:match("^" .. me .. "%-")) then
                Log(("  my score row %d: %s"):format(i, ShowAll(unpack(row, 2))))
                local stats = Try("GetNumBattlefieldStats")
                for s = 1, (type(stats) == "number" and stats or 0) do
                    Try("GetBattlefieldStatInfo", s)
                    Try("GetBattlefieldStatData", i, s)
                end
            end
        end
    end
    Log("  score rows by faction: " .. Show(factions))
end

-- Every battleground and PvP function this client might have.
local function Read(why)
    Log(("-- read (%s): in instance %s"):format(why, ShowAll(IsInInstance())))
    Try("GetInstanceInfo")
    Try("GetZonePVPInfo")
    local max = Try("GetMaxBattlefieldID")
    for i = 1, (type(max) == "number" and max or 3) do
        Try("GetBattlefieldStatus", i)
    end
    Try("GetBattlefieldWinner")
    Try("GetBattlefieldInstanceRunTime")
    Try("GetBattlefieldInstanceExpiration")
    Try("IsActiveBattlefieldArena")
    Try("GetBattlefieldTeamInfo", 0)
    Try("GetBattlefieldTeamInfo", 1)
    Try("GetPVPSessionStats")
    Try("GetPVPYesterdayStats")
    Try("GetPVPThisWeekStats")
    Try("GetPVPLastWeekStats")
    Try("GetPVPLifetimeStats")
    Try("GetHonorCurrency")
    Try("UnitPVPRank", "player")
    Try("UnitHonor", "player")
    Try("UnitHonorLevel", "player")
    local rank = _G["UnitPVPRank"]
    Try("GetPVPRankInfo", rank and rank("player") or 0)
    Try("C_PvP.GetActiveMatchState")
    Try("C_PvP.IsBattleground")
    Try("C_PvP.IsPVPMap")
    Try("C_PvP.GetActiveMatchDuration")
    Try("C_PvP.GetActiveMatchWinner")
    Try("C_PvP.GetScoreInfoByPlayerGuid", UnitGUID("player"))
    Try("C_CurrencyInfo.GetCurrencyInfo", 1901)    -- honor on modern clients
    Try("C_CurrencyInfo.GetCurrencyInfo", 1792)
    ReadScores()
end

local function OnEvent(event, ...)
    if NOISY[event] then
        local n = noisy[event] or { 0, 0 }
        noisy[event] = n
        n[2] = n[2] + 1
        if GetTime() - n[1] < 60 then return end
        Log(("%s x%d (last: %s)"):format(event, n[2], ShowAll(...)))
        n[1], n[2] = GetTime(), 0
    else
        Log(("%s: %s"):format(event, ShowAll(...)))
    end
    local inside, kind = IsInInstance()
    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_ENTERING_BATTLEGROUND" then
        if inside and (kind == "pvp" or kind == "arena") then
            Read("entered")
            if RequestBattlefieldScoreData then pcall(RequestBattlefieldScoreData) end
        end
    elseif event == "UPDATE_BATTLEFIELD_SCORE" and GetTime() - lastScoreRead >= REREAD then
        lastScoreRead = GetTime()
        ReadScores()
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
        local winner = GetBattlefieldWinner and GetBattlefieldWinner()
        if winner then Read("winner " .. tostring(winner)) end
    elseif event == "ZONE_CHANGED_NEW_AREA" and not inside then
        Read("outside")
    end
end

-- Deaths, in a battleground or not: who killed the player, every way the
-- client might tell. The combat log's last hits on the player (blocked for
-- addons on Forever, open on Era and Anniversary), the death recap if this
-- client has one (read at once and DEATH_REREAD seconds later, as it may
-- fill late), the target and enemy players whose nameplates target the
-- player, and system and combat chat for DEATH_CHAT seconds after.
local HITS, DEATH_REREAD, DEATH_CHAT = 8, 2, 5
local hits = {}             -- the last HITS combat log lines that hit the player
local diedAt = 0            -- GetTime() of the last death

local function OnCombatLog()
    local getInfo = _G["CombatLogGetCurrentEventInfo"]
    if type(getInfo) ~= "function" then return end
    local e = { getInfo() }
    -- timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags,
    -- sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, then
    -- the subevent's own: spell ID, name, school for SPELL_*; amount after.
    if e[8] ~= UnitGUID("player") then return end
    local kind = tostring(e[4]):match("^(%a+)%-") or tostring(e[4])
    local spell = tostring(e[2]):match("^SPELL") and e[13] or e[2]:match("^SWING") and "melee" or nil
    hits[#hits + 1] = ("%s %s from %s (%s)%s"):format(date("%H:%M:%S"), tostring(e[2]), Show(e[5]), kind,
        spell and (", " .. Show(spell)) or "")
    if #hits > HITS then table.remove(hits, 1) end
end

local function ListKeys(space)
    local t = _G[space]
    if type(t) ~= "table" then return space .. ": missing" end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return space .. ": " .. table.concat(keys, ", ")
end

-- Every field of a table, unlike Show's first twelve: a death recap event's.
local function ShowFields(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. Show(t[k]) end
    return table.concat(parts, ", ")
end

-- Forever's own death dialog asks C_DeathRecap with no ID (the latest
-- death); its recap window counts event 1 as the killing blow, naming its
-- caster from sourceName unless hideCaster.
local function ReadRecap(why)
    Log(("-- death recap (%s)"):format(why))
    Log("  " .. ListKeys("C_DeathRecap"))
    Try("C_DeathRecap.HasRecapEvents")
    Try("C_DeathRecap.GetRecapMaxHealth")
    local events = Try("C_DeathRecap.GetRecapEvents")
    if type(events) == "table" then
        Log(("  recap events: %d"):format(#events))
        for k = 1, math.min(3, #events) do
            if type(events[k]) == "table" then Log(("  event %d: %s"):format(k, ShowFields(events[k]))) end
        end
    end
    Try("GetDeathRecapLink", 1)
    Try("DeathRecap_HasEvents")
end

local function OnDeath()
    diedAt = GetTime()
    local inside, kind = IsInInstance()
    Log(("-- died (in instance %s, %s)"):format(tostring(inside), tostring(kind)))
    Log(("  combat log hits: %d"):format(#hits))
    for _, line in ipairs(hits) do Log("    " .. line) end
    wipe(hits)
    if UnitExists("target") then
        Log(("  target: %s, player %s, enemy %s, guid %s"):format(Show(UnitName("target")),
            Show(UnitIsPlayer("target")), Show(UnitIsEnemy("player", "target")), Show(UnitGUID("target"))))
    else
        Log("  target: none")
    end
    local aiming = {}
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local ok, onMe = pcall(UnitIsUnit, unit .. "target", "player")
            if ok and onMe == true then aiming[#aiming + 1] = Show(UnitName(unit)) end
        end
    end
    Log(("  enemy players targeting me: %s"):format(#aiming > 0 and table.concat(aiming, ", ") or "none"))
    ReadRecap("at death")
    C_Timer.After(DEATH_REREAD, function() ns.SafeCall(ReadRecap, DEATH_REREAD .. "s later") end)
end

local function OnDeathChat(event, msg)
    if GetTime() - diedAt <= DEATH_CHAT then Log(("  %s: %s"):format(event, Show(msg))) end
end

local combatLog = ns.On("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
ns.On("PLAYER_DEAD", OnDeath)
for _, event in ipairs({ "CHAT_MSG_SYSTEM", "CHAT_MSG_COMBAT_MISC_INFO", "CHAT_MSG_COMBAT_XP_GAIN" }) do
    ns.On(event, function(msg) OnDeathChat(event, msg) end)
end

local registered, missing = {}, {}
for _, event in ipairs(EVENTS) do
    if ns.On(event, function(...) OnEvent(event, ...) end) then
        registered[#registered + 1] = event
    else
        missing[#missing + 1] = event
    end
end

ns.On("PLAYER_LOGIN", function()
    Log(("-- login: %d events registered; not on this client: %s; combat log %s"):format(#registered,
        #missing > 0 and table.concat(missing, ", ") or "none", combatLog and "registered" or "refused"))
end)

ns.Command("bgprobe", "log what battlegrounds tell the addon; quiet, clear (developer)", function(arg)
    if arg == "quiet" then
        quiet = not quiet
        ns.Print("bgprobe chat lines " .. (quiet and "off" or "on") .. " (the saved log goes on).")
        return
    end
    if arg == "clear" then
        ns.db.bgProbe = {}
        ns.Print("bgprobe log cleared.")
        return
    end
    Read("asked")
    if RequestBattlefieldScoreData then pcall(RequestBattlefieldScoreData) end
    ns.Print(("bgprobe log: %d of %d lines. /reload to save it."):format(#(ns.db.bgProbe or {}), MAX_LINES))
end)
