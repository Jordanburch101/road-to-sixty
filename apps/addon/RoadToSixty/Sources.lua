local _, ns = ...

-- Where each piece of gear came from (issue #62). Items that can be worn
-- are noted as they arrive, and when one is put on, the newest note for it
-- goes into the "eq" event (Journal.lua) as its source:
--   { t, how, c, x, y, id, kind, name, instance }
--   t, c, x, y  when and where it was got (ns.Now, world yards; c -1 when
--               the place is not known)
--   how   "drop"    looted: id is the NPC, object or container's ID, kind
--                   its GUID type ("Creature", "GameObject", "Item"), name
--                   the mob's name when it was seen; from a master looter,
--                   none of these
--         "quest"   a quest reward: id is the quest ID
--         "vendor"  bought: id is the vendor's NPC ID, name its name
--         "trade"   traded: name is the other player (with the realm when
--                   it differs)
--         "mail"    taken from the mail: name is the sender
--         "ah"      won at the auction house (taken from its mail)
--         "craft"   made by the player
--         "roll"    won in a group roll
--         "?"       none of these was seen
--   instance  the instance ID when got inside one
--
-- The bags and the gear are counted together by item string without the
-- enchant (ns.CountItems), so a new copy of an item is one arriving; one
-- moving between the bags and the gear, a level up or an enchant is not.
-- What was going on just before says how: a loot window open, a quest
-- turned in, a purchase, a trade, a mail taken, a "You create" or "You won"
-- message. Items taken out of the bank are not new, so nothing is noted
-- while it is open.
--
-- Saved: ns.char.got, item string (without enchant) -> notes, oldest
-- first; at most NOTES_PER_ITEM per item, NOTES_KEPT in all, none older
-- than NOTE_DAYS. Merge keeps it from the copy seen last.
--
-- Drops and quest rewards were seen on Forever (gearprobe); vendor, trade,
-- mail, auction house, crafting and rolls are built from the client's own
-- code and not yet checked in game.

local Sources = {}
ns.Sources = Sources

local SCAN_DELAY = 0.3
local WINDOW = 10           -- seconds a signal counts for after it ends
local NOTES_PER_ITEM, NOTES_KEPT, NOTE_DAYS = 5, 300, 30
local TRADE_SLOTS = 6       -- the seventh is "will not be traded"

local loggedIn = false
local counts                -- item string -> count, at the last read
local signals = {}          -- { key, how, until, ... } what could explain an item arriving
local lootOpen, bankOpen = false, false

local function Key(link) return ns.ItemString(link, true) end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function Plain(v)
    if v == nil or IsSecret(v) then return nil end
    return v
end

-- "Creature-0-6836-0-2-69-A66013D72E" -> 69, "Creature".
local function FromGUID(guid)
    if type(guid) ~= "string" or IsSecret(guid) then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return tonumber(id), kind
end

-- Mob names by GUID, as seen on the target, the mouseover and nameplates:
-- no API names an NPC ID, so a drop's mob is named from here. Mob names are
-- secret inside instances, so drops there keep only the ID.
local NAMES_KEPT = 200
local names, nameOrder = {}, {}

local function SeeUnit(unit)
    local guid = UnitGUID(unit)
    if type(guid) ~= "string" or IsSecret(guid) or names[guid] or not guid:find("^Creature") then return end
    local name = UnitName(unit)
    if not name or IsSecret(name) then return end
    names[guid] = name
    nameOrder[#nameOrder + 1] = guid
    if #nameOrder > NAMES_KEPT then names[table.remove(nameOrder, 1)] = nil end
end

local function FullName(name, realm)
    name, realm = Plain(name), Plain(realm)
    if name and realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Notes that an item with this link may be about to arrive, and how.
-- until is math.huge while a window stays open.
local function Signal(link, how, fields, untilTime)
    local key = Key(link)
    if not key then return end
    local s = fields or {}
    s.key, s.how, s["until"] = key, how, untilTime or (GetTime() + WINDOW)
    signals[#signals + 1] = s
    return s
end

-- Ends the open-ended signals of one kind: they count for WINDOW more seconds.
local function Close(how)
    for _, s in ipairs(signals) do
        if s.how == how and s["until"] == math.huge then s["until"] = GetTime() + WINDOW end
    end
end

-- The newest signal for an item still counting, taken so it explains one copy.
local function Explain(key)
    local now = GetTime()
    for i = #signals, 1, -1 do
        local s = signals[i]
        if s.key == key and s["until"] >= now then
            if s["until"] ~= math.huge then table.remove(signals, i) end
            return s
        end
    end
end

-- Whether a signal of this kind for this item still counts.
local function Signalled(key, how)
    local now = GetTime()
    for _, s in ipairs(signals) do
        if s.key == key and s.how == how and s["until"] >= now then return true end
    end
    return false
end

local function Prune()
    local now = GetTime()
    for i = #signals, 1, -1 do
        if signals[i]["until"] < now then table.remove(signals, i) end
    end
end

-- Keeps the saved notes within their limits.
local function Trim(got)
    local oldest, all = ns.Now() - NOTE_DAYS * 86400, {}
    for key, notes in pairs(got) do
        for i = #notes, 1, -1 do
            if (notes[i].t or 0) < oldest then table.remove(notes, i) end
        end
        while #notes > NOTES_PER_ITEM do table.remove(notes, 1) end
        if #notes == 0 then got[key] = nil end
        for _, note in ipairs(notes) do all[#all + 1] = { key, note } end
    end
    if #all > NOTES_KEPT then
        table.sort(all, function(a, b) return a[2].t < b[2].t end)
        for i = 1, #all - NOTES_KEPT do
            local notes = got[all[i][1]]
            for j = #notes, 1, -1 do
                if notes[j] == all[i][2] then table.remove(notes, j) end
            end
            if #notes == 0 then got[all[i][1]] = nil end
        end
    end
end

local function Note(key, signal)
    local c, x, y = ns.Recorder:Position()
    local note = {
        t = ns.Now(), how = signal and signal.how or "?", c = c or -1, x = x or 0, y = y or 0,
        id = signal and signal.id, kind = signal and signal.kind, name = signal and signal.name,
        instance = ns.char.instance,
    }
    local got = ns.char.got or {}
    ns.char.got = got
    got[key] = got[key] or {}
    table.insert(got[key], note)
    Trim(got)
end

function Sources:Scan()
    if not loggedIn then return end
    Prune()
    local now = ns.CountItems(Key)
    if counts and not bankOpen then
        local keys = {}
        for key in pairs(now) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            for _ = 1, now[key] - (counts[key] or 0) do
                Note(key, Explain(key))
            end
        end
    end
    counts = now
end

-- The newest note for an item being put on, taken out of the saved notes;
-- nil when there is none. key is its item string without the enchant.
function Sources:Take(key)
    ns.SafeCall(self.Scan, self)     -- an item got a moment ago may not be noted yet
    local got = ns.char.got
    local notes = got and got[key]
    if not notes or #notes == 0 then return nil end
    local note = table.remove(notes)
    if #notes == 0 then got[key] = nil end
    return note
end

local scanQueued = false
local function QueueScan()
    if not loggedIn or scanQueued then return end
    scanQueued = true
    C_Timer.After(SCAN_DELAY, function()
        scanQueued = false
        ns.SafeCall(Sources.Scan, Sources)
    end)
end

-- Listening ---------------------------------------------------------------------

ns.On("PLAYER_LOGIN", function()
    loggedIn = true
    if ns.char.got then Trim(ns.char.got) end
    QueueScan()
end)
ns.On("BAG_UPDATE_DELAYED", QueueScan)
ns.On("PLAYER_EQUIPMENT_CHANGED", QueueScan)

-- Loot windows: each item with the mob, object or container it came from.
ns.On("LOOT_OPENED", function()
    lootOpen = true
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local ok, guid = pcall(GetLootSourceInfo, slot)
        guid = ok and guid or nil
        local id, kind = FromGUID(guid)
        Signal(link, "drop", { id = id, kind = kind, name = id and names[guid] or nil }, math.huge)
    end
end)
ns.On("PLAYER_TARGET_CHANGED", function() SeeUnit("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() SeeUnit("mouseover") end)
ns.On("NAME_PLATE_UNIT_ADDED", function(unit) SeeUnit(unit) end)

ns.On("LOOT_CLOSED", function()
    lootOpen = false
    Close("drop")
end)

ns.On("QUEST_LOOT_RECEIVED", function(questID, link)
    Signal(link, "quest", { id = questID })
end)

-- Loot messages: a roll won, something made, and loot with no window open
-- (a master looter's).
local lootMatchers = {
    { "roll", ns.ChatMatcher(LOOT_ROLL_YOU_WON or "You won: %s") },
    { "craft", ns.ChatMatcher(LOOT_ITEM_CREATED_SELF_MULTIPLE or "You create: %sx%d.") },
    { "craft", ns.ChatMatcher(LOOT_ITEM_CREATED_SELF or "You create: %s.") },
    { "drop", ns.ChatMatcher(LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d.") },
    { "drop", ns.ChatMatcher(LOOT_ITEM_SELF or "You receive loot: %s.") },
}
ns.On("CHAT_MSG_LOOT", function(msg)
    for _, m in ipairs(lootMatchers) do
        local link = m[2](msg)
        if link then
            -- Loot from a window is known already, with where it came from
            -- (with auto loot the message comes after the window has closed);
            -- a roll won arrives as loot too, and the roll says more.
            local key = Key(link)
            if m[1] ~= "drop" or not (lootOpen or key and (Signalled(key, "drop") or Signalled(key, "roll"))) then
                Signal(link, m[1])
            end
            return
        end
    end
end)

if BuyMerchantItem then
    hooksecurefunc("BuyMerchantItem", function(index)
        ns.SafeCall(function()
            local id = FromGUID(UnitGUID("npc"))
            Signal(GetMerchantItemLink(index), "vendor", { id = id, name = Plain(UnitName("npc")) })
        end)
    end)
end

-- Trades: what the other player puts in, while the window is open.
local function ReadTrade()
    Close("trade")
    local name = FullName(UnitName("NPC"))
    for slot = 1, TRADE_SLOTS do
        local link = GetTradeTargetItemLink and GetTradeTargetItemLink(slot)
        if link then Signal(link, "trade", { name = name }, math.huge) end
    end
end
ns.On("TRADE_TARGET_ITEM_CHANGED", ReadTrade)
ns.On("TRADE_ACCEPT_UPDATE", ReadTrade)
ns.On("TRADE_CLOSED", function() Close("trade") end)

-- Mail: the sender, or the auction house for an auction won.
local function TakeMail(index)
    local sender = Plain(select(3, GetInboxHeaderInfo(index)))
    local invoice = GetInboxInvoiceInfo and GetInboxInvoiceInfo(index)
    local how = invoice == "buyer" and "ah" or "mail"
    for item = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
        local link = GetInboxItemLink(index, item)
        if link then Signal(link, how, { name = how == "mail" and sender or nil }) end
    end
end
if TakeInboxItem then
    hooksecurefunc("TakeInboxItem", function(index) ns.SafeCall(TakeMail, index) end)
end
if AutoLootMailItem then
    hooksecurefunc("AutoLootMailItem", function(index) ns.SafeCall(TakeMail, index) end)
end

ns.On("BANKFRAME_OPENED", function()
    ns.SafeCall(Sources.Scan, Sources)
    bankOpen = true
end)
ns.On("BANKFRAME_CLOSED", function()
    ns.SafeCall(Sources.Scan, Sources)  -- still open: what came out of the bank is counted, not noted
    bankOpen = false
end)
