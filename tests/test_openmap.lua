-- What the addon takes from OpenMap and asks of it, with OpenMap's data and functions faked in
-- OpenMap's own shapes. The result is compared with tests/openmap_expected.txt, recorded before the
-- accesses were gathered in OpenMapLink.lua. To record it again after a wanted change:
-- lua5.1 tests/test_openmap.lua record
local H = dofile("tests/harness.lua")
local check, finish = H.checker()

local out, calls = {}, {}
local function note(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  calls[#calls + 1] = table.concat(parts, " ")
end
local function dump(v)
  if type(v) ~= "table" then return type(v) == "number" and string.format("%.6g", v) or tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    if type(v[k]) ~= "function" then parts[#parts + 1] = tostring(k) .. "=" .. dump(v[k]) end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function section(name, value) out[#out + 1] = name .. ": " .. dump(value) end
local function flush(name)
  section(name, calls)
  calls = {}
end

-- OpenMap, in its own shapes
local nodes = {
  [1] = { "Orgrimmar, Durotar", 1, 100, 200, 2 },
  [2] = { "Crossroads, The Barrens", 1, 5000, 200, 2 },
  [3] = { "Stormwind, Elwynn", 0, 5, 5, 1 },
  [4] = { "Nighthaven, Moonglade", 1, 50, 9000, 3, "DRUID" },
}
local paths = { { 1, 2, 300 }, { 2, 1, 310 }, { 1, 3, 50 }, { 1, 4, 10 } }
local transports = {
  { "zeppelin", "Grom'gol - Orgrimmar", 1, 110, 210, 0, 500, 500 },
  { "boat", "Booty Bay - Ratchet", 1, 20000, 2000, 0, 30000, 3000 },
  { "boat", "Alliance boat", 1, 40000, 2000, 0, 50000, 3000 },
  { "tram", "Deeprun", 0, 1, 1, 0, 2, 2 },
}
local instances = {
  { 1, 700, 700, { { 33, "Wing A", false, 20, 30 }, { 33, "Wing B", false, 25, 40 } } },
  { nil, 0.5, 0.25, { { 40, "Raid", true, 60, 60 } }, map = 1416 },
}
local levels = { [10] = { 5, 10 }, [20] = {}, [30] = { 12, 12 } }
local flightsKnown = { ["Orgrimmar, Durotar"] = true, ["Stormwind, Elwynn"] = true }
local waypoint, hidden, stitched = { 14, 0.1, 0.2 }, false, true
local worldmap = {
  char = { flightsKnown = flightsKnown },
  LevelColor = function(lo, hi) return "|cffaabbcc", lo == hi and tostring(hi) or (lo .. "-" .. hi) end,
  WaypointPoint = function() if waypoint then return waypoint[1], waypoint[2], waypoint[3] end end,
  TrackPoint = function(ui, x, y, title) note("TrackPoint", ui, x, y, title) waypoint = { ui, x, y } end,
  ClearPin = function() note("ClearPin") waypoint = nil end,
  RefreshWaypoint = function() note("RefreshWaypoint") end,
  PinsHidden = function() return hidden end,
  SetPinsHidden = function(v) note("SetPinsHidden", v) hidden = v end,
}
local function frame()
  local pin = {}
  pin.SetScript = function(self, what, fn) self[what] = fn end
  pin.CreateFontString = function()
    return { SetPoint = function() end, SetText = function(_, t) note("number", t) end, SetTextColor = function() end }
  end
  return pin
end
local pins = {}
local stitch = {
  IsBuilt = function() return true end,
  PinSet = function(key, minZoom, level) note("PinSet", key, minZoom, level) return { key = key } end,
  ClearPinSet = function(set) note("ClearPinSet", set.key) end,
  AddPin = function(set, u, v, look, data)
    note("AddPin", set.key, string.format("%.4f %.4f", u, v), look.size, data.kind)
    local p = frame()
    p.data = data
    pins[#pins + 1] = p
    return p
  end,
  AddLine = function(set, u1, v1, u2, v2, w) note("AddLine", set.key, string.format("%.4f %.4f %.4f %.4f", u1, v1, u2, v2), w) end,
  AddPath = function(set, pts, w) note("AddPath", set.key, table.concat(pts, " "), w) end,
  FromYards = function(c, x, y) return x / 10000 + c, y / 10000 end,
}
local api = {
  major = 1, version = 4,
  IsStitched = function() return stitched end,
  ShowWorld = function(u, v, zoom) note("ShowWorld", u, v, zoom) end,
  GetView = function() return 0.1, 0.1, 12 end,
  WorldFromMap = function(ui, x, y) if ui == 14 then return x, y end end,
  RegisterCallback = function(owner, event) note("RegisterCallback", owner, event) end,
  RegisterMenuToggle = function(owner, spec) note("RegisterMenuToggle", owner, spec.id, spec.section) end,
}
local openMap = { MapFlights = { nodes = nodes, paths = paths }, MapPlaces = { transports = transports, instances = instances },
  MapLevels = levels, MapStitch = stitch, GetModule = function() return worldmap end }
local questie = {
  RequireContract = function() return true end,
  Quest = { Get = function() end }, Npc = { Get = function() end }, Object = { Get = function() end }, Item = { Get = function() end },
  Support = { Get = function(name) return name == "QuestXP" and { db = {} } or { private = { dungeons = {} } } end },
  Enum = { raceMaskById = {} },
}

local initDeps
local env, ns = H.session(nil, { ["QuestData.lua"] = function(ns) initDeps = ns.InitDeps end })
env._G, env.OpenMap, env.OpenMapAPI, env.LibQuestieDB = env, openMap, api, questie
local failure = initDeps()
check("dependencies accepted: " .. tostring(failure), failure == nil)
env.UnitFactionGroup = function() return "Horde" end
env.UnitClass = function() return "Chaman", "SHAMAN" end
env.UnitLevel = function() return 30 end
env.CreateVector2D = function(x, y) return { x = x, y = y, GetXY = function() return x, y end } end
env.C_TaxiMap = { GetTaxiNodesForMap = function(map)
  return map == 1414 and { { nodeID = 2, name = "La Croisée, Les Tarides" } } or {}
end }
env.C_Map = {
  GetWorldPosFromMapPos = function(_, v) return 1, env.CreateVector2D(v.x * 1000, v.y * 1000) end,
  GetMapPosFromWorldPos = function() return nil end,
  GetMapInfo = function(ui) return { name = "Map " .. ui, mapID = ui, mapType = 3 } end,
}
local Geo, CP = ns.Geo, ns.CP
Geo.ready, Geo.areaToUi = true, { [100] = 30 }
ns.PASSES, ns.PASS_PATROLS = {}, {}
Geo.PassesChanged()

section("instances", Geo.Instances())
local usable = {}
for id = 1, 5 do usable[id] = Geo.NodeUsable(id) end
section("usable nodes", usable)
section("node points", { Geo.NodePoint(1), Geo.NodePoint(5) })
section("node names", { Geo.NodeName(1), Geo.NodeName(2), Geo.NodeName(5), Geo.TaxiNames().byName })
local known, count = Geo.KnownNodes()
section("known nodes", { known, count })
section("node at", { Geo.NodeAt({ c = 1, x = 101, y = 201 }), Geo.NodeAt({ c = 0, x = 101, y = 201 }) })
local lines = {}
for _, t in ipairs(Geo.Transports()) do lines[#lines + 1] = { t.faction } end
section("transport factions", lines)
section("docks", Geo.Docks())
section("level texts", { Geo.LevelRange(3, 4), Geo.ZoneLevelText(10), Geo.ZoneLevelText(20) or "none",
  Geo.PlaceLevelText("Map 30") or "none", Geo.PlaceLevelText("Map 20") or "none" })
local world = Geo.World()
section("world", { nodes = world.nodes, edges = world.edges, docks = world.docks, links = world.links,
  zone = world.zones[10], bare = world.zones[20] })

-- the map: a Roadbook previewed, then given back
local route = {
  { kind = "start", p = { c = 1, x = 0, y = 0 } },
  { kind = "take", p = { c = 1, x = 1000, y = 2000 }, task = { id = 1, title = "A" } },
  { kind = "travel", p = { c = 1, x = 3000, y = 4000 }, task = { mode = "flight", destP = { c = 0, x = 100, y = 100 } } },
  { kind = "hearth", p = { c = 0, x = 6000, y = 100 }, task = { title = "home" } },
  { kind = "obj", p = { c = 0, ui = 14, mx = 50, my = 60 }, task = { id = 1, title = "A" } },
}
Geo.Frozen = function() return { route = route, info = {} } end
CP.StepDone = function() return false end
Geo.MapPanelSync = function() note("panel") end
Geo.WalkWay = function() return 1, { { c = 1, x = 5, y = 6 } } end
ns.PlayerPos = function() return { c = 1, x = 10, y = 20 } end
env.WorldMapFrame = { IsShown = function() return true end, HookScript = function() end }
env.GameTooltip = { SetOwner = function() end, AddLine = function(_, t) note("tooltip", t) end, Show = function() note("tooltip shown") end, Hide = function() end }
calls = {}
Geo.MapInit()
flush("map at login")
Geo.MapClaim("preview")
flush("map taken")
check("pins drawn", #pins > 0)
CP.StepSummary = function(st) return "Step " .. st.kind end
Geo.StepDetailLines = function() return { "detail" } end
pins[1].OnEnter(pins[1])
flush("pin hovered")
Geo.ClickStep = function(st) note("clicked", st.kind) end
pins[1].OnClick(pins[1])
flush("pin clicked")
Geo.MapRelease()
flush("map given back")
stitched = false
Geo.mapStitchWarned = true
Geo.MapClaim("preview")
flush("map taken, OpenMap's map off")
Geo.MapRelease()
calls = {}
stitched = true

-- the addon's own pin
Geo.OpenWorldMap = function() end
Geo.PlaceQuestPin = Geo.PlaceQuestPin
section("waypoint there", { Geo.WaypointAt(14, 0.1, 0.2), Geo.WaypointAt(14, 0.5, 0.2) })

local result = table.concat(out, "\n") .. "\n"
if arg[1] == "record" then
  assert(io.open("tests/openmap_expected.txt", "w")):write(result)
  print("recorded")
else
  local f = assert(io.open("tests/openmap_expected.txt"))
  local expected = f:read("*a")
  f:close()
  local i, same = 0, true
  local got = {}
  for line in result:gmatch("[^\n]*\n") do got[#got + 1] = line end
  for line in expected:gmatch("[^\n]*\n") do
    i = i + 1
    local name = line:match("^(.-): ") or tostring(i)
    check(name, got[i] == line)
    if got[i] ~= line and same then
      same = false
      print("  expected " .. line:sub(1, 400) .. "  got      " .. tostring(got[i]):sub(1, 400))
    end
  end
  check("same number of sections", #got == i)
end
finish()
