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

-- Names for the fake quests (their IDs are made up), so turn-ins on the map
-- read like real ones. Classic Alliance quests from the realistic route.
local QUEST_NAMES = {
    "A New Threat", "Dwarven Outfitters", "Coldridge Valley Mail Delivery", "The Troll Cave",
    "Ammo for Rumbleshot", "Stocking Jetsteam", "The Grizzled Den", "Bitter Rivals",
    "Rat Catching", "In Defense of the King's Lands", "Mercenaries", "Stormpike's Delivery",
    "The Westfall Stew", "Patrolling Westfall", "The Defias Brotherhood", "Red Leather Bandanas",
    "Underground Assault", "Murloc Poachers", "Selling Fish", "Wanted: Lieutenant Fangore",
    "Blackrock Menace", "Shadow Magic", "Look to the Stars", "The Night Watch",
    "Worgen in the Woods", "Raven Hill", "The Legend of Stalvan", "Report to Gryan Stoutmantle",
    "Daily Delivery", "Claws from the Deep", "Fenwick Thatros", "The Absent Minded Prospector",
    "Buzzbox 827", "The Tower of Althalaxx", "Mist", "Bathran's Hair", "Raene's Cleansing",
    "Ruuzel", "Elune's Tear", "The Ancient Statuette",
}

