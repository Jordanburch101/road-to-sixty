-- Offline test of Sources.lua with a fake WoW API. Run with LuaJIT from
-- apps/addon: luajit tests/sources_test.lua

local failures = 0
local function check(ok, message)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local handlers, timers, hooks = {}, {}, {}
local clock = 1000000
local ns = {
    char = {},
    Now = function() return clock end,
    Recorder = { Position = function() return 0, -8900, 500 end },
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
local function Settle()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

-- Fake game. Links as Forever writes them, with the player's level in field 9.
local now = 100
local game = { equipped = {}, bags = {}, loot = {}, trade = {}, mail = {}, merchant = {} }
local function Link(itemID, suffix)
    return ("|cff1eff00|Hitem:%d::::::%s::12:1491:::::::::|h[Item]|h|r"):format(itemID, suffix or "")
end
GetTime = function() return now end
GetInventoryItemLink = function(_, slot) return game.equipped[slot] end
C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 40 or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local link = bag == 0 and game.bags[slot]
        return link and { hyperlink = link, stackCount = 1 } or nil
    end,
}
C_Item = { GetItemInfoInstant = function(itemID)
    if itemID == 750 then return itemID, nil, nil, "" end       -- Tough Wolf Meat
    return itemID, nil, nil, "INVTYPE_CHEST"
end }
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
hooksecurefunc = function(name, fn) hooks[name] = fn end
BuyMerchantItem, TakeInboxItem = function() end, function() end
GetNumLootItems = function() return #game.loot end
GetLootSlotLink = function(slot) return game.loot[slot] and game.loot[slot][1] end
GetLootSourceInfo = function(slot) return game.loot[slot] and game.loot[slot][2] end
GetMerchantItemLink = function(index) return game.merchant[index] end
GetTradeTargetItemLink = function(slot) return game.trade[slot] end
GetInboxHeaderInfo = function(index) return nil, nil, game.mail[index].sender end
GetInboxInvoiceInfo = function(index) return game.mail[index].invoice end
GetInboxItemLink = function(index, item) return game.mail[index].items[item] end
local units = {}
UnitGUID = function(unit) return units[unit] and units[unit][2] end
UnitName = function(unit)
    if units[unit] then return units[unit][1], units[unit][3] end
end
LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %s.", "You receive loot: %sx%d."
LOOT_ROLL_YOU_WON = "You won: %s"
LOOT_ITEM_CREATED_SELF, LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %s.", "You create: %sx%d."

assert(loadfile("RoadToSixty/ChatPatterns.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Items.lua"))("RoadToSixty", ns)
assert(loadfile("RoadToSixty/Sources.lua"))("RoadToSixty", ns)
local Sources = ns.Sources

local free = 1
local function Arrive(link)
    game.bags[free], free = link, free + 1
    Fire("BAG_UPDATE_DELAYED")
    Settle()
