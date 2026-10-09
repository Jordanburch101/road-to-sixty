local _, ns = ...

-- Records the groups the character is in and the players met in them
-- (issue #16). Groups change all the time, raids most: people join late,
-- leave, come back and move between subgroups. Every change is logged, so
-- who was there at any moment can be worked out later. Journal events:
--   grp   kind, members, leader, subgroup
--                                 joined or formed a group: kind "party" or
--                                 "raid"; members = the others in it then;
--                                 leader = true when the player led it;
--                                 subgroup = the player's own, in a raid
--   grpa  member                  someone joined, or came back
--   grpl  guid, level             someone left, at that level
--   grps  guid, subgroup          someone moved to another raid subgroup;
--                                 guid false for the player
--   grpk  kind                    the group became a raid, or a party again
--   grpx  summary                 the group ended (left, disbanded, or found
--                                 gone at login): { duration, kills, xp,
--                                 quests, deaths, instances, met = players
--                                 who were in it, levels = guid -> level of
--                                 those still in it at the end }
-- A member is { guid, name, race, sex, class, level, guild, subgroup }: name
-- "Name-Realm" for another realm, race and class as the client's file names
-- (NightElf, WARRIOR), sex "Male" or "Female", level and guild when they
-- joined, subgroup 1-8 in a raid. Details the client had not loaded yet are
-- filled in on a later roster update.
--
-- ns.char.people is everyone grouped with: guid -> { name, race, sex,
-- class, level, guild (last seen), first, last (times), c, x, y (where first
-- met), groups, seconds (party groups shared, time in them), raids,
-- raidSeconds (the same for raids), dungeons, raidRuns (dungeon and raid
-- instances run together, by the instance's type) }.
-- Parties and raids are counted apart, so forty strangers in a raid do not
-- crowd out the people actually played with.
--
-- ns.char.group is the group now, saved so it survives a reload or logout:
-- { t, kind, totals at the start, members = guid -> time joined (those in
-- it now), everMet = guid -> true (all who were ever in it), met = their
-- count, levels and subs = guid -> level and subgroup last seen, mySub =
-- the player's subgroup, seen =
-- last time it was known to still exist }.
--
-- Groups inside battlegrounds and other instance groups are left out: only
-- the player's own (home) group counts.

local Groups = {}
ns.Groups = Groups

local READY = 5             -- seconds after login before reading the group
local SETTLE = 0.5          -- roster updates come in bursts; read once after them
local FORMING = 10          -- seconds after a group starts in which members still count as there from its start
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
local function ReadUnit(unit, subgroup)
    local guid = UnitGUID(unit)
    local name, realm = UnitName(unit)
    if not guid or not name or name == UNKNOWNOBJECT or name == "" then return end
    local _, race = UnitRace(unit)
    local _, class = UnitClass(unit)
    local level = UnitLevel(unit)
    local guild = GetGuildInfo(unit)
    return {
        guid, realm and realm ~= "" and (name .. "-" .. realm) or name, race,
        SEXES[UnitSex(unit)], class, level and level > 0 and level or nil, guild, subgroup,
    }
end

-- The others in the group now: guid -> member, the kind of group, and
-- the player's own subgroup in a raid.
function Groups:Read()
    local roster, mySub = {}, nil
    local raid = IsInRaid()
    local count = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
    for i = 1, count do
        local unit = (raid and "raid" or "party") .. i
        local subgroup = raid and select(3, GetRaidRosterInfo(i)) or nil
        if UnitIsUnit(unit, "player") then
            mySub = subgroup
        else
            local m = ReadUnit(unit, subgroup)
            if m then roster[m[1]] = m end
        end
    end
    return roster, raid and "raid" or "party", mySub
end

-- Notes a member in ns.char.people: met now, or seen again. newGroup is
-- the kind of group when they are new to it, to count it.
local function Meet(m, t, newGroup)
    local people = ns.char.people
    local p = people[m[1]]
    if not p then
        local c, x, y = ns.Recorder:Position()
        p = { first = t, c = c, x = x, y = y }
        people[m[1]] = p
    end
    p.groups, p.seconds, p.dungeons = p.groups or 0, p.seconds or 0, p.dungeons or 0
    p.raids, p.raidSeconds, p.raidRuns = p.raids or 0, p.raidSeconds or 0, p.raidRuns or 0
    p.name, p.race, p.sex, p.class = m[2], m[3] or p.race, m[4] or p.sex, m[5] or p.class
    p.level, p.guild = m[6] or p.level, m[7] or p.guild
    p.last = t
    if newGroup == "raid" then
        p.raids = p.raids + 1
    elseif newGroup then
        p.groups = p.groups + 1
    end
end

-- Adds the time a member spent in a group of kind up to t to their total.
local function Part(guid, since, t, kind)
    local p = ns.char.people[guid]
    if p and since then
        local seconds = math.max(0, t - since)
        if kind == "raid" then
            p.raidSeconds = (p.raidSeconds or 0) + seconds
        else
            p.seconds = (p.seconds or 0) + seconds
        end
        p.last = t
    end
end

local function Start(roster, kind, mySub, t)
    local totals = ns.char.totals
    local members, everMet, levels, subs, list = {}, {}, {}, {}, {}
    for guid, m in pairs(roster) do
        members[guid], everMet[guid] = t, true
        levels[guid], subs[guid] = m[6], m[8]
        list[#list + 1] = m
        Meet(m, t, kind)
    end
    ns.char.group = {
        t = t, kind = kind, members = members, everMet = everMet, levels = levels, subs = subs,
        seen = t, met = #list, mySub = mySub,
        kills = totals.kills, xp = totals.killXP + totals.questXP, quests = totals.quests,
        deaths = totals.deaths, instances = totals.instances,
    }
    ns.Journal:Log("grp", kind, list, UnitIsGroupLeader("player") or nil, mySub)
end

-- Logs the group's end at time t (now, or when it was last known to exist).
local function End(t)
    local g, totals = ns.char.group, ns.char.totals
    local levels = {}
    for guid, since in pairs(g.members) do
        Part(guid, since, t, g.kind)
        levels[guid] = g.levels[guid]
    end
    local summary = {
        duration = math.max(0, t - g.t),
        kills = totals.kills - g.kills,
        xp = totals.killXP + totals.questXP - g.xp,
        quests = totals.quests - g.quests,
        deaths = totals.deaths - g.deaths,
        instances = totals.instances - g.instances,
        met = g.met,
        levels = levels,
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

-- Fills in what the client had not loaded when members were logged, in
-- this group's events.
local function FillIn(roster)
    for i = #ns.char.events, 1, -1 do
        local e = ns.char.events[i]
        if e[2] == "grp" or e[2] == "grpa" then
            local list = e[2] == "grp" and e[7] or { e[6] }
            for _, m in ipairs(list) do
                local now = roster[m[1]]
                if now then
                    for k = 3, 8 do
                        m[k] = m[k] or now[k]
                    end
                end
            end
            if e[2] == "grp" then break end
        end
    end
end

-- The grp event that started the group now.
local function StartEvent()
    local events = ns.char.events
    for i = #events, 1, -1 do
        if events[i][2] == "grp" then return events[i] end
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
    local roster, kind, mySub = self:Read()
    if not g then
        Start(roster, kind, mySub, t)
        return
    end
    g.seen = t
    g.levels, g.subs = g.levels or {}, g.subs or {}

    -- A party becoming a raid (or back): time so far counts as the old kind.
    if kind ~= g.kind then
        for guid, since in pairs(g.members) do
            Part(guid, since, t, g.kind)
            g.members[guid] = t
        end
        g.kind = kind
        ns.Journal:Log("grpk", kind)
    end
    if mySub and mySub ~= g.mySub then
        if g.mySub then ns.Journal:Log("grps", false, mySub) end
        g.mySub = mySub
    end

    for guid, since in pairs(g.members) do
        if not roster[guid] then
            Part(guid, since, t, g.kind)
            g.members[guid] = nil
            ns.Journal:Log("grpl", guid, g.levels[guid])
        end
    end
    for guid, m in pairs(roster) do
        if not g.members[guid] then
            g.members[guid] = t
            -- Someone coming back is logged, but still the same group to them.
            local new = not g.everMet[guid]
            if new then
                g.everMet[guid] = true
                g.met = g.met + 1
            end
            Meet(m, t, new and kind)
            -- The client can take a moment to know who is in a group just
            -- joined, so those appearing in its first seconds belong to it
            -- from the start.
            local start = new and t - g.t <= FORMING and StartEvent()
            if start then
                table.insert(start[7], m)
            else
                ns.Journal:Log("grpa", m)
            end
        else
            Meet(m, t, nil)
            if m[8] and g.subs[guid] and m[8] ~= g.subs[guid] then
                ns.Journal:Log("grps", guid, m[8])
            end
        end
        ns.Journal:JoinRun(guid)
        g.levels[guid] = m[6] or g.levels[guid]
        g.subs[guid] = m[8] or g.subs[guid]
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
            Part(guid, since, g.seen, g.kind)
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

-- Counts a dungeon or raid run (raid true) for everyone in it (called
-- when the run ends).
function Groups:CountRun(guids, raid)
    for _, guid in ipairs(guids or {}) do
        local p = ns.char.people[guid]
        if p then
            if raid then
                p.raidRuns = (p.raidRuns or 0) + 1
            else
                p.dungeons = (p.dungeons or 0) + 1
            end
        end
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
        ns.Print(("%s <%s>: %s %s %s level %s; parties %d, %dm, %d dungeons; raids %d, %dm, %d runs; first %s"):format(
            tostring(p.name), tostring(p.guild), tostring(p.sex), tostring(p.race), tostring(p.class),
            tostring(p.level), p.groups or 0, math.floor((p.seconds or 0) / 60), p.dungeons or 0,
            p.raids or 0, math.floor((p.raidSeconds or 0) / 60), p.raidRuns or 0, date("%d %b %H:%M", p.first)))
    end
    ns.Print(n .. " players met.")
end)
--@end-debug@
