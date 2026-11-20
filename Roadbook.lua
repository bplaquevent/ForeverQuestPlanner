-- Forever Quest Planner: Roadbook checkpoints, saved Roadbook, Objective button.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local ActivePin, AllInstance, BuildNetwork, CharKey, ClearPin, Color = ns.ActivePin, ns.AllInstance, ns.BuildNetwork, ns.CharKey, ns.ClearPin, ns.Color
local DBXP, Dist, FormatTime, Geo, GeoReady, GetObjectives = ns.DBXP, ns.Dist, ns.FormatTime, ns.Geo, ns.GeoReady, ns.GetObjectives
local ICON, IsCompleted, IsInLog, K, L, Nearest = ns.ICON, ns.IsCompleted, ns.IsInLog, ns.K, ns.L, ns.Nearest
local PinPoint, PlayerPos, PointText, Print, QDB, QGet = ns.PinPoint, ns.PlayerPos, ns.PointText, ns.Print, ns.QDB, ns.QGet
local QuestTargets, Refresh, Route, Settings, Snapshot, StartScan = ns.QuestTargets, ns.Refresh, ns.Route, ns.Settings, ns.Snapshot, ns.StartScan
local State, TaxiCount, TaxiStore, TravelSpeed, TurnInText, WatchOnly = ns.State, ns.TaxiCount, ns.TaxiStore, ns.TravelSpeed, ns.TurnInText, ns.WatchOnly
local scan = ns.scan

---------------------------------------------------------------------------
-- Roadbook checkpoints: focus on the next step from a floating button
---------------------------------------------------------------------------
local CP = {} -- Roadbook checkpoints (a table to stay under the local variables limit)
CP.lastPlan = nil -- steps of the last computed plan (without the starting point)

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
  if s.kind == "fm" then return L["activate the flight master"] end
  if s.kind == "bind" then return L["bind the hearthstone"] end
  if s.kind == "hearth" then return L["hearthstone"] end
  if s.kind == "travel" then return L["transport"] end
  if s.kind == "take" then return L["pick up the quest"] end
  if s.kind == "obj" then return s.r and s.r.tg.name or L["objective"] end
  return L["turn in the quest"]
end

function CP.StepText(s)
  if s.kind == "fm" or s.kind == "bind" then return (s.task.title or "?") .. " (" .. (s.task.npc or "?") .. ")" end
  if s.kind == "hearth" or s.kind == "travel" then return s.task.title or "?" end
  local tag = (s.escort and L["Escort"]) or (s.kind == "take" and L["Pick up"]) or (s.kind == "obj" and L["Objective"]) or L["Turn in"]
  local extra = s.kind == "obj" and s.r and (L[": "] .. (s.r.tg.name or L["objective"]) .. L[" x"] .. s.r.count) or ""
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
  CP.focused = s
  CP.focusRec = { questId = s.task.id, label = CP.StepPinLabel(s), area = s.p.area, mx = s.p.mx, my = s.p.my,
    progress = CP.Progress(s.task.id) }
  local qid = s.task.id
  if qid and IsInLog(qid) then WatchOnly(qid) end
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

-- Validate the checkpoint: focus on the next step of the saved Roadbook if the current one is
-- done in the game (see CP.ValidateUnsafe).
---------------------------------------------------------------------------
-- Saved Roadbook: once computed, the plan no longer changes until its end, or until a
-- recompute request (duration change, Recalculate button, Ctrl-click on the button).
---------------------------------------------------------------------------
function Geo.CopyPoint(p)
  if not p then return nil end
  return { c = p.c, x = p.x, y = p.y, area = p.area, ui = p.ui, mx = p.mx, my = p.my, zoneName = p.zoneName,
    teleport = p.teleport, instance = p.instance }
end

function Geo.SerializeStep(st)
  local t = st.task or {}
  return { kind = st.kind, at = st.at, xp = st.xp, work = st.work, gain = st.gain, spots = st.spots, quick = st.quick,
    escort = st.escort, glue = st.glue,
    spotN = st.spot and st.spot.n, done = st.done, p = Geo.CopyPoint(st.p),
    objName = st.r and st.r.tg and st.r.tg.name, objKind = st.r and st.r.tg and st.r.tg.kind, count = st.r and st.r.count,
    first = t.stops and t.stops[1] == st or nil,
    task = { id = t.id, title = t.title, level = t.level, xp = t.xp, starter = t.starter, reqLevel = t.reqLevel,
      depTitle = t.dep and t.dep.title, tags = t.tags, npc = t.npc, mode = t.mode, from = t.from, dest = t.dest,
      destP = Geo.CopyPoint(t.destP), kind = t.kind, quick = t.quick } }
