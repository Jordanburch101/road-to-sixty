# Parse.lua Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `RoadToSixty/Parse.lua` reads saved data in the exact format the game writes SavedVariables in, refuses anything that isn't data, and writes data back as text that reads back the same.

**Architecture:** One pure Lua 5.1 file with no game calls, shared by the addon (step 3, reading the sync folder) and the sync server (`lua5.1` subprocess, step 4). Reading walks the text with a position and `string.find` anchored at that position. It never builds a token list or copies the rest of the text, so a 3 MB file reads in one pass. Writing sorts keys so equal data always gives equal text, since the server names stored versions by a fingerprint of their content.

**Tech Stack:** Lua 5.1 (WoW, PUC `lua5.1` on the server), LuaJIT for the offline tests.

**Spec:** `docs/superpowers/specs/2026-10-12-sync-and-backup-design.md`. The format facts come from the PC report on issue #36.

## Global Constraints

- Plain Lua 5.1 with no game calls, and the same behaviour in WoW, standard Lua 5.1 and LuaJIT (spec, "Rules for writing").
- Never depend on the order `pairs` returns. Sort keys wherever order matters.
- Never use `#` on tables with holes.
- Standard Lua 5.1 only: no WoW globals (`wipe`, `strsplit`, `tinsert`, `CopyTable`) and no LuaJIT extras.
- Parse accepts data only (tables, strings, numbers, booleans) and refuses anything that looks like code (spec, "New files").
- Tests: writing a journey out and reading it back gives identical data. Code, compiled bytecode and deep nesting are refused (spec, "Testing").
- Comments are plain sentences that explain why. British spelling. Commit subjects `Area: what changed (#1)`.
- No `pcall` inside `Parse.lua`. Step 3 may parse inside a coroutine to spread the work over frames, and Lua 5.1 cannot yield across a `pcall`. Callers `pcall` it.

## The format (from #36)

- One `Name = value` per file. The file starts with an empty line. Lines end in CRLF. Nothing is indented.
- String keys are `["key"] = `. Other keys are `[n] = `, `[1.5] = `, `[true] = `. The array part is bare values. A gap in it is `nil,`. Every entry ends with `,`.
- Numbers: `42`, `-7`, `-8913.25`, `0.3333333333333333`, `1e-05`, `9.223372036854776e+18`, `-0`. No hex, no `inf` or `nan`.
- Strings use double quotes. The game escapes only `\"`, `\\`, `\n`, `\r` and `\000` (three decimal digits). Every other byte is written raw, including tabs, control bytes and bytes that aren't valid UTF-8.
- A value the game can't save is written as `nil --[[ inf ]]`, `nil --[[ nan ]]` or `nil --[[ skipped inline function ]]`.
- An empty table is `{` with `}` on the next line.

What Read accepts follows that and nothing more: values `{`, `"..."`, numbers, `true`, `false`, `nil`; keys `["..."]`, `[number]`, `[true]`, `[false]`, or bare array values; `--[[ ]]` comments between tokens; `,` as the only separator, with the last one optional; the five escapes above, with `\ddd` up to 255. Anything else is an error that names the line and byte.

## Review Focus

1. A file read while the game is still writing it, or an upload cut short: it must be refused, never read as a shorter journey. Task 1, test 3 tries every cut-short copy of the fixture.
2. Bytes that aren't valid UTF-8 and control bytes inside strings must come back byte for byte. Tasks 1 and 2 test all 256 byte values.
3. A full-size journey (3 MB, 30,000 events, long path strings) must read and write in one pass without slowing to a crawl. Task 2, test 8 times one and prints it.
4. Text that isn't data must be refused, not run: code, compiled bytecode, deep nesting, and on the writing side tables that hold themselves. Task 1, test 4 and Task 2, test 9.
5. Standard Lua 5.1, which the server runs, must give the same results as LuaJIT: `%z` in patterns, `tonumber` on exponents, `%.17g`, and string `<` (which follows the C locale in PUC Lua). Task 3 builds PUC Lua 5.1 and runs the tests under it.

## Files

- Create `RoadToSixty/Parse.lua`: `ns.Parse` with `Read`, `File`, `Write` and `MAX_DEPTH`.
- Create `tests/fixtures/save_format.txt`: the made-up save from #36. It is `.txt` so the syntax check and LuaLS leave it alone.
- Create `tests/parse_test.lua`.
- Modify `RoadToSixty/RoadToSixty.toc` (after `Tidy.lua`), `tests/pure_test.lua`, `CLAUDE.md` (layout table).

---

### Task 1: Read saved data

