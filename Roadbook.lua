-- Forever Quest Planner: Roadbook checkpoints, saved Roadbook, Objective button.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local ActivePin, AllInstance, BuildNetwork, CharKey, ClearPin, Color = ns.ActivePin, ns.AllInstance, ns.BuildNetwork, ns.CharKey, ns.ClearPin, ns.Color
local DBXP, Dist, FormatTime, Geo, GeoReady, GetObjectives = ns.DBXP, ns.Dist, ns.FormatTime, ns.Geo, ns.GeoReady, ns.GetObjectives
local ICON, IsCompleted, IsInLog, K, L, Nearest = ns.ICON, ns.IsCompleted, ns.IsInLog, ns.K, ns.L, ns.Nearest
local PinPoint, PlayerPos, PointText, Print, QDB, QGet = ns.PinPoint, ns.PlayerPos, ns.PointText, ns.Print, ns.QDB, ns.QGet
local QuestTargets, Refresh, Route, Settings, Snapshot, StartScan = ns.QuestTargets, ns.Refresh, ns.Route, ns.Settings, ns.Snapshot, ns.StartScan
local KnownFlights, State, TaxiCount, TravelSpeed, TurnInText, WatchOnly = ns.KnownFlights, ns.State, ns.TaxiCount, ns.TravelSpeed, ns.TurnInText, ns.WatchOnly
local OpenQuestDetails, scan = ns.OpenQuestDetails, ns.scan

---------------------------------------------------------------------------
-- Roadbook checkpoints: focus on the next step from a floating button
---------------------------------------------------------------------------
local CP = {} -- Roadbook checkpoints (a table to stay under the local variables limit)

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
  if s.kind == "dungeon" then return L["enter the dungeon"] end
  if s.kind == "fm" then return L["activate the flight master"] end
  if s.kind == "bind" then return L["bind the hearthstone"] end
  if s.kind == "hearth" then return s.task.spell and L["teleport"] or L["hearthstone"] end
  if s.kind == "travel" then return L["transport"] end
  if s.kind == "take" then return L["pick up the quest"] end
  if s.kind == "obj" then return s.r and s.r.tg.name or L["objective"] end
  return L["turn in the quest"]
end

function CP.StepText(s)
  if s.kind == "fm" or s.kind == "bind" then return (s.task.title or "?") .. " (" .. (s.task.npc or "?") .. ")" end
  if s.kind == "hearth" or s.kind == "travel" or s.kind == "dungeon" then return s.task.title or "?" end
  local tag = (s.escort and L["Escort"]) or (s.kind == "take" and L["Pick up"]) or (s.kind == "obj" and L["Objective"]) or L["Turn in"]
  local extra = s.kind == "obj" and s.r and (L[": "] .. (s.r.tg.name or L["objective"]) .. L[" x"] .. s.r.count)
    or (s.search and string.format(L[" (possible place %d/%d)"], s.search.i, s.search.n)) or ""
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
  local moved = CP.focused ~= s
  CP.focused = s
  CP.focusRec = { questId = s.task.id, label = CP.StepPinLabel(s), area = s.p.area, mx = s.p.mx, my = s.p.my,
    progress = CP.Progress(s.task.id) }
  local qid = s.task.id
  if qid and IsInLog(qid) then WatchOnly(qid) end
  local fz = moved and s.kind == "turnin" and Geo.Frozen(Geo.ActiveKind())
  if fz and not CP.StepReady(s, fz.route) then
    local need = s.task.id and Geo.SkillNeed(s.task.id, CP.LogEntry(s.task.id))
    Print(Color(K.DESC.warn, need and (Geo.SkillNeedText(need) .. L[": "]) or L["Objectives not completed yet: "])
      .. (s.task.title or "?"))
  end
  Geo.MapClaim("track", Geo.ActiveKind()) -- the followed Roadbook holds the map (RoadbookMap.lua)
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

---------------------------------------------------------------------------
-- Saved Roadbook: once computed, the plan no longer changes until its end, or until a
-- recompute request (duration change, Recalculate button).
---------------------------------------------------------------------------
function Geo.CopyPoint(p)
  if not p then return nil end
  return { c = p.c, x = p.x, y = p.y, area = p.area, ui = p.ui, mx = p.mx, my = p.my, zoneName = p.zoneName,
    teleport = p.teleport, cast = p.cast, instance = p.instance, lmin = p.lmin, lmax = p.lmax }
end

-- Quest steps done inside a dungeon (dungeon step of the custom Roadbook).
function Geo.SerializeMembers(members)
  if not members then return nil end
  local out = {}
  for _, m in ipairs(members) do
    local t = m.task or {}
    out[#out + 1] = { kind = m.kind, id = t.id, title = t.title, level = t.level, xp = m.xp,
      objName = m.r and m.r.tg and m.r.tg.name, objKind = m.r and m.r.tg and m.r.tg.kind, count = m.r and m.r.count,
      objSource = m.r and m.r.tg and m.r.tg.sourceItem }
  end
  return out
end

function Geo.DeserializeMembers(list)
  if not list then return nil end
  local out = {}
  for _, m in ipairs(list) do
    out[#out + 1] = { kind = m.kind, xp = m.xp, task = { id = m.id, title = m.title, level = m.level },
      r = m.objName and { tg = { name = m.objName, kind = m.objKind, sourceItem = m.objSource }, count = m.count } or nil }
  end
  return out
end

function Geo.SerializeStep(st)
  local t = st.task or {}
  return { kind = st.kind, at = st.at, xp = st.xp, work = st.work, gain = st.gain, spots = st.spots, quick = st.quick,
    escort = st.escort, glue = st.glue, via = st.via, bindDest = st.bindDest, search = st.search,
    fmHub = st.fmHub and { id = st.fmHub.id, node = st.fmHub.node, name = st.fmHub.name, p = Geo.CopyPoint(st.fmHub.p) } or nil,
    members = Geo.SerializeMembers(t.members),
    spotN = st.spot and st.spot.n, done = st.done, p = Geo.CopyPoint(st.p),
    objName = st.r and st.r.tg and st.r.tg.name, objKind = st.r and st.r.tg and st.r.tg.kind, count = st.r and st.r.count,
    objSource = st.r and st.r.tg and st.r.tg.sourceItem, afterSource = st.afterSource,
    first = t.stops and t.stops[1] == st or nil,
    task = { id = t.id, title = t.title, level = t.level, xp = t.xp, starter = t.starter, reqLevel = t.reqLevel,
      depTitle = t.dep and t.dep.title, tags = t.tags, npc = t.npc, mode = t.mode, from = t.from, dest = t.dest,
      destP = Geo.CopyPoint(t.destP), kind = t.kind, quick = t.quick, dungeon = t.dungeon, warn = t.warn,
      levelWarn = t.levelWarn, orderWarn = t.orderWarn, spell = t.spell } }
end

function Geo.DeserializeStep(rec, tasks)
  local tr = rec.task or {}
  local key = tostring(tr.id) .. "|" .. tostring(tr.title) .. "|" .. tostring((rec.kind == "travel" or rec.kind == "dungeon") and rec.at or "")
  local task = tasks[key]
  if not task then
    task = { id = tr.id, title = tr.title, level = tr.level, xp = tr.xp, starter = tr.starter, reqLevel = tr.reqLevel,
      dep = tr.depTitle and { title = tr.depTitle } or nil, tags = tr.tags, npc = tr.npc, mode = tr.mode,
      from = tr.from, dest = tr.dest, destP = tr.destP, kind = tr.kind, quick = tr.quick, stops = {},
      dungeon = tr.dungeon, warn = tr.warn, levelWarn = tr.levelWarn, orderWarn = tr.orderWarn, spell = tr.spell,
      members = Geo.DeserializeMembers(rec.members) }
    tasks[key] = task
  end
  local st = { kind = rec.kind, at = rec.at, xp = rec.xp, work = rec.work or 0, gain = rec.gain, spots = rec.spots, quick = rec.quick,
    escort = rec.escort, glue = rec.glue, fmHub = rec.fmHub, via = rec.via, bindDest = rec.bindDest, search = rec.search,
    spot = rec.spotN and { n = rec.spotN } or nil, done = rec.done, p = rec.p or {}, task = task, afterSource = rec.afterSource,
    r = rec.objName and { tg = { name = rec.objName, kind = rec.objKind, sourceItem = rec.objSource }, count = rec.count } or nil }
  if rec.first then task.stops[1] = st end
  return st
