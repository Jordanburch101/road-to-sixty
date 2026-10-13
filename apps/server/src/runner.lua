-- Merges a character's upload into its merged journey for the sync server
-- (#1), under standard Lua 5.1 with the addon's own files: the same
-- Prepare, tidy, Merge and Check the addon runs at login. src/lua.ts runs
-- it as a process of its own, given only the two files.
--
--   lua5.1 runner.lua <lua dir> <upload> <current or ""> <out> <pc> <max MB> <max seconds>
--
-- <upload> is the SavedVariables file a PC uploaded, <current> the
-- character's merged journey as Parse.Write text (none for a first
-- upload), <pc> the uploading device's ID. Writes the result to <out> as
-- Parse.Write text and prints one line, - for anything unknown:
--   ok <layout uploaded> <layout> <level> <played> <last seen>
--   rejected <layout uploaded> <reason>

local dir, uploadPath, currentPath, outPath, pc, maxMB, maxSeconds = ...

-- Data can't hold code, so only a fault in the merge could run away, but a
-- stuck merge must never hold up the worker: checked every 10,000
-- instructions, and lua.ts kills the process if even this fails.
-- ponytail: one huge string operation between checks can pass the memory
-- limit; the 32 MB upload limit bounds how far.
local started, limitKB, limitSeconds = os.clock(), tonumber(maxMB) * 1024, tonumber(maxSeconds)
debug.sethook(function()
    if collectgarbage("count") > limitKB then error("over the memory limit", 0) end
    if os.clock() - started > limitSeconds then error("over the time limit", 0) end
end, "", 10000)

-- Maps that aren't places: Azeroth and the continents, the UiMap rows of
-- type 2 or less (wago.tools, build 1.60.1.70245). ns.IsPlaceMap finds
-- them in game from the map type; Tidy.Events drops "zone" events for them.
local NOT_PLACES = { [947] = true, [1414] = true, [1415] = true, [1463] = true, [1464] = true }
local function IsPlace(mapID) return mapID ~= nil and not NOT_PLACES[mapID] end

local function Read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local from = "-"

local function Run()
    local ns = {}
    for _, name in ipairs({ "Packed.lua", "Tidy.lua", "Parse.lua", "Tally.lua", "Merge.lua" }) do
        assert(loadfile(dir .. "/" .. name))("RoadToSixty", ns)
    end
    local function TidyUp(char)
        if not char.seeded then ns.Tidy.Runs(char) end
        ns.Tidy.Events(char, IsPlace)
        if not char.seeded then ns.Tidy.Guilds(char) end
    end

    local upload = ns.Parse.File(Read(uploadPath)).RoadToSixtyCharDB
    if type(upload) ~= "table" then error("the upload holds no journey", 0) end
    from = tostring(tonumber(upload.version) or "-")
    if upload.seeded then error("a seeded test journey", 0) end
    local why
    upload, why = ns.Merge.Prepare(upload, pc)
    if not upload then error(why, 0) end
    TidyUp(upload)
    local out = upload
    if currentPath ~= "" then
        local current = ns.Parse.Read(Read(currentPath))
        TidyUp(current)
        out, why = ns.Merge.Merge(current, upload)
        if not out then error(why, 0) end
        local passed, failed = ns.Merge.Check(current, upload, out)
        if not passed then error(failed, 0) end
    end
    local file = assert(io.open(outPath, "wb"))
    file:write(ns.Parse.Write(out))
    file:close()

    local level, last
    for l in pairs(out.levels or {}) do
        if type(l) == "number" and (not level or l > level) then level = l end
    end
    for _, e in ipairs(out.events) do
        if not last or e[1] > last then last = e[1] end
    end
    return ("ok %s %d %s %s %s"):format(from, out.version, tostring(level or "-"),
        tostring(tonumber(out.played) or "-"), tostring(last or "-"))
end

local ok, result = pcall(Run)
debug.sethook()
if ok then
    io.write(result, "\n")
else
    io.write("rejected ", from, " ", (tostring(result):gsub("\n", " ")), "\n")
end
