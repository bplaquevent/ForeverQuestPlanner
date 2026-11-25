-- Forever Quest Planner: Roadbook solver in pure Lua (no game API, no global): world model (walks
-- through the zone passes, dangerous zones, flight / boat / zeppelin network), route evaluation.
-- The same file runs in the game and in the offline test bench (tools/bench.lua), on a problem
-- captured in game by /fqp dump (Bench.lua):
--   problem = { k = constants, player = {...}, world = {...}, quests = { [id] = {...} }, tasks = {...},
--               custom = {...}, baseline = {...} }

local ADDON_NAME, ns = ...
local S = {}

---------------------------------------------------------------------------
-- Pure formulas (shared with the game code)
---------------------------------------------------------------------------
function S.Dist(a, b)
  if not a or not b or a.c ~= b.c then return nil end
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Monster XP (Classic formula: level difference, gray monsters, elites x2).
function S.MobXP(clevel, mlevel, elite)
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

-- Quest XP at a player level (Questie's formula), from the quest level and its base XP.
function S.QuestXP(qLevel, base, plevel, maxLevel)
  if not qLevel or qLevel <= 0 or not base or base <= 0 then return 0 end
  if maxLevel and plevel >= maxLevel then return 0 end
  local mult = math.max(1, math.min(10, 2 * (qLevel - plevel) + 20))
  local xp = base * mult / 10
  if xp <= 100 then xp = 5 * math.floor((xp + 2) / 5)
  elseif xp <= 500 then xp = 10 * math.floor((xp + 5) / 10)
  elseif xp <= 1000 then xp = 25 * math.floor((xp + 12) / 25)
  else xp = 50 * math.floor((xp + 25) / 50) end
  return math.floor(xp)
end

---------------------------------------------------------------------------
-- World model, built once per problem from problem.world:
--   grid[c] = { cell, ix0, iy0, rows = { "zone*count,zone*count,…" } } (zone uiMapID, 0 = none)
--   zones[id] = { name, min, max }, passes = { { c, x, y, a, b } },
--   nodes[id] = { name, p, known }, edges = { { from, to, len } },
--   docks = { { name, p } }, links = { { i, j, mode } }
---------------------------------------------------------------------------
local function DecodeGrid(g)
  local rows = {}
  for r, s in ipairs(g.rows) do
    local row, ix = {}, g.ix0
    for id, n in s:gmatch("(%d+)%*(%d+)") do
      id, n = tonumber(id), tonumber(n)
      if id ~= 0 then
        for k = 0, n - 1 do row[ix + k] = id end
      end
      ix = ix + n
    end
    rows[g.iy0 + r - 1] = row
  end
  return { cell = g.cell, rows = rows }
end

function S.World(P)
  if P.W then return P.W end
  local w, k = P.world, P.k
  local W = { k = k, grid = {}, zones = w.zones or {}, passes = w.passes or {}, nodes = {}, edges = {},
    docks = w.docks or {}, links = w.links or {}, passGraph = {}, nets = {}, zoneAt = w.zoneAt }
  for c, g in pairs(w.grid or {}) do W.grid[tonumber(c) or c] = DecodeGrid(g) end
  for _, n in ipairs(w.nodes or {}) do W.nodes[n.id] = n end
  for _, e in ipairs(w.edges or {}) do
    if W.nodes[e[1]] and W.nodes[e[2]] then
      W.edges[e[1]] = W.edges[e[1]] or {}
      table.insert(W.edges[e[1]], { e[2], e[3] })
    end
  end
  P.W = W
  return W
end

-- Zone (uiMapID) at a world point: world.zoneAt (in game), else the captured grid; nil out of any zone.
function S.ZoneId(W, p)
  if W.zoneAt then return W.zoneAt(p) end
  local g = W.grid[p.c]
  if not g then return nil end
  local row = g.rows[math.floor(p.y / g.cell)]
  return row and row[math.floor(p.x / g.cell)] or nil
end

-- Shortest ways between the passes of a continent (Floyd-Warshall): two passes are joined when
-- they share a zone (a straight line across it).
function S.PassGraph(W, c)
  local g = W.passGraph[c]
  if g then return g end
  local pts, byZone = {}, {}
  for _, ps in ipairs(W.passes) do
    if ps.c == c then
      pts[#pts + 1] = ps
      for _, z in ipairs({ ps.a, ps.b }) do
        byZone[z] = byZone[z] or {}
        table.insert(byZone[z], #pts)
      end
    end
  end
  local n, D, nxt = #pts, {}, {}
  for i = 1, n do
    D[i], nxt[i] = {}, {}
    local p = pts[i]
    for j = 1, n do
      local q = pts[j]
      local shared = p.a == q.a or p.a == q.b or p.b == q.a or p.b == q.b
      D[i][j] = (i == j and 0) or (shared and S.Dist(p, q)) or math.huge
      nxt[i][j] = j
    end
  end
  for m = 1, n do
    local Dm = D[m]
    for i = 1, n do
      local dim = D[i][m]
      if dim < math.huge then
        local Di, Ni, nim = D[i], nxt[i], nxt[i][m]
        for j = 1, n do
          local v = dim + Dm[j]
          if v < Di[j] then Di[j], Ni[j] = v, nim end
        end
      end
    end
  end
  g = { pts = pts, byZone = byZone, D = D, nxt = nxt }
  W.passGraph[c] = g
  return g
end

-- Walking distance from a to b (nil: other continent) and the passes it goes through, in order.
function S.WalkWay(W, a, b)
  local d = S.Dist(a, b)
  if not d or d < W.k.PASS_MIN then return d end
  local za, zb = S.ZoneId(W, a), S.ZoneId(W, b)
  if not (za and zb) or za == zb then return d end
  local g = S.PassGraph(W, a.c)
  local ia, ib = g.byZone[za], g.byZone[zb]
  if not (ia and ib) then return d end
  local best, bi, bj = math.huge, nil, nil
  for _, i in ipairs(ia) do
    local di = S.Dist(a, g.pts[i])
    for _, j in ipairs(ib) do
      local v = di + g.D[i][j] + S.Dist(g.pts[j], b)
      if v < best then best, bi, bj = v, i, j end
    end
  end
  if not bi then return d end
  local way, i = { g.pts[bi] }, bi
  while i ~= bj do
    i = g.nxt[i][bj]
    way[#way + 1] = g.pts[i]
  end
  return best, way
end

function S.WalkTime(W, a, b, speed)
  local d, way = S.WalkWay(W, a, b)
  if not d then return nil end
  return d * (way and W.k.PASS_PATH_FACTOR or W.k.PATH_FACTOR) / speed, way
end

-- Shape of the walk a -> b, independent of the speed and of the player level: its length (path factor
-- included) and the highest zone minimum level crossed; nil length when there is no way on foot.
local function WalkShape(W, a, b)
  local d, way = S.WalkWay(W, a, b)
  if not d then return nil end
  local worst, worstZone, p = nil, nil, a
  for m = 1, (way and #way or 0) + 1 do
    local q = way and way[m] or b
    if S.Dist(p, q) > 300 then
      for _, f in ipairs({ 0.25, 0.5, 0.75, 1 }) do
        local id = S.ZoneId(W, { c = p.c, x = p.x + (q.x - p.x) * f, y = p.y + (q.y - p.y) * f })
        local z = W.zones[id or 0]
        if z and z.min and (not worst or z.min > worst) then worst, worstZone = z.min, id end
      end
    end
    p = q
  end
  return d * (way and W.k.PASS_PATH_FACTOR or W.k.PATH_FACTOR), worst, worstZone
end

-- Walking time with the dangerous zones crossed (minimum level > plevel + margin: slower).
-- Also returns the highest zone minimum level crossed (any level) and that zone, for reports and directions.
-- The shape of each walk is cached by pair of points (shared objects): the same pair comes back for
-- every network and player level, only the speed and the danger penalty change.
function S.WalkCost(W, a, b, speed, plevel)
  W.walkCache = W.walkCache or setmetatable({}, { __mode = "k" })
  local row = W.walkCache[a]
  if not row then
    row = {}
    W.walkCache[a] = row
  end
  local e = row[b]
  if not e then
    local len, worst, zone = WalkShape(W, a, b)
    e = { len or false, worst, zone }
    row[b] = e
  end
  if not e[1] then return math.huge end
  local t, worst = e[1] / speed, e[2]
  if worst and worst > plevel + W.k.DANGER_MARGIN then t = t * W.k.DANGER_FACTOR end
  return t, worst, e[3]
end

-- Flight lengths from node `from` to every node reachable over `known` nodes only (Dijkstra).
function S.FlightDists(W, from, known)
  local dist, done = { [from] = 0 }, {}
  while true do
    local m, md
    for id, d in pairs(dist) do
      if not done[id] and (not md or d < md) then m, md = id, d end
    end
    if not m then break end
    done[m] = true
    for _, e in ipairs(W.edges[m] or {}) do
      local to = e[1]
      if known[to] and not done[to] then
        local nd = md + e[2]
        if not dist[to] or nd < dist[to] then dist[to] = nd end
      end
    end
  end
  return dist
end

-- Set of known flight nodes -> stable key.
function S.KnownKey(known)
  local ids = {}
  for id in pairs(known) do ids[#ids + 1] = id end
  table.sort(ids)
  return table.concat(ids, ",")
end

-- Transport skipped by the player (P.ban = { mode, from = departure point, to = arrival point }):
-- a flight bans every flight leaving the flight master at `from`, a boat or zeppelin its
-- line from the dock at `from` to the dock at `to`.
S.BAN_RADIUS = 200 -- yards
function S.Near(a, b, r)
  local d = S.Dist(a, b)
  return d ~= nil and d < r
end

function S.BanKey(ban)
  if not ban then return "" end
  local function pt(p) return p and string.format("%s:%.0f:%.0f", tostring(p.c), p.x or 0, p.y or 0) or "-" end
  return "#" .. tostring(ban.mode) .. pt(ban.from) .. pt(ban.to)
end

local WEAK = { __mode = "k" }

-- Transport network with the flight nodes `known`: hubs (flight masters, docks) and shortest
-- paths between them (Floyd-Warshall). Cached by set of known nodes, speed and banned transport.
function S.Network(W, known, speed, ban)
  local key = S.KnownKey(known) .. "@" .. speed .. S.BanKey(ban)
  local net = W.nets[key]
  if net then return net end
  local k = W.k
  local hubs = {}
  local ids = {}
  for id in pairs(known) do if W.nodes[id] then ids[#ids + 1] = id end end
  table.sort(ids)
  for _, id in ipairs(ids) do
    hubs[#hubs + 1] = { kind = "taxi", name = W.nodes[id].name, p = W.nodes[id].p, node = id }
  end
  local dockIndex = {}
  for i, d in ipairs(W.docks) do
    hubs[#hubs + 1] = { kind = "dock", name = d.name, p = d.p }
    dockIndex[i] = #hubs
  end
  local n = #hubs
  local D, nxt, via = {}, {}, {}
  for i = 1, n do
    D[i], nxt[i], via[i] = {}, {}, {}
    local a = hubs[i]
    local banned = ban and ban.mode == "flight" and a.node and S.Near(a.p, ban.from, S.BAN_RADIUS)
    local fd = a.node and not banned and S.FlightDists(W, a.node, known) or nil
    for j = 1, n do
      nxt[i][j] = j
      if i == j then
        D[i][j] = 0
      else
        local b = hubs[j]
        local best, how = math.huge, nil
        local walk = S.WalkTime(W, a.p, b.p, speed)
        if walk then best, how = walk, "walk" end
        local len = fd and b.node and fd[b.node]
        if len then
          local fl = len / k.FLIGHT_SPEED + k.FLIGHT_OVERHEAD
          if fl < best then best, how = fl, "flight" end
        end
        D[i][j], via[i][j] = best, how
      end
    end
  end
  for _, l in ipairs(W.links) do
    local i, j = dockIndex[l[1]], dockIndex[l[2]]
    local banned = ban and ban.mode ~= "flight" and i and j and S.Near(hubs[i].p, ban.from, S.BAN_RADIUS)
      and S.Near(hubs[j].p, ban.to, S.BAN_RADIUS)
    if i and j and not banned and k.TRANSPORT_TIME < D[i][j] then D[i][j], via[i][j] = k.TRANSPORT_TIME, l[3] end
  end
  for m = 1, n do
    local Dm = D[m]
    for i = 1, n do
      local dim = D[i][m]
      if dim < math.huge then
        local Di, Ni, nim = D[i], nxt[i], nxt[i][m]
        for j = 1, n do
          local v = dim + Dm[j]
          if v < Di[j] then Di[j], Ni[j] = v, nim end
        end
      end
    end
  end
  -- (weak keys: in game a network outlives the computations, points like the player's place do not)
  net = { key = key, hubs = hubs, D = D, nxt = nxt, via = via, speed = speed, near = setmetatable({}, WEAK), travel = {} }
  W.nets[key] = net
  return net
end

local function NearHubs(W, net, p)
  local cached = net.near[p]
  if cached then return cached end
  local list = {}
  for i, h in ipairs(net.hubs) do
    local d = S.Dist(h.p, p)
    if d then list[#list + 1] = { i = i, d = d } end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  local out = {}
  for m = 1, math.min(W.k.K_HUBS, #list) do out[m] = list[m].i end
  net.near[p] = out
  return out
end

-- Best way from a to b: direct walk, or walk -> network -> walk. Returns the time and the hubs used.
function S.Route(W, a, b, net, plevel)
  if not a or not b then return 0, nil end
  local speed = net.speed
  local best = (a.c == b.c) and (S.WalkCost(W, a, b, speed, plevel)) or math.huge
  local choice
  if #net.hubs > 0 then
    -- Walk from each arrival hub to b: computed once, it does not depend on the departure hub.
    local hb, wb = NearHubs(W, net, b), {}
    for m, j in ipairs(hb) do wb[m] = (S.WalkCost(W, net.hubs[j].p, b, speed, plevel)) end
    for _, i in ipairs(NearHubs(W, net, a)) do
      local wa = S.WalkCost(W, a, net.hubs[i].p, speed, plevel)
      if wa < best then
        for m, j in ipairs(hb) do
          local v = wa + net.D[i][j] + wb[m]
          if v < best then best, choice = v, { i = i, j = j } end
        end
      end
    end
  end
  if best == math.huge then best = W.k.CROSS_CONTINENT end
  return best, choice
end

-- Cached travel time a -> b on a network at a player level (points are shared objects).
function S.Travel(W, net, plevel, a, b)
  if a == b then return 0 end
  local byLevel = net.travel[plevel]
  if not byLevel then
    byLevel = setmetatable({}, WEAK)
    net.travel[plevel] = byLevel
  end
  local row = byLevel[a]
  if not row then
    row = {}
    byLevel[a] = row
  end
  local v = row[b]
  if v == nil then
    v = S.Route(W, a, b, net, plevel)
    row[b] = v
  end
  return v
end

---------------------------------------------------------------------------
-- Route evaluation
---------------------------------------------------------------------------
-- Known flight nodes at the start of the problem.
function S.KnownStart(P)
  local known = {}
  for _, n in ipairs(P.world.nodes or {}) do if n.known then known[n.id] = true end end
  return known
end

-- XP needed to go from a level to the next one.
local function Needed(P, level)
  return P.player.xpNeeded[level] or math.huge
end

-- XP gained: the level, the XP in it and its XP to the next one. need: the current level's, when the game
-- gives it (else xpNeeded).
function S.LevelUp(level, xp, maxLevel, xpNeeded, need)
  need = need or xpNeeded[level] or math.huge
  while level < maxLevel and xp >= need do
    xp, level = xp - need, level + 1
    need = xpNeeded[level] or math.huge
  end
  return level, xp, need
end

-- XP the game gives now for each quest (quest log, available quests): the reference. It can differ
-- from QuestieDB's (Forever's own values): QuestieDB's formula only gives how it changes with the level.
function S.Prepare(P)
  if P.prepared then return end
  P.prepared = true
  local lists = { P.tasks or {}, P.custom and P.custom.tasks or {} }
  for _, list in ipairs(lists) do
    for _, t in ipairs(list) do
      local q = t.id and P.quests[t.id]
      if q and q.xpNow == nil and t.xp and t.xp > 0 then q.xpNow = t.xp end
    end
  end
end

-- XP of a quest turned in at a player level.
function S.TurnInXP(P, id, level, fallback)
  local q = id and P.quests[id]
  if not (q and q.qLevel) then return fallback or 0 end
  local pl = P.player
  local xp = S.QuestXP(q.qLevel, q.baseXP, level, pl.maxLevel)
  local ref = S.QuestXP(q.qLevel, q.baseXP, pl.level, pl.maxLevel)
  if q.xpNow and ref > 0 then xp = math.floor(xp * q.xpNow / ref + 0.5) end
  return xp
end

-- XP of a step at a player level: quest turn-in, monsters of an objective.
-- `legacy`: the XP computed in game when the plan was made (fixed).
function S.StepXP(P, st, level, legacy)
  if legacy then return st.xp or 0 end
  if st.kind == "turnin" then
    return S.TurnInXP(P, st.id, level, st.xp)
  elseif st.kind == "obj" then
    local o = st.obj
    if o and o.mobLevel then return math.floor((o.kills or 0) * S.MobXP(level, o.mobLevel, o.elite)) end
    return st.xp or 0
  elseif st.kind == "dungeon" then
    local xp = 0
    for _, m in ipairs(st.members or {}) do xp = xp + S.StepXP(P, m, level, legacy) end
    return xp
  end
  return 0
end

-- Simulates a route (list of steps, route[1] = start) from the problem's starting state.
-- Step: { kind, p, work, xp, id (quest), obj = { kills, mobLevel, elite }, via (way back key),
--         bindDest, fmNode, legacyFM, members (dungeon) }.
-- opts.legacy: the in-game accounting of the current planner (one network: the flight paths known
-- at the start, except the ones activated by the custom planner (legacyFM); danger and XP at the
-- starting level; teleports without cooldown).
-- Returns { time, xp, questXP, mobXP, level, xpLeft, at = {}, levels = {}, travel = {}, stepXP = {} (rested
--           bonus included), rawXP = {},
--           nets = {} (network of each leg), legs = { [i] = { from, to, net, level } } (travelled legs, not
--           teleports: the way the game shows, S.Route with these is the one costed), binds = {} (bind point before each step), wait,
--           violations = { { i, kind ("recall", "level"), what } }, reach = time the goal level is reached }.
function S.Evaluate(P, route, opts)
  opts = opts or {}
  local legacy = opts.legacy
  local W = S.World(P)
  S.Prepare(P)
  local pl = P.player
  local known = S.KnownStart(P)
  local net = S.Network(W, known, pl.speed)
  -- Transport skipped by the player: not usable on the first leg only (P.ban).
  local banNet = P.ban and S.Network(W, known, pl.speed, P.ban)
  local level, xp, rested = pl.level, pl.xp or 0, pl.rested or 0
  local need = pl.xpMax or Needed(P, level)
  local bind = P.world.bind
  local sources = {}
  for _, s in ipairs(P.world.recall or {}) do
    sources[tostring(s.key)] = { ready = s.ready or 0, cd = s.cd or 0, charges = s.charges, src = s }
  end
  local res = { at = { 0 }, levels = { level }, travel = { 0 }, stepXP = { 0 }, rawXP = { 0 }, nets = {}, legs = {}, binds = {}, violations = {},
    wait = 0, questXP = 0, mobXP = 0 }
  local t, pos = 0, route[1].p
  local target = opts.targetLevel
  for i = 2, #route do
    local st = route[i]
    local lvNow = legacy and pl.level or level
    res.nets[i], res.binds[i] = net, bind
    if st.reqLevel and level < st.reqLevel and not legacy then
      res.violations[#res.violations + 1] = { i = i, kind = "level", ci = st.ci, what = "picked up below its required level " .. st.reqLevel }
    end
    local move, dest = 0, st.p
    if st.kind == "hearth" then
      move = st.cast or (st.p and st.p.cast) or P.k.HEARTH_TIME
      if not legacy then
        local s = sources[tostring(st.via or "hearth")]
        if not s then
          res.violations[#res.violations + 1] = { i = i, kind = "recall", what = "unknown way back " .. tostring(st.via) }
        else
          if t < s.ready then
            res.wait = res.wait + (s.ready - t)
            res.violations[#res.violations + 1] = { i = i, kind = "recall",
              what = string.format("%s on cooldown: %d s to wait", tostring(st.via or "hearth"), s.ready - t) }
            t = s.ready
          end
          if s.charges then
            if s.charges <= 0 then res.violations[#res.violations + 1] = { i = i, kind = "recall", what = "no charge left" } end
            s.charges = s.charges - 1
          end
          s.ready = t + move + s.cd
          if s.src.bind or st.bindDest then dest = bind or st.p else dest = s.src.p or st.p end
        end
      end
    else
      local legNet = (i == 2 and banNet) or net
      res.legs[i] = { from = pos, to = st.p, net = legNet, level = lvNow }
      move = S.Travel(W, legNet, lvNow, pos, st.p)
    end
    t = t + move + (st.work or 0)
    pos = dest
    if st.kind == "bind" then bind = st.p end
    -- Flight path activated: usable from the next leg (legacy: only the custom planner did it).
    if st.kind == "fm" and st.fmNode and (not legacy or st.legacyFM) and not known[st.fmNode] then
      known[st.fmNode] = true
      net = S.Network(W, known, pl.speed)
    end
    local gain = S.StepXP(P, st, level, legacy)
    res.rawXP[i] = gain
    if st.kind == "obj" then res.mobXP = res.mobXP + gain else res.questXP = res.questXP + gain end
    if st.kind == "obj" and gain > 0 and rested > 0 then
      local b = math.min(rested, gain)
      rested, gain = rested - b, gain + b
    end
    level, xp, need = S.LevelUp(level, xp + gain, pl.maxLevel, pl.xpNeeded, need)
    if target and not res.reach and level >= target then res.reach = t end
    res.at[i], res.levels[i], res.travel[i], res.stepXP[i] = t, level, move, gain
  end
  res.time, res.level, res.xpLeft = t, level, xp
  res.xp = res.questXP + res.mobXP
  return res
end

-- Can the quests be done in some order, with the XP of the quests alone? player = { level, xp,
-- xpNeeded = { [level] = XP to the next one }, maxLevel }; quests = { { id, row = { qLevel, baseXP },
-- reqLevel, pres = { quest ids that must be done first }, inLog } }. A quest is ready when its
-- prerequisites are done and the level required is reached (or it is in the log already); the lowest
-- requirement goes first. Returns nil when all can be done, else { id, need, reach }: the blocked quest
-- with the lowest required level, and the level reached when nothing more can be done.
function S.LevelReach(player, quests)
  local level, xp = player.level, player.xp or 0
  local done, left = {}, {}
  for i, q in ipairs(quests) do left[i] = q end
  while #left > 0 do
    local pick
    for i, q in ipairs(left) do
      local ready = q.inLog or (q.reqLevel or 0) <= level
      for _, p in ipairs(q.pres or {}) do
        if not done[p] then ready = false end
      end
      if ready and q.anyPres then -- one of the alternatives is enough
        ready = false
        for _, p in ipairs(q.anyPres) do
          if done[p] then ready = true break end
        end
      end
      if ready and (not pick or (q.reqLevel or 0) < (left[pick].reqLevel or 0)) then pick = i end
    end
    if not pick then break end
    local q = table.remove(left, pick)
    done[q.id] = true
    local gain = q.row and S.QuestXP(q.row[1], q.row[2], level, player.maxLevel) or 0
    level, xp = S.LevelUp(level, xp + gain, player.maxLevel, player.xpNeeded)
  end
  if #left == 0 then return nil end
  local worst
  for _, q in ipairs(left) do
    -- (a quest only waiting for a prerequisite is not the one to blame)
    local late = (q.reqLevel or 0) > level
    local wlate = worst and (worst.reqLevel or 0) > level
    if not worst or (late and not wlate) or (late == wlate and (q.reqLevel or 0) < (worst.reqLevel or 0)) then worst = q end
  end
  return { id = worst.id, need = worst.reqLevel or 0, reach = level }
end

---------------------------------------------------------------------------
-- Goal
---------------------------------------------------------------------------
-- Goal of a computation: "custom" (every quest of the list, P.custom, in the least time),
-- { kind = "time", value = seconds } (most XP within that time) or { kind = "level", value = level }
-- (fastest route to that level, at least the next one: target). With a list (P.custom), a duration or
-- level goal completes it with candidate quests, or keeps only the part of it that serves the goal best.
function S.Goal(P, goal)
  if goal == "custom" then return goal end
  goal = goal or P.player.goal or { kind = "time", value = 7200 }
  local g = { kind = goal.kind, value = goal.value }
  if g.kind == "level" then g.target = math.max(g.value, P.player.level + 1) end
  return g
end

-- XP an evaluated route gains within a time (s).
function S.XPWithin(res, time)
  local xp = 0
  for i = 2, #res.at do
    if res.at[i] <= time then xp = xp + res.stepXP[i] end
  end
  return xp
end

-- Goal value of an evaluated route (lower is better); a route breaking a rule (quest picked up below
-- its required level, teleport not ready) is worse than any other. A little of the total time is
-- added: of two routes as good, the shorter one (no useless step at the end).
-- level goal: time to reach the level; a route that does not reach it is worse than any route that
-- does, and two such routes compare by the time they would take getting the missing XP at their own rate;
-- time goal: minus the XP gained within the time; custom Roadbook ("custom"): total time, a quest picked
-- up below its required level costing S.LEVEL_PENALTY (its list may not allow better: a soft rule).
-- A quest of the list picked up below its required level is a soft rule with the other goals too
-- (S.LIST_LEVEL_PENALTY XP for a duration, S.LEVEL_PENALTY seconds for a level).
S.LIST_LEVEL_PENALTY = 1e6
function S.Objective(P, res, goal)
  local soft = 0
  for _, v in ipairs(res.violations) do
    if v.kind ~= "level" or not v.ci then return 1e12 + #res.violations end
    soft = soft + 1
  end
  if goal == "custom" then return res.time + soft * S.LEVEL_PENALTY end
  local eps = 1e-3 * res.time
  if goal.kind == "level" then
    if res.reach then return res.reach + eps + soft * S.LEVEL_PENALTY end
    local pl = P.player
    local missing = ((res.level == pl.level and pl.xpMax) or Needed(P, res.level)) - res.xpLeft
    for lv = res.level + 1, goal.target - 1 do missing = missing + Needed(P, lv) end
    local rate = math.max(res.xp / math.max(res.time, 60), 0.5)
    return 1e7 + res.time + missing / rate + eps + soft * S.LEVEL_PENALTY
  end
  return -S.XPWithin(res, goal.value) + eps + soft * S.LIST_LEVEL_PENALTY
end

-- Rules broken by a route that no order of its steps can excuse (every violation but a quest of the
-- list picked up below its required level).
function S.HardViolations(res)
  local n = 0
  for _, v in ipairs(res.violations) do
    if v.kind ~= "level" or not v.ci then n = n + 1 end
  end
  return n
end

---------------------------------------------------------------------------
-- Teleports: placed on the legs where they save the most
---------------------------------------------------------------------------
-- Ways back of a route without teleports (`base`: its evaluation): for each leg, the time saved by
-- each way back (cast, then travel from its arrival); the best ones are kept in order of gain,
-- one per leg, with the cooldown between two uses of the same one and its charges.
function S.AddRecalls(P, core, base)
  local sources = P.world.recall or {}
  if #sources == 0 then return core end
  local W, minGain = P.W, P.k.HEARTH_MIN_GAIN
  local cands = {}
  for i = 2, #core do
    local st = core[i]
    if not st.glue then -- escort: on foot with the NPC
      for _, src in ipairs(sources) do
        local dest = src.bind and base.binds[i] or src.p
        if dest then
          local gain = base.travel[i] - (src.cast + S.Travel(W, base.nets[i], base.levels[i - 1], dest, st.p))
          if gain >= minGain then
            cands[#cands + 1] = { i = i, t = base.at[i - 1], gain = gain, src = src, dest = dest }
          end
        end
      end
    end
  end
  if #cands == 0 then return core end
  table.sort(cands, function(a, b) return a.gain > b.gain end)
  local byLeg, chosen, used = {}, {}, {}
  for _, c in ipairs(cands) do
    local src = c.src
    local ok = not byLeg[c.i] and c.t >= (src.ready or 0) and (not src.charges or (used[src] or 0) < src.charges)
    if ok and (src.cd or 0) > 0 then
      for _, o in ipairs(chosen) do
        if o.src == src and math.abs(c.t - o.t) < src.cd + src.cast then ok = false break end
      end
    end
    if ok then
      chosen[#chosen + 1] = c
      byLeg[c.i] = c
      used[src] = (used[src] or 0) + 1
    end
  end
  local out = { core[1] }
  for i = 2, #core do
    local c = byLeg[i]
    if c then
      out[#out + 1] = { kind = "hearth", via = c.src.key, bindDest = c.src.bind or nil, p = c.dest, cast = c.src.cast,
        gain = c.gain, work = 0, title = c.src.name }
    end
    out[#out + 1] = core[i]
  end
  return out
end

-- Route of a core (quest steps, binds, flight paths activated) with its teleports, and its evaluation.
-- Teleports no longer ready once the times moved are dropped.
function S.Simulate(P, core, goal)
  local target = goal ~= "custom" and goal.target or nil
  local base = S.Evaluate(P, core, { targetLevel = target })
  local route = S.AddRecalls(P, core, base)
  if route == core then return base, core end
  for _ = 1, 4 do
    local res = S.Evaluate(P, route, { targetLevel = target })
    local drop = {}
    for _, v in ipairs(res.violations) do
      if v.kind == "recall" then drop[v.i] = true end
    end
    if not next(drop) then return res, route end
    local r = {}
    for i, st in ipairs(route) do
      if not drop[i] then r[#r + 1] = st end
    end
    route = r
  end
  return S.Evaluate(P, route, { targetLevel = target }), route
end

---------------------------------------------------------------------------
-- Optimization of the automatic Roadbook
---------------------------------------------------------------------------
S.yield = function() end -- set by the game: spreads the computation over several frames
S.clock = nil            -- set by the caller: function returning seconds (time budget)

S.OPT = {
  TOP_K = 25,         -- chains of quests fully evaluated at each addition (the best by the quick estimate)
  ADD_POOL = 100,     -- quests inserted (quick estimate) at each addition, after a sort by distance
  CHAIN_DEPTH = 2,    -- follow-ups added with a quest at once
  MAX_SEGMENT = 6,    -- longest block of steps moved at once
  OVERSHOOT = 1.15,   -- time goal: the construction may go this far beyond the time
  FM_SEARCH = 2500,   -- yards: unknown flight masters this close to a step are tried (kept if the route gains)
  FM_NEAR = 500,      -- yards: unknown flight masters this close to a step are activated, whatever the gain
  MAX_EVALS = 40000,  -- evaluation budget
  MAX_TIME = 60,      -- seconds of computation, at most (when S.clock is set)
  LNS_ROUNDS = 30,    -- destroy and rebuild attempts
  LNS_SHARE = 30,     -- % of the quests removed by a random destruction
  LNS_NOISE = 0.3,    -- rebuilds: random factor on the XP rates (other choices explored)
  BUILD_SHARE = 0.5,  -- share of the budget the first construction may use
}

-- Objective that can be done in any order with the other ones of its quest: monsters to kill, items to
-- loot, objects to use. Talking to an NPC, an event or a place to reach (often "use the item there"),
-- an escort: kept at their place among the objectives (S.Ranks).
function S.FreeObjective(st)
  return st.kind == "obj" and not st.escort and st.obj ~= nil and not st.obj.fixed
    and (st.obj.kind == "kill" or st.obj.kind == "item" or st.obj.kind == "object")
end

-- Order rank of the steps of a quest (in their planned order): pick-up 0; free objectives share the
-- rank of their group, a fixed objective starts a new rank; turn-in last. A step needs every step
-- of a lower rank done before it. Sets st.rank and st.below (steps of a lower rank).
function S.Ranks(stops)
  local r = 0
  for _, st in ipairs(stops) do
    if st.kind == "take" then
      st.rank = 0
    elseif st.kind == "turnin" then
      st.rank = r + 1
    elseif S.FreeObjective(st) then
      if r % 2 == 0 then r = r + 1 end
      st.rank = r
    else
      r = r + (r % 2 == 0 and 2 or 1)
      st.rank = r
    end
  end
  for _, st in ipairs(stops) do
    local below = 0
    for _, o in ipairs(stops) do
      if o.rank < st.rank then below = below + 1 end
    end
    st.below = below
  end
end

-- Order rules of those ranks, added to pred (by step index ci): every step of a lower rank comes first.
function S.RankPreds(stops, pred)
  S.Ranks(stops)
  for _, a in ipairs(stops) do
    for _, b in ipairs(stops) do
      if b.rank < a.rank then
        pred[a.ci] = pred[a.ci] or {}
        table.insert(pred[a.ci], b.ci)
      end
    end
  end
end

-- Hunting spots of an objective step (st.spots: the densest ones, with their hunting time): one variant
-- of the step per spot, sharing st.variants. The original step (spot chosen when the problem was
-- built) is the first one; the "spots" move swaps them.
function S.Variants(st)
  if not st.spots or st.variants then return end
  st.variants = { st }
  for _, alt in ipairs(st.spots) do
    local d = S.Dist(alt.p, st.p)
    if not (d and d < 30) then
      local v = {}
      for key, x in pairs(st) do v[key] = x end
      v.p, v.work, v.alt = alt.p, alt.work, alt
      table.insert(st.variants, v)
    end
  end
end

-- Indexes of the problem: tasks by number, follow-ups, steps (task number, index, order rank,
-- required level, hunting spot variants), estimated value of each quest with its best follow-ups.
function S.PrepareTasks(P)
  if P.byN then return end
  P.byN, P.followers = {}, {}
  for _, t in ipairs(P.tasks or {}) do
    P.byN[t.n] = t
    local value, work = (t.xp or 0), 0
    for k, st in ipairs(t.stops) do
      st.tn, st.k = t.n, k
      if st.kind == "take" and t.kind == "take" then st.reqLevel = t.reqLevel end -- every place to check
      if st.kind == "obj" then value = value + (st.xp or 0) end
      work = work + (st.work or 0)
    end
    S.Ranks(t.stops)
    for _, st in ipairs(t.stops) do S.Variants(st) end
    t.estValue, t.work = value, work
    if t.dep then
      P.followers[t.dep] = P.followers[t.dep] or {}
      table.insert(P.followers[t.dep], t.n)
    end
  end
  -- Value with the best chain of follow-ups (CHAIN_DEPTH): a quest leading to good ones is considered.
  local function chain(t, depth)
    local best = 0
    if depth < S.OPT.CHAIN_DEPTH then
      for _, fn in ipairs(P.followers[t.n] or {}) do
        local v = chain(P.byN[fn], depth + 1)
        if v > best then best = v end
      end
    end
    return (t.estValue or 0) + best
  end
  for _, t in ipairs(P.tasks or {}) do t.chainValue = chain(t, 0) end
end

-- Quick travel estimate (network and level at the start), for ranking only.
local function QuickTravel(P, a, b)
  return S.Travel(P.W, P.net0, P.player.level, a, b)
end

-- A random factor between 1 and 1 + noise on v (rebuilds explore other choices); v as it is without noise.
local function Noisy(v, rand, noise)
  if not noise then return v end
  return v * (1 + noise * (rand(1000) - 1) / 1000)
end

-- Cheapest place to insert step s in route r, after one of r[lo..hi]; glued(b): nothing may come between
-- b and the step before it. Returns the index and the travel added (QuickTravel), nil if no place fits.
local function CheapestSlot(P, r, s, lo, hi, glued, rand, noise)
  local bestI, bestD
  for i = lo, hi do
    local a, b = r[i], r[i + 1]
    if not (b and glued(b)) then
      local d = QuickTravel(P, a.p, s.p)
      if b then d = d + QuickTravel(P, s.p, b.p) - QuickTravel(P, a.p, b.p) end
      d = Noisy(d, rand, noise)
      if not bestD or d < bestD then bestI, bestD = i, d end
    end
  end
  return bestI, bestD
end

-- Places allowed to a step of the list in a route whose steps are at pos[ci]: after the steps it needs
-- (pred, unless free of the order rules), right after the step it is glued to. nil: not yet.
local function ListRange(pred, s, pos, n, free)
  local lo, hi = 1, n
  if not free then
    for _, pc in ipairs(pred[s.ci] or {}) do
      local j = pos[pc]
      if not j then return nil end
      if j > lo then lo = j end
    end
  end
  if s.glueTo then
    local j = pos[s.glueTo]
    if not j then return nil end
    lo, hi = j, j
  end
  return lo, hi
end

-- Inserts a task's steps where they cost the least (quick estimate), in their order, after the turn-in
-- of the quest they follow (a candidate quest or a quest of the list: depCi). Returns the new core and
-- the extra time, or nil.
function S.InsertTask(P, core, t)
  local r = {}
  for i, st in ipairs(core) do r[i] = st end
  local lo = 1
  if t.depCi then
    lo = nil
    for i, st in ipairs(r) do
      if st.ci == t.depCi then lo = i break end
    end
    if not lo then return nil end
  elseif t.dep then
    local dep = P.byN[t.dep]
    local last = dep and dep.stops[#dep.stops]
    lo = nil
    for i, st in ipairs(r) do
      if st == last then lo = i break end
    end
    if not lo then return nil end
  end
  local delta = 0
  for k, s in ipairs(t.stops) do
    local hi = #r
    if s.glue and k > 1 then hi = lo end
    local bestI, bestD = CheapestSlot(P, r, s, lo, hi, function(b) return b.glue end)
    if not bestI then return nil end
    table.insert(r, bestI + 1, s)
    delta = delta + bestD + (s.work or 0)
    lo = bestI + 1
  end
  return r, delta
end

-- Order rules: each step of a quest after the steps of a lower rank (S.Ranks: pick-up first, free
-- objectives in any order, fixed ones at their place, turn-in last), escort steps right after the
-- previous step, a follow-up started after the turn-in of the quest it follows.
function S.Valid(P, core)
  local seen, done, ciDone = {}, {}, {}
  for i = 2, #core do
    local s = core[i]
    if s.ci then ciDone[s.ci] = true end
    if s.tn then
      local c = seen[s.tn] or 0
      if c < s.below then return false end
      local t = P.byN[s.tn]
      if c == 0 and t.dep and not done[t.dep] then return false end
      if c == 0 and t.depCi and not ciDone[t.depCi] then return false end
      if s.glue and s.k > 1 then
        local prev = core[i - 1]
        if prev.tn ~= s.tn or prev.k ~= s.k - 1 then return false end
      end
      seen[s.tn] = c + 1
      if c + 1 == #t.stops then done[s.tn] = true end
    end
  end
  return true
end

-- Tasks (numbers) and quests (ids) of a core.
local function Contents(core)
  local tasks, ids = {}, {}
  for _, st in ipairs(core) do
    if st.tn then
      tasks[st.tn] = true
      if st.id then ids[st.id] = true end
    end
  end
  return tasks, ids
end

-- Quests that can be added to a core, alone or with their best follow-ups (CHAIN_DEPTH), inserted
-- by the quick estimate and sorted by estimated XP per second.
function S.Additions(P, core)
  local tasks, ids = Contents(core)
  local ciIn = {}
  for _, st in ipairs(core) do if st.ci then ciIn[st.ci] = true end end
  -- Quick sort of every quest that can be added: value with its follow-ups per second of its work plus
  -- a round trip from the nearest step of the route; only the best ADD_POOL ones are inserted.
  local pts = {}
  for _, st in ipairs(core) do pts[#pts + 1] = st.p end
  local k, speed = P.k, P.player.speed
  local pool = {}
  for _, t in ipairs(P.tasks) do
    if not tasks[t.n] and not t.inList and not (t.id and ids[t.id]) and (not t.dep or tasks[t.dep])
      and (not t.depCi or ciIn[t.depCi]) then
      local d
      for _, s in ipairs(t.stops) do
        for _, q in ipairs(pts) do
          local x = S.Dist(s.p, q)
          if x and (not d or x < d) then d = x end
        end
      end
      local cost = (t.work or 0) + (d and 2 * d * k.PATH_FACTOR / speed or 2 * k.CROSS_CONTINENT)
      pool[#pool + 1] = { t = t, score = (t.chainValue or 0) / math.max(cost, 30) }
    end
  end
  table.sort(pool, function(a, b) return a.score > b.score end)
  for i = #pool, S.OPT.ADD_POOL + 1, -1 do pool[i] = nil end
  local out = {}
  for _, e in ipairs(pool) do
    local t = e.t
    do
      local c, delta, value = core, 0, 0
      local chainIds, cur = {}, t
      for depth = 0, S.OPT.CHAIN_DEPTH do
        local d
        c, d = S.InsertTask(P, c, cur)
        if not c then break end
        delta, value = delta + d, value + (cur.estValue or 0)
        if cur.id then chainIds[cur.id] = true end
        out[#out + 1] = { core = c, rate = value / math.max(delta, 30), root = t }
        if depth == S.OPT.CHAIN_DEPTH then break end
        local best
        for _, fn in ipairs(P.followers[cur.n] or {}) do
          local f = P.byN[fn]
          if not f.inList and not (f.id and (ids[f.id] or chainIds[f.id])) and (not best or (f.estValue or 0) > (best.estValue or 0)) then best = f end
        end
        if not best then break end
        cur = best
      end
      S.yield()
    end
  end
  table.sort(out, function(a, b) return a.rate > b.rate end)
  return out
end

-- Removes a task and the follow-ups depending on it.
local function Without(P, core, tn)
  local gone = { [tn] = true }
  local changed = true
  while changed do
    changed = false
    for _, st in ipairs(core) do
      local t = st.tn and P.byN[st.tn]
      if t and t.dep and gone[t.dep] and not gone[t.n] then
        gone[t.n], changed = true, true
      end
    end
  end
  local r = {}
  for _, st in ipairs(core) do
    if not (st.tn and gone[st.tn]) then r[#r + 1] = st end
  end
  return r
end

-- Step of the core nearest to a point (index), and its distance.
local function NearestStep(core, p)
  local bi, bd
  for i, st in ipairs(core) do
    local d = S.Dist(st.p, p)
    if d and (not bd or d < bd) then bi, bd = i, d end
  end
  return bi, bd
end

local function InsertAt(core, i, st)
  local r = {}
  for k = 1, i do r[k] = core[k] end
  r[#r + 1] = st
  for k = i + 1, #core do r[#r + 1] = core[k] end
  return r
end

---------------------------------------------------------------------------
-- Custom Roadbook: every step of the list, in an order its rules allow
---------------------------------------------------------------------------
-- P.custom = { steps = { step (ci = its index, ti = its quest's index, glueTo = ci of the step it
-- must follow right away) }, pred = { [ci] = { ci of the steps before it } }, tasks = { { id, title } },
-- first = ci of the step that must come first (service shortcut) }.
S.LEVEL_PENALTY = 3600

function S.ValidCustom(P, core)
  local pos = {}
  for i, st in ipairs(core) do if st.ci then pos[st.ci] = i end end
  local pred = P.custom.pred
  -- Service shortcut (P.custom.first): the first step of the route, whatever else is in it.
  if P.custom.first and (not core[2] or core[2].ci ~= P.custom.first) then return false end
  for i, st in ipairs(core) do
    if st.ci then
      if not st.relaxed then
        for _, pc in ipairs(pred[st.ci] or {}) do
          local j = pos[pc]
          if not j or j > i then return false end
        end
      end
      if st.glueTo and (not core[i - 1] or core[i - 1].ci ~= st.glueTo) then return false end
    end
  end
  return true
end

-- Cheapest insertion (quick estimate) of the steps of the list missing from the core, each one as soon
-- as the steps before it are placed. A cycle in the rules: one step is placed ignoring them (relaxed).
-- noise: random factor on the costs (rebuilds), rand(n): random integer 1..n.
function S.BuildCustom(P, core, rand, noise)
  local r, placed = {}, {}
  for i, st in ipairs(core) do
    r[i] = st
    if st.ci then placed[st.ci] = true end
  end
  local remaining = {}
  for _, st in ipairs(P.custom.steps) do
    if not placed[st.ci] then remaining[#remaining + 1] = st end
  end
  local relax = false
  while #remaining > 0 do
    local pos = {}
    for i, st in ipairs(r) do if st.ci then pos[st.ci] = i end end
    local best
    for ri, s in ipairs(remaining) do
      local lo, hi = ListRange(P.custom.pred, s, pos, #r, relax or s.relaxed)
      if lo then
        local j, d = CheapestSlot(P, r, s, lo, hi, function(b) return b.glueTo end, rand, noise)
        if j and (not best or d < best.d) then best = { ri = ri, j = j, d = d } end
      end
      S.yield()
    end
    if best then
      local s = table.remove(remaining, best.ri)
      table.insert(r, best.j + 1, s)
      if relax then s.relaxed = true end
      relax = false
    elseif not relax then
      relax = true
    else
      break
    end
  end
  return r
end

---------------------------------------------------------------------------
-- List with candidate quests (a duration or level goal with a list): the list is kept whole and
-- completed ("keep"), or only its part serving the goal best is kept ("pick")
---------------------------------------------------------------------------
-- Candidates already in the list are left out (inList); a candidate following a quest of the list
-- starts after that quest's turn-in step (depCi: its step, or the dungeon visit where it is turned in).
-- Units of the list: a quest, or the quests sharing a dungeon visit, added or removed whole ("pick").
function S.MixPrepare(P)
  local C = P.custom
  if C.units then return end
  local tiOf, turnin = {}, {}
  for ti, t in ipairs(C.tasks) do if t.id then tiOf[t.id] = ti end end
  for _, st in ipairs(C.steps) do
    if st.kind == "turnin" and st.ti then turnin[st.ti] = st.ci end
    for _, m in ipairs(st.members or {}) do
      if m.kind == "turnin" and m.id and tiOf[m.id] then turnin[tiOf[m.id]] = st.ci end
    end
  end
  for _, t in ipairs(P.tasks or {}) do
    if t.id and tiOf[t.id] then t.inList = true end
  end
  for _, t in ipairs(P.tasks or {}) do
    local d = t.dep and P.byN[t.dep]
    if d and d.inList and not t.inList then
      t.depCi, t.dep = turnin[tiOf[d.id]], nil
      if not t.depCi then t.inList = true end -- turn-in of the list quest not found: left out
    end
  end
  local parent = {}
  for ti in ipairs(C.tasks) do parent[ti] = ti end
  local function find(x)
    while parent[x] ~= x do x = parent[x] end
    return x
  end
  for _, st in ipairs(C.steps) do
    local first
    for _, m in ipairs(st.members or {}) do
      local ti = m.id and tiOf[m.id]
      if ti then
        if first then parent[find(ti)] = find(first) else first = ti end
      end
    end
    st.memberTi = first
  end
  C.unitOf, C.units, C.unitList = {}, {}, {}
  for _, st in ipairs(C.steps) do
    local ti = st.ti or st.memberTi
    local u = ti and find(ti) or -st.ci
    C.unitOf[st.ci] = u
    if not C.units[u] then
      C.units[u] = {}
      C.unitList[#C.unitList + 1] = u
    end
    table.insert(C.units[u], st.ci)
  end
end

-- Units of the list in a core.
function S.UnitsIn(P, core)
  local inCore = {}
  for _, st in ipairs(core) do if st.ci then inCore[P.custom.unitOf[st.ci]] = true end end
  return inCore
end

-- Inserts the steps of a unit of the list where they cost the least (quick estimate), each one once
-- the steps before it are placed. Returns the new core, or nil (a step before it is not in the core).
function S.InsertUnit(P, core, u, rand, noise)
  local C = P.custom
  local r = {}
  for i, st in ipairs(core) do r[i] = st end
  local remaining = {}
  for _, ci in ipairs(C.units[u]) do remaining[#remaining + 1] = C.steps[ci] end
  while #remaining > 0 do
    local pos = {}
    for i, st in ipairs(r) do if st.ci then pos[st.ci] = i end end
    local best
    for ri, s in ipairs(remaining) do
      local lo, hi = ListRange(C.pred, s, pos, #r, s.relaxed)
      if lo then
        local j, d = CheapestSlot(P, r, s, lo, hi, function(b) return b.glueTo or b.glue end, rand, noise)
        if j and (not best or d < best.d) then best = { ri = ri, j = j, d = d } end
      end
    end
    if not best then return nil end
    table.insert(r, best.j + 1, table.remove(remaining, best.ri))
  end
  return r
end

-- Removes a unit of the list, and the units needing it (a step before theirs, e.g. a prerequisite
-- turned in).
function S.WithoutUnit(P, core, u)
  local C = P.custom
  local gone = { [u] = true }
  local changed = true
  while changed do
    changed = false
    local present = {}
    for _, st in ipairs(core) do
      if st.ci and not gone[C.unitOf[st.ci]] then present[st.ci] = true end
    end
    for _, st in ipairs(core) do
      local v = st.ci and C.unitOf[st.ci]
      if v and not gone[v] and not st.relaxed then
        for _, pc in ipairs(C.pred[st.ci] or {}) do
          if not present[pc] then
            gone[v], changed = true, true
            break
          end
        end
      end
    end
  end
  local r = {}
  for _, st in ipairs(core) do
    if not (st.ci and gone[C.unitOf[st.ci]]) then r[#r + 1] = st end
  end
  return r
end

---------------------------------------------------------------------------
-- The search: construction, then moves tried on the route and kept when the goal value improves.
-- Every function below takes the search context X made by NewSearch:
--   problem and goal: P, goal, opts, W; custom (every step of the list), mixed (goal with a list)
--   and mode ("keep" / "pick"); valid(P, core): the order rules; svcUnit: the unit never removed;
--   budget and draws: t0, evals, maxEvals, maxTime, rand(n);
--   best route so far: core (its steps), score, res, route (S.Evaluate's result and route).
---------------------------------------------------------------------------
local function NewSearch(P, goal, opts)
  local W = S.World(P)
  S.Prepare(P)
  S.PrepareTasks(P)
  P.net0 = P.net0 or S.Network(W, S.KnownStart(P), P.player.speed)
  goal = S.Goal(P, goal)
  local custom = goal == "custom"
  local mixed = not custom and P.custom ~= nil and #(P.custom.steps or {}) > 0
  if custom or mixed then
    for _, st in ipairs(P.custom.steps) do S.Variants(st) end
  end
  if mixed then S.MixPrepare(P) end
  local valid = custom and S.ValidCustom or S.Valid
  if mixed then valid = function(p, c) return S.ValidCustom(p, c) and S.Valid(p, c) end end
  local seed = 12345
  local function rand(n)
    seed = (seed * 16807) % 2147483647
    return seed % n + 1
  end
  return { P = P, goal = goal, opts = opts, W = W, custom = custom, mixed = mixed, valid = valid, rand = rand,
    t0 = S.clock and S.clock() or 0, evals = 0,
    maxEvals = opts.maxEvals or S.OPT.MAX_EVALS, maxTime = opts.maxTime or S.OPT.MAX_TIME }
end

-- Budget used up (share: part of it, e.g. for the construction).
function S.SearchOut(X, share)
  if X.evals >= X.maxEvals * (share or 1) then return true end
  return S.clock and (S.clock() - X.t0) > X.maxTime * (share or 1) or false
end

function S.SearchSim(X, c)
  X.evals = X.evals + 1
  S.yield()
  return S.Simulate(X.P, c, X.goal)
end

local function Reached(X, res)
  if X.goal.kind == "level" then return res.reach ~= nil or res.time >= (X.opts.maxRouteTime or math.huge) end
  return res.time >= X.goal.value
end

-- c becomes the best route when valid and of a better goal value.
function S.SearchTry(X, c)
  if not X.valid(X.P, c) then return false end
  local res, route = S.SearchSim(X, c)
  local sc = S.Objective(X.P, res, X.goal)
  if sc < X.score - 1e-6 then
    X.core, X.score, X.res, X.route = c, sc, res, route
    return true
  end
  return false
end

-- Greedy construction: from c, adds the candidate bringing the most XP per second added, until the
-- goal. each(c, consider) calls consider(candidate) for every one. noise: each rate is multiplied by
-- a random factor up to 1 + noise (rebuilds explore other choices). penalize: a candidate adding a
-- rule broken counts less.
local function Greedy(X, c, noise, share, penalize, each)
  local P, goal = X.P, X.goal
  local cur = S.SearchSim(X, c)
  while not Reached(X, cur) and not S.SearchOut(X, share) do
    local best
    each(c, function(cand)
      if not (cand and X.valid(P, cand)) then return end
      local res = S.SearchSim(X, cand)
      if S.HardViolations(res) ~= 0 or (goal.kind == "time" and res.time > goal.value * S.OPT.OVERSHOOT) then return end
      local rate = (res.xp - cur.xp) / math.max(res.time - cur.time, 30)
      if penalize and #res.violations > #cur.violations then rate = rate / 10 end
      rate = Noisy(rate, X.rand, noise)
      if rate > 0 and (not best or rate > best.rate) then best = { core = cand, res = res, rate = rate } end
    end)
    if not best then break end
    c, cur = best.core, best.res
  end
  return c
end

-- c completed by what the search works with: quests or chains of quests until the goal; "pick":
-- units of the list; custom Roadbook: every step of the list, by cheapest insertion.
function S.Construct(X, c, noise, share)
  local P = X.P
  if X.custom then return S.BuildCustom(P, c, X.rand, noise) end
  if X.mode == "pick" then
    return Greedy(X, c, noise, share, true, function(core, consider)
      local inCore = S.UnitsIn(P, core)
      for _, u in ipairs(P.custom.unitList) do
        if not inCore[u] then consider(S.InsertUnit(P, core, u, X.rand, noise)) end
      end
    end)
  end
  return Greedy(X, c, noise, share, false, function(core, consider)
    local adds = S.Additions(P, core)
    for j = 1, math.min(S.OPT.TOP_K, #adds) do consider(adds[j].core) end
  end)
end

-- Moves: each tries changes of the best route (S.SearchTry) and tells whether one was kept.

-- Blocks of steps moved elsewhere in the route.
function S.MoveRelocate(X)
  local any = false
  for len = 1, S.OPT.MAX_SEGMENT do
    local i = 2
    while i + len - 1 <= #X.core and not S.SearchOut(X) do
      local seg, rest = {}, {}
      for k, st in ipairs(X.core) do
        if k >= i and k < i + len then seg[#seg + 1] = st else rest[#rest + 1] = st end
      end
      local moved = false
      for j = 1, #rest do
        if j ~= i - 1 then
          local c = {}
          for k = 1, j do c[k] = rest[k] end
          for _, st in ipairs(seg) do c[#c + 1] = st end
          for k = j + 1, #rest do c[#c + 1] = rest[k] end
          if S.SearchTry(X, c) then moved, any = true, true break end
        end
      end
      if not moved then i = i + 1 end
    end
  end
  return any
end

-- A quest, a bind or a flight path removed.
function S.MoveRemove(X)
  local any = false
  local i = 2
  while i <= #X.core and not S.SearchOut(X) do
    local st = X.core[i]
    local c
    if st.tn then c = Without(X.P, X.core, st.tn)
    elseif st.kind == "bind" or st.kind == "fm" then
      c = {}
      for k, x in ipairs(X.core) do if k ~= i then c[#c + 1] = x end end
    end
    if c and S.SearchTry(X, c) then any = true else i = i + 1 end
  end
  return any
end

-- A quest (or chain) added.
function S.MoveAdd(X)
  local any = false
  local adds = S.Additions(X.P, X.core)
  for j = 1, math.min(S.OPT.TOP_K, #adds) do
    if S.SearchOut(X) then break end
    if S.SearchTry(X, adds[j].core) then
      any = true
      adds = S.Additions(X.P, X.core)
    end
  end
  return any
end

-- A quest of the route replaced by a quest (or chain) that is not in it.
function S.MoveSwap(X)
  local any = false
  local tasks = {}
  for tn in pairs((Contents(X.core))) do tasks[#tasks + 1] = tn end
  table.sort(tasks)
  for _, tn in ipairs(tasks) do
    if S.SearchOut(X) then break end
    local inCore = Contents(X.core)
    if inCore[tn] then
      local base = Without(X.P, X.core, tn)
      local adds = S.Additions(X.P, base)
      for j = 1, math.min(5, #adds) do
        if adds[j].root.n ~= tn and S.SearchTry(X, adds[j].core) then any = true break end
      end
    end
  end
  return any
end

-- Units of the list removed ("pick"); the service shortcut's unit stays.
function S.MoveRemoveUnits(X)
  local P = X.P
  local any = false
  for _, u in ipairs(P.custom.unitList) do
    if S.SearchOut(X) then break end
    if u ~= X.svcUnit and S.UnitsIn(P, X.core)[u] and S.SearchTry(X, S.WithoutUnit(P, X.core, u)) then any = true end
  end
  return any
end

-- Units of the list added ("pick").
function S.MoveAddUnits(X)
  local P = X.P
  local any = false
  for _, u in ipairs(P.custom.unitList) do
    if S.SearchOut(X) then break end
    if not S.UnitsIn(P, X.core)[u] then
      local c = S.InsertUnit(P, X.core, u, X.rand)
      if c and S.SearchTry(X, c) then any = true end
    end
  end
  return any
end

-- Hunting spots: each objective step tried at its other dense spots; kept when the route gets better
-- (the detour from the route against the hunting time there).
function S.MoveSpots(X)
  local any = false
  for i = 2, #X.core do
    if S.SearchOut(X) then break end
    local st = X.core[i]
    for _, v in ipairs(st and st.variants or {}) do
      if v ~= X.core[i] then
        local c = {}
        for k, x in ipairs(X.core) do c[k] = x end
        c[i] = v
        if S.SearchTry(X, c) then any = true end
      end
    end
  end
  return any
end

-- Flight masters still to activate: unknown, and not already visited by the route (inCore, to be
-- completed by the caller as it adds them).
local function UnknownFlightMasters(X)
  local known = S.KnownStart(X.P)
  local inCore = {}
  for _, st in ipairs(X.core) do if st.kind == "fm" then inCore[st.fmNode] = true end end
  local list, n = X.P.world.fms or {}, 0
  return function()
    while n < #list do
      n = n + 1
      local fm = list[n]
      if fm.node and not known[fm.node] and not inCore[fm.node] then return fm end
    end
  end, inCore
end

local function FlightPathStep(P, fm, near)
  return { kind = "fm", p = fm.p, fmNode = fm.node, fm = fm, near = near, work = P.k.OVERHEAD / 2,
    title = "Flight path: " .. tostring(fm.name) }
end

local function FlightDetours(P)
  return not (P.player.settings and P.player.settings.noFMDetour)
end

-- Flight paths activated on the way: an unknown flight master near a step, visited after it.
function S.MoveFlightMasters(X)
  if not FlightDetours(X.P) then return false end
  local any = false
  local unknown, inCore = UnknownFlightMasters(X)
  for fm in unknown do
    if S.SearchOut(X) then break end
    local i, d = NearestStep(X.core, fm.p)
    if i and d <= S.OPT.FM_SEARCH and S.SearchTry(X, InsertAt(X.core, i, FlightPathStep(X.P, fm))) then
      any, inCore[fm.node] = true, true
    end
  end
  return any
end

-- Bind at an inn near a step (hearthstone, Astral Recall back to it later).
function S.MoveBinds(X)
  local P = X.P
  local bindSource = false
  for _, src in ipairs(P.world.recall or {}) do if src.bind then bindSource = true end end
  if not bindSource then return false end
  local any = false
  for _, inn in ipairs(P.world.inns or {}) do
    if S.SearchOut(X) then break end
    local same = S.Dist(inn.p, P.world.bind)
    if not (same and same < 60) then
      -- Every place near the inn is tried (after each step within the detour, the start included):
      -- the nearest step is often too late (a turn-in in town, after the hearth back).
      local st = { kind = "bind", p = inn.p, inn = inn, work = P.k.BIND_WORK, title = "Bind: " .. tostring(inn.name) }
      local places = {}
      for i, s in ipairs(X.core) do
        local d = S.Dist(s.p, inn.p)
        if d and d <= P.k.INN_DETOUR then places[#places + 1] = i end
      end
      for _, i in ipairs(places) do
        if S.SearchOut(X) then break end
        if S.SearchTry(X, InsertAt(X.core, i, st)) then any = true break end
      end
    end
  end
  return any
end

-- The moves of each search, tried in turn until none improves the route.
local function Moves(X)
  if X.custom then return { S.MoveRelocate, S.MoveSpots, S.MoveFlightMasters, S.MoveBinds } end
  if X.mode == "pick" then
    return { S.MoveRelocate, S.MoveSpots, S.MoveRemoveUnits, S.MoveAddUnits, S.MoveFlightMasters, S.MoveBinds }
  end
  return { S.MoveRelocate, S.MoveSpots, S.MoveRemove, S.MoveAdd, S.MoveSwap, S.MoveFlightMasters, S.MoveBinds }
end

-- Returns the number of rounds.
function S.LocalSearch(X)
  local rounds = 0
  repeat
    rounds = rounds + 1
    local improved = false
    for _, move in ipairs(Moves(X)) do
      if S.SearchOut(X) then break end
      if move(X) then improved = true end
    end
  until not improved or S.SearchOut(X)
  return rounds
end

-- The quests of the route and their steps (candidates: task numbers; custom: quests of the list;
-- "pick": units of the list): keys in order, steps by key.
local function RouteQuests(X)
  local steps, keys = {}, {}
  for _, st in ipairs(X.core) do
    local key
    if X.custom then key = st.ti
    elseif X.mode == "pick" then key = st.ci and X.P.custom.unitOf[st.ci]
    else key = st.tn end
    if key and key ~= X.svcUnit then
      if not steps[key] then
        steps[key] = {}
        keys[#keys + 1] = key
      end
      table.insert(steps[key], st)
    end
  end
  table.sort(keys)
  return keys, steps
end

-- The route without the quests of drop (a set of RouteQuests keys).
local function Destroyed(X, keys, drop)
  local c = X.core
  if X.custom then
    c = {}
    for _, st in ipairs(X.core) do
      if not (st.ti and drop[st.ti]) then c[#c + 1] = st end
    end
    return c
  end
  local without = X.mode == "pick" and S.WithoutUnit or Without
  for _, key in ipairs(keys) do
    if drop[key] then c = without(X.P, c, key) end
  end
  return c
end

-- Destroy and rebuild (large neighbourhood search): the quests of a zone, or a share of the quests
-- at random, are removed and the route is rebuilt by the construction; kept when better. Escapes
-- the dead ends of the moves above (e.g. a long block chosen first, that no single move can replace).
-- Returns the number of rebuilds kept and of local search rounds.
function S.DestroyAndRebuild(X)
  local rebuilt, rounds = 0, 0
  for it = 1, S.OPT.LNS_ROUNDS do
    if S.SearchOut(X) then break end
    local keys, steps = RouteQuests(X)
    if #keys == 0 then break end
    local zone = it % 2 == 1 and S.ZoneId(X.W, steps[keys[X.rand(#keys)]][1].p) or nil
    local drop = {}
    for _, key in ipairs(keys) do
      if zone then
        for _, st in ipairs(steps[key]) do
          if S.ZoneId(X.W, st.p) == zone then drop[key] = true break end
        end
      else
        drop[key] = X.rand(100) <= S.OPT.LNS_SHARE
      end
    end
    if S.SearchTry(X, S.Construct(X, Destroyed(X, keys, drop), S.OPT.LNS_NOISE)) then
      rebuilt = rebuilt + 1
      rounds = rounds + S.LocalSearch(X)
    end
  end
  return rebuilt, rounds
end

-- Flight masters right next to a step of the final route: activated whatever the gain ("activate
-- nearby flight masters"). A flight path is worth it later, once the other end is known too, which the
-- goal of this route does not see. Each one goes where the goal value suffers least.
function S.AddNearbyFlightMasters(X)
  local P = X.P
  if not FlightDetours(P) then return end
  local unknown, inCore = UnknownFlightMasters(X)
  for fm in unknown do
    local st = FlightPathStep(P, fm, true)
    local bc, bs, br, bscore
    for i, s in ipairs(X.core) do
      local d = S.Dist(s.p, fm.p)
      if d and d <= S.OPT.FM_NEAR then
        local c = InsertAt(X.core, i, st)
        if X.valid(P, c) then
          local res, route = S.SearchSim(X, c)
          local sc = S.Objective(P, res, X.goal)
          if not bscore or sc < bscore then bc, bs, br, bscore = c, res, route, sc end
        end
      end
    end
    if bc then X.core, X.res, X.route, X.score, inCore[fm.node] = bc, bs, br, bscore, true end
  end
end

-- Best Roadbook for a goal: construction (quests or chains of quests with the most XP per second
-- added, until the goal is reached), then local search on the goal value: blocks of steps moved,
-- quests removed or added, binds at an inn, flight paths activated on the way.
-- "custom": every step of the list. A duration or level goal with a list (P.custom): the whole list
-- when it does not reach the goal, completed with candidate quests (mode "keep"); otherwise the units
-- of the list (quests) serving the goal best (mode "pick"), without candidates.
-- Returns { route, res, core, evals, seconds, goal, mode }.
function S.Optimize(P, goal, opts)
  local X = NewSearch(P, goal, opts or {})
  local start = { { kind = "start", p = P.player.pos, work = 0 } }
  if X.mixed then
    -- The whole list reaching the goal: only its best part; otherwise all of it, completed.
    local whole = S.BuildCustom(P, start, X.rand)
    X.mode = Reached(X, (S.SearchSim(X, whole))) and "pick" or "keep"
    if X.mode == "keep" then start = whole
    elseif P.custom.first then start = { start[1], P.custom.steps[P.custom.first] } end -- service shortcut kept
    X.svcUnit = P.custom.first and P.custom.unitOf[P.custom.first] or nil
  end
  X.core = S.Construct(X, start, nil, S.OPT.BUILD_SHARE)
  X.res, X.route = S.SearchSim(X, X.core)
  X.score = S.Objective(P, X.res, X.goal)
  local rounds = S.LocalSearch(X)
  local rebuilt, more = S.DestroyAndRebuild(X)
  S.AddNearbyFlightMasters(X)
  return { route = X.route, res = X.res, core = X.core, evals = X.evals, rounds = rounds + more, rebuilt = rebuilt,
    goal = X.goal, mode = X.mode, seconds = S.clock and (S.clock() - X.t0) or nil, score = X.score }
end

-- Shared with the next files.
ns.Solver = S
return S
