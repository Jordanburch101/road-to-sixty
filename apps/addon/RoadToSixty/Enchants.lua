local _, ns = ...

-- Records permanent enchants put on gear (issue #62) as journal events:
--   ench  itemID, enchantID, oldEnchantID, slot, by, byGUID, spellID, text
--         an item's enchant changed to enchantID (oldEnchantID 0 when it
--         had none); slot is the equipment slot it is in, 0 in the bags.
--         by is "self", the trade partner's name (with the realm when it
--         differs) or nil when unknown, byGUID the partner's GUID; spellID
--         the player's own cast just before (an enchanting spell, or an
--         item such as an armour kit), text the enchant's name as the trade
--         window showed it.
--
-- Enchanting another player's item goes through the trade window: the item
-- sits in the "will not be traded" slot (7) and the enchant lands when the
-- trade completes, in the bags. So the bags and the equipped gear are read
-- together as counts of item ID and enchant ID, and an item whose enchant
-- changed is one that went from one enchant to another between two reads
-- (an item moving between bags and gear changes nothing). Items appearing
-- or going (loot, sales, the bank) have no matching change, so they are not
-- enchants. The item link's level field changes at every level up, so only
-- the item and enchant IDs are compared.
--
-- Temporary enchants (oils, stones, poisons) are not progress. Whether they
-- show in the link on Forever is not yet known, so a change to or from an
-- enchant GetWeaponEnchantInfo reports as temporary is left out, and so is
-- an enchant going away, which a permanent one never does on its own.
--
-- Not yet checked on Forever: which events fire when an enchant lands, the
-- trade window's enchant text, and whether temporary enchants show in the
-- link. /rts gearprobe watch shows all three.

local Enchants = {}
ns.Enchants = Enchants

local SCAN_DELAY = 0.3      -- seconds; bursts of bag and inventory events read once
local TRADE_WINDOW = 10     -- seconds after a trade closes that its enchant can land
local CAST_WINDOW = 3       -- seconds after the player's own cast that it counts as the cause
local TRADE_ENCHANT_SLOT = 7
local BAGS = 4              -- backpack is 0, then four bags

local Log = function(...) return ns.Journal:Log(...) end

local loggedIn = false
local counts                -- "itemID:enchantID" -> count, at the last read
local tempEnchants = {}     -- enchant IDs seen as temporary this session
local trade                 -- { itemID, text, name, guid, open, closedAt } the last trade's enchant slot
local cast                  -- { spellID, at } the player's last cast

-- "item:ID:enchant:..." -> item ID, enchant ID (0 for none); nil if not an item link.
function Enchants.Parse(link)
    if type(link) ~= "string" then return nil end
    local id, enchant = link:match("item:(%-?%d+):(%-?%d*)")
    if not id then return nil end
    return tonumber(id), tonumber(enchant) or 0
end

local function Equippable(itemID)
    ---@diagnostic disable-next-line: deprecated
    local info = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    if not info then return true end
    local equipLoc = select(4, info(itemID))
    return equipLoc ~= nil and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
end

local function Add(into, link)
    local itemID, enchantID = Enchants.Parse(link)
    if itemID and Equippable(itemID) then
        local key = itemID .. ":" .. enchantID
        into[key] = (into[key] or 0) + 1
    end
end

-- Counts of "itemID:enchantID" over the equipped gear and the bags.
local function Read()
    local now = {}
    for slot = 1, 19 do
        Add(now, GetInventoryItemLink("player", slot))
    end
    local bags = C_Container
    if bags and bags.GetContainerNumSlots and bags.GetContainerItemInfo then
        for bag = 0, BAGS do
            for slot = 1, bags.GetContainerNumSlots(bag) do
                local info = bags.GetContainerItemInfo(bag, slot)
                if info then Add(now, info.hyperlink) end
            end
        end
    end
    return now
end

