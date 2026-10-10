local _, ns = ...

-- Records professions and recipes (issues #2 and #3) as journal events:
--   prof  name, rank, maxRank, baseline   a profession learned, or a new tier
--                                         of it (maxRank went up); baseline =
--                                         true for ones already known when
--                                         tracking began
--   rec   name, spellID, profession, source   a recipe learned; spellID and
--                                         profession when the client says;
--                                         source "t" when a trainer was open
--
-- ns.char.skills is the last skill seen per profession: name -> { rank, max,
-- icon }, icon a file ID when the client gives one.
-- ns.char.recipes is the recipes known per profession: profession ->
-- { [recipe name] = true }, filled whenever the profession window is open
-- and when a recipe is learned. It is for counting and for finding a
-- recipe's profession; window scans never log events.
--
-- Professions known when tracking began are logged once as baseline, so an
-- old character does not show them as learned today.
--
-- Forever uses the modern APIs (GetProfessions, C_TradeSkillUI); the classic
-- skill and trade skill functions do not exist there.

local Crafts = {}
ns.Crafts = Crafts

local Log = function(...) ns.Journal:Log(...) end

local trainerOpen = false
local lastRecipe = { name = nil, t = 0, event = nil }   -- to log a recipe once when two sources report it

-- Professions now: name -> { rank, max, icon }, or nil without the API.
function Crafts:ReadSkills()
    if not (GetProfessions and GetProfessionInfo) then return end
    local skills = {}
    for _, index in ipairs({ GetProfessions() }) do
        local ok, name, icon, rank, max = pcall(GetProfessionInfo, index)
        if ok and name then
            skills[name] = { rank, max, icon }
        end
    end
    return skills
end

-- Compares the professions with the last ones seen and logs what is new.
function Crafts:CheckSkills()
    -- A seeded test journey has made-up professions; the real ones would not fit it.
    if ns.char.seeded then return end
    local skills = self:ReadSkills()
    if not skills then return end
    local known = ns.char.skills
    local baseline = known == nil
    known = known or {}
    for name, s in pairs(skills) do
        local old = known[name]
        if not old then
            Log("prof", name, s[1], s[2], baseline or nil)
        elseif (s[2] or 0) > (old[2] or 0) then
            Log("prof", name, s[1], s[2])
        end
        known[name] = { s[1], s[2], s[3] or (old and old[3]) }
    end
    ns.char.skills = known
end

-- True when the open profession window shows someone else's profession (a
-- linked one) or a guild's, whose recipes are not this character's.
local function ViewingOthers()
    local ui = C_TradeSkillUI
    return ui and ((ui.IsTradeSkillLinked and ui.IsTradeSkillLinked())
        or (ui.IsTradeSkillGuild and ui.IsTradeSkillGuild())) or false
end

-- The profession the open profession window shows, if any.
local function OpenProfession()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo) then return end
    local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if ok and info and info.professionName and info.professionName ~= "" then
        return info.professionName
    end
end

-- The profession a recipe belongs to, from its spell ID. At a trainer no
-- profession window is open, so this is the only way to know.
function Crafts:RecipeProfession(spellID)
    local lookup = spellID and C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLineForRecipe
    if not lookup then return end
    local ok, _, name, _, parentName = pcall(lookup, spellID)
    if ok then
        return parentName or name
    end
end

-- Names of the learned recipes in the open window that belong to profession.
-- Switching windows, the recipe list can still be the last profession's for
-- a moment, so each recipe's own profession is checked.
function Crafts:ReadRecipes(profession)
    local ui = C_TradeSkillUI
    if not (ui and ui.GetAllRecipeIDs and ui.GetRecipeInfo) then return end
    local ok, ids = pcall(ui.GetAllRecipeIDs)
    if not (ok and ids) then return end
    local names = {}
    for _, id in ipairs(ids) do
        local info = ui.GetRecipeInfo(id)
        local owner = self:RecipeProfession(id)
        if info and info.learned and info.name and (not owner or owner == profession) then
            names[info.name] = true
        end
    end
    return names
end

