-- Forever Quest Planner: Roadbook: transport stops, hearthstone, route optimization (PlanXP).
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, BuildNetwork, BuildScanContext, BuildTasks, CharKey, DBXP, Dist = ns.AreaName, ns.BuildNetwork, ns.BuildScanContext, ns.BuildTasks, ns.CharKey, ns.DBXP, ns.Dist
local Geo, GetItemInfoCompat, InsertStops, K, L, MakeTravel = ns.Geo, ns.GetItemInfoCompat, ns.InsertStops, ns.K, ns.L, ns.MakeTravel
local PlayerPos, Print, Route, Settings, TaxiCount, TravelSpeed = ns.PlayerPos, ns.Print, ns.Route, ns.Settings, ns.TaxiCount, ns.TravelSpeed
local WorldPos, scan = ns.WorldPos, ns.scan

---------------------------------------------------------------------------
-- Transports: "take the flight / zeppelin / boat" step at the boarding point
---------------------------------------------------------------------------
-- World point (c, x, y) -> displayable/pinnable point (zone map + 0-100 coordinates).
function Geo.MapPoint(w)
  if w.ui or w.area then return w end
  if not (C_Map.GetMapPosFromWorldPos and CreateVector2D) then return w end
  local vec = CreateVector2D(w.x, w.y)
  local ok, ui, mp = pcall(C_Map.GetMapPosFromWorldPos, w.c, vec)
  if not (ok and ui and mp) then return w end
  local mx, my = mp:GetXY()
  local zoneName
  if C_Map.GetMapInfoAtPosition then
    local okI, info = pcall(C_Map.GetMapInfoAtPosition, ui, mx, my)
    if okI and info and info.mapID and info.mapID ~= ui then
      local ok2, ui2, mp2 = pcall(C_Map.GetMapPosFromWorldPos, w.c, vec, info.mapID)
      if ok2 and ui2 and mp2 then ui, mx, my = ui2, mp2:GetXY() end
    end
    if okI and info then zoneName = info.name end
  end
  if not zoneName and C_Map.GetMapInfo then
    local okM, mi = pcall(C_Map.GetMapInfo, ui)
    zoneName = okM and mi and mi.name or nil
  end
  return { c = w.c, x = w.x, y = w.y, ui = ui, mx = mx * 100, my = my * 100, zoneName = zoneName }
end

