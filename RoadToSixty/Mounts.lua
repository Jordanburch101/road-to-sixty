local _, ns = ...

-- Records riding and mounts (issue #7) as journal events:
--   ride   spellID, name, late    a riding skill learned: modern Apprentice
--                                 Riding and up, or a race's own (Horse
--                                 Riding, Ram Riding, ...); late = true when
--                                 found with no learn signal just before, so
--                                 its time and place may be off
--   mount  mountID, name, spellID, itemID, how   a new mount: how "n" when
--                                 the client named it (NEW_MOUNT_ADDED or the
--                                 chat message's spell link), "w" when it was
--                                 the only new one in the collection just
--                                 after a learn signal, "i" when a mount
--                                 item came into the bags; mountID, spellID
--                                 and itemID when known
--
-- Saved, so a later version can repair or fill in what was missed:
--   ns.char.riding      spellID -> { name, time, level, base }
--   ns.char.mounts      mountID -> { time, continentID, x, y, level, base, logged }
--   ns.char.mountItems  itemID -> the same, for mount items in the bags
-- each nil until first read. base = true for what was known at the first
-- read (logged nothing); logged = true once a mount event was logged.
--
-- Forever's mount collection (C_MountJournal) lists the classic mounts, but
-- buying riding or a mount could not be tried on the beta, so this reads
-- every way the client might show them. Collected mounts may be shared by
-- the whole account, as on retail, so a mount is only logged when tied to a
-- learn signal; others are only noted. Mounts may also be bag items that
-- summon, as in classic; a new one in the bags counts as learning it.

local Mounts = {}
ns.Mounts = Mounts

local READY = 5         -- seconds after login before the first read
local LEARN_WINDOW = 5  -- seconds a learn signal counts for
local RECHECK = 2       -- the collection can lag the signal, so it is read again

local Log = function(...) ns.Journal:Log(...) end

local ready = false
local signalAt = -math.huge     -- time() of the last learn signal

-- Riding spells: modern Apprentice, Journeyman, Expert, Artisan, Master,
-- then the classic races' own.
local RIDING_SPELLS = {
    33388, 33391, 34090, 34091, 90265,
    824, 825, 826, 828, 10861, 10906, 10907, 18995,
}
-- English names, for riding spells not in the list above.
local RIDING_WORDS = { "riding", "horsemanship", "piloting" }

local function IsRidingName(name)
    name = type(name) == "string" and name:lower() or ""
    for _, word in ipairs(RIDING_WORDS) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

---@diagnostic disable-next-line: deprecated
local IsPlayerSpell = IsPlayerSpell

local function SpellName(spellID)
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spellID)
    end
end

-- Where and when, for the saved notes.
local function Note(base)
    local c, x, y = ns.Recorder:Position()
    return { time(), c, x and math.floor(x), y and math.floor(y), UnitLevel("player"), base or nil }
end

local function Recent()
    return time() - signalAt <= LEARN_WINDOW
end

-- Riding ---------------------------------------------------------------------------

-- Riding skills known now: spellID -> name.
function Mounts:ReadRiding()
    local now = {}
    if IsPlayerSpell then
        for _, id in ipairs(RIDING_SPELLS) do
            if IsPlayerSpell(id) then
                now[id] = SpellName(id) or "Riding"
            end
        end
    end
    -- The spellbook can also list spells not learned yet; those do not count.
    local book = C_SpellBook
    if book and book.GetNumSpellBookSkillLines and book.GetSpellBookItemInfo then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        local future = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.FutureSpell
        for line = 1, book.GetNumSpellBookSkillLines() do
            local info = book.GetSpellBookSkillLineInfo(line)
            for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                local ok, item = pcall(book.GetSpellBookItemInfo, i, bank)
                if ok and item and item.spellID and IsRidingName(item.name)
                    and (not future or item.itemType ~= future)
                    and (not IsPlayerSpell or IsPlayerSpell(item.spellID)) then
                    now[item.spellID] = item.name
                end
            end
        end
    end
    return now
end

-- Logs riding skills learned since the last read.
function Mounts:CheckRiding()
    if not ready or ns.char.seeded then return end
    local known = ns.char.riding
    local baseline = known == nil
    known = known or {}
    for id, name in pairs(self:ReadRiding()) do
        if not known[id] then
            local note = Note(baseline)
            known[id] = { name, note[1], note[5], note[6] }
            if not baseline then
                Log("ride", id, name, not Recent() or nil)
            end
        end
    end
    ns.char.riding = known
