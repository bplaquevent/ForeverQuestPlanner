-- Forever Quest Planner: Roadbook: transport stops, hearthstone and class teleports, planning with the solver (PlanXP).
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, BuildNetwork, CharKey, Dist, Geo, GetItemInfoCompat = ns.AreaName, ns.BuildNetwork, ns.CharKey, ns.Dist, ns.Geo, ns.GetItemInfoCompat
local K, L, PlayerPos, Print, Route, Settings = ns.K, ns.L, ns.PlayerPos, ns.Print, ns.Route, ns.Settings
local SharedData, Solver, TaxiCount, TravelSpeed, WorldPos, scan = ns.SharedData, ns.Solver, ns.TaxiCount, ns.TravelSpeed, ns.WorldPos, ns.scan

---------------------------------------------------------------------------
-- Roadbook trace: the changes of the Roadbook (plan saved or emptied, step marked, focus, list), kept per
-- character in the saved data (the last K.TRACE_MAX lines) to find out how a step got its state.
-- Off by default (Settings().traceOn, /fqp trace on).
---------------------------------------------------------------------------
K.TRACE_MAX = 300
function Geo.Trace(kind, text)
  local st = Settings()
  if not st.traceOn then return end -- off by default: /fqp trace on
  st.roadbookTrace = st.roadbookTrace or {}
  local t = st.roadbookTrace
  t[#t + 1] = (date and date("%d/%m %H:%M:%S") or "") .. " " .. kind .. " " .. tostring(text)
  while #t > K.TRACE_MAX do table.remove(t, 1) end
end

-- One step in a few words: kind, quest, objective and count, state.
function Geo.StepTrace(s)
  local t = s.task or {}
  local r = s.r
  return tostring(s.kind) .. " " .. tostring(t.id or "-") .. " " .. tostring(t.title or "?")
    .. (r and r.tg and (" / " .. tostring(r.tg.name) .. " x" .. tostring(r.count)) or "")
    .. (s.done and " [done]" or "")
end

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

-- Boardings of a route: { hub, mode ("vol", "zeppelin", "bateau", "airship"), dest }.
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
      if Geo.IsShip(mode) then
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
-- Hearthstone and class teleports: bind at an innkeeper, hearth back, Astral Recall, mage and
-- druid teleports, to save travel time
---------------------------------------------------------------------------
K.HEARTHSTONE = 6948
K.HEARTH_SPELL = 8690
K.HEARTH_TIME = 30      -- cast (10 s) + teleport
K.HEARTH_CD = 3600      -- hearthstone cooldown
K.HEARTH_MIN_GAIN = 120 -- minimum gain (s) to suggest hearthing
K.BIND_WORK = 20        -- talking to the innkeeper
K.INN_DETOUR = 500      -- maximum detour (m, as the crow flies) to go and bind
K.RECALL_TOLERANCE = 60 -- a cooldown that moved by more than this (s) changes the plan
K.TELEPORT_RUNE = 17031 -- Rune of Teleportation (mage teleports)
K.TELEPORT_MAX_GAP = 1500 -- a place farther than this (m) from the default arrival is not the arrival
-- Class spells: bind = back to the hearthstone's bind point; otherwise a fixed arrival (AreaID +
-- 0-100 coordinates, approximate: replaced by the place really reached after the first cast).
-- cast = cast + loading (s); cd = cooldown used to space two uses (the real remaining time is read).
-- The mage portals are left out: alone, they lead to the same places as the teleports.
K.RECALL_SPELLS = {
  { spell = 556, bind = true, cast = 30, cd = 900 },                                  -- Astral Recall (shaman)
  { spell = 3561, area = 1519, x = 38.0, y = 79.0, cast = 30, reagent = K.TELEPORT_RUNE }, -- Teleport: Stormwind
  { spell = 3562, area = 1537, x = 25.5, y = 7.0, cast = 30, reagent = K.TELEPORT_RUNE },  -- Teleport: Ironforge
  { spell = 3565, area = 1657, x = 40.0, y = 82.0, cast = 30, reagent = K.TELEPORT_RUNE }, -- Teleport: Darnassus
  { spell = 3567, area = 1637, x = 38.5, y = 85.5, cast = 30, reagent = K.TELEPORT_RUNE }, -- Teleport: Orgrimmar
  { spell = 3563, area = 1497, x = 84.5, y = 17.0, cast = 30, reagent = K.TELEPORT_RUNE }, -- Teleport: Undercity
  { spell = 3566, area = 1638, x = 22.5, y = 16.5, cast = 30, reagent = K.TELEPORT_RUNE }, -- Teleport: Thunder Bluff
  { spell = 18960, area = 493, x = 44.0, y = 45.0, cast = 30 },                       -- Teleport: Moonglade (druid)
}
K.RECALL_BY_SPELL = {}
for _, e in ipairs(K.RECALL_SPELLS) do K.RECALL_BY_SPELL[e.spell] = e end

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

