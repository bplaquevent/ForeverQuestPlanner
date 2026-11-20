-- Forever Quest Planner (formerly Forever Quest Export)
-- 1. Copies the character's quest log into ForeverQuestPlannerDB.
--    The game writes this table to disk on every /reload or logout:
--      WTF/Account/<ACCOUNT>/SavedVariables/ForeverQuestPlanner.lua
-- 2. Analysis window: Roadbook, around me, quest log, available quests, text export.
-- 3. Uses QuestieDB (optional dependency) for quest chains, classes,
--    professions, zones, NPCs and XP. Without QuestieDB, analysis is limited to the game API.

local ADDON_NAME, ns = ...
ns = ns or {}
-- Localization: English by default, other languages in Locales/*.lua.
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
local PREFIX = "|cff33ccffForeverQuestPlanner|r: "

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

local function Settings()
  ForeverQuestPlannerSettings = ForeverQuestPlannerSettings or {}
  ForeverQuestPlannerSettings.keep = ForeverQuestPlannerSettings.keep or {}
  ForeverQuestPlannerSettings.excluded = ForeverQuestPlannerSettings.excluded or {} -- quest id -> title
  return ForeverQuestPlannerSettings
end

local function CharKey()
  local name, realm = UnitFullName("player")
  realm = realm or (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
  return (name or "?") .. "-" .. (realm or "?")
end

local function Color(hex, s) return "|cff" .. hex .. tostring(s) .. "|r" end

-- Resolves WoW plural codes "|4singular:plural;" and strips color codes.
local function CleanText(text, plural)
  if not text then return nil end
  text = text:gsub("|4([^:;]*):([^;]*);", function(s, p) return plural and p or s end)
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return text
end

local function IsCompleted(id)
  return C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) or false
end

local function IsInLog(id)
  if C_QuestLog.GetLogIndexForQuestID then
    return C_QuestLog.GetLogIndexForQuestID(id) ~= nil
  end
  return C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(id) or false
end

-- Bit test without the bit library (Forever race masks exceed 32 bits).
local function HasBit(mask, bitValue)
  return math.floor(mask / bitValue) % 2 == 1
end

local function TrivialRange()
  if UnitQuestTrivialLevelRange then
    local ok, r = pcall(UnitQuestTrivialLevelRange, "player")
    if ok and r then return r end
  end
  if GetQuestGreenRange then
    local ok, r = pcall(GetQuestGreenRange)
    if ok and r then return r end
  end
  return 8
end

---------------------------------------------------------------------------
-- QuestieDB (optional)
---------------------------------------------------------------------------
local QDB = { ok = false }
local K = {} -- tuning constants (avoids the 200 local variables limit)
-- Transport mode names (internal ids -> displayed text).
K.MODE_NAME = { vol = L["flight"], zeppelin = L["zeppelin"], bateau = L["boat"] }
K.MAX_LEVEL_GAP = 2 -- difficulty: quest level at most this many levels above (or below) yours (+1 for quests already in the log)
K.MAX_ELITE_GAP = -2 -- same for elite quests, usually too hard alone at your level
-- Technical search bound: quests whose required level is up to this many levels above yours are
-- examined, but a quest only enters the Roadbook from the step where the expected level reaches its
-- required level (see Geo.StartIndex).
K.LOOKAHEAD_LEVELS = 5

local CLASS_SORTS = { [-395] = true, [-372] = true, [-263] = true, [-262] = true, [-261] = true, [-162] = true,
  [-161] = true, [-141] = true, [-82] = true, [-81] = true, [-61] = true }
-- Profession quest categories; -666 = "Camping", the crafting quests of Forever ("Camping 101: …").
local PROF_SORTS = { [-398] = true, [-377] = true, [-373] = true, [-371] = true, [-324] = true, [-304] = true,
  [-264] = true, [-201] = true, [-182] = true, [-181] = true, [-121] = true, [-101] = true, [-24] = true,
  [-666] = true }
local EVENT_SORTS = { [-1000] = true, [-404] = true, [-402] = true, [-378] = true, [-376] = true, [-375] = true,
  [-374] = true, [-370] = true, [-369] = true, [-366] = true, [-364] = true, [-41] = true, [-22] = true,
  [-21] = true, [-368] = true, [-365] = true, [-241] = true }
local PROF_HEADERS = { ["Artisanat"] = true, ["Métiers"] = true, ["Professions"] = true, ["Crafting"] = true }

local function QGet(entity, id, key)
  if not entity or not id then return nil end
  local ok, v = pcall(entity.Get, id, key)
  if ok then return v end
  return nil
end

local function InitQuestieDB()
  local lib = rawget(_G, "LibQuestieDB")
  if not lib then return end
  if lib.RequireContract then
    local ok, msg = lib.RequireContract(4)
    if not ok then
      Print(L["QuestieDB found but incompatible: "] .. tostring(msg))
      return
    end
  end
  QDB.Quest = lib.Quest or rawget(_G, "QuestDB")
  QDB.Npc = lib.Npc or rawget(_G, "NpcDB")
  QDB.Object = lib.Object or rawget(_G, "ObjectDB")
  QDB.Item = lib.Item or rawget(_G, "ItemDB")
  if not (QDB.Quest and QDB.Quest.Get) then return end

  if lib.Support and lib.Support.Get then
    local okX, xpMod = pcall(lib.Support.Get, "QuestXP")
    if okX and type(xpMod) == "table" then QDB.xp = xpMod.db end
    local okZ, zoneMod = pcall(lib.Support.Get, "ZoneDB")
    if okZ and type(zoneMod) == "table" and zoneMod.private then
      QDB.dungeons = zoneMod.private.dungeons
      QDB.zonePrivate = zoneMod.private
    end
  end
  QDB.lib = lib

  -- Zone (or alternate zone) -> dungeon id
  QDB.dungeonOf = {}
  for areaId, entry in pairs(QDB.dungeons or {}) do
    QDB.dungeonOf[areaId] = areaId
    if type(entry[2]) == "table" then
      for _, alt in ipairs(entry[2]) do QDB.dungeonOf[alt] = areaId end
    end
  end

  QDB.raceMasks = lib.Enum and lib.Enum.raceMaskById
  QDB.ok = true
end

local function AreaName(areaId)
  if not areaId or areaId <= 0 then return nil end
  if C_Map and C_Map.GetAreaInfo then
    local n = C_Map.GetAreaInfo(areaId)
    if n and n ~= "" then return n end
  end
  local d = QDB.dungeons and QDB.dungeons[areaId]
  if d then return d[1] end
  return L["Zone "] .. areaId
end

local function PlayerBits()
  local _, _, classID = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  local classBit = classID and 2 ^ (classID - 1) or nil
  local raceBit = raceID and ((QDB.raceMasks and QDB.raceMasks[raceID]) or 2 ^ (raceID - 1)) or nil
  return classBit, raceBit
end

-- Static quest data, cached.
local metaCache = {}
local function QuestMeta(id)
  if not QDB.ok or not id then return nil end
  local m = metaCache[id]
  if m == nil then
    local Q = QDB.Quest
    local name = QGet(Q, id, "name")
    if not name then
      metaCache[id] = false
      return nil
    end
    m = {
      id = id,
      name = name,
      level = QGet(Q, id, "questLevel") or 0,
      reqLevel = QGet(Q, id, "requiredLevel") or 0,
      races = QGet(Q, id, "requiredRaces") or 0,
      classes = QGet(Q, id, "requiredClasses") or 0,
      sort = QGet(Q, id, "zoneOrSort") or 0,
      skill = QGet(Q, id, "requiredSkill"),
      nextQ = QGet(Q, id, "nextQuestInChain"),
      children = QGet(Q, id, "childQuests"),
    }
    metaCache[id] = m
  end
  return m or nil
end

local function PopCount(mask)
  local n, b = 0, 1
  while b <= mask and b <= 2 ^ 12 do
    if HasBit(mask, b) then n = n + 1 end
    b = b * 2
  end
  return n
end

local function IsClassMeta(m)
  return CLASS_SORTS[m.sort] or (m.classes ~= 0 and PopCount(m.classes) <= 4) or false
end

local function IsProfMeta(m)
  return PROF_SORTS[m.sort] or (m.skill ~= nil) or false
end

local function AllowedForPlayer(m, classBit, raceBit)
  if m.races ~= 0 and raceBit and not HasBit(m.races, raceBit) then return false end
  if m.classes ~= 0 and classBit and not HasBit(m.classes, classBit) then return false end
  return true
end

-- Estimated XP at the current level (formula used by Questie, without temporary bonuses).
local function DBXP(id, plevel)
  local row = QDB.xp and QDB.xp[id]
  if not row then return nil end
  local qLevel, xp = row[1], row[2]
  if not qLevel or qLevel <= 0 or not xp or xp <= 0 then return 0 end
  if GetMaxPlayerLevel and plevel >= GetMaxPlayerLevel() then return 0 end
  local mult = math.max(1, math.min(10, 2 * (qLevel - plevel) + 20))
  xp = xp * mult / 10
  if xp <= 100 then xp = 5 * math.floor((xp + 2) / 5)
  elseif xp <= 500 then xp = 10 * math.floor((xp + 5) / 10)
  elseif xp <= 1000 then xp = 25 * math.floor((xp + 12) / 25)
  else xp = 50 * math.floor((xp + 25) / 50) end
  return math.floor(xp)
end

local function NextQuests(m)
  local t = {}
  if m.nextQ and m.nextQ > 0 then t[#t + 1] = m.nextQ end
  if type(m.children) == "table" then
    for _, c in ipairs(m.children) do t[#t + 1] = c end
  end
  return t
end

-- Walks the quest's follow-ups (unlocked quests, recursively).
local function ChainInfo(id, plevel, range)
  local m = QuestMeta(id)
  if not m then return nil end
  local classBit, raceBit = PlayerBits()
  local info = { count = 0, xp = 0, maxLevel = 0, useful = false, hasClass = false, hasProf = false }
  local seen, queue = { [id] = true }, {}
  local function push(list)
    for _, qid in ipairs(list) do
      if not seen[qid] then
        seen[qid] = true
        queue[#queue + 1] = qid
      end
    end
  end
  push(NextQuests(m))
  local i = 1
  while i <= #queue and i <= 40 do
    local qid = queue[i]
    i = i + 1
    if not IsCompleted(qid) then
      local c = QuestMeta(qid)
      if c and AllowedForPlayer(c, classBit, raceBit) then
        info.count = info.count + 1
        local lvl = (c.level and c.level > 0) and c.level or plevel
        if lvl > info.maxLevel then info.maxLevel = lvl end
        if lvl >= plevel - range then info.useful = true end
        info.xp = info.xp + (DBXP(qid, plevel) or 0)
        if IsClassMeta(c) then info.hasClass = true end
        if IsProfMeta(c) then info.hasProf = true end
        push(NextQuests(c))
      end
    end
  end
  return info
end

local function ChainText(chain)
  if not chain or chain.count == 0 then return nil end
  local s = L["follow-up: "] .. chain.count .. L[" quest(s) up to level "] .. chain.maxLevel
  if chain.xp > 0 then s = s .. ", ~" .. chain.xp .. " XP" end
  if chain.hasClass then s = s .. L[", class"] end
  if chain.hasProf then s = s .. L[", profession"] end
  return s
end

-- Name + location of an NPC or a world object.
local function SpawnPlace(entity, id)
  local name = QGet(entity, id, "name")
  local spawns = QGet(entity, id, "spawns")
  local zone, x, y
  if type(spawns) == "table" then
    for zoneId, pts in pairs(spawns) do
      zone = AreaName(zoneId)
      if type(pts) == "table" and pts[1] and pts[1][1] and pts[1][1] >= 0 then
        x, y = pts[1][1], pts[1][2]
      end
      break
    end
  end
  return name, zone, x, y
end

local function PlaceText(name, zone, x, y)
  if not name then return nil end
  local s = name
  if zone then
    s = s .. " - " .. zone
    if x and y then s = s .. string.format(" (%.0f, %.0f)", x, y) end
  end
  return s
end

-- givers = {npcIds?, objectIds?, itemIds?}
local function GiverText(givers)
  if type(givers) ~= "table" then return nil, nil end
  if type(givers[1]) == "table" and givers[1][1] then
    local name, zone, x, y = SpawnPlace(QDB.Npc, givers[1][1])
    return PlaceText(name, zone, x, y), zone
  end
  if type(givers[2]) == "table" and givers[2][1] then
    local name, zone, x, y = SpawnPlace(QDB.Object, givers[2][1])
    return PlaceText(name, zone, x, y), zone
  end
  if type(givers[3]) == "table" and givers[3][1] then
    local name = QGet(QDB.Item, givers[3][1], "name")
    return name and (L["object: "] .. name) or nil, nil
  end
  return nil, nil
end

local function TurnInText(id)
  if not QDB.ok then return nil end
  return (GiverText(QGet(QDB.Quest, id, "finishedBy")))
end

-- Profession names by skill line id (for missing prerequisites).
K.SKILL_NAMES = {
  [164] = L["Blacksmithing"], [165] = L["Leatherworking"], [171] = L["Alchemy"], [182] = L["Herbalism"],
  [185] = L["Cooking"], [186] = L["Mining"], [197] = L["Tailoring"], [202] = L["Engineering"],
  [333] = L["Enchanting"], [356] = L["Fishing"], [393] = L["Skinning"], [129] = L["First Aid"],
  [762] = L["Riding"],
}
-- Profession skill line ids.
local PROFESSION_SKILLS = {
  [164] = true, [165] = true, [171] = true, [182] = true, [185] = true, [186] = true, [197] = true,
  [202] = true, [333] = true, [356] = true, [393] = true, [129] = true, [755] = true, [773] = true,
  [794] = true, [762] = true,
}

-- Professions known by the character: skillLine -> rank, localized names, and whether reading succeeded.
-- Forever uses C_SkillInfo (like Questie); the other APIs are fallbacks.
local skillCache, skillCacheTime = nil, 0
local function PlayerSkills()
  local now = GetTime and GetTime() or 0
  if skillCache and now - skillCacheTime < 5 then return skillCache[1], skillCache[2], skillCache[3] end
  local skills, names, known = {}, {}, false
  if C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
    -- Expand collapsed categories to see every line (from the end to the beginning).
    if C_SkillInfo.ExpandSkillHeader then
      for i = C_SkillInfo.GetNumSkillLines(), 1, -1 do
        local line = C_SkillInfo.GetSkillLineInfo(i)
        if line and line.isHeader and line.isCollapsed then pcall(C_SkillInfo.ExpandSkillHeader, i) end
      end
    end
    for i = 1, C_SkillInfo.GetNumSkillLines() do
      local line = C_SkillInfo.GetSkillLineInfo(i)
      if line and not line.isHeader and line.skillID and PROFESSION_SKILLS[line.skillID] then
        skills[line.skillID] = line.rank or 0
        if line.name then names[line.name] = true end
      end
    end
    known = C_SkillInfo.GetNumSkillLines() > 0
  elseif GetProfessions and GetProfessionInfo then
    local list = { GetProfessions() }
    for i = 1, 6 do
      local idx = list[i]
      if idx then
        local ok, name, _, rank, _, _, _, skillLine = pcall(GetProfessionInfo, idx)
        if ok then
          known = true
          if skillLine then skills[skillLine] = rank or 0 end
          if name then names[name] = true end
        end
      end
    end
  end
  skillCache, skillCacheTime = { skills, names, known }, now
  return skills, names, known
end

local function IsProfessionHeader(header)
  if not header then return false end
  if PROF_HEADERS[header] then return true end
  local _, names = PlayerSkills()
  return names[header] or false
end

---------------------------------------------------------------------------
-- Quest log capture
---------------------------------------------------------------------------
local function GetObjectives(questID)
  local out = {}
  if C_QuestLog.GetQuestObjectives then
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, questID)
    if ok and objs then
      for _, o in ipairs(objs) do
        -- The "finished" flag is not always updated right away: 15/15 = finished.
        local done = o.finished or ((o.numRequired or 0) > 0 and (o.numFulfilled or 0) >= o.numRequired) or false
        out[#out + 1] = {
          text = CleanText(o.text, (o.numRequired or 2) > 1),
          type = o.type,
          finished = done,
          have = o.numFulfilled,
          need = o.numRequired,
        }
      end
    end
  end
  return out
end

-- Quest description text (requires "selecting" it in the quest log).
local function GetQuestTexts(questID)
  if not (C_QuestLog.SetSelectedQuest and GetQuestLogQuestText) then return nil, nil end
  local previous = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
  local ok, desc, objText = pcall(function()
    C_QuestLog.SetSelectedQuest(questID)
    return GetQuestLogQuestText()
  end)
  if previous and previous ~= 0 then pcall(C_QuestLog.SetSelectedQuest, previous) end
  if ok then return desc, objText end
  return nil, nil
end

local function GetXP(questID)
  if GetQuestLogRewardXP then
    local ok, xp = pcall(GetQuestLogRewardXP, questID)
    if ok and xp and xp > 0 then return xp end
  end
  if QDB.ok then return DBXP(questID, UnitLevel("player")) end
  return nil
end

-- Zone where the objectives take place, and dungeon/raid hint.
local function GetQuestPlace(questID)
  local mapZone, isInstance, instanceName
  if GetQuestUiMapID and C_Map and C_Map.GetMapInfo then
    local ok, mapID = pcall(GetQuestUiMapID, questID)
    if ok and mapID and mapID > 0 then
      local info = C_Map.GetMapInfo(mapID)
      if info then
        mapZone = info.name
        if Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Dungeon then isInstance = true end
      end
    end
  end
  local tagName
  if C_QuestLog.GetQuestTagInfo then
    local ok, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)
    if ok and tag then
      tagName = tag.tagName
      if Enum and Enum.QuestTag and (tag.tagID == Enum.QuestTag.Dungeon or tag.tagID == Enum.QuestTag.Raid) then
        isInstance = true
      end
    end
  end
  -- QuestieDB: quest zone and dungeon, if any
  local m = QuestMeta(questID)
  if m and m.sort > 0 then
    local d = QDB.dungeonOf[m.sort]
    if d then
      isInstance = true
      instanceName = AreaName(d)
    elseif not mapZone then
      mapZone = AreaName(m.sort)
    end
  end
  return mapZone, isInstance, tagName, instanceName
end

local function Snapshot()
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then
    Print(L["C_QuestLog API not found, cannot export."])
    return 0
  end

  local quests, header = {}, nil
  local n = C_QuestLog.GetNumQuestLogEntries() or 0

  for i = 1, n do
    local info = C_QuestLog.GetInfo(i)
    if info then
      if info.isHeader then
        header = info.title
      elseif not info.isHidden and info.questID and info.questID > 0 then
        local id = info.questID
        local desc, objText = GetQuestTexts(id)
        local mapZone, isInstance, tagName, instanceName = GetQuestPlace(id)
        quests[#quests + 1] = {
          id = id,
          title = info.title,
          zone = header,
          mapZone = mapZone,
          isInstance = isInstance,
          instanceName = instanceName,
          tag = tagName,
          level = info.level,
          difficultyLevel = info.difficultyLevel,
          suggestedGroup = info.suggestedGroup,
          frequency = info.frequency, -- 0 normal, 1 daily, 2 weekly
          isTask = info.isTask,
          xp = GetXP(id),
          money = (function()
            if not GetQuestLogRewardMoney then return nil end
            local ok, m = pcall(GetQuestLogRewardMoney, id)
            return ok and m or nil
          end)(),
          complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) or false,
          failed = C_QuestLog.IsFailed and C_QuestLog.IsFailed(id) or false,
          objectives = GetObjectives(id),
          objectivesText = objText,
          description = desc,
        }
      end
    end
  end

  local _, class = UnitClass("player")
  ForeverQuestPlannerDB = ForeverQuestPlannerDB or {}
  ForeverQuestPlannerDB[CharKey()] = {
    name = UnitName("player"),
    class = class,
    level = UnitLevel("player"),
    zone = GetRealZoneText(),
    updated = date("%Y-%m-%d %H:%M:%S"),
    count = #quests,
    quests = quests,
  }
  return #quests
end

-- Automatic, batched update (the game sends QUEST_LOG_UPDATE very often).
local pending = false
local function ScheduleSnapshot()
  if pending then return end
  pending = true
  C_Timer.After(2, function()
    pending = false
    Snapshot()
  end)
end

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

-- Returns true + reason if the item is interesting, false otherwise, nil if unknown (not cached).
local function EvaluateItem(link, isUsable)
  if not link then return nil end
  local name, _, _, ilvl, _, _, _, _, equipLoc = GetItemInfoCompat(link)
  if not name then return nil end
  if equipLoc == "INVTYPE_BAG" then return true, name .. L[" (bag)"] end
  local slots = SLOTS[equipLoc]
  if not slots or isUsable == false then return false end
  local worst = math.huge
  for _, s in ipairs(slots) do worst = math.min(worst, EquippedItemLevel(s)) end
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
  return table.concat(parts, " ; ")
end

---------------------------------------------------------------------------
-- Quest log analysis: to turn in, to abandon, groups, dungeons, later
---------------------------------------------------------------------------
-- Localized names of the dungeons known by QuestieDB (to recognize quest log categories).
local dungeonNameSet
local function DungeonNames()
  if dungeonNameSet then return dungeonNameSet end
  dungeonNameSet = {}
  if QDB.ok then
    for areaId in pairs(QDB.dungeonOf or {}) do
      local n = AreaName(areaId)
      if n then dungeonNameSet[n] = true end
    end
  end
  return dungeonNameSet
end

local function DungeonOf(q)
  if q.instanceName then return q.instanceName end
  if q.zone and DungeonNames()[q.zone] then return q.zone end
  if q.isInstance then return q.zone or L["Dungeon"] end
  if q.tag and (q.tag:find("Donjon") or q.tag:find("Dungeon") or q.tag:find("Raid")) then return q.zone or L["Dungeon"] end
  return nil
end

-- Money: interest threshold (level² × 2 copper) and display in g/s/c.
local function MoneyThreshold(plevel)
  return (plevel or 1) * (plevel or 1) * 2
end

local function MoneyText(copper)
  if not copper or copper <= 0 then return nil end
  if GetCoinTextureString then
    local ok, txt = pcall(GetCoinTextureString, copper)
    if ok and txt then return txt end
  end
  local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. L["g"] end
  if sv > 0 then parts[#parts + 1] = sv .. L["s"] end
  if c > 0 then parts[#parts + 1] = c .. L["c"] end
  return table.concat(parts, " ")
end

local function Analyze()
  Snapshot()
  local e = ForeverQuestPlannerDB[CharKey()]
  local result = { abandon = {}, turnIn = {}, groups = {}, later = {}, dungeons = {}, kept = 0 }
  local byDungeon = {}
  if not e then return result end

  local plevel = UnitLevel("player")
  local className = UnitClass("player")
  local range = TrivialRange()
  local keep = Settings().keep
  local byZone = {}

  for _, q in ipairs(e.quests) do
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
      if q.failed and not keep[q.id] then
        q._abandon = L["Failed quest"]
      elseif not (isClass or isProf or keep[q.id] or xpUseful or itemReason or itemUnknown or chainUseful or moneyUseful) then
      local why = {}
      why[#why + 1] = trivial and (L["gray (level "] .. level .. ")") or L["no XP"]
      why[#why + 1] = L["no useful item"]
      why[#why + 1] = (q.money and q.money > 0) and (L["little money ("] .. MoneyText(q.money) .. ")") or L["no money"]
      if not QDB.ok then
        why[#why + 1] = L["unknown follow-up (QuestieDB missing)"]
      elseif chain and chain.count > 0 then
        why[#why + 1] = L["gray follow-up ("] .. chain.count .. L[" quest(s))"]
      else
        why[#why + 1] = L["no follow-up"]
      end
        q._abandon = table.concat(why, ", ")
      end
      if q._abandon then result.abandon[#result.abandon + 1] = { quest = q, reason = q._abandon } end
      if keep[q.id] then result.kept = result.kept + 1 end
      local dungeon = DungeonOf(q)
      if dungeon then
        q._tooHigh = level > plevel + 3
        local g = byDungeon[dungeon]
        if not g then
          g = { name = dungeon, instance = true, quests = {} }
          byDungeon[dungeon] = g
          result.dungeons[#result.dungeons + 1] = g
        end
        g.quests[#g.quests + 1] = q
      elseif level > plevel + 3 and not isProf then
        result.later[#result.later + 1] = q
      else
        local key
        if isProf and not q.isInstance then
          key = L["Professions"]
        elseif isClass and not q.isInstance then
          key = L["Class"]
        elseif q.isInstance then
          key = q.instanceName or q.zone or L["Dungeon"]
        else
          key = q.mapZone or q.zone or L["No zone"]
        end
        local g = byZone[key]
        if not g then
          g = { name = key, instance = q.isInstance, quests = {} }
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
  table.sort(result.dungeons, function(a, b)
    if #a.quests ~= #b.quests then return #a.quests > #b.quests end
    return a.name < b.name
  end)
  for _, g in ipairs(result.dungeons) do
    table.sort(g.quests, function(a, b) return (a.level or 0) < (b.level or 0) end)
  end
  return result
end

---------------------------------------------------------------------------
-- Available quests (QuestieDB), scan spread over several frames
---------------------------------------------------------------------------
local scan = { running = false, dirty = true, entries = nil }

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
    lookahead = K.LOOKAHEAD_LEVELS,
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
  return (name or (L["faction "] .. rep[1])) .. L[": "] .. StandingLabel(rep[2]) .. L[" required"]
end

local function AnyNonEmpty(t)
  if type(t) ~= "table" then return false end
  for _, v in pairs(t) do
    if type(v) == "table" and v[1] then return true end
  end
  return false
end

local function CheckAvailable(id, ctx)
  local Q = QDB.Quest
  local req = QGet(Q, id, "requiredLevel") or 0
  local lvl = QGet(Q, id, "questLevel") or 0
  -- Only the required level decides whether the character can pick the quest up (a high quest
  -- level alone does not hide it).
  -- Quests slightly too high kept for the Roadbook (unlocked by the expected level).
  if req > ctx.plevel + (ctx.lookahead or 0) then return nil end
  local function done(q) return IsCompleted(q) or (ctx.done and ctx.done[q]) or false end
  -- Missing prerequisites (quests, professions): the quest is listed with what is missing.
  local missing = { texts = {}, quests = {} }
  local function questName(q) return string.format(L["\"%s\""], QGet(Q, q, "name") or ("#" .. q)) end
  if lvl < 0 then lvl = ctx.plevel end -- quest at the player's level
  local lowLevel = lvl > 0 and lvl < ctx.plevel - ctx.range
  local maxL = QGet(Q, id, "requiredMaxLevel")
  if maxL and maxL > 0 and ctx.plevel > maxL then return nil end
  if IsCompleted(id) or IsInLog(id) then return nil end

  local races = QGet(Q, id, "requiredRaces") or 0
  if races ~= 0 and ctx.raceBit and not HasBit(races, ctx.raceBit) then return nil end
  local classes = QGet(Q, id, "requiredClasses") or 0
  if classes ~= 0 and ctx.classBit and not HasBit(classes, ctx.classBit) then return nil end

  local sort = QGet(Q, id, "zoneOrSort") or 0
  if EVENT_SORTS[sort] then return nil end

  local group = QGet(Q, id, "preQuestGroup")
  if type(group) == "table" then
    for _, p in ipairs(group) do
      if not done(p) then
        missing.texts[#missing.texts + 1] = questName(p)
        missing.quests[#missing.quests + 1] = { p }
      end
    end
  end
  local single = QGet(Q, id, "preQuestSingle")
  if type(single) == "table" and #single > 0 then
    local ok = false
    for _, p in ipairs(single) do if done(p) then ok = true break end end
    if not ok then
      local names = {}
      for _, p in ipairs(single) do names[#names + 1] = questName(p) end
      missing.texts[#missing.texts + 1] = table.concat(names, L[" or "])
      missing.quests[#missing.quests + 1] = single
    end
  end
  local excl = QGet(Q, id, "exclusiveTo")
  if type(excl) == "table" then
    for _, x in ipairs(excl) do if IsCompleted(x) or IsInLog(x) then return nil end end
  end
  local nx = QGet(Q, id, "nextQuestInChain")
  if nx and nx > 0 and (IsCompleted(nx) or IsInLog(nx)) then return nil end
  local parent = QGet(Q, id, "parentQuest")
  if parent and parent > 0 and not IsInLog(parent) then return nil end
  local asw = QGet(Q, id, "availableStartingWith")
  if asw and asw > 0 and not (IsInLog(asw) or done(asw)) then return nil end
  local auc = QGet(Q, id, "availableUntilCompleted")
  if auc and auc > 0 and IsCompleted(auc) then return nil end
  local dis = QGet(Q, id, "disabledByQuest")
  if dis and dis > 0 and IsInLog(dis) then return nil end
  local spell = QGet(Q, id, "requiredSpell")
  if spell and spell ~= 0 and IsSpellKnown then
    local known = IsSpellKnown(math.abs(spell)) and true or false
    if (spell > 0) ~= known then return nil end
  end
  local skill = QGet(Q, id, "requiredSkill")
  if type(skill) == "table" and ctx.skillsKnown then
    local have = ctx.skills[skill[1]]
    if not have or have < (skill[2] or 0) then
      missing.texts[#missing.texts + 1] = (K.SKILL_NAMES[skill[1]] or (L["profession"] .. " " .. skill[1])) ..
        ((skill[2] or 0) > 0 and (" " .. skill[2]) or "")
    end
  end
  if ctx.skillsKnown then
    -- Specialization: a profession id (the profession is required) or a specialization spell.
    local spec = QGet(Q, id, "requiredSpecialization")
    if spec and spec > 0 then
      if PROFESSION_SKILLS[spec] then
        if not ctx.skills[spec] then missing.texts[#missing.texts + 1] = K.SKILL_NAMES[spec] or L["profession"] end
      elseif IsSpellKnown and not IsSpellKnown(spec) then
        return nil
      end
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
            names[#names + 1] = (K.SKILL_NAMES[pair[1]] or tostring(pair[1])) .. " " .. pair[2]
          end
        end
        missing.texts[#missing.texts + 1] = table.concat(names, L[" or "])
      end
    end
  end

  local starters = QGet(Q, id, "startedBy")
  if not AnyNonEmpty(starters) then return nil end

  local name = QGet(Q, id, "name")
  if not name then return nil end

  local m = QuestMeta(id)
  local dungeonId = sort > 0 and QDB.dungeonOf[sort] or nil
  local starterText, starterZone = GiverText(starters)
  return {
    id = id,
    name = name,
    level = lvl,
    reqLevel = req,
    future = req > ctx.plevel or nil,
    xp = DBXP(id, math.max(ctx.plevel, req)),
    dungeon = dungeonId and AreaName(dungeonId) or nil,
    area = (sort > 0 and not dungeonId) and AreaName(sort) or nil,
    starter = starterText,
    starterZone = starterZone,
    isClass = m and IsClassMeta(m) or false,
    isProf = m and IsProfMeta(m) or false,
    opensChain = m and #NextQuests(m) > 0 or false,
    repMissing = MissingReputation(QGet(Q, id, "requiredMinRep")),
    missing = #missing.texts > 0 and missing or nil,
    repeatable = HasBit(QGet(Q, id, "specialFlags") or 0, 1),
    lowLevel = lowLevel,
  }
end

local Refresh -- declared further down

local function StartScan()
  if scan.running or not QDB.ok then return end
  local okIds, ids = pcall(QDB.Quest.GetAllIds)
  if not okIds or type(ids) ~= "table" then
    scan.error = L["Unable to read the QuestieDB quest list."]
    return
  end
  if #ids == 0 and next(ids) then
    local list = {}
    for k in pairs(ids) do list[#list + 1] = k end
    ids = list
  end

  local ctx = BuildScanContext()
  local results, i = {}, 1
  scan.running, scan.error = true, nil
  local function step()
    local stop = math.min(i + 249, #ids)
    for k = i, stop do
      local ok, entry = pcall(CheckAvailable, ids[k], ctx)
      if ok and entry then results[#results + 1] = entry end
    end
    i = stop + 1
    if i <= #ids then
      C_Timer.After(0, step)
    else
      scan.running, scan.dirty = false, false
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
      results = kept
      scan.entries = results
      if Refresh then Refresh() end
    end
  end
  step()
end

---------------------------------------------------------------------------
-- Geography: QuestieDB positions converted to world coordinates (game map API)
---------------------------------------------------------------------------
local Geo = { npc = {}, object = {}, targets = {}, givers = {} }
K.CROSS_CONTINENT = 480 -- flat seconds to change continent
K.PATH_FACTOR = 1.35    -- paths are never straight lines
K.OVERHEAD = 20         -- dialogs, quest pick-up/turn-in

local function LoadDataString(v)
  if type(v) == "table" then return v end
  if type(v) == "string" and loadstring then
    local fn = loadstring(v)
    if fn then
      local ok, t = pcall(fn)
      if ok and type(t) == "table" then return t end
    end
  end
  return nil
end

local function GeoReady()
  if Geo.ready ~= nil then return Geo.ready end
  Geo.ready = false
  if not (QDB.ok and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return false end
  local p = QDB.zonePrivate or {}
  Geo.areaToUi = LoadDataString(p.areaIdToUiMapId) or {}
  for k, v in pairs(LoadDataString(p.areaIdToUiMapIdOverride) or {}) do Geo.areaToUi[k] = v end
  Geo.parent = LoadDataString(p.subZoneToParentZone) or {}
  for k, v in pairs(LoadDataString(p.subZoneToParentZoneOverride) or {}) do Geo.parent[k] = v end
  Geo.ready = next(Geo.areaToUi) ~= nil
  return Geo.ready
end

-- Drop rate (%) of an item on an NPC, from the Wowhead data shipped with QuestieDB.
local function DropRate(itemId, npcId)
  if Geo.drops == nil then
    Geo.drops = false
    if QDB.lib and QDB.lib.Support then
      local ok, mod = pcall(QDB.lib.Support.Get, "QuestieClassicItemDrops")
      if ok and type(mod) == "table" then Geo.drops = LoadDataString(mod.wowheadData) or false end
    end
  end
  local t = Geo.drops and Geo.drops[itemId]
  return t and t[npcId]
end

-- Zone (AreaID) + 0-100 coordinates -> world point {c = continent, x, y, area, mx, my}
local function WorldPos(areaId, x, y)
  local ui = Geo.areaToUi[areaId]
  if (not ui or ui == 0) and Geo.parent[areaId] then ui = Geo.areaToUi[Geo.parent[areaId]] end
  if not ui or ui == 0 then return nil end
  local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, ui, CreateVector2D(x / 100, y / 100))
  if not ok or not cont or not pos then return nil end
  local wx, wy = pos:GetXY()
  return { c = cont, x = wx, y = wy, area = areaId, mx = x, my = y }
end

local function DungeonEntrance(areaId)
  local d = QDB.dungeonOf[areaId]
  local entry = d and QDB.dungeons[d]
  local loc = entry and type(entry[4]) == "table" and entry[4][1]
  if not loc then return nil end
  local w = WorldPos(loc[1], loc[2], loc[3])
  if w then w.instance = AreaName(d) end
  return w
end

-- Spawn points (sampled) of an NPC or a world object.
local function EntityPoints(kind, id)
  local cache = Geo[kind]
  if cache[id] then return cache[id] end
  local entity = (kind == "npc") and QDB.Npc or QDB.Object
  local pts = {}
  local spawns = QGet(entity, id, "spawns")
  if type(spawns) == "table" then
    for zone, list in pairs(spawns) do
      if type(list) == "table" and #list > 0 then
        local step = math.max(1, math.floor(#list / 10))
        for i = 1, #list, step do
          local p = list[i]
          if type(p) == "table" and p[1] then
            local w = (p[1] < 0) and DungeonEntrance(zone) or WorldPos(zone, p[1], p[2])
            if w then pts[#pts + 1] = w end
            if p[1] < 0 then break end
          end
        end
      end
    end
  end
  cache[id] = pts
  return pts
end

local function GiverPoints(givers)
  local pts = {}
  if type(givers) ~= "table" then return pts end
  for _, id in ipairs(givers[1] or {}) do
    for _, p in ipairs(EntityPoints("npc", id)) do pts[#pts + 1] = p end
  end
  for _, id in ipairs(givers[2] or {}) do
    for _, p in ipairs(EntityPoints("object", id)) do pts[#pts + 1] = p end
  end
  return pts
end

local function StartPoints(id)
  local pts = Geo.givers[id]
  if not pts then
    pts = GiverPoints(QGet(QDB.Quest, id, "startedBy"))
    Geo.givers[id] = pts
  end
  return pts
end

local function Dist(a, b)
  if not a or not b or a.c ~= b.c then return nil end
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function Nearest(points, from)
  local best, bd
  for _, p in ipairs(points or {}) do
    local d = Dist(p, from)
    if d and (not bd or d < bd) then best, bd = p, d end
  end
  if not best and points and points[1] then return points[1], nil end
  return best, bd
end

local function PlayerPos()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
  local map = C_Map.GetBestMapForUnit("player")
  if not map then return nil end
  local pos = C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return nil end
  local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, map, pos)
  if not ok or not cont or not w then return nil end
  local x, y = w:GetXY()
  return { c = cont, x = x, y = y }
end

-- Travel speed: running, or the mount speed remembered the last time you were mounted.
local function TravelSpeed()
  local s = Settings()
  if GetUnitSpeed and IsMounted and IsMounted() then
    local _, run = GetUnitSpeed("player")
    if run and run > 7 then s.mountSpeed = run end
  end
  return math.max(7, s.mountSpeed or 7)
end

local function TravelTime(a, b, speed)
  if not a or not b then return 0 end
  local d = Dist(a, b)
  if not d then return K.CROSS_CONTINENT end
  return d * K.PATH_FACTOR / speed
end

local function PointText(p)
  if not p then return "?" end
  if p.instance then return p.instance .. L[" (entrance)"] end
  return string.format("%s (%.0f, %.0f)", AreaName(p.area) or p.zoneName or "?", p.mx or 0, p.my or 0)
end

local function AllInstance(points)
  if #points == 0 then return false end
  for _, p in ipairs(points) do if not p.instance then return false end end
  return true
end

---------------------------------------------------------------------------
-- Transport network: known flight masters, zeppelins, boats
---------------------------------------------------------------------------
K.FLIGHT_SPEED = 30     -- m/s while flying
K.FLIGHT_OVERHEAD = 30  -- dialog, take-off, landing
K.TRANSPORT_TIME = 180  -- average wait + crossing
K.DANGER_MARGIN = 2     -- dangerous zone if its minimum level > player level + margin
K.DANGER_FACTOR = 1.5   -- extra cost of walking in a dangerous zone (detours, fights)
K.K_HUBS = 3            -- number of transport points considered at departure and arrival

-- Classic coordinates, converted for Forever by QuestieDB when the zone has changed.
local DOCKS = {
  { key = "ogz", name = L["Orgrimmar zeppelin tower"], area = 14, x = 50.7, y = 13.0, faction = "Horde" },
  { key = "ucz", name = L["Tirisfal zeppelin tower"], area = 85, x = 60.8, y = 58.8, faction = "Horde" },
  { key = "ggz", name = L["Grom'gol zeppelin tower"], area = 33, x = 31.6, y = 29.6, faction = "Horde" },
  { key = "rat", name = L["Ratchet docks"], area = 17, x = 63.7, y = 38.6 },
  { key = "bb", name = L["Booty Bay docks"], area = 33, x = 25.9, y = 73.1 },
  { key = "men", name = L["Menethil Harbor"], area = 11, x = 5.0, y = 60.0, faction = "Alliance" },
  { key = "the", name = L["Theramore docks"], area = 15, x = 71.6, y = 56.4, faction = "Alliance" },
  { key = "aub", name = L["Auberdine docks"], area = 148, x = 32.6, y = 43.2, faction = "Alliance" },
  { key = "rut", name = "Rut'theran", area = 141, x = 54.9, y = 96.8, faction = "Alliance" },
}
local LINKS = {
  { "ogz", "ucz", "zeppelin" }, { "ogz", "ggz", "zeppelin" }, { "ucz", "ggz", "zeppelin" },
  { "rat", "bb", "bateau" }, { "men", "the", "bateau" }, { "men", "aub", "bateau" }, { "aub", "rut", "bateau" },
}

local function TaxiStore()
  local s = Settings()
  s.taxi = s.taxi or {}
  local k = CharKey()
  s.taxi[k] = s.taxi[k] or {}
  return s.taxi[k]
end

local function TaxiCount()
  local n = 0
  for _ in pairs(TaxiStore()) do n = n + 1 end
  return n
end

-- Called when a flight master's map opens: records the character's known flight paths.
local function RecordTaxiNodes()
  if not (GetTaxiMapID and C_Map and C_Map.GetWorldPosFromMapPos) then return end
  local mapID = GetTaxiMapID()
  if not mapID then return end
  local store = TaxiStore()
  local function save(name, pos)
    if not name or not pos then return end
    local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
    if ok and cont and w then
      local x, y = w:GetXY()
      store[name] = { c = cont, x = x, y = y, name = name }
    end
  end
  if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
    local ok, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, mapID)
    if ok and type(nodes) == "table" then
      for _, n in ipairs(nodes) do
        local unreachable = Enum and Enum.FlightPathState and n.state == Enum.FlightPathState.Unreachable
        if not unreachable then save(n.name, n.position) end
      end
    end
  elseif NumTaxiNodes and TaxiNodeName and TaxiNodeGetType and TaxiNodePosition then
    for i = 1, NumTaxiNodes() do
      if TaxiNodeGetType(i) ~= "NONE" then
        local x, y = TaxiNodePosition(i)
        if x and y then save(TaxiNodeName(i), CreateVector2D(x, y)) end
      end
    end
  end
end

-- Zone (name, minimum level) at a world point; cached by 200 m squares.
local zoneCache = {}
local function ZoneAt(p)
  if not (C_Map.GetMapPosFromWorldPos and C_Map.GetMapInfoAtPosition and C_Map.GetMapLevels) then return nil end
  local key = p.c .. ":" .. math.floor(p.x / 200) .. ":" .. math.floor(p.y / 200)
  local z = zoneCache[key]
  if z == nil then
    z = false
    local ok, ui, mp = pcall(C_Map.GetMapPosFromWorldPos, p.c, CreateVector2D(p.x, p.y))
    if ok and ui and mp then
      local mx, my = mp:GetXY()
      local okI, info = pcall(C_Map.GetMapInfoAtPosition, ui, mx, my)
      local zoneMap = (okI and info and info.mapID) or ui
      local okL, minL = pcall(C_Map.GetMapLevels, zoneMap)
      if okL and minL and minL > 0 then
        z = { name = (okI and info and info.name) or AreaName(0), min = minL }
      end
    end
    zoneCache[key] = z
  end
  return z or nil
end

-- Walking time between two points; also returns the dangerous zone crossed.
local function WalkCost(a, b, net, plevel)
  local d = Dist(a, b)
  if not d then return math.huge end
  local t = d * K.PATH_FACTOR / net.speed
  local worst
  if d > 300 then
    for _, f in ipairs({ 0.25, 0.5, 0.75, 1 }) do
      local z = ZoneAt({ c = a.c, x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f })
      if z and z.min > plevel + K.DANGER_MARGIN and (not worst or z.min > worst.min) then worst = z end
    end
    if worst then t = t * K.DANGER_FACTOR end
  end
  return t, worst
end

-- Transport point graph + shortest paths (Floyd-Warshall, about fifty nodes).
local function BuildNetwork(speed)
  local hubs = {}
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  for name, n in pairs(TaxiStore()) do
    hubs[#hubs + 1] = { kind = "taxi", name = name, p = { c = n.c, x = n.x, y = n.y } }
  end
  local dockIndex = {}
  for _, dock in ipairs(DOCKS) do
    if not dock.faction or dock.faction == faction then
      local x, y = dock.x, dock.y
      if QDB.lib and QDB.lib.EraToForever then
        local ok, fx, fy = pcall(QDB.lib.EraToForever, dock.area, x, y)
        if ok and fx and fy then x, y = fx, fy end
      end
      local w = WorldPos(dock.area, x, y)
      if w then
        hubs[#hubs + 1] = { kind = "dock", name = dock.name, p = w }
        dockIndex[dock.key] = #hubs
      end
    end
  end

  local n = #hubs
  local D, nxt, via = {}, {}, {}
  for i = 1, n do
    D[i], nxt[i], via[i] = {}, {}, {}
    for j = 1, n do
      nxt[i][j] = j
      if i == j then
        D[i][j] = 0
      else
        local a, b = hubs[i], hubs[j]
        local d = Dist(a.p, b.p)
        local best, how = math.huge, nil
        if d then
          best, how = d * K.PATH_FACTOR / speed, "walk"
          if a.kind == "taxi" and b.kind == "taxi" then
            local fl = d * 1.2 / K.FLIGHT_SPEED + K.FLIGHT_OVERHEAD
            if fl < best then best, how = fl, "flight" end
          end
        end
        D[i][j], via[i][j] = best, how
      end
    end
  end
  for _, l in ipairs(LINKS) do
    local i, j = dockIndex[l[1]], dockIndex[l[2]]
    if i and j then
      if K.TRANSPORT_TIME < D[i][j] then D[i][j], via[i][j] = K.TRANSPORT_TIME, l[3] end
      if K.TRANSPORT_TIME < D[j][i] then D[j][i], via[j][i] = K.TRANSPORT_TIME, l[3] end
    end
  end
  for k = 1, n do
    local Dk = D[k]
    for i = 1, n do
      local dik = D[i][k]
      if dik < math.huge then
        local Di, Ni, nik = D[i], nxt[i], nxt[i][k]
        for j = 1, n do
          local v = dik + Dk[j]
          if v < Di[j] then Di[j], Ni[j] = v, nik end
        end
      end
    end
  end
  return { hubs = hubs, D = D, nxt = nxt, via = via, speed = speed, near = {}, taxi = TaxiCount() }
end

local function NearHubs(net, p)
  local cached = net.near[p]
  if cached then return cached end
  local list = {}
  for i, h in ipairs(net.hubs) do
    local d = Dist(h.p, p)
    if d then list[#list + 1] = { i = i, d = d } end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  local out = {}
  for k = 1, math.min(K.K_HUBS, #list) do out[k] = list[k].i end
  net.near[p] = out
  return out
end

-- Best route from a to b: direct walk, or walk -> network -> walk.
local function Route(a, b, net, plevel)
  if not a or not b then return 0, nil end
  if not net then return TravelTime(a, b, 7), nil end
  local best = (a.c == b.c) and (WalkCost(a, b, net, plevel)) or math.huge
  local choice
  if #net.hubs > 0 then
    local hb = NearHubs(net, b)
    for _, i in ipairs(NearHubs(net, a)) do
      local wa = WalkCost(a, net.hubs[i].p, net, plevel)
      if wa < best then
        for _, j in ipairs(hb) do
          local v = wa + net.D[i][j] + (WalkCost(net.hubs[j].p, b, net, plevel))
          if v < best then best, choice = v, { i = i, j = j } end
        end
      end
    end
  end
  if best == math.huge then best = K.CROSS_CONTINENT end
  return best, choice
end

-- Readable directions to go from a to b.
local function RouteText(a, b, net, plevel)
  if not a or not b then return nil end
  local _, choice = Route(a, b, net, plevel)
  local parts = {}
  local function walk(p, q, toName)
    local d = Dist(p, q)
    if not d or d < 40 then return end
    local _, warn = WalkCost(p, q, net, plevel)
    local s = toName and string.format(L["walk to %s (%.0f m)"], toName, d) or string.format(L["walk %.0f m"], d)
    if warn then s = s .. Color("ff6060", L[" [crosses "] .. (warn.name or "?") .. L[", level "] .. warn.min .. "+]") end
    parts[#parts + 1] = s
  end
  if not choice then
    if a.c ~= b.c then
      parts[#parts + 1] = Color("ff8040", L["other continent: no known route (open a flight master's map to record it)"])
    else
      walk(a, b)
    end
  else
    local hubs = net.hubs
    walk(a, hubs[choice.i].p, hubs[choice.i].name)
    local cur, flightFrom = choice.i, nil
    while cur ~= choice.j do
      local nx = net.nxt[cur][choice.j]
      local mode = net.via[cur][nx]
      if mode == "flight" then
        flightFrom = flightFrom or hubs[cur].name
        if net.via[nx][net.nxt[nx][choice.j]] ~= "flight" or nx == choice.j then
          parts[#parts + 1] = Color("80c0ff", L["flight "] .. flightFrom .. " -> " .. hubs[nx].name)
          flightFrom = nil
        end
      elseif mode == "zeppelin" or mode == "bateau" then
        parts[#parts + 1] = Color("80c0ff", (K.MODE_NAME[mode] or mode) .. " -> " .. hubs[nx].name)
      else
        walk(hubs[cur].p, hubs[nx].p, hubs[nx].name)
      end
      cur = nx
    end
    walk(hubs[choice.j].p, b)
  end
  if #parts == 0 then return L["right here"] end
  return table.concat(parts, ", ")
end

-- Escort (or defense of an NPC): no flag says so, the text does. The English base texts are
-- read (GetRaw bypasses the translation); custom Forever quests have no flags, hence the
-- unambiguous words alone. Checked on the whole QuestieDB: 70 quests, 1 false positive.
K.ESCORT_STRONG = { "escort", "help [^.]- escape" }
K.ESCORT_FLAGGED = { "protect", "defend", "safely", "to safety", "must reach", "keep [^.]- safe",
  "show [^.]- the way", "help [^.]- to the road", "help [^.]- get", "go with" }
Geo.escort = {}
function Geo.IsEscort(id)
  if not id then return false end
  local v = Geo.escort[id]
  if v ~= nil then return v end
  local Q = QDB.Quest
  local function raw(key)
    if Q and Q.GetRaw then
      local ok, val = pcall(Q.GetRaw, id, key)
      if ok then return val end
    end
    return QGet(Q, id, key)
  end
  local parts = {}
  local trig = raw("triggerEnd")
  if type(trig) == "table" and type(trig[1]) == "string" then parts[#parts + 1] = trig[1] end
  local texts = raw("objectivesText")
  if type(texts) == "table" then
    for _, s in ipairs(texts) do parts[#parts + 1] = tostring(s) end
  end
  local text = table.concat(parts, " | "):lower()
  v = false
  for _, p in ipairs(K.ESCORT_STRONG) do
    if text:find(p) then v = true break end
  end
  if not v and HasBit(QGet(Q, id, "specialFlags") or 0, 2) then
    for _, p in ipairs(K.ESCORT_FLAGGED) do
      if text:find(p) then v = true break end
    end
  end
  Geo.escort[id] = v
  return v
end

-- Static quest targets: located objectives, start, end.
local function QuestTargets(id)
  local t = Geo.targets[id]
  if t then return t end
  t = {}
  local calls = 0
  local function add(kind, name, points, rate, mob, mobIds)
    calls = calls + 1
    if #points > 0 then
      local tg = { kind = kind, name = name, points = points, rate = rate, mobIds = mobIds or (mob and { mob }) }
      -- Monster level (min/max average) for the XP earned by killing it.
      if mob then
        local lo, hi = QGet(QDB.Npc, mob, "minLevel"), QGet(QDB.Npc, mob, "maxLevel")
        if type(lo) == "number" and lo > 0 then
          tg.mobLevel = math.floor(((lo + (type(hi) == "number" and hi or lo)) / 2) + 0.5)
          local rank = QGet(QDB.Npc, mob, "rank")
          tg.elite = rank == 1 or rank == 2 or rank == 3
        end
      end
      t[#t + 1] = tg
    end
  end
  local obj = QGet(QDB.Quest, id, "objectives")
  if type(obj) == "table" then
    for _, o in ipairs(obj[1] or {}) do
      local icon = o[3] -- QuestieDB icon type: 3 event, 5 talk, 17 interact; otherwise a monster to kill
      if icon == 3 or icon == 5 or icon == 17 then
        -- One action at the NPC (speak, scripted event…): no monster to kill, no monster XP.
        add("talk", QGet(QDB.Npc, o[1], "name"), EntityPoints("npc", o[1]))
      else
        add("kill", QGet(QDB.Npc, o[1], "name"), EntityPoints("npc", o[1]), nil, o[1])
      end
    end
    for _, o in ipairs(obj[2] or {}) do
      add("object", QGet(QDB.Object, o[1], "name"), EntityPoints("object", o[1]))
    end
    for _, o in ipairs(obj[3] or {}) do
      local itemId = o[1]
      local pts, rateSum, rateN = {}, 0, 0
      local npcs = QGet(QDB.Item, itemId, "npcDrops") or {}
      for i = 1, math.min(#npcs, 6) do
        for _, p in ipairs(EntityPoints("npc", npcs[i])) do pts[#pts + 1] = p end
        local r = DropRate(itemId, npcs[i])
        if r then rateSum, rateN = rateSum + r, rateN + 1 end
      end
      local objs = QGet(QDB.Item, itemId, "objectDrops") or {}
      for i = 1, math.min(#objs, 6) do
        for _, p in ipairs(EntityPoints("object", objs[i])) do pts[#pts + 1] = p end
      end
      local kind = (#npcs == 0 and #objs > 0) and "object" or "item"
      local ids = {}
      for i = 1, math.min(#npcs, 6) do ids[#ids + 1] = npcs[i] end
      add(kind, QGet(QDB.Item, itemId, "name"), pts, rateN > 0 and rateSum / rateN or nil, npcs[1], #ids > 0 and ids or nil)
    end
    for _, o in ipairs(obj[5] or {}) do
      if type(o) == "table" and o[2] then
        add("kill", o[3] or QGet(QDB.Npc, o[2], "name"), EntityPoints("npc", o[2]), nil, o[2])
      end
    end
  end
  local trig = QGet(QDB.Quest, id, "triggerEnd")
  if type(trig) == "table" and type(trig[2]) == "table" then
    local pts = {}
    for zone, list in pairs(trig[2]) do
      for _, p in ipairs(list) do
        local w = WorldPos(zone, p[1], p[2])
        if w then pts[#pts + 1] = w end
      end
    end
    add("explore", trig[1], pts)
  end
  -- Quantities read from the objective text ("Kill 8 ogres…"), default values otherwise.
  local texts, nums = QGet(QDB.Quest, id, "objectivesText"), {}
  if type(texts) == "table" then
    for _, s in ipairs(texts) do
      for n in tostring(s):gmatch("(%d+)") do
        local v = tonumber(n)
        if v and v > 1 and v <= 50 then nums[#nums + 1] = v end
      end
    end
  end
  for i, tg in ipairs(t) do
    tg.defaultCount = nums[i] or ((tg.kind == "kill" or tg.kind == "item") and 6 or 1)
  end
  t.missing = calls - #t -- objectives without a known position in QuestieDB
  t.start = StartPoints(id)
  t.finish = GiverPoints(QGet(QDB.Quest, id, "finishedBy"))
  Geo.targets[id] = t
  return t
end

-- Remaining objectives: matches the game's objectives (with progress) to QuestieDB targets.
local function RemainingTargets(q, t)
  local out, used = {}, {}
  local objs = (q and q.objectives) or {}
  for i, tg in ipairs(t) do
    local match
    if tg.name then
      for j, o in ipairs(objs) do
        if not used[j] and o.text and o.text:find(tg.name, 1, true) then match = j break end
      end
    end
    if not match and objs[i] and not used[i] then match = i end
    local count = tg.defaultCount
    if match then
      used[match] = true
      local o = objs[match]
      if o.finished or (o.need and o.have and o.need > 0 and o.have >= o.need) then
        count = 0
      elseif o.need and o.have and o.need > 0 then
        count = o.need - o.have
      end
    end
    if count > 0 then out[#out + 1] = { tg = tg, count = count } end
  end
  -- Unfinished game objectives that no QuestieDB target locates: the quest cannot be
  -- planned correctly (otherwise it would show as "to turn in" while still in progress).
  local unmatched = 0
  for j, o in ipairs(objs) do
    local done = o.finished or (o.need and o.have and o.need > 0 and o.have >= o.need)
    if not used[j] and not done then unmatched = unmatched + 1 end
  end
  return out, unmatched
end

-- Time (s) for one objective unit.
K.MOB_TIME = 30          -- seconds per monster killed
K.ELITE_MOB_TIME = 75    -- seconds per elite monster killed (alone)
K.KILLS_NO_RATE = 2      -- monsters per item to collect when QuestieDB does not know the drop rate
-- Monsters to kill per item: from the QuestieDB drop rate, otherwise the configured value.
function Geo.KillsPerItem(tg)
  if tg.rate and tg.rate > 0 then return 100 / math.max(tg.rate, 1) end
  return K.KILLS_NO_RATE
end
-- Fight time per monster of an objective: longer for elites.
function Geo.MobTime(tg)
  return tg.elite and K.ELITE_MOB_TIME or K.MOB_TIME
end

local function UnitTime(tg)
  if tg.kind == "kill" then return Geo.MobTime(tg) end
  if tg.kind == "item" then return Geo.MobTime(tg) * Geo.KillsPerItem(tg) end
  if tg.kind == "object" then return 20 end
  return 10
end

---------------------------------------------------------------------------
-- Around me
---------------------------------------------------------------------------
local nearRadius = 500

-- Maps (uiMap) of the current position: the player's map and its parents up to the zone.
local function CurrentMapSet()
  local set, zoneName = {}, nil
  if not (C_Map and C_Map.GetBestMapForUnit) then return set, nil end
  local id, guard = C_Map.GetBestMapForUnit("player"), 0
  while id and id > 0 and guard < 6 do
    local info = C_Map.GetMapInfo(id)
    if info and Enum and Enum.UIMapType and info.mapType <= Enum.UIMapType.Continent then break end
    set[id] = true
    if not info then break end
    if Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Zone then zoneName = info.name end
    id = info.parentMapID
    guard = guard + 1
  end
  return set, zoneName or GetRealZoneText()
end

local function PointInMaps(p, set)
  if not p or not p.area then return false end
  local ui = Geo.areaToUi[p.area] or (Geo.parent[p.area] and Geo.areaToUi[Geo.parent[p.area]])
  return ui and set[ui] or false
end

-- Returns the elements within the radius (in meters), or in the whole current zone (radius = "zone").
local function NearItems(radius)
  local pos = PlayerPos()
  if not pos then return nil, L["Unknown position (in an instance or map unavailable)."] end
  local inside, zone = {}, {}
  local here = CurrentMapSet()
  local function add(it)
    if radius == "zone" then
      if PointInMaps(it.p, here) then inside[#inside + 1] = it end
    elseif it.d <= radius then
      inside[#inside + 1] = it
    end
  end

  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do
    local t = QuestTargets(q.id)
    if q.complete then
      local p, d = Nearest(t.finish, pos)
      if d then
        local finisher = TurnInText(q.id)
        add({ kind = "turnin", id = q.id, label = q.title, d = d, p = p, level = q.level,
          giver = finisher and (finisher:match("^(.-) %- ") or finisher) })
      end
    elseif not q.failed then
      for _, r in ipairs(RemainingTargets(q, t)) do
        local p, d = Nearest(r.tg.points, pos)
        if d then
          add({ kind = "step", id = q.id, label = q.title, d = d, p = p, level = q.level,
            extra = (r.tg.name or L["objective"]) .. L[" x"] .. r.count })
        end
      end
    end
  end

  local showLow = Settings().showLowLevel
  for _, en in ipairs(scan.entries or {}) do
    if (showLow or not en.lowLevel) and not en.future and not en.missing then
      local p, d = Nearest(StartPoints(en.id), pos)
      if d then
        -- Quest giver location: the nearest point (an NPC may have several locations).
        local giver = en.starter and en.starter:match("^(.-) %- ") or en.starter
        add({ kind = "take", id = en.id, label = en.name, d = d, p = p, giver = giver,
          rep = en.repMissing, level = en.level, xp = en.xp, lowLevel = en.lowLevel })
      end
    end
  end
  table.sort(inside, function(a, b) return a.d < b.d end)
  table.sort(zone, function(a, b) return a.d < b.d end)
  return inside, zone
end

---------------------------------------------------------------------------
-- Roadbook: XP / time planning along the route
---------------------------------------------------------------------------
local xpHorizon = 7200
K.MAX_TAKE_CANDIDATES = 80
K.LOOKAHEAD_WEIGHT = 1   -- a quest is also judged with what it unlocks, at full weight
K.MAX_FOLLOW_DEPTH = 12  -- safety: maximum length of an evaluated quest chain
K.SLICE_MS = 15          -- maximum computation time per frame (the computation is spread over several frames)
K.REPLAN_DISTANCE = 150  -- beyond this distance (m), the Roadbook is recomputed from the new position
K.XP_TABLE = { 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400,
  16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
  50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500,
  123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800 }

-- Spread computation: yields back to the game when the time slice is used up.
function Geo.Yield()
  if Geo.co and debugprofilestop and coroutine.running() == Geo.co then
    if debugprofilestop() - (Geo.sliceStart or 0) > K.SLICE_MS then coroutine.yield() end
  end
end

-- XP to go from the given level to the next one (Classic table, scaled to the game's actual value).
function Geo.XPNeeded(level)
  local base = K.XP_TABLE[level]
  if not base then return nil end
  if not Geo.xpScale then
    local b = K.XP_TABLE[UnitLevel("player")]
    local real = UnitXPMax and UnitXPMax("player")
    Geo.xpScale = (b and real and real > 0) and real / b or 1
  end
  return base * Geo.xpScale
end

-- Monster XP (Classic formula: level difference, gray monsters, elites x2).
function Geo.MobXP(clevel, mlevel, elite)
  if not mlevel or mlevel <= 0 then return 0 end
  local gray
  if clevel <= 5 then gray = 0
  elseif clevel <= 39 then gray = clevel - math.floor(clevel / 10) - 5
  else gray = clevel - math.floor(clevel / 5) - 1 end
  if mlevel <= gray then return 0 end
  local base = clevel * 5 + 45
  local xp
  if mlevel >= clevel then
    xp = base * (1 + 0.05 * math.min(mlevel - clevel, 4))
  else
    local zd = (clevel <= 7 and 5) or (clevel <= 9 and 6) or (clevel <= 11 and 7) or (clevel <= 15 and 8)
      or (clevel <= 19 and 9) or (clevel <= 29 and 11) or (clevel <= 39 and 12) or (clevel <= 44 and 13)
      or (clevel <= 49 and 14) or (clevel <= 54 and 15) or (clevel <= 59 and 16) or 17
    xp = base * (1 - (clevel - mlevel) / zd)
  end
  if elite then xp = xp * 2 end
  return math.max(0, math.floor(xp))
end

-- XP of the monsters killed for an objective (kill, or loot an item from monsters).
function Geo.ObjectiveXP(r, plevel)
  local tg = r.tg
  if not tg.mobLevel then return 0 end
  local kills
  if tg.kind == "kill" then kills = r.count
  elseif tg.kind == "item" then kills = r.count * Geo.KillsPerItem(tg)
  else return 0 end
  return math.floor(kills * Geo.MobXP(plevel, tg.mobLevel, tg.elite))
end

-- Expected level after each route step (lv[1] = now), rested XP included.
function Geo.Levels(route)
  local level = UnitLevel("player")
  local xp = UnitXP and UnitXP("player") or 0
  local need = (UnitXPMax and UnitXPMax("player")) or Geo.XPNeeded(level) or math.huge
  local rested = GetXPExhaustion and GetXPExhaustion() or 0
  local maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
  local lv = { level }
  for i = 2, #route do
    local s = route[i]
    local gain = s.xp or 0
    if s.kind == "obj" and gain > 0 and rested > 0 then
      local b = math.min(rested, gain)
      rested, gain = rested - b, gain + b
    end
    xp = xp + gain
    while level < maxLevel and xp >= need do
      xp, level = xp - need, level + 1
      need = Geo.XPNeeded(level) or math.huge
    end
    lv[i] = level
  end
  return lv
end

---------------------------------------------------------------------------
-- Monster spots: grouping of QuestieDB spawn points into hunting areas
---------------------------------------------------------------------------
K.SPOT_RADIUS = 100   -- m: two spawns closer than this belong to the same spot
K.SPOT_MIN = 3        -- a spot has at least 3 monsters
K.MAX_SPAWNS = 400    -- maximum spawn points read per monster

-- All spawn points of an NPC (outside dungeons), in world coordinates.
function Geo.AllSpawns(id)
  Geo.spawnCache = Geo.spawnCache or {}
  local c = Geo.spawnCache[id]
  if c then return c end
  c = {}
  local spawns = QGet(QDB.Npc, id, "spawns")
  if type(spawns) == "table" then
    for zone, list in pairs(spawns) do
      if type(list) == "table" then
        for _, pt in ipairs(list) do
          if #c >= K.MAX_SPAWNS then break end
          if type(pt) == "table" and pt[1] and pt[1] >= 0 then
            local w = WorldPos(zone, pt[1], pt[2])
            if w then c[#c + 1] = w end
            if #c % 100 == 0 then Geo.Yield() end
          end
        end
      end
    end
  end
  Geo.spawnCache[id] = c
  return c
end

-- Spots of a monster objective (every species that counts), from the most to the least populated.
-- Each spot: { p = most central spawn point, n = number of monsters, r = radius }.
function Geo.Spots(tg)
  if tg.spots ~= nil then return tg.spots or nil end
  if not (tg.mobIds and (tg.kind == "kill" or tg.kind == "item")) then
    tg.spots = false
    return nil
  end
  local pts = {}
  for _, id in ipairs(tg.mobIds) do
    for _, w in ipairs(Geo.AllSpawns(id)) do pts[#pts + 1] = w end
  end
  local clusters = {}
  for _, w in ipairs(pts) do
    local best, bd
    for _, cl in ipairs(clusters) do
      if cl.c == w.c then
        local dx, dy = cl.x - w.x, cl.y - w.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= K.SPOT_RADIUS and (not bd or d < bd) then best, bd = cl, d end
      end
    end
    if best then
      best.pts[#best.pts + 1] = w
      local n = #best.pts
      best.x, best.y = best.x + (w.x - best.x) / n, best.y + (w.y - best.y) / n
    else
      clusters[#clusters + 1] = { c = w.c, x = w.x, y = w.y, pts = { w } }
    end
  end
  local spots = {}
  for _, cl in ipairs(clusters) do
    if #cl.pts >= K.SPOT_MIN then
      local center, cd, rad = nil, nil, 0
      for _, w in ipairs(cl.pts) do
        local dx, dy = w.x - cl.x, w.y - cl.y
        local d = math.sqrt(dx * dx + dy * dy)
        if not cd or d < cd then center, cd = w, d end
        if d > rad then rad = d end
      end
      spots[#spots + 1] = { p = center, n = #cl.pts, r = math.max(rad, 30) }
    end
  end
  table.sort(spots, function(a, b) return a.n > b.n end)
  tg.spots = #spots > 0 and spots or false
  return tg.spots or nil
end

-- Time per monster depending on spot density (close monsters = less walking between fights),
-- plus respawn waiting if more monsters are needed than the spot holds.
function Geo.SpotFactor(spot, kills)
  local n = spot and spot.n or 8
  local f = (n >= 15 and 0.75) or (n >= 8 and 1) or (n >= 4 and 1.25) or 1.6
  if kills and kills > n then f = f * 1.3 end
  return f
end

-- Best spot for an objective: travel from "from" + hunting time based on density.
function Geo.BestSpot(r, from)
  local spots = Geo.Spots(r.tg)
  if not spots then return nil end
  local kills = (r.tg.kind == "item") and r.count * Geo.KillsPerItem(r.tg) or r.count
  local speed = Geo.planSpeed or 7
  local best, bc
  for _, sp in ipairs(spots) do
    local d = Dist(from, sp.p)
    local travel = d and (d * K.PATH_FACTOR / speed) or K.CROSS_CONTINENT
    local cost = travel + kills * Geo.MobTime(r.tg) * Geo.SpotFactor(sp, kills)
    if not bc or cost < bc then best, bc = sp, cost end
  end
  return best, #spots, kills
end

-- Quest steps: pick up (if needed), each remaining objective, turn in.
-- Objectives are chained from nearest to nearest starting at the departure point.
-- For monsters, the chosen spot is the most efficient one (travel + density).
-- Each step carries its XP (monsters for an objective, reward for the turn-in).
K.ESCORT_SPEED = 2.5   -- walking speed of an escorted NPC (yd/s)
K.ESCORT_MARGIN = 90   -- ambushes, waiting for the NPC to start
local function MakeStops(task, pos, plevel)
  local t = task.targets
  local stops, from, mob = {}, pos, 0
  if task.kind == "take" then
    local p = Nearest(t.start, pos)
    if not p then return nil end
    stops[#stops + 1] = { task = task, kind = "take", p = p, work = K.OVERHEAD / 2 }
    from = p
  end
  if task.kind ~= "turnin" then
    local todo = {}
    for _, r in ipairs(task.remaining) do todo[#todo + 1] = r end
    -- Escort: it starts at the quest giver, so it comes first, before the other objectives.
    local escortFirst = task.kind == "take" and Geo.IsEscort(task.id)
    while #todo > 0 do
      local bi, bp, bd, bspot
      local onlyExplore = false
      if escortFirst then
        for _, r in ipairs(todo) do if r.tg.kind == "explore" then onlyExplore = true end end
      end
      for i, r in ipairs(todo) do
        if not (onlyExplore and r.tg.kind ~= "explore") then
          local spot = Geo.BestSpot(r, from)
          local p, d
          if spot then p, d = spot.p, Dist(from, spot.p) else p, d = Nearest(r.tg.points, from) end
          if p and (not bi or (d or math.huge) < bd) then bi, bp, bd, bspot = i, p, d or math.huge, spot end
        end
      end
      if not bi then break end
      local r = table.remove(todo, bi)
      local xp = Geo.ObjectiveXP(r, plevel or UnitLevel("player"))
      mob = mob + xp
      local work = r.count * UnitTime(r.tg)
      local nSpots
      if bspot then
        local _, ns, kills = Geo.BestSpot(r, from)
        nSpots = ns
        work = work * Geo.SpotFactor(bspot, kills)
      end
      local st = { task = task, kind = "obj", p = bp, work = work, r = r, xp = xp,
        spot = bspot, spots = nSpots }
      if r.tg.kind == "explore" and Geo.IsEscort(task.id) then
        -- Escort: the NPC walks (slower than you) and ambushes happen on the way.
        local d = Dist(from, bp) or 0
        st.escort = true
        st.work = math.max(0, d / K.ESCORT_SPEED - d / TravelSpeed()) + K.ESCORT_MARGIN
        -- Right after the pick-up: nothing may come between them (glued to the previous stop).
        if task.kind == "take" and #stops == 1 then st.glue = true end
      end
      stops[#stops + 1] = st
      from = bp
    end
  end
  local f = Nearest(t.finish, from)
  if not f then return nil end
  local turnin = { task = task, kind = "turnin", p = f, work = K.OVERHEAD / 2, xp = task.xp }
  -- Escort without a known destination (no completion trigger): it ends at the turn-in NPC.
  if task.kind == "take" and #stops == 1 and Geo.IsEscort(task.id) then
    local d = Dist(from, f) or 0
    turnin.escort, turnin.glue = true, true
    turnin.work = turnin.work + math.max(0, d / K.ESCORT_SPEED - d / TravelSpeed()) + K.ESCORT_MARGIN
  end
  stops[#stops + 1] = turnin
  task.mobXP = mob
  task.value = (task.xp or 0) + mob
  return stops
end

-- Quest to pick up (available, or a follow-up unlocked by the plan) -> plannable task.
function Geo.TakeTask(en, plevel, pos)
  if Settings().excluded[en.id] then return nil end -- removed from the Roadbook by the player
  local t = QuestTargets(en.id)
  if #t.finish == 0 then return nil end
  if (t.missing or 0) > 0 then return nil end -- an objective without a position: cannot be planned
  -- Quest filed under a dungeon: only kept when it is just about talking or delivering (e.g. to an
  -- NPC in a city); anything that happens inside the instance is rejected too.
  if en.dungeon and Geo.DungeonCombat(en.id) then return nil end
  if AllInstance(t.finish) or (#t.start > 0 and AllInstance(t.start)) then return nil end
  local remaining = RemainingTargets(nil, t)
  for _, r in ipairs(remaining) do if AllInstance(r.tg.points) then return nil end end
  local task = { id = en.id, title = en.name, level = en.level, kind = "take", xp = en.xp or 0, targets = t,
    remaining = remaining, starter = en.starter,
    reqLevel = (en.reqLevel or 0) > plevel and en.reqLevel or nil }
  task.stops = MakeStops(task, pos, plevel)
  if not task.stops then return nil end
  Geo.Priority(task, plevel, en.isClass)
  if task.later then
    Geo.RecordLater(task)
    return nil
  end
  if plevel >= Geo.MaxLevel() and (task.share or 0) <= 0 then return nil end
  return task
end

-- Reverse index "quest -> quests that require it", built once per session.
function Geo.PreIndex()
  if Geo.pre then return Geo.pre end
  local pre = {}
  local okIds, ids = pcall(QDB.Quest.GetAllIds)
  if okIds and type(ids) == "table" then
    if #ids == 0 and next(ids) then
      local list = {}
      for k in pairs(ids) do list[#list + 1] = k end
      ids = list
    end
    for n, id in ipairs(ids) do
      for _, key in ipairs({ "preQuestSingle", "preQuestGroup" }) do
        local lst = QGet(QDB.Quest, id, key)
        if type(lst) == "table" then
          for _, p in ipairs(lst) do
            pre[p] = pre[p] or {}
            table.insert(pre[p], id)
          end
        end
      end
      if n % 400 == 0 then Geo.Yield() end
    end
  end
  Geo.pre = pre
  return pre
end

-- Follow-ups of a quest that become available once it is turned in.
function Geo.Followers(task, ctx, plevel)
  if task.followers then return task.followers end
  task.followers = {}
  if not task.id or (task.depth or 0) >= K.MAX_FOLLOW_DEPTH or not task.stops then return task.followers end
  local ids, seen = {}, {}
  local m = QuestMeta(task.id)
  if m then for _, b in ipairs(NextQuests(m)) do ids[#ids + 1] = b end end
  for _, b in ipairs(Geo.PreIndex()[task.id] or {}) do ids[#ids + 1] = b end
  local done = {}
  for k, v in pairs(task.done or {}) do done[k] = v end
  done[task.id] = true
  local c = setmetatable({ done = done }, { __index = ctx })
  local from = task.stops[#task.stops].p
  for _, b in ipairs(ids) do
    if not seen[b] then
      seen[b] = true
      local ok, en = pcall(CheckAvailable, b, c)
      if ok and en and not en.repMissing and not en.missing and not en.repeatable
        and ((en.xp or 0) > 0 or plevel >= Geo.MaxLevel())
        and (en.level or 0) <= Geo.MaxQuestLevel(en.id, plevel, en.reqLevel) then
        local f = Geo.TakeTask(en, plevel, from)
        if f then
          f.dep, f.depth, f.done = task, (task.depth or 0) + 1, done
          task.followers[#task.followers + 1] = f
        end
      end
    end
  end
  return task.followers
end

---------------------------------------------------------------------------
-- Roadbook priorities: class quests, interesting rewards, quests ready to turn in.
-- XP stays the main criterion: each priority adds a share (0 to 100 %) of the XP of an average
-- Roadbook quest to the quest value when choosing. 100 % = as if it gave one more average quest.
---------------------------------------------------------------------------
K.PRIO_CLASS = 1.00        -- class quest, or a chain leading to one
K.PRIO_ITEM_SPEC = 1.00    -- usable blue (or better) item suited to the specialization
K.PRIO_ITEM_BLUE = 0.25    -- usable blue item, not ideal for the specialization
K.PRIO_UPGRADE_SPEC = 0.50 -- equipment upgrade with the right stats
K.PRIO_UPGRADE = 0.15      -- item level upgrade only
K.PRIO_BAG = 0.50          -- bag
K.PRIO_SPELL = 0.30        -- reward that teaches a skill: book, recipe of one of your professions
K.READY_BONUS = 0.10       -- quest ready to turn in (quick win, frees the quest log)
K.QUICKWIN_RADIUS = 250    -- m: turn-in added to the saved Roadbook if it is next to a step

-- Armor (subclasses) and weapons usable per class (Classic). Mail / plate from level 40.
K.ARMOR = {
  WARRIOR = { [1] = true, [2] = true, [3] = true, [4] = 40, [6] = true },
  PALADIN = { [1] = true, [2] = true, [3] = true, [4] = 40, [6] = true },
  HUNTER = { [1] = true, [2] = true, [3] = 40 },
  SHAMAN = { [1] = true, [2] = true, [3] = 40, [6] = true },
  ROGUE = { [1] = true, [2] = true },
  DRUID = { [1] = true, [2] = true },
  PRIEST = { [1] = true }, MAGE = { [1] = true }, WARLOCK = { [1] = true },
}
K.WEAPONS = {
  WARRIOR = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true, [16] = true, [18] = true },
  PALADIN = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true },
  HUNTER = { [0] = true, [1] = true, [2] = true, [3] = true, [6] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true, [16] = true, [18] = true },
  ROGUE = { [2] = true, [3] = true, [4] = true, [7] = true, [13] = true, [15] = true, [16] = true, [18] = true },
  SHAMAN = { [0] = true, [1] = true, [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
  DRUID = { [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
  PRIEST = { [4] = true, [10] = true, [15] = true, [19] = true },
  MAGE = { [7] = true, [10] = true, [15] = true, [19] = true },
  WARLOCK = { [7] = true, [10] = true, [15] = true, [19] = true },
}
-- Main stats per class and talent tree (Classic tab order).
K.SPEC_STATS = {
  SHAMAN = { { "INTELLECT" }, { "AGILITY", "STRENGTH" }, { "INTELLECT", "SPIRIT" } },
  PALADIN = { { "INTELLECT", "SPIRIT" }, { "STAMINA", "STRENGTH" }, { "STRENGTH", "AGILITY" } },
  DRUID = { { "INTELLECT" }, { "AGILITY", "STRENGTH" }, { "INTELLECT", "SPIRIT" } },
  WARRIOR = { { "STRENGTH", "AGILITY" }, { "STRENGTH", "AGILITY" }, { "STAMINA", "STRENGTH" } },
  HUNTER = { { "AGILITY" }, { "AGILITY" }, { "AGILITY" } },
  ROGUE = { { "AGILITY" }, { "AGILITY" }, { "AGILITY" } },
  PRIEST = { { "INTELLECT", "SPIRIT" }, { "INTELLECT", "SPIRIT" }, { "INTELLECT" } },
  MAGE = { { "INTELLECT" }, { "INTELLECT" }, { "INTELLECT" } },
  WARLOCK = { { "INTELLECT", "STAMINA" }, { "INTELLECT", "STAMINA" }, { "INTELLECT", "STAMINA" } },
}

-- Main talent tree (the one with the most points), nil before level 10.
function Geo.SpecIndex()
  if not (GetNumTalentTabs and GetTalentTabInfo) then return nil end
  local best, bestPts = nil, 0
  for i = 1, GetNumTalentTabs() or 0 do
    local r = { pcall(GetTalentTabInfo, i) }
    if r[1] then
      local pts = type(r[4]) == "number" and r[4] or (type(r[6]) == "number" and r[6]) or 0
      if pts > bestPts then best, bestPts = i, pts end
    end
  end
  return best
end

-- Index "quest -> reward items" (QuestieDB), built once per session.
function Geo.ItemIdList()
  local okIds, ids = false, nil
  if QDB.Item and QDB.Item.GetAllIds then okIds, ids = pcall(QDB.Item.GetAllIds) end
  if not okIds or type(ids) ~= "table" then return {} end
  if #ids == 0 and next(ids) then
    local list = {}
    for k in pairs(ids) do list[#list + 1] = k end
    ids = list
  end
  return ids
end

function Geo.IndexItemRewards(idx, id)
  local qs = QGet(QDB.Item, id, "questRewards")
  if type(qs) == "table" then
    for _, q in ipairs(qs) do
      idx[q] = idx[q] or {}
      table.insert(idx[q], id)
    end
  end
end

-- Built in one go (spread over frames inside the Roadbook computation).
function Geo.RewardIndex()
  if Geo.rewards then return Geo.rewards end
  local idx = {}
  for n, id in ipairs(Geo.ItemIdList()) do
    Geo.IndexItemRewards(idx, id)
    if n % 500 == 0 then Geo.Yield() end
  end
  Geo.rewards = idx
  return idx
end

-- Built in the background (500 items per frame) for the "Available" tab, then the list is refreshed.
function Geo.BuildRewardIndexAsync()
  if Geo.rewards or Geo.rewardsBuilding or not QDB.ok then return end
  local ids, idx, i = Geo.ItemIdList(), {}, 1
  Geo.rewardsBuilding = true
  local function step()
    if Geo.rewards then -- built meanwhile by the Roadbook computation
      Geo.rewardsBuilding = nil
      return
    end
    local stop = math.min(i + 499, #ids)
    for k = i, stop do Geo.IndexItemRewards(idx, ids[k]) end
    i = stop + 1
    if i <= #ids then
      C_Timer.After(0, step)
    else
      Geo.rewards, Geo.rewardsBuilding = idx, nil
      if Refresh then Refresh() end
    end
  end
  step()
end

-- Recipe item (class 9) subclass -> profession skill line (Classic). Subclass 0 = book.
K.RECIPE_SKILL = { [1] = 165, [2] = 197, [3] = 202, [4] = 164, [5] = 185, [6] = 171, [7] = 129, [8] = 333, [9] = 356 }

-- QuestieDB "teachesSpell" field: a spell ID, or the default 0 (truthy in Lua!) when the item teaches nothing.
function Geo.ItemTeachesSpell(itemId)
  local v = QGet(QDB.Item, itemId, "teachesSpell")
  return type(v) == "number" and v > 0
end

-- Reward that teaches a skill: a book, or a recipe of one of the character's professions.
-- (QuestieDB's "teachesSpell" field is empty in the Forever database: the item class is used too.)
function Geo.TeachesSkill(classID, subclassID)
  if classID ~= 9 then return false end
  if subclassID == 0 then return true end
  local line = K.RECIPE_SKILL[subclassID]
  local skills = PlayerSkills()
  return line and skills[line] ~= nil or false
end

-- Interest of a reward item: share of an average quest's XP + reason, or 0.
function Geo.ItemInterest(itemId, plevel)
  local name, link, quality, ilvl, _, _, _, _, equipLoc, _, _, classID, subclassID = GetItemInfoCompat(itemId)
  if not name then
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemId) end
    return 0
  end
  if Geo.ItemTeachesSpell(itemId) or Geo.TeachesSkill(classID, subclassID) then
    return K.PRIO_SPELL, name .. L[" (teaches a skill)"]
  end
  if equipLoc == "INVTYPE_BAG" then return K.PRIO_BAG, name .. L[" (bag)"] end
  local slots = SLOTS[equipLoc]
  if not slots then return 0 end
  local _, cls = UnitClass("player")
  if classID == 4 and subclassID and subclassID > 0 then
    local ok = K.ARMOR[cls] and K.ARMOR[cls][subclassID]
    if not ok or (type(ok) == "number" and plevel < ok) then return 0 end
  elseif classID == 2 then
    if not (K.WEAPONS[cls] and K.WEAPONS[cls][subclassID]) then return 0 end
  end
  local specOK = true
  local spec = Geo.SpecIndex()
  local wanted = spec and K.SPEC_STATS[cls] and K.SPEC_STATS[cls][spec]
  if wanted and link and GetItemStats then
    local ok, stats = pcall(GetItemStats, link)
    if ok and type(stats) == "table" then
      specOK = false
      for _, st in ipairs(wanted) do
        if stats["ITEM_MOD_" .. st .. "_SHORT"] then specOK = true break end
      end
    end
  end
  local worst = math.huge
  for _, sl in ipairs(slots) do worst = math.min(worst, EquippedItemLevel(sl)) end
  local upgrade = (ilvl or 0) > worst
  if (quality or 0) >= 3 then
    if specOK then return K.PRIO_ITEM_SPEC, name .. L[" (blue)"] end
    return K.PRIO_ITEM_BLUE, name .. L[" (blue, off-spec)"]
  end
  if upgrade and specOK then return K.PRIO_UPGRADE_SPEC, name .. L[" (upgrade)"] end
  if upgrade then return K.PRIO_UPGRADE, name .. L[" (upgrade)"] end
  return 0
end

-- Task priority (equivalent XP) and reasons shown in the Roadbook.
K.MAX_LEVEL_UNIT = 10000 -- at max level (no more XP), reference value for priorities
K.ENDGAME_MARGIN = 5      -- a dungeon less than 5 levels below the maximum is an endgame goal

function Geo.MaxLevel()
  return (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
end

-- Item important for the endgame but useless while leveling: key, mount,
-- epic item that cannot be used (yet).
function Geo.LaterItem(itemId, plevel)
  local name, _, quality, _, _, _, _, _, _, _, _, classID, subclassID = GetItemInfoCompat(itemId)
  if not name then return nil end
  if Geo.ItemInterest(itemId, plevel) > 0 then return nil end
  if classID == 13 then return name .. L[" (key)"] end
  if classID == 15 and subclassID == 5 then return name .. L[" (mount)"] end
  if (quality or 0) >= 4 then return name .. L[" (epic)"] end
  return nil
end

-- Reason to keep a quest (and its chain) for max level, or nil.
function Geo.LaterReason(id, plevel)
  Geo.laterCache = Geo.laterCache or {}
  local c = Geo.laterCache[id]
  if c ~= nil then return c or nil end
  local maxL = Geo.MaxLevel()
  local root = QuestMeta(id)
  local rootLevel = (root and root.level and root.level > 0) and root.level or plevel
  local reason
  local queue, seen, i = { id }, { [id] = true }, 1
  while i <= #queue and i <= 25 and not reason do
    local qid = queue[i]
    i = i + 1
    local m = QuestMeta(qid)
    if m and (qid == id or not IsCompleted(qid)) then
      local lvl = (m.level and m.level > 0) and m.level or rootLevel
      -- Chain rewards, within the same level range as the starting quest.
      if qid == id or lvl <= rootLevel + 5 then
        for _, item in ipairs(Geo.RewardIndex()[qid] or {}) do
          local r = Geo.LaterItem(item, plevel)
          if r then reason = r break end
        end
      end
      -- Chain leading to an endgame dungeon (access, attunement).
      local dg = m.sort and m.sort > 0 and QDB.dungeonOf and QDB.dungeonOf[m.sort]
      if not reason and dg and lvl >= maxL - K.ENDGAME_MARGIN and rootLevel >= maxL - 10 then
        reason = L["access to "] .. (AreaName(dg) or L["an endgame dungeon"])
      end
      for _, nq in ipairs(NextQuests(m)) do
        if not seen[nq] then
          seen[nq] = true
          queue[#queue + 1] = nq
        end
      end
    end
  end
  Geo.laterCache[id] = reason or false
  return reason
end

-- Quest set aside for max level (shown separately in the Roadbook).
function Geo.RecordLater(task)
  Geo.laterList = Geo.laterList or {}
  for _, e in ipairs(Geo.laterList) do if e.id == task.id then return end end
  Geo.laterList[#Geo.laterList + 1] = { id = task.id, title = task.title, level = task.level, reason = task.later }
end

-- Dungeon / raid quest kept out of the Roadbook: anything but talking or delivering, even when its
-- targets are outside the instance (e.g. an elite in front of the entrance).
function Geo.DungeonCombat(id)
  for _, t in ipairs(Geo.QuestTypes(id)) do
    if t ~= "talk" and t ~= "delivery" then return true end
  end
  return false
end

-- Elite quest: tagged "Elite" by the game (quest log), otherwise most of the monsters of its
-- objectives (to kill, or dropping the requested items) are elites in QuestieDB.
Geo.elite = {}
function Geo.IsEliteQuest(id, tag)
  -- A quest has a single game tag ("Dungeon" wins over "Elite"): it only settles the "Elite" case.
  if tag and (tag == ELITE or tag:find("[EÉ]lite")) then return true end
  if not id then return false end
  local v = Geo.elite[id]
  if v ~= nil then return v end
  local mobs = {}
  local obj = QGet(QDB.Quest, id, "objectives")
  if type(obj) == "table" then
    for _, o in ipairs(obj[1] or {}) do
      local icon = o[3]
      if not (icon == 3 or icon == 5 or icon == 17) then mobs[#mobs + 1] = o[1] end
    end
    for _, o in ipairs(obj[3] or {}) do
      local drops = QGet(QDB.Item, o[1], "npcDrops")
      for _, n in ipairs(type(drops) == "table" and drops or {}) do mobs[#mobs + 1] = n end
    end
    for _, o in ipairs(obj[5] or {}) do
      if type(o) == "table" and type(o[1]) == "table" then
        for _, n in ipairs(o[1]) do mobs[#mobs + 1] = n end
      end
    end
  end
  local elites = 0
  for _, n in ipairs(mobs) do
    local rank = QGet(QDB.Npc, n, "rank")
    if rank == 1 or rank == 2 or rank == 3 then elites = elites + 1 end
  end
  v = elites > 0 and elites * 2 >= #mobs
  Geo.elite[id] = v
  return v
end

-- Highest quest level the Roadbook takes on, from your level (or the required level, if higher);
-- elite quests are excluded when the "Include elite quests" option is unchecked.
function Geo.MaxQuestLevel(id, plevel, reqLevel, tag)
  local elite = Geo.IsEliteQuest(id, tag)
  if elite and Settings().noElite then return -math.huge end -- "Include elite quests" unchecked
  return math.max(plevel, reqLevel or 0) + (elite and K.MAX_ELITE_GAP or K.MAX_LEVEL_GAP)
end

-- XP of an average quest among the Roadbook candidates (set by BuildTasks), the unit of priorities.
function Geo.AverageXP()
  return Geo.avgXP or K.MAX_LEVEL_UNIT
end

function Geo.Priority(task, plevel, isClass)
  if plevel < Geo.MaxLevel() then task.later = Geo.LaterReason(task.id, plevel) end
  local share, tags = 0, {}
  if isClass then
    share = share + K.PRIO_CLASS
    tags[#tags + 1] = L["class quest"]
  else
    local chain = ChainInfo(task.id, plevel, TrivialRange())
    if chain and chain.hasClass then
      share = share + K.PRIO_CLASS
      tags[#tags + 1] = L["unlocks a class quest"]
    end
  end
  local best, why = 0, nil
  for _, itemId in ipairs(Geo.RewardIndex()[task.id] or {}) do
    local v, r = Geo.ItemInterest(itemId, plevel)
    if v > best then best, why = v, r end
  end
  if best > 0 then
    share = share + best
    tags[#tags + 1] = L["reward: "] .. why
  end
  task.share = share
  task.prio = share * Geo.AverageXP()
  task.tags = #tags > 0 and tags or nil
end

local function BuildTasks(pos, plevel)
  local tasks, skipped = {}, 0
  Geo.avgXP = nil -- computed below from the candidates
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do
    local xp = q.xp or DBXP(q.id, plevel) or 0
    local group = q.suggestedGroup and q.suggestedGroup > 1
    local atMax = plevel >= Geo.MaxLevel()
    -- Quest ready to turn in: always a candidate (even dungeon, group, gray or high level),
    -- you only need to visit the NPC: it is a quick win.
    local ready = q.complete and not q.failed
    if Settings().excluded[q.id] then
      skipped = skipped + 1 -- removed from the Roadbook by the player
    elseif not ready and (q.isInstance or q.instanceName) and Geo.DungeonCombat(q.id) then
      skipped = skipped + 1 -- dungeon / raid quest (game tag): only turned in when it is ready
    elseif ready or (not q.failed and (xp > 0 or atMax) and not group and (q.level or 0) <= Geo.MaxQuestLevel(q.id, plevel, nil, q.tag or "") + 1) then
      local t = QuestTargets(q.id)
      local remaining, unmatched = {}, 0
      if not q.complete then remaining, unmatched = RemainingTargets(q, t) end
      local inInstance = unmatched > 0 -- objective not found: quest ignored (counted as not located)
      for _, r in ipairs(remaining) do if AllInstance(r.tg.points) then inInstance = true end end
      if #t.finish > 0 and AllInstance(t.finish) then inInstance = true end -- turn-in inside the instance
      if #t.finish > 0 and not inInstance then
        local task = { id = q.id, title = q.title, level = q.level, kind = q.complete and "turnin" or "do",
          xp = xp, targets = t, remaining = remaining }
        task.stops = MakeStops(task, pos, plevel)
        local m = QuestMeta(q.id)
        Geo.Priority(task, plevel, (q.zone == UnitClass("player")) or (m and IsClassMeta(m)) or false)
        if ready then
          task.later = nil -- the objective is done: turn the quest in now
          task.share = (task.share or 0) + K.READY_BONUS
          task.quick = true
        end
        if task.later then
          Geo.RecordLater(task)
        elseif not atMax or (task.share or 0) > 0 then
          tasks[#tasks + 1] = task
        end
      else
        skipped = skipped + 1
      end
    else
      skipped = skipped + 1
    end
  end

  -- Quests to pick up (including slightly too high ones for now): nearest first.
  local near = {}
  for _, en in ipairs(scan.entries or {}) do
    if not en.lowLevel and not en.repMissing and not en.missing and not en.repeatable
      and ((en.xp or 0) > 0 or plevel >= Geo.MaxLevel())
      and (en.level or 0) <= Geo.MaxQuestLevel(en.id, plevel, en.reqLevel) then
      local p, d = Nearest(StartPoints(en.id), pos)
      if p then near[#near + 1] = { en = en, d = d or math.huge } end
    end
  end
  table.sort(near, function(a, b) return a.d < b.d end)
  for i = 1, math.min(#near, K.MAX_TAKE_CANDIDATES) do
    local task = Geo.TakeTask(near[i].en, plevel, pos)
    if task then tasks[#tasks + 1] = task end
    if i % 10 == 0 then Geo.Yield() end
  end
  -- Unit of the priorities: XP of an average candidate quest (quest + monsters).
  local sum, n = 0, 0
  for _, task in ipairs(tasks) do
    if (task.value or 0) > 0 then sum, n = sum + task.value, n + 1 end
  end
  Geo.avgXP = (n > 0 and plevel < Geo.MaxLevel()) and sum / n or K.MAX_LEVEL_UNIT
  for _, task in ipairs(tasks) do task.prio = (task.share or 0) * Geo.avgXP end
  return tasks, skipped
end

-- Cached travel time between two points (points are shared objects).
local function MakeTravel(net, plevel)
  local cache = {}
  return function(a, b)
    if a == b then return 0 end
    if b.teleport then return K.HEARTH_TIME end -- hearthstone: usable from anywhere
    local row = cache[a]
    if not row then
      row = {}
      cache[a] = row
    end
    local v = row[b]
    if v == nil then
      v = Route(a, b, net, plevel)
      row[b] = v
    end
    return v
  end
end

-- Inserts a quest's steps into the route at the lowest extra cost, keeping their order.
-- Returns the extra cost (travel + work) and the new route.
local function InsertStops(route, stops, travel, startIdx)
  local r = {}
  for i, s in ipairs(route) do r[i] = s end
  local delta, minIdx = 0, startIdx or 1
  for k, s in ipairs(stops) do
    local bestI, bestD
    local lo, hi = minIdx, #r
    if s.glue and k > 1 then hi = minIdx end -- right after the previous step of the quest
    for i = lo, hi do -- insertion after r[i]
      local a, b = r[i], r[i + 1]
      if not (b and b.glue) then
        local d = travel(a.p, s.p)
        if b then d = d + travel(s.p, b.p) - travel(a.p, b.p) end
        if not bestD or d < bestD then bestI, bestD = i, d end
      end
    end
    if not bestI then return math.huge, route end
    table.insert(r, bestI + 1, s)
    delta = delta + bestD + s.work
    minIdx = bestI + 1
  end
  return delta, r
end

K.MAX_PLAN_QUESTS = 50
K.FM_DETOUR = 250      -- maximum detour (m, as the crow flies) to activate an unknown flight master
K.FM_KNOWN_RADIUS = 150 -- a flight master closer than this to a recorded flight path is known

-- Service NPCs of the player's faction (QuestieDB), read once per session:
-- flight masters (Geo.fm) and innkeepers (Geo.inn).
function Geo.ScanServices()
  if Geo.fm then return end
  Geo.fm, Geo.inn = {}, {}
  if not (QDB.Npc and QDB.Npc.GetAllIds) then return end
  local okIds, ids = pcall(QDB.Npc.GetAllIds)
  if not okIds or type(ids) ~= "table" then return end
  if #ids == 0 and next(ids) then
    local list = {}
    for k in pairs(ids) do list[#list + 1] = k end
    ids = list
  end
  local fac = UnitFactionGroup and UnitFactionGroup("player")
  local letter = (fac == "Horde" and "H") or (fac == "Alliance" and "A") or nil
  if not letter then return end
  for _, id in ipairs(ids) do
    local flags = QGet(QDB.Npc, id, "npcFlags")
    local isFM = type(flags) == "number" and HasBit(flags, 8)
    local isInn = type(flags) == "number" and HasBit(flags, 128)
    if not (isFM or isInn) then
      local sub = QGet(QDB.Npc, id, "subName")
      if type(sub) == "string" then
        isFM = (sub:find("Flight Master") or sub:find("Gryphon Master") or sub:find("Wind Rider Master")
          or sub:find("Hippogryph Master") or sub:find("Bat Handler") or sub:find("[Mm]aître de vol")) and true or false
        isInn = (sub:find("Innkeeper") or sub:find("[Aa]ubergiste")) and true or false
      end
    end
    if isFM or isInn then
      local friendly = QGet(QDB.Npc, id, "friendlyToFaction")
      if type(friendly) == "string" and friendly:find(letter) then
        local p = EntityPoints("npc", id)[1]
        if p and not p.instance then
          local name = QGet(QDB.Npc, id, "name")
          if isFM then Geo.fm[#Geo.fm + 1] = { id = id, name = name or L["Flight Master"], p = p } end
          if isInn then Geo.inn[#Geo.inn + 1] = { id = id, name = name or L["Innkeeper"], p = p } end
        end
      end
    end
  end
end

function Geo.FlightMasters()
  Geo.ScanServices()
  return Geo.fm or {}
end

function Geo.Innkeepers()
  Geo.ScanServices()
  return Geo.inn or {}
end

-- Flight masters not yet activated by the character (no recorded flight path nearby).
function Geo.UnknownFlightMasters()
  local known, out = {}, {}
  for _, n in pairs(TaxiStore()) do known[#known + 1] = { c = n.c, x = n.x, y = n.y } end
  for _, fm in ipairs(Geo.FlightMasters()) do
    local isKnown = false
    for _, k in ipairs(known) do
      local d = Dist(k, fm.p)
      if d and d < K.FM_KNOWN_RADIUS then isKnown = true break end
    end
    if not isKnown then out[#out + 1] = fm end
  end
  return out
end

-- Adds an "activate the flight master" step when the route passes near an unknown
-- flight master (only on parts done on foot or mounted).
function Geo.AddFlightMasterStops(route, net, plevel)
  local unknown = Geo.UnknownFlightMasters()
  if #unknown == 0 or #route < 2 then return route end
  local legs = {}
  for k = 2, #route do
    local a, b = route[k - 1].p, route[k].p
    local _, choice = Route(a, b, net, plevel)
    local segs = {}
    if route[k].kind == "hearth" or route[k].glue then
      -- teleport: nothing is passed on the way; escort: no detour
    elseif choice then
      segs[1] = { a, net.hubs[choice.i].p }
      segs[2] = { net.hubs[choice.j].p, b }
    elseif a.c == b.c then
      segs[1] = { a, b }
    end
    legs[k] = segs
  end
  local inserts = {}
  for _, fm in ipairs(unknown) do
    local bestK, bestD, bestFrom
    for k = 2, #route do
      for _, s in ipairs(legs[k]) do
        local d1, d2, d0 = Dist(s[1], fm.p), Dist(fm.p, s[2]), Dist(s[1], s[2])
        if d1 and d2 and d0 then
          local detour = d1 + d2 - d0
          if not bestD or detour < bestD then bestK, bestD, bestFrom = k, detour, d1 end
        end
      end
    end
    if bestK and bestD <= K.FM_DETOUR then
      inserts[bestK] = inserts[bestK] or {}
      table.insert(inserts[bestK], { fm = fm, from = bestFrom })
    end
  end
  if not next(inserts) then return route end
  local out = { route[1] }
  for k = 2, #route do
    local list = inserts[k]
    if list then
      table.sort(list, function(x, y) return x.from < y.from end)
      for _, it in ipairs(list) do
        out[#out + 1] = { kind = "fm", p = it.fm.p, work = K.OVERHEAD / 2,
          task = { title = L["Activate the flight path of "] .. (AreaName(it.fm.p.area) or "?"), npc = it.fm.name, xp = 0, fm = true } }
      end
    end
    out[#out + 1] = route[k]
  end
  return out
end

---------------------------------------------------------------------------
-- Transports: "take the flight / zeppelin / boat" step at the boarding point
---------------------------------------------------------------------------
-- World point (c, x, y) -> displayable/pinnable point (zone map + 0-100 coordinates).
function Geo.MapPoint(w)
  if w.ui or w.area then return w end
  if not (C_Map.GetMapPosFromWorldPos and CreateVector2D) then return w end
  local vec = CreateVector2D(w.x, w.y)
  local ok, ui, mp = pcall(C_Map.GetMapPosFromWorldPos, w.c, vec)
  if not (ok and ui and mp) then return w end
  local mx, my = mp:GetXY()
  local zoneName
  if C_Map.GetMapInfoAtPosition then
    local okI, info = pcall(C_Map.GetMapInfoAtPosition, ui, mx, my)
    if okI and info and info.mapID and info.mapID ~= ui then
      local ok2, ui2, mp2 = pcall(C_Map.GetMapPosFromWorldPos, w.c, vec, info.mapID)
      if ok2 and ui2 and mp2 then ui, mx, my = ui2, mp2:GetXY() end
    end
    if okI and info then zoneName = info.name end
  end
  if not zoneName and C_Map.GetMapInfo then
    local okM, mi = pcall(C_Map.GetMapInfo, ui)
    zoneName = okM and mi and mi.name or nil
  end
  return { c = w.c, x = w.x, y = w.y, ui = ui, mx = mx * 100, my = my * 100, zoneName = zoneName }
end

-- Boardings of a route: { hub, mode ("vol", "zeppelin", "bateau"), dest }.
function Geo.Boardings(choice, net)
  local out = {}
  local hubs, cur = net.hubs, choice.i
  local run
  while cur ~= choice.j do
    local nx = net.nxt[cur][choice.j]
    local mode = net.via[cur][nx]
    if mode == "flight" then
      if not run then
        run = { hub = hubs[cur], mode = "vol" }
        out[#out + 1] = run
      end
      run.dest = hubs[nx]
    else
      run = nil
      if mode == "zeppelin" or mode == "bateau" then
        out[#out + 1] = { hub = hubs[cur], mode = mode, dest = hubs[nx] }
      end
    end
    cur = nx
  end
  return out
end

-- Adds a step at the boarding point of each transport used by the route.
function Geo.AddTransportStops(route, net, plevel)
  if #net.hubs == 0 then return route end
  local out = { route[1] }
  for k = 2, #route do
    local cur = route[k]
    if cur.kind ~= "hearth" and not cur.glue then -- escort: on foot, with the NPC
      local _, choice = Route(out[#out].p, cur.p, net, plevel)
      if choice then
        for _, b in ipairs(Geo.Boardings(choice, net)) do
          local what = (b.mode == "vol" and L["Take the flight"]) or (L["Take the "] .. (K.MODE_NAME[b.mode] or b.mode))
          out[#out + 1] = { kind = "travel", p = Geo.MapPoint(b.hub.p), work = 0,
            task = { title = what .. L[": "] .. (b.hub.name or "?") .. " -> " .. (b.dest and b.dest.name or "?"),
              mode = b.mode, from = b.hub.name, dest = b.dest and b.dest.name, destP = b.dest and b.dest.p,
              xp = 0, travel = true } }
        end
      end
    end
    out[#out + 1] = cur
  end
  return out
end

---------------------------------------------------------------------------
-- Hearthstone: bind at an innkeeper and hearth back, to save travel time
---------------------------------------------------------------------------
K.HEARTHSTONE = 6948
K.HEARTH_SPELL = 8690
K.HEARTH_TIME = 30      -- cast (10 s) + teleport
K.HEARTH_CD = 3600      -- hearthstone cooldown
K.HEARTH_MIN_GAIN = 120 -- minimum gain (s) to suggest hearthing
K.BIND_WORK = 20        -- talking to the innkeeper
K.INN_DETOUR = 500      -- maximum detour (m, as the crow flies) to go and bind

function Geo.BindStore()
  local st = Settings()
  st.bind = st.bind or {}
  return st.bind
end

-- Remembers the bind location (inn position) for this character.
function Geo.RecordBind(p)
  if not p then return end
  local mp = Geo.MapPoint({ c = p.c, x = p.x, y = p.y })
  Geo.BindStore()[CharKey()] = { c = p.c, x = p.x, y = p.y, area = p.area, mx = p.mx or mp.mx, my = p.my or mp.my,
    ui = (not p.area) and mp.ui or nil, zoneName = mp.zoneName, name = GetBindLocation and GetBindLocation() or nil }
end

-- Zones (zone ids) with this name, or containing the subzone with this name.
function Geo.ZonesNamed(name)
  local zones = {}
  for id in pairs(Geo.areaToUi or {}) do
    if AreaName(id) == name then zones[Geo.parent[id] or id] = true end
  end
  for id, parent in pairs(Geo.parent or {}) do
    if AreaName(id) == name then zones[parent] = true end
  end
  return zones
end

-- Estimated bind location from its name, from the most to the least precise:
-- the innkeeper of that zone, the center of the zone's innkeepers, the center of the zone.
function Geo.GuessBind(name)
  if Geo.bindGuess and Geo.bindGuess.name == name then return Geo.bindGuess.p end
  local zones = Geo.ZonesNamed(name)
  local list = {}
  for _, inn in ipairs(Geo.Innkeepers()) do
    local a = inn.p.area
    if AreaName(a) == name or zones[a] or (Geo.parent[a] and zones[Geo.parent[a]]) then list[#list + 1] = inn.p end
  end
  local p
  if #list == 1 then
    p = list[1]
  elseif #list > 1 then
    local c, x, y, n = list[1].c, 0, 0, 0
    for _, q in ipairs(list) do
      if q.c == c then x, y, n = x + q.x, y + q.y, n + 1 end
    end
    p = Geo.MapPoint({ c = c, x = x / n, y = y / n })
    p.approx = true
  else
    for zid in pairs(zones) do
      local w = WorldPos(zid, 50, 50)
      if w then
        p = w
        p.approx = true
        break
      end
    end
  end
  Geo.bindGuess = { name = name, p = p }
  return p
end

-- Current bind location: remembered position, otherwise estimated from the location name.
function Geo.CurrentBind()
  local name = GetBindLocation and GetBindLocation() or nil
  local st = Geo.BindStore()[CharKey()]
  if st and (not name or st.name == name) then return st, name end
  if name then return Geo.GuessBind(name), name end
  return nil, name
end

-- Seconds until the hearthstone is ready (0 = ready), nil if there is no hearthstone.
function Geo.HearthReady()
  local count = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(K.HEARTHSTONE))
    or (GetItemCount and GetItemCount(K.HEARTHSTONE)) or 0
  if count == 0 then return nil end
  local cd = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
  if cd and GetTime then
    local start, dur = cd(K.HEARTHSTONE)
    if start and dur and start > 0 and dur > 0 then return math.max(0, start + dur - GetTime()) end
  end
  return 0
end

function Geo.RouteTime(route, travel)
  local t = 0
  for i = 2, #route do t = t + travel(route[i - 1].p, route[i].p) + route[i].work end
  return t
end

function Geo.HearthStep(bindP, gain)
  local dest = AreaName(bindP.area) or bindP.zoneName or bindP.name or "?"
  return { kind = "hearth", work = 0, gain = gain,
    p = { c = bindP.c, x = bindP.x, y = bindP.y, area = bindP.area, ui = bindP.ui, mx = bindP.mx, my = bindP.my,
      zoneName = bindP.zoneName, teleport = true },
    task = { title = L["Hearthstone: back to "] .. dest, xp = 0, hearth = true } }
end

-- Places hearths where they save the most, respecting the cooldown.
-- The bind location changes after a "bind" step.
function Geo.ApplyHearth(route, travel, bind0, ready0)
  local cands, clock, bindP = {}, 0, bind0
  for i = 2, #route do
    local prev, cur = route[i - 1], route[i]
    local normal = travel(prev.p, cur.p)
    if bindP and cur.kind ~= "hearth" and not cur.glue then
      local gain = normal - (K.HEARTH_TIME + travel(bindP, cur.p))
      if gain >= K.HEARTH_MIN_GAIN then cands[#cands + 1] = { i = i, t = clock, gain = gain, bindP = bindP } end
    end
    clock = clock + normal + cur.work
    if cur.kind == "bind" then bindP = cur.bindP end
  end
  table.sort(cands, function(a, b) return a.gain > b.gain end)
  local chosen, byIndex, total = {}, {}, 0
  for _, c in ipairs(cands) do
    local ok = c.t >= ready0
    for _, o in ipairs(chosen) do
      if math.abs(c.t - o.t) < K.HEARTH_CD then ok = false break end
    end
    if ok then
      chosen[#chosen + 1] = c
      byIndex[c.i] = c
      total = total + c.gain
    end
  end
  if #chosen == 0 then return route, 0 end
  local out = { route[1] }
  for i = 2, #route do
    local c = byIndex[i]
    if c then out[#out + 1] = Geo.HearthStep(c.bindP, c.gain) end
    out[#out + 1] = route[i]
  end
  return out, total
end

-- Removes hearths that became impossible (stone not ready yet) and recomputes their gain.
function Geo.FixHearth(route, travel, ready0)
  local out, clock, ready = { route[1] }, 0, ready0
  for i = 2, #route do
    local s = route[i]
    local keep = true
    if s.kind == "hearth" then
      if clock < ready then keep = false else ready = clock + K.HEARTH_CD end
    end
    if keep then
      clock = clock + travel(out[#out].p, s.p) + s.work
      out[#out + 1] = s
    end
  end
  -- A bind with no hearth after it is useless.
  local final, needed = {}, false
  for i = #out, 1, -1 do
    local s = out[i]
    if s.kind == "hearth" then needed = true end
    if s.kind == "bind" then
      if needed then table.insert(final, 1, s) end
      needed = false
    else
      table.insert(final, 1, s)
    end
  end
  return final
end

-- Best strategy: hearths to the current bind location, or binding at an inn
-- met on the way and then hearthing back to it.
function Geo.OptimizeHearth(route, travel)
  if Settings().noHearth or #route < 3 then return route end
  local ready0 = Geo.HearthReady()
  if not ready0 then return route end
  local bind0 = Geo.CurrentBind()
  local best, bestT = route, Geo.RouteTime(route, travel)
  if bind0 then
    local r, gain = Geo.ApplyHearth(route, travel, bind0, ready0)
    if gain > 0 then
      local t = Geo.RouteTime(r, travel)
      if t < bestT then best, bestT = r, t end
    end
  end
  for _, inn in ipairs(Geo.Innkeepers()) do
    local same = bind0 and Dist(bind0, inn.p)
    if not (same and same < 60) then
      local bestK, bestD
      for k = 2, #route do
        if route[k].kind ~= "hearth" and not route[k].glue then
          local a, b = route[k - 1].p, route[k].p
          local d1, d2, d0 = Dist(a, inn.p), Dist(inn.p, b), Dist(a, b)
          if d1 and d2 and d0 and (not bestD or d1 + d2 - d0 < bestD) then bestK, bestD = k, d1 + d2 - d0 end
        end
      end
      if bestK and bestD <= K.INN_DETOUR then
        local r = {}
        for k = 1, #route do
          if k == bestK then
            r[#r + 1] = { kind = "bind", p = inn.p, bindP = inn.p, work = K.BIND_WORK,
              task = { title = L["Bind your hearthstone: "] .. (AreaName(inn.p.area) or "?"), npc = inn.name, xp = 0, bind = true } }
          end
          r[#r + 1] = route[k]
        end
        local r2, gain = Geo.ApplyHearth(r, travel, bind0, ready0)
        if gain > 0 then
          local t = Geo.RouteTime(r2, travel)
          if t < bestT - K.HEARTH_MIN_GAIN then best, bestT = r2, t end
        end
      end
    end
  end
  return best
end

-- Task insertion constraints: after the turn-in of the quest it follows, and after the
-- moment the expected level reaches its required level. Returns the index to insert after, or nil.
function Geo.StartIndex(task, lv, idx)
  local si = 1
  if task.dep then
    local i = idx[task.dep.stops[#task.dep.stops]]
    if not i then return nil end
    si = i
  end
  if task.reqLevel then
    local found
    for i = si, #lv do
      if lv[i] >= task.reqLevel then found = i break end
    end
    if not found then return nil end
    si = found
  end
  return si
end

function Geo.Index(route)
  local idx = {}
  for i, st in ipairs(route) do idx[st] = i end
  return idx
end

-- Checks that no quest is picked up before reaching its required level.
function Geo.LevelsOK(route)
  local lv = Geo.Levels(route)
  for i = 2, #route do
    local st = route[i]
    if st.kind == "take" and st.task.reqLevel and lv[i - 1] < st.task.reqLevel then return false end
  end
  return true
end

-- Local improvement: moves each step to the best allowed place (order of a quest's
-- steps, follow-ups after their parent quest, required level) as long as the route gets shorter.
function Geo.Improve(route, travel)
  for _ = 1, 3 do
    local improved = false
    local i = 2
    while i <= #route do
      local st = route[i]
      local task = st.task
      -- An escort and its pick-up are not moved (they must stay side by side).
      if task and st.kind ~= "start" and not st.glue and not (route[i + 1] and route[i + 1].glue) then
        local prev, nxt = route[i - 1], route[i + 1]
        local gain = travel(prev.p, st.p) + (nxt and (travel(st.p, nxt.p) - travel(prev.p, nxt.p)) or 0)
        table.remove(route, i)
        -- Allowed window (insertion after index j, lo <= j <= hi).
        local lo, hi = 1, #route
        local last = task.stops[#task.stops]
        local depLast = task.dep and task.dep.stops[#task.dep.stops]
        local seenSelfAfter = false
        for j = 1, #route do
          local o = route[j]
          if o.task == task then
            if j < i then lo = math.max(lo, j) elseif not seenSelfAfter then hi = math.min(hi, j - 1) seenSelfAfter = true end
          end
          if depLast and o == depLast then lo = math.max(lo, j) end
          if st == last and o.task and o.task.dep == task and o.kind == "take" then hi = math.min(hi, j - 1) end
        end
        local bestJ, bestC
        for j = lo, hi do
          if j ~= i - 1 and not (route[j + 1] and route[j + 1].glue) then
            local a, b = route[j], route[j + 1]
            local c = travel(a.p, st.p) + (b and (travel(st.p, b.p) - travel(a.p, b.p)) or 0)
            if not bestC or c < bestC then bestJ, bestC = j, c end
          end
        end
        if bestC and bestC < gain - 1 then
          table.insert(route, bestJ + 1, st)
          if Geo.LevelsOK(route) then
            improved = true
          else
            table.remove(route, bestJ + 1)
            table.insert(route, i, st)
          end
        else
          table.insert(route, i, st)
        end
      end
      i = i + 1
      Geo.Yield()
    end
    if not improved then break end
  end
  return route
end

-- Reward items of the quests (log and available) asked to the game before planning, up to
-- K.ITEM_WAIT seconds: otherwise an item not cached yet counts as "no interest" and the next
-- computation, with the data, gives another Roadbook.
K.ITEM_WAIT = 3
function Geo.PreloadRewardItems()
  local idx, missing = Geo.RewardIndex(), {}
  local function want(qid)
    for _, itemId in ipairs(idx[qid] or {}) do
      if not GetItemInfoCompat(itemId) then -- asks the server when not cached
        missing[#missing + 1] = itemId
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemId) end
      end
    end
  end
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do want(q.id) end
  for _, en in ipairs(scan.entries or {}) do want(en.id) end
  local start = GetTime and GetTime() or 0
  while #missing > 0 and Geo.co and coroutine.running() == Geo.co and (GetTime() - start) < K.ITEM_WAIT do
    coroutine.yield() -- next frame
    local still = {}
    for _, itemId in ipairs(missing) do
      if not GetItemInfoCompat(itemId) then still[#still + 1] = itemId end
    end
    missing = still
  end
end

local function PlanXP(horizon)
  Geo.PreloadRewardItems()
  local pos = PlayerPos()
  if not pos then return nil, L["Unknown position (in an instance or map unavailable)."] end
  Geo.xpScale = nil
  Geo.laterList, Geo.laterCache = {}, {}
  local speed = TravelSpeed()
  Geo.planSpeed = speed
  local plevel = UnitLevel("player")
  local net = BuildNetwork(speed)
  local travel = MakeTravel(net, plevel)
  local tasks, skipped = BuildTasks(pos, plevel)
  local ctx = BuildScanContext()

  local route = { { kind = "start", p = pos, work = 0 } }
  local total, count = 0, 0
  local usedIds = {}

  -- What inserting a task unlocks: its follow-ups, and the quests whose required level is
  -- reached thanks to its XP.
  -- What inserting a task unlocks, evaluated as a whole:
  -- * the quest's whole chain (every step doable within the session, with its XP,
  --   its rewards, its required level), keeping the best value / time ratio;
  -- * the quests whose required level is reached thanks to its XP.
  local function lookahead(task, nr, d, lvEnd, locked)
    local best
    local function consider(v, dd)
      local sc = v / math.max(dd, 30)
      if not best or sc > best then best = sc end
    end
    local base = task.value + (task.prio or 0)
    if #locked > 0 then
      local nlv = Geo.Levels(nr)
      if nlv[#nlv] > lvEnd then
        local nidx = Geo.Index(nr)
        for _, u in ipairs(locked) do
          if u.reqLevel <= nlv[#nlv] and not usedIds[u.id] and not u.dep then
            local si = Geo.StartIndex(u, nlv, nidx)
            if si then
              local du = InsertStops(nr, u.stops, travel, si)
              if total + d + du <= horizon * 1.1 then consider(base + u.value + (u.prio or 0), d + du) end
            end
          end
        end
      end
    end
    -- Whole chain: chain, step by step, the best available follow-up.
    local cur, r, v, dd = task, nr, base, d
    local seen = { [task.id or 0] = true }
    for _ = 1, K.MAX_FOLLOW_DEPTH do
      local followers = Geo.Followers(cur, ctx, plevel)
      if #followers == 0 then break end
      local lvR, idxR = Geo.Levels(r), Geo.Index(r)
      local pick
      for _, u in ipairs(followers) do
        if u.stops and not usedIds[u.id] and not seen[u.id] then
          local si = Geo.StartIndex(u, lvR, idxR)
          if si then
            local du, ur = InsertStops(r, u.stops, travel, si)
            if total + dd + du <= horizon * 1.1 then
              local val = u.value + (u.prio or 0)
              local rate = val / math.max(du, 30)
              if not pick or rate > pick.rate then pick = { u = u, du = du, r = ur, val = val, rate = rate } end
            end
          end
        end
      end
      if not pick then break end
      seen[pick.u.id] = true
      v, dd, r, cur = v + pick.val, dd + pick.du, pick.r, pick.u
      consider(v, dd)
    end
    return best
  end

  local function fill()
    while count < K.MAX_PLAN_QUESTS and total < horizon do
      local lv, idx = Geo.Levels(route), Geo.Index(route)
      local lvEnd = lv[#lv]
      local locked = {}
      for _, task in ipairs(tasks) do
        if task.stops and not task.used and task.reqLevel and task.reqLevel > lvEnd and not usedIds[task.id] then
          locked[#locked + 1] = task
        end
      end
      local best
      for _, task in ipairs(tasks) do
        if task.stops and not task.used and not usedIds[task.id] and (not task.dep or task.dep.used) then
          local si = Geo.StartIndex(task, lv, idx)
          if si then
            local d, nr = InsertStops(route, task.stops, travel, si)
            if total + d <= horizon * 1.1 then
              local score = (task.value + (task.prio or 0)) / math.max(d, 30)
              local pair = lookahead(task, nr, d, lvEnd, locked)
              if pair and pair * K.LOOKAHEAD_WEIGHT > score then score = pair * K.LOOKAHEAD_WEIGHT end
              if not best or score > best.score then best = { task = task, score = score, d = d, route = nr } end
            end
          end
          Geo.Yield()
        end
      end
      if not best then break end
      best.task.used = true
      if best.task.id then usedIds[best.task.id] = true end
      route, total, count = best.route, total + best.d, count + 1
      -- The chosen quest's follow-ups become candidates.
      for _, f in ipairs(Geo.Followers(best.task, ctx, plevel)) do tasks[#tasks + 1] = f end
    end
  end

  fill()
  -- Shorten the route, then use the saved time for other quests.
  route = Geo.Improve(route, travel)
  total = Geo.RouteTime(route, travel)
  fill()

  -- Hearthstone: bind + hearths, then the saved time is used to add quests.
  local okH, withH = pcall(Geo.OptimizeHearth, route, travel)
  if not okH then Print(L["Hearthstone error: "] .. tostring(withH)) end
  if okH and withH and withH ~= route then
    route = withH
    total = Geo.RouteTime(route, travel)
    fill()
    route = Geo.FixHearth(route, travel, Geo.HearthReady() or 0)
  end

  -- Unknown flight masters met on the way: activation step.
  local okFM, withFM = pcall(Geo.AddFlightMasterStops, route, net, plevel)
  if okFM and withFM then route = withFM end

  -- Flights, zeppelins, boats: step at the boarding point.
  local okT, withT = pcall(Geo.AddTransportStops, route, net, plevel)
  if not okT then Print(L["Transport steps error: "] .. tostring(withT)) end
  if okT and withT then route = withT end

  -- Exact recomputation of time and XP along the final route.
  local t, questXP, mobXP = 0, 0, 0
  for i = 2, #route do
    local st = route[i]
    t = t + travel(route[i - 1].p, st.p) + st.work
    st.at = t
    if st.kind == "turnin" then questXP = questXP + (st.xp or 0) end
    if st.kind == "obj" then mobXP = mobXP + (st.xp or 0) end
  end
  return route, nil, { speed = speed, skipped = skipped, total = t, xp = questXP + mobXP, mobXP = mobXP,
    count = count, net = net, plevel = plevel, levels = Geo.Levels(route), later = Geo.laterList }
end

-- Roadbook computation in the background (spread over several frames) with caching.
function Geo.PlanKey(horizon)
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  local b = Geo.BindStore()[CharKey()]
  return table.concat({ horizon, tostring(Settings().noHearth), UnitLevel("player"),
    UnitXP and UnitXP("player") or 0, e and e.updated or "", tostring(scan.entries), TaxiCount(),
    tostring(b and b.name), tostring(Settings().mountSpeed), Geo.paramsVersion or 0 }, "|")
end

-- Returns true if the cached plan is up to date; otherwise starts (or continues) the computation and
-- calls cb(route, err, info) when done. force = recompute even if the cache is valid.
function Geo.RequestPlan(horizon, cb, force)
  local key = Geo.PlanKey(horizon)
  local pos = PlayerPos()
  local c = Geo.planCache
  if not force and c and c.key == key and pos and c.pos and (Dist(pos, c.pos) or math.huge) < K.REPLAN_DISTANCE then
    return true
  end
  if cb then
    Geo.planCbs = Geo.planCbs or {}
    local dup = false
    for _, f in ipairs(Geo.planCbs) do if f == cb then dup = true break end end
    if not dup then table.insert(Geo.planCbs, cb) end
  end
  if Geo.co and Geo.runningKey == key then return false end
  Geo.runningKey = key
  local co = coroutine.create(function() return PlanXP(horizon) end)
  Geo.co = co
  local function finish(result)
    Geo.co = nil
    Geo.planCache = result
    local cbs = Geo.planCbs or {}
    Geo.planCbs = nil
    for _, f in ipairs(cbs) do
      local ok, e = pcall(f, result.route, result.err, result.info)
      if not ok then Print(L["Error after computing the Roadbook: "] .. tostring(e)) end
    end
  end
  local function step()
    if Geo.co ~= co then return end -- replaced by a more recent computation
    Geo.sliceStart = debugprofilestop and debugprofilestop() or 0
    local ok, route, err, info = coroutine.resume(co)
    if not ok then
      Print(L["|cffff6060Roadbook computation error|r: "] .. tostring(route))
      finish({ key = key, pos = pos, err = L["Computation error: "] .. tostring(route) })
    elseif coroutine.status(co) == "dead" then
      finish({ key = key, pos = pos, route = route, err = err, info = info })
    else
      C_Timer.After(0, step)
    end
  end
  step()
  return false
end

local function FormatTime(sec)
  sec = math.floor(sec + 0.5)
  if sec < 60 then return sec .. L[" s"] end
  if sec < 3600 then return math.floor(sec / 60 + 0.5) .. L[" min"] end
  return string.format("%d h %02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

local function FormatNumber(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^ ", ""))
end

---------------------------------------------------------------------------
-- Quest abandon
---------------------------------------------------------------------------
local function AbandonQuestByID(questID)
  if not (C_QuestLog.SetSelectedQuest and C_QuestLog.SetAbandonQuest and C_QuestLog.AbandonQuest) then
    Print(L["Abandon API not found in this client."])
    return
  end
  C_QuestLog.SetSelectedQuest(questID)
  C_QuestLog.SetAbandonQuest()
  C_QuestLog.AbandonQuest()
end

StaticPopupDialogs["FQE_ABANDON"] = {
  text = L["Abandon the quest \"%s\"?\n\nYour progress on this quest will be lost."],
  button1 = L["Abandon"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, questID)
    if not (questID and IsInLog(questID)) then return end
    AbandonQuestByID(questID)
    C_Timer.After(1.5, function()
      if IsInLog(questID) then
        Print(L["|cffff6060The game did not take the abandon into account.|r Abandon it from the quest log (L)."])
      end
      if Refresh then Refresh() end
    end)
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Text to export (Ctrl+C)
---------------------------------------------------------------------------
local FREQ = { [1] = L["daily"], [2] = L["weekly"] }

local function BuildText()
  Snapshot()
  local e = ForeverQuestPlannerDB[CharKey()]
  if not e then return L["No data."] end
  local plevel, range = UnitLevel("player"), TrivialRange()

  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  add(string.format(L["Quest log - %s (%s level %s) - %s - %s - %d quests"],
    e.name or "?", e.class or "?", tostring(e.level or "?"), e.zone or "?", e.updated or "?", e.count or 0))

  local currentZone
  for _, q in ipairs(e.quests) do
    if q.zone ~= currentZone then
      currentZone = q.zone
      add("")
      add("## " .. (currentZone or L["No zone"]))
    end
    local tags = {}
    if q.level then tags[#tags + 1] = L["level "] .. q.level end
    if q.xp and q.xp > 0 then tags[#tags + 1] = q.xp .. " XP" end
    if q.money and q.money > 0 then
      local g, sv, c = math.floor(q.money / 10000), math.floor(q.money / 100) % 100, q.money % 100
      tags[#tags + 1] = (g > 0 and (g .. L["g "]) or "") .. (sv > 0 and (sv .. L["s "]) or "") .. (c > 0 and (c .. L["c"]) or "")
    end
    if q.instanceName then tags[#tags + 1] = L["dungeon: "] .. q.instanceName
    elseif q.mapZone and q.mapZone ~= q.zone then tags[#tags + 1] = L["location: "] .. q.mapZone end
    if q.tag then tags[#tags + 1] = q.tag end
    if q.suggestedGroup and q.suggestedGroup > 1 then tags[#tags + 1] = L["group "] .. q.suggestedGroup end
    if FREQ[q.frequency] then tags[#tags + 1] = FREQ[q.frequency] end
    if q.complete then tags[#tags + 1] = L["COMPLETE"] end
    if q.failed then tags[#tags + 1] = L["FAILED"] end
    add(string.format("- %s [%d] (%s)", q.title or "?", q.id, table.concat(tags, ", ")))
    if q.objectivesText and q.objectivesText ~= "" then
      add(L["    Goal: "] .. (q.objectivesText:gsub("[\r\n]+", " ")))
    end
    for _, o in ipairs(q.objectives or {}) do
      add(string.format("    %s %s", o.finished and "[x]" or "[ ]", o.text or ""))
    end
    if QDB.ok then
      local chain = ChainText(ChainInfo(q.id, plevel, range))
      if chain then add("    " .. chain) end
      local turnIn = TurnInText(q.id)
      if turnIn then add(L["    Turn in to: "] .. turnIn) end
    end
  end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local mainFrame
local panels, tabButtons = {}, {}
local currentTab = "near"
local availFilter = "zone"
local CONTENT_WIDTH = 770 -- same gap on the right (to the scroll bar) as on the left

-- Scroll bar of a UIPanelScrollFrameTemplate frame (key, name, or Slider child).
local function ScrollBarOf(scroll)
  if type(scroll.ScrollBar) == "table" then return scroll.ScrollBar end
  local name = scroll.GetName and scroll:GetName()
  if type(name) == "string" and type(_G[name .. "ScrollBar"]) == "table" then return _G[name .. "ScrollBar"] end
  for _, child in ipairs({ scroll:GetChildren() }) do
    if type(child) == "table" and child.GetObjectType and child:GetObjectType() == "Slider" then return child end
  end
  return nil
end

-- Shows the scroll bar only if the content is taller than the visible area.
local function UpdateScrollBar(scroll)
  local function apply()
    local bar = ScrollBarOf(scroll)
    if not bar or not scroll.child then return end
    local need = (scroll.child:GetHeight() or 0) > (scroll:GetHeight() or 0) + 2
    bar:SetShown(need)
    if not need then scroll:SetVerticalScroll(0) end
  end
  apply()
  C_Timer.After(0, apply) -- after the next frame's layout
end

local function CreateScrollPanel(parent, child, top)
  local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 12, top or -64)
  scroll:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -32, 24)
  if not child then
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CONTENT_WIDTH, 1)
  end
  scroll:SetScrollChild(child)
  scroll.child = child
  -- The game template hides the scroll bar itself when there is nothing to scroll.
  scroll.scrollBarHideable = true
  if scroll.HookScript then
    scroll:HookScript("OnScrollRangeChanged", function(self) UpdateScrollBar(self) end)
  end
  return scroll
end

---------------------------------------------------------------------------
-- Shared list engine: colored, collapsible category bars, lines with buttons
---------------------------------------------------------------------------
-- Category bar colors (solid background, dark text).
local CAT_COLORS = {
  turnin = { 0.30, 0.80, 0.30 },
  zone = { 0.90, 0.75, 0.20 },
  dungeon = { 0.62, 0.45, 0.90 },
  singles = { 0.80, 0.70, 0.40 },
  later = { 0.85, 0.35, 0.35 },
  take = { 0.40, 0.65, 0.95 },
  step = { 0.90, 0.75, 0.20 },
  abandon = { 0.90, 0.50, 0.25 },
  class = { 0.35, 0.80, 0.80 },
  info = { 0.55, 0.55, 0.55 },
}

-- Item tooltip opened from a list line: hidden when the lines are redrawn or the window closes
-- (the line under the cursor may be hidden or reused without any "leave" event).
function Geo.HideRowTooltip()
  local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
  if owner and owner.isListRow then GameTooltip:Hide() end
end

local function ListRow(panel, i)
  panel.rows = panel.rows or {}
  local r = panel.rows[i]
  if r then return r end
  r = CreateFrame("Frame", nil, panel.scroll.child)
  r:SetWidth(CONTENT_WIDTH)
  r.isListRow = true
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.hl = r:CreateTexture(nil, "BACKGROUND", nil, 1)
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 0.85, 0.4, 0.12)
  r.hl:Hide()
  r.stripe = r:CreateTexture(nil, "BORDER")
  r.stripe:SetPoint("TOPLEFT")
  r.stripe:SetPoint("BOTTOMLEFT")
  r.stripe:SetWidth(4)
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  r.text:SetPoint("TOPLEFT", 10, -6)
  r.text:SetJustifyH("LEFT")
  r.text:SetSpacing(2)
  -- Item names of a line (rewards): game tooltip on hover.
  if r.SetHyperlinksEnabled then
    r:SetHyperlinksEnabled(true)
    r:SetScript("OnHyperlinkEnter", function(self, link)
      GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
      pcall(GameTooltip.SetHyperlink, GameTooltip, link)
      GameTooltip:Show()
    end)
    r:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
  end
  -- Three button columns (b1, b2, b3), placed by RenderList according to the tab's grid.
  r.b1 = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  r.b2 = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  r.b3 = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  for _, b in ipairs({ r.b1, r.b2, r.b3 }) do b:SetHeight(20) end
  panel.rows[i] = r
  return r
end

local function SetButton(b, spec)
  if spec then
    b:SetText(spec.text)
    b:SetScript("OnClick", spec.fn)
    b:Show()
  else
    b:Hide()
  end
end

local BUTTON_MIN = { 80, 72, 80 } -- minimum width per column
K.BUTTON_GAP = 4

-- List button grid: columns used by at least one line, common width
-- per column (the longest label), aligned as far right as possible.
local measureText
local function ButtonGrid(items)
  if not measureText then
    measureText = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    measureText:Hide()
  end
  local width, used = { 0, 0, 0 }, { false, false, false }
  for _, it in ipairs(items) do
    for c, key in ipairs({ "b1", "b2", "b3" }) do
      local spec = it[key]
      if spec then
        used[c] = true
        measureText:SetText(spec.text)
        local w = (measureText:GetStringWidth() or 0) + 24
        if w > width[c] then width[c] = w end
      end
    end
  end
  local offsets, x = {}, -2
  for c = 3, 1, -1 do
    if used[c] then
      width[c] = math.max(width[c], BUTTON_MIN[c])
      offsets[c] = x
      x = x - width[c] - K.BUTTON_GAP
    end
  end
  return { width = width, used = used, offsets = offsets, total = -x }
end

-- items: { header = true, kind, key, label, b1, b2, b3 } | { text, b1, b2, b3, tint, stripe }  (b = { text, fn })
-- Categories are collapsed by default and every time the window opens.
-- Categories expanded while the window is open; everything collapses again each time it opens.
local expandedCategories = {}

K.MAX_VISIBLE_ROWS = 400

local OpenQuestDetails -- defined with quest tracking, further down

local function RenderList(panel, tabKey, items, forceOpen)
  Geo.HideRowTooltip()
  -- Two grids: quest lines and category bars, each aligned to the right.
  local rowItems, headerItems = {}, {}
  for _, it in ipairs(items) do
    if it.header then headerItems[#headerItems + 1] = it else rowItems[#rowItems + 1] = it end
  end
  local rowGrid, headerGrid = ButtonGrid(rowItems), ButtonGrid(headerItems)
  local expanded = expandedCategories
  local y, zebra, n, closed, capped = -4, 0, 0, false, false
  for _, it in ipairs(items) do
    local ckey = it.key and (tabKey .. ":" .. it.key)
    if it.header then closed = (not forceOpen) and ckey and not expanded[ckey] and true or false end
    if n >= K.MAX_VISIBLE_ROWS and not it.header then
      capped = capped or not closed -- too many expanded lines: only the bars stay visible
    elseif it.header or not closed then
      n = n + 1
      local r = ListRow(panel, n)
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", 0, y)
      r:Show()
      r.hl:Hide()
      local grid = it.header and headerGrid or rowGrid
      for c, b in ipairs({ r.b1, r.b2, r.b3 }) do
        SetButton(b, it["b" .. c])
        if grid.used[c] then
          b:ClearAllPoints()
          b:SetPoint("TOPRIGHT", r, "TOPRIGHT", grid.offsets[c], -2)
          b:SetWidth(grid.width[c])
        end
      end
      local hasButtons = it.b1 or it.b2 or it.b3
      r.text:SetWidth(CONTENT_WIDTH - (hasButtons and (grid.total + 12) or 16))
      if it.stripe then
        r.stripe:SetColorTexture(it.stripe[1], it.stripe[2], it.stripe[3], 1)
        r.stripe:Show()
      else
        r.stripe:Hide()
      end
      if it.header then
        local c = CAT_COLORS[it.kind] or CAT_COLORS.zone
        r.bg:SetColorTexture(c[1], c[2], c[3], 0.9)
        local prefix = ckey and ((closed and "[+]  ") or "[-]  ") or ""
        r.text:SetText("|cff101010" .. prefix .. it.label .. "|r")
        r:SetScript("OnEnter", nil)
        r:SetScript("OnLeave", nil)
        r.hl:Hide()
        if ckey then
          r:EnableMouse(true)
          r:SetScript("OnMouseUp", function()
            expanded[ckey] = not expanded[ckey] or nil
            Refresh()
          end)
        else
          r:EnableMouse(false)
          r:SetScript("OnMouseUp", nil)
        end
        zebra = 0
      else
        zebra = zebra + 1
        if it.tint then
          r.bg:SetColorTexture(it.tint[1], it.tint[2], it.tint[3], (zebra % 2 == 0) and 0.24 or 0.18)
        else
          r.bg:SetColorTexture(1, 1, 1, (zebra % 2 == 0) and 0.05 or 0)
        end
        if it.questID and IsInLog(it.questID) then
          local qid = it.questID
          r:EnableMouse(true)
          r:SetScript("OnMouseUp", function() OpenQuestDetails(qid) end)
          r:SetScript("OnEnter", function(self) self.hl:Show() end)
          r:SetScript("OnLeave", function(self) self.hl:Hide() end)
        else
          r:EnableMouse(it.links and true or false) -- item names: tooltips need the mouse
          r:SetScript("OnMouseUp", nil)
          r:SetScript("OnEnter", nil)
          r:SetScript("OnLeave", nil)
        end
        r.text:SetText(it.text or "")
      end
      local h = math.max(it.header and 24 or 26, r.text:GetStringHeight() + 12)
      r:SetHeight(h)
      y = y - h - (it.header and 3 or 0)
    end
  end
  if capped then
    n = n + 1
    local r = ListRow(panel, n)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, y)
    r:Show()
    for _, b in ipairs({ r.b1, r.b2, r.b3 }) do b:Hide() end
    r.stripe:Hide()
    r.bg:SetColorTexture(1, 0.5, 0.15, 0.2)
    r:EnableMouse(false)
    r:SetScript("OnMouseUp", nil)
    r.text:SetWidth(CONTENT_WIDTH - 16)
    r.text:SetText(Color("ff8040", L["Too many expanded lines: collapse some categories, pick a narrower filter or search."]))
    r:SetHeight(26)
    y = y - 26
  end
  for i = n + 1, #(panel.rows or {}) do panel.rows[i]:Hide() end
  panel.scroll.child:SetHeight(-y + 10)
  UpdateScrollBar(panel.scroll)
end

local function ShowMessage(panel, tabKey, text)
  RenderList(panel, tabKey, { { text = text } })
end

local function Plural(n, word)
  return n .. " " .. word .. "(s)"
end

local function RenderExport()
  local eb = panels.export.scroll.child
  local text = BuildText()
  eb.fullText = text
  eb:SetText(text)
  eb:SetFocus()
  eb:SetCursorPosition(0)
  eb:HighlightText()
  UpdateScrollBar(panels.export.scroll)
end

---------------------------------------------------------------------------
-- Quest tracking and map pins
---------------------------------------------------------------------------
local function IsWatched(id)
  if C_QuestLog.GetQuestWatchType then return C_QuestLog.GetQuestWatchType(id) ~= nil end
  if IsQuestWatched and C_QuestLog.GetLogIndexForQuestID then
    local i = C_QuestLog.GetLogIndexForQuestID(id)
    return i and IsQuestWatched(i) or false
  end
  return false
end

local function SetWatched(id, on)
  local idx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
  if on then
    if C_QuestLog.AddQuestWatch then pcall(C_QuestLog.AddQuestWatch, id)
    elseif AddQuestWatch and idx then pcall(AddQuestWatch, idx) end
  else
    if C_QuestLog.RemoveQuestWatch then pcall(C_QuestLog.RemoveQuestWatch, id)
    elseif RemoveQuestWatch and idx then pcall(RemoveQuestWatch, idx) end
  end
end

-- Opens the game's quest log on a quest's details (depending on the client's UI).
OpenQuestDetails = function(questID)
  if not (questID and IsInLog(questID)) then return end
  if QuestMapFrame_OpenToQuestDetails then
    if pcall(QuestMapFrame_OpenToQuestDetails, questID) then return end
  end
  if C_QuestLog.SetSelectedQuest then pcall(C_QuestLog.SetSelectedQuest, questID) end
  local logFrame = rawget(_G, "QuestLogFrame")
  if logFrame then
    if not logFrame:IsShown() then
      if ShowUIPanel then pcall(ShowUIPanel, logFrame) else logFrame:Show() end
    end
    local idx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
    if idx and QuestLog_SetSelection then pcall(QuestLog_SetSelection, idx) end
    if QuestLog_Update then pcall(QuestLog_Update) end
    return
  end
  if ToggleQuestLog then pcall(ToggleQuestLog) end
end

-- Tracks a single quest: removes every other one from tracking.
local function WatchOnly(questID)
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do
    if q.id ~= questID and IsWatched(q.id) then SetWatched(q.id, false) end
  end
  SetWatched(questID, true)
end

local function SetWatchedList(quests, on)
  local failed = 0
  for _, q in ipairs(quests) do
    SetWatched(q.id, on)
    if on and not IsWatched(q.id) then failed = failed + 1 end
  end
  if failed > 0 then Print(failed .. L[" quest(s) not tracked: the game's tracking limit was reached."]) end
end

-- Most useful point of a quest: nearest remaining objective, otherwise the turn-in NPC.
local function ObjectivePoint(q)
  local pos = PlayerPos()
  local t = QuestTargets(q.id)
  if not q.complete then
    local best, bd, label
    for _, r in ipairs(RemainingTargets(q, t)) do
      local p, d = Nearest(r.tg.points, pos)
      if p and (not best or (d and (not bd or d < bd))) then best, bd, label = p, d, r.tg.name end
    end
    if best then return best, label end
  end
  local f = Nearest(t.finish, pos)
  return f, L["turn in the quest"]
end

-- Pin placed by the addon, remembered per character.
local function PinStore()
  local s = Settings()
  s.pins = s.pins or {}
  return s.pins
end

-- Active addon pin, or nil if it was cleared or replaced by another pin.
local ownPinChange = false -- true while the addon is placing a pin itself

local function ActivePin()
  local pin = PinStore()[CharKey()]
  if not pin then return nil end
  if pin.via == "game" and C_Map.HasUserWaypoint and not C_Map.HasUserWaypoint() then
    PinStore()[CharKey()] = nil
    return nil
  end
  return pin
end

-- Called on USER_WAYPOINT_UPDATED: a pin placed or cleared by the player replaces ours.
local function OnWaypointChanged()
  if ownPinChange then
    ownPinChange = false
    return
  end
  local pin = PinStore()[CharKey()]
  if pin and pin.via == "game" then PinStore()[CharKey()] = nil end
end

local function ClearPin()
  local pin = PinStore()[CharKey()]
  PinStore()[CharKey()] = nil
  if pin and pin.via == "game" and C_Map.ClearUserWaypoint then
    ownPinChange = true
    if not pcall(C_Map.ClearUserWaypoint) then ownPinChange = false end
  elseif pin and pin.via == "tomtom" and TomTom and TomTom.ClearAllWaypoints then
    pcall(TomTom.ClearAllWaypoints, TomTom)
  end
end

-- Game map pin icon, or a text fallback if the atlas does not exist in this client.
local pinIcon
local function PinIcon()
  if pinIcon == nil then
    local ok, info = pcall(function() return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("Waypoint-MapPin-Tracked") end)
    pinIcon = (ok and info) and "|A:Waypoint-MapPin-Tracked:18:18|a " or Color("ff66ff", L["[Pin] "])
  end
  return pinIcon
end

local function IsPinned(questId)
  local pin = questId and ActivePin()
  return pin and pin.questId == questId or false
end

local function PinTag(questId)
  return IsPinned(questId) and PinIcon() or ""
end

-- Quest state icons (textures available in every client).
local ICON = {
  turnin = "|TInterface\\GossipFrame\\ActiveQuestIcon:16:16|t",     -- yellow ?: to turn in
  inprogress = "|TInterface\\GossipFrame\\IncompleteQuestIcon:16:16|t", -- gray ?: in progress
  available = "|TInterface\\GossipFrame\\AvailableQuestIcon:16:16|t",  -- yellow !: to pick up
  watched = "|TInterface\\Buttons\\UI-CheckBox-Check:16:16|t",         -- check mark: tracked
}

local function StateIcons(questId)
  if not questId then return "" end
  local icons = {}
  if IsInLog(questId) then
    local done = C_QuestLog.IsComplete and C_QuestLog.IsComplete(questId)
    icons[#icons + 1] = done and ICON.turnin or ICON.inprogress
    if IsWatched(questId) then icons[#icons + 1] = ICON.watched end
  else
    icons[#icons + 1] = ICON.available
  end
  if IsPinned(questId) then icons[#icons + 1] = PinIcon() end
  return table.concat(icons, "") .. " "
end

---------------------------------------------------------------------------
-- Quest line shown the same way in every tab: title, level, elite, types
---------------------------------------------------------------------------
-- Quest types, deduced from the QuestieDB objectives (several per quest, in this order).
K.QUEST_TYPES = { "escort", "assassination", "slaying", "collect", "gathering", "interaction", "exploration",
  "talk", "reputation", "delivery" }
K.QUEST_TYPE_LABEL = {
  escort = L["Escort"], assassination = L["Assassination"], slaying = L["Slaying"], collect = L["Collect"],
  gathering = L["Gathering"], interaction = L["Interaction"], exploration = L["Exploration"], talk = L["Talk"],
  reputation = L["Reputation"], delivery = L["Delivery"],
}

-- Words of the objective text, for quests whose objectives QuestieDB does not know.
K.QUEST_TYPE_WORDS = {
  slaying = { "%f[%a]kill", "%f[%a]slay", "%f[%a]destroy", "%f[%a]defeat", "%f[%a]exterminate", "%f[%a]eliminate" },
  collect = { "%f[%a]collect%f[%A]", "%f[%a]gather%f[%A]", "%f[%a]obtain%f[%A]", "%f[%a]recover%f[%A]",
    "%f[%a]retrieve%f[%A]", "bring %d", "bring me %d" },
  exploration = { "%f[%a]explore%f[%A]", "%f[%a]scout%f[%A]", "%f[%a]investigate%f[%A]", "%f[%a]locate%f[%A]" },
  interaction = { "%f[%a]use%f[%A]", "%f[%a]place%f[%A]", "%f[%a]plant%f[%A]", "%f[%a]activate%f[%A]" },
}

-- Unique NPC (to assassinate): rare, rare elite or boss, or a single known spawn point.
function Geo.UniqueNpc(id)
  local rank = QGet(QDB.Npc, id, "rank")
  if rank == 2 or rank == 3 or rank == 4 then return true end
  local spawns, n = QGet(QDB.Npc, id, "spawns"), 0
  if type(spawns) == "table" then
    for _, pts in pairs(spawns) do n = n + (type(pts) == "table" and #pts or 0) end
  end
  return n == 1
end

Geo.qtypes = {}
function Geo.QuestTypes(id)
  if not id then return {} end
  local cached = Geo.qtypes[id]
  if cached then return cached end
  local has = {}
  if Geo.IsEscort(id) then has.escort = true end
  local obj = QGet(QDB.Quest, id, "objectives")
  if type(obj) == "table" then
    for _, o in ipairs(obj[1] or {}) do
      local icon = o[3]
      if icon == 3 or icon == 5 or icon == 17 then has.talk = true
      elseif Geo.UniqueNpc(o[1]) then has.assassination = true
      else has.slaying = true end
    end
    if #(obj[2] or {}) > 0 then has.interaction = true end
    for _, o in ipairs(obj[3] or {}) do
      local npcs, objs = QGet(QDB.Item, o[1], "npcDrops"), QGet(QDB.Item, o[1], "objectDrops")
      if type(npcs) == "table" and #npcs > 0 then has.collect = true
      elseif type(objs) == "table" and #objs > 0 then has.gathering = true
      else has.collect = true end -- bought, crafted…
    end
    if #(obj[4] or {}) > 0 then has.reputation = true end
    local givesItem = (tonumber(QGet(QDB.Quest, id, "sourceItemId")) or 0) > 0 -- 0 = no item
    for _, o in ipairs(obj[5] or {}) do
      if givesItem then has.interaction = true -- credit for using the item given by the quest on them
      elseif type(o) == "table" and o[2] and Geo.UniqueNpc(o[2]) then has.assassination = true
      else has.slaying = true end
    end
    if #(obj[6] or {}) > 0 then has.interaction = true end
  end
  if not has.escort and type(QGet(QDB.Quest, id, "triggerEnd")) == "table" then has.exploration = true end
  if not next(has) then
    -- No objective known by QuestieDB (frequent for Forever quests): words of the English text.
    local text = ""
    if QDB.Quest and QDB.Quest.GetRaw then
      local ok, t = pcall(QDB.Quest.GetRaw, id, "objectivesText")
      if ok and type(t) == "table" then text = table.concat(t, " "):lower() end
    end
    for kind, words in pairs(K.QUEST_TYPE_WORDS) do
      for _, w in ipairs(words) do
        if text:find(w) then has[kind] = true break end
      end
    end
    if not next(has) then has.delivery = true end -- bring something / someone, or talk to an NPC
  end
  local list = {}
  for _, k in ipairs(K.QUEST_TYPES) do if has[k] then list[#list + 1] = k end end
  Geo.qtypes[id] = list
  return list
end

-- Game tag of a quest of the log ("Elite", "Dungeon"…), "" if none, nil if not in the log.
function Geo.LogTag(id)
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do
    if q.id == id then return q.tag or "" end
  end
  return nil
end

-- Quest level, colored like in the game's quest log (gray, green, yellow, orange, red).
function Geo.LevelBadge(level)
  if not (level and level > 0) then return "" end
  local hex
  if GetQuestDifficultyColor then
    local ok, c = pcall(GetQuestDifficultyColor, level)
    if ok and type(c) == "table" and c.r then
      hex = string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
  end
  if not hex then
    local gap = level - (UnitLevel("player") or level)
    hex = (gap >= 5 and "ff2020") or (gap >= 3 and "ff8040") or (gap >= -2 and "ffff00") or "40c040"
  end
  return Color(hex, "[" .. level .. "]")
end

-- "  [35] Elite · Dungeon · Escort · Collect": o = { id, level, tag (game tag, log quests),
-- isClass, isProf, dungeon }.
function Geo.QuestBadges(o)
  local id = o.id
  local tag = o.tag
  if tag == nil and id then tag = Geo.LogTag(id) end
  local parts = {}
  if id and Geo.IsEliteQuest(id, tag) then parts[#parts + 1] = Color("ff8040", L["Elite"]) end
  if tag and tag ~= "" and not tag:find("[EÉ]lite") and tag ~= ELITE then parts[#parts + 1] = tag
  elseif o.dungeon then parts[#parts + 1] = L["Dungeon"] end
  local isClass = o.isClass
  if isClass == nil and id then
    local m = QuestMeta(id)
    isClass = m and IsClassMeta(m) or false
  end
  if isClass then parts[#parts + 1] = L["Class"] end
  if o.isProf then parts[#parts + 1] = L["Profession"] end
  local types = Geo.QuestTypes(id)
  for i = 1, math.min(#types, 3) do parts[#parts + 1] = K.QUEST_TYPE_LABEL[types[i]] end
  local badge = Geo.LevelBadge(o.level)
  return "  " .. badge .. (#parts > 0 and (" " .. Color("80c0ff", table.concat(parts, " · "))) or "")
end

local function IconLegend(withAvailable)
  return Color("aaaaaa", ICON.turnin .. L[" to turn in   "] .. ICON.inprogress .. L[" in progress   "] .. ICON.watched ..
    L[" tracked   "] .. PinIcon() .. L["pin"] .. (withAvailable and ("   " .. ICON.available .. L[" to pick up"]) or ""))
end

-- Quest states (for filters): turnin, inprogress, watched, pinned, available.
local function QuestStates(questId)
  local st = {}
  if not questId then return st end
  if IsInLog(questId) then
    if C_QuestLog.IsComplete and C_QuestLog.IsComplete(questId) then st.turnin = true else st.inprogress = true end
    if IsWatched(questId) then st.watched = true end
  else
    st.available = true
  end
  if IsPinned(questId) then st.pinned = true end
  return st
end

-- State filters: none checked = everything; otherwise the quest must have at least one checked state.
local journalStates, nearStates = {}, {}
local function PassStates(questId, selected, toDrop)
  if not next(selected) then return true end
  local st = QuestStates(questId)
  if toDrop then st.abandon = true end
  for key in pairs(selected) do
    if st[key] then return true end
  end
  return false
end

-- Places the game map pin (or TomTom) on a QuestieDB point.
local function PinPoint(p, title, label, questId)
  if not p then
    Print(L["Unknown position for \""] .. (title or "?") .. L["\"."])
    return
  end
  local ui = p.ui or Geo.areaToUi[p.area]
  if (not ui or ui == 0) and Geo.parent[p.area] then ui = Geo.areaToUi[Geo.parent[p.area]] end
  if not ui or ui == 0 then
    Print(L["No map found for this position."])
    return
  end
  local x, y = (p.mx or 50) / 100, (p.my or 50) / 100
  local done, via = false, nil
  if C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
    local can = not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(ui)
    if can then
      ownPinChange = true
      done = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(ui, x, y))
      if done then via = "game" else ownPinChange = false end
      if done and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
      end
    end
  end
  if not done and TomTom and TomTom.AddWaypoint then
    done = pcall(TomTom.AddWaypoint, TomTom, ui, x, y, { title = title })
    if done then via = "tomtom" end
  end
  if done then
    PinStore()[CharKey()] = { questId = questId, title = title, label = label, ui = ui, x = x, y = y,
      place = PointText(p), via = via, area = p.area, mx = p.mx, my = p.my }
    Print(L["Pin: "] .. (title or "?") .. (label and (" - " .. label) or "") .. " - " .. PointText(p))
    if Refresh then C_Timer.After(0.1, Refresh) end
  else
    Print(L["This client cannot place a pin here ("] .. PointText(p) .. ").")
  end
end

local function SetMapPin(q)
  if not (QDB.ok and GeoReady()) then
    Print(L["Cannot place a pin: QuestieDB is required to know objective locations."])
    return
  end
  local p, label = ObjectivePoint(q)
  PinPoint(p, q.title, label or L["objective"], q.id)
end

local function UnpinButton()
  return { text = L["Remove pin"], fn = function()
    ClearPin()
    Print(L["Pin removed."])
    if Refresh then Refresh() end
  end }
end

local function PinButton(p, title, label, questId)
  if IsPinned(questId) then return UnpinButton() end
  if not (QDB.ok and p) then return nil end
  return { text = L["Pin"], fn = function() PinPoint(p, title, label, questId) end }
end

---------------------------------------------------------------------------
-- Search (accent and case insensitive, every word must be present)
---------------------------------------------------------------------------
local ACCENTS = {
  ["à"] = "a", ["â"] = "a", ["ä"] = "a", ["á"] = "a", ["À"] = "a", ["Â"] = "a", ["Ä"] = "a",
  ["ç"] = "c", ["Ç"] = "c",
  ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e", ["É"] = "e", ["È"] = "e", ["Ê"] = "e", ["Ë"] = "e",
  ["î"] = "i", ["ï"] = "i", ["í"] = "i", ["Î"] = "i", ["Ï"] = "i",
  ["ô"] = "o", ["ö"] = "o", ["ó"] = "o", ["Ô"] = "o", ["Ö"] = "o",
  ["ù"] = "u", ["û"] = "u", ["ü"] = "u", ["ú"] = "u", ["Ù"] = "u", ["Û"] = "u", ["Ü"] = "u",
  ["œ"] = "oe", ["Œ"] = "oe", ["’"] = "'",
}

local function Normalize(s)
  s = tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:gsub("[\1-\127\194-\244][\128-\191]*", function(c) return ACCENTS[c] or c end)
  return s:lower()
end

local function ParseQuery(text)
  local words = {}
  for w in Normalize(text):gmatch("%S+") do words[#words + 1] = w end
  return words
end

local function MatchWords(hay, words)
  for _, w in ipairs(words) do
    if not hay:find(w, 1, true) then return false end
  end
  return true
end

local todoQuery, availQuery, nearQuery, xpQuery = {}, {}, {}, {}

local function QuestHaystack(q)
  local parts = { q.title, q.zone, q.mapZone, q.instanceName, q.tag, q._turnIn, q.objectivesText, q._chain }
  for _, o in ipairs(q.objectives or {}) do parts[#parts + 1] = o.text end
  local list = {}
  for _, v in pairs(parts) do if v then list[#list + 1] = tostring(v) end end
  return Normalize(table.concat(list, " "))
end

local function EntryHaystack(e)
  if not e._hay then
    e._hay = Normalize(table.concat({ e.name or "", e.area or "", e.dungeon or "", e.starter or "", e.starterZone or "" }, " "))
  end
  return e._hay
end

-- Search box (game template if available), with a short delay before filtering.
local function CreateSearchBox(parent, width, onChange)
  local ok, eb = pcall(CreateFrame, "EditBox", nil, parent, "SearchBoxTemplate")
  local custom = false
  if not ok or not eb then
    eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    custom = true
  end
  eb:SetSize(width, 20)
  eb:SetAutoFocus(false)
  if custom then
    eb.hint = eb:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    eb.hint:SetPoint("LEFT", 4, 0)
    eb.hint:SetText(L["Search…"])
  end
  local timer
  eb:HookScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    if eb.hint then eb.hint:SetShown(text == "") end
    if timer then timer:Cancel() end
    if C_Timer.NewTimer then
      timer = C_Timer.NewTimer(0.25, function() onChange(text) end)
    else
      onChange(text)
    end
  end)
  eb:HookScript("OnEnterPressed", function(self) self:ClearFocus() end)
  eb:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return eb
end

---------------------------------------------------------------------------
-- Quest log tab (to do / to abandon)
---------------------------------------------------------------------------
local function AbandonButton(q)
  return { text = L["Abandon"], fn = function() StaticPopup_Show("FQE_ABANDON", q.title or "?", nil, q.id) end }
end

local function QuestLine(q)
  local extras = {}
  if q._itemReason then extras[#extras + 1] = q._itemReason end
  if q.xp and q.xp > 0 then extras[#extras + 1] = q.xp .. " XP" end
  if q.money and q.money > 0 then extras[#extras + 1] = MoneyText(q.money) end
  if q.suggestedGroup and q.suggestedGroup > 1 then extras[#extras + 1] = L["group "] .. q.suggestedGroup end
  local badges = Geo.QuestBadges({ id = q.id, level = q.level, tag = q.tag or "", isClass = q._isClass, isProf = q._isProf })
  return (q.title or "?") .. badges .. (#extras > 0 and Color("aaaaaa", "  " .. table.concat(extras, ", ")) or "")
end

local function RenderTodo(a)
  local searching = #todoQuery > 0 or next(journalStates) ~= nil
  local items = {}

  local function category(kind, key, label, quests, detail)
    if searching then
      local kept = {}
      for _, q in ipairs(quests) do
        if (#todoQuery == 0 or MatchWords(QuestHaystack(q), todoQuery)) and PassStates(q.id, journalStates, q._abandon) then
          kept[#kept + 1] = q
        end
      end
      if #kept == 0 then return end
      quests = kept
    end
    local watched, toDrop = 0, 0
    for _, q in ipairs(quests) do
      if IsWatched(q.id) then watched = watched + 1 end
      if q._abandon then toDrop = toDrop + 1 end
    end
    local text = label .. " - " .. Plural(#quests, L["quest"])
    if watched > 0 then text = text .. " - " .. watched .. L[" tracked"] end
    if toDrop > 0 then text = text .. " - " .. toDrop .. L[" to abandon"] end
    if searching then text = text .. L["  (filtered)"] end
    local list = quests
    items[#items + 1] = { header = true, kind = kind, key = key, label = text,
      b1 = { text = L["Track all"], fn = function()
        SetWatchedList(list, true)
        C_Timer.After(0.2, Refresh)
      end },
      b2 = { text = L["Track none"], fn = function()
        SetWatchedList(list, false)
        C_Timer.After(0.2, Refresh)
      end },
    }
    for _, q in ipairs(quests) do
      local body = "  " .. StateIcons(q.id) .. (q._abandon and Color("ff8040", L["[To abandon] "]) or "") .. QuestLine(q)
      if q._abandon then body = body .. "\n       " .. Color("ff8040", L["Reason: "] .. q._abandon) end
      for _, l in ipairs(detail(q)) do body = body .. "\n       " .. l end
      local watchedQ = IsWatched(q.id)
      local b1
      if q._abandon then
        b1 = { text = L["Keep"], fn = function()
          Settings().keep[q.id] = true
          Refresh()
        end }
      else
        b1 = { text = watchedQ and L["Untrack"] or L["Track"], fn = function()
          SetWatchedList({ q }, not watchedQ)
          C_Timer.After(0.2, Refresh)
        end }
      end
      items[#items + 1] = {
        text = body,
        questID = q.id,
        tint = q._abandon and { 0.9, 0.5, 0.25 } or nil,
        stripe = q._abandon and { 1, 0.5, 0.15 } or nil,
        b1 = b1,
        b2 = IsPinned(q.id) and UnpinButton() or (QDB.ok and { text = L["Pin"], fn = function() SetMapPin(q) end } or nil),
        b3 = AbandonButton(q),
      }
    end
  end

  local function normalDetail(q)
    local lines = {}
    local rest = RemainingObjectives(q)
    if rest ~= "" then lines[#lines + 1] = Color("bbbbbb", rest) end
    if q._chain then lines[#lines + 1] = Color("c080ff", q._chain) end
    return lines
  end

  if #a.abandon > 0 and not searching then
    items[#items + 1] = { text = Color("ff8040", Plural(#a.abandon, L["quest"]) .. L[" recommended for abandoning: orange lines marked [To abandon], in their category."]) ..
      (a.kept > 0 and Color("888888", "\n" .. Plural(a.kept, L["quest"]) .. L[" kept despite the recommendation (/fqp reset to clear)."]) or ""),
      tint = { 0.9, 0.5, 0.25 }, stripe = { 1, 0.5, 0.15 } }
  elseif a.kept > 0 and not searching then
    items[#items + 1] = { text = Color("888888", Plural(a.kept, L["quest"]) .. L[" kept despite the abandon recommendation (/fqp reset to clear)."]) }
  end

  if #a.turnIn > 0 then
    category("turnin", "turnin", L["To turn in"], a.turnIn, function(q)
      return { Color("888888", "-> " .. (q._turnIn or q.zone or "?")) }
    end)
  end

  local singles = {}
  for _, g in ipairs(a.groups) do
    if #g.quests >= 2 then
      category("zone", "zone:" .. g.name, g.name, g.quests, normalDetail)
    else
      singles[#singles + 1] = g.quests[1]
    end
  end

  for _, g in ipairs(a.dungeons) do
    category("dungeon", "dungeon:" .. g.name, L["Dungeon: "] .. g.name, g.quests, normalDetail)
  end

  if #singles > 0 then
    category("singles", "singles", L["Doable single quests"], singles, function(q)
      local lines = { Color("888888", q.instanceName or q.mapZone or q.zone or "?") }
      if q._chain then lines[#lines + 1] = Color("c080ff", q._chain) end
      return lines
    end)
  end

  if #a.later > 0 then
    category("later", "later", L["Later - level too high"], a.later, function(q)
      return { Color("888888", q.instanceName or q.mapZone or q.zone or "?") }
    end)
  end

  local hasQuests = false
  for _, it in ipairs(items) do if it.header then hasQuests = true break end end
  if not hasQuests then
    items[#items + 1] = { text = searching and L["No quest matches the search or filters."] or L["Your quest log is empty."] }
  end
  RenderList(panels.groups, "groups", items, searching)
end

local function CurrentZoneNames()
  local names = {}
  local function add(n) if n and n ~= "" then names[n] = true end end
  add(GetRealZoneText())
  add(GetZoneText())
  if C_Map and C_Map.GetBestMapForUnit then
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    if info then
      add(info.name)
      local parent = info.parentMapID and C_Map.GetMapInfo(info.parentMapID)
      if parent and Enum and Enum.UIMapType and parent.mapType == Enum.UIMapType.Zone then add(parent.name) end
    end
  end
  return names
end


---------------------------------------------------------------------------
-- Quest rewards: line of the "Available" tab (item names, game tooltip on hover)
---------------------------------------------------------------------------
-- Reward item: name from QuestieDB; the game's link (quality color) when already in its cache.
-- No request to the server: the tooltip loads the item on hover.
Geo.itemCache = {}
function Geo.ItemInGameCache(id)
  if C_Item and C_Item.IsItemDataCachedByID then
    local ok, v = pcall(C_Item.IsItemDataCachedByID, id)
    return ok and v and true or false
  end
  return false
end

function Geo.RewardItem(itemId)
  local it = Geo.itemCache[itemId]
  if not it then
    it = { id = itemId, name = QGet(QDB.Item, itemId, "name") or ("#" .. itemId) }
    Geo.itemCache[itemId] = it
  end
  if not it.link and Geo.ItemInGameCache(itemId) then -- e.g. loaded by a tooltip since
    local name, link = GetItemInfoCompat(itemId)
    if name then it.name, it.link = name, link end
  end
  return it
end

-- Rewards of a quest: item ids and reputations.
Geo.rewardCache = {}
function Geo.QuestRewards(id)
  local r = Geo.rewardCache[id]
  if r then return r end
  r = { items = Geo.RewardIndex()[id] or {}, rep = {} }
  local rep = QGet(QDB.Quest, id, "reputationReward")
  if type(rep) == "table" then
    for _, p in ipairs(rep) do
      if type(p) == "table" and p[1] and (p[2] or 0) > 0 then r.rep[#r.rep + 1] = { faction = p[1], value = p[2] } end
    end
  end
  Geo.rewardCache[id] = r
  return r
end

function Geo.FactionName(fid)
  if GetFactionInfoByID then
    local ok, name = pcall(GetFactionInfoByID, fid)
    if ok and name then return name end
  end
  return L["Faction "] .. fid
end

-- "Possible rewards: [Item] · [Item] · Reputation: Orgrimmar +250"
function Geo.RewardLine(id)
  if not Geo.rewards then -- index still being built in the background: the list is refreshed when ready
    Geo.BuildRewardIndexAsync()
    return nil
  end
  local r = Geo.QuestRewards(id)
  local parts = {}
  for _, itemId in ipairs(r.items) do
    local it = Geo.RewardItem(itemId)
    parts[#parts + 1] = it.link or ("|cffffffff|Hitem:" .. it.id .. "|h[" .. it.name .. "]|h|r")
  end
  for _, p in ipairs(r.rep) do
    parts[#parts + 1] = Color("aaaaaa", L["Reputation: "]) .. Geo.FactionName(p.faction) .. " +" .. p.value
  end
  if #parts == 0 then return nil end
  return Color("bbbbbb", L["Possible rewards: "]) .. table.concat(parts, Color("888888", " · "))
end

local function RenderAvailable()
  local panel = panels.avail
  if not QDB.ok then
    ShowMessage(panel, "avail", L["QuestieDB is not loaded: this tab needs its database.\nInstall or enable the QuestieDB addon, then restart the game."])
    return
  end
  if scan.error then
    ShowMessage(panel, "avail", Color("ff6060", scan.error))
    return
  end
  if scan.dirty or not scan.entries then
    if not scan.running then StartScan() end
    if scan.running or scan.dirty then
      ShowMessage(panel, "avail", L["Scanning the QuestieDB database…"])
      return
    end
  end

  local searching = #availQuery > 0
  local zoneNames = availFilter == "zone" and CurrentZoneNames() or nil
  local hereMaps = availFilter == "zone" and CurrentMapSet() or {}
  local function StartsHere(e)
    if not GeoReady() then return false end
    for _, pt in ipairs(StartPoints(e.id)) do
      local ui = Geo.areaToUi[pt.area] or (Geo.parent[pt.area] and Geo.areaToUi[Geo.parent[pt.area]])
      if ui and hereMaps[ui] then return true end
    end
    return false
  end
  local groups, byKey = {}, {}
  local showLow = Settings().showLowLevel
  for _, e in ipairs(scan.entries) do
    local keep, key, kind
    if (e.lowLevel and not showLow) or e.future then
      -- low-level quest hidden ("Low-level quests" option), or not at the required level yet
    else
    if availFilter == "zone" then
      keep = StartsHere(e) or (e.area and zoneNames[e.area]) or (e.starterZone and zoneNames[e.starterZone])
        or (e.dungeon and zoneNames[e.dungeon])
      key = e.dungeon or e.area or e.starterZone or L["Other"]
    elseif availFilter == "dungeon" then
      keep = e.dungeon ~= nil
      key = e.dungeon
    elseif availFilter == "class" then
      keep = e.isClass or e.isProf
      key = e.isClass and L["Class"] or L["Professions"]
    else
      keep = true
      key = e.dungeon or e.area or e.starterZone or L["Other"]
    end
    if keep and searching then keep = MatchWords(EntryHaystack(e), availQuery) end
    end
    if keep then
      kind = e.dungeon and key == e.dungeon and "dungeon" or ((key == L["Class"] or key == L["Professions"]) and "class") or "zone"
      local g = byKey[key]
      if not g then
        g = { name = key, kind = kind, list = {} }
        byKey[key] = g
        groups[#groups + 1] = g
      end
      g.list[#g.list + 1] = e
    end
  end

  table.sort(groups, function(a, b)
    if #a.list ~= #b.list then return #a.list > #b.list end
    return a.name < b.name
  end)

  local total = 0
  for _, g in ipairs(groups) do total = total + #g.list end
  local head = Plural(total, L["quest"]) .. L[" available"] .. (Settings().showLowLevel and L[", low level included"] or L[" (low level excluded)"]) .. L[", according to QuestieDB. Quests specific to Forever may be missing."]
  local items = { { text = Color("aaaaaa", head) } }
  local pos = PlayerPos()
  for _, g in ipairs(groups) do
    table.sort(g.list, function(a, b) return (a.level or 0) < (b.level or 0) end)
    items[#items + 1] = { header = true, kind = g.kind, key = g.name, label = g.name .. " - " .. Plural(#g.list, L["quest"]) }
    for _, e in ipairs(g.list) do
      local tags = {}
      if e.xp and e.xp > 0 then tags[#tags + 1] = "~" .. e.xp .. " XP" end
      if e.opensChain then tags[#tags + 1] = L["opens a chain"] end
      if e.repeatable then tags[#tags + 1] = L["repeatable"] end
      if e.lowLevel then tags[#tags + 1] = L["low level"] end
      local info = Color("aaaaaa", L["requires level "] .. e.reqLevel) ..
        (#tags > 0 and Color("80c0ff", "  " .. table.concat(tags, ", ")) or "")
      local text = "  " .. StateIcons(e.id) .. e.name ..
        Geo.QuestBadges({ id = e.id, level = e.level, isClass = e.isClass, isProf = e.isProf, dungeon = e.dungeon }) ..
        "\n       " .. info
      if e.repMissing then text = text .. "\n       " .. Color("ff6060", e.repMissing) end
      if e.missing then
        text = text .. "\n       " .. Color("ff6060", L["Missing prerequisites: "] .. table.concat(e.missing.texts, ", "))
      end
      if e.starter then text = text .. "\n       " .. Color("bbbbbb", L["Given by: "] .. e.starter) end
      local rewards = Geo.RewardLine(e.id)
      if rewards then text = text .. "\n       " .. rewards end
      local p = GeoReady() and Nearest(StartPoints(e.id), pos) or nil
      items[#items + 1] = { text = text, b2 = PinButton(p, e.name, L["pick up the quest"], e.id), links = rewards ~= nil }
    end
  end
  if total == 0 then items[#items + 1] = { text = searching and L["No quest matches the search."] or L["No quest available for this filter."] } end
  RenderList(panel, "avail", items, searching)
end

local function RenderNear()
  local panel = panels.near
  if not QDB.ok then
    ShowMessage(panel, "near", L["QuestieDB is not loaded: this tab needs the locations from its database."])
    return
  end
  if not GeoReady() then
    ShowMessage(panel, "near", L["Unable to convert QuestieDB positions to this client's map."])
    return
  end
  if (scan.dirty or not scan.entries) and not scan.running then StartScan() end

  local found, zoneFound = NearItems(nearRadius)
  if not found then
    ShowMessage(panel, "near", Color("ff6060", zoneFound))
    return
  end
  local where
  if nearRadius == "zone" then
    local _, zoneName = CurrentMapSet()
    where = L["In the whole current zone"] .. (zoneName and (" (" .. zoneName .. ")") or "")
  else
    where = L["Within "] .. nearRadius .. L[" m"]
  end
  local info = where .. L[" - updated automatically every 3 s."]
  if scan.running then info = info .. "\n" .. Color("ff8040", L["Scanning available quests: \"Available quests\" will fill in."]) end
  local items = { { text = Color("aaaaaa", info) } }

  local KIND_TAG = { turnin = Color("40ff40", L["[Turn in] "]), step = Color("ffd100", L["[Step] "]), take = Color("80c0ff", L["[Available] "]) }

  local function matches(it)
    if not PassStates(it.id, nearStates) then return false end
    if #nearQuery == 0 then return true end
    return MatchWords(Normalize(table.concat({ it.label or "", it.giver or "", it.extra or "", PointText(it.p) }, " ")), nearQuery)
  end

  local function row(it, withKind)
    local info = string.format("%.0f m", it.d)
    if it.kind == "take" then
      local tags = {}
      if it.lowLevel then tags[#tags + 1] = L["low level"] end
      if it.xp and it.xp > 0 then tags[#tags + 1] = "~" .. it.xp .. " XP" end
      if #tags > 0 then info = info .. Color("80c0ff", "  " .. table.concat(tags, ", ")) end
    end
    local who
    if it.kind == "take" then
      who = L["Given by: "] .. (it.giver or "?")
    elseif it.kind == "turnin" then
      who = L["Turn in to: "] .. (it.giver or "?")
    else
      who = L["Objective: "] .. (it.extra or "?")
    end
    local text = "  " .. StateIcons(it.id) .. (withKind and KIND_TAG[it.kind] or "") .. it.label ..
      (it.id and Geo.QuestBadges({ id = it.id, level = it.level }) or "") ..
      "\n       " .. Color("aaaaaa", info) .. "\n       " .. Color("bbbbbb", who .. " - " .. PointText(it.p))
    if it.rep then text = text .. "\n       " .. Color("ff6060", it.rep) end
    local b1
    if it.kind ~= "take" and it.id then
      local watched = IsWatched(it.id)
      local qid = it.id
      b1 = { text = watched and L["Untrack"] or L["Track"], fn = function()
        SetWatched(qid, not watched)
        C_Timer.After(0.2, Refresh)
      end }
    end
    return { text = text, b1 = b1, questID = it.kind ~= "take" and it.id or nil,
      b2 = PinButton(it.p, it.label, it.kind == "step" and it.extra or (it.kind == "turnin" and L["turn in the quest"] or L["pick up the quest"]), it.id) }
  end

  local sections = {
    { kind = "turnin", label = L["To turn in"], unit = L["quest"] },
    { kind = "step", label = L["Steps of quests in progress"], unit = L["step"] },
    { kind = "take", label = L["Available quests"], unit = L["quest"] },
  }
  for _, sec in ipairs(sections) do
    local list = {}
    for _, it in ipairs(found) do
      if it.kind == sec.kind and matches(it) then list[#list + 1] = it end
    end
    if #list > 0 then
      items[#items + 1] = { header = true, kind = sec.kind, key = sec.kind, label = sec.label .. " - " .. Plural(#list, sec.unit) }
      for _, it in ipairs(list) do items[#items + 1] = row(it, false) end
    end
  end

  if #found == 0 then
    items[#items + 1] = { text = nearRadius == "zone" and L["Nothing to do in the current zone."] or L["Nothing to do within this radius. Try a larger radius or \"Current zone\"."] }
  end
  if #nearQuery > 0 or next(nearStates) ~= nil then
    local any = false
    for _, it in ipairs(items) do if it.header then any = true break end end
    if not any then items[#items + 1] = { text = L["No results for this search or these filters."] } end
  end
  RenderList(panel, "near", items, #nearQuery > 0 or next(nearStates) ~= nil)
end

---------------------------------------------------------------------------
-- Roadbook checkpoints: focus on the next step from a floating button
---------------------------------------------------------------------------
local CP = {} -- Roadbook checkpoints (a table to stay under the local variables limit)
CP.lastPlan = nil -- steps of the last computed plan (without the starting point)

-- Escorts --------------------------------------------------------------------
K.ESCORT_ICON = "|TInterface\\Icons\\Ability_Warrior_DefensiveStance:14:14|t"

function CP.IsFailed(id)
  return id and IsInLog(id) and C_QuestLog.IsFailed and C_QuestLog.IsFailed(id) or false
end

-- Escorted NPC: the quest giver (escorts start where they are picked up).
function CP.EscortNpc(task)
  local n = task.starter and (task.starter:match("^(.-) %- ") or task.starter)
  if n then return n end
  local by = task.id and QGet(QDB.Quest, task.id, "startedBy")
  local npc = type(by) == "table" and type(by[1]) == "table" and by[1][1]
  return npc and QGet(QDB.Npc, npc, "name") or L["the NPC"]
end

-- Failed escort (NPC dead, too far): the pick-up step becomes the focus again, the
-- quest has to be abandoned and picked up again.
function CP.EscortFailed(s)
  if CP.escortFailNotified == s then return end
  CP.escortFailNotified = s
  local take = s.task.stops and s.task.stops[1]
  Print(Color("ff6060", L["Escort failed: "]) .. (s.task.title or "?") ..
    L[". Abandon the quest, then pick it up again from "] .. CP.EscortNpc(s.task) .. ".")
  if take and take.kind == "take" then
    Geo.MarkDone(take, false)
    CP.FocusStep(take)
  else
    CP.RefreshButton()
  end
end

function CP.StepPinLabel(s)
  if s.kind == "fm" then return L["activate the flight master"] end
  if s.kind == "bind" then return L["bind the hearthstone"] end
  if s.kind == "hearth" then return L["hearthstone"] end
  if s.kind == "travel" then return L["transport"] end
  if s.kind == "take" then return L["pick up the quest"] end
  if s.kind == "obj" then return s.r and s.r.tg.name or L["objective"] end
  return L["turn in the quest"]
end

function CP.StepText(s)
  if s.kind == "fm" or s.kind == "bind" then return (s.task.title or "?") .. " (" .. (s.task.npc or "?") .. ")" end
  if s.kind == "hearth" or s.kind == "travel" then return s.task.title or "?" end
  local tag = (s.escort and L["Escort"]) or (s.kind == "take" and L["Pick up"]) or (s.kind == "obj" and L["Objective"]) or L["Turn in"]
  local extra = s.kind == "obj" and s.r and (L[": "] .. (s.r.tg.name or L["objective"]) .. L[" x"] .. s.r.count) or ""
  return tag .. " - " .. (s.task.title or "?") .. extra
end

-- Roadbook focus, kept in memory separately from the map pin: the game clears its pin when
-- you reach it (e.g. at the monster area), yet the focus must stay active.
-- It is not kept across /reload.
function CP.FocusRecord()
  return CP.focusRec
end

function CP.ClearFocus()
  CP.focusRec, CP.focused = nil, nil
  if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
end

function CP.IsStepFocused(s)
  local rec = CP.focusRec
  return rec and s and s.task and s.p and rec.questId == s.task.id and rec.area == s.p.area
    and rec.label == CP.StepPinLabel(s)
    and math.abs((rec.mx or -1) - (s.p.mx or -2)) < 0.05 and math.abs((rec.my or -1) - (s.p.my or -2)) < 0.05 or false
end

-- The map pin currently sits on this step.
function CP.CurrentFocus()
  local s = CP.focused
  if s and CP.IsStepFocused(s) then return s end
  return nil
end

function CP.FocusStep(s)
  if s.escort then CP.escortFailNotified = nil end -- escort (re)started: a new failure is reported
  CP.focused = s
  CP.focusRec = { questId = s.task.id, label = CP.StepPinLabel(s), area = s.p.area, mx = s.p.mx, my = s.p.my,
    progress = CP.Progress(s.task.id) }
  local qid = s.task.id
  if qid and IsInLog(qid) then WatchOnly(qid) end
  PinPoint(s.p, s.task.title, CP.StepPinLabel(s), qid)
  CP.RefreshButton()
  CP.WatchTransport(s)
end

function CP.FocusedStepIndex(plan)
  for i, st in ipairs(plan or {}) do
    if CP.IsStepFocused(st) then return i end
  end
  return nil
end

-- Validate the checkpoint: focus on the next step of the saved Roadbook if the current one is
-- done in the game (see CP.ValidateUnsafe).
---------------------------------------------------------------------------
-- Saved Roadbook: once computed, the plan no longer changes until its end, or until a
-- recompute request (duration change, Recalculate button, Ctrl-click on the button).
---------------------------------------------------------------------------
function Geo.CopyPoint(p)
  if not p then return nil end
  return { c = p.c, x = p.x, y = p.y, area = p.area, ui = p.ui, mx = p.mx, my = p.my, zoneName = p.zoneName,
    teleport = p.teleport, instance = p.instance }
end

function Geo.SerializeStep(st)
  local t = st.task or {}
  return { kind = st.kind, at = st.at, xp = st.xp, work = st.work, gain = st.gain, spots = st.spots, quick = st.quick,
    escort = st.escort, glue = st.glue,
    spotN = st.spot and st.spot.n, done = st.done, p = Geo.CopyPoint(st.p),
    objName = st.r and st.r.tg and st.r.tg.name, objKind = st.r and st.r.tg and st.r.tg.kind, count = st.r and st.r.count,
    first = t.stops and t.stops[1] == st or nil,
    task = { id = t.id, title = t.title, level = t.level, xp = t.xp, starter = t.starter, reqLevel = t.reqLevel,
      depTitle = t.dep and t.dep.title, tags = t.tags, npc = t.npc, mode = t.mode, from = t.from, dest = t.dest,
      destP = Geo.CopyPoint(t.destP), kind = t.kind, quick = t.quick } }
end

function Geo.DeserializeStep(rec, tasks)
  local tr = rec.task or {}
  local key = tostring(tr.id) .. "|" .. tostring(tr.title) .. "|" .. tostring(rec.kind == "travel" and rec.at or "")
  local task = tasks[key]
  if not task then
    task = { id = tr.id, title = tr.title, level = tr.level, xp = tr.xp, starter = tr.starter, reqLevel = tr.reqLevel,
      dep = tr.depTitle and { title = tr.depTitle } or nil, tags = tr.tags, npc = tr.npc, mode = tr.mode,
      from = tr.from, dest = tr.dest, destP = tr.destP, kind = tr.kind, quick = tr.quick, stops = {} }
    tasks[key] = task
  end
  local st = { kind = rec.kind, at = rec.at, xp = rec.xp, work = rec.work or 0, gain = rec.gain, spots = rec.spots, quick = rec.quick,
    escort = rec.escort, glue = rec.glue,
    spot = rec.spotN and { n = rec.spotN } or nil, done = rec.done, p = rec.p or {}, task = task,
    r = rec.objName and { tg = { name = rec.objName, kind = rec.objKind }, count = rec.count } or nil }
  if rec.first then task.stops[1] = st end
  return st
end

function Geo.FrozenStore()
  local st = Settings()
  st.roadbook = st.roadbook or {}
  return st.roadbook
end

-- Saves a plan that was just computed.
function Geo.Freeze(route, info)
  local steps = {}
  for i = 2, #route do steps[#steps + 1] = Geo.SerializeStep(route[i]) end
  local slim = { count = info.count, xp = info.xp, total = info.total, mobXP = info.mobXP, levels = info.levels,
    speed = info.speed, plevel = info.plevel, skipped = info.skipped, later = info.later, taxi = info.net and info.net.taxi }
  Geo.FrozenStore()[CharKey()] = { horizon = xpHorizon, saved = date and date("%H:%M") or "", start = Geo.CopyPoint(route[1].p),
    steps = steps, info = slim }
  Geo.frozen = { route = route, info = info }
  CP.lastPlan = {}
  for i = 2, #route do CP.lastPlan[#CP.lastPlan + 1] = route[i] end
end

-- Saved plan (reloaded after a /reload), or nil.
function Geo.Frozen()
  if Geo.frozen then return Geo.frozen end
  local rec = Geo.FrozenStore()[CharKey()]
  if not (rec and rec.steps and #rec.steps > 0) then return nil end
  -- After a /reload, the QuestieDB map mappings are not loaded yet.
  if not (QDB.ok and GeoReady()) then return nil end
  local route, tasks = { { kind = "start", p = rec.start or {}, work = 0 } }, {}
  for _, r in ipairs(rec.steps) do route[#route + 1] = Geo.DeserializeStep(r, tasks) end
  local info = {}
  for k, v in pairs(rec.info or {}) do info[k] = v end
  info.net = BuildNetwork(info.speed or TravelSpeed())
  info.net.taxi = TaxiCount()
  Geo.frozen = { route = route, info = info }
  if rec.horizon then xpHorizon = rec.horizon end
  CP.lastPlan = {}
  for i = 2, #route do CP.lastPlan[#CP.lastPlan + 1] = route[i] end
  return Geo.frozen
end

function Geo.ClearFrozen()
  Geo.frozen = nil
  Geo.FrozenStore()[CharKey()] = nil
  Geo.planCache = nil
end

-- Marks a step as done (and saves it).
function Geo.MarkDone(st, value)
  if value == nil then value = true end
  st.done = value or nil
  local fz = Geo.frozen
  local rec = Geo.FrozenStore()[CharKey()]
  if fz and rec and rec.steps then
    for i = 2, #fz.route do
      if fz.route[i] == st and rec.steps[i - 1] then rec.steps[i - 1].done = value or nil end
    end
  end
end

-- Quick wins: a quest from the log that became ready to turn in during the Roadbook, whose NPC is
-- next to an upcoming step (or to you), is added to the saved plan right after that step.
function Geo.InjectQuickWins()
  local fz = Geo.Frozen()
  if not (fz and QDB.ok) then return 0 end
  local route = fz.route
  local rec = Geo.FrozenStore()[CharKey()]
  local pending = {}
  for i = 2, #route do
    local st = route[i]
    if st.kind == "turnin" and st.task and st.task.id and not CP.StepDone(st) then pending[st.task.id] = true end
  end
  local cur = CP.CurrentFocus()
  local curI = 2
  for i = 2, #route do if route[i] == cur then curI = i break end end
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  local pos = PlayerPos()
  local added, focusNew = 0, nil
  for _, q in ipairs(e and e.quests or {}) do
    if q.complete and not q.failed and not pending[q.id] and IsInLog(q.id)
      and (not C_QuestLog.IsComplete or C_QuestLog.IsComplete(q.id)) then
      local t = QuestTargets(q.id)
      if #t.finish > 0 and not AllInstance(t.finish) then
        local bestI, bestD, bestP
        if pos and not (route[curI] and route[curI].glue) then
          local f, d = Nearest(t.finish, pos)
          if d and d < K.QUICKWIN_RADIUS then bestI, bestD, bestP = curI - 1, d, f end
        end
        for i = curI, #route do
          local st = route[i]
          if st.p and st.p.c and not CP.StepDone(st) and not (route[i + 1] and route[i + 1].glue) then
            local f, d = Nearest(t.finish, st.p)
            if d and d < K.QUICKWIN_RADIUS and (not bestD or d < bestD) then bestI, bestD, bestP = i, d, f end
          end
        end
        if bestI then
          local task = { id = q.id, title = q.title, level = q.level, stops = {},
            xp = q.xp or DBXP(q.id, UnitLevel("player")) or 0 }
          local st = { kind = "turnin", p = bestP, work = K.OVERHEAD / 2, xp = task.xp, task = task, quick = true,
            at = route[math.max(bestI, 2)] and route[math.max(bestI, 2)].at or 0 }
          task.stops[1] = st
          table.insert(route, bestI + 1, st)
          if rec and rec.steps then table.insert(rec.steps, bestI, Geo.SerializeStep(st)) end
          if bestI + 1 <= curI then
            focusNew = st
            curI = curI + 1
          end
          pending[q.id] = true
          added = added + 1
          Print(L["Quick win added to the Roadbook: turn in \""] .. (q.title or "?") .. L["\" ("] .. PointText(bestP) .. ").")
        end
      end
    end
  end
  if added > 0 then
    CP.lastPlan = {}
    for i = 2, #route do CP.lastPlan[#CP.lastPlan + 1] = route[i] end
    if focusNew and cur then CP.FocusStep(focusNew) end
  end
  return added
end

-- Step already done: marked, or observed in the game (quest picked up, objective done, quest turned in…).
function CP.StepDone(st)
  if st.done then return true end
  local id = st.task and st.task.id
  if st.kind == "take" then
    if id and Geo.IsEscort(id) and CP.IsFailed(id) then return false end -- failed escort: pick it up again
    return id and (IsInLog(id) or IsCompleted(id)) or false
  end
  if st.kind == "turnin" then return id and IsCompleted(id) or false end
  if st.kind == "obj" then
    if not id then return false end
    if IsCompleted(id) then return true end
    if not IsInLog(id) then return false end
    if C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) then return true end
    local name = st.r and st.r.tg and st.r.tg.name
    if name then
      local lname = name:lower()
      for _, o in ipairs(GetObjectives(id)) do
        if o.text and o.text:lower():find(lname, 1, true) then return o.finished and true or false end
      end
    end
    return false
  end
  if st.kind == "fm" then
    for _, n in pairs(TaxiStore()) do
      local d = Dist(n, st.p)
      if d and d < K.FM_KNOWN_RADIUS then return true end
    end
  end
  return false
end

-- Computes a new Roadbook and saves it; cb(route) when done.
function Geo.Recompute(cb)
  Geo.ClearFrozen()
  Snapshot()
  if CP.checkpointButton and CP.checkpointButton.sub then CP.checkpointButton.sub:SetText(L["Computing the Roadbook…"]) end
  Geo.RequestPlan(xpHorizon, function(route, err, info)
    if route and #route >= 2 then Geo.Freeze(route, info) end
    if cb then cb(route, err, info) end
    if Refresh then C_Timer.After(0.1, Refresh) end
  end, true)
end

-- Focuses the first step of the saved Roadbook that is not done yet.
-- At the end of the plan, a new Roadbook is computed.
function CP.FocusNext(silent, after)
  local fz = Geo.Frozen()
  if fz then
    -- Start from the step that was just done, then wrap around from the beginning of the plan.
    local start = 2
    if after then
      for i = 2, #fz.route do if fz.route[i] == after then start = i + 1 break end end
    end
    local order = {}
    for i = start, #fz.route do order[#order + 1] = i end
    for i = 2, math.min(start - 1, #fz.route) do order[#order + 1] = i end
    for _, i in ipairs(order) do
      local st = fz.route[i]
      if not CP.StepDone(st) then
        CP.FocusStep(st)
        if not silent then Print(L["Focus: "] .. CP.StepText(st)) end
        if Refresh then C_Timer.After(0.2, Refresh) end
        return
      end
    end
    Print(L["Roadbook finished: computing a new Roadbook."])
  end
  CP.Recompute()
end

-- Full recompute (Ctrl-click on the button, or end of the Roadbook) then focus on the first step.
function CP.Recompute(attempt)
  if not (QDB.ok and GeoReady()) then
    Print(L["Cannot compute: the Roadbook requires QuestieDB."])
    return
  end
  -- Available quests change after a pick-up or turn-in: wait for their scan to finish.
  if scan.running or scan.dirty or not scan.entries then
    if not scan.running then StartScan() end
    attempt = (attempt or 0) + 1
    if attempt > 40 then
      Print(L["Quest scan is taking too long: try again in a moment."])
      return
    end
    C_Timer.After(0.5, function() CP.Recompute(attempt) end)
    return
  end
  Geo.Recompute(function(route, err)
    if not route or #route < 2 then
      Print(err or L["The Roadbook is empty: no step to follow."])
      CP.RefreshButton()
      return
    end
    local first
    for i = 2, #route do
      if not CP.StepDone(route[i]) then first = route[i] break end
    end
    if first then
      CP.FocusStep(first)
      Print(L["New Roadbook. Active step: "] .. CP.StepText(first))
    end
  end)
end

-- Click on the button: focus the next step only if the current one is done in the
-- game; Shift-click: skip the current step even if it is not done.
function CP.ValidateUnsafe(recompute)
  if recompute or not Geo.Frozen() then
    CP.Recompute()
    return
  end
  local cur = CP.CurrentFocus()
  if cur and not CP.StepDone(cur) then
    CP.FocusStep(cur) -- tracking active: the pin is placed on the current step again
    Print(L["Focus: "] .. CP.StepText(cur))
    return
  end
  if cur then Geo.MarkDone(cur) end
  CP.FocusNext(false, cur) -- no tracking yet, or step done: first step left to do
end

-- Shift-click: stops following the objective (focus, addon pin and compass); click resumes it.
function CP.StopTracking()
  if not CP.CurrentFocus() then
    Print(L["No objective tracked."])
    return
  end
  CP.ClearFocus()
  ClearPin()
  CP.RefreshButton()
  Print(L["Objective tracking stopped: click the Objective button to resume it."])
  if Refresh then Refresh() end
end

-- Ctrl-Alt-click: removes the current step. A quest step removes the whole quest (confirmation,
-- then a new Roadbook); any other step (flight, hearthstone…) is skipped.
function CP.RemoveCurrentStep()
  local cur = CP.CurrentFocus()
  if not cur then
    Print(L["No objective tracked."])
    return
  end
  if cur.task and cur.task.id then
    CP.AskExclude(cur)
    return
  end
  Print(L["Step skipped: "] .. CP.StepText(cur))
  Geo.MarkDone(cur)
  CP.FocusNext(false, cur)
end

-- Quest removed from the Roadbook (badly defined, not found…): excluded, then a new Roadbook.
function CP.ExcludeQuest(id, title)
  if not id then return end
  Settings().excluded[id] = title or true
  Geo.planCache = nil
  Print(L["Quest removed from the Roadbook: "] .. (title or tostring(id)) .. L[". It can be added back in the options."])
  CP.Recompute()
end

function CP.AskExclude(s)
  local id = s and s.task and s.task.id
  if not id then return end
  StaticPopup_Show("FQP_EXCLUDE", s.task.title or tostring(id), nil, { id = id, title = s.task.title })
end

StaticPopupDialogs["FQP_EXCLUDE"] = {
  text = L["Remove the quest \"%s\" from the Roadbook and compute a new one?\n\nUseful when a quest is badly defined or cannot be found. It can be added back in the options."],
  button1 = L["Remove"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, data) if data then CP.ExcludeQuest(data.id, data.title) end end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

function CP.Validate(recompute)
  local ok, err = xpcall(function() CP.ValidateUnsafe(recompute) end, function(e)
    return tostring(e) .. (debugstack and ("\n" .. debugstack(2, 3, 0)) or "")
  end)
  if not ok then Print(L["|cffff6060Error while validating the checkpoint|r (copy it to report it):\n"] .. err) end
end

-- Progress of a quest from the log: finished objectives (+1 if the quest is complete).
function CP.Progress(qid)
  if not (qid and IsInLog(qid)) then return 0 end
  local n = 0
  for _, o in ipairs(GetObjectives(qid)) do if o.finished then n = n + 1 end end
  if C_QuestLog.IsComplete and C_QuestLog.IsComplete(qid) then n = n + 1 end
  return n
end

-- Automatic update: when the focused Roadbook step is done
-- (quest picked up, objective done, quest turned in, flight master activated), the step is
-- marked as done and the focus moves to the next step of the saved Roadbook.
function CP.AutoUpdate(reason)
  if CP.autoPending then return end
  CP.autoPending = true
  C_Timer.After(1, function()
    CP.autoPending = nil
    Print(reason .. L[": next Roadbook step."])
    local cur = CP.CurrentFocus()
    if cur then Geo.MarkDone(cur) end
    local ok, err = pcall(CP.FocusNext, true, cur)
    if not ok then Print(L["Focus update error: "] .. tostring(err)) end
  end)
end

-- Zeppelin / boat: arrived when near the destination dock (the continent change
-- happens at sea, during the loading screen: it is not enough).
K.ARRIVAL_RADIUS = 300
function CP.CheckArrival(s)
  local dest = s.task.destP
  local pos = PlayerPos()
  if not (dest and pos) then return end
  local d = Dist(pos, dest)
  if d and d < K.ARRIVAL_RADIUS then
    if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
    CP.AutoUpdate(L["Arrival of the "] .. (K.MODE_NAME[s.task.mode] or s.task.mode or L["transport"]))
  end
end

-- Watches the position every 2 s while a zeppelin / boat step has the focus.
function CP.WatchTransport(s)
  if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
  if not (s.kind == "travel" and s.task.mode ~= "vol" and C_Timer.NewTicker) then return end
  CP.transportTicker = C_Timer.NewTicker(2, function()
    if not (CP.focused == s and CP.IsStepFocused(s)) then
      if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
      return
    end
    pcall(CP.OnGameEvent, "FQP_TRANSPORT_TICK")
  end)
end

-- In flight: the focus moves right away to the next step (no recompute from the air).
function CP.AdvanceFocus()
  local cur = CP.CurrentFocus()
  if cur then Geo.MarkDone(cur) end
  CP.FocusNext(false, cur)
end

function CP.OnGameEvent(event, a1, a2)
  if event == "QUEST_LOG_UPDATE" and CP.checkpointButton then C_Timer.After(0.2, function() pcall(CP.RefreshButton) end) end
  if (event == "QUEST_LOG_UPDATE" or event == "ZONE_CHANGED_NEW_AREA") and not CP.quickPending and Geo.frozen then
    CP.quickPending = true
    C_Timer.After(2.5, function() -- after the quest log capture (2 s)
      CP.quickPending = nil
      local ok, n = pcall(Geo.InjectQuickWins)
      if ok and n and n > 0 and Refresh then Refresh() end
    end)
  end
  -- Landing after a flight taken during a focus.
  if event == "FQP_TAXI_LANDED" and CP.flying then
    CP.flying = nil -- the focus already moved to the next step at take-off
    return
  end
  local s = CP.CurrentFocus()
  if not s then return end
  if event == "FQP_TAXI_TAKEOFF" then CP.flying = true end
  local qid = s.task.id
  if s.escort and event == "QUEST_LOG_UPDATE" and CP.IsFailed(qid) then
    CP.EscortFailed(s)
    return
  end
  if s.kind == "bind" then
    if event == "HEARTHSTONE_BOUND" then CP.AutoUpdate(L["Hearthstone bound"]) end
  elseif s.kind == "hearth" then
    if event == "FQP_HEARTH_ARRIVED" then CP.AutoUpdate(L["Back by hearthstone"]) end
  elseif s.kind == "travel" then
    if event == "FQP_TAXI_TAKEOFF" then
      CP.AdvanceFocus()
    elseif s.task.mode ~= "vol" and (event == "ZONE_CHANGED_NEW_AREA" or event == "FQP_TRANSPORT_TICK") then
      CP.CheckArrival(s)
    end
  elseif s.kind == "fm" then
    if event == "TAXIMAP_OPENED" then CP.AutoUpdate(L["Flight master activated"]) end
  elseif (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and s.kind ~= "take" then
    if qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(event == "QUEST_TURNED_IN" and L["Quest turned in"] or L["Quest removed"]) end
  elseif s.kind == "take" then
    if event == "QUEST_ACCEPTED" and qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(L["Quest picked up"]) end
  elseif s.kind == "obj" then
    if event == "QUEST_LOG_UPDATE" and qid then
      local now = CP.Progress(qid)
      local rec = CP.FocusRecord()
      if rec and now > (rec.progress or 0) then
        rec.progress = now
        CP.AutoUpdate(L["Objective completed"])
      elseif rec and now < (rec.progress or 0) then
        rec.progress = now -- item destroyed / given back: follow the new value
      end
    end
  end
end

-- Summary of the focused step, for the floating button: title + detail.
function CP.StepSummary(s)
  local task = s.task
  local function nameOnly(t) return t and (t:match("^(.-) %- ") or t) or nil end
  local place = PointText(s.p)
  if s.kind == "bind" then
    return "|TInterface\\Minimap\\Tracking\\Innkeeper:14:14|t " .. (task.title or "?"),
      L["Talk to "] .. (task.npc or "?") .. " · " .. place
  elseif s.kind == "hearth" then
    return "|TInterface\\Icons\\INV_Misc_Rune_01:14:14|t " .. (task.title or "?"),
      L["Use the hearthstone · saves ~"] .. FormatTime(s.gain or 0)
  elseif s.kind == "travel" then
    return "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t " .. (task.mode == "vol" and L["Flight"] or K.MODE_NAME[task.mode] or task.mode or L["Transport"]) ..
      L[" to "] .. (task.dest or "?"), L["Departure: "] .. (task.from or "?") .. " · " .. place
  elseif s.kind == "fm" then
    return "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t " .. (task.title or L["Flight Master"]),
      L["Talk to "] .. (task.npc or "?") .. " · " .. place
  elseif s.escort and CP.IsFailed(task.id) then
    return K.ESCORT_ICON .. " " .. (task.title or "?"),
      Color("ff6060", L["Escort failed: abandon the quest and pick it up again"])
  elseif s.escort then
    local dest = s.kind == "turnin" and (L[", then turn in to "] .. (nameOnly(TurnInText(task.id)) or "?")) or ""
    return K.ESCORT_ICON .. " " .. L["Escort: "] .. (task.title or "?"),
      L["Stay close to "] .. CP.EscortNpc(task) .. dest .. " · " .. place
  elseif s.kind == "take" then
    local esc = Geo.IsEscort(task.id) and (" · " .. Color("ffb060", L["escort"])) or ""
    if CP.IsFailed(task.id) then esc = " · " .. Color("ff6060", L["failed: abandon it first"]) end
    return ICON.available .. " " .. (task.title or "?"),
      L["Pick up from "] .. (nameOnly(task.starter) or "?") .. " · " .. place .. esc
  elseif s.kind == "obj" then
    local name = s.r and s.r.tg.name or L["objective"]
    local prog = "x" .. (s.r and s.r.count or "?")
    local lname = name:lower()
    for _, o in ipairs(task.id and IsInLog(task.id) and GetObjectives(task.id) or {}) do
      if o.text and o.need and o.text:lower():find(lname, 1, true) then
        prog = (o.have or 0) .. "/" .. o.need
        break
      end
    end
    local multi = (s.spots and s.spots > 1) and (L[" · multiple spots ("] .. s.spots .. ")") or ""
    return ICON.inprogress .. " " .. (task.title or "?"), name .. " " .. prog .. " · " .. place .. multi
  end
  return ICON.turnin .. " " .. (task.title or "?"),
    L["Turn in to "] .. (nameOnly(TurnInText(task.id)) or "?") .. " · " .. place
end

function CP.RefreshButton()
  local b = CP.checkpointButton
  if not (b and b.title) then return end
  local s = CP.CurrentFocus()
  if s then
    local t, d = CP.StepSummary(s)
    -- Quest step: white title, then the same badges as in the tabs (colored level, elite, types).
    if s.task and s.task.id then t = Color("ffffff", t) .. Geo.QuestBadges({ id = s.task.id, level = s.task.level }) end
    b.title:SetText(t)
    b.sub:SetText(d)
    b.current = s
  else
    b.title:SetText(L["Objective"])
    b.sub:SetText(L["No objective tracked · click to follow it"])
    b.current = nil
  end
  -- Width fitted to the text, within reasonable limits.
  local w = math.max(b.title:GetStringWidth() or 0, b.sub:GetStringWidth() or 0)
  b:SetWidth(math.min(math.max(47 + w + 14, 214), 480))
  b.compassTarget = CP.CompassTarget()
end

-- Compass target, in world coordinates: the active pin, otherwise the focused step.
function CP.CompassTarget()
  if Settings().compass == false then return nil end
  local s = CP.checkpointButton and CP.checkpointButton.current
  if not s then return nil end -- no objective followed: no compass
  local pin = ActivePin()
  if pin and pin.ui and pin.x and C_Map.GetWorldPosFromMapPos and CreateVector2D then
    local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, pin.ui, CreateVector2D(pin.x, pin.y))
    if ok and cont and w then
      local x, y = w:GetXY()
      return { c = cont, x = x, y = y }
    end
  end
  if s.p and s.p.c and s.p.x then return s.p end
  return nil
end

-- Rotates the arrow every frame. World coordinates: x towards the north, y towards
-- the west; GetPlayerFacing: 0 = north, counterclockwise, like SetRotation.
function CP.UpdateCompass(b)
  local t = b.compassTarget
  local me = t and PlayerPos()
  local facing = me and GetPlayerFacing and GetPlayerFacing()
  local d = facing and Dist(me, t) -- nil on another continent or in an instance
  if not d then
    b.arrow:Hide()
    b.dist:Hide()
    b.icon:Show()
    return
  end
  b.icon:Hide()
  b.arrow:Show()
  b.dist:Show()
  b.dist:SetText(d < 1000 and string.format(L["%d yd"], d) or string.format(L["%.1f kyd"], d / 1000))
  if d < 5 then
    b.arrow:SetRotation(0)
    b.arrow:SetVertexColor(0.25, 1, 0.25) -- arrived: green
  else
    b.arrow:SetRotation(math.atan2(t.y - me.y, t.x - me.x) - facing)
    b.arrow:SetVertexColor(1, 0.82, 0)
  end
end

-- Centers the Objective button horizontally on the screen, keeping its height.
function CP.CenterCheckpointButton()
  CP.CreateCheckpointButton()
  local b = CP.checkpointButton
  if not b then return end
  local _, cy = b:GetCenter()
  if not cy then return end
  local y = cy * b:GetEffectiveScale() / UIParent:GetEffectiveScale() - UIParent:GetHeight() / 2
  b:ClearAllPoints()
  b:SetPoint("CENTER", UIParent, "CENTER", 0, y)
  Settings().checkpointPos = { "CENTER", 0, y }
end

function CP.UpdateCheckpointButton()
  if not CP.checkpointButton then return end
  CP.checkpointButton:SetShown(CP.CHECKPOINT_TOGGLE.get())
end

function CP.CreateCheckpointButton()
  if CP.checkpointButton then return end
  local b = CreateFrame("Button", "ForeverQuestPlannerCheckpoint", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  b:SetSize(214, 44)
  -- Dark tooltip-like frame, golden border.
  local GOLD = { 1, 0.82, 0 }
  if b.SetBackdrop then
    b:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 14,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    b:SetBackdropColor(0.09, 0.07, 0.04, 0.92)
    b:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.85)
  else
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.09, 0.07, 0.04, 0.92)
  end
  -- Framed icon, anchored at the top AND bottom to stay vertically centered.
  local frameTex = b:CreateTexture(nil, "ARTWORK")
  frameTex:SetWidth(32)
  local function PlaceIcon(dx, dy)
    frameTex:ClearAllPoints()
    frameTex:SetPoint("TOPLEFT", b, "TOPLEFT", 7 + dx, -6 + dy)
    frameTex:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 7 + dx, 6 + dy)
  end
  PlaceIcon(0, 0)
  frameTex:SetColorTexture(0, 0, 0, 0.8)
  local icon = b:CreateTexture(nil, "OVERLAY")
  icon:SetPoint("TOPLEFT", frameTex, "TOPLEFT", 1, -1)
  icon:SetPoint("BOTTOMRIGHT", frameTex, "BOTTOMRIGHT", -1, 1)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
  if icon.SetTexCoord then icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
  b.icon = icon
  -- Compass: arrow pointing at the active marker, with the distance below.
  local arrow = b:CreateTexture(nil, "OVERLAY")
  arrow:SetSize(30, 30)
  arrow:SetPoint("CENTER", frameTex, "CENTER", 0, 3)
  arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
  arrow:SetVertexColor(1, 0.82, 0)
  arrow:Hide()
  local dist = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dist:SetPoint("BOTTOM", frameTex, "BOTTOM", 0, 1)
  dist:SetScale(0.8)
  dist:Hide()
  b.arrow, b.dist = arrow, dist
  local elapsed = 1
  b:SetScript("OnUpdate", function(_, e)
    elapsed = elapsed + e
    if elapsed >= 0.5 then -- target and player zone: twice per second is enough
      elapsed = 0
      b.compassTarget = CP.CompassTarget()
    end
    CP.UpdateCompass(b)
  end)
  -- Golden title + gray subtitle.
  local title = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("BOTTOMLEFT", b, "LEFT", 47, 1)
  title:SetPoint("RIGHT", b, "RIGHT", -8, 0)
  title:SetJustifyH("LEFT")
  title:SetText(L["Objective"])
  local sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", b, "LEFT", 47, -2)
  sub:SetPoint("RIGHT", b, "RIGHT", -8, 0)
  sub:SetJustifyH("LEFT")
  sub:SetTextColor(0.75, 0.75, 0.75)
  sub:SetText(L["No objective tracked · click to follow it"])
  title:SetWordWrap(false)
  sub:SetWordWrap(false)
  b.label, b.title, b.sub = L["Objective"], title, sub
  -- Hover: soft highlight and lighter border; click: slight press.
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", 4, -4)
  hl:SetPoint("BOTTOMRIGHT", -4, 4)
  hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  hl:SetBlendMode("ADD")
  hl:SetAlpha(0.35)
  b:SetScript("OnMouseDown", function() PlaceIcon(1, -1) end)
  b:SetScript("OnMouseUp", function() PlaceIcon(0, 0) end)
  b.HoverIn = function()
    if b.SetBackdropBorderColor then b:SetBackdropBorderColor(1, 0.95, 0.6, 1) end
  end
  b.HoverOut = function()
    if b.SetBackdropBorderColor then b:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.85) end
  end
  b:SetFrameStrata("MEDIUM")
  b:SetMovable(true)
  b:SetClampedToScreen(true)
  b:RegisterForDrag("LeftButton")
  local pos = Settings().checkpointPos
  if pos then b:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3]) else b:SetPoint("CENTER", UIParent, "CENTER", 0, -220) end
  b:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown and IsShiftKeyDown() then self:StartMoving() end -- Shift + drag: move the button
  end)
  b:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self.dragEnd = GetTime and GetTime() or 0 -- the release of a Shift-drag must not count as a Shift-click
    local point, _, _, x, y = self:GetPoint()
    Settings().checkpointPos = { point, x, y }
  end)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(_, button)
    if b.dragEnd and GetTime and GetTime() - b.dragEnd < 0.3 then return end
    if button == "RightButton" then
      if IsShiftKeyDown and IsShiftKeyDown() then
        CP.CenterCheckpointButton() -- Shift-right-click: center the button horizontally
      elseif CP.OpenWindow then
        CP.OpenWindow("xp") -- right-click: window opened on the Roadbook
      end
    else
      local alt = IsAltKeyDown and IsAltKeyDown()
      local ctrl = IsControlKeyDown and IsControlKeyDown()
      local shift = IsShiftKeyDown and IsShiftKeyDown()
      if alt and ctrl then
        CP.RemoveCurrentStep()   -- Ctrl-Alt-click: remove the step from the Roadbook
      elseif alt then
        CP.Validate(true)        -- Alt-click: compute a new Roadbook
      elseif shift then
        CP.StopTracking()        -- Shift-click: stop following the objective
      else
        CP.Validate(false)       -- click: follow the objective
      end
    end
  end)
  b:SetScript("OnEnter", function(self)
    if self.HoverIn then self.HoverIn() end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Forever Quest Planner - Roadbook"])
    if self.current then
      GameTooltip:AddLine(L["Current step: "] .. CP.StepText(self.current), 1, 1, 1, true)
    else
      GameTooltip:AddLine(L["No Roadbook step has the focus."], 1, 1, 1, true)
    end
    GameTooltip:AddLine(L["The focus moves to the next step on its own when this one is done."], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L["Click: follow the objective (step to do, pin, compass)."], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L["Shift-click: stop following the objective."], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L["Alt-click: compute a new Roadbook."], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L["Ctrl-Alt-click: remove the step from the Roadbook (a quest: the whole quest, then a new Roadbook)."], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L["Shift-right-click: center the button horizontally."], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L["Right-click: open the Roadbook."], 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(L["Shift-drag: move the button."], 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    if self.HoverOut then self.HoverOut() end
    GameTooltip:Hide()
  end)
  CP.checkpointButton = b
  CP.UpdateCheckpointButton()
  CP.RefreshButton()
end

CP.CHECKPOINT_TOGGLE = {
  label = L["Show objective"],
  get = function() return Settings().checkpoint ~= false end, -- shown by default
  set = function(v)
    Settings().checkpoint = v and true or false
    CP.CreateCheckpointButton()
    CP.UpdateCheckpointButton()
  end,
}

local function RenderXP()
  local panel = panels.xp
  if not QDB.ok then
    ShowMessage(panel, "xp", L["QuestieDB is not loaded: this tab needs the locations and XP from its database."])
    return
  end
  if not GeoReady() then
    ShowMessage(panel, "xp", L["Unable to convert QuestieDB positions to this client's map."])
    return
  end
  if scan.dirty or not scan.entries then
    if not scan.running then StartScan() end
    if scan.running or scan.dirty then
      ShowMessage(panel, "xp", L["Scanning available quests…"])
      return
    end
  end

  -- Saved Roadbook: it no longer changes until its end or a recompute request.
  local fz = Geo.Frozen()
  if not fz then
    if Geo.co then
      ShowMessage(panel, "xp", L["Computing the Roadbook, please wait…"])
      return
    end
    local last = Geo.planCache
    if last and last.err and not last.route and Geo.lastErrShown ~= last then
      Geo.lastErrShown = last
      RenderList(panel, "xp", { { text = Color("ff6060", last.err),
        b3 = { text = L["Recalculate"], fn = function() CP.Recompute() end } } })
      return
    end
    Geo.Recompute()
    if not Geo.Frozen() then
      ShowMessage(panel, "xp", L["Computing the Roadbook, please wait…"])
      return
    end
    fz = Geo.Frozen()
  end
  pcall(Geo.InjectQuickWins)
  local route, info = fz.route, fz.info
  local doneCount = 0
  for i = 2, #route do if CP.StepDone(route[i]) then doneCount = doneCount + 1 end end
  if doneCount >= #route - 1 then
    Geo.Recompute()
    ShowMessage(panel, "xp", L["Roadbook finished: computing a new Roadbook…"])
    return
  end
  local frozenRec = Geo.FrozenStore()[CharKey()]

  -- Compact header: plan, level, travel and hearthstone in three short lines.
  local need = (UnitXPMax and UnitXP) and (UnitXPMax("player") - UnitXP("player")) or nil
  local sep = Color("777777", "  ·  ")
  local l1 = { Color("ffffff", Plural(info.count, L["quest"]) .. " · " .. FormatNumber(info.xp) .. " XP") }
  if info.mobXP and info.mobXP > 0 then l1[#l1 + 1] = L["monsters: "] .. FormatNumber(info.mobXP) .. " XP" end
  l1[#l1 + 1] = "~" .. FormatTime(info.total) .. " · ~" ..
    (info.total > 0 and FormatNumber(info.xp / info.total * 3600) or "0") .. " XP/h"
  local l2 = {}
  if info.levels then
    local lEnd, l0 = info.levels[#info.levels], info.levels[1]
    l2[#l2 + 1] = L["Level "] .. l0 .. (lEnd > l0 and (" -> " .. lEnd) or "")
  end
  if need then l2[#l2 + 1] = L["next level in "] .. FormatNumber(need) .. " XP" end
  l2[#l2 + 1] = Color("ffd100", string.format(L["%d/%d steps done"], doneCount, #route - 1) ..
    (frozenRec and frozenRec.saved and (L[" (saved at "] .. frozenRec.saved .. ")") or ""))
  local l3 = { string.format("%.1f m/s", info.speed) .. (Settings().mountSpeed and "" or L[" (on foot)"]) }
  if info.net.taxi == 0 then
    l3[#l3 + 1] = Color("ff8040", L["no flight master recorded (open a flight map)"])
  else
    l3[#l3 + 1] = string.format(L["%d flight master(s)"], info.net.taxi)
  end
  do
    local ready = Geo.HearthReady()
    local bindP, bindName = Geo.CurrentBind()
    if Settings().noHearth then
      l3[#l3 + 1] = L["hearthstone ignored"]
    elseif ready then
      local where = bindName or "?"
      if not bindP then where = where .. Color("ff8040", " (?)")
      elseif bindP.approx then where = where .. Color("ffd100", " (~)") end
      l3[#l3 + 1] = L["hearth: "] .. where .. " (" .. (ready > 0 and FormatTime(ready) or L["ready"]) .. ")"
    end
  end
  if info.skipped > 0 then l3[#l3 + 1] = Plural(info.skipped, L["quest"]) .. L[" ignored"] end
  local nEx = 0
  for _ in pairs(Settings().excluded) do nEx = nEx + 1 end
  if nEx > 0 then l3[#l3 + 1] = Plural(nEx, L["quest"]) .. L[" removed by you"] end
  local head = { table.concat(l1, sep), table.concat(l2, sep), table.concat(l3, sep) }
  local items = { { text = Color("aaaaaa", table.concat(head, "\n")) } }

  -- Split the plan into sections per zone, in route order.
  local net, plevel = info.net, info.plevel
  local segments, current = {}, nil
  for i = 2, #route do
    local s = route[i]
    local zone = s.p.instance or AreaName(s.p.area) or s.p.zoneName or "?"
    if not current or current.zone ~= zone then
      current = { zone = zone, steps = {}, xp = 0 }
      segments[#segments + 1] = current
    end
    current.steps[#current.steps + 1] = { s = s, prev = route[i - 1], i = i }
    if s.kind == "turnin" or s.kind == "obj" then current.xp = current.xp + (s.xp or 0) end
  end

  local n = 0
  for si, seg in ipairs(segments) do
    local last = seg.steps[#seg.steps].s
    local label = string.format("%d. %s - %s", si, seg.zone, Plural(#seg.steps, L["step"]))
    if seg.xp > 0 then label = label .. " - +" .. FormatNumber(seg.xp) .. " XP" end
    label = label .. L[" - until ~"] .. FormatTime(last.at)
    local segItems = {}
    for _, st in ipairs(seg.steps) do
      local s, task = st.s, st.s.task
      n = n + 1
      local function nameOnly(t) return t and (t:match("^(.-) %- ") or t) or nil end
      local kindLabel, action, pinLabel, spotLine
      if s.kind == "bind" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\Innkeeper:14:14|t" .. Color("ffb060", L["[Innkeeper]"])
        action = L["Talk to "] .. (task.npc or "?") .. L[" and choose \"Make this inn your home\" - "] .. PointText(s.p)
        pinLabel = L["bind the hearthstone"]
      elseif s.kind == "hearth" then
        kindLabel = "|TInterface\\Icons\\INV_Misc_Rune_01:14:14|t" .. Color("ffb060", L["[Hearthstone]"])
        action = L["Use the hearthstone - saves ~"] .. FormatTime(s.gain or 0)
        pinLabel = L["hearthstone"]
      elseif s.kind == "travel" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t" .. Color("80c0ff", L["[Transport]"])
        action = (task.mode == "vol" and (L["Talk to the flight master at "] .. (task.from or "?") .. L[", destination "] .. (task.dest or "?"))
          or (L["Board at "] .. (task.from or "?") .. L[" for "] .. (task.dest or "?"))) .. " - " .. PointText(s.p)
        pinLabel = L["transport"]
      elseif s.kind == "fm" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t" .. Color("c890ff", L["[Flight master]"])
        action = L["Talk to "] .. (task.npc or "?") .. L[" to activate the flight path - "] .. PointText(s.p)
        pinLabel = L["activate the flight master"]
      elseif s.escort then
        kindLabel = K.ESCORT_ICON .. Color("ffb060", L["[Escort]"])
        action = L["Stay close to "] .. CP.EscortNpc(task) ..
          (s.kind == "turnin" and (L[", then turn in to "] .. (nameOnly(TurnInText(task.id)) or "?")) or "") ..
          " - " .. PointText(s.p) .. Color("ffb060", "  ~" .. FormatTime(s.work or 0) .. L[", do not interrupt"])
        if s.kind == "turnin" then action = action .. Color("80c0ff", "  +" .. FormatNumber(task.xp or 0) .. " XP") end
        pinLabel = s.kind == "obj" and s.r and s.r.tg.name or L["turn in the quest"]
      elseif s.kind == "take" then
        kindLabel = Color("80c0ff", L["[Pick up]"])
        action = L["Pick up from "] .. (nameOnly(task.starter) or "?") .. " - " .. PointText(s.p)
        if Geo.IsEscort(task.id) then action = action .. Color("ffb060", L["  (escort: starts right after)"]) end
        if task.reqLevel then action = action .. Color("ffb060", L["  (level "] .. task.reqLevel .. L[" required)"]) end
        if task.dep then action = action .. Color("c0a0ff", L["  (follow-up of \""] .. (task.dep.title or "?") .. L["\")"]) end
        pinLabel = L["pick up the quest"]
      elseif s.kind == "obj" then
        kindLabel = Color("ffd100", L["[Objective]"])
        action = (s.r.tg.name or L["objective"]) .. L[" x"] .. s.r.count .. " - " .. PointText(s.p)
        if (s.xp or 0) > 0 then action = action .. Color("80c0ff", "  ~" .. FormatNumber(s.xp) .. L[" XP (monsters)"]) end
        if s.spots and s.spots > 1 then
          spotLine = Color("ffb060", L["Multiple spots ("] .. s.spots .. L["): chosen spot has "] ..
            (s.spot and s.spot.n or "?") .. L[" monsters, the most efficient (travel + density)"])
        elseif s.spot then
          action = action .. Color("888888", L["  (spot of "] .. s.spot.n .. L[" monsters)"])
        end
        pinLabel = s.r.tg.name
      else
        kindLabel = Color("40ff40", L["[Turn in]"])
        action = L["Turn in to "] .. (nameOnly(TurnInText(task.id)) or "?") .. " - " .. PointText(s.p) ..
          Color("80c0ff", "  +" .. FormatNumber(task.xp or 0) .. " XP")
        if s.quick then action = action .. Color("40ff40", L["  (quick win: added on the way)"])
        elseif task.quick then action = action .. Color("40ff40", L["  (ready to turn in)"]) end
        pinLabel = L["turn in the quest"]
      end
      -- Step icon (not the quest's current state): ! to pick up, gray ? objective, yellow ? to turn in.
      local icon = ""
      if s.kind == "take" then icon = ICON.available
      elseif s.kind == "obj" then icon = ICON.inprogress
      elseif s.kind == "turnin" then icon = ICON.turnin end
      if task.id and IsWatched(task.id) then icon = icon .. ICON.watched end
      if task.id and IsPinned(task.id) then icon = icon .. PinIcon() end
      if icon ~= "" then icon = icon .. " " end
      local text = string.format("  %d. %s%s %s%s", n, icon, kindLabel, task.title or "?",
        task.id and Geo.QuestBadges({ id = task.id, level = task.level }) or "")
      text = text .. "\n       " .. Color("bbbbbb", action) .. Color("888888", "  [" .. FormatTime(s.at) .. "]")
      if spotLine then text = text .. "\n       " .. spotLine end
      local way = s.kind ~= "hearth" and RouteText(st.prev.p, s.p, net, plevel) or nil
      if way and way ~= L["right here"] then text = text .. "\n       " .. Color("ffffff", L["Route: "]) .. way end
      if task.tags and task.stops and s == task.stops[1] then
        text = text .. "\n       " .. "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12:12|t " .. Color("ffd100", L["Priority: "] .. table.concat(task.tags, " · "))
      end
      local lvs = info.levels
      if lvs and st.i and lvs[st.i] and lvs[st.i - 1] and lvs[st.i] > lvs[st.i - 1] then
        text = text .. "\n       " .. Color("40ff40", L["---- level "] .. lvs[st.i] .. L[" reached (~"] .. FormatTime(s.at) .. ") ----")
      end
      if #xpQuery == 0 or MatchWords(Normalize(text), xpQuery) then
        -- Only button: remove the quest from the Roadbook. Tracking and the pin follow the
        -- floating Objective button (exclusive focus).
        local qid, step = task.id, s
        local exclude
        if CP.StepDone(step) then
          -- step done: checked, no button
          text = text:gsub("^  (%d+%. )", "  %1|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t" .. Color("40ff40", L["[Done] "]), 1)
        elseif qid then
          exclude = { text = L["Remove from the Roadbook"], fn = function() CP.AskExclude(step) end }
        end
        segItems[#segItems + 1] = { text = text, b3 = exclude, questID = task.id }
      end
    end
    if #segItems > 0 then
      items[#items + 1] = { header = true, kind = "step", key = "seg" .. si, label = label }
      for _, it in ipairs(segItems) do items[#items + 1] = it end
    end
  end
  -- Quests kept for max level: reward or access only useful at endgame.
  if info.later and #info.later > 0 then
    local laterItems = {}
    table.sort(info.later, function(a, b) return (a.level or 0) < (b.level or 0) end)
    for _, e in ipairs(info.later) do
      local text = "  " .. StateIcons(e.id) .. (e.title or "?") .. Color("aaaaaa", L[" (level "] .. tostring(e.level or "?") .. ")") ..
        "\n       " .. Color("ffb060", L["To do at level "] .. Geo.MaxLevel() .. L[": "] .. (e.reason or "?"))
      if #xpQuery == 0 or MatchWords(Normalize(text), xpQuery) then
        laterItems[#laterItems + 1] = { text = text, questID = e.id }
      end
    end
    if #laterItems > 0 then
      items[#items + 1] = { header = true, kind = "take", key = "later",
        label = L["For max level - "] .. Plural(#laterItems, L["quest"]) .. L[" (easier and faster at that level)"] }
      for _, it in ipairs(laterItems) do items[#items + 1] = it end
    end
  end
  if #route <= 1 then items[#items + 1] = { text = L["No usable quest found around you."] } end
  if #xpQuery > 0 then
    local any = false
    for _, it in ipairs(items) do if it.header then any = true break end end
    if not any then items[#items + 1] = { text = L["No plan step matches the search."] } end
  end
  RenderList(panel, "xp", items, #xpQuery > 0)
  pcall(CP.RefreshButton)
end

-- Second line: toggle state buttons (several allowed), the list moves down one line.
local STATE_DEFS = {
  { key = "turnin", label = L["To turn in"], icon = function() return ICON.turnin end },
  { key = "inprogress", label = L["In progress"], icon = function() return ICON.inprogress end },
  { key = "watched", label = L["Tracked"], icon = function() return ICON.watched end },
  { key = "pinned", label = L["Pin"], icon = function() return PinIcon() end },
  { key = "available", label = L["To pick up"], icon = function() return ICON.available end },
  { key = "abandon", label = L["To abandon"], icon = function() return "|TInterface\\RaidFrame\\ReadyCheck-NotReady:16:16|t" end },
}

local function AddStateFilters(panel, keys, selected)
  panel.stateChecks = {}
  local x = 12
  local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", x, -104)
  label:SetText(L["Show:"])
  x = x + 54
  for _, def in ipairs(STATE_DEFS) do
    if keys[def.key] then
      local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
      cb:SetSize(22, 22)
      cb:SetPoint("TOPLEFT", x, -98)
      cb.label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      cb.label:SetPoint("LEFT", cb, "RIGHT", 0, 0)
      cb.label:SetText(def.icon() .. " " .. def.label)
      cb:SetScript("OnClick", function(self)
        selected[def.key] = self:GetChecked() and true or nil
        Refresh()
      end)
      panel.stateChecks[def.key] = cb
      x = x + 112
    end
  end
  panel.scroll:ClearAllPoints()
  panel.scroll:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 12, -124)
  panel.scroll:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -32, 24)
  function panel.HighlightStates()
    for k, cb in pairs(panel.stateChecks) do cb:SetChecked(selected[k] and true or false) end
  end
end

local function CreateFilterPanel(f, filters, getCurrent, setCurrent, onSearch, toggle, caption)
  local c = CreateFrame("Frame", nil, f)
  c:SetAllPoints(f)
  c.buttons = {}
  local x = 14
  -- Single choice: radio buttons (game template, otherwise a checkbox used as a radio).
  if #filters > 0 and caption then
    local cap = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cap:SetPoint("TOPLEFT", x, -76)
    cap:SetText(caption)
    x = x + (cap:GetStringWidth() or 40) + 8
  end
  for _, flt in ipairs(filters) do
    local ok, b = pcall(CreateFrame, "CheckButton", nil, c, "UIRadioButtonTemplate")
    if not ok or not b then b = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate") end
    b:SetSize(18, 18)
    b:SetPoint("TOPLEFT", x, -73)
    b.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", b, "RIGHT", 2, 0)
    b.label:SetText(flt.label)
    b:SetScript("OnClick", function()
      setCurrent(flt.key)
      Refresh()
    end)
    c.buttons[flt.key] = b
    x = x + 18 + 2 + (b.label:GetStringWidth() or 50) + 14
  end
  if onSearch then
    c.search = CreateSearchBox(c, 140, onSearch)
    c.search:SetPoint("TOPLEFT", x + 12, -71)
    x = x + 12 + 140
  end
  if toggle then
    local cb = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x + 8, -69)
    cb.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label:SetText(toggle.label)
    cb:SetChecked(toggle.get() and true or false)
    cb:SetScript("OnClick", function(self)
      toggle.set(self:GetChecked() and true or false)
      Refresh()
    end)
    c.toggle = cb
  end
  c.scroll = CreateScrollPanel(c, nil, -98)
  function c.Highlight()
    local cur = getCurrent()
    for k, b in pairs(c.buttons) do b:SetChecked(k == cur) end
  end
  return c
end

-- Option shared by "Around me" and "Available".
local LOW_LEVEL_TOGGLE = {
  label = L["Low-level quests"],
  get = function() return Settings().showLowLevel end,
  set = function(v) Settings().showLowLevel = v or nil end,
}

local nearTicker

local function StopNearTicker()
  if nearTicker then
    nearTicker:Cancel()
    nearTicker = nil
  end
end

local function SelectTab(name)
  if not panels[name] then name = "groups" end -- old tab removed (e.g. "To abandon")
  currentTab = name
  if name ~= "settings" then Settings().lastTab = name end
  for key, p in pairs(panels) do p:SetShown(key == name) end
  local highlighted = (name == "export") and "groups" or name -- the export is part of the Quest log tab
  if mainFrame.usesTabs and PanelTemplates_SetTab and tabButtons[highlighted] then
    pcall(PanelTemplates_SetTab, mainFrame, tabButtons[highlighted].tabIndex)
  elseif mainFrame.usesTabs and PanelTemplates_SetTab then
    pcall(PanelTemplates_SetTab, mainFrame, 0) -- settings: no tab selected
  else
    for key, b in pairs(tabButtons) do
      if key == highlighted then b:LockHighlight() else b:UnlockHighlight() end
    end
  end
  StopNearTicker()
  if name == "near" and C_Timer.NewTicker then
    nearTicker = C_Timer.NewTicker(3, function()
      if mainFrame and mainFrame:IsShown() and currentTab == "near" then
        RenderNear()
      else
        StopNearTicker()
      end
    end)
  end
  Refresh()
end

local RefreshUnsafe
local lastError
Refresh = function()
  if not (mainFrame and mainFrame:IsShown()) then return end
  local ok, err = xpcall(RefreshUnsafe, function(e)
    return tostring(e) .. (debugstack and ("\n" .. debugstack(2, 3, 0)) or "")
  end)
  if not ok and err ~= lastError then
    lastError = err
    Print(L["|cffff6060Error while updating the window|r (copy it to report it):\n"] .. err)
  end
end

RefreshUnsafe = function()
  if currentTab == "export" then
    RenderExport()
  elseif currentTab == "avail" then
    panels.avail.Highlight()
    RenderAvailable()
  elseif currentTab == "near" then
    panels.near.Highlight()
    panels.near.HighlightStates()
    RenderNear()
  elseif currentTab == "xp" then
    panels.xp.Highlight()
    RenderXP()

  else
    local a = Analyze()
    RenderTodo(a)
  end
end

---------------------------------------------------------------------------
-- Settings: Roadbook priority and estimate parameters
---------------------------------------------------------------------------
K.PARAMS = {
  { section = L["Priority bonuses (100 % = as if the quest gave the XP of one more average Roadbook quest)"] },
  { key = "PRIO_CLASS", label = L["Class quest (or chain leading to one)"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_ITEM_SPEC", label = L["Blue reward suited to your spec"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_ITEM_BLUE", label = L["Blue reward, off-spec"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_UPGRADE_SPEC", label = L["Upgrade with the right stats"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_UPGRADE", label = L["Upgrade (item level only)"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_SPELL", label = L["Reward that teaches a skill"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_BAG", label = L["Reward: bag"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "READY_BONUS", label = L["Quest ready to turn in"], pct = true, min = 0, max = 1, step = 0.05 },
  { section = L["Difficulty"] },
  { key = "MAX_LEVEL_GAP", label = L["Max quest level"], unit = L[" lvl"], min = -5, max = 5, step = 1, signed = true },
  { key = "MAX_ELITE_GAP", label = L["Max elite quest level"], unit = L[" lvl"], min = -5, max = 5, step = 1, signed = true },
  { section = L["Time estimates"] },
  { key = "MOB_TIME", label = L["Time per monster"], unit = L[" s"], min = 10, max = 90, step = 5 },
  { key = "ELITE_MOB_TIME", label = L["Time per elite monster"], unit = L[" s"], min = 20, max = 240, step = 5 },
  { key = "KILLS_NO_RATE", label = L["Monsters per item (unknown drop rate)"], unit = "", min = 1, max = 20, step = 1 },
}
for _, d in ipairs(K.PARAMS) do
  if d.key then d.default = K[d.key] end
end

-- Applies the saved values (or the defaults).
K.PARAMS_SCALE = 2 -- 2: priorities in share of an average quest (before: share of the level's XP)
function Geo.ApplyParams()
  local st = Settings()
  if st.params and st.paramsScale ~= K.PARAMS_SCALE then
    -- Values saved with the former scale make no sense anymore: back to the defaults.
    for _, k in ipairs({ "PRIO_CLASS", "PRIO_UNLOCK_CLASS", "PRIO_ITEM_SPEC", "PRIO_ITEM_BLUE", "PRIO_UPGRADE_SPEC",
      "PRIO_UPGRADE", "PRIO_SPELL", "PRIO_BAG", "READY_BONUS", "LOOKAHEAD_WEIGHT" }) do st.params[k] = nil end
  end
  st.paramsScale = K.PARAMS_SCALE
  local saved = st.params or {}
  for _, d in ipairs(K.PARAMS) do
    if d.key then
      local v = saved[d.key]
      K[d.key] = (type(v) == "number") and math.min(d.max, math.max(d.min, v)) or d.default
    end
  end
  Geo.paramsVersion = (Geo.paramsVersion or 0) + 1
  Geo.planCache = nil
end

function Geo.SetParam(d, v)
  local st = Settings()
  st.params = st.params or {}
  st.params[d.key] = (math.abs(v - d.default) < 1e-6) and nil or v
  Geo.ApplyParams()
  if d.rescan then scan.dirty = true end
end

function Geo.ParamText(d, v)
  if d.pct then return string.format("%d %%", math.floor(v * 100 + 0.5)) end
  if d.signed then return string.format("%+d", v) .. (d.unit or "") end
  return tostring(v) .. (d.unit or "")
end

-- Bordered group box ("panel") with a title, used to sort the settings by family.
function Geo.SettingsBox(parent, title, x, y, w, h)
  local box = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  box:SetPoint("TOPLEFT", x, y)
  box:SetSize(w, h)
  if box.SetBackdrop then
    box:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0, 0, 0, 0.35)
    box:SetBackdropBorderColor(0.8, 0.65, 0.35, 0.8)
  end
  local t = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("TOPLEFT", 10, -8)
  t:SetText(title)
  return box
end

function Geo.SettingsCheck(box, label, x, y, get, set, panel)
  local cb = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
  cb:SetSize(22, 22)
  cb:SetPoint("TOPLEFT", x, y)
  cb.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  cb.label:SetText(label)
  cb:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    if Refresh then Refresh() end
  end)
  panel.updaters[#panel.updaters + 1] = function() cb:SetChecked(get() and true or false) end
  return cb
end

function Geo.SettingsSlider(box, d, x, y, panel)
  local name = "ForeverQuestPlannerParam" .. d.key
  local ok, sl = pcall(CreateFrame, "Slider", name, box, "OptionsSliderTemplate")
  if not ok or not sl then
    sl = CreateFrame("Slider", name, box)
    sl:SetOrientation("HORIZONTAL")
    sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  end
  sl:SetSize(200, 16)
  sl:SetPoint("TOPLEFT", x + 160, y - 6)
  sl:SetMinMaxValues(d.min, d.max)
  sl:SetValueStep(d.step)
  if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
  for _, suffix in ipairs({ "Low", "High", "Text" }) do
    local r = _G[name .. suffix]
    if r then r:SetText("") end
  end
  local label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", x, y - 2)
  label:SetWidth(155)
  label:SetJustifyH("LEFT")
  label:SetText(d.label)
  local value = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  value:SetPoint("TOP", sl, "BOTTOM", 0, -1)
  sl.valueText, sl.def = value, d
  sl:SetScript("OnValueChanged", function(self, v, userInput)
    v = math.floor(v / d.step + 0.5) * d.step
    self.valueText:SetText(Geo.ParamText(d, v) .. ((math.abs(v - d.default) < 1e-6) and "" or
      Color("888888", L["  (default "] .. Geo.ParamText(d, d.default) .. ")")))
    if userInput ~= false and not panel.updating then Geo.SetParam(d, v) end
  end)
  sl:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(d.label)
    GameTooltip:AddLine(L["Default value: "] .. Geo.ParamText(d, d.default), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(L["The Roadbook is recomputed with the new value."], 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  sl:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.sliders[#panel.sliders + 1] = sl
end

-- Settings window: general options, then a Roadbook panel with its option groups.
-- (Duration, Around me radius, Available filter and low-level quests stay in their tabs.)
function Geo.CreateSettingsPanel(f)
  local panel = CreateFrame("Frame", nil, f)
  panel:SetAllPoints(f)
  panel.sliders, panel.updaters = {}, {}

  -- General
  local gen = Geo.SettingsBox(panel, L["General"], 14, -32, 392, 62)
  Geo.SettingsCheck(gen, L["Minimap icon"], 10, -28,
    function() return not Settings().hideMinimap end,
    function(v)
      Settings().hideMinimap = not v or nil
      local mb = _G["ForeverQuestPlannerMinimapButton"]
      if mb then mb:SetShown(v) end
    end, panel)

  -- Quest log
  local journal = Geo.SettingsBox(panel, L["Quest log"], 414, -32, 392, 62)
  local keep = CreateFrame("Button", nil, journal, "UIPanelButtonTemplate")
  keep:SetSize(240, 22)
  keep:SetPoint("TOPLEFT", 10, -28)
  keep:SetText(L["Clear \"Keep\" quests"])
  keep:SetScript("OnClick", function()
    Settings().keep = {}
    Print(L["\"Keep\" quest list cleared."])
    if Refresh then Refresh() end
  end)

  -- Roadbook: objective button, hearthstone, then priorities, look-ahead and time estimates.
  -- Layout: boxes 8 px apart; content 10 px from the left edge, first row 28-30 px below the
  -- top edge, 12 px of padding under the last row (slider row = 46 px).
  local rb = Geo.SettingsBox(panel, L["Roadbook"], 14, -102, 792, 526)
  Geo.SettingsCheck(rb, L["Use the hearthstone"], 18, -28,
    function() return not Settings().noHearth end,
    function(v)
      Settings().noHearth = not v or nil
      Geo.planCache = nil
    end, panel)
  local restore = CreateFrame("Button", nil, rb, "UIPanelButtonTemplate")
  restore:SetSize(260, 22)
  restore:SetPoint("TOPRIGHT", -18, -28) -- aligned with "Center horizontally" below
  local function RemovedCount()
    local n = 0
    for _ in pairs(Settings().excluded) do n = n + 1 end
    return n
  end
  local function UpdateRestore()
    local n = RemovedCount()
    restore:SetText(L["Restore removed quests"] .. (n > 0 and (" (" .. n .. ")") or ""))
    restore:SetEnabled(n > 0)
  end
  panel.updaters[#panel.updaters + 1] = UpdateRestore
  restore:SetScript("OnClick", function()
    local n = RemovedCount()
    if n == 0 then return end
    Settings().excluded = {}
    Geo.planCache = nil
    Print(Plural(n, L["quest"]) .. L[" added back: computing a new Roadbook."])
    UpdateRestore()
    CP.Recompute()
  end)
  -- Objective button: shown, compass, centered.
  local obj = Geo.SettingsBox(rb, L["Objective"], 8, -58, 776, 62)
  Geo.SettingsCheck(obj, L["Show"], 10, -28, CP.CHECKPOINT_TOGGLE.get, CP.CHECKPOINT_TOGGLE.set, panel)
  Geo.SettingsCheck(obj, L["Compass"], 220, -28,
    function() return Settings().compass ~= false end,
    function(v)
      if v then Settings().compass = nil else Settings().compass = false end -- shown by default
      local b = CP.checkpointButton
      if b then b.compassTarget = CP.CompassTarget() end
    end, panel)
  local center = CreateFrame("Button", nil, obj, "UIPanelButtonTemplate")
  center:SetSize(260, 22)
  center:SetPoint("TOPRIGHT", -10, -28)
  center:SetText(L["Center horizontally"])
  center:SetScript("OnClick", function() CP.CenterCheckpointButton() end)
  local boxes = {
    Geo.SettingsBox(rb, L["Priorities (100 % = adds the XP of an average Roadbook quest)"], 8, -128, 776, 214),
    Geo.SettingsBox(rb, L["Difficulty"], 8, -350, 384, 168),
    Geo.SettingsBox(rb, L["Time estimates"], 400, -350, 384, 168),
  }
  local sec, n = 0, 0
  for _, d in ipairs(K.PARAMS) do
    if d.section then
      sec, n = sec + 1, 0
    elseif boxes[sec] then
      local cols = (sec == 1) and 2 or 1
      local col, row = n % cols, math.floor(n / cols)
      Geo.SettingsSlider(boxes[sec], d, 10 + col * 392, -30 - row * 46, panel)
      n = n + 1
    end
  end
  -- Elite quests on/off, on the free row of the "Difficulty" box; off: their slider is greyed.
  local function UpdateEliteSlider()
    local sl = _G["ForeverQuestPlannerParamMAX_ELITE_GAP"]
    if sl and sl.Enable then
      if Settings().noElite then sl:Disable() else sl:Enable() end
      sl:SetAlpha(Settings().noElite and 0.4 or 1)
    end
  end
  Geo.SettingsCheck(boxes[2], L["Include elite quests"], 10, -122,
    function() return not Settings().noElite end,
    function(v)
      Settings().noElite = not v or nil
      Geo.planCache = nil
      UpdateEliteSlider()
    end, panel)
  panel.updaters[#panel.updaters + 1] = UpdateEliteSlider

  local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  reset:SetSize(170, 24)
  reset:SetPoint("BOTTOMLEFT", 16, 26)
  reset:SetText(L["Defaults"])
  reset:SetScript("OnClick", function()
    Settings().params = nil
    Geo.ApplyParams()
    scan.dirty = true
    panel.Update()
  end)
  local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  note:SetPoint("LEFT", reset, "RIGHT", 12, 0)
  note:SetWidth(580)
  note:SetJustifyH("LEFT")
  note:SetText(L["Settings are saved. Priorities and estimates apply to the next Roadbook computation; \"Defaults\" resets them."])
  function panel.Update()
    panel.updating = true
    for _, fn in ipairs(panel.updaters) do fn() end
    for _, sl in ipairs(panel.sliders) do
      sl:SetValue(K[sl.def.key])
      local fn = sl:GetScript("OnValueChanged")
      if fn then fn(sl, K[sl.def.key], false) end
    end
    panel.updating = false
  end
  return panel
end

-- "ForeverQuestPlanner vX.Y.Z" footer at the bottom of a window (version read from the .toc).
-- Addon version, read from the .toc.
function Geo.Version()
  local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ok, version = false, nil
  if getMeta then ok, version = pcall(getMeta, "ForeverQuestPlanner", "Version") end
  return (ok and version) or "?"
end

function Geo.AddVersionFooter(frame)
  local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footer:SetPoint("BOTTOMRIGHT", -14, 8)
  footer:SetText("ForeverQuestPlanner v" .. Geo.Version())
  -- GitHub link, bottom left: the game cannot open URLs, so a click shows it ready to copy.
  local link = CreateFrame("Button", nil, frame)
  link.text = link:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  link.text:SetPoint("LEFT")
  link.text:SetText(K.REPO_URL)
  link:SetSize((link.text:GetStringWidth() or 200) + 4, 14)
  link:SetPoint("BOTTOMLEFT", 14, 6)
  link:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 0.82, 0)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Click to copy the link"])
    GameTooltip:Show()
  end)
  link:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.5, 0.5, 0.5)
    GameTooltip:Hide()
  end)
  link:SetScript("OnClick", function() StaticPopup_Show("FQP_COPY_URL") end)
  return footer
end

K.REPO_URL = "https://github.com/bplaquevent/ForeverQuestPlanner"
StaticPopupDialogs["FQP_COPY_URL"] = {
  text = L["Copy the link with Ctrl+C:"],
  button1 = OKAY or "OK",
  hasEditBox = true,
  editBoxWidth = 320,
  OnShow = function(self)
    local eb = self.editBox or self.EditBox
    if eb then
      eb:SetText(K.REPO_URL)
      eb:HighlightText()
      eb:SetFocus()
    end
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
  EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

-- Standalone settings window (movable, closed with Escape or the close button).
function Geo.ToggleSettings()
  local w = Geo.settingsWindow
  if not w then
    w = CreateFrame("Frame", "ForeverQuestPlannerSettingsFrame", UIParent, "BasicFrameTemplateWithInset")
    w:SetSize(820, 700)
    w:SetPoint("CENTER", 40, -20)
    w:SetFrameStrata("DIALOG")
    w:SetToplevel(true)
    w:SetMovable(true)
    w:SetClampedToScreen(true)
    w:EnableMouse(true)
    w:RegisterForDrag("LeftButton")
    w:SetScript("OnDragStart", w.StartMoving)
    w:SetScript("OnDragStop", w.StopMovingOrSizing)
    w.title = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    w.title:SetPoint("TOP", 0, -5)
    w.title:SetText(L["Forever Quest Planner - Roadbook settings"])
    -- Same background as the main window: darkened parchment with a slight gradient.
    w.art = w:CreateTexture(nil, "BACKGROUND", nil, 2)
    w.art:SetPoint("TOPLEFT", 6, -24)
    w.art:SetPoint("BOTTOMRIGHT", -6, 6)
    w.art:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal")
    w.art:SetVertexColor(0.42, 0.34, 0.26)
    w.shade = w:CreateTexture(nil, "BACKGROUND", nil, 3)
    w.shade:SetAllPoints(w.art)
    w.shade:SetColorTexture(0, 0, 0, 1)
    if w.shade.SetGradient and CreateColor then
      pcall(w.shade.SetGradient, w.shade, "VERTICAL", CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0.15))
    else
      w.shade:SetAlpha(0.35)
    end
    w.panel = Geo.CreateSettingsPanel(w)
    Geo.AddVersionFooter(w)
    w:SetScript("OnShow", function() w.panel.Update() end)
    w:SetScript("OnHide", function()
      -- The open Roadbook is recomputed with the new values.
      if Refresh then Refresh() end
    end)
    tinsert(UISpecialFrames, "ForeverQuestPlannerSettingsFrame")
    Geo.settingsWindow = w
    w:Hide()
  end
  w:SetShown(not w:IsShown())
end

local function CreateMainFrame()
  currentTab = Settings().lastTab or currentTab
  local f = CreateFrame("Frame", "ForeverQuestPlannerFrame", UIParent, "BasicFrameTemplateWithInset")
  mainFrame = f
  f:SetSize(820, 570)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()

  -- Background: darkened parchment, quest-book style, with a slight downward gradient.
  f.art = f:CreateTexture(nil, "BACKGROUND", nil, 2)
  f.art:SetPoint("TOPLEFT", 6, -24)
  f.art:SetPoint("BOTTOMRIGHT", -6, 6)
  f.art:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal")
  f.art:SetVertexColor(0.42, 0.34, 0.26)
  f.shade = f:CreateTexture(nil, "BACKGROUND", nil, 3)
  f.shade:SetAllPoints(f.art)
  f.shade:SetColorTexture(0, 0, 0, 1)
  if f.shade.SetGradient and CreateColor then
    pcall(f.shade.SetGradient, f.shade, "VERTICAL", CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0.15))
  else
    f.shade:SetAlpha(0.35)
  end

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.title:SetPoint("TOP", 0, -5)
  f.title:SetText("Forever Quest Planner" .. (QDB.ok and "  (QuestieDB)" or ""))
  Geo.AddVersionFooter(f)

  local tabs = {
    { key = "xp", label = L["Roadbook"] },
    { key = "near", label = L["Around me"] },
    { key = "groups", label = L["Quest log"] },
    { key = "avail", label = L["Available"] },
  }
  -- Game tabs if the client provides the template, otherwise regular buttons.
  local tabTemplate
  for _, tpl in ipairs({ "PanelTopTabButtonTemplate", "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate" }) do
    local ok, probe = pcall(CreateFrame, "Button", nil, f, tpl)
    if ok and probe then
      probe:Hide()
      tabTemplate = tpl
      break
    end
  end
  f.Tabs = {}
  local prev
  for i, t in ipairs(tabs) do
    local b
    if tabTemplate then
      b = CreateFrame("Button", "ForeverQuestPlannerFrameTab" .. i, f, tabTemplate)
      b:SetID(i)
      b:SetText(t.label)
      if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, b, 12) end
      if tabTemplate == "PanelTopTabButtonTemplate" then
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", 14, -26) end
      else
        -- "old-style" tabs, attached under the window
        if prev then b:SetPoint("LEFT", prev, "RIGHT", -14, 0) else b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 10, 2) end
      end
    else
      b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
      b:SetSize(112, 24)
      if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -30) end
      b:SetText(t.label)
    end
    b:SetScript("OnClick", function() SelectTab(t.key) end)
    b.tabIndex = i
    tabButtons[t.key] = b
    f.Tabs[i] = b
    prev = b
  end
  f.usesTabs = tabTemplate ~= nil
  if f.usesTabs and PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, f, #tabs) end

  -- Gear icon: opens / closes the settings (back to the previous tab).
  local gear = CreateFrame("Button", nil, f)
  gear:SetSize(18, 18)
  -- Small golden gear, vertically centered on the tab row, right after the last tab.
  gear:SetPoint("BOTTOMLEFT", f.Tabs[#f.Tabs], "BOTTOMRIGHT", 10, -1) -- sitting on the tab text line
  local gearPath = "Interface\\Buttons\\UI-OptionsButton"
  local gearTex = gear:CreateTexture(nil, "ARTWORK")
  gearTex:SetAllPoints()
  if gearTex:SetTexture(gearPath) == false then
    gearPath = "Interface\\Icons\\INV_Misc_Gear_01"
    gearTex:SetTexture(gearPath)
  end
  gear:SetScript("OnMouseDown", function() gearTex:SetVertexColor(0.7, 0.7, 0.7) end)
  gear:SetScript("OnMouseUp", function() gearTex:SetVertexColor(1, 1, 1) end)
  local glow = gear:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetTexture(gearPath)
  glow:SetBlendMode("ADD")
  glow:SetAlpha(0.5)
  gear:SetScript("OnClick", function() Geo.ToggleSettings() end)
  gear:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(L["Roadbook settings"])
    GameTooltip:AddLine(L["Quest priorities, look-ahead, time estimates."], 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  gear:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- "Export" tab: selected, read-only text area.
  local eb = CreateFrame("EditBox", nil, f)
  eb:SetMultiLine(true)
  eb:SetMaxLetters(0)
  eb:SetAutoFocus(false)
  eb:SetFontObject(ChatFontNormal)
  eb:SetWidth(CONTENT_WIDTH)
  eb:SetScript("OnEscapePressed", function() f:Hide() end)
  eb:SetScript("OnTextChanged", function(self, userInput)
    if userInput then
      self:SetText(self.fullText or "")
      self:HighlightText()
    end
  end)
  eb:SetScript("OnMouseUp", function(self) self:HighlightText() end)
  local exportPanel = CreateFrame("Frame", nil, f)
  exportPanel:SetAllPoints(f)
  local back = CreateFrame("Button", nil, exportPanel, "UIPanelButtonTemplate")
  back:SetSize(150, 22)
  back:SetPoint("TOPLEFT", 12, -70)
  back:SetText(L["< Back to the quest log"])
  back:SetScript("OnClick", function() SelectTab("groups") end)
  local hint = exportPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("LEFT", back, "RIGHT", 12, 0)
  hint:SetText(L["Text already selected: Ctrl+C to copy, Escape to close."])
  exportPanel.scroll = CreateScrollPanel(exportPanel, eb, -98)
  panels.export = exportPanel

  panels.groups = CreateFilterPanel(f, {}, function() return nil end, function() end, function(text)
    todoQuery = ParseQuery(text)
    Refresh()
  end)
  AddStateFilters(panels.groups, { turnin = true, inprogress = true, watched = true, pinned = true, abandon = true }, journalStates)
  local exportButton = CreateFrame("Button", nil, panels.groups, "UIPanelButtonTemplate")
  exportButton:SetSize(150, 22)
  exportButton:SetPoint("TOPRIGHT", -12, -70)
  exportButton:SetText(L["Export quest log"])
  exportButton:SetScript("OnClick", function() SelectTab("export") end)

  panels.avail = CreateFilterPanel(f, {
    { key = "zone", label = L["Current zone"] },
    { key = "dungeon", label = L["Dungeons"] },
    { key = "class", label = L["Class & professions"] },
    { key = "all", label = L["All"] },
  }, function() return availFilter end, function(v)
    availFilter = v
    Settings().availFilter = v
  end, function(text)
    availQuery = ParseQuery(text)
    Refresh()
  end, LOW_LEVEL_TOGGLE, L["Quests:"])

  panels.near = CreateFilterPanel(f, {
    { key = 200, label = "200 m" },
    { key = 500, label = "500 m" },
    { key = 1500, label = "1500 m" },
    { key = "zone", label = L["Current zone"] },
  }, function() return nearRadius end, function(v)
    nearRadius = v
    Settings().nearRadius = v
  end, function(text)
    nearQuery = ParseQuery(text)
    Refresh()
  end, LOW_LEVEL_TOGGLE, L["Radius:"])
  AddStateFilters(panels.near, { turnin = true, inprogress = true, watched = true, pinned = true, available = true }, nearStates)

  panels.xp = CreateFilterPanel(f, {
    { key = 3600, label = "1 h" },
    { key = 7200, label = "2 h" },
    { key = 14400, label = "4 h" },
  }, function() return xpHorizon end, function(v)
    if v ~= xpHorizon then
      xpHorizon = v
      Settings().horizon = v
      CP.Recompute() -- new duration: new Roadbook, same as the "Recalculate" button
    end
  end, function(text)
    xpQuery = ParseQuery(text)
    Refresh()
  end, nil, L["Duration:"])
  local recompute = CreateFrame("Button", nil, panels.xp, "UIPanelButtonTemplate")
  recompute:SetSize(150, 22)
  recompute:SetPoint("TOPRIGHT", -12, -70) -- same place as "Export quest log" in the Quest log tab
  recompute:SetText(L["Recalculate"])
  recompute:SetScript("OnClick", function() CP.Recompute() end)

  f:SetScript("OnShow", function()
    -- Same sound as opening the game's quest log.
    if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_OPEN) or 844) end
    for k in pairs(expandedCategories) do expandedCategories[k] = nil end
    Settings().expanded = nil
    SelectTab(currentTab)
  end)
  f:SetScript("OnHide", function()
    StopNearTicker()
    Geo.HideRowTooltip()
    if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_CLOSE) or 845) end
  end)
  tinsert(UISpecialFrames, "ForeverQuestPlannerFrame")
end

local function ToggleMainFrame(tab)
  if not mainFrame then CreateMainFrame() end
  if tab then currentTab = tab end
  if mainFrame:IsShown() then
    if tab then SelectTab(currentTab) else mainFrame:Hide() end
  else
    mainFrame:Show() -- OnShow selects the current tab
  end
end
CP.OpenWindow = ToggleMainFrame

---------------------------------------------------------------------------
-- Export to file: capture + UI reload
---------------------------------------------------------------------------
local function ExportAndSave()
  if InCombatLockdown() then
    Print(L["Not possible in combat, try again once out of combat."])
    return
  end
  local count = Snapshot()
  Print(count .. L[" quests exported, reloading the UI to write the file…"])
  ReloadUI()
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
local minimapButton

local function UpdateButtonPosition()
  local angle = math.rad(Settings().minimapAngle or 200)
  local radius = (Minimap:GetWidth() / 2) + 10
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  cx, cy = cx / scale, cy / scale
  Settings().minimapAngle = math.deg(math.atan2(cy - my, cx - mx)) % 360
  UpdateButtonPosition()
end

local function CreateMinimapButton()
  if minimapButton or not Minimap then return end

  local b = CreateFrame("Button", "ForeverQuestPlannerMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER", 0, 1)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(18, 18)
  icon:SetPoint("CENTER", 0, 1)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then Geo.ToggleSettings() else ToggleMainFrame() end
  end)
  b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddDoubleLine("Forever Quest Planner", "v" .. Geo.Version(), 1, 0.82, 0, 0.6, 0.6, 0.6)
    GameTooltip:AddLine(L["|cffffff00Click|r: open / close the window"], 1, 1, 1)
    GameTooltip:AddLine(L["|cffffff00Right-click|r: settings"], 1, 1, 1)
    GameTooltip:AddLine(L["|cffffff00Drag|r: move the icon"], 1, 1, 1)
    GameTooltip:AddLine(QDB.ok and L["QuestieDB: active"] or L["QuestieDB: missing"], 0.6, 0.8, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  minimapButton = b
  UpdateButtonPosition()
  if Settings().hideMinimap then b:Hide() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_REMOVED")
f:RegisterEvent("QUEST_TURNED_IN")
f:RegisterEvent("PLAYER_LEVEL_UP")
-- Reputation and profession changes can unlock quests: rescan (batched, they can fire often).
pcall(f.RegisterEvent, f, "UPDATE_FACTION")
pcall(f.RegisterEvent, f, "SKILL_LINES_CHANGED")
f:RegisterEvent("TAXIMAP_OPENED")
pcall(f.RegisterEvent, f, "USER_WAYPOINT_UPDATED")
f:RegisterEvent("PLAYER_LOGOUT")
pcall(f.RegisterEvent, f, "HEARTHSTONE_BOUND")
pcall(f.RegisterEvent, f, "PLAYER_CONTROL_LOST")
pcall(f.RegisterEvent, f, "PLAYER_CONTROL_GAINED")
pcall(f.RegisterEvent, f, "ZONE_CHANGED_NEW_AREA")
pcall(f.RegisterEvent, f, "PLAYER_ENTERING_WORLD")
if f.RegisterUnitEvent then
  pcall(f.RegisterUnitEvent, f, "UNIT_SPELLCAST_SUCCEEDED", "player")
else
  pcall(f.RegisterEvent, f, "UNIT_SPELLCAST_SUCCEEDED")
end
f:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    Settings().focus = nil -- old saved focus (versions 2.32.1-2.32.2)
    -- Options saved from the settings window or the tabs.
    local st = Settings()
    if st.horizon then xpHorizon = st.horizon end
    if st.nearRadius then nearRadius = st.nearRadius end
    if st.availFilter then availFilter = st.availFilter end
    pcall(Geo.ApplyParams)
    local ok, err = pcall(InitQuestieDB)
    if not ok then Print(L["QuestieDB initialization error: "] .. tostring(err)) end
    CreateMinimapButton()
    if CP.CHECKPOINT_TOGGLE.get() then CP.CreateCheckpointButton() end
    ScheduleSnapshot()
  elseif event == "PLAYER_LOGOUT" then
    Snapshot()
  elseif event == "HEARTHSTONE_BOUND" then
    -- New inn: position of the innkeeper targeted by the Roadbook, otherwise ours.
    local s = CP.focused
    local p = (s and s.kind == "bind" and CP.IsStepFocused(s)) and s.p or PlayerPos()
    pcall(Geo.RecordBind, p)
    pcall(CP.OnGameEvent, event)
    if mainFrame and mainFrame:IsShown() then C_Timer.After(0.5, Refresh) end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if unit == "player" and spellID == K.HEARTH_SPELL then
      C_Timer.After(5, function()
        local name = GetBindLocation and GetBindLocation()
        local st = Geo.BindStore()[CharKey()]
        if not (st and st.name == name) then pcall(Geo.RecordBind, PlayerPos()) end
        pcall(CP.OnGameEvent, "FQP_HEARTH_ARRIVED")
      end)
    end
  elseif event == "PLAYER_CONTROL_LOST" then
    C_Timer.After(0.5, function()
      if UnitOnTaxi and UnitOnTaxi("player") and not f.onTaxi then
        f.onTaxi = true
        pcall(CP.OnGameEvent, "FQP_TAXI_TAKEOFF")
      end
    end)
  elseif event == "UPDATE_FACTION" or event == "SKILL_LINES_CHANGED" then
    if not f.rescanPending then
      f.rescanPending = true
      C_Timer.After(10, function()
        f.rescanPending = nil
        scan.dirty = true
        if mainFrame and mainFrame:IsShown() and currentTab ~= "xp" then Refresh() end
      end)
    end
  elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
    pcall(CP.OnGameEvent, "ZONE_CHANGED_NEW_AREA")
  elseif event == "PLAYER_CONTROL_GAINED" then
    if f.onTaxi then
      f.onTaxi = nil
      C_Timer.After(1, function() pcall(CP.OnGameEvent, "FQP_TAXI_LANDED") end)
    end
  elseif event == "USER_WAYPOINT_UPDATED" then
    OnWaypointChanged()
    C_Timer.After(0.2, function() pcall(CP.RefreshButton) end)
    if mainFrame and mainFrame:IsShown() then C_Timer.After(0.1, Refresh) end
  elseif event == "TAXIMAP_OPENED" then
    local ok, err = pcall(RecordTaxiNodes)
    if not ok then Print(L["Error recording flight masters: "] .. tostring(err)) end
    pcall(CP.OnGameEvent, event, ...)
  else
    ScheduleSnapshot()
    pcall(CP.OnGameEvent, event, ...)
    if event == "QUEST_LOG_UPDATE" and mainFrame and mainFrame:IsShown() and currentTab == "groups" and not f.pendingRefresh then
      f.pendingRefresh = true
      C_Timer.After(1, function()
        f.pendingRefresh = nil
        Refresh()
      end)
    end
    if event ~= "QUEST_LOG_UPDATE" then
      scan.dirty = true
      if mainFrame and mainFrame:IsShown() and currentTab ~= "export" then
        C_Timer.After(0.5, Refresh)
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
SLASH_FOREVERQUESTPLANNER1 = "/fqp"
SlashCmdList.FOREVERQUESTPLANNER = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "save" then
    ExportAndSave()
  elseif msg == "hearth" or msg == "foyer" then
    local st = Settings()
    st.noHearth = not st.noHearth or nil
    Print(st.noHearth and L["Hearthstone ignored by the Roadbook."] or L["Hearthstone used by the Roadbook."])
    if Refresh then Refresh() end
  elseif msg == "icon" then
    local s = Settings()
    s.hideMinimap = not s.hideMinimap
    if minimapButton then minimapButton:SetShown(not s.hideMinimap) end
    Print(L["Minimap icon "] .. (s.hideMinimap and L["hidden."] or L["shown."]))
  elseif msg == "reset" then
    Settings().keep = {}
    Print(L["\"Keep\" quest list cleared."])
    Refresh()
  elseif msg == "abandon" then
    ToggleMainFrame("groups")
  elseif msg == "near" or msg == "around" or msg == "autour" then
    ToggleMainFrame("near")
  elseif msg == "xp" or msg == "roadbook" then
    ToggleMainFrame("xp")
  elseif msg == "log" or msg == "journal" or msg == "afaire" or msg == "todo" then
    ToggleMainFrame("groups")
  elseif msg == "available" or msg == "dispo" then
    ToggleMainFrame("avail")
  elseif msg == "settings" or msg == "config" or msg == "reglages" or msg == "réglages" then
    Geo.ToggleSettings()
  elseif msg == "export" then
    ToggleMainFrame("export")
  else
    ToggleMainFrame()
  end
end
