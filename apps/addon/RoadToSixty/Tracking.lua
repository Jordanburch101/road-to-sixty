local _, ns = ...

-- Extra journey tracking: what the map has no use for yet, kept apart from the journey so it cannot touch the recorder or the
-- sync. It lives in the account-wide file, under ns.db.tracking:
--
--   off    = { [what] = true } tracking turned off: an event kind below, or
--            party or stats (Options.lua). All start off (Core.lua); a switch
--            turned on is saved as false so the defaults don't refill it
--   chars  = { [GUID] = {
--     name, realm, race, sex, class, faction,
--     seen   = { [subzone] = true } places been, to mark first visits,
--     stats  = "t,level,xp,xpMax,rested,money;..." one row a minute, on change,
--              up to the first row at the level cap,
--     people = { [GUID] = { name, class, d = "t,c,x,y,level;..." } } where
--              party members were, sampled outdoors below the level cap, at
--              most TRACK_MAX_ROWS rows each,
--     events = same shape as the journey's: { time, kind, c, x, y, ... }
--   } }
--
-- Times are ns.Now(), positions world yards (x north, y west), so everything
-- lines up with the journey. Events inside instances use the last outdoor
-- position. Kinds and their fields from index 6 on:
--   env   build, interface         session start
--   sub   zone, subzone, first     moved to another subzone; first = true on
--                                  the character's first visit
--   taxi  from, to, cost           took a flight
--   tal   points                   talents changed: "Arms 5 / Fury 0 / Prot 0"
--   bind  place                    hearthstone bound
--   rest  on                       entered or left a rested area
--   npc   what, name               vendor, trainer, bank, auction or mail
--   trade name                     opened a trade with someone
--   shot                           took a screenshot
--   note  text                     /rts note
--
-- Reads that could come back secret or be missing on one client or another
-- (places, positions, names, levels, XP and gold) go through Safe and Clean,
-- and one that fails records nothing. The yes-or-no checks (grouped, in an
-- instance, resting), the raid roster, the taxi map, the number of talent
-- tabs and the character's own details at login are called directly: they
-- are plain values in the open world.

local Tracking = {}
ns.Tracking = Tracking

local TRACK_INTERVAL = 15       -- seconds between samples of where the party is
local TRACK_MOVED = 30          -- yards a member must move to be written again
local TRACK_STILL = 300         -- seconds after which they are written anyway
local TRACK_MAX_ROWS = 5000     -- rows kept per party member, about 175 KB
local STATS_INTERVAL = 60       -- seconds between XP and gold samples
local NPC_REPEAT = 300          -- seconds before the same NPC counts as a new visit
local LOGIN_DELAY = 5           -- seconds after login before reading talents and the hearthstone

local db, me
local position = {}             -- last outdoor position: c, x, y
local statsLast                 -- text of the last stats row, without its time
local statsDone                 -- the row at the level cap is written
local statsBuffer, trackBuffers = {}, {}
local trackLast = {}            -- guid -> { c, x, y, t } last written
local trackRows = {}            -- guid -> rows saved and buffered
local npcLast = {}              -- name -> time last logged
local lastSub