-- Zones (zone ids) with this name (value true), or containing the subzone with this name (value "sub").
function Geo.ZonesNamed(name)
  local zones = {}
  for id, parent in pairs(Geo.parent or {}) do
    if AreaName(id) == name then zones[parent] = "sub" end
  end
  for id in pairs(Geo.areaToUi or {}) do
    if AreaName(id) == name then zones[Geo.parent[id] or id] = Geo.parent[id] and "sub" or true end
  end
  return zones
end

-- Bind point of a new character: the start position of its race (no inn there). `areas` are the
-- AreaIDs (AreaTable) of the names GetBindLocation can give there ("Shadow Grave" seen in game for an
-- Undead; the others cover the start area and its subzones). Position: world coordinates of the
-- server table playercreateinfo (same as Geo's world points: c = continent, x, y).
K.START_BINDS = {
  { areas = { 2117, 154 }, c = 0, x = 1676.71, y = 1678.31 },   -- Undead: Shadow Grave, Deathknell
  { areas = { 24, 9 }, c = 0, x = -8949.95, y = -132.493 },     -- Human: Northshire Abbey / Valley
  { areas = { 77, 132 }, c = 0, x = -6240.32, y = 331.033 },    -- Dwarf, Gnome: Anvilmar, Coldridge Valley
  { areas = { 256, 188 }, c = 1, x = 10311.3, y = 832.463 },    -- Night Elf: Aldrassil, Shadowglen
  { areas = { 363 }, c = 1, x = -618.518, y = -4251.67 },       -- Orc, Troll: Valley of Trials
  { areas = { 221, 220 }, c = 1, x = -2917.58, y = -257.98 },   -- Tauren: Camp Narache, Red Cloud Mesa
}

function Geo.StartBind(name)
  for _, e in ipairs(K.START_BINDS) do
    for _, a in ipairs(e.areas) do
      if AreaName(a) == name then return Geo.MapPoint({ c = e.c, x = e.x, y = e.y }) end
    end
  end
end

-- Estimated bind location from its name, from the most to the least precise: the starting area of
-- a race, the innkeeper of that zone, the center of the zone's innkeepers, the center of the zone.
-- A subzone name only gives its zone's innkeepers (the subzone of an innkeeper is not known):
-- the result is then approximate.
function Geo.GuessBind(name)
  if Geo.bindGuess and Geo.bindGuess.name == name then return Geo.bindGuess.p end
  local p = Geo.StartBind(name)
  local zones = Geo.ZonesNamed(name)
  local list, sub = {}, false
  for _, inn in ipairs(p and {} or Geo.Innkeepers()) do
    local a = inn.p.area
    local z = (AreaName(a) == name and true) or zones[a] or (Geo.parent[a] and zones[Geo.parent[a]])
    if z then
      list[#list + 1] = inn.p
      if z == "sub" then sub = true end
    end
  end
  if p then
    -- starting area
  elseif #list == 1 then
    p = list[1]
    if sub then
      local q = {}
      for k, v in pairs(p) do q[k] = v end
      q.approx = true
      p = q
    end
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

-- Spell name, icon and cooldown: the C_Spell API of recent clients (Forever's client no longer has
-- GetSpellInfo and the like), otherwise the former functions.
function Geo.SpellName(spell)
  local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spell)
  if not name and GetSpellInfo then name = GetSpellInfo(spell) end
  return name
end

function Geo.SpellIcon(spell)
  local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spell)
  if not tex and GetSpellTexture then tex = GetSpellTexture(spell) end
  return tex
end

-- Seconds until a spell is ready (0 = ready); the global cooldown does not count.
function Geo.SpellReady(spell)
  if not GetTime then return 0 end
  local start, dur
  if C_Spell and C_Spell.GetSpellCooldown then
    local info = C_Spell.GetSpellCooldown(spell)
    if type(info) == "table" then start, dur = info.startTime, info.duration end
  elseif GetSpellCooldown then
    start, dur = GetSpellCooldown(spell)
  end
  if start and dur and start > 0 and dur > 1.5 then return math.max(0, start + dur - GetTime()) end
  return 0
