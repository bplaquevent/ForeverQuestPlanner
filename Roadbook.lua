-- Forever Quest Planner: Roadbook checkpoints, saved Roadbook, Objective button.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local ActivePin, AllInstance, BuildNetwork, CharKey, ClearPin, Color = ns.ActivePin, ns.AllInstance, ns.BuildNetwork, ns.CharKey, ns.ClearPin, ns.Color
local DBXP, Dist, FormatTime, Geo, GeoReady, GetObjectives = ns.DBXP, ns.Dist, ns.FormatTime, ns.Geo, ns.GeoReady, ns.GetObjectives
local ICON, IsCompleted, IsInLog, K, L, Nearest = ns.ICON, ns.IsCompleted, ns.IsInLog, ns.K, ns.L, ns.Nearest
local PinPoint, PlayerPos, PointText, Print, QDB, QGet = ns.PinPoint, ns.PlayerPos, ns.PointText, ns.Print, ns.QDB, ns.QGet
local QuestTargets, Refresh, Route, Settings, Snapshot, StartScan = ns.QuestTargets, ns.Refresh, ns.Route, ns.Settings, ns.Snapshot, ns.StartScan
local KnownFlights, State, TaxiCount, TravelSpeed, TurnInText, WatchOnly = ns.KnownFlights, ns.State, ns.TaxiCount, ns.TravelSpeed, ns.TurnInText, ns.WatchOnly
local IsWatched, SetWatched = ns.IsWatched, ns.SetWatched
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
  if s.kind == "skill" then return L["raise the skill"] end
  if s.kind == "hearth" then return s.task.spell and L["teleport"] or L["hearthstone"] end
  if s.kind == "travel" then return L["transport"] end
  if s.kind == "take" then return L["pick up the quest"] end
  if s.kind == "obj" then return s.r and s.r.tg.name or L["objective"] end
  return L["turn in the quest"]
end

function CP.StepText(s)
  if s.kind == "fm" or s.kind == "bind" or s.kind == "service" then return (s.task.title or "?") .. " (" .. (s.task.npc or "?") .. ")" end
  if s.kind == "hearth" or s.kind == "travel" or s.kind == "dungeon" then return s.task.title or "?" end
  if s.kind == "skill" then
    return string.format(L["Raise the %s skill to level %d"], s.skill.name, s.skill.need) .. " - " .. (s.task.title or "?")
  end
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
  if moved then Geo.Trace("focus", Geo.StepTrace(s)) end
  CP.focused = s
  CP.focusRec = { questId = s.task.id, label = CP.StepPinLabel(s), area = s.p.area, mx = s.p.mx, my = s.p.my,
    progress = CP.Progress(s.task.id) }
  local qid = s.task.id
  if qid and IsInLog(qid) then WatchOnly(qid) end
  local fz = moved and s.kind == "turnin" and Geo.Frozen()
  if fz and not CP.StepReady(s, fz.route) then
    local need = s.task.id and Geo.SkillNeed(s.task.id, CP.LogEntry(s.task.id))
    Print(Color(K.DESC.warn, need and (Geo.SkillNeedText(need) .. L[": "]) or L["Objectives not completed yet: "])
      .. (s.task.title or "?"))
  end
  Geo.MapClaim("track") -- the followed Roadbook holds the map (RoadbookMap.lua)
  if not s.nopin then PinPoint(s.p, s.task.title, CP.StepPinLabel(s), qid) end
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
  return { kind = st.kind, at = st.at, xp = st.xp, work = st.work, gain = st.gain, spots = st.spots,
    escort = st.escort, glue = st.glue, via = st.via, bindDest = st.bindDest, search = st.search,
    fmHub = st.fmHub and { id = st.fmHub.id, node = st.fmHub.node, name = st.fmHub.name, p = Geo.CopyPoint(st.fmHub.p) } or nil,
    members = Geo.SerializeMembers(t.members),
    spotN = st.spot and st.spot.n, done = st.done, p = Geo.CopyPoint(st.p),
    objName = st.r and st.r.tg and st.r.tg.name, objKind = st.r and st.r.tg and st.r.tg.kind, count = st.r and st.r.count,
    objSource = st.r and st.r.tg and st.r.tg.sourceItem, afterSource = st.afterSource,
    skill = st.skill, npc = st.npc, nopin = st.nopin,
    first = t.stops and t.stops[1] == st or nil,
    task = { id = t.id, title = t.title, level = t.level, xp = t.xp, starter = t.starter, reqLevel = t.reqLevel,
      depTitle = t.dep and t.dep.title, tags = t.tags, npc = t.npc, mode = t.mode, from = t.from, dest = t.dest,
      destP = Geo.CopyPoint(t.destP), kind = t.kind, quick = t.quick, dungeon = t.dungeon, warn = t.warn,
      levelWarn = t.levelWarn, orderWarn = t.orderWarn, spell = t.spell, service = t.service, npcId = t.npcId } }
end

function Geo.DeserializeStep(rec, tasks)
  local tr = rec.task or {}
  local key = tostring(tr.id) .. "|" .. tostring(tr.title) .. "|" .. tostring((rec.kind == "travel" or rec.kind == "dungeon") and rec.at or "")
  local task = tasks[key]
  if not task then
    task = { id = tr.id, title = tr.title, level = tr.level, xp = tr.xp, starter = tr.starter, reqLevel = tr.reqLevel,
      dep = tr.depTitle and { title = tr.depTitle } or nil, tags = tr.tags, npc = tr.npc, mode = tr.mode,
      from = tr.from, dest = tr.dest, destP = tr.destP, kind = tr.kind, quick = tr.quick, stops = {},
      dungeon = tr.dungeon, warn = tr.warn, levelWarn = tr.levelWarn, orderWarn = tr.orderWarn, spell = tr.spell, service = tr.service, npcId = tr.npcId,
      members = Geo.DeserializeMembers(rec.members) }
    tasks[key] = task
  end
  local st = { kind = rec.kind, at = rec.at, xp = rec.xp, work = rec.work or 0, gain = rec.gain, spots = rec.spots,
    escort = rec.escort, glue = rec.glue, fmHub = rec.fmHub, via = rec.via, bindDest = rec.bindDest, search = rec.search,
    spot = rec.spotN and { n = rec.spotN } or nil, done = rec.done, p = rec.p or {}, task = task, afterSource = rec.afterSource,
    skill = rec.skill, npc = rec.npc, nopin = rec.nopin,
    r = rec.objName and { tg = { name = rec.objName, kind = rec.objKind, sourceItem = rec.objSource }, count = rec.count } or nil }
  if rec.first then task.stops[1] = st end
  return st
end