end

-- Mounts -----------------------------------------------------------------------------

-- Collected mounts now: mountID -> { name, spellID }, or nil without the
-- mount collection.
function Mounts:ReadMounts()
    local journal = C_MountJournal
    if not (journal and journal.GetMountIDs and journal.GetMountInfoByID) then return end
    local now = {}
    for _, id in ipairs(journal.GetMountIDs() or {}) do
        local name, spellID, _, _, _, _, _, _, _, _, collected = journal.GetMountInfoByID(id)
        if collected then
            now[id] = { name, spellID }
        end
    end
    return now
end

-- The mount the client named, if it is collected now: mountID from
-- NEW_MOUNT_ADDED (a mount ID on retail), spellID from a learned spell. A
-- spell ID is only looked up as a spell, as it can be some other mount's ID.
local function Named(now, mountID, spellID)
    if mountID and now[mountID] then return mountID end
    local fromSpell = C_MountJournal and C_MountJournal.GetMountFromSpell
    for _, id in ipairs({ spellID or false, mountID or false }) do
        if id and fromSpell then
            local ok, found = pcall(fromSpell, id)
            if ok and found and now[found] then return found end
        end
    end
end

local function LogMount(mountID, itemID, how)
    local known = ns.char.mounts or {}
    ns.char.mounts = known
    local note = known[mountID]
    if note and (note.logged or note[6]) then return end   -- logged already, or had before tracking
    local name, spellID
    if mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
        name, spellID = C_MountJournal.GetMountInfoByID(mountID)
    end
    if not name and itemID and C_Item and C_Item.GetItemNameByID then
        name = C_Item.GetItemNameByID(itemID)
    end
    Log("mount", mountID, name, spellID, itemID, how)
    if mountID then
        known[mountID] = note or Note()
        known[mountID].logged = true
    end
end

-- Notes newly collected mounts, and logs one when it can be tied to a learn
-- signal: the mount the client named, or else the only one that appeared
-- since the signal. More than one at once (an account's mounts arriving
-- late, say) is only noted. mountID and spellID are what the signal named.
function Mounts:CheckMounts(mountID, spellID)
    if not ready or ns.char.seeded then return end
    local now = self:ReadMounts()
    if not now then return end
    local known = ns.char.mounts
    local baseline = known == nil
    known = known or {}
    for id in pairs(now) do
        if not known[id] then known[id] = Note(baseline) end
    end
    ns.char.mounts = known
    if baseline then return end
    local named = Named(now, mountID, spellID)
    if named then
        LogMount(named, nil, "n")
    elseif Recent() then
        local fresh
        for id, note in pairs(known) do
            if now[id] and not note.logged and not note[6] and note[1] >= signalAt - LEARN_WINDOW then
                if fresh then return end
                fresh = id
            end
        end
        if fresh then LogMount(fresh, nil, "w") end
    end
end

-- Mount items in the bags: itemID -> mountID (or false when the collection
-- does not know it).
function Mounts:ReadItems()
    local items = {}
    local bags = C_Container
    if not (bags and bags.GetContainerNumSlots and bags.GetContainerItemInfo) then return items end
    local fromItem = C_MountJournal and C_MountJournal.GetMountFromItem
    for bag = 0, 4 do
        for slot = 1, bags.GetContainerNumSlots(bag) do
            local info = bags.GetContainerItemInfo(bag, slot)
            local itemID = info and info.itemID
            if itemID and items[itemID] == nil then
                local mountID = fromItem and fromItem(itemID)
                local classID, subclassID
                if C_Item and C_Item.GetItemInfoInstant then
                    classID, subclassID = select(6, C_Item.GetItemInfoInstant(itemID))
                end
                -- Item class 15 (miscellaneous), subclass 5 is a mount.
                if mountID or (classID == 15 and subclassID == 5) then
                    items[itemID] = mountID or false
                end
            end
        end
    end
    return items
end

