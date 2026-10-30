local _, ns = ...

-- Gathering (issue #78): mining, herbalism and fishing, recorded as journal
-- events and shown on the journey map as nodes.
--   gath  prof, itemID, objectID, loot, instanceID   one gather: prof "m"
--         mining, "h" herbalism, "f" fishing; itemID the main resource,
--         whose icon the node shows (Copper Ore for a copper vein);
--         objectID the game object looted (from its GUID), nil when not
--         known; loot what was taken, "itemID:count,itemID:count";
--         instanceID when gathered inside one, whose events have the last
--         outdoor position (Journal.lua). The position is the player's, a
--         few yards from the node.
--
-- A gather is a loot window whose source is a game object (GetLootSourceInfo,
-- readable on Forever even inside instances) holding a known ore or herb,
-- or any fishing loot (IsFishingLoot). Nothing reads spell or item names,
-- so it works in any language. Its loot counts as each slot is taken
-- (LOOT_SLOT_CLEARED), so a window closed with full bags and opened again
-- counts once. A vein can be mined more than once before it goes, each
-- time a loot window from the same GUID: those are one gather. Fishing is
-- one gather per spot: catches within FISH_YARDS of the first, with no gap
-- over VISIT_SECONDS.
--
-- On the map, gathers of one resource within NODE_YARDS of each other are
-- one node, as nodes spawn at fixed spots: an ore icon with how many times
-- it was gathered. Fishing trips within SPOT_YARDS of each other are one
-- fishing spot, whatever they caught, its tooltip listing each trip.
-- History lists every gather; both follow the History filters Mining,
-- Herbalism and Fishing (under Learned, Panel.lua).

local Gathering = {}
ns.Gathering = Gathering

local VISIT_SECONDS = 5 * 60    -- the same node looted again this soon is the same visit
local NODE_YARDS = 10           -- gathers of one resource this close are one node on the map
local FISH_YARDS = 20           -- catches this close to a fishing trip's first are that trip
local SPOT_YARDS = 30           -- fishing trips this close are one fishing spot on the map
local SPOT_VISITS = 8           -- trips a spot's tooltip lists, newest first

-- The ores each kind of vein gives, the first found in a loot window being
-- its main resource; stones and gems are not listed, so they never are.
local ORES = {
    [2770] = true, [2771] = true, [2775] = true, [2772] = true, [2776] = true,      -- copper, tin, silver, iron, gold
    [3858] = true, [7911] = true, [10620] = true, [11370] = true,                   -- mithril, truesilver, thorium, dark iron
    [3340] = true, [4278] = true, [22202] = true, [18562] = true,                   -- incendicite, lesser bloodstone, obsidian, elementium
    [23424] = true, [23425] = true, [23426] = true, [23427] = true, [32464] = true, -- fel iron, adamantite, khorium, eternium, nethercite
    [5833] = true,                                                                  -- indurium (Uldaman)
}
-- Stones come out of veins too, and are never the main resource, even for
-- a vein known only by item class.
local STONES = { [2835] = true, [2836] = true, [2838] = true, [7912] = true, [12365] = true }

-- Herbs; the secondary ones only count as the main resource when nothing
-- else in the window is a herb.
local HERBS = {
    [2447] = true, [765] = true, [2449] = true, [785] = true, [2450] = true, [3820] = true,     -- peacebloom .. stranglekelp
    [2453] = true, [3355] = true, [3369] = true, [3356] = true, [3357] = true, [3818] = true,    -- bruiseweed .. fadeleaf
    [3821] = true, [3358] = true, [3819] = true, [4625] = true, [8831] = true, [8836] = true,    -- goldthorn .. arthas' tears
    [8838] = true, [8839] = true, [8845] = true, [8846] = true, [13464] = true, [13463] = true, -- sungrass .. dreamfoil
    [13465] = true, [13466] = true, [13467] = true, [13468] = true, [19726] = true,              -- silversage .. bloodvine
    [22785] = true, [22786] = true, [22787] = true, [22788] = true, [22789] = true,             -- felweed .. terocone
    [22790] = true, [22791] = true, [22792] = true, [22793] = true, [22710] = true,             -- lichen .. bloodthistle
    [2452] = "secondary", [22794] = "secondary",                                                -- swiftthistle, fel lotus
}

-- Resources a newer client adds (Forever may) are known by their item
-- class instead: Trade Goods, Metal & Stone or Herb.
local TRADE_GOODS, METAL_STONE, HERB = 7, 7, 9

local PROF_WORDS = { m = "Mined", h = "Gathered", f = "Fished" }

-- Gathers that can still carry on, by key (the node's GUID, or "f" for
-- fishing): { t, c, x, y, event }. Several, so a herb picked between a
-- vein's charges does not split the vein; kept VISIT_SECONDS.
-- A known limit, accepted (Jordan, 2026-10-29): these live only in memory,
-- so a /reload between two charges of one vein (or two catches at one
-- spot) makes two gathers, and the node counts one visit too many. Saving
-- them would cost more than the rare extra count.
local visits = {}
local open      -- the loot window of a gather: { event, slots = { [slot] = { itemID, count } } }
-- How many times a gather's loot grew; the map builds again when it changes.
Gathering.changes = 0
-- For History, which folds the loot a gather gave under it (Panel.lua).
Gathering.VISIT_SECONDS = VISIT_SECONDS

--@debug@
local probe = false     -- /rts gatherprobe: print each loot window and what was made of it
--@end-debug@

local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function ItemID(link)
    return tonumber(tostring(link or ""):match("item:(%d+)"))
end

local function ObjectGUID(guid)
    if guid and not Secret(guid) and tostring(guid):match("^GameObject%-") then return guid end
end

-- The game object ID in a GameObject GUID (GameObject-0-server-instance-zone-ID-spawn).
local function ObjectID(guid)
    return tonumber(tostring(guid or ""):match("^GameObject%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
end

local function ItemClass(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInfo then return end
    local ok, _, _, _, _, _, classID, subclassID = pcall(getInfo, itemID)
    if ok then return classID, subclassID end
end

-- What a loot window holds: { { itemID, count, slot }, ... } in slot order,
-- and the game object it came from (the first GUID that is one), if any.
local function ReadLoot()
    local items, object = {}, nil
    for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
        local id = ItemID(GetLootSlotLink and GetLootSlotLink(slot))
        if id then
            local _, _, count = GetLootSlotInfo(slot)
            items[#items + 1] = { id, tonumber(count) or 1, slot }
        end
        local sources = { pcall(GetLootSourceInfo, slot) }
        if table.remove(sources, 1) then
            for i = 1, #sources, 2 do
                object = object or ObjectGUID(sources[i])
            end
        end
    end
    return items, object
end

-- The profession and main resource of a loot window's items, or nil when
-- none is an ore or herb.
local function MainResource(items)
    local secondary
    for _, item in ipairs(items) do
        local id = item[1]
        if ORES[id] then return "m", id end
        if HERBS[id] == true then return "h", id end
        secondary = secondary or (HERBS[id] and id)
    end
    if secondary then return "h", secondary end
    -- By class only when the window holds nothing but trade goods, as a
    -- node's does: a chest with a bar among its gear is no vein.
    for _, item in ipairs(items) do
        if ItemClass(item[1]) ~= TRADE_GOODS then return end
    end
    for _, item in ipairs(items) do
        local class, subclass = ItemClass(item[1])
        if class == TRADE_GOODS and subclass == METAL_STONE and not STONES[item[1]] then return "m", item[1] end
        if class == TRADE_GOODS and subclass == HERB then return "h", item[1] end
    end
end

-- Loot strings: "itemID:count,..." <-> { [itemID] = count } and the order seen.
function Gathering.ParseLoot(text)
    local counts, order = {}, {}
    for idText, n in tostring(text or ""):gmatch("(%d+):(%d+)") do
        local id = tonumber(idText) or 0
        if not counts[id] then order[#order + 1] = id end
        counts[id] = (counts[id] or 0) + (tonumber(n) or 0)
    end
    return counts, order
end

local function LootText(counts, order)
    local parts = {}
    for _, id in ipairs(order) do
        parts[#parts + 1] = id .. ":" .. counts[id]
    end
    return table.concat(parts, ",")
end

-- Adds items to a loot string.
local function AddLoot(text, items)
    local counts, order = Gathering.ParseLoot(text)
    for _, item in ipairs(items) do
        local id = item[1]
        if not counts[id] then order[#order + 1] = id end
        counts[id] = (counts[id] or 0) + item[2]
    end
    return LootText(counts, order)
end

-- The visit a gather at c, x, y with this key carries on, if any; within
-- yards of where it began, when given. Visits gone stale are dropped.
local function OpenVisit(key, c, x, y, yards)
    for k, v in pairs(visits) do
        if ns.Now() - v.t > VISIT_SECONDS then visits[k] = nil end
    end
    local v = visits[key]
    if not v or not yards then return v end
    if c == v.c and c and c >= 0 and (x - v.x) ^ 2 + (y - v.y) ^ 2 <= yards * yards then return v end
end

-- A loot window opened (LOOT_READY, or LOOT_OPENED if that did not come):
-- logs the gather, or finds the one it carries on, and notes its slots, so
-- each counts once taken.
function Gathering:Looted()
    -- (a window left from long ago lost its LOOT_CLOSED, and must not stop the next)
    if (open and ns.Now() - open.t < 60) or ns.char.seeded then return end
    local items, object = ReadLoot()
    if #items == 0 then return end
    local fishing = IsFishingLoot and IsFishingLoot()
    local prof, main
    if fishing then
        prof, main = "f", items[1][1]
    elseif object then
        prof, main = MainResource(items)
    end
    --@debug@
    if probe then
        local shown = {}
        for _, item in ipairs(items) do
            local class, subclass = ItemClass(item[1])
            shown[#shown + 1] = ("%d x%d (%s/%s)"):format(item[1], item[2], tostring(class), tostring(subclass))
        end
        ns.Print(("Loot: %s; source %s; fishing %s -> %s"):format(table.concat(shown, ", "), tostring(object),
            tostring(fishing), prof and ("%s, main %d"):format(prof, main) or "not a gather"))
    end
    --@end-debug@
    if not prof then return end
    local c, x, y = ns.Recorder:Position()
    -- A vein's next charge is the same GUID; a fishing spot is where the first catch was.
    local key = fishing and "f" or object or "?"     -- (a gather that is not fishing has its object)
    local e
    local visit = OpenVisit(key, c, x, y, fishing and FISH_YARDS or nil)
    if visit then
        e = visit.event
        visit.t = ns.Now()
    else
        e = ns.Journal:Log("gath", prof, main, ObjectID(object), "", ns.char.instance)
        visits[key] = { t = ns.Now(), c = c, x = x, y = y, event = e }
    end
    open = { event = e, slots = {}, t = ns.Now() }
    for _, item in ipairs(items) do
        open.slots[item[3]] = { item[1], item[2] }
    end
end

-- A slot of the gather's window taken: its item counts.
function Gathering:Taken(slot)
    local item = open and open.slots[slot]
    if not item then return end
    open.slots[slot] = nil
    open.event[9] = AddLoot(open.event[9], { item })
    Gathering.changes = Gathering.changes + 1
    --@debug@
    if probe then ns.Print(("Taken: slot %d, %d x%d; the gather now has %s"):format(slot, item[1], item[2], open.event[9])) end
    --@end-debug@
end

-- Nodes -------------------------------------------------------------------------

-- The nodes in the journey shown, within the map's date range (Range.lua),
-- first gathered first: { c, x, y (world yards, the average of its gathers),
-- prof, item, count, first, last, loot = { [itemID] = count }, order (loot
-- item IDs as first seen), visits = { { t, catches }, ... } in time order }.
-- A fishing spot is one node whatever it gave: fishing trips within
-- SPOT_YARDS of each other, its item (and icon) the latest trip's first
-- catch (Jordan's pick). Gathers
-- inside instances are left out: their place is only the door's.
function Gathering:Nodes()
    local nodes, grid = {}, {}
    local function Cell(c, item, gx, gy) return ("%d:%d:%d:%d"):format(c, item, gx, gy) end
    for _, e in ipairs(ns.view.events) do
        local c, x, y = e[3], e[4], e[5]
        if e[2] == "gath" and e[7] and not e[10] and c and c >= 0 and ns.Range:Has(e[1]) then
            local fishing = e[6] == "f"
            -- Cells as wide as the reach, and each node filed under the cell of
            -- its centre as that moves, so a node is always in the 3 x 3 round a gather.
            local item, reach = fishing and 0 or e[7], fishing and SPOT_YARDS or NODE_YARDS
            local gx, gy = math.floor(x / reach), math.floor(y / reach)
            -- The nearest node in reach, so the same journey always makes the same nodes.
            local node, best = nil, reach * reach
            for cx = gx - 1, gx + 1 do
                for cy = gy - 1, gy + 1 do
                    for _, n in pairs(grid[Cell(c, item, cx, cy)] or {}) do
                        local d = (n.x - x) ^ 2 + (n.y - y) ^ 2
                        if d <= best then node, best = n, d end
                    end
                end
            end
            if not node then
                node = { c = c, x = x, y = y, prof = e[6], item = e[7], count = 0, first = e[1], loot = {}, order = {},
                    visits = {} }
                nodes[#nodes + 1] = node
            end
            -- The average of its gathers: the node is in the middle of where it was stood at.
            node.x = (node.x * node.count + x) / (node.count + 1)
            node.y = (node.y * node.count + y) / (node.count + 1)
            node.count, node.last = node.count + 1, e[1]
            local key = Cell(c, item, math.floor(node.x / reach), math.floor(node.y / reach))
            if key ~= node.cell then
                if node.cell then grid[node.cell][node] = nil end
                grid[key] = grid[key] or {}
                grid[key][node] = node
                node.cell = key
            end
            -- A fishing spot shows its latest trip's first catch.
            if fishing then node.item = e[7] end
            local counts, order = Gathering.ParseLoot(e[9])
            local catches = 0
            for _, id in ipairs(order) do
                if not node.loot[id] then node.order[#node.order + 1] = id end
                node.loot[id] = (node.loot[id] or 0) + counts[id]
                catches = catches + counts[id]
            end
            node.visits[#node.visits + 1] = { e[1], catches }
        end
    end
    return nodes
end

-- On the map --------------------------------------------------------------------

local function ItemIcon(itemID)
    if C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(itemID)
    end
    ---@diagnostic disable-next-line: deprecated
    return GetItemInfoInstant and select(5, GetItemInfoInstant(itemID)) or nil
end

-- An item's name; one the client has not loaded yet is asked for, and
-- named by its ID until it comes (GET_ITEM_INFO_RECEIVED below), when the
-- map and History build again at the next open.
local asked = {}
local function ItemName(itemID)
    ---@diagnostic disable-next-line: deprecated
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local name = getInfo and getInfo(itemID)
    if name then return name end
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    asked[itemID] = true
    return "Item " .. itemID
end

ns.On("GET_ITEM_INFO_RECEIVED", function(itemID)
    if itemID and asked[itemID] then
        asked[itemID] = nil
        Gathering.changes = Gathering.changes + 1
    end
end)

-- The History filter each profession's gathers and nodes follow (Panel.lua).
Gathering.CATEGORY = { m = "mining", h = "herbs", f = "fishing" }

-- How to show a gather in History: title, detail (what it gave, to go
-- before the place), icon, and the tooltip's lines (each item it gave).
function Gathering:Describe(e)
    local counts, order = self.ParseLoot(e[9])
    local parts, lines, caught = {}, {}, 0
    for _, id in ipairs(order) do
        local name = ItemName(id)
        parts[#parts + 1] = ("%d %s"):format(counts[id], name)
        lines[#lines + 1] = ("|T%s:0|t %s x%d"):format(tostring(ItemIcon(id)), name, counts[id])
        caught = caught + counts[id]
    end
    local title
    if e[6] == "f" then
        title = caught == 0 and "Fished" or caught == 1 and "Fished a catch" or ("Fished %d catches"):format(caught)
    else
        title = ("%s %s"):format(PROF_WORDS[e[6]] or "Gathered", ItemName(e[7]))
    end
    -- (nothing taken: full bags, or the window closed first)
    return title, #parts > 0 and table.concat(parts, ", ") or "Nothing taken", ItemIcon(e[7]), lines
end

-- A node's marker is a classic item button, as in the bags (Jordan picked
-- it from a screenshot): the icon under the button frame, the count at the
-- bottom right. The frame is drawn at 64 for a 37 button, a pixel low.
-- 12 pixels, picked by Jordan from 10 to 16.
local size = 12
local FRAME, FRAME_SCALE = "Interface\\Buttons\\UI-Quickslot2", 64 / 37
local COUNT_FONT = _G["NumberFontNormalSmall"] and "NumberFontNormalSmall" or "GameFontHighlightSmall"

-- The node's own art on marker m, made once: icon, frame and count.
local function Art(m)
    if m.gather then return m.gather end
    local g = CreateFrame("Frame", nil, m)
    g:SetAllPoints()
    g.icon = g:CreateTexture(nil, "ARTWORK")
    g.icon:SetPoint("CENTER")
    g.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    g.frame = g:CreateTexture(nil, "OVERLAY")
    g.frame:SetTexture(FRAME)
    g.count = g:CreateFontString(nil, "OVERLAY", COUNT_FONT)
    g.count:SetDrawLayer("OVERLAY", 7)
    m.gather = g
    return g
end

-- Shows marker m as node.
local function Dress(m, node)
    local g = Art(m)
    m.icon:Hide()
    m.text:SetText("")
    m:SetSize(size + 2, size + 2)
    g.icon:SetTexture(ItemIcon(node.item))
    g.icon:SetSize(size, size)
    g.frame:SetSize(size * FRAME_SCALE, size * FRAME_SCALE)
    g.frame:ClearAllPoints()
    g.frame:SetPoint("CENTER", 0, -size / 37)
    g.count:ClearAllPoints()
    g.count:SetPoint("BOTTOMRIGHT", g.icon, "BOTTOMRIGHT", 3, -2)
    g.count:SetText(node.count)
    g.count:SetShown(node.count > 1)
    g:Show()
end

-- Shows or hides a node marker's count: a pile's number replaces it (MarkerPiles.lua).
function Gathering:ShowCount(m, shown)
    if m.gather and m.node then
        m.gather.count:SetShown(shown and m.node.count > 1)
    end
end

-- Adds a marker for each node after the map's count markers, from
-- GetMarker (Map.lua's), placed with toContent (continent -> function
-- turning world yards into content units) and shown from minZoom. Returns
-- the new count.
function Gathering:AddMarkers(count, GetMarker, toContent, minZoom)
    for _, node in ipairs(self:Nodes()) do
        local place = toContent[node.c]
        if place then
            count = count + 1
            local m = GetMarker(count)
            m.t, m.popping, m.level, m.node = node.first, nil, nil, node
            m.x, m.y = place(node.x, node.y)
            m.c, m.category, m.minZoom = node.c, self.CATEGORY[node.prof], minZoom
            Dress(m, node)
        end
    end
    return count
end

local function When(t)
    return tostring(date("%d %b %Y, %H:%M", t))
end

-- A fishing spot's tooltip lines: how often, then each trip, newest first,
-- with its catches (the oldest beyond SPOT_VISITS counted, not listed).
local function SpotLines(node)
    local catches = 0
    for _, v in ipairs(node.visits) do catches = catches + v[2] end
    GameTooltip:AddLine(("Fished here %s, %d %s"):format(node.count == 1 and "once" or (node.count .. " times"),
        catches, catches == 1 and "catch" or "catches"), 1, 1, 1)
    for k = #node.visits, math.max(1, #node.visits - SPOT_VISITS + 1), -1 do
        local v = node.visits[k]
        GameTooltip:AddDoubleLine(When(v[1]), ("%d %s"):format(v[2], v[2] == 1 and "catch" or "catches"),
            0.7, 0.7, 0.7, 1, 1, 1)
    end
    local older = #node.visits - SPOT_VISITS
    if older > 0 then
        GameTooltip:AddLine(("and %d earlier %s"):format(older, older == 1 and "trip" or "trips"), 0.7, 0.7, 0.7)
    end
end

-- The tooltip of a node's marker.
function Gathering:ShowTooltip(owner, node)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if node.prof == "f" then
        GameTooltip:AddLine("Fishing spot")
        SpotLines(node)
    else
        GameTooltip:AddLine(ItemName(node.item))
        GameTooltip:AddLine(node.count == 1 and (PROF_WORDS[node.prof] or "Gathered") .. " once"
            or ("%s %d times"):format(PROF_WORDS[node.prof] or "Gathered", node.count), 1, 1, 1)
        local when = When(node.first)
        if node.count > 1 then
            when = ("First %s\nLast %s"):format(when, When(node.last))
        end
        GameTooltip:AddLine(when, 0.7, 0.7, 0.7)
    end
    for _, id in ipairs(node.order) do
        GameTooltip:AddLine(("|T%s:0|t %s x%d"):format(tostring(ItemIcon(id)), ItemName(id), node.loot[id]), 1, 1, 1)
    end
    GameTooltip:Show()
end

-- LOOT_READY comes first, so the window is read before any slot can be
-- taken, whatever auto loot does; Looted does nothing the second time.
ns.On("LOOT_READY", function() Gathering:Looted() end)
ns.On("LOOT_OPENED", function() Gathering:Looted() end)
ns.On("LOOT_SLOT_CLEARED", function(slot) Gathering:Taken(slot) end)
ns.On("LOOT_CLOSED", function() open = nil end)

--@debug@
ns.Command("gatherprobe", "print each loot window and whether it counts as a gather (developer)", function()
    probe = not probe
    local nodes = Gathering:Nodes()
    ns.Print(("Gather probe %s. This journey: %d node(s) on the map."):format(probe and "on" or "off", #nodes))
end)

-- /rts gatherseed: fake gathers in a seeded journey (/rts seed), to see the
-- nodes on the map without gathering for hours. Near every fourth quest
-- turn-in a node of an ore or herb for the level, gathered one to five
-- times over the following hours. Only a seeded journey, never a real one.
local SEED_ORES = { 2770, 2770, 2771, 2772, 2775, 3858, 7911, 10620, 10620 }   -- by level / 7
local SEED_HERBS = { 2447, 765, 785, 2453, 3356, 3818, 8836, 13464, 13467 }

ns.Command("gatherseed", "add fake gathering nodes to a seeded journey (developer)", function()
    local char = ns.char
    if not char.seeded then
        ns.Print("Only for a seeded journey (/rts seed): this one is real.")
        return
    end
    local added, level, quests = {}, 1, 0
    for _, e in ipairs(char.events) do
        if e[2] == "on" or e[2] == "lvl" then level = e[6] or level end
        if e[2] == "qd" and e[3] >= 0 then
            quests = quests + 1
            if quests % 4 == 0 then
                local roll = math.random()
                local prof = roll < 0.4 and "h" or roll < 0.8 and "m" or "f"
                local band = math.min(9, math.floor(level / 7) + 1)
                local item = prof == "h" and SEED_HERBS[band] or prof == "m" and SEED_ORES[band] or 6291
                local angle, far = math.random() * 2 * math.pi, math.random(40, 90)
                local nx, ny = e[4] + math.cos(angle) * far, e[5] + math.sin(angle) * far
                local t = e[1] + 30
                for _ = 1, math.random(1, 5) do
                    local loot = item .. ":" .. math.random(1, 3)
                    if prof == "m" and math.random() < 0.4 then loot = loot .. ",2835:1" end
                    -- A fishing trip: smallfish and mud snappers, standing a little further about.
                    if prof == "f" then loot = "6291:" .. math.random(2, 9) .. ",6303:" .. math.random(0, 4) end
                    local jitter = prof == "f" and 12 or 4
                    added[#added + 1] = { t, "gath", e[3], math.floor(nx + math.random(-jitter, jitter)),
                        math.floor(ny + math.random(-jitter, jitter)), prof, item, nil, loot }
                    t = t + math.random(1, 6) * 3600
                end
            end
        end
    end
    -- Each into its place by time, as the journal is in time order.
    local events = char.events
    for _, g in ipairs(added) do
        local at = #events + 1
        while at > 1 and events[at - 1][1] > g[1] do at = at - 1 end
        table.insert(events, at, g)
    end
    ns.Print(("Added %d fake gathers; %d nodes in this journey now. Close and open the map."):format(
        #added, #Gathering:Nodes()))
end)
--@end-debug@
