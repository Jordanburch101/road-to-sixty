local _, ns = ...

-- Records the groups the character is in and the players met in them
-- (issue #16), as journal events:
--   grp   kind, members, leader   joined or formed a group: kind "party" or
--                                 "raid"; members = the others in it then;
--                                 leader = true when the player led it
--   grpa  member                  someone joined the group later
--   grpx  summary                 the group ended (left, disbanded, or found
--                                 gone at login): { duration, kills, xp,
--                                 quests, deaths, instances, met = players
--                                 grouped with in it }
-- A member is { guid, name, race, sex, class, level }: name "Name-Realm" for
-- another realm, race and class as the client's file names (NightElf,
-- WARRIOR), sex "Male" or "Female", level when they joined. Details the
-- client had not loaded yet are filled in on a later roster update.
--
-- ns.char.people is everyone grouped with: guid -> { name, race, sex,
-- class, level (last seen), first, last (times), c, x, y (where first met),
-- groups (separate groups shared), seconds (time grouped), dungeons (runs
-- together) }. It is what "who you met" and the counts are built from.
--
-- ns.char.group is the group now, saved so it survives a reload or logout:
-- { t, kind, totals at the start, members = guid -> time joined (those in
-- it now), everMet = guid -> true (all who were in it), met = their count,
-- seen = last time it was known to still exist }.
--
-- Groups inside battlegrounds and other instance groups are left out: only
-- the player's own (home) group counts.

local Groups = {}
ns.Groups = Groups

local READY = 5             -- seconds after login before reading the group
local SETTLE = 0.5          -- roster updates come in bursts; read once after them
local SEXES = { [2] = "Male", [3] = "Female" }

local ready = false
local pending = false

local function InGroup()
    if LE_PARTY_CATEGORY_HOME then
        return IsInGroup(LE_PARTY_CATEGORY_HOME)
    end
    return IsInGroup()
end

-- A unit as a member, or nil when the client does not know it well enough yet.
local function ReadUnit(unit)
    local guid = UnitGUID(unit)
    local name, realm = UnitName(unit)
    if not guid or not name or name == UNKNOWNOBJECT or name == "" then return end
    local _, race = UnitRace(unit)
    local _, class = UnitClass(unit)
    local level = UnitLevel(unit)
    return {
        guid, realm and realm ~= "" and (name .. "-" .. realm) or name, race,
        SEXES[UnitSex(unit)], class, level and level > 0 and level or nil,
    }
end

-- The others in the group now: guid -> member.
function Groups:Read()
    local roster = {}
    local raid = IsInRaid()
    local count = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
    for i = 1, count do
        local unit = (raid and "raid" or "party") .. i
        if not UnitIsUnit(unit, "player") then
            local m = ReadUnit(unit)
            if m then roster[m[1]] = m end
        end
    end
    return roster, raid and "raid" or "party"
end

-- Notes a member in ns.char.people: met now, or seen again.
local function Meet(m, t, newGroup)
    local people = ns.char.people
    local p = people[m[1]]
    if not p then
        local c, x, y = ns.Recorder:Position()
        p = { first = t, c = c, x = x, y = y, groups = 0, seconds = 0, dungeons = 0 }
        people[m[1]] = p
    end
    p.name, p.race, p.sex, p.class = m[2], m[3] or p.race, m[4] or p.sex, m[5] or p.class
    p.level = m[6] or p.level
    p.last = t
    if newGroup then p.groups = p.groups + 1 end
end

-- Adds the time a member spent in the group up to t to their total.
local function Part(guid, since, t)
    local p = ns.char.people[guid]
    if p and since then
        p.seconds = p.seconds + math.max(0, t - since)
        p.last = t
    end
end