function Geo.FrozenStore()
  local st = Settings()
  st.roadbook = st.roadbook or {}
  return st.roadbook
end

-- One Roadbook per character, with its progress: the fastest route doing every quest of the list
-- (info.custom). "Adapt" completes or trims the list, the changes of the list adapt it.
Geo.frozen = nil -- { route, info } (loaded plan)

function Geo.FrozenRec()
  return Geo.FrozenStore()[CharKey()]
end

-- The saved Roadbook was computed for the custom quest list.
function Geo.IsCustom()
  local rec = Geo.FrozenRec()
  return (rec and rec.info and rec.info.custom) and true or false
end

-- Saves the plan.
function Geo.Freeze(route, info)
  local steps = {}
  for i = 2, #route do steps[#steps + 1] = Geo.SerializeStep(route[i]) end
  local slim = { count = info.count, xp = info.xp, total = info.total, mobXP = info.mobXP, levels = info.levels,
    speed = info.speed, plevel = info.plevel, skipped = info.skipped, later = info.later, taxi = info.net and info.net.taxi,
    custom = info.custom, unplanned = info.unplanned, dungeons = info.dungeons, discovered = info.discovered }
  Geo.FrozenStore()[CharKey()] = { saved = date and date("%H:%M") or "",
    start = Geo.CopyPoint(route[1].p), steps = steps, info = slim, recall = Geo.RecallState() }
  Geo.frozen = { route = route, info = info }
  Geo.Trace("freeze", string.format("plan saved: %d step(s), %d done%s", #steps,
    (function() local n = 0 for _, s in ipairs(steps) do if s.done then n = n + 1 end end return n end)(),
    info.custom and ", custom list" or ""))
  Geo.MapSync() -- a new or adapted plan: redrawn on the map if it is there
end