-- Boardings of a route: { hub, mode ("vol", "zeppelin", "bateau"), dest }.
function Geo.Boardings(choice, net)
  local out = {}
  local hubs, cur = net.hubs, choice.i
  local run
  while cur ~= choice.j do
    local nx = net.nxt[cur][choice.j]
    local mode = net.via[cur][nx]
    if mode == "flight" then
      if not run then
        run = { hub = hubs[cur], mode = "vol" }
        out[#out + 1] = run
      end
      run.dest = hubs[nx]
    else
      run = nil
      if mode == "zeppelin" or mode == "bateau" then
        out[#out + 1] = { hub = hubs[cur], mode = mode, dest = hubs[nx] }
      end
    end
    cur = nx
  end
  return out
end

-- Network of the leg arriving at route[k]: a single network, or a function k -> network
-- (custom Roadbook: flight paths activated on the way become usable after their step).
function Geo.LegNet(net, k)
  if type(net) == "function" then return net(k) end
  return net
end

-- Adds a step at the boarding point of each transport used by the route.
function Geo.AddTransportStops(route, nets, plevel)
  local out = { route[1] }
  for k = 2, #route do
    local cur = route[k]
    local net = Geo.LegNet(nets, k)
    if cur.kind ~= "hearth" and not cur.glue and #net.hubs > 0 then -- escort: on foot, with the NPC
      local _, choice = Route(out[#out].p, cur.p, net, plevel)
      if choice then
        for _, b in ipairs(Geo.Boardings(choice, net)) do
          local what = (b.mode == "vol" and L["Take the flight"]) or (L["Take the "] .. (K.MODE_NAME[b.mode] or b.mode))
          out[#out + 1] = { kind = "travel", p = Geo.MapPoint(b.hub.p), work = 0,
            task = { title = what .. L[": "] .. (b.hub.name or "?") .. " -> " .. (b.dest and b.dest.name or "?"),
              mode = b.mode, from = b.hub.name, dest = b.dest and b.dest.name, destP = b.dest and b.dest.p,
              xp = 0, travel = true } }
        end
      end
    end
    out[#out + 1] = cur
  end
  return out
end

---------------------------------------------------------------------------
-- Hearthstone: bind at an innkeeper and hearth back, to save travel time
---------------------------------------------------------------------------
K.HEARTHSTONE = 6948
K.HEARTH_SPELL = 8690
K.HEARTH_TIME = 30      -- cast (10 s) + teleport
K.HEARTH_CD = 3600      -- hearthstone cooldown
K.HEARTH_MIN_GAIN = 120 -- minimum gain (s) to suggest hearthing
K.BIND_WORK = 20        -- talking to the innkeeper
K.INN_DETOUR = 500      -- maximum detour (m, as the crow flies) to go and bind

function Geo.BindStore()
  local st = Settings()
  st.bind = st.bind or {}
  return st.bind
end

-- Remembers the bind location (inn position) for this character.
function Geo.RecordBind(p)
  if not p then return end
  local mp = Geo.MapPoint({ c = p.c, x = p.x, y = p.y })
  Geo.BindStore()[CharKey()] = { c = p.c, x = p.x, y = p.y, area = p.area, mx = p.mx or mp.mx, my = p.my or mp.my,
    ui = (not p.area) and mp.ui or nil, zoneName = mp.zoneName, name = GetBindLocation and GetBindLocation() or nil }
end

-- Zones (zone ids) with this name, or containing the subzone with this name.
function Geo.ZonesNamed(name)
  local zones = {}
  for id in pairs(Geo.areaToUi or {}) do
    if AreaName(id) == name then zones[Geo.parent[id] or id] = true end
  end
  for id, parent in pairs(Geo.parent or {}) do
    if AreaName(id) == name then zones[parent] = true end
  end
  return zones
end

-- Estimated bind location from its name, from the most to the least precise:
-- the innkeeper of that zone, the center of the zone's innkeepers, the center of the zone.
function Geo.GuessBind(name)
  if Geo.bindGuess and Geo.bindGuess.name == name then return Geo.bindGuess.p end
  local zones = Geo.ZonesNamed(name)
  local list = {}
  for _, inn in ipairs(Geo.Innkeepers()) do
    local a = inn.p.area
    if AreaName(a) == name or zones[a] or (Geo.parent[a] and zones[Geo.parent[a]]) then list[#list + 1] = inn.p end
  end
  local p
  if #list == 1 then
    p = list[1]
  elseif #list > 1 then
    local c, x, y, n = list[1].c, 0, 0, 0
    for _, q in ipairs(list) do
      if q.c == c then x, y, n = x + q.x, y + q.y, n + 1 end
    end
    p = Geo.MapPoint({ c = c, x = x / n, y = y / n })
    p.approx = true
  else
    for zid in pairs(zones) do
      local w = WorldPos(zid, 50, 50)
      if w then
        p = w
        p.approx = true
        break
      end
    end
  end
  Geo.bindGuess = { name = name, p = p }
  return p
end

-- Current bind location: remembered position, otherwise estimated from the location name.
function Geo.CurrentBind()
  local name = GetBindLocation and GetBindLocation() or nil
  local st = Geo.BindStore()[CharKey()]
  if st and (not name or st.name == name) then return st, name end
  if name then return Geo.GuessBind(name), name end
  return nil, name
end

-- Seconds until the hearthstone is ready (0 = ready), nil if there is no hearthstone.
function Geo.HearthReady()
  local count = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(K.HEARTHSTONE))
    or (GetItemCount and GetItemCount(K.HEARTHSTONE)) or 0
  if count == 0 then return nil end
  local cd = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
  if cd and GetTime then
    local start, dur = cd(K.HEARTHSTONE)
    if start and dur and start > 0 and dur > 0 then return math.max(0, start + dur - GetTime()) end
  end
  return 0
end

function Geo.RouteTime(route, travel)
  local t = 0
  for i = 2, #route do t = t + travel(route[i - 1].p, route[i].p) + route[i].work end
  return t
end

function Geo.HearthStep(bindP, gain)
  local dest = AreaName(bindP.area) or bindP.zoneName or bindP.name or "?"
  return { kind = "hearth", work = 0, gain = gain,
    p = { c = bindP.c, x = bindP.x, y = bindP.y, area = bindP.area, ui = bindP.ui, mx = bindP.mx, my = bindP.my,
      zoneName = bindP.zoneName, teleport = true },
    task = { title = L["Hearthstone: back to "] .. dest, xp = 0, hearth = true } }
end

-- Places hearths where they save the most, respecting the cooldown.
-- The bind location changes after a "bind" step.
function Geo.ApplyHearth(route, travel, bind0, ready0)
  local cands, clock, bindP = {}, 0, bind0
  for i = 2, #route do
    local prev, cur = route[i - 1], route[i]
    local normal = travel(prev.p, cur.p)
    if bindP and cur.kind ~= "hearth" and not cur.glue then
      local gain = normal - (K.HEARTH_TIME + travel(bindP, cur.p))
      if gain >= K.HEARTH_MIN_GAIN then cands[#cands + 1] = { i = i, t = clock, gain = gain, bindP = bindP } end
    end
    clock = clock + normal + cur.work
    if cur.kind == "bind" then bindP = cur.bindP end
  end
  table.sort(cands, function(a, b) return a.gain > b.gain end)
  local chosen, byIndex, total = {}, {}, 0
  for _, c in ipairs(cands) do
    local ok = c.t >= ready0
    for _, o in ipairs(chosen) do
      if math.abs(c.t - o.t) < K.HEARTH_CD then ok = false break end
    end
    if ok then
      chosen[#chosen + 1] = c
      byIndex[c.i] = c
      total = total + c.gain
    end
  end
  if #chosen == 0 then return route, 0 end
  local out = { route[1] }
  for i = 2, #route do
    local c = byIndex[i]
    if c then out[#out + 1] = Geo.HearthStep(c.bindP, c.gain) end
    out[#out + 1] = route[i]
  end
  return out, total
end

-- Removes hearths that became impossible (stone not ready yet) and recomputes their gain.
function Geo.FixHearth(route, travel, ready0)
  local out, clock, ready = { route[1] }, 0, ready0
  for i = 2, #route do
    local s = route[i]
    local keep = true
    if s.kind == "hearth" then
      if clock < ready then keep = false else ready = clock + K.HEARTH_CD end
    end
    if keep then
      clock = clock + travel(out[#out].p, s.p) + s.work
      out[#out + 1] = s
    end
  end
  -- A bind with no hearth after it is useless.
  local final, needed = {}, false
  for i = #out, 1, -1 do
    local s = out[i]
    if s.kind == "hearth" then needed = true end
    if s.kind == "bind" then
      if needed then table.insert(final, 1, s) end
      needed = false
    else
      table.insert(final, 1, s)
    end
  end
  return final
end

-- Best strategy: hearths to the current bind location, or binding at an inn
-- met on the way and then hearthing back to it.
function Geo.OptimizeHearth(route, travel)
  if Settings().noHearth or #route < 3 then return route end
  local ready0 = Geo.HearthReady()
  if not ready0 then return route end
  local bind0 = Geo.CurrentBind()
  local best, bestT = route, Geo.RouteTime(route, travel)
  if bind0 then
    local r, gain = Geo.ApplyHearth(route, travel, bind0, ready0)
    if gain > 0 then
      local t = Geo.RouteTime(r, travel)
      if t < bestT then best, bestT = r, t end
    end
  end
  for _, inn in ipairs(Geo.Innkeepers()) do
    local same = bind0 and Dist(bind0, inn.p)
    if not (same and same < 60) then
      local bestK, bestD
      for k = 2, #route do
        if route[k].kind ~= "hearth" and not route[k].glue then
          local a, b = route[k - 1].p, route[k].p
          local d1, d2, d0 = Dist(a, inn.p), Dist(inn.p, b), Dist(a, b)
          if d1 and d2 and d0 and (not bestD or d1 + d2 - d0 < bestD) then bestK, bestD = k, d1 + d2 - d0 end
        end
      end
      if bestK and bestD <= K.INN_DETOUR then
        local r = {}
        for k = 1, #route do
          if k == bestK then
            r[#r + 1] = { kind = "bind", p = inn.p, bindP = inn.p, work = K.BIND_WORK,
              task = { title = L["Bind your hearthstone: "] .. (AreaName(inn.p.area) or "?"), npc = inn.name, xp = 0, bind = true } }
          end
          r[#r + 1] = route[k]
        end
        local r2, gain = Geo.ApplyHearth(r, travel, bind0, ready0)
        if gain > 0 then
          local t = Geo.RouteTime(r2, travel)
          if t < bestT - K.HEARTH_MIN_GAIN then best, bestT = r2, t end
        end
      end
    end
  end
  return best
end

-- Task insertion constraints: after the turn-in of the quest it follows, and after the
-- moment the expected level reaches its required level. Returns the index to insert after, or nil.
function Geo.StartIndex(task, lv, idx)
  local si = 1
  if task.dep then
    local i = idx[task.dep.stops[#task.dep.stops]]
    if not i then return nil end
    si = i
  end
  if task.reqLevel then
    local found
    for i = si, #lv do
      if lv[i] >= task.reqLevel then found = i break end
    end
    if not found then return nil end
    si = found
  end
  return si
end

function Geo.Index(route)
  local idx = {}
  for i, st in ipairs(route) do idx[st] = i end
  return idx
end

-- Checks that no quest is picked up before reaching its required level.
function Geo.LevelsOK(route)
  local lv = Geo.Levels(route)
  for i = 2, #route do
    local st = route[i]
    if st.kind == "take" and st.task.reqLevel and lv[i - 1] < st.task.reqLevel then return false end
  end
  return true
end

-- Local improvement: moves each step to the best allowed place (order of a quest's
-- steps, follow-ups after their parent quest, required level) as long as the route gets shorter.
function Geo.Improve(route, travel)
  for _ = 1, 3 do
    local improved = false
    local i = 2
    while i <= #route do
      local st = route[i]
      local task = st.task
      -- An escort and its pick-up are not moved (they must stay side by side).
      if task and st.kind ~= "start" and not st.glue and not (route[i + 1] and route[i + 1].glue) then
        local prev, nxt = route[i - 1], route[i + 1]
        local gain = travel(prev.p, st.p) + (nxt and (travel(st.p, nxt.p) - travel(prev.p, nxt.p)) or 0)
        table.remove(route, i)
        -- Allowed window (insertion after index j, lo <= j <= hi).
        local lo, hi = 1, #route
        local last = task.stops[#task.stops]
        local depLast = task.dep and task.dep.stops[#task.dep.stops]
        local seenSelfAfter = false
        for j = 1, #route do
          local o = route[j]
          if o.task == task then
            if j < i then lo = math.max(lo, j) elseif not seenSelfAfter then hi = math.min(hi, j - 1) seenSelfAfter = true end
          end
          if depLast and o == depLast then lo = math.max(lo, j) end
          if st == last and o.task and o.task.dep == task and o.kind == "take" then hi = math.min(hi, j - 1) end
        end
        local bestJ, bestC
        for j = lo, hi do
          if j ~= i - 1 and not (route[j + 1] and route[j + 1].glue) then
            local a, b = route[j], route[j + 1]
            local c = travel(a.p, st.p) + (b and (travel(st.p, b.p) - travel(a.p, b.p)) or 0)
            if not bestC or c < bestC then bestJ, bestC = j, c end
          end
        end
        if bestC and bestC < gain - 1 then
          table.insert(route, bestJ + 1, st)
          if Geo.LevelsOK(route) then
            improved = true
          else
            table.remove(route, bestJ + 1)
            table.insert(route, i, st)
          end
        else
          table.insert(route, i, st)
        end
      end
      i = i + 1
      Geo.Yield()
    end
    if not improved then break end
  end
  return route
end

-- Reward items of the quests (log and available) asked to the game before planning, up to
-- K.ITEM_WAIT seconds: otherwise an item not cached yet counts as "no interest" and the next
-- computation, with the data, gives another Roadbook.
K.ITEM_WAIT = 3
function Geo.PreloadRewardItems()
  local idx, missing = Geo.RewardIndex(), {}
  local function want(qid)
    for _, itemId in ipairs(idx[qid] or {}) do
      if not GetItemInfoCompat(itemId) then -- asks the server when not cached
        missing[#missing + 1] = itemId
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemId) end
      end
    end
  end
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do want(q.id) end
  for _, en in ipairs(scan.entries or {}) do want(en.id) end
  local start = GetTime and GetTime() or 0
  while #missing > 0 and Geo.co and coroutine.running() == Geo.co and (GetTime() - start) < K.ITEM_WAIT do
    coroutine.yield() -- next frame
    local still = {}
    for _, itemId in ipairs(missing) do
      if not GetItemInfoCompat(itemId) then still[#still + 1] = itemId end
    end
    missing = still
  end
end

-- Goal of the automatic Roadbook: { kind = "time", value = seconds } (most XP in that time) or
-- { kind = "level", value = level } (fastest route to that level).
-- A far level is reached in stages: one computation plans at most this much, then "Generate"
-- at the end of the Roadbook computes the next stage (with the real XP and flight paths).
K.LEVEL_PLAN_MAX_TIME = 40 * 3600 -- level goal: longest Roadbook computed
K.MAX_PLAN_QUESTS_LEVEL = 300      -- level goal: most quests in the Roadbook
K.LEVEL_INSERT_WINDOW = 60         -- level goal: a quest is inserted among the last steps only (speed)
K.LEVEL_IMPROVE_MAX = 250          -- level goal: route shortened only up to this many steps (speed)

-- Quest XP when it is done at the expected level `level` (lower once the quest turns green or gray).
function Geo.TaskXPAt(task, level, plevel)
  if not task.id or level == plevel then return task.xp or 0 end
  local xp = DBXP(task.id, level)
  if not xp then return task.xp or 0 end
  return math.min(xp, task.xp or xp)
end

-- Level reached at the end of a route.
function Geo.EndLevel(route)
  local lv = Geo.Levels(route)
  return lv[#lv]
end

local function PlanXP(goal)
  Geo.PreloadRewardItems()
  local pos = PlayerPos()
  if not pos then return nil, L["Unknown position (in an instance or map unavailable)."] end
  local plevel = UnitLevel("player")
  if plevel >= Geo.MaxLevel() then
    return nil, L["Max level reached: no more XP to earn. Use the custom Roadbook to choose your quests."]
  end
  local byLevel = goal.kind == "level"
  local target = byLevel and math.max(goal.value, plevel + 1) or nil
  local horizon = byLevel and K.LEVEL_PLAN_MAX_TIME or goal.value
  local limit = byLevel and horizon or horizon * 1.1 -- time a candidate may reach
  local maxQuests = byLevel and K.MAX_PLAN_QUESTS_LEVEL or K.MAX_PLAN_QUESTS
  local function goalReached(route, total)
    if byLevel then return Geo.EndLevel(route) >= target end
    return total >= horizon
  end
  Geo.xpScale = nil
  Geo.laterList, Geo.laterCache = {}, {}
  local speed = TravelSpeed()
  Geo.planSpeed = speed
  local net = BuildNetwork(speed)
  local travel = MakeTravel(net, plevel)
  local tasks, skipped = BuildTasks(pos, plevel)
  local ctx = BuildScanContext()
  -- Insertion of a quest's steps; far level goal: only among the last steps of the route (it is
  -- built in time order), otherwise a long route makes every insertion too slow.
  local function insert(r, stops, si)
    if byLevel then si = math.max(si or 1, #r - K.LEVEL_INSERT_WINDOW) end
    return InsertStops(r, stops, travel, si)
  end

  local route = { { kind = "start", p = pos, work = 0 } }
  local total, count = 0, 0
  local usedIds = {}

  -- What inserting a task unlocks: its follow-ups, and the quests whose required level is
  -- reached thanks to its XP.
  -- What inserting a task unlocks, evaluated as a whole:
  -- * the quest's whole chain (every step doable within the session, with its XP,
  --   its rewards, its required level), keeping the best value / time ratio;
  -- * the quests whose required level is reached thanks to its XP.
  local function lookahead(task, nr, d, lvEnd, locked)
    local best
    local function consider(v, dd)
      local sc = v / math.max(dd, 30)
      if not best or sc > best then best = sc end
    end
    local base = task.value
    if #locked > 0 then
      local nlv = Geo.Levels(nr)
      if nlv[#nlv] > lvEnd then
        local nidx = Geo.Index(nr)
        for _, u in ipairs(locked) do
          if u.reqLevel <= nlv[#nlv] and not usedIds[u.id] and not u.dep then
            local si = Geo.StartIndex(u, nlv, nidx)
            if si then
              local du = insert(nr, u.stops, si)
              if total + d + du <= limit then consider(base + u.value, d + du) end
            end
          end
        end
      end
    end
    -- Whole chain: chain, step by step, the best available follow-up.
    local cur, r, v, dd = task, nr, base, d
    local seen = { [task.id or 0] = true }
    for _ = 1, K.MAX_FOLLOW_DEPTH do
      local followers = Geo.Followers(cur, ctx, plevel)
      if #followers == 0 then break end
      local lvR, idxR = Geo.Levels(r), Geo.Index(r)
      local pick
      for _, u in ipairs(followers) do
        if u.stops and not usedIds[u.id] and not seen[u.id] then
          local si = Geo.StartIndex(u, lvR, idxR)
          if si then
            local du, ur = insert(r, u.stops, si)
            if total + dd + du <= limit then
              local val = u.value
              local rate = val / math.max(du, 30)
              if not pick or rate > pick.rate then pick = { u = u, du = du, r = ur, val = val, rate = rate } end
            end
          end
        end
      end
      if not pick then break end
      seen[pick.u.id] = true
      v, dd, r, cur = v + pick.val, dd + pick.du, pick.r, pick.u
      consider(v, dd)
    end
    return best
  end

  local function fill()
    while count < maxQuests and not goalReached(route, total) do
      local lv, idx = Geo.Levels(route), Geo.Index(route)
      local lvEnd = lv[#lv]
      local locked = {}
      for _, task in ipairs(tasks) do
        if task.stops and not task.used and task.reqLevel and task.reqLevel > lvEnd and not usedIds[task.id] then
          locked[#locked + 1] = task
        end
      end
      local best
      for _, task in ipairs(tasks) do
        if task.stops and not task.used and not usedIds[task.id] and (not task.dep or task.dep.used) then
          local si = Geo.StartIndex(task, lv, idx)
          if si then
            local d, nr = insert(route, task.stops, si)
            if total + d <= limit then
              -- XP at the level expected when the quest is done (less if it turned green or gray).
              local qxp = Geo.TaskXPAt(task, lv[si], plevel)
              local value = task.value - (task.xp or 0) + qxp
              local score = value / math.max(d, 30)
              local pair = lookahead(task, nr, d, lvEnd, locked)
              if pair and pair * K.LOOKAHEAD_WEIGHT > score then score = pair * K.LOOKAHEAD_WEIGHT end
              if not best or score > best.score then best = { task = task, score = score, d = d, route = nr, xp = qxp } end
            end
          end
          Geo.Yield()
        end
      end
      if not best then break end
      best.task.used = true
      if best.task.id then usedIds[best.task.id] = true end
      if best.xp ~= (best.task.xp or 0) then -- done at a higher level: its turn-in gives less XP
        local last = best.task.stops[#best.task.stops]
        if last and last.kind == "turnin" then last.xp = best.xp end
        best.task.value = best.task.value - (best.task.xp or 0) + best.xp
        best.task.xp = best.xp
      end
      route, total, count = best.route, total + best.d, count + 1
      -- The chosen quest's follow-ups become candidates.
      for _, f in ipairs(Geo.Followers(best.task, ctx, plevel)) do tasks[#tasks + 1] = f end
    end
  end

  fill()
  -- Shorten the route, then use the saved time for other quests.
  if not byLevel or #route <= K.LEVEL_IMPROVE_MAX then
    route = Geo.Improve(route, travel)
    total = Geo.RouteTime(route, travel)
    fill()
  end

  -- Hearthstone: bind + hearths, then the saved time is used to add quests.
  local okH, withH = pcall(Geo.OptimizeHearth, route, travel)
  if not okH then Print(L["Hearthstone error: "] .. tostring(withH)) end
  if okH and withH and withH ~= route then
    route = withH
    total = Geo.RouteTime(route, travel)
    fill()
    route = Geo.FixHearth(route, travel, Geo.HearthReady() or 0)
  end

  route = Geo.FinishRoute(route, net, travel, plevel)
  local info = Geo.RouteInfo(route, travel)
  info.speed, info.skipped, info.count, info.net, info.plevel, info.later = speed, skipped, count, net, plevel, Geo.laterList
  info.goal = { kind = goal.kind, value = byLevel and target or goal.value }
  -- Target not reached in one computation (its size, or the quests known now): this Roadbook is a
  -- stage; "Generate" at its end plans the next one from the real level, XP and flight paths.
  if byLevel and Geo.EndLevel(route) < target then info.goalStage = true end
  return route, nil, info
end

-- Last steps of a route: activation of the unknown flight masters met on the way (if the option is
-- on), then the flight / zeppelin / boat boarding steps.
function Geo.FinishRoute(route, net, travel, plevel)
  if not Settings().noFMDetour then
    local okFM, withFM = pcall(Geo.AddFlightMasterStops, route, net, plevel)
    if okFM and withFM then route = withFM end
  end
  local okT, withT = pcall(Geo.AddTransportStops, route, net, plevel)
  if not okT then Print(L["Transport steps error: "] .. tostring(withT)) end
  if okT and withT then route = withT end
  return route
end

-- Exact time and XP along a route (st.at = time at the end of each step).
function Geo.RouteInfo(route, travel)
  local t, questXP, mobXP = 0, 0, 0
  for i = 2, #route do
    local st = route[i]
    t = t + travel(route[i - 1].p, st.p) + st.work
    st.at = t
    if st.kind == "turnin" then questXP = questXP + (st.xp or 0) end
    if st.kind == "obj" then mobXP = mobXP + (st.xp or 0) end
  end
  return { total = t, xp = questXP + mobXP, mobXP = mobXP, levels = Geo.Levels(route) }
end

-- Skipped quest: its steps leave the saved Roadbook `fz` and the route of the steps left is
-- adapted: the travel, flight master and hearthstone steps are computed again for them, in the
-- same order (no quest is added). isDone(st): step done, kept as it is at the start of the route.
-- Returns the new route and its info.
Geo.AUX_STEPS = { travel = true, fm = true, hearth = true, bind = true }
function Geo.Reroute(fz, id, isDone)
  local plevel = UnitLevel("player")
  local speed = TravelSpeed()
  local net = BuildNetwork(speed)
  local travel = MakeTravel(net, plevel)
  local old = fz.route
  local done, doneIdx, todo = {}, {}, {}
  for i = 2, #old do
    local st = old[i]
    if isDone(st) then
      done[#done + 1] = st
      doneIdx[#doneIdx + 1] = i
    elseif not (st.task and st.task.id == id) and not Geo.AUX_STEPS[st.kind] then
      todo[#todo + 1] = st
    end
  end
  local pos = PlayerPos() or (done[#done] or old[1]).p
  local rest = { { kind = "start", p = pos, work = 0 } }
  for _, st in ipairs(todo) do rest[#rest + 1] = st end
  if #rest >= 3 then
    local okH, withH = pcall(Geo.OptimizeHearth, rest, travel)
    if okH and withH and withH ~= rest then rest = Geo.FixHearth(withH, travel, Geo.HearthReady() or 0) end
  end
  rest = Geo.FinishRoute(rest, net, travel, plevel)
  local restInfo = Geo.RouteInfo(rest, travel)
  -- Steps done first (their time and level as planned), then the steps left from now on.
  local oldLv = fz.info.levels or {}
  local route, levels = { old[1] }, { oldLv[1] or plevel }
  local t0 = 0
  for k, st in ipairs(done) do
    route[#route + 1] = st
    levels[#levels + 1] = oldLv[doneIdx[k]] or levels[#levels]
    t0 = math.max(t0, st.at or 0)
  end
  for i = 2, #rest do
    rest[i].at = t0 + (rest[i].at or 0)
    route[#route + 1] = rest[i]
    levels[#levels + 1] = restInfo.levels[i]
  end
  local info = {}
  for k, v in pairs(fz.info) do info[k] = v end
  local xp, mobXP, ids = 0, 0, {}
  for i = 2, #route do
    local st = route[i]
    if st.kind == "turnin" then xp = xp + (st.xp or 0) end
    if st.kind == "obj" then mobXP = mobXP + (st.xp or 0) end
    if st.task and st.task.id then ids[st.task.id] = true end
  end
  local count = 0
  for _ in pairs(ids) do count = count + 1 end
  info.xp, info.mobXP, info.count = xp + mobXP, mobXP, count
  info.total = t0 + restInfo.total
  info.levels, info.net, info.speed = levels, net, speed
  info.net.taxi = TaxiCount()
  if info.goal and info.goal.kind == "level" then info.goalStage = (levels[#levels] or 0) < info.goal.value or nil end
  return route, info
end

-- Roadbook computation in the background (spread over several frames) with caching.
-- goal: goal of the automatic Roadbook ({ kind, value }) or "custom" (custom Roadbook, its quest list in the key).
function Geo.GoalKey(goal)
  if goal == "custom" then return goal end
  return goal.kind .. goal.value
end

function Geo.PlanKey(goal)
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  local b = Geo.BindStore()[CharKey()]
  local list = {}
  if goal == "custom" then
    for _, it in ipairs(Geo.CustomList()) do list[#list + 1] = it.id end
  end
  return table.concat({ Geo.GoalKey(goal), table.concat(list, ","), tostring(Settings().noHearth),
    tostring(Settings().noFMDetour), UnitLevel("player"),
    UnitXP and UnitXP("player") or 0, e and e.updated or "", tostring(scan.entries), TaxiCount(),
    tostring(b and b.name), tostring(Settings().mountSpeed), Geo.paramsVersion or 0 }, "|")
end

-- Returns true if the cached plan is up to date; otherwise starts (or continues) the computation and
-- calls cb(route, err, info) when done. force = recompute even if the cache is valid.
function Geo.RequestPlan(goal, cb, force)
  local key = Geo.PlanKey(goal)
  local pos = PlayerPos()
  local cacheField = goal == "custom" and "customCache" or "planCache"
  local c = Geo[cacheField]
  if not force and c and c.key == key and pos and c.pos and (Dist(pos, c.pos) or math.huge) < K.REPLAN_DISTANCE then
    return true
  end
  if cb then
    Geo.planCbs = Geo.planCbs or {}
    local dup = false
    for _, f in ipairs(Geo.planCbs) do if f == cb then dup = true break end end
    if not dup then table.insert(Geo.planCbs, cb) end
  end
  if Geo.co and Geo.runningKey == key then return false end
  Geo.runningKey = key
  local co = coroutine.create(function()
    if goal == "custom" then return Geo.PlanCustom() end
    return PlanXP(goal)
  end)
  Geo.co = co
  local function finish(result)
    Geo.co = nil
    Geo[cacheField] = result
    local cbs = Geo.planCbs or {}
    Geo.planCbs = nil
    for _, f in ipairs(cbs) do
      local ok, e = pcall(f, result.route, result.err, result.info)
      if not ok then Print(L["Error after computing the Roadbook: "] .. tostring(e)) end
    end
  end
  local function step()
    if Geo.co ~= co then return end -- replaced by a more recent computation
    Geo.sliceStart = debugprofilestop and debugprofilestop() or 0
    local ok, route, err, info = coroutine.resume(co)
    if not ok then
      Print(L["|cffff6060Roadbook computation error|r: "] .. tostring(route))
      finish({ key = key, pos = pos, err = L["Computation error: "] .. tostring(route) })
    elseif coroutine.status(co) == "dead" then
      finish({ key = key, pos = pos, route = route, err = err, info = info })
    else
      C_Timer.After(0, step)
    end
  end
  step()
  return false
end

local function FormatTime(sec)
  sec = math.floor(sec + 0.5)
  if sec < 60 then return sec .. L[" s"] end
  if sec < 3600 then return math.floor(sec / 60 + 0.5) .. L[" min"] end
  return string.format("%d h %02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

local function FormatNumber(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^ ", ""))
end

-- Shared with the next files.
ns.FormatNumber, ns.FormatTime = FormatNumber, FormatTime
