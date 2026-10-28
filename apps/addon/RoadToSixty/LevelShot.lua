local _, ns = ...

-- A screenshot at each level up, unless turned off (ns.db.levelShot). The
-- game saves it in its own Screenshots folder, as Print Screen does. When
-- the game says it was saved, the level's snapshot (Journal.lua) gets
-- shot = true, which the level up's tooltip on the map and in History
-- shows (LevelShot:Note).

local LevelShot = {}
ns.LevelShot = LevelShot

local DELAY = 1         -- seconds after the level up, so the level up glow is in the picture
local TIMEOUT = 10      -- seconds to wait for the game to say the screenshot was saved

local pending           -- the level whose screenshot is being taken

-- A line for the level up's tooltip when its screenshot was taken, else nil.
function LevelShot:Note(level)
    local snapshot = level and ns.view.levels[level]
    if snapshot and snapshot.shot then return "Screenshot taken" end
end

-- detail with the screenshot line added under it, if there is one.
function LevelShot:Detail(level, detail)
    local note = self:Note(level)
    if not note then return detail end
    return (detail and detail ~= "" and detail .. "\n" or "") .. note
end

local function Take(level)
    if not ns.db.levelShot then return end
    pending = level
    if not pcall(Screenshot) then
        pending = nil
        return
    end
    C_Timer.After(TIMEOUT, function()
        if pending == level then pending = nil end
    end)
end

-- Journal.lua's handler runs first (it loads first), so the snapshot exists.
ns.On("PLAYER_LEVEL_UP", function(level)
    if not ns.db.levelShot or ns.char.seeded then return end
    C_Timer.After(DELAY, function() ns.SafeCall(Take, level) end)
end)

ns.On("SCREENSHOT_SUCCEEDED", function()
    local snapshot = pending and ns.char.levels[pending]
    pending = nil
    if snapshot then snapshot.shot = true end
end)

ns.On("SCREENSHOT_FAILED", function()
    pending = nil
end)

--@debug@
-- /rts levelshot: takes the screenshot a level up would, marking the last
-- recorded level up (the one the map has a marker for), to try it without
-- levelling.
ns.Command("levelshot", "take the level up screenshot for the last level up (developer)", function()
    local level
    for _, e in ipairs(ns.char.events) do
        if e[2] == "lvl" then level = e[6] end
    end
    if not level then
        ns.Print("No level up recorded yet, so the map has no level up to mark.")
        return
    end
    if not ns.char.levels[level] then
        ns.Print(("No snapshot for level %d yet."):format(level))
        return
    end
    Take(level)
    ns.Print(pending and ("Screenshot asked for level %d."):format(level)
        or "Screenshot not taken: the option is off, or the game refused.")
end)
--@end-debug@
