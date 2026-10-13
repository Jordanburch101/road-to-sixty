-- Makes a sync folder by hand, as the Road to Sixty app will (#1), to try
-- the addon's login merge without the app. Run from the repo root:
--
--   luajit scripts/sync-folder.lua <saved file> <sync folder> <Name-Realm> [replace]
--
-- <saved file> is a character's WTF/.../SavedVariables/RoadToSixty.lua, and
-- <sync folder> is Interface/AddOns/RoadToSixty_Sync, made beforehand. The
-- game reads a new addon folder only when it starts; after that, a /reload
-- picks up a new data.lua. Each run gets a higher version, from the clock.
-- What it writes holds other players' names: never put it in the repo.

local saved, folder, key, replace = arg[1], arg[2], arg[3], arg[4] == "replace"
assert(saved and folder and key, "usage: luajit scripts/sync-folder.lua <saved file> <sync folder> <Name-Realm> [replace]")

local ns = {}
assert(loadfile("RoadToSixty/Parse.lua"))("RoadToSixty", ns)

local function Read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local function Save(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local journey = assert(ns.Parse.File(Read(saved)).RoadToSixtyCharDB, "no RoadToSixtyCharDB in " .. saved)
local interface = assert(Read("RoadToSixty/RoadToSixty.toc"):match("## Interface: (%d+)"), "no Interface in the toc")
local version = os.time()

Save(folder .. "/RoadToSixty_Sync.toc", ("## Interface: %s\n## Title: Road to Sixty Sync\n## Notes: Journeys from your other PCs, written by the Road to Sixty app\ndata.lua\n"):format(interface))
Save(folder .. "/data.lua", ("RoadToSixtySync = { chars = { [%q] = { version = %d, replace = %s, journey = %q } } }\n"):format(
    key, version, tostring(replace), ns.Parse.Write(journey)))
print(("Wrote version %d for %s%s."):format(version, key, replace and ", as a restore" or ""))
