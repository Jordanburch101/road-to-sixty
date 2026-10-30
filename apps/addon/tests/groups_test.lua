-- Offline test of Groups.lua with a fake WoW API: a group open at logout
-- and found gone at login counts its time under the PC that started it, so
-- two PCs ending the same group count it once. Run with LuaJIT from
-- apps/addon: luajit tests/groups_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = { pc = "pcB" }
ns.Now = function() return 1000 end
ns.On = function() return true end   ---@diagnostic disable-line: duplicate-set-field
ns.Command = function() end
ns.SafeCall = function(fn, ...) fn(...) end
ns.Recorder = { Position = function() return 0, 10, 20 end }
ns.Journal = { Log = function() end, JoinRun = function() end }
LE_PARTY_CATEGORY_HOME = 1
IsInGroup = function() return false end
assert(loadfile("RoadToSixty/Tally.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Groups.lua"))("RoadToSixty", ns)

ns.char = {
    events = {}, people = { G1 = {} },
    totals = { kills = 0, killXP = 0, questXP = 0, quests = 0, deaths = 0, instances = 0 },
    group = { t = 100, kind = "party", pc = "pcA", members = { G1 = 100 }, everMet = { G1 = true },
        levels = {}, subs = {}, seen = 400, met = 1, kills = 0, xp = 0, quests = 0, deaths = 0, instances = 0 },
}
ns.Groups:Resume()
local seconds = ns.char.people.G1.seconds or {}
check(ns.char.group == nil, "a group gone at login ends")
check(seconds.pcA == 300 and seconds.pcB == nil, "its time counts under the PC that started it: " .. tostring(seconds.pcA) .. "/" .. tostring(seconds.pcB))

-- A group from before this change has no pc: it counts as this PC's, as before.
ns.char.people.G1 = {}
ns.char.group = { t = 100, kind = "party", members = { G1 = 100 }, everMet = { G1 = true },
    levels = {}, subs = {}, seen = 200, met = 1, kills = 0, xp = 0, quests = 0, deaths = 0, instances = 0 }
ns.Groups:Resume()
check((ns.char.people.G1.seconds or {}).pcB == 100, "an older group without a pc counts as this PC's")

-- A member whose name the client has not loaded yet (after a loading
-- screen) is still in the group: no leave, no rejoin. And inside a
-- battleground the home group is left alone. Groups.lua is loaded again
-- with its handlers kept, so the login can make it ready.
local handlers, logged = {}, {}
ns.On = function(event, fn) handlers[event] = fn return true end   ---@diagnostic disable-line: duplicate-set-field
ns.Journal.Log = function(_, kind) logged[#logged + 1] = kind end
C_Timer = { After = function(_, fn) fn() end }
UNKNOWNOBJECT = "Unknown"
local name, inBattleground = "Brightmane", false
IsInGroup = function(category) return category == 1 end
IsInInstance = function() return inBattleground, inBattleground and "pvp" or "none" end
LE_PARTY_CATEGORY_INSTANCE = 2
IsInRaid = function() return false end
GetNumSubgroupMembers = function() return 1 end
UnitIsUnit = function() return false end
UnitGUID = function(unit) return unit == "party1" and "G2" or nil end
UnitName = function(unit) return unit == "party1" and name or nil end
UnitRace = function() return "Human", "Human" end
UnitClass = function() return "Priest", "PRIEST" end
UnitLevel = function() return 20 end
UnitSex = function() return 3 end
GetGuildInfo = function() return nil end
UnitIsGroupLeader = function() return false end
assert(loadfile("RoadToSixty/Groups.lua"))("RoadToSixty", ns)
ns.char.people, ns.char.group = {}, nil
handlers.PLAYER_LOGIN()
check(ns.char.group and ns.char.group.members.G2, "the group starts with its member")
local before = #logged
name = "Unknown"
ns.Groups:Check()
check(#logged == before and ns.char.group.members.G2, "a member not loaded yet has not left: " .. table.concat(logged, ",", before + 1))
inBattleground, name = true, "Brightmane"
UnitGUID = function(unit) return unit == "party1" and "BG1" or nil end     -- a battleground stranger
ns.Groups:Check()
check(#logged == before and not ns.char.group.members.BG1, "in a battleground the home group is left alone")

if failures == 0 then
    print("Groups tests passed.")
else
    print(failures .. " groups test(s) failed.")
    os.exit(1)
end
