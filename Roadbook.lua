-- Forever Quest Planner: following the Roadbook: the focused step, which steps are done or can be done,
-- the recomputations, the game events that move it forward.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local ClearPin, Color, Dist, Geo, GeoReady, GetObjectives = ns.ClearPin, ns.Color, ns.Dist, ns.Geo, ns.GeoReady, ns.GetObjectives
local IsCompleted, IsInLog, K, L, PinPoint, PlayerPos, Print = ns.IsCompleted, ns.IsInLog, ns.K, ns.L, ns.PinPoint, ns.PlayerPos, ns.Print
local QDB, QGet, Refresh, Settings, Snapshot, KnownFlights = ns.QDB, ns.QGet, ns.Refresh, ns.Settings, ns.Snapshot, ns.KnownFlights
local State, TravelSpeed, WatchOnly, IsWatched, SetWatched = ns.State, ns.TravelSpeed, ns.WatchOnly, ns.IsWatched, ns.SetWatched
local MarkScanDirty, LogEntry, IsQuestComplete, WaitScan = ns.MarkScanDirty, ns.LogEntry, ns.IsQuestComplete, ns.WaitScan
local Guard = ns.Guard

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
  Print(Color(K.DESC.bad, L["Escort failed: "]) ..
    string.format(L["%s. Abandon the quest, then pick it up again from %s."], s.task.title or "?", CP.EscortNpc(s.task)))
  if take and take.kind == "take" then
    Geo.MarkDone(take, false)
    CP.FocusStep(take)
  else
    CP.RefreshButton()
  end
end

function CP.StepPinLabel(s)
  if s.kind == "dungeon" then return L["enter the instance"] end
  if s.kind == "fm" then return L["activate the flight master"] end
  if s.kind == "bind" then return L["bind the hearthstone"] end
  if s.kind == "skill" then return L["raise the skill"] end
  if s.kind == "hearth" then return s.task.spell and L["teleport"] or L["hearthstone"] end
  if s.kind == "travel" then return L["transport"] end
  if s.kind == "take" then return L["pick up the quest"] end
  if s.kind == "obj" then return s.r and s.r.tg.name or L["objective"] end
  return L["turn in the quest"]
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
    local need = s.task.id and Geo.SkillNeed(s.task.id, LogEntry(s.task.id))
    Print(Color(K.DESC.warn, need and (Geo.SkillNeedText(need) .. L[": "]) or L["Objectives not completed yet: "])
      .. (s.task.title or "?"))
  end
  Geo.MapClaim("track") -- the followed Roadbook holds the map (RoadbookMap.lua)
  if not s.nopin then PinPoint(s.p, s.task.title, CP.StepPinLabel(s), qid) end
  CP.RefreshButton()
  CP.WatchTransport(s)
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
    if IsQuestComplete(id) then return true end
    -- Source item (not a game objective): done once it is in the bags.
    local src = st.r and st.r.tg and st.r.tg.sourceItem
    if src then return Geo.ItemCount(src) > 0 end
    local o = Geo.TargetObjective(id, st.r and st.r.tg, GetObjectives(id))
    return o and o.finished and true or false
  end
  if st.kind == "skill" then
    return not (id and Geo.SkillNeed(id, LogEntry(id)))
  end
  if st.kind == "fm" then
    local node = (st.fmHub and st.fmHub.node) or Geo.NodeAt(st.p)
    if node and Geo.KnownNodes()[node] then return true end
  end
  return false
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
  if st.kind == "turnin" and Geo.SkillNeed(id, LogEntry(id)) then return false end -- profession level
  if st.kind == "turnin" and IsInLog(id) and IsQuestComplete(id) then return true end
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

-- A new or adapted plan becomes the Roadbook: saved, then redrawn on the map if it is there.
function Geo.AdoptPlan(route, info)
  Geo.Freeze(route, info)
  Geo.MapSync()
end

