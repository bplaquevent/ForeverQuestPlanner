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
  ForeverQuestPlannerSettings.keep = nil -- old "Keep" list, removed
  ForeverQuestPlannerSettings.excluded = nil -- old global list of removed quests (now kept per Roadbook)
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
local State = {} -- mutable state shared by the addon files (window, tabs, Roadbook horizon)
local K = {} -- tuning constants (avoids the 200 local variables limit)
-- Transport mode names (internal ids -> displayed text).
K.MODE_NAME = { vol = L["flight"], zeppelin = L["zeppelin"], bateau = L["boat"] }
K.MAX_LEVEL_GAP = 2 -- difficulty: quest level at most this many levels above (or below) yours (+1 for quests already in the log)
K.MAX_ELITE_GAP = -2 -- same for elite quests, usually too hard alone at your level
-- Technical search bound: quests whose required level is up to this many levels above yours are
-- examined, but a quest only enters the Roadbook from the step where the expected level reaches its
-- required level (see Geo.StartIndex).
K.LOOKAHEAD_LEVELS = 5
K.MAX_QUESTS = 40 -- quest log size on the Forever server

local CLASS_SORTS = { [-395] = true, [-372] = true, [-263] = true, [-262] = true, [-261] = true, [-162] = true,
  [-161] = true, [-141] = true, [-82] = true, [-81] = true, [-61] = true }
-- Profession quest categories. Forever: -666 = "Camping" ("Camping 101: …"), 16941 = "Crafting"
-- (a QuestieDB area grouping the "Craftsman's Writ" quests, no actual place).
local PROF_SORTS = { [-398] = true, [-377] = true, [-373] = true, [-371] = true, [-324] = true, [-304] = true,
  [-264] = true, [-201] = true, [-182] = true, [-181] = true, [-121] = true, [-101] = true, [-24] = true,
  [-666] = true, [16941] = true }
local EVENT_SORTS = { [-1000] = true, [-404] = true, [-402] = true, [-378] = true, [-376] = true, [-375] = true,
  [-374] = true, [-370] = true, [-369] = true, [-366] = true, [-364] = true, [-41] = true, [-22] = true,
  [-21] = true, [-368] = true, [-365] = true, [-241] = true }
-- Battleground quest areas: Alterac Valley, Warsong Gulch, Arathi Basin, Darkspear Islands (Forever).
K.PVP_SORTS = { [-25] = true, [2597] = true, [3277] = true, [3358] = true, [16606] = true }
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
  return table.concat(parts, " · ")
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
  local result = { abandon = {}, turnIn = {}, groups = {}, later = {}, dungeons = {} }
  State.abandonIds = {} -- for the icon in front of the titles (Geo.ToAbandon)
  local byDungeon = {}
  if not e then return result end
  result.count = #e.quests

  local plevel = UnitLevel("player")
  local className = UnitClass("player")
  local range = TrivialRange()
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
      if q.failed then
        q._abandon = L["Failed quest"]
      elseif not (isClass or isProf or xpUseful or itemReason or itemUnknown or chainUseful or moneyUseful) then
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
      if q._abandon then
        result.abandon[#result.abandon + 1] = { quest = q, reason = q._abandon }
        State.abandonIds[q.id] = true
      end
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

-- Shared with the next files.
ns.Analyze, ns.AreaName, ns.ChainInfo, ns.ChainText, ns.CharKey, ns.Color = Analyze, AreaName, ChainInfo, ChainText, CharKey, Color
ns.DBXP, ns.EVENT_SORTS, ns.EquippedItemLevel, ns.GetItemInfoCompat, ns.GetObjectives, ns.GiverText = DBXP, EVENT_SORTS, EquippedItemLevel, GetItemInfoCompat, GetObjectives, GiverText
ns.HasBit, ns.InitQuestieDB, ns.IsClassMeta, ns.IsCompleted, ns.IsInLog, ns.IsProfMeta = HasBit, InitQuestieDB, IsClassMeta, IsCompleted, IsInLog, IsProfMeta
ns.K, ns.L, ns.MoneyText, ns.NextQuests, ns.PROFESSION_SKILLS, ns.PlayerBits = K, L, MoneyText, NextQuests, PROFESSION_SKILLS, PlayerBits
ns.PlayerSkills, ns.Print, ns.QDB, ns.QGet, ns.QuestMeta, ns.RemainingObjectives = PlayerSkills, Print, QDB, QGet, QuestMeta, RemainingObjectives
ns.SLOTS, ns.ScheduleSnapshot, ns.Settings, ns.Snapshot, ns.State, ns.TrivialRange = SLOTS, ScheduleSnapshot, Settings, Snapshot, State, TrivialRange
ns.TurnInText = TurnInText
