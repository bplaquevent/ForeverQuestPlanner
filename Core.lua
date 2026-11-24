-- Forever Quest Planner (formerly Forever Quest Export)
-- 1. Copies the character's quest log into ForeverQuestPlannerDB.
--    The game writes this table to disk on every /reload or logout:
--      WTF/Account/<ACCOUNT>/SavedVariables/ForeverQuestPlanner.lua
-- 2. Analysis window: Roadbook, around me, quest log, available quests, text export.
-- 3. Requires QuestieDB (quest chains, classes, professions, zones, NPCs, XP) and OpenMap
--    (flight network, boats and zeppelins, zone and dungeon levels): both are read directly.

local ADDON_NAME, ns = ...
ns = ns or {}
-- Localization: English by default, other languages in Locales/*.lua.
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
local PREFIX = "|cff33ccffForeverQuestPlanner|r: "

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

local function CharKey()
  local name, realm = UnitFullName("player")
  realm = realm or (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
  return (name or "?") .. "-" .. (realm or "?")
end

-- What FQP saves is per character: ForeverQuestPlannerSettings.chars[CharKey()]; only what it learns
-- about the world, true for every character, is shared (SharedData).
-- Former versions saved most settings for the whole account: each character takes them over once,
-- at its first use (its own entries of the tables keyed by character move to it, the other values
-- are copied as its defaults), except the values tied to another character.
local CHAR_TABLES = { roadbook = true, bind = true, pins = true, mapSaved = true, activeRoadbook = true,
  custom = true, roadbookMigrated = true }
local NOT_INHERITED = { chars = true, shared = true, passes = true, teleportArrivals = true, goal = true, goalLevel = true, mountSpeed = true, lastTab = true,
  horizon = true, keep = true, excluded = true, taxi = true, rewardFilter = true, collapsed = true, focus = true }

local function DeepCopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = DeepCopy(x) end
  return t
end

local function MigrateSettings(root, key)
  local st = {}
  for k, v in pairs(root) do
    if CHAR_TABLES[k] then
      if type(v) == "table" then
        st[k] = {}
        for sub, val in pairs(v) do
          if sub == key or sub == key .. "|custom" then
            st[k][sub] = val
            v[sub] = nil
          end
        end
      end
    elseif not NOT_INHERITED[k] then
      st[k] = DeepCopy(v)
    end
  end
  -- The session duration is a preference; a level goal is only taken over by a character below it
  -- (the one that set it: the others, above it, could not use it).
  local level = UnitLevel and UnitLevel("player") or 0
  if root.goalLevel and root.goalLevel > level then st.goalLevel = root.goalLevel end
  local g = root.goal
  if type(g) == "table" and (g.kind == "time" or (g.kind == "level" and (g.value or 0) > level)) then
    st.goal = DeepCopy(g)
  end
  return st
end

-- Learned about the world, shared by every character: zone passes walked ({ c, x, y, a, b, n }) and
-- the places really reached by the teleport spells (spell -> point). Created once from what was saved
-- before (account-wide, then per character in 2.56.16): the same pass seen twice is kept once.
local function SharedData()
  local root = ForeverQuestPlannerSettings
  if type(root) ~= "table" then
    root = {}
    ForeverQuestPlannerSettings = root
  end
  if root.shared then return root.shared end
  local shared = { passes = {}, teleportArrivals = {} }
  local function take(t)
    if type(t) ~= "table" then return end
    for _, ps in ipairs(type(t.passes) == "table" and t.passes or {}) do
      local same
      for _, q in ipairs(shared.passes) do
        if q.a == ps.a and q.b == ps.b and q.c == ps.c and math.abs(q.x - ps.x) < 150 and math.abs(q.y - ps.y) < 150 then
          same = q
          break
        end
      end
      if same then same.n = math.max(same.n or 1, ps.n or 1) else table.insert(shared.passes, ps) end
    end
    for spell, p in pairs(type(t.teleportArrivals) == "table" and t.teleportArrivals or {}) do
      shared.teleportArrivals[spell] = shared.teleportArrivals[spell] or p
    end
    t.passes, t.teleportArrivals = nil, nil
  end
  take(root)
  for _, st in pairs(root.chars or {}) do take(st) end
  root.shared = shared
  return shared
end

local settingsCache = {}
local function Settings()
  local root = ForeverQuestPlannerSettings
  if type(root) ~= "table" then
    root = {}
    ForeverQuestPlannerSettings = root
  end
  if settingsCache.root == root then return settingsCache.st end
  root.chars = root.chars or {}
  local key = CharKey()
  local st = root.chars[key]
  if not st then
    st = MigrateSettings(root, key)
    root.chars[key] = st
  end
  -- Cached once the character is fully known (name and realm).
  if not (key:find("^%?%-") or key:find("%-%?$")) then settingsCache.root, settingsCache.st = root, st end
  return st
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
-- Dependencies: QuestieDB and OpenMap (required, checked by InitDeps at login)
---------------------------------------------------------------------------
local QDB = {}
local State = {} -- mutable state shared by the addon files (window, tabs, Roadbook horizon)
local K = {} -- tuning constants (avoids the 200 local variables limit)
-- Transport mode names (internal ids -> displayed text).
K.MODE_NAME = { vol = L["flight"], zeppelin = L["zeppelin"], bateau = L["boat"], airship = L["airship"] }
K.MAX_LEVEL_GAP = 2 -- difficulty: quest level at most this many levels above (or below) yours (+1 for quests already in the log)
K.MAX_ELITE_GAP = -2 -- same for elite quests, usually too hard alone at your level
-- Technical search bound: quests whose required level is up to this many levels above yours are
-- examined, but a quest only enters the Roadbook from the step where the expected level reaches its
-- required level (checked by the solver's evaluation).
K.LOOKAHEAD_LEVELS = 5
K.MAX_QUESTS = 40 -- quest log size on the Forever server

-- Quest categories (QuestieDB sorts) and profession headers: Data/Supplements.lua.
local CLASS_SORTS, PROF_SORTS, EVENT_SORTS = ns.SORT_CLASS, ns.SORT_PROFESSION, ns.SORT_EVENT
local PROF_HEADERS = ns.PROFESSION_HEADERS

-- QuestieDB codes: objective NPC icons meaning "talk to", creature ranks (1 elite, 2 rare elite, 3 boss,
-- 4 rare) of the monsters that make a quest elite, and of the NPCs met once (to assassinate).
K.TALK_ICONS = { [3] = true, [5] = true, [17] = true }
K.ELITE_RANKS = { [1] = true, [2] = true, [3] = true }
K.UNIQUE_RANKS = { [2] = true, [3] = true, [4] = true }

local function QGet(entity, id, key)
  if not entity or not id then return nil end
  local ok, v = pcall(entity.Get, id, key)
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

-- OpenMap: its Forever data (flight network, boats, dungeon entrances, zone levels) and its
-- world map module (learned flight paths, level colours). These tables are OpenMap's own, not
-- its documented API: their shape is checked here so a change is reported instead of failing later.
-- Returns nil or an error message.
local OM = {}
local function InitOpenMap()
  local om = rawget(_G, "OpenMap")
  if type(om) ~= "table" then return L["OpenMap is not loaded."] end
  local fl, pl, lv = om.MapFlights, om.MapPlaces, om.MapLevels
  local okM, wm = pcall(function() return om:GetModule("worldmap") end)
  local function bad(what) return L["OpenMap version not supported (data changed: "] .. what .. ")." end
  if not (type(fl) == "table" and type(fl.nodes) == "table" and type(fl.paths) == "table") then return bad("MapFlights") end
  local _, n = next(fl.nodes)
  if not (type(n) == "table" and type(n[2]) == "number" and type(n[3]) == "number" and type(n[5]) == "number") then return bad("MapFlights.nodes") end
  local e = fl.paths[1]
  if not (type(e) == "table" and type(e[1]) == "number" and type(e[2]) == "number" and type(e[3]) == "number") then return bad("MapFlights.paths") end
  if not (type(pl) == "table" and type(pl.transports) == "table" and type(pl.instances) == "table") then return bad("MapPlaces") end
  local t = pl.transports[1]
  if not (type(t) == "table" and type(t[1]) == "string" and type(t[2]) == "string" and type(t[4]) == "number") then return bad("MapPlaces.transports") end
  local i = pl.instances[1]
  if not (type(i) == "table" and type(i[4]) == "table" and type(i[4][1]) == "table") then return bad("MapPlaces.instances") end
  if type(lv) ~= "table" then return bad("MapLevels") end
  if not (okM and type(wm) == "table" and type(wm.LevelColor) == "function") then return bad("worldmap") end
  -- Map pins and drawing (RoadbookMap.lua): its waypoint and pins (worldmap module), its stitched
  -- map's pin sets and lines (MapStitch), and its public API (OpenMapAPI).
  for _, name in ipairs({ "TrackPoint", "ClearPin", "WaypointPoint", "RefreshWaypoint", "PinsHidden", "SetPinsHidden",
    "AddPin", "DropWaypoint", "SetPinMode", "PinAt" }) do
    if type(wm[name]) ~= "function" then return bad("worldmap." .. name) end
  end
  local S, api = om.MapStitch, rawget(_G, "OpenMapAPI")
  if type(S) ~= "table" then return bad("MapStitch") end
  for _, name in ipairs({ "PinSet", "AddPin", "AddLine", "ClearPinSet", "FromYards", "IsBuilt" }) do
    if type(S[name]) ~= "function" then return bad("MapStitch." .. name) end
  end
  if not (type(api) == "table" and api.major == 1 and (api.version or 0) >= 2) then return bad("OpenMapAPI") end
  OM.flights, OM.places, OM.levels, OM.worldmap, OM.stitch, OM.api = fl, pl, lv, wm, S, api
end

-- Both dependencies; nil when ready, otherwise the error message.
local function InitDeps()
  return InitQuestieDB() or InitOpenMap()
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
  local ok, ids = pcall(entity.GetAllIds)
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
  local now = GetTime and GetTime() or 0
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
  for areaId in pairs(QDB.dungeonOf) do
    local n = AreaName(areaId)
    if n then dungeonNameSet[n] = true end
  end
  return dungeonNameSet
end

local function DungeonOf(q)
  if q.instanceName then return q.instanceName end
  if q.zone and DungeonNames()[q.zone] then return q.zone end
  if q.isInstance then return q.zone or L["Dungeon"] end
  for _, word in ipairs(q.tag and ns.DUNGEON_TAG_WORDS or {}) do
    if q.tag:find(word) then return q.zone or L["Dungeon"] end
  end
  return nil
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

K.LATER_GAP = 3 -- a quest more than this many levels above yours is for later (professions apart)

-- Category of a quest, the first that applies: "dungeon" (name), "later", "zone" Professions or
-- Class; else "zone" with no name (the caller's zone of the quest). dungeon: its name, or nil.
local function QuestCategory(dungeon, level, plevel, isProf, isClass)
  if dungeon then return "dungeon", dungeon end
  if level > plevel + K.LATER_GAP and not isProf then return "later" end
  if isProf then return "zone", L["Professions"] end
  if isClass then return "zone", L["Class"] end
  return "zone", nil
end

local function Analyze()
  Snapshot()
  local e = LogRecord()
  local result = { abandon = {}, turnIn = {}, groups = {}, later = {}, dungeons = {} }
  State.abandonIds = {} -- for the icon in front of the titles (Geo.ToAbandon)
  local byDungeon = {}
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
      why[#why + 1] = trivial and (L["gray (level "] .. level .. ")") or L["no XP"]
      why[#why + 1] = L["no useful item"]
      why[#why + 1] = (q.money and q.money > 0) and (L["little money ("] .. MoneyText(q.money) .. ")") or L["no money"]
      if chain and chain.count > 0 then
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
      local kind, name = QuestCategory(DungeonOf(q), level, plevel, isProf, isClass)
      if kind == "dungeon" then
        local g = byDungeon[name]
        if not g then
          g = { name = name, instance = true, quests = {} }
          byDungeon[name] = g
          result.dungeons[#result.dungeons + 1] = g
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
ns.DBXP, ns.EVENT_SORTS, ns.GetItemInfoCompat, ns.GetObjectives, ns.GiverText = DBXP, EVENT_SORTS, GetItemInfoCompat, GetObjectives, GiverText
ns.HasBit, ns.InitDeps, ns.IsClassMeta, ns.IsCompleted, ns.IsInLog, ns.IsProfMeta = HasBit, InitDeps, IsClassMeta, IsCompleted, IsInLog, IsProfMeta
ns.K, ns.L, ns.MoneyText, ns.NextQuests, ns.PlayerBits = K, L, MoneyText, NextQuests, PlayerBits
ns.PlayerSkills, ns.Print, ns.QDB, ns.QGet, ns.QuestMeta, ns.RemainingObjectives = PlayerSkills, Print, QDB, QGet, QuestMeta, RemainingObjectives
ns.ScheduleSnapshot, ns.Settings, ns.Snapshot, ns.State, ns.TrivialRange = ScheduleSnapshot, Settings, Snapshot, State, TrivialRange
ns.OM, ns.SharedData, ns.TurnInText = OM, SharedData, TurnInText
ns.AllPrereqs, ns.QuestPrereqs = AllPrereqs, QuestPrereqs
ns.LogById, ns.LogEntry, ns.LogQuests, ns.LogRecord = LogById, LogEntry, LogQuests, LogRecord
ns.AllIds, ns.NpcFriendly, ns.PlayerFaction, ns.QuestAllowed = AllIds, NpcFriendly, PlayerFaction, QuestAllowed
ns.WornItemLevel = WornItemLevel
ns.QuestCategory = QuestCategory
ns.FormatNumber, ns.FormatTime = FormatNumber, FormatTime
ns.IsQuestComplete = IsQuestComplete
ns.SkillName = SkillName
