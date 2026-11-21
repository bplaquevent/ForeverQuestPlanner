-- Forever Quest Planner: geography, transport network, quest targets.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, CharKey, Color, HasBit, K, L = ns.AreaName, ns.CharKey, ns.Color, ns.HasBit, ns.K, ns.L
local OM, QDB, QGet, Settings = ns.OM, ns.QDB, ns.QGet, ns.Settings

---------------------------------------------------------------------------
-- Geography: QuestieDB positions converted to world coordinates (game map API)
---------------------------------------------------------------------------
local Geo = { npc = {}, object = {}, targets = {}, givers = {} }
K.CROSS_CONTINENT = 480 -- flat seconds to change continent
K.PATH_FACTOR = 1.35    -- paths are never straight lines
K.OVERHEAD = 20         -- dialogs, quest pick-up/turn-in
K.INSTANCE_MATCH = 400  -- yards: an OpenMap dungeon entrance this close to QuestieDB's is the same one

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
  local p = QDB.zonePrivate
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
    local ok, mod = pcall(QDB.lib.Support.Get, "QuestieClassicItemDrops")
    if ok and type(mod) == "table" then Geo.drops = LoadDataString(mod.wowheadData) or false end
  end
  local t = Geo.drops and Geo.drops[itemId]
  return t and t[npcId]
end

-- Zone (AreaID) -> uiMapID (QuestieDB tables; a sub-zone takes its parent's map), or nil.
function Geo.AreaUi(areaId)
  local ui = areaId and Geo.areaToUi[areaId]
  if (not ui or ui == 0) and areaId and Geo.parent[areaId] then ui = Geo.areaToUi[Geo.parent[areaId]] end
  if not ui or ui == 0 then return nil end
  return ui
end

-- Zone (AreaID) + 0-100 coordinates -> world point {c = continent, x, y, area, mx, my}
local function WorldPos(areaId, x, y)
  local ui = Geo.AreaUi(areaId)
  if not ui then return nil end
  local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, ui, CreateVector2D(x / 100, y / 100))
  if not ok or not cont or not pos then return nil end
  local wx, wy = pos:GetXY()
  return { c = cont, x = wx, y = wy, area = areaId, mx = x, my = y }
end