-- Steps to come removed, the steps done kept (history): the custom Roadbook whose list was emptied.
-- Returns false when no step is done (nothing to keep).
function Geo.KeepOnlyDone()
  local fz = Geo.Frozen()
  if not fz then return false end
  local start = { { kind = "start", p = fz.route[1].p, work = 0 } }
  local info = {}
  for k, v in pairs(fz.info) do info[k] = v end
  local route = Geo.KeepDone(fz, CP.StepDone, start, { total = 0, levels = { UnitLevel("player") } }, info)
  if #route < 2 then return false end
  info.dungeons, info.discovered, info.skipped, info.unplanned = nil, nil, nil, nil
  Geo.AdoptPlan(route, info)
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
    if not State.computing then return end -- deleted meanwhile
    State.computing = nil
    Guard(CP.RefreshButton) -- the Objective button can be clicked again
    Geo.SyncQuestLogButton() -- the list can change again
    if route and #route >= 2 and goal ~= "custom" then
      Geo.AcceptGenerated(route, info, function(ok)
        if cb then cb(ok and route or nil, not ok and L["Adaptation cancelled: the Roadbook and its list are unchanged."] or err, info) end
        C_Timer.After(0.1, Refresh)
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
      end
      Geo.AdoptPlan(route, info)
    end
    if cb then cb(route, err, info) end
    C_Timer.After(0.1, Refresh)
  end, re and re.opts)
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
      if not silent then Print(L["Focus: "] .. CP.StepLine(pick)) end
      C_Timer.After(0.2, Refresh)
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
  if CP.RefuseWhileComputing() then return end
  if not Geo.Frozen() then
    Print(L["This Roadbook has no step: add quests to its list or click \"Adapt\"."])
    return
  end
  if Geo.IsFinished() then
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
    res = ok and State.computing and true or false
  end
  CP.turningOn = nil
  if not ok then Print(L["Roadbook update error: "] .. tostring(res)) end
  if not (ok and res) then CP.FocusNext(false) end
  CP.RefreshButton()
  Refresh()
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
  if not (fz and rec) or State.computing then return false end
  local now = Geo.RecallState()
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
function CP.Replan(msg, opts, manual)
  -- Never computed again by itself while not tracked (manual: the Recompute icon).
  if not (manual or Geo.Tracking() or CP.turningOn) then return false end
  if not GeoReady() then return false end
  if CP.RefuseWhileComputing() then return false end
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
    if State.computing or CP.Busy() or not PlayerPos() then
      CP.ScheduleRecallCheck(10)
      return
    end
    local okA, started = pcall(CP.AheadCheck)
    if not okA then Print(L["Roadbook update error: "] .. tostring(started)) end
    if okA and started then return end
    if not Geo.Tracking() then return end
    local ok, err = pcall(CP.RecallCheck)
    if not ok then Print(L["Roadbook update error: "] .. tostring(err)) end
  end)
end

-- One computation at a time: a request meanwhile is refused with a message. Returns true when refused.
function CP.RefuseWhileComputing()
  if not State.computing then return false end
  Print(string.format(L["Computing the Roadbook (up to %d s), please wait…"], K.PLAN_TIME))
  return true
end

-- Flying, on a taxi, fighting or dead: no change of the Roadbook now.
function CP.Busy()
  return CP.flying or (UnitOnTaxi and UnitOnTaxi("player")) or (InCombatLockdown and InCombatLockdown())
    or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) or false
end

-- Steps done ahead: a quest picked up, an objective done or a quest turned in before its place in
-- the Roadbook. Right after the steps done, the route stays right (several quests from the same
-- NPC…); further on, the steps to come are computed again without them (they join the history).
-- A step that comes back after the computation it started does not start another one (it is
-- forgotten when its quest leaves the log, CP.QuestRemoved). Returns true if a computation started.
K.AHEAD_KINDS = { take = true, obj = true, turnin = true }
CP.aheadSeen = {} -- key of a step done ahead (Geo.StepKey) -> quest id
function CP.AheadCheck()
  local fz = Geo.Frozen()
  if not fz or State.computing or CP.autoPending then return false end
  local route, first, ahead = fz.route, nil, {}
  for i = 2, #route do
    local st = route[i]
    local done = CP.StepDone(st)
    if not first then
      if not done then first = i end
    elseif done and not st.done and K.AHEAD_KINDS[st.kind] and not st.search and st.task and st.task.id
      and not CP.aheadSeen[Geo.StepKey(st)] then
      ahead[#ahead + 1] = st
    end
  end
  if #ahead == 0 or not CP.Replan(L["Step done ahead: "] .. CP.StepLine(ahead[1]) .. ". ") then return false end
  for _, st in ipairs(ahead) do CP.aheadSeen[Geo.StepKey(st)] = st.task.id end -- only once started
  return true
end

-- Steps on the spot first: the plan models a walk as a straight line, so it can leave a city and come
-- back later (or pass next to a step to do it much later). Steps of quest (never transports) that can be
-- done now are brought first when, from the player's position: in a city, they are in that city (before
-- any step outside it), anywhere else, they are within K.NEARBY_RADIUS. The Roadbook is then adapted
-- with them first (Geo.ApplyNearFirst). Only steps already in the Roadbook; nothing is added.
K.NEARBY_RADIUS = 150 -- yards: about one minute of detour at most
K.NEARBY_KINDS = { take = 1, skill = 2, obj = 2, turnin = 3, dungeon = 2 } -- quest steps, in order of a quest
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
  if not fz or not Geo.Tracking() or State.computing or CP.autoPending or Geo.ServicePending() then return end
  if CP.Busy() then return end
  local pos = PlayerPos()
  if not pos then return end
  local plevel = UnitLevel("player")
  local zone = Geo.ZoneIdAt(pos)
  local city = zone and ns.CITY_MAPS[zone] and zone or nil
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
  local msg = (city and L["Steps in this city first: "] or L["Step nearby first: "]) .. CP.StepLine(first) .. ". "
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

