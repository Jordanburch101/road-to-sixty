local _, ns = ...

-- Battlegrounds (issue #80): what happened in each, kept on its run
-- (Journal.lua) as run.pvp, which the run's summary (its "out" event)
-- carries:
--   pvp = { won, length, kb, hk, deaths, scoreHonor, honor, damage, healing,
--           stats = { { name, value }, ... }, rep = { [faction] = gained },
--           teams = { horde, alliance }, chatKills }
-- won is true or false once the match has a winner, nil when left before;
-- length the match's seconds by its own clock (from when it opened, so
-- longer than the player's time inside after joining late); kb, hk, deaths,
-- scoreHonor, damage and healing the player's row on the score board;
-- stats the map's own columns (towers, flags, ...) by the names the board
-- gives them; teams how many were on each side. These are read on each
-- score update until leaving, during the match too (so leaving early keeps
-- them): the map's columns are gone a few seconds after the end, so they
-- are kept as last seen. honor is every honor point awarded inside, from
-- chat (the board's leaves out the bonus honor: 420 of 840 in a probed
-- Alterac Valley), chatKills the honorable kills chat named, and rep the
-- reputation gained inside, by faction name. Any of them is nil when the
-- client did not give it.
--
-- A battleground run ends as soon as it is left (Journal.lua), and is
-- never joined with the next one (Tidy.lua); it counts as no dungeon for
-- the group (Groups.lua). It is still one of the instances in the totals,
-- which Merge.lua counts from "in" events.

local Battlegrounds = {}
ns.Battlegrounds = Battlegrounds

local PVP = { pvp = true, arena = true }

-- Whether an instance type (IsInInstance's, kept on runs and "in" events) is a battleground or arena.
function Battlegrounds.IsPvP(instanceType)
    return PVP[instanceType] == true
end

-- A function to call on each event of a journey, in time order: true for
-- those inside a battleground (after its "in", before its "out"). Their
-- place is where the player queued from, so the map leaves them off.
function Battlegrounds.Tracker()
    local inside = false
    return function(e)
        if e[2] == "in" then
            inside = PVP[e[8]] == true
            return false
        elseif e[2] == "out" then
            inside = false
            return false
        end
        return inside
    end
end

local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

-- What fn(...) gives, or nil when it is missing, errors or is secret.
local function Read(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, value = pcall(fn, ...)
    if ok and not Secret(value) then return value end
end

local function Number(v)
    if type(v) == "number" and not Secret(v) then return v end
end

-- The pvp table of the battleground run going on; nil outside one.
local function Current()
    local run = ns.char and ns.char.run
    if not run or run.left or not PVP[run.type] or ns.char.seeded then return end
    run.pvp = run.pvp or { rep = {} }
    return run.pvp
end

-- The player's row on the score board, { index, values }, and how many
-- are on each side, { horde, alliance }.
local function MyRow()
    local count = Number(Read(_G["GetNumBattlefieldScores"]))
    local getScore = _G["GetBattlefieldScore"]
    if not count or type(getScore) ~= "function" then return end
    local me, teams, mine = UnitName("player"), { 0, 0 }, nil
    for i = 1, count do
        local row = { pcall(getScore, i) }
        if row[1] then
            local name, faction = row[2], row[7]
            if faction == 0 or faction == 1 then teams[faction + 1] = teams[faction + 1] + 1 end
            -- (a name from another realm has it after a dash)
            if type(name) == "string" and not Secret(name) and (name == me or name:sub(1, #me + 1) == me .. "-") then
                mine = { i, row }
            end
        end
    end
    return mine, teams
end

-- Reads the player's row on the score board, which the client keeps up
-- during the match too (so leaving early keeps it), and the result once
-- the match has a winner.
local askedAtEnd       -- the run whose final board was asked for, once

function Battlegrounds:ReadScore()
    local pvp = Current()
    if not pvp then return end
    local winner = Number(Read(_G["GetBattlefieldWinner"]))
    -- The board as it ended, asked for once: asking again on each update
    -- would never stop if the player's row were not found.
    if winner and askedAtEnd ~= ns.char.run and RequestBattlefieldScoreData then
        askedAtEnd = ns.char.run
        pcall(RequestBattlefieldScoreData)
    end
    local mine, teams = MyRow()
    if not mine then return end
    local i, row = mine[1], mine[2]
    -- row[1] is pcall's; the client's values start at row[2] with the name:
    -- name, killing blows, honorable kills, deaths, honor, faction, then on
    -- Era and Anniversary rank, race, class, class token, damage, healing.
    -- Damage and healing are found after the class token, in case a client
    -- leaves the rank out.
    local faction = Number(row[7])
    if faction and winner then pvp.won = faction == winner end
    pvp.kb, pvp.hk, pvp.deaths, pvp.scoreHonor = Number(row[3]), Number(row[4]), Number(row[5]), Number(row[6])
    local _, classToken = UnitClass("player")
    for k = 8, #row do
        if row[k] == classToken then
            pvp.damage, pvp.healing = Number(row[k + 1]), Number(row[k + 2])
            break
        end
    end
    pvp.teams = teams
    local ms = Number(Read(_G["GetBattlefieldInstanceRunTime"]))
    if ms and ms > 0 then pvp.length = math.floor(ms / 1000) end
    local columns = Number(Read(_G["GetNumBattlefieldStats"])) or 0
    if columns > 0 then
        local stats = {}
        for s = 1, columns do
            local name = Read(_G["GetBattlefieldStatInfo"], s)
            if type(name) == "string" then
                stats[#stats + 1] = { name, Number(Read(_G["GetBattlefieldStatData"], i, s)) or 0 }
            end
        end
        pvp.stats = stats
    end
end

-- "You have been awarded 126 honor points.", or an honorable kill's honor
-- ("X dies, honorable kill Rank: Scout (50 Honor Points)"): the last number
-- in the message, in any language. Kills are counted too, for a match left
-- before the board was read.
local killMatchers = {
    ns.ChatMatcher(_G["COMBATLOG_HONORGAIN"]),
    ns.ChatMatcher(_G["COMBATLOG_HONORGAIN_NO_RANK"]),
}

function Battlegrounds:Honor(msg)
    local pvp = Current()
    if not pvp or type(msg) ~= "string" then return end
    local last
    for n in msg:gmatch("%d+") do last = n end
    if last then pvp.honor = (pvp.honor or 0) + tonumber(last) end
    for _, match in ipairs(killMatchers) do
        if match(msg) then
            pvp.chatKills = (pvp.chatKills or 0) + 1
            return
        end
    end
end

-- "Reputation with %s increased by %d.", with the racial bonus or without.
-- (the bonus format first, as the plain one matches the start of it; a
-- client may not have it)
local repMatchers = {
    ns.ChatMatcher(_G["FACTION_STANDING_INCREASED_BONUS"]),
    ns.ChatMatcher(_G["FACTION_STANDING_INCREASED"] or "Reputation with %s increased by %d."),
}

function Battlegrounds:Reputation(msg)
    local pvp = Current()
    if not pvp or type(msg) ~= "string" then return end
    for _, match in ipairs(repMatchers) do
        local faction, amount = match(msg)
        if faction and tonumber(amount) then
            pvp.rep = pvp.rep or {}
            pvp.rep[faction] = (pvp.rep[faction] or 0) + tonumber(amount)
            return
        end
    end
end

-- Showing them ------------------------------------------------------------------

local function Count(n, one, many)
    return ("%s %s"):format(ns.Commas(n), n == 1 and one or many)
end

-- History's line for a battleground run: "Won, 10m, 4 deaths, 840 honor".
function Battlegrounds:Detail(s, FormatDuration)
    local pvp, parts = s.pvp or {}, {}
    if pvp.won ~= nil then parts[#parts + 1] = pvp.won and "Won" or "Lost" end
    -- The player's own time inside: the match's length counts from when the
    -- battleground opened, before a player joining late came in.
    parts[#parts + 1] = FormatDuration(s.duration)
    if (pvp.deaths or s.deaths or 0) > 0 then parts[#parts + 1] = Count(pvp.deaths or s.deaths, "death", "deaths") end
    local honor = pvp.honor or pvp.scoreHonor
    if honor and honor > 0 then parts[#parts + 1] = ns.Commas(honor) .. " honor" end
    return table.concat(parts, ", ")
end

-- The lines a battleground run's card adds: the result, the score board's
-- numbers, the map's own columns that are not 0, and reputation gained.
function Battlegrounds:Lines(s)
    local pvp, lines = s.pvp, {}
    if not pvp then return lines end
    if pvp.won ~= nil then
        local teams = pvp.teams and pvp.teams[1] + pvp.teams[2] > 0
            and (" (%d v %d)"):format(pvp.teams[2], pvp.teams[1]) or ""
        lines[#lines + 1] = (pvp.won and "|cff40ff40Won|r" or "|cffff5050Lost|r") .. teams
    else
        lines[#lines + 1] = "Left before the end"
    end
    local board = {}
    if pvp.kb then board[#board + 1] = Count(pvp.kb, "killing blow", "killing blows") end
    local hk = pvp.hk or pvp.chatKills
    if hk then board[#board + 1] = Count(hk, "honorable kill", "honorable kills") end
    if pvp.deaths then board[#board + 1] = Count(pvp.deaths, "death", "deaths") end
    if #board > 0 then lines[#lines + 1] = table.concat(board, ", ") end
    local honor = pvp.honor or pvp.scoreHonor
    if honor then lines[#lines + 1] = ns.Commas(honor) .. " honor" end
    if pvp.damage or pvp.healing then
        lines[#lines + 1] = ("%s damage, %s healing"):format(ns.Commas(pvp.damage or 0), ns.Commas(pvp.healing or 0))
    end
    for _, stat in ipairs(pvp.stats or {}) do
        if (stat[2] or 0) > 0 then lines[#lines + 1] = ("%s: %s"):format(stat[1], ns.Commas(stat[2])) end
    end
    for faction, amount in pairs(pvp.rep or {}) do
        lines[#lines + 1] = ("+%s %s"):format(ns.Commas(amount), faction)
    end
    return lines
end

-- Listening ---------------------------------------------------------------------

-- The client updates the board only when asked (the default UI asks while
-- its score frame shows), so inside a battleground it is asked every
-- REQUEST seconds: a match left early then keeps a recent row.
local REQUEST = 30
local ticker

local function Watch()
    local inside, kind = IsInInstance()
    if inside and PVP[kind] then
        if not ticker and C_Timer and C_Timer.NewTicker then
            ticker = C_Timer.NewTicker(REQUEST, function()
                if RequestBattlefieldScoreData then pcall(RequestBattlefieldScoreData) end
            end)
        end
    elseif ticker then
        ticker:Cancel()
        ticker = nil
    end
end

ns.On("PLAYER_ENTERING_WORLD", Watch)

ns.On("UPDATE_BATTLEFIELD_STATUS", function() Battlegrounds:ReadScore() end)
ns.On("UPDATE_BATTLEFIELD_SCORE", function() Battlegrounds:ReadScore() end)
ns.On("CHAT_MSG_COMBAT_HONOR_GAIN", function(msg) Battlegrounds:Honor(msg) end)
ns.On("CHAT_MSG_COMBAT_FACTION_CHANGE", function(msg) Battlegrounds:Reputation(msg) end)