end

function Geo.SpellKnown(spell)
  if IsPlayerSpell and IsPlayerSpell(spell) then return true end
  return (IsSpellKnown and IsSpellKnown(spell)) and true or false
end

local function ItemCount(id)
  return (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id)) or (GetItemCount and GetItemCount(id)) or 0
end

-- Arrival of a teleport spell: the place reached after its last cast, otherwise the default one.
function Geo.TeleportStore()
  return SharedData().teleportArrivals
end

function Geo.RecordTeleport(spell, p)
  local e = K.RECALL_BY_SPELL[spell]
  if not (p and e and e.area) then return end
  -- Still before the loading screen (or somewhere else): not the arrival.
  local d = Dist(p, WorldPos(e.area, e.x, e.y) or {})
  if not d or d > K.TELEPORT_MAX_GAP then return end
  local mp = Geo.MapPoint({ c = p.c, x = p.x, y = p.y })
  Geo.TeleportStore()[spell] = { c = p.c, x = p.x, y = p.y, area = p.area, mx = p.mx or mp.mx, my = p.my or mp.my,
    ui = (not p.area) and mp.ui or nil, zoneName = mp.zoneName }
  Geo.recallDest = nil
end

function Geo.TeleportDest(e)
  Geo.recallDest = Geo.recallDest or {}
  local p = Geo.recallDest[e.spell]
  if p then return p end
  p = Geo.TeleportStore()[e.spell]
  if not p then
    p = WorldPos(e.area, e.x, e.y)
    if p then p.approx = true end
  end
  Geo.recallDest[e.spell] = p
  return p
end

-- Ways back usable by the Roadbook now, according to the options: the hearthstone (key "hearth"),
-- then the class spells known (key = spell id). Each one: { key, bind (to the bind point) or p,
-- cast, cd, ready (s until usable), charges (uses left, nil = unlimited), spell, name }.
function Geo.RecallSources()
  local out = {}
  if not Settings().noHearth then
    local ready = Geo.HearthReady()
    if ready then
      out[#out + 1] = { key = "hearth", bind = true, cast = K.HEARTH_TIME, cd = K.HEARTH_CD, ready = ready,
        name = L["Hearthstone"] }
    end
  end
  if Settings().noRecallSpells then return out end
  for _, e in ipairs(K.RECALL_SPELLS) do
    if Geo.SpellKnown(e.spell) then
      local charges = e.reagent and ItemCount(e.reagent) or nil
      local p = not e.bind and Geo.TeleportDest(e) or nil
      if (charges == nil or charges > 0) and (e.bind or p) then
        local name = Geo.SpellName(e.spell)
        out[#out + 1] = { key = e.spell, spell = e.spell, bind = e.bind, p = p, cast = e.cast, cd = e.cd or 0,
          ready = Geo.SpellReady(e.spell), charges = charges, name = name or ("#" .. e.spell) }
      end
    end
  end
  return out
end

-- State of the ways back, saved with a Roadbook to tell later whether it changed:
-- { [key] = { ready = server time when usable, charges }, bind = bind location name }.
function Geo.RecallState()
  local now = time and time() or 0
  local state = { bind = GetBindLocation and GetBindLocation() or nil, src = {} }
  for _, s in ipairs(Geo.RecallSources()) do
    state.src[tostring(s.key)] = { ready = now + math.floor(s.ready + 0.5), charges = s.charges }
  end
  return state
end

-- The ways back changed since `saved` (Geo.RecallState): one more or less, a cooldown used or
-- reset, a rune more or less, another bind location.
function Geo.RecallChanged(saved, now)
  if not saved then return true end
  now = now or Geo.RecallState()
  if saved.bind ~= now.bind then return true end
  local a, b = saved.src or {}, now.src or {}
  for k, v in pairs(a) do
    local w = b[k]
    if not w or w.charges ~= v.charges or math.abs((w.ready or 0) - (v.ready or 0)) > K.RECALL_TOLERANCE then return true end
  end
  for k in pairs(b) do if not a[k] then return true end end
  return false
end

-- Teleport step (kind "hearth") with the way back `src` to `destP`.
function Geo.RecallStep(src, destP, gain)
  local dest = AreaName(destP.area) or destP.zoneName or destP.name or "?"
  local title
  if src.key == "hearth" then
    title = L["Hearthstone: back to "] .. dest
  elseif src.bind then
    title = src.name .. L[": back to "] .. dest
  else
    title = src.name
  end
  return { kind = "hearth", work = 0, gain = gain, via = src.key, bindDest = src.bind or nil,
    p = { c = destP.c, x = destP.x, y = destP.y, area = destP.area, ui = destP.ui, mx = destP.mx, my = destP.my,
      zoneName = destP.zoneName, teleport = true, cast = src.cast },
    task = { title = title, xp = 0, hearth = true, spell = src.spell } }
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

