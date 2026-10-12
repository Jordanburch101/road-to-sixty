-- Every time the addon saves has to come from the game server's clock, so
-- journeys from two computers with different clocks can be merged without
-- their sessions seeming to overlap (#35). This fails on any time() call in
-- a file the release toc lists. Developer-only files keep time(). Run with
-- LuaJIT from the repo root: luajit tests/clock_test.lua

local failures = 0

local function ShippedFiles()
    local files, debug = {}, false
    for line in io.lines("RoadToSixty/RoadToSixty.toc") do
        if line:find("#@debug@", 1, true) then
            debug = true
        elseif line:find("#@end-debug@", 1, true) then
            debug = false
        elseif not debug and line:match("%.lua%s*$") then
            files[#files + 1] = line:match("^%s*(.-)%s*$")
        end
    end
    return files
end

local files = ShippedFiles()
assert(#files > 20, "found only " .. #files .. " shipped files in the toc")

for _, name in ipairs(files) do
    local n = 0
    for line in io.lines("RoadToSixty/" .. name) do
        n = n + 1
        -- time() on its own, not os.time() or GetServerTime().
        local stripped = line:gsub("GetServerTime%(%)", ""):gsub("os%.time%(%)", "")
        if stripped:find("%f[%w_]time%(%)") then
            failures = failures + 1
            print(("FAIL: %s:%d uses time(): %s"):format(name, n, line:match("^%s*(.-)%s*$")))
        end
    end
end

if failures == 0 then
    print("Clock tests passed.")
else
    print(failures .. " clock test(s) failed.")
    os.exit(1)
end
