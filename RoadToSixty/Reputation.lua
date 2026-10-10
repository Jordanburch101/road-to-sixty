local _, ns = ...

-- Records reputation (issue #4) as journal events:
--   rep  factionID, standing, name, up   standing with a faction changed a
--                                        level (1 Hated to 8 Exalted); up =
--                                        true when it went up
--
-- ns.char.reps is the standing last seen per faction: factionID -> {
-- standing, name }, nil until first read. Factions known at the first read
-- are the baseline and log nothing, and so is a faction met later: meeting
-- one is not a change of standing. Only a change of level is logged, not
-- each gain, which would be thousands.
--
-- The client lists factions under headers the player can collapse, and a
-- collapsed header's factions are not in the list. Factions already known
-- are read by ID instead; to find new ones, a deep read opens every header
-- and closes them again afterwards. It runs at login and when the chat
-- names a faction not known yet, never on each UPDATE_FACTION, which fires
-- with every gain.
--
-- Forever is classic content on a modern client, so the modern
-- C_Reputation functions are used when they exist, else the classic ones.

local Reputation = {}
ns.Reputation = Reputation

local READY = 5     -- seconds after login before the first read; the list can be empty before

local Log = function(...) ns.Journal:Log(...) end

local ready = false
local scanning = false

-- The client's functions, modern first. Each returns nil when neither exists.
local R = C_Reputation or {}

local function Count()
    local fn = R.GetNumFactions or GetNumFactions
    return fn and fn() or 0
end

-- A faction as { id, name, standing, header, collapsed, hasRep } from the
-- modern table or the classic list of values.
local function FromData(data)
    if type(data) ~= "table" then return end
    return {
        id = data.factionID, name = data.name, standing = data.reaction,
        header = data.isHeader, collapsed = data.isCollapsed, hasRep = data.isHeaderWithRep,
    }
end

local function FromValues(name, _, standing, _, _, _, _, _, header, collapsed, hasRep, _, _, id)
    if not name then return end
    return { id = id, name = name, standing = standing, header = header, collapsed = collapsed, hasRep = hasRep }
end

local function AtIndex(i)
    if R.GetFactionDataByIndex then
        local ok, data = pcall(R.GetFactionDataByIndex, i)
        return ok and FromData(data) or nil
    end
    return GetFactionInfo and FromValues(GetFactionInfo(i))
end

local function ByID(id)
    if R.GetFactionDataByID then
        local ok, data = pcall(R.GetFactionDataByID, id)
        return ok and FromData(data) or nil
    end
    return GetFactionInfoByID and FromValues(GetFactionInfoByID(id))
end

local function Expand(i)
    local fn = R.ExpandFactionHeader or ExpandFactionHeader
    if fn then pcall(fn, i) end
end

local function Collapse(i)
    local fn = R.CollapseFactionHeader or CollapseFactionHeader
    if fn then pcall(fn, i) end
end

-- Whether a faction has a standing of its own: not a plain header.
local function Counts(f)
    return f.id and f.standing and (not f.header or f.hasRep)
end

-- Opens every collapsed header, calls fn, then closes them again. Opening a
-- header puts its factions right after it, so the loop goes on into them
-- and opens headers inside it too. Closing goes from the end, so closing
-- one does not move the headers still to close.
local function Opened(fn)
    local opened = {}
    local i = 1
    while i <= Count() do
        local f = AtIndex(i)
        if f and f.header and f.collapsed then
            Expand(i)
            opened[f.name] = true
        end
        i = i + 1
    end
    fn()
    for k = Count(), 1, -1 do
        local f = AtIndex(k)
        if f and f.header and not f.collapsed and opened[f.name] then
            Collapse(k)
        end
    end
end

-- Standings now: factionID -> { standing, name }. deep opens collapsed
-- headers to find factions not known yet; otherwise known ones hidden under
-- them are read by ID.
function Reputation:Read(deep)
    local now = {}
    local function List()
        for i = 1, Count() do
            local f = AtIndex(i)
            if f and Counts(f) then
                now[f.id] = { f.standing, f.name }
            end
        end
    end
    if deep then
        scanning = true
        local ok, err = pcall(Opened, List)
        scanning = false
        if not ok then error(err) end
    else
        List()
    end
    for id in pairs(ns.char.reps or {}) do
        if not now[id] then
            local f = ByID(id)
            if f and f.standing then
                now[id] = { f.standing, f.name }
            end
        end
    end
    return now
end

-- Compares the standings with the last ones seen and logs each change of level.
function Reputation:Check(deep)
    -- A seeded test journey has made-up standings; the real ones would not fit it.
    if not ready or scanning or ns.char.seeded then return end
    local now = self:Read(deep)
    if next(now) == nil then return end     -- not loaded yet
    local known = ns.char.reps or {}
    for id, f in pairs(now) do
        local old = known[id]
        if old and old[1] ~= f[1] then
            Log("rep", id, f[1], f[2], f[1] > old[1] or nil)
        end
        known[id] = f
    end
    ns.char.reps = known
end

-- Showing them ------------------------------------------------------------------

Reputation.ICON = "Interface\\Icons\\Achievement_Reputation_01"

local LABELS = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }
local COLORS = {
    { 0.8, 0.3, 0.22 }, { 0.8, 0.3, 0.22 }, { 0.75, 0.27, 0 }, { 0.9, 0.7, 0 },
    { 0, 0.6, 0.1 }, { 0, 0.6, 0.1 }, { 0, 0.6, 0.1 }, { 0, 0.6, 0.1 },
}

