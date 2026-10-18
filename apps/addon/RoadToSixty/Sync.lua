local _, ns = ...

-- Brings in the journey the Road to Sixty app left in the sync folder
-- (#1): merged into what this PC has, or, for a restore picked in the
-- app, put in its place. The app owns Interface/AddOns/RoadToSixty_Sync,
-- which RoadToSixty.toc lists under OptionalDeps so it loads first. Its
-- data.lua sets one global:
--
--   RoadToSixtySync = {
--       pc = "3f9a1c2b7d4e",       -- optional: this PC's ID (Core.lua uses it)
--       chars = {
--           ["Name-Realm"] = {     -- Roster:Name(), the journey's rosterKey
--               version = 42,      -- the server's version number; higher is newer
--               restore = 40,      -- optional: the restore this PC hasn't taken in yet
--               journey = "...",   -- the journey as Parse.Write text
--           },
--       },
--   }
--
-- The journey is text read only by Parse.Read, which refuses code, so
-- nothing from outside ever runs.

local Sync = {}
ns.Sync = Sync

-- The repairs a login makes (Journal.lua and Guilds.lua run the same),
-- done to both copies first so the merge compares like with like.
local function TidyUp(char)
    if not char.seeded then ns.Tidy.Runs(char) end
    ns.Tidy.Events(char, ns.IsPlaceMap)
    if not char.seeded then ns.Tidy.Guilds(char) end
end

-- A journey's stamp (Core.lua) as its GUID and start, or nil for none.
local function Stamp(char)
    local guid, start = tostring(char.journeyId or ""):match("^(.+):(%d+)$")
    return guid, tonumber(start)
end

-- What a sync folder entry does to char, the journey this PC saved: "same"
-- when that version was already brought in; "merged" or "replaced" with
-- the journey to keep; "problem" with why it can't be used. Tidies char in
-- place, as the login would anyway, and changes nothing else in it. An
-- entry for another journey of this name (another GUID's, or the one
-- before an erase here) is "same": nothing to bring in.
function Sync.Apply(char, entry)
    if type(entry) ~= "table" or type(entry.version) ~= "number" then
        return "problem", "the sync folder's entry has no version number"
    end
    if char.syncedVersion and entry.version <= char.syncedVersion then return "same" end
    if type(entry.journey) ~= "string" then return "problem", "the sync folder's entry has no journey" end
    local ok, journey = pcall(ns.Parse.Read, entry.journey)
    if not ok then return "problem", "the synced journey can't be read (" .. tostring(journey) .. ")" end
    if type(journey) ~= "table" then return "problem", "the synced journey isn't a journey" end
    if (tonumber(journey.version) or 0) > ns.Merge.VERSION then
        return "problem", "it was saved by a newer Road to Sixty. Update the addon on this PC"
    end
    if char.seeded or journey.seeded then return "problem", "a seeded test journey is never merged or restored" end
    local why
    journey, why = ns.Merge.Prepare(journey, ns.pc)
    if not journey then return "problem", why end
    -- Both stamped and different: erased on another PC (same GUID, later
    -- start), which replaces this copy; anything else isn't this journey.
    -- No stamp on either side merges as before stamps.
    local mine, mineStart = Stamp(char)
    local theirs, theirStart = Stamp(journey)
    local erased = mine and theirs and (mine ~= theirs or mineStart ~= theirStart)
    if erased and (mine ~= theirs or theirStart < mineStart) then return "same" end
    TidyUp(char)
    TidyUp(journey)
    -- A restore replaces only a copy older than it. A PC that already took
    -- the restore in has play since then that a replace would throw away.
    -- replace is what app 0.1.1 writes instead of restore.
    local restore = tonumber(entry.restore)
    if erased or (restore and (char.syncedVersion or 0) < restore) or (not restore and entry.replace) then
        return "replaced", journey
    end
    local out
    out, why = ns.Merge.Merge(char, journey)
    if not out then return "problem", why end
    local passed, failed = ns.Merge.Check(char, journey, out)
    if not passed then return "problem", failed end
    return "merged", out
end

-- At login, first after Core: before the tidy, the roster and the recorder
-- read the journey, and while the loading screen still hides any wait.
ns.On("PLAYER_LOGIN", function()
    local data = RoadToSixtySync
    RoadToSixtySync = nil   -- the journey text is large; the game runs data.lua again at every load
    Sync.found = type(data) == "table"
    local entry = Sync.found and type(data.chars) == "table" and data.chars[ns.Roster:Name()]
    if not entry then return end
    local started = debugprofilestop()
    local ok, what, value = pcall(Sync.Apply, ns.char, entry)
    if not ok then what, value = "problem", value end
    local status = { what = what, version = type(entry) == "table" and entry.version or nil }
    if what == "merged" or what == "replaced" then
        local char, addon = ns.char, ns.char.addon
        wipe(char)
        for k, v in pairs(value) do char[k] = v end
        ns.CharDefaults(char)
        char.addon, char.syncedVersion, char.rosterBuilt = addon, entry.version, nil
        ns.Print(what == "merged" and "Brought in your journey from your other PCs."
            or "Restored this character's journey to the version picked in the Road to Sixty app.")
    elseif what == "problem" then
        status.why = tostring(value)
        ns.Print("|cffff4040Could not bring in the synced journey: " .. status.why .. ". Type /rts check.|r")
    end
    status.ms = debugprofilestop() - started
    Sync.status = status
end)

-- One line for /rts check.
function Sync:Describe()
    local s = self.status
    if not self.found then return "Sync: no sync folder. The Road to Sixty app makes one." end
    if not s then return "Sync: nothing for this character in the sync folder." end
    if s.what == "same" then return ("Sync: version %s was already brought in."):format(tostring(s.version)) end
    if s.what == "problem" then
        return ("|cffff4040Sync: could not bring in version %s: %s.|r"):format(tostring(s.version), s.why)
    end
    return ("Sync: %s version %s at login in %d ms."):format(
        s.what == "merged" and "merged" or "restored", tostring(s.version), s.ms)
end
