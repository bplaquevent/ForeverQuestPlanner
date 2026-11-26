-- What ends the followed step: only the event of that step, at its place.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local pos
local env, ns, log = H.session(nil, { ["Geo.lua"] = function(ns) ns.PlayerPos = function() return pos end end })
local Geo, CP = ns.Geo, ns.CP
local done, tookOff, recorded, restamped, rechecked, followed, stepDone
CP.AutoUpdate = function(reason) done[#done + 1] = reason end
CP.TakeOff = function() tookOff = tookOff + 1 end
CP.IsStepFocused = function(s) return s == followed end
CP.StepDone = function() return stepDone end
CP.ScheduleRecallCheck = function() rechecked = rechecked + 1 end
Geo.RecordBind = function(p) recorded = p end
Geo.RestampRecalls = function() restamped = restamped + 1 end
env.C_Timer.After = function(_, fn) fn() end

local function follow(s)
  done, tookOff, recorded, restamped, rechecked, stepDone = {}, 0, nil, 0, 0, false
  followed, CP.focused = s, s
end
local inn = { c = 0, x = 0, y = 0 }
local bind = { kind = "bind", p = inn, task = {} }

follow(bind)
pos = { c = 0, x = 3, y = 4 }
log.fire("HEARTHSTONE_BOUND")
check("bound at the planned inn: its place kept, step done", recorded == inn and #done == 1 and restamped == 1 and rechecked == 0)

follow(bind)
pos = { c = 0, x = 2000, y = 0 }
log.fire("HEARTHSTONE_BOUND")
check("bound at another inn: the player's place is kept", recorded == pos)
check("bound at another inn: step not done, route adapted", #done == 0 and restamped == 0 and rechecked == 1)

follow({ kind = "travel", p = inn, task = { mode = "zeppelin", destP = { c = 1, x = 0, y = 0 } } })
CP.OnGameEvent("FQP_TAXI_TAKEOFF")
check("flight taken during a zeppelin step: step kept", tookOff == 0 and #done == 0)
follow({ kind = "travel", p = inn, task = { mode = "flight" } })
CP.OnGameEvent("FQP_TAXI_TAKEOFF")
check("flight taken during a flight step", tookOff == 1)

local fm = { kind = "fm", p = inn, task = {} }
follow(fm)
pos = { c = 0, x = 2000, y = 0 }
CP.OnGameEvent("TAXIMAP_OPENED")
check("another flight master's map: step kept", #done == 0)
pos = { c = 0, x = 3, y = 4 }
CP.OnGameEvent("TAXIMAP_OPENED")
check("the planned flight master's map: step done", #done == 1)
follow(fm)
stepDone, pos = true, nil
CP.OnGameEvent("TAXIMAP_OPENED")
check("flight path already known: step done", #done == 1)
finish()
