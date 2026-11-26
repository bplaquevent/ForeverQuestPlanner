-- Forever Quest Planner: available quests (QuestieDB scan spread over several frames).
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, DBXP, EVENT_SORTS, GiverText, HasBit = ns.AreaName, ns.DBXP, ns.EVENT_SORTS, ns.GiverText, ns.HasBit
local IsClassMeta, IsCompleted, IsInLog, IsProfMeta, K, L = ns.IsClassMeta, ns.IsCompleted, ns.IsInLog, ns.IsProfMeta, ns.K, ns.L
local NextQuests, PlayerBits, PlayerSkills, QDB, QGet = ns.NextQuests, ns.PlayerBits, ns.PlayerSkills, ns.QDB, ns.QGet
local QuestMeta, QuestPrereqs, State, TrivialRange, AllIds = ns.QuestMeta, ns.QuestPrereqs, ns.State, ns.TrivialRange, ns.AllIds
local PlayerFaction, QuestAllowed, Print, SkillName = ns.PlayerFaction, ns.QuestAllowed, ns.Print, ns.SkillName
local IdKind, RequestQuestTags, TagProgress = ns.IdKind, ns.RequestQuestTags, ns.TagProgress
local Guard = ns.Guard

---------------------------------------------------------------------------
-- Available quests (QuestieDB), scan spread over several frames
---------------------------------------------------------------------------
-- dirty: to scan again; changed: marked dirty while the running scan was at work.
local scan = { running = false, dirty = true, entries = nil }

local function MarkScanDirty()
  scan.dirty, scan.changed = true, true
end

-- Levels above yours scanned for the Roadbook: a few by default, up to the target level with a
-- "reach level" goal (the Roadbook takes quests on as the expected level rises).
local function ScanLookahead()
  local g = State.xpGoal
  local plevel = UnitLevel("player")
  if g and g.kind == "level" and g.value - plevel > K.LOOKAHEAD_LEVELS then return g.value - plevel end
  return K.LOOKAHEAD_LEVELS
end

local function BuildScanContext()
  local classBit, raceBit = PlayerBits()
  local skills, _, skillsKnown = PlayerSkills()
  return {
    plevel = UnitLevel("player"),
    range = TrivialRange(),
    classBit = classBit,
    raceBit = raceBit,
    skills = skills,
    skillsKnown = skillsKnown,
    lookahead = ScanLookahead(),
    faction = PlayerFaction(),
  }
end

-- Reputation standings (absolute values) and the game's localized labels.
local STANDINGS = {
  { -42000, 1, L["Hated"] }, { -6000, 2, L["Hostile"] }, { -3000, 3, L["Unfriendly"] }, { 0, 4, L["Neutral"] },
  { 3000, 5, L["Friendly"] }, { 9000, 6, L["Honored"] }, { 21000, 7, L["Revered"] }, { 42000, 8, L["Exalted"] },
}

local function StandingLabel(value)
  local label = STANDINGS[1]
  for _, s in ipairs(STANDINGS) do
    if value >= s[1] then label = s end
  end
  return _G["FACTION_STANDING_LABEL" .. label[2]] or label[3]
end

-- Current reputation (absolute value) and faction name; nil if unknown to the character.
local function PlayerReputation(factionId)
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local ok, data = pcall(C_Reputation.GetFactionDataByID, factionId)
    if ok and data and data.name then return data.currentStanding, data.name end
  end
  if GetFactionInfoByID then
    local ok, name, _, _, _, _, barValue = pcall(GetFactionInfoByID, factionId)
    if ok and name then return barValue, name end
  end
  return nil, nil
end

-- "Faction: Friendly required" text if the player's reputation is too low, otherwise nil.
local function MissingReputation(rep)
  if type(rep) ~= "table" or not rep[1] or not rep[2] then return nil end
  local current, name = PlayerReputation(rep[1])
  if current and current >= rep[2] then return nil end
  return string.format(L["%s: %s required"], name or (L["faction "] .. rep[1]), StandingLabel(rep[2]))
