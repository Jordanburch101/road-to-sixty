local _, ns = ...

-- Replaces this character's journey with fake test data; /reload then saves
-- it. The fake data follows the real formats in Recorder.lua and Journal.lua.
--
--   /rts seed confirm                  a realistic 1-30: the levelling route for
--                                     the character's race, quest hubs, real
--                                     dungeons at their level, a normal pace
--   /rts seed stress confirm [points]  a 1-60 through every zone at full size,
--                                     to stress test the map, memory use and
--                                     SavedVariables size

local DEFAULT_POINTS = 150000   -- rough estimate for a real 1-60
local SESSION_POINTS = 3600     -- about 2.5 hours of moving per login
local TAXI_DISTANCE = 1500      -- trips between zones longer than this fly or hearth
local HEARTH_CHANCE = 0.3       -- of those trips, the share done by hearthstone
local DUNGEON_CHANCE = 0.3      -- per zone
local KILL_CHANCE = 0.027       -- per point, about 4000 kills
local QUEST_CHANCE = 0.006      -- per point, about 900 quests
local DEATH_CHANCE = 0.0007     -- per point, about 100 deaths
local LOOT_CHANCE = 0.004       -- per point, about 600 green-or-better drops
local BLUE_SHARE, EPIC_SHARE = 0.13, 0.02   -- of world drops; the rest are green
local ITEM_LOAD_SECONDS = 5     -- longest wait for item data before seeding

-- Real Classic items for fake loot, so tooltips and icons work. Their
-- quality is read from the client, so a wrong guess here only moves an item
-- to another quality or, if it does not exist, leaves it out.
local SEED_ITEMS = {
    -- green weapons
    15210, 15211, 15212, 15213, 15214, 15215, 15216, 15217, 15218, 15219,
    15220, 15221, 15222, 15223, 15224, 15225, 15226, 15227, 15228, 15229, 15230,
    -- blues
    1121, 1155, 6318, 810, 1981, 2246, 2800, 2815, 1204, 9379,
    -- epics
    2244, 873, 1728, 2243, 647, 1263,
}

local random, floor, sqrt, cos, sin, atan2, pi =
    math.random, math.floor, math.sqrt, math.cos, math.sin, math.atan2, math.pi

local G  -- generator state for one run

local function round(v)
    return floor(v + 0.5)
end

-- Map lookups ----------------------------------------------------------------

local function ContinentOf(mapID)
    while mapID and mapID > 0 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then return end
        if info.mapType == Enum.UIMapType.Continent then return mapID end
        mapID = info.parentMapID
    end
end

-- Zones with a world-space box covering the middle of each zone map.
local function ZonesOf(continentMap)
    local zones = {}
    for _, child in ipairs(C_Map.GetMapChildrenInfo(continentMap, Enum.UIMapType.Zone) or {}) do
        local c1, a = C_Map.GetWorldPosFromMapPos(child.mapID, CreateVector2D(0.25, 0.25))
        local c2, b = C_Map.GetWorldPosFromMapPos(child.mapID, CreateVector2D(0.75, 0.75))
        if a and b and c1 == c2 and ns.MinimapDirs[c1] then
            table.insert(zones, {
                id = child.mapID, c = c1,
                x1 = math.min(a.x, b.x), x2 = math.max(a.x, b.x),
                y1 = math.min(a.y, b.y), y2 = math.max(a.y, b.y),
                cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2,
            })
        end
    end
    return zones
end

-- Orders zones by always going to the nearest one not yet visited.
local function NearestFirst(zones, x, y)
    local left, ordered = { unpack(zones) }, {}
    while #left > 0 do
        local best, bestD
        for i, z in ipairs(left) do
            local d = (z.cx - x) ^ 2 + (z.cy - y) ^ 2
            if not bestD or d < bestD then
                best, bestD = i, d
            end
        end
        local zone = table.remove(left, best)
        table.insert(ordered, zone)
        x, y = zone.cx, zone.cy
    end
    return ordered
end

