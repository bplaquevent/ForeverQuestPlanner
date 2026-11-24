-- Forever Quest Planner: the Roadbook problem, read from the game for the solver (Solver.lua): world
-- (flight network, docks, passes, innkeepers, flight masters, ways back), character, candidate quests
-- and their follow-ups (automatic Roadbook) or the custom list with its order rules.
-- Built for the planning in game (Geo.Problem, live: each step keeps its game step in `src`) and
-- captured by /fqp dump into ForeverQuestPlannerBench for the offline test bench (tools/bench.lua):
-- plain tables only, with the map of the zones around the points (the bench has no map API).

local ADDON_NAME, ns = ...
local BuildScanContext, BuildTasks, CharKey, Geo, K, L = ns.BuildScanContext, ns.BuildTasks, ns.CharKey, ns.Geo, ns.K, ns.L
local OM, PlayerPos, Print, QDB, QGet, Settings = ns.OM, ns.PlayerPos, ns.Print, ns.QDB, ns.QGet, ns.Settings
local AllPrereqs = ns.AllPrereqs
local StartScan, State, TravelSpeed, UnitTime, scan = ns.StartScan, ns.State, ns.TravelSpeed, ns.UnitTime, ns.scan

local Pb = {}
K.BENCH_VERSION = 2
K.BENCH_MAX_TASKS = 2000 -- safety: candidate quests and follow-ups, at most
K.BENCH_MARGIN = 2       -- capture: map cells added around the points
K.SPOT_ALTS = 8          -- hunting spots offered to the solver for an objective (the densest ones)

function Pb.Point(p)
  if not p then return nil end
  return { c = p.c, x = p.x, y = p.y, area = p.area, ui = p.ui, mx = p.mx, my = p.my, zoneName = p.zoneName,
    instance = p.instance, teleport = p.teleport, cast = p.cast }
end

