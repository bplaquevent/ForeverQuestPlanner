-- Forever Quest Planner: the only file that knows OpenMap, the shape of its data and which of its
-- functions are called. The rest of the addon uses ns.OM.
-- Only the part marked "public API" is OpenMapAPI, OpenMap's documented API. Its data tables, its
-- worldmap module and its pin sets (MapStitch) are its own: Init checks them, so that a change of
-- their shape is reported at login instead of failing later.
-- The data are given with named fields, read once; OpenMap's functions are called, never replaced.

local ADDON_NAME, ns = ...
local L = ns.L

local OM = {}
local raw -- OpenMap's tables, once checked
local read = {} -- its data, converted

-- Returns nil, or an error message.
function OM.Init()
  local om = rawget(_G, "OpenMap")
  if type(om) ~= "table" then return L["OpenMap is not loaded."] end
  local fl, pl, lv = om.MapFlights, om.MapPlaces, om.MapLevels
  local okM, wm = pcall(function() return om:GetModule("worldmap") end)
  local function bad(what) return L["OpenMap version not supported (data changed: "] .. what .. ")." end
  if not (type(fl) == "table" and type(fl.nodes) == "table" and type(fl.paths) == "table") then return bad("MapFlights") end
  local _, n = next(fl.nodes)
  if not (type(n) == "table" and type(n[2]) == "number" and type(n[3]) == "number" and type(n[5]) == "number") then return bad("MapFlights.nodes") end
  local e = fl.paths[1]
  if not (type(e) == "table" and type(e[1]) == "number" and type(e[2]) == "number" and type(e[3]) == "number") then return bad("MapFlights.paths") end
  if not (type(pl) == "table" and type(pl.transports) == "table" and type(pl.instances) == "table") then return bad("MapPlaces") end
  local t = pl.transports[1]
  if not (type(t) == "table" and type(t[1]) == "string" and type(t[2]) == "string" and type(t[4]) == "number") then return bad("MapPlaces.transports") end
  local i = pl.instances[1]
  if not (type(i) == "table" and type(i[4]) == "table" and type(i[4][1]) == "table") then return bad("MapPlaces.instances") end
  if type(lv) ~= "table" then return bad("MapLevels") end
  if not (okM and type(wm) == "table" and type(wm.LevelColor) == "function") then return bad("worldmap") end
  -- Map pins and drawing (RoadbookMap.lua): its waypoint and the switch hiding the player's pins
  -- (worldmap module), its stitched map's pin sets and lines (MapStitch), its public API (OpenMapAPI).
  for _, name in ipairs({ "TrackPoint", "ClearPin", "WaypointPoint", "RefreshWaypoint", "PinsHidden", "SetPinsHidden" }) do
    if type(wm[name]) ~= "function" then return bad("worldmap." .. name) end
  end
  local S, api = om.MapStitch, rawget(_G, "OpenMapAPI")
  if type(S) ~= "table" then return bad("MapStitch") end
  for _, name in ipairs({ "PinSet", "AddPin", "AddLine", "AddPath", "ClearPinSet", "FromYards", "IsBuilt" }) do
    if type(S[name]) ~= "function" then return bad("MapStitch." .. name) end
  end
  if not (type(api) == "table" and api.major == 1 and (api.version or 0) >= 2) then return bad("OpenMapAPI") end
  raw = { flights = fl, places = pl, levels = lv, worldmap = wm, stitch = S, api = api }
  read = {}
end

---------------------------------------------------------------------------
-- Data. World points: c = continent, x, y in yards.
---------------------------------------------------------------------------
-- Flight nodes: id -> { name (English), c, x, y, faction (bits: 1 Alliance, 2 Horde), class (the only
-- one flying it, or nil) }.
function OM.FlightNodes()
  if not read.nodes then
    read.nodes = {}
    for id, n in pairs(raw.flights.nodes) do
      read.nodes[id] = { name = n[1], c = n[2], x = n[3], y = n[4], faction = n[5], class = n[6] }
    end
  end
  return read.nodes
end