StaticPopupDialogs["FQP_QUEST_ABANDONED"] = {
  text = "%s",
  button1 = L["Remove from the list"],
  button2 = L["Pick it up again"],
  OnAccept = function(_, data)
    if data then CP.SkipQuest({ task = { id = data.id, title = data.title } }) end
  end,
  OnCancel = function(_, data) -- also Escape: the quest stays planned
    if data then CP.Replan(L["Quest abandoned, to pick up again: "] .. data.title .. ". ") end
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
-- Roadbook, its steps and their progress are kept (computed again only by the Recompute icon or a change of its list).
function CP.TrackOff(quiet)
  CP.StopFocus()
  if not quiet then Print(L["Tracking off: the Roadbook is only computed again by the Recompute icon or a change of its list. Turn the tracking on to follow it again."]) end
  C_Timer.After(0.1, Refresh)
end

-- Empties the Roadbook after confirmation: tracking stopped, steps and list emptied.
function CP.Empty()
  StaticPopup_Show("FQP_EMPTY")
end

function CP.DoEmpty()
  if State.computing then -- computation in progress: cancelled
    State.co, State.planCbs, State.computing = nil, nil, nil
    CP.computeToken = (CP.computeToken or 0) + 1
  end
  CP.TrackOff(true)
  if Geo.MapOwner() then Geo.MapRelease() end -- its preview ends
  Geo.ClearFrozen()
  Geo.ServiceClear()
  Geo.CustomSetList({}, true)
  State.customUnplanned = nil
  State.customToken = (State.customToken or 0) + 1 -- no pending recompute
  Print(L["Roadbook emptied."])
  Geo.SyncQuestLogButton()
  CP.RefreshButton()
  Refresh()
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
  MarkScanDirty() -- the levels scanned for the Roadbook follow the goal
  Refresh()
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
    if CP.RefuseWhileComputing() then return end -- one computation at a time: a request meanwhile is refused, not queued
    CP.computeToken = (CP.computeToken or 0) + 1
    token = CP.computeToken
    State.computing, State.computeStart = true, GetTime()
    Geo.SyncQuestLogButton() -- the list is locked
    if not keep then Geo.ClearFrozen() end
    Refresh()
    Guard(CP.RefreshButton) -- the Objective button waits
  end
  if token ~= CP.computeToken then return end -- deleted meanwhile
  -- Available quests change after a pick-up or turn-in: wait for their scan to finish.
  if goal ~= "custom" and WaitScan(attempt,
    function(n) CP.Recompute(goal, keep, n, token, re) end,
    function()
      State.computing = nil
      Guard(CP.RefreshButton)
      Geo.SyncQuestLogButton()
      Refresh()
    end) then
    return
  end
  local was = CP.CurrentFocus()
  Geo.Recompute(goal, function(route, err)
    local refocus = CP.focusAfter -- tracking (re)started during the computation
    CP.focusAfter = nil
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
    Print(L["Roadbook computed."])
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
    if now and not CP.SameStep(now, was) then Print(L["Focus: "] .. CP.StepLine(now)) end
  end, keep, re)
end

-- Skips a step with no quest (hearthstone, transport…): it is marked done; if it is the followed
-- one, the focus moves to the next step.
function CP.SkipStep(s)
  local followed = CP.CurrentFocus() == s
  Print(L["Step skipped: "] .. CP.StepLine(s))
  Geo.MarkDone(s)
  -- Transport skipped: the steps to come are planned again without it for the way to the next step
  -- (only this time: it can be proposed again later).
  if s.kind == "travel" then
    local fz, inside = Geo.Frozen(), false
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
    Refresh()
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
  Geo.CustomRemove(id)
end

-- Progress of a quest from the log: finished objectives (+1 if the quest is complete).
-- Every objective of the quest done (or the quest complete).
function CP.QuestObjectivesDone(qid)
  if not (qid and IsInLog(qid)) then return false end
  if IsQuestComplete(qid) then return true end
  local objs = GetObjectives(qid)
  for _, o in ipairs(objs) do if not o.finished then return false end end
  return #objs > 0
end

function CP.Progress(qid)
  if not (qid and IsInLog(qid)) then return 0 end
  local n = 0
  for _, o in ipairs(GetObjectives(qid)) do if o.finished then n = n + 1 end end
  if IsQuestComplete(qid) then n = n + 1 end
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
    Print(string.format(L["%s: next Roadbook step."], reason))
    local cur = CP.CurrentFocus()
    if cur then Geo.MarkDone(cur) end
    local ok, err = pcall(CP.FocusNext, true, cur)
    if not ok then Print(L["Focus update error: "] .. tostring(err)) end
  end)