-- Hunting spots of an objective step (monsters to kill or to loot): the densest ones, each with the
-- time it takes there (density: less walking between fights). The solver picks the one costing the
-- least with the route around it (detour + hunting). nil: one place only.
function Pb.Spots(st, live)
  local r = st.r
  if st.kind ~= "obj" or st.escort or not (r and r.tg and r.tg.mobIds) then return nil end
  local spots = Geo.Spots(r.tg)
  if not spots or #spots < 2 then return nil end
  local kills = r.tg.kind == "item" and r.count * Geo.KillsPerItem(r.tg) or r.count
  local out = {}
  for i = 1, math.min(#spots, K.SPOT_ALTS) do
    local sp = spots[i]
    out[i] = { p = Pb.Point(sp.p), n = sp.n, work = r.count * UnitTime(r.tg) * Geo.SpotFactor(sp, kills),
      spot = live and sp or nil }
  end
  return out
end

-- A route step or a quest step: what the solver needs to evaluate it. live: keeps the game step (src).
function Pb.Step(st, live)
  local t = st.task or {}
  local o
  if st.r and st.r.tg then
    local tg = st.r.tg
    local kills = (tg.kind == "item" and st.r.count * Geo.KillsPerItem(tg)) or (tg.kind == "kill" and st.r.count) or nil
    o = { kind = tg.kind, name = tg.name, count = st.r.count, kills = kills, mobLevel = tg.mobLevel,
      elite = tg.elite or nil, rate = tg.rate, fixed = st.afterSource or nil }
  end
  local members
  if st.kind == "dungeon" and t.members then
    members = {}
    for _, m in ipairs(t.members) do members[#members + 1] = Pb.Step(m) end
  end
  return { kind = st.kind, p = Pb.Point(st.p), work = st.work, xp = st.xp, id = t.id, title = t.title, obj = o,
    glue = st.glue or nil, escort = st.escort or nil, via = st.via, bindDest = st.bindDest,
    fmNode = st.fmNode or (st.fmHub and st.fmHub.node) or nil, legacyFM = st.fmHub and true or nil,
    spotN = st.spot and st.spot.n, at = st.at, search = st.search, mode = t.mode, members = members, inside = st.inside and true or nil,
    reqLevel = st.kind == "take" and not t.levelWarn and t.reqLevel or nil, src = live and st or nil,
    spots = Pb.Spots(st, live) }
end

function Pb.Task(task, n, dep, live)
  local stops = {}
  for _, s in ipairs(task.stops or {}) do stops[#stops + 1] = Pb.Step(s, live) end
  return { n = n, id = task.id, title = task.title, kind = task.kind, level = task.level, xp = task.xp,
    value = task.value, mobXP = task.mobXP, reqLevel = task.reqLevel, quick = task.quick, depth = task.depth,
    dep = dep, starter = task.starter, escort = task.id and Geo.IsEscort(task.id) or nil, stops = stops }
end

-- Quest level and base XP (QuestieDB) of every quest met, for the XP at any player level.
function Pb.AddQuest(P, id, title)
  if not id or P.quests[id] then return end
  local row = QDB.xp and QDB.xp[id]
  P.quests[id] = { title = title, qLevel = row and row[1], baseXP = row and row[2],
    reqLevel = QGet(QDB.Quest, id, "requiredLevel") }
end

-- Candidate quests of the automatic Roadbook (quest log, available ones) and, depth first, every
-- follow-up they unlock (dep = number of the quest it follows).
function Pb.Tasks(P, pos, plevel, live)
  local t0 = debugprofilestop()
  Geo.laterList, Geo.laterCache = {}, {}
  local tasks, skipped = BuildTasks(pos, plevel)
  local ctx = BuildScanContext()
  local list = {}
  local function add(task, dep)
    if #list >= K.BENCH_MAX_TASKS then return end
    local n = #list + 1
    list[n] = Pb.Task(task, n, dep, live)
    Pb.AddQuest(P, task.id, task.title)
    for _, f in ipairs(Geo.Followers(task, ctx, plevel)) do add(f, n) end
    Geo.Yield()
  end
  for _, task in ipairs(tasks) do add(task, nil) end
  P.tasks, P.skipped, P.later = list, skipped, Geo.laterList
  P.buildSeconds = (debugprofilestop() - t0) / 1000 -- wall time, frames included
end

-- Custom list as the game plans it: its quests, dungeon visits and order rules.
-- near: steps on the spot first (Geo.ApplyNearFirst).
-- Returns { tasks, steps, pred, dungeons, unplanned } (game objects), or nil and the reason.
function Geo.CustomPlanSteps(pos, plevel, near)
  local list = Geo.CustomList()
  local svc = Geo.ServiceStep()
  if #list == 0 and not svc then return nil, L["The list is empty: add quests with the \"Add\" button of the other tabs, or choose a session or a level."] end
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
  if #tasks == 0 and not svc then return nil, L["No quest of the list can be located."], unplanned end
  for _, task in ipairs(tasks) do
    task.pres = {}
    for _, p in ipairs(AllPrereqs(task.id)) do
      if byId[p] and byId[p] ~= task then task.pres[#task.pres + 1] = byId[p] end
    end
  end
  local dungeons = Geo.GroupDungeons(tasks)
  local pred = Geo.CustomConstraints(tasks)
  local steps, seen = {}, {}
  if svc then steps[1] = svc end -- service shortcut: before every other step
  for _, task in ipairs(tasks) do
    for _, s in ipairs(task.order) do
      if not seen[s] then
        seen[s] = true
        steps[#steps + 1] = s
      end
    end
  end
  if near then Geo.ApplyNearFirst(tasks, steps, pred, near, svc) end -- steps on the spot first
  if svc then
    for i = 2, #steps do
      pred[steps[i]] = pred[steps[i]] or {}
      table.insert(pred[steps[i]], svc)
    end
  end
  return { tasks = tasks, steps = steps, pred = pred, dungeons = dungeons, unplanned = unplanned, service = svc }
end

-- The custom list for the solver: steps (ci = index, ti = quest index, glueTo = the step it follows
-- right away), order rules by index.
function Pb.Custom(P, cp, live)
  local out = { tasks = {}, steps = {}, pred = {}, unplanned = cp.unplanned }
  local ci, ti = {}, {}
  for i, task in ipairs(cp.tasks) do
    ti[task] = i
    out.tasks[i] = { id = task.id, title = task.title, xp = task.xp }
    Pb.AddQuest(P, task.id, task.title)
  end
  for i, s in ipairs(cp.steps) do
    local st = Pb.Step(s, live)
    st.ci = i
    st.ti = s.kind ~= "dungeon" and ti[s.task] or nil
    out.steps[i] = st
    ci[s] = i
  end
  for _, task in ipairs(cp.tasks) do
    for k = 2, #task.order do
      local s = task.order[k]
      if s.glue and ci[s] then out.steps[ci[s]].glueTo = ci[task.order[k - 1]] end
    end
  end
  for s, list in pairs(cp.pred) do
    if ci[s] then
      local l = {}
      for _, p in ipairs(list) do
        if ci[p] then l[#l + 1] = ci[p] end
      end
      out.pred[ci[s]] = l
    end
  end
  -- Objectives of a quest (outside dungeons): talking, events, places, escorts keep their place among
  -- them; the others in any order (Solver.Ranks).
  for _, task in ipairs(cp.tasks) do
    local objs = {}
    for _, s in ipairs(task.stops or {}) do
      if s.kind == "obj" and ci[s] then objs[#objs + 1] = out.steps[ci[s]] end
    end
    ns.Solver.Ranks(objs)
    for _, a in ipairs(objs) do
      for _, b in ipairs(objs) do
        if b.rank < a.rank then
          out.pred[a.ci] = out.pred[a.ci] or {}
          table.insert(out.pred[a.ci], b.ci)
        end
      end
    end
  end
  out.first = cp.service and ci[cp.service] or nil -- service shortcut: always the first step
  P.custom = out
end

-- Flight network, docks, passes, innkeepers, flight masters, ways back, bind location.
-- live: zones read from the map when needed; otherwise the passes are copied (plain tables).
function Pb.World(P, live)
  local w = {}
  local known = Geo.KnownNodes()
  local usable = {}
  w.nodes = {}
  for id in pairs(OM.flights.nodes) do
    if Geo.NodeUsable(id) then
      usable[id] = true
      w.nodes[#w.nodes + 1] = { id = id, name = Geo.NodeName(id), p = Geo.NodePoint(id), known = known[id] or nil }
    end
  end
  table.sort(w.nodes, function(a, b) return a.id < b.id end)
  w.edges = {}
  for _, e in ipairs(OM.flights.paths) do
    if usable[e[1]] and usable[e[2]] then w.edges[#w.edges + 1] = { e[1], e[2], e[3] } end
  end
  local dk = Geo.Docks()
  w.docks, w.links = {}, {}
  for _, d in ipairs(dk.docks) do w.docks[#w.docks + 1] = { name = d.name, p = Pb.Point(d.p) } end
  for _, l in ipairs(dk.links) do w.links[#w.links + 1] = { l[1], l[2], l[3] } end
  if live then
    w.passes = Geo.Passes()
  else
    w.passes = {}
    for _, ps in ipairs(Geo.Passes()) do w.passes[#w.passes + 1] = { c = ps.c, x = ps.x, y = ps.y, a = ps.a, b = ps.b } end
  end
  w.inns = {}
  for _, inn in ipairs(Geo.Innkeepers()) do w.inns[#w.inns + 1] = { id = inn.id, name = inn.name, p = Pb.Point(inn.p) } end
  w.fms = {}
  for _, fm in ipairs(Geo.FlightMasters()) do
    w.fms[#w.fms + 1] = { id = fm.id, node = fm.node, name = fm.name, p = Pb.Point(fm.p) }
  end
  w.recall = {}
  for _, s in ipairs(Geo.RecallSources()) do
    w.recall[#w.recall + 1] = { key = s.key, bind = s.bind or nil, p = Pb.Point(s.p), cast = s.cast, cd = s.cd,
      ready = s.ready, charges = s.charges, spell = s.spell, name = s.name }
  end
  local bind, bindName = Geo.CurrentBind()
  w.bind, w.bindName = Pb.Point(bind), bindName
  if live then
    -- Zone of a point (map API, cached by Geo.ZoneIdAt) and its levels (OpenMap), read when needed.
    w.zoneAt = function(p) return (Geo.ZoneIdAt(p)) end
    w.zones = setmetatable({}, { __index = function(t, id)
      local lv = OM.levels[id]
      local z = { min = lv and lv[1], max = lv and lv[2] }
      t[id] = z
      return z
    end })
  end
  P.world = w
end

-- Every point of a capture, by continent.
function Pb.Points(P)
  local out = {}
  local function add(p)
    if p and p.c and p.x then
      out[p.c] = out[p.c] or {}
      table.insert(out[p.c], p)
    end
  end
  local function addSteps(list)
    for _, s in ipairs(list or {}) do
      add(s.p)
      addSteps(s.members)
    end
  end
  local w = P.world
  for _, n in ipairs(w.nodes) do add(n.p) end
  for _, d in ipairs(w.docks) do add(d.p) end
  for _, ps in ipairs(w.passes) do add(ps) end
  for _, inn in ipairs(w.inns) do add(inn.p) end
  for _, fm in ipairs(w.fms) do add(fm.p) end
  for _, s in ipairs(w.recall) do add(s.p) end
  add(w.bind)
  add(P.player.pos)
  for _, t in ipairs(P.tasks or {}) do addSteps(t.stops) end
  addSteps(P.custom and P.custom.steps)
  for _, b in pairs(P.baseline or {}) do addSteps(b.route) end
  return out
end

-- Capture: zone of every map cell (K.ZONE_CELL yards) of the box holding the points, per continent:
-- rows of "zone*count" runs (zone uiMapID, 0 = none), with the zones' level ranges.
function Pb.Grid(P)
  local cell = K.ZONE_CELL
  local grid, zones, cells = {}, {}, 0
  for c, pts in pairs(Pb.Points(P)) do
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(pts) do
      x0, x1 = math.min(x0, p.x), math.max(x1, p.x)
      y0, y1 = math.min(y0, p.y), math.max(y1, p.y)
    end
    local ix0, ix1 = math.floor(x0 / cell) - K.BENCH_MARGIN, math.floor(x1 / cell) + K.BENCH_MARGIN
    local iy0, iy1 = math.floor(y0 / cell) - K.BENCH_MARGIN, math.floor(y1 / cell) + K.BENCH_MARGIN
    local rows = {}
    for iy = iy0, iy1 do
      local runs, cur, n = {}, nil, 0
      for ix = ix0, ix1 do
        -- Not cached (many cells).
        local id, name = Geo.ZoneIdRaw({ c = c, x = (ix + 0.5) * cell, y = (iy + 0.5) * cell })
        id = id or 0
        if id ~= 0 and not zones[id] then
          local lv = OM.levels[id]
          zones[id] = { name = name, min = lv and lv[1], max = lv and lv[2] }
        end
        if id == cur then
          n = n + 1
        else
          if cur then runs[#runs + 1] = cur .. "*" .. n end
          cur, n = id, 1
        end
      end
      runs[#runs + 1] = cur .. "*" .. n
      rows[#rows + 1] = table.concat(runs, ",")
      cells = cells + (ix1 - ix0 + 1)
      Geo.Yield()
    end
    grid[c] = { cell = cell, ix0 = ix0, iy0 = iy0, rows = rows }
  end
  P.world.grid, P.world.zones = grid, zones
  return cells
end

function Pb.Player(P, pos)
  local plevel = UnitLevel("player")
  local maxLevel = Geo.MaxLevel()
  local needed = {}
  for lv = 1, maxLevel do needed[lv] = Geo.XPNeeded(lv) end
  local st = Settings()
  local g = State.xpGoal
  P.player = { level = plevel, xp = UnitXP("player"), xpMax = UnitXPMax("player"),
    rested = GetXPExhaustion and GetXPExhaustion() or 0, maxLevel = maxLevel, xpNeeded = needed,
    speed = TravelSpeed(), pos = Pb.Point(pos), faction = UnitFactionGroup("player"),
    class = select(2, UnitClass("player")), race = select(2, UnitRace("player")),
    goal = g and { kind = g.kind, value = g.value } or nil,
    settings = { noHearth = st.noHearth, noRecallSpells = st.noRecallSpells, noFMDetour = st.noFMDetour,
      noElite = st.noElite } }
end

function Pb.Constants(P)
  local k = {}
  for _, name in ipairs({ "PATH_FACTOR", "PASS_PATH_FACTOR", "PASS_MIN", "DANGER_MARGIN", "DANGER_FACTOR",
    "FLIGHT_SPEED", "FLIGHT_OVERHEAD", "TRANSPORT_TIME", "K_HUBS", "CROSS_CONTINENT", "ZONE_CELL", "HEARTH_TIME",
    "HEARTH_CD", "HEARTH_MIN_GAIN", "BIND_WORK", "INN_DETOUR", "OVERHEAD", "MOB_TIME", "ELITE_MOB_TIME",
    "KILLS_NO_RATE", "DUNGEON_TIME", "LEVEL_PLAN_MAX_TIME", "LOOKAHEAD_LEVELS" }) do
    k[name] = K[name]
  end
  P.k = k
end

-- Roadbook problem from the game, for the solver (inside a computation spread over frames: Geo.Yield).
-- kind: "auto" (candidate quests, with the list cp = Geo.CustomPlanSteps if any), "custom" (the list cp),
-- "none" (world and character).
function Geo.Problem(kind, pos, cp)
  local P = { quests = {} }
  Pb.Constants(P)
  Pb.Player(P, pos)
  P.player.posSrc = pos
  Pb.World(P, true)
  if kind == "auto" then Pb.Tasks(P, pos, P.player.level, true) end
  if cp then Pb.Custom(P, cp, true) end -- the list (custom; auto: kept or trimmed for the goal)
  return P
end

---------------------------------------------------------------------------
-- /fqp dump: capture for the test bench
---------------------------------------------------------------------------
-- Capture work, spread over several frames (Geo.Yield).
function Pb.Capture(P)
  local pos = P.player.pos
  local plevel = P.player.level
  Pb.Tasks(P, pos, plevel)
  local cp = Geo.CustomPlanSteps(pos, plevel)
  if cp then Pb.Custom(P, cp) end
  Pb.World(P)
  P.cells = Pb.Grid(P)
end

function Pb.Run(P)
  local co = coroutine.create(function() Pb.Capture(P) end)
  Geo.co, Geo.runningKey = co, "bench"
  local function step()
    if Geo.co ~= co then
      Print(L["Capture interrupted by a Roadbook computation: try again."])
      return
    end
    Geo.sliceStart = debugprofilestop()
    local ok, err = coroutine.resume(co)
    if not ok then
      Geo.co = nil
      Print(L["Capture error: "] .. tostring(err))
    elseif coroutine.status(co) == "dead" then
      Geo.co = nil
      P.later = nil -- game objects
      ForeverQuestPlannerBench = ForeverQuestPlannerBench or {}
      ForeverQuestPlannerBench[P.char] = P
      Print(string.format(L["Test bench capture done: %d quests, %d map cells. Type /reload to write it to the file."],
        #P.tasks, P.cells))
    else
      C_Timer.After(0, step)
    end
  end
  step()
end

-- Roadbooks of the planner on the same problem (comparison base): the duration or level goal
-- chosen, then the custom quest list.
function Pb.Baselines(P, done)
  local todo = {}
  local g = State.xpGoal
  if g then todo[#todo + 1] = { name = "auto", goal = g } end
  if #Geo.CustomList() > 0 then todo[#todo + 1] = { name = "custom", goal = "custom" } end
  local function nextOne(i)
    local b = todo[i]
    if not b then return done() end
    Geo.RequestPlan(b.goal, function(route, err, info)
      local out = { err = err, goal = b.goal }
      if route then
        out.route = { { kind = "start", p = Pb.Point(route[1].p), work = 0 } }
        for k = 2, #route do out.route[k] = Pb.Step(route[k]) end
      end
      if info then
        out.info = { total = info.total, xp = info.xp, mobXP = info.mobXP, count = info.count, skipped = info.skipped,
          levels = info.levels, plevel = info.plevel, speed = info.speed, goal = info.goal, discovered = info.discovered }
      end
      P.baseline[b.name] = out
      nextOne(i + 1)
    end, true)
  end
  nextOne(1)
end

function Geo.BenchDump(attempt)
  if Geo.co then
    Print(L["A Roadbook computation is running: try again in a moment."])
    return
  end
  -- The available quests must be scanned (candidates of the automatic Roadbook).
  if scan.running or scan.dirty or not scan.entries then
    if not scan.running then StartScan() end
    attempt = (attempt or 0) + 1
    if attempt > 40 then
      Print(L["Quest scan is taking too long: try again in a moment."])
      return
    end
    C_Timer.After(0.5, function() Geo.BenchDump(attempt) end)
    return
  end
  local pos = PlayerPos()
  if not pos then
    Print(L["Unknown position (in an instance or map unavailable)."])
    return
  end
  Print(L["Capturing the Roadbook problem for the test bench…"])
  local P = { version = K.BENCH_VERSION, char = CharKey(), date = date("%Y-%m-%d %H:%M:%S"), quests = {},
    baseline = {}, frozen = Geo.FrozenRec() }
  Pb.Constants(P)
  Pb.Player(P, pos)
  Pb.Baselines(P, function()
    for _, b in pairs(P.baseline) do
      for _, s in ipairs(b.route or {}) do Pb.AddQuest(P, s.id, s.title) end
    end
    Pb.Run(P)
  end)
end

-- Shared with the next files.
ns.Problem = Pb