end

function Geo.FrozenStore()
  local st = Settings()
  st.roadbook = st.roadbook or {}
  return st.roadbook
end

-- Two Roadbooks per character, each with its progress: "auto" and "custom".
Geo.frozen = {} -- kind -> { route, info } (loaded plans)

function Geo.FrozenRec(kind)
  return kind and Geo.FrozenStore()[Geo.FrozenKey(kind)] or nil
end

-- Saves a plan of a kind. excluded: quests skipped by the player in this Roadbook (id -> title),
-- kept when the route is adapted; a new Roadbook starts without any.
function Geo.Freeze(route, info, excluded, kind)
  local steps = {}
  for i = 2, #route do steps[#steps + 1] = Geo.SerializeStep(route[i]) end
  local slim = { count = info.count, xp = info.xp, total = info.total, mobXP = info.mobXP, levels = info.levels,
    speed = info.speed, plevel = info.plevel, skipped = info.skipped, later = info.later, taxi = info.net and info.net.taxi,
    custom = info.custom, unplanned = info.unplanned, dungeons = info.dungeons, discovered = info.discovered,
    goal = info.goal, goalStage = info.goalStage }
  Geo.FrozenStore()[Geo.FrozenKey(kind)] = { saved = date and date("%H:%M") or "",
    start = Geo.CopyPoint(route[1].p), steps = steps, info = slim, excluded = excluded, recall = Geo.RecallState() }
  Geo.frozen[kind] = { route = route, info = info }
  Geo.MapSync() -- a new or adapted plan: redrawn on the map if it is there
end