-- Logs a mount item new to the bags, unless its mount is logged already.
function Mounts:CheckItems()
    if not ready or ns.char.seeded then return end
    local known = ns.char.mountItems
    local baseline = known == nil
    known = known or {}
    for itemID, mountID in pairs(self:ReadItems()) do
        if not known[itemID] then
            known[itemID] = Note(baseline)
            if not baseline then
                LogMount(mountID or nil, itemID, "i")
            end
        end
    end
    ns.char.mountItems = known
end

-- Something was just learned: read now, and again once the client has caught up.
local function Learned(mountID, spellID)
    if not ready then return end
    signalAt = time()
    Mounts:CheckRiding()
    Mounts:CheckMounts(mountID, spellID)
    C_Timer.After(RECHECK, function()
        ns.SafeCall(function()
            Mounts:CheckRiding()
            Mounts:CheckMounts(mountID, spellID)
        end)
    end)
end

-- Showing them ------------------------------------------------------------------

Mounts.ICON = "Interface\\Icons\\Ability_Mount_RidingHorse"

-- A mount's icon from the collection, by mount ID or by its spell.
local function MountIcon(mountID, spellID)
    local journal = C_MountJournal
    if not journal then return end
    if not mountID and spellID and journal.GetMountFromSpell then
        mountID = journal.GetMountFromSpell(spellID)
    end
    if mountID and journal.GetMountInfoByID then
        local _, _, icon = journal.GetMountInfoByID(mountID)
        return icon
    end
end

local function SpellIcon(spellID)
    if spellID and C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    end
end

local function ItemIcon(itemID)
    if itemID and C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(itemID)
    end
end

-- How to show a ride or mount event: title, detail (what kind of entry, to
-- go before the place) and icon.
function Mounts:Describe(e)
    if e[2] == "ride" then
        return "Learned " .. (e[7] or "riding"), "Riding", SpellIcon(e[6]) or self.ICON
    elseif e[2] == "mount" then
        return "New mount: " .. (e[7] or "?"), "Mount",
            MountIcon(e[6], e[8]) or ItemIcon(e[9]) or self.ICON
    end
end

-- For Stats, from the journey shown: the level riding was first learned at
-- (nil if not learned while tracking), whether any riding is known, and the
-- ride and mount events, oldest first.
function Mounts:Summary()
    local level, learnedAt, events = nil, nil, {}
    for _, e in ipairs(ns.view.events) do
        local kind = e[2]
        if kind == "on" or kind == "lvl" then
            level = e[6]
        elseif kind == "ride" or kind == "mount" then
            if kind == "ride" and not learnedAt then learnedAt = level end
            events[#events + 1] = e
        end
    end
    return learnedAt, next(ns.view.riding or {}) ~= nil, events
end

-- Listening ---------------------------------------------------------------------

-- A chat message as a pattern matching the whole of it.
local function Pattern(text)
    return text and ("^" .. text:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$")
end
local LEARNED = { Pattern(ERR_LEARN_SPELL_S), Pattern(ERR_LEARN_ABILITY_S) }

ns.On("PLAYER_LOGIN", function()
    C_Timer.After(READY, function()
        ready = true
        ns.SafeCall(function()
            Mounts:CheckRiding()
            Mounts:CheckMounts()
            Mounts:CheckItems()
        end)
    end)
end)

ns.On("NEW_MOUNT_ADDED", function(mountID) Learned(mountID) end)
ns.On("COMPANION_LEARNED", function() Learned() end)
ns.On("LEARNED_SPELL_IN_TAB", function(spellID) Learned(nil, spellID) end)
ns.On("LEARNED_SPELL_IN_SKILL_LINE", function(spellID) Learned(nil, spellID) end)
ns.On("SKILL_LINES_CHANGED", function() Mounts:CheckRiding() end)
-- Quietly, so a collection that fills in late is noted, not logged.
ns.On("MOUNT_JOURNAL_LIST_UPDATE", function() Mounts:CheckMounts() end)
ns.On("BAG_UPDATE_DELAYED", function() Mounts:CheckItems() end)

ns.On("CHAT_MSG_SYSTEM", function(msg)
    for _, pattern in pairs(LEARNED) do
        local what = msg:match(pattern)
        if what then
            -- The spell's link names the mount exactly.
            Learned(nil, tonumber(what:match("|Hspell:(%d+)")))
            return
        end
    end
end)