end

function Geo.DeserializeStep(rec, tasks)
  local tr = rec.task or {}
  local key = tostring(tr.id) .. "|" .. tostring(tr.title) .. "|" .. tostring(rec.kind == "travel" and rec.at or "")
  local task = tasks[key]
  if not task then
    task = { id = tr.id, title = tr.title, level = tr.level, xp = tr.xp, starter = tr.starter, reqLevel = tr.reqLevel,
      dep = tr.depTitle and { title = tr.depTitle } or nil, tags = tr.tags, npc = tr.npc, mode = tr.mode,
      from = tr.from, dest = tr.dest, destP = tr.destP, kind = tr.kind, quick = tr.quick, stops = {} }
    tasks[key] = task
  end
  local st = { kind = rec.kind, at = rec.at, xp = rec.xp, work = rec.work or 0, gain = rec.gain, spots = rec.spots, quick = rec.quick,
    escort = rec.escort, glue = rec.glue,
    spot = rec.spotN and { n = rec.spotN } or nil, done = rec.done, p = rec.p or {}, task = task,
    r = rec.objName and { tg = { name = rec.objName, kind = rec.objKind }, count = rec.count } or nil }
  if rec.first then task.stops[1] = st end
  return st
end

function Geo.FrozenStore()
  local st = Settings()
  st.roadbook = st.roadbook or {}
  return st.roadbook
end

-- Saves a plan that was just computed.
function Geo.Freeze(route, info)
  local steps = {}
  for i = 2, #route do steps[#steps + 1] = Geo.SerializeStep(route[i]) end
  local slim = { count = info.count, xp = info.xp, total = info.total, mobXP = info.mobXP, levels = info.levels,
    speed = info.speed, plevel = info.plevel, skipped = info.skipped, later = info.later, taxi = info.net and info.net.taxi }
  Geo.FrozenStore()[CharKey()] = { horizon = State.xpHorizon, saved = date and date("%H:%M") or "", start = Geo.CopyPoint(route[1].p),
    steps = steps, info = slim }
  Geo.frozen = { route = route, info = info }
  CP.lastPlan = {}
  for i = 2, #route do CP.lastPlan[#CP.lastPlan + 1] = route[i] end
end

