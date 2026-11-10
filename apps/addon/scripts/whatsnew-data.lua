-- Writes WhatsNewData.lua, the notes the in-game changelog shows
-- (WhatsNew.lua, #132), from CHANGELOG.md: the newest versions' sections,
-- as players read them. The release build runs it (scripts/package.ps1);
-- run it by hand to try the window in a dev install.
--
--   luajit scripts/whatsnew-data.lua <CHANGELOG.md> <WhatsNewData.lua> [version]
--
-- With a release version (X.Y.Z), sections for later versions are left out,
-- and that version must have one of its own.
-- Loaded with dofile (the tests) it writes nothing and returns its functions.

local M = {}

M.COUNT = 12        -- versions kept: the window shows at most 8, the rest is slack

-- A note as players read it: Markdown's code and bold marks dropped, and
-- the lines of one bullet joined.
local function Plain(text)
    text = text:gsub("`", ""):gsub("%*%*", "")
    return (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- The changelog's versions, newest first: { version, sections = { { title,
-- { note, ... } }, ... } }. Only "## X.Y.Z" headings start a version; text
-- before the first one is the file's own introduction.
function M.Parse(text)
    local versions, version, section, note = {}, nil, nil, nil
    local function Close()
        if note and section then section[2][#section[2] + 1] = Plain(note) end
        note = nil
    end
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local number = line:match("^##%s+(%d+%.%d+%.%d+)%s*$")
        local title = line:match("^###%s+(.-)%s*$")
        if number then
            Close()
            version, section = { version = number, sections = {} }, nil
            versions[#versions + 1] = version
        elseif line:match("^##%s") then
            -- Any other heading at that level ends the version.
            Close()
            version, section = nil, nil
        elseif version and title then
            Close()
            section = { title, {} }
            version.sections[#version.sections + 1] = section
        elseif section and line:match("^%-%s") then
            Close()
            note = line:gsub("^%-%s+", "")
        elseif note and line:match("^%s+%S") then
            note = note .. " " .. line
        else
            Close()
        end
    end
    Close()
    return versions
end

-- Whether version a (X.Y.Z) is newer than b.
function M.Newer(a, b)
    local a1, a2, a3 = a:match("^(%d+)%.(%d+)%.(%d+)$")
    local b1, b2, b3 = b:match("^(%d+)%.(%d+)%.(%d+)$")
    a1, a2, a3, b1, b2, b3 = tonumber(a1), tonumber(a2), tonumber(a3), tonumber(b1), tonumber(b2), tonumber(b3)
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end

-- The Lua file for the newest count versions.
function M.Lua(versions, count)
    local out = {
        "local _, ns = ...",
        "",
        "-- Generated from CHANGELOG.md by scripts/whatsnew-data.lua for the",
        "-- in-game changelog (WhatsNew.lua). Not committed, not edited by hand.",
        "ns.WhatsNewData = {",
    }
    for i = 1, math.min(count or M.COUNT, #versions) do
        local v = versions[i]
        out[#out + 1] = ("    { version = %q, sections = {"):format(v.version)
        for _, section in ipairs(v.sections) do
            out[#out + 1] = ("        { %q, {"):format(section[1])
            for _, note in ipairs(section[2]) do
                out[#out + 1] = ("            %q,"):format(note)
            end
            out[#out + 1] = "        } },"
        end
        out[#out + 1] = "    } },"
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n") .. "\n"
end

local args = { ... }
if args[1] then
    local file = assert(io.open(args[1], "rb"))
    local versions = M.Parse(file:read("*a"))
    file:close()
    local want = args[3] and args[3]:match("^v?(%d+%.%d+%.%d+)$")
    if want then
        while versions[1] and M.Newer(versions[1].version, want) do table.remove(versions, 1) end
        if not versions[1] or versions[1].version ~= want then
            io.stderr:write(("CHANGELOG.md has no section for %s\n"):format(want))
            os.exit(1)
        end
    end
    local out = assert(io.open(args[2], "wb"))
    out:write(M.Lua(versions))
    out:close()
    print(("WhatsNewData.lua: %d versions, newest %s"):format(math.min(M.COUNT, #versions),
        versions[1] and versions[1].version or "none"))
end

return M
