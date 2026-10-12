-- Offline test of Parse.lua: it reads the format the game writes saved data
-- in (#36), refuses anything that isn't data, and writes data so it reads
-- back the same. Run with LuaJIT from the repo root: luajit tests/parse_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local ns = {}
assert(loadfile("RoadToSixty/Parse.lua"))("RoadToSixty", ns)
local Parse = ns.Parse

local function DeepEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not DeepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- True, with the error, when fn(text) errors.
local function Refused(fn, text)
    local ok, err = pcall(fn, text)
    return not ok, tostring(err)
end

-- 1. The made-up save from #36 reads as the data it holds, with CRLF line
-- endings as the game writes them and with LF. Git may check the fixture
-- out with either, so it is brought to LF first.
local f = assert(io.open("tests/fixtures/save_format.txt", "rb"))
local lf = f:read("*a"):gsub("\r\n", "\n")
f:close()
check(lf:sub(1, 1) == "\n", "the fixture starts with an empty line, as the game's files do")
check(lf:find("\t", 1, true) ~= nil, "the fixture still holds a raw tab")
local crlf = lf:gsub("\n", "\r\n")

local char = Parse.File(crlf).RoadToSixtyCharDB
check(DeepEqual(Parse.File(lf).RoadToSixtyCharDB, char), "LF and CRLF files read the same")
check(char.version == 2 and char.addon == "1.9.0", "string keys")
local seg = char.segments[1]
check(seg.m == "w" and seg.x == -8913 and seg.d == "5,12,-3;6,10,-4", "a path segment")
local e = char.events[1]
check(e[1] == 1791712544 and e[2] == "grp" and e[3] == -1 and e[4] == -8913.25, "whole and decimal numbers")
check(e[5] == 0.3333333333333333, "a 16-digit decimal reads exactly")
check(e[7][1] == "Player-0000-00000000", "a table inside an array")
check(e[8] == nil and e[9] == true, "nil keeps its place in an array")
check(char.people["Player-0000-00000000"][2] == "Zoë \"the Brave\" \\ o/", "escaped quotes and backslashes, raw UTF-8")
check(char.levels[1] == 2 and char.levels[2] == 3 and char.levels[60] == 1791777464, "a number key after the array part")
local odd = char.odd
check(odd.inf == nil and odd.nan == nil and odd.fn == nil, "values the game couldn't save read as nil")
check(odd.small == 1e-05 and odd.huge == 9.223372036854776e+18, "exponents")
check(odd.negzero == 0 and 1 / odd.negzero < 0, "negative zero")
check(odd.text == "one\ntwo\r\0end", "\\n, \\r and \\000")
check(odd.tab == "a\tb", "a raw tab")
check(odd.colour == "|cffff0000red|r", "colour codes")
check(odd['a"b'] == false and odd[true] == "boolean key", "an escaped string key and a boolean key")
check(odd[1.5] == "float key" and odd[-1] == "negative key", "decimal and negative keys")
check(type(odd.empty) == "table" and next(odd.empty) == nil, "an empty table over two lines")

-- 2. Raw bytes, including ones that aren't valid UTF-8, read back as written.
local raw = "\1\9\31\127\128\192\255]] [["
check(Parse.Read('"' .. raw .. '"') == raw, "raw bytes read back byte for byte")
check(Parse.Read('"\\0001"') == "\0" .. "1", "\\000 takes three digits and the next digit is text")

-- 3. A file cut short anywhere before its last } is refused, so a file read
-- while the game is still writing it never reads as a shorter journey.
local first, last = crlf:find("%S"), crlf:find("}%s*$")
local cut = 0
for n = first, last - 1 do
    if pcall(Parse.File, crlf:sub(1, n)) then cut = cut + 1 end
end
check(cut == 0, cut .. " cut-short copies of the fixture were read")

-- 4. Anything but data is refused.
local notData = {
    "{ os.exit() }",
    "{ [1] = f() }",
    '{ "a" .. "b" }',
    "{ a = 1 }",
    "{ [{}] = 1 }",
    "{ [nil] = 1 }",
    "{ 0x10 }",
    "{ inf }",
    "{ nan }",
    "{ 1e999 }",
    "{ [[long]] }",
    "{ 1; 2 }",
    '{ "\\q" }',
    '{ "\\256" }',
    '{ "line\nbreak" }',
    "{ 1, --[[ never closed",
    "{ 1 } -- a line comment",
    "{ 1 } { 2 }",
    "\27LuaQ\0\1\4\8\4\8\0",
    "",
}
for _, text in ipairs(notData) do
    check(Refused(Parse.Read, text), "read as data: " .. text:gsub("%c", "?"))
end
for _, text in ipairs({ "x = f()", 'RoadToSixtyCharDB = loadstring("return 1")()', "RoadToSixtyCharDB", "os.exit()", "\27LuaQ\0" }) do
    check(Refused(Parse.File, text), "read as a file: " .. text:gsub("%c", "?"))
end
local refused, err = Refused(Parse.Read, ("{"):rep(100))
check(refused and err:find("deep"), "deep nesting is refused: " .. err)
local deepest = ("{"):rep(Parse.MAX_DEPTH) .. ("}"):rep(Parse.MAX_DEPTH)
check(pcall(Parse.Read, deepest), "nesting MAX_DEPTH deep reads")
check(Refused(Parse.Read, "{" .. deepest .. "}"), "one deeper is refused")
refused, err = Refused(Parse.Read, "{\n1,\n?}")
check(refused and err:find("^line 3 "), "an error names its line: " .. err)

