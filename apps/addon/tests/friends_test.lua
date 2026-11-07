---@diagnostic disable: duplicate-set-field
-- Offline test of Friends.lua: two clients joined by a modelled server, with
-- made-up journeys. Nothing is shared without both adding each other, a first
-- sync brings a whole journey in batches, later ones only what is new, a sync
-- that stops carries on, a friend can't replace one of the account's own
-- characters, broken and hostile batches are refused, and an automatic sync
-- passes over someone offline without a line in chat, nothing is asked or sent
-- where chat is locked down, and a resume never grafts onto data that moved.
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
local AT = 1785000000           -- a time a journey can hold, for made-up events

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
        kills = { d = "1785000000,10,1;", last = 1785000000, names = { "Boar" } },
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

-- forever: a client where characters have surnames ("First Last"), and
-- c.sendAs, if set, is how the server writes this client as a sender.
local function Client(name, other, guid, char, forever)
    local c = { handlers = {}, errors = {} }
    local env = setmetatable({}, { __index = _G })
    c.env = env
    env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.GetTime = function() return clock end
    env.date = function() return "Nov 02" end
    env.C_Timer = { After = function(d, f) At(d, f) end }
    env.UnitName = function()
        if forever then return name:match("^(%S+) (%S+)$") end
        return name
    end
    if forever then env.RegionalUniqueNamesEnabled = function() return true end end
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
            local to = forever and target:gsub("%-Era$", ""):gsub("%-", " ") or target:gsub("%-.*", "")
            if to:lower() ~= other:lower() then return true end
            carried = carried + 1
            if text:sub(1, 1) == "Q" then clients[other].lastAsked = text:match("^Q:(%x+)") end
            At(0.05, function()
                if c.offline or clients[other].offline or clients[other].mute then return end
                clients[other].fire("CHAT_MSG_ADDON", prefix, text, channel, c.sendAs and c.sendAs(name) or name .. "-Era")
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
    if kind == "number" then return v == math.huge and "n1e999~" or "n" .. v .. "~" end
    if kind == "boolean" then return v and "t~" or "f~" end
    if kind == "string" then
        return "s" .. v:gsub("[%%~|%c\128-\255]", function(ch) return ("%%%02X"):format(ch:byte()) end) .. "~"
    end
    local out = { "{~" }
    for key, value in pairs(v) do out[#out + 1] = Ser(key) .. Ser(value) end
    out[#out + 1] = "}~"
    return table.concat(out)
end
local function Deliver(batch, from)
    local text = Ser(batch)
    local parts = {}
    for at = 1, #text, 200 do parts[#parts + 1] = text:sub(at, at + 199) end
    for n, part in ipairs(parts) do
        z.fire("CHAT_MSG_ADDON", "RTSFriends", ("B:%s:%d:%d:%s"):format(b.lastAsked, n, #parts, part), "WHISPER",
            from or "Bromm-Era")
    end
    return status(rec)
end
local function Reply(batch, from)
    b.mute = true
    F:Sync("Bromm")
    local after = Deliver(batch, from)
    b.mute = false
    Run()
    return after
end
local stored, storedEvents = rec.journey, #rec.journey.events
local firstPath = rec.journey.segments[1].d
local nextEvent = storedEvents + 1
for name, bad in pairs({
    later_segment = { s = { { i = 1, o = #firstPath, d = "1,1,1;" }, { i = 99, m = "w", c = 0, t = AT, x = 1, y = 1, d = "" } } },
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
    loot_table = { ef = nextEvent, e = { { AT, "loot", 0, 1, 1, {} } } },
    loot_link = { ef = nextEvent, e = { { AT, "loot", 0, 1, 1, "|Hjunk|h" } } },
    place = { ef = nextEvent, e = { { AT, "lvl", "x", 1, 1, 2 } } },
    run = { ef = nextEvent, e = { { AT, "out", 0, 1, 1, 3, { duration = "long" } } } },
    named_field = { ef = nextEvent, e = { { AT, "zone", 0, 1, 1, 12, x = 1 } } },
    table_field = { ef = nextEvent, e = { { AT, "zone", 0, 1, 1, { 12 } } } },
    good_events_bad_meta = { ef = nextEvent, e = { { AT, "zone", 0, 1, 1, 12 } }, m = { guild = true } },
    -- A number too big to hold reads as infinity, which passes any check on a number.
    infinite_time = { ef = nextEvent, e = { { math.huge, "zone", 0, 1, 1, 12 } } },
    infinite_total = { m = { totals = { kills = math.huge } } },
    infinite_start = { s = { { i = 3, m = "w", c = 0, t = math.huge, x = 1, y = 1, d = "" } } },
    -- Fields the map, History and Stats read without a check.
    no_level = { ef = nextEvent, e = { { AT, "lvl", 0, 1, 1 } } },
    no_zone = { ef = nextEvent, e = { { AT, "zone", 0, 1, 1 } } },
    no_quest = { ef = nextEvent, e = { { AT, "qd", 0, 1, 1, nil, 450 } } },
    no_instance = { ef = nextEvent, e = { { AT, "in", 0, 1, 1, nil, "Deadmines" } } },
    no_slot = { ef = nextEvent, e = { { AT, "eq", 0, 1, 1, nil, 2 } } },
    no_link = { ef = nextEvent, e = { { AT, "loot", 0, 1, 1 } } },
    no_standing = { ef = nextEvent, e = { { AT, "rep", 0, 1, 1, 72 } } },
    no_enchant = { ef = nextEvent, e = { { AT, "ench", 0, 1, 1, 5 } } },
    enchant_item = { ef = nextEvent, e = { { AT, "ench", 0, 1, 1, "sword", 6 } } },
    enchant_by = { ef = nextEvent, e = { { AT, "ench", 0, 1, 1, 5, 6, nil, nil, true } } },
    rare_level = { ef = nextEvent, e = { { AT, "rare", 0, 1, 1, "Thuzadin", "rare", "high" } } },
    duel_level = { ef = nextEvent, e = { { AT, "duel", 0, 1, 1, "Ann", "won", nil, nil, "high" } } },
    no_member = { ef = nextEvent, e = { { AT, "grpa", 0, 1, 1 } } },
    member_guid = { ef = nextEvent, e = { { AT, "grpa", 0, 1, 1, { [2] = "Ann" } } } },
    member_level = { ef = nextEvent, e = { { AT, "grp", 0, 1, 1, "party", { { "Player-1-0001", "Ann", nil, nil, nil, "x" } } } } },
    left_level = { ef = nextEvent, e = { { AT, "grpl", 0, 1, 1, "Player-1-0001", "x" } } },
    group_end = { ef = nextEvent, e = { { AT, "grpx", 0, 1, 1 } } },
    group_end_counts = { ef = nextEvent, e = { { AT, "grpx", 0, 1, 1, { duration = 5 } } } },
    group_end_levels = { ef = nextEvent, e = { { AT, "grpx", 0, 1, 1, { kills = 0, xp = 0, quests = 0, deaths = 0, levels = { x = "y" } } } } },
    pvp_teams = { ef = nextEvent, e = { { AT, "out", 0, 1, 1, 3, { duration = 1, kills = 0, xp = 0, deaths = 0, money = 0,
        levels = 0, items = {}, pvp = { teams = { 1 } } } } } },
    pvp_stat = { ef = nextEvent, e = { { AT, "out", 0, 1, 1, 3, { duration = 1, kills = 0, xp = 0, deaths = 0, money = 0,
        levels = 0, items = {}, pvp = { stats = { { nil, 3 } } } } } } },
    run_items = { ef = nextEvent, e = { { AT, "out", 0, 1, 1, 3, { duration = 1, kills = 0, xp = 0, deaths = 0, money = 0, levels = 0 } } } },
    no_profession = { ef = nextEvent, e = { { AT, "prof", 0, 1, 1 } } },
    no_gather_item = { ef = nextEvent, e = { { AT, "gath", 0, 1, 1, "m" } } },
    tabard_colour = { ef = nextEvent, e = { { AT, "gj", 0, 1, 1, "Pals", "Member", nil, { bg = 1, border = 1 } } } },
    guild_tabard = { m = { guild = { "Pals", "Member", 1, { bg = 1, border = 1 } } } },
    tabard_colour_text = { ef = nextEvent, e = { { AT, "gj", 0, 1, 1, "Pals", "Member", nil, { bg = { "red" }, border = { 1 } } } } },
    skill_key = { m = { skills = { [1] = { 5 }, Mining = { 5 } } } },
    snapshot_skill_key = { m = { levels = { [3] = { skills = { [1] = { 5 }, Mining = { 5 } } } } } },
    loot_not_a_link = { ef = nextEvent, e = { { AT, "loot", 0, 1, 1, "junk|Hitem:1" } } },
    -- Times and levels the screens step through: past these they would never finish.
    far_time = { ef = nextEvent, e = { { 4e9, "zone", 0, 1, 1, 12 } } },
    far_past = { ef = nextEvent, e = { { -4e9, "zone", 0, 1, 1, 12 } } },
    far_start = { s = { { i = 3, m = "w", c = 0, t = 4e9, x = 1, y = 1, d = "" } } },
    far_step = { s = { { i = 3, m = "w", c = 0, t = AT, x = 1, y = 1, d = "9999999999,1,1;9999999999,1,1;9999999999,1,1" } } },
    far_step_on = { s = { { i = 1, o = #firstPath, d = ";9999999999,1,1;9999999999,1,1" } } },
    -- Eleven digits that read as 1: only the cap on digits refuses it.
    long_step = { s = { { i = 3, m = "w", c = 0, t = AT, x = 1, y = 1, d = "00000000001,1,1" } } },
    long_position = { s = { { i = 3, m = "w", c = 0, t = AT, x = 1, y = 1, d = "1," .. string.rep("9", 400) .. ",1" } } },
    far_snapshot = { m = { levels = { [3] = { t = 4e9 } } } },
    far_last_kill = { m = { kills = { d = "", last = 4e9, names = {} } } },
    far_kill = { m = { kills = { d = "1785000000,1,1;9999999999,1,1;", last = 0, names = {} } } },
    long_kill = { m = { kills = { d = "001785000000,1,1;", last = 0, names = {} } } },
    early_time = { ef = nextEvent, e = { { 5e8, "zone", 0, 1, 1, 12 } } },
    early_kill = { m = { kills = { d = "", last = 5e8, names = {} } } },
    big_id = { ef = nextEvent, e = { { AT, "zone", 0, 1, 1, 1e300 } } },
    big_position = { s = { { i = 3, m = "w", c = 0, t = AT, x = 1e300, y = 1, d = "" } } },
    run_item_kind = { ef = nextEvent, e = { { AT, "out", 0, 1, 1, 3, { duration = 1, kills = 0, xp = 0, deaths = 0, money = 0,
        levels = 0, items = { true } } } } },
    no_recipe = { ef = nextEvent, e = { { AT, "rec", 0, 1, 1 } } },
    no_skill = { ef = nextEvent, e = { { AT, "skill", 0, 1, 1 } } },
    tabard_colour_short = { ef = nextEvent, e = { { AT, "gj", 0, 1, 1, "Pals", "Member", nil, { bg = {}, border = {} } } } },
    high_level_key = { m = { levels = { [1000] = { t = AT } } } },
    high_level = { ef = nextEvent, e = { { AT, "lvl", 0, 1, 1, 1000 } } },
    high_login_level = { ef = nextEvent, e = { { AT, "on", 0, 1, 1, 1000 } } },
    -- A level's snapshot and rows of the fields beside the events.
    snapshot_time = { m = { levels = { [3] = { t = "soon" } } } },
    snapshot_count = { m = { levels = { [3] = { kills = "many" } } } },
    riding_row = { m = { riding = { [1] = { "Riding", "soon" } } } },
    mount_row = { m = { mounts = { [1] = { "soon" } } } },
    -- A stamp this long would push every later ask past 255 bytes.
    long_stamp = { j = string.rep("x", 65) },
}) do
    bad.g, bad.j, bad.s = "Player-1-FFFF", bad.j or "Player-1-FFFF:9", bad.s or {}
    local after = Reply(bad)
    check(after:find("did not fit"), name .. " taken: " .. after)
    check(rec.journey == stored and #stored.events == storedEvents and stored.segments[1].d == firstPath
        and stored.guild == false, name .. " changed the journey")
end
check(#z.errors == 0, "errors: " .. tostring(z.errors[1]))

-- The shapes the addon does save pass those checks, a nil in the middle too.
do
    local heldEvents, heldSize, heldKills = #stored.events, rec.size, stored.kills
    local after = Reply({ g = "Player-1-FFFF", j = "Player-1-FFFF:9", s = {}, ef = nextEvent, done = true,
        m = { kills = { d = "", last = 0, names = {} } }, e = {
        { AT, "lvl", 0, 1, 1, 2 },
        { AT, "zone", 0, 1, 1, 12 },
        { AT, "qd", 0, 1, 1, 100 },
        { AT, "in", 0, 1, 1, 33, "Deadmines", "party" },
        { AT, "eq", 0, 1, 1, 16, 0 },
        { AT, "rep", 0, 1, 1, 72, 5, "Stormwind", true },
        { AT, "ench", 0, 1, 1, 5, 6, 0, 16, "self", nil, 7, "+3 Agility" },
        { AT, "rare", 0, 1, 1, "Thuzadin", "rare", 61, 61, "kill" },
        { AT, "duel", 0, 1, 1, "Ann", "won", "me", "MAGE", 10, "Human", "Pals", true },
        { AT, "grp", 0, 1, 1, "raid", { { "Player-1-0001" }, { "Player-1-0002", "Ann", "Human", "Female", "MAGE", 10, "Pals", 1 } }, true, 2 },
        { AT, "grpa", 0, 1, 1, { "Player-1-0001" } },
        { AT, "grpl", 0, 1, 1, "Player-1-0001", 12 },
        { AT, "grps", 0, 1, 1, false, 2 },
        { AT, "grpk", 0, 1, 1, "raid" },
        { AT, "grpx", 0, 1, 1, { duration = 1, kills = 0, xp = 0, quests = 0, deaths = 0, instances = 0, met = 1,
            levels = { ["Player-1-0001"] = 12 } } },
        { AT, "out", 0, 1, 1, 3, { duration = 1, kills = 0, xp = 0, deaths = 0, money = 0, levels = 0, items = {}, type = "pvp",
            pvp = { won = true, teams = { 1, 2 }, kb = 1, stats = { { "Flags", 1 } }, rep = { Frostwolf = 5 } } } },
        { AT, "prof", 0, 1, 1, "Mining", 1, 75 },
        { AT, "gath", 0, 1, 1, "f", 6303 },
        { AT, "gj", 0, 1, 1, "Pals", "Member", true, { files = { 1, 2 }, emblem = 3, style = 2, bg = { 1, 0, 0 }, border = { 0, 0, 1 } } },
        { AT, "loot", 0, 1, 1, "|cnIQ2:|Hitem:2:0|h[Sword]|h|r", 2 },
        -- A field a newer version adds may be a table where this version has letters.
        { AT, "grpa", 0, 1, 1, { "Player-1-0001", [20] = { 1 } } },
        { AT, "grpx", 0, 1, 1, { kills = 0, xp = 0, quests = 0, deaths = 0, later = { 1 } } },
        { AT, "out", 0, 1, 1, 3, { duration = 1, kills = 0, xp = 0, deaths = 0, money = 0, levels = 0, items = {}, later = { 1 },
            pvp = { later = { 1 } } } },
    } })
    check(after:find("^Last synced"), "real shapes refused: " .. after)
    for i = #stored.events, heldEvents + 1, -1 do stored.events[i] = nil end
    rec.size, stored.kills = heldSize, heldKills
end

-- A print that doesn't match asks for the whole journey again, once a sync:
-- a sender that keeps sending one can't keep a sync going for ever.
do
    local asked = {}
    z.onSend = function(_, text) asked[#asked + 1] = text end
    b.mute = true
    F:Sync("Bromm")
    local base = { g = "Player-1-FFFF", j = "Player-1-FFFF:9", s = {}, p = 12345 }
    check(Deliver(base) == "Asking...", "a print that doesn't match wasn't asked again: " .. status(rec))
    check(#asked == 2 and asked[1]:find("^Q:%x+:1:4:2:") and asked[2]:find("^Q:%x+:1:4:0:0:0:0:$"),
        "not asked for the whole journey: " .. tostring(asked[2]))
    check(rec.journey == stored, "dropped the journey before the new one came")
    check(Deliver(base):find("changed while it came"), "a second print that doesn't match wasn't stopped: " .. status(rec))
    check(#asked == 2, "asked a third time")
    -- Events alone: the path stays, and only the events are asked for again.
    local held = {}
    for i, e in ipairs(stored.events) do held[i] = e end
    local heldSize = rec.size
    asked = {}
    F:Sync("Bromm")
    local segments = #stored.segments
    check(Deliver({ g = base.g, j = base.j, s = {}, pe = 12345 }) == "Asking...", "events that don't match weren't asked again")
    check(#asked == 2 and asked[2]:find(("^Q:%%x+:1:4:%d:%%d+:0:"):format(segments)), "not asked for the events alone: " .. tostring(asked[2]))
    check(#stored.events == 0 and rec.journey == stored and #stored.segments == segments, "not ready for the events again")
    check(Deliver({ g = base.g, j = base.j, s = {}, pe = 12345 }):find("changed while it came"), "a second mismatch wasn't stopped")
    for i, e in ipairs(held) do stored.events[i] = e end
    rec.size = heldSize
    -- An ask for the events again that can't go keeps the events there were.
    F:Sync("Bromm")
    z.onSend = function() return 11 end
    Deliver({ g = base.g, j = base.j, s = {}, pe = 12345 })
    check(#stored.events == #held and rec.size == heldSize, "events dropped though the ask didn't go")
    b.mute, z.onSend = false, nil
    Run()
end

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

-- Without surnames a name with a space is no character's.
F:Add("Bo Ray")
check((z.printed or ""):find("exact character name") and friends["bo ray"] == nil, "took a name with a space")

-- On Forever characters have surnames: a friend is added by full name, typed
-- with a space or a hyphen in any case, and found however the server writes
-- the sender, which also puts right the case of a surname typed wrong.
clients["Ann Lee"] = Client("Ann Lee", "Bo McRay", "Player-1-0A01", Journey(20, 3), true)
clients["Bo McRay"] = Client("Bo McRay", "Ann Lee", "Player-1-0B01", Journey(5, 2), true)
local ann, bo = clients["Ann Lee"], clients["Bo McRay"]
Run()
ann.ns.Friends:Add("Bo")
check((ann.printed or ""):find("full name") and next(ann.ns.db.friends) == nil, "took a first name alone")
ann.ns.Friends:Add("ann LEE")
check(ann.printed == "That's you." and next(ann.ns.db.friends) == nil, "added itself by full name")
bo.ns.Friends:Add(" ann-lee ")
check(bo.ns.db.friends["ann lee"] and bo.ns.db.friends["ann lee"].name == "Ann Lee", "hyphen form not taken")
ann.ns.Friends:Add("bo mcray")
Run()
local bo_rec = ann.ns.db.friends["bo mcray"]
check(bo_rec and bo_rec.synced and bo_rec.journey and #bo_rec.journey.segments[1].d > 0,
    "full name sync did not finish: " .. (bo_rec and ann.ns.Friends:Status(bo_rec) or "no friend"))
check(bo_rec and bo_rec.name == "Bo McRay", "name not taken from the sender: " .. tostring(bo_rec and bo_rec.name))
local forms = {
    { "plain", function(n) return n end },
    { "realm", function(n) return n .. "-Era" end },
    { "hyphen", function(n) return (n:gsub(" ", "-")) end },
}
for _, form in ipairs(forms) do
    ann.sendAs, bo.sendAs = form[2], form[2]
    bo_rec.synced = nil
    ann.ns.Friends:Sync("Bo McRay")
    Run()
    check(bo_rec.synced, "sender written " .. form[1] .. " not matched: " .. ann.ns.Friends:Status(bo_rec))
end
check(#ann.errors == 0 and #bo.errors == 0, "errors: " .. tostring(ann.errors[1] or bo.errors[1]))

-- A resume never grafts onto data that moved, and chat lockdown stops only what it must.
clients.Cy = Client("Cy", "Di", "Player-1-CC01", Journey(400, 40))
clients.Di = Client("Di", "Cy", "Player-1-DD01", Journey(5, 2))
local cy, di = clients.Cy, clients.Di
local CF, DF = cy.ns.Friends, di.ns.Friends
CF:Add("Di")
DF:Add("Cy")
Run()
DF:Sync("Cy")
Run()
local copy = di.ns.db.friends.cy
check(copy.journey and copy.synced, "second pair didn't sync: " .. DF:Status(copy))

local function Same(what)
    local mine, theirs = copy.journey, cy.ns.char
    check(#mine.segments == #theirs.segments, what .. ": segments " .. #mine.segments .. " of " .. #theirs.segments)
    for i, seg in ipairs(theirs.segments) do
        local got = mine.segments[i]
        check(got and got.t == seg.t and got.d == seg.d, what .. ": segment " .. i .. " differs")
    end
    check(#mine.events == #theirs.events, what .. ": events " .. #mine.events .. " of " .. #theirs.events)
    for i, e in ipairs(theirs.events) do
        check(mine.events[i] and mine.events[i][1] == e[1], what .. ": event " .. i .. " differs")
    end
end
Same("first sync")

-- A session from a late second PC lands in the middle: same stamp, more of
-- everything, so counts alone would carry on from the wrong place.
-- An event landing there costs only the events again, as a run's summary saved
-- late does, and the path isn't sent again.
local held = copy.journey
table.insert(cy.ns.char.events, 5, { 1785000003, "zone", 0, 1, 1, 12 })
local pathSent = 0
cy.onSend = function(_, text)
    if text:sub(1, 1) == "B" and text:find('sd~s1,3,-2', 1, true) then pathSent = pathSent + 1 end
end
DF:Sync("Cy")
Run()
cy.onSend = nil
check(copy.journey == held, "an event merged in the middle fetched the path too")
check(pathSent == 0, "an event merged in the middle sent the path again")
Same("event in the middle")
held = copy.journey
table.insert(cy.ns.char.segments, 2, { m = "w", c = 0, t = 1785005000, x = 1, y = 1, d = "1,1,1" })
DF:Sync("Cy")
Run()
check(copy.journey ~= held, "a segment merged in the middle was grafted onto")
Same("segment in the middle")

-- A rewind that stops part way leaves a copy that says it is partial.
table.insert(cy.ns.char.events, 6, { 1785000004, "zone", 0, 1, 1, 12 })
local armed, cut = false, 0
di.onSend = function(_, text)
    -- The ask for the events again: those it then sends are the ones cut.
    if text:match("^Q:%x+:%d+:%d+:%d+:%d+:0:") then armed = true end
end
cy.onSend = function(_, text)
    if armed and text:sub(1, 1) == "B" then
        cut = cut + 1
        if cut > 3 then return 12 end
    end
end
DF:Sync("Cy")
Run()
cy.onSend, di.onSend = nil, nil
check(armed and cut > 3, "the rewind wasn't cut part way")
check(DF:Status(copy) == "Stopped. Sync again to carry on.", "a stopped rewind not said: " .. DF:Status(copy))
check(not copy.synced, "a copy part fetched again still says when it was last synced")
DF:Sync("Cy")
Run()
check(copy.synced, "the next sync didn't finish it")
Same("after a stopped rewind")

-- The latest events are sent again anyway, so one landing there costs no more.
held = copy.journey
table.insert(cy.ns.char.events, #cy.ns.char.events - 2, { 1785000037, "zone", 0, 1, 1, 12 })
cy.ns.char.events[#cy.ns.char.events + 1] = { 1786000000, "zone", 0, 1, 1, 12 }
local asks = {}
di.onSend = function(_, text)
    local have = text:match("^Q:%x+:%d+:%d+:%d+:%d+:(%d+):")
    if have then asks[#asks + 1] = have end
end
DF:Sync("Cy")
Run()
di.onSend = nil
check(copy.journey == held, "an event among the latest fetched the whole journey again")
check(#asks == 1 and asks[1] ~= "0", "an event among the latest fetched the events again")
Same("event among the latest")

-- A sender from before stamps gets the same: its rewind has no print to check,
-- as it can't say it is starting again.
local stamped = cy.ns.char.journeyId
cy.ns.char.journeyId = nil
DF:Sync("Cy")
Run()
Same("sender without a stamp")
table.insert(cy.ns.char.events, 5, { 1785000002, "zone", 0, 1, 1, 12 })
DF:Sync("Cy")
Run()
check(DF:Status(copy):find("^Last synced"), "a rewind without a stamp stopped: " .. DF:Status(copy))
Same("event in the middle, no stamp")
table.insert(cy.ns.char.segments, 2, { m = "w", c = 0, t = 1785004000, x = 1, y = 1, d = "1,1,1" })
DF:Sync("Cy")
Run()
check(DF:Status(copy):find("^Last synced"), "a path rewind without a stamp stopped: " .. DF:Status(copy))
Same("segment in the middle, no stamp")
cy.ns.char.journeyId = stamped

-- A stamp kept from before its length was checked can't stop the asking (the
-- client model checks each message is under 255 bytes).
copy.journey.journeyId = string.rep("x", 300)
DF:Sync("Cy")
Run()
check(copy.journey.journeyId == "Player-1-FFFF:0", "a long stamp kept: " .. DF:Status(copy))
Same("after a long stamp")

-- Locked here: the send's result says so, and it says why.
di.onSend = function() return 11 end
DF:Sync("Cy")
check(DF:Status(copy):find("inside a dungeon"), "result 11 not named: " .. DF:Status(copy))
check(not DF:Busy(), "still asking")
di.onSend = function() return 9 end
DF:Sync("Cy")
check(DF:Status(copy) == "Could not send. Are they online?", "other results changed: " .. DF:Status(copy))
di.onSend = nil

-- Lockdown said but the send still goes: the game decides, so the sync works.
di.env.C_ChatInfo.InChatMessagingLockdown = function() return true end
cy.env.C_ChatInfo.InChatMessagingLockdown = function() return true end
DF:Sync("Cy")
Run()
check(DF:Status(copy):find("^Last synced"), "refused a sync the game would have sent: " .. DF:Status(copy))
di.env.C_ChatInfo.InChatMessagingLockdown, cy.env.C_ChatInfo.InChatMessagingLockdown = nil, nil

-- Locked there: they can't answer, not even to say so, and the wait says it may be that.
cy.onSend = function() return 11 end
DF:Sync("Cy")
Run()
check(DF:Status(copy):find("^No answer") and DF:Status(copy):find("dungeon"), "no answer not explained: " .. DF:Status(copy))
cy.onSend = nil
DF:Sync("Cy")
Run()

-- An automatic round in lockdown asks, and says nothing when it can't.
local refused = 0
di.onSend = function()
    refused = refused + 1
    return 11
end
check(DF:ParseAutoSync("5"), "choice not taken")
At(330, function() DF:ParseAutoSync("off") end)
Run()
check(refused > 0, "the automatic round didn't ask")
check(DF:Status(copy):find("^Last synced"), "an automatic round reported lockdown: " .. DF:Status(copy))
di.onSend = nil

-- A send said to be offline may still bring the game's line: hidden, once a
-- friend's ask has ended, for each of them, and only for a moment.
local hid = {}
for _, name in ipairs({ "Gone", "Away", "Left" }) do
    di.ns.db.friends[name:lower()] = { name = name, realm = "Era" }
end
di.onSend = function(_, _, _, target)
    if target ~= "Cy" then
        local line = OFFLINE:format(target)
        At(0.05, function() hid[#hid + 1] = di.filter(nil, "CHAT_MSG_SYSTEM", line) end)
        At(0.1, function() hid[#hid + 1] = di.filter(nil, "CHAT_MSG_SYSTEM", line) end)
        At(5, function() hid.later = di.filter(nil, "CHAT_MSG_SYSTEM", line) end)
        return 12
    end
end
check(DF:ParseAutoSync("5"), "choice not taken")
At(330, function() DF:ParseAutoSync("off") end)
Run()
di.onSend = nil
check(#hid >= 6, "not every offline friend was asked: " .. #hid)
for i, seen in ipairs(hid) do check(seen == true, "offline line " .. i .. " not hidden after result 12") end
check(hid.later == false, "offline line hidden too long")
check(DF:Status(di.ns.db.friends.gone) == "Not synced yet.", "offline friend reported: " .. DF:Status(di.ns.db.friends.gone))
for _, name in ipairs({ "gone", "away", "left" }) do di.ns.db.friends[name] = nil end

-- A send that can't go on stops at once, and the friend carries on later.
for _, result in ipairs({ 11, 12 }) do
    local bigger2 = Journey(9000, 300)
    bigger2.journeyId = "Player-1-FFFF:" .. (30 + result)
    cy.ns.char = bigger2
    local parts, lineHidden = 0, nil
    cy.onSend = function(_, text)
        if text:sub(1, 1) == "B" then
            parts = parts + 1
            if parts > 5 then
                if result == 12 then
                    At(0.05, function() lineHidden = cy.filter(nil, "CHAT_MSG_SYSTEM", OFFLINE:format("Di-Era")) end)
                end
                return result
            end
        end
    end
    DF:Sync("Cy")
    Run()
    check(parts == 6, "result " .. result .. " didn't stop the send: " .. parts .. " parts")
    check(DF:Status(copy):find("^Stopped"), "sync not stopped: " .. DF:Status(copy))
    check(result ~= 12 or lineHidden == true, "offline line not hidden for a send")
    cy.onSend = nil
    DF:Sync("Cy")
    Run()
    check(copy.synced and DF:Status(copy):find("^Last synced"), "didn't carry on: " .. DF:Status(copy))
    Same("after result " .. result)
end
check(#cy.errors == 0 and #di.errors == 0, "errors: " .. tostring(cy.errors[1] or di.errors[1]))

if failures > 0 then os.exit(1) end
print("friends_test: all passed")