-- Direct flights: { from, to (node ids), length (yards) }.
function OM.FlightPaths()
  if not read.paths then
    read.paths = {}
    for _, e in ipairs(raw.flights.paths) do
      read.paths[#read.paths + 1] = { from = e[1], to = e[2], length = e[3] }
    end
  end
  return read.paths
end

-- Boat, zeppelin and airship lines, one way each: { kind, route (name), from, to (world points),
-- faction ("Alliance", "Horde", "Neutral", or nil when OpenMap does not say) }.
function OM.Transports()
  if not read.transports then
    read.transports = {}
    for _, t in ipairs(raw.places.transports) do
      read.transports[#read.transports + 1] = { kind = t[1], route = t[2], from = { c = t[3], x = t[4], y = t[5] },
        to = { c = t[6], x = t[7], y = t[8] }, faction = t.faction }
    end
  end
  return read.transports
end

-- Instance entrances: a world point (c, x, y), or a spot on a zone's map (map, u, v: 0..1), with the
-- level range of its instances (minLevel, maxLevel).
function OM.Instances()
  if not read.instances then
    read.instances = {}
    for _, e in ipairs(raw.places.instances) do
      local lo, hi
      for _, w in ipairs(e[4]) do
        if w[4] and (not lo or w[4] < lo) then lo = w[4] end
        if w[5] and (not hi or w[5] > hi) then hi = w[5] end
      end
      local out = { minLevel = lo, maxLevel = hi }
      if e[1] then
        out.c, out.x, out.y = e[1], e[2], e[3]
      else
        out.map, out.u, out.v = e.map, e[2], e[3]
      end
      read.instances[#read.instances + 1] = out
    end
  end
  return read.instances
end

-- Level ranges of the zones: uiMapID -> { min, max } (the zones with a range only).
function OM.ZoneLevels()
  if not read.levels then
    read.levels = {}
    for ui, lv in pairs(raw.levels) do
      if lv[1] then read.levels[ui] = { min = lv[1], max = lv[2] } end
    end
  end
  return read.levels
end

-- Flight paths the character has learned, as OpenMap records them: node name -> true (its own table).
function OM.LearnedFlights()
  local char = raw.worldmap.char
  return type(char) == "table" and type(char.flightsKnown) == "table" and char.flightsKnown or {}
end

-- Colour code of a level range for the character, and the range as text.
function OM.LevelColor(lo, hi)
  return raw.worldmap.LevelColor(lo, hi)
end

---------------------------------------------------------------------------
-- Worldmap module: its waypoint, the player's own pins
---------------------------------------------------------------------------
function OM.WaypointPoint() return raw.worldmap.WaypointPoint() end
function OM.TrackPoint(ui, x, y, title) return raw.worldmap.TrackPoint(ui, x, y, title) end
function OM.ClearPin() return raw.worldmap.ClearPin() end
function OM.RefreshWaypoint() return raw.worldmap.RefreshWaypoint() end
function OM.PinsHidden() return raw.worldmap.PinsHidden() end
function OM.SetPinsHidden(hidden) return raw.worldmap.SetPinsHidden(hidden) end

---------------------------------------------------------------------------
-- Public API (OpenMapAPI). u, v: a point of its stitched world, 0..1.
---------------------------------------------------------------------------
function OM.IsStitched() return raw.api.IsStitched() end
function OM.WorldFromMap(ui, x, y) return raw.api.WorldFromMap(ui, x, y) end
function OM.GetView() return raw.api.GetView() end
function OM.ShowWorld(u, v, zoom) return raw.api.ShowWorld(u, v, zoom) end
function OM.OnStitchedChanged(owner, fn) raw.api.RegisterCallback(owner, "OpenMap_StitchedChanged", fn) end
function OM.AddMenuToggle(owner, spec) raw.api.RegisterMenuToggle(owner, spec) end

---------------------------------------------------------------------------
-- Drawing on the stitched map (MapStitch): pin sets of the addon's own
---------------------------------------------------------------------------
function OM.MapBuilt() return raw.stitch.IsBuilt() end
function OM.FromYards(c, x, y) return raw.stitch.FromYards(c, x, y) end
function OM.PinSet(key, level) return raw.stitch.PinSet(key, 0, level) end -- shown at every zoom
function OM.ClearPinSet(set) return raw.stitch.ClearPinSet(set) end
-- A pin (a button): it keeps data in pin.data.
function OM.AddPin(set, u, v, look, data) return raw.stitch.AddPin(set, u, v, look, data) end
function OM.OnPinClick(pin, fn) pin.OnClick = fn end -- fn(pin)
function OM.AddLine(set, u1, v1, u2, v2, thickness, ...) return raw.stitch.AddLine(set, u1, v1, u2, v2, thickness, ...) end
function OM.AddPath(set, points, thickness, ...) return raw.stitch.AddPath(set, points, thickness, ...) end

-- Shared with the next files.
ns.OM = OM
