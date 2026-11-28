local _, ns = ...

-- Players of the other faction killed in the open world, each an "hk" event:
--   hk  name, rank, honor, class, level, race, guild
-- name the player's as the kill's message gives it, or their full name
-- ("First Last") when the message gives only the first and they were seen
-- with surnames on; rank their PvP rank's name ("Scout"), nil when they had
-- none; honor the honor the kill gave; class and race their tokens
-- ("WARRIOR", "Orc"), level and guild theirs, each nil when they were not
-- seen. class to guild sit where a "duel" keeps its opponent's, so Duels'
-- helpers describe them both. Logged at the kill, so its time and place are
-- the kill's.
--
-- From the honorable kill message (COMBATLOG_HONORGAIN "%s dies, honorable
-- kill Rank: %s (%d Honor Points)", or COMBATLOG_HONORGAIN_NO_RANK without
-- the rank), CHAT_MSG_COMBAT_HONOR_GAIN, as the combat log is blocked on
-- Forever. It comes for a kill the player or their group had a part in, so
-- the player may not have dealt the killing blow; a player too low to give
-- honor gives no message and is missed. Inside a battleground or arena
-- nothing is logged: the run counts its honorable kills (Battlegrounds.lua).
--
-- The message names the player killed but nothing else, and the target is
-- often gone by then, so enemy players seen (targeted, moused over, on a
-- nameplate) are kept for a few minutes by name, not saved, and the one the
-- message names describes the kill.
--
-- WorldPvP:Describe(e), WorldPvP:ShowTooltip(owner, e, where, anchor) are
-- History's and the map's line and tooltip (Panel.lua, Map.lua); the Stats
-- screen counts them (Stats.Life).

local WorldPvP = {}
ns.WorldPvP = WorldPvP

local KEEP = 300            -- seconds an enemy player seen is kept for
local MAX_SEEN = 60         -- enemy players kept at most, the oldest dropped first

local seen = {}             -- Key(name) -> { info, at }
local seenCount = 0

-- The honor message's two forms: with the rank of the player killed, and
-- without one. ("You have been awarded %d honor points." matches neither.)
local matchers = {
    ns.ChatMatcher(_G["COMBATLOG_HONORGAIN"]),
    ns.ChatMatcher(_G["COMBATLOG_HONORGAIN_NO_RANK"]),
}

local function Plain(v)
    if v ~= nil and not (issecretvalue and issecretvalue(v)) then return v end
end

-- A name compared without case, spaces or hyphens: the message may write
-- "First Last" where UnitName gives "First", "Last", or "Name-Realm".
local function Key(name)
    return type(name) == "string" and (name:gsub("[%s%-]", ""):lower()) or nil
end

local function Surnames()
    local ok, on = pcall(function() return RegionalUniqueNamesEnabled() end)
    return ok and on == true
end

-- Whether the player is in a battleground or an arena.
local function InPvP()
    local ok, inside, kind = pcall(IsInInstance)
    return ok and inside and ns.Battlegrounds and ns.Battlegrounds.IsPvP(kind) or false
end

-- An enemy player's unit, described and kept under each way a message may
-- name them.
local function Saw(unit)
    if type(unit) ~= "string" or InPvP() then return end
    local ok, enemy = pcall(function()
        return UnitExists(unit) and UnitIsPlayer(unit) and UnitIsEnemy("player", unit)
    end)
    if not ok or Plain(enemy) ~= true then return end
    local name, second = UnitName(unit)
    name, second = Plain(name), Plain(second)
    if type(name) ~= "string" or name == "" then return end
    local info = ns.Duels.DescribeUnit(unit)
    if not info then return end
    second = type(second) == "string" and second ~= "" and second or nil
    info.full = second and Surnames() and (name .. " " .. second) or nil
    local now = GetTime()
    -- (name is a string here, so neither key is nil)
    local id, first = Key(name .. (second or "")) or "", Key(name) or ""
    local entry = { info = info, at = now, id = id }
    if not seen[id] then seenCount = seenCount + 1 end
    seen[id] = entry
    if second then
        -- The first name alone, as the message may give it. Two players of
        -- one first name seen lately: it tells them apart no more, so it
        -- gives neither one's details nor full name.
        local kept = seen[first]
        if not kept then seenCount = seenCount + 1 end
        if kept and kept.id ~= id and now - kept.at <= KEEP then
            seen[first] = { ambiguous = true, at = now, id = "?" }
        else
            seen[first] = entry
        end
    end
    -- Too many: the stale go, and if a crowd is still too many, all of them
    -- but the one just seen.
    if seenCount > MAX_SEEN then
        for key, kept in pairs(seen) do
            if now - kept.at > KEEP or seenCount > 2 * MAX_SEEN and kept ~= entry then
                seen[key], seenCount = nil, seenCount - 1
            end
        end
    end
end

-- What was seen of the player a message names, if recently.
local function Seen(name)
    local kept = seen[Key(name)]
    if kept and not kept.ambiguous and GetTime() - kept.at <= KEEP then return kept.info end
end

