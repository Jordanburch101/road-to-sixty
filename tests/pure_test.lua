-- The files the sync server runs must work with nothing but standard Lua
-- 5.1: no game API. It reads every global each file uses from LuaJIT's
-- bytecode listing, which covers branches no call below reaches and a
-- missing local, then loads each file in an environment holding only the
-- standard library and calls what it defines. Run with LuaJIT from the repo root: luajit tests/pure_test.lua

local STANDARD = {
    "assert", "error", "ipairs", "next", "pairs", "pcall", "select", "setmetatable",
    "getmetatable", "tonumber", "tostring", "type", "unpack", "string", "table", "math",
}

local function Load(name, ns)
    local env = {}
    for _, key in ipairs(STANDARD) do env[key] = _G[key] end
    local chunk = assert(loadfile("RoadToSixty/" .. name))
    setfenv(chunk, env)
    chunk("RoadToSixty", ns)
end

local allowed = {}
for _, key in ipairs(STANDARD) do allowed[key] = true end
for _, name in ipairs({ "Packed.lua", "Tidy.lua" }) do
    local listing = io.popen("luajit -bl RoadToSixty/" .. name):read("*a")
    for global in listing:gmatch('G[GS]ET%s+%d+%s+%d+%s+; "([^"]+)"') do
        assert(allowed[global], name .. " uses the global " .. global .. ", which the server does not have")
    end
end

local ns = {}
Load("Packed.lua", ns)
Load("Tidy.lua", ns)

local packed = ns.Packed.PackKills({ { t = 1, xp = 2, name = "A" } })
local list = {}
ns.Packed.DecodeKills(packed.d, packed.names, 0, list)
assert(list[1].name == "A")
assert(#ns.Packed.DecodePath({ t = 1, x = 0, y = 0, d = "1,1,1" }) == 2)

local char = {
    events = { { 1, "zone", 0, 0, 0, 1415 }, { 2, "die", 0, 0, 0 }, { 2, "die", 0, 0, 0 } },
    totals = { deaths = 2, instances = 0 },
}
ns.Tidy.Runs(char)
ns.Tidy.Events(char, function(mapID) return mapID ~= 1415 end)
assert(#char.events == 1 and char.totals.deaths == 1)

local guilded = { guild = false, events = { { 1, "gj", 0, 0, 0, "G", "M", 1 }, { 2, "gr", 0, 0, 0, "G", "M", 1 } } }
ns.Tidy.Guilds(guilded)
assert(#guilded.events == 1)

print("Pure tests passed.")
