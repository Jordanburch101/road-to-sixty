-- Loads a built addon (the release build, or the source) the way the client
-- does: every file in toc order, with the addon name and a shared namespace.
-- Any game API is a stand-in that accepts every call, so this only catches
-- errors at load time, such as a release file using something only a
-- developer file defines. Usage: luajit tests/release_load.lua build/ForeverMod

local dir = assert(arg[1], "usage: luajit tests/release_load.lua <addon folder>")
local addonName = dir:match("([^/\\]+)[/\\]*$")

-- A value that is every API at once: callable, indexable, and safe in sums,
-- comparisons and string joins.
local stub
local function self() return stub end
stub = setmetatable({}, {
    __index = self, __call = self,
    __add = self, __sub = self, __mul = self, __div = self, __mod = self, __pow = self, __unm = self,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
})

setmetatable(_G, { __index = function() return stub end })

local toc = assert(io.open(dir .. "/" .. addonName .. ".toc"), "no toc in " .. dir)
local ns, count = {}, 0
for line in toc:lines() do
    line = line:gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
        local chunk = assert(loadfile(dir .. "/" .. line))
        local ok, err = pcall(chunk, addonName, ns)
        if not ok then
            print(("FAIL: %s did not load: %s"):format(line, tostring(err)))
            os.exit(1)
        end
        count = count + 1
    end
end
toc:close()
print(("Release load test passed: %d files loaded from %s."):format(count, dir))
