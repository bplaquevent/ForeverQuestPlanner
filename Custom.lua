-- Forever Quest Planner: custom Roadbook: quests chosen by the player, fastest route to do them all.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, BuildNetwork, BuildScanContext, CharKey, DBXP, Dist = ns.AreaName, ns.BuildNetwork, ns.BuildScanContext, ns.CharKey, ns.DBXP, ns.Dist
local Geo, GiverText, HasBit, IsCompleted, IsInLog, K = ns.Geo, ns.GiverText, ns.HasBit, ns.IsCompleted, ns.IsInLog, ns.K
local L, MakeStops, MakeTravel, PlayerPos, Print, QDB = ns.L, ns.MakeStops, ns.MakeTravel, ns.PlayerPos, ns.Print, ns.QDB
local QGet, QuestTargets, RemainingTargets, Settings, TravelSpeed = ns.QGet, ns.QuestTargets, ns.RemainingTargets, ns.Settings, ns.TravelSpeed

K.DUNGEON_TIME = 60       -- minutes spent inside a dungeon (setting)
K.MAX_PREREQ_DEPTH = 15   -- safety: prerequisite chain added with a quest
K.FM_CANDIDATES = 8       -- unknown flight masters tried as a detour
K.FM_MAX_DISCOVER = 4     -- flight paths activated on purpose, at most
K.FM_MIN_GAIN = 60        -- s: a flight path is activated on purpose if it saves at least this
K.FM_SEARCH_RADIUS = 2500 -- m: unknown flight masters this close to a step are tried
K.DUNGEON_ICON = "|TInterface\\Icons\\INV_Misc_Key_03:14:14|t"

---------------------------------------------------------------------------
-- Quest list and mode (saved per character)
---------------------------------------------------------------------------
function Geo.CustomRec()
  local st = Settings()
  st.custom = st.custom or {}
  local k = CharKey()
  st.custom[k] = st.custom[k] or { list = {} }
  return st.custom[k]
end

-- Tab of a Roadbook kind (each one has its own tab).
function Geo.TabOf(kind)
  return kind == "custom" and "custom" or "xp"
end

-- Roadbook followed by the Objective button ("auto" or "custom"), saved per character: there is
-- always one, the automatic one by default; it is chosen with the radio buttons of the Roadbook tabs.
function Geo.ActiveKind()
  local st = Settings()
  return st.activeRoadbook and st.activeRoadbook[CharKey()] or "auto"
end

-- The active Roadbook is followed (a step is focused); paused otherwise.
function Geo.Tracking()
  return ns.CP.CurrentFocus() ~= nil
end

function Geo.SetActive(kind)
  local st = Settings()
  st.activeRoadbook = st.activeRoadbook or {}
  st.activeRoadbook[CharKey()] = kind
end

-- Saved Roadbook of a kind ("auto" or "custom").
function Geo.FrozenKey(kind)
  return kind == "custom" and (CharKey() .. "|custom") or CharKey()
end

function Geo.CustomIndex(id)
  for i, e in ipairs(Geo.CustomRec().list) do
    if e.id == id then return i end
  end
  return nil
end

function Geo.InCustom(id)
  return id ~= nil and Geo.CustomIndex(id) ~= nil
end

