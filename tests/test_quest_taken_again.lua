-- A quest turned in, then taken again (repeatable) and abandoned: the abandon is asked about.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns, log = H.session(nil, { ["Core.lua"] = function(ns)
  ns.IsInLog = function() return false end
  ns.IsCompleted = function() return false end
end })
local Geo, CP = ns.Geo, ns.CP
Geo.Frozen = function() return { route = { { kind = "start" } }, info = {} } end
Geo.InCustom = function() return true end
Geo.CustomList = function() return { { id = 5, title = "Q" } } end
CP.AutoAddAccepted = function() end
CP.GiverFound = function() return false end
CP.ScheduleRecallCheck = function() end
env.C_Timer.After = function(_, fn) fn() end

CP.OnGameEvent("QUEST_TURNED_IN", 5)
CP.OnGameEvent("QUEST_REMOVED", 5)
check("turned in: nothing asked", #log.popups == 0)
CP.OnGameEvent("QUEST_ACCEPTED", 5)
CP.OnGameEvent("QUEST_REMOVED", 5)
check("taken again then abandoned: asked", log.popups[1] == "FQP_QUEST_ABANDONED")
finish()
