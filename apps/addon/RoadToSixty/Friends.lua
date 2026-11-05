local _, ns = ...

-- Syncing journeys with friends in game, by addon whisper. FriendsPanel.lua
-- is the side panel's Friends tab.
--
-- Adding someone is what shares with them: a journey is only sent to a player
-- on the list, and only taken from one, so two players must add each other.
-- The list is the account's, so every character on it shares with them.
-- A sync is pulled: the side that wants a journey says what it has, and the
-- other sends the next batch of its current character's journey. Each batch
-- is kept as it arrives, so a sync that stops carries on from there, and
-- later syncs only cost what is new. Keys are lowercase names (Key); on
-- Forever, where characters have surnames, full names ("first last"):
--
--   RoadToSixtyDB.friends[key] = {
--     name, realm, class, level, zone, c, x, y, seen, played, synced (time),
--     battleTag (theirs, for grouping their characters), guid,
--     journey = in the form of RoadToSixtyCharDB,
--     size = what the journey's path and events take (Apply), capped = true
--     once that reached MAX_SIZE, metaSum (MetaSum),
--     key = guid, friend = true,
--   }
--   RoadToSixtyDB.autoSync = minutes between automatic syncs; 0 is off
--
-- That is the form of a roster entry, which Roster:Entries lists beside the
-- account's own characters. It stays out of the roster itself, which is only
-- ever the account's own, and out of the character file, so the merge and
-- the sync server never see it.
--
-- An automatic sync simply asks each friend in turn. The game answers with a
-- chat line when one is offline, which is hidden and taken as a no.
--
-- Messages, split by colons, are all whispers:
--   Q:id:version:layout:segments:offset:events:sum:journeyId   what the asker
--                                    has; layout is its character file's version,
--                                    sum its MetaSum
--   N:id:reason                      not sent, and why
--   B:id:n:total:data                part n of a batch
--
-- Anything may arrive from anyone, and a batch comes from someone else's
-- saved file, so it is parsed as plain data and checked before it is kept.

local Friends = {}
ns.Friends = Friends

local PREFIX = "RTSFriends"
local VERSION = 1
local RATE = 3                  -- messages a second; a live test got 4 through whole
local PART = 225                -- characters of a batch in each message
local BATCH = 24000             -- characters of path and events in a batch
local EVENTS_AGAIN = 20         -- latest events sent again, as open ones are filled in later
local MAX_PARTS = 4500          -- the most a batch may be, about 25 minutes
local MAX_DEPTH = 16
local MAX_FAILS = 30            -- refused sends in a row before giving up
local AUTO_MINUTES = { 0, 5, 15, 30 }   -- the choices for automatic syncing; 0 is off
Friends.AUTO_MINUTES = AUTO_MINUTES
local AUTO_GAP = 2              -- seconds between friends in an automatic sync
local HIDE_FOR = 2              -- seconds an offline line stays hidden, for each chat window
local NO_ANSWER = 15            -- seconds to wait for a first answer
local STALLED = 45              -- seconds without a message before a sync counts as stopped

-- The most of a friend's path and events kept, in characters as sent. It
-- sits in the account file every character loads, and a level 60 journey is
-- 2 to 3 MB. The other fields are replaced whole each time, so one batch
-- bounds them.
Friends.MAX_SIZE = 8 * 1024 * 1024

local REASONS = {
    notfriend = "Waiting for them to add you.",
    busy = "They are busy sending. Try again in a moment.",
    nodata = "They have no journey to send.",
    version = "They have another version of Road to Sixty. You both need the latest.",
}
local BUSY = "Another sync is running. Try again when it ends."
local TOO_BIG = "Their journey is too big to keep any more of it."

-- Shapes ----------------------------------------------------------------------------
-- A friend's journey is read by the same code as the account's own, which
-- trusts its shape, so everything a friend sends is checked against the
-- shapes the addon saves. Letters name a value's type: n number, s string,
-- b boolean, t table, c a tally (a number, or a table of numbers, see
-- Tally.lua), . anything but a table. A missing value always fits.

local TYPES = { n = "number", s = "string", b = "boolean", t = "table" }
local Shaped

local function Fits(v, letter)
    if v == nil then return true end
    if letter == "c" then return type(v) == "number" or Shaped(v, nil, "n") end
    if not letter or letter == "." then return type(v) ~= "table" end
    return type(v) == TYPES[letter]
end

-- Whether t is a table whose values fit spec[key], or default for keys spec doesn't name.
function Shaped(t, spec, default)
    if type(t) ~= "table" then return false end
    for key, v in pairs(t) do
        if not Fits(v, spec and spec[key] or default) then return false end
    end
    return true
end

-- Whether every value of t is a table that check passes.
local function Rows(t, check)
    if type(t) ~= "table" then return false end
    for _, row in pairs(t) do
        if type(row) ~= "table" or not check(row) then return false end
    end
    return true
end

local function Whole(v)
    return type(v) == "number" and v == math.floor(v)
end