local function QuestName(id)
    return QUEST_NAMES[id % #QUEST_NAMES + 1]
end


-- Gear the stress seed's character puts on as it levels: { item ID, level }.
-- Real Classic items; each item's slot comes from the client
-- (GetItemInfoInstant), so a wrong ID is left out rather than worn in the
-- wrong place. The realistic seed has its own, REALISTIC_GEAR.
local GEAR_POOL = {
    -- starting gear
    { 38, 1 }, { 39, 1 }, { 40, 1 }, { 25, 1 }, { 2362, 1 },
    { 2504, 5 }, { 15210, 8 }, { 15211, 12 },
    -- Deadmines: Blackened Defias set, Cruel Barb
    { 10399, 17 }, { 10400, 17 }, { 10401, 18 }, { 10402, 18 }, { 10403, 19 }, { 5191, 19 },
    -- Shadowfang Keep: Wolfmaster Cape, Shadowfang
    { 6314, 22 }, { 1482, 23 }, { 1981, 26 },
    -- Scarlet Monastery: Scarlet set, Herod's Shoulder, Raging Berserker's Helm, Ravager
    { 10328, 29 }, { 10330, 29 }, { 10331, 30 }, { 10332, 30 }, { 10329, 30 }, { 10333, 30 },
    { 7719, 33 }, { 7718, 34 }, { 7717, 36 },
    { 810, 40 }, { 2244, 45 }, { 1728, 50 },
    -- Battlegear of Valor
    { 16731, 54 }, { 16733, 55 }, { 16730, 56 }, { 16737, 56 }, { 16732, 57 }, { 16734, 57 },
    { 16736, 58 }, { 16735, 58 },
    { 647, 60 },
}

-- Professions and recipes, as Crafts.lua logs them, for both seeds: a warrior
-- with Skinning and Leatherworking plus the secondary skills. Per level:
-- learn = { { profession, rank, max } } learned or trained to a new tier, and
-- recipes = { { name, spell ID, profession, from a trainer } }. Spell IDs are Classic's;
-- the saved profession is what History shows.
local CRAFT_PLAN = {
    [3] = { learn = { { "First Aid", 1, 75 } }, recipes = { { "Linen Bandage", 3275, "First Aid", true } } },
    [5] = {
        learn = { { "Skinning", 1, 75 }, { "Leatherworking", 1, 75 } },
        recipes = {
            { "Light Leather", 2881, "Leatherworking", true },
            { "Handstitched Leather Boots", 2149, "Leatherworking", true },
            { "Light Armor Kit", 2152, "Leatherworking", true },
        },
    },
    [6] = { learn = { { "Cooking", 1, 75 } }, recipes = { { "Spiced Wolf Meat", 2539, "Cooking", true } } },
    [8] = { recipes = { { "Handstitched Leather Belt", 3753, "Leatherworking", true } } },
    [10] = {
        learn = { { "Leatherworking", 50, 150 }, { "Skinning", 50, 150 } },
        recipes = {
            { "Handstitched Leather Cloak", 9058, "Leatherworking", true },
            { "Light Leather Quiver", 9060, "Leatherworking", true },
        },
    },
    [12] = { learn = { { "First Aid", 50, 150 } }, recipes = { { "Heavy Linen Bandage", 3276, "First Aid", true } } },
    [14] = { recipes = { { "Roasted Boar Meat", 2540, "Cooking" }, { "Coyote Steak", 2541, "Cooking" } } },
    [16] = { recipes = { { "Wool Bandage", 3277, "First Aid", true } } },
    [18] = { recipes = { { "Embossed Leather Gloves", 3756, "Leatherworking", true } } },
    [20] = {
        learn = { { "Leatherworking", 125, 225 }, { "Skinning", 125, 225 } },
        recipes = {
            { "Fine Leather Belt", 3763, "Leatherworking", true },
            { "Embossed Leather Vest", 2160, "Leatherworking", true },
        },
    },
    [22] = { learn = { { "First Aid", 125, 225 } }, recipes = { { "Heavy Wool Bandage", 3278, "First Aid", true } } },
    [24] = { recipes = { { "Crab Cake", 2544, "Cooking" } } },
    [26] = { recipes = { { "Embossed Leather Boots", 2161, "Leatherworking", true } } },
    [35] = { learn = { { "Leatherworking", 200, 300 }, { "Skinning", 200, 300 } } },
    [40] = { learn = { { "First Aid", 225, 300 } } },
}
local CRAFT_RATE = { ["First Aid"] = 6, Skinning = 7, Leatherworking = 6, Cooking = 4 }  -- skill ups per level

-- Equip location -> inventory slot. Rings and trinkets are not in the pool.
local EQUIP_SLOTS = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_BODY = 4,
    INVTYPE_CHEST = 5, INVTYPE_ROBE = 5, INVTYPE_WAIST = 6, INVTYPE_LEGS = 7,
    INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10, INVTYPE_CLOAK = 15,
    INVTYPE_WEAPON = 16, INVTYPE_WEAPONMAINHAND = 16, INVTYPE_2HWEAPON = 16,
    INVTYPE_SHIELD = 17, INVTYPE_HOLDABLE = 17, INVTYPE_WEAPONOFFHAND = 17,
    INVTYPE_RANGED = 18, INVTYPE_RANGEDRIGHT = 18, INVTYPE_THROWN = 18, INVTYPE_TABARD = 19,
}
local OFF_HAND = 17

local random, floor, sqrt, cos, sin, atan2, pi =
    math.random, math.floor, math.sqrt, math.cos, math.sin, math.atan2, math.pi

local G  -- generator state for one run

-- Mobs for fake kills by level band (1-9, 10-19, ...), Classic Alliance zones.
local MOB_NAMES = {
    { "Rockjaw Trogg", "Frostmane Troll Whelp", "Young Wendigo", "Burly Rockjaw Trogg", "Kobold Vermin" },
    { "Defias Thug", "Harvest Watcher", "Murloc Coastrunner", "Redridge Mongrel", "Riverpaw Gnoll" },
    { "Skeletal Warrior", "Mottled Worg", "Mosshide Gnoll", "Blackwood Furbolg", "Foulweald Ursa" },
    { "Syndicate Thief", "Dragonmaw Raider", "Mountain Lion", "Daggerspine Siren", "Thistlefur Shaman" },
    { "Dustbelcher Ogre", "Hakkari Priest", "Scarlet Crusader", "Gorishi Worker", "Felpaw Ravager" },
    { "Blackrock Warlock", "Scourge Champion", "Felmusk Satyr", "Cursed Paladin", "Winterfall Ursa" },
}

