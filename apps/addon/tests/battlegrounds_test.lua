-- Offline test of Battlegrounds.lua with the score board an Alterac Valley
-- probe showed on Anniversary (#80): honor and reputation from chat while
-- inside, the result and the player's row once there is a winner, the
-- map's columns kept after the board drops them, and what History shows.
-- Run with LuaJIT from apps/addon: luajit tests/battlegrounds_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers = {}
local ns = { char = { run = { type = "pvp", t = 1000 } } }
function ns.On(event, fn) handlers[event] = fn return true end
function ns.Commas(n) return tostring(n) end
local function Fire(event, ...) handlers[event](...) end
assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)

UnitName = function() return "Judgejbrown" end
UnitClass = function() return "Paladin", "PALADIN" end
FACTION_STANDING_INCREASED = "Reputation with %s increased by %d."
COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (%d Honor Points)"
local winner, columns, runTime = nil, 5, 602000
-- 40 a side, Alliance (1) in rows 1 to 40; the player is row 21.
GetNumBattlefieldScores = function() return 80 end
GetBattlefieldScore = function(i)
    if i == 21 then return "Judgejbrown", 0, 0, 4, 420, 1, 0, "Human", "Paladin", "PALADIN", 1397, 33, 0, 0 end
    return "Player" .. i, 1, 2, 3, 100, i <= 40 and 1 or 0
end
GetBattlefieldWinner = function() return winner end
GetBattlefieldInstanceRunTime = function() return runTime end
GetNumBattlefieldStats = function() return columns end
local NAMES = { "Graveyards Assaulted", "Graveyards Defended", "Towers Assaulted", "Towers Defended", "Secondary Objectives" }
GetBattlefieldStatInfo = function(s) return NAMES[s], "icon", "tip" end
GetBattlefieldStatData = function(_, s) return s == 3 and 1 or 0 end
RequestBattlefieldScoreData = function() end

assert(loadfile("RoadToSixty/Battlegrounds.lua"))("RoadToSixty", ns)
local B = ns.Battlegrounds

check(B.IsPvP("pvp") and B.IsPvP("arena") and not B.IsPvP("party") and not B.IsPvP(nil), "which instance types are battlegrounds")

-- Which events are inside a battleground: after its "in", before its "out";
-- not the "in" itself, and not inside a dungeon.
local inside, marks = B.Tracker(), {}
for _, e in ipairs({ { 1, "die" }, { 2, "in", 0, 0, 0, 30, "Alterac Valley", "pvp" }, { 3, "die" }, { 4, "lvl" },
    { 5, "out" }, { 6, "die" }, { 7, "in", 0, 0, 0, 36, "Deadmines", "party" }, { 8, "die" } }) do
    marks[#marks + 1] = inside(e) and "x" or "."
end
check(table.concat(marks) == "..xx....", "events inside a battleground: " .. table.concat(marks))

-- While it goes on: honor and reputation from chat; no winner, no score read.
Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "You have been awarded 126 honor points.")
Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Someone dies, honorable kill Rank: Scout (42 Honor Points)")
Fire("CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Stormpike Guard increased by 137.")
Fire("CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Stormpike Guard increased by 13.")
Fire("UPDATE_BATTLEFIELD_SCORE")
local pvp = ns.char.run.pvp
check(pvp and pvp.honor == 168, "honor from chat as it comes: " .. tostring(pvp and pvp.honor))
check(pvp and pvp.rep["Stormpike Guard"] == 150, "reputation gained inside, by faction")
check(pvp and pvp.won == nil and pvp.deaths == 4, "the score row is read during the match, the result not yet")
check(pvp and pvp.chatKills == 1, "honorable kills counted from chat: " .. tostring(pvp and pvp.chatKills))

-- The winner: the result and the player's row; then the map's columns go.
winner = 1
Fire("UPDATE_BATTLEFIELD_STATUS", 2)
check(pvp.won == true, "Alliance won and the player is Alliance: won")
check(pvp.kb == 0 and pvp.hk == 0 and pvp.deaths == 4 and pvp.scoreHonor == 420 and pvp.damage == 1397
    and pvp.healing == 33, "the player's score row")
