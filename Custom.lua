-- Forever Quest Planner: custom Roadbook: quests chosen by the player, fastest route to do them all.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, BuildScanContext, CharKey, DBXP = ns.AreaName, ns.BuildScanContext, ns.CharKey, ns.DBXP
local Geo, GiverText, HasBit, IsCompleted, IsInLog, K = ns.Geo, ns.GiverText, ns.HasBit, ns.IsCompleted, ns.IsInLog, ns.K
local L, MakeStops, PlayerPos, Print, QDB = ns.L, ns.MakeStops, ns.PlayerPos, ns.Print, ns.QDB
local QGet, QuestTargets, RemainingTargets, Settings, TravelSpeed = ns.QGet, ns.QuestTargets, ns.RemainingTargets, ns.Settings, ns.TravelSpeed
local QuestPrereqs = ns.QuestPrereqs
local Color, PlayerFaction, QuestDoubts = ns.Color, ns.PlayerFaction, ns.QuestDoubts
local State = ns.State
local PlayerBits = ns.PlayerBits
local QuestAllowed = ns.QuestAllowed

K.DUNGEON_TIME = 60       -- minutes spent inside a dungeon (setting)
K.DUNGEON_WAVE_DEPTH = 20 -- safety: dungeon visits following one another
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

-- Service shortcut (vendor, repair, class trainer) waiting to be done: the NPC chosen, first step of
-- the Roadbook until done. Saved per character: { kind, id, name, p }.
function Geo.ServicePending()
  return Settings().service
end

function Geo.ServiceSet(e)
  Settings().service = e and { kind = e.kind, id = e.id, name = e.name, p = Geo.CopyPoint(e.p) } or nil
end

function Geo.ServiceClear()
  Geo.ServiceSet(nil)
end

-- Game step of the pending service, or nil.
function Geo.ServiceStep()
  local sv = Geo.ServicePending()
  if not (sv and sv.p) then return nil end
  local title = sv.kind
  for _, def in ipairs(K.SERVICES) do if def.key == sv.kind then title = def.title end end
  return { kind = "service", p = Geo.CopyPoint(sv.p), work = K.SERVICE_TIME,
    task = { title = title .. (sv.name or "?"), npc = sv.name, npcId = sv.id, service = sv.kind, xp = 0 } }
end

-- The Roadbook is tracked (a step is focused); not tracked otherwise.
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
end