end

-- Zeppelin / boat: arrived when near the destination dock (the continent change
-- happens at sea, during the loading screen: it is not enough).
K.ARRIVAL_RADIUS = 300
-- Arrived where the followed boat, zeppelin or teleport goes: the step is done (msg: what to say).
function CP.CheckArrival(s, msg)
  if not CP.TransportReached(s, PlayerPos()) then return end
  if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
  CP.AutoUpdate(msg)
end

-- The player stands at the place of the step (the NPC it is done with): a game event that does not
-- say which NPC it comes from ends the step only there.
K.AT_STEP_RADIUS = 100 -- yards
function CP.AtStep(s)
  local pos = PlayerPos()
  local d = pos and s.p and Dist(pos, s.p)
  return d ~= nil and d < K.AT_STEP_RADIUS
end

-- Transport step whose destination is reached at `pos`: bind point of a hearthstone step, arrival
-- of a flight / zeppelin / boat.
function CP.TransportReached(s, pos)
  local dest = s.kind == "hearth" and s.p or (s.kind == "travel" and s.task.destP)
  local d = pos and dest and Dist(pos, dest)
  return d ~= nil and d < (s.task.mode == "flight" and K.LANDING_RADIUS or K.ARRIVAL_RADIUS)
end

-- Watches the position every 2 s while a zeppelin / boat / hearthstone step has the focus.
function CP.WatchTransport(s)
  if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
  local watched = s.kind == "hearth" or (s.kind == "travel" and s.task.mode ~= "flight")
  if not (watched and C_Timer.NewTicker) then return end
  CP.transportTicker = C_Timer.NewTicker(2, function()
    if not (CP.focused == s and CP.IsStepFocused(s)) then
      if CP.transportTicker then CP.transportTicker:Cancel() CP.transportTicker = nil end
      return
    end
    Guard(CP.OnGameEvent, "FQP_TRANSPORT_TICK")
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
  if s.task.mode == "flight" and chosen and s.task.dest and chosen ~= s.task.dest and not CP.NearDest(chosen, s.task.destP) then
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
  if not (t and t.mode == "flight" and t.dest and pos) then return end
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
  for _ = fi, ti - 1 do Geo.RouteRemove(fz, fi) end
  local legs = {}
  if target and target.kind ~= "hearth" and not target.glue then
    -- flight paths known now (some may have been activated on the way)
    legs = Geo.LegSteps(Geo.World(), pos, target.p, Geo.Net(TravelSpeed()), UnitLevel("player"), st.at)
  end
  for k, leg in ipairs(legs) do Geo.RouteInsert(fz, fi + k - 1, leg) end
  Geo.SaveRoute()
  local first = legs[1]
  msg = msg or L["Wrong destination: new route. "]
  if first then
    Print(msg .. L["Focus: "] .. CP.StepLine(first))
    CP.FocusStep(first)
  elseif target then
    Print(msg .. L["Focus: "] .. CP.StepLine(target))
    CP.FocusStep(target)
  else
    CP.FocusNext(false)
  end
  C_Timer.After(0.2, Refresh)
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
    local route = fz.route
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
          Geo.RouteRemove(fz, i)
        end
      end
      Geo.SaveRoute()
      handled = true
      local msg = L["Quest giver found: "] .. (title or "?") .. ". "
      MarkScanDirty() -- the quest left the available ones: scanned again before the computation
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
    C_Timer.After(0.2, Refresh)
  end
  return handled
end

-- Auto mode (Settings().autoAdd): each quest accepted is proposed for the list, one window at a time.
function CP.SetAutoAdd(on)
  Settings().autoAdd = on and true or nil
  Print(on and L["Auto mode on: each quest you accept is proposed for the Roadbook list."]
    or L["Auto mode off."])
  Refresh()
  if Geo.MapPanelSync then Guard(Geo.MapPanelSync) end
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
  if State.computing then
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

---------------------------------------------------------------------------
-- What ends the followed step, by its kind: handler(step, event, a1, a2)
---------------------------------------------------------------------------
-- A quest turned in ends its step, whatever it is but a pick-up.
local function TurnedIn(s, event, a1, a2)
  local qid = s.task.id
  if event == "QUEST_TURNED_IN" and qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(L["Quest turned in"]) end
end

local STEP_EVENTS = {}

function STEP_EVENTS.bind(s, event)
  if event == "HEARTHSTONE_BOUND" and CP.AtStep(s) then CP.AutoUpdate(L["Hearthstone bound"]) end
end

function STEP_EVENTS.hearth(s, event, a1)
  if event == "FQP_HEARTH_ARRIVED" and tostring(a1 or "hearth") == tostring(s.via or "hearth") then
    CP.AutoUpdate(a1 and a1 ~= "hearth" and L["Teleport done"] or L["Back by hearthstone"])
  elseif event == "FQP_HEARTH_ARRIVED" or event == "ZONE_CHANGED_NEW_AREA" or event == "FQP_TRANSPORT_TICK" then
    CP.CheckArrival(s, L["Arrived at the hearthstone destination"])
  end
end

function STEP_EVENTS.travel(s, event)
  if event == "FQP_TAXI_TAKEOFF" then
    if s.task.mode == "flight" then CP.TakeOff(s) end
  elseif s.task.mode ~= "flight" and (event == "ZONE_CHANGED_NEW_AREA" or event == "FQP_TRANSPORT_TICK") then
    CP.CheckArrival(s, L["Arrival of the "] .. (K.MODE_NAME[s.task.mode] or s.task.mode or L["transport"]))
  end
end

function STEP_EVENTS.fm(s, event)
  if event == "TAXIMAP_OPENED" and (CP.StepDone(s) or CP.AtStep(s)) then CP.AutoUpdate(L["Flight master activated"]) end
end

function STEP_EVENTS.skill(s, event)
  if event == "SKILL_LINES_CHANGED" and CP.StepDone(s) then CP.AutoUpdate(L["Skill level reached"]) end
end

function STEP_EVENTS.service(s, event)
  if event == K.SERVICE_EVENTS[s.task.service or "vendor"] then
    Geo.ServiceClear() -- done: the next computations no longer plan it
    CP.AutoUpdate(L["Service done"])
  end
end

function STEP_EVENTS.dungeon(s, event)
  if (event == "QUEST_LOG_UPDATE" or event == "QUEST_TURNED_IN" or event == "QUEST_ACCEPTED") and CP.StepDone(s) then
    CP.AutoUpdate(L["Instance done"])
  end
end

function STEP_EVENTS.take(s, event, a1, a2)
  local qid = s.task.id
  if event == "QUEST_ACCEPTED" and qid and (a1 == qid or a2 == qid) then CP.AutoUpdate(L["Quest picked up"]) end
end

function STEP_EVENTS.obj(s, event, a1, a2)
  local qid = s.task.id
  if event == "QUEST_TURNED_IN" then
    TurnedIn(s, event, a1, a2)
  elseif event == "BAG_UPDATE_DELAYED" then
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

function CP.OnGameEvent(event, a1, a2)
  if event == "QUEST_ACCEPTED" then Guard(CP.AutoAddAccepted, a1, a2) end
  if event == "QUEST_LOG_UPDATE" and CP.checkpointButton then C_Timer.After(0.2, function() Guard(CP.RefreshButton) end) end
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
    if a1 then C_Timer.After(1, function() Guard(CP.QuestRemoved, a1) end) end
    return
  end
  if event == "QUEST_ACCEPTED" and CP.GiverFound(a1, a2) then return end
  if event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED" or event == "QUEST_TURNED_IN" then
    Guard(CP.ScheduleRecallCheck, 3) -- steps done ahead (CP.AheadCheck)
  end
  local s = CP.CurrentFocus()
  if not s then return end
  if event == "FQP_TAXI_TAKEOFF" then CP.flying, CP.flightStep = true, nil end
  local qid = s.task.id
  if s.escort and event == "QUEST_LOG_UPDATE" and CP.IsFailed(qid) then
    CP.EscortFailed(s)
    return
  end
  (STEP_EVENTS[s.kind] or TurnedIn)(s, event, a1, a2) -- (turn-in steps: TurnedIn)
end

-- Shared with the next files.
ns.CP = CP
