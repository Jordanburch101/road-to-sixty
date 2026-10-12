-- Offline test of Core.lua's saved variable setup with a fake WoW API: a
-- new character starts on the current layout, an older file is brought up
-- to it, and the addon version is saved. Run with LuaJIT from the repo
-- root: luajit tests/core_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local script
CreateFrame = function()
    return {
        RegisterEvent = function() end,
        SetScript = function(_, _, fn) script = fn end,
    }
end
SlashCmdList = {}
CopyTable = function(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = type(v) == "table" and CopyTable(v) or v end
    return copy
end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
time = function() return 1000 end
GetServerTime = function() return 2000 end
C_AddOns = { GetAddOnMetadata = function(_, field) return field == "Version" and "9.9.9" or nil end }

local function Load(saved)
    RoadToSixtyDB, RoadToSixtyCharDB = nil, saved
    local ns = {}
    assert(loadfile("RoadToSixty/Core.lua"))("RoadToSixty", ns)
    script(nil, "ADDON_LOADED", "RoadToSixty")
    return ns
end

-- 1. A new character starts on the current layout, all by the realm's clock.
local ns = Load(nil)
local current = ns.char.version
check(current >= 2, "a new character is on layout 2 or later, got " .. tostring(current))
check(ns.char.clockFrom == nil, "a new journey has no PC clock part")
check(ns.char.addon == "9.9.9", "the addon version is saved")
check(ns.Now() == 2000, "ns.Now reads the realm's clock")

-- 2. A file from layout 1 is upgraded, keeping its data, and marks when it
-- moved to the realm's clock.
ns = Load({ version = 1, events = { { 500, "on" } }, segments = {} })
check(ns.char.version == current, "an old file is brought up to the current layout")
check(ns.char.clockFrom == 2000, "an old file notes when it moved to the realm's clock")
check(#ns.char.events == 1 and ns.char.kills and ns.char.totals, "an old file keeps its data and gains defaults")

-- 3. Loading again changes nothing more.
ns = Load(ns.char)
check(ns.char.clockFrom == 2000, "clockFrom is set once")

if failures == 0 then
    print("Core tests passed.")
else
    print(failures .. " core test(s) failed.")
    os.exit(1)
end
