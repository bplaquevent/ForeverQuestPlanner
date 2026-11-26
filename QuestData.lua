-- Forever Quest Planner: QuestieDB (required, with OpenMap) and the fixed data of the quests: what
-- they require, their follow-ups, their givers; the character facing them (race, class, professions).

local ADDON_NAME, ns = ...
local Guard, HasBit, IsCompleted, L = ns.Guard, ns.HasBit, ns.IsCompleted, ns.L

local QDB = {}
-- Quest categories (QuestieDB sorts) and profession headers: Data/Supplements.lua.
local CLASS_SORTS, PROF_SORTS, EVENT_SORTS = ns.SORT_CLASS, ns.SORT_PROFESSION, ns.SORT_EVENT
local PROF_HEADERS = ns.PROFESSION_HEADERS

local function QGet(entity, id, key)
  if not entity or not id then return nil end
  local ok, v = Guard(entity.Get, id, key)
  if ok then return v end
  return nil
end

-- QuestieDB: LibQuestieDB, consumer contract 4. Returns nil or an error message.
local function InitQuestieDB()
  local lib = rawget(_G, "LibQuestieDB")
  if not (lib and lib.RequireContract) then return L["QuestieDB is not loaded."] end
  local ok, msg = lib.RequireContract(4)
  if not ok then return L["QuestieDB found but incompatible: "] .. tostring(msg) end
  QDB.Quest, QDB.Npc, QDB.Object, QDB.Item = lib.Quest, lib.Npc, lib.Object, lib.Item
  local okX, xpMod = pcall(lib.Support.Get, "QuestXP")
  local okZ, zoneMod = pcall(lib.Support.Get, "ZoneDB")
  if not (okX and type(xpMod) == "table" and type(xpMod.db) == "table") then
    return L["QuestieDB found but incompatible: "] .. "QuestXP"
  end
  if not (okZ and type(zoneMod) == "table" and type(zoneMod.private) == "table" and type(zoneMod.private.dungeons) == "table") then
    return L["QuestieDB found but incompatible: "] .. "ZoneDB"
  end
  QDB.xp = xpMod.db
  QDB.dungeons = zoneMod.private.dungeons
  QDB.zonePrivate = zoneMod.private
  QDB.lib = lib

  -- Zone (or alternate zone) -> dungeon id
  QDB.dungeonOf = {}
  for areaId, entry in pairs(QDB.dungeons) do
    QDB.dungeonOf[areaId] = areaId
    if type(entry[2]) == "table" then
      for _, alt in ipairs(entry[2]) do QDB.dungeonOf[alt] = areaId end
    end
  end

  QDB.raceMasks = lib.Enum.raceMaskById
end

-- Both dependencies; nil when ready, otherwise the error message.
local function InitDeps()
  return InitQuestieDB() or ns.OM.Init() -- OpenMapLink.lua, loaded next
end

local function AreaName(areaId)
  if not areaId or areaId <= 0 then return nil end
  if C_Map and C_Map.GetAreaInfo then
    local n = C_Map.GetAreaInfo(areaId)
    if n and n ~= "" then return n end
  end
  local d = QDB.dungeons[areaId]
  if d then return d[1] end
  return L["Zone "] .. areaId
end

local function PlayerBits()
  local _, _, classID = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  local classBit = classID and 2 ^ (classID - 1) or nil
  local raceBit = raceID and (QDB.raceMasks[raceID] or 2 ^ (raceID - 1)) or nil
  return classBit, raceBit
end