end
local function Got(itemID, suffix)
    local notes = ns.char.got and ns.char.got[ns.ItemString(Link(itemID, suffix), true)]
    return notes and notes[#notes]
end

-- 1. The first read after login is the baseline: nothing is noted.
game.bags[1], free = Link(38), 2
Fire("BAG_UPDATE_DELAYED")
check(#timers == 0, "nothing is read before login")
Fire("PLAYER_LOGIN")
Settle()
check(ns.char.got == nil, "what is already carried at login is not noted")

-- 2. A drop: the loot window names the mob; things that can't be worn are left out.
game.loot = { { Link(1372), "Creature-0-6836-0-2-69-A66013D72E" }, { Link(750), "Creature-0-6836-0-2-69-A66013D72E" } }
Fire("LOOT_OPENED")
Fire("CHAT_MSG_LOOT", "You receive loot: " .. Link(1372) .. ".")
Arrive(Link(1372))
Arrive(Link(750))
Fire("LOOT_CLOSED")
local note = Got(1372)
check(note and note.how == "drop" and note.id == 69 and note.kind == "Creature", "a drop names the mob it came from")
check(note and note.t == clock and note.c == 0 and note.x == -8900, "with when and where")
check(Got(750) == nil, "items that can't be worn are not noted")

-- With auto loot the window closes before the loot message and the item
-- (as seen on Forever); the item still names its mob.
game.loot = { { Link(2652), "Creature-0-6836-0-2-6-0D97F7561A" } }
Fire("LOOT_OPENED", true)
Fire("LOOT_CLOSED")
Fire("CHAT_MSG_LOOT", "You receive loot: " .. Link(2652) .. ".")
Arrive(Link(2652))
note = Got(2652)
check(note and note.how == "drop" and note.id == 6, "with auto loot the drop still names its mob")

-- A mob seen as the target (or mouseover, or on a nameplate) is named;
-- a secret name (inside instances) is not kept.
units.target = { "Kobold Vermin", "Creature-0-6836-0-2-6-0D97F7561B" }
Fire("PLAYER_TARGET_CHANGED")
issecretvalue = function(v) return v == "Defias Secret" end
units.mouseover = { "Defias Secret", "Creature-0-6836-0-2-6-0D97F7561C" }
Fire("UPDATE_MOUSEOVER_UNIT")
game.loot = { { Link(2653), "Creature-0-6836-0-2-6-0D97F7561B" }, { Link(2654), "Creature-0-6836-0-2-6-0D97F7561C" } }
Fire("LOOT_OPENED", true)
Arrive(Link(2653))
Arrive(Link(2654))
Fire("LOOT_CLOSED")
check(Got(2653) and Got(2653).name == "Kobold Vermin" and Got(2653).id == 6, "a drop names the mob seen as the target")
check(Got(2654) and Got(2654).name == nil and Got(2654).id == 6, "a secret name is not kept, the ID is")
issecretvalue = nil   ---@diagnostic disable-line: assign-type-mismatch
units.target, units.mouseover = nil, nil

-- 3. A quest reward, with its quest.
Fire("QUEST_LOOT_RECEIVED", 33, Link(6070), 1)
Arrive(Link(6070))
note = Got(6070)
check(note and note.how == "quest" and note.id == 33, "a quest reward names its quest")

-- 4. Bought: the vendor's NPC ID and name.
units.npc = { "Brother Danil", "Creature-0-6836-0-2-152-0000000001" }
game.merchant[3] = Link(2488)
hooks.BuyMerchantItem(3, 1)
Arrive(Link(2488))
note = Got(2488)
check(note and note.how == "vendor" and note.id == 152 and note.name == "Brother Danil", "a purchase names the vendor")

-- 5. Traded: the other player, with the realm when it differs.
units.NPC = { "Tradefriend", "Player-1-0000000B", "Otherrealm" }
game.trade[2] = Link(5191)
Fire("TRADE_ACCEPT_UPDATE", 1, 1)
game.trade = {}
Fire("TRADE_CLOSED")
now = now + 1
Arrive(Link(5191))
note = Got(5191)
check(note and note.how == "trade" and note.name == "Tradefriend-Otherrealm", "a trade names the other player")

-- 6. Mail from a player, and an auction won.
game.mail[1] = { sender = "Mailfriend", items = { Link(10399) } }
game.mail[2] = { sender = "Stormwind Auction House", invoice = "buyer", items = { Link(10400) } }
hooks.TakeInboxItem(1, 1)
Arrive(Link(10399))
hooks.TakeInboxItem(2, 1)
Arrive(Link(10400))
check(Got(10399) and Got(10399).how == "mail" and Got(10399).name == "Mailfriend", "mail names the sender")
check(Got(10400) and Got(10400).how == "ah" and Got(10400).name == nil, "an auction won is from the auction house")

-- 7. Made, and won in a roll (whose loot message does not make it a drop).
Fire("CHAT_MSG_LOOT", "You create: " .. Link(2580) .. ".")
Arrive(Link(2580))
Fire("CHAT_MSG_LOOT", "You won: " .. Link(10401))
Fire("CHAT_MSG_LOOT", "You receive loot: " .. Link(10401) .. ".")
Arrive(Link(10401))
check(Got(2580) and Got(2580).how == "craft", "an item made is crafted")
check(Got(10401) and Got(10401).how == "roll", "an item won in a roll is a roll, not a drop")

-- 8. Loot with no window open is a master looter's drop; nothing at all is unknown.
Fire("CHAT_MSG_LOOT", "You receive loot: " .. Link(10402) .. ".")
Arrive(Link(10402))
check(Got(10402) and Got(10402).how == "drop" and Got(10402).id == nil, "loot without a window is a drop with no mob")
now = now + 60
Arrive(Link(10403))
check(Got(10403) and Got(10403).how == "?", "an item arriving with no signal is noted as unknown")

-- 9. Not new: equipping, a level up, the bank.
local before = 0
for _, notes in pairs(ns.char.got) do before = before + #notes end
game.equipped[5], game.bags[1] = game.bags[1], nil
Fire("PLAYER_EQUIPMENT_CHANGED", 5)
Settle()
for i, link in pairs(game.bags) do game.bags[i] = link:gsub("::12:1491", "::13:1491") end
Fire("BAG_UPDATE_DELAYED")
Settle()
Fire("BANKFRAME_OPENED")
Arrive(Link(10404))
Fire("BANKFRAME_CLOSED")
Settle()
local after = 0
for _, notes in pairs(ns.char.got) do after = after + #notes end
check(after == before, "equipping, a level up and the bank note nothing, got " .. (after - before))

-- 10. Putting an item on takes its newest note; a suffix is another item.
Arrive(Link(15210, "1017"))
check(Got(15210, "1017") and Got(15210) == nil, "a random suffix is noted as its own item")
local taken = Sources:Take(ns.ItemString(Link(6070), true))
check(taken and taken.how == "quest", "putting an item on takes its note")
check(Got(6070) == nil, "and the note is gone")
check(Sources:Take("item:99999") == nil, "an item with no note has no source")

-- 11. An item put on a moment after it arrived, before the queued read, still has its note.
game.loot = { { Link(10405), "GameObject-0-6836-0-2-1617-0000000001" } }
Fire("LOOT_OPENED")
game.bags[free], free = Link(10405), free + 1
Fire("BAG_UPDATE_DELAYED")     -- read queued, not yet run
taken = Sources:Take(ns.ItemString(Link(10405), true))
check(taken and taken.how == "drop" and taken.kind == "GameObject" and taken.id == 1617, "a chest's item put on at once")
Fire("LOOT_CLOSED")
Settle()

-- 12. Notes are kept within limits: per item, and none too old.
for _ = 1, 8 do Arrive(Link(38)) end
check(#ns.char.got[ns.ItemString(Link(38), true)] == 5, "at most five notes per item")
clock = clock + 31 * 86400
Fire("PLAYER_LOGIN")
check(ns.char.got[ns.ItemString(Link(38), true)] == nil, "notes older than 30 days go at login")

if failures == 0 then
    print("Sources tests passed.")
else
    print(failures .. " sources test(s) failed.")
    os.exit(1)
end