-- Logs a recipe learned. The chat message and NEW_RECIPE_LEARNED both report
-- it, chat usually first and without a spell ID, so a second report of the
-- same recipe only fills in what the first one lacked.
local function LogRecipe(name, spellID, profession)
    if not name then return end
    profession = profession or Crafts:RecipeProfession(spellID) or OpenProfession()
    if profession then
        local known = ns.char.recipes[profession]
        if known then known[name] = true end
    end
    local now = GetTime()
    local e = lastRecipe.event
    if lastRecipe.name == name and now - lastRecipe.t < 5 and e then
        e[7] = e[7] or spellID
        e[8] = e[8] or profession
        return
    end
    Log("rec", name, spellID, profession, trainerOpen and "t" or nil)
    lastRecipe.name, lastRecipe.t = name, now
    lastRecipe.event = ns.char.events[#ns.char.events]
end

-- Adds the open profession window's recipes to the ones known. Only for
-- counting and finding a recipe's profession: learning is logged from the
-- chat message and NEW_RECIPE_LEARNED, which both work on Forever.
function Crafts:CheckRecipes()
    if ViewingOthers() then return end
    local profession = OpenProfession()
    local names = profession and self:ReadRecipes(profession)
    if not (profession and names) then return end
    local known = ns.char.recipes[profession] or {}
    for name in pairs(names) do
        known[name] = true
    end
    ns.char.recipes[profession] = known
end

local function SpellName(spellID)
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spellID)
    end
    ---@diagnostic disable-next-line: deprecated
    return GetSpellInfo and (GetSpellInfo(spellID))
end

-- Showing them ------------------------------------------------------------------

Crafts.PROFESSION_ICON = "Interface\\Icons\\INV_Misc_Book_11"
Crafts.RECIPE_ICON = "Interface\\Icons\\INV_Scroll_03"

-- Classic tiers by their maximum skill.
local TIERS = { [75] = "Apprentice", [150] = "Journeyman", [225] = "Expert", [300] = "Artisan" }

-- A profession's icon: the one saved while it was known, else the one the
-- client has for it now (for professions known before icons were saved,
-- and seeded ones).
local liveIcons
function Crafts:Icon(profession)
    if not profession then return self.PROFESSION_ICON end
    local s = ns.view.skills and ns.view.skills[profession]
    if s and s[3] then return s[3] end
    if not liveIcons then
        liveIcons = {}
        for name, live in pairs(self:ReadSkills() or {}) do
            liveIcons[name] = live[3]
        end
    end
    local icon = liveIcons[profession]
    if next(liveIcons) == nil then
        liveIcons = nil     -- not loaded yet; ask again next time
    end
    return icon or self.PROFESSION_ICON
end

-- The profession whose recipe list (from its window) has this recipe.
function Crafts:ProfessionOf(recipe)
    for profession, names in pairs(ns.view.recipes) do
        if names[recipe] then return profession end
    end
end

-- Recipes learned (rec events) and recipes known now, over all professions.
function Crafts:RecipeCounts()
    local learned, known = 0, 0
    for _, e in ipairs(ns.view.events) do
        if e[2] == "rec" then learned = learned + 1 end
    end
    for _, names in pairs(ns.view.recipes) do
        for _ in pairs(names) do known = known + 1 end
    end
    return learned, known
end

-- How to show a prof or rec event: title, detail (what kind of entry, to go
-- before the place) and icon. Nil for professions known when tracking began,
-- whose time is not when they were learned.
function Crafts:Describe(e)
    if e[2] == "prof" then
        local name, rank, max = e[6], e[7] or 0, e[8] or 0
        if e[9] then return end
        if rank <= 1 then
            return "Learned " .. name, TIERS[max] or "New profession", self:Icon(name)
        end
        local tier = TIERS[max]
        return tier and ("%s: %s"):format(name, tier) or ("%s: up to %d"):format(name, max),
            ("Skill %d of %d"):format(rank, max), self:Icon(name)
    elseif e[2] == "rec" then
        local name, spellID, source = e[6], e[7], e[9]
        -- The first recipes were saved without one; the profession windows'
        -- recipe lists can still tell.
        local profession = e[8] or self:RecipeProfession(spellID) or self:ProfessionOf(name)
        -- The recipe's own icon (what it makes); recipe spells themselves
        -- only have the default spell icon.
        local icon
        if spellID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
            local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, spellID)
            icon = ok and info and info.icon or nil
        end
        local detail
        if source == "t" then
            detail = profession and (profession .. " trainer") or "Trainer"
        else
            detail = profession or "Recipe"
        end
        return name, detail, icon or (profession and self:Icon(profession)) or self.RECIPE_ICON
    end
