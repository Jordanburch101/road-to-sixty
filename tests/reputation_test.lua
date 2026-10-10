-- Offline test of Reputation.lua with a fake reputation list: the first read
-- is a baseline, changes of standing are logged, factions under collapsed
-- headers are found and the headers closed again. Run with LuaJIT from the
-- repo root: luajit tests/reputation_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, timers = {}, {}
local ns = { char = { events = {} } }
ns.view = ns.char
ns.Journal = {
    Log = function(_, kind, ...)
        table.insert(ns.char.events, { 0, kind, 0, 0, 0, ... })
    end,
}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
function ns.SafeCall(fn, ...) fn(...) end
function ns.Command() end
function ns.Print() end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }

-- The client's list, as a tree: headers with factions in them. A collapsed
-- header's factions are not in the flat list the API shows.
local tree = {
    { name = "Alliance", header = true, collapsed = false, children = {
        { id = 72, name = "Stormwind", standing = 5 },
        { id = 47, name = "Ironforge", standing = 4 },
    } },
    { name = "Other", header = true, collapsed = true, children = {
        { id = 59, name = "Thorium Brotherhood", standing = 4 },
        { name = "Inner", header = true, collapsed = true, children = {
            { id = 576, name = "Timbermaw Hold", standing = 2 },
        } },
    } },
}
local byID = {}
local function Index(nodes)
    for _, n in ipairs(nodes) do
        if n.id then byID[n.id] = n end
        if n.children then Index(n.children) end
    end
end
Index(tree)

local updates = 0
local function Flat()
    local list = {}
    local function Walk(nodes)
        for _, n in ipairs(nodes) do
            list[#list + 1] = n
            if n.header and not n.collapsed then Walk(n.children) end
        end
    end
    Walk(tree)
    return list
end
local function Data(n)
    return n and { factionID = n.id, name = n.name, reaction = n.standing, isHeader = n.header,
        isCollapsed = n.collapsed }
end
C_Reputation = {
    GetNumFactions = function() return #Flat() end,
    GetFactionDataByIndex = function(i) return Data(Flat()[i]) end,
    GetFactionDataByID = function(id) return Data(byID[id]) end,
    ExpandFactionHeader = function(i)
        Flat()[i].collapsed = false
        updates = updates + 1
        Fire("UPDATE_FACTION")      -- the client tells at once
    end,
    CollapseFactionHeader = function(i) Flat()[i].collapsed = true end,
}

assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Reputation.lua"))("RoadToSixty", ns)
local Reputation = ns.Reputation

local function Kinds()
    local list = {}
    for _, e in ipairs(ns.char.events) do
        list[#list + 1] = ("%s %d %d %s"):format(e[2], e[6], e[7], tostring(e[9]))
    end
    return table.concat(list, ", ")
end

-- Nothing is read before the login delay.
Fire("UPDATE_FACTION")
check(ns.char.reps == nil, "nothing read before login")

-- Login: the baseline has every faction, also under collapsed headers, and logs nothing.
Fire("PLAYER_LOGIN")
timers[1]()
local count = 0
for _ in pairs(ns.char.reps or {}) do count = count + 1 end
check(count == 4, "baseline has all four factions: " .. count)
check(#ns.char.events == 0, "baseline logs nothing: " .. Kinds())
check(updates == 2, "both collapsed headers were opened: " .. updates)
check(tree[2].collapsed and tree[2].children[2].collapsed, "headers are closed again")

-- A gain within the same standing logs nothing; a new level does.
Fire("UPDATE_FACTION")
check(#ns.char.events == 0, "no change, nothing logged")
byID[72].standing = 6
Fire("UPDATE_FACTION")
check(Kinds() == "rep 72 6 true", "Honored with Stormwind: " .. Kinds())

-- A faction under a collapsed header is still read, by its ID.
byID[576].standing = 3
Fire("UPDATE_FACTION")
check(Kinds() == "rep 72 6 true, rep 576 3 true", "Timbermaw read by ID: " .. Kinds())

-- Dropping a level is logged without up.
byID[47].standing = 3
Fire("UPDATE_FACTION")
check(Kinds():match("rep 47 3 nil$"), "drop logged: " .. Kinds())
local title = Reputation:Describe(ns.char.events[#ns.char.events])
check(title == "Dropped to Unfriendly with Ironforge", "drop title: " .. title)
check((Reputation:Describe(ns.char.events[1])) == "Honored with Stormwind", "rise title")

-- A faction met under a collapsed header: the chat names it, a deep read
-- finds it, and meeting it logs nothing.
local events = #ns.char.events
table.insert(tree[2].children, { id = 529, name = "Argent Dawn", standing = 4 })
byID[529] = tree[2].children[3]
Fire("CHAT_MSG_SYSTEM", "You are now Neutral with Argent Dawn.")
check(ns.char.reps[529] ~= nil, "new faction found by opening headers")
check(#ns.char.events == events, "meeting a faction logs nothing")
check(tree[2].collapsed, "header closed again after the chat read")

-- Stats: best standing first.
local list = Reputation:Standings()
check(list[1][1] == "Stormwind" and list[1][2] == 6, "best standing first: " .. tostring(list[1][1]))

-- A seeded journey is left alone.
ns.char.seeded = true
byID[72].standing = 7
Fire("UPDATE_FACTION")
check(ns.char.reps[72][1] == 6, "seeded journey not read")

if failures > 0 then
    print(("reputation_test: %d failure(s)"):format(failures))
    os.exit(1)
end
print("reputation_test: ok")
