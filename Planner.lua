-- Forever Quest Planner: Roadbook: XP and travel time model, monster spots, priorities.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AllInstance, AreaName, ChainInfo, CharKey, CheckAvailable, DBXP = ns.AllInstance, ns.AreaName, ns.ChainInfo, ns.CharKey, ns.CheckAvailable, ns.DBXP
local Dist, EntityPoints, EquippedItemLevel, Geo, GetItemInfoCompat, HasBit = ns.Dist, ns.EntityPoints, ns.EquippedItemLevel, ns.Geo, ns.GetItemInfoCompat, ns.HasBit
local IsClassMeta, IsCompleted, K, L, Nearest, NextQuests = ns.IsClassMeta, ns.IsCompleted, ns.K, ns.L, ns.Nearest, ns.NextQuests
local PlayerPos, PlayerSkills, QDB, QGet, QuestMeta, QuestTargets = ns.PlayerPos, ns.PlayerSkills, ns.QDB, ns.QGet, ns.QuestMeta, ns.QuestTargets
local Refresh, RemainingTargets, Route, SLOTS, Settings, StartPoints = ns.Refresh, ns.RemainingTargets, ns.Route, ns.SLOTS, ns.Settings, ns.StartPoints
local State, TaxiStore, TravelSpeed, TrivialRange, TurnInText, UnitTime = ns.State, ns.TaxiStore, ns.TravelSpeed, ns.TrivialRange, ns.TurnInText, ns.UnitTime
local WorldPos, scan = ns.WorldPos, ns.scan

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
State.xpHorizon = 7200
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

-- Shared with the next files.
ns.BuildTasks, ns.CurrentMapSet, ns.InsertStops, ns.MakeTravel, ns.NearItems = BuildTasks, CurrentMapSet, InsertStops, MakeTravel, NearItems
