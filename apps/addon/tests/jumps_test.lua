-- Offline test of the journey map's jump arcs, run from the real Map.lua on
-- stand-in widgets that count every call made on them (#152). An arc drawn
-- from the same as in the last build keeps its pieces with no call at all;
-- one that changes, or leaves, gives its pieces back hidden; and an arc
-- whose dots were left out for an earlier route's is drawn again once that
-- route is gone. Run with LuaJIT from apps/addon: luajit tests/jumps_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local file = assert(io.open("RoadToSixty/Map.lua", "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local from = assert(source:find("\n-- Jump arcs", 1, true))
local to = assert(source:find("\n-- Lines and jumps are sized for the zoom now", from, true))

-- Stand-in widgets: every method call is counted; shown is tracked.
local calls, made = 0, 0
local function Widget(kind)
    made = made + 1
    local w = { kind = kind, shown = true }
    return setmetatable(w, { __index = function(_, method)
        return function(self, ...)
            calls = calls + 1
            if method == "Hide" then self.shown = false
            elseif method == "Show" then self.shown = true
            elseif method == "SetShown" then self.shown = (...) and true or false end
            return self
        end
    end })
end
local layer = { CreateLine = function() return Widget("line") end, CreateTexture = function() return Widget("texture") end }

local T = {
    state = { jumps = {}, pj = {}, seaTrips = {}, zoom = 8, lineZoom = 8, journey = {} },
    ns = {
        PathLines = { FitJump = function() return 0, false end },
        Portals = { Begin = function() end, Add = function() end, Finish = function() end },
    },
    Style = {},
    pathLayer = layer, overlay = layer,
}
-- Dotted for hearthstones ("h"), dashed for deaths ("d"), solid for teleports ("p").
local STYLES = {
    h = { style = "dots", 0.4, 0.8, 1, 1, icon = "hearth" },
    d = { style = "dash", 1, 0.3, 0.3, 1 },
    p = { style = "solid", 0.8, 0.5, 1, 1 },
}
T.Style.Jump = function(reason) return STYLES[reason] end

local prelude = [[
local T = ...
local state, ns, Style, pathLayer, overlay = T.state, T.ns, T.Style, T.pathLayer, T.overlay
local addonName = "RoadToSixty"
local jumpLines, jumpDots, jumpIcons = {}, {}, {}
local JUMP_ARC, JUMP_ARC_STEPS, JUMP_ICON_ZOOM, JUMP_ICON = 0.2, 16, 4, 16
local JUMP_OUTLINE, JUMP_OUTLINE_COLOR, JUMP_LINE, LINE_WIDTH = 4, { 0, 0, 0, 0.8 }, 2, 2
local JUMP_DOT, JUMP_DOT_SPACING, JUMP_DASH, JUMP_GAP, JUMP_MAX_PIECES = 4, 10, 6, 4, 150
]]
local chunk = assert(loadstring(prelude .. source:sub(from, to) .. "\nreturn BuildJumps, jumpLines, jumpDots"))
local BuildJumps, freeLines, freeDots = chunk(T)
local state = T.state

-- Jump lines as the map builds them: { x1, y1, x2, y2, "j", point }.
local function Jump(x1, y1, x2, y2, p, reason)
    state.pj[p] = reason
    return { x1, y1, x2, y2, "j", p }
end
local function Drawn(list)
    local out = {}
    for i, j in ipairs(list) do out[i] = { j[1], j[2], j[3], j[4], j[5], j[6] } end
    return out
end
local A = Jump(10, 10, 60, 10, 2, "h")
local B = Jump(10, 40, 60, 40, 3, "d")
local C = Jump(10, 70, 60, 80, 4, "p")
local AREA = { -50, -50, 150, 150 }

local function Parts()
    local all, owner = 0, {}
    for _, jump in ipairs(state.jumps) do
        for _, part in ipairs(jump.parts) do
            all = all + 1
            check(not owner[part], "a piece belongs to one arc only")
            owner[part] = jump
        end
    end
    return all, owner
end

-- First build: everything new.
BuildJumps(Drawn({ A, B, C }), 99, 8, AREA)
local first, firstMade = Parts(), made
check(#state.jumps == 3 and first > 20 and firstMade >= first, "three arcs drawn, got " .. #state.jumps .. " with " .. first .. " pieces")
local arcA = state.jumps[1]

-- The view moved a little, every arc still wholly inside: nothing is placed.
calls, made = 0, 0
BuildJumps(Drawn({ A, B, C }), 99, 8, { -55, -55, 155, 155 })
-- (One call: the hearthstone's icon is shown again, once for each arc with one.)
check(made == 0 and calls <= 1, ("arcs drawn from the same make no calls (made %d, calls %d)"):format(made, calls))
check(state.jumps[1] == arcA and Parts() == first, "the same arcs are kept")

-- The view cuts B's dashes short: only B is drawn again, from pieces
-- given back or new ones, and what it gave back is hidden and free.
calls, made = 0, 0
local oldB = state.jumps[2]
BuildJumps(Drawn({ A, B, C }), 99, 8, { -50, -50, 35, 150 })
check(state.jumps[1] ~= arcA, "A, cut short too, is drawn again")
check(state.jumps[2] ~= oldB, "B, cut short, is drawn again")
check(state.jumps[3].build == state.jumps[1].build, "C, solid and whole, is kept")
local _, owner = Parts()
for _, part in ipairs(oldB.parts) do
    check(not owner[part] and not part.shown, "a piece B gave back is hidden and in no arc")
end
local free = 0
for _, part in ipairs(freeLines) do free = free + 1 check(not owner[part], "free lines are in no arc") end
for _, part in ipairs(freeDots) do free = free + 1 check(not owner[part], "free dots are in no arc") end
check(free > 0, "pieces given back are free to reuse")

-- Visibility follows the replay: arcs past shown hide their pieces.
BuildJumps(Drawn({ A, B, C }), 2, 8, AREA)
for _, jump in ipairs(state.jumps) do
    for _, part in ipairs(jump.parts) do
        check(part.shown == (jump.index <= 2), "pieces shown as far as the replay has reached")
    end
end
BuildJumps(Drawn({ A, B, C }), 99, 8, AREA)

-- A second hearthstone on top of A leaves its dots out where A has them;
-- without A it must be drawn again with its own.
local A2 = Jump(10, 10.01, 60, 10.01, 5, "h")
BuildJumps(Drawn({ A, A2 }), 99, 8, AREA)
local over = state.jumps[2]
check(#over.marks < #state.jumps[1].marks, "a route on top of another leaves its dots out")
BuildJumps(Drawn({ A2 }), 99, 8, AREA)
check(state.jumps[1] ~= over and #state.jumps[1].marks > #over.marks, "alone again, it is drawn with all its dots")

-- Another zoom: everything drawn again (sizes and spacing are per zoom).
local before = state.jumps[1]
BuildJumps(Drawn({ A2 }), 99, 12, AREA)
check(state.jumps[1] ~= before, "a new zoom draws arcs again")

if failures == 0 then
    print("Jumps tests passed.")
else
    print(failures .. " jumps test(s) failed.")
    os.exit(1)
end
