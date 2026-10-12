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