-- Saved plan (reloaded after a /reload), or nil.
function Geo.Frozen()
  if Geo.frozen then return Geo.frozen end
  local rec = Geo.FrozenStore()[CharKey()]
  if not (rec and rec.steps and #rec.steps > 0) then return nil end
  -- After a /reload, the QuestieDB map mappings are not loaded yet.
  if not (QDB.ok and GeoReady()) then return nil end
  local route, tasks = { { kind = "start", p = rec.start or {}, work = 0 } }, {}
  for _, r in ipairs(rec.steps) do route[#route + 1] = Geo.DeserializeStep(r, tasks) end
  local info = {}
  for k, v in pairs(rec.info or {}) do info[k] = v end
  info.net = BuildNetwork(info.speed or TravelSpeed())
  info.net.taxi = TaxiCount()
  Geo.frozen = { route = route, info = info }
  if rec.horizon then State.xpHorizon = rec.horizon end
  CP.lastPlan = {}
  for i = 2, #route do CP.lastPlan[#CP.lastPlan + 1] = route[i] end
  return Geo.frozen
end

function Geo.ClearFrozen()
  Geo.frozen = nil
  Geo.FrozenStore()[CharKey()] = nil
  Geo.planCache = nil
end

-- Marks a step as done (and saves it).
function Geo.MarkDone(st, value)
  if value == nil then value = true end
  st.done = value or nil
  local fz = Geo.frozen
  local rec = Geo.FrozenStore()[CharKey()]
  if fz and rec and rec.steps then
    for i = 2, #fz.route do
      if fz.route[i] == st and rec.steps[i - 1] then rec.steps[i - 1].done = value or nil end
    end
  end
end

-- Quick wins: a quest from the log that became ready to turn in during the Roadbook, whose NPC is
-- next to an upcoming step (or to you), is added to the saved plan right after that step.
function Geo.InjectQuickWins()
  local fz = Geo.Frozen()
  if not (fz and QDB.ok) then return 0 end
  local route = fz.route
  local rec = Geo.FrozenStore()[CharKey()]
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
    if q.complete and not q.failed and not pending[q.id] and IsInLog(q.id)
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
  if added > 0 then
    CP.lastPlan = {}
    for i = 2, #route do CP.lastPlan[#CP.lastPlan + 1] = route[i] end
    if focusNew and cur then CP.FocusStep(focusNew) end
  end
  return added
end

-- Step already done: marked, or observed in the game (quest picked up, objective done, quest turned in…).
function CP.StepDone(st)
  if st.done then return true end
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
    for _, n in pairs(TaxiStore()) do
      local d = Dist(n, st.p)
      if d and d < K.FM_KNOWN_RADIUS then return true end
    end
  end
  return false
end

-- Computes a new Roadbook and saves it; cb(route) when done.
function Geo.Recompute(cb)
  Geo.ClearFrozen()
  Snapshot()
  if CP.checkpointButton and CP.checkpointButton.sub then CP.checkpointButton.sub:SetText(L["Computing the Roadbook…"]) end
  Geo.RequestPlan(State.xpHorizon, function(route, err, info)
    if route and #route >= 2 then Geo.Freeze(route, info) end
    if cb then cb(route, err, info) end
    if Refresh then C_Timer.After(0.1, Refresh) end
  end, true)
end

-- Focuses the first step of the saved Roadbook that is not done yet.
-- At the end of the plan, a new Roadbook is computed.
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
    for _, i in ipairs(order) do
      local st = fz.route[i]
      if not CP.StepDone(st) then
        CP.FocusStep(st)
        if not silent then Print(L["Focus: "] .. CP.StepText(st)) end
        if Refresh then C_Timer.After(0.2, Refresh) end
        return
      end
    end
    Print(L["Roadbook finished: computing a new Roadbook."])
  end
  CP.Recompute()
end

-- Full recompute (Ctrl-click on the button, or end of the Roadbook) then focus on the first step.
function CP.Recompute(attempt)
  if not (QDB.ok and GeoReady()) then
    Print(L["Cannot compute: the Roadbook requires QuestieDB."])
    return
  end
  -- Available quests change after a pick-up or turn-in: wait for their scan to finish.
  if scan.running or scan.dirty or not scan.entries then
    if not scan.running then StartScan() end
    attempt = (attempt or 0) + 1
    if attempt > 40 then
      Print(L["Quest scan is taking too long: try again in a moment."])
      return
    end
    C_Timer.After(0.5, function() CP.Recompute(attempt) end)
    return
  end
  Geo.Recompute(function(route, err)
    if not route or #route < 2 then
      Print(err or L["The Roadbook is empty: no step to follow."])
      CP.RefreshButton()
      return
    end
    local first
    for i = 2, #route do
      if not CP.StepDone(route[i]) then first = route[i] break end
    end
    if first then
      CP.FocusStep(first)
      Print(L["New Roadbook. Active step: "] .. CP.StepText(first))
    end
  end)
end

-- Click on the button: focus the next step only if the current one is done in the
-- game; Shift-click: skip the current step even if it is not done.
function CP.ValidateUnsafe(recompute)
  if recompute or not Geo.Frozen() then
    CP.Recompute()
    return
  end
  local cur = CP.CurrentFocus()
  if cur and not CP.StepDone(cur) then
    CP.FocusStep(cur) -- tracking active: the pin is placed on the current step again
    Print(L["Focus: "] .. CP.StepText(cur))
    return
  end
  if cur then Geo.MarkDone(cur) end
  CP.FocusNext(false, cur) -- no tracking yet, or step done: first step left to do
end

-- Ctrl-click: stops following the objective (focus, addon pin and compass); click resumes it.
function CP.StopTracking()
  if not CP.CurrentFocus() then
    Print(L["No objective tracked."])
    return
  end
  CP.ClearFocus()
  ClearPin()
  CP.RefreshButton()
  Print(L["Objective tracking stopped: click the Objective button to resume it."])
  if Refresh then Refresh() end
end

-- Shift-click: link of the quest of the followed step in the chat.
function CP.LinkCurrentQuest()
  local cur = CP.CurrentFocus()
  local id = cur and cur.task and cur.task.id
  if id then Geo.LinkQuestInChat(id) else Print(L["No quest for this objective."]) end
end

-- Ctrl-Alt-click: removes the current step. A quest step removes the whole quest (confirmation,
-- then a new Roadbook); any other step (flight, hearthstone…) is skipped.
function CP.RemoveCurrentStep()
  local cur = CP.CurrentFocus()
  if not cur then
    Print(L["No objective tracked."])
    return
  end
  if cur.task and cur.task.id then
    CP.AskExclude(cur)
    return
  end
  Print(L["Step skipped: "] .. CP.StepText(cur))
  Geo.MarkDone(cur)
  CP.FocusNext(false, cur)
end

-- Quest removed from the Roadbook (badly defined, not found…): excluded, then a new Roadbook.
function CP.ExcludeQuest(id, title)
  if not id then return end
  Settings().excluded[id] = title or true
  Geo.planCache = nil
  Print(L["Quest removed from the Roadbook: "] .. (title or tostring(id)) .. L[". It can be added back in the options."])
  CP.Recompute()
end

function CP.AskExclude(s)
  local id = s and s.task and s.task.id
  if not id then return end
  StaticPopup_Show("FQP_EXCLUDE", s.task.title or tostring(id), nil, { id = id, title = s.task.title })
end

StaticPopupDialogs["FQP_EXCLUDE"] = {
  text = L["Remove the quest \"%s\" from the Roadbook and compute a new one?\n\nUseful when a quest is badly defined or cannot be found. It can be added back in the options."],
  button1 = L["Remove"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, data) if data then CP.ExcludeQuest(data.id, data.title) end end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

function CP.Validate(recompute)
  local ok, err = xpcall(function() CP.ValidateUnsafe(recompute) end, function(e)
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

-- Watches the position every 2 s while a zeppelin / boat step has the focus.
function CP.WatchTransport(s)
  if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
  if not (s.kind == "travel" and s.task.mode ~= "vol" and C_Timer.NewTicker) then return end
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
  if s.task.mode == "vol" and chosen and s.task.dest and chosen ~= s.task.dest then
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
  for _, n in pairs(TaxiStore()) do
    local d = Dist(n, pos)
    if d and (not nd or d < nd) then node, nd = n, d end
  end
  if node and nd < K.LANDING_RADIUS then
    if node.name == t.dest then return end
  else
    local d = t.destP and Dist(pos, t.destP)
    if not t.destP or (d and d < K.LANDING_RADIUS) then return end
  end
  CP.Reroute(st, pos)
end

-- Replaces the transport steps from the step `st` to the next real step by the shortest
-- route from `pos`, then focuses the first step of that route.
function CP.Reroute(st, pos)
  local fz = Geo.Frozen()
  if not fz then return end
  local route = fz.route
  local fi
  for i = 2, #route do if route[i] == st then fi = i break end end
  if not fi then return end
  local ti = fi
  while route[ti] and route[ti].kind == "travel" do ti = ti + 1 end
  local target = route[ti]
  for _ = fi, ti - 1 do table.remove(route, fi) end
  local legs = {}
  if target and target.kind ~= "hearth" and not target.glue then
    local net = fz.info.net or BuildNetwork(TravelSpeed())
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
  local rec = Geo.FrozenStore()[CharKey()]
  if rec then
    rec.steps = {}
    for i = 2, #route do rec.steps[#rec.steps + 1] = Geo.SerializeStep(route[i]) end
  end
  CP.lastPlan = {}
  for i = 2, #route do CP.lastPlan[#CP.lastPlan + 1] = route[i] end
  local first = legs[1]
  if first then
    Print(L["Wrong destination: new route. "] .. L["Focus: "] .. CP.StepText(first))
    CP.FocusStep(first)
  elseif target then
    Print(L["Wrong destination: new route. "] .. L["Focus: "] .. CP.StepText(target))
    CP.FocusStep(target)
  else
    CP.FocusNext(false)
  end
  if Refresh then C_Timer.After(0.2, Refresh) end
end

function CP.OnGameEvent(event, a1, a2)
  if event == "QUEST_LOG_UPDATE" and CP.checkpointButton then C_Timer.After(0.2, function() pcall(CP.RefreshButton) end) end
  if (event == "QUEST_LOG_UPDATE" or event == "ZONE_CHANGED_NEW_AREA") and not CP.quickPending and Geo.frozen then
    CP.quickPending = true
    C_Timer.After(2.5, function() -- after the quest log capture (2 s)
      CP.quickPending = nil
      local ok, n = pcall(Geo.InjectQuickWins)
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
    if event == "FQP_HEARTH_ARRIVED" then CP.AutoUpdate(L["Back by hearthstone"]) end
  elseif s.kind == "travel" then
    if event == "FQP_TAXI_TAKEOFF" then
      CP.TakeOff(s)
    elseif s.task.mode ~= "vol" and (event == "ZONE_CHANGED_NEW_AREA" or event == "FQP_TRANSPORT_TICK") then
      CP.CheckArrival(s)
    end
  elseif s.kind == "fm" then
    if event == "TAXIMAP_OPENED" then CP.AutoUpdate(L["Flight master activated"]) end
  elseif (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and s.kind ~= "take" then
    if qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(event == "QUEST_TURNED_IN" and L["Quest turned in"] or L["Quest removed"]) end
  elseif s.kind == "take" then
    if event == "QUEST_ACCEPTED" and qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(L["Quest picked up"]) end
  elseif s.kind == "obj" then
    if event == "QUEST_LOG_UPDATE" and qid then
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
    return "|TInterface\\Icons\\INV_Misc_Rune_01:14:14|t " .. (task.title or "?"),
      L["Use the hearthstone · saves ~"] .. FormatTime(s.gain or 0)
  elseif s.kind == "travel" then
    return "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t " .. (task.mode == "vol" and L["Flight"] or K.MODE_NAME[task.mode] or task.mode or L["Transport"]) ..
      L[" to "] .. (task.dest or "?"), L["Departure: "] .. (task.from or "?") .. " · " .. place
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
    return ICON.available .. " " .. (task.title or "?"),
      L["Pick up from "] .. (nameOnly(task.starter) or "?") .. " · " .. place .. esc
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
    b.sub:SetText(L["No objective tracked · click to follow it"])
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

-- Commands of the Objective button, shown in its tooltip (two per line).
K.OBJECTIVE_COMMANDS = {
  { "Click: follow", "Ctrl-click: stop" },
  { "Shift-click: chat link", "Alt-click: new Roadbook" },
  { "Ctrl-Alt-click: remove the step", "Right-click: Roadbook" },
  { "Shift-right-click: center", "Shift-drag: move" },
}
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
  sub:SetText(L["No objective tracked · click to follow it"])
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
    self.dragEnd = GetTime and GetTime() or 0 -- the release of a Shift-drag must not count as a Shift-click (link)
    local point, _, _, x, y = self:GetPoint()
    Settings().checkpointPos = { point, x, y }
  end)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(_, button)
    if b.dragEnd and GetTime and GetTime() - b.dragEnd < 0.3 then return end
    if button == "RightButton" then
      if IsShiftKeyDown and IsShiftKeyDown() then
        CP.CenterCheckpointButton() -- Shift-right-click: center the button horizontally
      elseif CP.OpenWindow then
        CP.OpenWindow("xp") -- right-click: window opened on the Roadbook
      end
    else
      local alt = IsAltKeyDown and IsAltKeyDown()
      local ctrl = IsControlKeyDown and IsControlKeyDown()
      local shift = IsShiftKeyDown and IsShiftKeyDown()
      if alt and ctrl then
        CP.RemoveCurrentStep()   -- Ctrl-Alt-click: remove the step from the Roadbook
      elseif alt then
        CP.Validate(true)        -- Alt-click: compute a new Roadbook
      elseif ctrl then
        CP.StopTracking()        -- Ctrl-click: stop following the objective
      elseif shift then
        CP.LinkCurrentQuest()    -- Shift-click: link of the objective's quest in the chat
      else
        CP.Validate(false)       -- click: follow the objective
      end
    end
  end)
  b:SetScript("OnEnter", function(self)
    if self.HoverIn then self.HoverIn() end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Forever Quest Planner - Roadbook"])
    if self.current then
      GameTooltip:AddLine(L["Current step: "] .. CP.StepText(self.current), 1, 1, 1, true)
    else
      GameTooltip:AddLine(L["No Roadbook step has the focus."], 1, 1, 1, true)
    end
    -- Commands: compact, two per line, dimmed (the step detail stays the main content).
    GameTooltip:AddLine(" ")
    for _, pair in ipairs(K.OBJECTIVE_COMMANDS) do
      GameTooltip:AddDoubleLine(L[pair[1]], L[pair[2]], 0.55, 0.55, 0.55, 0.55, 0.55, 0.55)
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    if self.HoverOut then self.HoverOut() end
    GameTooltip:Hide()
  end)
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
