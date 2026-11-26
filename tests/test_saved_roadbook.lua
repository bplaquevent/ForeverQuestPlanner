-- The Roadbook saved: the three ways a plan becomes it, and the private caches.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()
local Geo, CP = ns.Geo, ns.CP
env.date = function() return "12:00" end
env.UnitLevel = function() return 30 end
local calls = {}
local realFreeze = Geo.Freeze
Geo.MapSync = function() calls[#calls + 1] = "map" end
Geo.RecallState = function() return {} end
Geo.Trace = function() end
local function route(n)
  local r = { { kind = "start", p = { c = 0, x = 0, y = 0 } } }
  for i = 1, n do r[#r + 1] = { kind = "fm", p = { c = 0, x = i, y = i }, task = { title = "s" .. i }, work = 1 } end
  return r
end
local info = { count = 1, xp = 0, total = 0, levels = { 30 } }

Geo.Freeze(route(2), info)
check("saving alone: no redraw", #calls == 0)
check("saving: the plan is read back", Geo.Frozen() and #Geo.Frozen().route == 3 and #ns.Settings().roadbook.steps == 2)

Geo.Freeze = function(r, i) calls[#calls + 1] = "save" realFreeze(r, i) end
calls = {}
local r3 = route(3)
Geo.AdoptPlan(r3, info)
check("adopting: saved then redrawn, once", table.concat(calls, ",") == "save,map" and Geo.Frozen().route == r3)

calls = {}
CP.StepDone = function() return true end
Geo.KeepDone = function(fz) return fz.route end
check("only the steps done kept: saved then redrawn", Geo.KeepOnlyDone() == true and table.concat(calls, ",") == "save,map")
calls = {}
Geo.KeepDone = function(fz) return { fz.route[1] } end
check("no step done: nothing saved", Geo.KeepOnlyDone() == false and #calls == 0)

calls = {}
Geo.ListFromRoute = function() return {} end
Geo.CustomList = function() return {} end
Geo.CustomSetList = function() end
Geo.SyncQuestLogButton = function() end
local done, r4 = nil, route(4)
Geo.AcceptGenerated(r4, info, function(ok) done = ok end)
check("generated list accepted: saved then redrawn", done == true and table.concat(calls, ",") == "save,map" and Geo.Frozen().route == r4)

Geo.ClearFrozen()
check("emptied: no plan left", Geo.Frozen() == nil and ns.Settings().roadbook == nil)

-- teleport destinations: read once, read again once forgotten
local arrivals = ns.LearnedData().teleportArrivals
local e = { spell = 556, area = 1, x = 0, y = 0 }
local first, second = { c = 0, x = 1, y = 1 }, { c = 0, x = 2, y = 2 }
arrivals[556] = first
local a = Geo.TeleportDest(e)
arrivals[556] = second
local b = Geo.TeleportDest(e)
Geo.ForgetTeleportDests()
check("teleport destination cached then forgotten", a == first and b == first and Geo.TeleportDest(e) == second)
check("reward index not built yet", Geo.RewardsReady() == false)
finish()
