-- Zone passes: Geo.Passes and the learning of Geo.PassTick.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()
local function vec(x, y) return { x = x, y = y, GetXY = function() return x, y end } end
env.CreateVector2D = vec
-- fake world: map position (0-1) -> world = 100000 * position; continent 1
env.C_Map = { GetWorldPosFromMapPos = function(_, v) return 1, vec(v.x * 100000, v.y * 100000) end }
ns.Geo.ready = true
ns.PASS_PATROLS = {}
-- two source passes between zones 10 and 20, one between 30 and 40
ns.PASSES = { { 10, 1, 1, 20 }, { 10, 5, 5, 20 }, { 40, 20, 20, 30 } }
local function learned(list)
  ns.LearnedData().passes = list
  ns.Geo.PassesChanged()
  return ns.Geo.Passes()
end
local function has(list, p) for _, q in ipairs(list) do if q == p then return true end end return false end

check("no learned pass: the sources", #learned({}) == 3)
local same = { c = 1, x = 1000 + 149, y = 1000, a = 10, b = 20 }
local far = { c = 1, x = 1000 + 151, y = 1000, a = 10, b = 20 }
local otherZones = { c = 1, x = 1000, y = 1000, a = 10, b = 30 }
local otherContinent = { c = 0, x = 1000, y = 1000, a = 10, b = 20 }
local newPair = { c = 1, x = 9000, y = 9000, a = 50, b = 60 }
local list = learned({ same })
check("learned within 150 yards: not added", #list == 3 and not has(list, same))
check("... but kept in the saved data", #ns.Geo.LearnedPasses() == 1)
list = learned({ far })
check("learned farther: added", #list == 4 and has(list, far))
local first = 0
for _, q in ipairs(list) do if q.a == 10 and q.b == 20 then first = first + 1 end end
check("the sources of the same zones are kept", first == 3)
list = learned({ otherZones, otherContinent, newPair })
check("other zones, other continent, new pair: added", #list == 6)
list = learned({ far, { c = 1, x = far.x + 50, y = far.y, a = 10, b = 20 } })
check("two learned passes that are the same: once", #list == 4)

-- learning: walks across a border, positions faked
local now, zone, x = 0, 10, 0
env.GetTime = function() return now end
env.GetUnitSpeed = function() return 7 end
env.IsInInstance = function() return false end
env.UnitOnTaxi = function() return false end
env.C_Map.GetBestMapForUnit = function() return 1 end
env.C_Map.GetPlayerMapPosition = function() return vec(x / 100000, 0.5) end
ns.Geo.ZoneIdRaw = function() return zone, "Zone " .. zone end
local function walk(at)
  ns.Geo.passLast = nil
  zone, x = 10, at - 5; now = now + 100; ns.Geo.PassTick()
  zone, x = 20, at + 5; now = now + 2; ns.Geo.PassTick()
end
learned({})
walk(3000)
check("walk: learned", #ns.Geo.LearnedPasses() == 1 and ns.Geo.LearnedPasses()[1].a == 10 and ns.Geo.LearnedPasses()[1].b == 20
  and ns.Geo.LearnedPasses()[1].x == 3000 and ns.Geo.LearnedPasses()[1].n == 1)
check("walk: list updated", #ns.Geo.Passes() == 4)
walk(3100)
check("walk again within 150 yards: counted, not doubled", #ns.Geo.LearnedPasses() == 1 and ns.Geo.LearnedPasses()[1].n == 2)
walk(3400)
check("walk farther: another pass", #ns.Geo.LearnedPasses() == 2 and #ns.Geo.Passes() == 5)
finish()
