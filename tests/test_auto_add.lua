-- Auto mode: the quest accepted during a computation is added once it ends, however long it is.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()
local Geo, CP, State = ns.Geo, ns.CP, ns.State
local added, timers = {}, {}
Geo.CustomAdd = function(id) added[#added + 1] = id end
env.C_Timer.After = function(_, fn) timers[#timers + 1] = fn end
local function tick() local fn = table.remove(timers, 1) if fn then fn() end end

State.computing = true
CP.AutoAddSoon(5, "Q")
for _ = 1, 100 do tick() end
check("computation running: not added yet", #added == 0)
State.computing = nil
tick()
check("added once the computation ends", added[1] == 5 and #added == 1)
finish()
