local _, ns = ...

-- Replaces this character's journey with fake test data; /reload then saves
-- it. The fake data follows the real formats in Recorder.lua and Journal.lua.
--
--   /rts seed confirm                  a realistic 1-30: the levelling route for
--                                     the character's race, quest hubs, real
--                                     dungeons at their level, a normal pace
--   /rts seed stress confirm [points] [weeks]
--                                     a 1-60 through every zone at full size,
--                                     then weeks at 60 (raids, 5-man runs,
--                                     days in the endgame zones; 15 unless
--                                     given), to stress test the map, memory
--                                     use and SavedVariables size

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


-- The stress seed's starting kit: { item ID, level }. The rest of its gear
-- comes after the run, from PlanGear. The realistic seed has its own,
-- REALISTIC_GEAR.
local GEAR_POOL = {
    { 38, 1 }, { 39, 1 }, { 40, 1 }, { 25, 1 }, { 2362, 1 },
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

        -- At the cap nothing gives XP, so the message kills are counted from never comes.
        if not G.atCap and random() < KILL_CHANCE then
            totals.kills = totals.kills + 1
            totals.killXP = totals.killXP + G.level * 10 + 40
            Kill(G.level * 10 + 40)
        end
        if random() < QUEST_CHANCE then
            -- At the cap a quest gives gold in place of its XP.
            local xp = G.atCap and 0 or G.level * 60 + 100
            totals.quests = totals.quests + 1
            totals.questXP = totals.questXP + xp
            Log("qd", G.quest, xp, G.atCap and random(8000, 20000) or G.level * 50, QuestName(G.quest))
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
        if G.sessionLeft <= 0 and not G.atCap then
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
-- extra, if given, runs after the last log off, while the generator state is
-- still there.
local function Finish(maxLevel, started, label, extra)
    while G.level < maxLevel do
        G.level = G.level + 1
        Log("lvl", G.level)
        GearUpTo(G.level)
        LearnCrafts(G.level)
        Snapshot(G.level)
    end
    CloseSegment()
    Log("off")
    if extra then extra() end

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

-- Gear plan (stress seed) ------------------------------------------------------
-- After the 1-60 run: every slot upgraded every few levels with real items
-- from SeedGear.lua (scripts/seed-gear.py), put on at some point within a
-- level rather than all at the level up, got from a mix of places, with a
-- quick swap back and forth now and then (the noise "kept gear" hides) and
-- enchants from level 40; pre-raid gear at 59; then weeks of raiding at 60.
-- The level snapshots are rebuilt from it at the end (issue #64).

local ENDGAME_WEEKS = 15
-- Slots in the order they are planned, with the level each first gets an item.
local PLAN_SLOTS = {
    { 16, 2 }, { 17, 3 }, { 5, 2 }, { 7, 2 }, { 8, 2 }, { 9, 3 }, { 10, 4 }, { 6, 4 }, { 15, 5 },
    { 1, 8 }, { 3, 10 }, { 18, 6 }, { 2, 14 }, { 11, 11 }, { 12, 17 }, { 13, 28 }, { 14, 38 },
}
local POOL_OF = { [12] = 11, [14] = 13 }      -- the second ring and trinket share the first's list
local VENDORS = { "Brother Danil", "Corina Steele", "Gunther Weller", "Wilhelm Strang", "Thurman Grant", "Kurran Steele" }
local ENCHANTERS = { "Ellinor", "Glimmerbright", "Thistlewick" }   -- made up
-- Dungeon bosses by the level they drop for.
local BOSSES = {
    { 18, "Edwin VanCleef" }, { 22, "Wolf Master Nandos" }, { 26, "Mutanus the Devourer" }, { 30, "Herod" },
    { 34, "Arcanist Doan" }, { 40, "Archaedas" }, { 45, "Chief Ukorz Sandscalp" }, { 50, "Hakkar's Avatar" },
    { 54, "Emperor Dagran Thaurissan" }, { 57, "Overlord Wyrmthalak" }, { 58, "General Drakkisath" },
    { 59, "Baron Rivendare" }, { 60, "Darkmaster Gandling" },
}
-- { instance ID, name, first week, bosses }
local RAIDS = {
    { 409, "Molten Core", 1, { "Lucifron", "Magmadar", "Gehennas", "Garr", "Baron Geddon", "Shazzrah",
        "Golemagg the Incinerator", "Sulfuron Harbinger", "Majordomo Executus", "Ragnaros" } },
    { 249, "Onyxia's Lair", 2, { "Onyxia" } },
    { 469, "Blackwing Lair", 6, { "Razorgore the Untamed", "Vaelastrasz the Corrupt", "Broodlord Lashlayer",
        "Firemaw", "Ebonroc", "Flamegor", "Chromaggus", "Nefarian" } },
}
local RAID_ITEM_LEVEL = 66

local function PlanGear(char, weeks)
    local pool = ns.SeedGear
    if not pool then return end
    local levelT = {}
    for level, snapshot in pairs(char.levels) do levelT[level] = snapshot.t end
    -- The time at a fraction of a level (23.4: 40% through level 23).
    local function TimeAt(f)
        local level = floor(f)
        local from = levelT[level]
        if not from then return nil end
        return from + (f - level) * ((levelT[level + 1] or from + 3600) - from)
    end
    local quests = {}
    for _, e in ipairs(char.events) do
        if e[2] == "qd" then quests[#quests + 1] = { e[1], e[6] } end
    end

    local added = {}
    local worn = {}
    for slot, id in pairs(char.levels[1] and char.levels[1].gear or {}) do worn[slot] = { id = id, ilvl = 5 } end
    local taken = {}

    -- A random item of quality q in list, needing a level from lo to hi, better than above.
    local function Pick(list, lo, hi, q, above, used, minLevel)
        local found = {}
        for _, e in ipairs(list) do
            if e[2] >= lo and e[2] <= hi and e[3] == q and e[4] > above and e[4] >= (minLevel or 0) and not used[e[1]] then
                found[#found + 1] = e
            end
        end
        return found[1] and found[random(#found)]
    end
    local function Quality(level)
        local r = random()
        if level < 10 then return r < 0.7 and 1 or 2 end
        if level < 40 then return r < 0.15 and 1 or r < 0.8 and 2 or 3 end
        if level < 57 then return r < 0.5 and 2 or r < 0.95 and 3 or 4 end
        return r < 0.15 and 2 or r < 0.75 and 3 or 4
    end
    local function Quest(t)
        local id
        for _, q in ipairs(quests) do
            if q[1] > t then break end
            id = q[2]
        end
        return { how = "quest", id = id }
    end
    local function Boss(level)
        local name = BOSSES[1][2]
        for _, b in ipairs(BOSSES) do
            if b[1] <= level + 2 then name = b[2] end
        end
        return { how = random() < 0.3 and "roll" or "drop", kind = "Creature", name = name, id = random(1000, 12000) }
    end
    local function Source(level, q, t)
        local r, s = random(), nil
        if q <= 1 then
            s = r < 0.5 and { how = "vendor", name = VENDORS[random(#VENDORS)], id = random(200, 2000) } or Quest(t)
        elseif q == 2 then
            local band = MOB_NAMES[math.min(#MOB_NAMES, floor(level / 10) + 1)]
            s = r < 0.5 and { how = "drop", kind = "Creature", name = band[random(#band)], id = random(100, 12000) }
                or r < 0.9 and Quest(t) or { how = "ah" }
        elseif q == 3 then
            s = r < 0.55 and Boss(level) or r < 0.8 and Quest(t) or r < 0.92 and { how = "ah" } or { how = "craft" }
        else
            s = r < 0.4 and { how = "ah" } or r < 0.8 and Boss(level) or { how = "craft" }
        end
        s.t, s.c, s.x, s.y = t - random(60, 1800), -1, 0, 0
        return s
    end
    -- Puts entry on in slot at t, enchanted first if enchant; returns what it replaced.
    local function Put(t, slot, entry, source, enchant)
        local item = "item:" .. entry[1] .. (enchant and (":" .. enchant) or "")
        if enchant then
            local by = random() < 0.3 and "self" or ENCHANTERS[random(#ENCHANTERS)]
            added[#added + 1] = { t - random(300, 3000), "ench", -1, 0, 0, entry[1], enchant, 0, 0, by }
        end
        added[#added + 1] = { t, "eq", -1, 0, 0, slot, entry[1], item, nil, source }
        local before = worn[slot]
        worn[slot] = { id = entry[1], ilvl = entry[4], item = item }
        return before
    end
    local function Enchant(slot, chance)
        local list = pool.enchants[slot]
        return list and random() < chance and list[random(#list)] or nil
    end

    -- Levelling: each slot every few levels (weapons more often), then pre-raid gear at 59.
    for _, planned in ipairs(PLAN_SLOTS) do
        local slot, level = planned[1], planned[2]
        local key = POOL_OF[slot] or slot
        local list = pool.slots[key]
        taken[key] = taken[key] or {}
        while list and level < 60 do
            local above = worn[slot] and worn[slot].ilvl or 0
            local entry = Pick(list, level - 6, level, Quality(level), above, taken[key])
                or Pick(list, level - 6, level, 2, above, taken[key]) or Pick(list, level - 10, level, 1, above, taken[key])
            local t = entry and TimeAt(level + random())
            if t then
                taken[key][entry[1]] = true
                local before = Put(t, slot, entry, Source(level, entry[3], t), level >= 40 and Enchant(slot, 0.35))
                if before and before.item and random() < 0.08 then
                    -- Swapped back for a moment, then on again.
                    added[#added + 1] = { t + 90, "eq", -1, 0, 0, slot, before.id, before.item }
                    added[#added + 1] = { t + 200, "eq", -1, 0, 0, slot, entry[1], worn[slot].item }
                end
            end
            level = level + (slot == 16 and random(2, 5) or random(3, 8))
        end
        local above = worn[slot] and worn[slot].ilvl or 0
        local entry = list and random() < 0.7 and (Pick(list, 55, 60, 4, above, taken[key]) or Pick(list, 55, 60, 3, above, taken[key]))
        local t = TimeAt(59 + random())
        if entry and t and entry[4] < RAID_ITEM_LEVEL then
            taken[key][entry[1]] = true
            Put(t, slot, entry, Source(59, entry[3], t), Enchant(slot, 0.6))
        end
    end

    -- Raiding at 60: a night per raid each week from its first week, an epic or two from it.
    local capAt = levelT[60]
    for week = 1, capAt and weeks or 0 do
        for _, raid in ipairs(RAIDS) do
            if week >= raid[3] then
                local t = capAt + (week - 1) * 7 * 86400 + random(1, 5) * 86400 + 19 * 3600
                added[#added + 1] = { t, "on", -1, 0, 0, 60 }
                added[#added + 1] = { t + 600, "in", -1, 0, 0, raid[1], raid[2], "raid" }
                local wipes = random(0, 3)
                for wipe = 1, wipes do
                    added[#added + 1] = { t + 600 + wipe * random(1800, 3000), "die", -1, 0, 0, raid[4][random(#raid[4])] }
                end
                if char.totals then char.totals.deaths = char.totals.deaths + wipes end
                local items = {}
                for drop = 1, random(0, 2) do
                    local planned = PLAN_SLOTS[random(#PLAN_SLOTS)]
                    local slot = planned[1]
                    local key = POOL_OF[slot] or slot
                    local list = pool.slots[key]
                    local above = worn[slot] and worn[slot].ilvl or 0
                    local entry = list and Pick(list, 60, 60, 4, above, taken[key], RAID_ITEM_LEVEL)
                    if entry then
                        taken[key][entry[1]] = true
                        local at = t + 1200 + drop * random(1800, 4000)
                        local boss = raid[4][random(#raid[4])]
                        local source = { how = random() < 0.4 and "roll" or "drop", kind = "Creature", name = boss,
                            id = random(10000, 15000), instance = raid[1], t = at - 120, c = -1, x = 0, y = 0 }
                        Put(at, slot, entry, source, Enchant(slot, 0.5))
                        -- The run's summary lists links, as History shows them.
                        local link = GetItemInfo and select(2, GetItemInfo(entry[1]))
                        items[#items + 1] = link or ("item:" .. entry[1])
                    end
                end
                local duration = 4 * 3600 - 900
                added[#added + 1] = { t + 600 + duration, "out", -1, 0, 0, raid[1], {
                    name = raid[2], type = "raid", duration = duration, kills = random(80, 160), xp = 0,
                    deaths = wipes, money = random(20, 60) * 10000, levels = 0, items = items,
                } }
                added[#added + 1] = { t + 4 * 3600, "off", -1, 0, 0 }
                if G then G.played = G.played + 4 * 3600 end
            end
        end
    end

    -- Each new event where the path was at its time, then all in time order.
    local events = char.events
    local known = {}
    for _, e in ipairs(events) do
        if e[3] ~= -1 then known[#known + 1] = e end
    end
    for _, e in ipairs(added) do
        local lo, hi = 1, #known
        while lo < hi do
            local mid = floor((lo + hi + 1) / 2)
            if known[mid][1] <= e[1] then lo = mid else hi = mid - 1 end
        end
        local at = known[lo]
        if at then e[3], e[4], e[5] = at[3], at[4], at[5] end
        events[#events + 1] = e
    end
    for i, e in ipairs(events) do e.order = i end
    table.sort(events, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a.order < b.order
    end)
    for _, e in ipairs(events) do e.order = nil end

    -- Snapshots: the gear worn at each, from the kit and the events before it.
    local gear, links = {}, {}
    for slot, id in pairs(char.levels[1] and char.levels[1].gear or {}) do gear[slot], links[slot] = id, "item:" .. id end
    local order = {}
    for level in pairs(char.levels) do order[#order + 1] = level end
    table.sort(order)
    local next = 1
    for _, level in ipairs(order) do
        local snapshot = char.levels[level]
        while events[next] and events[next][1] <= snapshot.t do
            local e = events[next]
            if e[2] == "eq" then
                gear[e[6]] = e[7] ~= 0 and e[7] or nil
                links[e[6]] = e[7] ~= 0 and e[8] or nil
            end
            next = next + 1
        end
        snapshot.gear, snapshot.links = CopyTable(gear), CopyTable(links)
    end
    while events[next] do
        local e = events[next]
        if e[2] == "eq" then gear[e[6]] = e[7] ~= 0 and e[7] or nil end
        next = next + 1
    end
    char.gear = gear
end
ns.SeedPlanGear = PlanGear     -- for tests/seed_test.lua

-- Endgame (stress seed) ---------------------------------------------------------
-- After reaching 60: two or three days a week in the endgame zones, each a
-- morning's session so it never meets the evening raid nights PlanGear
-- adds: wandering (quests for gold, deaths, loot, now and then a vein),
-- a 5-man run now and then, and reputation with the endgame factions
-- climbing over the weeks. No kills, as at the cap nothing gives XP.

local ENDGAME_ZONES = { [1452] = true, [1423] = true, [1422] = true, [1428] = true, [1451] = true, [1448] = true }
-- { instance ID, name, a boss }
local ENDGAME_DUNGEONS = {
    { 329, "Stratholme", "Baron Rivendare" }, { 289, "Scholomance", "Darkmaster Gandling" },
    { 229, "Blackrock Spire", "General Drakkisath" }, { 230, "Blackrock Depths", "Emperor Dagran Thaurissan" },
    { 429, "Dire Maul", "Immol'thar" },
}
-- { faction ID, name, { week reached, standing }, ... }
local ENDGAME_REPS = {
    { 529, "Argent Dawn", { 1, 6 }, { 5, 7 }, { 12, 8 } },
    { 576, "Timbermaw Hold", { 2, 5 }, { 7, 6 } },
    { 749, "Hydraxian Waterlords", { 3, 5 }, { 9, 6 } },
}
local THORIUM_ORE = 10620

local function EndgameDungeon()
    local d = ENDGAME_DUNGEONS[random(#ENDGAME_DUNGEONS)]
    G.char.totals.instances = G.char.totals.instances + 1
    Log("in", d[1], d[2], "party")
    local duration, deaths, items = random(50, 110) * 60, random(0, 2), {}
    for _ = 1, deaths do
        G.t = G.t + floor(duration / (deaths + 2))
        G.char.totals.deaths = G.char.totals.deaths + 1
        Log("die", d[3])
    end
    for _ = 1, random(1, 2) do items[#items + 1] = DropLoot(d[1], 3) end
    G.t = G.t + floor(duration / (deaths + 2))
    G.played = G.played + duration
    Log("out", d[1], {
        name = d[2], type = "party", duration = duration, kills = random(60, 140), xp = 0, deaths = deaths,
        money = random(2, 6) * 10000, levels = 0, items = items,
    })
    OpenSegment("w", "i")
end

local function SeedEndgame(route, weeks)
    -- Reach the cap first, if the points fell short of it.
    while G.level < 60 do
        G.level = G.level + 1
        Log("lvl", G.level)
        GearUpTo(G.level)
        LearnCrafts(G.level)
        Snapshot(G.level)
    end
    G.atCap = true
    local capAt = G.char.levels[60].t
    local zones = {}
    for _, zone in ipairs(route) do
        if ENDGAME_ZONES[zone.id] then zones[#zones + 1] = zone end
    end
    if #zones == 0 then
        for k = math.max(1, #route - 2), #route do zones[#zones + 1] = route[k] end
    end
    local reps = {}
    for week = 1, weeks do
        local days = { 0, 2, 4, 6 }
        for _ = 1, random(1, 2) do table.remove(days, random(#days)) end
        for k, day in ipairs(days) do
            -- A morning's session: hours 3 to 6 after the time of day the cap was reached.
            local start = capAt + (week - 1) * 7 * 86400 + day * 86400 + 3 * 3600 + random(0, 3600)
            if start <= G.t or start > time() - 3600 then break end
            Log("off")
            G.t = start
            Log("on", 60)
            OpenSegment(G.cur and G.cur.mode or "w", "l")
            if k == 1 then
                for _, rep in ipairs(ENDGAME_REPS) do
                    for step = 3, #rep do
                        local reached = rep[step]
                        if reached[1] == week then
                            Log("rep", rep[1], reached[2], rep[2], true)
                            reps[rep[1]] = { reached[2], rep[2] }
                        end
                    end
                end
            end
            local zone = zones[random(#zones)]
            TravelTo(zone, zone.x1 + random() * (zone.x2 - zone.x1), zone.y1 + random() * (zone.y2 - zone.y1))
            Wander(zone, random(700, 1400))
            if random() < 0.3 then
                for _ = 1, random(2, 6) do
                    G.t = G.t + random(60, 240)
                    Log("gath", "m", THORIUM_ORE, 175404, THORIUM_ORE .. ":" .. random(1, 3))
                end
            end
            if random() < 0.4 then EndgameDungeon() end
        end
    end
    G.char.reps = reps
end

-- items: links by quality, { [2] = {...}, [3] = {...}, [4] = {...} }.
-- weeks: how many weeks at 60 follow the levelling (ENDGAME_WEEKS if nil).
local function SeedStress(total, items, weeks)
    local route = BuildRoute()
    if not route or #route == 0 then
        ns.Print("Could not find any zones to walk. Go outside on a main continent and try again.")
        return
    end
    weeks = weeks or ENDGAME_WEEKS
    local started = debugprofilestop()
    local first = route[1]
    -- Far enough back that the weeks of raiding after 60 end before today.
    Begin(first, first.cx, first.cy, 45 + weeks * 7, items, { total = total })

    local perZone = floor(total * 0.9 / #route)
    for i, zone in ipairs(route) do
        if i > 1 then
            TravelTo(zone)
        end
        Wander(zone, perZone)
        MaybeDungeon()
    end
    SeedEndgame(route, weeks)
    Finish(60, started, ("stress 1-60 and %d weeks at 60"):format(weeks),
        function() PlanGear(G.char, weeks) end)
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
                    groups = { [ns.pc] = 1 },
                }
            end
            Log("grp", "party", members, true)
            G.party = { t = G.t, kills = G.char.totals.kills, quests = G.char.totals.quests }
        elseif i == 3 and G.char.guild then
            Log("gr", "Seeded Adventurers", "Member", true)
            G.char.guild[2], G.char.guild[3] = "Member", 3
        end
        -- The home city's standing rises in the second and fourth towns,
        -- logged like Reputation.lua does.
        if i == 2 or i == 4 then
            local id, name = 72, "Stormwind"
            if faction == "Horde" then id, name = 76, "Orgrimmar" end
            local standing = i == 2 and 6 or 7
            Log("rep", id, standing, name, true)
            G.char.reps = { [id] = { standing, name } }
        end
        -- A rare killed in the third town, logged like Rares.lua does.
        if i == 3 then
            Log("rare", "Seeded Dreadmaw", "rareelite", G.level + 2)
            G.char.rares = { ["Seeded Dreadmaw"] = { { [ns.pc] = 1 }, G.t, "Seeded Dreadmaw", nil, "rareelite" } }
        end
        -- Riding and a mount in the fourth town, logged like Mounts.lua does:
        -- far below level 40, so the short seed shows them.
        if i == 4 then
            local mount, spellID = "Brown Horse", 458
            if faction == "Horde" then mount, spellID = "Timber Wolf", 580 end
            Log("ride", 33388, "Apprentice Riding")
            G.t = G.t + 60
            Log("mount", nil, mount, spellID, "n")
            G.char.riding = { [33388] = { "Apprentice Riding", G.t, G.level } }
        end
        if i == 3 and G.party then
            local duration = G.t - G.party.t
            for _, p in pairs(G.char.people) do
                p.seconds, p.last = { [ns.pc] = duration }, G.t
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
    local confirm, count, weeks = arg:gsub("^stress%s+", ""):match("^(%S*)%s*(%d*)%s*(%d*)$")
    if confirm ~= "confirm" then
        ns.Print("This ERASES this character's journey and fills it with fake test data.")
        ns.Print("Type /rts seed confirm for a realistic 1-30 levelling journey.")
        ns.Print(("Type /rts seed stress confirm [points] [weeks] for a full-size 1-60 stress test and weeks at 60."
            .. " Default %d points, %d weeks."):format(DEFAULT_POINTS, ENDGAME_WEEKS))
        return
    end
    ns.Print("Loading item data for fake loot...")
    LoadItems(function(items)
        ns.Print(("Items for loot: %d green, %d blue, %d epic."):format(#items[2], #items[3], #items[4]))
        if stress then
            SeedStress(tonumber(count) or DEFAULT_POINTS, items, tonumber(weeks))
        else
            SeedRealistic(items)
        end
    end)
end)

-- /rts seedalt [count]: made-up characters in the roster (one, or up to
-- four), each with only its level snapshots, so the Stats screen has
-- someone to compare with (#83). /rts seedalt remove takes them all out
-- again. No character's own journey changes.
local SEED_ALTS = {
    { "Seedalt", "MAGE", 41, 1 },
    { "Seedbeta", "PRIEST", 24, 1.25 },
    { "Seedgamma", "HUNTER", 52, 0.8 },
    { "Seeddelta", "ROGUE", 60, 1 },
}

-- A made-up journey of level snapshots up to top, pace times a normal one's.
-- Each level takes longer than the last, as a real journey's do, with three
-- times as long logged out as played between them. Snapshots carry every
-- running total a real one has (Journal.lua), as the side panel subtracts them.
local function SeedAltJourney(top, pace, startT)
    local levels, played, t = {}, 0, startT
    local totals = { kills = 0, killXP = 0, questXP = 0, deaths = 0, quests = 0, instances = 0, distance = 0, flown = 0 }
    for level = 1, top do
        levels[level] = {
            t = t, played = math.floor(played), money = level * level * 2000, kills = totals.kills,
            killXP = totals.killXP, questXP = totals.questXP, deaths = totals.deaths, quests = totals.quests,
            instances = totals.instances, distance = math.floor(totals.distance), flown = math.floor(totals.flown),
        }
        local seconds = (0.08 + 0.0016 * level * level) * 3600 * (0.8 + 0.4 * math.random()) * pace
        local hours = seconds / 3600
        local xp = (40 * level * level + 360 * level) * (level >= 30 and 1.3 or 1)
        totals.kills = totals.kills + math.floor(hours * (40 - level * 0.25))
        totals.killXP = totals.killXP + math.floor(xp * 0.4)
        totals.questXP = totals.questXP + math.floor(xp * 0.6)
        totals.quests = totals.quests + math.floor(hours * 3) + 1
        totals.deaths = totals.deaths + (math.random() < 0.4 and 1 or 0)
        totals.instances = totals.instances + (level % 7 == 0 and 1 or 0)
        totals.distance = totals.distance + hours * 1500
        totals.flown = totals.flown + (level >= 20 and hours * 600 or 0)
        played, t = played + seconds, t + math.floor(seconds * 4)
    end
    totals.distance, totals.flown = math.floor(totals.distance), math.floor(totals.flown)
    return {
        seeded = true, levels = levels, events = {}, segments = {}, people = {}, recipes = {},
        kills = { d = "", last = 0, names = {} }, played = math.floor(played), totals = totals,
    }, t
end

ns.Command("seedalt", "add made-up characters to compare with on the Stats screen (developer)", function(arg)
    ns.db.roster = ns.db.roster or {}
    for _, alt in ipairs(SEED_ALTS) do ns.db.roster[alt[1] .. "-Seed"] = nil end
    if arg == "remove" then
        ns.Print("Removed the made-up characters.")
    else
        local count = math.max(1, math.min(#SEED_ALTS, tonumber(arg) or 1))
        local names = {}
        for k = 1, count do
            local alt = SEED_ALTS[k]
            local journey, seen = SeedAltJourney(alt[3], alt[4], ns.Now() - (40 + k * 5) * 86400)
            ns.db.roster[alt[1] .. "-Seed"] = {
                name = alt[1], realm = "Seed", class = alt[2], level = alt[3], seen = seen,
                played = journey.played, journey = journey,
            }
            names[#names + 1] = ("%s (level %d)"):format(alt[1], alt[3])
        end
        ns.Print(("Added %s to compare with on the Stats screen. /rts seedalt remove takes them out.")
            :format(table.concat(names, ", ")))
    end
    if ns.StatsScreen then ns.StatsScreen:Rebuild() end
end)
