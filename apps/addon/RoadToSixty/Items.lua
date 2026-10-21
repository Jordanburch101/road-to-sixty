local _, ns = ...

-- Shared ways to read items, for the gear, enchant and source recorders:
--   ns.ItemString(link, withoutEnchant)  an item link as a stable item string
--   ns.Equippable(itemID)                whether it can be worn
--   ns.CountItems(key)                   items in the gear and bags, counted by key

-- An item link as its item string, keeping what tells this item apart (the
-- random suffix such as "of the Monkey", the enchant, the item context that
-- hints where it came from) and leaving out what changes while it stays the
-- same item: the link level (field 9, the player's level, so every link
-- changes at a level up) and the spec (field 10). Empty fields at the end
-- are dropped: "item:6070:::::::::::11". withoutEnchant leaves the enchant
-- out too (Enchants.lua logs enchants). nil for anything but an item link.
function ns.ItemString(link, withoutEnchant)
    local s = type(link) == "string" and link:match("item:[%-%d:]+")
    if not s then return nil end
    local fields = {}
    for v in (s:sub(6) .. ":"):gmatch("([^:]*):") do fields[#fields + 1] = v end
    for i = #fields + 1, 10 do fields[i] = "" end
    fields[9], fields[10] = "", ""
    if withoutEnchant then fields[2] = "" end
    local last = #fields
    while last > 1 and fields[last] == "" do last = last - 1 end
    return "item:" .. table.concat(fields, ":", 1, last)
end

-- Whether an item can be worn (bags can, but are not gear).
function ns.Equippable(itemID)
    ---@diagnostic disable-next-line: deprecated
    local info = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    if not info then return true end
    local equipLoc = select(4, info(itemID))
    return equipLoc ~= nil and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
end

local BAGS = 4      -- the backpack is bag 0, then four bags

-- Counts of key(link) over the equipped gear and the bags together, for
-- items that can be worn; key returns nil to leave an item out. Read
-- together, an item moving between the bags and the gear changes nothing.
function ns.CountItems(key)
    local counts = {}
    local function Add(link, n)
        local k = link and key(link)
        local itemID = k and tonumber(link:match("item:(%-?%d+)"))
        if itemID and ns.Equippable(itemID) then counts[k] = (counts[k] or 0) + (n or 1) end
    end
    for slot = 1, 19 do
        Add(GetInventoryItemLink("player", slot))
    end
    local bags = C_Container
    if bags and bags.GetContainerNumSlots and bags.GetContainerItemInfo then
        for bag = 0, BAGS do
            for slot = 1, bags.GetContainerNumSlots(bag) do
                local info = bags.GetContainerItemInfo(bag, slot)
                if info then Add(info.hyperlink, info.stackCount) end
            end
        end
    end
    return counts
end