**Files:**
- Create: `RoadToSixty/Parse.lua`
- Create: `tests/fixtures/save_format.txt`
- Test: `tests/parse_test.lua`

**Interfaces:**
- Produces:
  - `ns.Parse.Read(text) -> value`: text holding one value. Errors (message `line N (byte M): what`) on anything that isn't data.
  - `ns.Parse.File(text) -> { [name] = value }`: a whole SavedVariables file. Errors the same way.
  - `ns.Parse.MAX_DEPTH = 32`: the deepest table nesting accepted.

- [ ] **Step 1: Cut the branch**

```bash
git switch dev && git switch -c sync-parse && git branch --unset-upstream 2>/dev/null; git status -sb | head -1
```
Expected: `## sync-parse`.

- [ ] **Step 2: Add the fixture**

Write `tests/fixtures/save_format.txt` with exactly this content. It starts with an empty line. `<TAB>` stands for a real tab, put in by the command after it.

```
 
RoadToSixtyCharDB = {
["version"] = 2,
["addon"] = "1.9.0",
["segments"] = {
{
["m"] = "w",
["c"] = 0,
["t"] = 1791712544,
["x"] = -8913,
["y"] = 856,
["d"] = "5,12,-3;6,10,-4",
},
},
["events"] = {
{
1791712544,
"grp",
-1,
-8913.25,
0.3333333333333333,
"party",
{
"Player-0000-00000000",
},
nil,
true,
},
},
["people"] = {
["Player-0000-00000000"] = {
"Fakename",
"Zoë \"the Brave\" \\ o/",
},
},
["levels"] = {
2,
3,
[60] = 1791777464,
},
["odd"] = {
["inf"] = nil --[[ inf ]],
["nan"] = nil --[[ nan ]],
["fn"] = nil --[[ skipped inline function ]],
["small"] = 1e-05,
["huge"] = 9.223372036854776e+18,
["negzero"] = -0,
["text"] = "one\ntwo\r\000end",
["tab"] = "a<TAB>b",
["colour"] = "|cffff0000red|r",
["a\"b"] = false,
[true] = "boolean key",
[1.5] = "float key",
[-1] = "negative key",
["empty"] = {
},
},
}
```

The first line must be truly empty (the space above is only so the code block shows it). Then:

```bash
perl -pi -e 's/<TAB>/\t/; s/^ $//' tests/fixtures/save_format.txt && head -c 1 tests/fixtures/save_format.txt | od -c | head -1 && grep -c "	" tests/fixtures/save_format.txt
```
Expected: `0000000  \n` and `1`.

- [ ] **Step 3: Write the failing test**

Create `tests/parse_test.lua`:

```lua
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

if failures == 0 then
    print("Parse tests passed.")
else
    print(failures .. " parse test(s) failed.")
    os.exit(1)
end
```

- [ ] **Step 4: Run it to see it fail**

Run: `luajit tests/parse_test.lua`
Expected: an error that `RoadToSixty/Parse.lua` can't be opened.

- [ ] **Step 5: Write the reader**

Create `RoadToSixty/Parse.lua`. Two rules in this code matter for big files and must survive later edits: always `find(s, "^...", pos)` from the current position, never `s:sub(pos)` to move on (that copies the rest of a 3 MB file per token), and every loop either moves `pos` forward or errors.