-- Versions with an automatic Roadbook (its quests chosen at each computation): it becomes the
-- Roadbook of a list, its quests not turned in yet, with the steps done kept.
function Geo.MigrateAutoRoadbook()
  local st = Settings()
  local rec = st.roadbook and st.roadbook[CharKey()]
  if not (rec and rec.info) or rec.info.custom then return end
  local list, seen = {}, {}
  local function add(id, title, level)
    if not id or seen[id] or IsCompleted(id) then return end
    seen[id] = true
    list[#list + 1] = { id = id, title = title or ("#" .. id), level = level }
  end
  for _, s in ipairs(rec.steps or {}) do
    local t = s.task or {}
    if s.kind == "take" or s.kind == "obj" or s.kind == "turnin" then add(t.id, t.title, t.level) end
    for _, m in ipairs(s.members or {}) do add(m.id, m.title, m.level) end
  end
  Geo.CustomSetList(list, true)
  rec.info.custom = true
  rec.info.goal, rec.info.goalStage, rec.info.generated, rec.excluded = nil, nil, nil, nil
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
  return QuestAllowed(id, PlayerBits())
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
  local group, single = QuestPrereqs(id)
  for _, p in ipairs(group) do
    if not (IsCompleted(p) or seen[p]) then add(p) end
  end
  if #single > 0 then
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

-- The only place that puts quests into the list: the new list replaces the old one. A quest that is new in
-- it and whose QuestieDB data contradict each other (QuestDoubts) is announced, once for everything added
-- by the same action (one quest and its prerequisites, "Add all", a chain, a generated Roadbook).
-- silent: no announcement (lists rebuilt, not added to).
function Geo.CustomSetList(list, silent)
  local rec = Geo.CustomRec()
  if not silent then
    local old = {}
    for _, e in ipairs(rec.list) do old[e.id] = true end
    local faction = PlayerFaction()
    for _, e in ipairs(list) do
      local why = not old[e.id] and QuestDoubts(e.id, faction)
      if why then
        Geo.doubtPending = Geo.doubtPending or {}
        Geo.doubtPending[#Geo.doubtPending + 1] = (e.title or QGet(QDB.Quest, e.id, "name") or ("#" .. e.id)) ..
          " (" .. table.concat(why, " ; ") .. ")"
      end
    end
    if Geo.doubtPending and not Geo.doubtScheduled then
      Geo.doubtScheduled = true
      C_Timer.After(0, function()
        local pending = Geo.doubtPending
        Geo.doubtPending, Geo.doubtScheduled = nil, nil
        if pending then
          Print(Color(K.DESC and K.DESC.warn or "ffb060", L["Warning: the QuestieDB data of these quests contradict each other: "]) ..
            table.concat(pending, " | "))
        end
      end)
    end
  end
  rec.list = list
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
  local list, pre = {}, 0
  for _, e in ipairs(Geo.CustomRec().list) do list[#list + 1] = e end
  local added = {}
  for _, p in ipairs(Geo.MissingPrereqs(id)) do
    if not Geo.InCustom(p) and not added[p] then
      added[p] = true
      list[#list + 1] = { id = p, title = QGet(QDB.Quest, p, "name") or ("#" .. p), level = Geo.QuestLevelOf(p), pre = id }
      pre = pre + 1
    end
  end
  list[#list + 1] = { id = id, title = title, level = level or Geo.QuestLevelOf(id) }
  Geo.CustomSetList(list)
  Geo.Trace("list", "added " .. id .. " " .. title .. (pre > 0 and (" (+" .. pre .. " prerequisite)") or ""))
  if quiet then return true, pre end
  Print(L["Added to the Roadbook list: "] .. title ..
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
  Print(string.format(L["%d quest(s) added to the Roadbook list"], added) ..
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
  Geo.Trace("list", "removed " .. tostring(id) .. " " .. tostring(e.title))
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
  Print(L["Removed from the Roadbook list: "] .. (e.title or tostring(id)) ..
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
  Print(string.format(L["%d quest(s) removed from the Roadbook list"], n) ..
    (extra > 0 and string.format(L[" (and %d prerequisite quest(s))"], extra) or ""))
  if n > 0 then Geo.CustomChanged() end
end

---------------------------------------------------------------------------
-- Quest chains: a quest and all its follow-ups
---------------------------------------------------------------------------
K.MAX_CHAIN = 40 -- safety: follow-ups walked

-- Follow-ups of a quest (recursively, in the order of the chain), the ones for the character's class and
-- race and not turned in yet. Of quests that exclude each other, only the first is kept.
-- Returns { { id, title, level, reqLevel } }.
function Geo.ChainQuests(id)
  Geo.chainCache = Geo.chainCache or {}
  local raw = Geo.chainCache[id]
  if not raw then
    raw = {}
    local m = ns.QuestMeta(id)
    if m then
      local seen, queue, i = { [id] = true }, {}, 1
      local function push(c)
        local nm = ns.QuestMeta(c)
        if nm then
          for _, q in ipairs(ns.NextQuests(nm)) do
            if not seen[q] then
              seen[q] = true
              queue[#queue + 1] = q
            end
          end
        end
      end
      push(id)
      while i <= #queue and i <= K.MAX_CHAIN do
        raw[#raw + 1] = queue[i]
        push(queue[i])
        i = i + 1
      end
    end
    Geo.chainCache[id] = raw
  end
  local out, taken = {}, {}
  for _, q in ipairs(raw) do
    local ok = not IsCompleted(q) and Geo.ForPlayer(q)
    if ok then
      local excl = QGet(QDB.Quest, q, "exclusiveTo")
      if type(excl) == "table" then
        for _, x in ipairs(excl) do
          if taken[x] or IsCompleted(x) or Geo.InCustom(x) then ok = false break end
        end
      end
    end
    if ok then
      taken[q] = true
      out[#out + 1] = { id = q, title = QGet(QDB.Quest, q, "name") or ("#" .. q), level = Geo.QuestLevelOf(q),
        reqLevel = QGet(QDB.Quest, q, "requiredLevel") or 0 }
    end
  end
  return out
end

-- Can the quests ids (with their prerequisites) be added to the list: can the XP of the quests of the
-- list reach the levels they require? Returns nil, or { id, need, reach } for the first quest blocked.
function Geo.ChainLevelCheck(ids)
  local set, order = {}, {}
  local function add(q)
    if not set[q] and not IsCompleted(q) then
      set[q] = true
      order[#order + 1] = q
    end
  end
  for _, e in ipairs(Geo.CustomList()) do add(e.id) end
  for _, q in ipairs(ids) do
    for _, p in ipairs(Geo.MissingPrereqs(q)) do add(p) end
    add(q)
  end
  local quests = {}
  for _, q in ipairs(order) do
    local all, any = QuestPrereqs(q)
    local pres, anyPres, met = {}, {}, false
    for _, p in ipairs(all) do if set[p] and p ~= q then pres[#pres + 1] = p end end
    for _, p in ipairs(any) do
      if IsCompleted(p) then met = true
      elseif set[p] and p ~= q then anyPres[#anyPres + 1] = p end
    end
    quests[#quests + 1] = { id = q, row = QDB.xp[q], reqLevel = QGet(QDB.Quest, q, "requiredLevel") or 0,
      pres = pres, anyPres = not met and #anyPres > 0 and anyPres or nil, inLog = IsInLog(q) }
  end
  return ns.Solver.LevelReach({ level = UnitLevel("player"), xp = UnitXP("player"), xpNeeded = Geo.XPNeededTable(),
    maxLevel = Geo.MaxLevel() }, quests)
end

-- Adds a quest and all its follow-ups, unless the levels they require cannot be reached with the
-- quests of the list (nothing is added then).
function Geo.CustomAddChain(id, title, level)
  local chain = Geo.ChainQuests(id)
  local ids = { id }
  for _, c in ipairs(chain) do ids[#ids + 1] = c.id end
  local bad = Geo.ChainLevelCheck(ids)
  if bad then
    Print(string.format(L["Chain refused: \"%s\" requires level %d, the quests of the list only reach level %d."],
      QGet(QDB.Quest, bad.id, "name") or ("#" .. bad.id), bad.need, bad.reach))
    return false
  end
  local added, pre = 0, 0
  local ok, p = Geo.CustomAdd(id, title, level, true)
  if ok then added, pre = added + 1, pre + p end
  for _, c in ipairs(chain) do
    ok, p = Geo.CustomAdd(c.id, c.title, c.level, true)
    if ok then added, pre = added + 1, pre + p end
  end
  Print(string.format(L["%d quest(s) of the chain added to the Roadbook list"], added) ..
    (pre > 0 and string.format(L[" (+%d prerequisite quest(s))"], pre) or ""))
  if added > 0 then Geo.CustomChanged() end
  return added > 0
end

function Geo.CustomRemoveChain(id)
  local list = { { id = id } }
  for _, c in ipairs(Geo.ChainQuests(id)) do list[#list + 1] = { id = c.id } end
  Geo.CustomRemoveList(list)
end

-- The list cannot change while the Roadbook is computed (the computation would be on a list that no
-- longer exists): the user's changes are refused with a message. Returns true when locked.
function Geo.ListLocked()
  if not State.computing then return false end
  Print(L["The Roadbook is being computed: its list can be changed when it is ready."])
  return true
end

-- List changed: the Roadbook is computed again (grouped when several quests are added in a row), its
-- steps done and its tracking kept (tracked or not); empty list: the steps to come
-- are removed and its tracking stops, the steps done stay (only "Empty" empties them).
function Geo.CustomChanged()
  State.customToken = (State.customToken or 0) + 1
  local token = State.customToken
  if #Geo.CustomList() == 0 then
    State.customUnplanned = nil
    Geo.ServiceClear()
    if ns.CP then ns.CP.TrackOff(true) end
    if not Geo.KeepOnlyDone() then Geo.ClearFrozen() end
  else
    C_Timer.After(0.6, function()
      if token == State.customToken and ns.CP then ns.CP.Recompute("custom", true) end
    end)
  end
  if ns.Refresh then ns.Refresh() end
  Geo.SyncQuestLogButton()
end

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
      if unmatched > 0 then
        -- Nothing left to do at known places: the quest is not done, so it is not offered for turn-in.
        if #task.remaining == 0 then return nil, L["an objective is not located"] end
        task.warn = L["an objective is not located"]
      end
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
    task.skillNeed = need -- a step "raise the skill" comes before the turn-in (MakeStops)
  end
  task.stops = MakeStops(task, pos, plevel)
  if not task.stops then return nil, L["not located"] end
  return task
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
    if depth < K.DUNGEON_WAVE_DEPTH then
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

-- Identity of a quest step (game step of the plan or of the saved route): kind, quest (or dungeon), target.
function Geo.StepKey(st)
  local t = st.task or {}
  return st.kind .. ":" .. tostring(t.id or t.dungeon) .. ":" .. tostring(st.r and st.r.tg and st.r.tg.name)
end

-- Steps on the spot first (CP.NearbyCheck): near = { keys = StepKey of the steps wanted first, city = uiMapID
-- of the city the player is in, or nil }. The steps wanted that can be done without any other step
-- (their order rules reach only wanted steps; a glued chain whole) become order rules of every other
-- step (outside the city if any): they come first. The pending service stays first.
function Geo.ApplyNearFirst(tasks, steps, pred, near, svc)
  local chosen, link = {}, {}
  for _, s in ipairs(steps) do
    if s ~= svc and near.keys[Geo.StepKey(s)] then chosen[s] = true end
  end
  for _, task in ipairs(tasks) do
    for k = 2, #task.order do
      local s = task.order[k]
      if s.glue then
        local a = task.order[k - 1]
        link[s] = link[s] or {}
        link[a] = link[a] or {}
        table.insert(link[s], a)
        table.insert(link[a], s)
      end
    end
  end
  local changed = true
  while changed do
    changed = false
    for _, s in ipairs(steps) do
      if chosen[s] then
        local ok = true
        for _, p in ipairs(pred[s] or {}) do if not chosen[p] then ok = false end end
        for _, g in ipairs(link[s] or {}) do if not chosen[g] then ok = false end end
        if not ok then
          chosen[s] = nil
          changed = true
        end
      end
    end
  end
  local first = {}
  for _, s in ipairs(steps) do if chosen[s] then first[#first + 1] = s end end
  if #first == 0 then return 0 end
  for _, t in ipairs(steps) do
    if not chosen[t] and t ~= svc and t.p and (not near.city or Geo.ZoneIdAt(t.p) ~= near.city) then
      pred[t] = pred[t] or {}
      for _, s in ipairs(first) do table.insert(pred[t], s) end
    end
  end
  return #first
end

-- Fastest route doing every quest of the list (solver): dungeon visits, order rules (pick-up first,
-- turn-in last, prerequisites before), required levels (a quest picked up below it gets a warning,
-- an order rule that cannot be kept too), teleports, binds and flight paths activated on the way.
function Geo.PlanCustom(opts)
  local pos = PlayerPos()
  if not pos then return nil, L["Unknown position (in an instance or map unavailable)."] end
  local cp, err, unplanned = Geo.CustomPlanSteps(pos, UnitLevel("player"), opts and opts.near)
  State.customUnplanned = cp and cp.unplanned or unplanned or {}
  if not cp then return nil, err end
  local P = Geo.Problem("custom", pos, cp)
  P.ban = opts and opts.ban
  local opt = Geo.Solve(P, "custom")
  local route, info = Geo.ListRoute(P, opt)
  info.skipped, info.unplanned = #cp.unplanned, cp.unplanned
  return route, nil, info
end

-- Game route of a solver result with a list: warnings (quest picked up below its required level,
-- order rule of the list not kept), dungeon visits and flight paths activated counted.
function Geo.ListRoute(P, opt)
  for _, v in ipairs(opt.res.violations) do
    local s = v.kind == "level" and opt.route[v.i].src
    if s and s.task then s.task.levelWarn = true end
  end
  for _, s in ipairs(P.custom and P.custom.steps or {}) do
    if s.relaxed and s.src and s.src.task then s.src.task.orderWarn = true end
  end
  local route, info = Geo.FromSolver(P, opt.route, opt.res)
  local discovered, dungeons = 0, 0
  for _, st in ipairs(route) do
    if st.kind == "fm" then discovered = discovered + 1 end
    if st.kind == "dungeon" then dungeons = dungeons + 1 end
  end
  info.custom, info.dungeons, info.discovered, info.later = true, dungeons, discovered, {}
  Geo.TraceService(route)
  return route, info
end

-- Trace of the plan of a service shortcut: the steps up to the service step (transports, teleports,
-- flight paths activated on the way), each with its time since the start.
function Geo.TraceService(route)
  local sv = Geo.ServicePending()
  if not sv then return end
  local parts = {}
  for i = 2, #route do
    local st = route[i]
    parts[#parts + 1] = string.format("%s %s @%ds", tostring(st.kind), tostring(st.task and st.task.title or "?"), st.at or 0)
    if st.kind == "service" then break end
  end
  local p = route[1].p or {}
  Geo.Trace("service", string.format("%s -> %s; start c%s %d,%d; known flight paths %d; steps: %s", tostring(sv.kind),
    tostring(sv.name), tostring(p.c), p.x or 0, p.y or 0, ns.TaxiCount and ns.TaxiCount() or -1, table.concat(parts, " | ")))
end

-- "Adapt" with a duration or level (goal): the list (if any) kept whole and completed with the
-- quests serving the goal best, or, when it alone goes beyond the goal, only its part serving it best
-- (Solver.Optimize). The quests of the list that cannot be located stay in it, unplanned.
function Geo.PlanGenerate(goal, opts)
  Geo.PreloadRewardItems()
  local pos = PlayerPos()
  if not pos then return nil, L["Unknown position (in an instance or map unavailable)."] end
  local plevel = UnitLevel("player")
  if plevel >= Geo.MaxLevel() then
    return nil, L["Max level reached: no more XP to earn."]
  end
  local cp, unplanned
  if #Geo.CustomList() > 0 or Geo.ServicePending() then
    local _, u
    cp, _, u = Geo.CustomPlanSteps(pos, plevel)
    unplanned = cp and cp.unplanned or u
  end
  local P = Geo.Problem("auto", pos, cp)
  P.ban = opts and opts.ban
  local opt = Geo.Solve(P, goal)
  local route, info = Geo.ListRoute(P, opt)
  info.later, info.unplanned = P.later, unplanned
  return route, nil, info
end

-- Quests of a generated route, in route order (dungeon visits: their quests), then the unplanned
-- quests of the list: the new list. An entry already in the list keeps its fields.
function Geo.ListFromRoute(route, unplanned)
  local old = {}
  for _, e in ipairs(Geo.CustomList()) do old[e.id] = e end
  local out, seen = {}, {}
  local function add(id, title, level)
    if not id or seen[id] or IsCompleted(id) then return end
    seen[id] = true
    out[#out + 1] = old[id] or { id = id, title = title or QGet(QDB.Quest, id, "name") or ("#" .. id), level = level or Geo.QuestLevelOf(id) }
  end
  for i = 2, #route do
    local st = route[i]
    if st.kind == "dungeon" then
      for _, m in ipairs(st.task.members or {}) do add(m.task and m.task.id, m.task and m.task.title, m.task and m.task.level) end
    elseif st.task then
      add(st.task.id, st.task.title, st.task.level)
    end
  end
  for _, u in ipairs(unplanned or {}) do add(u.id, u.title) end
  for _, e in ipairs(out) do
    if e.pre and not seen[e.pre] then e.pre = nil end -- added for a quest no longer in the list
  end
  return out
end

-- Generated Roadbook: the list becomes its quests (after a confirmation when quests of the list
-- leave it), then it is saved. done(accepted).
-- prepare(route): optional, returns the route to save (the steps done of the former Roadbook put first).
function Geo.AcceptGenerated(route, info, done, prepare)
  local list = Geo.ListFromRoute(route, info.unplanned)
  local keep, dropped = {}, 0
  for _, e in ipairs(list) do keep[e.id] = true end
  for _, e in ipairs(Geo.CustomList()) do
    if not keep[e.id] then dropped = dropped + 1 end
  end
  local function apply()
    Geo.CustomSetList(list)
    State.customToken = (State.customToken or 0) + 1 -- no pending recompute of the former list
    State.customUnplanned = info.unplanned
    Geo.Freeze(prepare and prepare(route) or route, info)
    Geo.SyncQuestLogButton()
    done(true)
  end
  if dropped == 0 then
    apply()
  else
    StaticPopup_Show("FQP_TRIM_LIST", dropped, nil, { apply = apply, done = done })
  end
end

StaticPopupDialogs["FQP_TRIM_LIST"] = {
  text = L["%d quest(s) of your list do not fit this goal: they leave the list.\n\nKeep the new Roadbook?"],
  button1 = YES or L["Yes"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, data) if data then data.apply() end end,
  OnCancel = function(_, data) if data then data.done(false) end end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}
