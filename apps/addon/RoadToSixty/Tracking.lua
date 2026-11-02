local _, ns = ...

-- Extra journey tracking, for Viewer/index.html: what the map has no use for
-- yet, kept apart from the journey so it cannot touch the recorder or the
-- sync. It lives in the account-wide file, under ns.db.tracking:
--
--   off    = { [what] = true } tracking turned off: an event kind below, or
--            party or stats (Options.lua)
--   build  client build the maps were read from
--   interface  the client's interface number, which tells the viewer which art
--   maps   = { [uiMapID] = { name, parent, type, c, n1, w1, n2, w2 } }: every
--            map's world rectangle in yards, top left and bottom right (north,
--            west); c and on are nil for maps with no world position
--   chars  = { [GUID] = {
--     name, realm, race, sex, class, faction,
--     seen   = { [subzone] = true } places been, to mark first visits,
--     stats  = "t,level,xp,xpMax,rested,money;..." one row a minute, on change,
--     people = { [GUID] = { name, class, d = "t,c,x,y,level;..." } } where
--              party members were, sampled outdoors,
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
-- Anything may come back secret or be missing on one client or another, so
-- every client read goes through Safe and Clean, and a read that fails just
-- records nothing.

local Tracking = {}
ns.Tracking = Tracking

local TRACK_INTERVAL = 15       -- seconds between samples of where the party is
local TRACK_MOVED = 30          -- yards a member must move to be written again
local TRACK_STILL = 300         -- seconds after which they are written anyway
local STATS_INTERVAL = 60       -- seconds between XP and gold samples
local PACK_INTERVAL = 60        -- seconds between writes of the buffers into their strings
local NPC_REPEAT = 300          -- seconds before the same NPC counts as a new visit
local MAP_DELAY = 5             -- seconds after login before reading the maps
local WORLD_MAP = 947
local COSMIC_MAP = 946

local db, me
local position = {}             -- last outdoor position: c, x, y
local statsLast                 -- text of the last stats row, without its time
local statsBuffer, trackBuffers = {}, {}
local trackLast = {}            -- guid -> { c, x, y, t } last written
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

-- Where unit is: continentID, world x, world y, or nil when hidden.
local function WorldOf(unit)
    local mapID = Clean(Safe(C_Map.GetBestMapForUnit, unit))
    if not mapID then return end
    local pos = Clean(Safe(C_Map.GetPlayerMapPosition, mapID, unit))
    if not pos or (pos.x == 0 and pos.y == 0) then return end
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

-- Maps --------------------------------------------------------------------------

-- The world rectangle of a map: continent, then north and west of its top
-- left and bottom right corners.
local function MapRect(mapID)
    local c, a = Safe(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(0, 0))
    local _, b = Safe(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(1, 1))
    c, a, b = Clean(c), Clean(a), Clean(b)
    if c and a and b then return c, Round(a.x), Round(a.y), Round(b.x), Round(b.y) end
end

local function AddMap(mapID)
    local info = Clean(Safe(C_Map.GetMapInfo, mapID))
    if not info or not info.name then return end
    db.maps[mapID] = { info.name, info.parentMapID, info.mapType, MapRect(mapID) }
end

-- Reads every map once for each client build: the viewer has no game data,
-- so this is how it knows the names and where the zones are.
local function ReadMaps()
    local build = select(2, GetBuildInfo())
    if db.build == build and next(db.maps) then return end
    db.build = build
    for _, root in ipairs({ COSMIC_MAP, WORLD_MAP }) do
        AddMap(root)
        for _, info in ipairs(Safe(C_Map.GetMapChildrenInfo, root, nil, true) or {}) do
            AddMap(info.mapID)
        end
    end
end

-- Subzones ------------------------------------------------------------------------

local function CheckSub()
    local zone, sub = Clean(Safe(GetZoneText)) or "", Clean(Safe(GetSubZoneText)) or ""
    if zone == "" then return end
    local place = sub ~= "" and sub or zone
    if place == lastSub then return end
    lastSub = place
    local key = zone .. "/" .. place
    local first = not me.seen[key] or nil
    me.seen[key] = true
    Log("sub", zone, sub ~= "" and sub or nil, first)
end

-- XP and gold ----------------------------------------------------------------------

local function SampleStats()
    if db.off.stats then return end
    local xp, xpMax, money = UnitXP("player") or 0, UnitXPMax("player") or 0, GetMoney() or 0
    -- These all read 0 while logging out; a real row has at least an XP bar or gold.
    if xpMax == 0 and money == 0 then return end
    local row = ("%d,%d,%d,%d,%d"):format(UnitLevel("player") or 0, xp, xpMax, GetXPExhaustion() or 0, money)
    if row == statsLast then return end
    statsLast = row
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
    local guid = Clean(UnitGUID(unit))
    local name = Clean(UnitName(unit))
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
    p.name, p.class = name, select(2, UnitClass(unit)) or p.class
    local buffer = trackBuffers[guid] or {}
    trackBuffers[guid] = buffer
    buffer[#buffer + 1] = ("%d,%d,%d,%d,%d;"):format(t, c, x, y, Clean(UnitLevel(unit)) or 0)
end

local function SampleParty()
    if db.off.party or IsInInstance() or not IsInGroup() then return end
    local t = ns.Now()
    for _, unit in ipairs(TrackedUnits()) do
        TrackUnit(unit, t)
    end
end

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
    db.interface = interface
    Log("env", build, interface)
    CheckSub()
    SampleStats()
    C_Timer.After(MAP_DELAY, function()
        ns.SafeCall(ReadMaps)
        ns.SafeCall(CheckTalents, true)
        ns.SafeCall(CheckBind)
    end)
    Every(TRACK_INTERVAL, SampleParty)
    Every(STATS_INTERVAL, SampleStats)
    Every(PACK_INTERVAL, Pack)
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

ns.Command("export", "how to open your journey in the offline viewer", function()
    if me then Pack() end
    ns.Print("The game writes saved data at logout or /reload. Then open Viewer/index.html in this addon's folder, in Chrome or Edge, and drag in your WTF folder.")
end)