local function Clean(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function Drop(ok, ...)
    if ok then return ... end
end

-- What fn(...) gives, or nothing when it is missing or errors.
local function Safe(fn, ...)
    if fn then return Drop(pcall(fn, ...)) end
end

local function Round(v)
    return math.floor(v + 0.5)
end

local function AtCap()
    local cap = Clean(Safe(GetMaxPlayerLevel))
    return (Clean(Safe(UnitLevel, "player")) or 0) >= (type(cap) == "number" and cap >= 60 and cap or 60)
end

-- Where unit is: continentID, world x, world y, or nil when hidden.
local function WorldOf(unit)
    local mapID = Clean(Safe(C_Map.GetBestMapForUnit, unit))
    if not mapID then return end
    local pos = Clean(Safe(C_Map.GetPlayerMapPosition, mapID, unit))
    if not pos then return end
    local px, py = Clean(pos.x), Clean(pos.y)
    if not px or not py or (px == 0 and py == 0) then return end
    local c, world = Safe(C_Map.GetWorldPosFromMapPos, mapID, pos)
    c, world = Clean(c), Clean(world)
    if not c or not world then return end
    return c, Round(world.x), Round(world.y)
end

local function Log(kind, ...)
    if db.off[kind] then return end
    if not IsInInstance() then
        local c, x, y = WorldOf("player")
        if c then position.c, position.x, position.y = c, x, y end
    end
    local e = { ns.Now(), kind, position.c or -1, position.x or 0, position.y or 0, ... }
    table.insert(me.events, e)
    return e
end

-- Subzones ------------------------------------------------------------------------

local function CheckSub()
    local zone, sub = Clean(Safe(GetZoneText)) or "", Clean(Safe(GetSubZoneText)) or ""
    if zone == "" then return end
    local place = sub ~= "" and sub or zone
    if place == lastSub then return end
    lastSub = place
    local key = zone .. "/" .. place
    if Log("sub", zone, sub ~= "" and sub or nil, not me.seen[key] or nil) then
        me.seen[key] = true
    end
end

-- XP and gold ----------------------------------------------------------------------

local function SampleStats()
    if db.off.stats or statsDone then return end
    local xp, xpMax = Clean(Safe(UnitXP, "player")) or 0, Clean(Safe(UnitXPMax, "player")) or 0
    local money = Clean(Safe(GetMoney)) or 0
    -- These all read 0 while logging out; a real row has at least an XP bar or gold.
    if xpMax == 0 and money == 0 then return end
    local row = ("%d,%d,%d,%d,%d"):format(Clean(Safe(UnitLevel, "player")) or 0, xp, xpMax,
        Clean(Safe(GetXPExhaustion)) or 0, money)
    if row == statsLast then return end
    statsLast = row
    statsDone = AtCap()
    statsBuffer[#statsBuffer + 1] = ns.Now() .. "," .. row .. ";"
end

-- Party positions ------------------------------------------------------------------

-- The units worth following: the party, or a raid's own subgroup, since
-- forty tracks would be most of the file and hardly any of the story.
local function TrackedUnits()
    local units = {}
    if IsInRaid() then
        local mine
        for i = 1, GetNumGroupMembers() do
            if UnitIsUnit("raid" .. i, "player") then
                mine = select(3, GetRaidRosterInfo(i))
            end
        end
        for i = 1, GetNumGroupMembers() do
            if select(3, GetRaidRosterInfo(i)) == mine and not UnitIsUnit("raid" .. i, "player") then
                units[#units + 1] = "raid" .. i
            end
        end
    else
        for i = 1, GetNumSubgroupMembers() do
            units[#units + 1] = "party" .. i
        end
    end
    return units
end

local function TrackUnit(unit, t)
    local guid = Clean(Safe(UnitGUID, unit))
    local name = Clean(Safe(UnitName, unit))
    if not guid or not name or name == UNKNOWNOBJECT or not UnitIsConnected(unit) then return end
    local c, x, y = WorldOf(unit)
    if not c then return end
    local last = trackLast[guid]
    if last and last[1] == c and t - last[4] < TRACK_STILL then
        local dx, dy = x - last[2], y - last[3]
        if dx * dx + dy * dy < TRACK_MOVED * TRACK_MOVED then return end
    end
    trackLast[guid] = { c, x, y, t }
    local p = me.people[guid]
    if not p then
        p = { d = "" }
        me.people[guid] = p
    end
    trackRows[guid] = trackRows[guid] or select(2, p.d:gsub(";", ""))
    if trackRows[guid] >= TRACK_MAX_ROWS then return end
    trackRows[guid] = trackRows[guid] + 1
    p.name, p.class = name, Clean((select(2, Safe(UnitClass, unit)))) or p.class
    local buffer = trackBuffers[guid] or {}
    trackBuffers[guid] = buffer
    buffer[#buffer + 1] = ("%d,%d,%d,%d,%d;"):format(t, c, x, y, Clean(Safe(UnitLevel, unit)) or 0)
end

local function SampleParty()
    if db.off.party or IsInInstance() or not IsInGroup() or AtCap() then return end
    local t = ns.Now()
    for _, unit in ipairs(TrackedUnits()) do
        TrackUnit(unit, t)
    end
end

-- Only at logout: saved data is written only then anyway, and
-- each pass copies the whole string.
local function Pack()
    if #statsBuffer > 0 then
        me.stats = me.stats .. table.concat(statsBuffer)
        wipe(statsBuffer)
    end
    for guid, buffer in pairs(trackBuffers) do
        if #buffer > 0 then
            local p = me.people[guid]
            p.d = p.d .. table.concat(buffer)
            wipe(buffer)
        end
    end
end

-- Talents ---------------------------------------------------------------------------

-- Classic clients give name, icon, points; newer ones id, name, text, icon, points.
local function TalentTab(i)
    local a, b, c, _, e = GetTalentTabInfo(i)
    if type(a) == "number" then return b, e end
    return a, c
end

local function CheckTalents(baseline)
    if not GetNumTalentTabs then return end
    local parts = {}
    for i = 1, GetNumTalentTabs() do
        local name, points = Safe(TalentTab, i)
        if name then parts[#parts + 1] = ("%s %d"):format(name, tonumber(points) or 0) end
    end
    local text = table.concat(parts, " / ")
    if text ~= "" and text ~= me.talents then
        if me.talents or not baseline then Log("tal", text) end
        me.talents = text
    end
end

-- Places ----------------------------------------------------------------------------

local function CheckBind()
    local place = Clean(Safe(GetBindLocation))
    if place and place ~= me.bind then
        me.bind = place
        Log("bind", place)
    end
end

local function NoteNPC(what)
    local name = Clean(Safe(UnitName, "npc")) or ""
    local t = ns.Now()
    local key = what .. name
    if npcLast[key] and t - npcLast[key] < NPC_REPEAT then return end
    npcLast[key] = t
    Log("npc", what, name ~= "" and name or nil)
end

-- Which flight is being taken, from the open taxi map.
local function NoteTaxi(index)
    local from
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then from = TaxiNodeName(i) end
    end
    Log("taxi", from, TaxiNodeName(index), TaxiNodeCost(index))
end

-- Events ----------------------------------------------------------------------------

local function Every(seconds, fn)
    C_Timer.NewTicker(seconds, function() ns.SafeCall(fn) end)
end

ns.On("PLAYER_LOGIN", function()
    local guid = ns.PlayerGUID()
    if not guid then return end
    db = ns.db.tracking
    me = db.chars[guid] or { events = {}, people = {}, seen = {}, stats = "" }
    db.chars[guid] = me
    me.name, me.realm = UnitName("player"), GetRealmName()
    me.race = select(2, UnitRace("player"))
    me.class = select(2, UnitClass("player"))
    me.faction = UnitFactionGroup("player")
    me.sex = UnitSex("player")

    local _, build, _, interface = GetBuildInfo()
    Log("env", build, interface)
    CheckSub()
    SampleStats()
    C_Timer.After(LOGIN_DELAY, function()
        ns.SafeCall(CheckTalents, true)
        ns.SafeCall(CheckBind)
    end)
    Every(TRACK_INTERVAL, SampleParty)
    Every(STATS_INTERVAL, SampleStats)
    if hooksecurefunc and TakeTaxiNode then
        hooksecurefunc("TakeTaxiNode", function(index) ns.SafeCall(NoteTaxi, index) end)
    end
end)

-- For events that need the login above, which runs on PLAYER_LOGIN.
local function OnReady(event, fn)
    ns.On(event, function(...)
        if me then fn(...) end
    end)
end

OnReady("PLAYER_LOGOUT", function()
    SampleStats()
    Pack()
end)
OnReady("ZONE_CHANGED", CheckSub)
OnReady("ZONE_CHANGED_INDOORS", CheckSub)
OnReady("ZONE_CHANGED_NEW_AREA", CheckSub)
OnReady("PLAYER_ENTERING_WORLD", CheckSub)
OnReady("PLAYER_LEVEL_UP", SampleStats)
OnReady("CHARACTER_POINTS_CHANGED", function() CheckTalents(false) end)
OnReady("HEARTHSTONE_BOUND", CheckBind)
OnReady("PLAYER_UPDATE_RESTING", function()
    local resting = IsResting() and true or false
    if resting ~= me.resting then
        me.resting = resting
        Log("rest", resting)
    end
end)
OnReady("MERCHANT_SHOW", function() NoteNPC("vendor") end)
OnReady("TRAINER_SHOW", function() NoteNPC("trainer") end)
OnReady("BANKFRAME_OPENED", function() NoteNPC("bank") end)
OnReady("AUCTION_HOUSE_SHOW", function() NoteNPC("auction") end)
OnReady("MAIL_SHOW", function() NoteNPC("mail") end)
OnReady("TRADE_SHOW", function()
    Log("trade", Clean(Safe(UnitName, "NPC")))
end)
OnReady("SCREENSHOT_SUCCEEDED", function() Log("shot") end)

ns.Command("note", "pin a note to this spot on the map: /rts note <text>", function(text)
    if not me then return end
    if text == "" then
        ns.Print("Type /rts note and your text.")
        return
    end
    Log("note", text)
    ns.Print("Noted here: " .. text)
end)