end

local function AnyNonEmpty(t)
  if type(t) ~= "table" then return false end
  for _, v in pairs(t) do
    if type(v) == "table" and v[1] then return true end
  end
  return false
end

-- Every bit set in mask is also set in allowed.
local function OnlyBits(mask, allowed)
  for i = 0, 40 do
    local b = 2 ^ i
    if HasBit(mask, b) and not HasBit(allowed, b) then return false end
  end
  return mask ~= 0
end

-- Starters (NPCs, objects, items) of a quest, as three lists.
local function StartLists(id)
  local by = QGet(QDB.Quest, id, "startedBy")
  if type(by) ~= "table" then return {}, {}, {} end
  return type(by[1]) == "table" and by[1] or {}, type(by[2]) == "table" and by[2] or {}, type(by[3]) == "table" and by[3] or {}
end

-- A quest that an NPC or an object AND an item start: QuestieDB's data conflict (the Forever quests
-- "Grant's Shield", "Silvia's Sword"...). Returns the items, or nil.
local function StartedByItem(id)
  local npcs, objects, items = StartLists(id)
  if #items > 0 and (#npcs > 0 or #objects > 0) then return items end
  return nil
end

-- Data of a quest that contradict each other (QuestieDB errors): the quest is kept, with a list of
-- texts telling what does not add up (nil when nothing does). faction: "A" or "H", the player's.
local function QuestDoubts(id, faction)
  local Q = QDB.Quest
  local out = {}
  local masks = QDB.lib.Enum.factionRaceMasks
  local races = QGet(Q, id, "requiredRaces") or 0
  local questFaction = (races ~= 0 and masks) and ((OnlyBits(races, masks.Alliance) and "A") or (OnlyBits(races, masks.Horde) and "H")) or nil
  local npcsStart = StartLists(id)
  local finish = QGet(Q, id, "finishedBy")
  local npcsEnd = type(finish) == "table" and type(finish[1]) == "table" and finish[1] or {}
  local function friendly(n)
    local f = QGet(QDB.Npc, n, "friendlyToFaction")
    return type(f) == "string" and f or nil
  end
  -- Quest of one faction (races), NPC friendly to the other one only.
  if questFaction then
    local names, seen = {}, {}
    for _, list in ipairs({ npcsStart, npcsEnd }) do
      for _, n in ipairs(list) do
        local f = friendly(n)
        if f and f ~= "AH" and f ~= questFaction and not seen[n] then
          seen[n] = true
          names[#names + 1] = QGet(QDB.Npc, n, "name") or ("#" .. n)
        end
      end
    end
    if #names > 0 then out[#out + 1] = L["NPC of the other faction: "] .. table.concat(names, ", ") end
  end
  -- No NPC of the player's faction to take or turn in the quest (an NPC without data gives no verdict).
  local function noFriend(list)
    if #list == 0 then return false end
    for _, n in ipairs(list) do
      local f = friendly(n)
      if not f or f:find(faction, 1, true) then return false end
    end
    return true
  end
  if faction then
    local _, objects, items = StartLists(id)
    if #objects == 0 and #items == 0 and noFriend(npcsStart) then out[#out + 1] = L["no quest giver of your faction"] end
    if not (type(finish) == "table" and type(finish[2]) == "table" and #finish[2] > 0) and noFriend(npcsEnd) then
      out[#out + 1] = L["no turn-in NPC of your faction"]
    end
  end
  -- Started by an item and an NPC.
  local items = StartedByItem(id)
  if items then
    out[#out + 1] = string.format(L["started by an item (%s): the giver listed may not give it"], QGet(QDB.Item, items[1], "name") or ("#" .. items[1]))
  end
  return #out > 0 and out or nil
end

-- A quest the character may take at the levels scanned (ctx), whatever else it still needs: not
-- turned in, allowed to its race and class, required level within the lookahead.
local function WithinReach(id, ctx)
  return (QGet(QDB.Quest, id, "requiredLevel") or 0) <= ctx.plevel + (ctx.lookahead or 0)
    and not IsCompleted(id) and QuestAllowed(id, ctx.classBit, ctx.raceBit)
end

-- The rules that keep a quest from being offered at all, whatever it may still need. done(q): the
-- prerequisite q counts as done.
local function Offered(id, ctx, done)
  local Q = QDB.Quest
  if not WithinReach(id, ctx) or IsInLog(id) then return false end
  local maxL = QGet(Q, id, "requiredMaxLevel")
  if maxL and maxL > 0 and ctx.plevel > maxL then return false end
  if EVENT_SORTS[QGet(Q, id, "zoneOrSort") or 0] then return false end
  local excl = QGet(Q, id, "exclusiveTo")
  if type(excl) == "table" then
    for _, x in ipairs(excl) do if IsCompleted(x) or IsInLog(x) then return false end end
  end
  local nx = QGet(Q, id, "nextQuestInChain")
  if nx and nx > 0 and (IsCompleted(nx) or IsInLog(nx)) then return false end
  local parent = QGet(Q, id, "parentQuest")
  if parent and parent > 0 and not IsInLog(parent) then return false end
  local asw = QGet(Q, id, "availableStartingWith")
  if asw and asw > 0 and not (IsInLog(asw) or done(asw)) then return false end
  local auc = QGet(Q, id, "availableUntilCompleted")
  if auc and auc > 0 and IsCompleted(auc) then return false end
  local dis = QGet(Q, id, "disabledByQuest")
  if dis and dis > 0 and IsInLog(dis) then return false end
  local spell = QGet(Q, id, "requiredSpell")
  if spell and spell ~= 0 and IsSpellKnown then
    local known = IsSpellKnown(math.abs(spell)) and true or false
    if (spell > 0) ~= known then return false end
  end
  -- A specialization that is a spell (not a profession) must be known.
  local spec = ctx.skillsKnown and QGet(Q, id, "requiredSpecialization")
  if spec and spec > 0 and not ns.PROFESSIONS[spec] and IsSpellKnown and not IsSpellKnown(spec) then return false end
  return AnyNonEmpty(QGet(Q, id, "startedBy"))
end

-- What a quest offered still needs (prerequisite quests, professions, the item that starts it):
-- { texts, quests (for each missing prerequisite, the quests any of which would do) }, or nil.
local function MissingNeeds(id, ctx, done)
  local Q = QDB.Quest
  local missing = { texts = {}, quests = {} }
  local function questName(q) return string.format(L["\"%s\""], QGet(Q, q, "name") or ("#" .. q)) end
  local group, single = QuestPrereqs(id)
  for _, p in ipairs(group) do
    if not done(p) then
      missing.texts[#missing.texts + 1] = questName(p)
      missing.quests[#missing.quests + 1] = { p }
    end
  end
  if #single > 0 then
    local ok = false
    for _, p in ipairs(single) do if done(p) then ok = true break end end
    if not ok then
      local names = {}
      for _, p in ipairs(single) do names[#names + 1] = questName(p) end
      missing.texts[#missing.texts + 1] = table.concat(names, L[" or "])
      missing.quests[#missing.quests + 1] = single
    end
  end
  local skill = QGet(Q, id, "requiredSkill")
  if type(skill) == "table" and ctx.skillsKnown then
    local have = ctx.skills[skill[1]]
    if not have or have < (skill[2] or 0) then
      missing.texts[#missing.texts + 1] = (SkillName(skill[1]) or (L["profession"] .. " " .. skill[1])) ..
        ((skill[2] or 0) > 0 and (" " .. skill[2]) or "")
    end
  end
  if ctx.skillsKnown then
    -- Specialization: a profession id: the profession is required.
    local spec = QGet(Q, id, "requiredSpecialization")
    if spec and spec > 0 and ns.PROFESSIONS[spec] and not ctx.skills[spec] then
      missing.texts[#missing.texts + 1] = SkillName(spec) or L["profession"]
    end
    -- Profession ranks: at least one of the listed professions (positive rank) must be known.
    local ranks = QGet(Q, id, "requiredRanks")
    if type(ranks) == "table" and #ranks > 0 then
      local needOne, hasOne = false, false
      for _, pair in ipairs(ranks) do
        if type(pair) == "table" and pair[1] and (pair[2] or 0) > 0 then
          needOne = true
          if ctx.skills[pair[1]] then hasOne = true end
        end
      end
      if needOne and not hasOne then
        local names = {}
        for _, pair in ipairs(ranks) do
          if type(pair) == "table" and pair[1] and (pair[2] or 0) > 0 then
            names[#names + 1] = (SkillName(pair[1]) or tostring(pair[1])) .. " " .. pair[2]
          end
        end
        missing.texts[#missing.texts + 1] = table.concat(names, L[" or "])
      end
    end
  end

  -- The item that starts the quest (also given by an NPC in the data) is needed: listed with it missing.
  local startItems = StartedByItem(id)
  if startItems then
    local have = false
    for _, itemId in ipairs(startItems) do
      if ns.Geo.ItemCount(itemId) > 0 then have = true break end
    end
    if not have then
      missing.texts[#missing.texts + 1] = L["object: "] .. (QGet(QDB.Item, startItems[1], "name") or ("#" .. startItems[1]))
    end
  end

  return #missing.texts > 0 and missing or nil
end

local function CheckAvailable(id, ctx)
  local Q = QDB.Quest
  -- A prerequisite quest the player's race or class could never take (the quest of another race, flagged done
  -- through the exclusive classic chain) does not count as done: what follows it cannot be taken either.
  local function done(q) return (IsCompleted(q) or (ctx.done and ctx.done[q]) or false) and QuestAllowed(q, ctx.classBit, ctx.raceBit) end
  if not Offered(id, ctx, done) then return nil end
  local name = QGet(Q, id, "name")
  if not name then return nil end
  -- Only the required level decides whether the character can pick the quest up (a high quest
  -- level alone does not hide it). Quests slightly too high are kept for the Roadbook (unlocked by
  -- the expected level).
  local req = QGet(Q, id, "requiredLevel") or 0
  local lvl = QGet(Q, id, "questLevel") or 0
  if lvl < 0 then lvl = ctx.plevel end -- quest at the player's level
  local lowLevel = lvl > 0 and lvl < ctx.plevel - ctx.range
  local sort = QGet(Q, id, "zoneOrSort") or 0
  local starters = QGet(Q, id, "startedBy")

  local m = QuestMeta(id)
  local _, _, instance = IdKind(id)
  local starterText, starterZone = GiverText(starters)
  return {
    id = id,
    name = name,
    level = lvl,
    reqLevel = req,
    future = req > ctx.plevel or nil,
    xp = DBXP(id, math.max(ctx.plevel, req)),
    instance = instance, -- QuestieDB's; kind (dungeon, raid, PvP): set by the scan, tags loaded
    area = (sort > 0 and not instance) and AreaName(sort) or nil,
    starter = starterText,
    starterZone = starterZone,
    isClass = m and IsClassMeta(m) or false,
    isProf = m and IsProfMeta(m) or false,
    opensChain = m and #NextQuests(m) > 0 or false,
    repMissing = MissingReputation(QGet(Q, id, "requiredMinRep")),
    missing = MissingNeeds(id, ctx, done),
    doubts = QuestDoubts(id, ctx.faction),
    repeatable = HasBit(QGet(Q, id, "specialFlags") or 0, 1),
    lowLevel = lowLevel,
  }
end

local function Refresh() ns.Refresh() end -- the real one is in UI/Window.lua

local StartScan

-- Is the scan of the available quests still to wait for? Then it is started if needed and retry(attempt)
-- is called a little later; after K.SCAN_TRIES without a quest tag loaded, the wait is given up: a
-- message, then giveUp().
K.SCAN_TRIES, K.SCAN_WAIT = 40, 0.5
local function WaitScan(attempt, retry, giveUp)
  if not (scan.running or scan.dirty or not scan.entries) then return false end
  if not scan.running then StartScan() end
  local loaded = TagProgress()
  if loaded ~= scan.waitLoaded then scan.waitLoaded, attempt = loaded, 0 end -- the loading goes on
  attempt = (attempt or 0) + 1
  if attempt > K.SCAN_TRIES then
    Print(L["Quest scan is taking too long: try again in a moment."])
    if giveUp then giveUp() end
  else
    C_Timer.After(K.SCAN_WAIT, function() retry(attempt) end)
  end
  return true
end

-- The scan's results are shown once the game's tags of their quests are loaded.
local function Publish(results)
  local function finish()
    for _, en in ipairs(results) do
      local kind, _, _, tagged = IdKind(en.id)
      en.kind, en.tagged = kind, tagged
    end
    scan.entries = results
    scan.running, scan.dirty = false, scan.changed
    Refresh()
  end
  local ids = {}
  for _, en in ipairs(results) do ids[#ids + 1] = en.id end
  if RequestQuestTags(ids, finish) then finish() end
end

function StartScan()
  if scan.running then return end
  local ids = AllIds(QDB.Quest)
  if not ids then
    scan.error = L["Unable to read the QuestieDB quest list."]
    return
  end

  local ctx = BuildScanContext()
  local results, i = {}, 1
  scan.running, scan.error, scan.changed = true, nil, false
  local function step()
    local stop = math.min(i + 249, #ids)
    for k = i, stop do
      local ok, entry = Guard(CheckAvailable, ids[k], ctx)
      if ok and entry then results[#results + 1] = entry end
    end
    i = stop + 1
    if i <= #ids then
      C_Timer.After(0, step)
    else
      -- Quests with missing quest prerequisites are kept only if each prerequisite can be done
      -- now (in the log or available): "do this first" hints, not whole distant chains.
      local reachable = {}
      for _, en in ipairs(results) do if not en.missing then reachable[en.id] = true end end
      local kept = {}
      for _, en in ipairs(results) do
        local ok = true
        if en.missing then
          for _, anyOf in ipairs(en.missing.quests) do
            local one = false
            for _, q in ipairs(anyOf) do if reachable[q] or IsInLog(q) then one = true break end end
            if not one then ok = false break end
          end
        end
        if ok then kept[#kept + 1] = en end
      end
      -- A quest whose missing prerequisites are all listed quests that lead to it is shown in their
      -- chain (Geo.ChainLines), not as a row of its own.
      local listed = {}
      for _, en in ipairs(kept) do listed[en.id] = en end
      local heads = {}
      for _, en in ipairs(kept) do
        if not en.missing then
          for _, c in ipairs(ns.Geo.ChainQuests(en.id)) do heads[c.id] = true end
        end
      end
      results = {}
      for _, en in ipairs(kept) do
        local inChain = en.missing and heads[en.id]
        if inChain then
          for _, anyOf in ipairs(en.missing.quests) do
            local one = false
            for _, q in ipairs(anyOf) do if listed[q] then one = true break end end
            if not one then inChain = false break end
          end
        end
        if not inChain then results[#results + 1] = en end
      end
      Publish(results)
    end
  end
  step()
end


-- Shared with the next files.
ns.BuildScanContext, ns.CheckAvailable, ns.Refresh, ns.StartScan, ns.scan = BuildScanContext, CheckAvailable, Refresh, StartScan, scan
ns.QuestDoubts = QuestDoubts
ns.WaitScan = WaitScan
ns.MarkScanDirty, ns.WithinReach = MarkScanDirty, WithinReach