-- Ids of a QuestieDB table as a list (some versions give a set); nil if they cannot be read.
local function AllIds(entity)
  local ok, ids = Guard(entity.GetAllIds)
  if not ok or type(ids) ~= "table" then return nil end
  if #ids == 0 and next(ids) then
    local list = {}
    for k in pairs(ids) do list[#list + 1] = k end
    ids = list
  end
  return ids
end

-- The character's faction as QuestieDB's friendlyToFaction: "A" (Alliance) or "H" (Horde); nil if unknown.
local function PlayerFaction()
  local f = UnitFactionGroup and UnitFactionGroup("player")
  return (f == "Alliance" and "A") or (f == "Horde" and "H") or nil
end

-- Is the NPC friendly to the character's faction? nil when unknown (no data, or no faction).
local function NpcFriendly(npcId)
  local letter, friendly = PlayerFaction(), QGet(QDB.Npc, npcId, "friendlyToFaction")
  if not letter or type(friendly) ~= "string" then return nil end
  return friendly:find(letter, 1, true) ~= nil
end

-- Prerequisites of a quest in QuestieDB (its types, Types/Meta.t.lua): every one of preQuestGroup is
-- required, one of the preQuestSingle alternatives is enough. Returns all, any (empty when none).
local function QuestPrereqs(id)
  local all, any = QGet(QDB.Quest, id, "preQuestGroup"), QGet(QDB.Quest, id, "preQuestSingle")
  return type(all) == "table" and all or {}, type(any) == "table" and any or {}
end

-- Every prerequisite of both kinds, in one list (order of the steps, "follows a quest").
local function AllPrereqs(id)
  local all, any = QuestPrereqs(id)
  local out = {}
  for _, p in ipairs(all) do out[#out + 1] = p end
  for _, p in ipairs(any) do out[#out + 1] = p end
  return out
end

-- Static quest data, cached.
local metaCache = {}
local function QuestMeta(id)
  if not id then return nil end
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

-- Can this class and race (bits, PlayerBits) do the quest? A quest unknown to QuestieDB: yes.
local function QuestAllowed(id, classBit, raceBit)
  local m = QuestMeta(id)
  return not m or AllowedForPlayer(m, classBit, raceBit)
end

-- Estimated XP at the current level (formula used by Questie, without temporary bonuses).
local function DBXP(id, plevel)
  local row = QDB.xp[id]
  if not row then return nil end
  return ns.Solver.QuestXP(row[1], row[2], plevel, GetMaxPlayerLevel and GetMaxPlayerLevel() or nil)
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
  local s = string.format(L["follow-up: %d quest(s) up to level %d"], chain.count, chain.maxLevel)
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

-- Where an item that starts a quest drops: monster or object, with its zone (name, zone), or nil.
local function ItemSource(itemId)
  local drops = QGet(QDB.Item, itemId, "npcDrops")
  local entity, id = QDB.Npc, type(drops) == "table" and drops[1] or nil
  if not id then
    drops = QGet(QDB.Item, itemId, "objectDrops")
    entity, id = QDB.Object, type(drops) == "table" and drops[1] or nil
  end
  if not id then return nil, nil end
  local name, zone = SpawnPlace(entity, id)
  return name, zone
end

-- givers = {npcIds?, objectIds?, itemIds?}. An item that starts the quest comes first: it is what
-- gives it, with where it drops (a quest also listing an NPC is a data conflict, the item wins).
local function GiverText(givers)
  if type(givers) ~= "table" then return nil, nil end
  if type(givers[3]) == "table" and givers[3][1] then
    local name = QGet(QDB.Item, givers[3][1], "name")
    if name then
      local src, zone = ItemSource(givers[3][1])
      local also = (type(givers[1]) == "table" and givers[1][1]) or (type(givers[2]) == "table" and givers[2][1])
      -- The zone of the quest follows the drop only when an NPC was listed too (it was that NPC's zone).
      return L["object: "] .. name .. (src and (" (" .. src .. (zone and (" - " .. zone) or "") .. ")") or ""), also and zone or nil
    end
  end
  if type(givers[1]) == "table" and givers[1][1] then
    local name, zone, x, y = SpawnPlace(QDB.Npc, givers[1][1])
    return PlaceText(name, zone, x, y), zone
  end
  if type(givers[2]) == "table" and givers[2][1] then
    local name, zone, x, y = SpawnPlace(QDB.Object, givers[2][1])
    return PlaceText(name, zone, x, y), zone
  end
  return nil, nil
end

local function TurnInText(id)
  return (GiverText(QGet(QDB.Quest, id, "finishedBy")))
end

-- Name of a profession (Data/GameData.lua), nil if unknown.
local function SkillName(id)
  local p = ns.PROFESSIONS[id]
  return p and p.name
end

-- Professions known by the character: skillLine -> rank, localized names, and whether reading succeeded.
-- Forever uses C_SkillInfo (like Questie); the other APIs are fallbacks.
local skillCache, skillCacheTime = nil, 0
local function PlayerSkills(fresh) -- fresh: read again (a skill changed)
  local now = GetTime()
  if not fresh and skillCache and now - skillCacheTime < 5 then return skillCache[1], skillCache[2], skillCache[3] end
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
      if line and not line.isHeader and line.skillID and ns.PROFESSIONS[line.skillID] then
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

-- Shared with the next files.
ns.AllIds, ns.AllPrereqs, ns.AreaName, ns.ChainInfo, ns.ChainText = AllIds, AllPrereqs, AreaName, ChainInfo, ChainText
ns.DBXP, ns.EVENT_SORTS, ns.GiverText, ns.InitDeps = DBXP, EVENT_SORTS, GiverText, InitDeps
ns.IsClassMeta, ns.IsProfMeta, ns.IsProfessionHeader = IsClassMeta, IsProfMeta, IsProfessionHeader
ns.NextQuests, ns.NpcFriendly, ns.PlayerBits, ns.PlayerFaction = NextQuests, NpcFriendly, PlayerBits, PlayerFaction
ns.PlayerSkills, ns.QDB, ns.QGet, ns.QuestAllowed, ns.QuestMeta = PlayerSkills, QDB, QGet, QuestAllowed, QuestMeta
ns.QuestPrereqs, ns.SkillName, ns.TurnInText = QuestPrereqs, SkillName, TurnInText