-- A kill at the generator's time, packed as Journal.lua stores them.
local function Kill(xp)
    local kills = G.char.kills
    local band = MOB_NAMES[math.min(#MOB_NAMES, floor(G.level / 10) + 1)]
    local name = band[random(#band)]
    local n = G.mobIndex[name]
    if not n then
        n = #kills.names + 1
        kills.names[n] = name
        G.mobIndex[name] = n
    end
    G.killBuf[#G.killBuf + 1] = ("%d,%d,%d;"):format(G.t - kills.last, xp, n)
    kills.last = G.t
end

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

-- The seeded party: { name, race, sex, class }.
local SEED_PARTY = {
    { "Brightmane", "Human", "Female", "PRIEST" }, { "Oakhorn", "Tauren", "Male", "DRUID" },
    { "Fizzlewick", "Gnome", "Female", "MAGE" },
}

local function Log(kind, ...)
    table.insert(G.char.events, { G.t, kind, G.c, round(G.x), round(G.y), ... })
end

-- An item's inventory slot and whether it takes both hands, from the client;
-- nil if the client does not know it (or offline tests).
local function SlotOf(itemID)
    ---@diagnostic disable-next-line: deprecated
    local info = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not info then return end
    local equipLoc = select(4, info(itemID))
    return EQUIP_SLOTS[equipLoc], equipLoc == "INVTYPE_2HWEAPON"
end

-- list ({ item ID, level }) with slots, in level order: { level, slot, id,
-- twoHand }. Items the client does not know are left out.
local function BuildGearPool(list)
    local pool = {}
    for _, entry in ipairs(list) do
        local slot, twoHand = SlotOf(entry[1])
        if slot then
            pool[#pool + 1] = { level = entry[2], slot = slot, id = entry[1], twoHand = twoHand }
        end
    end
    table.sort(pool, function(a, b) return a.level < b.level end)
    return pool
end

-- Wears an item, logged like Journal.lua's "eq" events unless silent.
local function Equip(slot, itemID, silent)
    G.gear[slot] = itemID ~= 0 and itemID or nil
    if not silent then
        Log("eq", slot, itemID)
    end
end

-- Wears an item in its own slot; a two-handed weapon empties the off hand.
local function EquipItem(itemID, silent)
    local slot, twoHand = SlotOf(itemID)
    if not slot then return end
    Equip(slot, itemID, silent)
    if twoHand and G.gear[OFF_HAND] then
        Equip(OFF_HAND, 0, silent)
    end
end

-- Puts on every pool item up to level not yet worn.
local function GearUpTo(level, silent)
    local pool = G.gearPool
    while G.gearNext <= #pool and pool[G.gearNext].level <= level do
        EquipItem(pool[G.gearNext].id, silent)
        G.gearNext = G.gearNext + 1
    end
end

local function CopyGear()
    local copy = {}
    for slot, id in pairs(G.gear) do
        copy[slot] = id
    end
    return copy
end

-- On reaching a level: skill ups for the professions known, then what
-- CRAFT_PLAN learns at this level, logged like Crafts.lua does.
local function LearnCrafts(level)
    local skills = G.char.skills
    for name, s in pairs(skills) do
        s[1] = math.min(s[2], s[1] + (CRAFT_RATE[name] or 5))
    end
    local plan = CRAFT_PLAN[level]
    if not plan then return end
    for _, p in ipairs(plan.learn or {}) do
        local name, rank, max = p[1], p[2], p[3]
        skills[name] = { math.max(rank, skills[name] and skills[name][1] or 0), max }
        Log("prof", name, rank, max)
    end
    for _, r in ipairs(plan.recipes or {}) do
        local known = G.char.recipes[r[3]] or {}
        known[r[1]] = true
        G.char.recipes[r[3]] = known
        Log("rec", r[1], r[2], r[3], r[4] and "t" or nil)
    end
end

local function CopySkills()
    local copy = {}
    for name, s in pairs(G.char.skills) do
        copy[name] = { s[1], s[2] }
    end
    return copy
end

local function Snapshot(level)
    local totals = G.char.totals
    G.char.levels[level] = {
        gear = CopyGear(),
        skills = CopySkills(),
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
        GearUpTo(G.level)
        LearnCrafts(G.level)
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
            Kill(G.level * 10 + 40)
        end
        if random() < QUEST_CHANCE then
            local xp = G.level * 60 + 100
            totals.quests = totals.quests + 1
            totals.questXP = totals.questXP + xp
            Log("qd", G.quest, xp, G.level * 50, QuestName(G.quest))
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
        gear = {}, gearNext = 1,
        killBuf = {}, mobIndex = {},
    }
    G.char.kills = { d = "", last = 0, names = {} }
    G.char.skills, G.char.recipes, G.char.people = {}, {}, {}
    for k, v in pairs(settings) do
        G[k] = v
    end
    G.gearPool = BuildGearPool(G.gearList or GEAR_POOL)
    GearUpTo(1, true)
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
        GearUpTo(G.level)
        LearnCrafts(G.level)
        Snapshot(G.level)
    end
    CloseSegment()
    Log("off")

    ns.char.kills.d = table.concat(G.killBuf)
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

-- Dungeons per faction, run once the character is at least level and, if
-- zone is set, questing in that route zone. Alliance runs happen at the real
-- entrance (map, x, y: uiMapID and map position), drop the real loot (worn
-- if better) and give the quest reward on the way back:
--   { level, zone, id = instanceID, name, map, x, y, loot = {...}, reward = {...} }
-- All item IDs, levels and slots checked in game with /rts itemcheck.
local DUNGEONS = {
    Alliance = {
        -- In Moonbrook, Westfall, while questing in Redridge. Smite's Mighty
        -- Hammer and Cape of the Brotherhood drop; the Defias Brotherhood
        -- finale gives Chausses of Westfall.
        { level = 19, zone = 1433, id = 36, name = "The Deadmines", map = 1436, x = 0.426, y = 0.720,
            loot = { 7230, 5193 }, reward = { 6087 } },
        -- In Stormwind City, from the Wetlands. Jimmied Handcuffs.
        { level = 24, zone = 1437, id = 34, name = "The Stockade", map = 1453, x = 0.405, y = 0.558,
            loot = { 3228 } },
        -- On the Zoram Strand, Ashenvale. Strike of the Hydra, Algae Fists,
        -- Tortoise Armor.
        { level = 28, zone = 1440, id = 48, name = "Blackfathom Deeps", map = 1440, x = 0.143, y = 0.139,
            loot = { 6909, 6906, 6907 } },
    },
    Horde = {
        { level = 15, id = 389, name = "Ragefire Chasm" }, { level = 19, id = 43, name = "Wailing Caverns" },
        { level = 23, id = 33, name = "Shadowfang Keep" }, { level = 26, id = 48, name = "Blackfathom Deeps" },
        { level = 29, id = 47, name = "Razorfen Kraul" },
    },
}

-- The realistic seed's gear: a human Arms warrior in mail, { item ID, level
-- it is put on }, besides the dungeon loot above. Starting kit, then world
-- drop greens and quest rewards, all checked in game (/rts survey and
-- /rts itemcheck). Weapons: Worn Shortsword and shield, Twin-bladed Axe,
-- Miner's Revenge (Loch Modan), then the dungeon two-handers.
local REALISTIC_GEAR = {
    { 38, 1 }, { 39, 1 }, { 40, 1 }, { 25, 1 }, { 2362, 1 },   -- Recruit's kit, Worn Shortsword and Shield
    { 18612, 5 },                   -- Bloody Chain Boots
    { 15479, 6 }, { 15477, 6 },     -- Charger's Armor and Pants
    { 15309, 10 },                  -- Feral Cloak
    { 15491, 10 }, { 15495, 10 },   -- Bloodspattered Gloves and Wristbands
    { 15268, 11 },                  -- Twin-bladed Axe
    { 15489, 11 },                  -- Bloodspattered Sabatons
    { 14725, 12 },                  -- War Paint Waistband
    { 6084, 14 },                   -- Stormwind Guard Leggings (Westfall quest)
    { 14167, 14 },                  -- Buccaneer's Cape
    { 1893, 16 },                   -- Miner's Revenge (Loch Modan quest)
    { 12985, 17 },                  -- Ring of Defense
    { 15517, 20 },                  -- Spiked Chain Wristbands
    { 14749, 21 }, { 15520, 21 },   -- Hulking Spaulders, Spiked Chain Gauntlets
    { 15525, 23 },                  -- Sentry's Slippers
    { 15518, 25 }, { 15539, 25 },   -- Spiked Chain Breastplate, Wicked Chain Waistband
    { 15533, 26 },                  -- Sentry's Headdress
    { 15544, 27 },                  -- Thick Scale Sabatons
    { 15542, 28 },                  -- Wicked Chain Shoulder Pads
    { 15540, 29 },                  -- Wicked Chain Helmet
}

-- Alliance flight masters, world positions from /rts survey: { continent, x, y }.
local FLIGHT_MASTERS = {
    { 0, -8833, 479 },      -- Stormwind
    { 0, -10629, 1037 },    -- Sentinel Hill, Westfall
    { 0, -9429, -2231 },    -- Lakeshire, Redridge
    { 0, -4822, -1155 },    -- Ironforge
    { 0, -3792, -783 },     -- Menethil Harbor, Wetlands
    { 0, -5422, -2930 },    -- Thelsamar, Loch Modan
    { 0, -10515, -1262 },   -- Darkshire, Duskwood
    { 0, -711, -515 },      -- Southshore, Hillsbrad
    { 0, -1241, -2515 },    -- Refuge Pointe, Arathi
    { 1, 6341, 558 },       -- Auberdine, Darkshore
    { 1, 8644, 841 },       -- Rut'theran Village, Teldrassil
    { 1, 2827, -289 },      -- Astranaar, Ashenvale
    { 1, 2681, 1462 },      -- Stonetalon Peak
    { 1, -3825, -4517 },    -- Theramore, Dustwallow Marsh
}

-- Boats between the continents, dock to dock as in Routes.lua's DOCKS:
-- { from continent, x, y, to continent, x, y }.
local BOATS = {
    { 0, -8550, 1450, 1, 6547, 944 },   -- Stormwind Harbor to Auberdine
    { 0, -3906, -584, 1, 6547, 944 },   -- Menethil Harbor to Auberdine
    { 1, 6547, 944, 0, -3906, -584 },   -- Auberdine to Menethil Harbor
}
local BOAT_SECONDS = 300

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
            Kill(G.level * 12 + 45)
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
        Log("qd", G.quest, xp, G.level * 60, QuestName(G.quest))
        G.quest = G.quest + 1
        Log("qa", G.quest)
    end
    if G.points - G.sessionStart >= SESSION_POINTS then
        NextSession()
        G.sessionStart = G.points
    end
end

-- Realistic travel --------------------------------------------------------------

-- The flight master (or boat) in list nearest (x, y) on continent c.
local function NearestIn(list, c, x, y)
    local best, bestD
    for _, entry in ipairs(list) do
        if entry[1] == c then
            local d = (entry[2] - x) ^ 2 + (entry[3] - y) ^ 2
            if not bestD or d < bestD then
                best, bestD = entry, d
            end
        end
    end
    return best
end

-- To (tx, ty) on this continent: a long trip walks to the nearest flight
-- master, flies to the one nearest the target and walks the rest; short
-- trips, and all trips before G.walkBelow, are on foot.
local function GoTo(tx, ty)
    local far = sqrt((tx - G.x) ^ 2 + (ty - G.y) ^ 2) > TAXI_DISTANCE
    if far and G.level >= (G.walkBelow or 0) then
        local from, to = NearestIn(FLIGHT_MASTERS, G.c, G.x, G.y), NearestIn(FLIGHT_MASTERS, G.c, tx, ty)
        if from and to and from ~= to then
            WalkTo(from[2], from[3], 18)
            OpenSegment("t")
            WalkTo(to[2], to[3], 60)
            OpenSegment("w")
        end
    end
    WalkTo(tx, ty, 18)
end

-- To (tx, ty) on continent c, taking the boat from the nearest dock first if
-- c is the other continent.
local function Journey(c, tx, ty)
    if c ~= G.c then
        local boat = NearestIn(BOATS, G.c, G.x, G.y)
        if boat then
            GoTo(boat[2], boat[3])
            G.t = G.t + BOAT_SECONDS
            G.c, G.x, G.y = boat[4], boat[5], boat[6]
        else
            G.c, G.x, G.y = c, tx, ty
        end
        OpenSegment("w", "b")
    end
    GoTo(tx, ty)
end

local function TravelToZone(zone, tx, ty)
    Journey(zone.c, tx, ty)
    Log("zone", zone.id)
end

-- Hearthstone back to the inn the character is bound to (G.home).
local function Hearth()
    if not G.home then return end
    G.t = G.t + 10
    G.c, G.x, G.y = G.home.c, G.home.x, G.home.y
    OpenSegment("w", "h")
end

-- One visit to an instance: to its entrance if known, an hour or two inside
-- (no path), its loot worn, a summary, then back to town by hearthstone,
-- where its quest rewards are handed out.
local function RunDungeon(dungeon)
    local instanceID, name = dungeon.id, dungeon.name
    if dungeon.map then
        local c, pos = C_Map.GetWorldPosFromMapPos(dungeon.map, CreateVector2D(dungeon.x, dungeon.y))
        if pos then
            Journey(c, pos.x, pos.y)
            Log("zone", dungeon.map)
        end
    end
    G.char.totals.instances = G.char.totals.instances + 1
    Log("in", instanceID, name, "party")
    local duration = random(60, 120) * 60
    G.t = G.t + floor(duration / 2)
    local items = {}
    if dungeon.loot then
        for _, itemID in ipairs(dungeon.loot) do
            local item = G.itemsById and G.itemsById[itemID]
            if item then
                Log("loot", item.link, item.quality, instanceID)
                items[#items + 1] = item.link
            end
            EquipItem(itemID)
        end
    else
        for _ = 1, random(1, 2) do
            items[#items + 1] = DropLoot(instanceID, random() < 0.6 and 3 or 2)
        end
    end
    -- Kills spread over the second half of the run.
    local kills, rest = random(40, 90), duration - floor(duration / 2)
    local runEnd = G.t + rest
    for i = 1, kills do
        G.t = runEnd - rest + floor(rest * i / kills)
        Kill(G.level * 12 + 45)
    end
    G.t = runEnd
    G.played = G.played + duration
    G.char.totals.kills = G.char.totals.kills + kills
    Log("out", instanceID, {
        name = name, duration = duration, kills = kills, xp = kills * (G.level * 12 + 45),
        deaths = random(0, 2), money = G.level * random(300, 700), levels = 0, items = items,
    })
    OpenSegment("w", "i")
    if dungeon.map then
        Hearth()
        for _, itemID in ipairs(dungeon.reward or {}) do
            EquipItem(itemID)
        end
    end
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
        gearList = REALISTIC_GEAR,
        itemsById = items.byId,
    })

    local dungeons, nextDungeon = DUNGEONS[faction] or DUNGEONS.Alliance, 1
    for i, zone in ipairs(zones) do
        if i > 1 then
            town = { RandomSpot(zone) }
            TravelToZone(zone, town[1], town[2])
            -- New to this continent: a hearthstone back across the sea to the
            -- last inn and a mage's portal back, so the map's sea lanes get
            -- trips both ways.
            if G.home and G.home.c ~= G.c then
                G.t = G.t + 1800
                Hearth()
                G.t = G.t + 600
                G.c, G.x, G.y = zone.c, town[1], town[2]
                OpenSegment("w", "p")
            end
        end
        -- Bound to this zone's inn, for the hearthstone after dungeons.
        G.home = { c = G.c, x = G.x, y = G.y }
        -- Joins a guild in the second town and is promoted in the third,
        -- logged like Guilds.lua does. No tabard: it shows the tabard item.
        if i == 2 then
            Log("gj", "Seeded Adventurers", "Initiate")
            G.char.guild = { "Seeded Adventurers", "Initiate", 4 }
            -- And forms a party, logged like Groups.lua does, that lasts
            -- until the next zone.
            local members = {}
            for k, d in ipairs(SEED_PARTY) do
                local guid = "Player-0-SEED000" .. k
                members[k] = { guid, d[1], d[2], d[3], d[4], G.level }
                G.char.people[guid] = {
                    name = d[1], race = d[2], sex = d[3], class = d[4], level = G.level,
                    first = G.t, last = G.t, c = G.c, x = round(G.x), y = round(G.y),
                    groups = 1, seconds = 0, dungeons = 0,
                }
            end
            Log("grp", "party", members, true)
            G.party = { t = G.t, kills = G.char.totals.kills, quests = G.char.totals.quests }
        elseif i == 3 and G.char.guild then
            Log("gr", "Seeded Adventurers", "Member", true)
            G.char.guild[2], G.char.guild[3] = "Member", 3
        end
        if i == 3 and G.party then
            local duration = G.t - G.party.t
            for _, p in pairs(G.char.people) do
                p.seconds, p.last = duration, G.t
            end
            Log("grpx", {
                duration = duration, kills = G.char.totals.kills - G.party.kills, xp = 0,
                quests = G.char.totals.quests - G.party.quests, deaths = 0, instances = 0, met = #SEED_PARTY,
            })
            G.party = nil
        end
        -- Quest from this zone's town until the level to move on.
        local leaveAt = ends[zone.leaveAt - 1] or REALISTIC_POINTS
        while G.points < leaveAt do
            local dungeon = dungeons[nextDungeon]
            if dungeon and G.level >= dungeon.level and (not dungeon.zone or dungeon.zone == zone.id) then
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

-- Asks the client for SEED_ITEMS and the dungeon loot, and calls done once
-- all have loaded, or after ITEM_LOAD_SECONDS with whatever has. done gets
-- SEED_ITEMS links by quality ({ [2] = {...}, [3] = ..., [4] = ... }) with
-- byId = { [itemID] = { link, quality } } for the dungeon loot.
local function LoadItems(done)
    ---@diagnostic disable-next-line: deprecated
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local exists = C_Item and C_Item.DoesItemExistByID
    -- Cached items can report loaded straight away, so finishing waits until
    -- every request is out.
    local waiting, finished, requesting = 0, false, true

    local loot = {}
    for _, list in pairs(DUNGEONS) do
        for _, dungeon in ipairs(list) do
            for _, id in ipairs(dungeon.loot or {}) do
                loot[#loot + 1] = id
            end
        end
    end
    local all = { unpack(SEED_ITEMS) }
    for _, id in ipairs(loot) do
        all[#all + 1] = id
    end

    local function Finish()
        if finished then return end
        finished = true
        local byQuality = { [2] = {}, [3] = {}, [4] = {}, byId = {} }
        for _, id in ipairs(SEED_ITEMS) do
            local _, link, quality = getInfo(id)
            if link and byQuality[quality] then
                table.insert(byQuality[quality], link)
            end
        end
        for _, id in ipairs(loot) do
            local _, link, quality = getInfo(id)
            if link then
                byQuality.byId[id] = { link = link, quality = quality }
            end
        end
        done(byQuality)
    end

    for _, id in ipairs(all) do
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