end

-- Listening ---------------------------------------------------------------------

-- "You have learned how to create a new item: %s."
local matchRecipe = ns.ChatMatcher(ERR_LEARN_RECIPE_S or "You have learned how to create a new item: %s.")

ns.On("PLAYER_LOGIN", function()
    -- Professions can be missing for a moment at login.
    C_Timer.After(5, function() ns.SafeCall(Crafts.CheckSkills, Crafts) end)
end)
ns.On("SKILL_LINES_CHANGED", function() Crafts:CheckSkills() end)
ns.On("CHAT_MSG_SKILL", function() Crafts:CheckSkills() end)

ns.On("TRADE_SKILL_SHOW", function() Crafts:CheckRecipes() end)
ns.On("TRADE_SKILL_LIST_UPDATE", function() Crafts:CheckRecipes() end)

ns.On("TRAINER_SHOW", function() trainerOpen = true end)
ns.On("TRAINER_CLOSED", function() trainerOpen = false end)

ns.recipeEventTracked = ns.On("NEW_RECIPE_LEARNED", function(spellID)
    --@debug@
    ns.Print(("NEW_RECIPE_LEARNED %s (%s)"):format(tostring(spellID), tostring(SpellName(spellID))))
    --@end-debug@
    LogRecipe(SpellName(spellID), spellID)
end)

ns.On("CHAT_MSG_SYSTEM", function(msg)
    local name = matchRecipe(msg)
    if name then
        LogRecipe(name)
    end
end)

--@debug@
-- /rts craftprobe: what the profession and recipe APIs return now. Run it
-- again with a profession window open.
ns.Command("craftprobe", "check the profession and recipe APIs (developer)", function()
    local skills = Crafts:ReadSkills()
    if skills then
        local list = {}
        for name, s in pairs(skills) do
            list[#list + 1] = ("%s %s/%s"):format(name, tostring(s[1]), tostring(s[2]))
        end
        ns.Print("Professions: " .. (#list > 0 and table.concat(list, ", ") or "none"))
    else
        ns.Print("No GetProfessions on this client.")
    end

    local profession = OpenProfession()
    if profession then
        local count = 0
        for _ in pairs(Crafts:ReadRecipes(profession) or {}) do count = count + 1 end
        ns.Print(("Open window: %s, %d of its recipes learned."):format(profession, count))
    else
        ns.Print("No profession window open. Open one and run this again.")
    end

    local known = {}
    for name, names in pairs(ns.char.recipes) do
        local count = 0
        for _ in pairs(names) do count = count + 1 end
        known[#known + 1] = ("%s %d"):format(name, count)
    end
    local logged, last = { prof = 0, rec = 0 }, nil
    for _, e in ipairs(ns.char.events) do
        if logged[e[2]] then logged[e[2]] = logged[e[2]] + 1 end
        if e[2] == "rec" then last = e end
    end
    if last then
        ns.Print(("Last recipe: %s, spell %s, saved profession %s, looked up %s, source %s."):format(
            tostring(last[6]), tostring(last[7]), tostring(last[8]),
            tostring((Crafts:RecipeProfession(last[7]))), tostring(last[9])))
    end
    ns.Print(("Known recipes: %s. Events: %d prof, %d rec."):format(
        #known > 0 and table.concat(known, ", ") or "none", logged.prof, logged.rec))
end)

-- /rts craftfix: clears what an early version recorded wrongly on test
-- characters: recipe events from window scans (no spell ID and no trainer)
-- and recipe lists that mixed professions. The lists refill as windows open.
ns.Command("craftfix", "remove wrongly recorded recipes (developer)", function()
    local events, removed = ns.char.events, 0
    for i = #events, 1, -1 do
        local e = events[i]
        if e[2] == "rec" and not e[7] and e[9] ~= "t" then
            table.remove(events, i)
            removed = removed + 1
        end
    end
    wipe(ns.char.recipes)
    ns.Print(("Removed %d recipe events and cleared the recipe lists. Open each profession window to refill them, then /reload to save."):format(removed))
end)
--@end-debug@
