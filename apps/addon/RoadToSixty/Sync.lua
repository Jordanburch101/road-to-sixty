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
--           ["Name-Realm"] = {     -- Roster:Name(), the journey's rosterKey ("First Last-Realm" on Forever)
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

-- Whether copy has every session char has, by their logins.
local function HasSessions(copy, char)
    local has = {}
    for _, e in ipairs(copy.events or {}) do
        if e[2] == "on" then has[e[1]] = true end
    end
    for _, e in ipairs(char.events or {}) do
        if e[2] == "on" and not has[e[1]] then return false end
    end
    return true
end

-- What a sync folder entry does to char, the journey this PC saved: "same"
-- when that version was already brought in; "merged" or "replaced" with
-- the journey to keep; "problem" with why it can't be used. Tidies char in
-- place, as the login would anyway, and changes nothing else in it. An
-- entry for another journey of this name (another GUID's, or the one
-- before an erase here) is "same": nothing to bring in.
-- was is the realm char was saved under when that isn't the entry's: "" for
-- none (1.20.11's "First Last-"), nil when it is the entry's. The server's
-- copy under the entry's name then may not hold char's play at all: it went
-- up to another row, or was refused and never went up. A restore picked for
-- the entry would throw that play away for good, so it is merged instead.
-- What the restore took out may come back; nothing is lost.
-- The third value of "merged" is whether the entry already held every
-- session of char's.
function Sync.Apply(char, entry, was)
    if type(entry) ~= "table" or type(entry.version) ~= "number" then
        return "problem", "the sync folder's entry has no version number"
    end
    -- (brought in from another realm's row, it says nothing of this one)
    local synced = (was == nil or was == "") and char.syncedVersion or nil
    if synced and entry.version <= synced then return "same" end
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
    local restored = was == nil and ((restore and (synced or 0) < restore) or (not restore and entry.replace))
    if erased or restored then
        return "replaced", journey
    end
    local held = HasSessions(journey, char)
    local out
    out, why = ns.Merge.Merge(char, journey)
    if not out then return "problem", why end
    local passed, failed = ns.Merge.Check(char, journey, out)
    if not passed then return "problem", failed end
    return "merged", out, held
end

-- The realm the server knows this character by, from the sync folder.
-- Forever's client 71037 gives no realm (Roster.lua's ns.RealmName), so a
-- PC names it by what it has: the name 1.20.11 saved as "First Last-",
-- which the app refuses to back up, or another character's realm on that
-- server, or the realm's ruleset. Two PCs can then name one character two
-- ways, and the server keeps it as two rows, each PC merging only its own
-- for good. The entries whose journey belongs to this character's GUID (its
-- stamp is "<GUID>:<start>") name it as the server does. Every PC's folder
-- holds every row, so each picks the same one: a realm's own name before a
-- ruleset's, then the first in byte order. (A row the server can't hand
-- over yet is missing, so a PC may pick another until it is there.) Nil if
-- no entry holds it.
function Sync.RealmFor(chars, guid)
    if type(guid) ~= "string" or guid == "" then return nil end
    local rules = ns.IsRulesRealm or function(_) return false end
    local found
    for key, entry in pairs(chars) do
        local realm = type(key) == "string" and key:match("^[^%-]+%-(.+)$")
        local journey = realm and type(entry) == "table" and entry.journey
        -- (the stamp's field, as Parse.Write or the game writes it: other
        -- GUIDs appear in a journey too, a group's members for one)
        if type(journey) == "string" and journey:find('%["journeyId"%]%s*=%s*"' .. guid:gsub("%p", "%%%0") .. ":") then
            local better = not found or rules(found) and not rules(realm)
                or rules(found) == rules(realm) and realm < found
            if better then found = realm end
        end
    end
    return found
end

-- At login, first after Core: before the tidy, the roster and the recorder
-- read the journey, and while the loading screen still hides any wait.
-- A character the folder names otherwise than this PC takes the folder's
-- realm, kept from then on (RealmFor, Roster.lua's realmKept): even when an
-- entry under this PC's name is there too, as two PCs that each uploaded
-- under their own name both see both, and must agree on one.
-- ns.char.movedFrom is the realm the journey was saved under before the one
-- it is under now ("" for none), from the login that moved it until the
-- folder's copy has all its sessions: up to then its play may be in no
-- backup, and the saved name no longer shows it (Apply's was).
ns.On("PLAYER_LOGIN", function()
    local data = RoadToSixtySync
    RoadToSixtySync = nil   -- the journey text is large; the game runs data.lua again at every load
    Sync.found = type(data) == "table"
    -- By the full name, or the first name for a journey the server still
    -- keeps under it (#141): until this character's next upload, or one
    -- whose surname the client hadn't given yet. Another character's
    -- journey under that first name is told apart by its stamp in Apply.
    local chars = Sync.found and type(data.chars) == "table" and data.chars
    local function Find()
        local name, first = ns.Roster:Name(), ns.Roster.FirstName and ns.Roster:FirstName()
        return chars and (name and chars[name] or first and chars[first])
    end
    local kept
    -- The realm it was saved under, "" for none; nil for no name saved.
    local was = type(ns.char.rosterKey) == "string" and ns.char.rosterKey:match("^[^%-]+%-(.*)$") or nil
    -- (Forever only: elsewhere the client names the realm, and is right)
    local realm = chars and ns.Forever and Sync.RealmFor(chars, ns.PlayerGUID and ns.PlayerGUID())
    if realm and ns.Roster:Name() ~= ns.Roster:FullName() .. "-" .. realm then
        kept = ns.Roster:FullName() .. "-" .. realm
        ns.char.rosterKey, ns.char.realmKept = kept, true
    end
    local name = ns.Roster:Name()
    local now = name and name:match("^[^%-]+%-(.*)$")
    if was and now and was ~= now then
        ns.char.movedFrom = was
    end
    local entry = Find()
    if not entry then return end
    local started = debugprofilestop()
    local moved = ns.char.movedFrom
    local ok, what, value, held = pcall(Sync.Apply, ns.char, entry, moved)
    if not ok then what, value = "problem", value end
    local status = { what = what, version = type(entry) == "table" and entry.version or nil }
    if what == "merged" or what == "replaced" then
        local char, addon = ns.char, ns.char.addon
        wipe(char)
        for k, v in pairs(value) do char[k] = v end
        ns.CharDefaults(char)
        char.addon, char.syncedVersion, char.rosterBuilt = addon, entry.version, nil
        -- (the copy may hold the mark of the PC it came from; from here
        -- syncedVersion is this row's, so the mark is as for no realm)
        char.movedFrom = what == "merged" and moved and not held and "" or nil
        -- (the journey brought in may name it otherwise)
        if kept then char.rosterKey, char.realmKept = kept, true end
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
