-- A flight node with no QuestieDB flight master near it still has a place on the map.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local _, ns = H.session(nil, {
  ["OpenMapLink.lua"] = function(ns) ns.OM.FlightNodes = function() return { [5] = { c = 0, x = 1, y = 1 } } end end,
})
local Geo = ns.Geo
Geo.ScanServices = function() end
Geo.NodeUsable = function() return true end
Geo.NodePoint = function() return { c = 0, x = 1, y = 1 } end
Geo.NodeName = function() return "Node" end
Geo.MapPoint = function(w) return { c = w.c, x = w.x, y = w.y, ui = 1, mx = 50, my = 50 } end
local fm = Geo.FlightMasters()[1]
check("map position of the node", fm and fm.p.ui == 1 and fm.p.mx == 50)
check("named after the node when the map gives no zone", fm and fm.p.zoneName == "Node")
finish()