check(pvp.length == 602, "the match length in seconds: " .. tostring(pvp.length))
check(pvp.teams[1] == 40 and pvp.teams[2] == 40, "40 a side")
check(#pvp.stats == 5 and pvp.stats[3][1] == "Towers Assaulted" and pvp.stats[3][2] == 1, "the map's columns")
columns, runTime = 0, 0
Fire("UPDATE_BATTLEFIELD_SCORE")
check(#pvp.stats == 5 and pvp.length == 602, "columns and length kept once the board drops them")

-- What History shows.
local function Duration(seconds) return math.floor(seconds / 60) .. "m" end
local s = { type = "pvp", duration = 610, deaths = 4, items = {}, pvp = pvp }
check(B:Detail(s, Duration) == "Won, 10m, 4 deaths, 168 honor", "History's line: " .. B:Detail(s, Duration))
local lines = table.concat(B:Lines(s), " | ")
check(lines:find("Won", 1, true) and lines:find("4 deaths", 1, true) and lines:find("Towers Assaulted: 1", 1, true)
    and lines:find("+150 Stormpike Guard", 1, true) and not lines:find("Graveyards", 1, true),
    "the card's lines: " .. lines)
check(B:Detail({ type = "pvp", duration = 300, deaths = 0, items = {} }, Duration) == "5m",
    "a battleground left before the end, recorded before this version")

-- Lost: the other side won.
ns.char.run = { type = "pvp", t = 2000 }
winner, columns, runTime = 0, 5, 300000
Fire("UPDATE_BATTLEFIELD_STATUS", 2)
check(ns.char.run.pvp.won == false, "Horde won: lost")

-- A client whose row has no rank: damage and healing are still found, after the class token.
GetBattlefieldScore = function(i)
    if i == 21 then return "Judgejbrown", 1, 2, 3, 300, 1, "Human", "Paladin", "PALADIN", 5000, 700 end
    return "Player" .. i, 1, 2, 3, 100, i <= 40 and 1 or 0
end
ns.char.run = { type = "pvp", t = 2500 }
Fire("UPDATE_BATTLEFIELD_SCORE")
check(ns.char.run.pvp.damage == 5000 and ns.char.run.pvp.healing == 700, "damage and healing without a rank field")

-- The player's row not found at the end: the board is asked for once, not on every update.
local asked = 0
RequestBattlefieldScoreData = function() asked = asked + 1 end
GetNumBattlefieldScores = function() return 0 end
ns.char.run = { type = "pvp", t = 2600 }
for _ = 1, 5 do Fire("UPDATE_BATTLEFIELD_SCORE") end
check(asked == 1, "the final board asked for once: " .. asked)

-- Not inside a battleground, or a dungeon run: nothing is added.
ns.char.run = { type = "party", t = 3000 }
Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "You have been awarded 126 honor points.")
Fire("UPDATE_BATTLEFIELD_STATUS", 2)
check(ns.char.run.pvp == nil, "a dungeon run gets no pvp")
ns.char.run = { type = "pvp", t = 4000, left = { t = 4100 } }
Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "You have been awarded 126 honor points.")
check(ns.char.run.pvp == nil, "a battleground left gets nothing more")

-- Forever: only C_PvP's board (GetBattlefieldScore, GetBattlefieldWinner and
-- the column calls are deprecated fallbacks, off by default), its numbers
-- secret until the match is over.
GetBattlefieldScore, GetBattlefieldWinner, GetBattlefieldInstanceRunTime = nil, nil, nil ---@diagnostic disable-line: assign-type-mismatch
GetNumBattlefieldStats, GetBattlefieldStatInfo, GetBattlefieldStatData = nil, nil, nil ---@diagnostic disable-line: assign-type-mismatch
local SECRET = setmetatable({}, { __tostring = function() return "secret" end })
issecretvalue = function(v) return v == SECRET end
local complete, matchWinner, duration = false, 255, 0
local function Value(v) return complete and v or SECRET end
UnitGUID = function() return "Player-1-00000001" end
local function Info(i)
    local me = i == 21
    return {
        name = me and "Judgejbrown" or ("Player" .. i), guid = me and "Player-1-00000001" or ("Player-1-" .. i),
        faction = i <= 40 and 1 or 0, classToken = "PALADIN",
        killingBlows = Value(me and 3 or 1), honorableKills = Value(me and 12 or 2), deaths = Value(me and 2 or 3),
        honorGained = Value(me and 250 or 100), damageDone = Value(me and 4000 or 10), healingDone = Value(me and 900 or 10),
        stats = me and {
            { pvpStatID = 2, pvpStatValue = Value(1), orderIndex = 2, name = "Flags Returned" },
            { pvpStatID = 1, pvpStatValue = Value(2), orderIndex = 1, name = "Flags Captured" },
        } or {},
    }
end
GetNumBattlefieldScores = function() return 80 end
C_PvP = {
    GetScoreInfo = function(i) return Info(i) end,
    GetScoreInfoByPlayerGuid = function(guid) return guid == "Player-1-00000001" and Info(21) or nil end,
    IsMatchComplete = function() return complete end,
    GetActiveMatchWinner = function() return matchWinner end,
    GetActiveMatchDuration = function() return duration end,
}
ns.char.run = { type = "pvp", t = 5000 }
Fire("UPDATE_BATTLEFIELD_SCORE")
pvp = ns.char.run.pvp
check(pvp and pvp.won == nil and pvp.kb == nil and pvp.deaths == nil and pvp.stats == nil,
    "Forever during the match: secret numbers are not read")
check(pvp and pvp.teams[1] == 40 and pvp.teams[2] == 40, "Forever: the sides are counted during the match")
complete, matchWinner, duration = true, 1, 845
Fire("PVP_MATCH_COMPLETE", 1, 845)
check(pvp.won == true and pvp.kb == 3 and pvp.hk == 12 and pvp.deaths == 2 and pvp.scoreHonor == 250
    and pvp.damage == 4000 and pvp.healing == 900, "Forever after the match: the result and the player's score")
check(pvp.length == 845, "Forever: the match length: " .. tostring(pvp.length))
check(pvp.stats and #pvp.stats == 2 and pvp.stats[1][1] == "Flags Captured" and pvp.stats[1][2] == 2
    and pvp.stats[2][1] == "Flags Returned", "Forever: the map's columns in the board's order")
complete = false
Fire("UPDATE_BATTLEFIELD_SCORE")
check(pvp.kb == 3 and pvp.stats and #pvp.stats == 2 and pvp.length == 845, "numbers gone secret again keep the last read")
ns.char.run = { type = "pvp", t = 6000 }
complete, matchWinner = true, 0
Fire("UPDATE_BATTLEFIELD_STATUS", 2)
check(ns.char.run.pvp.won == false, "Forever: Horde won, lost")
ns.char.run = { type = "pvp", t = 7000 }
matchWinner = 255
Fire("UPDATE_BATTLEFIELD_STATUS", 2)
check(ns.char.run.pvp.won == nil and ns.char.run.pvp.kb == 3, "Forever: a draw has no result, the score is still read")

if failures > 0 then
    print(failures .. " battleground test(s) failed.")
    os.exit(1)
end
print("Battlegrounds tests passed.")
