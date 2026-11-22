-- Forever Quest Planner: Roadbook: XP and travel time model, monster spots, priorities.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AllInstance, AreaName, ChainInfo, CharKey, CheckAvailable, DBXP = ns.AllInstance, ns.AreaName, ns.ChainInfo, ns.CharKey, ns.CheckAvailable, ns.DBXP
local Dist, EntityPoints, EquippedItemLevel, Geo, GetItemInfoCompat, HasBit = ns.Dist, ns.EntityPoints, ns.EquippedItemLevel, ns.Geo, ns.GetItemInfoCompat, ns.HasBit
local IsClassMeta, IsCompleted, K, L, Nearest, NextQuests = ns.IsClassMeta, ns.IsCompleted, ns.K, ns.L, ns.Nearest, ns.NextQuests
local PlayerPos, PlayerSkills, QDB, QGet, QuestMeta, QuestTargets = ns.PlayerPos, ns.PlayerSkills, ns.QDB, ns.QGet, ns.QuestMeta, ns.QuestTargets
local Refresh, RemainingTargets, Route, SLOTS, Settings, StartPoints = ns.Refresh, ns.RemainingTargets, ns.Route, ns.SLOTS, ns.Settings, ns.StartPoints
local State, TravelSpeed, TrivialRange, TurnInText, UnitTime = ns.State, ns.TravelSpeed, ns.TrivialRange, ns.TurnInText, ns.UnitTime
local OM, WorldPos, scan = ns.OM, ns.WorldPos, ns.scan
local BuildNetwork = ns.BuildNetwork