-- Route: the player's continent first (starting near the player), then the rest.
local function BuildRoute()
    local playerMap = C_Map.GetBestMapForUnit("player")
    local home = playerMap and ContinentOf(playerMap)
    if not home then return end

    local continents = { home }
    local parent = C_Map.GetMapInfo(home).parentMapID
    for _, child in ipairs(parent and C_Map.GetMapChildrenInfo(parent, Enum.UIMapType.Continent) or {}) do
        if child.mapID ~= home then
            table.insert(continents, child.mapID)
        end
    end

    local _, px, py = ns.GetWorldPosition()
    local route = {}
    for _, continentMap in ipairs(continents) do
        local zones = ZonesOf(continentMap)
        if #zones > 0 then
            local sx, sy = px or zones[1].cx, py or zones[1].cy
            for _, zone in ipairs(NearestFirst(zones, sx, sy)) do
                table.insert(route, zone)
            end
            px, py = nil, nil
        end
    end
    return route
end

-- Writing --------------------------------------------------------------------

local function Log(kind, ...)
    table.insert(G.char.events, { G.t, kind, G.c, round(G.x), round(G.y), ... })
end

local function Snapshot(level)
    local totals = G.char.totals
    G.char.levels[level] = {
        t = G.t,
        money = level * level * 250,
        kills = totals.kills,
        killXP = totals.killXP,
        questXP = totals.questXP,
        deaths = totals.deaths,
        quests = totals.quests,
        instances = totals.instances,
        distance = floor(totals.distance),
        flown = floor(totals.flown),
        played = G.played,
    }
end

local function CloseSegment()
    if G.cur then
        G.cur.seg.d = table.concat(G.cur.steps, ";")
        G.cur = nil
    end
end

-- reason: why the path jumped here, as seg.j in Recorder.lua.
local function OpenSegment(mode, reason)
    CloseSegment()
    local seg = { m = mode, c = G.c, t = G.t, x = round(G.x), y = round(G.y), d = "", j = reason }
    table.insert(G.char.segments, seg)
    G.cur = { seg = seg, steps = {}, mode = mode, x = seg.x, y = seg.y, t = seg.t }
end

local function CheckLevel()
    -- Early levels come faster than late ones.
    local level = G.levelFor and G.levelFor(G.points) or math.min(60, 1 + floor(59 * (G.points / G.total) ^ 0.7))
    while G.level < level do
        G.level = G.level + 1
        Log("lvl", G.level)
        Snapshot(G.level)
    end
end

