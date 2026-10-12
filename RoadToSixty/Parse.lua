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
    -- An empty file is refused like a cut-short one: the app may read it
    -- while the game is rewriting it.
    if next(vars) == nil then Fail(s, pos, "no saved variables") end
    return vars
end

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
