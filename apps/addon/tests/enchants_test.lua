-- Offline test of Enchants.lua with a fake WoW API. Run with LuaJIT from
-- apps/addon: luajit tests/enchants_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, timers, logged = {}, {}, {}
local ns = {
    Journal = { Log = function(_, ...) logged[#logged + 1] = { ... } end },
}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
function ns.SafeCall(fn, ...) return fn(...) end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end

-- Fake game: equipped links by slot, bag links by bag and slot.
local now = 100
local game = { equipped = {}, bags = { [0] = {} }, weapon = {}, trade = {}, partner = "Enchanter", partnerGUID = "Player-1-0000000A" }
local function Link(itemID, enchantID, level)
    -- The modern link, with the player's level in field 9 as on Forever.
    return ("|cff1eff00|Hitem:%d:%s:::::::%d:1491:::::::::|h[Item]|h|r"):format(itemID, enchantID and tostring(enchantID) or "",
        level or 10)
end
GetTime = function() return now end
GetInventoryItemLink = function(_, slot) return game.equipped[slot] end
C_Container = {
    GetContainerNumSlots = function(bag) return game.bags[bag] and 16 or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local link = game.bags[bag] and game.bags[bag][slot]
        return link and { hyperlink = link } or nil
    end,
}
C_Item = { GetItemInfoInstant = function(itemID)
    if itemID == 2589 then return itemID, nil, nil, "" end              -- Linen Cloth
    return itemID, nil, nil, "INVTYPE_WRIST"
end }
GetWeaponEnchantInfo = function() return unpack(game.weapon) end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
GetTradePlayerItemLink = function(slot) return game.trade[slot] and game.trade[slot].link end
GetTradePlayerItemInfo = function(slot)
    local t = game.trade[slot]
    if t then return "Item", 0, 1, 2, t.enchant, false, false, 1 end
end
UnitName = function(unit) if unit == "NPC" then return game.partner, game.realm end end
UnitGUID = function(unit) return unit == "NPC" and game.partnerGUID or nil end

local function Settle()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

assert(loadfile("RoadToSixty/Enchants.lua"))("RoadToSixty", ns)
local Enchants = ns.Enchants

-- 1. Reading links: item and enchant IDs, a blank enchant as 0.
local id, enchant = Enchants.Parse(Link(1370, nil))
check(id == 1370 and enchant == 0, "a link without an enchant reads as enchant 0")
id, enchant = Enchants.Parse(Link(1370, 41))
check(id == 1370 and enchant == 41, "the enchant ID is the field after the item ID")
check(Enchants.Parse("not a link") == nil and Enchants.Parse(nil) == nil, "anything else is not an item")

-- 2. Diff: a change is an item losing one enchant and gaining another.
local function D(before, after, temp) return Enchants.Diff(before, after, temp or {}) end
local changes = D({ ["1370:0"] = 1 }, { ["1370:41"] = 1 })
check(#changes == 1 and changes[1][1] == 1370 and changes[1][2] == 41 and changes[1][3] == 0, "an enchant put on an item")
check(#D({ ["1370:41"] = 1 }, { ["1370:66"] = 1 }) == 1, "an enchant replaced")
check(#D({}, { ["1370:41"] = 1 }) == 0, "an item turning up enchanted (loot, the bank) is not an enchant")
check(#D({ ["1370:41"] = 1 }, {}) == 0, "an item going away is not an enchant")
check(#D({ ["1370:41"] = 1 }, { ["1370:0"] = 1 }) == 0, "an enchant going away is left out")
check(#D({ ["1370:0"] = 1 }, { ["1370:41"] = 1 }, { [41] = true }) == 0, "a temporary enchant put on is left out")
check(#D({ ["1370:41"] = 1 }, { ["1370:66"] = 1 }, { [41] = true }) == 0, "a temporary enchant running out is left out")
changes = D({ ["1370:0"] = 2 }, { ["1370:0"] = 1, ["1370:41"] = 1 })
check(#changes == 1, "one of two copies enchanted is one change")
check(#D({ ["1370:0"] = 1, ["5000:0"] = 1 }, { ["5000:41"] = 1 }) == 1 and D({ ["1370:0"] = 1, ["5000:0"] = 1 }, { ["5000:41"] = 1 })[1][1] == 5000,
    "another item going away does not pair with the enchanted one")

-- 3. Nothing is read before login; the first read is the baseline.
game.bags[0][1] = Link(1370, nil)
game.equipped[9] = Link(3365, nil)
Fire("BAG_UPDATE_DELAYED")
check(#timers == 0, "nothing is read before login")
Fire("PLAYER_LOGIN")
Settle()
check(#logged == 0, "the first read logs nothing")

-- 4. Equipping and levelling change links but not enchants.
game.equipped[9], game.bags[0][1] = Link(1370, nil), Link(3365, nil)
Fire("PLAYER_EQUIPMENT_CHANGED", 9)
Fire("BAG_UPDATE_DELAYED")
Settle()
check(#timers == 0 and #logged == 0, "an item moving between bags and gear is not an enchant, and is read once")
game.equipped[9], game.bags[0][1] = Link(1370, nil, 11), Link(3365, nil, 11)
game.bags[0][2] = Link(2589, nil, 11)
Fire("BAG_UPDATE_DELAYED")
Settle()
check(#logged == 0, "a level up changing every link is not an enchant")

-- 5. Through the trade window: the partner's name, GUID and enchant text.
Fire("TRADE_SHOW")
game.trade[7] = { link = Link(3365, nil, 11), enchant = "Enchant Bracer - Minor Health" }
Fire("TRADE_PLAYER_ITEM_CHANGED", 7)
Fire("TRADE_ACCEPT_UPDATE", 1, 1)
game.trade = {}
Fire("TRADE_CLOSED")
now = now + 1
game.bags[0][1] = Link(3365, 41, 11)
Fire("BAG_UPDATE_DELAYED")
Settle()
local e = logged[1]
check(e and e[1] == "ench" and e[2] == 3365 and e[3] == 41 and e[4] == 0 and e[5] == 0,
    "an enchant from a trade is logged in the bags (slot 0)")
check(e and e[6] == "Enchanter" and e[7] == "Player-1-0000000A" and e[8] == nil and e[9] == "Enchant Bracer - Minor Health",
    "with who did it and the enchant's name from the trade window")

-- 6. The player's own enchanting on equipped gear: by self, with the spell.
now = now + 60
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 7418)
now = now + 1
game.equipped[9] = Link(1370, 66, 11)
Fire("UNIT_INVENTORY_CHANGED", "player")
Settle()
e = logged[2]
check(e and e[2] == 1370 and e[3] == 66 and e[4] == 0 and e[5] == 9, "an enchant on worn gear has its slot")
check(e and e[6] == "self" and e[8] == 7418, "the player's cast just before makes it their own")

-- 7. Long after any cast or trade, the cause is unknown.
now = now + 60
game.equipped[9] = Link(1370, 70, 11)
Fire("UNIT_INVENTORY_CHANGED", "player")
Settle()
e = logged[3]
check(e and e[3] == 70 and e[4] == 66 and e[6] == nil and e[8] == nil, "an enchant with no cause is logged without one")

-- 8. A temporary enchant on the weapon is left out, on and off.
game.equipped[16] = Link(25, nil, 11)
Fire("UNIT_INVENTORY_CHANGED", "player")
Settle()
game.weapon = { true, 1800000, 0, 2625 }
game.equipped[16] = Link(25, 2625, 11)
Fire("UNIT_INVENTORY_CHANGED", "player")
Settle()
game.weapon = {}
game.equipped[16] = Link(25, nil, 11)
Fire("UNIT_INVENTORY_CHANGED", "player")
Settle()
check(#logged == 3, "a weapon oil put on and running out logs nothing, got " .. #logged)

-- 9. A partner from another realm is named with it; a trade whose enchant
-- slot held another item does not name who enchanted this one.
game.realm = "Otherrealm"
Fire("TRADE_SHOW")
game.trade[7] = { link = Link(1370, 70, 11), enchant = "Enchant Bracer - Lesser Strength" }
Fire("TRADE_ACCEPT_UPDATE", 1, 1)
game.trade = {}
Fire("TRADE_CLOSED")
game.equipped[9], game.bags[0][3] = nil, Link(1370, 70, 11)
Fire("UNIT_INVENTORY_CHANGED", "player")
Settle()
game.bags[0][3] = Link(1370, 101, 11)
Fire("BAG_UPDATE_DELAYED")
Settle()
e = logged[4]
check(e and e[3] == 101 and e[6] == "Enchanter-Otherrealm", "a partner from another realm keeps the realm")
game.bags[0][1] = Link(3365, 66, 11)
Fire("BAG_UPDATE_DELAYED")
Settle()
e = logged[5]
check(e and e[2] == 3365 and e[6] == nil, "the trade names only the item that was in its enchant slot")

if failures == 0 then
    print("Enchants tests passed.")
else
    print(failures .. " enchants test(s) failed.")
    os.exit(1)
end
