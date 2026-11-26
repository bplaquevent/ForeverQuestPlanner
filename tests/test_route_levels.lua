-- The levels of the saved Roadbook stay at their steps when steps are removed or inserted.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local pos = { c = 0, x = 0, y = 0 }
local env, ns = H.session(nil, { ["Geo.lua"] = function(ns) ns.PlayerPos = function() return pos end end })
local Geo, CP = ns.Geo, ns.CP
env.date = function() return "12:00" end
env.UnitLevel = function() return 30 end
Geo.RecallState = function() return {} end
Geo.Trace = function() end
Geo.MapSync = function() end
Geo.World = function() return {} end
Geo.Net = function() return {} end
CP.StepLine = function() return "" end
CP.FocusStep = function() end
CP.FocusNext = function() end
CP.Replan = function() return true end

local function step(kind, title, x, extra)
  local s = { kind = kind, p = { c = 0, x = x, y = 0 }, task = { title = title }, work = 1 }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end
local function freeze(route, levels)
  Geo.Freeze(route, { count = 1, xp = 0, total = 0, levels = levels })
end
local function levels() return table.concat(Geo.Frozen().info.levels, ",") end

local a, b = step("travel", "a", 1), step("travel", "b", 2)
local target = step("turnin", "t", 3)
freeze({ { kind = "start", p = pos }, a, b, target, step("fm", "after", 4) }, { 30, 30, 30, 31, 32 })
Geo.LegSteps = function() return { step("travel", "new", 5) } end
CP.Reroute(a, pos, "")
check("rerouted: two legs replaced by one", #Geo.Frozen().route == 4 and levels() == "30,30,31,32")
check("rerouted: saved levels follow", table.concat(ns.Settings().roadbook.info.levels, ",") == "30,30,31,32")

local s1 = step("take", "q", 100, { search = true, task = { id = 7, title = "q" } })
local s2 = step("take", "q", 1, { search = true, task = { id = 7, title = "q" } })
local s3 = step("take", "q", 200, { search = true, task = { id = 7, title = "q" } })
freeze({ { kind = "start", p = pos }, s1, s2, s3, step("fm", "after", 4) }, { 30, 30, 30, 30, 31 })
ns.MarkScanDirty = function() end
CP.GiverFound(7)
check("quest giver found: the places left out take their level with them", #Geo.Frozen().route == 3 and levels() == "30,30,31")
finish()
