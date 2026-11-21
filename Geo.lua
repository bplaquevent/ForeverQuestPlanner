-- Forever Quest Planner: geography, transport network, quest targets.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, CharKey, Color, HasBit, K, L = ns.AreaName, ns.CharKey, ns.Color, ns.HasBit, ns.K, ns.L
local QDB, QGet, Settings = ns.QDB, ns.QGet, ns.Settings

---------------------------------------------------------------------------
-- Geography: QuestieDB positions converted to world coordinates (game map API)
---------------------------------------------------------------------------
local Geo = { npc = {}, object = {}, targets = {}, givers = {} }
K.CROSS_CONTINENT = 480 -- flat seconds to change continent
K.PATH_FACTOR = 1.35    -- paths are never straight lines
K.OVERHEAD = 20         -- dialogs, quest pick-up/turn-in

local function LoadDataString(v)
  if type(v) == "table" then return v end
  if type(v) == "string" and loadstring then
    local fn = loadstring(v)
    if fn then
      local ok, t = pcall(fn)
      if ok and type(t) == "table" then return t end
    end
  end
  return nil
end

local function GeoReady()
  if Geo.ready ~= nil then return Geo.ready end
  Geo.ready = false
  if not (QDB.ok and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return false end
  local p = QDB.zonePrivate or {}
  Geo.areaToUi = LoadDataString(p.areaIdToUiMapId) or {}
  for k, v in pairs(LoadDataString(p.areaIdToUiMapIdOverride) or {}) do Geo.areaToUi[k] = v end
  Geo.parent = LoadDataString(p.subZoneToParentZone) or {}
  for k, v in pairs(LoadDataString(p.subZoneToParentZoneOverride) or {}) do Geo.parent[k] = v end
  Geo.ready = next(Geo.areaToUi) ~= nil
  return Geo.ready
end

-- Drop rate (%) of an item on an NPC, from the Wowhead data shipped with QuestieDB.
local function DropRate(itemId, npcId)
  if Geo.drops == nil then
    Geo.drops = false
    if QDB.lib and QDB.lib.Support then
      local ok, mod = pcall(QDB.lib.Support.Get, "QuestieClassicItemDrops")
      if ok and type(mod) == "table" then Geo.drops = LoadDataString(mod.wowheadData) or false end
    end
  end
  local t = Geo.drops and Geo.drops[itemId]
  return t and t[npcId]
end

-- Zone (AreaID) + 0-100 coordinates -> world point {c = continent, x, y, area, mx, my}
local function WorldPos(areaId, x, y)
  local ui = Geo.areaToUi[areaId]
  if (not ui or ui == 0) and Geo.parent[areaId] then ui = Geo.areaToUi[Geo.parent[areaId]] end
  if not ui or ui == 0 then return nil end
  local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, ui, CreateVector2D(x / 100, y / 100))
  if not ok or not cont or not pos then return nil end
  local wx, wy = pos:GetXY()
  return { c = cont, x = wx, y = wy, area = areaId, mx = x, my = y }
end

local function DungeonEntrance(areaId)
  local d = QDB.dungeonOf[areaId]
  local entry = d and QDB.dungeons[d]
  local loc = entry and type(entry[4]) == "table" and entry[4][1]
  if not loc then return nil end
  local w = WorldPos(loc[1], loc[2], loc[3])
  if w then w.instance = AreaName(d) end
  return w
end