---------------------------------------------------------------------------
-- Profession level needed to turn a quest in (e.g. a profession introduction: "reach 20 in
-- Herbalism"): QuestieDB's requiredSkill, else the quest texts (QuestieDB's English ones, the
-- log's localized objectives and description) naming a profession next to a number.
---------------------------------------------------------------------------
K.SKILL_NAMES_EN = {
  [164] = "blacksmithing", [165] = "leatherworking", [171] = "alchemy", [182] = "herbalism", [185] = "cooking",
  [186] = "mining", [197] = "tailoring", [202] = "engineering", [333] = "enchanting", [356] = "fishing",
  [393] = "skinning", [129] = "first aid",
}
K.SKILL_TEXT_GAP = 30 -- characters: a number this close to a profession name is its level

function Geo.SkillFromText(text)
  text = text:lower()
  for skill, en in pairs(K.SKILL_NAMES_EN) do
    for _, name in ipairs({ en, (K.SKILL_NAMES[skill] or en):lower() }) do
      local a, b = text:find(name, 1, true)
      if a then
        local around = text:sub(math.max(1, a - K.SKILL_TEXT_GAP), b + K.SKILL_TEXT_GAP)
        for n in around:gmatch("(%d+)") do
          local v = tonumber(n)
          if v and v >= 2 and v <= 300 then return skill, v end
        end
      end
    end
  end
  return nil
end

-- { skill, need, have, name } when the character's profession level is below the one needed, nil
-- otherwise (or when it cannot be read). q: the quest log entry, if any.
function Geo.SkillNeed(id, q)
  local skills, _, known = PlayerSkills()
  if not known then return nil end
  local skill, need
  local req = QGet(QDB.Quest, id, "requiredSkill")
  if type(req) == "table" and req[1] and (req[2] or 0) > 0 then skill, need = req[1], req[2] end
  if not skill then
    local parts = {}
    local Q = QDB.Quest
    local okR, raw = false, nil
    if Q and Q.GetRaw then okR, raw = pcall(Q.GetRaw, id, "objectivesText") end
    for _, list in ipairs({ okR and raw or QGet(Q, id, "objectivesText"), q and q.objectivesText }) do
      if type(list) == "table" then
        for _, t in ipairs(list) do parts[#parts + 1] = tostring(t) end
      elseif type(list) == "string" then
        parts[#parts + 1] = list
      end
    end
    if q and type(q.description) == "string" then parts[#parts + 1] = q.description end
    for _, t in ipairs(parts) do
      skill, need = Geo.SkillFromText(t)
      if skill then break end
    end
  end
  if not skill then return nil end
  local have = skills[skill] or 0
  if have >= need then return nil end
  return { skill = skill, need = need, have = have, name = K.SKILL_NAMES[skill] or (L["profession"] .. " " .. skill) }
end

-- Warning line of a quest whose turn-in waits for a profession level.
function Geo.SkillNeedText(n)
  return string.format(L["%s %d required to turn in (you: %d)"], n.name, n.need, n.have)
end

---------------------------------------------------------------------------
-- Around me
---------------------------------------------------------------------------
State.nearRadius = 500

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
      if d and not Geo.SkillNeed(q.id, q) then
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
-- Goal of the automatic Roadbook: { kind = "time", value = s } or { kind = "level", value = level }.
State.xpGoal = { kind = "time", value = 7200 }
K.MAX_TAKE_CANDIDATES = 1500      -- safety: quests to pick up considered by the Roadbook, at most
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
Geo.MobXP = ns.Solver.MobXP

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
    local travel = Geo.WalkTime(from, sp.p, speed) or K.CROSS_CONTINENT
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
    local places = task.id and Geo.StartPlaces(task.id, pos)
    if places then
      -- Quest giver moving between places: one step per place to check (search = { i, n }), all
      -- before the objectives; those left go once the quest is picked up (Roadbook.lua).
      for i, p in ipairs(places) do
        stops[#stops + 1] = { task = task, kind = "take", p = p, work = K.OVERHEAD / 2, search = { i = i, n = #places } }
      end
      from = places[1]
    else
      local p = Nearest(t.start, pos)
      if not p then return nil end
      stops[#stops + 1] = { task = task, kind = "take", p = p, work = K.OVERHEAD / 2 }
      from = p
    end
  end
  local takes = #stops
  if task.kind ~= "turnin" then
    local todo = {}
    for _, r in ipairs(task.remaining) do todo[#todo + 1] = r end
    -- Escort: it starts at the quest giver, so it comes first, before the other objectives.
    local escortFirst = task.kind == "take" and Geo.IsEscort(task.id)
    -- Source item (QuestieDB requiredSourceItems): the objectives that use it wait for it.
    local sourced = false
    while #todo > 0 do
      local bi, bp, bd, bspot
      local onlyExplore, sourceLeft = false, false
      if escortFirst then
        for _, r in ipairs(todo) do if r.tg.kind == "explore" then onlyExplore = true end end
      end
      for _, r in ipairs(todo) do if r.tg.sourceItem then sourceLeft = true end end
      for i, r in ipairs(todo) do
        if not (onlyExplore and r.tg.kind ~= "explore") and not (sourceLeft and r.tg.needsSource) then
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
      if r.tg.sourceItem then sourced = true end
      -- After the source item: fixed place in the quest's order (not a free objective).
      if sourced and r.tg.needsSource then st.afterSource = true end
      if r.tg.kind == "explore" and Geo.IsEscort(task.id) then
        -- Escort: the NPC walks (slower than you) and ambushes happen on the way.
        local d = Dist(from, bp) or 0
        st.escort = true
        st.work = math.max(0, d / K.ESCORT_SPEED - d / TravelSpeed()) + K.ESCORT_MARGIN
        -- Right after the pick-up: nothing may come between them (glued to the previous stop).
        if task.kind == "take" and #stops == 1 and takes == 1 then st.glue = true end
      end
      stops[#stops + 1] = st
      from = bp
    end
  end
  local f = Nearest(t.finish, from)
  if not f then return nil end
  local turnin = { task = task, kind = "turnin", p = f, work = K.OVERHEAD / 2, xp = task.xp }
  -- Escort without a known destination (no completion trigger): it ends at the turn-in NPC.
  if task.kind == "take" and #stops == 1 and takes == 1 and Geo.IsEscort(task.id) then
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
    remaining = remaining, starter = en.starter }
  -- Taken on from the level expected along the route: required level and difficulty setting.
  local unlock = Geo.UnlockLevel(en)
  if not unlock then return nil end
  if unlock > plevel then task.reqLevel = unlock end
  task.stops = MakeStops(task, pos, plevel)
  if not task.stops then return nil end
  Geo.CheckLater(task, plevel)
  if task.later then
    Geo.RecordLater(task)
    return nil
  end
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
        and (Geo.UnlockLevel(en) or math.huge) <= Geo.PlanCeiling(plevel) then
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
  okIds, ids = pcall(QDB.Item.GetAllIds)
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
  if Geo.rewards or Geo.rewardsBuilding then return end
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

-- Interest of a reward item while leveling: 1 + reason, or 0 (an item useful now is not kept for max level).
function Geo.ItemInterest(itemId, plevel)
  local name, link, quality, ilvl, _, _, _, _, equipLoc, _, _, classID, subclassID = GetItemInfoCompat(itemId)
  if not name then
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemId) end
    return 0
  end
  if Geo.ItemTeachesSpell(itemId) or Geo.TeachesSkill(classID, subclassID) then
    return 1, name .. L[" (teaches a skill)"]
  end
  if equipLoc == "INVTYPE_BAG" then return 1, name .. L[" (bag)"] end
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
    if specOK then return 1, name .. L[" (blue)"] end
    return 1, name .. L[" (blue, off-spec)"]
  end
  if upgrade and specOK then return 1, name .. L[" (upgrade)"] end
  if upgrade then return 1, name .. L[" (upgrade)"] end
  return 0
end

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
      local dg = m.sort and m.sort > 0 and QDB.dungeonOf[m.sort]
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

-- Level from which the Roadbook takes a quest on: its required level, and its quest level minus the
-- allowed gap ("Difficulty" settings). nil: elite quest while elite quests are excluded.
function Geo.UnlockLevel(en)
  local gap = Geo.MaxQuestLevel(en.id, 0, 0, en.tag)
  if gap == -math.huge then return nil end
  return math.max(en.reqLevel or 0, (en.level or 0) - gap)
end

-- Highest unlock level of the quests the Roadbook considers: a few levels above yours, or up to
-- the target level of a "reach level" goal.
function Geo.PlanCeiling(plevel)
  local g = State.xpGoal
  if g and g.kind == "level" then return math.max(plevel + K.LOOKAHEAD_LEVELS, g.value - 1) end
  return plevel + K.LOOKAHEAD_LEVELS
end

-- Highest quest level the Roadbook takes on, from your level (or the required level, if higher);
-- elite quests are excluded when the "Include elite quests" option is unchecked.
function Geo.MaxQuestLevel(id, plevel, reqLevel, tag)
  local elite = Geo.IsEliteQuest(id, tag)
  if elite and Settings().noElite then return -math.huge end -- "Include elite quests" unchecked
  return math.max(plevel, reqLevel or 0) + (elite and K.MAX_ELITE_GAP or K.MAX_LEVEL_GAP)
end

-- Quest kept for max level (endgame reward or access): task.later = reason.
function Geo.CheckLater(task, plevel)
  if plevel < Geo.MaxLevel() then task.later = Geo.LaterReason(task.id, plevel) end
end

local function BuildTasks(pos, plevel)
  local tasks, skipped = {}, 0
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do
    local xp = q.xp or DBXP(q.id, plevel) or 0
    local group = q.suggestedGroup and q.suggestedGroup > 1
    local atMax = plevel >= Geo.MaxLevel()
    -- Quest ready to turn in: always a candidate (even dungeon, group, gray or high level),
    -- you only need to visit the NPC: it is a quick win.
    local ready = q.complete and not q.failed
    if Geo.SkillNeed(q.id, q) then
      skipped = skipped + 1 -- profession level too low to turn it in
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
        Geo.CheckLater(task, plevel)
        if ready then
          task.later = nil -- the objective is done: turn the quest in now
          task.quick = true
        end
        if task.later then
          Geo.RecordLater(task)
        else
          tasks[#tasks + 1] = task
        end
      else
        skipped = skipped + 1
      end
    else
      skipped = skipped + 1
    end
  end

  -- Quests to pick up: every one available up to the level the Roadbook may reach (the solver takes
  -- one on from the step where the expected level allows it), nearest first.
  local near = {}
  local ceiling = Geo.PlanCeiling(plevel)
  for _, en in ipairs(scan.entries or {}) do
    local unlock = Geo.UnlockLevel(en)
    if not en.lowLevel and not en.repMissing and not en.missing and not en.repeatable
      and ((en.xp or 0) > 0 or plevel >= Geo.MaxLevel()) and unlock and unlock <= ceiling then
      local p, d = Nearest(StartPoints(en.id), pos)
      if p then near[#near + 1] = { en = en, d = d or math.huge } end
    end
  end
  table.sort(near, function(a, b) return a.d < b.d end)
  local taken = 0
  for i, n in ipairs(near) do
    if taken >= K.MAX_TAKE_CANDIDATES then break end
    local task = Geo.TakeTask(n.en, plevel, pos)
    if task then
      tasks[#tasks + 1] = task
      taken = taken + 1
    end
    if i % 10 == 0 then Geo.Yield() end
  end
  return tasks, skipped
end

-- Cached travel time between two points (points are shared objects).
local function MakeTravel(net, plevel)
  local cache = {}
  return function(a, b)
    if a == b then return 0 end
    if b.teleport then return b.cast or K.HEARTH_TIME end -- hearthstone, teleport spell: usable from anywhere
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

K.FM_KNOWN_RADIUS = 150 -- yards: the QuestieDB flight master NPC standing at a flight node

-- Service NPCs of the player's faction (QuestieDB), read once per session:
-- flight masters (Geo.fm) and innkeepers (Geo.inn).
function Geo.ScanServices()
  if Geo.fm then return end
  Geo.fm, Geo.inn = {}, {}
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

---------------------------------------------------------------------------
-- Service NPCs of the shortcuts under the Objective button: any vendor, repair NPC, class trainer
---------------------------------------------------------------------------
-- QuestieDB npcFlags (vanilla 1.12 values, like the flight master 8 and innkeeper 128 above).
K.NPC_FLAG_VENDOR, K.NPC_FLAG_TRAINER, K.NPC_FLAG_BANKER, K.NPC_FLAG_REPAIR = 4, 16, 256, 16384
K.SERVICE_TIME = 60          -- seconds spent at a service NPC (selling, repairing, training)
K.SERVICE_NEAR = 12          -- candidates kept per continent, nearest in a straight line
K.SERVICE_CACHE = 20         -- seconds a nearest NPC stays valid (tooltips)
K.SERVICES = {
  { key = "vendor", icon = "Interface\\Icons\\INV_Misc_Coin_01", label = L["Vendor"], title = L["Sell and buy: "] },
  { key = "repair", icon = "Interface\\Icons\\Trade_BlackSmithing", label = L["Repair"], title = L["Repair: "] },
  { key = "trainer", icon = "Interface\\Icons\\INV_Misc_Book_11", label = L["Class trainer"], title = L["Train: "] },
  { key = "bank", icon = "Interface\\Icons\\INV_Misc_Bag_10_Blue", label = L["Bank"], title = L["Bank: "] },
  { key = "mail", icon = "Interface\\Icons\\INV_Letter_15", label = L["Mailbox"], title = L["Mailbox: "] },
}
-- Game event that ends the step of each service (the window of the NPC or mailbox opens).
K.SERVICE_EVENTS = { vendor = "MERCHANT_SHOW", repair = "MERCHANT_SHOW", trainer = "TRAINER_SHOW",
  bank = "BANKFRAME_OPENED", mail = "MAIL_SHOW" }

-- Ids of a QuestieDB table as a list (some versions give a set).
local function AllIds(entity)
  local okIds, ids = pcall(entity.GetAllIds)
  if not okIds or type(ids) ~= "table" then return {} end
  if #ids == 0 and next(ids) then
    local list = {}
    for k in pairs(ids) do list[#list + 1] = k end
    ids = list
  end
  return ids
end

-- Vendors, repair NPCs, class trainers and bankers of the player's faction, and mailboxes (objects),
-- read once per session (QuestieDB). Each entry: { id, name, p }.
function Geo.ServiceNpcs()
  if Geo.svc then return Geo.svc end
  local svc = { vendor = {}, repair = {}, trainer = {}, bank = {}, mail = {} }
  Geo.svc = svc
  local fac = UnitFactionGroup and UnitFactionGroup("player")
  local letter = (fac == "Horde" and "H") or (fac == "Alliance" and "A") or nil
  local classLoc, token = UnitClass("player")
  local classEn = token and (token:sub(1, 1) .. token:sub(2):lower()) or nil
  for _, id in ipairs(letter and AllIds(QDB.Npc) or {}) do
    local flags = QGet(QDB.Npc, id, "npcFlags")
    if type(flags) == "number" and flags > 0 then
      local isVendor = HasBit(flags, K.NPC_FLAG_VENDOR)
      local isRepair = HasBit(flags, K.NPC_FLAG_REPAIR)
      local isBank = HasBit(flags, K.NPC_FLAG_BANKER)
      local isTrainer = false
      if HasBit(flags, K.NPC_FLAG_TRAINER) then
        local sub = QGet(QDB.Npc, id, "subName")
        -- Case-insensitive: "Maître des paladins" must match the class "Paladin".
        local low = type(sub) == "string" and sub:lower() or nil
        isTrainer = low and ((classLoc and low:find(classLoc:lower(), 1, true))
          or (classEn and low:find(classEn:lower(), 1, true))) and true or false
      end
      if isVendor or isRepair or isTrainer or isBank then
        local friendly = QGet(QDB.Npc, id, "friendlyToFaction")
        if type(friendly) == "string" and friendly:find(letter) then
          local name = QGet(QDB.Npc, id, "name") or ("#" .. id)
          for _, p in ipairs(EntityPoints("npc", id)) do -- one entry per place it stands
            if not p.instance then
              local e = { id = id, name = name, p = p }
              if isVendor then table.insert(svc.vendor, e) end
              if isRepair then table.insert(svc.repair, e) end
              if isTrainer then table.insert(svc.trainer, e) end
              if isBank then table.insert(svc.bank, e) end
            end
          end
        end
      end
    end
  end
  -- Mailboxes: objects named "Mailbox" (no flag, neutral).
  for _, id in ipairs(AllIds(QDB.Object)) do
    local name = QGet(QDB.Object, id, "name")
    if type(name) == "string" then
      local low = name:lower()
      if low:find("mailbox", 1, true) or low:find("boîte aux lettres", 1, true) or low:find("boite aux lettres", 1, true) then
        for _, p in ipairs(EntityPoints("object", id)) do -- the same object stands in many places
          if not p.instance then table.insert(svc.mail, { id = id, name = name, p = p }) end
        end
      end
    end
  end
  return svc
end

-- Nearest NPC of a service (kind: "vendor", "repair", "trainer") by travel time on the transport
-- network: the nearest ones in a straight line on the player's continent, else on each other
-- continent the ones nearest to a flight master. Returns { id, name, p, time } or nil.
function Geo.NearestService(kind, pos)
  pos = pos or PlayerPos()
  if not pos then return nil end
  local cache = Geo.svcNear and Geo.svcNear[kind]
  local now = GetTime and GetTime() or 0
  if cache and now - cache.at < K.SERVICE_CACHE and cache.pos and (Dist(pos, cache.pos) or math.huge) < 100 then
    return cache.best
  end
  local list = Geo.ServiceNpcs()[kind] or {}
  local byCont = {}
  for _, e in ipairs(list) do
    local c = e.p.c
    byCont[c] = byCont[c] or {}
    table.insert(byCont[c], e)
  end
  local refs = {}
  local function nearest(entries, ref)
    local scored = {}
    for _, e in ipairs(entries) do
      local d = Dist(e.p, ref)
      if d then scored[#scored + 1] = { e = e, d = d } end
    end
    table.sort(scored, function(a, b) return a.d < b.d end)
    return scored
  end
  local cands = {}
  local here = byCont[pos.c]
  if here then
    for i, r in ipairs(nearest(here, pos)) do
      if i > K.SERVICE_NEAR then break end
      cands[#cands + 1] = r.e
    end
  end
  if #cands == 0 then
    for c, entries in pairs(byCont) do
      local ref
      for _, fm in ipairs(Geo.FlightMasters()) do if fm.p.c == c then ref = fm.p break end end
      if ref then
        for i, r in ipairs(nearest(entries, ref)) do
          if i > 8 then break end
          cands[#cands + 1] = r.e
        end
      end
    end
  end
  local plevel = UnitLevel("player")
  local travel = MakeTravel(BuildNetwork(TravelSpeed()), plevel)
  local best
  for _, e in ipairs(cands) do
    local t = travel(pos, e.p)
    if t and t < math.huge and (not best or t < best.time) then
      best = { id = e.id, name = e.name, p = e.p, time = t }
    end
  end
  Geo.svcNear = Geo.svcNear or {}
  Geo.svcNear[kind] = { at = now, pos = pos, best = best }
  return best
end

-- Flight masters the character can use: OpenMap's flight nodes (Forever's tables: faction, class),
-- each with the QuestieDB flight master NPC standing there (name, map pin) when there is one.
function Geo.FlightMasters()
  if Geo.fmNodes then return Geo.fmNodes end
  Geo.ScanServices()
  local out = {}
  for id in pairs(OM.flights.nodes) do
    if Geo.NodeUsable(id) then
      local np = Geo.NodePoint(id)
      local npc, nd
      for _, fm in ipairs(Geo.fm or {}) do
        local d = Dist(fm.p, np)
        if d and d < K.FM_KNOWN_RADIUS and (not nd or d < nd) then npc, nd = fm, d end
      end
      if not npc then np.zoneName = Geo.NodeName(id) end
      out[#out + 1] = { id = npc and npc.id or ("node" .. id), node = id, name = npc and npc.name or Geo.NodeName(id),
        p = npc and npc.p or np }
    end
  end
  Geo.fmNodes = out
  return out
end

function Geo.Innkeepers()
  Geo.ScanServices()
  return Geo.inn or {}
end

-- Shared with the next files.
ns.BuildTasks, ns.CurrentMapSet, ns.MakeStops, ns.MakeTravel, ns.NearItems = BuildTasks, CurrentMapSet, MakeStops, MakeTravel, NearItems
