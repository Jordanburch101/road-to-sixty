-- Offline test of replaying together, run from the real Map.lua on stand-ins:
-- on the real clock a character that logged off waits where it was, on the
-- played clock logins cost nothing and everyone starts at once, and long
-- stretches with nobody moving are skipped. Also the Characters tab's filter,
-- from the real Panel.lua.
-- Run with LuaJIT from apps/addon: luajit tests/together_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local file = assert(io.open("RoadToSixty/Map.lua", "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local from = assert(source:find("-- Replaying together: every path", 1, true))
local to = assert(source:find("local function OnUpdate(_, elapsed)", from, true))
check(source:find('Together.SPEEDS = {\n    { 120, "2m/s" }', 1, true), "the slowest speed is not 2m/s")

local prelude = [[
local T = ...
local state, ns, charMarkers, otherLines = T.state, T.ns, T.charMarkers, T.otherLines
local infoText, speedButton = T.infoText, T.speedButton
local SPEEDS = { 1, 2 }
local Together = { SPEEDS = { { 600, "10m/s" }, { 3600, "1h/s" } }, GAP = 600, OFFLINE_GAP = 1800,
    button = T.togetherButton }
local function PlaceCharacters() end
local function FormatTime(t) return "t" .. t end
local function SetPlaying(on) state.playing = on end
local function ApplyCursor() end
local function FollowHead() end
]]

local function LastIndex(times, t)
    local lo, hi = 0, #times
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if times[mid] <= t then lo = mid else hi = mid - 1 end
    end
    return lo
end
local function Stub()
    return {
        SetText = function(self, v) self.text = v end,
        SetShown = function(self, v) self.shown = v end,
    }
end

local T = { ns = { LastIndex = LastIndex, FormatDuration = function(t) return t .. "s" end } }
T.infoText, T.speedButton, T.togetherButton = Stub(), Stub(), Stub()
-- Both log off for hours, at different times.
local friend = { n = 3, pt = { 105, 120, 4000 }, px = { 1, 2, 3 }, py = { 4, 5, 6 },
    pj = { [3] = "l" }, brk = { true, false, true } }
local old = { n = 2, px = { 9, 9 }, py = { 9, 9 } }     -- saved before paths had times
T.charMarkers = { Stub(), Stub() }
T.charMarkers[1].entry, T.charMarkers[2].entry = "friend", "old"
T.otherLines = { Stub(), Stub(), Stub() }
T.state = {
    n = 4, pt = { 100, 110, 5000, 5010 }, pj = { [3] = "l" }, brk = { true, false, true, false },
    cur = 4, togetherSpeed = 1, speedIndex = 1, charCount = 2, otherTracks = { friend, old },
    trackOf = { friend = friend, old = old }, otherLineCount = 3,
    otherDrawn = { { [6] = 2, track = friend }, { [6] = 3, track = friend }, { [6] = 2, track = old } },
}
local body = prelude .. source:sub(from, to - 1) .. "\nreturn Together\n"
local Together = assert(loadstring(body, "together"))(T)
local s, marker = T.state, T.charMarkers[1]

-- Real time: nobody shows before their first point, and a character that
-- logged off waits where it was until it returns.
s.togetherMode = "real"
local a, b = Together.Bounds()
check(a == 100 and b == 5010, "real bounds")
check(Together.NextMove(100) == 105 and Together.NextMove(120) == 4000, "next move")
check(Together.NextMove(5010) == nil, "a move after the end")
s.clock, s.clockTo, s.playing = 100, 5010, true
Together.Apply()
check(marker.shown == false and T.otherLines[1].shown == false, "showing before their start")
check(T.otherLines[3].shown == true, "an untimed path hidden")
check(T.infoText.text == "t100", "date not shown")
s.clock = 3000
Together.Apply()
check(marker.shown == true and marker.x == 2, "not waiting where it logged off")
check(T.otherLines[1].shown == true and T.otherLines[2].shown == false, "lines while logged off")
s.clock = 120
Together.Step(0.016)            -- the long stretch nobody moved in is skipped
check(s.clock == 4000 and s.cur == 2, "gap not skipped: " .. s.clock)
check(marker.x == 3 and T.otherLines[2].shown == true, "did not return")

-- Play time: logins cost nothing, and everyone starts at the same moment.
s.togetherMode = "game"
s.pg, friend.pg = nil, nil
a, b = Together.Bounds()
check(a == 0 and b == 20, "played bounds: " .. a .. " " .. b)
s.clock, s.clockTo, s.playing = 0, b, true
Together.Apply()
check(marker.shown == true and marker.x == 1, "friend not at their start")
check(T.infoText.text == "0s played", "time played not shown")
s.clock = 14
Together.Apply()
check(marker.x == 1, "friend ahead of their time played")
s.clock = 16
Together.Apply()
check(marker.x == 3, "login gap not removed")
s.clock = 15
Together.Step(0.5)
check(s.clock == 20 and s.playing == false and s.cur == 4, "end not reached")

-- What counts as time away.
local pg = Together.PlayedTimes({ n = 3, pt = { 0, 100, 5000 }, pj = { [3] = "h" }, brk = { true, false, true } })
check(pg[3] == 5000, "a hearthstone is not a logoff")
pg = Together.PlayedTimes({ n = 3, pt = { 0, 100, 5000 }, pj = {}, brk = { true, false, true } })
check(pg[3] == 100, "an old save's long break is a logoff")
pg = Together.PlayedTimes({ n = 3, pt = { 0, 100, 5000 }, pj = {}, brk = { true, false, false } })
check(pg[3] == 5000, "standing still is still playing")

Together.End()
check(s.clock == nil and s.togetherMode == nil, "end left the clock")
check(T.togetherButton.text == "Solo" and T.speedButton.text == "1x", "end left the buttons")

-- The Characters tab's filter.
local ns = {}
assert(loadfile("RoadToSixty/Panel.lua"))("RoadToSixty", ns)
local entries = {
    { name = "Zed" }, { name = "Alt" },
    { name = "Bromm", friend = true, battleTag = "Bromm#1234" },
    { name = "Brommalt", friend = true, battleTag = "Bromm#1234" },
    { name = "Ann", friend = true },
}
local groups = ns.Panel:CharacterGroups(entries)
check(#groups == 4 and groups[1].key == "all" and groups[2].key == "mine", "groups")
check(groups[3].label == "Bromm#1234" and groups[4].label == "Ann", "friend groups")
check(#ns.Panel:FilterCharacters(entries, "all") == 5, "all")
local mine = ns.Panel:FilterCharacters(entries, "mine")
check(#mine == 2 and mine[2].name == "Alt", "mine")
local theirs = ns.Panel:FilterCharacters(entries, "Bromm#1234")
check(#theirs == 2 and theirs[2].name == "Brommalt", "a friend's characters")
check(#ns.Panel:FilterCharacters(entries, "Ann") == 1, "a friend with no tag")

if failures > 0 then os.exit(1) end
print("together_test: all passed")