-- Saved plan (reloaded after a /reload), or nil.
function Geo.Frozen()
  if Geo.frozen then return Geo.frozen end
  local rec = Geo.FrozenRec()
  if not (rec and rec.steps and #rec.steps > 0) then return nil end
  -- After a /reload, the QuestieDB map mappings are not loaded yet.
  if not GeoReady() then return nil end
  local route, tasks = { { kind = "start", p = rec.start or {}, work = 0 } }, {}
  for _, r in ipairs(rec.steps) do route[#route + 1] = Geo.DeserializeStep(r, tasks) end
  local info = {}
  for k, v in pairs(rec.info or {}) do info[k] = v end
  info.net = BuildNetwork(info.speed or TravelSpeed())
  info.net.taxi = TaxiCount()
  Geo.frozen = { route = route, info = info }
  return Geo.frozen
end

-- Empties the Roadbook (its steps and its progress).
function Geo.ClearFrozen()
  if Geo.frozen or Geo.FrozenRec() then Geo.Trace("clear", "plan emptied") end
  Geo.frozen = nil
  Geo.FrozenStore()[CharKey()] = nil
  Geo.planCache, Geo.customCache = nil, nil
end

-- Steps to come removed, the steps done kept (history): the custom Roadbook whose list was emptied.
-- Returns false when no step is done (nothing to keep).
function Geo.KeepOnlyDone()
  local fz = Geo.Frozen()
  if not fz then return false end
  local start = { { kind = "start", p = fz.route[1].p, work = 0 } }
  local info = {}
  for k, v in pairs(fz.info) do info[k] = v end
  local route = Geo.KeepDone(fz, CP.StepDone, start, { total = 0, levels = {} }, info)
  if #route < 2 then return false end
  info.dungeons, info.discovered, info.skipped, info.unplanned = nil, nil, nil, nil
  Geo.Freeze(route, info)
  return true
end

-- Every step of the Roadbook is done: it can only be extended (custom: quests added), generated again or emptied.
function Geo.IsFinished()
  local fz = Geo.Frozen()
  if not fz or #fz.route < 2 then return false end
  for i = 2, #fz.route do
    if not CP.StepDone(fz.route[i]) then return false end
  end
  return true
end

-- The Roadbook exists (saved, or being computed).
function Geo.HasRoadbook()
  if Geo.computing then return true end
  local rec = Geo.FrozenRec()
  return (rec and rec.steps and #rec.steps > 0) or false
end

-- Marks a step as done (and saves it).
function Geo.MarkDone(st, value)
  if value == nil then value = true end
  Geo.Trace("mark", (value and "done: " or "not done: ") .. Geo.StepTrace(st))
  st.done = value or nil
  local fz, rec = Geo.frozen, Geo.FrozenRec()
  if fz and rec and rec.steps then
    for i = 2, #fz.route do
      if fz.route[i] == st and rec.steps[i - 1] then rec.steps[i - 1].done = value or nil end
    end
  end
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
    if src then return Geo.ItemCount(src) > 0 end
    local o = Geo.TargetObjective(id, st.r and st.r.tg, GetObjectives(id))
    return o and o.finished and true or false
  end
  if st.kind == "skill" then
    return not (id and Geo.SkillNeed(id, CP.LogEntry(id)))
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

-- Option chosen in the Roadbook tab, for the next "Adapt": { kind = "time" | "level", value } (the
-- list completed or trimmed for it).
function Geo.SelectedGoal()
  return State.xpGoal
end

-- Computes the Roadbook for `goal` (see Geo.SelectedGoal) and saves it; cb(route, err, info) when done.
-- keepDone: the steps done of the saved Roadbook stay first (history), only the steps to come are
-- computed again; otherwise the Roadbook is emptied first.
-- re (Roadbook adapted, CP.Replan): { opts = Geo.RequestPlan options }.
-- A duration or level goal ("Adapt"): the list becomes the quests of the new Roadbook (Geo.AcceptGenerated),
-- the steps done kept in front when keepDone.
function Geo.Recompute(goal, cb, keepDone, re)
  if not keepDone then Geo.ClearFrozen() end
  Snapshot()
  Geo.RequestPlan(goal, function(route, err, info)
    if not Geo.computing then return end -- deleted meanwhile
    Geo.computing = nil
    pcall(CP.RefreshButton) -- the Objective button can be clicked again
    if Geo.QuestLogButtonSync then pcall(Geo.QuestLogButtonSync) end -- the list can change again
    if route and #route >= 2 and goal ~= "custom" then
      Geo.AcceptGenerated(route, info, function(ok)
        if cb then cb(ok and route or nil, not ok and L["Adaptation cancelled: the Roadbook and its list are unchanged."] or err, info) end
        if Refresh then C_Timer.After(0.1, Refresh) end
      end, keepDone and function(newRoute)
        local old = Geo.Frozen()
        if not old then return newRoute end
        return Geo.KeepDone(old, CP.StepDone, newRoute, info, info)
      end or nil)
      return
    end
    if route and #route >= 2 then
      local old = keepDone and Geo.Frozen()
      if old then
        route = Geo.KeepDone(old, CP.StepDone, route, info, info)
        info.later = old.info.later
      end
      Geo.Freeze(route, info)
    end
    if cb then cb(route, err, info) end
    if Refresh then C_Timer.After(0.1, Refresh) end
  end, true, re and re.opts)
end

-- Focuses the first step of the active Roadbook that is not done yet.
-- At the end of the plan, the tracking stops (Roadbook kept, every step done): "Adapt" or new quests extend it.
function CP.FocusNext(silent, after)
  local fz = Geo.Frozen()
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
    Print(L["Roadbook finished: every quest of the list is done."])
    CP.TrackOff(true)
    return
  end
  CP.ShowActive()
end

-- No Roadbook: the window opens on its tab, where it is generated.
function CP.ShowActive()
  local tab = "xp"
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

-- A finished Roadbook cannot be tracked again: what can be done with it.
function CP.FinishedMessage()
  Print(L["Roadbook finished: add quests to the list to extend it, click \"Adapt\" to complete it, or delete it."])
end

-- Turns the tracking on ("Tracking" box of the steps panel, Objective button): the Objective button
-- follows the Roadbook, which is computed again from here.
function CP.TrackOn()
  if Geo.computing then
    Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
    return
  end
  local pending = Geo.CustomRec().pending
  if not Geo.Frozen() and not (pending and #Geo.CustomList() > 0) then
    Print(L["This Roadbook has no step: add quests to its list or click \"Adapt\"."])
    return
  end
  if Geo.IsFinished() and not pending then
    CP.FinishedMessage()
    return
  end
  CP.DoTrackOn()
end

-- Tracking turned on: the steps to come are always computed again from here (the Roadbook is not
-- updated while it is not tracked); the focus is placed when the computation ends.
function CP.DoTrackOn()
  if not Geo.Tracking() then Print(L["Tracking on."]) end
  CP.turningOn = true -- a computation started here ends with the focus
  local ok, res
  if Geo.Frozen() then
    ok, res = pcall(CP.Replan, L["Tracking on: the steps to come are computed again. "])
  else
    CP.focusAfter = true
    ok, res = pcall(CP.Recompute, "custom", true)
    res = ok and Geo.computing and true or false
  end
  CP.turningOn = nil
  if not ok then Print(L["Roadbook update error: "] .. tostring(res)) end
  if not (ok and res) then CP.FocusNext(false) end
  CP.RefreshButton()
  if Refresh then Refresh() end
end

-- Hearthstone and class teleports ---------------------------------------------
-- The saved Roadbook keeps the state of the ways back (cooldowns, runes, bind location) it was
-- computed with. When it changes (or, at start, when you are elsewhere), the steps to come are
-- adapted to the position and the cooldowns now; the steps done stay (history).

-- The planned use of a way back (or the planned bind) is not a change: the saved state follows it.
function Geo.RestampRecalls()
  local rec = Geo.FrozenRec()
  if rec then rec.recall = Geo.RecallState() end
end

-- Returns true if an update was started.
function CP.RecallCheck()
  local fz, rec = Geo.Frozen(), Geo.FrozenRec()
  if not (fz and rec) or Geo.computing then return false end
  local now = Geo.RecallState()
  if not rec.recall then -- Roadbook from a former version: its state starts now
    rec.recall = now
    return false
  end
  local route, first = fz.route, nil
  for i = 2, #route do if not CP.StepDone(route[i]) then first = i break end end
  if not first then return false end
  local changed, why = Geo.RecallChanged(rec.recall, now)
  if not changed then return false end
  Geo.Trace("recall", why or "position changed")
  return CP.Replan(L["Position or hearthstone / teleport cooldowns changed: the steps to come are updated. "])
end

-- Roadbook adapted (position or cooldowns changed, quest or transport skipped, quest giver found):
-- the steps to come are planned again from here, the steps done stay (history): every quest left of
-- the list in the least time.
-- opts: { ban = transport not usable on the first leg }. Returns true if a computation started.
function CP.Replan(msg, opts)
  if not (Geo.Tracking() or CP.turningOn) then return false end -- never computed again while not tracked
  if not GeoReady() then return false end
  if Geo.computing then
    Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
    return false
  end
  if not Geo.ServicePending() and (not Geo.HasRoadbook() or #Geo.CustomList() == 0) then return false end
  Print(msg .. string.format(L["Computing the Roadbook (up to %d s)…"], K.PLAN_TIME))
  Geo.Trace("replan", msg)
  CP.focusAfter = (CP.turningOn or Geo.Tracking()) and true or nil -- the tracking goes on / starts after it
  CP.Recompute("custom", true, nil, nil, { opts = opts or {} })
  return true
end

-- While the Roadbook is tracked, steps done ahead are checked a few seconds after a quest event, and
-- cooldown, rune, spell or bind changes too (never during a flight, a fight or a computation).
function CP.ScheduleRecallCheck(delay)
  if not (GetTime and Geo.Frozen()) then return end
  local now = GetTime()
  local at = math.max(CP.recallAt or 0, now + (delay or 3))
  CP.recallAt = at
  CP.recallToken = (CP.recallToken or 0) + 1
  local token = CP.recallToken
  C_Timer.After(at - now, function()
    if token ~= CP.recallToken then return end
    CP.recallAt = nil
    if not Geo.Frozen() or not Geo.Tracking() then return end
    if CP.flying or Geo.computing or (UnitOnTaxi and UnitOnTaxi("player")) or (InCombatLockdown and InCombatLockdown())
      or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) or not PlayerPos() then
      CP.ScheduleRecallCheck(10)
      return
    end
    local okA, started = pcall(CP.AheadCheck)
    if not okA then Print(L["Roadbook update error: "] .. tostring(started)) end
    if okA and started then return end
    if not Geo.Tracking() then return end
    local ok, err = pcall(CP.RecallCheck, false)
    if not ok then Print(L["Roadbook update error: "] .. tostring(err)) end
  end)
end

-- Steps done ahead: a quest picked up, an objective done or a quest turned in before its place in
-- the Roadbook. Right after the steps done, the route stays right (several quests from the same
-- NPC…); further on, the steps to come are computed again without them (they join the history).
-- A step that comes back after the computation it started does not start another one (it is
-- forgotten when its quest leaves the log, CP.QuestRemoved). Returns true if a computation started.
K.AHEAD_KINDS = { take = true, obj = true, turnin = true }
CP.aheadSeen = {} -- key of a step done ahead (CP.AheadKey) -> quest id
function CP.AheadKey(st)
  return st.kind .. ":" .. st.task.id .. ":" .. tostring(st.r and st.r.tg and st.r.tg.name)
end
function CP.AheadCheck()
  local fz = Geo.Frozen()
  if not fz or Geo.computing or CP.autoPending then return false end
  local route, first, ahead = fz.route, nil, {}
  for i = 2, #route do
    local st = route[i]
    local done = CP.StepDone(st)
    if not first then
      if not done then first = i end
    elseif done and not st.done and K.AHEAD_KINDS[st.kind] and not st.search and st.task and st.task.id
      and not CP.aheadSeen[CP.AheadKey(st)] then
      ahead[#ahead + 1] = st
    end
  end
  if #ahead == 0 or not CP.Replan(L["Step done ahead: "] .. CP.StepText(ahead[1]) .. ". ") then return false end
  for _, st in ipairs(ahead) do CP.aheadSeen[CP.AheadKey(st)] = st.task.id end -- only once started
  return true
end

-- Steps on the spot first: the plan models a walk as a straight line, so it can leave a city and come
-- back later (or pass next to a step to do it much later). Steps of quest (never transports) that can be
-- done now are brought first when, from the player's position: in a city, they are in that city (before
-- any step outside it), anywhere else, they are within K.NEARBY_RADIUS. The Roadbook is then adapted
-- with them first (Geo.ApplyNearFirst). Only steps already in the Roadbook; nothing is added.
K.NEARBY_RADIUS = 150 -- yards: about one minute of detour at most
K.NEARBY_KINDS = { take = 1, skill = 2, obj = 2, turnin = 3, dungeon = 2 } -- quest steps, in order of a quest
K.CITY_MAPS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true } -- uiMapID of the capitals
CP.nearSeen = {} -- StepKey of the steps already brought first (forgotten once they are no longer on the spot)

-- The step can be done at the player's level: pick-up with the level required, objective or dungeon with
-- a quest not too high (Geo.MaxQuestLevel); turn-in and skill: always.
function CP.StepLevelOk(st, plevel)
  local t = st.task or {}
  if st.kind == "turnin" or st.kind == "skill" then return true end
  if st.kind == "take" then return (t.id and QGet(QDB.Quest, t.id, "requiredLevel") or 0) <= plevel end
  if st.kind == "dungeon" then
    for _, m in ipairs(t.members or {}) do
      if not CP.StepLevelOk(m, plevel) then return false end
    end
    return true
  end
  return not (t.id and t.level) or t.level <= Geo.MaxQuestLevel(t.id, plevel, nil, "")
end

function CP.NearbyCheck()
  local fz = Geo.Frozen()
  if not fz or not Geo.Tracking() or Geo.computing or CP.autoPending or Geo.ServicePending() then return end
  if CP.flying or (UnitOnTaxi and UnitOnTaxi("player")) or (InCombatLockdown and InCombatLockdown())
    or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then return end
  local pos = PlayerPos()
  if not pos then return end
  local plevel = UnitLevel("player")
  local zone = Geo.ZoneIdAt(pos)
  local city = zone and K.CITY_MAPS[zone] and zone or nil
  local route = fz.route
  -- Candidates: quest steps not done, on the spot and possible at this level.
  local C, todo = {}, {}
  for i = 2, #route do
    local st = route[i]
    if K.NEARBY_KINDS[st.kind] and st.task and st.p and st.p.c and not CP.StepDone(st) then
      todo[#todo + 1] = i
      local near
      if city then near = Geo.ZoneIdAt(st.p) == city
      else near = st.p.c == pos.c and (Dist(st.p, pos) or math.huge) < K.NEARBY_RADIUS end
      if near and CP.StepLevelOk(st, plevel) then C[st] = true end
    end
  end
  -- Possible now: the steps of its quest that come before it (pick-up, objectives) are in too; a glued
  -- chain whole.
  local changed = true
  while changed do
    changed = false
    for _, i in ipairs(todo) do
      local st = route[i]
      if C[st] then
        local ok = true
        local rank, id = K.NEARBY_KINDS[st.kind], st.task.id
        if id then
          for _, j in ipairs(todo) do
            local o = route[j]
            if o.task.id == id and K.NEARBY_KINDS[o.kind] < rank and not C[o] then ok = false break end
          end
        end
        if ok and st.glue and route[i - 1] and i > 2 and not C[route[i - 1]] then ok = false end
        if ok and route[i + 1] and route[i + 1].glue and not C[route[i + 1]] then ok = false end
        if not ok then
          C[st] = nil
          changed = true
        end
      end
    end
  end
  -- Violation: a step not wanted first (outside the city, if in one) comes before a wanted one.
  local keys, now, first, other = {}, {}, nil, nil
  for _, i in ipairs(todo) do
    local st = route[i]
    local k = Geo.StepKey(st)
    if C[st] then
      keys[k], now[k] = true, true
      if other and not first and not CP.nearSeen[k] then first = st end
    elseif not other and (not city or Geo.ZoneIdAt(st.p) ~= city) then
      other = st
    end
  end
  for k in pairs(CP.nearSeen) do
    if not now[k] then CP.nearSeen[k] = nil end -- no longer on the spot
  end
  if not first then return end
  local msg = (city and L["Steps in this city first: "] or L["Step nearby first: "]) .. CP.StepText(first) .. ". "
  if CP.Replan(msg, { near = { keys = keys, city = city } }) then
    for k in pairs(keys) do CP.nearSeen[k] = true end
  end
end

-- Quest gone from the log (QUEST_REMOVED, a moment later): turned in, the focused step moves on (if
-- QUEST_TURNED_IN did not already do it); abandoned while the Roadbook plans it: remove it from the
-- list, or keep it and pick it up again (the steps to come are computed again either way).
function CP.QuestRemoved(id)
  if IsInLog(id) then return end
  for key, qid in pairs(CP.aheadSeen) do -- picked up again later: its steps count again
    if qid == id then CP.aheadSeen[key] = nil end
  end
  local s = CP.CurrentFocus()
  if (CP.turnedIn and CP.turnedIn[id]) or IsCompleted(id) then
    if s and s.kind ~= "take" and s.task and s.task.id == id then CP.AutoUpdate(L["Quest turned in"]) end
    return
  end
  local fz = Geo.Frozen()
  if not fz then return end
  local title, planned
  for i = 2, #fz.route do
    local st = fz.route[i]
    if st.task and st.task.id == id then
      title = title or st.task.title
      if not CP.StepDone(st) then planned = true end
    end
  end
  if not planned and not Geo.InCustom(id) then return end
  if not title then
    for _, e in ipairs(Geo.CustomList()) do if e.id == id then title = e.title end end
  end
  title = title or tostring(id)
  local text = string.format(L["You abandoned \"%s\".\n\nRemove it from the list, or keep it and pick it up again? The steps to come of the Roadbook are computed again (the steps done stay)."], title)
  StaticPopup_Show("FQP_QUEST_ABANDONED", text, nil, { id = id, title = title })
end

-- Roadbook adapted as soon as no computation is running.
function CP.ReplanSoon(msg, tries)
  if Geo.computing then
    if (tries or 0) < 30 then C_Timer.After(2, function() CP.ReplanSoon(msg, (tries or 0) + 1) end) end
    return
  end
  CP.Replan(msg)
end

StaticPopupDialogs["FQP_QUEST_ABANDONED"] = {
  text = "%s",
  button1 = L["Remove from the list"],
  button2 = L["Pick it up again"],
  OnAccept = function(_, data)
    if data then CP.SkipQuest({ task = { id = data.id, title = data.title } }) end
  end,
  OnCancel = function(_, data) -- also Escape: the quest stays planned
    if data then CP.ReplanSoon(L["Quest abandoned, to pick up again: "] .. data.title .. ". ") end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Cast of the hearthstone or of a class teleport (key: "hearth" or the spell id).
function CP.RecallCast(key)
  local s = CP.CurrentFocus()
  if s and s.kind == "hearth" and tostring(s.via or "hearth") == tostring(key) then
    C_Timer.After(1.5, function() Geo.RestampRecalls() end) -- the planned one
  else
    CP.ScheduleRecallCheck(8) -- unplanned: the route is adapted after the arrival
  end
end

-- Turns the tracking off: only the Objective button, the pin and the map stop following it; the
-- Roadbook, its steps and their progress are kept (not updated until the tracking is on again).
function CP.TrackOff(quiet)
  CP.StopFocus()
  if not quiet then Print(L["Tracking off: the Roadbook is no longer updated. Turn the tracking on to compute it again and follow it."]) end
  if Refresh then C_Timer.After(0.1, Refresh) end
end

-- Empties the Roadbook after confirmation: tracking stopped, steps and list emptied.
function CP.Empty()
  StaticPopup_Show("FQP_EMPTY")
end

function CP.DoEmpty()
  if Geo.computing then -- computation in progress: cancelled
    Geo.co, Geo.runningKey, Geo.planCbs, Geo.computing = nil, nil, nil, nil
    CP.computeToken = (CP.computeToken or 0) + 1
  end
  CP.TrackOff(true)
  if Geo.MapOwner() then Geo.MapRelease() end -- its preview ends
  Geo.ClearFrozen()
  Geo.ServiceClear()
  Geo.CustomRec().list = {}
  Geo.customUnplanned = nil
  Geo.customToken = (Geo.customToken or 0) + 1 -- no pending recompute
  Print(L["Roadbook emptied."])
  if Geo.QuestLogButtonSync then pcall(Geo.QuestLogButtonSync) end
  CP.RefreshButton()
  if Refresh then Refresh() end
end

StaticPopupDialogs["FQP_EMPTY"] = {
  text = L["Empty the Roadbook?\n\nIts steps, their progress and the quest list are lost."],
  button1 = L["Empty"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function() CP.DoEmpty() end,
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

-- Option of "Adapt" (the list completed or trimmed for a session duration or a level to reach).
-- Each kind keeps its last value.
function CP.SetGoal(kind, value)
  local st = Settings()
  if kind == "time" then st.goalTime = value elseif kind == "level" then st.goalLevel = value end
  local g = State.xpGoal
  if g.kind == kind and g.value == value then return end
  State.xpGoal = { kind = kind, value = value }
  st.goal = { kind = kind, value = value }
  scan.dirty = true -- the levels scanned for the Roadbook follow the goal
  if Refresh then Refresh() end
end

-- "Adapt" button: the list is completed or trimmed for the chosen session or level and the Roadbook
-- computed again; its steps done and its tracking are kept.
function CP.Adapt()
  CP.focusAfter = Geo.Tracking() and true or nil
  CP.Recompute(Geo.SelectedGoal(), true)
end

-- Computes the Roadbook again for `goal` (Geo.SelectedGoal, or "custom": the list as it is).
-- keep: its steps done and its tracking stay (change of the list, "Adapt"); otherwise it is emptied first.
-- re: the Roadbook adapted (CP.Replan), see Geo.Recompute.
function CP.Recompute(goal, keep, attempt, token, re)
  if not attempt then
    if not GeoReady() then
      Print(L["Unable to convert QuestieDB positions to this client's map."])
      return
    end
    if goal == "custom" and #Geo.CustomList() == 0 and not Geo.ServicePending() then
      if not keep then Print(L["The list is empty: add quests with the \"Add\" button of the other tabs, or choose a session or a level."]) end
      return
    end
    if Geo.computing then -- one computation at a time
      if keep then
        local t = Geo.customToken
        C_Timer.After(1, function() if t == Geo.customToken then CP.Recompute(goal, keep, nil, nil, re) end end)
      else
        Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
      end
      return
    end
    CP.computeToken = (CP.computeToken or 0) + 1
    token = CP.computeToken
    Geo.computing, Geo.computingGoal, Geo.computeStart = true, goal, GetTime and GetTime() or 0
    if Geo.QuestLogButtonSync then pcall(Geo.QuestLogButtonSync) end -- the list is locked
    if not keep then Geo.ClearFrozen() end
    if Refresh then Refresh() end
    pcall(CP.RefreshButton) -- the Objective button waits
  end
  if token ~= CP.computeToken then return end -- deleted meanwhile
  -- Available quests change after a pick-up or turn-in: wait for their scan to finish.
  if goal ~= "custom" and (scan.running or scan.dirty or not scan.entries) then
    if not scan.running then StartScan() end
    attempt = (attempt or 0) + 1
    if attempt > 40 then
      Geo.computing = nil
      pcall(CP.RefreshButton)
      if Geo.QuestLogButtonSync then pcall(Geo.QuestLogButtonSync) end
      Print(L["Quest scan is taking too long: try again in a moment."])
      if Refresh then Refresh() end
      return
    end
    C_Timer.After(0.5, function() CP.Recompute(goal, keep, attempt, token, re) end)
    return
  end
  local was = CP.CurrentFocus()
  Geo.Recompute(goal, function(route, err)
    local refocus = CP.focusAfter -- tracking (re)started during the computation
    CP.focusAfter = nil
    if route and #route >= 2 then Geo.CustomRec().pending = nil end
    if not route or #route < 2 then
      Print(err or L["The Roadbook is empty: no step to follow."])
      CP.RefreshButton()
      return
    end
    if not keep then
      Print(L["Roadbook ready: turn on the tracking (Objective button or steps panel) to follow it."])
      CP.RefreshButton()
      return
    end
    if not was then
      if refocus then CP.FocusNext(false) else CP.RefreshButton() end
      return
    end
    -- Recomputed while followed: the focus goes to the first step of the new plan that can be done
    -- (steps inserted before the current one come first); a change of step is announced (compared
    -- with the step followed now: it may have moved on during the computation).
    was = CP.CurrentFocus() or was
    CP.ClearFocus()
    CP.FocusNext(true)
    local now = CP.focused
    if now and not CP.SameStep(now, was) then Print(L["Focus: "] .. CP.StepText(now)) end
  end, keep, re)
end

-- Click on the button. Roadbook being computed: nothing (until it is computed and tracked), unless it
-- is adapted while followed (the followed step stays shown, the click works on it). No
-- Roadbook: the window opens on its tab, where one is made. Roadbook not followed: it starts and
-- the steps panel (RoadbookPanel.lua) is shown. Followed: the steps panel is shown or hidden.
-- Left click: the map opens on the followed step (closed when already open); a Roadbook not followed is tracked (the steps
-- panel shown, the map left closed). Right click: the steps panel shown or hidden.
function CP.ObjectiveClickUnsafe(button)
  -- Roadbook being computed: nothing, unless it is adapted while followed (its step stays shown).
  if Geo.computing and not (Geo.Tracking() and CP.CurrentFocus()) then return end
  if not Geo.Frozen() then
    CP.ShowActive()
    return
  end
  if button == "RightButton" then
    Geo.MapPanelOpen(true)
    return
  end
  if not Geo.Tracking() then
    if Geo.IsFinished() then
      CP.FinishedMessage()
      CP.ShowActive()
      return
    end
    CP.DoTrackOn() -- tracking only: the map does not open
    Geo.MapPanelOpen(false)
    return
  end
  -- Map already open: the click closes it.
  if WorldMapFrame and WorldMapFrame:IsShown() then
    if ToggleWorldMap then pcall(ToggleWorldMap) else WorldMapFrame:Hide() end
    return
  end
  local s = CP.CurrentFocus()
  if s then Geo.ShowStep(s) else Geo.MapPanelOpen(false) end
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
    local fz, inside = Geo.frozen, false
    for i = 2, fz and #fz.route or 0 do if fz.route[i] == s then inside = true end end
    local ban = { mode = s.task.mode, from = s.p, to = s.task.destP }
    if inside and CP.Replan(L["Transport skipped: the Roadbook is adapted without it. "], { ban = ban }) then
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
function CP.ConfirmSkipQuest(s)
  local title = s.task.title or tostring(s.task.id)
  local text = string.format(L["Remove \"%s\" from the list?\n\nThe prerequisite quests added only for it leave too, and the steps to come of the Roadbook are computed again (the steps done stay)."], title)
  StaticPopup_Show("FQP_SKIP_QUEST", text, nil, { s = s })
end

StaticPopupDialogs["FQP_SKIP_QUEST"] = {
  text = "%s",
  button1 = YES or L["Yes"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, data) if data and data.s then CP.SkipQuest(data.s) end end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- Removes a quest (badly defined, not found, not wanted…): it leaves the list (with the prerequisites
-- added only for it) and the steps to come of the Roadbook are computed again; the steps done stay.
function CP.SkipQuest(s)
  local id = s and s.task and s.task.id
  if not id or Geo.ListLocked() then return end
  if Geo.CustomRemove(id) then return end
  -- Not in the list (a Roadbook from a former version): the Roadbook is computed again without it.
  CP.Replan(L["Quest removed: "] .. (s.task.title or tostring(id)) .. ". ")
end

function CP.ObjectiveClick(button)
  local ok, err = xpcall(function() CP.ObjectiveClickUnsafe(button) end, function(e)
    return tostring(e) .. (debugstack and ("\n" .. debugstack(2, 3, 0)) or "")
  end)
  if not ok then Print(L["|cffff6060Error while validating the checkpoint|r (copy it to report it):\n"] .. err) end
end

-- Progress of a quest from the log: finished objectives (+1 if the quest is complete).
-- Every objective of the quest done (or the quest complete).
function CP.QuestObjectivesDone(qid)
  if not (qid and IsInLog(qid)) then return false end
  if C_QuestLog.IsComplete and C_QuestLog.IsComplete(qid) then return true end
  local objs = GetObjectives(qid)
  for _, o in ipairs(objs) do if not o.finished then return false end end
  return #objs > 0
end

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
-- step (optional): the step that triggered the update; it is only marked if it still has the focus and
-- check() (optional) still holds a second later (an objective step is never marked for another's progress).
function CP.AutoUpdate(reason, step, check)
  if CP.autoPending then return end
  CP.autoPending = true
  C_Timer.After(1, function()
    CP.autoPending = nil
    if step and (CP.CurrentFocus() ~= step or (check and not check())) then
      Geo.Trace("auto", "refused (" .. reason .. "): " .. Geo.StepTrace(step) .. ", focus on "
        .. (CP.CurrentFocus() and Geo.StepTrace(CP.CurrentFocus()) or "nothing"))
      return
    end
    Geo.Trace("auto", reason .. ": " .. (CP.CurrentFocus() and Geo.StepTrace(CP.CurrentFocus()) or "no focus"))
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
  local fz = Geo.Frozen()
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
  local rec = Geo.FrozenRec()
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
-- you is where it was found (done), the other ones leave the Roadbook, and the Roadbook is adapted
-- (CP.Replan), tracked or not. Returns true if the Roadbook was changed.
function CP.GiverFound(a1, a2)
  local pos = PlayerPos()
  local handled = false
  local fz = Geo.Frozen()
  if fz then
    local route, rec = fz.route, Geo.FrozenRec()
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
      handled = true
      local msg = L["Quest giver found: "] .. (title or "?") .. ". "
      scan.dirty = true -- the quest left the available ones: scanned again before the computation
      if not CP.Replan(msg) then
        Print(msg)
        if Geo.Tracking() then
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

-- Auto mode (Settings().autoAdd): each quest accepted is proposed for the list, one window at a time.
function CP.SetAutoAdd(on)
  Settings().autoAdd = on and true or nil
  Print(on and L["Auto mode on: each quest you accept is proposed for the Roadbook list."]
    or L["Auto mode off."])
  if Refresh then Refresh() end
  if Geo.MapPanelSync then pcall(Geo.MapPanelSync) end
end

function CP.AutoAskNext()
  if CP.autoShown or not CP.autoAsk or #CP.autoAsk == 0 then return end
  local e = table.remove(CP.autoAsk, 1)
  CP.autoShown = true
  if not StaticPopup_Show("FQP_AUTO_ADD", e.title, nil, e) then
    CP.autoShown = nil
  end
end

-- Auto mode: the game tracks a quest as it is accepted; it is untracked, except the active step's quest.
function CP.AutoUnwatch(id)
  C_Timer.After(0.5, function()
    local f = CP.focused
    if f and f.task and f.task.id == id then return end
    if IsInLog(id) and IsWatched(id) then SetWatched(id, false) end
  end)
end

function CP.AutoAddAccepted(a1, a2)
  if not Settings().autoAdd then return end
  local id = a2 or a1
  if type(id) ~= "number" then return end
  CP.AutoUnwatch(id)
  if Geo.InCustom(id) then return end
  CP.autoAsk = CP.autoAsk or {}
  for _, e in ipairs(CP.autoAsk) do if e.id == id then return end end
  CP.autoAsk[#CP.autoAsk + 1] = { id = id, title = QGet(QDB.Quest, id, "name") or ("#" .. id) }
  CP.AutoAskNext()
end

-- Added as soon as no computation is running.
function CP.AutoAddSoon(id, title, tries)
  if Geo.computing then
    if (tries or 0) < 30 then C_Timer.After(2, function() CP.AutoAddSoon(id, title, (tries or 0) + 1) end) end
    return
  end
  Geo.CustomAdd(id, title)
end

StaticPopupDialogs["FQP_AUTO_ADD"] = {
  text = L["Add \"%s\" to the Roadbook list?"],
  button1 = L["Add"],
  button2 = L["Ignore"],
  OnAccept = function(_, data)
    if data then CP.AutoAddSoon(data.id, data.title) end
  end,
  OnHide = function()
    CP.autoShown = nil
    C_Timer.After(0.2, CP.AutoAskNext)
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

function CP.OnGameEvent(event, a1, a2)
  if event == "QUEST_ACCEPTED" then pcall(CP.AutoAddAccepted, a1, a2) end
  if event == "QUEST_LOG_UPDATE" and CP.checkpointButton then C_Timer.After(0.2, function() pcall(CP.RefreshButton) end) end
  -- Landing after a flight taken during a focus.
  if event == "FQP_TAXI_LANDED" and CP.flying then
    CP.flying = nil -- the focus already moved to the next step at take-off
    local st = CP.flightStep
    CP.flightStep, CP.taxiChosen = nil, nil
    if st then CP.CheckLanding(st) end
    return
  end
  if event == "QUEST_TURNED_IN" and a1 then
    CP.turnedIn = CP.turnedIn or {}
    CP.turnedIn[a1] = true
  end
  if event == "QUEST_REMOVED" then -- turned in or abandoned: known a moment later
    if a1 then C_Timer.After(1, function() pcall(CP.QuestRemoved, a1) end) end
    return
  end
  if event == "QUEST_ACCEPTED" and CP.GiverFound(a1, a2) then return end
  if event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED" or event == "QUEST_TURNED_IN" then
    pcall(CP.ScheduleRecallCheck, 3) -- steps done ahead (CP.AheadCheck)
  end
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
  elseif s.kind == "skill" then
    if event == "SKILL_LINES_CHANGED" and CP.StepDone(s) then CP.AutoUpdate(L["Skill level reached"]) end
  elseif s.kind == "service" then
    if event == K.SERVICE_EVENTS[s.task.service or "vendor"] then
      Geo.ServiceClear() -- done: the next computations no longer plan it
      CP.AutoUpdate(L["Service done"])
    end
  elseif s.kind == "dungeon" then
    if (event == "QUEST_LOG_UPDATE" or event == "QUEST_TURNED_IN" or event == "QUEST_ACCEPTED") and CP.StepDone(s) then
      CP.AutoUpdate(L["Dungeon done"])
    end
  elseif event == "QUEST_TURNED_IN" and s.kind ~= "take" then
    if qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(L["Quest turned in"]) end
  elseif s.kind == "take" then
    if event == "QUEST_ACCEPTED" and qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(L["Quest picked up"]) end
  elseif s.kind == "obj" then
    if event == "BAG_UPDATE_DELAYED" then
      if s.r and s.r.tg and s.r.tg.sourceItem and CP.StepDone(s) then
        CP.AutoUpdate(L["Item obtained"], s, function() return CP.StepDone(s) end)
      end
    elseif event == "QUEST_LOG_UPDATE" and qid then
      local now = CP.Progress(qid)
      local rec = CP.FocusRecord()
      -- Objective of the step found in the game: done when it is (another objective of the quest
      -- done meanwhile is a step done ahead, CP.AheadCheck); otherwise any progress of the quest.
      local known = IsInLog(qid) and Geo.TargetObjective(qid, s.r and s.r.tg, GetObjectives(qid))
      if known then
        if rec then rec.progress = now end
        if CP.StepDone(s) then CP.AutoUpdate(L["Objective completed"], s, function() return CP.StepDone(s) end) end
      elseif rec and now > (rec.progress or 0) then
        rec.progress = now
        -- Objective not identified: only the whole quest done (every objective) ends the step.
        CP.AutoUpdate(L["Objective completed"], s, function() return CP.QuestObjectivesDone(qid) end)
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
  elseif s.kind == "skill" then
    local sk = s.skill
    return "|TInterface\\Icons\\INV_Misc_Book_11:14:14|t " .. string.format(L["Raise the %s skill to level %d"], sk.name, sk.need),
      (s.npc and (L["Train with "] .. s.npc .. " · " .. place) or L["trainer not located"])
        .. " · " .. string.format(L["skill %d/%d"], sk.have, sk.need) .. " · " .. task.title
  elseif s.kind == "service" then
    local icon = "Interface\\Icons\\INV_Misc_Coin_01"
    for _, def in ipairs(K.SERVICES) do if def.key == task.service then icon = def.icon end end
    return "|T" .. icon .. ":14:14|t " .. (task.title or "?"), L["Talk to "] .. (task.npc or "?") .. " · " .. place
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
    local o = task.id and IsInLog(task.id) and Geo.TargetObjective(task.id, s.r and s.r.tg, GetObjectives(task.id))
    if o and o.need then prog = (o.have or 0) .. "/" .. o.need end
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
  if Geo.computing and not s then
    -- Roadbook being computed with no step followed (being computed, start…): the click does nothing.
    b.title:SetText(L["Objective"])
    b.sub:SetText(L["Recomputing…"])
    b.current = nil
  elseif s then
    local t, d = CP.StepSummary(s)
    local maxW = K.OBJECTIVE_MAX_WIDTH - K.OBJECTIVE_TEXT_X - 10
    -- White title, as in the tabs; quest step: then the same badges (colored level, elite), too wide:
    -- on the next line; the quest types on the first line of the details (same font).
    local types = ""
    if not (s.task and s.task.id) then
      t = Color("ffffff", t)
    else
      local badges = Geo.QuestBadges({ id = s.task.id, level = s.task.level, noTypes = true })
      local full = Color("ffffff", t) .. badges
      if CP.TextWidth(b.title, full) > maxW then full = Color("ffffff", t) .. "\n" .. badges:gsub("^%s+", "") end
      types = Geo.QuestTypesText(s.task.id)
      t = full
    end
    b.title:SetText(t)
    local sub = CP.PackInfos(b.sub, d, maxW)
    if types ~= "" then sub = types .. ((sub and sub ~= "") and ("\n" .. sub) or "") end
    -- Roadbook adapted while followed: the step stays shown meanwhile, replaced at the end if needed.
    if Geo.computing then sub = Color("ffd100", L["Recomputing…"]) .. ((sub and sub ~= "") and ("\n" .. sub) or "") end
    b.sub:SetText(sub)
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
  CP.ServiceBarSync()
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
  -- Dark tooltip-like frame, golden border (the style of every window of the addon).
  Geo.FrameStyle(b)
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
    local c = K.FRAME_BORDER_HOVER
    if b.SetBackdropBorderColor then b:SetBackdropBorderColor(c[1], c[2], c[3], c[4]) end
  end
  b.HoverOut = function()
    local c = K.FRAME_BORDER
    if b.SetBackdropBorderColor then b:SetBackdropBorderColor(c[1], c[2], c[3], c[4]) end
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
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(_, button)
    if b.dragEnd and GetTime and GetTime() - b.dragEnd < 0.3 then return end -- release of a Shift-drag
    CP.ObjectiveClick(button)
  end)
  b:SetScript("OnEnter", function(self)
    if self.HoverIn then self.HoverIn() end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Objective"])
    GameTooltip:AddLine(L["Click: open or close the map on the objective"], 1, 1, 1)
    GameTooltip:AddLine(L["Right-click: the steps"], 1, 1, 1)
    GameTooltip:AddLine(L["Shift-drag: move"], 0.75, 0.75, 0.75)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    if self.HoverOut then self.HoverOut() end
    GameTooltip:Hide()
  end)
  CP.checkpointButton = b
  CP.CreateServiceBar(b)
  CP.UpdateCheckpointButton()
  CP.RefreshButton()
end

---------------------------------------------------------------------------
-- Service shortcuts under the Objective button: vendor, repair, class trainer
---------------------------------------------------------------------------
K.SERVICE_ICON_SIZE = 26

-- Click: the nearest NPC of the service becomes the priority objective and the Roadbook is
-- planned again (transport steps to reach it, then the rest). A second click on the pending
-- service cancels it.
function CP.ServiceClick(kind)
  if Geo.computing then
    Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
    return
  end
  if not GeoReady() then
    Print(L["Unable to convert QuestieDB positions to this client's map."])
    return
  end
  local cur = Geo.ServicePending()
  if cur and cur.kind == kind then
    Geo.ServiceClear()
    CP.ServiceBarSync()
    if #Geo.CustomList() == 0 then -- nothing left in the Roadbook but the service
      CP.TrackOff(true)
      if not Geo.KeepOnlyDone() then Geo.ClearFrozen() end
      CP.RefreshButton()
      Refresh()
    elseif not CP.Replan(L["Service cancelled. "]) then
      Refresh()
    end
    return
  end
  local npc = Geo.NearestService(kind)
  if not npc then
    Print(L["No such place found."])
    return
  end
  Geo.ServiceSet({ kind = kind, id = npc.id, name = npc.name, p = npc.p })
  CP.ServiceBarSync()
  CP.turningOn = true -- going to the service means following the Roadbook
  local started = CP.Replan(string.format(L["Going to %s first. "], npc.name or "?"))
  CP.turningOn = nil
  if not started then
    Geo.ServiceClear()
    CP.ServiceBarSync()
  end
end

-- Highlight of the pending service.
function CP.ServiceBarSync()
  local bar = CP.serviceBar
  if not bar then return end
  local cur = Geo.ServicePending()
  for _, ib in ipairs(bar.buttons) do
    ib.glow:SetShown(cur ~= nil and cur.kind == ib.key)
  end
end

function CP.CreateServiceBar(b)
  local n, size, gap = #K.SERVICES, K.SERVICE_ICON_SIZE, 4
  local bar = CreateFrame("Frame", nil, b)
  bar:SetSize(n * size + (n - 1) * gap, size)
  bar:SetPoint("TOP", b, "BOTTOM", 0, -3)
  bar.buttons = {}
  for i, def in ipairs(K.SERVICES) do
    local ib = CreateFrame("Button", nil, bar, BackdropTemplateMixin and "BackdropTemplate" or nil)
    ib:SetSize(size, size)
    ib:SetPoint("LEFT", bar, "LEFT", (i - 1) * (size + gap), 0)
    Geo.FrameStyle(ib)
    local tex = ib:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 3, -3)
    tex:SetPoint("BOTTOMRIGHT", -3, 3)
    tex:SetTexture(def.icon)
    if tex.SetTexCoord then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    local glow = ib:CreateTexture(nil, "OVERLAY")
    glow:SetPoint("TOPLEFT", -2, 2)
    glow:SetPoint("BOTTOMRIGHT", 2, -2)
    glow:SetColorTexture(1, 0.82, 0, 0.35)
    glow:Hide()
    local hl = ib:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(tex)
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    ib.key, ib.glow = def.key, glow
    ib:RegisterForClicks("LeftButtonUp")
    ib:SetScript("OnClick", function() CP.ServiceClick(def.key) end)
    ib:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(def.label)
      local ok, npc = pcall(Geo.NearestService, def.key)
      if ok and npc then
        GameTooltip:AddLine(string.format(L["Nearest: %s (~%s)"], npc.name or "?", FormatTime(npc.time or 0)), 1, 1, 1)
      else
        GameTooltip:AddLine(L["No such place found."], 1, 0.4, 0.4)
      end
      local cur = Geo.ServicePending()
      GameTooltip:AddLine((cur and cur.kind == def.key) and L["Click: cancel this priority"]
        or L["Click: go there first, then carry on with the Roadbook"], 0.75, 0.75, 0.75)
      GameTooltip:Show()
    end)
    ib:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bar.buttons[i] = ib
  end
  CP.serviceBar = bar
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
