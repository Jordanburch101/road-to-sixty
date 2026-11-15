local _, ns = ...

-- /rts perflog: records every frame of the journey map into the saved
-- variables, so how dragging, zooming and builds feel in game can be read
-- afterwards (addons cannot write files; /reload writes the saved
-- variables). Developer only. /rts perflog turns it on or off, and /rts
-- perflog clear empties the log.
--
-- RoadToSixtyDB.perfLog = { started = "date", frames = { "...", ... } },
-- one string a frame, at most MAX_FRAMES (then it stops):
--   "t,frame,lua,drag,zoom"
--     t      GetTime() in seconds
--     frame  ms since the frame before (elapsed): what the player feels
--     lua    ms in the map's OnUpdate this frame, builds included
--     drag   1 while the mouse drags the map
--     zoom   1 while the zoom animates
-- and on a frame with a path build, after it:
--   ",B,build,detail,others,place,lod,placed,kept,lines,otherLines,level,zoomLevel,jumps"
--     build   ms for the whole build (BuildPath)
--     detail  ms choosing the player's lines (DETAIL.Lines)
--     others  ms building other characters' lines
--     place   ms placing lines and jump arcs (jumps included)
--     lod     ms making detail levels on demand
--     placed, kept  lines set down anew, and lines kept where they were
--     lines, otherLines  lines built for the player and for others
--     level   the near part's detail level; zoomLevel the map's zoom
--     jumps   ms of place spent on the jump arcs (BuildJumps)

local PerfLog = {}
ns.PerfLog = PerfLog

local MAX_FRAMES = 40000        -- about ten minutes at 60 frames a second

local lastBuilds

function PerfLog.Frame(elapsed, lua, dragging, state)
    local log = ns.db.perfLog
    if not log then return end
    local frames = log.frames
    local line = ("%.3f,%.1f,%.2f,%d,%d"):format(GetTime(), elapsed * 1000, lua,
        dragging and 1 or 0, state.zoom ~= state.targetZoom and 1 or 0)
    if state.builds ~= lastBuilds then
        lastBuilds = state.builds
        local p = state.perf
        line = line .. (",B,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%.2f,%.2f,%.2f"):format(p.build or 0, p.detail or 0,
            p.others or 0, p.place or 0, p.lod or 0, p.placed or 0, p.kept or 0, state.lineCount or 0,
            state.otherLineCount or 0, state.lodLevel or 0, state.zoom, p.jumps or 0)
    end
    frames[#frames + 1] = line
    if #frames >= MAX_FRAMES then
        PerfLog.on = false
        ns.Print(("Map frame log full at %d frames and stopped. /reload writes it."):format(#frames))
    end
end

ns.Command("perflog", "record every map frame into the saved variables, /reload to write them; 'clear' empties it (developer)", function(arg)
    if arg == "clear" then
        ns.db.perfLog = PerfLog.on and { started = date(), frames = {} } or nil
        ns.Print("Map frame log cleared.")
        return
    end
    PerfLog.on = not PerfLog.on
    if PerfLog.on then
        ns.db.perfLog = ns.db.perfLog or { started = date(), frames = {} }
        lastBuilds = nil
        ns.Print(("Map frame log on (%d frames so far). Open the map, drag and zoom, then /reload to write it."):format(#ns.db.perfLog.frames))
    else
        ns.Print(("Map frame log off, %d frames. /reload writes it."):format(#(ns.db.perfLog and ns.db.perfLog.frames or {})))
    end
end)
