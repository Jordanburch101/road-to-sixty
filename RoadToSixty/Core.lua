local addonName, ns = ...

local defaults = {
    greet = true,
    terrain = true,
    motes = true,
    showPaths = {},     -- roster key -> true to draw that character's path on the map
    historyFilter = {   -- history category -> false when hidden
        quests = false, -- hundreds of turn-ins would crowd the list; opt in
    },
    minimap = { angle = 215, hide = false },  -- minimap button, angle in degrees
    showGear = false,   -- gear card on the journey map, following the replay
    questPops = true,   -- quest turn-ins popping up on the map during the replay
}

-- Per-character journey data. Bump version when the layout changes.
local charDefaults = {
    version = 1,
    segments = {},
    events = {},
    levels = {},
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
    ns.char = RoadToSixtyCharDB

    -- SavedVariables are written on logout and /reload, so the data on disk
    -- is as of this load.
    ns.loadedAt = time()
end)

ns.On("PLAYER_LOGIN", function()
    if ns.db.greet then
        Print("Recording your journey. Type /rts for commands.")
    end
end)

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