-- Quests of the list, without the ones turned in meanwhile (removed from the list).
function Geo.CustomList()
  local rec = Geo.CustomRec()
  local out = {}
  for _, e in ipairs(rec.list) do
    if not IsCompleted(e.id) then out[#out + 1] = e end
  end
  rec.list = out
  return out
end

-- Quest that the character's class and race can do.
function Geo.ForPlayer(id)
  Geo.customCtx = Geo.customCtx or BuildScanContext()
  local ctx = Geo.customCtx
  local races = QGet(QDB.Quest, id, "requiredRaces") or 0
  if races ~= 0 and ctx.raceBit and not HasBit(races, ctx.raceBit) then return false end
  local classes = QGet(QDB.Quest, id, "requiredClasses") or 0
  if classes ~= 0 and ctx.classBit and not HasBit(classes, ctx.classBit) then return false end
  return true
end

-- Prerequisite quests still to turn in (QuestieDB), the first ones of the chain first.
function Geo.MissingPrereqs(id, out, seen, depth)
  out, seen, depth = out or {}, seen or { [id] = true }, depth or 0
  if depth > K.MAX_PREREQ_DEPTH then return out end
  local function add(q)
    seen[q] = true
    Geo.MissingPrereqs(q, out, seen, depth + 1)
    out[#out + 1] = q
  end
  local group = QGet(QDB.Quest, id, "preQuestGroup")
  if type(group) == "table" then
    for _, p in ipairs(group) do
      if not (IsCompleted(p) or seen[p]) then add(p) end
    end
  end
  local single = QGet(QDB.Quest, id, "preQuestSingle")
  if type(single) == "table" and #single > 0 then
    local ok = false
    for _, p in ipairs(single) do
      if IsCompleted(p) or seen[p] then ok = true break end
    end
    if not ok then
      -- One of them is enough: the one in the quest log, otherwise the first one for your class and race.
      local pick
      for _, p in ipairs(single) do if IsInLog(p) then pick = p break end end
      if not pick then
        for _, p in ipairs(single) do if Geo.ForPlayer(p) then pick = p break end end
      end
      add(pick or single[1])
    end
  end
  return out
end

function Geo.QuestLevelOf(id)
  local lvl = QGet(QDB.Quest, id, "questLevel")
  return (type(lvl) == "number" and lvl > 0) and lvl or nil
end

-- Adds a quest (and the prerequisites it still needs) to the custom Roadbook.
-- quiet: no message and no update (adding in bulk). Returns true, number of prerequisites added.
function Geo.CustomAdd(id, title, level, quiet)
  if not id or Geo.InCustom(id) then return false, 0 end
  title = title or QGet(QDB.Quest, id, "name") or ("#" .. id)
  if IsCompleted(id) then
    if not quiet then Print(L["Quest already done: "] .. title) end
    return false, 0
  end
  local rec = Geo.CustomRec()
  local pre = 0
  for _, p in ipairs(Geo.MissingPrereqs(id)) do
    if not Geo.InCustom(p) then
      rec.list[#rec.list + 1] = { id = p, title = QGet(QDB.Quest, p, "name") or ("#" .. p), level = Geo.QuestLevelOf(p), pre = id }
      pre = pre + 1
    end
  end
  rec.list[#rec.list + 1] = { id = id, title = title, level = level or Geo.QuestLevelOf(id) }
  if quiet then return true, pre end
  Print(L["Added to the custom Roadbook: "] .. title ..
    (pre > 0 and string.format(L[" (+%d prerequisite quest(s))"], pre) or ""))
  if not Geo.ForPlayer(id) then Print(L["Warning: this quest is not for your class or race."]) end
  Geo.CustomChanged()
  return true, pre
end

-- Adds every quest of a list ({ id, title, level }) with a single message and a single update.
function Geo.CustomAddList(list)
  local added, pre = 0, 0
  for _, q in ipairs(list) do
    local ok, p = Geo.CustomAdd(q.id, q.title, q.level, true)
    if ok then added, pre = added + 1, pre + p end
  end
  Print(string.format(L["%d quest(s) added to the custom Roadbook"], added) ..
    (pre > 0 and string.format(L[" (+%d prerequisite quest(s))"], pre) or ""))
  if added > 0 then Geo.CustomChanged() end
end

-- Prerequisite p still needed by the quest id.
function Geo.NeedsPrereq(id, p)
  for _, q in ipairs(Geo.MissingPrereqs(id)) do
    if q == p then return true end
  end
  return false
end

-- Removes a quest, and the prerequisites that were only added for it.
-- quiet: no message and no update (removing in bulk). Returns true, number of prerequisites removed.
function Geo.CustomRemove(id, quiet)
  local i = Geo.CustomIndex(id)
  if not i then return false, 0 end
  local rec = Geo.CustomRec()
  local e = table.remove(rec.list, i)
  local removed, again = 0, true
  while again do
    again = false
    for j = #rec.list, 1, -1 do
      local o = rec.list[j]
      if o.pre and not Geo.InCustom(o.pre) then
        local by
        for _, x in ipairs(rec.list) do
          if x ~= o and Geo.NeedsPrereq(x.id, o.id) then by = x.id break end
        end
        if by then
          o.pre = by
        else
          table.remove(rec.list, j)
          removed, again = removed + 1, true
        end
      end
    end
  end
  if quiet then return true, removed end
  Print(L["Removed from the custom Roadbook: "] .. (e.title or tostring(id)) ..
    (removed > 0 and string.format(L[" (and %d prerequisite quest(s))"], removed) or ""))
  Geo.CustomChanged()
  return true, removed
end

function Geo.CustomRemoveList(list)
  local n, extra = 0, 0
  for _, q in ipairs(list) do
    local ok, r = Geo.CustomRemove(q.id, true)
    if ok then n, extra = n + 1, extra + r end
  end
  Print(string.format(L["%d quest(s) removed from the custom Roadbook"], n) ..
    (extra > 0 and string.format(L[" (and %d prerequisite quest(s))"], extra) or ""))
  if n > 0 then Geo.CustomChanged() end
end

function Geo.CustomClear()
  Geo.CustomRec().list = {}
  Geo.customUnplanned = nil
  Print(L["Quests removed from the custom Roadbook; its steps done are kept."])
  Geo.CustomChanged()
end

-- List changed: the steps to come of the custom Roadbook are computed again (grouped when several
-- quests are added in a row), its steps done and its tracking kept; empty list: the steps to come
-- are removed and it is paused, the steps done stay (only "Delete" empties them). It has no "Generate".
function Geo.CustomChanged()
  Geo.customToken = (Geo.customToken or 0) + 1
  local token = Geo.customToken
  if #Geo.CustomList() == 0 then
    if ns.CP then ns.CP.Pause("custom", true) end
    if not (Geo.KeepOnlyDone and Geo.KeepOnlyDone("custom")) then Geo.ClearFrozen("custom") end
    if Geo.ResetActiveIfEmpty then Geo.ResetActiveIfEmpty() end
  else
    C_Timer.After(0.6, function()
      if token == Geo.customToken and ns.CP then ns.CP.Recompute("custom", true) end
    end)
  end
  if ns.Refresh then ns.Refresh() end
  if Geo.QuestLogButtonSync then pcall(Geo.QuestLogButtonSync) end
end

StaticPopupDialogs["FQP_CUSTOM_CLEAR"] = {
  text = L["Remove every quest from the custom Roadbook?"],
  button1 = L["Remove all"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function() Geo.CustomClear() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Planning: fastest route to do every quest of the list
---------------------------------------------------------------------------
-- Task of the list: pick-up (if not in the log yet), remaining objectives, turn-in.
function Geo.CustomTask(e, pos, plevel, logById)
  local q = logById[e.id]
  local t = QuestTargets(e.id)
  if #t.finish == 0 then return nil, L["turn-in NPC not located"] end
  local task = { id = e.id, title = (q and q.title) or e.title, level = (q and q.level) or e.level, targets = t, custom = true }
  if q then
    if q.failed then return nil, L["failed: abandon it and pick it up again"] end
    task.kind = q.complete and "turnin" or "do"
    task.xp = q.xp or DBXP(e.id, plevel) or 0
    task.remaining = {}
    if not q.complete then
      local unmatched
      task.remaining, unmatched = RemainingTargets(q, t)
      if unmatched > 0 then task.warn = L["an objective is not located"] end
    end
  else
    if #t.start == 0 then return nil, L["quest giver not located"] end
    task.kind = "take"
    task.xp = DBXP(e.id, plevel) or 0
    task.remaining = RemainingTargets(nil, t)
    if (t.missing or 0) > 0 then task.warn = L["an objective is not located"] end
    local req = QGet(QDB.Quest, e.id, "requiredLevel") or 0
    if req > plevel then task.reqLevel = req end
    task.starter = GiverText(QGet(QDB.Quest, e.id, "startedBy"))
  end
  task.stops = MakeStops(task, pos, plevel)
  if not task.stops then return nil, L["not located"] end
  return task
end

-- Network (and travel times) with the flight masters `hubs` activated, cached by set.
function Geo.NetEntry(cache, hubs, speed, plevel)
  local ids = {}
  for _, h in ipairs(hubs) do ids[#ids + 1] = string.format("%s:%.0f:%.0f", tostring(h.p.c), h.p.x, h.p.y) end
  table.sort(ids)
  local key = table.concat(ids, ";")
  local e = cache[key]
  if not e then
    local list = {}
    for i, h in ipairs(hubs) do list[i] = h end
    e = { net = BuildNetwork(speed, list) }
    cache[key] = e
  end
  if not e.travel then e.travel = MakeTravel(e.net, plevel) end
  return e
end

-- Network of each leg (arriving at route[i]): the known flight paths, plus the ones activated
-- by the earlier steps of the route.
function Geo.RouteNets(route, speed, plevel, cache)
  local out, hubs = {}, {}
  local cur = Geo.NetEntry(cache, hubs, speed, plevel)
  for i = 1, #route do
    out[i] = cur
    local h = route[i].fmHub
    if h and h.p then
      hubs[#hubs + 1] = h
      cur = Geo.NetEntry(cache, hubs, speed, plevel)
    end
  end
  return out
end

function Geo.FlightMasterStep(fm)
  return { kind = "fm", p = fm.p, work = K.OVERHEAD / 2,
    fmHub = { id = fm.id, node = fm.node, name = AreaName(fm.p.area) or fm.name, p = fm.p },
    task = { title = L["Activate the flight path of "] .. (AreaName(fm.p.area) or fm.name), npc = fm.name, xp = 0, fm = true } }
end

-- No quest picked up before its required level (unless it can never be reached: warned).
function Geo.CustomLevelsOK(route)
  local lv = Geo.Levels(route)
  for i = 2, #route do
    local st = route[i]
    if st.kind == "take" and st.task.reqLevel and not st.task.levelWarn and lv[i - 1] < st.task.reqLevel then return false end
  end
  return true
end

-- Construction: each step, as soon as the steps it depends on are placed, inserted where it
-- costs the least time (cheapest insertion). When nothing can be placed any more, the required
-- level, then the order, are ignored for one step (the quest gets a warning).
function Geo.CustomBuild(route, steps, pred, travel)
  local remaining = {}
  for i, s in ipairs(steps) do remaining[i] = s end
  local relax = 0
  while #remaining > 0 do
    local idx, lv = Geo.Index(route), Geo.Levels(route)
    local best
    for ri, s in ipairs(remaining) do
      local ok, lo = true, 1
      for _, p in ipairs(pred[s] or {}) do
        local j = idx[p]
        if j then
          if j > lo then lo = j end
        elseif relax < 2 then
          ok = false
          break
        end
      end
      local req = s.kind == "take" and s.task.reqLevel
      if ok and req and relax < 1 and not s.task.levelWarn then
        local found
        for j = lo, #lv do
          if lv[j] >= req then found = j break end
        end
        if found then lo = found else ok = false end
      end
      if ok then
        local hi = s.glue and lo or #route
        for j = lo, hi do
          local a, b = route[j], route[j + 1]
          if not (b and b.glue) then
            local d = travel(a.p, s.p) + (b and (travel(s.p, b.p) - travel(a.p, b.p)) or 0)
            if not best or d < best.d then best = { ri = ri, j = j, d = d } end
          end
        end
      end
      Geo.Yield()
    end
    if best then
      local s = table.remove(remaining, best.ri)
      table.insert(route, best.j + 1, s)
      local req = s.kind == "take" and s.task.reqLevel
      if relax >= 1 and req and (lv[best.j] or 0) < req then s.task.levelWarn = true end
      if relax >= 2 and s.task then s.task.orderWarn = true end
      relax = 0
    elseif relax < 2 then
      relax = relax + 1
    else
      break
    end
  end
  return route
end

-- Improvement: moves groups of 1 to 3 consecutive steps to the place where they cost the least,
-- within the order constraints, as long as the route gets shorter.
function Geo.CustomImprove(route, travel, pred, succ)
  for _ = 1, 6 do
    local improved = false
    for len = 1, 3 do
      local i = 2
      while i + len - 1 <= #route do
        local last, nxt = route[i + len - 1], route[i + len]
        if not route[i].glue and not (nxt and nxt.glue) then
          local prev, first = route[i - 1], route[i]
          local gain = travel(prev.p, first.p) + (nxt and (travel(last.p, nxt.p) - travel(prev.p, nxt.p)) or 0)
          local seg = {}
          for k = 1, len do seg[k] = table.remove(route, i) end
          local idx = Geo.Index(route)
          local lo, hi = 1, #route
          for _, s in ipairs(seg) do
            for _, p in ipairs(pred[s] or {}) do
              local j = idx[p]
              if j and j > lo then lo = j end
            end
            for _, q in ipairs(succ[s] or {}) do
              local j = idx[q]
              if j and j - 1 < hi then hi = j - 1 end
            end
          end
          local bestJ, bestC
          for j = lo, hi do
            if j ~= i - 1 and not (route[j + 1] and route[j + 1].glue) then
              local a, b = route[j], route[j + 1]
              local c = travel(a.p, first.p) + (b and (travel(last.p, b.p) - travel(a.p, b.p)) or 0)
              if not bestC or c < bestC then bestJ, bestC = j, c end
            end
          end
          local moved = false
          if bestC and bestC < gain - 1 then
            for k = len, 1, -1 do table.insert(route, bestJ + 1, seg[k]) end
            if Geo.CustomLevelsOK(route) then
              moved, improved = true, true
            else
              for _ = 1, len do table.remove(route, bestJ + 1) end
            end
          end
          if not moved then
            for k = len, 1, -1 do table.insert(route, i, seg[k]) end
          end
        end
        i = i + 1
        Geo.Yield()
      end
    end
    if not improved then break end
  end
  return route
end

-- Flight paths activated on purpose: an unknown flight master near the route is added as a step
-- when the flights it then allows save more time than the detour costs.
function Geo.DiscoverFlightMasters(route, speed, plevel, cache)
  local unknown = Geo.UnknownFlightMasters()
  if #unknown == 0 or #route < 2 then return route, 0 end
  local function timeOf(r)
    local nets = Geo.RouteNets(r, speed, plevel, cache)
    local t = 0
    for i = 2, #r do t = t + nets[i].travel(r[i - 1].p, r[i].p) + r[i].work end
    return t
  end
  local cands = {}
  for _, fm in ipairs(unknown) do
    local best
    for _, st in ipairs(route) do
      local d = Dist(fm.p, st.p)
      if d and (not best or d < best) then best = d end
    end
    if best and best <= K.FM_SEARCH_RADIUS then cands[#cands + 1] = { fm = fm, d = best } end
  end
  table.sort(cands, function(a, b) return a.d < b.d end)
  for i = #cands, K.FM_CANDIDATES + 1, -1 do cands[i] = nil end
  local baseT, added = timeOf(route), 0
  while added < K.FM_MAX_DISCOVER do
    local best
    for _, c in ipairs(cands) do
      if not c.used then
        local places = {}
        for k = 2, #route + 1 do
          local a, b = route[k - 1], route[k]
          local d1 = Dist(a.p, c.fm.p)
          if d1 and not (b and b.glue) then
            local detour = d1
            if b then detour = d1 + (Dist(c.fm.p, b.p) or d1) - (Dist(a.p, b.p) or 0) end
            places[#places + 1] = { k = k, detour = detour }
          end
        end
        table.sort(places, function(x, y) return x.detour < y.detour end)
        for n = 1, math.min(6, #places) do
          local k = places[n].k
          table.insert(route, k, Geo.FlightMasterStep(c.fm))
          local t = timeOf(route)
          table.remove(route, k)
          if t < baseT - K.FM_MIN_GAIN and (not best or t < best.t) then best = { c = c, k = k, t = t } end
          Geo.Yield()
        end
      end
    end
    if not best then break end
    best.c.used = true
    table.insert(route, best.k, Geo.FlightMasterStep(best.c.fm))
    baseT, added = best.t, added + 1
  end
  return route, added
end

-- Dungeon steps: every step of the list inside the same dungeon is done during one visit (a step at
-- the entrance). A quest whose dungeon part needs another quest done (and turned in outside) first
-- goes to a later visit ("wave").
function Geo.GroupDungeons(tasks)
  -- Visit of dungeon d needed by a task: one more than a prerequisite that goes inside d and is
  -- turned in outside it (its turn-in comes between both visits).
  local function wave(task, d, depth)
    task.waves = task.waves or {}
    if task.waves[d] then return task.waves[d] end
    local w = 0
    if depth < 20 then
      for _, a in ipairs(task.pres) do
        local wa = wave(a, d, depth + 1)
        local inside = false
        for _, s in ipairs(a.stops) do if s.p and s.p.instance == d then inside = true end end
        local f = a.stops[#a.stops]
        if inside and not (f and f.p and f.p.instance == d) then wa = wa + 1 end
        if wa > w then w = wa end
      end
    end
    task.waves[d] = w
    return w
  end
  local dungeons, byKey = {}, {}
  for _, task in ipairs(tasks) do
    local order, seen = {}, {}
    for _, s in ipairs(task.stops) do
      local d = s.p and s.p.instance
      if d then
        local key = d .. "#" .. wave(task, d, 0)
        local D = byKey[key]
        if not D then
          D = { kind = "dungeon", p = s.p, work = K.DUNGEON_TIME * 60, xp = 0,
            task = { title = L["Dungeon: "] .. d, dungeon = d, members = {}, xp = 0, stops = {} } }
          D.task.stops[1] = D
          byKey[key] = D
          dungeons[#dungeons + 1] = D
        end
        table.insert(D.task.members, s)
        D.xp = D.xp + (s.xp or 0)
        s.inside = D
        if not seen[D] then
          seen[D] = true
          order[#order + 1] = D
        end
      else
        if s.glue and order[#order] and order[#order].kind == "dungeon" then s.glue = nil end
        order[#order + 1] = s
      end
    end
    task.order = order
  end
  return dungeons
end

-- Order constraints: pick-up before the rest of the quest, turn-in after; prerequisite turned in
-- before the pick-up of its follow-up.
function Geo.CustomConstraints(tasks)
  local pred, succ = {}, {}
  local function before(a, b)
    if not a or not b or a == b then return end
    pred[b] = pred[b] or {}
    table.insert(pred[b], a)
    succ[a] = succ[a] or {}
    table.insert(succ[a], b)
  end
  for _, task in ipairs(tasks) do
    local take = task.kind == "take" and task.stops[1]
    local turnin = task.stops[#task.stops]
    task.firstC = take and (take.inside or take) or nil
    task.lastC = turnin.inside or turnin
    local both = task.firstC == task.lastC
    for _, x in ipairs(task.order) do
      if task.firstC then before(task.firstC, x) end
      if not both then before(x, task.lastC) end
    end
  end
  for _, b in ipairs(tasks) do
    if b.firstC then
      for _, a in ipairs(b.pres) do before(a.lastC, b.firstC) end
    end
  end
  return pred, succ
end

function Geo.PlanCustom()
  local pos = PlayerPos()
  if not pos then return nil, L["Unknown position (in an instance or map unavailable)."] end
  local list = Geo.CustomList()
  if #list == 0 then return nil, L["The custom Roadbook is empty: add quests with the \"Add\" button of the other tabs."] end
  Geo.xpScale, Geo.customCtx = nil, nil
  Geo.laterList = {}
  local speed = TravelSpeed()
  Geo.planSpeed = speed
  local plevel = UnitLevel("player")
  local cache = {}
  local base = Geo.NetEntry(cache, {}, speed, plevel)
  local travel = base.travel

  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  local logById = {}
  for _, q in ipairs(e and e.quests or {}) do logById[q.id] = q end
  local tasks, byId, unplanned = {}, {}, {}
  for _, it in ipairs(list) do
    local ok, task, why = pcall(Geo.CustomTask, it, pos, plevel, logById)
    if ok and task then
      tasks[#tasks + 1] = task
      byId[it.id] = task
    else
      unplanned[#unplanned + 1] = { id = it.id, title = it.title, reason = ok and why or tostring(task) }
    end
    Geo.Yield()
  end
  Geo.customUnplanned = unplanned
  if #tasks == 0 then return nil, L["No quest of the custom Roadbook can be located."] end
  for _, task in ipairs(tasks) do
    task.pres = {}
    for _, key in ipairs({ "preQuestGroup", "preQuestSingle" }) do
      local lst = QGet(QDB.Quest, task.id, key)
      if type(lst) == "table" then
        for _, p in ipairs(lst) do
          if byId[p] and byId[p] ~= task then task.pres[#task.pres + 1] = byId[p] end
        end
      end
    end
  end

  local dungeons = Geo.GroupDungeons(tasks)
  local pred, succ = Geo.CustomConstraints(tasks)
  local steps, seen = {}, {}
  for _, task in ipairs(tasks) do
    for _, s in ipairs(task.order) do
      if not seen[s] then
        seen[s] = true
        steps[#steps + 1] = s
      end
    end
  end

  local route = Geo.CustomBuild({ { kind = "start", p = pos, work = 0 } }, steps, pred, travel)
  route = Geo.CustomImprove(route, travel, pred, succ)
  local discovered = 0
  if not Settings().noFMDetour then -- "Activate nearby flight masters" checked
    route, discovered = Geo.DiscoverFlightMasters(route, speed, plevel, cache)
  end

  -- Hearthstone: bind + hearths, with the travel times of the flight paths activated on the way.
  local nets = Geo.RouteNets(route, speed, plevel, cache)
  local netTo = {} -- point -> network of the leg arriving there
  for i = 2, #route do netTo[route[i].p] = nets[i] end
  local function legTravel(a, b)
    return (netTo[b] or base).travel(a, b)
  end
  local okH, withH = pcall(Geo.OptimizeHearth, route, legTravel)
  if not okH then Print(L["Hearthstone error: "] .. tostring(withH)) end
  if okH and withH and withH ~= route then route = Geo.FixHearth(withH, legTravel, Geo.HearthReady() or 0) end

  -- Flight masters met on the way (activated for free, usable afterwards), then boarding steps.
  nets = Geo.RouteNets(route, speed, plevel, cache)
  local okFM, withFM = false, nil
  if not Settings().noFMDetour then
    okFM, withFM = pcall(Geo.AddFlightMasterStops, route, function(k) return nets[k].net end, plevel)
  end
  if okFM and withFM then
    route = withFM
    for _, st in ipairs(route) do
      if st.kind == "fm" and not st.fmHub and st.fmId then
        st.fmHub = { id = st.fmId, node = st.fmNode, name = AreaName(st.p.area) or st.task.npc, p = st.p }
      end
    end
  end
  nets = Geo.RouteNets(route, speed, plevel, cache)
  local okT, withT = pcall(Geo.AddTransportStops, route, function(k) return nets[k].net end, plevel)
  if not okT then Print(L["Transport steps error: "] .. tostring(withT)) end
  if okT and withT then route = withT end

  -- Exact time and XP along the final route.
  nets = Geo.RouteNets(route, speed, plevel, cache)
  local t, questXP, mobXP = 0, 0, 0
  for i = 2, #route do
    local st = route[i]
    t = t + nets[i].travel(route[i - 1].p, st.p) + st.work
    st.at = t
    if st.kind == "turnin" or st.kind == "dungeon" then questXP = questXP + (st.xp or 0) end
    if st.kind == "obj" then mobXP = mobXP + (st.xp or 0) end
  end
  return route, nil, { speed = speed, skipped = #unplanned, unplanned = unplanned, total = t, xp = questXP + mobXP,
    mobXP = mobXP, count = #tasks, net = base.net, plevel = plevel, levels = Geo.Levels(route), later = {},
    custom = true, dungeons = #dungeons, discovered = discovered, netCache = cache }
end
