local addonName, ns = ...

-- Shared ground for every module: saved variable defaults, ns.On (event
-- bus), ns.Command (slash commands), ns.SafeCall and ns.Print.
--
-- ns.Classic is true on the clients with the classic map art: Classic Era
-- (#72, interface 11509) and the Anniversary realms (20506). Forever
-- (16001 is 1.60.1) repainted every map, so its art has file IDs of its own.
-- ns.Forever is true on Forever (16xxx), and was on its beta and stress
-- test, which used the same client and, from launch, the same folder.
-- ns.Anniversary is true on the Anniversary realms (#75): Era's art, plus
-- zones Era has not (ZoneOverlaysAnniversary.lua) and Outland. It covers
-- every expansion they move on to (TBC is 2xxxx, Wrath will be 3xxxx), up
-- to retail's 1xxxxx: what TBC added stays, and the gear screen takes the
-- level cap from the client (GetMaxPlayerLevel), so Wrath's 80 needs no change.
--
-- Saved variables. RoadToSixtyDB (ns.db) is account-wide: the settings in
-- defaults below (friends are documented in Friends.lua), plus roster (Roster.lua) and pc, this PC's ID (ns.pc),
-- which counts the merge can't rebuild are kept under (Tally.lua). The
-- app's sync folder gives the ID; without the app the addon makes one.
-- RoadToSixtyCharDB (ns.char) is one character's journey, with charDefaults
-- below plus fields that start nil on purpose and are set by the file that
-- owns them:
--   gear       slot -> item ID last seen, for logging real changes (Journal.lua)
--   lastZone   uiMapID of the last zone event (Journal.lua)
--   instance   instance ID while inside one; run holds that visit's totals
--              at entry, so leaving can log a summary (Journal.lua)
--   played     total seconds played, from the last TIME_PLAYED_MSG (Journal.lua)
--   skills     profession -> { rank, max, icon }; nil means professions
--              have never been read, so the first read logs them as a
--              baseline (Crafts.lua)
--   rosterBuilt  layout version of the roster's journey copy last built
--              from the full journey (Roster.lua)
--   seeded     true for a fake journey from /rts seed (Seed.lua)
--   clockFrom  when a journey begun before layout 2 moved to the realm's
--              clock (see DATA_VERSION)
--   syncedVersion  the sync folder version last brought in (Sync.lua)
--   rosterKey  Name-Realm, set at each login after the sync (Roster.lua): the
--              app reads it, since the game's folder names don't give the
--              realm the addon uses
--   journeyId  the journey's stamp, "<GUID>:<start>" (see DATA_VERSION 4),
--              so a namesake made after a character is deleted, or an
--              erased journey, is never merged with the old one (#51)
-- addon is the addon version that last loaded the file (the toc's version
-- placeholder, unfilled, in a developer install), so whatever reads it
-- knows what wrote it. Never write the placeholder itself in a .lua file:
-- the release build fails on any left after packaging.

do
    local interface = GetBuildInfo and select(4, GetBuildInfo()) or 0
    ns.Classic = interface < 16000 or interface >= 17000
    ns.Forever = not ns.Classic
    ns.Anniversary = interface >= 20000 and interface < 100000
    -- (Classic Era itself: the classic art, without the Anniversary realms' additions)
    ns.Era = ns.Classic and not ns.Anniversary
end

local defaults = {
    greet = true,
    levelChat = true,       -- the addon's own summary in chat at each level up
    levelShot = true,       -- a screenshot at each level up (LevelShot.lua)
    terrain = true,
    cityArt = true,     -- with terrain off, capitals show their own street plans
    motes = true,
    showPaths = {},     -- roster key -> true to draw that character's path on the map
    historyFilter = {   -- history category -> false when hidden
        quests = false, -- hundreds of turn-ins would crowd the list; opt in
        recipes = false,    -- crafters learn hundreds too
    },
    minimap = { angle = 215, hide = false },  -- minimap button, angle in degrees
    showGear = false,   -- gear card on the journey map, following the replay
    questPops = true,   -- quest turn-ins popping up on the map during the replay
    killPops = true,    -- kills popping up at the arrow during the replay
    killMarks = true,   -- faint marks on the map where kills happened
    gearBars = "classic",   -- the gear screen's item bars: classic, glow, edges, both or comet (GearScreen.BAR_STYLES)
    friends = {},       -- friends and their synced journeys, see Friends.lua
    autoSync = 0,       -- minutes between automatic syncs with friends; 0 is off
}

-- Layout of RoadToSixtyCharDB; bump it at every change to what is saved
-- or what it means, and bring older files up in Upgrade. A new event kind
-- needs no bump (Merge matches unknown kinds on time and kind; AGENTS.md).
--   1  everything up to 1.8.0 (fields were only ever added)
--   2  times are by the realm's clock (ns.Now). Times in a journey begun
--      earlier are by that PC's clock before clockFrom.
--   3  the counts the merge can't rebuild are tallies by PC (Tally.lua):
--      people[guid] groups, seconds, raids, raidSeconds, dungeons and
--      raidRuns, and rares[key][1]. Older counts become this PC's. class,
--      the character's class (UnitClass's file name), set at each login.
--   4  journeyId, the journey's stamp: "<GUID>:<start>", start 0 for an
--      ordinary journey or the time of an Erase. Set at each login (see
--      PLAYER_LOGIN below) and by ns.ResetCharacter.
local DATA_VERSION = 4

-- Brings a character file saved by an older layout up to DATA_VERSION.
local function Upgrade(char)
    if char.version < 2 then
        char.clockFrom = ns.Now()
    end
    if char.version < 3 then
        ns.Tally.Upgrade(char, ns.pc)
    end
    -- A file from a newer addon keeps its number after a rollback, so the
    -- sync's merge still knows it holds a layout this one does not.
    char.version = math.max(char.version, DATA_VERSION)
end

-- Per-character journey data.
local charDefaults = {
    version = DATA_VERSION,
    segments = {},
    events = {},
    levels = {},
    kills = { d = "", last = 0, names = {} },  -- packed, see Journal.lua
    recipes = {},       -- profession -> { [recipe name] = true }, see Crafts.lua
    people = {},        -- guid -> players grouped with, see Groups.lua
    -- skills (profession -> { rank, max }) is left out: nil until first read
    -- guild (see Guilds.lua) too: nil until first read, false when in none
    -- reps (factionID -> { standing, name }, see Reputation.lua) too
    -- riding and mounts (see Mounts.lua) too
    -- rares (name -> { count, first kill time }, see Rares.lua) too
    totals = {
        kills = 0,
        killXP = 0,
        questXP = 0,
        deaths = 0,
        quests = 0,
        instances = 0,
        distance = 0,
        flown = 0,
    },
}

local function Print(msg)
    print("|cff33ff99" .. addonName .. "|r: " .. msg)
end
ns.Print = Print

local function ApplyDefaults(db, source)
    for k, v in pairs(source) do
        if db[k] == nil then
            db[k] = type(v) == "table" and CopyTable(v) or v
        elseif type(v) == "table" and type(db[k]) == "table" then
            ApplyDefaults(db[k], v)
        end
    end
end

-- Errors caught by SafeCall this session, for /rts check; shown, those
-- SafeShow caught in the journey map and gear screen.
ns.errors = { count = 0, shown = 0 }

-- Calls fn, reporting any error instead of raising it, so one broken handler
-- cannot stop the others or kill the recorder's ticker. WoW hides Lua errors
-- by default, so the first one also gets a chat message.
function ns.SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local errors = ns.errors
        errors.count = errors.count + 1
        errors.last = err
        if errors.count == 1 then
            Print("|cffff4040An error happened while recording. Type /rts check for details.|r")
        end
        geterrorhandler()(err)
    end
end

-- SafeCall for the journey map and the gear screen: their errors are counted
-- apart, so a drawing bug is not reported as the recording breaking.
function ns.SafeShow(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local errors = ns.errors
        errors.shown = errors.shown + 1
        errors.last = err
        if errors.shown == 1 then
            Print("|cffff4040The journey map hit an error. Type /rts check for details.|r")
        end
        geterrorhandler()(err)
    end
end

-- Now in Unix seconds by the realm's clock. Every saved time uses it, so
-- journeys recorded on PCs whose clocks differ line up when merged (#1).
-- GetServerTime was checked on Forever (#35); the PC's clock is the
-- fallback if the client gives none.
function ns.Now()
    local t = GetServerTime and GetServerTime()
    return t and t > 0 and t or time()
end

-- The PC's own clock, only to compare with times the client gives by it
-- (the death recap's timestamps, Deaths.lua). Never saved: see ns.Now.
function ns.PCTime()
    return time()
end

-- Index of the last entry of times (sorted ascending) that is at or before
-- t, or 0 if none is. For timelines: values[ns.LastIndex(times, t)]. With
-- key, entries are tables sorted by entry[key].
function ns.LastIndex(times, t, key)
    local lo, hi = 0, #times
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local v = times[mid]
        if key then
            v = v[key]
        end
        if v <= t then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo
end

-- Event bus so each module can listen without owning a frame.
-- Returns false if the client refuses the event (unknown or restricted).
local frame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
    if not handlers[event] then
        if not pcall(frame.RegisterEvent, frame, event) then
            return false
        end
        handlers[event] = {}
    end
    table.insert(handlers[event], fn)
    return true
end

frame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do
        ns.SafeCall(fn, ...)
    end
end)

ns.On("ADDON_LOADED", function(name)
    if name ~= addonName then return end

    RoadToSixtyDB = RoadToSixtyDB or {}
    ApplyDefaults(RoadToSixtyDB, defaults)
    ns.db = RoadToSixtyDB
    local synced = type(RoadToSixtySync) == "table" and RoadToSixtySync.pc
    if type(synced) == "string" and #synced <= 64 and synced:match("^[%w%-]+$") then
        ns.db.pc = synced
    end
    ns.db.pc = ns.db.pc or ("%06x%06x"):format(math.random(0, 0xffffff), math.random(0, 0xffffff))
    ns.pc = ns.db.pc

    RoadToSixtyCharDB = RoadToSixtyCharDB or {}
    ApplyDefaults(RoadToSixtyCharDB, charDefaults)
    Upgrade(RoadToSixtyCharDB)
    local metadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    RoadToSixtyCharDB.addon = metadata and metadata(addonName, "Version")
    ns.char = RoadToSixtyCharDB
    -- The journey the map shows; another character's with Roster:SetView.
    ns.view = ns.char

    -- SavedVariables are written on logout and /reload, so the data on disk
    -- is as of this load.
    ns.loadedAt = ns.Now()
end)

-- Fills in what a journey is missing as a new character's would have, for
-- a journey that came from the sync folder.
function ns.CharDefaults(char)
    ApplyDefaults(char, charDefaults)
end

-- The logged-in character's GUID, or nil when the client gives none or a
-- secret value, which would error when compared.
local function PlayerGUID()
    local ok, guid = pcall(function()
        local g = UnitGUID("player")
        if issecretvalue and issecretvalue(g) then return nil end
        return type(g) == "string" and g:match("^[%w%-]+$") and g or nil
    end)
    return ok and guid or nil
end
ns.PlayerGUID = PlayerGUID

local function StampGUID(char)
    return type(char.journeyId) == "string" and char.journeyId:match("^([%w%-]+):%d+$") or nil
end

-- Keeps the journey of another GUID, about to be wiped from this file, in
-- the roster under that GUID, so the map's Characters list still shows it.
-- The roster already has it when that character played on this account
-- (its copy from its last logout); not when the file came without the
-- account's, copied by hand after a realm transfer, say. Returns its name,
-- and whether the Characters list shows it (Roster:Gone).
local function KeepAside(char, guid)
    local roster = ns.db.roster or {}
    ns.db.roster = roster
    local name, realm = tostring(char.rosterKey or ""):match("^([^%-]+)%-(.+)$")
    local function Listed(e) return not (ns.Roster and ns.Roster.Gone and ns.Roster:Gone(e)) end
    local entry = roster[guid]
    if entry and entry.journey then return entry.name or name, Listed(entry) end
    local journey, level, seen = {}, 1, nil
    for k, v in pairs(char) do journey[k] = v end
    for _, e in ipairs(type(char.events) == "table" and char.events or {}) do
        if e[2] == "lvl" and type(e[6]) == "number" then level = math.max(level, e[6]) end
        if type(e[1]) == "number" then seen = math.max(seen or e[1], e[1]) end
    end
    local kept = {
        name = name, realm = realm, guid = guid, class = char.class, level = level, zone = char.lastZone,
        seen = seen, played = char.played, journey = journey,
    }
    -- Where it was last seen outdoors, as Roster:Sync notes it, for its marker.
    local segments = type(char.segments) == "table" and char.segments or {}
    local last = segments[#segments]
    if ns.Packed and type(last) == "table" then
        local ok, _, xs, ys = pcall(ns.Packed.DecodePath, last, last.d)
        if ok and xs and #xs > 0 then kept.c, kept.x, kept.y = last.c, xs[#xs], ys[#ys] end
    end
    roster[guid] = kept
    return name, Listed(kept)
end

-- Stamps the journey as this character's, first at login so Sync.lua sees
-- it. A file stamped with another GUID was a deleted namesake's (WoW keeps
-- it under the same name), or this character's from before a realm
-- transfer: this character starts fresh, as a new one would, before the
-- recorder, journal and roster read it. The old journey stays in the
-- roster (KeepAside) and on the server if it was ever synced, and the
-- player is told, since a transfer can look like a lost journey.
ns.On("PLAYER_LOGIN", function()
    local guid = PlayerGUID()
    if guid then
        local char, stamped = ns.char, StampGUID(ns.char)
        if stamped and stamped ~= guid then
            local name, listed = KeepAside(char, stamped)
            local addon = char.addon
            wipe(char)
            ApplyDefaults(char, charDefaults)
            char.addon, stamped = addon, nil
            Print(("The journey saved for this character belonged to another character named %s, deleted or moved"
                .. " from another realm. %s, and this character starts a new journey."):format(name or "the same",
                listed and "It is kept in the journey map's Characters list" or "It stays saved on this PC"))
        end
        if not stamped then char.journeyId = guid .. ":0" end
    end
    if ns.db.greet then
        Print("Recording your journey. Type /rts for commands.")
    end
end)

-- Whether a map is a place the player can be in (a zone, city or dungeon),
-- not the continent or world the client sometimes reports at a zone's
-- edges: in the Deadmines' mine it gives Eastern Kingdoms. Journal logs
-- only places as zones, and tidies the rest out of older journeys.
local isPlace = {}
function ns.IsPlaceMap(mapID)
    if not mapID then return false end
    local place = isPlace[mapID]
    if place == nil then
        local info = C_Map.GetMapInfo(mapID)
        place = not (info and info.mapType and info.mapType <= Enum.UIMapType.Continent)
        isPlace[mapID] = place
    end
    return place
end

-- Slash commands: modules add their own with ns.Command.
local commands, commandOrder = {}, {}

function ns.Command(name, help, fn)
    commands[name] = fn
    table.insert(commandOrder, { name = name, help = help })
end

SLASH_ROADTOSIXTY1 = "/rts"
SLASH_ROADTOSIXTY2 = "/roadtosixty"
SlashCmdList.ROADTOSIXTY = function(input)
    local cmd, rest = strtrim(input or ""):match("^(%S*)%s*(.-)$")
    local fn = commands[cmd:lower()]
    if fn then
        fn(rest)
        return
    end
    Print("Commands:")
    for _, entry in ipairs(commandOrder) do
        Print(("  /rts %s - %s"):format(entry.name, entry.help))
    end
end

ns.Command("greet", "toggle login message", function()
    ns.db.greet = not ns.db.greet
    ns.Options:Refresh()
    Print("Login message " .. (ns.db.greet and "enabled" or "disabled") .. ".")
end)

ns.Command("version", "show client build and interface number", function()
    local version, build, _, interface = GetBuildInfo()
    Print(("Client %s (build %s), interface %d."):format(version, build, interface))
end)

ns.Command("reset", "erase this character's journey (type /rts reset confirm)", function(arg)
    if arg ~= "confirm" then
        Print("This erases all journey data for this character. Type /rts reset confirm to do it.")
        return
    end
    ns.ResetCharacter()
    ReloadUI()
end)

-- Empties this character's journey in place, keeping the same table, and
-- brings the recorder and roster in line without needing a reload. The new
-- stamp starts now, so the sync keeps the erased journey apart instead of
-- merging it back.
function ns.ResetCharacter()
    local guid = PlayerGUID() or StampGUID(ns.char)
    wipe(ns.char)
    ApplyDefaults(ns.char, charDefaults)
    if guid then ns.char.journeyId = guid .. ":" .. ns.Now() end
    ns.Recorder:Reset()
    ns.Journal:Reset()
    ns.Roster:Rebuild()
end

--@debug@
-- Only in developer builds: lets saved developer settings (perf, showSkipped)
-- take effect. A release build ignores them even if they were saved.
ns.dev = true

ns.Command("perf", "toggle timing info on the journey map", function()
    ns.db.perf = not ns.db.perf
    Print("Map timing info " .. (ns.db.perf and "shown" or "hidden") .. ".")
end)

-- The game's "blocked from an action" box names no function, so blocked and
-- forbidden calls are kept as they come (some before chat is ready) and
-- printed once the world is up, or with /rts blocked.
local blocked, ready = {}, false
local function ShowBlocked(item)
    Print(("%s: %s blocked %s"):format(item.event, tostring(item.addon), tostring(item.call)))
end
for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    ns.On(event, function(addon, call)
        local item = { event = event, addon = addon, call = call }
        blocked[#blocked + 1] = item
        if ready then ShowBlocked(item) end
    end)
end
ns.On("PLAYER_ENTERING_WORLD", function()
    if ready then return end
    C_Timer.After(3, function()
        ready = true
        for _, item in ipairs(blocked) do ShowBlocked(item) end
    end)
end)
ns.Command("blocked", "list the calls the game blocked this session (developer)", function()
    for _, item in ipairs(blocked) do ShowBlocked(item) end
    Print(("%d blocked."):format(#blocked))
end)
--@end-debug@
