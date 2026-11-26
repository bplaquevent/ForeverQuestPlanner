-- The solver (Solver.lua, pure Lua) on small problems made by hand.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()

local function Solver()
  local ns = {}
  assert(loadfile("Solver.lua"))("ForeverQuestPlanner", ns)
  return ns.Solver
end
local S = Solver()

local function pt(x, y) return { c = 0, x = x, y = y or 0 } end
local function step(kind, x, extra)
  local s = { kind = kind, p = pt(x), work = 0 }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end
local function start() return step("start", 0) end

-- A level 30 character at x = 0 walking 10 yards a second, in a world of its own.
local function problem(extra)
  local xpNeeded = {}
  for level = 1, 59 do xpNeeded[level] = 100000 end
  local P = { quests = {}, tasks = {}, world = {},
    player = { level = 30, xp = 0, maxLevel = 60, speed = 10, pos = pt(0), xpNeeded = xpNeeded },
    k = { PATH_FACTOR = 1, PASS_PATH_FACTOR = 1, PASS_MIN = 300, DANGER_MARGIN = 5, DANGER_FACTOR = 3,
      FLIGHT_SPEED = 30, FLIGHT_OVERHEAD = 10, TRANSPORT_TIME = 60, K_HUBS = 4, CROSS_CONTINENT = 3600,
      HEARTH_TIME = 10, HEARTH_MIN_GAIN = 60, BIND_WORK = 30, INN_DETOUR = 300, OVERHEAD = 10 } }
  for k, v in pairs(extra or {}) do P[k] = v end
  P.net0 = S.Network(S.World(P), {}, P.player.speed) -- (as a search prepares it)
  return P
end

-- A custom list: steps given in order (ci = index).
local function list(steps, pred, first)
  for ci, s in ipairs(steps) do s.ci = ci end
  return { steps = steps, pred = pred or {}, tasks = {}, first = first }
end

local function titles(core)
  local out = {}
  for i = 2, #core do out[#out + 1] = core[i].title or core[i].kind end
  return table.concat(out, " ")
end

local function count(route, kind)
  local n = 0
  for _, s in ipairs(route) do
    if s.kind == kind then n = n + 1 end
  end
  return n
end

local function search(P, core, extra)
  local X = { P = P, core = core, score = math.huge, evals = 0, maxEvals = 1000, goal = "custom",
    valid = S.ValidCustom, custom = true }
  for k, v in pairs(extra or {}) do X[k] = v end
  return X
end

-- 1. an addition kept leaves a shorter list of additions
do
  local T = Solver()
  local lists = { { { core = "a" }, { core = "b" }, { core = "c" } }, { { core = "d" } } }
  local made = 0
  T.Additions = function()
    made = made + 1
    return lists[made]
  end
  T.SearchTry = function(_, c) return c == "a" end
  local ok, any = pcall(T.MoveAdd, search(problem(), {}))
  check("shorter list of additions: no error, the addition kept", ok and any == true and made == 2)
end

-- 2. a zone too high crossed between two hubs of the network is as slow as on the direct walk
do
  local P = problem({ world = { zones = { [1] = { min = 25 }, [2] = { min = 45 } },
    docks = { { name = "west", p = pt(100) }, { name = "east", p = pt(2900) } },
    zoneAt = function(p) return (p.x > 1000 and p.x < 2000) and 2 or 1 end } })
  local W = S.World(P)
  local net = S.Network(W, {}, 10)
  local a, b = pt(0), pt(3000)
  -- through the hubs: the 2800 yards between them as dangerous, only the 100 to and from them apart
  check("dangerous walk: no way round it through the hubs", math.abs(S.Route(W, a, b, net, 30) - 860) < 1e-6)
  check("level high enough: the walk at normal speed, same network", math.abs(S.Route(W, a, b, net, 40) - 300) < 1e-6)
  local x, y = S.Paths(W, net, 30), S.Paths(W, net, 31)
  check("paths shared by the levels finding the same walks dangerous", x == y and x ~= S.Paths(W, net, 40))
end