```lua
local _, ns = ...

-- Reads and writes saved data in the format the game writes SavedVariables
-- in, with no game calls, so the addon and the sync server share it.
-- Reading accepts data only: tables, strings, numbers, true, false and nil.
-- Anything else, code included, is an error, so text from outside never runs.
--
-- The format, as Forever writes it (#36): CRLF lines, no indenting, string
-- keys as ["key"] = , other keys as [1.5] = or [true] = , the array part as
-- bare values with nil, for a gap, and a comma after every entry. Strings
-- use double quotes and escape only \" \\ \n \r and \000. Every other byte
-- is written raw, including bytes that aren't valid UTF-8. A value the game
-- can't save (inf, nan, a function) is written as nil --[[ inf ]].
--
-- Write gives the same format on one line with the keys sorted, so equal
-- data always gives equal text.
--
-- Both error on bad input instead of returning nil; callers pcall them.

local Parse = {}
ns.Parse = Parse

-- The deepest table nesting read or written. Real files reach 8 (the
-- roster's journey copies in the account file).
Parse.MAX_DEPTH = 32

local find, sub, format = string.find, string.sub, string.format

local ESCAPES = { n = "\n", r = "\r", ['"'] = '"', ["\\"] = "\\" }

local function Fail(s, pos, what)
    local line = 1
    for _ in sub(s, 1, pos - 1):gmatch("\n") do line = line + 1 end
    error(format("line %d (byte %d): %s", line, pos, what), 0)
end

-- The position of the next token, past spaces, line breaks and --[[ ]]
-- comments.
local function Skip(s, pos)
    while true do
        local _, e = find(s, "^%s*", pos)
        pos = e + 1
        if sub(s, pos, pos + 3) ~= "--[[" then return pos end
        local _, close = find(s, "]]", pos + 4, true)
        if not close then Fail(s, pos, "a comment that never ends") end
        pos = close + 1
    end
end

-- pos is at the opening quote.
local function ReadString(s, pos)
    local _, e, plain = find(s, '^"([^"\\\r\n]*)"', pos)
    if e then return plain, e + 1 end
    local parts, i = {}, pos + 1
    while true do
        local stop = find(s, '["\\\r\n]', i)
        if not stop then Fail(s, pos, "a string that never ends") end
        parts[#parts + 1] = sub(s, i, stop - 1)
        local c = sub(s, stop, stop)
        if c == '"' then return table.concat(parts), stop + 1 end
        if c ~= "\\" then Fail(s, stop, "a line break inside a string") end
        local escaped = ESCAPES[sub(s, stop + 1, stop + 1)]
        if escaped then
            parts[#parts + 1] = escaped
            i = stop + 2
        else
            local _, last, digits = find(s, "^(%d%d?%d?)", stop + 1)
            if not digits or tonumber(digits) > 255 then Fail(s, stop, "an unknown escape") end
            parts[#parts + 1] = string.char(tonumber(digits))
            i = last + 1
        end
    end
end

local function ReadNumber(s, pos)
    local _, e = find(s, "^-?%d+%.?%d*", pos)
    if not e then Fail(s, pos, "expected a value") end
    local _, exponent = find(s, "^[eE][-+]?%d+", e + 1)
    e = exponent or e
    local n = tonumber(sub(s, pos, e))
    if not n or n ~= n or n == math.huge or n == -math.huge then Fail(s, pos, "not a finite number") end
    return n, e + 1
end

local ReadTable

-- Returns the value at pos and the position after it.
local function ReadValue(s, pos, depth)
    local c = sub(s, pos, pos)
    if c == "{" then return ReadTable(s, pos + 1, depth + 1) end
    if c == '"' then return ReadString(s, pos) end
    if sub(s, pos, pos + 3) == "true" then return true, pos + 4 end
    if sub(s, pos, pos + 4) == "false" then return false, pos + 5 end
    if sub(s, pos, pos + 2) == "nil" then return nil, pos + 3 end
    return ReadNumber(s, pos)
end

-- pos is just after the {.
function ReadTable(s, pos, depth)
    if depth > Parse.MAX_DEPTH then Fail(s, pos, "tables nested too deep") end
    local t, n = {}, 0
    while true do
        pos = Skip(s, pos)
        local c = sub(s, pos, pos)
        if c == "}" then return t, pos + 1 end
        if c == "" then Fail(s, pos, "a table that never ends") end
        if c == "[" then
            local key
            key, pos = ReadValue(s, Skip(s, pos + 1), depth)
            if key == nil or type(key) == "table" then Fail(s, pos, "a key that isn't a string, number or boolean") end
            pos = Skip(s, pos)
            if sub(s, pos, pos) ~= "]" then Fail(s, pos, "expected ]") end
            pos = Skip(s, pos + 1)
            if sub(s, pos, pos) ~= "=" then Fail(s, pos, "expected =") end
            t[key], pos = ReadValue(s, Skip(s, pos + 1), depth)
        else
            n = n + 1
            t[n], pos = ReadValue(s, pos, depth)
        end
        pos = Skip(s, pos)
        c = sub(s, pos, pos)
        if c == "," then
            pos = pos + 1
        elseif c ~= "}" then
            Fail(s, pos, "expected , or }")
        end
    end
end

-- Reads text holding one value, such as a journey from the sync folder.
function Parse.Read(s)
    local value, pos = ReadValue(s, Skip(s, 1), 0)
    pos = Skip(s, pos)
    if pos <= #s then Fail(s, pos, "more text after the value") end
    return value
end

-- Reads a whole SavedVariables file: each Name = value in it, as
-- { [Name] = value }.
function Parse.File(s)
    local vars, pos = {}, Skip(s, 1)
    while pos <= #s do
        local _, e, name = find(s, "^([%a_][%w_]*)%s*=", pos)
        if not name then Fail(s, pos, "expected a saved variable name") end
        vars[name], pos = ReadValue(s, Skip(s, e + 1), 0)
        pos = Skip(s, pos)
    end
    return vars
end
```

