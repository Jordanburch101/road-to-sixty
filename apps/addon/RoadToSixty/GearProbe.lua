local _, ns = ...

-- /rts gearprobe: what this client gives for gear, enchants and where items
-- come from, to choose how to record them (issue #62).
-- /rts gearprobe shows each equipped item's link fields (suffix, enchant,
-- unique ID) and item level, the temporary weapon enchants, and which APIs
-- and loot messages exist.
-- /rts gearprobe watch prints, until watch again or /reload: gear and bag
-- changes as links before and after (an enchant shows as a changed link),
-- quest loot, trades (both sides, the "will not be traded" slot, the
-- partner), vendor buys, mail taken, loot windows with their sources, rolls,
-- boss encounters, the player's spell casts, and every loot and system
-- message.
-- Every line is also kept in the account file (ns.db.gearProbe, newest
-- last), as the output is too long to screenshot: /reload writes it.
-- /rts gearprobe clear empties it. The report goes to the file only.

local MAX_LINES = 5000
local quiet = false     -- true while the report runs: file only, not chat

local function P(msg)
    local log = ns.db.gearProbe or {}
    ns.db.gearProbe = log
    log[#log + 1] = date("%H:%M:%S ") .. msg
    if #log > MAX_LINES then table.remove(log, 1) end
    if not quiet then ns.Print(msg) end
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

-- Any value as text: secret values named, tables listed, links shown as text.
local function Show(v)
    if IsSecret(v) then return "<secret>" end
    if type(v) == "table" then
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. Show(x) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    if type(v) == "string" then return (v:gsub("|", "||")) end
    return tostring(v)
end

local function Has(t, names)
    local list = {}
    for _, name in ipairs(names) do
        list[#list + 1] = ("%s %s"):format(name, t and t[name] and "yes" or "no")
    end
    return table.concat(list, ", ")
end

-- "item:..." from a link, or nil.
local function ItemString(link)
    if type(link) ~= "string" or IsSecret(link) then return nil end
    return link:match("|H(item:[^|]+)|h") or link:match("item:[%-%d:]+")
end

-- A link as itself (clickable in chat) followed by its item string.
local function Link(link)
    if not link then return "none" end
    if IsSecret(link) then return "<secret>" end
    return ("%s %s"):format(link, ItemString(link) or "(no item string)")
end

-- Named fields of an item string, classic order.
local FIELDS = { "id", "enchant", "gem1", "gem2", "gem3", "gem4", "suffix", "unique", "linkLevel", "spec",
    "modifiers", "context" }

local function Fields(link)
    local s = ItemString(link)
    if not s then return "no item string" end
    local values, parts = {}, {}
    for v in (s:sub(6) .. ":"):gmatch("([^:]*):") do values[#values + 1] = v end
    for i, name in ipairs(FIELDS) do
        local v = values[i]
        if v and v ~= "" and v ~= "0" then parts[#parts + 1] = name .. " " .. v end
    end
    if #values > #FIELDS then
        parts[#parts + 1] = "rest " .. table.concat(values, ":", #FIELDS + 1)
    end
    return table.concat(parts, ", ")
end

local function ItemLevel(link)
    ---@diagnostic disable-next-line: deprecated
    local get = C_Item and C_Item.GetDetailedItemLevelInfo or _G.GetDetailedItemLevelInfo
    if not (get and link) then return nil end
    local ok, level = pcall(get, link)
    return ok and level or nil
end

local MESSAGES = {
    "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
    "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ROLL_WON", "LOOT_ROLL_YOU_WON",
    "ERR_TRADE_COMPLETE", "ERR_QUEST_REWARD_ITEM_S",
}

local function Report()
    local shown = 0
    for _, name in ipairs(ns.GEAR_SLOTS) do
        local ok, slot = pcall(GetInventorySlotInfo, name)
        local link = ok and slot and GetInventoryItemLink("player", slot)
        if link then
            P(("%s %d: %s, ilvl %s, %s"):format(name, slot, link, tostring(ItemLevel(link)), Fields(link)))
            P("  " .. (ItemString(link) or "no item string"))
            shown = shown + 1
        end
    end
    if shown == 0 then P("Nothing equipped.") end
    if GetWeaponEnchantInfo then
        P("GetWeaponEnchantInfo: " .. Show({ GetWeaponEnchantInfo() }))
    end
    P("APIs: " .. Has(_G, { "GetTradePlayerItemLink", "GetTradeTargetItemLink", "GetTradePlayerItemInfo",
        "GetTradeTargetItemInfo", "GetInboxHeaderInfo", "GetInboxItemLink", "GetInboxInvoiceInfo", "TakeInboxItem",
        "AutoLootMailItem", "BuyMerchantItem", "GetMerchantItemLink", "GetMerchantItemCostInfo", "GetLootSourceInfo",
        "GetLootRollItemLink", "GetWeaponEnchantInfo", "GetDetailedItemLevelInfo" }))
    P("C_Item: " .. Has(C_Item, { "GetDetailedItemLevelInfo", "GetCurrentItemLevel", "GetItemInfoInstant", "GetItemLink" }))
    for _, name in ipairs(MESSAGES) do
        P(("%s: %s"):format(name, Show(_G[name])))
    end
end

-- Watching -----------------------------------------------------------------------

local watching = false
local registered = nil      -- event -> whether the client accepted it
local gear, bags = {}, {}   -- last seen: slot -> link, link -> count
local tradeUntil = 0        -- UI messages are shown until this time (a trade is open or just closed)
local IGNORED_SPELLS = { [75] = true, [5019] = true, [6603] = true }   -- Auto Shot, Shoot, Attack

local function ScanGear()
    local now = {}
    for slot = 1, 19 do
        now[slot] = GetInventoryItemLink("player", slot)
    end
    return now
end

local function ScanBags()
    local now = {}
    local c = C_Container
    if not (c and c.GetContainerNumSlots and c.GetContainerItemInfo) then return now end
    for bag = 0, 4 do
        for slot = 1, c.GetContainerNumSlots(bag) do
            local info = c.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink then
                now[info.hyperlink] = (now[info.hyperlink] or 0) + (info.stackCount or 1)
            end
        end
    end
    return now
end

local function DiffGear(why)
    local now = ScanGear()
    for slot = 1, 19 do
        if now[slot] ~= gear[slot] then
            P(("Gear slot %d (%s): %s -> %s"):format(slot, why, Link(gear[slot]), Link(now[slot])))
        end
    end
    gear = now
end

local function DiffBags(why)
    local now = ScanBags()
    for link, count in pairs(now) do
        local before = bags[link] or 0
        if count > before then P(("Bag +%d (%s): %s"):format(count - before, why, Link(link))) end
    end
    for link, count in pairs(bags) do
        local after = now[link] or 0
        if after < count then P(("Bag -%d (%s): %s"):format(count - after, why, Link(link))) end
    end
    bags = now
end

-- Both sides of an open trade; slot 7 is "will not be traded" (enchanting).
local function TradeSides()
    local unitName = UnitName("NPC")
    P(("Trade partner: %s, guid %s"):format(Show(unitName), Show(UnitGUID("NPC"))))
    for slot = 1, 7 do
        local mine = GetTradePlayerItemLink and GetTradePlayerItemLink(slot)
        local theirs = GetTradeTargetItemLink and GetTradeTargetItemLink(slot)
        if mine then
            P(("  mine %d: %s, info %s"):format(slot, Link(mine), Show({ GetTradePlayerItemInfo(slot) })))
        end
        if theirs then
            P(("  theirs %d: %s, info %s"):format(slot, Link(theirs), Show({ GetTradeTargetItemInfo(slot) })))
        end
    end
end

local function LootWindow()
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local sources = { pcall(GetLootSourceInfo, slot) }
        table.remove(sources, 1)
        P(("Loot %d: %s, sources %s"):format(slot, Link(link), Show(sources)))
    end
end

local function MailItems(index)
    if not GetInboxHeaderInfo then return end
    P(("Mail %d header: %s"):format(index, Show({ GetInboxHeaderInfo(index) })))
    if GetInboxInvoiceInfo then
        P(("Mail %d invoice: %s"):format(index, Show({ GetInboxInvoiceInfo(index) })))
    end
    for i = 1, 16 do
        local link = GetInboxItemLink and GetInboxItemLink(index, i)
        if link then P(("Mail %d item %d: %s"):format(index, i, Link(link))) end
    end
end

-- event -> handler; nil prints the event and its arguments.
local HANDLERS = {
    PLAYER_EQUIPMENT_CHANGED = function(...)
        P("PLAYER_EQUIPMENT_CHANGED " .. Show({ ... }))
        DiffGear("PLAYER_EQUIPMENT_CHANGED")
    end,
    UNIT_INVENTORY_CHANGED = function(unit)
        if unit == "player" then DiffGear("UNIT_INVENTORY_CHANGED") end
    end,
    BAG_UPDATE_DELAYED = function()
        DiffBags("BAG_UPDATE_DELAYED")
        DiffGear("BAG_UPDATE_DELAYED")
    end,
    ITEM_PUSH = false,
    QUEST_LOOT_RECEIVED = false,
    QUEST_TURNED_IN = false,
    TRADE_SHOW = function()
        tradeUntil = math.huge
        P("TRADE_SHOW")
        TradeSides()
    end,
    TRADE_PLAYER_ITEM_CHANGED = false,
    TRADE_TARGET_ITEM_CHANGED = false,
    TRADE_ACCEPT_UPDATE = function(...)
        P("TRADE_ACCEPT_UPDATE " .. Show({ ... }))
        TradeSides()
    end,
    TRADE_REQUEST_CANCEL = false,
    TRADE_CLOSED = function()
        tradeUntil = GetTime() + 3
        P("TRADE_CLOSED")
    end,
    UI_INFO_MESSAGE = function(...)
        if GetTime() < tradeUntil then P("UI_INFO_MESSAGE " .. Show({ ... })) end
    end,
    MERCHANT_SHOW = false,
    MERCHANT_CLOSED = false,
    MAIL_SHOW = false,
    MAIL_CLOSED = false,
    LOOT_OPENED = function(...)
        P("LOOT_OPENED " .. Show({ ... }))
        LootWindow()
    end,
    START_LOOT_ROLL = function(rollID, ...)
        P(("START_LOOT_ROLL %s %s: %s"):format(Show(rollID), Show({ ... }),
            Link(GetLootRollItemLink and GetLootRollItemLink(rollID))))
    end,
    LOOT_ROLLS_COMPLETE = false,
    ENCOUNTER_START = false,
    ENCOUNTER_END = false,
    BOSS_KILL = false,
    UNIT_SPELLCAST_SUCCEEDED = function(unit, _, spellID)
        if unit ~= "player" or IGNORED_SPELLS[spellID] then return end
        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
        P(("Cast %s (%s)"):format(Show(name), Show(spellID)))
    end,
    CHAT_MSG_LOOT = function(msg) P("CHAT_MSG_LOOT " .. Show(msg)) end,
    CHAT_MSG_SYSTEM = function(msg) P("CHAT_MSG_SYSTEM " .. Show(msg)) end,
}

local function Hook(name, fn)
    if _G[name] then
        hooksecurefunc(name, function(...)
            if watching then ns.SafeCall(fn, ...) end
        end)
    end
end

local function Watch()
    if not registered then
        registered = {}
        for event, handler in pairs(HANDLERS) do
            registered[event] = ns.On(event, function(...)
                if not watching then return end
                if handler then
                    handler(...)
                else
                    P(event .. " " .. Show({ ... }))
                end
            end)
        end
        Hook("BuyMerchantItem", function(index, quantity)
            local merchant = C_MerchantFrame and C_MerchantFrame.GetItemInfo
            ---@diagnostic disable-next-line: deprecated
            local info = merchant and merchant(index) or { GetMerchantItemInfo(index) }
            P(("BuyMerchantItem %s x%s: %s, info %s"):format(Show(index), Show(quantity),
                Link(GetMerchantItemLink(index)), Show(info)))
            if GetMerchantItemCostInfo and GetMerchantItemCostInfo(index) > 0 then
                P("  currency cost: " .. Show({ GetMerchantItemCostItem(index, 1) }))
            end
        end)
        Hook("TakeInboxItem", function(index, item)
            P(("TakeInboxItem %s %s"):format(Show(index), Show(item)))
            MailItems(index)
        end)
        Hook("AutoLootMailItem", function(index)
            P(("AutoLootMailItem %s"):format(Show(index)))
            MailItems(index)
        end)
    end
    watching = not watching
    gear, bags = ScanGear(), ScanBags()
    local refused = {}
    for event, ok in pairs(registered) do
        if not ok then refused[#refused + 1] = event end
    end
    table.sort(refused)
    P(("Watching gear, bags, trades, loot and encounters %s.%s"):format(watching and "on" or "off",
        #refused > 0 and (" Refused by the client: " .. table.concat(refused, ", ")) or ""))
end

ns.Command("gearprobe", "check gear links and where items come from; watch to print the events (developer)", function(arg)
    if arg == "watch" then
        Watch()
    elseif arg == "clear" then
        ns.db.gearProbe = nil
        ns.Print("Gear probe log cleared.")
    else
        quiet = true
        ns.SafeCall(Report)
        quiet = false
        ns.Print(("Gear probe report saved (%d lines in the log). /reload to write it."):format(#(ns.db.gearProbe or {})))
    end
end)
