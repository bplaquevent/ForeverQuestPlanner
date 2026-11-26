-- A pending service cancelled leaves the Roadbook, tracked or not.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local _, ns = H.session(nil, { ["Geo.lua"] = function(ns) ns.GeoReady = function() return true end end })
local Geo, CP = ns.Geo, ns.CP
Geo.ServiceSet({ kind = "vendor", name = "V" })
Geo.CustomList = function() return { { id = 1 } } end
CP.RefuseWhileComputing = function() return false end
CP.ServiceBarSync = function() end
local manual
CP.Replan = function(_, _, m) manual = m return true end
CP.ServiceClick("vendor")
check("cancelled", Geo.ServicePending() == nil)
check("computed again even when not tracked", manual == true)
finish()
