-- Forever Quest Planner: geography, transport network, quest targets.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AreaName, Color, HasBit, K, L, OM, QDB, QGet = ns.AreaName, ns.Color, ns.HasBit, ns.K, ns.L, ns.OM, ns.QDB, ns.QGet
local Settings = ns.Settings
local Guard = ns.Guard
local LearnedData, LearnedChar, PlayerFaction, NpcFriendly = ns.LearnedData, ns.LearnedChar, ns.PlayerFaction, ns.NpcFriendly
local Print = ns.Print
local GetObjectives = ns.GetObjectives

---------------------------------------------------------------------------
-- Geography: QuestieDB positions converted to world coordinates (game map API)
---------------------------------------------------------------------------
local Geo = { npc = {}, object = {}, targets = {}, givers = {} }
K.CROSS_CONTINENT = 480 -- flat seconds to change continent
K.PATH_FACTOR = 1.35    -- paths are never straight lines
K.OVERHEAD = 20         -- dialogs, quest pick-up/turn-in
K.INSTANCE_MATCH = 400  -- yards: an OpenMap dungeon entrance this close to QuestieDB's is the same one
K.MAX_DROP_SOURCES = 6  -- monsters or objects looked at for an item to loot, at most

local function LoadDataString(v)
  if type(v) == "table" then return v end
  if type(v) == "string" and loadstring then
    local fn = loadstring(v)
    if fn then
      setfenv(fn, {}) -- a table written as code: it needs, and gets, no global
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