-- Saved plan of a kind (reloaded after a /reload), or nil.
function Geo.Frozen(kind)
  if not kind then return nil end
  if Geo.frozen[kind] then return Geo.frozen[kind] end
  local rec = Geo.FrozenRec(kind)
  if not (rec and rec.steps and #rec.steps > 0) then return nil end
  -- After a /reload, the QuestieDB map mappings are not loaded yet.
  if not GeoReady() then return nil end
  local route, tasks = { { kind = "start", p = rec.start or {}, work = 0 } }, {}
  for _, r in ipairs(rec.steps) do route[#route + 1] = Geo.DeserializeStep(r, tasks) end
  local info = {}
  for k, v in pairs(rec.info or {}) do info[k] = v end
  info.net = BuildNetwork(info.speed or TravelSpeed())
  info.net.taxi = TaxiCount()
  Geo.frozen[kind] = { route = route, info = info }
  return Geo.frozen[kind]
end

-- Empties a Roadbook (its steps and its progress); the other one is not touched.
function Geo.ClearFrozen(kind)
  Geo.frozen[kind] = nil
  Geo.FrozenStore()[Geo.FrozenKey(kind)] = nil
  if kind == "custom" then Geo.customCache = nil else Geo.planCache = nil end
end

-- Steps to come removed, the steps done kept (history): the custom Roadbook whose list was emptied.
-- Returns false when no step is done (nothing to keep).
function Geo.KeepOnlyDone(kind)
  local fz = Geo.Frozen(kind)
  if not fz then return false end
  local start = { { kind = "start", p = fz.route[1].p, work = 0 } }
  local info = {}
  for k, v in pairs(fz.info) do info[k] = v end
  local route = Geo.KeepDone(fz, CP.StepDone, start, { total = 0, levels = {} }, info)
  if #route < 2 then return false end
  info.dungeons, info.discovered, info.skipped, info.unplanned = nil, nil, nil, nil
  Geo.Freeze(route, info, Geo.FrozenRec(kind) and Geo.FrozenRec(kind).excluded, kind)
  return true
end

-- Every step of the Roadbook is done: it can only be extended (quests added), generated again or deleted.
function Geo.IsFinished(kind)
  local fz = Geo.Frozen(kind)
  if not fz or #fz.route < 2 then return false end
  for i = 2, #fz.route do
    if not CP.StepDone(fz.route[i]) then return false end
  end
  return true
end

-- A Roadbook of this kind exists (saved, or being computed).
function Geo.HasRoadbook(kind)
  if Geo.computing == kind then return true end
  local rec = Geo.FrozenRec(kind)
  return (rec and rec.steps and #rec.steps > 0) or false
end

-- Every Roadbook is empty (no steps, empty custom list): the automatic one becomes the active one again.
function Geo.ResetActiveIfEmpty()
  if Geo.ActiveKind() == "auto" or #Geo.CustomRec().list > 0 then return end
  if Geo.HasRoadbook("custom") or Geo.HasRoadbook("auto") then return end
  Geo.SetActive("auto")
end

-- Quests skipped by the player in a Roadbook (id -> title).
function Geo.Excluded(kind)
  local rec = Geo.FrozenRec(kind)
  return rec and rec.excluded or {}
end

-- Marks a step as done (and saves it), in the Roadbook that holds it.
function Geo.MarkDone(st, value)
  if value == nil then value = true end
  st.done = value or nil
  for kind, fz in pairs(Geo.frozen) do
    local rec = Geo.FrozenRec(kind)
    if rec and rec.steps then
      for i = 2, #fz.route do
        if fz.route[i] == st and rec.steps[i - 1] then rec.steps[i - 1].done = value or nil end
      end
    end
  end
end

-- Quick wins: a quest from the log that became ready to turn in during the Roadbook, whose NPC is
-- next to an upcoming step (or to you), is added to the saved plan right after that step.
function Geo.InjectQuickWins(kind)
  local fz = Geo.Frozen(kind)
  if not fz then return 0 end
  local route = fz.route
  local rec = Geo.FrozenRec(kind)
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
    if q.complete and not q.failed and not pending[q.id] and not Geo.Excluded(kind)[q.id] and IsInLog(q.id)
      and not Geo.SkillNeed(q.id, q)
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
  if added > 0 and focusNew and cur then CP.FocusStep(focusNew) end
  return added
end

-- Step already done: marked, or observed in the game (quest picked up, objective done, quest turned in…).
function CP.StepDone(st)
  if st.done then return true end
  if st.kind == "dungeon" then -- every quest step done inside
    for _, m in ipairs(st.task.members or {}) do
      if not CP.StepDone(m) then return false end
    end
    return true
  end
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
    -- Source item (not a game objective): done once it is in the bags.
    local src = st.r and st.r.tg and st.r.tg.sourceItem
    if src then return (GetItemCount(src) or 0) > 0 end
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
    local node = (st.fmHub and st.fmHub.node) or Geo.NodeAt(st.p)
    if node and Geo.KnownNodes()[node] then return true end
  end
  return false
end

-- Quest log entry of a quest (last capture), or nil.
function CP.LogEntry(id)
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do
    if q.id == id then return q end
  end
  return nil
end

-- Step that can be done now (order of its quest): a turn-in once the other steps of its quest in
-- the Roadbook are done (or the quest complete in the log), an objective once its pick-up is done
-- (and the source item it uses is in the bags).
function CP.StepReady(st, route)
  if st.kind == "travel" or st.kind == "hearth" then -- on the way to the next real step: ready with it
    local after
    for i = 2, #route do
      if route[i] == st then after = i break end
    end
    for i = (after or #route) + 1, #route do
      local o = route[i]
      if o.kind ~= "travel" and o.kind ~= "hearth" then return CP.StepReady(o, route) end
    end
    return true
  end
  local id = st.task and st.task.id
  if not id or (st.kind ~= "turnin" and st.kind ~= "obj") then return true end
  if st.kind == "turnin" and Geo.SkillNeed(id, CP.LogEntry(id)) then return false end -- profession level
  if st.kind == "turnin" and IsInLog(id) and C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) then return true end
  for i = 2, #route do
    local o = route[i]
    if o ~= st and o.task and o.task.id == id and not CP.StepDone(o)
      and (o.kind == "take" or (st.kind == "turnin" and o.kind == "obj")
        or (st.afterSource and o.r and o.r.tg and o.r.tg.sourceItem)) then
      return false
    end
  end
  return true
end

-- Computes a Roadbook of a kind and saves it; cb(route, err, info) when done.
-- keepDone: the steps done of the saved Roadbook stay first (history), only the steps to come are
-- computed again; otherwise the Roadbook is emptied first.
-- re (Roadbook adapted, CP.Replan): { goal = goal of this computation, goalInfo = goal shown (the
-- Roadbook's own), opts = Geo.RequestPlan options }.
function Geo.Recompute(kind, cb, keepDone, re)
  if not keepDone then Geo.ClearFrozen(kind) end
  Snapshot()
  if CP.checkpointButton and CP.checkpointButton.sub then CP.checkpointButton.sub:SetText(string.format(L["Computing the Roadbook (up to %d s)…"], K.PLAN_TIME)) end
  local goal = (re and re.goal) or (kind == "custom" and "custom") or State.xpGoal
  Geo.RequestPlan(goal, function(route, err, info)
    if Geo.computing ~= kind then return end -- deleted meanwhile
    Geo.computing = nil
    if route and #route >= 2 then
      local old = keepDone and Geo.Frozen(kind)
      local rec = keepDone and Geo.FrozenRec(kind)
      if old then route = Geo.KeepDone(old, CP.StepDone, route, info, info) end
      if re and re.goalInfo then
        info.goal = re.goalInfo -- the Roadbook keeps its goal (a duration: the whole session)
        if info.goal.kind == "level" then
          info.goalStage = (info.levels[#info.levels] or 0) < info.goal.value or nil
        else
          info.goalStage = nil
        end
      end
      Geo.Freeze(route, info, rec and rec.excluded or nil, kind) -- quests skipped in it stay out
    end
    if cb then cb(route, err, info) end
    if Refresh then C_Timer.After(0.1, Refresh) end
  end, true, re and re.opts)
end

-- Name of a Roadbook kind, for the messages.
function CP.KindName(kind)
  return kind == "custom" and L["custom Roadbook"] or L["automatic Roadbook"]
end

-- Focuses the first step of the active Roadbook that is not done yet.
-- At the end of the plan, the Roadbook is paused (kept, every step done): "Generate" makes a new one.
function CP.FocusNext(silent, after)
  local kind = Geo.ActiveKind()
  local fz = Geo.Frozen(kind)
  if fz then
    -- Start from the step that was just done, then wrap around from the beginning of the plan.
    local start = 2
    if after then
      for i = 2, #fz.route do if fz.route[i] == after then start = i + 1 break end end
    end
    local order = {}
    for i = start, #fz.route do order[#order + 1] = i end
    for i = 2, math.min(start - 1, #fz.route) do order[#order + 1] = i end
    -- Only a step that can be done now: a turn-in after the objectives of its quest, an objective
    -- after its pick-up (a step done ahead must not lead to the turn-in of an unfinished quest).
    -- None: the first step not done of the plan.
    local pick
    for _, i in ipairs(order) do
      local st = fz.route[i]
      if not CP.StepDone(st) and CP.StepReady(st, fz.route) then pick = st break end
    end
    if not pick then
      for i = 2, #fz.route do
        if not CP.StepDone(fz.route[i]) then pick = fz.route[i] break end
      end
    end
    if pick then
      CP.FocusStep(pick)
      if not silent then Print(L["Focus: "] .. CP.StepText(pick)) end
      if Refresh then C_Timer.After(0.2, Refresh) end
      return
    end
    local g = kind == "auto" and fz.info.goal
    if kind == "custom" then
      Print(L["Custom Roadbook finished: every quest of the list is done."])
    elseif g and g.kind == "level" and UnitLevel("player") < g.value then
      Print(string.format(L["Stage finished: click \"Generate\" in the Roadbook tab to continue to level %d."], g.value))
    else
      Print(L["Roadbook finished: click \"Generate\" in the Roadbook tab for a new one."])
    end
    CP.Pause(kind, true)
    return
  end
  CP.ShowActive()
end

-- Active Roadbook empty: the window opens on its tab, where it is generated (or filled).
function CP.ShowActive()
  local tab = Geo.TabOf(Geo.ActiveKind())
  if CP.OpenWindow and not (State.mainFrame and State.mainFrame:IsShown() and State.currentTab == tab) then
    CP.OpenWindow(tab)
  end
end

-- Stops the tracking of the active Roadbook (focus, pin, compass) without touching its steps; the
-- map gets back what it showed before (RoadbookMap.lua).
function CP.StopFocus()
  CP.ClearFocus()
  ClearPin()
  if Geo.MapOwner() and Geo.MapOwner().mode == "track" then Geo.MapRelease() end
  CP.RefreshButton()
end

-- A finished Roadbook cannot be started again: what can be done with it.
function CP.FinishedMessage(kind)
  Print(kind == "custom" and L["Custom Roadbook finished: add quests to extend it, or delete it."]
    or L["Roadbook finished: click \"Generate\" for a new one, or delete it."])
end

-- Starts a Roadbook (Start button of its tab): it becomes the active one (the only way to change
-- it); if the other one was followed, it is paused first, after confirmation.
function CP.Start(kind)
  if Geo.computing == kind then
    Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
    return
  end
  if not Geo.Frozen(kind) then
    Print(kind == "custom" and L["The custom Roadbook is empty: add quests with the \"Add\" button of the other tabs."]
      or L["This Roadbook has no step: click \"Generate\" first."])
    return
  end
  if Geo.IsFinished(kind) then
    CP.FinishedMessage(kind)
    return
  end
  local cur = Geo.ActiveKind()
  if cur ~= kind and Geo.Tracking() then
    StaticPopup_Show("FQP_SWITCH", CP.KindName(cur), CP.KindName(kind), { kind = kind })
    return
  end
  CP.DoStart(kind)
end

function CP.DoStart(kind)
  if Geo.ActiveKind() ~= kind then
    CP.StopFocus()
    Geo.SetActive(kind)
  end
  if not Geo.Tracking() then Print(L["Roadbook started: "] .. CP.KindName(kind) .. ".") end
  local ok, res = pcall(CP.Resync, kind)
  if not ok then Print(L["Roadbook update error: "] .. tostring(res)) end
  if not (ok and res) then CP.FocusNext(false) end
  CP.RefreshButton()
  if Refresh then Refresh() end
end

-- Start of a Roadbook: if the hearthstone / teleport cooldowns changed since it was saved, or if you
-- are elsewhere while one can be used, the steps to come are computed again (CP.RecallCheck).
-- Otherwise its next transport steps are matched to where the player is now. The ones
-- up to a destination already reached are done; a flight / boat step far from both its departure
-- and the previous step is replaced by the route from here. Returns true if the focus was placed
-- (or will be, after the computation).
function CP.Resync(kind)
  local okR, replanned = pcall(CP.RecallCheck, kind, true)
  if not okR then Print(L["Roadbook update error: "] .. tostring(replanned)) end
  if okR and replanned then return true end
  local fz = Geo.Frozen(kind)
  local pos = PlayerPos()
  if not (fz and pos) then return false end
  local route = fz.route
  local first
  for i = 2, #route do if not CP.StepDone(route[i]) then first = i break end end
  if not first then return false end
  local reached
  local i = first
  while route[i] and (route[i].kind == "hearth" or route[i].kind == "travel") do
    if CP.TransportReached(route[i], pos) then reached = i end
    i = i + 1
  end
  local nextI = first
  if reached then
    for j = first, reached do
      if not CP.StepDone(route[j]) then
        Print(L["Already there, step skipped: "] .. CP.StepText(route[j]))
        Geo.MarkDone(route[j])
      end
    end
    nextI = reached + 1
    while route[nextI] and CP.StepDone(route[nextI]) do nextI = nextI + 1 end
  end
  local st = route[nextI]
  if not (st and st.kind == "travel") then return false end
  local function far(p)
    local d = Dist(pos, p)
    return not d or d > K.LANDING_RADIUS
  end
  if far(st.p) and far(route[nextI - 1].p) then return CP.Reroute(st, pos, L["Position changed: new route. "]) end
  return false
end

-- Hearthstone and class teleports ---------------------------------------------
-- The saved Roadbook keeps the state of the ways back (cooldowns, runes, bind location) it was
-- computed with. When it changes (or, at start, when you are elsewhere), the steps to come are
-- adapted to the position and the cooldowns now; the steps done stay (history).

-- The planned use of a way back (or the planned bind) is not a change: the saved state follows it.
function Geo.RestampRecalls(kind)
  local rec = Geo.FrozenRec(kind or Geo.ActiveKind())
  if rec then rec.recall = Geo.RecallState() end
end

-- Returns true if an update was started. atStart: the tracking (re)starts; the position counts too.
function CP.RecallCheck(kind, atStart)
  local fz, rec = Geo.Frozen(kind), Geo.FrozenRec(kind)
  if not (fz and rec) or Geo.computing then return false end
  local now = Geo.RecallState()
  if not rec.recall and not atStart then -- Roadbook from a former version: its state starts now
    rec.recall = now
    return false
  end
  local route, first = fz.route, nil
  for i = 2, #route do if not CP.StepDone(route[i]) then first = i break end end
  if not first then return false end
  local changed = Geo.RecallChanged(rec.recall, now)
  if not changed and atStart then
    local ahead = next(now.src) ~= nil
    for i = first, #route do
      if route[i].kind == "hearth" or route[i].kind == "bind" then ahead = true break end
    end
    local pos = PlayerPos()
    local d = ahead and pos and Dist(pos, route[first - 1].p)
    changed = d ~= nil and d > K.LANDING_RADIUS
  end
  if not changed then return false end
  return CP.RecallReplan(kind, L["Position or hearthstone / teleport cooldowns changed: the steps to come are updated. "])
end

-- Roadbook adapted (position or cooldowns changed, quest or transport skipped, quest giver found):
-- the steps to come are planned again from here, the steps done stay (history). Custom Roadbook:
-- every quest left of its list in the least time. Automatic one: its goal again, a duration being
-- what was left of it (planned time of the last step done), a level the same level.
-- opts: { ban = transport not usable on the first leg }. Returns true if a computation started.
K.REPLAN_MIN_TIME = 600 -- seconds: less left of a duration goal: only the route is adapted
function CP.Replan(kind, msg, opts)
  if not GeoReady() then return false end
  if Geo.computing then
    Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
    return false
  end
  local re = { opts = opts or {} }
  if kind == "custom" then
    if #Geo.CustomList() == 0 then return false end
    re.goal = "custom"
  else
    local fz = Geo.Frozen(kind)
    local g = fz and fz.info.goal
    if not (g and g.kind and g.value) or UnitLevel("player") >= Geo.MaxLevel() then return false end
    if g.kind == "time" then
      local t0 = 0
      for i = 2, #fz.route do
        local st = fz.route[i]
        if CP.StepDone(st) then t0 = math.max(t0, st.at or 0) end
      end
      local left = g.value - t0
      if left < K.REPLAN_MIN_TIME then return false end
      re.goal = { kind = "time", value = left }
    else
      if UnitLevel("player") >= g.value then return false end
      re.goal = { kind = "level", value = g.value }
    end
    re.goalInfo = { kind = g.kind, value = g.value }
  end
  Print(msg .. string.format(L["Computing the Roadbook (up to %d s)…"], K.PLAN_TIME))
  if Geo.ActiveKind() == kind then CP.focusAfter = kind end
  CP.Recompute(kind, true, nil, nil, re)
  return true
end

-- Steps to come computed again from here (CP.Replan); when it cannot be, the automatic Roadbook keeps
-- its quests and their order (only travel, flight master, hearthstone and teleport steps change).
-- The focus goes to the first step to do of the adapted plan.
function CP.RecallReplan(kind, msg)
  if CP.Replan(kind, msg) then return true end
  if kind == "custom" or Geo.computing then return false end
  local fz = Geo.Frozen(kind)
  local ok, route, info = pcall(Geo.Reroute, fz, false, CP.StepDone)
  if not ok then
    Print(L["Roadbook update error: "] .. tostring(route))
    return false
  end
  Geo.Freeze(route, info, Geo.FrozenRec(kind) and Geo.FrozenRec(kind).excluded, kind)
  local target
  for i = 2, #route do
    local st = route[i]
    if not CP.StepDone(st) then target = st break end
  end
  CP.ClearFocus()
  if target then
    Print(msg .. L["Focus: "] .. CP.StepText(target))
    CP.FocusStep(target)
  else
    Print(msg)
    CP.FocusNext(false)
  end
  if Refresh then C_Timer.After(0.2, Refresh) end
  return true
end

-- While a Roadbook is followed: cooldown, rune, spell or bind changes are checked a few seconds
-- later (never during a flight, a fight or a computation).
function CP.ScheduleRecallCheck(delay)
  if not (Geo.Tracking() and GetTime) then return end
  local now = GetTime()
  local at = math.max(CP.recallAt or 0, now + (delay or 3))
  CP.recallAt = at
  CP.recallToken = (CP.recallToken or 0) + 1
  local token = CP.recallToken
  C_Timer.After(at - now, function()
    if token ~= CP.recallToken then return end
    CP.recallAt = nil
    local kind = Geo.ActiveKind()
    if not (Geo.Tracking() and Geo.Frozen(kind)) then return end
    if CP.flying or Geo.computing or (UnitOnTaxi and UnitOnTaxi("player")) or (InCombatLockdown and InCombatLockdown())
      or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) or not PlayerPos() then
      CP.ScheduleRecallCheck(10)
      return
    end
    local ok, err = pcall(CP.RecallCheck, kind, false)
    if not ok then Print(L["Roadbook update error: "] .. tostring(err)) end
  end)
end

-- Cast of the hearthstone or of a class teleport (key: "hearth" or the spell id).
function CP.RecallCast(key)
  local s = CP.CurrentFocus()
  if s and s.kind == "hearth" and tostring(s.via or "hearth") == tostring(key) then
    C_Timer.After(1.5, function() Geo.RestampRecalls() end) -- the planned one
  else
    CP.ScheduleRecallCheck(8) -- unplanned: the route is adapted after the arrival
  end
end

StaticPopupDialogs["FQP_SWITCH"] = {
  text = L["Pause the %s and start the %s?\n\nThe paused Roadbook keeps its progress."],
  button1 = YES or L["Yes"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, data) if data and data.kind then CP.DoStart(data.kind) end end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Pauses a Roadbook: only its tracking stops, its steps and their progress are kept; it stays the
-- active one.
function CP.Pause(kind, quiet)
  if not kind or Geo.ActiveKind() ~= kind then return end
  CP.StopFocus()
  if not quiet then Print(L["Roadbook paused: its progress is kept. Click the Objective button to resume it."]) end
  if Refresh then C_Timer.After(0.1, Refresh) end
end

-- Deletes a Roadbook after confirmation: tracking stopped, steps emptied, and the quest list of
-- the custom Roadbook emptied too.
function CP.Delete(kind)
  StaticPopup_Show("FQP_DELETE", CP.KindName(kind), nil, { kind = kind })
end

function CP.DoDelete(kind)
  if Geo.computing == kind then -- computation in progress: cancelled
    Geo.co, Geo.runningKey, Geo.planCbs, Geo.computing = nil, nil, nil, nil
    CP.computeToken = (CP.computeToken or 0) + 1
  end
  CP.Pause(kind, true)
  local owner = Geo.MapOwner()
  if owner and owner.kind == kind then Geo.MapRelease() end -- its preview ends
  Geo.ClearFrozen(kind)
  if kind == "custom" then
    Geo.CustomRec().list = {}
    Geo.customUnplanned = nil
    Geo.customToken = (Geo.customToken or 0) + 1 -- no pending recompute
  end
  Geo.ResetActiveIfEmpty()
  Print(L["Roadbook deleted: "] .. CP.KindName(kind) .. ".")
  CP.RefreshButton()
  if Refresh then Refresh() end
end

StaticPopupDialogs["FQP_DELETE"] = {
  text = L["Delete the %s?\n\nIts steps and their progress are lost (and the quest list, for the custom Roadbook)."],
  button1 = DELETE or L["Delete"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, data) if data and data.kind then CP.DoDelete(data.kind) end end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Same Roadbook step in two computations (quest, kind, objective or place).
function CP.SameStep(a, b)
  if a.kind ~= b.kind then return false end
  local ta, tb = a.task or {}, b.task or {}
  if ta.id or tb.id then
    if ta.id ~= tb.id then return false end
    if a.kind == "obj" then
      return (a.r and a.r.tg and a.r.tg.name) == (b.r and b.r.tg and b.r.tg.name)
    end
    if a.search or b.search then -- a place to check for the quest giver: the same place
      local d = Dist(a.p, b.p)
      return d ~= nil and d < K.START_MERGE
    end
    return true
  end
  return ta.title == tb.title
end

-- Flight node named `name` (the game's name) at the planned destination: a flight master
-- activated on the way has a planned name that may differ from the game's.
function CP.NearDest(name, destP)
  local id = name and Geo.TaxiNames().byName[name]
  local node = id and Geo.NodePoint(id)
  local d = node and destP and Dist(node, destP)
  return d ~= nil and d < K.LANDING_RADIUS
end

-- Goal of the automatic Roadbook (session duration or level to reach), used by the next "Generate";
-- the current Roadbook is kept. Each kind keeps its last value.
function CP.SetGoal(kind, value)
  local st = Settings()
  if kind == "time" then st.goalTime = value else st.goalLevel = value end
  local g = State.xpGoal
  if g.kind == kind and g.value == value then return end
  State.xpGoal = { kind = kind, value = value }
  st.goal = { kind = kind, value = value }
  scan.dirty = true -- the levels scanned for the Roadbook follow the goal
  if Refresh then Refresh() end
end

-- "Generate" button: an existing Roadbook is replaced, after confirmation (it is stopped first);
-- the new one has to be started.
function CP.Generate(kind)
  if Geo.HasRoadbook(kind) and not Geo.computing then
    StaticPopup_Show("FQP_REGENERATE", CP.KindName(kind), nil, { kind = kind })
    return
  end
  CP.Recompute(kind)
end

StaticPopupDialogs["FQP_REGENERATE"] = {
  text = L["Generate a new %s?\n\nThe current Roadbook is replaced and its progress lost; the new one has to be started."],
  button1 = L["Generate"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, data)
    if not (data and data.kind) then return end
    CP.Pause(data.kind, true)
    CP.Recompute(data.kind)
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Empties the Roadbook of this kind and computes it again; it is not started.
-- keep: recompute after a change of the custom list, the tracking goes on.
-- re: the Roadbook adapted (CP.Replan), see Geo.Recompute.
function CP.Recompute(kind, keep, attempt, token, re)
  if not attempt then
    if not GeoReady() then
      Print(L["Unable to convert QuestieDB positions to this client's map."])
      return
    end
    if kind == "custom" and #Geo.CustomList() == 0 then
      if not keep then Print(L["The custom Roadbook is empty: add quests with the \"Add\" button of the other tabs."]) end
      return
    end
    if Geo.computing then -- one computation at a time
      if keep then
        local t = Geo.customToken
        C_Timer.After(1, function() if t == Geo.customToken then CP.Recompute(kind, keep, nil, nil, re) end end)
      else
        Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
      end
      return
    end
    CP.computeToken = (CP.computeToken or 0) + 1
    token = CP.computeToken
    Geo.computing, Geo.computeStart = kind, GetTime and GetTime() or 0
    if not keep then Geo.ClearFrozen(kind) end
    if Refresh then Refresh() end
  end
  if token ~= CP.computeToken then return end -- deleted meanwhile
  -- Available quests change after a pick-up or turn-in: wait for their scan to finish.
  if kind == "auto" and (scan.running or scan.dirty or not scan.entries) then
    if not scan.running then StartScan() end
    attempt = (attempt or 0) + 1
    if attempt > 40 then
      Geo.computing = nil
      Print(L["Quest scan is taking too long: try again in a moment."])
      if Refresh then Refresh() end
      return
    end
    C_Timer.After(0.5, function() CP.Recompute(kind, keep, attempt, token, re) end)
    return
  end
  local was = Geo.ActiveKind() == kind and CP.CurrentFocus() or nil
  Geo.Recompute(kind, function(route, err)
    local refocus = CP.focusAfter == kind -- tracking (re)started during the computation
    CP.focusAfter = nil
    if not route or #route < 2 then
      Print(err or L["The Roadbook is empty: no step to follow."])
      CP.RefreshButton()
      return
    end
    if not keep then
      Print(L["Roadbook ready: click \"Start\" in the Roadbook tab to follow it."])
      CP.RefreshButton()
      return
    end
    if not was then
      if refocus and Geo.ActiveKind() == kind then CP.FocusNext(false) else CP.RefreshButton() end
      return
    end
    -- Recomputed while followed: the focus goes to the first step of the new plan that can be done
    -- (steps inserted before the current one come first); a change of step is announced.
    CP.ClearFocus()
    CP.FocusNext(true)
    local now = CP.focused
    if now and not CP.SameStep(now, was) then Print(L["Focus: "] .. CP.StepText(now)) end
  end, keep, re)
end

-- Click on the button. Active Roadbook not followed: it starts (empty: the window opens on its tab,
-- where a Roadbook is made). Followed: the game's quest log opens on the quest of the current step,
-- or, with no quest in the log, the world map centered on the step's pin.
function CP.ObjectiveClickUnsafe()
  local kind = Geo.ActiveKind()
  if not Geo.Frozen(kind) then
    if Geo.computing == kind then Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME)) else CP.ShowActive() end
    return
  end
  if not Geo.Tracking() then
    if Geo.IsFinished(kind) then
      CP.FinishedMessage(kind)
      CP.ShowActive()
    else
      CP.DoStart(kind)
    end
    return
  end
  local cur = CP.CurrentFocus()
  if not cur then return end
  local qid = cur.task and cur.task.id
  if qid and IsInLog(qid) then
    OpenQuestDetails(qid)
  else
    Geo.ShowStep(cur, kind)
  end
end

-- Skips a step with no quest (hearthstone, transport…): it is marked done; if it is the followed
-- one, the focus moves to the next step.
function CP.SkipStep(s)
  local followed = CP.CurrentFocus() == s
  Print(L["Step skipped: "] .. CP.StepText(s))
  Geo.MarkDone(s)
  -- Transport skipped: the steps to come are planned again without it for the way to the next step
  -- (only this time: it can be proposed again later).
  if s.kind == "travel" then
    local kind
    for k, fz in pairs(Geo.frozen) do
      for i = 2, #fz.route do if fz.route[i] == s then kind = k end end
    end
    local ban = { mode = s.task.mode, from = s.p, to = s.task.destP }
    if kind and CP.Replan(kind, L["Transport skipped: the Roadbook is adapted without it. "], { ban = ban }) then
      return -- the focus moves when the computation ends
    end
  end
  if followed then
    CP.FocusNext(false, s)
  else
    CP.RefreshButton()
    if Refresh then Refresh() end
  end
end

-- Asks before skipping a quest (CP.SkipQuest): every step of the quest leaves the Roadbook.
function CP.ConfirmSkipQuest(s, kind)
  local title = s.task.title or tostring(s.task.id)
  local text = kind == "custom"
    and string.format(L["Remove \"%s\" from the custom Roadbook?\n\nThe prerequisite quests added only for it leave too, and the steps to come are computed again (the steps done stay)."], title)
    or string.format(L["Skip the quest \"%s\"?\n\nIts steps to come leave the automatic Roadbook and the route is adapted (the steps done stay); it comes back with a new Roadbook."], title)
  StaticPopup_Show("FQP_SKIP_QUEST", text, nil, { s = s, kind = kind })
end

StaticPopupDialogs["FQP_SKIP_QUEST"] = {
  text = "%s",
  button1 = YES or L["Yes"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, data) if data and data.s then CP.SkipQuest(data.s, data.kind) end end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Skips a quest (badly defined, not found, not wanted…): all its steps leave the Roadbook, which
-- persists: the route of the steps left is adapted, no quest is added, the steps done are kept.
-- The quest stays out until a new Roadbook. Custom Roadbook: the quest leaves the list.
function CP.SkipQuest(s, kind)
  local id = s and s.task and s.task.id
  if not id then return end
  if kind == "custom" then -- custom Roadbook: the quest leaves the list (and the route is computed again)
    Geo.CustomRemove(id)
    return
  end
  local fz = Geo.Frozen("auto")
  if not fz then return end
  if Geo.computing then
    Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
    return
  end
  local title = s.task.title
  local excluded = {}
  for k, v in pairs(Geo.Excluded("auto")) do excluded[k] = v end
  excluded[id] = title or true
  local rec = Geo.FrozenRec("auto")
  if rec then rec.excluded = excluded end -- read by the computation (Geo.TakeTask, BuildTasks)
  if CP.Replan("auto", L["Quest skipped: "] .. (title or tostring(id)) .. ". ") then return end
  local wasFocus = CP.CurrentFocus()
  local ok, route, info = pcall(Geo.Reroute, fz, id, CP.StepDone)
  if not ok then
    Print(L["Roadbook update error: "] .. tostring(route))
    return
  end
  Geo.Freeze(route, info, excluded, "auto")
  Print(L["Quest skipped: "] .. (title or tostring(id)) .. L[". The route is adapted; it comes back with a new Roadbook."])
  if Geo.ActiveKind() == "auto" and (wasFocus or CP.CurrentFocus()) then
    CP.ClearFocus()
    CP.FocusNext(false)
  else
    CP.RefreshButton()
    if Refresh then Refresh() end
  end
end

function CP.ObjectiveClick()
  local ok, err = xpcall(function() CP.ObjectiveClickUnsafe() end, function(e)
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

-- Hearthstone step: arrived at the bind point by any mean (hearthstone, Astral Recall, teleport,
-- on foot).
function CP.CheckHearthArrival(s)
  if not CP.TransportReached(s, PlayerPos()) then return end
  if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
  CP.AutoUpdate(L["Arrived at the hearthstone destination"])
end

-- Transport step whose destination is reached at `pos`: bind point of a hearthstone step, arrival
-- of a flight / zeppelin / boat.
function CP.TransportReached(s, pos)
  local dest = s.kind == "hearth" and s.p or (s.kind == "travel" and s.task.destP)
  local d = pos and dest and Dist(pos, dest)
  return d ~= nil and d < (s.task.mode == "vol" and K.LANDING_RADIUS or K.ARRIVAL_RADIUS)
end

-- Watches the position every 2 s while a zeppelin / boat / hearthstone step has the focus.
function CP.WatchTransport(s)
  if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
  local watched = s.kind == "hearth" or (s.kind == "travel" and s.task.mode ~= "vol")
  if not (watched and C_Timer.NewTicker) then return end
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

-- Destination chosen at the flight master (final node of the flight).
if hooksecurefunc and TakeTaxiNode then
  hooksecurefunc("TakeTaxiNode", function(i)
    local ok, name = pcall(TaxiNodeName, i)
    CP.taxiChosen = ok and name or nil
  end)
end

-- Take-off while a travel step has the focus: the focus moves to the next step, unless the
-- chosen destination is not the planned one (the flight step then keeps the focus).
function CP.TakeOff(s)
  local chosen = CP.taxiChosen
  CP.taxiChosen = nil
  CP.flightStep = s
  if s.task.mode == "vol" and chosen and s.task.dest and chosen ~= s.task.dest and not CP.NearDest(chosen, s.task.destP) then
    Print(string.format(L["Wrong destination: %s instead of %s. The route will be computed again on landing."], chosen, s.task.dest))
    return
  end
  CP.AdvanceFocus()
end

-- Landing after a flight step: if it is not the planned destination, the transport steps
-- towards the next real step are replaced by the shortest route from where you landed.
K.LANDING_RADIUS = 500
function CP.CheckLanding(st)
  local t = st.task
  local pos = PlayerPos()
  if not (t and t.mode == "vol" and t.dest and pos) then return end
  local node, nd
  for _, n in pairs(KnownFlights()) do
    local d = Dist(n, pos)
    if d and (not nd or d < nd) then node, nd = n, d end
  end
  if node and nd < K.LANDING_RADIUS then
    if node.name == t.dest or CP.NearDest(node.name, t.destP) then return end
  else
    local d = t.destP and Dist(pos, t.destP)
    if not t.destP or (d and d < K.LANDING_RADIUS) then return end
  end
  CP.Reroute(st, pos)
end

-- Replaces the transport steps from the step `st` to the next real step by the shortest
-- route from `pos`, then focuses the first step of that route (returns true; false if `st` is not
-- in the active Roadbook).
function CP.Reroute(st, pos, msg)
  local kind = Geo.ActiveKind()
  local fz = Geo.Frozen(kind)
  if not fz then return false end
  local route = fz.route
  local fi
  for i = 2, #route do if route[i] == st then fi = i break end end
  if not fi then return false end
  local ti = fi
  while route[ti] and route[ti].kind == "travel" do ti = ti + 1 end
  local target = route[ti]
  for _ = fi, ti - 1 do table.remove(route, fi) end
  local legs = {}
  if target and target.kind ~= "hearth" and not target.glue then
    local net = BuildNetwork(TravelSpeed()) -- flight paths known now (some may have been activated on the way)
    local _, choice = Route(pos, target.p, net, UnitLevel("player"))
    if choice then
      for _, b in ipairs(Geo.Boardings(choice, net)) do
        local what = (b.mode == "vol" and L["Take the flight"]) or (L["Take the "] .. (K.MODE_NAME[b.mode] or b.mode))
        legs[#legs + 1] = { kind = "travel", p = Geo.MapPoint(b.hub.p), work = 0, at = st.at,
          task = { title = what .. L[": "] .. (b.hub.name or "?") .. " -> " .. (b.dest and b.dest.name or "?"),
            mode = b.mode, from = b.hub.name, dest = b.dest and b.dest.name, destP = b.dest and b.dest.p,
            xp = 0, travel = true } }
      end
    end
  end
  for k, leg in ipairs(legs) do table.insert(route, fi + k - 1, leg) end
  local rec = Geo.FrozenRec(kind)
  if rec then
    rec.steps = {}
    for i = 2, #route do rec.steps[#rec.steps + 1] = Geo.SerializeStep(route[i]) end
  end
  local first = legs[1]
  msg = msg or L["Wrong destination: new route. "]
  if first then
    Print(msg .. L["Focus: "] .. CP.StepText(first))
    CP.FocusStep(first)
  elseif target then
    Print(msg .. L["Focus: "] .. CP.StepText(target))
    CP.FocusStep(target)
  else
    CP.FocusNext(false)
  end
  if Refresh then C_Timer.After(0.2, Refresh) end
  return true
end

-- Quest picked up while its giver had several places to check (search steps): the place nearest to
-- you is where it was found (done), the other ones leave the Roadbook, and the followed Roadbook is
-- adapted (CP.Replan). Returns true if the followed Roadbook was changed.
function CP.GiverFound(a1, a2)
  local pos = PlayerPos()
  local handled = false
  for kind, fz in pairs(Geo.frozen) do
    local route, rec = fz.route, Geo.FrozenRec(kind)
    local list = {}
    for i = 2, #route do
      local st = route[i]
      local id = st.search and not st.done and st.task and st.task.id
      if id and (id == a1 or id == a2) then list[#list + 1] = i end
    end
    if #list > 0 then
      local best, bd = list[1], nil
      for _, i in ipairs(list) do
        local d = pos and Dist(pos, route[i].p)
        if d and (not bd or d < bd) then best, bd = i, d end
      end
      local title = route[best].task.title
      Geo.MarkDone(route[best])
      for k = #list, 1, -1 do
        local i = list[k]
        if i ~= best then
          table.remove(route, i)
          if rec and rec.steps then table.remove(rec.steps, i - 1) end
        end
      end
      if kind == Geo.ActiveKind() and Geo.Tracking() then
        handled = true
        local msg = L["Quest giver found: "] .. (title or "?") .. ". "
        scan.dirty = true -- the quest left the available ones: scanned again before the computation
        if not CP.Replan(kind, msg) then
          Print(msg)
          CP.ClearFocus()
          CP.FocusNext(false)
        end
      end
    end
  end
  if handled then
    Geo.MapSync()
    if Refresh then C_Timer.After(0.2, Refresh) end
  end
  return handled
end

function CP.OnGameEvent(event, a1, a2)
  if event == "QUEST_LOG_UPDATE" and CP.checkpointButton then C_Timer.After(0.2, function() pcall(CP.RefreshButton) end) end
  if (event == "QUEST_LOG_UPDATE" or event == "ZONE_CHANGED_NEW_AREA") and not CP.quickPending and Geo.Tracking() and Geo.frozen[Geo.ActiveKind()] then
    CP.quickPending = true
    C_Timer.After(2.5, function() -- after the quest log capture (2 s)
      CP.quickPending = nil
      local ok, n = pcall(Geo.InjectQuickWins, Geo.ActiveKind())
      if ok and n and n > 0 and Refresh then Refresh() end
    end)
  end
  -- Landing after a flight taken during a focus.
  if event == "FQP_TAXI_LANDED" and CP.flying then
    CP.flying = nil -- the focus already moved to the next step at take-off
    local st = CP.flightStep
    CP.flightStep, CP.taxiChosen = nil, nil
    if st then CP.CheckLanding(st) end
    return
  end
  if event == "QUEST_ACCEPTED" and CP.GiverFound(a1, a2) then return end
  local s = CP.CurrentFocus()
  if not s then return end
  if event == "FQP_TAXI_TAKEOFF" then CP.flying, CP.flightStep = true, nil end
  local qid = s.task.id
  if s.escort and event == "QUEST_LOG_UPDATE" and CP.IsFailed(qid) then
    CP.EscortFailed(s)
    return
  end
  if s.kind == "bind" then
    if event == "HEARTHSTONE_BOUND" then CP.AutoUpdate(L["Hearthstone bound"]) end
  elseif s.kind == "hearth" then
    if event == "FQP_HEARTH_ARRIVED" and tostring(a1 or "hearth") == tostring(s.via or "hearth") then
      CP.AutoUpdate(a1 and a1 ~= "hearth" and L["Teleport done"] or L["Back by hearthstone"])
    elseif event == "FQP_HEARTH_ARRIVED" then
      CP.CheckHearthArrival(s)
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "FQP_TRANSPORT_TICK" then
      CP.CheckHearthArrival(s)
    end
  elseif s.kind == "travel" then
    if event == "FQP_TAXI_TAKEOFF" then
      CP.TakeOff(s)
    elseif s.task.mode ~= "vol" and (event == "ZONE_CHANGED_NEW_AREA" or event == "FQP_TRANSPORT_TICK") then
      CP.CheckArrival(s)
    end
  elseif s.kind == "fm" then
    if event == "TAXIMAP_OPENED" then CP.AutoUpdate(L["Flight master activated"]) end
  elseif s.kind == "dungeon" then
    if (event == "QUEST_LOG_UPDATE" or event == "QUEST_TURNED_IN" or event == "QUEST_ACCEPTED") and CP.StepDone(s) then
      CP.AutoUpdate(L["Dungeon done"])
    end
  elseif (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and s.kind ~= "take" then
    if qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(event == "QUEST_TURNED_IN" and L["Quest turned in"] or L["Quest removed"]) end
  elseif s.kind == "take" then
    if event == "QUEST_ACCEPTED" and qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(L["Quest picked up"]) end
  elseif s.kind == "obj" then
    if event == "BAG_UPDATE_DELAYED" then
      if s.r and s.r.tg and s.r.tg.sourceItem and CP.StepDone(s) then CP.AutoUpdate(L["Item obtained"]) end
    elseif event == "QUEST_LOG_UPDATE" and qid then
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
    local icon, _, action = Geo.RecallText(s)
    return icon .. " " .. (task.title or "?"), action
  elseif s.kind == "travel" then
    return "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t " .. (task.mode == "vol" and L["Flight"] or K.MODE_NAME[task.mode] or task.mode or L["Transport"]) ..
      L[" to "] .. (task.dest or "?"), L["Departure: "] .. (task.from or "?") .. " · " .. place
  elseif s.kind == "dungeon" then
    local left = 0
    for _, m in ipairs(task.members or {}) do if not CP.StepDone(m) then left = left + 1 end end
    return K.DUNGEON_ICON .. " " .. (task.title or "?"),
      string.format(L["%d quest step(s) inside"], left) .. " · " .. place .. " · ~" .. FormatTime(s.work or 0)
  elseif s.kind == "fm" then
    return "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t " .. (task.title or L["Flight Master"]),
      L["Talk to "] .. (task.npc or "?") .. " · " .. place
  elseif s.escort and CP.IsFailed(task.id) then
    return K.ESCORT_ICON .. " " .. (task.title or "?"),
      Color(K.DESC.bad, L["Escort failed: abandon the quest and pick it up again"])
  elseif s.escort then
    local dest = s.kind == "turnin" and (L[", then turn in to "] .. (nameOnly(TurnInText(task.id)) or "?")) or ""
    local xp = s.kind == "turnin" and Geo.XPText(task.xp) or nil
    return K.ESCORT_ICON .. " " .. L["Escort: "] .. (task.title or "?"),
      L["Stay close to "] .. CP.EscortNpc(task) .. dest .. " · " .. place .. (xp and (" · " .. xp) or "")
  elseif s.kind == "take" then
    local esc = Geo.IsEscort(task.id) and (" · " .. Color(K.DESC.warn, L["escort"])) or ""
    if CP.IsFailed(task.id) then esc = " · " .. Color(K.DESC.bad, L["failed: abandon it first"]) end
    if task.reqLevel then esc = esc .. " · " .. Color(K.DESC.warn, string.format(L["level %d required"], task.reqLevel)) end
    if s.search then
      esc = " · " .. Color(K.DESC.warn, string.format(L["possible place %d/%d"], s.search.i, s.search.n)) .. esc
    end
    return ICON.available .. " " .. (task.title or "?"),
      (s.search and L["Look for "] or L["Pick up from "]) .. (nameOnly(task.starter) or "?") .. " · " .. place .. esc
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
  local xp = Geo.XPText(task.xp)
  return ICON.turnin .. " " .. (task.title or "?"),
    L["Turn in to "] .. (nameOnly(TurnInText(task.id)) or "?") .. " · " .. place .. (xp and (" · " .. xp) or "")
end

function CP.RefreshButton()
  Geo.MapSync() -- the Roadbook on the map follows its progress
  local b = CP.checkpointButton
  if not (b and b.title) then return end
  local s = CP.CurrentFocus()
  if s then
    local t, d = CP.StepSummary(s)
    local maxW = K.OBJECTIVE_MAX_WIDTH - K.OBJECTIVE_TEXT_X - 10
    -- White title, as in the tabs; quest step: then the same badges (colored level, elite, types);
    -- too wide: the badges go to the next line.
    if not (s.task and s.task.id) then
      t = Color("ffffff", t)
    else
      local badges = Geo.QuestBadges({ id = s.task.id, level = s.task.level })
      local full = Color("ffffff", t) .. badges
      if CP.TextWidth(b.title, full) > maxW then full = Color("ffffff", t) .. "\n" .. badges:gsub("^%s+", "") end
      t = full
    end
    b.title:SetText(t)
    b.sub:SetText(CP.PackInfos(b.sub, d, maxW))
    b.current = s
  else
    b.title:SetText(L["Objective"])
    b.sub:SetText(L["No objective tracked · click to start"])
    b.current = nil
  end
  -- Width fitted to the widest line, at most K.OBJECTIVE_MAX_WIDTH; the height follows the number of
  -- lines (at least 56 px, text vertically centered).
  local function Natural(fs) return CP.TextWidth(fs, fs:GetText() or "") end
  local w = math.max(Natural(b.title), Natural(b.sub))
  local width = math.min(math.max(K.OBJECTIVE_TEXT_X + w + 14, 230), K.OBJECTIVE_MAX_WIDTH)
  local textW = width - K.OBJECTIVE_TEXT_X - 10
  b.title:SetWidth(textW)
  b.sub:SetWidth(textW)
  local textH = (b.title:GetStringHeight() or 12) + 3 + (b.sub:GetStringHeight() or 10)
  local height = math.max(56, textH + 16)
  b:SetSize(width, height)
  b.title:ClearAllPoints()
  b.title:SetPoint("TOPLEFT", b, "TOPLEFT", K.OBJECTIVE_TEXT_X, -math.floor((height - textH) / 2))
  b.compassTarget = CP.CompassTarget()
end

K.OBJECTIVE_TEXT_X = 59       -- text of the Objective button, right of the compass square
K.OBJECTIVE_MAX_WIDTH = 380   -- widest Objective button (beyond, one information per line)

-- Width of a text in a font string, on one line.
function CP.TextWidth(fs, text)
  fs:SetWidth(2000)
  fs:SetText(text)
  return fs:GetStringWidth() or 0
end

-- Upper case first letter (ASCII or accented French letter, after any color code).
K.UPPER_ACCENTS = { ["é"] = "É", ["è"] = "È", ["ê"] = "Ê", ["à"] = "À", ["â"] = "Â", ["î"] = "Î", ["ô"] = "Ô",
  ["û"] = "Û", ["ç"] = "Ç" }
function CP.Capitalize(line)
  local prefix, rest = "", line
  while rest:find("^|c%x%x%x%x%x%x%x%x") do -- Lua patterns cannot repeat a group
    prefix, rest = prefix .. rest:sub(1, 10), rest:sub(11)
  end
  local first, tail = rest:match("^([%z\1-\127\194-\244][\128-\191]*)(.*)$")
  if not first then return line end
  return prefix .. (K.UPPER_ACCENTS[first] or first:upper()) .. tail
end

-- "info · info · info" wider than maxW: one information per line (never cut inside one), each
-- line starting with an upper case letter.
function CP.PackInfos(fs, text, maxW)
  if not text or CP.TextWidth(fs, text) <= maxW then return text end
  local lines = {}
  for info in (text .. " · "):gmatch("(.-) · ") do lines[#lines + 1] = CP.Capitalize(info) end
  return table.concat(lines, "\n")
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
  b:SetSize(230, 56)
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
  -- Framed icon (compass square), vertically centered whatever the height of the button.
  local frameTex = b:CreateTexture(nil, "ARTWORK")
  frameTex:SetSize(44, 44)
  local function PlaceIcon(dx, dy)
    frameTex:ClearAllPoints()
    frameTex:SetPoint("LEFT", b, "LEFT", 7 + dx, dy)
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
  arrow:SetSize(36, 36)
  arrow:SetPoint("CENTER", frameTex, "CENTER", 0, 4)
  arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
  arrow:SetVertexColor(1, 0.82, 0)
  arrow:Hide()
  local dist = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dist:SetPoint("BOTTOM", frameTex, "BOTTOM", 0, 1)
  dist:SetScale(0.85)
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
  title:SetPoint("TOPLEFT", b, "TOPLEFT", K.OBJECTIVE_TEXT_X, -8)
  title:SetJustifyH("LEFT")
  title:SetText(L["Objective"])
  local sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  sub:SetJustifyH("LEFT")
  sub:SetTextColor(0.75, 0.75, 0.75)
  sub:SetText(L["No objective tracked · click to start"])
  title:SetWordWrap(true)
  sub:SetWordWrap(true)
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
    self.dragEnd = GetTime and GetTime() or 0 -- the release of a Shift-drag must not count as a click
    local point, _, _, x, y = self:GetPoint()
    Settings().checkpointPos = { point, x, y }
  end)
  b:RegisterForClicks("LeftButtonUp")
  b:SetScript("OnClick", function()
    if b.dragEnd and GetTime and GetTime() - b.dragEnd < 0.3 then return end -- release of a Shift-drag
    CP.ObjectiveClick()
  end)
  b:SetScript("OnEnter", function(self) if self.HoverIn then self.HoverIn() end end)
  b:SetScript("OnLeave", function(self) if self.HoverOut then self.HoverOut() end end)
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

-- Shared with the next files.
ns.CP = CP
