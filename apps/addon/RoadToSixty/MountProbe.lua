local _, ns = ...

-- /rts mountprobe: what the riding and mount APIs give on this client, to
-- choose how to record learning riding and the first mount (issue #7).
-- Forever is classic content on a modern client, so riding may be a racial
-- skill (Horse Riding, Ram Riding, ...) or modern Apprentice Riding, and
-- mounts may be in the modern mount collection or bag items.
-- /rts mountprobe watch prints the mount and spell events as they fire, and
-- every system message, until the next /reload or watch again.
-- /rts mountprobe trainer lists what an open trainer teaches (riding),
-- /rts mountprobe vendor what an open vendor sells that is a mount, so both
-- can be checked on the beta, where neither can be bought.

local P = function(msg) ns.Print(msg) end

-- Names that riding skills and spells have, classic and modern.
local RIDING_WORDS = { "riding", "horsemanship", "piloting" }

-- Riding spells: modern Apprentice, Journeyman, Expert, Artisan, Master,
-- then the classic races' own (as Mounts.lua).
local RIDING_SPELLS = { 33388, 33391, 34090, 34091, 90265, 824, 825, 826, 828, 10861, 10906, 10907, 18995 }

local function Plain(v)
    if type(v) == "table" then
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. Plain(x) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function Has(t, names)
    local list = {}
    for _, name in ipairs(names) do
        list[#list + 1] = ("%s %s"):format(name, t and t[name] and "yes" or "no")
    end
    return table.concat(list, ", ")
end

local function IsRiding(name)
    name = name and name:lower() or ""
    for _, word in ipairs(RIDING_WORDS) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

-- Every spell in the player's spellbook: { name, spellID }, modern API first.
local function SpellBook()
    local list = {}
    local book = C_SpellBook
    if book and book.GetNumSpellBookSkillLines and book.GetSpellBookItemInfo then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        for line = 1, book.GetNumSpellBookSkillLines() do
            local info = book.GetSpellBookSkillLineInfo(line)
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local ok, item = pcall(book.GetSpellBookItemInfo, i, bank)
                if ok and item then
                    list[#list + 1] = { item.name, item.spellID, info.name, item.itemType }
                end
            end
        end
        return list, "C_SpellBook"
    end
    if GetNumSpellTabs and GetSpellBookItemName then
        for tab = 1, GetNumSpellTabs() do
            local tabName, _, offset, count = GetSpellTabInfo(tab)
            for i = offset + 1, offset + count do
                local name = GetSpellBookItemName(i, "spell")
                local _, spellID = GetSpellBookItemInfo(i, "spell")
                list[#list + 1] = { name, spellID, tabName }
            end
        end
        return list, "GetSpellBookItemName"
    end
    return list, "none"
end

-- Mount items in the bags: { link, how it was told }.
local function BagMounts()
    local list = {}
    local bags = C_Container
    if not (bags and bags.GetContainerNumSlots and bags.GetContainerItemInfo) then return list, false end
    for bag = 0, 4 do
        for slot = 1, bags.GetContainerNumSlots(bag) do
            local info = bags.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local journal = C_MountJournal and C_MountJournal.GetMountFromItem
                    and C_MountJournal.GetMountFromItem(info.itemID)
                local classID, subclassID
                if C_Item and C_Item.GetItemInfoInstant then
                    classID, subclassID = select(6, C_Item.GetItemInfoInstant(info.itemID))
                end
                -- Item class 15 (miscellaneous), subclass 5 is a mount.
                if journal or (classID == 15 and subclassID == 5) then
                    list[#list + 1] = ("%s (journal %s, class %s/%s)"):format(info.hyperlink or info.itemID,
                        tostring(journal), tostring(classID), tostring(subclassID))
                end
            end
        end
    end
    return list, true
end

local function Report()
    ---@diagnostic disable-next-line: deprecated
    local playerSpell, spellKnown = IsPlayerSpell and "yes" or "no", IsSpellKnown and "yes" or "no"
    P(("Level %d, IsMounted %s, IsPlayerSpell %s, IsSpellKnown %s."):format(UnitLevel("player"),
        tostring(IsMounted and IsMounted()), playerSpell, spellKnown))
    P("C_MountJournal: " .. Has(C_MountJournal, { "GetNumMounts", "GetMountIDs", "GetMountInfoByID",
        "GetMountFromSpell", "GetMountFromItem", "GetNumDisplayedMounts" }))
    P("Companions: " .. Has(_G, { "GetNumCompanions", "GetCompanionInfo" }))

    -- The modern mount collection: how many it lists, and which are collected.
    local journal = C_MountJournal
    if journal and journal.GetMountIDs and journal.GetMountInfoByID then
        local ids, owned, active = journal.GetMountIDs() or {}, {}, nil
        for _, id in ipairs(ids) do
            local name, spellID, _, isActive, _, _, _, _, _, _, isCollected = journal.GetMountInfoByID(id)
            if isCollected then owned[#owned + 1] = ("%s (mount %d, spell %s)"):format(name, id, tostring(spellID)) end
            if isActive then active = name end
        end
        P(("Mount journal: %d mounts listed, %d collected%s."):format(#ids, #owned,
            active and (", riding " .. active) or ""))
        for k = 1, math.min(#owned, 5) do P("  " .. owned[k]) end
    end
    if GetNumCompanions then
        local ok, count = pcall(GetNumCompanions, "MOUNT")
        P("GetNumCompanions(MOUNT): " .. (ok and tostring(count) or ("error " .. tostring(count))))
    end

    -- Riding, by spell ID (does the client have it, is it known) and by name in the spellbook.
    local ids = {}
    for _, id in ipairs(RIDING_SPELLS) do
        local exists = C_Spell and C_Spell.DoesSpellExist and C_Spell.DoesSpellExist(id)
        ---@diagnostic disable-next-line: deprecated
        local knownNow = IsPlayerSpell and IsPlayerSpell(id)
        ids[#ids + 1] = ("%d %s%s%s"):format(id, tostring(C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)),
            exists == false and " (missing)" or "", knownNow and " KNOWN" or "")
    end
    P("Riding spells: " .. table.concat(ids, ", "))
    local spells, how = SpellBook()
    local riding = {}
    for _, s in ipairs(spells) do
        if IsRiding(s[1]) then
            riding[#riding + 1] = ("%s (spell %s, tab %s, type %s)"):format(s[1], tostring(s[2]), tostring(s[3]), tostring(s[4]))
        end
    end
    P(("Spellbook (%s): %d spells, riding: %s"):format(how, #spells,
        #riding > 0 and table.concat(riding, "; ") or "none"))
    if GetProfessions then
        local names = {}
        for _, index in ipairs({ GetProfessions() }) do
            local name = GetProfessionInfo(index)
            names[#names + 1] = tostring(name)
        end
        P("GetProfessions: " .. (#names > 0 and table.concat(names, ", ") or "none"))
    end

    local items, ok = BagMounts()
    P("Mount items in bags: " .. (not ok and "no C_Container" or #items > 0 and table.concat(items, "; ") or "none"))
    P("Learn messages: " .. tostring(ERR_LEARN_SPELL_S) .. " / " .. tostring(ERR_LEARN_ABILITY_S))

    -- A vendor mount in the collection: where it says it comes from, and
    -- whether it is for this character.
    if journal and journal.GetMountFromSpell then
        for _, spellID in ipairs({ 458, 580, 6898 }) do   -- Brown Horse, Timber Wolf, White Ram
            local id = journal.GetMountFromSpell(spellID)
            if id then
                local name, _, _, _, usable, sourceType, _, factionSpecific, faction, hide, collected =
                    journal.GetMountInfoByID(id)
                local source = journal.GetMountInfoExtraByID and select(3, journal.GetMountInfoExtraByID(id))
                P(("%s (mount %d): usable %s, source %s %s, faction %s %s, hidden %s, collected %s"):format(
                    tostring(name), id, tostring(usable), tostring(sourceType),
                    tostring(source and source:gsub("|n", " ") or nil), tostring(factionSpecific),
                    tostring(faction), tostring(hide), tostring(collected)))
            end
        end
    end
end

-- What an open trainer teaches: riding lines first, else a count.
local function Trainer()
    if not (GetNumTrainerServices and GetTrainerServiceInfo) then
        P("No GetNumTrainerServices on this client.")
        return
    end
    local count, shown = GetNumTrainerServices(), 0
    if count == 0 then
        P("No trainer open, or it teaches nothing. Open a riding trainer and run this again.")
        return
    end
    for i = 1, count do
        local name, rank, category = GetTrainerServiceInfo(i)
        local skill = GetTrainerServiceSkillLine and GetTrainerServiceSkillLine(i)
        if IsRiding(name) or IsRiding(skill) or IsRiding(rank) then
            local link = GetTrainerServiceItemLink and GetTrainerServiceItemLink(i)
            local level = GetTrainerServiceLevelReq and GetTrainerServiceLevelReq(i)
            P(("Trainer %d: %s, %s, %s, skill line %s, level %s, link %s"):format(i, tostring(name), tostring(rank),
                tostring(category), tostring(skill), tostring(level), tostring(link and link:gsub("|", "||"))))
            shown = shown + 1
        end
    end
    if shown == 0 then
        local first = GetTrainerServiceInfo(1)
        P(("Trainer teaches %d things, none named riding. First: %s."):format(count, tostring(first)))
    end
end

-- What an open vendor sells that is a mount (or might be).
local function Vendor()
    if not (GetMerchantNumItems and GetMerchantItemID) then
        P("No GetMerchantItemID on this client.")
        return
    end
    local count, shown = GetMerchantNumItems(), 0
    if count == 0 then
        P("No vendor open. Open a mount vendor and run this again.")
        return
    end
    for i = 1, count do
        local itemID = GetMerchantItemID(i)
        if itemID then
            local mountID = C_MountJournal and C_MountJournal.GetMountFromItem and C_MountJournal.GetMountFromItem(itemID)
            local classID, subclassID
            if C_Item and C_Item.GetItemInfoInstant then
                classID, subclassID = select(6, C_Item.GetItemInfoInstant(itemID))
            end
            if mountID or classID == 15 then
                local spellName, spellID
                if C_Item and C_Item.GetItemSpell then spellName, spellID = C_Item.GetItemSpell(itemID) end
                P(("Vendor %d: item %d %s, mount %s, class %s/%s, item spell %s (%s)"):format(i, itemID,
                    tostring(C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)), tostring(mountID),
                    tostring(classID), tostring(subclassID), tostring(spellName), tostring(spellID)))
                shown = shown + 1
            end
        end
    end
    if shown == 0 then P(("Vendor sells %d items, none a mount."):format(count)) end
end

-- Watching -----------------------------------------------------------------------

local WATCHED = {
    "NEW_MOUNT_ADDED", "COMPANION_LEARNED", "COMPANION_UPDATE", "PLAYER_MOUNT_DISPLAY_CHANGED",
    "LEARNED_SPELL_IN_TAB", "LEARNED_SPELL_IN_SKILL_LINE", "SKILL_LINES_CHANGED", "MOUNT_JOURNAL_USABILITY_CHANGED",
    "MOUNT_JOURNAL_LIST_UPDATE", "BAG_UPDATE_DELAYED", "TRAINER_UPDATE",
}
local watching = false
local registered = nil      -- event -> whether the client accepted it

local function Watch()
    if not registered then
        registered = {}
        for _, event in ipairs(WATCHED) do
            registered[event] = ns.On(event, function(...)
                if watching then
                    P(("%s %s, mounted %s"):format(event, Plain({ ... }), tostring(IsMounted and IsMounted())))
                end
            end)
        end
        -- Every system message, links shown as text: a mount may be
        -- announced in words other than "learned".
        ns.On("CHAT_MSG_SYSTEM", function(msg)
            if watching then
                P("CHAT_MSG_SYSTEM " .. msg:gsub("|", "||"))
            end
        end)
    end
    watching = not watching
    local refused = {}
    for _, event in ipairs(WATCHED) do
        if not registered[event] then refused[#refused + 1] = event end
    end
    P(("Watching mount and spell events %s.%s"):format(watching and "on" or "off",
        #refused > 0 and (" Refused by the client: " .. table.concat(refused, ", ")) or ""))
end

ns.Command("mountprobe", "check the riding and mount APIs; watch to print their events (developer)", function(arg)
    if arg == "watch" then
        Watch()
    elseif arg == "trainer" then
        Trainer()
    elseif arg == "vendor" then
        Vendor()
    else
        Report()
    end
end)
