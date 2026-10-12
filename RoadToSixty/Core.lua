local addonName, ns = ...

-- Shared ground for every module: saved variable defaults, ns.On (event
-- bus), ns.Command (slash commands), ns.SafeCall and ns.Print.
--
-- Saved variables. RoadToSixtyDB (ns.db) is account-wide: the settings in
-- defaults below, plus roster (Roster.lua). RoadToSixtyCharDB (ns.char) is
-- one character's journey, with charDefaults below plus fields that start
-- nil on purpose and are set by the file that owns them:
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
-- addon is the addon version that last loaded the file ("@project-version@"
-- in a developer install), so whatever reads it knows what wrote it.

local defaults = {
    greet = true,
    levelChat = true,       -- the addon's own summary in chat at each level up
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
}

-- Layout of RoadToSixtyCharDB; bump it at every change to what is saved
-- or what it means, and bring older files up in Upgrade.
--   1  everything up to 1.8.0 (fields were only ever added)
--   2  times are by the realm's clock (ns.Now). Times in a journey begun
--      earlier are by that PC's clock before clockFrom.
local DATA_VERSION = 2

-- Brings a character file saved by an older layout up to DATA_VERSION.
local function Upgrade(char)
    if char.version < 2 then
        char.clockFrom = ns.Now()
    end
    char.version = DATA_VERSION
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

-- Errors caught by SafeCall this session, for /rts check.
ns.errors = { count = 0 }

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

-- Now in Unix seconds by the realm's clock. Every saved time uses it, so
-- journeys recorded on PCs whose clocks differ line up when merged (#1).
-- GetServerTime was checked on Forever (#35); the PC's clock is the
-- fallback if the client gives none.
function ns.Now()
    local t = GetServerTime and GetServerTime()
    return t and t > 0 and t or time()
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

ns.On("PLAYER_LOGIN", function()
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
-- brings the recorder and roster in line without needing a reload.
function ns.ResetCharacter()
    wipe(ns.char)
    ApplyDefaults(ns.char, charDefaults)
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
--@end-debug@
