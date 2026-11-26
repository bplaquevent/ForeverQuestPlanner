-- Forever Quest Planner: what the captured quests are: kind (dungeon, raid, PvP), category, interest
-- of their rewards, quests to turn in or to abandon (Analyze).

local ADDON_NAME, ns = ...
local AreaName, ChainInfo, ChainText, GameTag = ns.AreaName, ns.ChainInfo, ns.ChainText, ns.GameTag
local IsClassMeta, IsProfMeta, IsProfessionHeader, K = ns.IsClassMeta, ns.IsProfMeta, ns.IsProfessionHeader, ns.K
local L, LogEntry, LogRecord, MoneyText = ns.L, ns.LogEntry, ns.LogRecord, ns.MoneyText
local MoneyThreshold, QDB, QGet, QuestMeta, State = ns.MoneyThreshold, ns.QDB, ns.QGet, ns.QuestMeta, ns.State
local TagKind, TrivialRange, TurnInText = ns.TagKind, ns.TrivialRange, ns.TurnInText

---------------------------------------------------------------------------
-- Reward analysis (items)
---------------------------------------------------------------------------
local GetItemInfoCompat = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local SLOTS = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
  INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
  INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
  INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
  INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
  INVTYPE_SHIELD = { 17 }, INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_HOLDABLE = { 17 },
  INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

local function EquippedItemLevel(slot)
  local link = GetInventoryItemLink("player", slot)
  if not link then return 0 end
  local _, _, _, ilvl = GetItemInfoCompat(link)
  return ilvl or 0
end

-- Lowest item level you wear where an item of this equip location goes, or nil if it cannot be worn.
local function WornItemLevel(equipLoc)
  local slots = SLOTS[equipLoc]
  if not slots then return nil end
  local worst = math.huge
  for _, s in ipairs(slots) do worst = math.min(worst, EquippedItemLevel(s)) end
  return worst
end

-- Returns true + reason if the item is interesting, false otherwise, nil if unknown (not cached).
local function EvaluateItem(link, isUsable)
  if not link then return nil end
  local name, _, _, ilvl, _, _, _, _, equipLoc = GetItemInfoCompat(link)
  if not name then return nil end
  if equipLoc == "INVTYPE_BAG" then return true, name .. L[" (bag)"] end
  local worst = WornItemLevel(equipLoc)
  if not worst or isUsable == false then return false end
  if (ilvl or 0) > worst then return true, name .. L[" (upgrade)"] end
  return false
end

local function GetRewardInterest(questID)
  local unknown = false
  local function scan(kind, count, infoFn)
    for i = 1, count do
      local link = GetQuestLogItemLink and GetQuestLogItemLink(kind, i, questID)
      local isUsable
      if infoFn then
        local ok, _, _, _, _, usable = pcall(infoFn, i, questID)
        if ok then isUsable = usable end
      end
      local good, reason = EvaluateItem(link, isUsable)
      if good then return reason end
      if good == nil then unknown = true end
    end
  end
  local nRewards = GetNumQuestLogRewards and select(2, pcall(GetNumQuestLogRewards, questID)) or 0
  local nChoices = GetNumQuestLogChoices and select(2, pcall(GetNumQuestLogChoices, questID, true)) or 0
  if type(nRewards) ~= "number" then nRewards = 0 end
  if type(nChoices) ~= "number" then nChoices = 0 end
  local reason = scan("reward", nRewards, GetQuestLogRewardInfo) or scan("choice", nChoices, GetQuestLogChoiceInfo)
  return reason, unknown
end