-- Drop rate (%) of an item on an NPC, in Questie's order: manual corrections, then the private server
-- data (quest-only drops, measured on players having the quest), then Wowhead's (every kill counted:
-- far too low for an item that only drops during the quest). Questie's own DropDB when Questie is
-- loaded, otherwise the same order on the tables shipped with QuestieDB. nil: unknown.
K.DROP_WOWHEAD, K.DROP_PSERVER = -1, -2 -- correction pointing to another table (Questie's DropDB.correctionKeys)
local function DropRate(itemId, npcId)
  if Geo.dropDB == nil then
    Geo.dropDB = false
    if QuestieLoader and QuestieLoader.ImportModule then
      local ok, db = pcall(QuestieLoader.ImportModule, QuestieLoader, "DropDB")
      if ok and type(db) == "table" and db.GetItemDroprate then Geo.dropDB = db end
    end
  end
  if Geo.dropDB and Geo.dropDB.tablePserver then -- Questie loaded and its drop tables ready
    local ok, r = pcall(Geo.dropDB.GetItemDroprate, itemId, npcId)
    if ok then return type(r) == "table" and r[1] or nil end
  end
  if Geo.drops == nil then
    Geo.drops = false
    local ok, mod = pcall(QDB.lib.Support.Get, "QuestieClassicItemDrops")
    if ok and type(mod) == "table" then
      local okC, fix = pcall(QDB.lib.Support.Get, "QuestieItemDropCorrections")
      Geo.drops = { wowhead = LoadDataString(mod.wowheadData) or {}, pserver = LoadDataString(mod.cmangosData) or {},
        fix = okC and type(fix) == "table" and type(fix.Era) == "table" and fix.Era or {} }
    end
  end
  local d = Geo.drops
  if not d then return nil end
  local function get(t)
    local row = t[itemId]
    return row and row[npcId]
  end
  local fix = get(d.fix)
  if fix and fix >= 0 then return fix end
  if fix == K.DROP_WOWHEAD and get(d.wowhead) then return get(d.wowhead) end
  return get(d.pserver) or get(d.wowhead)
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
  for _, e in ipairs(OM.Instances()) do
    local p
    if e.c then
      p = { c = e.c, x = e.x, y = e.y }
    elseif e.map then
      local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, e.map, CreateVector2D(e.u, e.v))
      if ok and cont and pos then
        local wx, wy = pos:GetXY()
        p = { c = cont, x = wx, y = wy }
      end
    end
    if p then out[#out + 1] = { p = p, min = e.minLevel, max = e.maxLevel } end
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

-- Quest started by an item that an NPC or an object is listed with too (QuestieDB data conflict).
local function ItemAndGiver(givers)
  return type(givers) == "table" and type(givers[3]) == "table" and #givers[3] > 0
    and (#(givers[1] or {}) > 0 or #(givers[2] or {}) > 0)
end

local function GiverPoints(givers)
  local pts = {}
  if type(givers) ~= "table" then return pts end
  -- The item gives the quest: where it drops (monsters, objects), not the giver listed with it.
  if ItemAndGiver(givers) then
    for _, itemId in ipairs(givers[3]) do
      local npcs = QGet(QDB.Item, itemId, "npcDrops") or {}
      for i = 1, math.min(#npcs, K.MAX_DROP_SOURCES) do
        for _, p in ipairs(EntityPoints("npc", npcs[i])) do pts[#pts + 1] = p end
      end
      local objs = QGet(QDB.Item, itemId, "objectDrops") or {}
      for i = 1, math.min(#objs, K.MAX_DROP_SOURCES) do
        for _, p in ipairs(EntityPoints("object", objs[i])) do pts[#pts + 1] = p end
      end
    end
    if #pts > 0 then return pts end
  end
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

-- Places of a searched quest giver found empty by the player ("Not here"), saved until the quest is
-- picked up or leaves the list: { [quest id] = { { c, x, y } } }.
function Geo.DismissPlace(id, p)
  if not (p and p.c and p.x) then return end
  local st = Settings()
  st.dismissedPlaces = st.dismissedPlaces or {}
  local list = st.dismissedPlaces[id] or {}
  st.dismissedPlaces[id] = list
  list[#list + 1] = { c = p.c, x = p.x, y = p.y }
end

function Geo.PlaceDismissed(id, p)
  local all = Settings().dismissedPlaces
  for _, d in ipairs(all and all[id] or {}) do
    if d.c == p.c and math.abs(d.x - p.x) < K.START_MERGE and math.abs(d.y - p.y) < K.START_MERGE then return true end
  end
  return false
end

-- id: that quest's places; nil: every quest's.
function Geo.ForgetDismissedPlaces(id)
  local st = Settings()
  if not id then st.dismissedPlaces = nil
  elseif st.dismissedPlaces then st.dismissedPlaces[id] = nil end
end

-- Places where the quest giver may stand: one NPC (the only giver) whose spawns are in several places
-- far apart (it moves between them). Each place is one step to check in the Roadbook. Several NPCs
-- or objects can each start it: the nearest one is enough (nil then, as for a single place).
K.START_MERGE = 150     -- yards: spawns this close are the same place
K.START_PLACES_MAX = 5  -- places checked, at most (the nearest to `from`)
function Geo.StartPlaces(id, from)
  local by = QGet(QDB.Quest, id, "startedBy")
  if type(by) ~= "table" or #(by[2] or {}) > 0 or #(by[1] or {}) ~= 1 or ItemAndGiver(by) then return nil end
  Geo.startPlaces = Geo.startPlaces or {}
  local places = Geo.startPlaces[id]
  if places == nil then
    places = {}
    local spawns = QGet(QDB.Npc, by[1][1], "spawns")
    for zone, list in pairs(type(spawns) == "table" and spawns or {}) do
      for _, sp in ipairs(type(list) == "table" and list or {}) do
        local w = type(sp) == "table" and sp[1] and sp[1] >= 0 and WorldPos(zone, sp[1], sp[2])
        if w then
          local merged = false
          for _, pl in ipairs(places) do
            if pl.c == w.c and math.abs(pl.x - w.x) < K.START_MERGE and math.abs(pl.y - w.y) < K.START_MERGE then
              merged = true
              break
            end
          end
          if not merged then places[#places + 1] = w end
        end
      end
    end
    if #places < 2 then places = false end
    Geo.startPlaces[id] = places
  end
  if not places then return nil end
  local list = {}
  for _, pl in ipairs(places) do
    if not Geo.PlaceDismissed(id, pl) then list[#list + 1] = pl end
  end
  if #list == 0 then -- every place found empty: all to check again
    Geo.ForgetDismissedPlaces(id)
    for i, pl in ipairs(places) do list[i] = pl end
  end
  if from then
    local function d(p)
      local dx, dy = p.x - from.x, p.y - from.y
      return (p.c == from.c) and math.sqrt(dx * dx + dy * dy) or math.huge
    end
    table.sort(list, function(a, b) return d(a) < d(b) end)
  end
  for i = #list, K.START_PLACES_MAX + 1, -1 do list[i] = nil end
  return list
end

local Solver = ns.Solver
local Dist = Solver.Dist

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

K.RUN_SPEED = 7 -- yards/s on foot

-- Remembers the mount speed while you are mounted (every K.PASS_TICK seconds, Events.lua).
function Geo.LearnMountSpeed()
  if GetUnitSpeed and IsMounted and IsMounted() then
    local _, run = GetUnitSpeed("player")
    if run and run > K.RUN_SPEED then LearnedChar().mountSpeed = run end
  end
end

-- Travel speed: running, or the mount speed remembered the last time you were mounted.
local function TravelSpeed()
  return math.max(K.RUN_SPEED, LearnedChar().mountSpeed or K.RUN_SPEED)
end

-- A point's own fields, in a new table (saved data, solver problem).
function Geo.CopyPoint(p)
  if not p then return nil end
  return { c = p.c, x = p.x, y = p.y, area = p.area, ui = p.ui, mx = p.mx, my = p.my, zoneName = p.zoneName,
    teleport = p.teleport, cast = p.cast, instance = p.instance, lmin = p.lmin, lmax = p.lmax }
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
K.SHIP_MODES = { boat = true, zeppelin = true, airship = true } -- OpenMap's kinds of transport lines

local function PlayerFactionBit()
  local f = PlayerFaction()
  return (f == "A" and 1) or (f == "H" and 2) or 0
end

-- A flight node the character can use: its faction, and its class when it flies only one (Nighthaven).
function Geo.NodeUsable(id)
  local n = OM.FlightNodes()[id]
  if not (n and HasBit(n.faction, PlayerFactionBit())) then return false end
  return not n.class or n.class == select(2, UnitClass("player"))
end

-- Flight node -> world point.
function Geo.NodePoint(id)
  local n = OM.FlightNodes()[id]
  return n and { c = n.c, x = n.x, y = n.y } or nil
end

-- The game's names of the flight nodes (client language) and name -> node, from the game's own
-- flight node list (C_TaxiMap.GetTaxiNodesForMap on both continents).
function Geo.TaxiNames()
  if Geo.taxiNames then return Geo.taxiNames end
  local byName, byId = {}, {}
  for _, mapID in ipairs(ns.CONTINENT_MAPS) do
    local ok, list = pcall(C_TaxiMap.GetTaxiNodesForMap, mapID)
    for _, info in ipairs(ok and type(list) == "table" and list or {}) do
      if info.nodeID and type(info.name) == "string" and info.name ~= "" then
        byName[info.name], byId[info.nodeID] = info.nodeID, info.name
      end
    end
  end
  for id, n in pairs(OM.FlightNodes()) do
    if type(n.name) == "string" and not byName[n.name] then byName[n.name] = id end
  end
  if next(byId) then Geo.taxiNames = { byName = byName, byId = byId } end
  return { byName = byName, byId = byId }
end

function Geo.NodeName(id)
  local n = OM.FlightNodes()[id]
  return Geo.TaxiNames().byId[id] or (n and n.name) or "?"
end

-- Flight nodes learned by the character: OpenMap's list (it records them at every flight master),
-- by name, turned into node numbers. Returns the set and its size.
function Geo.KnownNodes()
  local learned = OM.LearnedFlights()
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
  for id, n in pairs(OM.FlightNodes()) do
    if n.c == p.c then
      local dx, dy = n.x - p.x, n.y - p.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d < K.NODE_MATCH and (not bd or d < bd) then best, bd = id, d end
    end
  end
  return best
end

-- Boat, zeppelin and airship lines of OpenMap, each with its faction filled in: OpenMap's own `faction`
-- field when it has one, else the supplement of Data/Supplements.lua (a line OpenMap gives none),
-- else the convention of its kind. Rows as ns.OM.Transports gives them, `faction` always set
-- ("Alliance", "Horde" or "Neutral": everyone). Built once.
function Geo.Transports()
  if Geo.transports then return Geo.transports end
  local out = {}
  for _, t in ipairs(OM.Transports()) do
    local row = {}
    for k, v in pairs(t) do row[k] = v end
    local sup = ns.TRANSPORT_SUPPLEMENT[t.route]
    row.faction = t.faction or (sup and sup.faction) or ns.TRANSPORT_KIND_FACTION[t.kind] or "Neutral"
    out[#out + 1] = row
  end
  Geo.transports = out
  return out
end

function Geo.IsShip(mode)
  return K.SHIP_MODES[mode] == true
end

-- Docks of the character's faction and the lines between them (directed), built once.
-- Name of a dock: the town it serves (nearest flight node of any faction, "Orgrimmar, Durotar" ->
-- "Orgrimmar"), else its zone, else the line's name.
K.DOCK_TOWN = 1200 -- yards: a flight node this close names the dock
function Geo.DockName(c, x, y, route)
  local best, bd
  for id, n in pairs(OM.FlightNodes()) do
    if n.c == c then
      local dx, dy = n.x - x, n.y - y
      local d = math.sqrt(dx * dx + dy * dy)
      if d < K.DOCK_TOWN and (not bd or d < bd) then best, bd = id, d end
    end
  end
  if best then
    local name = Geo.NodeName(best)
    if name and name ~= "?" then return (name:match("^(.-),") or name) end
  end
  local ok, ui = pcall(C_Map.GetMapPosFromWorldPos, c, CreateVector2D(x, y))
  local info = ok and ui and C_Map.GetMapInfo(ui)
  return info and info.name or route
end

function Geo.Docks()
  if Geo.docks then return Geo.docks end
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  local docks, links = {}, {}
  local function dockAt(c, x, y, mode, route)
    for i, d in ipairs(docks) do
      if d.p.c == c and math.abs(d.p.x - x) < K.DOCK_MERGE and math.abs(d.p.y - y) < K.DOCK_MERGE then return i end
    end
    docks[#docks + 1] = { name = Geo.DockName(c, x, y, route), p = { c = c, x = x, y = y } }
    return #docks
  end
  for _, t in ipairs(Geo.Transports()) do
    local mode = Geo.IsShip(t.kind) and t.kind
    if mode and (t.faction == "Neutral" or t.faction == faction) then
      local a = dockAt(t.from.c, t.from.x, t.from.y, mode, t.route)
      local b = dockAt(t.to.c, t.to.x, t.to.y, mode, t.route)
      links[#links + 1] = { a, b, mode }
    end
  end
  local dk = { docks = docks, links = links }
  if Geo.taxiNames then Geo.docks = dk end -- the game's town names known: kept for the session
  return dk
end

---------------------------------------------------------------------------
-- Zones and the walking passes between them: a walk from a zone to another goes through a pass
-- (mountain pass, tunnel, bridge), a straight line within a zone. Passes: QuestieDB's patrols
-- crossing a border and the Warcraft Wiki's (Data/Passes.lua), completed by those learned in game
-- (the player walked from a zone to another, account-wide). Zones without any pass: straight line.
---------------------------------------------------------------------------
K.ZONE_CELL = 100        -- yards: zone lookups cached by squares of this size
K.PASS_PATH_FACTOR = 1.2 -- a walk through passes: its main detours are already in its way
K.PASS_MIN = 200         -- yards: shorter walks stay straight
K.PASS_MERGE = 150       -- yards: two passes of the same zones this close are the same one
K.PASS_TICK = 2          -- seconds between two position readings (learning)
K.PASS_SLACK = 1.5       -- a move longer than speed x time x this is no walk (transport, teleport)
K.PATROL_GAP = 80        -- yards: a patrol's path ends this close on both sides of a border make a pass

-- uiMapID and name of the zone (or city) at a world point, nil out of any zone (sea...).
-- A dungeon or micro map counts as the zone holding it.
function Geo.ZoneIdRaw(p)
  local ok, ui, mp = pcall(C_Map.GetMapPosFromWorldPos, p.c, CreateVector2D(p.x, p.y))
  if not (ok and ui and mp) then return nil end
  local mx, my = mp:GetXY()
  local okI, info = pcall(C_Map.GetMapInfoAtPosition, ui, mx, my)
  if not (okI and info) then info = C_Map.GetMapInfo(ui) end
  local zone = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
  for _ = 1, 4 do
    if not (info and info.mapType and info.mapType > zone and info.parentMapID) then break end
    info = C_Map.GetMapInfo(info.parentMapID)
  end
  if not (info and info.mapType == zone) then return nil end
  return info.mapID, info.name
end

local zoneIdCache = {}
function Geo.ZoneIdAt(p)
  local key = p.c .. ":" .. math.floor(p.x / K.ZONE_CELL) .. ":" .. math.floor(p.y / K.ZONE_CELL)
  local z = zoneIdCache[key]
  if z == nil then
    local id, name = Geo.ZoneIdRaw(p)
    z = id and { id = id, name = name } or false
    zoneIdCache[key] = z
  end
  if not z then return nil end
  return z.id, z.name
end

-- Passes learned in game: { c, x, y, a, b, n } (world point, the zones' uiMapIDs a < b, times seen).
function Geo.LearnedPasses()
  return LearnedData().passes
end

-- Passes from QuestieDB's patrols: two ends of a patrol's paths in two zones, close to each other.
local function PatrolPasses(out)
  for _, id in ipairs(ns.PASS_PATROLS) do
    local ends = {}
    local wp = QGet(QDB.Npc, id, "waypoints")
    for area, paths in pairs(type(wp) == "table" and wp or {}) do
      local zone = Geo.AreaUi(area)
      for _, path in ipairs(zone and type(paths) == "table" and paths or {}) do
        for _, pt in ipairs({ path[1], path[#path] }) do
          local w = type(pt) == "table" and pt[1] and pt[1] >= 0 and WorldPos(area, pt[1], pt[2])
          if w then ends[#ends + 1] = { p = w, zone = zone } end
        end
      end
    end
    for i = 1, #ends do
      for j = i + 1, #ends do
        local e, f = ends[i], ends[j]
        local d = e.zone ~= f.zone and Dist(e.p, f.p)
        if d and d < K.PATROL_GAP then
          out[#out + 1] = { c = e.p.c, x = (e.p.x + f.p.x) / 2, y = (e.p.y + f.p.y) / 2,
            a = math.min(e.zone, f.zone), b = math.max(e.zone, f.zone) }
        end
      end
    end
  end
end

-- The pass of `list` that is the same as `ps`: same two zones, within K.PASS_MERGE; nil if none.
local function SamePass(list, ps)
  for _, other in ipairs(list) do
    local d = other.a == ps.a and other.b == ps.b and Dist(other, ps)
    if d and d < K.PASS_MERGE then return other end
  end
end

local patrolFailureTold -- said once a session

-- Every pass: { c, x, y, a, b }. Those of the other sources (patrols, wiki), then the learned ones
-- that add a way: the learned passes already listed are kept in the saved data only.
function Geo.Passes()
  if Geo.passList then return Geo.passList end
  local list = {}
  if GeoReady() then
    local ok, err = pcall(PatrolPasses, list) -- QuestieDB's data: the other passes stay usable
    if not ok and not patrolFailureTold then
      patrolFailureTold = true
      Print(L["Zone passes from QuestieDB's patrols unavailable: "] .. tostring(err))
    end
  end
  for _, s in ipairs(ns.PASSES) do
    local ok, c, w = pcall(C_Map.GetWorldPosFromMapPos, s[1], CreateVector2D(s[2] / 100, s[3] / 100))
    if ok and c and w then
      local x, y = w:GetXY()
      list[#list + 1] = { c = c, x = x, y = y, a = math.min(s[1], s[4]), b = math.max(s[1], s[4]) }
    end
  end
  for _, ps in ipairs(Geo.LearnedPasses()) do
    if not SamePass(list, ps) then list[#list + 1] = ps end
  end
  Geo.passList = list
  return list
end

function Geo.PassesChanged()
  Geo.passList, Geo.liveWorld = nil, nil
end

-- Walks of the travel model (Solver.lua) in the live world: distance and passes on the way, time at `speed`.
function Geo.WalkWay(a, b)
  return Solver.WalkWay(Geo.World(), a, b)
end

function Geo.WalkTime(a, b, speed)
  return Solver.WalkTime(Geo.World(), a, b, speed)
end

-- Learning, every K.PASS_TICK seconds: a walk from a zone to another (not flying, not on a boat:
-- the move matches the player's own speed) records the pass between the two readings.
function Geo.PassTick()
  local last = Geo.passLast
  Geo.passLast = nil
  local p = PlayerPos()
  if not p or (IsInInstance and IsInInstance()) or (UnitOnTaxi and UnitOnTaxi("player")) then return end
  local zone, name = Geo.ZoneIdRaw(p)
  local speed = GetUnitSpeed and GetUnitSpeed("player") or 0
  local now = GetTime()
  Geo.passLast = { p = p, zone = zone, name = name, speed = speed, t = now }
  if not (last and zone and last.zone and last.zone ~= zone) then return end
  local dt, d = now - last.t, Dist(last.p, p)
  if not d or dt > K.PASS_TICK * 2 or d > math.max(speed, last.speed) * dt * K.PASS_SLACK + 5 then return end
  local mid = { c = p.c, x = (last.p.x + p.x) / 2, y = (last.p.y + p.y) / 2,
    a = math.min(last.zone, zone), b = math.max(last.zone, zone) }
  local list = Geo.LearnedPasses()
  local known = SamePass(list, mid)
  if known then
    known.n = (known.n or 1) + 1
    return
  end
  list[#list + 1] = { c = mid.c, x = math.floor(mid.x + 0.5), y = math.floor(mid.y + 0.5), a = mid.a, b = mid.b, n = 1 }
  Geo.PassesChanged()
  ns.Print(string.format(L["Zone pass learned: %s - %s."], last.name or "?", name or "?"))
end

-- Level range "lo-hi" in the quest colours for the player (OpenMap's own colouring).
function Geo.LevelRange(lo, hi)
  if not lo then return "" end
  local ok, code, range = Guard(OM.LevelColor, lo, hi or lo)
  if not ok or not code then return lo .. "-" .. (hi or lo) end
  return code .. range .. "|r"
end

-- Level range of the zone (uiMapID), coloured, or nil.
function Geo.ZoneLevelText(uiMapID)
  local lv = uiMapID and OM.ZoneLevels()[uiMapID]
  return lv and Geo.LevelRange(lv.min, lv.max) or nil
end

-- Level range of a place known by its name (quest log headers, Available categories): a dungeon
-- (its entrance's group finder range, OpenMap) or a zone (OpenMap.MapLevels). Coloured, or nil.
-- The name -> { lo, hi } index is built once; colours follow the player's current level.
function Geo.PlaceLevelText(name)
  if not name then return nil end
  if not Geo.placeLevels then
    if not GeoReady() then return nil end
    local idx = {}
    for ui, lv in pairs(OM.ZoneLevels()) do
      local info = C_Map.GetMapInfo and C_Map.GetMapInfo(ui)
      if info and info.name and info.name ~= "" then idx[info.name] = { lv.min, lv.max } end
    end
    for area, ui in pairs(Geo.areaToUi) do
      local lv = OM.ZoneLevels()[ui]
      local n = lv and AreaName(area)
      if n and not idx[n] then idx[n] = { lv.min, lv.max } end
    end
    for d in pairs(QDB.dungeons) do -- a dungeon wins over a zone of the same name
      local w = DungeonEntrance(d)
      if w and w.lmin then idx[AreaName(d) or "?"] = { w.lmin, w.lmax } end
    end
    Geo.placeLevels = idx
  end
  local r = Geo.placeLevels[name]
  return r and Geo.LevelRange(r[1], r[2]) or nil
end

-- "label lo-hi": the label followed by the level range of the place name (unchanged if unknown).
function Geo.WithLevel(label, name)
  local lv = Geo.PlaceLevelText(name)
  return lv and (label .. " " .. lv) or label
end

-- Readable directions to go from a to b.
-- net: a network of the live world (Geo.Net).
local function RouteText(a, b, net, plevel)
  if not a or not b then return nil end
  local W = Geo.World()
  local _, choice = Solver.Route(W, a, b, net, plevel)
  local parts = {}
  local function walk(p, q, toName)
    local d, way = Geo.WalkWay(p, q)
    if not d or d < 40 then return end
    local _, worst, zone = Solver.WalkCost(W, p, q, net.speed, plevel)
    local s = toName and string.format(L["walk to %s (%.0f m)"], toName, d) or string.format(L["walk %.0f m"], d)
    if way then s = s .. string.format(L[" through %d zone pass(es)"], #way) end
    if worst and worst > plevel + K.DANGER_MARGIN then
      s = s .. Color(K.DESC.bad, string.format(L[" [crosses %s, level %d+]"], W.zones[zone].name or "?", worst))
    end
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
      local nx = choice.nxt[cur][choice.j]
      local mode = choice.via[cur][nx]
      if mode == "flight" then
        flightFrom = flightFrom or hubs[cur].name
        if choice.via[nx][choice.nxt[nx][choice.j]] ~= "flight" or nx == choice.j then
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

-- Target of an item to collect: where it drops (monsters, objects), with the average drop rate.
function Geo.AddItemTarget(add, itemId)
  -- Drop rate: average over the monsters, each weighted by its number of spawns (the ones met).
  local pts, rateSum, rateN = {}, 0, 0
  local npcs = QGet(QDB.Item, itemId, "npcDrops") or {}
  for i = 1, math.min(#npcs, K.MAX_DROP_SOURCES) do
    local spawns = EntityPoints("npc", npcs[i])
    for _, p in ipairs(spawns) do pts[#pts + 1] = p end
    local r = DropRate(itemId, npcs[i])
    if r and #spawns > 0 then rateSum, rateN = rateSum + r * #spawns, rateN + #spawns end
  end
  local objs = QGet(QDB.Item, itemId, "objectDrops") or {}
  for i = 1, math.min(#objs, K.MAX_DROP_SOURCES) do
    for _, p in ipairs(EntityPoints("object", objs[i])) do pts[#pts + 1] = p end
  end
  local kind = (#npcs == 0 and #objs > 0) and "object" or "item"
  if #pts == 0 then
    -- Not dropped by anything located: sold by vendors (QuestieDB `vendors`): one purchase.
    -- Every vendor of the player's faction (a common item has many: the nearest one is chosen later).
    for _, vid in ipairs(QGet(QDB.Item, itemId, "vendors") or {}) do
      if NpcFriendly(vid) ~= false then -- unknown: kept
        for _, p in ipairs(EntityPoints("npc", vid)) do
          if not p.instance then pts[#pts + 1] = p end
        end
      end
    end
    if #pts > 0 then kind = "buy" end
  end
  local ids = {}
  for i = 1, math.min(#npcs, K.MAX_DROP_SOURCES) do ids[#ids + 1] = npcs[i] end
  add(kind, QGet(QDB.Item, itemId, "name"), pts, rateN > 0 and rateSum / rateN or nil, npcs[1], #ids > 0 and ids or nil)
end

-- Static quest targets: located objectives, start, end.
local function QuestTargets(id)
  local t = Geo.targets[id]
  if t then return t end
  t = { id = id }
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
          tg.elite = K.ELITE_RANKS[rank] or false
        end
      end
      t[#t + 1] = tg
    end
  end
  local obj = QGet(QDB.Quest, id, "objectives")
  if type(obj) == "table" then
    for _, o in ipairs(obj[1] or {}) do
      local icon = o[3] -- QuestieDB icon type: 3 event, 5 talk, 17 interact; otherwise a monster to kill
      if K.TALK_ICONS[icon] then
        -- One action at the NPC (speak, scripted event…): no monster to kill, no monster XP.
        add("talk", QGet(QDB.Npc, o[1], "name"), EntityPoints("npc", o[1]))
      else
        add("kill", QGet(QDB.Npc, o[1], "name"), EntityPoints("npc", o[1]), nil, o[1])
      end
    end
    for _, o in ipairs(obj[2] or {}) do
      add("object", QGet(QDB.Object, o[1], "name"), EntityPoints("object", o[1]))
    end
    for _, o in ipairs(obj[3] or {}) do Geo.AddItemTarget(add, o[1]) end
    for _, o in ipairs(obj[5] or {}) do
      if type(o) == "table" and o[2] then
        add("kill", o[3] or QGet(QDB.Npc, o[2], "name"), EntityPoints("npc", o[2]), nil, o[2])
      end
    end
  end
  -- Items needed but not counted by the quest (QuestieDB requiredSourceItems: "bring the remains
  -- to the grave"): one target where each drops, done before the objectives that use it.
  local srcIds = {}
  local given, objItems = QGet(QDB.Quest, id, "sourceItemId"), {}
  for _, o in ipairs(type(obj) == "table" and obj[3] or {}) do objItems[o[1]] = true end
  for _, itemId in ipairs(QGet(QDB.Quest, id, "requiredSourceItems") or {}) do
    if itemId ~= given and not objItems[itemId] then srcIds[#srcIds + 1] = itemId end
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
  local nPlaced, nCalls = #t, calls -- objectives (without the source items)
  for _, itemId in ipairs(srcIds) do
    local before = #t
    Geo.AddItemTarget(add, itemId)
    if #t > before then t[#t].sourceItem = itemId end
  end
  local hasSource = #t > nPlaced
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
    tg.defaultCount = tg.sourceItem and 1 or nums[i] or ((tg.kind == "kill" or tg.kind == "item") and 6 or 1)
    -- Objective done at a place with the source item (object, NPC, area): after the item.
    if hasSource and not tg.sourceItem and tg.kind ~= "kill" and tg.kind ~= "item" then tg.needsSource = true end
  end
  t.missing = nCalls - nPlaced -- objectives without a known position in QuestieDB (source items apart)
  t.start = StartPoints(id)
  t.finish = GiverPoints(QGet(QDB.Quest, id, "finishedBy"))
  Geo.targets[id] = t
  return t
end

-- Game objective of each QuestieDB target (t = QuestTargets): the one naming it, otherwise the one at
-- the same position (custom Forever quests: QuestieDB only has the English names, e.g.
-- "Kristof's Report" for "Rapport de Kristof"). Source items are not game objectives.
-- Returns { [target index] = objective index }, { [objective index] = true } (the ones matched).
function Geo.MatchObjectives(objs, t)
  local map, used = {}, {}
  for i, tg in ipairs(t) do
    if not tg.sourceItem and tg.name then
      for j, o in ipairs(objs) do
        if not used[j] and o.text and o.text:find(tg.name, 1, true) then
          map[i], used[j] = j, true
          break
        end
      end
    end
  end
  -- Positions last: they never take an objective that a target names.
  for i, tg in ipairs(t) do
    if not (tg.sourceItem or map[i]) and objs[i] and not used[i] then map[i], used[i] = i, true end
  end
  return map, used
end

-- Count of an item in the bags (the Forever client has C_Item.GetItemCount, not the global).
function Geo.ItemCount(id)
  return (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id))
    or (GetItemCount and GetItemCount(id)) or 0
end

-- Game objective (from objs, GetObjectives) of the target tg of quest id, or nil. tg can be a copy
-- (Roadbook saved: name and kind only).
function Geo.TargetObjective(id, tg, objs)
  if not (id and tg) then return nil end
  local t = QuestTargets(id)
  local k
  for i, x in ipairs(t) do
    if x == tg then k = i break end
  end
  if not k then
    for i, x in ipairs(t) do
      if x.name == tg.name and x.kind == tg.kind then k = i break end
    end
  end
  local j = k and Geo.MatchObjectives(objs, t)[k]
  if j then return objs[j] end
  if not tg.name then return nil end
  local lname = tg.name:lower() -- target no longer known: by its name alone
  for _, o in ipairs(objs) do
    if o.text and o.text:lower():find(lname, 1, true) then return o end
  end
  return nil
end

-- Quantities the game asks for a quest out of the log (its data loaded: Geo.AwaitTags):
-- { [target index] = quantity }, only the targets the game gives one for.
local function GameCounts(t)
  local objs, out = GetObjectives(t.id), {}
  for i, j in pairs((Geo.MatchObjectives(objs, t))) do
    local need = objs[j].need
    if need and need > 0 then out[i] = need end
  end
  return out
end

-- Remaining objectives: matches the game's objectives (with progress) to QuestieDB targets.
-- q: the quest in the log, nil for a quest to pick up (the game's quantities, else the default ones).
local function RemainingTargets(q, t)
  local out = {}
  local objs = (q and q.objectives) or {}
  local map, used = Geo.MatchObjectives(objs, t)
  local asked = q and {} or GameCounts(t)
  local allDone = true -- every objective listed by the game is done
  for _, o in ipairs(objs) do
    if not (o.finished or (o.need and o.have and o.need > 0 and o.have >= o.need)) then allDone = false end
  end
  for i, tg in ipairs(t) do
    local match = tg.sourceItem and -1 or map[i] -- source item: needed while it is not in the bags
    local count = asked[i] or tg.defaultCount
    -- The game lists its objectives and none is this "talk" target: a hidden objective (QuestieDB lists
    -- the turn-in NPC of "On Patrol" after the 3 NPCs to meet; the game shows only those 3 and the quest
    -- completes once the player has spoken to the turn-in NPC). Planned once every listed objective is done.
    if not match and tg.kind == "talk" and #objs > 0 then
      if not allDone then count = 0 end
    elseif match == -1 then
      if Geo.ItemCount(tg.sourceItem) > 0 then count = 0 end
    elseif match then
      local o = objs[match]
      if o.finished or (o.need and o.have and o.need > 0 and o.have >= o.need) then
        count = 0
      elseif o.need and o.have and o.need > 0 then
        count = o.need - o.have
      end
    end
    if count > 0 then out[#out + 1] = { tg = tg, count = count } end
  end
  -- Objectives that used the source items all done (items given away): they are no longer needed.
  local needs, users = false, false
  for _, tg in ipairs(t) do if tg.needsSource then users = true end end
  for _, r in ipairs(out) do if r.tg.needsSource then needs = true end end
  if users and not needs then
    for i = #out, 1, -1 do if out[i].tg.sourceItem then table.remove(out, i) end end
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

-- Where to pick up a quest: its giver, otherwise the monsters / objects dropping the item that
-- starts it, otherwise its first located objective, otherwise its turn-in NPC.
function Geo.GiverPoint(id, pos)
  local p = Nearest(StartPoints(id), pos)
  if p then return p, L["pick up the quest"] end
  local by = QGet(QDB.Quest, id, "startedBy")
  local items = type(by) == "table" and by[3]
  for _, itemId in ipairs(type(items) == "table" and items or {}) do
    local pts = {}
    for _, n in ipairs(QGet(QDB.Item, itemId, "npcDrops") or {}) do
      for _, w in ipairs(EntityPoints("npc", n)) do pts[#pts + 1] = w end
    end
    for _, o in ipairs(QGet(QDB.Item, itemId, "objectDrops") or {}) do
      for _, w in ipairs(EntityPoints("object", o)) do pts[#pts + 1] = w end
    end
    local q = Nearest(pts, pos)
    if q then return q, L["item that starts the quest"] end
  end
  local t = QuestTargets(id)
  for _, tg in ipairs(t) do
    local q = Nearest(tg.points, pos)
    if q then return q, tg.name or L["objective"] end
  end
  local f = Nearest(t.finish, pos)
  if f then return f, L["turn in the quest"] end
  return nil
end

-- Shared with the next files.
ns.AllInstance, ns.Dist, ns.EntityPoints, ns.Geo, ns.GeoReady = AllInstance, Dist, EntityPoints, Geo, GeoReady
ns.Nearest, ns.PlayerPos, ns.PointText, ns.QuestTargets, ns.RemainingTargets = Nearest, PlayerPos, PointText, QuestTargets, RemainingTargets
ns.RouteText, ns.StartPoints, ns.TaxiCount, ns.KnownFlights, ns.TravelSpeed = RouteText, StartPoints, TaxiCount, KnownFlights, TravelSpeed
ns.UnitTime, ns.WorldPos = UnitTime, WorldPos