-- Spawn points (sampled) of an NPC or a world object.
local function EntityPoints(kind, id)
  local cache = Geo[kind]
  if cache[id] then return cache[id] end
  local entity = (kind == "npc") and QDB.Npc or QDB.Object
  local pts = {}
  local spawns = QGet(entity, id, "spawns")
  if type(spawns) == "table" then
    for zone, list in pairs(spawns) do
      if type(list) == "table" and #list > 0 then
        local step = math.max(1, math.floor(#list / 10))
        for i = 1, #list, step do
          local p = list[i]
          if type(p) == "table" and p[1] then
            local w = (p[1] < 0) and DungeonEntrance(zone) or WorldPos(zone, p[1], p[2])
            if w then pts[#pts + 1] = w end
            if p[1] < 0 then break end
          end
        end
      end
    end
  end
  cache[id] = pts
  return pts
end

local function GiverPoints(givers)
  local pts = {}
  if type(givers) ~= "table" then return pts end
  for _, id in ipairs(givers[1] or {}) do
    for _, p in ipairs(EntityPoints("npc", id)) do pts[#pts + 1] = p end
  end
  for _, id in ipairs(givers[2] or {}) do
    for _, p in ipairs(EntityPoints("object", id)) do pts[#pts + 1] = p end
  end
  return pts
end

local function StartPoints(id)
  local pts = Geo.givers[id]
  if not pts then
    pts = GiverPoints(QGet(QDB.Quest, id, "startedBy"))
    Geo.givers[id] = pts
  end
  return pts
end

local function Dist(a, b)
  if not a or not b or a.c ~= b.c then return nil end
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function Nearest(points, from)
  local best, bd
  for _, p in ipairs(points or {}) do
    local d = Dist(p, from)
    if d and (not bd or d < bd) then best, bd = p, d end
  end
  if not best and points and points[1] then return points[1], nil end
  return best, bd
end

local function PlayerPos()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
  local map = C_Map.GetBestMapForUnit("player")
  if not map then return nil end
  local pos = C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return nil end
  local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, map, pos)
  if not ok or not cont or not w then return nil end
  local x, y = w:GetXY()
  return { c = cont, x = x, y = y }
end

-- Travel speed: running, or the mount speed remembered the last time you were mounted.
local function TravelSpeed()
  local s = Settings()
  if GetUnitSpeed and IsMounted and IsMounted() then
    local _, run = GetUnitSpeed("player")
    if run and run > 7 then s.mountSpeed = run end
  end
  return math.max(7, s.mountSpeed or 7)
end

local function TravelTime(a, b, speed)
  if not a or not b then return 0 end
  local d = Dist(a, b)
  if not d then return K.CROSS_CONTINENT end
  return d * K.PATH_FACTOR / speed
end

local function PointText(p)
  if not p then return "?" end
  if p.instance then return p.instance .. L[" (entrance)"] end
  return string.format("%s (%.0f, %.0f)", AreaName(p.area) or p.zoneName or "?", p.mx or 0, p.my or 0)
end

local function AllInstance(points)
  if #points == 0 then return false end
  for _, p in ipairs(points) do if not p.instance then return false end end
  return true
end

---------------------------------------------------------------------------
-- Transport network: known flight masters, zeppelins, boats
---------------------------------------------------------------------------
K.FLIGHT_SPEED = 30     -- m/s while flying
K.FLIGHT_OVERHEAD = 30  -- dialog, take-off, landing
K.TRANSPORT_TIME = 180  -- average wait + crossing
K.DANGER_MARGIN = 2     -- dangerous zone if its minimum level > player level + margin
K.DANGER_FACTOR = 1.5   -- extra cost of walking in a dangerous zone (detours, fights)
K.K_HUBS = 3            -- number of transport points considered at departure and arrival

-- Classic coordinates, converted for Forever by QuestieDB when the zone has changed.
local DOCKS = {
  { key = "ogz", name = L["Orgrimmar zeppelin tower"], area = 14, x = 50.7, y = 13.0, faction = "Horde" },
  { key = "ucz", name = L["Tirisfal zeppelin tower"], area = 85, x = 60.8, y = 58.8, faction = "Horde" },
  { key = "ggz", name = L["Grom'gol zeppelin tower"], area = 33, x = 31.6, y = 29.6, faction = "Horde" },
  { key = "rat", name = L["Ratchet docks"], area = 17, x = 63.7, y = 38.6 },
  { key = "bb", name = L["Booty Bay docks"], area = 33, x = 25.9, y = 73.1 },
  { key = "men", name = L["Menethil Harbor"], area = 11, x = 5.0, y = 60.0, faction = "Alliance" },
  { key = "the", name = L["Theramore docks"], area = 15, x = 71.6, y = 56.4, faction = "Alliance" },
  { key = "aub", name = L["Auberdine docks"], area = 148, x = 32.6, y = 43.2, faction = "Alliance" },
  { key = "rut", name = "Rut'theran", area = 141, x = 54.9, y = 96.8, faction = "Alliance" },
}
local LINKS = {
  { "ogz", "ucz", "zeppelin" }, { "ogz", "ggz", "zeppelin" }, { "ucz", "ggz", "zeppelin" },
  { "rat", "bb", "bateau" }, { "men", "the", "bateau" }, { "men", "aub", "bateau" }, { "aub", "rut", "bateau" },
}

local function TaxiStore()
  local s = Settings()
  s.taxi = s.taxi or {}
  local k = CharKey()
  s.taxi[k] = s.taxi[k] or {}
  return s.taxi[k]
end

local function TaxiCount()
  local n = 0
  for _ in pairs(TaxiStore()) do n = n + 1 end
  return n
end

-- Called when a flight master's map opens: records the character's known flight paths.
local function RecordTaxiNodes()
  if not (GetTaxiMapID and C_Map and C_Map.GetWorldPosFromMapPos) then return end
  local mapID = GetTaxiMapID()
  if not mapID then return end
  local store = TaxiStore()
  local function save(name, pos)
    if not name or not pos then return end
    local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
    if ok and cont and w then
      local x, y = w:GetXY()
      store[name] = { c = cont, x = x, y = y, name = name }
    end
  end
  if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
    local ok, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, mapID)
    if ok and type(nodes) == "table" then
      for _, n in ipairs(nodes) do
        local unreachable = Enum and Enum.FlightPathState and n.state == Enum.FlightPathState.Unreachable
        if not unreachable then save(n.name, n.position) end
      end
    end
  elseif NumTaxiNodes and TaxiNodeName and TaxiNodeGetType and TaxiNodePosition then
    for i = 1, NumTaxiNodes() do
      if TaxiNodeGetType(i) ~= "NONE" then
        local x, y = TaxiNodePosition(i)
        if x and y then save(TaxiNodeName(i), CreateVector2D(x, y)) end
      end
    end
  end
end

-- Zone (name, minimum level) at a world point; cached by 200 m squares.
local zoneCache = {}
local function ZoneAt(p)
  if not (C_Map.GetMapPosFromWorldPos and C_Map.GetMapInfoAtPosition and C_Map.GetMapLevels) then return nil end
  local key = p.c .. ":" .. math.floor(p.x / 200) .. ":" .. math.floor(p.y / 200)
  local z = zoneCache[key]
  if z == nil then
    z = false
    local ok, ui, mp = pcall(C_Map.GetMapPosFromWorldPos, p.c, CreateVector2D(p.x, p.y))
    if ok and ui and mp then
      local mx, my = mp:GetXY()
      local okI, info = pcall(C_Map.GetMapInfoAtPosition, ui, mx, my)
      local zoneMap = (okI and info and info.mapID) or ui
      local okL, minL = pcall(C_Map.GetMapLevels, zoneMap)
      if okL and minL and minL > 0 then
        z = { name = (okI and info and info.name) or AreaName(0), min = minL }
      end
    end
    zoneCache[key] = z
  end
  return z or nil
end

-- Walking time between two points; also returns the dangerous zone crossed.
local function WalkCost(a, b, net, plevel)
  local d = Dist(a, b)
  if not d then return math.huge end
  local t = d * K.PATH_FACTOR / net.speed
  local worst
  if d > 300 then
    for _, f in ipairs({ 0.25, 0.5, 0.75, 1 }) do
      local z = ZoneAt({ c = a.c, x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f })
      if z and z.min > plevel + K.DANGER_MARGIN and (not worst or z.min > worst.min) then worst = z end
    end
    if worst then t = t * K.DANGER_FACTOR end
  end
  return t, worst
end

-- Transport point graph + shortest paths (Floyd-Warshall, about fifty nodes).
-- extra: flight masters not known yet, used as if their flight path were activated
-- ({ name, p }, custom Roadbook: flight paths activated on the way).
local function BuildNetwork(speed, extra)
  local hubs = {}
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  for name, n in pairs(TaxiStore()) do
    hubs[#hubs + 1] = { kind = "taxi", name = name, p = { c = n.c, x = n.x, y = n.y } }
  end
  for _, h in ipairs(extra or {}) do
    hubs[#hubs + 1] = { kind = "taxi", name = h.name, p = { c = h.p.c, x = h.p.x, y = h.p.y }, guess = true }
  end
  local dockIndex = {}
  for _, dock in ipairs(DOCKS) do
    if not dock.faction or dock.faction == faction then
      local x, y = dock.x, dock.y
      if QDB.lib and QDB.lib.EraToForever then
        local ok, fx, fy = pcall(QDB.lib.EraToForever, dock.area, x, y)
        if ok and fx and fy then x, y = fx, fy end
      end
      local w = WorldPos(dock.area, x, y)
      if w then
        hubs[#hubs + 1] = { kind = "dock", name = dock.name, p = w }
        dockIndex[dock.key] = #hubs
      end
    end
  end

  local n = #hubs
  local D, nxt, via = {}, {}, {}
  for i = 1, n do
    D[i], nxt[i], via[i] = {}, {}, {}
    for j = 1, n do
      nxt[i][j] = j
      if i == j then
        D[i][j] = 0
      else
        local a, b = hubs[i], hubs[j]
        local d = Dist(a.p, b.p)
        local best, how = math.huge, nil
        if d then
          best, how = d * K.PATH_FACTOR / speed, "walk"
          if a.kind == "taxi" and b.kind == "taxi" then
            local fl = d * 1.2 / K.FLIGHT_SPEED + K.FLIGHT_OVERHEAD
            if fl < best then best, how = fl, "flight" end
          end
        end
        D[i][j], via[i][j] = best, how
      end
    end
  end
  for _, l in ipairs(LINKS) do
    local i, j = dockIndex[l[1]], dockIndex[l[2]]
    if i and j then
      if K.TRANSPORT_TIME < D[i][j] then D[i][j], via[i][j] = K.TRANSPORT_TIME, l[3] end
      if K.TRANSPORT_TIME < D[j][i] then D[j][i], via[j][i] = K.TRANSPORT_TIME, l[3] end
    end
  end
  for k = 1, n do
    local Dk = D[k]
    for i = 1, n do
      local dik = D[i][k]
      if dik < math.huge then
        local Di, Ni, nik = D[i], nxt[i], nxt[i][k]
        for j = 1, n do
          local v = dik + Dk[j]
          if v < Di[j] then Di[j], Ni[j] = v, nik end
        end
      end
    end
  end
  return { hubs = hubs, D = D, nxt = nxt, via = via, speed = speed, near = {}, taxi = TaxiCount() }
end

local function NearHubs(net, p)
  local cached = net.near[p]
  if cached then return cached end
  local list = {}
  for i, h in ipairs(net.hubs) do
    local d = Dist(h.p, p)
    if d then list[#list + 1] = { i = i, d = d } end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  local out = {}
  for k = 1, math.min(K.K_HUBS, #list) do out[k] = list[k].i end
  net.near[p] = out
  return out
end

-- Best route from a to b: direct walk, or walk -> network -> walk.
local function Route(a, b, net, plevel)
  if not a or not b then return 0, nil end
  if not net then return TravelTime(a, b, 7), nil end
  local best = (a.c == b.c) and (WalkCost(a, b, net, plevel)) or math.huge
  local choice
  if #net.hubs > 0 then
    local hb = NearHubs(net, b)
    for _, i in ipairs(NearHubs(net, a)) do
      local wa = WalkCost(a, net.hubs[i].p, net, plevel)
      if wa < best then
        for _, j in ipairs(hb) do
          local v = wa + net.D[i][j] + (WalkCost(net.hubs[j].p, b, net, plevel))
          if v < best then best, choice = v, { i = i, j = j } end
        end
      end
    end
  end
  if best == math.huge then best = K.CROSS_CONTINENT end
  return best, choice
end

-- Readable directions to go from a to b.
local function RouteText(a, b, net, plevel)
  if not a or not b then return nil end
  local _, choice = Route(a, b, net, plevel)
  local parts = {}
  local function walk(p, q, toName)
    local d = Dist(p, q)
    if not d or d < 40 then return end
    local _, warn = WalkCost(p, q, net, plevel)
    local s = toName and string.format(L["walk to %s (%.0f m)"], toName, d) or string.format(L["walk %.0f m"], d)
    if warn then s = s .. Color("ff6060", L[" [crosses "] .. (warn.name or "?") .. L[", level "] .. warn.min .. "+]") end
    parts[#parts + 1] = s
  end
  if not choice then
    if a.c ~= b.c then
      parts[#parts + 1] = Color("ff8040", L["other continent: no known route (open a flight master's map to record it)"])
    else
      walk(a, b)
    end
  else
    local hubs = net.hubs
    walk(a, hubs[choice.i].p, hubs[choice.i].name)
    local cur, flightFrom = choice.i, nil
    while cur ~= choice.j do
      local nx = net.nxt[cur][choice.j]
      local mode = net.via[cur][nx]
      if mode == "flight" then
        flightFrom = flightFrom or hubs[cur].name
        if net.via[nx][net.nxt[nx][choice.j]] ~= "flight" or nx == choice.j then
          parts[#parts + 1] = Color("80c0ff", L["flight "] .. flightFrom .. " -> " .. hubs[nx].name)
          flightFrom = nil
        end
      elseif mode == "zeppelin" or mode == "bateau" then
        parts[#parts + 1] = Color("80c0ff", (K.MODE_NAME[mode] or mode) .. " -> " .. hubs[nx].name)
      else
        walk(hubs[cur].p, hubs[nx].p, hubs[nx].name)
      end
      cur = nx
    end
    walk(hubs[choice.j].p, b)
  end
  if #parts == 0 then return L["right here"] end
  return table.concat(parts, ", ")
end

-- Escort (or defense of an NPC): no flag says so, the text does. The English base texts are
-- read (GetRaw bypasses the translation); custom Forever quests have no flags, hence the
-- unambiguous words alone. Checked on the whole QuestieDB: 70 quests, 1 false positive.
K.ESCORT_STRONG = { "escort", "help [^.]- escape" }
K.ESCORT_FLAGGED = { "protect", "defend", "safely", "to safety", "must reach", "keep [^.]- safe",
  "show [^.]- the way", "help [^.]- to the road", "help [^.]- get", "go with" }
Geo.escort = {}
function Geo.IsEscort(id)
  if not id then return false end
  local v = Geo.escort[id]
  if v ~= nil then return v end
  local Q = QDB.Quest
  local function raw(key)
    if Q and Q.GetRaw then
      local ok, val = pcall(Q.GetRaw, id, key)
      if ok then return val end
    end
    return QGet(Q, id, key)
  end
  local parts = {}
  local trig = raw("triggerEnd")
  if type(trig) == "table" and type(trig[1]) == "string" then parts[#parts + 1] = trig[1] end
  local texts = raw("objectivesText")
  if type(texts) == "table" then
    for _, s in ipairs(texts) do parts[#parts + 1] = tostring(s) end
  end
  local text = table.concat(parts, " | "):lower()
  v = false
  for _, p in ipairs(K.ESCORT_STRONG) do
    if text:find(p) then v = true break end
  end
  if not v and HasBit(QGet(Q, id, "specialFlags") or 0, 2) then
    for _, p in ipairs(K.ESCORT_FLAGGED) do
      if text:find(p) then v = true break end
    end
  end
  Geo.escort[id] = v
  return v
end

-- Static quest targets: located objectives, start, end.
local function QuestTargets(id)
  local t = Geo.targets[id]
  if t then return t end
  t = {}
  local calls = 0
  local function add(kind, name, points, rate, mob, mobIds)
    calls = calls + 1
    if #points > 0 then
      local tg = { kind = kind, name = name, points = points, rate = rate, mobIds = mobIds or (mob and { mob }) }
      -- Monster level (min/max average) for the XP earned by killing it.
      if mob then
        local lo, hi = QGet(QDB.Npc, mob, "minLevel"), QGet(QDB.Npc, mob, "maxLevel")
        if type(lo) == "number" and lo > 0 then
          tg.mobLevel = math.floor(((lo + (type(hi) == "number" and hi or lo)) / 2) + 0.5)
          local rank = QGet(QDB.Npc, mob, "rank")
          tg.elite = rank == 1 or rank == 2 or rank == 3
        end
      end
      t[#t + 1] = tg
    end
  end
  local obj = QGet(QDB.Quest, id, "objectives")
  if type(obj) == "table" then
    for _, o in ipairs(obj[1] or {}) do
      local icon = o[3] -- QuestieDB icon type: 3 event, 5 talk, 17 interact; otherwise a monster to kill
      if icon == 3 or icon == 5 or icon == 17 then
        -- One action at the NPC (speak, scripted event…): no monster to kill, no monster XP.
        add("talk", QGet(QDB.Npc, o[1], "name"), EntityPoints("npc", o[1]))
      else
        add("kill", QGet(QDB.Npc, o[1], "name"), EntityPoints("npc", o[1]), nil, o[1])
      end
    end
    for _, o in ipairs(obj[2] or {}) do
      add("object", QGet(QDB.Object, o[1], "name"), EntityPoints("object", o[1]))
    end
    for _, o in ipairs(obj[3] or {}) do
      local itemId = o[1]
      local pts, rateSum, rateN = {}, 0, 0
      local npcs = QGet(QDB.Item, itemId, "npcDrops") or {}
      for i = 1, math.min(#npcs, 6) do
        for _, p in ipairs(EntityPoints("npc", npcs[i])) do pts[#pts + 1] = p end
        local r = DropRate(itemId, npcs[i])
        if r then rateSum, rateN = rateSum + r, rateN + 1 end
      end
      local objs = QGet(QDB.Item, itemId, "objectDrops") or {}
      for i = 1, math.min(#objs, 6) do
        for _, p in ipairs(EntityPoints("object", objs[i])) do pts[#pts + 1] = p end
      end
      local kind = (#npcs == 0 and #objs > 0) and "object" or "item"
      local ids = {}
      for i = 1, math.min(#npcs, 6) do ids[#ids + 1] = npcs[i] end
      add(kind, QGet(QDB.Item, itemId, "name"), pts, rateN > 0 and rateSum / rateN or nil, npcs[1], #ids > 0 and ids or nil)
    end
    for _, o in ipairs(obj[5] or {}) do
      if type(o) == "table" and o[2] then
        add("kill", o[3] or QGet(QDB.Npc, o[2], "name"), EntityPoints("npc", o[2]), nil, o[2])
      end
    end
  end
  local trig = QGet(QDB.Quest, id, "triggerEnd")
  if type(trig) == "table" and type(trig[2]) == "table" then
    local pts = {}
    for zone, list in pairs(trig[2]) do
      for _, p in ipairs(list) do
        local w = WorldPos(zone, p[1], p[2])
        if w then pts[#pts + 1] = w end
      end
    end
    add("explore", trig[1], pts)
  end
  -- Quantities read from the objective text ("Kill 8 ogres…"), default values otherwise.
  local texts, nums = QGet(QDB.Quest, id, "objectivesText"), {}
  if type(texts) == "table" then
    for _, s in ipairs(texts) do
      for n in tostring(s):gmatch("(%d+)") do
        local v = tonumber(n)
        if v and v > 1 and v <= 50 then nums[#nums + 1] = v end
      end
    end
  end
  for i, tg in ipairs(t) do
    tg.defaultCount = nums[i] or ((tg.kind == "kill" or tg.kind == "item") and 6 or 1)
  end
  t.missing = calls - #t -- objectives without a known position in QuestieDB
  t.start = StartPoints(id)
  t.finish = GiverPoints(QGet(QDB.Quest, id, "finishedBy"))
  Geo.targets[id] = t
  return t
end

-- Remaining objectives: matches the game's objectives (with progress) to QuestieDB targets.
local function RemainingTargets(q, t)
  local out, used = {}, {}
  local objs = (q and q.objectives) or {}
  for i, tg in ipairs(t) do
    local match
    if tg.name then
      for j, o in ipairs(objs) do
        if not used[j] and o.text and o.text:find(tg.name, 1, true) then match = j break end
      end
    end
    if not match and objs[i] and not used[i] then match = i end
    local count = tg.defaultCount
    if match then
      used[match] = true
      local o = objs[match]
      if o.finished or (o.need and o.have and o.need > 0 and o.have >= o.need) then
        count = 0
      elseif o.need and o.have and o.need > 0 then
        count = o.need - o.have
      end
    end
    if count > 0 then out[#out + 1] = { tg = tg, count = count } end
  end
  -- Unfinished game objectives that no QuestieDB target locates: the quest cannot be
  -- planned correctly (otherwise it would show as "to turn in" while still in progress).
  local unmatched = 0
  for j, o in ipairs(objs) do
    local done = o.finished or (o.need and o.have and o.need > 0 and o.have >= o.need)
    if not used[j] and not done then unmatched = unmatched + 1 end
  end
  return out, unmatched
end

-- Time (s) for one objective unit.
K.MOB_TIME = 30          -- seconds per monster killed
K.ELITE_MOB_TIME = 75    -- seconds per elite monster killed (alone)
K.KILLS_NO_RATE = 2      -- monsters per item to collect when QuestieDB does not know the drop rate
-- Monsters to kill per item: from the QuestieDB drop rate, otherwise the configured value.
function Geo.KillsPerItem(tg)
  if tg.rate and tg.rate > 0 then return 100 / math.max(tg.rate, 1) end
  return K.KILLS_NO_RATE
end
-- Fight time per monster of an objective: longer for elites.
function Geo.MobTime(tg)
  return tg.elite and K.ELITE_MOB_TIME or K.MOB_TIME
end

local function UnitTime(tg)
  if tg.kind == "kill" then return Geo.MobTime(tg) end
  if tg.kind == "item" then return Geo.MobTime(tg) * Geo.KillsPerItem(tg) end
  if tg.kind == "object" then return 20 end
  return 10
end

-- Shared with the next files.
ns.AllInstance, ns.BuildNetwork, ns.Dist, ns.EntityPoints, ns.Geo, ns.GeoReady = AllInstance, BuildNetwork, Dist, EntityPoints, Geo, GeoReady
ns.Nearest, ns.PlayerPos, ns.PointText, ns.QuestTargets, ns.RecordTaxiNodes, ns.RemainingTargets = Nearest, PlayerPos, PointText, QuestTargets, RecordTaxiNodes, RemainingTargets
ns.Route, ns.RouteText, ns.StartPoints, ns.TaxiCount, ns.TaxiStore, ns.TravelSpeed = Route, RouteText, StartPoints, TaxiCount, TaxiStore, TravelSpeed
ns.UnitTime, ns.WorldPos = UnitTime, WorldPos
