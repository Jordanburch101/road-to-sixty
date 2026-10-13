-- Matching chat and system messages against the client's own format strings
-- (COMBATLOG_XPGAIN_FIRSTPERSON, LOOT_ITEM_SELF, ...), so it works in every
-- client language. Some languages number their arguments ("%1$s stirbt,
-- Ihr bekommt %2$d Erfahrung." in German) and may put them in another order
-- than English, or leave one out; ns.ChatMatcher handles all of these and
-- always returns the captures in argument order.
local _, ns = ...

local MAGIC = "([%(%)%.%+%-%*%?%[%]%^%$])"

-- What each conversion captures; anything else (%s and the rare ones) as text.
local CAPTURES = {
    d = "(%d+)", i = "(%d+)", u = "(%d+)",
    f = "(%-?[%d%.]+)", g = "(%-?[%d%.]+)",
}

-- Returns a function taking a message and returning its captures (each %d
-- as a string of digits, each %s as text) in argument order, or nil if the
-- message does not match. An argument the format leaves out comes back nil;
-- one it uses twice comes from its first place. A format with no arguments
-- gives true on a match. With whole, the message must match to its end. A
-- missing format gives a matcher that never matches.
function ns.ChatMatcher(format, whole)
    if type(format) ~= "string" then
        return function() end
    end
    -- Scanned left to right, so "%%" stays a literal percent sign.
    local parts, order, count, at = {}, {}, 0, 1
    while true do
        local from = format:find("%", at, true)
        if not from then break end
        parts[#parts + 1] = (format:sub(at, from - 1):gsub(MAGIC, "%%%1"))
        local position, dollar, kind, to = format:match("^(%d*)(%$?)[-+ #%d%.]*(%a)()", from + 1)
        if format:sub(from + 1, from + 1) == "%" or not kind then
            parts[#parts + 1] = "%%"
            at = format:sub(from + 1, from + 1) == "%" and from + 2 or from + 1
        else
            parts[#parts + 1] = CAPTURES[kind] or "(.+)"
            -- Without a "$" the digits are a width, not a position.
            order[#order + 1] = dollar ~= "" and tonumber(position) or #order + 1
            count = math.max(count, order[#order])
            at = to
        end
    end
    parts[#parts + 1] = (format:sub(at):gsub(MAGIC, "%%%1"))
    local pattern = "^" .. table.concat(parts) .. (whole and "$" or "")

    if #order == 0 then
        return function(msg)
            if msg:match(pattern) then return true end
        end
    end
    return function(msg)
        local captures = { msg:match(pattern) }
        if captures[1] == nil then return nil end
        local args = {}
        for i = #order, 1, -1 do
            args[order[i]] = captures[i]
        end
        return unpack(args, 1, count)
    end
end
