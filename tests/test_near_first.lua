-- Steps on the spot first and the order of a quest's objectives: an objective kept at its place among
-- them (talking, an event, a place to reach...) does not come before the ones planned ahead of it.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()

local here = { c = 0, x = 0, y = 0 }
local files = H.files()
local hooks = {}
for i, f in ipairs(files) do
  if f == "Roadbook.lua" then
    hooks[files[i - 1]] = function(ns)
      ns.PlayerPos = function() return here end
      ns.AllPrereqs = function() return {} end
    end
  end
end
local env, ns = H.session(nil, hooks)
local Geo, CP = ns.Geo, ns.CP
env.UnitLevel = function() return 30 end
Geo.ZoneIdAt = function() return nil end
CP.StepLine = function() return "" end
CP.StepDone = function() return false end
CP.Busy = function() return false end
Geo.Tracking = function() return true end
Geo.ServicePending = function() return nil end

-- A quest to do: its objectives in their planned order ({ kind, distance from the player }), then its
-- turn-in, far away.
local function quest(...)
  local task = { id = 1, title = "Q", kind = "do", stops = {}, pres = {} }
  for i, o in ipairs({ ... }) do
    task.stops[i] = { kind = "obj", task = task, p = { c = 0, x = o[2], y = 0 }, work = 1,
      r = { count = 1, tg = { kind = o[1], name = "target" .. i } } }
  end
  task.stops[#task.stops + 1] = { kind = "turnin", task = task, p = { c = 0, x = 5000, y = 0 }, work = 1 }
  task.order = task.stops
  local steps = {}
  for i, s in ipairs(task.stops) do steps[i] = s end
  return task, steps
end

local function after(pred, b, a)
  local n = 0
  for _, p in ipairs(pred[b] or {}) do if p == a then n = n + 1 end end
  return n
end

local function nearFirst(task, steps, ...)
  local pred = Geo.CustomConstraints({ task })
  local keys = {}
  for _, s in ipairs({ ... }) do keys[Geo.StepKey(s)] = true end
  return Geo.ApplyNearFirst({ task }, steps, pred, { keys = keys }), pred
end

-- the objective to talk, planned after the monsters
do
  local task, steps = quest({ "kill", 3000 }, { "talk", 20 })
  local kill, talk = steps[1], steps[2]
  check("an objective kept at its place: after the one before it", after(Geo.CustomConstraints({ task }), talk, kill) == 1)
  local n, pred = nearFirst(task, steps, talk)
  check("nearby alone: not brought first", n == 0 and after(pred, kill, talk) == 0)
  n = nearFirst(task, steps, kill, talk)
  check("with the one before it nearby: both first", n == 2)
end

-- monsters, items and objects: in any order
do
  local task, steps = quest({ "kill", 3000 }, { "object", 20 })
  local pred = Geo.CustomConstraints({ task })
  check("free objectives: no order between them", after(pred, steps[2], steps[1]) == 0)
  check("free objective nearby: brought first", nearFirst(task, steps, steps[2]) == 1)
end

-- the saved Roadbook, read again as after a reload
local function replans(...)
  local task, steps = quest(...)
  local route, levels, tasks = { { kind = "start", p = here } }, { 30 }, {}
  for _, s in ipairs(steps) do
    route[#route + 1] = Geo.DeserializeStep(Geo.SerializeStep(s), tasks)
    levels[#levels + 1] = 30
  end
  Geo.Frozen = function() return { route = route } end
  local asked = 0
  CP.nearSeen = {}
  CP.Replan = function() asked = asked + 1 return true end
  CP.NearbyCheck()
  return asked
end
check("saved Roadbook: the objective to talk waits, nothing computed", replans({ "kill", 3000 }, { "talk", 20 }) == 0)
check("saved Roadbook: a free objective nearby: computed", replans({ "kill", 3000 }, { "object", 20 }) == 1)

-- the solver gets each of these rules once
do
  local task, steps = quest({ "kill", 3000 }, { "talk", 20 })
  local P = { quests = { [1] = {} } }
  ns.Problem.Custom(P, { tasks = { task }, steps = steps, pred = Geo.CustomConstraints({ task }), unplanned = {} })
  check("the solver's rules: the monsters before the talk, once", after(P.custom.pred, 2, 1) == 1)
end

finish()
