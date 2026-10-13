local _, ns = ...

-- Brings in the journey the Road to Sixty app left in the sync folder
-- (#1): merged into what this PC has, or, for a restore picked on the
-- website, put in its place. The app owns Interface/AddOns/RoadToSixty_Sync,
-- which RoadToSixty.toc lists under OptionalDeps so it loads first. Its
-- data.lua sets one global:
--
--   RoadToSixtySync = {
--       pc = "3f9a1c2b7d4e",       -- optional: this PC's ID (Core.lua uses it)
--       chars = {
--           ["Name-Realm"] = {     -- Roster:Key()
--               version = 42,      -- the server's version number; higher is newer
--               replace = true,    -- optional: a restore
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

-- What a sync folder entry does to char, the journey this PC saved: "same"
-- when that version was already brought in; "merged" or "replaced" with
-- the journey to keep; "problem" with why it can't be used. Tidies char in
-- place, as the login would anyway, and changes nothing else in it.
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
    local why
    journey, why = ns.Merge.Prepare(journey, ns.pc)
    if not journey then return "problem", why end
    TidyUp(char)
    TidyUp(journey)
    if entry.replace then return "replaced", journey end
    local out
    out, why = ns.Merge.Merge(char, journey)
    if not out then return "problem", why end
    local passed, failed = ns.Merge.Check(char, journey, out)
    if not passed then return "problem", failed end
    return "merged", out
end
