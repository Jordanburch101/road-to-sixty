-- Offline test of the guild repair in Tidy.lua. Run with LuaJIT from the
-- repo root: luajit tests/tidy_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Tidy.lua"))("RoadToSixty", ns)
local Tidy = ns.Tidy

local FULL = { bg = { 1, 0, 0 }, border = { 0, 0, 1 }, emblem = 5 }

local function Kinds(events)
    local out = {}
    for i, e in ipairs(events) do out[i] = e[2] .. "@" .. e[1] end
    return table.concat(out, " ")
end

-- 1. A rank change where only the rank number flickered is dropped; a real
-- one stays.
local char = {
    guild = { "Knights", "Member", 3, FULL },
    events = {
        { 100, "gj", 0, 0, 0, "Knights", "Initiate", 4, FULL },
        { 200, "gr", 0, 0, 0, "Knights", "Initiate", 4 },   -- same rank name: a flicker
        { 300, "gr", 0, 0, 0, "Knights", "Member", 3 },     -- a real promotion
        { 400, "gr", 0, 0, 0, "Knights", "Member", 3 },     -- flicker again
    },
}
Tidy.Guilds(char)
check(Kinds(char.events) == "gj@100 gr@300", "flickers dropped, promotion kept: " .. Kinds(char.events))

-- 2. A join saved without the tabard's colours gets the current guild's.
char = {
    guild = { "Knights", "Member", 3, FULL },
    events = { { 100, "gj", 0, 0, 0, "Knights", "Member", 3, { emblem = 5 } } },
}
Tidy.Guilds(char)
check(char.events[1][9] == FULL, "an incomplete tabard on the join is filled from the current guild")

-- 3. An incomplete tabard on the current guild is dropped, so it is read again.
char = { guild = { "Knights", "Member", 3, { emblem = 5 } }, events = {} }
Tidy.Guilds(char)
check(char.guild[4] == nil, "an incomplete current tabard is cleared")

-- 4. In no guild (false) or not read yet (nil): rank flickers still go, nothing errors.
for _, guild in ipairs({ false, "unread" }) do
    char = {
        guild = guild ~= "unread" and guild or nil,
        events = {
            { 100, "gj", 0, 0, 0, "Old", "Member", 3 },
            { 200, "gr", 0, 0, 0, "Old", "Member", 3 },
            { 300, "gl", 0, 0, 0, "Old" },
        },
    }
    Tidy.Guilds(char)
    check(Kinds(char.events) == "gj@100 gl@300", "works with guild = " .. tostring(guild) .. ": " .. Kinds(char.events))
end

check(Tidy.TabardComplete(FULL) == true and Tidy.TabardComplete({ bg = {} }) == false
    and Tidy.TabardComplete(nil) == false, "TabardComplete needs bg and border")

if failures == 0 then
    print("Tidy tests passed.")
else
    print(failures .. " tidy test(s) failed.")
    os.exit(1)
end
