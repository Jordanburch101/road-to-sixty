local _, ns = ...

-- Repairs to saved journeys that the addon makes at every login, as plain
-- functions of the data with no game calls, so the merge and the sync
-- server tidy both copies of a journey exactly as a login would before
-- merging them. Each changes the journey it is given in place.

local Tidy = {}
ns.Tidy = Tidy

-- Seconds between leaving an instance and going back in that still count
-- as one run.
Tidy.RUN_GAP = 30 * 60

-- Everyone in either list of guids, once each, in order; nil if no one.
local function MergeParty(a, b)
    local seen, list = {}, {}
    for _, party in ipairs({ a or {}, b or {} }) do
        for _, guid in ipairs(party) do
            if not seen[guid] then
                seen[guid] = true
                list[#list + 1] = guid
            end
        end
    end
    return #list > 0 and list or nil
end

-- Joins runs that earlier versions split in two when the character died
-- and ran back in: an "out" followed within RUN_GAP by an "in" to the same
-- instance, with no other instance and no group starting or ending
-- between, becomes one run.
function Tidy.Runs(char)
    local events = char.events
    local i = 1
    while i <= #events do
        local out = events[i]
        local back = events[i + 1]
        local k = i + 1
        local regrouped = false
        while back and back[2] ~= "in" and back[2] ~= "out" do
            regrouped = regrouped or back[2] == "grp" or back[2] == "grpx"
            k = k + 1
            back = events[k]
        end
        if out[2] == "out" and not regrouped and back and back[2] == "in" and back[6] == out[6]
            and back[1] - out[1] < Tidy.RUN_GAP and type(out[7]) == "table" then
            local first = out[7]
            -- Where the second part's summary goes: its own "out", or the
            -- run still going on.
            local j = k + 1
            while events[j] and events[j][2] ~= "out" and events[j][2] ~= "in" do
                j = j + 1
            end
            local second = events[j]
            local merged = true
            if second and second[2] == "out" and second[6] == out[6] and type(second[7]) == "table" then
                local s = second[7]
                s.duration = s.duration + first.duration + (back[1] - out[1])
                s.kills, s.xp, s.deaths = s.kills + first.kills, s.xp + first.xp, s.deaths + first.deaths
                s.money, s.levels = s.money + first.money, s.levels + first.levels
                for n, link in ipairs(first.items) do
                    table.insert(s.items, n, link)
                end
                s.party = MergeParty(first.party, s.party)
            elseif not second and char.run and char.instance == out[6] then
                local run = char.run
                run.t = run.t - first.duration - (back[1] - out[1])
                run.kills, run.xp, run.deaths = run.kills - first.kills, run.xp - first.xp, run.deaths - first.deaths
                run.money, run.level = run.money - first.money, run.level - first.levels
                for n, link in ipairs(first.items) do
                    table.insert(run.items, n, link)
                end
                run.party = run.party or {}
                for _, guid in ipairs(first.party or {}) do
                    run.party[guid] = true
                end
            else
                merged = false
            end
            if merged then
                table.remove(events, k)
                table.remove(events, i)
                char.totals.instances = math.max(0, char.totals.instances - 1)
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

-- Takes out events that versions up to 1.5.0 saved wrongly, from a journey
-- (a character's, or a roster copy): "zone" events for a continent, and a
-- death logged a second time in the same second (the client fired
-- PLAYER_DEAD twice), which the totals counted too. isPlace(mapID) says
-- whether a map is a place rather than a continent: ns.IsPlaceMap in game,
-- a table from the map data on the server.
function Tidy.Events(journey, isPlace)
    local events, kept, lastDeath = journey.events or {}, 0, nil
    local doubled = 0
    for i = 1, #events do
        local e = events[i]
        local keep = true
        if e[2] == "zone" then
            keep = isPlace(e[6])
        elseif e[2] == "die" then
            keep = e[1] ~= lastDeath
            doubled = doubled + (keep and 0 or 1)
            lastDeath = e[1]
        end
        if keep then
            kept = kept + 1
            events[kept] = e
        end
    end
    for i = #events, kept + 1, -1 do
        events[i] = nil
    end
    if doubled > 0 and journey.totals then
        journey.totals.deaths = math.max(0, journey.totals.deaths - doubled)
    end
end

-- True if a guild tabard has what drawing it needs (see Guilds:ReadTabard).
function Tidy.TabardComplete(tabard)
    return tabard and tabard.bg and tabard.border and true or false
end

-- Repairs what earlier versions saved wrongly in guild events: rank
-- changes logged when only the rank number flickered (the rank name the
-- same as before), and joins saved with a tabard missing its colours,
-- filled from the current guild's when it has them. char.guild is
-- { name, rank, rankIndex, tabard }, false in no guild, or nil unread.
function Tidy.Guilds(char)
    local events, ranks = char.events, {}
    local known = char.guild
    local Complete = Tidy.TabardComplete
    for i = #events, 1, -1 do
        local e = events[i]
        if e[2] == "gj" and known and e[6] == known[1] and not Complete(e[9]) and Complete(known[4]) then
            e[9] = known[4]
        end
    end
    local i = 1
    while i <= #events do
        local e = events[i]
        if e[2] == "gj" then
            ranks[e[6]] = e[7]
        elseif e[2] == "gr" then
            if ranks[e[6]] == e[7] then
                table.remove(events, i)
                i = i - 1
            else
                ranks[e[6]] = e[7]
            end
        end
        i = i + 1
    end
    if known and not Complete(known[4]) then
        known[4] = nil
    end
end