-- The honor message: an honorable kill in the open world is logged, with
-- what was seen of the player killed. Returns the event.
function WorldPvP:Honor(msg)
    if ns.char.seeded or type(msg) ~= "string" or Plain(msg) == nil or InPvP() then return end
    local name, rank, honor
    for i, match in ipairs(matchers) do
        if i == 1 then
            name, rank, honor = match(msg)
        else
            name, honor = match(msg)
        end
        if name then break end
    end
    if not name then return end
    -- The target first: read now, its level is the one at the kill.
    Saw("target")
    local info = Seen(name) or {}
    name = (not name:find("[%s%-]") and info.full) or name
    rank = rank and rank ~= "" and rank or nil
    return ns.Journal:Log("hk", name, rank, tonumber(honor), info.class, info.level, info.race, info.guild)
end

ns.On("CHAT_MSG_COMBAT_HONOR_GAIN", function(msg) WorldPvP:Honor(msg) end)
ns.On("PLAYER_TARGET_CHANGED", function() Saw("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() Saw("mouseover") end)
ns.On("NAME_PLATE_UNIT_ADDED", function(unit) Saw(unit) end)

-- Showing them ------------------------------------------------------------------

local ICON = "Interface\\Icons\\Ability_Warrior_Challange"
local GREY = { 0.6, 0.6, 0.6 }

-- "Killed Gorehowl".
function WorldPvP:Title(e)
    return ("Killed %s"):format(tostring(e[6] or "?"))
end

-- History's and the map's line: title, detail, icon. The detail is the
-- player as far as known, with their rank and the honor.
function WorldPvP:Describe(e)
    local parts = {}
    local who = ns.Duels.Opponent(e)
    if who ~= "" then parts[#parts + 1] = who end
    if type(e[7]) == "string" then parts[#parts + 1] = e[7] end
    if type(e[8]) == "number" and e[8] > 0 then parts[#parts + 1] = ns.Commas(e[8]) .. " honor" end
    return self:Title(e), #parts > 0 and table.concat(parts, ", ") or "Honorable kill", ICON
end

-- How often the player killed one player, and was killed by them, in a
-- journey's events: kills, deaths.
function WorldPvP.Record(events, name)
    local key, kills, deaths = Key(name), 0, 0
    for _, e in ipairs(events or {}) do
        if e[2] == "hk" and Key(e[6]) == key then
            kills = kills + 1
        elseif e[2] == "die" and e[7] == "p" and Key(e[6]) == key then
            deaths = deaths + 1
        end
    end
    return kills, deaths
end

-- The kill's tooltip (History's rows, the map's markers): the player with
-- their class icon and level, race, class and guild; their rank and the
-- honor; how often the player killed them and they the player in the
-- journey shown; where and when.
function WorldPvP:ShowTooltip(owner, e, where, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(self:Title(e), self:Color())
    local r, g, b = ns.ClassColor(e[9])
    GameTooltip:AddDoubleLine(ns.Duels.ClassIcon(e[9]) .. tostring(e[6] or "?"),
        e[10] and ("Level %d"):format(e[10]) or " ", r, g, b, 1, 1, 1)
    local who = ns.Duels.Opponent(e, true)
    if who ~= "" then GameTooltip:AddLine(who, 0.85, 0.85, 0.85) end
    GameTooltip:AddLine(" ")
    if type(e[7]) == "string" then
        GameTooltip:AddDoubleLine("Rank", e[7], GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    if type(e[8]) == "number" then
        GameTooltip:AddDoubleLine("Honor", ns.Commas(e[8]), GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    local kills, deaths = WorldPvP.Record(ns.view and ns.view.events, e[6])
    if kills > 1 or deaths > 0 then
        GameTooltip:AddDoubleLine("You killed them", kills == 1 and "once" or ("%d times"):format(kills),
            GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    if deaths > 0 then
        GameTooltip:AddDoubleLine("They killed you", deaths == 1 and "once" or ("%d times"):format(deaths),
            GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    if where and where ~= "" then
        GameTooltip:AddDoubleLine("Where", where, GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("When", tostring(date("%d %b %Y, %H:%M", e[1])), GREY[1], GREY[2], GREY[3], 1, 1, 1)
    GameTooltip:Show()
end

-- The title's colour: the red of a hostile name.
function WorldPvP:Color()
    return 1, 0.45, 0.4
end

--@debug@
-- /rts pvpprobe: the honor strings this client has, the lifetime count,
-- the enemy players kept and the kills recorded.
ns.Command("pvpprobe", "check the honorable kill strings and the last kill (developer)", function()
    ns.Print(("Strings: ranked %q, no rank %q."):format(tostring(_G["COMBATLOG_HONORGAIN"]),
        tostring(_G["COMBATLOG_HONORGAIN_NO_RANK"])))
    if GetPVPLifetimeStats then
        ns.Print(("Lifetime honorable kills: %s."):format(tostring((GetPVPLifetimeStats()))))
    end
    local names = {}
    for key, kept in pairs(seen) do
        names[#names + 1] = ("%s (%ds ago)"):format(key, math.floor(GetTime() - kept.at))
    end
    ns.Print(("Enemies kept: %d. %s"):format(seenCount, table.concat(names, ", ")))
    local count, last = 0, nil
    for _, e in ipairs(ns.char.events) do
        if e[2] == "hk" then count, last = count + 1, e end
    end
    if last then
        ns.Print(("Last kill: %s; %s, %s %s %s %s, guild %s, %s."):format(WorldPvP:Title(last), tostring(last[7]),
            tostring(last[8]), tostring(last[11]), tostring(last[9]), tostring(last[10]), tostring(last[12]),
            date("%H:%M:%S", last[1])))
    end
    ns.Print(("World kills recorded: %d."):format(count))
end)
--@end-debug@
