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
    return {
        journeyId = "Player-1-FFFF:0", played = 777,
        segments = {
            { m = "w", c = 0, t = 1785000000, x = 100, y = -50, d = table.concat(steps, ";") },
            { m = "t", c = 1, t = 1785009000, x = 5, y = 6, d = "", j = "b" },
        },
        events = list,
        levels = { [2] = { t = 1785000100, gear = { 1, 2, 3 } } },
        kills = { d = "1,10,1;", last = 1785000000, names = { "Boar" } },
        recipes = { Cooking = { Stew = true } },
        people = {},
        totals = { kills = 1, killXP = 10, questXP = 0, deaths = 0, quests = events, instances = 0, distance = 9, flown = 0 },
        guild = false,
    }
end

local function Client(name, other, guid, char)
    local c = { handlers = {} }
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
        Print = function() end,
        Now = function() return 1785000000 + math.floor(clock) end,
        SafeCall = function(fn, ...) return fn(...) end,
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
sent.events[301] = { 1785999999, "level", 0, 1, 1 }
sent.events[300][6] = "filled in later"
F:Sync("Bromm")
Run()
check(carried - before < 40, "resent too much: " .. (carried - before))
check(rec.journey.segments[2].d == "1,2,3;4,5,6" and #rec.journey.events == 301, "new data missing")
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

-- Removing a friend deletes their journey.
F:Remove("Bromm")
check(friends.bromm == nil, "remove left the friend")
check(#z.ns.Roster:Entries() == 1, "remove left the friend listed")

if failures > 0 then os.exit(1) end
print("friends_test: all passed")
