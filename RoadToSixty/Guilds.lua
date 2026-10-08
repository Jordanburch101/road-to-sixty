local _, ns = ...

-- Records guild membership (issue #5) as journal events:
--   gj  name, rank, baseline, tabard   joined a guild; baseline = true for
--                                       the guild the character was already
--                                       in when tracking began
--   gl  name, how                      left it; how "k" when kicked, "d" when
--                                       the guild was disbanded, nil when the
--                                       player left (or the client did not say)
--   gr  name, rank, up                 rank changed; up = true for a promotion
--
-- ns.char.guild is the guild last seen: { name, rank, rankIndex, tabard },
-- false when in none, nil until first read. Ranks are compared by index, as
-- guild masters can rename them; a lower index is a higher rank.
--
-- tabard is what the client tells about the guild's tabard, saved so it can
-- be drawn later, also for other characters: { files = the six
-- GetGuildTabardFiles file IDs, emblem = file ID, style = emblem style,
-- bg / border / emblemColor = { r, g, b } }, each part only when the client
-- has it; nil for a guild without a tabard.
--
-- Guild info is empty for a moment after login and loading screens, so
-- nothing is read until GUILD_READY seconds after login, a missing name is
-- read again shortly, and leaving is only logged once still out of the guild
-- LEAVE_CONFIRM seconds later.

local Guilds = {}
ns.Guilds = Guilds

local GUILD_READY = 5
local RETRY = 2
local LEAVE_CONFIRM = 3
local HOW_SECONDS = 30      -- a kick or disband message counts for a leave this soon after it

local Log = function(...) ns.Journal:Log(...) end

local ready = false
local retrying = false
local leaving = false
local how = { kind = nil, at = 0 }  -- last kick or disband message

local function Color(c)
    if type(c) == "table" and c.r then
        return { c.r, c.g, c.b }
    end
end

-- The tabard as the client describes it, or nil.
function Guilds:ReadTabard()
    local tabard = {}
    if C_GuildInfo and C_GuildInfo.GetGuildTabardInfo then
        local ok, info = pcall(C_GuildInfo.GetGuildTabardInfo, "player")
        if ok and type(info) == "table" then
            tabard.emblem, tabard.style = info.emblemFileID, info.emblemStyle
            tabard.bg = Color(info.backgroundColor)
            tabard.border = Color(info.borderColor)
            tabard.emblemColor = Color(info.emblemColor)
        end
    end
    if GetGuildTabardFiles then
        local files = { pcall(GetGuildTabardFiles) }
        if table.remove(files, 1) and files[1] then
            tabard.files = files
        end
    end
    return next(tabard) and tabard or nil
end

-- The guild now: { name, rank, rankIndex }, false when in none, or nil when
-- the client has not loaded it yet.
function Guilds:Read()
    if not IsInGuild() then return false end
    local name, rank, rankIndex = GetGuildInfo("player")
    if not name then return nil end
    return { name, rank, rankIndex }
end

local function RetrySoon()
    if retrying then return end
    retrying = true
    C_Timer.After(RETRY, function()
        retrying = false
        ns.SafeCall(Guilds.Check, Guilds)
    end)
end

-- Compares the guild with the last one seen and logs what changed.
function Guilds:Check()
    -- A seeded test journey has a made-up guild; the real one would not fit it.
    if not ready or ns.char.seeded then return end
    local now = self:Read()
    if now == nil then
        RetrySoon()
        return
    end
    local known = ns.char.guild

    if known == nil then
        if now then
            now[4] = self:ReadTabard()
            Log("gj", now[1], now[2], true, now[4])
        end
        ns.char.guild = now
        return
    end

    if not now then
        if known and not leaving then
            -- Confirmed a moment later, in case the client only lost it briefly.
            leaving = true
            C_Timer.After(LEAVE_CONFIRM, function()
                leaving = false
                ns.SafeCall(function()
                    if self:Read() == false and ns.char.guild then
                        local kind = GetTime() - how.at <= HOW_SECONDS and how.kind or nil
                        Log("gl", ns.char.guild[1], kind)
                        ns.char.guild = false
                    end
                end)
            end)
        end
        return
    end

    if not known or known[1] ~= now[1] then
        -- Moved straight to another guild without the leave being seen.
        if known then
            Log("gl", known[1])
        end
        now[4] = self:ReadTabard()
        Log("gj", now[1], now[2], nil, now[4])
        ns.char.guild = now
        return
    end

    if now[3] and known[3] and now[3] ~= known[3] then
        Log("gr", now[1], now[2], now[3] < known[3])
    end
    known[2], known[3] = now[2], now[3]
    -- A tabard designed or changed later is kept for drawing, not logged.
    -- Tabard data can come a moment after the join, so a join saved without
    -- one gets it then.
    local tabard = self:ReadTabard()
    if tabard then
        known[4] = tabard
        local events = ns.char.events
        for i = #events, 1, -1 do
            local e = events[i]
            if e[2] == "gj" then
                if e[6] == known[1] and not e[9] then
                    e[9] = tabard
                end
                break
            end
        end
    end
end

-- Showing them ------------------------------------------------------------------

-- The guild tabard item, for the History filter's Guild button.
Guilds.ICON = "Interface\\Icons\\INV_Shirt_GuildTabard_01"

-- interface/guildframe/guildinspect-parts (512 x 512) holds the retail guild
-- banner: its white cloth, tinted with the tabard's background colour, and
-- its outline, tinted with the border colour. Texture coordinates of each.
-- The cloth (120 x 146 pixels with its soft shadow) is solid from 7 pixels
-- in on the left to 6 on the right and 7 from the bottom. The outline is a
-- little smaller than that, so it is stretched over the solid part.
local BANNER_PARTS = 458233
local BANNER_CLOTH = { 120 / 512, 240 / 512, 358 / 512, 504 / 512 }
local BANNER_BORDER = { 10 / 512, 112 / 512, 358 / 512, 497 / 512 }
local BANNER_WIDTH = 120 / 146      -- of its height
local BORDER_SIZE = { 108 / 146, 139 / 146 }    -- of the cloth's height
local BORDER_LEFT = 7 / 146         -- from the cloth's left, of its height
local EMBLEM_SIZE = 0.62            -- of the banner's height
local EMBLEM_RAISE = 0.08           -- above the middle, as a share of the height

-- A guild without a tabard: a grey banner with the client's own "no logo"
-- emblem (interface/guildframe/guildlogo-nologo, a grey helm).
local NO_TABARD = { bg = { 0.55, 0.55, 0.55 }, border = { 0.25, 0.25, 0.25 } }
local NO_LOGO = 460904

-- A frame for a guild's banner, size pixels high and BANNER_WIDTH as wide.
-- Filled in by SetBadge.
function Guilds:CreateBadge(parent, size)
    local badge = CreateFrame("Frame", nil, parent)
    local function Layer(sublevel)
        local tex = badge:CreateTexture(nil, "ARTWORK", nil, sublevel)
        tex:SetPoint("CENTER")
        return tex
    end
    badge.cloth, badge.emblem, badge.border = Layer(0), Layer(2), Layer(1)
    badge.cloth:SetTexture(BANNER_PARTS)
    badge.cloth:SetTexCoord(unpack(BANNER_CLOTH))
    badge.border:SetTexture(BANNER_PARTS)
    badge.border:SetTexCoord(unpack(BANNER_BORDER))
    -- SetLargeGuildTabardTextures fills a background and border too, which
    -- draw nothing on this client; the banner stands in for them.
    badge.unusedBg, badge.unusedBorder = Layer(0), Layer(0)
    badge.unusedBg:Hide()
    badge.unusedBorder:Hide()
    self:SizeBadge(badge, size or 32)
    return badge
end

function Guilds:SizeBadge(badge, size)
    badge:SetSize(size, size)
    badge.cloth:SetSize(size * BANNER_WIDTH, size)
    badge.border:SetSize(size * BORDER_SIZE[1], size * BORDER_SIZE[2])
    badge.border:ClearAllPoints()
    badge.border:SetPoint("TOPLEFT", badge.cloth, "TOPLEFT", size * BORDER_LEFT, 0)
    badge.emblem:SetSize(size * EMBLEM_SIZE, size * EMBLEM_SIZE)
    badge.emblem:SetPoint("CENTER", 0, size * EMBLEM_RAISE)
end

-- Draws a tabard saved by ReadTabard on a badge: the banner in its colours,
-- with the emblem drawn the way the client's own guild frames draw it
-- (SetLargeGuildTabardTextures, given the saved emblem and colour instead of
-- a unit, so it works for any guild ever joined). A guild without a tabard
-- (nil) gets the grey banner. Returns whether the guild's own tabard was drawn.
function Guilds:SetBadge(badge, tabard)
    local t = tabard
    local own = t and t.bg and t.border and true or false
    t = own and t or NO_TABARD
    badge.cloth:SetVertexColor(unpack(t.bg))
    badge.border:SetVertexColor(unpack(t.border))
    local drawn = false
    if own and t.emblem and t.emblemColor and SetLargeGuildTabardTextures and CreateColor then
        local data = {
            backgroundColor = CreateColor(unpack(t.bg)),
            borderColor = CreateColor(unpack(t.border)),
            emblemColor = CreateColor(unpack(t.emblemColor)),
            emblemFileID = t.emblem,
            emblemStyle = t.style,
        }
        drawn = pcall(SetLargeGuildTabardTextures, nil, badge.emblem, badge.unusedBg,
            badge.unusedBorder, data)
    end
    if not drawn then
        badge.emblem:SetTexture(NO_LOGO)
        badge.emblem:SetTexCoord(0, 1, 0, 1)
        badge.emblem:SetVertexColor(1, 1, 1)
    end
    return own and drawn
end

-- The tabard of the guild an event is about: the one saved at the latest
-- join of that guild up to the event, or the current guild's.
function Guilds:TabardOf(e)
    local name, tabard = e[6], nil
    for _, other in ipairs(ns.view.events) do
        if other[1] > e[1] then break end
        if other[2] == "gj" and other[6] == name then
            tabard = other[9] or tabard
        end
    end
    local current = ns.view.guild
    return tabard or (current and current[1] == name and current[4]) or nil
end

local LEFT = { k = "Removed from %s", d = "%s was disbanded" }

-- How to show a gj, gl or gr event: title, detail (what kind of entry, to go
-- before the place), icon and tabard (for a badge, see SetBadge). Nil for
-- the guild the character was in when tracking began, whose time is not
-- when it joined.
function Guilds:Describe(e)
    local kind, name = e[2], e[6] or "?"
    if kind == "gj" and e[8] then return end
    local tabard = self:TabardOf(e)
    if kind == "gj" then
        return "Joined <" .. name .. ">", e[7] or "Guild", self.ICON, tabard
    elseif kind == "gl" then
        return (LEFT[e[7]] or "Left %s"):format("<" .. name .. ">"), "Guild", self.ICON, tabard
    elseif kind == "gr" then
        return (e[8] and "Promoted to %s" or "Rank changed to %s"):format(e[7] or "?"), "<" .. name .. ">",
            self.ICON, tabard
    end
end

-- Each guild of the journey shown with when the character was in it:
-- { name, from, to, baseline }, oldest first; to is nil for the current one.
function Guilds:History()
    local list, current = {}, nil
    for _, e in ipairs(ns.view.events) do
        if e[2] == "gj" then
            current = { e[6], e[1], nil, e[8] }
            list[#list + 1] = current
        elseif e[2] == "gl" and current then
            current[3] = e[1]
            current = nil
        end
    end
    return list
end

-- Listening ---------------------------------------------------------------------

-- A system message as a pattern matching the whole of it.
local function Exact(text)
    return text and ("^" .. text:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1") .. "$")
end
local KICKED = Exact(ERR_GUILD_REMOVE_SELF)
local DISBANDED = Exact(ERR_GUILD_DISBANDED)

ns.On("PLAYER_LOGIN", function()
    C_Timer.After(GUILD_READY, function()
        ready = true
        ns.SafeCall(Guilds.Check, Guilds)
    end)
end)
ns.On("PLAYER_GUILD_UPDATE", function() Guilds:Check() end)
ns.On("GUILD_ROSTER_UPDATE", function() Guilds:Check() end)

ns.On("CHAT_MSG_SYSTEM", function(msg)
    if KICKED and msg:match(KICKED) then
        how.kind, how.at = "k", GetTime()
    elseif DISBANDED and msg:match(DISBANDED) then
        how.kind, how.at = "d", GetTime()
    end
end)