- [ ] **Step 6: Run the test**

Run: `luajit tests/parse_test.lua`
Expected: `Parse tests passed.`

- [ ] **Step 7: Run every test**

Run: `for t in tests/*_test.lua; do luajit "$t" || echo "FAILED: $t"; done 2>&1 | grep -v "passed" ; echo done`
Expected: only `done`, plus the timing line if any test prints one.

- [ ] **Step 8: Commit**

```bash
git add RoadToSixty/Parse.lua tests/parse_test.lua tests/fixtures/save_format.txt
git commit -m "Parse: read saved data in the game's format, refusing anything else (#1)

Reads the format #36 measured on the beta: CRLF, no indenting, bare
array values with nil for gaps, nil --[[ inf ]] for values the game
couldn't save, and raw bytes in strings. Code, bytecode, cut-short
files and nesting deeper than 32 are errors.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Write saved data

**Files:**
- Modify: `RoadToSixty/Parse.lua` (append the writer)
- Test: `tests/parse_test.lua` (insert before the summary at the end)

**Interfaces:**
- Consumes: `ns.Parse.Read`, `ns.Parse.MAX_DEPTH` from Task 1.
- Produces: `ns.Parse.Write(value) -> string`. One line, keys sorted. Errors on functions, inf, nan, keys that are tables, and nesting deeper than `MAX_DEPTH` (which also catches a table that holds itself).

- [ ] **Step 1: Write the failing tests**

Insert into `tests/parse_test.lua`, just before `if failures == 0 then`:

```lua
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `luajit tests/parse_test.lua`
Expected: an error that `Write` is nil (`attempt to call field 'Write'`).

- [ ] **Step 3: Write the writer**

Append to `RoadToSixty/Parse.lua`:

```lua
local ESCAPED = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\0"] = "\\000" }

-- Mixed key types are sorted by type first, since < between a number and a
-- string errors.
local KEY_ORDER = { number = 1, string = 2, boolean = 3 }

local function KeyBefore(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return KEY_ORDER[ta] < KEY_ORDER[tb] end
    if ta == "boolean" then return not a and b end
    return a < b
end

local WriteValue

local function WriteNumber(x, out)
    if x ~= x or x == math.huge or x == -math.huge then error("can't write " .. tostring(x), 0) end
    -- The short form when it reads back exactly, else all 17 digits.
    local text = format("%.14g", x)
    if tonumber(text) ~= x then text = format("%.17g", x) end
    out[#out + 1] = text
end

local function WriteTable(t, out, depth)
    if depth >= Parse.MAX_DEPTH then error("tables nested too deep", 0) end
    out[#out + 1] = "{"
    local n = 0
    while t[n + 1] ~= nil do
        n = n + 1
        WriteValue(t[n], out, depth + 1)
        out[#out + 1] = ","
    end
    local keys = {}
    for k in pairs(t) do
        if not KEY_ORDER[type(k)] then error("can't write a " .. type(k) .. " key", 0) end
        if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, KeyBefore)
    for _, k in ipairs(keys) do
        out[#out + 1] = "["
        WriteValue(k, out, depth)
        out[#out + 1] = "]="
        WriteValue(t[k], out, depth + 1)
        out[#out + 1] = ","
    end
    out[#out + 1] = "}"
end

function WriteValue(v, out, depth)
    local kind = type(v)
    if kind == "string" then
        out[#out + 1] = '"' .. v:gsub('[%z\\"\n\r]', ESCAPED) .. '"'
    elseif kind == "number" then
        WriteNumber(v, out)
    elseif kind == "boolean" then
        out[#out + 1] = tostring(v)
    elseif kind == "table" then
        WriteTable(v, out, depth)
    else
        error("can't write a " .. kind, 0)
    end
end

-- The text for value, which Read reads back as the same data.
function Parse.Write(value)
    local out = {}
    WriteValue(value, out, 0)
    return table.concat(out)
end
```

- [ ] **Step 4: Run the test**

Run: `luajit tests/parse_test.lua`
Expected: a line `Full-size journey: <about 3,000,000> bytes, written in <N> ms, read in <N> ms.` then `Parse tests passed.`

- [ ] **Step 5: Run every test**

Run: `for t in tests/*_test.lua; do luajit "$t" || echo "FAILED: $t"; done 2>&1 | grep -v "passed" ; echo done`
Expected: the full-size journey line, then `done`.

- [ ] **Step 6: Commit**

