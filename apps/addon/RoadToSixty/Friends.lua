local _, ns = ...

-- Syncing journeys with friends in game, by addon whisper. FriendsPanel.lua
-- is the side panel's Synced friends tab.
--
-- Adding someone is what shares with them: a journey is only sent to a player
-- on the list, and only taken from one, so two players must add each other.
-- A sync is pulled: the side that wants a journey says what it has, and the
-- other sends the next batch of its current character's journey. Each batch
-- is kept as it arrives, so a sync that stops carries on from there, and
-- later syncs only cost what is new. Keys are lowercase names:
--
--   RoadToSixtyDB.friends[key] = {
--     name, realm, class, level, zone, c, x, y, seen, played, synced (time),
--     battleTag (theirs, for grouping their characters), guid,
--     journey = in the form of RoadToSixtyCharDB,
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
--   Q:id:version:segments:offset:events:journeyId   what the asker has
--   N:id:reason                                     not sent, and why
--   B:id:n:total:data                               part n of a batch
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
local AUTO_GAP = 2              -- seconds between friends in an automatic sync
local HIDE_FOR = 2              -- seconds an offline line stays hidden, for each chat window
local NO_ANSWER = 15            -- seconds to wait for a first answer
local STALLED = 45              -- seconds without a message before a sync counts as stopped

-- Road to Sixty's fields besides the path and events, and what each must be.
local FIELDS = {
    levels = "table", kills = "table", recipes = "table", people = "table", totals = "table",
    skills = "table", guild = "any", reps = "table", riding = "table", mounts = "table",
    rares = "table", played = "number", version = "number",
}
local REASONS = {
    notfriend = "Waiting for them to add you.",
    busy = "They are busy sending. Try again in a moment.",
    nodata = "They have no journey to send.",
}

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

-- The value in text, or nil unless it is well formed.
local function Parse(text)
    local stack, top, root, finished = {}, nil, nil, false
    local pos, size = 1, #text
    local function Place(value)
        if not top then
            root, finished = value, true
        elseif top.key == nil then
            if type(value) ~= "string" and type(value) ~= "number" then return false end
            top.key = value
        else
            top.t[top.key], top.key = value, nil
        end
        return true
    end
    while pos <= size do
        if finished then return nil end
        local stop = text:find("~", pos, true)
        if not stop then return nil end
        local kind, body = text:sub(pos, pos), text:sub(pos + 1, stop - 1)
        pos = stop + 1
        if kind == "}" then
            if not top or top.key ~= nil then return nil end
            local closed = top.t
            stack[#stack] = nil
            top = stack[#stack]
            if not Place(closed) then return nil end
        else
            local value
            if kind == "n" then
                value = tonumber(body)
                if not value then return nil end
            elseif kind == "s" then
                value = Unescape(body)
            elseif kind == "t" then
                value = true
            elseif kind == "f" then
                value = false
            elseif kind == "{" then
                if #stack >= MAX_DEPTH or (top and top.key == nil) then return nil end
                top = { t = {} }
                stack[#stack + 1] = top
            else
                return nil
            end
            if kind ~= "{" and not Place(value) then return nil end
        end
    end
    if finished then return root end
end

-- Keeping a friend ------------------------------------------------------------------

local function Key(name)
    return name:lower()
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

local function Whole(v)
    return type(v) == "number" and v == math.floor(v)
end

local function ValidSegment(s)
    return Whole(s.i) and type(s.d) == "string" and s.d:find("^[-%d,;]*$") ~= nil
        and (s.o ~= nil and Whole(s.o) or (
            (s.m == "w" or s.m == "t" or s.m == "g") and Whole(s.c) and Whole(s.t)
            and Whole(s.x) and Whole(s.y) and (s.j == nil or type(s.j) == "string")))
end

-- Puts a batch into the friend's journey. False if it does not fit.
local function Apply(rec, b)
    if type(b) ~= "table" or type(b.g) ~= "string" or not b.g:find("^Player%-%d+%-%x+$")
        or type(b.j) ~= "string" or type(b.s) ~= "table" or not FreeSlot(b.g) then
        return false
    end
    if b.r or rec.guid ~= b.g then
        rec.journey = nil
    end
    local journey = rec.journey or NewJourney()
    local segments, events = journey.segments, journey.events

    for i = 1, #b.s do
        local s = b.s[i]
        if type(s) ~= "table" or not ValidSegment(s) then return false end
        if s.o then
            local seg = segments[s.i]
            if not seg or #seg.d ~= s.o then return false end
            -- A new table, as Road to Sixty decodes each once.
            segments[s.i] = { m = seg.m, c = seg.c, j = seg.j, t = seg.t, x = seg.x, y = seg.y, d = seg.d .. s.d }
        elseif s.i >= 1 and s.i <= #segments + 1 then
            segments[s.i] = { m = s.m, c = s.c, j = s.j, t = s.t, x = s.x, y = s.y, d = s.d }
        else
            return false
        end
    end

    if b.e then
        if type(b.e) ~= "table" or not Whole(b.ef) or b.ef < 1 or b.ef > #events + 1 then return false end
        for i = 1, #b.e do
            local e = b.e[i]
            if type(e) ~= "table" or type(e[1]) ~= "number" or type(e[2]) ~= "string" then return false end
            events[b.ef + i - 1] = e
        end
    end

    if b.m ~= nil then
        if type(b.m) ~= "table" then return false end
        for field, kind in pairs(FIELDS) do
            local value = b.m[field]
            if value ~= nil and (kind == "any" or type(value) == kind) then journey[field] = value end
        end
        local kills = journey.kills
        if type(kills.d) ~= "string" or type(kills.last) ~= "number" or type(kills.names) ~= "table" then
            journey.kills = NewJourney().kills
        end
    end

    journey.journeyId = b.j
    rec.journey, rec.guid = journey, b.g
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

-- Ends a sync. An automatic one only reports what needs looking at, with
-- keep: a friend being offline is not worth a line.
local function Finish(key, text, keep)
    local auto = request and request.key == key and request.auto
    if request and request.key == key then request = nil end
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
    serial = serial + 1
    local journey, id = rec.journey, ("%x"):format((ns.Now() * 16 + serial % 16) % 0xffffff)
    local segments = journey and #journey.segments or 0
    local last = journey and journey.segments[segments]
    local asked = { id = id, key = key, parts = {}, got = 0, bytes = bytes or 0, heard = GetTime(),
        answered = bytes ~= nil, auto = auto }
    request = asked
    status[key] = "Asking..."
    if not Send(("Q:%s:%d:%d:%d:%d:%s"):format(id, VERSION, segments, last and #last.d or 0,
        journey and #journey.events or 0, Escape(journey and journey.journeyId or "")), rec.name) then
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
    if not rec or not Apply(rec, batch) then
        Finish(key, "Their data did not fit. Removing and adding them starts afresh.", true)
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
    Later(1 / RATE, SendNext)
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
    batch.m, batch.done = meta, true
    return batch
end

local function OnAsked(sender, short, id, rest)
    local segments, offset, eventCount, journeyId = rest:match("^%d+:(%d+):(%d+):(%d+):(.*)$")
    if not segments then return end
    local refuse
    if not ns.db.friends[Key(short)] then
        refuse = "notfriend"
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
        s = tonumber(segments), o = tonumber(offset), e = tonumber(eventCount), id = Unescape(journeyId),
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
    local short = Ambiguate and Ambiguate(sender, "none") or sender
    local kind, id, rest = text:match("^(%u):(%x+):(.*)$")
    if kind == "Q" then
        OnAsked(sender, short, id, rest)
    elseif kind == "N" then
        if request and request.id == id and request.key == Key(short) then
            Finish(request.key, REASONS[rest] or "They could not send.")
        end
    elseif kind == "B" then
        local n, total, data = rest:match("^(%d+):(%d+):(.*)$")
        if n then OnPart(Key(short), id, tonumber(n), tonumber(total), data) end
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
        status[key] = "Another sync is running. Try again when it ends."
        Changed()
    else
        Ask(rec, key)
    end
end

-- Adds a friend, sharing this character's journey with them, and asks for theirs.
function Friends:Add(name)
    name = strtrim(name or ""):gsub("%-.*$", "")
    if name == "" or not name:find("^[^%s%d%p]+$") and not name:find("[\128-\255]") then
        ns.Print("Type the exact character name of a friend.")
        return
    end
    if name:lower() == UnitName("player"):lower() then
        ns.Print("That's you.")
        return
    end
    name = name:sub(1, 1):upper() .. name:sub(2):lower()
    local key = Key(name)
    if not ns.db.friends[key] then
        ns.db.friends[key] = { name = name, realm = GetRealmName() }
        ns.Print(name .. " can now sync this character's journey, once they add you too.")
    end
    Changed()
    self:Sync(name)
end

-- Removes a friend and their journey, and stops sharing with them.
function Friends:Remove(name)
    local key = Key(name)
    local rec = ns.db.friends[key]
    if not rec then return end
    if request and request.key == key then request = nil end
    if outgoing and Key(Ambiguate and Ambiguate(outgoing.to, "none") or outgoing.to) == key then outgoing = nil end
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
    if rec and message == line:format(rec.name) then
        Finish(request.key, nil)
        return Hide()
    end
    if outgoing and message == line:format(outgoing.to) then
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

ns.Command("autosync", "sync with online friends on a timer: /rts autosync <5, 15, 30 or off>", function(arg)
    arg = arg:lower()
    if not Friends:ParseAutoSync(arg) then
        ns.Print("Type /rts autosync and 5, 15, 30 or off.")
        return
    end
    ns.Print("Automatic sync: " .. (arg == "off" and "off" or "every " .. arg .. " minutes") .. ".")
end)