-- Dungeon entrances of OpenMap (WoW Forever's tables, with the group finder's level ranges):
-- { p = world point, min, max } each, built once. A wing is an instance of its own at the same
-- entrance: the range covers them all.
function Geo.Instances()
  if Geo.instances then return Geo.instances end
  local out = {}
  for _, e in ipairs(OM.places.instances) do
    local p
    if e[1] then
      p = { c = e[1], x = e[2], y = e[3] }
    elseif e.map then
      local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, e.map, CreateVector2D(e[2], e[3]))
      if ok and cont and pos then
        local wx, wy = pos:GetXY()
        p = { c = cont, x = wx, y = wy }
      end
    end
    if p then
      local lo, hi
      for _, w in ipairs(e[4]) do
        if w[4] and (not lo or w[4] < lo) then lo = w[4] end
        if w[5] and (not hi or w[5] > hi) then hi = w[5] end
      end
      out[#out + 1] = { p = p, min = lo, max = hi }
    end
  end
  Geo.instances = out
  return out
end

-- Entrance of the dungeon containing the zone areaId: QuestieDB's, moved to OpenMap's nearest
-- entrance when there is one (Forever's own positions, and the dungeon's level range).
Geo.dungeonInfo = {}
local function DungeonEntrance(areaId)
  local d = QDB.dungeonOf[areaId]
  if not d then return nil end
  local info = Geo.dungeonInfo[d]
  if info == nil then
    info = false
    local entry = QDB.dungeons[d]
    local loc = type(entry[4]) == "table" and entry[4][1]
    local w = loc and WorldPos(loc[1], loc[2], loc[3])
    if w then
      local best, bd
      for _, inst in ipairs(Geo.Instances()) do
        if inst.p.c == w.c then
          local dx, dy = inst.p.x - w.x, inst.p.y - w.y
          local dd = math.sqrt(dx * dx + dy * dy)
          if dd < K.INSTANCE_MATCH and (not bd or dd < bd) then best, bd = inst, dd end
        end
      end
      if best then
        w.x, w.y, w.lmin, w.lmax = best.p.x, best.p.y, best.min, best.max
        -- zone coordinates of the moved entrance (map pins)
        local ui = Geo.AreaUi(w.area)
        local ok, _, mp = pcall(C_Map.GetMapPosFromWorldPos, w.c, CreateVector2D(w.x, w.y), ui)
        if ok and mp then
          local mx, my = mp:GetXY()
          if mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then w.mx, w.my = mx * 100, my * 100 end
        end
      end
      w.instance = AreaName(d)
      info = w
    end
    Geo.dungeonInfo[d] = info
  end
  if not info then return nil end
  local w = {}
  for k, v in pairs(info) do w[k] = v end
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
  if p.instance then
    return p.instance .. L[" (entrance)"] .. (p.lmin and (" " .. Geo.LevelRange(p.lmin, p.lmax)) or "")
  end
  -- zone level range (OpenMap), coloured for the player's level
  local lv = p.area and Geo.areaToUi and Geo.ZoneLevelText(Geo.AreaUi(p.area))
  return string.format("%s%s (%.0f, %.0f)", AreaName(p.area) or p.zoneName or "?", lv and (" " .. lv) or "", p.mx or 0, p.my or 0)
end

local function AllInstance(points)
  if #points == 0 then return false end
  for _, p in ipairs(points) do if not p.instance then return false end end
  return true
end

---------------------------------------------------------------------------
-- Transport network: flight paths, boats, zeppelins and airships, read from OpenMap
-- (OpenMap.MapFlights / MapPlaces: WoW Forever's own tables, kept up to date by OpenMap).
---------------------------------------------------------------------------
K.FLIGHT_SPEED = 30     -- yards/s while flying
K.FLIGHT_OVERHEAD = 30  -- dialog, take-off, landing
K.TRANSPORT_TIME = 180  -- average wait + crossing
K.DANGER_MARGIN = 2     -- dangerous zone if its minimum level > player level + margin
K.DANGER_FACTOR = 1.5   -- extra cost of walking in a dangerous zone (detours, fights)
K.K_HUBS = 3            -- number of transport points considered at departure and arrival
K.DOCK_MERGE = 60       -- yards: transport ends this close are one dock
K.NODE_MATCH = 150      -- yards: a flight master this close to a flight node is that node
-- Boat and zeppelin lines OpenMap gives no faction to: the same rule as its Map/Routes.lua
-- (zeppelins are the Horde's, these two goblin lines everyone's, every other boat the Alliance's).
K.TRANSPORT_NEUTRAL = { ["Booty Bay - Ratchet"] = true, ["Steamwheedle Port - Powderfuse Port"] = true }
K.TRANSPORT_MODE = { boat = "bateau", zeppelin = "zeppelin", airship = "airship" }

local function PlayerFactionBit()
  local f = UnitFactionGroup and UnitFactionGroup("player")
  return (f == "Alliance" and 1) or (f == "Horde" and 2) or 0
end

-- A flight node the character can use: its faction, and its class when it flies only one (Nighthaven).
function Geo.NodeUsable(id)
  local n = OM.flights.nodes[id]
  if not (n and HasBit(n[5], PlayerFactionBit())) then return false end
  return not n[6] or n[6] == select(2, UnitClass("player"))
end

-- Flight node -> world point.
function Geo.NodePoint(id)
  local n = OM.flights.nodes[id]
  return n and { c = n[2], x = n[3], y = n[4] } or nil
end

-- The game's names of the flight nodes (client language) and name -> node, from the game's own
-- flight node list (C_TaxiMap.GetTaxiNodesForMap on both continents).
function Geo.TaxiNames()
  if Geo.taxiNames then return Geo.taxiNames end
  local byName, byId = {}, {}
  for _, mapID in ipairs({ 1414, 1415 }) do
    local ok, list = pcall(C_TaxiMap.GetTaxiNodesForMap, mapID)
    for _, info in ipairs(ok and type(list) == "table" and list or {}) do
      if info.nodeID and type(info.name) == "string" and info.name ~= "" then
        byName[info.name], byId[info.nodeID] = info.nodeID, info.name
      end
    end
  end
  for id, n in pairs(OM.flights.nodes) do
    if type(n[1]) == "string" and not byName[n[1]] then byName[n[1]] = id end
  end
  if next(byId) then Geo.taxiNames = { byName = byName, byId = byId } end
  return { byName = byName, byId = byId }
end

function Geo.NodeName(id)
  local n = OM.flights.nodes[id]
  return Geo.TaxiNames().byId[id] or (n and n[1]) or "?"
end

-- Flight nodes learned by the character: OpenMap's list (it records them at every flight master),
-- by name, turned into node numbers. Returns the set and its size.
function Geo.KnownNodes()
  local char = OM.worldmap.char
  local learned = type(char) == "table" and type(char.flightsKnown) == "table" and char.flightsKnown or {}
  local n = 0
  for _ in pairs(learned) do n = n + 1 end
  local c = Geo.knownCache
  if c and c.learned == learned and c.n == n then return c.set, c.count end
  local byName = Geo.TaxiNames().byName
  local set, count = {}, 0
  for name in pairs(learned) do
    local id = byName[name]
    if id and not set[id] and Geo.NodeUsable(id) then set[id], count = true, count + 1 end
  end
  Geo.knownCache = { learned = learned, n = n, set = set, count = count }
  return set, count
end

local function TaxiCount()
  local _, count = Geo.KnownNodes()
  return count
end

-- Learned flight masters: node -> { c, x, y, name, node }.
local function KnownFlights()
  local out = {}
  for id in pairs((Geo.KnownNodes())) do
    local p = Geo.NodePoint(id)
    p.name, p.node = Geo.NodeName(id), id
    out[id] = p
  end
  return out
end

-- Flight node at a point (a flight master's position), nil if none is close enough.
function Geo.NodeAt(p)
  if not p then return nil end
  local best, bd
  for id, n in pairs(OM.flights.nodes) do
    if n[2] == p.c then
      local dx, dy = n[3] - p.x, n[4] - p.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d < K.NODE_MATCH and (not bd or d < bd) then best, bd = id, d end
    end
  end
  return best
end

-- Flight lengths (yards) from node `from` to every node reachable over `learned` nodes only
-- (the ends included): Dijkstra over OpenMap's flight paths. Nodes the flight map shows as
-- unreachable are exactly those no such path joins.
function Geo.FlightDists(from, learned)
  if not Geo.flightEdges then
    local edges = {}
    for _, e in ipairs(OM.flights.paths) do
      edges[e[1]] = edges[e[1]] or {}
      table.insert(edges[e[1]], { e[2], e[3] })
    end
    Geo.flightEdges = edges
  end
  local dist, done = { [from] = 0 }, {}
  while true do
    local k, kd
    for id, d in pairs(dist) do
      if not done[id] and (not kd or d < kd) then k, kd = id, d end
    end
    if not k then break end
    done[k] = true
    for _, e in ipairs(Geo.flightEdges[k] or {}) do
      local to = e[1]
      if learned[to] and not done[to] then
        local nd = kd + e[2]
        if not dist[to] or nd < dist[to] then dist[to] = nd end
      end
    end
  end
  return dist
end

-- Faction allowed on a boat/zeppelin/airship line (nil: everyone).
function Geo.TransportFaction(t)
  if t.faction then return t.faction end
  if t[1] == "zeppelin" then return "Horde" end
  if t[1] == "airship" or K.TRANSPORT_NEUTRAL[t[2]] then return nil end
  return "Alliance"
end

function Geo.IsShip(mode)
  return mode == "zeppelin" or mode == "bateau" or mode == "airship"
end

-- Docks of the character's faction and the lines between them (directed), built once.
function Geo.Docks()
  if Geo.docks then return Geo.docks end
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  local docks, links = {}, {}
  local function dockAt(c, x, y, mode, route)
    for i, d in ipairs(docks) do
      if d.p.c == c and math.abs(d.p.x - x) < K.DOCK_MERGE and math.abs(d.p.y - y) < K.DOCK_MERGE then return i end
    end
    local zone
    local ok, ui = pcall(C_Map.GetMapPosFromWorldPos, c, CreateVector2D(x, y))
    local info = ok and ui and C_Map.GetMapInfo(ui)
    zone = info and info.name or route
    docks[#docks + 1] = { name = (K.MODE_NAME[mode] or mode) .. " (" .. zone .. ")", p = { c = c, x = x, y = y } }
    return #docks
  end
  for _, t in ipairs(OM.places.transports) do
    local f = Geo.TransportFaction(t)
    local mode = K.TRANSPORT_MODE[t[1]]
    if mode and (not f or f == faction) then
      local a = dockAt(t[3], t[4], t[5], mode, t[2])
      local b = dockAt(t[6], t[7], t[8], mode, t[2])
      links[#links + 1] = { a, b, mode }
    end
  end
  Geo.docks = { docks = docks, links = links }
  return Geo.docks
end

-- Zone (name, minimum level) at a world point; cached by 200 m squares. Levels: OpenMap.MapLevels
-- (the client's tables have none); zones it does not list (cities...) have no level.
local zoneCache = {}
local function ZoneAt(p)
  local key = p.c .. ":" .. math.floor(p.x / 200) .. ":" .. math.floor(p.y / 200)
  local z = zoneCache[key]
  if z == nil then
    z = false
    local ok, ui, mp = pcall(C_Map.GetMapPosFromWorldPos, p.c, CreateVector2D(p.x, p.y))
    if ok and ui and mp then
      local mx, my = mp:GetXY()
      local okI, info = pcall(C_Map.GetMapInfoAtPosition, ui, mx, my)
      local zoneMap = (okI and info and info.mapID) or ui
      local lv = OM.levels[zoneMap]
      if lv and lv[1] then
        z = { name = (okI and info and info.name) or AreaName(0), min = lv[1] }
      end
    end
    zoneCache[key] = z
  end
  return z or nil
end

-- Level range "lo-hi" in the quest colours for the player (OpenMap's own colouring).
function Geo.LevelRange(lo, hi)
  if not lo then return "" end
  local ok, code, range = pcall(OM.worldmap.LevelColor, lo, hi or lo)
  if not ok or not code then return lo .. "-" .. (hi or lo) end
  return code .. range .. "|r"
end

-- Level range of the zone (uiMapID), coloured, or nil.
function Geo.ZoneLevelText(uiMapID)
  local lv = uiMapID and OM.levels[uiMapID]
  return lv and lv[1] and Geo.LevelRange(lv[1], lv[2]) or nil
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
-- extra: flight masters not learned yet, used as if their flight path were activated
-- ({ name, p, node }, custom Roadbook: flight paths activated on the way).
local function BuildNetwork(speed, extra)
  local hubs = {}
  local learned = {}
  for id in pairs((Geo.KnownNodes())) do learned[id] = true end
  for id in pairs(learned) do
    hubs[#hubs + 1] = { kind = "taxi", name = Geo.NodeName(id), p = Geo.NodePoint(id), node = id }
  end
  for _, h in ipairs(extra or {}) do
    local id = h.node or Geo.NodeAt(h.p)
    if not (id and learned[id]) then
      if id then learned[id] = true end
      hubs[#hubs + 1] = { kind = "taxi", name = h.name, p = { c = h.p.c, x = h.p.x, y = h.p.y }, node = id, guess = true }
    end
  end
  local dk = Geo.Docks()
  local dockIndex = {}
  for k, dock in ipairs(dk.docks) do
    hubs[#hubs + 1] = { kind = "dock", name = dock.name, p = dock.p }
    dockIndex[k] = #hubs
  end

  local n = #hubs
  local D, nxt, via = {}, {}, {}
  for i = 1, n do
    D[i], nxt[i], via[i] = {}, {}, {}
    local a = hubs[i]
    local fd = (a.kind == "taxi" and a.node) and Geo.FlightDists(a.node, learned) or nil
    for j = 1, n do
      nxt[i][j] = j
      if i == j then
        D[i][j] = 0
      else
        local b = hubs[j]
        local d = Dist(a.p, b.p)
        local best, how = math.huge, nil
        if d then best, how = d * K.PATH_FACTOR / speed, "walk" end
        local len = fd and b.kind == "taxi" and b.node and fd[b.node]
        if len then
          local fl = len / K.FLIGHT_SPEED + K.FLIGHT_OVERHEAD
          if fl < best then best, how = fl, "flight" end
        end
        D[i][j], via[i][j] = best, how
      end
    end
  end
  for _, l in ipairs(dk.links) do
    local i, j = dockIndex[l[1]], dockIndex[l[2]]
    if i and j and K.TRANSPORT_TIME < D[i][j] then D[i][j], via[i][j] = K.TRANSPORT_TIME, l[3] end
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
      elseif Geo.IsShip(mode) then
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
ns.Nearest, ns.PlayerPos, ns.PointText, ns.QuestTargets, ns.RemainingTargets = Nearest, PlayerPos, PointText, QuestTargets, RemainingTargets
ns.Route, ns.RouteText, ns.StartPoints, ns.TaxiCount, ns.KnownFlights, ns.TravelSpeed = Route, RouteText, StartPoints, TaxiCount, KnownFlights, TravelSpeed
ns.UnitTime, ns.WorldPos = UnitTime, WorldPos