local function Step(nx, ny, dt)
    local cur, totals = G.cur, G.char.totals
    local dist = sqrt((nx - G.x) ^ 2 + (ny - G.y) ^ 2)
    G.t, G.x, G.y = G.t + dt, nx, ny
    G.played = G.played + dt
    G.points = G.points + 1

    local x, y = round(nx), round(ny)
    cur.steps[#cur.steps + 1] = (G.t - cur.t) .. "," .. (x - cur.x) .. "," .. (y - cur.y)
    cur.x, cur.y, cur.t = x, y, G.t

    if cur.mode == "t" then
        totals.flown = totals.flown + dist
    else
        totals.distance = totals.distance + dist
    end
    CheckLevel()
end

local function WalkTo(tx, ty, stepLength)
    while true do
        local dx, dy = tx - G.x, ty - G.y
        local d = sqrt(dx * dx + dy * dy)
        if d <= stepLength then return end
        local jitter = (random() - 0.5) * 0.3
        local heading = atan2(dy, dx) + jitter
        Step(G.x + cos(heading) * stepLength, G.y + sin(heading) * stepLength, 2)
    end
end

-- Events ---------------------------------------------------------------------

local function Die()
    G.char.totals.deaths = G.char.totals.deaths + 1
    Log("die")
    local deathX, deathY = G.x, G.y
    local angle, distance = random() * 2 * pi, random(300, 700)
    G.x, G.y = G.x + cos(angle) * distance, G.y + sin(angle) * distance
    G.t = G.t + 15
    OpenSegment("g", "d")
    WalkTo(deathX, deathY, 18)
    OpenSegment("w")
end

-- Logs a looted item like Journal.lua does and returns its link, or nil if
-- no items loaded. minQuality pushes dungeon drops towards blues.
local function DropLoot(instanceID, minQuality)
    local roll = random()
    local epic, blue = G.epicShare or EPIC_SHARE, G.blueShare or BLUE_SHARE
    local quality = roll < epic and 4 or roll < epic + blue and 3 or 2
    quality = math.max(quality, minQuality or 2)
    -- Fall back to any quality that has items.
    local list = G.items[quality]
    for q = 2, 4 do
        if #list > 0 then break end
        quality, list = q, G.items[q]
    end
    if #list == 0 then return end
    local link = list[random(#list)]
    Log("loot", link, quality, instanceID)
    return link
end

local function NextSession()
    Log("off")
    G.t = G.t + random(6, 20) * 3600
    Log("on", G.level)
    OpenSegment(G.cur.mode, "l")
    G.sessionLeft = SESSION_POINTS + random(-1000, 1000)
end

local function Wander(zone, count)
    local totals = G.char.totals
    local heading = random() * 2 * pi
    for _ = 1, count do
        if G.x < zone.x1 or G.x > zone.x2 or G.y < zone.y1 or G.y > zone.y2 then
            heading = atan2(zone.cy - G.y, zone.cx - G.x) + (random() - 0.5)
        else
            heading = heading + (random() - 0.5) * 0.8
        end
        local d = random(15, 20)
        Step(G.x + cos(heading) * d, G.y + sin(heading) * d, random(2, 3))

        if random() < KILL_CHANCE then
            totals.kills = totals.kills + 1
            totals.killXP = totals.killXP + G.level * 10 + 40
        end
        if random() < QUEST_CHANCE then
            local xp = G.level * 60 + 100
            totals.quests = totals.quests + 1
            totals.questXP = totals.questXP + xp
            Log("qd", G.quest, xp, G.level * 50)
            G.quest = G.quest + 1
            Log("qa", G.quest)
        end
        if random() < DEATH_CHANCE then
            Die()
        end
        if random() < LOOT_CHANCE then
            DropLoot()
        end

        G.sessionLeft = G.sessionLeft - 1
        if G.sessionLeft <= 0 then
            NextSession()
        end
    end
end

local function MaybeDungeon()
    if random() >= DUNGEON_CHANCE then return end
    G.dungeon = G.dungeon + 1
    G.char.totals.instances = G.char.totals.instances + 1
    local instanceID = 90000 + G.dungeon
    local name = "Test Dungeon " .. G.dungeon
    Log("in", instanceID, name, "party")
    local duration = random(45, 90) * 60
    G.t = G.t + floor(duration / 2)
    local items = {}
    for _ = 1, random(1, 3) do
        items[#items + 1] = DropLoot(instanceID, random() < 0.6 and 3 or 2)
    end
    G.t = G.t + duration - floor(duration / 2)
    -- Same layout as Journal.lua's run summary.
    Log("out", instanceID, {
        name = name, duration = duration, kills = random(20, 60), xp = G.level * random(400, 900),
        deaths = random(0, 2), money = G.level * random(200, 600), levels = 0, items = items,
    })
    OpenSegment("w", "i")
end

-- Travels to (tx, ty) in zone, by default its middle: a boat to another
-- continent, a hearthstone or flight path for long trips (walking below
-- G.walkBelow, before flight paths are known), else on foot.
local function TravelTo(zone, tx, ty)
    tx, ty = tx or zone.cx, ty or zone.cy
    local far = sqrt((tx - G.x) ^ 2 + (ty - G.y) ^ 2) > TAXI_DISTANCE
    local walking = G.walkBelow and G.level < G.walkBelow
    if zone.c ~= G.c then
        -- Boat to the other continent: a jump, so a new segment.
        G.t = G.t + 600
        G.c, G.x, G.y = zone.c, tx, ty
        OpenSegment("w", "b")
    elseif far and not walking and random() < HEARTH_CHANCE then
        -- Hearth: straight to the next zone, as if it were home.
        G.t = G.t + 10
        G.x, G.y = tx, ty
        OpenSegment("w", "h")
    elseif far and not walking then
        OpenSegment("t")
        WalkTo(tx, ty, 60)
        OpenSegment("w")
    else
        WalkTo(tx, ty, 18)
    end
    Log("zone", zone.id)
end

-- Run ------------------------------------------------------------------------

-- Wipes the journey and starts generating at level 1 in zone at (x, y),
-- daysAgo days in the past. settings are extra generator fields.
local function Begin(zone, x, y, daysAgo, items, settings)
    ns.ResetCharacter()
    G = {
        char = ns.char, points = 0, played = 0,
        level = 1, quest = 1, dungeon = 0,
        sessionLeft = SESSION_POINTS,
        c = zone.c, x = x, y = y,
        t = time() - daysAgo * 86400,
        items = items,
    }
    for k, v in pairs(settings) do
        G[k] = v
    end
    Log("on", 1)
    Snapshot(1)
    OpenSegment("w")
    Log("zone", zone.id)
    Log("qa", G.quest)
end

-- Fills any levels up to maxLevel the point budget fell short of, logs off,
-- and reports.
local function Finish(maxLevel, started, label)
    while G.level < maxLevel do
        G.level = G.level + 1
        Log("lvl", G.level)
        Snapshot(G.level)
    end
    CloseSegment()
    Log("off")

    ns.char.played = G.played
    ns.char.seeded = true
    local points = G.points
    G = nil
    -- The roster's coarse path was emptied by the reset; make it from the seed.
    ns.Roster:Rebuild()

    -- ReloadUI from a timer never happened on Forever (the saved data showed no
    -- login after a seed), so the save is left to the player; everything in
    -- memory is already consistent.
    ns.Print(("Seeded %s: %d points, %d segments, %d events in %.0f ms. Type /reload to save it now."):format(
        label, points, #ns.char.segments, #ns.char.events, debugprofilestop() - started))
end

-- items: links by quality, { [2] = {...}, [3] = {...}, [4] = {...} }.
local function SeedStress(total, items)
    local route = BuildRoute()
    if not route or #route == 0 then
        ns.Print("Could not find any zones to walk. Go outside on a main continent and try again.")
        return
    end
    local started = debugprofilestop()
    local first = route[1]
    Begin(first, first.cx, first.cy, 45, items, { total = total })

    local perZone = floor(total * 0.9 / #route)
    for i, zone in ipairs(route) do
        if i > 1 then
            TravelTo(zone)
        end
        Wander(zone, perZone)
        MaybeDungeon()
    end
    Finish(60, started, "stress 1-60")
end

-- Realistic 1-30 ---------------------------------------------------------------

local REALISTIC_POINTS = 28000      -- about 40 hours played at a normal pace
local REALISTIC_LEVEL = 30
local LEVEL_TIME_POWER = 1.3        -- time per level grows as level ^ this
local GRIND_RADIUS = 150            -- yards around a quest spot
local GRIND_KILL_CHANCE = 0.08      -- per point at a quest spot
local GRIND_DEATH_CHANCE = 0.0012
local GRIND_LOOT_CHANCE = 0.0015
local REALISTIC_BLUE_SHARE = 0.06

-- Levelling route per race: uiMapID, level when leaving it, ... (classic map IDs).
local ROUTES = {
    Human = { 1429, 10, 1436, 15, 1432, 18, 1433, 21, 1439, 23, 1437, 25, 1431, 28, 1440, 30 },
    Dwarf = { 1426, 10, 1432, 15, 1436, 18, 1433, 21, 1439, 23, 1437, 25, 1431, 28, 1440, 30 },
    NightElf = { 1438, 10, 1439, 17, 1440, 21, 1437, 24, 1433, 26, 1431, 30 },
    Orc = { 1411, 10, 1413, 20, 1442, 23, 1440, 26, 1424, 28, 1441, 30 },
    Tauren = { 1412, 10, 1413, 20, 1442, 23, 1440, 26, 1424, 28, 1441, 30 },
    Scourge = { 1420, 10, 1421, 16, 1413, 21, 1442, 24, 1440, 27, 1424, 30 },
}
ROUTES.Gnome, ROUTES.Troll = ROUTES.Dwarf, ROUTES.Orc

-- Dungeons per faction: { level, instanceID, name }.
local DUNGEONS = {
    Alliance = {
        { 19, 36, "The Deadmines" }, { 24, 34, "The Stockade" },
        { 26, 48, "Blackfathom Deeps" }, { 29, 90, "Gnomeregan" },
    },
    Horde = {
        { 15, 389, "Ragefire Chasm" }, { 19, 43, "Wailing Caverns" }, { 23, 33, "Shadowfang Keep" },
        { 26, 48, "Blackfathom Deeps" }, { 29, 47, "Razorfen Kraul" },
    },
}

-- A zone's middle part in world yards, keeping quest spots away from its edges.
local function ZoneBox(mapID)
    local c1, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.3, 0.3))
    local c2, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.7, 0.7))
    if not (a and b) or c1 ~= c2 then return end
    return {
        id = mapID, c = c1,
        x1 = math.min(a.x, b.x), x2 = math.max(a.x, b.x),
        y1 = math.min(a.y, b.y), y2 = math.max(a.y, b.y),
        cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2,
    }
end

local function RandomSpot(zone)
    return zone.x1 + random() * (zone.x2 - zone.x1), zone.y1 + random() * (zone.y2 - zone.y1)
end

-- Point counts at which each level ends, levels taking longer as they go.
local function LevelEnds(total, maxLevel)
    local weights, sum = {}, 0
    for level = 1, maxLevel - 1 do
        weights[level] = level ^ LEVEL_TIME_POWER
        sum = sum + weights[level]
    end
    local ends, done = {}, 0
    for level = 1, maxLevel - 1 do
        done = done + weights[level] / sum * total
        ends[level] = done
    end
    return ends
end

-- Kills and the odd death or drop around a quest spot.
local function Grind(sx, sy, count)
    local totals = G.char.totals
    local heading = random() * 2 * pi
    for _ = 1, count do
        if (G.x - sx) ^ 2 + (G.y - sy) ^ 2 > GRIND_RADIUS ^ 2 then
            heading = atan2(sy - G.y, sx - G.x) + (random() - 0.5)
        else
            heading = heading + (random() - 0.5) * 1.2
        end
        local d = random(15, 21)
        Step(G.x + cos(heading) * d, G.y + sin(heading) * d, 3)

        if random() < GRIND_KILL_CHANCE then
            totals.kills = totals.kills + 1
            totals.killXP = totals.killXP + G.level * 12 + 45
        end
        if random() < GRIND_DEATH_CHANCE then
            Die()
        end
        if random() < GRIND_LOOT_CHANCE then
            DropLoot()
        end
    end
end

-- Hands in a few quests in town, picks up new ones, and logs off for the
-- day if the session has run long.
local function TurnIn()
    local totals = G.char.totals
    for _ = 1, random(2, 4) do
        local xp = G.level * 70 + 120
        totals.quests = totals.quests + 1
        totals.questXP = totals.questXP + xp
        Log("qd", G.quest, xp, G.level * 60)
        G.quest = G.quest + 1
        Log("qa", G.quest)
    end
    if G.points - G.sessionStart >= SESSION_POINTS then
        NextSession()
        G.sessionStart = G.points
    end
end

-- One visit to an instance: no path, an hour or two, a summary and a drop or two.
local function RunDungeon(dungeon)
    local instanceID, name = dungeon[2], dungeon[3]
    G.char.totals.instances = G.char.totals.instances + 1
    Log("in", instanceID, name, "party")
    local duration = random(60, 120) * 60
    G.t = G.t + floor(duration / 2)
    local items = {}
    for _ = 1, random(1, 2) do
        items[#items + 1] = DropLoot(instanceID, random() < 0.6 and 3 or 2)
    end
    G.t = G.t + duration - floor(duration / 2)
    G.played = G.played + duration
    local kills = random(40, 90)
    G.char.totals.kills = G.char.totals.kills + kills
    Log("out", instanceID, {
        name = name, duration = duration, kills = kills, xp = kills * (G.level * 12 + 45),
        deaths = random(0, 2), money = G.level * random(300, 700), levels = 0, items = items,
    })
    OpenSegment("w", "i")
end

local function SeedRealistic(items)
    local _, race = UnitRace("player")
    local faction = UnitFactionGroup("player")
    local route = ROUTES[race] or (faction == "Horde" and ROUTES.Orc or ROUTES.Human)

    local zones = {}
    for i = 1, #route, 2 do
        local zone = ZoneBox(route[i])
        if zone then
            zone.leaveAt = route[i + 1]
            zones[#zones + 1] = zone
        end
    end
    if #zones == 0 then
        ns.Print("Could not find the levelling zones on this client.")
        return
    end

    local started = debugprofilestop()
    local ends = LevelEnds(REALISTIC_POINTS, REALISTIC_LEVEL)
    local town = { RandomSpot(zones[1]) }
    Begin(zones[1], town[1], town[2], 21, items, {
        total = REALISTIC_POINTS,
        levelFor = function(points)
            for level = 1, REALISTIC_LEVEL - 1 do
                if points < ends[level] then return level end
            end
            return REALISTIC_LEVEL
        end,
        walkBelow = 10,
        sessionStart = 0,
        blueShare = REALISTIC_BLUE_SHARE,
        epicShare = 0,
    })

    local dungeons, nextDungeon = DUNGEONS[faction] or DUNGEONS.Alliance, 1
    for i, zone in ipairs(zones) do
        if i > 1 then
            town = { RandomSpot(zone) }
            TravelTo(zone, town[1], town[2])
        end
        -- Quest from this zone's town until the level to move on.
        local leaveAt = ends[zone.leaveAt - 1] or REALISTIC_POINTS
        while G.points < leaveAt do
            local dungeon = dungeons[nextDungeon]
            if dungeon and G.level >= dungeon[1] then
                RunDungeon(dungeon)
                nextDungeon = nextDungeon + 1
            end
            for _ = 1, random(1, 2) do
                local sx, sy = RandomSpot(zone)
                WalkTo(sx, sy, 18)
                Grind(sx, sy, random(40, 120))
            end
            WalkTo(town[1], town[2], 18)
            TurnIn()
        end
    end
    Finish(REALISTIC_LEVEL, started, "realistic 1-30")
end

-- Asks the client for SEED_ITEMS and calls done with their links by quality
-- once all have loaded, or after ITEM_LOAD_SECONDS with whatever has.
local function LoadItems(done)
    ---@diagnostic disable-next-line: deprecated
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local exists = C_Item and C_Item.DoesItemExistByID
    -- Cached items can report loaded straight away, so finishing waits until
    -- every request is out.
    local waiting, finished, requesting = 0, false, true

    local function Finish()
        if finished then return end
        finished = true
        local byQuality = { [2] = {}, [3] = {}, [4] = {} }
        for _, id in ipairs(SEED_ITEMS) do
            local _, link, quality = getInfo(id)
            if link and byQuality[quality] then
                table.insert(byQuality[quality], link)
            end
        end
        done(byQuality)
    end

    for _, id in ipairs(SEED_ITEMS) do
        if not exists or exists(id) then
            if Item and Item.CreateFromItemID then
                waiting = waiting + 1
                Item:CreateFromItemID(id):ContinueOnItemLoad(function()
                    waiting = waiting - 1
                    if waiting == 0 and not requesting then
                        Finish()
                    end
                end)
            else
                getInfo(id)     -- starts loading it
            end
        end
    end
    requesting = false
    if Item and Item.CreateFromItemID and waiting == 0 then
        Finish()
    end
    C_Timer.After(ITEM_LOAD_SECONDS, Finish)
end

-- Command --------------------------------------------------------------------

ns.Command("seed", "replace this character's journey with fake test data", function(arg)
    local stress = arg:match("^stress%s+") ~= nil
    local confirm, count = arg:gsub("^stress%s+", ""):match("^(%S*)%s*(%d*)$")
    if confirm ~= "confirm" then
        ns.Print("This ERASES this character's journey and fills it with fake test data.")
        ns.Print("Type /rts seed confirm for a realistic 1-30 levelling journey.")
        ns.Print(("Type /rts seed stress confirm [points] for a full-size 1-60 stress test. Default %d points."):format(
            DEFAULT_POINTS))
        return
    end
    ns.Print("Loading item data for fake loot...")
    LoadItems(function(items)
        ns.Print(("Items for loot: %d green, %d blue, %d epic."):format(#items[2], #items[3], #items[4]))
        if stress then
            SeedStress(tonumber(count) or DEFAULT_POINTS, items)
        else
            SeedRealistic(items)
        end
    end)
end)
