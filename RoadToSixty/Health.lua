local _, ns = ...

-- /rts check: shows whether recording is working, restarts the sampler if it
-- has stopped, and reminds how long the journey has gone unsaved.

local MODE_NAMES = { w = "on foot", t = "flight path", g = "ghost" }

local function Line(text)
    ns.Print("  " .. text)
end

local function Minutes(seconds)
    return math.floor(seconds / 60 + 0.5)
end

ns.Command("check", "check that recording is working", function()
    local Recorder, problems = ns.Recorder, {}

    if Recorder:EnsureRunning() then
        problems[#problems + 1] = "The sampler had stopped. It has been restarted."
    end
    if ns.errors.count > 0 then
        problems[#problems + 1] = ("%d error(s) this session."):format(ns.errors.count)
    end

    if #problems == 0 then
        ns.Print("|cff00ff00Recording OK.|r")
    else
        ns.Print("|cffff4040Recording has a problem:|r")
        for _, problem in ipairs(problems) do
            Line("|cffff4040" .. problem .. "|r")
        end
    end

    local age = Recorder.lastSample and ("%.1f s ago"):format(GetTime() - Recorder.lastSample) or "never"
    Line(("Sampler: last sample %s, %d samples and %d points stored this session."):format(
        age, Recorder.samples, Recorder.stored))

    local c, x, y, mapID = ns.GetWorldPosition()
    if c and not IsInInstance() then
        local info = C_Map.GetMapInfo(mapID)
        Line(("Position: %s, %d, %d, %s."):format(
            info and info.name or "?", x, y, MODE_NAMES[Recorder:Mode()] or "?"))
    else
        Line("Position: not recorded here (instance or loading). Events use your last outdoor spot.")
    end

    local segments, points = Recorder:Stats()
    Line(("Path: %d segments, %d points. Open segment: %d points."):format(
        segments, points, Recorder:OpenPoints()))

    local sessionEvents = 0
    for _, e in ipairs(ns.char.events) do
        if e[1] >= ns.loadedAt then
            sessionEvents = sessionEvents + 1
        end
    end
    Line(("Journal: %d events since load. Kill counting %s."):format(
        sessionEvents, ns.killsTracked and "on" or "|cffff4040unavailable|r"))

    if ns.errors.last then
        Line("Last error: " .. tostring(ns.errors.last))
    end

    Line(("Unsaved for %d min. Logging out or /reload saves it."):format(Minutes(time() - ns.loadedAt)))

    if ns.char.seeded then
        Line("|cffff8040This character has fake seeded data. /rts reset confirm clears it.|r")
    end
end)