```bash
git add RoadToSixty/Parse.lua tests/parse_test.lua
git commit -m "Parse: write saved data in a fixed order that reads back the same (#1)

Keys are sorted, so equal data always gives equal text: the server
names stored versions by a fingerprint of their content. Numbers use
the shortest form that reads back exactly. Strings escape only what
the game escapes.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Load it with the addon, keep it pure, check standard Lua 5.1

**Files:**
- Modify: `RoadToSixty/RoadToSixty.toc:13` (add `Parse.lua` after `Tidy.lua`)
- Modify: `tests/pure_test.lua`
- Modify: `CLAUDE.md:21-22` (layout table)

**Interfaces:**
- Consumes: `ns.Parse.Read`, `ns.Parse.Write` from Tasks 1 and 2.

- [ ] **Step 1: Make pure_test cover Parse.lua (failing)**

In `tests/pure_test.lua`, change the bytecode list:

```lua
for _, name in ipairs({ "Packed.lua", "Tidy.lua", "Parse.lua" }) do
```

and after `Load("Tidy.lua", ns)` add:

```lua
Load("Parse.lua", ns)
```

and before `print("Pure tests passed.")` add:

```lua
-- The environment has no loadstring, so this also shows Read never runs
-- what it reads.
assert(ns.Parse.Read(ns.Parse.Write({ 1, a = "b" })).a == "b")
```

Run: `luajit tests/pure_test.lua`
Expected: `Pure tests passed.` (it passes at once because Parse.lua already exists; to see the check bite, temporarily add `wipe({})` inside `Parse.Write`, run it, see `Parse.lua uses the global wipe`, and remove it again).

- [ ] **Step 2: Add Parse.lua to the toc**

In `RoadToSixty/RoadToSixty.toc`, after the line `Tidy.lua`, add the line `Parse.lua`.

Run: `luajit tests/release_load.lua RoadToSixty && luajit tests/clock_test.lua`
Expected: the load test reports one more file than before (45) and passes; `Clock tests passed.`

- [ ] **Step 3: Layout table**

In `CLAUDE.md`, change the Tidy row and add a Parse row after it:

```markdown
| Tidy.lua | the login repairs of saved journeys as plain functions (no game calls) |
| Parse.lua | reads and writes saved data in the game's format, refusing anything that isn't data (no game calls); `tests/pure_test.lua` keeps Packed, Tidy and Parse pure |
```

- [ ] **Step 4: Run the tests under standard Lua 5.1**

The server runs PUC Lua 5.1, which isn't on this Mac. Build it in the scratchpad (`$SCRATCH` is this session's scratchpad directory):

```bash
cd "$SCRATCH" && curl -sLO https://www.lua.org/ftp/lua-5.1.5.tar.gz && tar xzf lua-5.1.5.tar.gz && make -C lua-5.1.5 posix >/dev/null && lua-5.1.5/src/lua -v
```
Expected: `Lua 5.1.5  Copyright (C) 1994-2012 Lua.org, PUC-Rio`.

Then from the repo root:

```bash
"$SCRATCH/lua-5.1.5/src/lua" tests/parse_test.lua && "$SCRATCH/lua-5.1.5/src/lua" tests/pure_test.lua
```
Expected: the full-size journey line, `Parse tests passed.`, `Pure tests passed.` If a check fails only here, it is a difference between the runtimes that the server would hit: fix it in `Parse.lua`, never in the test.

- [ ] **Step 5: Run every test and commit**

Run: `for t in tests/*_test.lua; do luajit "$t" || echo "FAILED: $t"; done 2>&1 | grep -v "passed" ; echo done`
Expected: the full-size journey line, then `done`.

```bash
git add RoadToSixty/RoadToSixty.toc tests/pure_test.lua CLAUDE.md
git commit -m "Parse: load it with the addon and keep it free of game calls (#1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Notes for later steps

- Step 3 or 5 has to put a journey's text inside `data.lua` as a Lua string. #36 shows `]] [[` and raw bytes over 127 can occur in it, so a `[[ ]]` long string needs a level of `=` signs that doesn't occur in the text, or the text must be escaped. That belongs to whoever writes `data.lua`, not to Parse.
- Times being whole numbers is a check for Merge or Tidy, not Parse: real files hold decimals (`-8913.25`, colour values).
- Parse reads values the game couldn't save as nil, so a journey that once held inf or nan loses that field. Forever errors on `0 / 0`, so this shouldn't come up.
- CI running the tests under both LuaJIT and standard Lua 5.1 comes with the workspace in step 4. Until then, Task 3's manual run is the only standard Lua 5.1 check.