local function Plain(t) return Shaped(t) end
local function Skill(s) return Shaped(s, { "n", "n", "n" }) end

local PERSON = {
    name = "s", race = "s", sex = "s", class = "s", level = "n", guild = "s", first = "n", last = "n",
    c = "n", x = "n", y = "n",
    groups = "c", seconds = "c", raids = "c", raidSeconds = "c", dungeons = "c", raidRuns = "c",
}

-- Road to Sixty's fields besides the path and events, and the check each must pass.
local FIELDS = {
    levels = function(v)
        for level, snap in pairs(v) do
            if not Whole(level) or not Shaped(snap, { gear = "t", links = "t", skills = "t" })
                or snap.gear and not Shaped(snap.gear, nil, "n")
                or snap.links and not Shaped(snap.links, nil, "s")
                or snap.skills and not Rows(snap.skills, Skill) then
                return false
            end
        end
        return true
    end,
    kills = function(v)
        return Shaped(v, { names = "t" }) and type(v.d) == "string" and type(v.last) == "number"
            and Shaped(v.names, nil, "s")
    end,
    recipes = function(v) return Rows(v, Plain) end,
    people = function(v) return Rows(v, function(p) return Shaped(p, PERSON) end) end,
    totals = function(v) return Shaped(v, nil, "n") end,
    skills = function(v) return Rows(v, Skill) end,
    guild = function(v)
        return v == false or Shaped(v, { "s", "s", "n", "t" }) and type(v[1]) == "string"
            and (v[4] == nil or Shaped(v[4], nil, "c"))
    end,
    reps = function(v) return Rows(v, function(r) return Shaped(r, { "n", "s" }) end) end,
    riding = function(v) return Rows(v, Plain) end,
    mounts = function(v) return Rows(v, Plain) end,
    rares = function(v) return Rows(v, function(r) return Shaped(r, { "c" }) end) end,
    played = function(v) return type(v) == "number" end,
    version = function(v) return type(v) == "number" end,
}

-- The types of each kind's own fields, from e[6] on (Journal.lua lists the
-- kinds). Fields past these, and every field of other kinds, may be anything:
-- a new kind or field doesn't bump DATA_VERSION, so a friend on a newer
-- version can send ones this code has never seen, and nothing here reads them.
local EVENT_FIELDS = {
    on = "nn", off = "n", lvl = "n", die = "s", qa = "n", qd = "nnns", zone = "n",
    ["in"] = "nss", out = "nt", loot = "sn", eq = "nn..t", prof = "snn", skill = "snn",
    rec = "sns", craft = "sn", gj = "ssbt", gl = "ss", gr = "ssb", rep = "nns",
    ride = "ns", mount = "ns", rare = "ss", duel = "ss", gath = "sn.s",
    grp = "stbn", grpa = "t", grpx = "t",
}
local RUN = {
    name = "s", duration = "n", kills = "n", xp = "n", deaths = "n", money = "n", levels = "n",
    items = "t", party = "t", type = "s", pvp = "t",
}
-- What is inside the tables some kinds hold.
local EVENT_TABLES = {
    -- The panel hands the link to the tooltip, which errors on anything but a link.
    loot = function(e) return e[6] == nil or e[6]:find("|Hitem:%d") or e[6]:find("^item:%d") end,
    out = function(e)
        local s = e[7]
        if s == nil then return true end
        if not Shaped(s, RUN) or not Shaped(s.items or {}, nil, "s") then return false end
        for _, field in ipairs({ "duration", "kills", "xp", "deaths", "money", "levels" }) do
            if s[field] == nil then return false end
        end
        return true
    end,
    eq = function(e) return e[10] == nil or Plain(e[10]) end,
    gj = function(e) return e[9] == nil or Shaped(e[9], nil, "c") end,
    grp = function(e) return e[7] == nil or Rows(e[7], Plain) end,
    grpa = function(e) return e[6] == nil or Plain(e[6]) end,
}

local function ValidEvent(e)
    if type(e) ~= "table" or type(e[1]) ~= "number" or type(e[2]) ~= "string" or type(e[3]) ~= "number"
        or type(e[4]) ~= "number" or type(e[5]) ~= "number" then
        return false
    end
    local spec = EVENT_FIELDS[e[2]] or ""
    for key, v in pairs(e) do
        if not Whole(key) or key < 1 then return false end
        local letter = key > 5 and spec:sub(key - 5, key - 5) or ""
        if key <= 5 or letter ~= "" then
            if not Fits(v, letter ~= "" and letter or nil) then return false end
        end
    end
    local check = EVENT_TABLES[e[2]]
    return not check or check(e) and true or false
end

local request                   -- the sync this client is asking for
local outgoing                  -- the batch this client is sending
local status = {}               -- key -> text for the tab
local serial = 0
local autoQueue = {}            -- keys of friends waiting for an automatic sync
local autoRun = 0               -- which schedule is current, as a timer can't be stopped
local hiddenText, hiddenUntil   -- the offline line being kept out of chat
local NextAuto

