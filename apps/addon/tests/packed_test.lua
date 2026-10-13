-- Offline test of Packed.lua, the packed kill and path formats. Run with
-- LuaJIT from the repo root: luajit tests/packed_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Packed.lua"))("RoadToSixty", ns)
local Packed = ns.Packed

local function Times(list)
    local out = {}
    for i, k in ipairs(list) do out[i] = k.t .. ":" .. k.xp .. ":" .. tostring(k.name) end
    return table.concat(out, " ")
end

-- 1. Packing then decoding gives the same kills back, names shared.
local kills = {
    { t = 1000, xp = 40, name = "Kobold" },
    { t = 1012, xp = 40, name = "Kobold" },
    { t = 1012, xp = 55, name = "Hogger" },
}
local packed = Packed.PackKills(kills)
check(packed.d == "1000,40,1;12,40,1;0,55,2;", "packed string: " .. packed.d)
check(packed.last == 1012, "last is the time of the last kill, got " .. packed.last)
check(#packed.names == 2 and packed.names[1] == "Kobold" and packed.names[2] == "Hogger", "names listed once each")
local decoded = {}
local last = Packed.DecodeKills(packed.d, packed.names, 0, decoded)
check(Times(decoded) == "1000:40:Kobold 1012:40:Kobold 1012:55:Hogger", "decoded: " .. Times(decoded))
check(last == 1012, "DecodeKills returns the last time, got " .. last)

-- 2. Times that go backwards (the switch to the realm's clock) survive.
packed = Packed.PackKills({ { t = 2000, xp = 1, name = "A" }, { t = 1995, xp = 2, name = "A" } })
check(packed.d == "2000,1,1;-5,2,1;", "negative gap packed: " .. packed.d)
decoded = {}
Packed.DecodeKills(packed.d, packed.names, 0, decoded)
check(Times(decoded) == "2000:1:A 1995:2:A", "negative gap decoded: " .. Times(decoded))

-- 3. Decoding continues from a given time and appends to the list.
decoded = { { t = 1, xp = 0, name = "x" } }
last = Packed.DecodeKills("5,10,1;", { "Wolf" }, 100, decoded)
check(#decoded == 2 and decoded[2].t == 105 and decoded[2].name == "Wolf" and last == 105, "appends after t")
check(Packed.DecodeKills("", {}, 77, {}) == 77, "nothing to decode keeps t")

-- 4. A kill whose name was lost packs as "?".
packed = Packed.PackKills({ { t = 10, xp = 3, name = nil } })
check(packed.d == "10,3,1;" and packed.names[1] == "?", "a nameless kill packs as ?")

-- 5. No kills packs to the defaults a new character starts with.
packed = Packed.PackKills({})
check(packed.d == "" and packed.last == 0 and #packed.names == 0, "empty list packs to the defaults")

-- 6. A path segment decodes to its points, including negative steps.
local ts, xs, ys = Packed.DecodePath({ t = 100, x = 10, y = 20, d = "1,5,-5;2,-15,0" })
check(table.concat(ts, ",") == "100,101,103", "path times: " .. table.concat(ts, ","))
check(table.concat(xs, ",") == "10,15,0", "path x: " .. table.concat(xs, ","))
check(table.concat(ys, ",") == "20,15,15", "path y: " .. table.concat(ys, ","))
ts = Packed.DecodePath({ t = 5, x = 0, y = 0, d = "" })
check(#ts == 1, "a segment with only its start point")
ts = Packed.DecodePath({ t = 5, x = 0, y = 0, d = "" }, "3,1,1")
check(#ts == 2 and ts[2] == 8, "steps passed in place of seg.d")

if failures == 0 then
    print("Packed tests passed.")
else
    print(failures .. " packed test(s) failed.")
    os.exit(1)
end
