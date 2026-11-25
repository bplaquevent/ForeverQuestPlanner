-- Forever Quest Planner: Roadbook: XP and travel time model, monster spots, priorities.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AllInstance, CheckAvailable, DBXP, Dist, Geo, K, L = ns.AllInstance, ns.CheckAvailable, ns.DBXP, ns.Dist, ns.Geo, ns.K, ns.L
local Nearest, NextQuests, PlayerPos, PlayerSkills, QDB, QGet = ns.Nearest, ns.NextQuests, ns.PlayerPos, ns.PlayerSkills, ns.QDB, ns.QGet
local QuestMeta, QuestTargets, AllPrereqs, RemainingTargets = ns.QuestMeta, ns.QuestTargets, ns.AllPrereqs, ns.RemainingTargets
local Settings, StartPoints, State, TravelSpeed, TurnInText = ns.Settings, ns.StartPoints, ns.State, ns.TravelSpeed, ns.TurnInText
local UnitTime, WorldPos, scan, LogQuests, AllIds, SkillName = ns.UnitTime, ns.WorldPos, ns.scan, ns.LogQuests, ns.AllIds, ns.SkillName
local LogEntry, Normalize, GeoReady = ns.LogEntry, ns.Normalize, ns.GeoReady

---------------------------------------------------------------------------
-- Profession level needed to turn a quest in (e.g. a profession introduction: "reach 20 in
-- Herbalism"): QuestieDB's requiredSkill, else the quest texts (QuestieDB's English ones, the
-- log's localized objectives and description) naming a profession next to a number.
---------------------------------------------------------------------------
K.SKILL_TEXT_GAP = 30 -- characters: a number this close to a profession name is its level

function Geo.SkillFromText(text)
  text = text:lower()
  for skill, p in pairs(ns.PROFESSIONS) do
    for _, name in ipairs(p.en and { p.en, p.name:lower() } or {}) do
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
  -- QuestieDB's requiredSkill is the level to pick the quest up: the turn-in may ask for more (the
  -- profession introductions: "reach 20"), so the quest texts are read too and the highest level wins.
  local req = QGet(QDB.Quest, id, "requiredSkill")
  if type(req) == "table" and req[1] and (req[2] or 0) > 0 then skill, need = req[1], req[2] end
  local parts = {}
  local Q = QDB.Quest
  local okR, raw
  okR, raw = pcall(Q.GetRaw, id, "objectivesText")
  for _, list in ipairs({ okR and raw or QGet(Q, id, "objectivesText"), q and q.objectivesText }) do
    if type(list) == "table" then
      for _, t in ipairs(list) do parts[#parts + 1] = tostring(t) end
    elseif type(list) == "string" then
      parts[#parts + 1] = list
    end
  end
  for _, o in ipairs(q and q.objectives or {}) do
    if type(o.text) == "string" then parts[#parts + 1] = o.text end
  end
  if q and type(q.description) == "string" then parts[#parts + 1] = q.description end
  for _, t in ipairs(parts) do
    local s2, n2 = Geo.SkillFromText(t)
    if s2 and (not skill or (s2 == skill and n2 > need)) then skill, need = s2, n2 end
    if s2 and s2 == skill then break end
  end
  if not skill then return nil end
  local have = skills[skill] or 0
  if have >= need then return nil end
  return { skill = skill, need = need, have = have, name = SkillName(skill) or (L["profession"] .. " " .. skill) }
end

-- Warning line of a quest whose turn-in waits for a profession level.
function Geo.SkillNeedText(n)
  return string.format(L["%s %d required to turn in (you: %d)"], n.name, n.need, n.have)
end

-- Time to raise a profession by one point, averaged over every profession (setting "Time per skill point").
K.SKILL_TIME = 20

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
  local ui = p and Geo.AreaUi(p.area)
  return ui and set[ui] or false
end

-- Returns the elements within the radius (in meters), or in the whole current zone (radius = "zone").
local function NearItems(radius)
  local pos = PlayerPos()
  if not pos then return nil, L["Unknown position (in an instance or map unavailable)."] end
  local inside = {}
  local here = CurrentMapSet()
  local function add(it)
    if radius == "zone" then
      if PointInMaps(it.p, here) then inside[#inside + 1] = it end
    elseif it.d <= radius then
      inside[#inside + 1] = it
    end
  end

  for _, q in ipairs(LogQuests()) do
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
  return inside
end

---------------------------------------------------------------------------
-- Roadbook: XP / time planning along the route
---------------------------------------------------------------------------
-- Goal of the automatic Roadbook: { kind = "time", value = s } or { kind = "level", value = level }.
State.xpGoal = { kind = "time", value = 7200 }
K.MAX_TAKE_CANDIDATES = 1500      -- safety: quests to pick up considered by the Roadbook, at most
K.MAX_FOLLOW_DEPTH = 12  -- safety: maximum length of an evaluated quest chain
K.SLICE_MS = 15          -- maximum computation time per frame (the computation is spread over several frames)
-- Spread computation: yields back to the game when the time slice is used up.
function Geo.Yield()
  if State.co and debugprofilestop and coroutine.running() == State.co then
    if debugprofilestop() - (State.sliceStart or 0) > K.SLICE_MS then coroutine.yield() end
  end
end

-- Runs a computation (coroutine calling Geo.Yield) over several frames: it replaces the running one.
-- onDone(its results), onError(message), onReplaced() when a newer one took its place (optional).
function Geo.RunSliced(co, onDone, onError, onReplaced)
  State.co = co
  local function handle(ok, ...)
    if not ok then
      State.co = nil
      onError(...)
    elseif coroutine.status(co) == "dead" then
      State.co = nil
      onDone(...)
    else
      return true
    end
  end
  local function step()
    if State.co ~= co then
      if onReplaced then onReplaced() end
      return
    end
    State.sliceStart = debugprofilestop()
    if handle(coroutine.resume(co)) then C_Timer.After(0, step) end
  end
  step()
end

-- XP to go from the given level to the next one (Classic table, scaled to the game's actual value).
function Geo.XPNeeded(level)
  local base = ns.XP_TABLE[level]
  if not base then return nil end
  local here = ns.XP_TABLE[UnitLevel("player")]
  local real = UnitXPMax and UnitXPMax("player")
  return base * ((here and real and real > 0) and real / here or 1)
end

-- XP to go from each level to the next one: { [level] = XP }.
function Geo.XPNeededTable()
  local needed = {}
  for lv = 1, Geo.MaxLevel() do needed[lv] = Geo.XPNeeded(lv) end
  return needed
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
function Geo.BestSpot(r, from, speed)
  local spots = Geo.Spots(r.tg)
  if not spots then return nil end
  local kills = (r.tg.kind == "item") and r.count * Geo.KillsPerItem(r.tg) or r.count
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
  local speed = TravelSpeed()
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
          local spot = Geo.BestSpot(r, from, speed)
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
        local _, ns, kills = Geo.BestSpot(r, from, speed)
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
        st.work = math.max(0, d / K.ESCORT_SPEED - d / speed) + K.ESCORT_MARGIN
        -- Right after the pick-up: nothing may come between them (glued to the previous stop).
        if task.kind == "take" and #stops == 1 and takes == 1 then st.glue = true end
      end
      stops[#stops + 1] = st
      from = bp
    end
  end
  -- Profession level to reach before the turn-in: a step at the nearest trainer of the profession
  -- (no place when none is known: it then stays where the route is).
  local need = task.skillNeed
  if need and task.kind ~= "turnin" then
    local trainer = Geo.NearestSkillTrainer(need.skill, from)
    stops[#stops + 1] = { task = task, kind = "skill", p = trainer and trainer.p or Geo.CopyPoint(from),
      work = math.max(1, need.need - need.have) * K.SKILL_TIME, skill = need, npc = trainer and trainer.name,
      nopin = not trainer or nil }
    if trainer then from = trainer.p end
  end
  local f = Nearest(t.finish, from)
  if not f then return nil end
  local turnin = { task = task, kind = "turnin", p = f, work = K.OVERHEAD / 2, xp = task.xp }
  -- Escort without a known destination (no completion trigger): it ends at the turn-in NPC.
  if task.kind == "take" and #stops == 1 and takes == 1 and Geo.IsEscort(task.id) then
    local d = Dist(from, f) or 0
    turnin.escort, turnin.glue = true, true
    turnin.work = turnin.work + math.max(0, d / K.ESCORT_SPEED - d / speed) + K.ESCORT_MARGIN
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
  return task
end

-- Reverse index "quest -> quests that require it", built once per session.
function Geo.PreIndex()
  if Geo.pre then return Geo.pre end
  local pre = {}
  for n, id in ipairs(AllIds(QDB.Quest) or {}) do
    for _, p in ipairs(AllPrereqs(id)) do
      pre[p] = pre[p] or {}
      table.insert(pre[p], id)
    end
    if n % 400 == 0 then Geo.Yield() end
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



function Geo.MaxLevel()
  return (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
end

---------------------------------------------------------------------------
-- What a quest is: its types, whether it follows another, its tag, whether to abandon it
---------------------------------------------------------------------------
-- Quest types, deduced from the QuestieDB objectives (several per quest, in this order).
K.QUEST_TYPES = { "escort", "assassination", "slaying", "collect", "gathering", "interaction", "exploration",
  "talk", "reputation", "delivery" }
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
  if K.UNIQUE_RANKS[rank] then return true end
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
      if K.TALK_ICONS[icon] then has.talk = true
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
    local ok, t = pcall(QDB.Quest.GetRaw, id, "objectivesText")
    if ok and type(t) == "table" then text = table.concat(t, " "):lower() end
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

-- A quest that follows another one (a quest prerequisite in QuestieDB).
function Geo.IsFollowUp(id)
  return id ~= nil and #AllPrereqs(id) > 0
end

-- Game tag of a quest of the log ("Elite", "Dungeon"…), "" if none, nil if not in the log.
function Geo.LogTag(id)
  local q = LogEntry(id)
  return q and (q.tag or "") or nil
end

-- Quests of the log recommended for abandoning (ids), from the last Analyze(); computed again after
-- a quest event (Events.lua clears State.abandonIds).
function Geo.ToAbandon(questId)
  if not State.abandonIds then
    pcall(ns.Analyze)
    State.abandonIds = State.abandonIds or {} -- no new try on each line after an error
  end
  return State.abandonIds[questId] or false
end

-- Dungeon / raid quest kept out of the Roadbook: anything but talking or delivering, even when its
-- targets are outside the instance (e.g. an elite in front of the entrance).
function Geo.DungeonCombat(id)
  for _, t in ipairs(Geo.QuestTypes(id)) do
    if t ~= "talk" and t ~= "delivery" then return true end
  end
  return false
end

-- The game tag saying a quest is elite.
function Geo.IsEliteTag(tag)
  return tag ~= nil and (tag == ELITE or tag:find(ns.ELITE_TAG_PATTERN) ~= nil)
end

-- Elite quest: tagged "Elite" by the game (quest log), otherwise most of the monsters of its
-- objectives (to kill, or dropping the requested items) are elites in QuestieDB.
Geo.elite = {}
function Geo.IsEliteQuest(id, tag)
  -- A quest has a single game tag ("Dungeon" wins over "Elite"): it only settles the "Elite" case.
  if Geo.IsEliteTag(tag) then return true end
  if not id then return false end
  local v = Geo.elite[id]
  if v ~= nil then return v end
  local mobs = {}
  local obj = QGet(QDB.Quest, id, "objectives")
  if type(obj) == "table" then
    for _, o in ipairs(obj[1] or {}) do
      local icon = o[3]
      if not K.TALK_ICONS[icon] then mobs[#mobs + 1] = o[1] end
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
    if K.ELITE_RANKS[rank] then elites = elites + 1 end
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

local function BuildTasks(pos, plevel)
  local tasks, skipped = {}, 0
  for _, q in ipairs(LogQuests()) do
    local xp = q.xp or DBXP(q.id, plevel) or 0
    local group = q.suggestedGroup and q.suggestedGroup > 1
    local atMax = plevel >= Geo.MaxLevel()
    -- Quest ready to turn in: always a candidate (even dungeon, group, gray or high level),
    -- you only need to visit the NPC: it is cheap.
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
        if ready then task.quick = true end
        tasks[#tasks + 1] = task
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

-- The available quests (scan.entries) a filter of the "Available" tab shows, grouped, the groups in
-- their order. filter: "all", "zone", "dungeon", "pvp", "class", "custom" (the Roadbook list);
-- matches(entry): the search, optional; showLow: low-level quests too. Returns the groups
-- ({ name, kind ("zone", "dungeon", "class", "pvp"), list = entries }) and the number of quests.
function Geo.AvailableGroups(filter, matches, showLow)
  local zoneNames = filter == "zone" and CurrentZoneNames() or nil
  local hereMaps = filter == "zone" and CurrentMapSet() or {}
  local function StartsHere(e)
    if not GeoReady() then return false end
    for _, pt in ipairs(StartPoints(e.id)) do
      if PointInMaps(pt, hereMaps) then return true end
    end
    return false
  end
  local groups, byKey, total = {}, {}, 0
  -- The groups apart from the places: id (never a place's name) -> title and place in the list.
  local special = { ["#class"] = { name = L["Class"], rank = 1 }, ["#prof"] = { name = L["Professions"], rank = 2 } }
  local function Place(e) return e.dungeon or e.area or e.starterZone or L["Other"] end
  local function ClassOrPlace(e)
    return (e.isClass and "#class") or (e.isProf and "#prof") or Place(e)
  end
  -- Whether the filter keeps the entry, and the key of its group.
  local function Select(e)
    if filter == "custom" then return Geo.InCustom(e.id), ClassOrPlace(e) end
    -- low-level quest hidden ("Low-level quests" option), or not at the required level yet
    if (e.lowLevel and not showLow) or e.future then return false end
    if filter == "zone" then
      return StartsHere(e) or (e.area and zoneNames[e.area]) or (e.starterZone and zoneNames[e.starterZone])
        or (e.dungeon and zoneNames[e.dungeon]), Place(e)
    elseif filter == "dungeon" then
      return e.dungeon ~= nil and not e.pvp, e.dungeon -- battlegrounds have their own filter
    elseif filter == "pvp" then
      return e.pvp, Place(e)
    elseif filter == "class" then
      return e.isClass or e.isProf, e.isClass and "#class" or "#prof"
    end
    -- "All": class and profession quests in their own groups (some are not tied to a place,
    -- e.g. the Forever "Crafting" writs), the others by zone.
    return true, ClassOrPlace(e)
  end
  for _, e in ipairs(scan.entries) do
    local keep, key = Select(e)
    if keep and (not matches or matches(e)) then
      local g = byKey[key]
      if not g then
        local s = special[key]
        local kind = e.dungeon and key == e.dungeon and "dungeon" or (s and "class") or "zone"
        g = { name = s and s.name or key, rank = s and s.rank, kind = kind, list = {} }
        byKey[key] = g
        groups[#groups + 1] = g
      end
      g.list[#g.list + 1] = e
      total = total + 1
      if e.pvp then g.pvp, g.kind = true, "pvp" end
    end
  end
  -- Order of the groups: class, professions, dungeons, standard zones, PvP; then alphabetical.
  local function Rank(g)
    if g.rank then return g.rank end -- class, professions
    if g.pvp then return 5 end
    if g.kind == "dungeon" then return 3 end
    return 4
  end
  table.sort(groups, function(a, b)
    local ra, rb = Rank(a), Rank(b)
    if ra ~= rb then return ra < rb end
    return Normalize(a.name) < Normalize(b.name)
  end)
  return groups, total
end

-- Shared with the next files.
ns.BuildTasks, ns.CurrentMapSet, ns.MakeStops, ns.NearItems = BuildTasks, CurrentMapSet, MakeStops, NearItems
ns.PointInMaps = PointInMaps
