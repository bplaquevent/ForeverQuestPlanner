-- Forever Quest Planner: custom Roadbook: quests chosen by the player, fastest route to do them all.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, BuildNetwork, BuildScanContext, CharKey, DBXP = ns.AreaName, ns.BuildNetwork, ns.BuildScanContext, ns.CharKey, ns.DBXP
local Geo, GiverText, HasBit, IsCompleted, IsInLog, K = ns.Geo, ns.GiverText, ns.HasBit, ns.IsCompleted, ns.IsInLog, ns.K
local L, MakeStops, MakeTravel, PlayerPos, Print, QDB = ns.L, ns.MakeStops, ns.MakeTravel, ns.PlayerPos, ns.Print, ns.QDB
local QGet, QuestTargets, RemainingTargets, Settings, TravelSpeed = ns.QGet, ns.QuestTargets, ns.RemainingTargets, ns.Settings, ns.TravelSpeed

K.DUNGEON_TIME = 60       -- minutes spent inside a dungeon (setting)
K.MAX_PREREQ_DEPTH = 15   -- safety: prerequisite chain added with a quest
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

-- The Roadbook is followed (a step is focused); paused otherwise.
function Geo.Tracking()
  return ns.CP.CurrentFocus() ~= nil
end

-- Versions with two Roadbooks (automatic and custom, each saved apart): the one that was active
-- stays the Roadbook, its goal selected; the other one is dropped. The custom quest list stays.
function Geo.MigrateRoadbooks()
  local st = Settings()
  local ck = CharKey()
  local active = st.activeRoadbook and st.activeRoadbook[ck]
  -- Older versions (one Roadbook per view mode): the custom mode selected.
  if not active and not (st.roadbookMigrated and st.roadbookMigrated[ck]) and Geo.CustomRec().mode == "custom" then
    active = "custom"
  end
  if st.roadbookMigrated then
    st.roadbookMigrated[ck] = nil
    if next(st.roadbookMigrated) == nil then st.roadbookMigrated = nil end
  end
  Geo.CustomRec().mode = nil
  if st.activeRoadbook then
    st.activeRoadbook[ck] = nil
    if next(st.activeRoadbook) == nil then st.activeRoadbook = nil end
  end
  local store = st.roadbook
  local old = store and store[ck .. "|custom"]
  if not (active or old) then return end -- nothing to migrate
  if old then store[ck .. "|custom"] = nil end
  if active == "custom" and old then store[ck] = old end
  local rec = store and store[ck]
  if rec and rec.info and rec.info.custom then st.goal = { kind = "custom" } end
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
  Print(L["Added to the custom quest list: "] .. title ..
    (pre > 0 and string.format(L[" (+%d prerequisite quest(s))"], pre) or ""))
  Geo.CustomHint()
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
  Print(string.format(L["%d quest(s) added to the custom quest list"], added) ..
    (pre > 0 and string.format(L[" (+%d prerequisite quest(s))"], pre) or ""))
  if added > 0 then Geo.CustomHint() end
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
  Print(L["Removed from the custom quest list: "] .. (e.title or tostring(id)) ..
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
  Print(string.format(L["%d quest(s) removed from the custom quest list"], n) ..
    (extra > 0 and string.format(L[" (and %d prerequisite quest(s))"], extra) or ""))
  if n > 0 then Geo.CustomChanged() end
end

function Geo.CustomClear()
  Geo.CustomRec().list = {}
  Geo.customUnplanned = nil
  Print(L["Quests removed from the custom quest list; the steps done of the Roadbook are kept."])
  Geo.CustomChanged()
end

-- The list is not the Roadbook's (another goal, or no Roadbook): where it is used.
function Geo.CustomHint()
  if Geo.IsCustom() or (Geo.computing and Geo.computingGoal == "custom") then return end
  Print(L["The custom quest list is used by the Roadbook with the \"Custom list\" goal: choose it, then click \"Generate\"."])
end

-- List changed while the Roadbook is made of it: its steps to come are computed again (grouped
-- when several quests are added in a row), its steps done and its tracking kept; empty list: the
-- steps to come are removed and it is paused, the steps done stay (only "Delete" empties them).
-- A Roadbook with another goal is not touched (the list waits for "Generate" with the Custom goal).
function Geo.CustomChanged()
  Geo.customToken = (Geo.customToken or 0) + 1
  local token = Geo.customToken
  Geo.customCache = nil
  local mine = Geo.IsCustom() or (Geo.computing and Geo.computingGoal == "custom")
  if mine and #Geo.CustomList() == 0 then
    Geo.customUnplanned = nil
    if ns.CP then ns.CP.Pause(true) end
    if not Geo.KeepOnlyDone() then Geo.ClearFrozen() end
  elseif mine then
    C_Timer.After(0.6, function()
      if token == Geo.customToken and ns.CP then ns.CP.Recompute("custom", true) end
    end)
  end
  if ns.Refresh then ns.Refresh() end
  if Geo.QuestLogButtonSync then pcall(Geo.QuestLogButtonSync) end
end

StaticPopupDialogs["FQP_CUSTOM_CLEAR"] = {
  text = L["Remove every quest from the custom quest list?"],
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
  -- Profession level too low: the turn-in waits for it (the steps before it stay planned).
  local need = Geo.SkillNeed(e.id, q)
  if need then
    if q and q.complete then return nil, Geo.SkillNeedText(need) end
    task.warn = Geo.SkillNeedText(need)
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
    -- Pick-up: one step, or one per place where the quest giver may stand (all before the rest).
    local takes, isTake = {}, {}
    if task.kind == "take" then
      for _, s in ipairs(task.stops) do
        local c = s.kind == "take" and (s.inside or s)
        if c and not isTake[c] then
          isTake[c] = true
          takes[#takes + 1] = c
        end
      end
    end
    local turnin = task.stops[#task.stops]
    task.takesC = takes
    task.firstC = takes[1]
    task.lastC = turnin.inside or turnin
    for _, x in ipairs(task.order) do
      if not isTake[x] then
        for _, c in ipairs(takes) do before(c, x) end
      end
      if not isTake[task.lastC] then before(x, task.lastC) end -- (pick-up and turn-in in one dungeon visit: none)
    end
  end
  for _, b in ipairs(tasks) do
    for _, c in ipairs(b.takesC) do
      for _, a in ipairs(b.pres) do before(a.lastC, c) end
    end
  end
  return pred, succ
end

-- Fastest route doing every quest of the list (solver): dungeon visits, order rules (pick-up first,
-- turn-in last, prerequisites before), required levels (a quest picked up below it gets a warning,
-- an order rule that cannot be kept too), teleports, binds and flight paths activated on the way.
function Geo.PlanCustom(opts)
  local pos = PlayerPos()
  if not pos then return nil, L["Unknown position (in an instance or map unavailable)."] end
  Geo.xpScale, Geo.customCtx = nil, nil
  Geo.laterList = {}
  Geo.planSpeed = TravelSpeed()
  local cp, err, unplanned = Geo.CustomPlanSteps(pos, UnitLevel("player"))
  Geo.customUnplanned = cp and cp.unplanned or unplanned or {}
  if not cp then return nil, err end
  local P = Geo.Problem("custom", pos, cp)
  P.ban = opts and opts.ban
  local opt = Geo.Solve(P, "custom")
  for _, v in ipairs(opt.res.violations) do
    local s = v.kind == "level" and opt.route[v.i].src
    if s and s.task then s.task.levelWarn = true end
  end
  for _, s in ipairs(P.custom.steps) do
    if s.relaxed and s.src and s.src.task then s.src.task.orderWarn = true end
  end
  local route, info = Geo.FromSolver(P, opt.route, opt.res)
  local discovered = 0
  for _, st in ipairs(route) do if st.kind == "fm" then discovered = discovered + 1 end end
  info.custom, info.count, info.skipped, info.unplanned = true, #cp.tasks, #cp.unplanned, cp.unplanned
  info.dungeons, info.discovered, info.later = #cp.dungeons, discovered, {}
  return route, nil, info
end
