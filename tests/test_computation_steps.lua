-- A computation spread over frames pauses inside a protected call too: Lua 5.1 cannot yield across
-- pcall (Geo.GuardInSteps), so a quest of the list is not left unplanned by a pause.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local broken = false
local env, ns, log = H.session(nil, {
  ["QuestLog.lua"] = function(ns)
    ns.LogById = function() return {} end
    ns.AllPrereqs = function() return {} end
  end,
})
local Geo, State = ns.Geo, ns.State
local clock = 0
env.debugprofilestop = function() clock = clock + 1000 return clock end -- every slice used up

-- Runs fn as the game's computation: returns the number of pauses and what fn returned.
local function compute(fn)
  State.co = coroutine.create(fn)
  local pauses = 0
  while true do
    local out = { coroutine.resume(State.co) }
    if coroutine.status(State.co) == "dead" then
      State.co = nil
      return pauses, unpack(out)
    end
    pauses = pauses + 1
  end
end

Geo.CustomList = function() return { { id = 1, title = "Q" } } end
Geo.ServiceStep = function() return nil end
Geo.AwaitTags = function() end
Geo.GroupDungeons = function() return {} end
Geo.CustomConstraints = function() return {} end
Geo.CustomTask = function(e)
  Geo.Yield() -- as the reading of monster spawns does
  Geo.Yield()
  if broken then error("quest data broke") end
  return { id = e.id, stops = {}, order = {} }
end
local function plan() return Geo.CustomPlanSteps({}, 10) end

local pauses, ok, cp = compute(plan)
check("quest read with pauses: planned", ok and cp and #cp.tasks == 1 and #cp.unplanned == 0)
check("its pauses reach the game", pauses >= 2)

broken = true
local _, ok2, nothing, why, unplanned = compute(plan)
check("a quest in error: unplanned, with the error", ok2 and nothing == nil and unplanned and unplanned[1]
  and unplanned[1].reason:find("quest data broke", 1, true) ~= nil)
check("and told in the chat", table.concat(log.chat, "\n"):find("quest data broke", 1, true) ~= nil)
broken = false

-- nested calls, values through the pauses, and no pause outside a computation
if Geo.GuardInSteps then
  local nested, okN, a, b = compute(function()
    return select(2, Geo.GuardInSteps(function()
      return Geo.GuardInSteps(function(x) Geo.Yield() return x, x + 1 end, 4)
    end))
  end)
  local _, r1, r2, r3 = compute(function()
    return Geo.GuardInSteps(function() local v = Geo.GuardInSteps(function() Geo.Yield() return 7 end) Geo.Yield() return v end)
  end)
  check("nested: pauses passed on", nested == 1 and okN and a == true and b == 4)
  check("nested: results of both", r1 == true and r2 == true and r3 == true)
  local out = { Geo.GuardInSteps(function() Geo.Yield() return 1, nil, 3 end) }
  check("outside a computation: no pause, every result", out[1] == true and out[2] == 1 and out[3] == nil and out[4] == 3)
end
check("nothing left marked", State.relayed == nil)
finish()