-- 5. Numbers write in a short exact form and read back exactly.
local NEGATIVE_ZERO = -1 / math.huge
check(Parse.Write(1791712544) == "1791712544", "whole numbers write without a decimal point")
check(Parse.Write(-8913.25) == "-8913.25" and Parse.Write(0.1) == "0.1", "decimals write short")
check(Parse.Write(NEGATIVE_ZERO) == "-0", "negative zero keeps its sign")
for _, x in ipairs({ 0, 1, -7, 2^31, 2^53, 2^63, 1 / 3, 0.1372549086809158, 1e-05, 1e-300, 1e300, 5e-324, 1.7976931348623157e308 }) do
    check(Parse.Read(Parse.Write(x)) == x, "a number reads back exactly: " .. Parse.Write(x))
end

-- 6. Keys of every kind write in one order, whatever order they were added in.
local mixed = { 1, 2, [10] = 3, a = 1, [true] = 1, [false] = 2, [1.5] = 1, [-1] = 1 }
check(Parse.Write(mixed) == '{1,2,[-1]=1,[1.5]=1,[10]=3,["a"]=1,[false]=2,[true]=1,}', "mixed keys: " .. Parse.Write(mixed))
local forwards, backwards = {}, {}
for i = 1, 26 do forwards[string.char(96 + i)] = i end
for i = 26, 1, -1 do backwards[string.char(96 + i)] = i end
check(Parse.Write(forwards) == Parse.Write(backwards), "the order keys were added in doesn't change the text")
check(Parse.Write({ 1, nil, 3 }) == "{1,[3]=3,}", "a gap ends the array part")

-- 7. Strings escape only what the game escapes, and every byte reads back.
local bytes = {}
for b = 0, 255 do bytes[#bytes + 1] = string.char(b) end
local all = table.concat(bytes)
check(Parse.Read(Parse.Write(all)) == all, "all 256 bytes read back")
check(Parse.Write('a"b\\c\nd\re\0f\tg') == '"a\\"b\\\\c\\nd\\re\\000f\tg"', "escapes: " .. Parse.Write('a"b\\c\nd\re\0f\tg'))

-- 8. The fixture and a full-size made-up journey survive a write and a read.
local text = Parse.Write(char)
check(DeepEqual(Parse.Read(text), char), "the fixture's journey reads back the same")
check(Parse.Write(Parse.Read(text)) == text, "writing what was read gives the same text")

math.randomseed(7)
local function FullSize()
    local journey = { version = 2, addon = "1.9.0", segments = {}, events = {}, levels = {} }
    local steps = {}
    for i = 1, 30000 do
        steps[i] = ("%d,%d,%d"):format(math.random(1, 9), math.random(-40, 40), math.random(-40, 40))
    end
    for i = 1, 300 do
        local from = (i - 1) % 100 * 300 + 1
        journey.segments[i] = { m = "w", c = i % 2, t = 1791712544 + i * 600, x = math.random(-9000, 9000) + 0.25,
            y = math.random(-9000, 9000), d = table.concat(steps, ";", from, from + 299) }
    end
    for i = 1, 30000 do
        journey.events[i] = { 1791712544 + i * 7, "qd", math.random() * 10000, math.random() * 10000, 0,
            math.random(1, 9000), "Quest " .. i }
    end
    for level = 2, 60 do
        journey.levels[level] = { t = 1791712544 + level * 9000, played = level * 3600, money = level * 1000,
            gear = { [1] = "item:" .. level, [5] = "item:" .. level * 2 } }
    end
    local kills, names = {}, {}
    for i = 1, 20000 do
        kills[i] = ("%d,%d,%d;"):format(math.random(1, 60), math.random(1, 500), math.random(1, 300))
    end
    for i = 1, 300 do names[i] = "Mob " .. i end
    journey.kills = { d = table.concat(kills), last = 1791712544 + 999999, names = names }
    return journey
end
local big = FullSize()
local started = os.clock()
local bigText = Parse.Write(big)
local wrote = os.clock()
local back = Parse.Read(bigText)
local read = os.clock()
check(#bigText > 1000000, "the made-up journey is full size: " .. #bigText .. " bytes")
check(DeepEqual(back, big), "a full-size journey reads back the same")
print(("Full-size journey: %d bytes, written in %d ms, read in %d ms."):format(
    #bigText, math.floor((wrote - started) * 1000), math.floor((read - wrote) * 1000)))

-- 9. Write refuses what Read couldn't read back.
local holdsItself = {}
holdsItself.self = holdsItself
local unwritable = {
    ["a function"] = print,
    inf = math.huge,
    nan = 0 / 0,
    ["a table key"] = { [{}] = 1 },
    ["a table holding itself"] = holdsItself,
}
for what, value in pairs(unwritable) do
    check(Refused(Parse.Write, value), "wrote " .. what)
end
local nest = {}
for _ = 2, Parse.MAX_DEPTH do nest = { nest } end
check(pcall(Parse.Write, nest), "nesting MAX_DEPTH deep writes")
check(Refused(Parse.Write, { nest }), "one deeper is refused")

if failures == 0 then
    print("Parse tests passed.")
else
    print(failures .. " parse test(s) failed.")
    os.exit(1)
end
