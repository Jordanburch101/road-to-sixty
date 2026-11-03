-- Offline test of Friends.lua: two clients joined by a modelled server, with
-- made-up journeys. Nothing is shared without both adding each other, a first
-- sync brings a whole journey in batches, later ones only what is new, a sync
-- that stops carries on, a friend can't replace one of the account's own
-- characters, broken and hostile batches are refused, and an automatic sync
-- passes over someone offline without a line in chat.
-- Run with LuaJIT from apps/addon: luajit tests/friends_test.lua

local clock, queue, seq = 0, {}, 0
local function At(d, f)
    seq = seq + 1
    queue[#queue + 1] = { t = clock + d, n = seq, f = f }
end
local function Run()
    while #queue > 0 do
        table.sort(queue, function(a, b)
            if a.t ~= b.t then return a.t < b.t end
            return a.n < b.n
        end)
        local e = table.remove(queue, 1)
        clock = e.t
        e.f()
    end
end

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local clients = {}
local carried = 0
local OFFLINE = "No player named '%s' is currently playing."

local function Journey(points, events)
    local steps = {}
    for i = 1, points do steps[i] = "1,3,-2" end
    local list = {}
    for i = 1, events do
        list[i] = { 1785000000 + i, "quest", 0, i, -i, "Quest \"|cff00ff00é~%" .. i .. "|r\"", nil, true }
    end
    -- Events in the shapes the addon saves, so the checks on what comes in can't refuse real ones.
    if events >= 7 then
        local t = 1785000000
        list[2] = { t, "loot", 0, 1, 1, "|cff1eff00|Hitem:2:0|h[Sword]|h|r", 2 }
        list[3] = { t, "out", 0, 1, 1, 33, { name = "Deadmines", duration = 600, kills = 40, xp = 9000, deaths = 1,
            money = 500, levels = 1, items = { "|Hitem:5|h" }, party = { "Player-1-0001" }, type = "party" } }
        list[4] = { t, "gj", 0, 1, 1, "Pals", "Member", true, { files = { 1, 2 }, emblem = 3, bg = { 1, 0, 0 } } }
        list[5] = { t, "grp", 0, 1, 1, "party", { { "Player-1-0001", "Ann", "Human", "Female", "MAGE", 10 } }, true }
        list[6] = { t, "eq", 0, 1, 1, 16, 2, "item:2", nil, { t, "drop", 0, 1, 1, 100, "Creature", "Defias" } }
        list[7] = { t, "qd", 0, 1, 1, 100, 450, 75, "Red Linen" }
    end
    return {
        journeyId = "Player-1-FFFF:0", played = 777, version = 4,
        segments = {
            { m = "w", c = 0, t = 1785000000, x = 100, y = -50, d = table.concat(steps, ";") },
            { m = "t", c = 1, t = 1785009000, x = 5, y = 6, d = "", j = "b" },
        },
        events = list,
        levels = { [2] = { t = 1785000100, played = 600, gear = { 1, 2, 3 }, links = { "item:1" },
            skills = { Mining = { 1, 75 } }, partial = true } },
        kills = { d = "1,10,1;", last = 1785000000, names = { "Boar" } },
        recipes = { Cooking = { Stew = true } },
        people = { ["Player-1-0001"] = { name = "Ann", race = "Human", sex = "Female", class = "MAGE", level = 10,
            guild = "Pals", first = 1785000000, last = 1785000500, c = 0, x = 1, y = 2, groups = { pc1 = 2 }, seconds = 30 } },
        totals = { kills = 1, killXP = 10, questXP = 0, deaths = 0, quests = events, instances = 0, distance = 9, flown = 0 },
        guild = false,
        reps = { [72] = { 5, "Stormwind" } },
        skills = { Mining = { 30, 75, 136248 } },
        rares = { [61] = { { pc1 = 1 }, 1785000300, "Thuzadin", 61, "rare" } },
        riding = { [33388] = { "Apprentice Riding", 1785000000, 40 } },
        mounts = { [6] = { 1785000000, 0, 1, 2, 40 } },
    }
end

local function Client(name, other, guid, char)
    local c = { handlers = {}, errors = {} }
    local env = setmetatable({}, { __index = _G })
    c.env = env
    env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.GetTime = function() return clock end
    env.date = function() return "Nov 02" end
    env.C_Timer = { After = function(d, f) At(d, f) end }
    env.UnitName = function() return name end
    env.UnitClass = function() return "Paladin", "PALADIN" end
    env.UnitLevel = function() return 12 end
    env.GetRealmName = function() return "Era" end
    env.BNGetInfo = function() return 1, name .. "#1234" end
    env.Ambiguate = function(n) return (n:gsub("%-.*", "")) end
    env.ERR_CHAT_PLAYER_NOT_FOUND_S = OFFLINE
    env.ChatFrame_AddMessageEventFilter = function(_, fn) c.filter = fn end
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(p)
            check(#p <= 16, "prefix too long")
            return true
        end,
        SendAddonMessage = function(prefix, text, channel, target)
            check(#text <= 255, "message too long")
            check(not text:find("\0", 1, true), "null in a message")
            if c.onSend then
                local answer = c.onSend(prefix, text, channel, target)
                if answer ~= nil then return answer end
            end
            if target:gsub("%-.*", ""):lower() ~= other:lower() then return true end
            carried = carried + 1
            if text:sub(1, 1) == "Q" then clients[other].lastAsked = text:match("^Q:(%x+)") end
            At(0.05, function()
                if c.offline or clients[other].offline or clients[other].mute then return end
                clients[other].fire("CHAT_MSG_ADDON", prefix, text, channel, name .. "-Era")
            end)
            return true
        end,
    }
    local ns = {
        char = char,
        db = { friends = {}, autoSync = 0, showPaths = {}, roster = {
            [guid] = { name = name, realm = "Era", c = 0, x = 10, y = 20, zone = 1429 },
        } },
        Print = function(text) c.printed = text end,
        Now = function() return 1785000000 + math.floor(clock) end,
        SafeCall = function(fn, ...)
            local ok, err = pcall(fn, ...)
            if not ok then c.errors[#c.errors + 1] = err end
        end,
        PlayerGUID = function() return c.guid end,
        Command = function() end,
    }
    function ns.On(event, fn) c.handlers[event] = fn return true end
    c.guid, c.ns = guid, ns
    function c.fire(event, ...) c.handlers[event](...) end
    local chunk = assert(loadfile("RoadToSixty/Friends.lua"))
    setfenv(chunk, env)
    chunk("RoadToSixty", ns)
    c.fire("PLAYER_LOGIN")
    return c
end

clients.Bromm = Client("Bromm", "Zed", "Player-1-FFFF", Journey(9000, 300))
clients.Zed = Client("Zed", "Bromm", "Player-1-AAAA", Journey(5, 2))
local z, b = clients.Zed, clients.Bromm
Run()
local F = z.ns.Friends
local function status(rec) return F:Status(rec) end

-- Nothing is shared with someone who wasn't added.
F:Add("bromm")
Run()
local rec = z.ns.db.friends.bromm
check(rec.name == "Bromm" and not rec.journey, "took a journey without being added")
check(status(rec) == "Waiting for them to add you.", "refusal not shown: " .. status(rec))

-- The first sync brings the whole journey, batch by batch.
b.ns.Friends:Add("Zed")
Run()
F:Sync("Bromm")
Run()
local sent = b.ns.char
local got = rec.journey
check(rec.synced and status(rec):find("^Last synced"), "sync did not finish: " .. status(rec))
check(got.segments[1].d == sent.segments[1].d, "path differs")
check(got.segments[2].j == "b" and got.segments[2].d == "", "last segment wrong")
check(#got.events == 300 and got.events[300][6] == sent.events[300][6], "events differ")
check(got.events[1][8] == true and got.events[1][7] == nil, "a gap in an event was lost")
check(got.levels[2].gear[3] == 3 and got.recipes.Cooking.Stew and got.guild == false, "fields differ")
check(got.events[3][7].kills == 40 and got.events[6][10][2] == "drop" and got.reps[72][2] == "Stormwind"
    and got.people["Player-1-0001"].groups.pc1 == 2 and got.rares[61][1].pc1 == 1, "real shapes refused or lost")
check(rec.class == "PALADIN" and rec.level == 12 and rec.played == 777, "summary wrong")
check(rec.c == 0 and rec.x == 10, "position wrong")
check(rec.battleTag == "Bromm#1234", "BattleTag not synced")
check(rec.key == "Player-1-FFFF" and rec.friend == true, "not ready to list")

-- A friend lists beside the characters, and stays out of the roster.
local roster = z.ns.db.roster
check(roster["Player-1-FFFF"] == nil, "friend went into the roster")
do
    local chunk = assert(loadfile("RoadToSixty/Roster.lua"))
    setfenv(chunk, z.env)
    chunk("RoadToSixty", z.ns)
    local entries = z.ns.Roster:Entries()
    check(#entries == 2 and entries[2] == rec, "friend not listed")
end

-- A later sync only costs what is new, and refreshes the latest events.
local before = carried
sent.segments[2].d = "1,2,3;4,5,6"
-- A kind this version doesn't know, from a friend on a newer one, may hold a table.
sent.events[301] = { 1785999999, "newkind", 0, 1, 1, { a = 1 } }
sent.events[300][6] = "filled in later"
F:Sync("Bromm")
Run()
check(carried - before < 40, "resent too much: " .. (carried - before))
check(rec.journey.segments[2].d == "1,2,3;4,5,6" and #rec.journey.events == 301, "new data missing: " .. status(rec))
check(rec.journey.events[300][6] == "filled in later", "recent event not refreshed")

-- A sync that stops carries on from where it got to.
local fresh = Journey(9000, 300)
fresh.journeyId = "Player-1-FFFF:9"
b.ns.char = fresh
At(60, function() b.offline = true end)
F:Sync("Bromm")
Run()
check(status(rec):find("^Stopped"), "stop not reported: " .. status(rec))
local kept = #rec.journey.segments[1].d
check(kept > 0 and kept < #fresh.segments[1].d, "nothing kept from the stopped sync")
b.offline = false
Run()
F:Sync("Bromm")
Run()
check(rec.journey.journeyId == "Player-1-FFFF:9", "new journey not taken")
check(rec.journey.segments[1].d == fresh.segments[1].d, "carried on wrong")

-- A friend can't take one of this account's characters, and junk does nothing.
for _, text in ipairs({ "B:zz:1:1:x", "B:ff:0:0:", "Q:ff", "Q:ff:1:x:y:z:", "N:ff", "::", "" }) do
    z.fire("CHAT_MSG_ADDON", "RTSFriends", text, "WHISPER", "Stranger-Era")
    z.fire("CHAT_MSG_ADDON", "RTSFriends", text, "WHISPER", "Bromm-Era")
end
Run()
b.guid = "Player-1-AAAA"
F:Sync("Bromm")
Run()
b.guid = "Player-1-FFFF"
check(rec.guid == "Player-1-FFFF", "own character taken")
check(status(rec):find("did not fit"), "bad batch not reported: " .. status(rec))

-- Broken and hostile batches are refused without error.
local head = "{~sg~sPlayer-1-FFFF~sj~sPlayer-1-FFFF:9~ss~{~n1~{~si~n1~sm~sw~sc~n0~st~n1~sx~n1~sy~n1~sd~"
for _, data in ipairs({
    "x", "n1~", "{~", "}~", "{~n1~}~", "s~s~", ("{~sa~"):rep(100),
    head .. "s1,1,1;os.exit()~}~}~}~",      -- a path that isn't numbers
    "{~sg~sPlayer-1-1~ss~{~}~}~",           -- no journey id
    "{~sg~s../../x~sj~sa~ss~{~}~}~",        -- not a guid
}) do
    b.mute = true
    F:Sync("Bromm")
    z.fire("CHAT_MSG_ADDON", "RTSFriends", "B:" .. b.lastAsked .. ":1:1:" .. data, "WHISPER", "Bromm-Era")
    check(status(rec):find("did not fit"), "took " .. data .. ": " .. status(rec))
    b.mute = false
    Run()
end

-- A stranger can't answer for a friend.
b.mute = true
F:Sync("Bromm")
z.fire("CHAT_MSG_ADDON", "RTSFriends", "B:" .. b.lastAsked .. ":1:1:n1~", "WHISPER", "Stranger-Era")
check(status(rec) == "Asking...", "took a batch from a stranger")
b.mute = false
Run()

-- An automatic sync asks everyone, passes over someone offline without a
-- line in chat, and stops when turned off.
local friends = z.ns.db.friends
friends.gone = { name = "Gone", realm = "Era" }
fresh.events[#fresh.events + 1] = { 1786000000, "level", 0, 2, 2 }
local total, wasSynced = #fresh.events, rec.synced
check(not F:ParseAutoSync("7") and F:AutoSync() == 0, "took a choice that isn't one")
check(F:ParseAutoSync("5") and F:AutoSync() == 5, "choice not taken")
local line, hidden = OFFLINE:format("Gone"), {}
z.onSend = function(_, _, _, target)
    if target == "Gone" then
        At(0.05, function()
            hidden[#hidden + 1] = z.filter(nil, "CHAT_MSG_SYSTEM", line)
            hidden[#hidden + 1] = z.filter(nil, "CHAT_MSG_SYSTEM", line)    -- a second chat window
        end)
        return true
    end
end
At(330, function() check(F:ParseAutoSync("off") and F:AutoSync() == 0, "not turned off") end)
Run()
z.onSend = nil
check(#rec.journey.events == total and rec.synced > wasSynced, "automatic sync did not fetch new data")
check(#hidden == 2 and hidden[1] == true and hidden[2] == true, "offline line not hidden")
check(status(friends.gone) == "Not synced yet.", "offline friend reported: " .. status(friends.gone))
check(z.filter(nil, "CHAT_MSG_SYSTEM", "Someone has come online.") == false, "hid another line")
friends.gone = nil

-- A friend going offline stops a send, without filling the chat.
local bigger = Journey(9000, 300)
bigger.journeyId = "Player-1-FFFF:10"
b.ns.char = bigger
local sends, atStop = 0, nil
b.onSend = function() sends = sends + 1 end
F:Sync("Bromm")
At(5, function()
    z.offline = true
    check(b.filter(nil, "CHAT_MSG_SYSTEM", OFFLINE:format("Zed-Era")) == true, "send line not hidden")
end)
At(5.5, function() atStop = sends end)
Run()
z.offline = false
b.onSend = nil
check(sends == atStop, "kept sending to someone offline")

b.ns.char = fresh
F:Sync("Bromm")
Run()
check(rec.journey.journeyId == "Player-1-FFFF:9" and status(rec):find("^Last synced"), "resync failed: " .. status(rec))

-- What a friend sends is checked whole before any of it is kept, nested
-- fields too, and a batch that fails leaves the journey as it was.
local function Ser(v)
    local kind = type(v)
    if kind == "number" then return "n" .. v .. "~" end
    if kind == "boolean" then return v and "t~" or "f~" end
    if kind == "string" then
        return "s" .. v:gsub("[%%~|%c\128-\255]", function(ch) return ("%%%02X"):format(ch:byte()) end) .. "~"
    end
    local out = { "{~" }
    for key, value in pairs(v) do out[#out + 1] = Ser(key) .. Ser(value) end
    out[#out + 1] = "}~"
    return table.concat(out)
end
local function Reply(batch, from)
    b.mute = true
    F:Sync("Bromm")
    local text = Ser(batch)
    local parts = {}
    for at = 1, #text, 200 do parts[#parts + 1] = text:sub(at, at + 199) end
    for n, part in ipairs(parts) do
        z.fire("CHAT_MSG_ADDON", "RTSFriends", ("B:%s:%d:%d:%s"):format(b.lastAsked, n, #parts, part), "WHISPER",
            from or "Bromm-Era")
    end
    local after = status(rec)
    b.mute = false
    Run()
    return after
end
local stored, storedEvents = rec.journey, #rec.journey.events
local firstPath = rec.journey.segments[1].d
local nextEvent = storedEvents + 1
for name, bad in pairs({
    later_segment = { s = { { i = 1, o = #firstPath, d = "1,1,1;" }, { i = 99, m = "w", c = 0, t = 1, x = 1, y = 1, d = "" } } },
    guild_true = { m = { guild = true } },
    guild_number = { m = { guild = { 5 } } },
    level_not_table = { m = { levels = { [2] = "x" } } },
    level_key = { m = { levels = { x = {} } } },
    kill_name = { m = { kills = { d = "", last = 0, names = { {} } } } },
    person = { m = { people = { g = "x" } } },
    person_tally = { m = { people = { g = { groups = { pc1 = "x" } } } } },
    rep = { m = { reps = { [1] = { "a" } } } },
    totals = { m = { totals = { kills = "many" } } },
    played = { m = { played = "long" } },
    loot_table = { ef = nextEvent, e = { { 1, "loot", 0, 1, 1, {} } } },
    loot_link = { ef = nextEvent, e = { { 1, "loot", 0, 1, 1, "|Hjunk|h" } } },
    place = { ef = nextEvent, e = { { 1, "lvl", "x", 1, 1, 2 } } },
    run = { ef = nextEvent, e = { { 1, "out", 0, 1, 1, 3, { duration = "long" } } } },
    named_field = { ef = nextEvent, e = { { 1, "zone", 0, 1, 1, 12, x = 1 } } },
    table_field = { ef = nextEvent, e = { { 1, "zone", 0, 1, 1, { 12 } } } },
    good_events_bad_meta = { ef = nextEvent, e = { { 1, "zone", 0, 1, 1, 12 } }, m = { guild = true } },
}) do
    bad.g, bad.j, bad.s = "Player-1-FFFF", "Player-1-FFFF:9", bad.s or {}
    local after = Reply(bad)
    check(after:find("did not fit"), name .. " taken: " .. after)
    check(rec.journey == stored and #stored.events == storedEvents and stored.segments[1].d == firstPath
        and stored.guild == false, name .. " changed the journey")
end
check(#z.errors == 0, "errors: " .. tostring(z.errors[1]))

-- A friend can't grow the saved file without end: past the cap, the sync
-- stops asking and says why.
local asks = 0
z.onSend = function(_, text) if text:sub(1, 1) == "Q" then asks = asks + 1 end end
local cap = F.MAX_SIZE
F.MAX_SIZE = 60000
local huge = Journey(9000, 300)
huge.journeyId = "Player-1-FFFF:11"
b.ns.char = huge
F:Sync("Bromm")
Run()
check(status(rec):find("too big"), "cap not reported: " .. status(rec))
check(asks == 3 and rec.size <= 60000, "kept asking past the cap: " .. asks .. ", " .. tostring(rec.size))
F.MAX_SIZE = cap
asks = 0
F:Sync("Bromm")
Run()
check(asks == 0 and status(rec):find("too big"), "asked again after the cap: " .. asks)
rec.capped = nil
z.onSend = nil
b.ns.char = fresh
F:Sync("Bromm")
Run()
check(rec.journey.journeyId == "Player-1-FFFF:9" and status(rec):find("^Last synced"), "no sync after the cap")

-- Only a friend on this realm counts, asking or answering.
check(Reply({ g = "Player-1-FFFF", j = "Player-1-FFFF:9", s = {} }, "Bromm-OtherRealm") == "Asking...",
    "took a batch from another realm")
local toOther = 0
b.onSend = function(_, _, _, target) if target == "Zed-OtherRealm" then toOther = toOther + 1 end end
b.fire("CHAT_MSG_ADDON", "RTSFriends", "Q:ab:1:4:0:0:0:0:", "WHISPER", "Zed-OtherRealm")
b.onSend = nil
Run()
check(toOther == 0, "answered someone on another realm")

-- Another version of the protocol or of the saved layout is refused with a reason.
local replies = {}
b.onSend = function(_, text) replies[#replies + 1] = text end
b.fire("CHAT_MSG_ADDON", "RTSFriends", "Q:ab:9:4:0:0:0:0:", "WHISPER", "Zed-Era")
b.onSend = nil
Run()
check(replies[1] == "N:ab:version", "another protocol version answered: " .. tostring(replies[1]))
z.ns.char.version = 5
F:Sync("Bromm")
Run()
z.ns.char.version = 4
check(status(rec):find("version of Road to Sixty"), "another layout not refused: " .. status(rec))
-- A copy kept in an older layout is fetched again whole.
rec.journey.version = 3
local old = rec.journey
F:Sync("Bromm")
Run()
check(rec.journey ~= old and rec.journey.version == 4 and status(rec):find("^Last synced"),
    "older copy not fetched again: " .. status(rec))

-- A name typed in another case finds the friend, accented letters too, and
-- adding says the list is shared by the whole account.
local asked
z.onSend = function(_, text, _, target)
    if target == "émile" then asked = text:match("^Q:(%x+)") end
end
F:Add("émile")
z.onSend = nil
check((z.printed or ""):find("every character on this account"), "add message: " .. tostring(z.printed))
check(asked, "no ask sent to émile")
z.fire("CHAT_MSG_ADDON", "RTSFriends", "N:" .. (asked or "0") .. ":notfriend", "WHISPER", "Émile-Era")
check(status(friends["émile"]) == "Waiting for them to add you.", "Émile not matched: " .. status(friends["émile"]))
F:Remove("émile")
Run()

-- The busy line goes when the sync it waited on ends.
friends.other = { name = "Other", realm = "Era" }
b.mute = true
F:Sync("Bromm")
F:Sync("Other")
check(status(friends.other):find("^Another sync"), "busy not shown: " .. status(friends.other))
b.mute = false
Run()
check(status(friends.other) == "Not synced yet.", "busy line stayed: " .. status(friends.other))
friends.other = nil

-- An error in the tab while hiding the offline line is caught, and the line still hidden.
friends.gone = { name = "Gone", realm = "Era" }
local filterOk, filterHid
z.onSend = function(_, _, _, target)
    if target == "Gone" then
        At(0.05, function()
            F.OnChange = function() error("tab broke") end
            filterOk, filterHid = pcall(z.filter, nil, "CHAT_MSG_SYSTEM", OFFLINE:format("Gone"))
            F.OnChange = nil
        end)
        return true
    end
end
check(F:ParseAutoSync("5"), "autosync not set")
At(330, function() F:ParseAutoSync("off") end)
Run()
z.onSend = nil
friends.gone = nil
check(filterOk and filterHid == true, "offline filter failed: " .. tostring(filterHid))
check(#z.errors == 1 and tostring(z.errors[1]):find("tab broke"), "error not caught once: " .. #z.errors)
z.errors = {}

-- A stopped send and a new ask never run two send loops at once.
b.ns.char = bigger
local times, start = {}, clock
b.onSend = function(_, text) if text:sub(1, 1) == "B" then times[#times + 1] = clock end end
b.fire("CHAT_MSG_ADDON", "RTSFriends", "Q:aa:1:4:0:0:0:0:", "WHISPER", "Zed-Era")
At(2, function()
    check(b.filter(nil, "CHAT_MSG_SYSTEM", OFFLINE:format("Zed-Era")) == true, "send line not hidden")
    b.fire("CHAT_MSG_ADDON", "RTSFriends", "Q:bb:1:4:0:0:0:0:", "WHISPER", "Zed-Era")
end)
Run()
b.onSend = nil
local inWindow = 0
for _, t in ipairs(times) do if t >= start + 5 and t < start + 15 then inWindow = inWindow + 1 end end
check(inWindow <= 31, "two send loops: " .. inWindow .. " parts in 10 seconds")
b.ns.char = fresh
Run()

-- The other fields are only sent again when they changed.
local sentData
b.onSend = function(_, text) if text:sub(1, 1) == "B" then sentData[#sentData + 1] = text:match("^B:%x+:%d+:%d+:(.*)$") end end
sentData = {}
F:Sync("Bromm")
Run()
check(status(rec):find("^Last synced") and not table.concat(sentData):find("sm~{~", 1, true), "unchanged fields sent again")
fresh.reps[72] = { 6, "Stormwind" }
sentData = {}
F:Sync("Bromm")
Run()
b.onSend = nil
check(table.concat(sentData):find("sm~{~", 1, true) and rec.journey.reps[72][1] == 6, "changed fields not sent")

-- Removing a friend deletes their journey.
F:Remove("Bromm")
check(friends.bromm == nil, "remove left the friend")
check(#z.ns.Roster:Entries() == 1, "remove left the friend listed")

check(#z.errors == 0 and #b.errors == 0, "errors: " .. tostring(z.errors[1] or b.errors[1]))

if failures > 0 then os.exit(1) end
print("friends_test: all passed")