local function Start(roster, kind, t)
    local totals = ns.char.totals
    local members, everMet, list = {}, {}, {}
    for guid, m in pairs(roster) do
        members[guid], everMet[guid] = t, true
        list[#list + 1] = m
        Meet(m, t, true)
    end
    ns.char.group = {
        t = t, kind = kind, members = members, everMet = everMet, seen = t, met = #list,
        kills = totals.kills, xp = totals.killXP + totals.questXP, quests = totals.quests,
        deaths = totals.deaths, instances = totals.instances,
    }
    ns.Journal:Log("grp", kind, list, UnitIsGroupLeader("player") or nil)
end

-- Logs the group's end at time t (now, or when it was last known to exist).
local function End(t)
    local g, totals = ns.char.group, ns.char.totals
    for guid, since in pairs(g.members) do
        Part(guid, since, t)
    end
    local summary = {
        duration = math.max(0, t - g.t),
        kills = totals.kills - g.kills,
        xp = totals.killXP + totals.questXP - g.xp,
        quests = totals.quests - g.quests,
        deaths = totals.deaths - g.deaths,
        instances = totals.instances - g.instances,
        met = g.met,
    }
    ns.char.group = nil
    -- Found gone at login: the event goes where it happened, among this
    -- session's first events, so the journal stays in time order.
    local c, x, y = ns.Recorder:Position()
    local e = { t, "grpx", c or -1, x or 0, y or 0, summary }
    local events = ns.char.events
    local at = #events + 1
    while at > 1 and events[at - 1][1] > t do
        at = at - 1
    end
    table.insert(events, at, e)
end

-- Fills in what the client had not loaded when a member was logged.
local function FillIn(roster)
    for i = #ns.char.events, 1, -1 do
        local e = ns.char.events[i]
        if e[2] == "grp" or e[2] == "grpa" then
            local list = e[2] == "grp" and e[7] or { e[6] }
            for _, m in ipairs(list) do
                local now = roster[m[1]]
                if now then
                    m[3], m[4], m[5], m[6] = m[3] or now[3], m[4] or now[4], m[5] or now[5], m[6] or now[6]
                end
            end
            if e[2] == "grp" then break end
        end
    end
end

-- Compares the group with the one saved and logs what changed.
function Groups:Check()
    if not ready or ns.char.seeded then return end
    local g, t = ns.char.group, time()
    if not InGroup() then
        if g then End(t) end
        return
    end
    local roster, kind = self:Read()
    if not g then
        Start(roster, kind, t)
        return
    end
    g.seen = t
    g.kind = kind == "raid" and "raid" or g.kind
    for guid, m in pairs(roster) do
        if not g.members[guid] then
            g.members[guid] = t
            -- Someone leaving and coming back is still the same group.
            if not g.everMet[guid] then
                g.everMet[guid] = true
                g.met = g.met + 1
                Meet(m, t, true)
                ns.Journal:Log("grpa", m)
            else
                Meet(m, t, false)
            end
        else
            Meet(m, t, false)
        end
    end
    for guid, since in pairs(g.members) do
        if not roster[guid] then
            Part(guid, since, t)
            g.members[guid] = nil
        end
    end
    FillIn(roster)
end

-- After a reload or logout: a group still there carries on, with the time
-- away not counted; one gone since ended when it was last seen.
function Groups:Resume()
    local g = ns.char.group
    if not g then return end
    if InGroup() then
        local t = time()
        for guid, since in pairs(g.members) do
            Part(guid, since, g.seen)
            g.members[guid] = t
        end
        g.seen = t
    else
        End(g.seen)
    end
end

-- The guids of the others in the group now, for a dungeon run's summary.
function Groups:Current()
    local g = ns.char.group
    if not g then return end
    local list = {}
    for guid in pairs(g.members) do
        list[#list + 1] = guid
    end
    return #list > 0 and list or nil
end

-- Counts a dungeon run for everyone in it (called when the run ends).
function Groups:CountRun(guids)
    for _, guid in ipairs(guids or {}) do
        local p = ns.char.people[guid]
        if p then p.dungeons = p.dungeons + 1 end
    end
end

local function CheckSoon()
    if pending then return end
    pending = true
    C_Timer.After(SETTLE, function()
        pending = false
        ns.SafeCall(Groups.Check, Groups)
    end)
end

ns.On("PLAYER_LOGIN", function()
    C_Timer.After(READY, function()
        ready = true
        ns.SafeCall(function()
            Groups:Resume()
            Groups:Check()
        end)
    end)
end)
ns.On("GROUP_ROSTER_UPDATE", CheckSoon)
ns.On("GROUP_LEFT", CheckSoon)
ns.On("PLAYER_LOGOUT", function()
    if ns.char.group then ns.char.group.seen = time() end
end)

--@debug@
-- /rts people: the group now and everyone met, to check the recording.
ns.Command("people", "list the group and the players met (developer)", function()
    local g = ns.char.group
    if g then
        local count = 0
        for _ in pairs(g.members) do count = count + 1 end
        ns.Print(("In a %s since %s with %d others, %d met in it."):format(g.kind, date("%H:%M", g.t), count, g.met))
    else
        ns.Print("Not in a group.")
    end
    local n = 0
    for _, p in pairs(ns.char.people) do
        n = n + 1
        ns.Print(("%s: %s %s %s level %s, %d groups, %dm together, %d dungeons, first %s"):format(
            tostring(p.name), tostring(p.sex), tostring(p.race), tostring(p.class), tostring(p.level),
            p.groups, math.floor(p.seconds / 60), p.dungeons, date("%d %b %H:%M", p.first)))
    end
    ns.Print(n .. " players met.")
end)
--@end-debug@