-- A standing's name, in the client's language when it has one.
function Reputation:Label(standing)
    return _G["FACTION_STANDING_LABEL" .. tostring(standing)] or LABELS[standing] or "?"
end

-- A standing's colour as r, g, b, the one the client's reputation bars use.
function Reputation:Color(standing)
    local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[standing]
    if c then return c.r, c.g, c.b end
    return unpack(COLORS[standing] or { 1, 1, 1 })
end

-- How to show a rep event: title, detail (what kind of entry, to go before
-- the place) and icon.
function Reputation:Describe(e)
    local standing, name, up = e[7], e[8] or "?", e[9]
    local label = self:Label(standing)
    if up then
        return ("%s with %s"):format(label, name), "Reputation", self.ICON
    end
    return ("Dropped to %s with %s"):format(label, name), "Reputation", self.ICON
end

-- Factions of the journey shown, best standing first: { name, standing, t },
-- t when the standing was reached, nil if before tracking or on meeting
-- the faction. Neutral and below only when nothing is better.
function Reputation:Standings()
    local reached = {}
    for _, e in ipairs(ns.view.events) do
        if e[2] == "rep" then reached[e[6]] = e[1] end
    end
    local list = {}
    for id, f in pairs(ns.view.reps or {}) do
        list[#list + 1] = { f[2] or "?", f[1] or 0, reached[id] }
    end
    table.sort(list, function(a, b)
        if a[2] ~= b[2] then return a[2] > b[2] end
        return a[1] < b[1]
    end)
    return list
end

-- Listening ---------------------------------------------------------------------

-- "You are now %s with %s." as a pattern giving the faction's name.
local changedPattern = "^" .. (FACTION_STANDING_CHANGED or "You are now %s with %s.")
    :gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)")

local function Known(name)
    for _, f in pairs(ns.char.reps or {}) do
        if f[2] == name then return true end
    end
    return false
end

ns.On("PLAYER_LOGIN", function()
    C_Timer.After(READY, function()
        ready = true
        ns.SafeCall(Reputation.Check, Reputation, true)
    end)
end)
ns.On("UPDATE_FACTION", function() Reputation:Check() end)

ns.On("CHAT_MSG_SYSTEM", function(msg)
    local _, name = msg:match(changedPattern)
    if name then
        -- A faction met under a collapsed header is only found by opening it.
        Reputation:Check(not Known(name))
    end
end)

--@debug@
-- /rts repprobe: what the reputation APIs return now, and what is recorded.
ns.Command("repprobe", "check the reputation APIs (developer)", function()
    local api = {}
    for _, name in ipairs({ "GetNumFactions", "GetFactionDataByIndex", "GetFactionDataByID",
        "ExpandFactionHeader", "CollapseFactionHeader" }) do
        api[#api + 1] = ("C_Reputation.%s %s"):format(name, R[name] and "yes" or "no")
    end
    for _, name in ipairs({ "GetNumFactions", "GetFactionInfo", "GetFactionInfoByID",
        "ExpandFactionHeader", "CollapseFactionHeader" }) do
        api[#api + 1] = ("%s %s"):format(name, _G[name] and "yes" or "no")
    end
    ns.Print(table.concat(api, ", "))

    local headers, collapsed, factions, sample = 0, 0, 0, nil
    for i = 1, Count() do
        local f = AtIndex(i)
        if f and f.header then
            headers = headers + 1
            if f.collapsed then collapsed = collapsed + 1 end
        end
        if f and Counts(f) then
            factions = factions + 1
            sample = sample or f
        end
    end
    ns.Print(("Listed: %d rows, %d headers (%d collapsed), %d factions."):format(
        Count(), headers, collapsed, factions))
    if sample then
        local byID = ByID(sample.id)
        ns.Print(("First: %s, ID %s, standing %s (%s); by ID: %s."):format(tostring(sample.name),
            tostring(sample.id), tostring(sample.standing), Reputation:Label(sample.standing),
            byID and tostring(byID.standing) or "nothing"))
    end

    local deep, count = Reputation:Read(true), 0
    for _ in pairs(deep) do count = count + 1 end
    local known = 0
    for _ in pairs(ns.char.reps or {}) do known = known + 1 end
    local logged, last = 0, nil
    for _, e in ipairs(ns.char.events) do
        if e[2] == "rep" then
            logged, last = logged + 1, e
        end
    end
    ns.Print(("With headers opened: %d factions. Recorded: %d known, %d rep events%s."):format(
        count, known, logged, last and (", last " .. (Reputation:Describe(last))) or ""))
end)
--@end-debug@
