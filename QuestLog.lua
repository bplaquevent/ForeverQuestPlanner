-- Forever Quest Planner: the capture of the quest log (Snapshot) and how it is read.

local ADDON_NAME, ns = ...
local AreaName, CharKey, CleanText, DBXP, L, Print = ns.AreaName, ns.CharKey, ns.CleanText, ns.DBXP, ns.L, ns.Print
local QDB, QuestMeta = ns.QDB, ns.QuestMeta

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

-- Quest description text (requires "selecting" it in the quest log). Kept per quest: selecting quests
-- of the game's quest log from the addon taints Blizzard's quest UI, so it is done once per quest.
local questTexts = {} -- questID -> { desc, objText }
local function GetQuestTexts(questID)
  local cached = questTexts[questID]
  if cached then return cached[1], cached[2] end
  if not (C_QuestLog.SetSelectedQuest and GetQuestLogQuestText) then return nil, nil end
  local previous = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
  local ok, desc, objText = pcall(function()
    C_QuestLog.SetSelectedQuest(questID)
    return GetQuestLogQuestText()
  end)
  if previous and previous ~= 0 then pcall(C_QuestLog.SetSelectedQuest, previous) end
  if ok then
    if desc and desc ~= "" then questTexts[questID] = { desc, objText } end
    return desc, objText
  end
  return nil, nil
end

local function GetXP(questID)
  if GetQuestLogRewardXP then
    local ok, xp = pcall(GetQuestLogRewardXP, questID)
    if ok and xp and xp > 0 then return xp end
  end
  return DBXP(questID, UnitLevel("player"))
end

-- The game's tag of a quest ({ tagID, tagName }), or nil: none, or the quest is out of the log and
-- its data are not loaded (QuestTags.lua).
local function GameTag(questID)
  if not C_QuestLog.GetQuestTagInfo then return nil end
  local ok, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)
  return ok and tag or nil
end

-- "pvp", "raid" or "dungeon" when the tag says so, otherwise nil.
local function TagKind(tag)
  if not (tag and Enum and Enum.QuestTag) then return nil end
  if tag.tagID == Enum.QuestTag.PvP then return "pvp" end
  if tag.tagID == Enum.QuestTag.Raid then return "raid" end
  if tag.tagID == Enum.QuestTag.Dungeon then return "dungeon" end
  return nil
end

-- Zone where the objectives take place, whether it is an instance (map type, QuestieDB), and what the
-- game tag says: its name, elite, kind.
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
  local tag = GameTag(questID)
  -- "Group" is shown as "Elite" by the game
  local gameElite = tag and Enum and Enum.QuestTag and tag.tagID == Enum.QuestTag.Group or nil
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
  return mapZone, isInstance, tag and tag.tagName or nil, instanceName, gameElite, TagKind(tag)
end

-- The character's last quest log capture (Snapshot), or nil.
local function LogRecord()
  return ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
end

local function LogQuests()
  local e = LogRecord()
  return e and e.quests or {}
end

-- Captured quests by id.
local function LogById()
  local out = {}
  for _, q in ipairs(LogQuests()) do out[q.id] = q end
  return out
end

-- Captured quest, or nil.
local function LogEntry(id)
  for _, q in ipairs(LogQuests()) do
    if q.id == id then return q end
  end
  return nil
end

-- Complete in the game (ready to turn in).
local function IsQuestComplete(id)
  return C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) or false
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
        local mapZone, isInstance, tagName, instanceName, gameElite, gameKind = GetQuestPlace(id)
        quests[#quests + 1] = {
          id = id,
          title = info.title,
          zone = header,
          mapZone = mapZone,
          isInstance = isInstance,
          instanceName = instanceName,
          tag = tagName,
          gameElite = gameElite,
          gameKind = gameKind,
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
          complete = IsQuestComplete(id),
          failed = C_QuestLog.IsFailed and C_QuestLog.IsFailed(id) or false,
          objectives = GetObjectives(id),
          objectivesText = objText,
          description = desc,
        }
      end
    end
  end

  -- The game can return no objectives (and level 0) for a while, at logout for instance: the ones of
  -- the last capture stay, otherwise the next plans would take every objective as still to do.
  local before = LogById()
  for _, q in ipairs(quests) do
    local b = before[q.id]
    if b then
      if #q.objectives == 0 and not q.complete and #(b.objectives or {}) > 0 then q.objectives = b.objectives end
      if (q.level or 0) == 0 and (b.level or 0) > 0 then q.level = b.level end
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

-- Shared with the next files.
ns.GameTag, ns.GetObjectives, ns.IsQuestComplete, ns.LogById = GameTag, GetObjectives, IsQuestComplete, LogById
ns.LogEntry, ns.LogQuests, ns.LogRecord, ns.ScheduleSnapshot = LogEntry, LogQuests, LogRecord, ScheduleSnapshot
ns.Snapshot, ns.TagKind = Snapshot, TagKind