-- 3. the teleports using the same rune share its charges
do
  local function teleports(reagent)
    local P = problem({ world = { recall = {
      { key = 1, p = pt(10000), cast = 10, cd = 0, charges = 1, reagent = reagent },
      { key = 2, p = pt(30000), cast = 10, cd = 0, charges = 1, reagent = reagent } } } })
    local core = { start(), step("travel", 10000), step("travel", 30000) }
    return P, core, S.AddRecalls(P, core, S.Evaluate(P, core))
  end
  local _, _, route = teleports(17031)
  check("one rune: one teleport", count(route, "hearth") == 1)
  local _, _, two = teleports(nil)
  check("no shared reagent: one charge each", count(two, "hearth") == 2)
  local P, core = teleports(17031)
  local res = S.Evaluate(P, { core[1], step("hearth", 10000, { via = 1 }), core[2], step("hearth", 30000, { via = 2 }), core[3] })
  check("second use of the rune: a rule broken", #res.violations == 1 and res.violations[1].what == "no charge left")
end

-- 4. no route with a quest picked up after one that keeps it from being taken
do
  local function quest(n, x)
    return { n = n, id = n, kind = "take", xp = 1000,
      stops = { step("take", x, { id = n, title = "take" .. n }), step("turnin", x + 10, { id = n, title = "turnin" .. n, xp = 1000 }) } }
  end
  local function two(blockers1, blockers2)
    local P = problem({ tasks = { quest(1, 100), quest(2, 200) } })
    P.quests = { [1] = { blockers = blockers1 }, [2] = { blockers = blockers2 } }
    S.PrepareTasks(P)
    return P, P.tasks[1].stops, P.tasks[2].stops
  end
  local P, a, b = two({ 2 }, { 1 })
  check("exclusive quests: invalid together", not S.Valid(P, { start(), a[1], a[2], b[1], b[2] }))
  check("exclusive quests: the second one is not inserted", S.InsertTask(P, { start(), a[1], a[2] }, P.tasks[2]) == nil)
  local res = S.Optimize(P, { kind = "time", value = 7200 }, { maxEvals = 300 })
  check("exclusive quests: one of them in the Roadbook", count(res.route, "take") == 1)
  P, a, b = two({ 2 }, nil) -- quest 2 is the next one of quest 1's chain
  check("next quest of a chain taken first: invalid", not S.Valid(P, { start(), b[1], b[2], a[1], a[2] }))
  check("next quest of a chain taken after: valid", S.Valid(P, { start(), a[1], a[2], b[1], b[2] }))
  local r = S.InsertTask(P, { start(), b[1], b[2] }, P.tasks[1])
  check("inserted before the next quest of its chain", r and S.Valid(P, r))
  P = two({ 2 }, { 1 })
  local mine = { step("take", 1, { id = 1, ci = 1 }), step("take", 2, { id = 2, ci = 2 }) }
  check("two exclusive quests of the list: the player's choice", S.Valid(P, { start(), mine[1], mine[2] }))
  check("a candidate excluded by a quest of the list", not S.Valid(P, { start(), mine[1], P.tasks[2].stops[1] }))
end

-- 4 (game side). QuestieDB's exclusive quests and next quest of the chain reach the solver
do
  local data = { [1] = { exclusiveTo = { 3, 4 }, nextQuestInChain = 2 }, [5] = { nextQuestInChain = 0 } }
  local _, ns = H.session(nil, { ["QuestData.lua"] = function(ns)
    ns.QGet = function(_, id, key) return data[id] and data[id][key] end
  end })
  ns.QDB.Quest, ns.QDB.xp = "quest", {}
  local P = { quests = {} }
  ns.Problem.AddQuest(P, 1, "one")
  ns.Problem.AddQuest(P, 5, "five")
  check("blockers of a quest in the problem", table.concat(P.quests[1].blockers or {}, ",") == "3,4,2")
  check("no blocker: no field", P.quests[5].blockers == nil)
end

-- 3 (game side). the reagent of a teleport reaches the solver
do
  local _, ns = H.session(nil, { ["Route.lua"] = function(ns)
    local Geo = ns.Geo
    Geo.RecallSources = function() return { { key = 1, p = pt(5), cast = 10, cd = 0, ready = 0, charges = 2, reagent = 17031 } } end
    Geo.Innkeepers, Geo.FlightMasters = function() return {} end, function() return {} end
    Geo.CurrentBind = function() return nil end
    Geo.CopyPoint = function(p) return p end
  end, ["Services.lua"] = function(ns)
    ns.Geo.Innkeepers, ns.Geo.FlightMasters = function() return {} end, function() return {} end
  end })
  ns.Problem.Network = function() end
  local P = {}
  ns.Problem.World(P)
  check("reagent of a way back in the problem", P.world.recall[1].reagent == 17031)
end

-- 5. a bind that no longer serves is removed from a list too
do
  local P = problem()
  P.custom = list({ step("take", 100, { title = "a" }) })
  local core = { start(), step("bind", 5000, { work = 30 }), P.custom.steps[1] }
  local X = search(P, core)
  S.LocalSearch(X)
  check("useless bind removed from the list", count(X.core, "bind") == 0 and count(X.core, "take") == 1)
end

-- 6. a quest destroyed takes with it the steps of the list that need it
do
  local P = problem()
  P.custom = list({ step("take", 100, { ti = 1, title = "a" }), step("turnin", 200, { ti = 1, title = "a2" }),
    step("take", 150, { ti = 2, title = "b" }), step("dungeon", 300, { title = "d" }), step("take", 50, { ti = 3, title = "c" }) },
    { [2] = { 1 }, [3] = { 2 }, [4] = { 3 } })
  local core = S.BuildCustom(P, { start() })
  local rest = S.WithoutQuests(P, core, { [1] = true })
  check("quest destroyed with its follow-up and the visit after it", titles(rest) == "c")
  check("rebuilt in an order the rules allow", S.ValidCustom(P, S.BuildCustom(P, rest)))
end

-- 7. rules in a cycle: one is left out, once, the others hold
do
  local P = problem()
  P.custom = list({ step("take", 5000, { title = "a", spots = { { p = pt(6000), work = 1 } }, work = 1 }),
    step("take", 6000, { title = "b" }), step("take", 10, { title = "c" }) },
    { [1] = { 2 }, [2] = { 1 }, [3] = { 1 } })
  local core = S.BuildCustom(P, { start() })
  local a, b, c = unpack(P.custom.steps)
  check("every step placed", #core == 4 and S.ValidCustom(P, core))
  check("a rule outside the cycle holds", not S.ValidCustom(P, { start(), c, a, b }))
  check("one step of the cycle marked", b.relaxed == true and not a.relaxed and not c.relaxed)
  S.Variants(b)
  S.Variants(a)
  check("hunting spot variants keep the rules of their step", not S.ValidCustom(P, { start(), c, a.variants[2], b }))
end

-- 7 (glued steps). what a glued step needs comes before the whole block
do
  local P = problem()
  P.custom = list({ step("take", 100, { title = "escort" }), step("obj", 120, { title = "walk", glueTo = 1 }),
    step("take", 900, { title = "key" }) }, { [2] = { 1, 3 } })
  local core = S.BuildCustom(P, { start() })
  check("glued block after what it needs", titles(core) == "key escort walk" and S.ValidCustom(P, core))
  check("no rule left out", not P.custom.steps[2].relaxed)
end

-- 8. a quest inserted does not come before the service shortcut
do
  local P = problem({ tasks = { { n = 1, id = 1, kind = "take", stops = { step("take", 5, { id = 1 }) } } } })
  P.custom = list({ step("service", 1000) }, {}, 1)
  S.PrepareTasks(P)
  local core = S.InsertTask(P, { start(), P.custom.steps[1] }, P.tasks[1])
  check("quest next to the player inserted after the service", core and core[2].kind == "service" and S.ValidCustom(P, core))
end

-- 9. no monster XP at the maximum level
do
  local P = problem()
  local obj = step("obj", 1, { obj = { kills = 10, mobLevel = 60 } })
  check("monster XP below the maximum level", S.StepXP(P, obj, 59) > 0)
  check("none at the maximum level", S.StepXP(P, obj, 60) == 0 and S.StepXP(P, step("obj", 1, { xp = 50 }), 60) == 0)
end

-- 10. no figure from the formula: the game's XP counts
do
  local P = problem({ quests = { [1] = { qLevel = 38, baseXP = 0, xpNow = 2000 }, [2] = { qLevel = 0, baseXP = 500 } } })
  check("no base XP: the game's figure", S.TurnInXP(P, 1, 30, 10) == 2000)
  check("no quest level and no figure now: the step's", S.TurnInXP(P, 2, 30, 700) == 700)
  check("maximum level: no XP", S.TurnInXP(P, 1, 60, 10) == 0)
end

-- 11. the transport skipped is banned on the first leg travelled, after a teleport too
do
  local P = problem({ world = { docks = { { name = "from", p = pt(0) }, { name = "to", p = pt(20000) } },
    links = { { 1, 2, "ship" } }, recall = { { key = 1, p = pt(0, 5), cast = 10, cd = 0 } } },
    ban = { mode = "ship", from = pt(0), to = pt(20000) } })
  local res = S.Evaluate(P, { start(), step("hearth", 0, { via = 1 }), step("travel", 20000), step("travel", 0), step("travel", 20000) })
  check("ban on the leg after the teleport", res.legs[3].net.key:find("#", 1, true) ~= nil and res.travel[3] > 1000)
  check("teleports compared on that network", res.nets[2] == res.legs[3].net and res.nets[3] == res.legs[3].net)
  check("not on the next legs: the line taken", res.legs[5].net.key:find("#", 1, true) == nil and res.travel[5] < 100)
end

-- 12. a duration with a list: the whole list is put in order before being cut
do
  local T = Solver()
  local P = problem()
  P.custom = list({ step("take", 1000, { ti = 1, id = 1 }), step("take", 2000, { ti = 2, id = 2 }) })
  P.custom.tasks = { { id = 1 }, { id = 2 } }
  local goal = { kind = "time", value = 150 }
  check("too long even in order: cut", T.Optimize(P, goal, { maxEvals = 300 }).mode == "pick")
  local real, ordered = T.LocalSearch, false
  T.LocalSearch = function(X)
    if X.custom then -- the computation of the whole list: it finds a short enough order
      ordered, X.res = true, { time = 100 }
      return 1
    end
    return real(X)
  end
  P.custom.units = nil
  check("short enough once in order: kept whole", T.Optimize(P, goal, { maxEvals = 300 }).mode == "keep" and ordered)
end

finish()
