-- Following and adapting the Roadbook: automatic updates, places found empty, steps on the spot,
-- failed computations, ways back, questions, reload.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()

-- A session whose timers wait for tick(), with the places and prerequisites given by the test.
local function session()
  local data, prereqs, pos, waitScan = {}, {}, { c = 0, x = 0, y = 0 }, { fn = function() return false end }
  local hooks = {}
  local files = H.files()
  local function before(file, fn)
    for i, f in ipairs(files) do
      if f == file then hooks[files[i - 1]] = fn end
    end
  end
  before("Geo.lua", function(ns)
    ns.QGet = function(_, id, key) return data[id] and data[id][key] end
    ns.IsInLog, ns.IsCompleted = function() return false end, function() return false end
  end)
  before("Roadbook.lua", function(ns)
    ns.PlayerPos = function() return pos end
    ns.AllPrereqs = function(id) return prereqs[id] or {} end
    ns.WaitScan = function(...) return waitScan.fn(...) end
    ns.GeoReady = function() return true end
    ns.Snapshot = function() end
  end)
  before("Custom.lua", function(ns)
    ns.QuestPrereqs = function(id) local d = data[id] or {} return d.group or {}, d.single or {} end
  end)
  local env, ns, log = H.session(nil, hooks)
  local timers = {}
  env.C_Timer.After = function(_, fn) timers[#timers + 1] = fn end
  env.StaticPopup_Show = function(which, text, _, d)
    log.popups[#log.popups + 1] = { which = which, text = text, data = d }
    return {}
  end
  env.date = function() return "12:00" end
  env.UnitLevel = function() return 30 end
  local Geo, CP = ns.Geo, ns.CP
  Geo.RecallState = function() return {} end
  Geo.Trace = function() end
  Geo.MapSync = function() end
  Geo.SyncQuestLogButton = function() end
  Geo.ZoneIdAt = function() return nil end
  CP.StepLine = function() return "" end
  CP.RefreshButton = function() end
  return { env = env, ns = ns, Geo = Geo, CP = CP, State = ns.State, log = log, data = data, prereqs = prereqs,
    waitScan = waitScan, pos = pos,
    tick = function()
      local due = timers
      timers = {}
      for _, fn in ipairs(due) do fn() end
    end }
end

local function step(kind, id, x, extra)
  local s = { kind = kind, p = { c = 0, x = x, y = 0 }, task = { id = id, title = "q" .. tostring(id) }, work = 1 }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

local function freeze(Geo, ...)
  local route, levels = { { kind = "start", p = { c = 0, x = 0, y = 0 } } }, { 30 }
  for _, s in ipairs({ ... }) do
    route[#route + 1] = s
    levels[#levels + 1] = 30
  end
  Geo.Freeze(route, { count = 1, xp = 0, total = 0, levels = levels, custom = true })
  return route
end

-- 1. an automatic update marks the step followed when it was asked
do
  local t = session()
  local CP, Geo = t.CP, t.Geo
  local followed, marked = nil, {}
  CP.CurrentFocus = function() return followed end
  Geo.MarkDone = function(s) marked[#marked + 1] = s end
  CP.FocusNext = function() end
  local a, b = step("turnin", 1, 0), step("take", 2, 0)
  followed = a
  CP.AutoUpdate("done")
  followed = b -- a computation ended meanwhile: the focus moved on
  t.tick()
  check("another step followed a second later: not marked", #marked == 0)
  followed = a
  CP.AutoUpdate("done")
  local again = step("turnin", 1, 0)
  followed = again
  t.tick()
  check("the same step in the new plan: marked", #marked == 1 and marked[1] == again)
end

-- 2. a place found empty is not proposed again
do
  local t = session()
  local Geo, CP = t.Geo, t.CP
  local places = { { c = 0, x = 0, y = 0 }, { c = 0, x = 1000, y = 0 }, { c = 0, x = 2000, y = 0 } }
  t.data[7] = { startedBy = { { 40 }, {}, {} } }
  Geo.startPlaces = { [7] = places }
  Geo.MarkDone = function() end
  CP.FocusNext = function() end
  CP.SkipStep(step("take", 7, 1000, { search = { i = 2, n = 3 } })) -- "Not here"
  local left = Geo.StartPlaces(7, t.pos)
  check("place found empty left out", left and #left == 2 and left[1].x == 0 and left[2].x == 2000)
  check("saved for after a reload", t.ns.Settings().dismissedPlaces[7][1].x == 1000)
  Geo.DismissPlace(7, places[1])
  Geo.DismissPlace(7, places[3])
  check("every place found empty: all to check again", #Geo.StartPlaces(7, t.pos) == 3)
  Geo.DismissPlace(7, places[1])
  CP.GiverFound = function() return true end
  t.log.fire("QUEST_ACCEPTED", 7)
  check("quest picked up: forgotten", #Geo.StartPlaces(7, t.pos) == 3)
  Geo.DismissPlace(7, places[1])
  t.ns.Settings().custom = { list = { { id = 7 } } }
  Geo.CustomRemove(7, true)
  check("quest out of the list: forgotten", #Geo.StartPlaces(7, t.pos) == 3)
end

-- 3. steps on the spot first: the place nearby alone, not every place of the quest giver
do
  local t = session()
  local Geo = t.Geo
  local near = step("take", 7, 50, { search = { i = 1, n = 3 } })
  local far = step("take", 7, 5000, { search = { i = 2, n = 3 } })
  local other = step("take", 8, 3000)
  local task = { order = { near, far } }
  local pred = {}
  local n = Geo.ApplyNearFirst({ task, { order = { other } } }, { other, near, far }, pred,
    { keys = { [Geo.StepKey(near)] = true } })
  check("one place first", n == 1 and pred[far] and pred[far][1] == near and pred[near] == nil)
end

-- 4. the alternative prerequisite already in the list is the one kept
do
  local t = session()
  t.data[10] = { single = { 11, 12 } }
  t.ns.Settings().custom = { list = { { id = 12 } } }
  local pre = t.Geo.MissingPrereqs(10)
  check("the alternative in the list", #pre == 1 and pre[1] == 12)
end

-- 5. steps on the spot first: only steps the order rules of the plan allow
do
  local function nearby(prereqs, ...)
    local t = session()
    local CP, Geo = t.CP, t.Geo
    for id, p in pairs(prereqs) do t.prereqs[id] = p end
    local route = freeze(Geo, ...)
    local asked = 0
    Geo.Tracking = function() return true end
    Geo.ServicePending = function() return nil end
    CP.StepDone = function() return false end
    CP.Busy = function() return false end
    CP.Replan = function(_, opts) asked = asked + 1 return true, opts end
    CP.NearbyCheck()
    return asked, route
  end
  local asked = nearby({ [2] = { 1 } }, step("turnin", 1, 3000), step("take", 2, 20))
  check("follow-up before its prerequisite is turned in: nothing computed", asked == 0)
  asked = nearby({}, step("turnin", 1, 3000), step("take", 2, 20))
  check("a step possible now: computed", asked == 1)
  local dungeon = { kind = "dungeon", p = { c = 0, x = 3000, y = 0 }, work = 1,
    task = { title = "d", members = { { kind = "obj", task = { id = 3 } } } } }
  asked = nearby({}, step("take", 9, 3000), dungeon, step("turnin", 3, 20))
  check("turn-in before an objective in an instance: nothing computed", asked == 0)
end

-- 6. after a reload, steps share a task only when it was the same
do
  local t = session()
  local Geo = t.Geo
  local old = { id = 1, title = "A", xp = 100 }
  local new = { id = 1, title = "A", xp = 250, orderWarn = true, tags = { "x" } }
  local take = { kind = "take", p = { c = 0, x = 1, y = 1 }, task = old, work = 1, done = true }
  local obj = { kind = "obj", p = { c = 0, x = 2, y = 2 }, task = new, work = 1 }
  local turnin = { kind = "turnin", p = { c = 0, x = 3, y = 3 }, task = new, work = 1 }
  old.stops, new.stops = { take }, { obj }
  local tasks, out = {}, {}
  for i, s in ipairs({ take, obj, turnin }) do out[i] = Geo.DeserializeStep(Geo.SerializeStep(s), tasks) end
  check("the new plan's figures and warning", out[3].task.xp == 250 and out[3].task.orderWarn == true)
  check("same task: shared, with its first step", out[2].task == out[3].task and out[3].task.stops[1] == out[2])
  check("the history keeps its own", out[1].task ~= out[3].task and out[1].task.xp == 100)
end

-- 7. a computation failed after a change of the list: the quests taken out leave the plan
do
  local t = session()
  local Geo, CP = t.Geo, t.CP
  CP.StepDone = function(s) return s.done == true end
  t.ns.Settings().custom = { list = { { id = 1 } } }
  local boat = { kind = "travel", p = { c = 0, x = 1, y = 0 }, task = { title = "boat" }, work = 1 }
  local kept = { kind = "travel", p = { c = 0, x = 2, y = 0 }, task = { title = "kept" }, work = 1 }
  local visit = { kind = "dungeon", p = { c = 0, x = 3, y = 0 }, work = 1,
    task = { title = "visit", members = { { kind = "obj", task = { id = 2 } }, { kind = "obj", task = { id = 1 } } } } }
  freeze(Geo, step("take", 2, 0, { done = true }), boat, step("obj", 2, 10), kept, step("take", 1, 20), visit,
    step("turnin", 2, 30))
  Geo.RequestPlan = function(_, cb) cb(nil, "no") end
  t.State.computing = true
  Geo.Recompute("custom", nil, true)
  local titles = {}
  for i = 2, #Geo.Frozen().route do titles[#titles + 1] = Geo.Frozen().route[i].task.title end
  check("steps and transports of the quest taken out gone, history kept", table.concat(titles, " ") == "q2 kept q1 visit")
  check("saved", #t.ns.Settings().roadbook.steps == 4)
end

-- 8. a state of the ways back already computed without success is not computed again
do
  local t = session()
  local Geo, CP = t.Geo, t.CP
  local saved = { bind = "a", src = {} }
  local now = { bind = "b", src = {} }
  local asked = 0
  Geo.Frozen = function() return { route = { {}, { kind = "fm" } } } end
  Geo.FrozenRec = function() return { recall = saved } end
  Geo.RecallState = function() return now end
  CP.StepDone = function() return false end
  CP.Replan = function() asked = asked + 1 return true end
  CP.RecallCheck()
  CP.RecallCheck()
  check("failed computation: asked once", asked == 1)
  now = { bind = "c", src = {} }
  CP.RecallCheck()
  check("another change: asked again", asked == 2)
  now = saved
  CP.RecallCheck()
  now = { bind = "c", src = {} }
  CP.RecallCheck()
  check("back to the saved state, then changed: asked again", asked == 3)
end

-- 9. two quests abandoned: one question after the other
do
  local t = session()
  local Geo, CP, popups = t.Geo, t.CP, t.log.popups
  Geo.Frozen = function() return { route = { {} } } end
  Geo.InCustom = function() return true end
  Geo.CustomList = function() return {} end
  CP.QuestRemoved(1)
  CP.QuestRemoved(2)
  check("one window at a time", #popups == 1 and popups[1].data.id == 1)
  t.State.computing = true -- the answer started a computation
  t.env.StaticPopupDialogs.FQP_QUEST_ABANDONED.OnHide()
  t.tick()
  check("next question waits for the computation", #popups == 1)
  t.State.computing = nil
  t.tick()
  check("then it is asked", #popups == 2 and popups[2].data.id == 2)
end

-- 10. no tracking left to start after a computation given up or the Roadbook emptied
do
  local t = session()
  local Geo, CP = t.Geo, t.CP
  CP.focusAfter = true
  Geo.CustomSetList = function() end
  Geo.MapOwner = function() return nil end
  CP.TrackOff = function() end
  CP.DoEmpty()
  check("emptied", CP.focusAfter == nil)
  t.waitScan.fn = function(_, _, giveUp)
    giveUp()
    return true
  end
  t.env.GetTime = function() return 0 end
  CP.focusAfter = true
  CP.Recompute({ kind = "time", value = 60 }, true)
  check("given up waiting for the scan", CP.focusAfter == nil and t.State.computing == nil)
end

-- 11. an error of OpenMap while drawing is told
do
  local t = session()
  local Geo = t.Geo
  t.ns.OM.FromYards = function() error("broken FromYards") end
  t.ns.OM.AddPath = function() end
  Geo.WalkWay = function() return 1, { { c = 0, x = 1, y = 1 } } end
  Geo.MapWalk({}, 0, 0, { c = 0, x = 0, y = 0 }, { c = 0, x = 9, y = 9 }, 1, 1)
  check("told in the chat", table.concat(t.log.chat, " "):find("broken FromYards", 1, true) ~= nil)
end

finish()