-- "Generate" options: { kind = "time", value = seconds } (most XP in that time) or
-- { kind = "level", value = level } (fastest route to that level).
-- A far level is reached in stages: one computation plans at most this much, then "Generate"
-- at the end of the Roadbook plans the next stage (with the real XP and flight paths).
K.LEVEL_PLAN_MAX_TIME = 40 * 3600 -- level goal: longest Roadbook computed
K.PLAN_TIME = 30                  -- seconds of computation for a Roadbook, at most (solver budget, shown in the waiting messages)

-- Runs the solver (Solver.lua) on a problem (Geo.Problem), inside the computation coroutine.
function Geo.Solve(P, goal)
  Solver.yield = Geo.Yield
  Solver.clock = debugprofilestop and function() return debugprofilestop() / 1000 end or nil
  return Solver.Optimize(P, goal, { maxTime = K.PLAN_TIME, maxRouteTime = K.LEVEL_PLAN_MAX_TIME })
end

-- Game route from a solver route `sroute` and its evaluation `res`: the game steps of the quests (src),
-- with the XP of the level they are done at, the teleports, binds and flight paths activated the
-- solver chose, then the boarding steps (flights, boats, zeppelins). Returns the route and its info.
function Geo.FromSolver(P, sroute, res)
  local pl = P.player
  local srcByKey = {}
  for _, s in ipairs(P.world.recall) do srcByKey[tostring(s.key)] = s end
  local route = { { kind = "start", p = pl.posSrc or pl.pos, work = 0 } }
  for i = 2, #sroute do
    local s = sroute[i]
    local st = s.src
    if st then
      if st.kind == "obj" or st.kind == "turnin" then st.xp = res.rawXP[i] end
      if s.alt and s.alt.spot then -- another hunting spot chosen by the solver
        st.p, st.spot, st.work = s.alt.spot.p, s.alt.spot, s.work
      end
    elseif s.kind == "hearth" and srcByKey[tostring(s.via)] then
      st = Geo.RecallStep(srcByKey[tostring(s.via)], s.p, s.gain)
    elseif s.kind == "bind" then
      st = { kind = "bind", p = s.p, bindP = s.p, work = s.work, task = { title = L["Bind your hearthstone: "]
        .. (AreaName(s.p.area) or "?"), npc = s.inn and s.inn.name, xp = 0, bind = true } }
    elseif s.kind == "fm" and s.fm then
      st = Geo.FlightMasterStep(s.fm)
    end
    if st then
      st.at = res.at[i]
      route[#route + 1] = st
    end
  end
  local cache = {}
  local nets = Geo.RouteNets(route, pl.speed, pl.level, cache)
  -- Transport skipped by the player (P.ban): left out of the first leg only.
  local banNet = P.ban and BuildNetwork(pl.speed, nil, P.ban)
  local okT, withT = pcall(Geo.AddTransportStops, route, function(k)
    if k == 2 and banNet then return banNet end
    return nets[k].net
  end, pl.level)
  if not okT then Print(L["Transport steps error: "] .. tostring(withT)) end
  if okT and withT then route = withT end
  for i = 2, #route do route[i].at = route[i].at or route[i - 1].at or 0 end -- boardings: on the way
  local ids, count = {}, 0
  for _, st in ipairs(route) do
    local id = st.task and st.task.id
    if id and not ids[id] then ids[id], count = true, count + 1 end
  end
  local net = BuildNetwork(pl.speed)
  local info = { total = res.time, xp = res.xp, mobXP = res.mobXP, levels = Geo.Levels(route), speed = pl.speed,
    plevel = pl.level, net = net, count = count, netCache = cache }
  return route, info
end

-- History of a Roadbook computed again: the steps done of the saved Roadbook `fz` (isDone(st)) come
-- first, in their order, with their time and level as planned, marked done for good; then the new
-- steps `rest` (route from a start step, info `restInfo`), their times following the last step done.
-- Fills info (it can be restInfo itself) with the totals of the whole: xp, mobXP, count, total, levels.
-- Returns the merged route.
function Geo.KeepDone(fz, isDone, rest, restInfo, info)
  local old = fz.route
  local oldLv = fz.info.levels or {}
  local restLv, restTotal = restInfo.levels or {}, restInfo.total or 0
  local route, levels = { old[1] }, { oldLv[1] or restLv[1] or UnitLevel("player") }
  local t0, kept, dropped = 0, 0, {}
  for i = 2, #old do
    local st = old[i]
    if not isDone(st) then
      if st.task and st.task.id then dropped[#dropped + 1] = Geo.StepTrace(st) end
    else
      kept = kept + 1
      if not st.done then Geo.Trace("keepdone", "marked done for good: " .. Geo.StepTrace(st)) end
      st.done = true
      route[#route + 1] = st
      levels[#levels + 1] = oldLv[i] or levels[#levels]
      t0 = math.max(t0, st.at or 0)
    end
  end
  if #route == 1 then -- nothing done: the new route as it is
    route, levels, t0 = rest, restLv, 0
  else
    for i = 2, #rest do
      rest[i].at = t0 + (rest[i].at or 0)
      route[#route + 1] = rest[i]
      levels[#levels + 1] = restLv[i] or levels[#levels]
    end
  end
  Geo.Trace("keepdone", string.format("%d step(s) done kept, %d not done dropped (%s), %d new step(s)",
    kept, #dropped, table.concat(dropped, "; "), #rest - 1))
  local xp, mobXP, ids = 0, 0, {}
  for i = 2, #route do
    local st = route[i]
    if st.kind == "turnin" or st.kind == "dungeon" then xp = xp + (st.xp or 0) end
    if st.kind == "obj" then mobXP = mobXP + (st.xp or 0) end
    if st.task and st.task.id then ids[st.task.id] = true end
  end
  local count = 0
  for _ in pairs(ids) do count = count + 1 end
  info.xp, info.mobXP, info.count = xp + mobXP, mobXP, count
  info.total, info.levels = t0 + restTotal, levels
  return route
end

-- Roadbook computation in the background (spread over several frames) with caching.
-- goal: "Generate" option ({ kind, value }) or "custom" (the whole list); the list is in the key.
function Geo.GoalKey(goal)
  if goal == "custom" then return goal end
  return goal.kind .. goal.value
end

-- Profession levels (a quest waiting for one can be turned in once it is reached).
function Geo.SkillsKey()
  local skills = ns.PlayerSkills()
  local ids = {}
  for id, v in pairs(skills) do ids[#ids + 1] = id .. ":" .. v end
  table.sort(ids)
  return table.concat(ids, ",")
end

function Geo.PlanKey(goal)
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  local b = Geo.BindStore()[CharKey()]
  local list = {}
  for _, it in ipairs(Geo.CustomList()) do list[#list + 1] = it.id end
  return table.concat({ Geo.GoalKey(goal), table.concat(list, ","), tostring(Settings().noHearth),
    tostring(Settings().noRecallSpells), tostring(Settings().noFMDetour), UnitLevel("player"),
    UnitXP and UnitXP("player") or 0, e and e.updated or "", tostring(scan.entries), TaxiCount(),
    tostring(b and b.name), tostring(Settings().mountSpeed), Geo.paramsVersion or 0, Geo.SkillsKey() }, "|")
end

-- Returns true if the cached plan is up to date; otherwise starts (or continues) the computation and
-- calls cb(route, err, info) when done. force = recompute even if the cache is valid.
-- opts: a Roadbook adapted (Geo.PlanCustom), computed apart from the plans of the tabs.
function Geo.RequestPlan(goal, cb, force, opts)
  local key = Geo.PlanKey(goal) .. (opts and "|adapt" or "")
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
    if goal == "custom" then return Geo.PlanCustom(opts) end
    return Geo.PlanGenerate(goal, opts)
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

-- Teleport step (kind "hearth"): icon, tag and what to do, for the lists and the Objective button.
function Geo.RecallText(s)
  local spell = s.task and s.task.spell
  local saves = L[" · saves ~"] .. FormatTime(s.gain or 0)
  if not spell then
    return "|TInterface\\Icons\\INV_Misc_Rune_01:14:14|t", L["[Hearthstone]"], L["Use the hearthstone"] .. saves
  end
  local tex = Geo.SpellIcon(spell) or "Interface\\Icons\\Spell_Arcane_TeleportStormWind"
  local name = Geo.SpellName(spell) or ("#" .. spell)
  return "|T" .. tex .. ":14:14|t", L["[Teleport]"], L["Cast "] .. name .. saves
end

-- Shared with the next files.
ns.FormatNumber, ns.FormatTime = FormatNumber, FormatTime