local function RemainingObjectives(q)
  local parts = {}
  for _, o in ipairs(q.objectives or {}) do
    if not o.finished and o.text then parts[#parts + 1] = o.text end
  end
  return table.concat(parts, K.DESC_SEP)
end

---------------------------------------------------------------------------
-- Quest log analysis: to turn in, to abandon, groups, instances (dungeon, raid, PvP), later
---------------------------------------------------------------------------
-- Localized names of the dungeons known by QuestieDB (to recognize quest log categories).
local dungeonNameSet
local function DungeonNames()
  if dungeonNameSet then return dungeonNameSet end
  dungeonNameSet = {}
  for areaId in pairs(QDB.dungeonOf) do
    local n = AreaName(areaId)
    if n then dungeonNameSet[n] = true end
  end
  return dungeonNameSet
end

-- What a quest is, when it is done in a group: kind ("pvp", "raid", "dungeon", or nil) and the name of
-- its place. The game's tag first; without it, an instance signalled by the game or QuestieDB is a
-- dungeon.
local function LogKind(q) -- captured quest
  local instance = q.instanceName or (q.zone and DungeonNames()[q.zone] and q.zone) or nil
  local kind = q.gameKind or ((instance or q.isInstance) and "dungeon") or nil
  return kind, kind and (instance or q.zone or q.mapZone) or nil
end

local function IdKind(id) -- quest out of the log: its tag once loaded (QuestTags.lua), QuestieDB
  local sort = QGet(QDB.Quest, id, "zoneOrSort") or 0
  local d = sort > 0 and QDB.dungeonOf[sort] or nil
  local instance = d and AreaName(d) or nil
  local kind = TagKind(GameTag(id)) or (instance and "dungeon") or nil
  return kind, kind and (instance or (sort > 0 and AreaName(sort))) or nil, instance
end

local function QuestKind(id)
  local q = LogEntry(id)
  if q then return LogKind(q) end
  local kind, place = IdKind(id)
  return kind, place
end

K.LATER_GAP = 3 -- a quest more than this many levels above yours is for later (professions apart)

-- Category of a quest, the first that applies: "dungeon" (name), "later", "zone" Professions or
-- Class; else "zone" with no name (the caller's zone of the quest). dungeon: its name, or nil.
local function QuestCategory(kind, place, level, plevel, isProf, isClass)
  if kind then return kind, place or K.KIND_LABEL[kind] end
  if level > plevel + K.LATER_GAP and not isProf then return "later" end
  if isProf then return "zone", L["Professions"] end
  if isClass then return "zone", L["Class"] end
  return "zone", nil
end

-- Analysis of the last quest log capture, without capturing: the caller captures first (Snapshot)
-- when it needs the log as it is now.
local function Analyze()
  local e = LogRecord()
  local result = { abandon = {}, turnIn = {}, groups = {}, later = {}, instances = {} }
  State.abandonIds = {} -- for the icon in front of the titles (Geo.ToAbandon)
  local byInstance = {}
  if not e then return result end
  result.count = #e.quests

  local plevel = UnitLevel("player")
  local className = UnitClass("player")
  local range = TrivialRange()
  local byZone = {}

  for _, captured in ipairs(e.quests) do
    -- a copy: what the analysis adds (_chain, _abandon…) never goes into the saved data
    local q = {}
    for k, v in pairs(captured) do q[k] = v end
    local level = q.level or 0
    local m = QuestMeta(q.id)
    local isClass = (q.zone == className) or (m and IsClassMeta(m)) or false
    local isProf = IsProfessionHeader(q.zone) or (m and IsProfMeta(m)) or false
    local trivial = level > 0 and level < plevel - range
    local xpUseful = not trivial and (q.xp == nil or q.xp > 0)
    local chain = m and ChainInfo(q.id, plevel, range)
    local chainUseful = chain and chain.count > 0 and (chain.useful or chain.hasClass or chain.hasProf) or false
    local itemReason, itemUnknown = GetRewardInterest(q.id)
    local moneyUseful = (q.money or 0) >= MoneyThreshold(plevel)

    q._isClass, q._isProf, q._itemReason = isClass, isProf, itemReason
    q._chain = ChainText(chain)
    q._turnIn = TurnInText(q.id)

    q._abandon = nil
    if q.complete then
      result.turnIn[#result.turnIn + 1] = q
    else
      if q.failed then
        q._abandon = L["Failed quest"]
      elseif not (isClass or isProf or xpUseful or itemReason or itemUnknown or chainUseful or moneyUseful) then
      local why = {}
      why[#why + 1] = trivial and string.format(L["gray (level %d)"], level) or L["no XP"]
      why[#why + 1] = L["no useful item"]
      why[#why + 1] = (q.money and q.money > 0) and string.format(L["little money (%s)"], MoneyText(q.money)) or L["no money"]
      if chain and chain.count > 0 then
        why[#why + 1] = string.format(L["gray follow-up (%d quest(s))"], chain.count)
      else
        why[#why + 1] = L["no follow-up"]
      end
        q._abandon = table.concat(why, ", ")
      end
      if q._abandon then
        result.abandon[#result.abandon + 1] = { quest = q, reason = q._abandon }
        State.abandonIds[q.id] = true
      end
      local questKind, place = LogKind(q)
      local kind, name = QuestCategory(questKind, place, level, plevel, isProf, isClass)
      if questKind then
        local g = byInstance[kind .. ":" .. name]
        if not g then
          g = { kind = kind, name = name, quests = {} }
          byInstance[kind .. ":" .. name] = g
          result.instances[#result.instances + 1] = g
        end
        g.quests[#g.quests + 1] = q
      elseif kind == "later" then
        result.later[#result.later + 1] = q
      else
        local key = name or q.mapZone or q.zone or L["No zone"]
        local g = byZone[key]
        if not g then
          g = { name = key, quests = {} }
          byZone[key] = g
          result.groups[#result.groups + 1] = g
        end
        g.quests[#g.quests + 1] = q
      end
    end
  end

  table.sort(result.groups, function(a, b)
    if #a.quests ~= #b.quests then return #a.quests > #b.quests end
    return a.name < b.name
  end)
  table.sort(result.instances, function(a, b)
    if #a.quests ~= #b.quests then return #a.quests > #b.quests end
    return a.name < b.name
  end)
  for _, g in ipairs(result.instances) do
    table.sort(g.quests, function(a, b) return (a.level or 0) < (b.level or 0) end)
  end
  return result
end

-- Shared with the next files.
ns.Analyze, ns.GetItemInfoCompat, ns.IdKind, ns.LogKind = Analyze, GetItemInfoCompat, IdKind, LogKind
ns.QuestCategory, ns.QuestKind, ns.RemainingObjectives = QuestCategory, QuestKind, RemainingObjectives
