-- Offline test of Parties:Info (Parties.lua). Run with LuaJIT from apps/addon:
-- luajit tests/parties_test.lua
--
-- Info works out who was in a group from the events after its grp event.
-- It used to search the journey from its start for every group, which
-- took seconds on a long journey each time the map opened (#103); it now
-- reads on from the group's place in an index. This checks it against the
-- old search on a made-up journey, as the live journey grows and after a
-- journey changed in place, and times it on a long one.

local jit = rawget(_G, "jit")
if jit then jit.off() end

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

function wipe(t)
    for k in pairs(t) do t[k] = nil end
    return t
end

local ns = { view = { events = {} } }
assert(loadfile("RoadToSixty/Parties.lua"))("RoadToSixty", ns)
local Parties = ns.Parties

-- The old Info, searching from the journey's start: the reference.
local FORMING = 10
local function OldInfo(e, events)
    local info = { kind = e[6], leader = e[8], start = e[1], members = {}, mySub = e[9], instances = {} }
    local byGuid = {}
    local function Add(m, joined)
        local entry = byGuid[m[1]]
        if entry then
            entry.left = nil
        else
            entry = { m = m, joined = joined, sub = m[8] }
            byGuid[m[1]] = entry
            info.members[#info.members + 1] = entry
        end
    end
    for _, m in ipairs(e[7] or {}) do Add(m, nil) end
    local found = false
    for _, other in ipairs(events) do
        local kind = other[2]
        if other == e then
            found = true
        elseif found then
            if kind == "grpa" then
                Add(other[6], other[1] - e[1] > FORMING and other[1] or nil)
            elseif kind == "grpl" then
                local entry = byGuid[other[6]]
                if entry then entry.left, entry.endLevel = other[1], other[7] or entry.endLevel end
            elseif kind == "grpk" then
                info.kind = other[6]
            elseif kind == "grps" then
                if other[6] == false then
                    info.mySub = other[7]
                elseif byGuid[other[6]] then
                    byGuid[other[6]].sub = other[7]
                end
            elseif kind == "in" then
                local name = other[7] or "an instance"
                if not info.instances[name] then
                    info.instances[name] = true
                    info.instances[#info.instances + 1] = { name, other[8] }
                end
            elseif kind == "grpx" then
                info.summary, info.finish = other[6], other[1]
                for guid, level in pairs(other[6].levels or {}) do
                    if byGuid[guid] then byGuid[guid].endLevel = level end
                end
                break
            elseif kind == "grp" then
                break
            end
        end
    end
    return info
end

local function Same(a, b, seen)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    seen = seen or {}
    if seen[a] then return true end
    seen[a] = true
    for k, v in pairs(a) do
        if not Same(v, b[k], seen) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- A made-up journey: groups forming, people joining, leaving and moving,
-- raids, instances, ends, some groups never ended, and other events between.
math.randomseed(103)
local function Journey(count, groups)
    local events, t, open, nextGuid = {}, 1000, nil, 1
    local every = math.floor(count / groups)
    local function Member()
        nextGuid = nextGuid + 1
        return { "Player-" .. nextGuid, "P" .. nextGuid, "Human", "Male", "WARRIOR", 10, nil, math.random(1, 8) }
    end
    for i = 1, count do
        t = t + math.random(1, 30)
        local e
        if i % every == 1 then
            local members = { Member(), Member() }
            e = { t, "grp", 0, 0, 0, "party", members, i % 3 == 0, 1 }
            open = { members[1][1], members[2][1] }
        elseif open and math.random() < 0.02 then
            local m = Member()
            open[#open + 1] = m[1]
            e = { t, "grpa", 0, 0, 0, m }
        elseif open and math.random() < 0.01 then
            e = { t, "grpl", 0, 0, 0, open[math.random(#open)], 20 }
        elseif open and math.random() < 0.005 then
            e = { t, "grpk", 0, 0, 0, "raid" }
        elseif open and math.random() < 0.005 then
            e = { t, "grps", 0, 0, 0, math.random() < 0.3 and false or open[math.random(#open)], math.random(1, 8) }
        elseif math.random() < 0.003 then
            e = { t, "in", 0, 0, 0, 1, "Dungeon " .. math.random(1, 5), "party" }
        elseif open and math.random() < 0.003 then
            e = { t, "grpx", 0, 0, 0, { levels = { [open[1]] = 30 } } }
            open = nil
        else
            e = { t, "kill", 0, 0, 0 }
        end
        events[#events + 1] = e
    end
    return events
end

local function AllMatch(events, label)
    local groups, wrong = 0, 0
    for _, e in ipairs(events) do
        if e[2] == "grp" then
            groups = groups + 1
            if not Same(Parties:Info(e), OldInfo(e, events)) then wrong = wrong + 1 end
        end
    end
    check(groups > 0 and wrong == 0, ("%s: %d of %d groups differ from the old search"):format(label, wrong, groups))
end

local events = Journey(5000, 60)
ns.view.events = events
AllMatch(events, "a journey")

-- The live journey grows: a group still going gets a new member.
local last
for _, e in ipairs(events) do
    if e[2] == "grp" then last = e end
end
events[#events + 1] = { events[#events][1] + 60, "grpa", 0, 0, 0, { "Player-new", "New", "Orc", "Female", "MAGE", 12 } }
Parties:Reset()
AllMatch(events, "after the journey grew")
local found = false
for _, entry in ipairs(Parties:Info(last).members) do
    if entry.m[1] == "Player-new" then found = true end
end
check(found or Parties:Info(last).finish, "the last group, if still going, has the member who came later")

-- The live journey grows by a new group, after its events were indexed:
-- the index carries on to it rather than being made again.
local newGroup = { events[#events][1] + 60, "grp", 0, 0, 0, "party", { { "Player-late", "Late" } }, false, 1 }
events[#events + 1] = newGroup
events[#events + 1] = { newGroup[1] + 30, "grpa", 0, 0, 0, { "Player-later", "Later", "Orc", "Male", "ROGUE", 14 } }
events[#events + 1] = { newGroup[1] + 90, "grpx", 0, 0, 0, { levels = {} } }
check(Parties.Position(events, newGroup) == #events - 2, "a group added to the live journey is found where it is")
local late = Parties:Info(newGroup)
check(#late.members == 2 and late.members[2].m[1] == "Player-later" and late.finish == newGroup[1] + 90,
    "a group added to the live journey has its own members and end")
AllMatch(events, "after a group was added")

-- Shrunk and grown again in place (an event taken out, others added).
table.remove(events, 5)
events[#events + 1] = { events[#events][1] + 10, "kill", 0, 0, 0 }
Parties:Reset()
AllMatch(events, "after the journey shrank and grew again")

-- A journey changed in place (an event put in near the start).
table.insert(events, 3, { events[2][1], "kill", 0, 0, 0 })
Parties:Reset()
AllMatch(events, "after an event was put in near the start")

-- Another journey shown: its own events.
local other = Journey(2000, 20)
ns.view.events = other
Parties:Reset()
AllMatch(other, "another journey")

-- A grp event that isn't in the journey shown: only its first members.
local stray = { 1, "grp", 0, 0, 0, "party", { { "Player-x", "X" } }, false, 1 }
local info = Parties:Info(stray)
check(#info.members == 1 and info.finish == nil, "a group not in the journey keeps its first members")

-- Long journeys: the map works out every group once for the markers and
-- once more for History. Timed with the JIT off, as the game runs it.
local long = Journey(100000, 1500)
ns.view.events = long
local clock = os.clock()
for _ = 1, 2 do
    Parties:Reset()
    for _, e in ipairs(long) do
        if e[2] == "grp" then Parties:Info(e) end
    end
end
local took = os.clock() - clock
-- The old search on every 30th group, scaled up, to say what it saved.
clock = os.clock()
local n = 0
for _, e in ipairs(long) do
    if e[2] == "grp" then
        n = n + 1
        if n % 30 == 0 then OldInfo(e, long) end
    end
end
local old = (os.clock() - clock) * 30 * 2
print(("Parties on 100,000 events and 1,500 groups, twice: %d ms (the old search: about %d ms)"):format(took * 1000, old * 1000))
check(took < 0.25, "every group twice in under 250 ms, took " .. math.floor(took * 1000) .. " ms")

if failures == 0 then
    print("Parties tests passed.")
else
    print(failures .. " parties test(s) failed.")
    os.exit(1)
end
