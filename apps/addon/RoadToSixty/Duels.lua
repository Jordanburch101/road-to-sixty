local _, ns = ...

-- Duels the player fights (issue #88), each a "duel" event:
--   duel  name, result, by, class, level, race, guild, toDeath
-- name the opponent's ("Name-Realm" from another realm); result "won",
-- "lost", "fled" (the player left the duel area) or "theyFled"; by "me"
-- when the player challenged, "them" when challenged, nil when neither was
-- seen; class and race the opponent's tokens ("WARRIOR", "NightElf"),
-- level and guild theirs, each nil when they were not targeted or
-- challenged by unit; toDeath true for a duel to the death (Hardcore
-- realms). Logged at the result, so its time and place are the duel's end.
-- A duel declined or cancelled logs nothing.
--
-- Checked against Forever's launch build and UI code: the result comes only
-- as a system message naming both players (DUEL_WINNER_KNOCKOUT "%1$s has
-- defeated %2$s in a duel", DUEL_WINNER_RETREAT "%2$s has fled from %1$s in
-- a duel"), shown for duels nearby too, so only those naming the player
-- count; DUEL_FINISHED says nothing of who won. A challenge received comes
-- as DUEL_REQUESTED or DUEL_TO_THE_DEATH_REQUESTED with the challenger's
-- name; one sent has no event, so StartDuel (what the unit menu and /duel
-- call; StartDuel(unit, true, true) for a duel to the death) is hooked.
-- Era has the same strings and functions.
--
-- Duels:Describe(e), Duels:Color(e) and Duels:ShowTooltip(owner, e, where)
-- are History's and the map's line and tooltip for one (Panel.lua,
-- Map.lua); the Stats screen counts them (Stats.Life).

local Duels = {}
ns.Duels = Duels

local STALE = 600           -- seconds: a challenge older than this is not the duel ending now

local pending               -- { name, by, toDeath, info, at } the challenge last seen

local matchKnockout = ns.ChatMatcher(DUEL_WINNER_KNOCKOUT or "%1$s has defeated %2$s in a duel", true)
local matchRetreat = ns.ChatMatcher(DUEL_WINNER_RETREAT or "%2$s has fled from %1$s in a duel", true)

local function Plain(v)
    if v ~= nil and not (issecretvalue and issecretvalue(v)) then return v end
end

-- A unit's name with its realm when it has one ("Name-Realm"), as the
-- system messages name players from other realms: without the realm's
-- spaces ("Area52"), as they write it.
local function FullName(unit)
    local name, realm = UnitName(unit)
    name, realm = Plain(name), Plain(realm)
    if type(name) ~= "string" or name == "" then return nil end
    return (type(realm) == "string" and realm ~= "") and (name .. "-" .. realm:gsub("%s", "")) or name
end

-- A name compared without case or spaces: a name typed after /duel may be
-- lower case, and realms are written with and without their spaces.
local function Key(name)
    return (name:gsub("%s", ""):lower())
end

-- Whether two names are one player: the same, or one with this realm's name
-- added (the client leaves the player's own realm off).
local function Same(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    a, b = Key(a), Key(b)
    if a == b then return true end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if type(realm) ~= "string" then return false end
    realm = Key(realm)
    return a .. "-" .. realm == b or b .. "-" .. realm == a
end

-- Whether s is a unit token rather than a player's name.
local function IsUnit(s)
    return s == "player" or s == "pet" or s == "npc" or s:find("^target") or s:find("^focus") or s:find("^mouseover")
        or s:find("^party%d") or s:find("^raid%d") or s:find("^arena%d") or s:find("^nameplate%d") or false
end

-- What can be read of a player unit: { class, level, race, guild }.
local function Describe(unit)
    if not (UnitExists(unit) and UnitIsPlayer(unit)) then return nil end
    local level = Plain(UnitLevel(unit))
    return {
        class = Plain(select(2, UnitClass(unit))),
        level = type(level) == "number" and level > 0 and level or nil,
        race = Plain(select(2, UnitRace(unit))),
        guild = Plain((GetGuildInfo(unit))),
    }
end

-- The opponent's details: the target's when it is them (read last, so the
-- level is the one at the end), else what the challenge read.
local function InfoFor(name)
    if Same(FullName("target"), name) then return Describe("target") end
    return pending and Same(pending.name, name) and pending.info or nil
end

local function Challenge(name, by, toDeath, info)
    pending = { name = name, by = by, toDeath = toDeath or nil, info = info, at = GetTime() }
end

-- Logs the duel the player was in: opponent and result.
function Duels:Ended(opponent, result)
    if ns.char.seeded then return end
    local challenge = pending and Same(pending.name, opponent) and GetTime() - pending.at <= STALE and pending or nil
    local info = InfoFor(opponent) or {}
    pending = nil
    return ns.Journal:Log("duel", opponent, result, challenge and challenge.by, info.class, info.level, info.race,
        info.guild, challenge and challenge.toDeath)
end

-- The result message: a duel the player was in, else someone else's nearby.
function Duels:Result(msg)
    local me = FullName("player")
    local winner, loser = matchKnockout(msg)
    local fled = false
    if not winner then
        winner, loser = matchRetreat(msg)
        fled = true
    end
    if not winner or not loser then return end
    if Same(winner, me) then
        return self:Ended(loser, fled and "theyFled" or "won")
    elseif Same(loser, me) then
        return self:Ended(winner, fled and "fled" or "lost")
    end
end

ns.On("DUEL_REQUESTED", function(name)
    name = Plain(name)
    if type(name) ~= "string" then return end
    Challenge(name, "them", false, Same(FullName("target"), name) and Describe("target") or nil)
end)

ns.On("DUEL_TO_THE_DEATH_REQUESTED", function(name)
    name = Plain(name)
    if type(name) ~= "string" then return end
    Challenge(name, "them", true, Same(FullName("target"), name) and Describe("target") or nil)
end)

ns.On("CHAT_MSG_SYSTEM", function(msg)
    if type(msg) == "string" and not (issecretvalue and issecretvalue(msg)) then Duels:Result(msg) end
end)

-- A challenge sent: by unit from the unit menu, by name or nothing (the
-- target) from /duel. The hook runs even when the challenge fails (out of
-- range, in combat, one already waiting), so a challenge received less
-- than KEEP_RECEIVED seconds ago is kept, and a unit not there (/duel with
-- nothing targeted) records nothing.
local KEEP_RECEIVED = 60
if hooksecurefunc and StartDuel then
    hooksecurefunc("StartDuel", function(who, _, toDeath)
        ns.SafeCall(function()
            local unit = (who == nil or who == "") and "target" or who
            if type(unit) ~= "string" then return end
            if pending and pending.by == "them" and GetTime() - pending.at < KEEP_RECEIVED then return end
            local name, info
            if UnitExists(unit) then
                name, info = FullName(unit), Describe(unit)
            elseif not IsUnit(unit) then
                name = unit     -- a name typed after /duel
            end
            if name then Challenge(name, "me", toDeath and true, info) end
        end)
    end)
end

-- How to show a duel: "Defeated Name in a duel", "Lost a duel to Name",
-- "Fled a duel with Name", "Name fled a duel".
function Duels:Title(e)
    local name, result = tostring(e[6] or "?"), e[7]
    local kind = e[13] and "a duel to the death" or "a duel"
    if result == "won" then return ("Defeated %s in %s"):format(name, kind) end
    if result == "lost" then return ("Lost %s to %s"):format(kind, name) end
    if result == "fled" then return ("Fled %s with %s"):format(kind, name) end
    if result == "theyFled" then return ("%s fled %s"):format(name, kind) end
    return ("Duel with %s"):format(name)
end

local ICON = "Interface\\Icons\\Ability_DualWield"
-- Race tokens shown as the game names them, where the token differs.
local RACE_NAMES = { Scourge = "Undead" }

-- The opponent as far as known: "Level 24 Orc Warrior <Blood Moon>", or "";
-- without the level with noLevel.
local function Opponent(e, noLevel)
    local parts = {}
    if e[10] and not noLevel then parts[#parts + 1] = "Level " .. e[10] end
    if type(e[11]) == "string" then
        parts[#parts + 1] = RACE_NAMES[e[11]] or (e[11]:gsub("(%l)(%u)", "%1 %2"))
    end
    if e[9] then parts[#parts + 1] = ns.ClassName(e[9]) end
    local who = table.concat(parts, " ")
    if type(e[12]) == "string" and e[12] ~= "" then who = (who ~= "" and who .. " " or "") .. "<" .. e[12] .. ">" end
    return who
end

-- History's and the map's line for a duel: title, detail, icon. The
-- detail is the opponent as far as known and who challenged.
function Duels:Describe(e)
    local who = Opponent(e)
    local by = e[8] == "me" and "you challenged" or e[8] == "them" and "they challenged" or nil
    local detail = who ~= "" and (by and (who .. ", " .. by) or who) or by or "Duel"
    return self:Title(e), detail, ICON
end

-- The player's record against one opponent in a journey's events:
-- { count, won, lost, fled, theyFled }.
function Duels.Record(events, name)
    local record = { count = 0, won = 0, lost = 0, fled = 0, theyFled = 0 }
    for _, e in ipairs(events or {}) do
        if e[2] == "duel" and e[6] == name then
            record.count = record.count + 1
            if record[e[7]] then record[e[7]] = record[e[7]] + 1 end
        end
    end
    return record
end

-- The class's round icon, inline in text.
local function ClassIcon(class)
    local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not coords then return "" end
    return ("|TInterface\\TargetingFrame\\UI-Classes-Circles:14:14:0:0:256:256:%d:%d:%d:%d|t "):format(
        coords[1] * 256, coords[2] * 256, coords[3] * 256, coords[4] * 256)
end

local GREY = { 0.6, 0.6, 0.6 }

-- The duel's tooltip (History's rows, the map's markers): the result in its
-- colour; the opponent with their class icon and level, race, class and
-- guild; a duel to the death; who challenged and the player's record
-- against them in the journey shown; where and when.
function Duels:ShowTooltip(owner, e, where, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(self:Title(e), self:Color(e))
    local r, g, b = ns.ClassColor(e[9])
    GameTooltip:AddDoubleLine(ClassIcon(e[9]) .. tostring(e[6] or "?"), e[10] and ("Level %d"):format(e[10]) or " ",
        r, g, b, 1, 1, 1)
    local who = Opponent(e, true)
    if who ~= "" then GameTooltip:AddLine(who, 0.85, 0.85, 0.85) end
    if e[13] then GameTooltip:AddLine("A duel to the death", 1, 0.25, 0.25) end
    GameTooltip:AddLine(" ")
    if e[8] == "me" or e[8] == "them" then
        GameTooltip:AddDoubleLine("Challenged by", e[8] == "me" and "You" or "Them", GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    local record = Duels.Record(ns.view and ns.view.events, e[6])
    if record.count > 1 then
        local won, lost = record.won + record.theyFled, record.lost + record.fled
        GameTooltip:AddDoubleLine("Your duels with them", ("%d won, %d lost"):format(won, lost),
            GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    if where and where ~= "" then
        GameTooltip:AddDoubleLine("Where", where, GREY[1], GREY[2], GREY[3], 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("When", tostring(date("%d %b %Y, %H:%M", e[1])), GREY[1], GREY[2], GREY[3], 1, 1, 1)
    GameTooltip:Show()
end

-- The title's colour: green for a win, red for a loss, grey for fleeing.
function Duels:Color(e)
    local result = e[7]
    if result == "won" or result == "theyFled" then return 0.45, 0.95, 0.45 end
    if result == "lost" then return 1, 0.45, 0.4 end
    return 0.75, 0.75, 0.75
end

--@debug@
-- /rts duelprobe: the duel strings this client has, the challenge waiting
-- and the duels recorded.
ns.Command("duelprobe", "check the duel strings and the last duel (developer)", function()
    ns.Print(("Strings: knockout %q, retreat %q."):format(tostring(DUEL_WINNER_KNOCKOUT), tostring(DUEL_WINNER_RETREAT)))
    ns.Print(("StartDuel %s, hooksecurefunc %s."):format(tostring(StartDuel ~= nil), tostring(hooksecurefunc ~= nil)))
    if pending then
        ns.Print(("Challenge waiting: %s, by %s%s, %ds ago."):format(pending.name, pending.by,
            pending.toDeath and ", to the death" or "", math.floor(GetTime() - pending.at)))
    end
    local count, last = 0, nil
    for _, e in ipairs(ns.char.events) do
        if e[2] == "duel" then count, last = count + 1, e end
    end
    if last then
        ns.Print(("Last duel: %s; by %s, %s %s %s, guild %s, %s."):format(Duels:Title(last), tostring(last[8]),
            tostring(last[11]), tostring(last[9]), tostring(last[10]), tostring(last[12]), date("%H:%M:%S", last[1])))
    end
    ns.Print(("Duels recorded: %d."):format(count))
end)
--@end-debug@