-- Enchant changes between two reads: { itemID, enchantID, oldEnchantID }
-- for each item that lost one enchant and gained another. temp holds
-- enchant IDs that are temporary; changes to or from them are left out, as
-- are enchants going away.
function Enchants.Diff(before, after, temp)
    local gained, lost = {}, {}
    for key, n in pairs(after) do
        local extra = n - (before[key] or 0)
        if extra > 0 then gained[#gained + 1] = { key, extra } end
    end
    for key, n in pairs(before) do
        local missing = n - (after[key] or 0)
        if missing > 0 then lost[#lost + 1] = { key, missing } end
    end
    table.sort(gained, function(a, b) return a[1] < b[1] end)
    table.sort(lost, function(a, b) return a[1] < b[1] end)
    local changes = {}
    for _, g in ipairs(gained) do
        local itemID, enchantID = g[1]:match("^(%-?%d+):(%-?%d+)$")
        itemID, enchantID = tonumber(itemID), tonumber(enchantID)
        for _, l in ipairs(lost) do
            local lostItem, oldEnchantID = l[1]:match("^(%-?%d+):(%-?%d+)$")
            if tonumber(lostItem) == itemID and l[2] > 0 and g[2] > 0 then
                oldEnchantID = tonumber(oldEnchantID)
                local pairsFound = math.min(g[2], l[2])
                l[2], g[2] = l[2] - pairsFound, g[2] - pairsFound
                if enchantID ~= 0 and not temp[enchantID] and not temp[oldEnchantID] then
                    for _ = 1, pairsFound do
                        changes[#changes + 1] = { itemID, enchantID, oldEnchantID }
                    end
                end
            end
        end
    end
    return changes
end

-- Notes the enchant IDs GetWeaponEnchantInfo reports as temporary now.
local function NoteTemporary()
    if not GetWeaponEnchantInfo then return end
    local info = { GetWeaponEnchantInfo() }
    for _, i in ipairs({ 4, 8, 12 }) do
        if info[i - 3] and type(info[i]) == "number" and info[i] > 0 then
            tempEnchants[info[i]] = true
        end
    end
end

-- The equipment slot an item with this enchant is in, or 0.
local function SlotOf(itemID, enchantID)
    for slot = 1, 19 do
        local id, enchant = Enchants.Parse(GetInventoryItemLink("player", slot))
        if id == itemID and enchant == enchantID then return slot end
    end
    return 0
end

local function Scan()
    NoteTemporary()
    local now = Read()
    if counts then
        for _, change in ipairs(Enchants.Diff(counts, now, tempEnchants)) do
            local itemID, enchantID, oldEnchantID = change[1], change[2], change[3]
            local by, guid, spellID, text
            local t = GetTime()
            if trade and trade.itemID == itemID and (trade.open or t - trade.closedAt <= TRADE_WINDOW) then
                by, guid, text = trade.name, trade.guid, trade.text
            elseif cast and t - cast.at <= CAST_WINDOW then
                by, spellID = "self", cast.spellID
            end
            Log("ench", itemID, enchantID, oldEnchantID, SlotOf(itemID, enchantID), by, guid, spellID, text)
        end
    end
    counts = now
end

local scanQueued = false
local function QueueScan()
    if not loggedIn or scanQueued then return end
    scanQueued = true
    C_Timer.After(SCAN_DELAY, function()
        scanQueued = false
        ns.SafeCall(Scan)
    end)
end

-- What the trade window's enchant slot holds on the player's side: the item
-- going to be enchanted, the enchant's name and who is doing it.
local function ReadTrade()
    local link = GetTradePlayerItemLink and GetTradePlayerItemLink(TRADE_ENCHANT_SLOT)
    local itemID = Enchants.Parse(link)
    if not itemID then return end
    local text = select(5, GetTradePlayerItemInfo(TRADE_ENCHANT_SLOT))
    local name, realm = UnitName("NPC")
    trade = {
        itemID = itemID, text = text ~= "" and text or nil, open = true, closedAt = 0,
        name = name and realm and realm ~= "" and (name .. "-" .. realm) or name, guid = UnitGUID("NPC"),
    }
end

-- How to show an ench event: title, detail (who, to go before the place) and icon.
function Enchants:Describe(e)
    local itemID, enchantID = e[6], e[7]
    local item = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID) or "an item"
    local name = e[13] or self:EnchantName(itemID, enchantID)
        or (e[12] and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(e[12]))
    local who = e[10] == "self" and "Enchanted yourself" or e[10] and ("Enchanted by " .. e[10]) or "Enchanted"
    ---@diagnostic disable-next-line: deprecated
    local getIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
    return ("%s: %s"):format(item, name or "new enchant"), who, getIcon and getIcon(itemID)
end

-- The enchant's line on the item's tooltip ("+3 Agility"), or nil.
function Enchants:EnchantName(itemID, enchantID)
    local tooltip = C_TooltipInfo and C_TooltipInfo.GetHyperlink
    if not tooltip then return nil end
    local ok, data = pcall(tooltip, ("item:%d:%d"):format(itemID, enchantID))
    if not ok or not data or not data.lines then return nil end
    local permanent = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemEnchantmentPermanent
    for _, line in ipairs(data.lines) do
        if line.type == permanent and line.leftText then return line.leftText end
    end
end

-- Listening ---------------------------------------------------------------------

-- The first read is the baseline, after login like every other recorder
-- (the sync folder may replace the journey before then).
ns.On("PLAYER_LOGIN", function()
    loggedIn = true
    QueueScan()
end)
ns.On("BAG_UPDATE_DELAYED", QueueScan)
ns.On("PLAYER_EQUIPMENT_CHANGED", QueueScan)
ns.On("UNIT_INVENTORY_CHANGED", function(unit)
    if unit == "player" then QueueScan() end
end)

ns.On("TRADE_SHOW", function() trade = nil end)
ns.On("TRADE_PLAYER_ITEM_CHANGED", function(slot)
    if slot == TRADE_ENCHANT_SLOT then ReadTrade() end
end)
ns.On("TRADE_TARGET_ITEM_CHANGED", function() ReadTrade() end)
ns.On("TRADE_ACCEPT_UPDATE", function() ReadTrade() end)
ns.On("TRADE_CLOSED", function()
    if trade and trade.open then
        trade.open, trade.closedAt = false, GetTime()
    end
end)

ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit == "player" then cast = { spellID = spellID, at = GetTime() } end
end)