local function Clean(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function Changed()
    if Friends.OnChange then Friends.OnChange() end
end

local function Later(delay, fn)
    C_Timer.After(delay, function() ns.SafeCall(fn) end)
end

local function Send(text, target)
    local send = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
    if not send then return false end
    local ok, result = pcall(send, PREFIX, text, "WHISPER", target)
    return ok and result ~= false and not (type(result) == "number" and result ~= 0)
end

-- Plain data as text ------------------------------------------------------------------

-- Everything but plain characters is escaped, so a message can be cut anywhere.
local function Escape(s)
    return (s:gsub("[%%~|%c\128-\255]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function Unescape(s)
    return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function Write(out, v, depth)
    local kind = type(v)
    if kind == "number" and v == v and v ~= math.huge and v ~= -math.huge then
        out[#out + 1] = "n" .. ("%.14g"):format(v) .. "~"
    elseif kind == "string" then
        out[#out + 1] = "s" .. Escape(v) .. "~"
    elseif kind == "boolean" then
        out[#out + 1] = v and "t~" or "f~"
    elseif kind == "table" and depth < MAX_DEPTH then
        out[#out + 1] = "{~"
        for key, value in pairs(v) do
            local size = #out
            Write(out, key, MAX_DEPTH)
            if #out > size then
                local keyed = #out
                Write(out, value, depth + 1)
                if #out == keyed then out[keyed] = nil end
            end
        end
        out[#out + 1] = "}~"
    end
end

local function Serialize(v)
    local out = {}
    Write(out, v, 0)
    return table.concat(out)
end

local MOD = 2147483647

local function Hash(text, h)
    for i = 1, #text do h = (h * 31 + text:byte(i)) % MOD end
    return h
end

-- A short sum of v that doesn't depend on the order pairs walks tables in,
-- so two clients holding the same data agree on it.
local function Sum(v, h)
    if type(v) ~= "table" then return Hash(Serialize(v), h) end
    local total = Hash("{", h)
    for key, value in pairs(v) do
        total = (total + Sum(value, Hash(Serialize(key), h))) % MOD
    end
    return total
end

-- The sum of a journey's fields besides the path and events, which the
-- asker sends so the sender can leave them out when they haven't changed.
local function MetaSum(journey)
    local meta = {}
    for field in pairs(FIELDS) do meta[field] = journey[field] end
    return Sum(meta, 0)
end

-- The value in text, or nil unless it is well formed.
-- Keep this one loop with no inner function: LuaJIT, which runs the tests,
-- miscompiled an earlier version whose inner function changed the loop's
-- variables, refusing good batches or crashing at random.
local function Parse(text)
    local stack, depth, root = {}, 0, nil
    local pos, size = 1, #text
    while pos <= size do
        if root ~= nil then return nil end
        local stop = text:find("~", pos, true)
        if not stop then return nil end
        local kind, body = text:sub(pos, pos), text:sub(pos + 1, stop - 1)
        pos = stop + 1
        local value, open
        if kind == "}" then
            local top = stack[depth]
            if not top or top.key ~= nil then return nil end
            stack[depth], depth = nil, depth - 1
            value = top.t
        elseif kind == "n" then
            value = tonumber(body)
            if not value then return nil end
        elseif kind == "s" then
            value = Unescape(body)
        elseif kind == "t" then
            value = true
        elseif kind == "f" then
            value = false
        elseif kind == "{" then
            if depth >= MAX_DEPTH or depth > 0 and stack[depth].key == nil then return nil end
            depth = depth + 1
            stack[depth] = { t = {} }
            open = true
        else
            return nil
        end
        if not open then
            local top = stack[depth]
            if not top then
                root = value
            elseif top.key == nil then
                if type(value) ~= "string" and type(value) ~= "number" then return nil end
                top.key = value
            else
                top.t[top.key], top.key = value, nil
            end
        end
    end
    return root
end

-- Keeping a friend ------------------------------------------------------------------

-- string.lower only knows A to Z, but a name typed "émile" must find the
-- "Émile" the game reports, so accented Latin and Cyrillic capitals are
-- lowered too (UTF-8: É is C3 89, é is C3 A9).
local function Key(name)
    return (name:lower():gsub("\195([\128-\158])", function(c)
        if c ~= "\151" then return "\195" .. string.char(c:byte() + 32) end
    end):gsub("\208([\128-\175])", function(c)
        local b = c:byte()
        if b >= 144 and b < 160 then return "\208" .. string.char(b + 32) end
        return "\209" .. string.char(b < 144 and b + 16 or b - 32)
    end))
end

local function SquashRealm(realm)
    return (realm:gsub("[%s%-]", ""):lower())
end

-- Forever gives every character a surname, and a full name is unique across
-- the region: a friend is "First Last", and needs no realm to tell them apart.
local function Surnames()
    local ok, on = pcall(function() return RegionalUniqueNamesEnabled() end)
    return ok and on == true
end
Friends.Surnames = Surnames

-- This character's name as a friend would type it.
local function MyName()
    local name, surname = UnitName("player")
    if Surnames() and type(surname) == "string" and surname ~= "" then return name .. " " .. surname end
    return name
end

local function Capital(word)
    return word:sub(1, 1):upper() .. word:sub(2):lower()
end

local function NameWord(word)
    return word:find("^[^%s%d%p]+$") or word:find("[\128-\255]")
end

-- A typed name as the friends list keeps it, or nil if it can't be one.
-- With surnames it is "First Last", typed that way or "First-Last" as the
-- chat box takes it; a realm after the full name is dropped.
local function TypedName(text)
    text = strtrim(text or "")
    if Surnames() then
        if text:find("%s") then text = text:gsub("%-.*$", "") end
        local first, last = text:match("^([^%s%-]+)[%s%-]+([^%s%-]+)$")
        if not first or not NameWord(first) or not NameWord(last) then return nil end
        return Capital(first) .. " " .. Capital(last)
    end
    text = text:gsub("%-.*$", "")
    if text == "" or not NameWord(text) then return nil end
    return Capital(text)
end

-- The friends key of a whisper's sender, and their name as the game writes
-- it; nil when they are on another realm than the friend of that name. The
-- sender comes as "Name-Realm", the realm without the spaces and hyphens
-- GetRealmName has. With surnames the realm says nothing, and the sender may
-- come as "First Last", "First Last-Realm" or "First-Last".
local function SenderKey(sender)
    if Surnames() then
        local whole = sender:gsub("%-", " ")
        local cut = sender:match("^(.-)%-[^-]*$")
        cut = cut and cut:gsub("%-", " ")
        for _, name in ipairs({ whole, cut }) do
            if ns.db.friends[Key(name)] then return Key(name), name end
        end
        return Key(cut or whole), cut or whole
    end
    local name, realm = sender:match("^([^-]+)%-?(.*)$")
    if not name then return nil end
    local key = Key(name)
    local rec = ns.db.friends[key]
    if rec and realm ~= "" and SquashRealm(realm) ~= SquashRealm(rec.realm or GetRealmName()) then return nil end
    return key, name
end

-- Whether a friend's guid may be used: never one of this account's characters.
local function FreeSlot(guid)
    return guid ~= ns.PlayerGUID() and not ns.db.roster[guid]
end

local function NewJourney()
    return {
        segments = {}, events = {}, levels = {}, recipes = {}, people = {},
        kills = { d = "", last = 0, names = {} },
        totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 },
    }
end

local function ValidSegment(s)
    return Whole(s.i) and type(s.d) == "string" and s.d:find("^[-%d,;]*$") ~= nil
        and (s.o ~= nil and Whole(s.o) or (
            (s.m == "w" or s.m == "t" or s.m == "g") and Whole(s.c) and Whole(s.t)
            and Whole(s.x) and Whole(s.y) and (s.j == nil or type(s.j) == "string")))
end

-- Puts a batch into the friend's journey. False if it does not fit, and then
-- none of it is kept; false, "big" if it would take them over MAX_SIZE.
-- rec.size is what their path and events take, in characters as sent.
local function Apply(rec, b)
    if type(b) ~= "table" or type(b.g) ~= "string" or not b.g:find("^Player%-%d+%-%x+$")
        or type(b.j) ~= "string" or type(b.s) ~= "table" or not FreeSlot(b.g) then
        return false
    end
    local fresh = b.r or rec.guid ~= b.g or not rec.journey
    local journey = fresh and NewJourney() or rec.journey
    local segments, events = journey.segments, journey.events
    local size = not fresh and rec.size or 0

    local segs, count = {}, #segments
    for i = 1, #b.s do
        local s = b.s[i]
        if type(s) ~= "table" or not ValidSegment(s) then return false end
        local prev, seg = segs[s.i] or segments[s.i], nil
        if s.o then
            if not prev or #prev.d ~= s.o then return false end
            -- A new table, as Road to Sixty decodes each once.
            seg = { m = prev.m, c = prev.c, j = prev.j, t = prev.t, x = prev.x, y = prev.y, d = prev.d .. s.d }
        elseif s.i >= 1 and s.i <= count + 1 then
            seg = { m = s.m, c = s.c, j = s.j, t = s.t, x = s.x, y = s.y, d = s.d }
        else
            return false
        end
        segs[s.i], count = seg, math.max(count, s.i)
        size = size + #seg.d + 40 - (prev and #prev.d + 40 or 0)
    end

    if b.e then
        if type(b.e) ~= "table" or not Whole(b.ef) or b.ef < 1 or b.ef > #events + 1 then return false end
        for i = 1, #b.e do
            local e, prev = b.e[i], events[b.ef + i - 1]
            if not ValidEvent(e) then return false end
            size = size + #Serialize(e) - (prev and #Serialize(prev) or 0)
        end
    end

    if b.m ~= nil then
        if type(b.m) ~= "table" then return false end
        for field, check in pairs(FIELDS) do
            local value = b.m[field]
            if value ~= nil and not check(value) then return false end
        end
    end
    if size > Friends.MAX_SIZE then return false, "big" end

    for i, seg in pairs(segs) do segments[i] = seg end
    for i = 1, b.e and #b.e or 0 do events[b.ef + i - 1] = b.e[i] end
    for field in pairs(b.m and FIELDS or {}) do
        if b.m[field] ~= nil then journey[field] = b.m[field] end
    end
    journey.journeyId = b.j
    rec.journey, rec.guid, rec.size = journey, b.g, size
    if fresh or b.m then rec.metaSum = MetaSum(journey) end
    if type(b.class) == "string" and b.class:find("^%u+$") then rec.class, journey.class = b.class, b.class end
    if Whole(b.level) then rec.level = b.level end
    if Whole(b.zone) then rec.zone = b.zone end
    if Whole(b.c) and type(b.x) == "number" and type(b.y) == "number" then
        rec.c, rec.x, rec.y = b.c, b.x, b.y
    end
    if type(b.played) == "number" then rec.played = b.played end
    if type(b.tag) == "string" and #b.tag <= 32 and b.tag:find("^[^#|%c]+#%d+$") then rec.battleTag = b.tag end
    -- A character new to their roster has no last position yet.
    local last = segments[#segments]
    if last and not rec.c then rec.c, rec.x, rec.y = last.c, last.x, last.y end
    rec.realm = rec.realm or GetRealmName()
    rec.seen = ns.Now()
    rec.key, rec.friend = rec.guid, true
    return true
end

-- Asking ----------------------------------------------------------------------------

-- Drops the sync being asked for, and with it the lines saying to wait for it.
local function Stop()
    request = nil
    for key, text in pairs(status) do
        if text == BUSY then status[key] = nil end
    end
end

-- Ends a sync. An automatic one only reports what needs looking at, with
-- keep: a friend being offline is not worth a line.
local function Finish(key, text, keep)
    local auto = request and request.key == key and request.auto
    if request and request.key == key then Stop() end
    if auto and not keep then text = nil end
    status[key] = text
    Changed()
    if autoQueue[1] then Later(AUTO_GAP, NextAuto) end
end

-- Gives up when nothing has come for a while.
local function Watch(asked)
    Later(5, function()
        if request ~= asked then return end
        local limit = asked.answered and STALLED or NO_ANSWER
        if GetTime() - asked.heard < limit then return Watch(asked) end
        Finish(asked.key, asked.answered and "Stopped. Sync again to carry on."
            or "No answer. They need this version of Road to Sixty and must be online.")
    end)
end

local function Ask(rec, key, bytes, auto)
    if rec.capped then
        Finish(key, TOO_BIG, true)
        return
    end
    serial = serial + 1
    local journey, id = rec.journey, ("%x"):format((ns.Now() * 16 + serial % 16) % 0xffffff)
    -- A copy kept in another layout is asked for again whole, as for a new journey.
    if journey and journey.version and journey.version ~= ns.char.version then journey = nil end
    local segments = journey and #journey.segments or 0
    local last = journey and journey.segments[segments]
    local asked = { id = id, key = key, parts = {}, got = 0, bytes = bytes or 0, heard = GetTime(),
        answered = bytes ~= nil, auto = auto }
    request = asked
    status[key] = "Asking..."
    if not Send(("Q:%s:%d:%d:%d:%d:%d:%d:%s"):format(id, VERSION, ns.char.version or 0, segments, last and #last.d or 0,
        journey and #journey.events or 0, journey and rec.metaSum or 0, Escape(journey and journey.journeyId or "")),
        rec.name) then
        Finish(key, "Could not send. Are they online?")
        return
    end
    Changed()
    Watch(asked)
end

-- Starts the next friend waiting for an automatic sync.
function NextAuto()
    while autoQueue[1] and not request do
        local key = table.remove(autoQueue, 1)
        local rec = ns.db.friends[key]
        if rec then Ask(rec, key, nil, true) end
    end
end

local function OnPart(key, id, n, total, data)
    local asked = request
    if not asked or asked.key ~= key or asked.id ~= id or n < 1 or n > total or total > MAX_PARTS then return end
    asked.total = asked.total or total
    if asked.total ~= total then return end
    asked.heard, asked.answered = GetTime(), true
    if not asked.parts[n] then
        asked.parts[n], asked.got = data, asked.got + 1
        asked.bytes = asked.bytes + #data
    end
    status[key] = ("Syncing, %d KB so far..."):format(math.floor(asked.bytes / 1024))
    if asked.got < total then
        if asked.got % 10 == 0 then Changed() end
        return
    end

    local rec = ns.db.friends[key]
    local batch = rec and Parse(table.concat(asked.parts, "", 1, total))
    local fits, why = false, nil
    if rec then fits, why = Apply(rec, batch) end
    if not fits then
        if rec then rec.capped = why == "big" or nil end
        Finish(key, why == "big" and TOO_BIG or "Their data did not fit. Removing and adding them starts afresh.", true)
    elseif batch.done then
        rec.synced = ns.Now()
        Finish(key, nil)
    else
        Ask(rec, key, asked.bytes, asked.auto)
    end
end

-- Sending ---------------------------------------------------------------------------

local function SendNext()
    local o = outgoing
    if not o then return end
    if Send(("B:%s:%d:%d:%s"):format(o.id, o.n, #o.parts, o.parts[o.n]), o.to) then
        o.n, o.fails = o.n + 1, 0
        if o.n > #o.parts then
            outgoing = nil
            return
        end
    else
        o.fails = o.fails + 1
        if o.fails > MAX_FAILS then
            outgoing = nil
            return
        end
    end
    -- A send stopped and replaced by another leaves this timer behind.
    Later(1 / RATE, function()
        if outgoing == o then SendNext() end
    end)
end

-- This character's next batch after what the asker has.
local function BuildBatch(have)
    local char = ns.char
    local segments, events = char.segments, char.events
    local journeyId = char.journeyId or ""
    local held = segments[have.s]
    local reset = have.id ~= journeyId or have.s > #segments or have.e > #events
        or (have.s > 0 and (not held or have.o > #(held.d or "")))
    if reset then have.s, have.o, have.e = 0, 0, 0 end

    local guid = ns.PlayerGUID()
    local entry = ns.db.roster[guid]
    local known, tag = pcall(function() return select(2, BNGetInfo()) end)
    local batch = {
        g = guid, j = journeyId, r = reset or nil, s = {}, class = select(2, UnitClass("player")),
        tag = known and Clean(tag) or nil,
        level = UnitLevel("player"), played = char.played,
        zone = entry and entry.zone, c = entry and entry.c, x = entry and entry.x, y = entry and entry.y,
    }

    local room, i, offset = BATCH, math.max(have.s, 1), have.s > 0 and have.o or 0
    while i <= #segments and room > 0 do
        local seg = segments[i]
        local d = seg.d or ""
        local piece = d:sub(offset + 1)
        local whole = #piece <= room
        if not whole then
            -- Cut between points, so a part of the journey still reads.
            local cut = piece:sub(1, room):match("^.*();")
            piece = cut and cut > 1 and piece:sub(1, cut - 1) or ""
        end
        if offset == 0 then
            batch.s[#batch.s + 1] = { i = i, m = seg.m, c = seg.c, j = seg.j, t = seg.t, x = seg.x, y = seg.y, d = piece }
        elseif #piece > 0 then
            batch.s[#batch.s + 1] = { i = i, o = offset, d = piece }
        end
        room = room - #piece - 40
        if not whole then return batch end
        i, offset = i + 1, 0
    end
    if i <= #segments then return batch end

    local from = math.max(1, have.e - EVENTS_AGAIN + 1)
    local list = {}
    batch.ef, batch.e = from, list
    for n = from, #events do
        -- Past the ones sent again, or the next ask would get no further.
        if room <= 0 and #list > EVENTS_AGAIN then return batch end
        list[#list + 1] = events[n]
        room = room - #Serialize(events[n])
    end

    local meta = {}
    for field in pairs(FIELDS) do meta[field] = char[field] end
    if reset or MetaSum(meta) ~= have.sum then batch.m = meta end
    batch.done = true
    return batch
end

local function OnAsked(sender, key, id, rest)
    local version, layout, segments, offset, eventCount, sum, journeyId
    version, rest = rest:match("^(%d+):(.*)$")
    if version and tonumber(version) == VERSION then
        layout, segments, offset, eventCount, sum, journeyId = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(.*)$")
        if not layout then return end
    end
    local refuse
    if not ns.db.friends[key] then
        refuse = "notfriend"
    elseif not layout or tonumber(layout) ~= ns.char.version then
        refuse = "version"
    elseif outgoing then
        refuse = "busy"
    elseif not ns.PlayerGUID() then
        refuse = "nodata"
    end
    if refuse then
        Send(("N:%s:%s"):format(id, refuse), sender)
        return
    end
    local text = Serialize(BuildBatch({
        s = tonumber(segments), o = tonumber(offset), e = tonumber(eventCount), sum = tonumber(sum),
        id = Unescape(journeyId),
    }))
    local parts = {}
    for at = 1, #text, PART do
        parts[#parts + 1] = text:sub(at, at + PART - 1)
    end
    if #parts > MAX_PARTS then
        Send(("N:%s:nodata"):format(id), sender)
        return
    end
    outgoing = { id = id, to = sender, parts = parts, n = 1, fails = 0 }
    SendNext()
end

local function OnMessage(prefix, text, channel, sender)
    prefix, text, sender = Clean(prefix), Clean(text), Clean(sender)
    if prefix ~= PREFIX or channel ~= "WHISPER" or type(text) ~= "string" or type(sender) ~= "string" then return end
    local key, name = SenderKey(sender)
    if not key then return end
    -- The name as the game writes it, for a surname typed in the wrong case.
    local rec = ns.db.friends[key]
    if rec and name and rec.name ~= name then rec.name = name end
    local kind, id, rest = text:match("^(%u):(%x+):(.*)$")
    if kind == "Q" then
        OnAsked(sender, key, id, rest)
    elseif kind == "N" then
        if request and request.id == id and request.key == key then
            Finish(request.key, REASONS[rest] or "They could not send.")
        end
    elseif kind == "B" then
        local n, total, data = rest:match("^(%d+):(%d+):(.*)$")
        if n then OnPart(key, id, tonumber(n), tonumber(total), data) end
    end
end

-- For the tab and commands ----------------------------------------------------------

-- Friends, the most recently synced first.
function Friends:List()
    local list = {}
    for _, rec in pairs(ns.db.friends) do list[#list + 1] = rec end
    table.sort(list, function(a, b)
        if (a.synced or 0) ~= (b.synced or 0) then return (a.synced or 0) > (b.synced or 0) end
        return a.name < b.name
    end)
    return list
end

function Friends:Status(rec)
    local text = status[Key(rec.name)]
    if text then return text end
    if rec.synced then
        return "Last synced " .. date("%b %d, %H:%M", rec.synced)
    end
    return rec.journey and "Part synced. Sync again to carry on." or "Not synced yet."
end

function Friends:Busy()
    return request ~= nil
end

-- Starts a sync with a friend. Their journey comes from whichever character
-- of that name is online, so each of their characters is a friend of its own.
function Friends:Sync(name)
    local key = Key(name)
    local rec = ns.db.friends[key]
    if not rec then
        ns.Print("Add " .. name .. " first.")
    elseif request then
        status[key] = BUSY
        Changed()
    else
        Ask(rec, key)
    end
end

-- Adds a friend for every character on this account, so whichever is online
-- shares its journey with them, and asks for theirs.
function Friends:Add(name)
    name = TypedName(name)
    if not name then
        ns.Print(Surnames() and "Type the full name of a friend's character, first and last."
            or "Type the exact character name of a friend.")
        return
    end
    if Key(name) == Key(MyName()) then
        ns.Print("That's you.")
        return
    end
    local key = Key(name)
    if not ns.db.friends[key] then
        ns.db.friends[key] = { name = name, realm = GetRealmName() }
        ns.Print(name .. " is now a friend of every character on this account. Once they add you too, "
            .. "whichever of your characters is online shares its journey with them.")
    end
    Changed()
    self:Sync(name)
end

-- Removes a friend and their journey, and stops sharing with them.
function Friends:Remove(name)
    local key = Key(name)
    local rec = ns.db.friends[key]
    if not rec then return end
    if request and request.key == key then Stop() end
    if outgoing and SenderKey(outgoing.to) == key then outgoing = nil end
    ns.db.friends[key], status[key] = nil, nil
    Changed()
    NextAuto()
end

-- Automatic syncing -----------------------------------------------------------------

function Friends:AutoSync()
    return ns.db.autoSync
end

local function Schedule()
    autoRun = autoRun + 1
    local run, minutes = autoRun, ns.db.autoSync
    if minutes == 0 then
        wipe(autoQueue)
        return
    end
    Later(minutes * 60, function()
        if run ~= autoRun then return end
        -- A round still going carries on rather than starting over.
        if not autoQueue[1] then
            for key in pairs(ns.db.friends) do autoQueue[#autoQueue + 1] = key end
            NextAuto()
        end
        Schedule()
    end)
end

function Friends:SetAutoSync(minutes)
    ns.db.autoSync = minutes
    Schedule()
    Changed()
end

-- Moves on to the next choice, for a button.
function Friends:NextAutoSync()
    for i, minutes in ipairs(AUTO_MINUTES) do
        if minutes == self:AutoSync() then
            return self:SetAutoSync(AUTO_MINUTES[i % #AUTO_MINUTES + 1])
        end
    end
    self:SetAutoSync(0)
end

-- Sets it from what was typed. False if that isn't a choice.
function Friends:ParseAutoSync(text)
    local minutes = text == "off" and 0 or tonumber(text)
    for _, choice in ipairs(AUTO_MINUTES) do
        if choice == minutes then
            self:SetAutoSync(minutes)
            return true
        end
    end
    return false
end

-- Chat filter: true for the game's line that a player is offline, when it
-- answers one of ours. An automatic sync moves on, and a send stops.
local function HideOffline(_, _, message)
    message = Clean(message)
    local line = ERR_CHAT_PLAYER_NOT_FOUND_S
    if type(message) ~= "string" or not line then return false end
    local now = GetTime()
    if message == hiddenText and now < hiddenUntil then return true end
    local rec = request and request.auto and ns.db.friends[request.key]
    local function Hide()
        hiddenText, hiddenUntil = message, now + HIDE_FOR
        return true
    end
    -- Without case, as the game may name them as it writes them or as we did.
    if rec and Key(message) == Key(line:format(rec.name)) then
        -- A chat filter runs outside ns.On, so an error here would reach the chat frame.
        ns.SafeCall(Finish, request.key, nil)
        return Hide()
    end
    if outgoing and Key(message) == Key(line:format(outgoing.to)) then
        outgoing = nil
        return Hide()
    end
    return false
end

ns.On("PLAYER_LOGIN", function()
    local register = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
    if register then pcall(register, PREFIX) end
    local filter = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
    if filter then filter("CHAT_MSG_SYSTEM", HideOffline) end
    Schedule()
end)

ns.On("CHAT_MSG_ADDON", OnMessage)

ns.Command("friend", "share with a friend and sync their journey: /rts friend <name>", function(name)
    Friends:Add(name)
end)

ns.Command("sync", "sync a friend's journey again: /rts sync <name>", function(name)
    Friends:Sync(name)
end)

--@debug@
-- /rts friendprobe [First Last]: how this client names players for the
-- friends sync, tried alone. It whispers this character in each form of its
-- name, and prints the sender each whisper comes back with and the friend
-- key that gives; with a name, it whispers that player too (unseen without
-- the addon) and prints the result and any "No player named" line.
local probe
ns.Command("friendprobe", "check how names reach the friends sync (developer): /rts friendprobe [First Last]",
    function(typed)
        if probe then
            ns.Print("A probe is still running.")
            return
        end
        local results = {}
        for key, value in pairs(Enum and Enum.SendAddonMessageResult or {}) do results[value] = key end
        local function Result(r) return tostring(r) .. (results[r] and " (" .. results[r] .. ")" or "") end

        local first, surname = UnitName("player")
        ns.Print(("Surnames %s; UnitName gives %q, %q; we send as %q."):format(tostring(Surnames()),
            tostring(first), tostring(surname), tostring(MyName())))
        local lockdown = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
        if lockdown then ns.Print("Chat lockdown: " .. tostring(select(2, pcall(lockdown)))) end

        probe = { got = {}, lines = {}, id = ("%x"):format(ns.Now() % 0xffffff) }
        local frame = CreateFrame("Frame")
        frame:RegisterEvent("CHAT_MSG_ADDON")
        frame:RegisterEvent("CHAT_MSG_SYSTEM")
        frame:SetScript("OnEvent", function(_, event, a, b, _, d)
            if event == "CHAT_MSG_SYSTEM" then
                probe.lines[#probe.lines + 1] = tostring(a)
            elseif a == PREFIX and type(b) == "string" and b:find("^P:" .. probe.id) then
                probe.got[#probe.got + 1] = { form = b:match("^P:%x+:(.*)$"), sender = tostring(d) }
            end
        end)

        local targets = {}
        local me = MyName()
        targets[#targets + 1] = me
        if me:find(" ") then targets[#targets + 1] = (me:gsub(" ", "-")) end
        local them = typed ~= "" and TypedName(typed) or nil
        if typed ~= "" then
            ns.Print(("%q is kept as %s, key %s."):format(typed, tostring(them), them and Key(them) or "none"))
        end
        if them then
            targets[#targets + 1] = them
            if them:find(" ") then targets[#targets + 1] = (them:gsub(" ", "-")) end
        end
        for _, target in ipairs(targets) do
            local send = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
            local ok, r = pcall(send, PREFIX, "P:" .. probe.id .. ":" .. target, "WHISPER", target)
            ns.Print(("Whisper to %q: %s."):format(target, ok and Result(r) or "error " .. tostring(r)))
        end

        C_Timer.After(4, function()
            frame:UnregisterAllEvents()
            -- Matched as if this character were a friend, for a moment.
            local mine, held = Key(me), ns.db.friends[Key(me)]
            for _, got in ipairs(probe.got) do
                ns.db.friends[mine] = held or { name = me, realm = GetRealmName() }
                local key = SenderKey(got.sender)
                ns.db.friends[mine] = held
                ns.Print(("Came back for %q as sender %q: %s."):format(got.form, got.sender,
                    key == mine and "a friend of that name is found" or "NOT found, key " .. tostring(key)))
            end
            if not probe.got[1] then ns.Print("No whisper came back.") end
            for _, line in ipairs(probe.lines) do
                if them and Key(line):find(Key(them:match("^%S+")), 1, true) then
                    local hidden = ERR_CHAT_PLAYER_NOT_FOUND_S
                        and Key(line) == Key(ERR_CHAT_PLAYER_NOT_FOUND_S:format(them))
                    ns.Print(("System line: %q; auto sync would hide it: %s."):format(line, tostring(hidden)))
                end
            end
            probe = nil
        end)
    end)
--@end-debug@

ns.Command("autosync", "sync with online friends on a timer: /rts autosync <5, 15, 30 or off>", function(arg)
    arg = arg:lower()
    if not Friends:ParseAutoSync(arg) then
        ns.Print("Type /rts autosync and 5, 15, 30 or off.")
        return
    end
    ns.Print("Automatic sync: " .. (arg == "off" and "off" or "every " .. arg .. " minutes") .. ".")
end)
