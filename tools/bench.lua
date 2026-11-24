-- Forever Quest Planner: offline test bench (Lua 5.1, no game needed).
-- Loads a Roadbook problem captured in game by /fqp dump (then /reload) and runs the solver
-- (Solver.lua, the same file as in the game) on it.
--
-- Usage: lua5.1 tools/bench.lua <file> [--char NAME] [--save NAME] [--goal GOAL] [--steps] [--evals N] [--custom N] [--list N]
--   <file>       the SavedVariables file (WTF/Account/<ACCOUNT>/SavedVariables/ForeverQuestPlanner.lua)
--                or a saved case (tools/cases/<name>.lua)
--   --char NAME  character to use ("Name-Realm"; default: the most recent capture)
--   --save NAME  save the problem as a test case: tools/cases/<NAME>.lua
--   --goal GOAL  goal of the optimized Roadbook: "time:7200" (seconds) or "level:40" (default: the capture's)
--   --evals N    evaluation budget of the optimizer
--   --custom N   custom Roadbook test: a list made of the first N captured quests (no follow-up), planned
--                by the solver (the capture's own custom list, if any, otherwise)
--   --list N     "Generate" with a duration or level goal (--goal) on a list made of the first N captured
--                quests (0: empty list): kept whole and completed, or only its best part kept
--   --service    service shortcut test: a service step at the place of the last quest step, that must come first
--   --steps      print every step of the Roadbooks

local root = ((arg[0]:match("^(.*)/[^/]*$")) or ".") .. "/.."

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

-- Options.
local file, opts = nil, {}
local i = 1
while arg[i] do
  local a = arg[i]
  if a == "--char" or a == "--save" or a == "--goal" or a == "--evals" or a == "--custom" or a == "--list" then
    opts[a:sub(3)] = arg[i + 1]
    i = i + 1
  elseif a == "--steps" then
    opts.steps = true
  elseif a == "--service" then
    opts.service = true
  elseif not file then
    file = a
  else
    fail("unexpected argument: " .. a)
  end
  i = i + 1
end
if not file then fail("usage: lua5.1 tools/bench.lua <file> [--char NAME] [--save NAME] [--goal GOAL] [--steps] [--evals N] [--custom N] [--list N]") end

-- Solver (an addon file: called with the addon name and namespace).
local chunk, err = loadfile(root .. "/Solver.lua")
if not chunk then fail(err) end
local ns = {}
chunk("ForeverQuestPlanner", ns)
local S = ns.Solver

-- Problem: a case file returns it; a SavedVariables file holds ForeverQuestPlannerBench[char].
local function LoadProblem(path)
  local f, e = loadfile(path)
  if not f then fail(e) end
  local env = {}
  setfenv(f, env)
  local ret = f()
  if type(ret) == "table" and ret.world then return ret end
  local all = env.ForeverQuestPlannerBench
  if type(all) ~= "table" or not next(all) then
    fail("no capture in " .. path .. ": type /fqp dump in game, then /reload")
  end
  if opts.char then
    return all[opts.char] or fail("no capture for " .. opts.char)
  end
  local best
  for _, rec in pairs(all) do
    if not best or (rec.date or "") > (best.date or "") then best = rec end
  end
  return best
end

-- Writes a value as Lua source (sorted keys: stable files, readable diffs).
local function Serialize(v, indent, out)
  local t = type(v)
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.10g", v) end
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "table" then
    local keys, n = {}, #v
    for k in pairs(v) do
      if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) and k ~= "W" and k ~= "prepared" then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return a < b end
      return type(a) == "number"
    end)
    local pad = indent .. "  "
    out[#out + 1] = "{\n"
    for k = 1, n do
      out[#out + 1] = pad
      Serialize(v[k], pad, out)
      out[#out + 1] = ",\n"
    end
    for _, k in ipairs(keys) do
      out[#out + 1] = pad
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then out[#out + 1] = k
      else
        out[#out + 1] = "["
        Serialize(k, pad, out)
        out[#out + 1] = "]"
      end
      out[#out + 1] = " = "
      Serialize(v[k], pad, out)
      out[#out + 1] = ",\n"
    end
    out[#out + 1] = indent .. "}"
  else
    out[#out + 1] = "nil"
  end
end

local function Time(s)
  if not s then return "-" end
  s = math.floor(s + 0.5)
  local sign = s < 0 and "-" or ""
  s = math.abs(s)
  if s < 3600 then return string.format("%s%d min %02d", sign, math.floor(s / 60), s % 60) end
  return string.format("%s%d h %02d", sign, math.floor(s / 3600), math.floor((s % 3600) / 60))
end

local function Count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function ZoneName(P, p)
  if not p then return "?" end
  local z = S.ZoneId(S.World(P), p)
  return z and P.world.zones[z] and P.world.zones[z].name or p.zoneName or "?"
end

---------------------------------------------------------------------------
local P = LoadProblem(file)
if opts.save then
  -- A name only: it goes into a file path and a shell command.
  if not opts.save:match("^[%w_-]+$") then fail("--save: letters, digits, - and _ only") end
  os.execute("mkdir -p '" .. root .. "/tools/cases'")
  local path = root .. "/tools/cases/" .. opts.save .. ".lua"
  local out = { "-- Roadbook problem captured by /fqp dump (" .. tostring(P.char) .. ", " .. tostring(P.date) .. ").\nreturn " }
  Serialize(P, "", out)
  out[#out + 1] = "\n"
  local f = io.open(path, "w") or fail("cannot write " .. path)
  f:write(table.concat(out))
  f:close()
  print("Case saved: " .. path)
end

local pl, w = P.player, P.world
print(string.format("== %s, captured %s (format %s)", tostring(P.char), tostring(P.date), tostring(P.version)))
print(string.format("Character: %s %s level %d (%d / %d XP, %d rested), speed %.1f, in %s",
  tostring(pl.race), tostring(pl.class), pl.level, pl.xp or 0, pl.xpMax or 0, pl.rested or 0, pl.speed, ZoneName(P, pl.pos)))
if pl.goal then
  print(string.format("Goal: %s %s", pl.goal.kind, pl.goal.kind == "time" and Time(pl.goal.value) or tostring(pl.goal.value)))
end
local knownN = 0
for _, n in ipairs(w.nodes) do if n.known then knownN = knownN + 1 end end
print(string.format("World: %d flight nodes (%d known), %d flight lines, %d docks, %d lines, %d passes, %d innkeepers, %d zones, %d cells",
  #w.nodes, knownN, #w.edges, #w.docks, #w.links, #w.passes, #w.inns, Count(w.zones), P.cells or 0))
for _, s in ipairs(w.recall) do
  local dest = s.bind and ("bind: " .. tostring(w.bindName)) or ZoneName(P, s.p)
  print(string.format("  way back %s (%s): %s, ready in %s, cooldown %s%s", tostring(s.name), tostring(s.key), dest,
    Time(s.ready), Time(s.cd), s.charges and (", " .. s.charges .. " charges") or ""))
end
local follow = 0
for _, t in ipairs(P.tasks) do if t.dep then follow = follow + 1 end end
print(string.format("Candidate quests: %d (%d follow-ups), %d skipped; custom list: %d quests",
  #P.tasks, follow, P.skipped or 0, P.custom and #(P.custom.tasks or P.custom.list or {}) or 0))
if P.buildSeconds then print(string.format("  quests prepared in game in %.1f s", P.buildSeconds)) end

-- A Roadbook of the current planner, evaluated by the solver: legacy accounting (must match the
-- game's times), then the full model.
local function Report(name, b)
  print("")
  print("== Roadbook " .. name .. " (current planner)")
  if not b.route then
    print("  not computed: " .. tostring(b.err))
    return
  end
  local route = b.route
  local info = b.info or {}
  local target = type(b.goal) == "table" and S.Goal(P, b.goal).target or nil
  print(string.format("  %d steps, in game: %s, %d XP", #route - 1, Time(info.total), info.xp or 0))
  local leg = S.Evaluate(P, route, { legacy = true })
  local worst, wi = 0, nil
  for k = 2, #route do
    local d = math.abs((leg.at[k] or 0) - (route[k].at or 0))
    if d > worst then worst, wi = d, k end
  end
  print(string.format("  legacy evaluation: %s (gap %+d s), %d XP; largest step gap %d s%s", Time(leg.time),
    math.floor(leg.time - (info.total or 0) + 0.5), leg.xp, math.floor(worst + 0.5),
    wi and string.format(" (step %d %s %s)", wi - 1, route[wi].kind, tostring(route[wi].title)) or ""))
  local full = S.Evaluate(P, route, { targetLevel = target })
  print(string.format("  full evaluation: %s, %d XP (%d quests, %d monsters), level %d -> %d, %.0f XP/h%s",
    Time(full.time), full.xp, full.questXP, full.mobXP, pl.level, full.level, full.xp / math.max(full.time, 1) * 3600,
    target and (", level " .. target .. (full.reach and (" at " .. Time(full.reach)) or " not reached")) or ""))
  if full.wait > 0 then print("  waiting for cooldowns: " .. Time(full.wait)) end
  for _, v in ipairs(full.violations) do
    print(string.format("  ! step %d (%s): %s", v.i - 1, tostring(route[v.i].title), v.what))
  end
  if opts.steps then
    print(string.format("  %4s %-7s %-44s %9s %9s %9s %5s", "#", "kind", "step", "game", "legacy", "full", "lvl"))
    for k = 2, #route do
      local st = route[k]
      local title = tostring(st.title or st.mode or "")
      if st.obj and st.obj.name then title = title .. " / " .. st.obj.name end
      print(string.format("  %4d %-7s %-44s %9s %9s %9s %5d", k - 1, st.kind, title:sub(1, 44), Time(st.at),
        Time(leg.at[k]), Time(full.at[k]), full.levels[k]))
    end
  end
end

for _, name in ipairs({ "auto", "custom" }) do
  if P.baseline and P.baseline[name] then Report(name, P.baseline[name]) end
end

-- --service: is the service step the first one (a teleport may come before it)?
local function PrintServiceFirst(route)
  local k = 2
  while route[k] and route[k].kind == "hearth" do k = k + 1 end
  local first = route[k]
  print("  service first: " .. ((first and first.kind == "service") and "OK"
    or "WRONG (first step: " .. tostring(first and first.kind) .. ")"))
end

---------------------------------------------------------------------------
-- Optimizer, compared with the automatic Roadbook of the current planner (same goal).
---------------------------------------------------------------------------
-- Custom list made of captured quests: their steps with the auto Roadbook's order rules (pick-up first,
-- free objectives in any order, fixed ones at their place, turn-in last).
local function CustomFrom(n)
  local out, byN, ci = { tasks = {}, steps = {}, pred = {} }, {}, 0
  for _, t in ipairs(P.tasks) do
    if #out.tasks >= n then break end
    if not t.dep then
      out.tasks[#out.tasks + 1] = { id = t.id, title = t.title }
      local ti, first, last = #out.tasks, nil, nil
      local list = {}
      for k, s in ipairs(t.stops) do
        local st = {}
        for key, v in pairs(s) do st[key] = v end
        ci = ci + 1
        st.ci, st.ti, st.tn, st.k = ci, ti, nil, nil
        out.steps[ci] = st
        list[k] = st
      end
      S.RankPreds(list, out.pred)
      for k, st in ipairs(list) do
        if st.glue and k > 1 then st.glueTo = list[k - 1].ci end
      end
      byN[t.n] = list
    end
  end
  if opts.service then
    -- Service shortcut (Geo.ServiceStep): at the place of the last step (the player's place when the
    -- list is empty), before every other step.
    local at = ci > 0 and out.steps[ci].p or P.player.pos
    local svc = { kind = "service", p = at, work = P.k.SERVICE_TIME or 60, -- (not in older captures)
      title = "Service", ci = ci + 1 }
    out.steps[ci + 1] = svc
    for k = 1, ci do
      out.pred[k] = out.pred[k] or {}
      table.insert(out.pred[k], svc.ci)
    end
    out.first = svc.ci
  end
  return out
end
if not opts.list and (opts.custom or (P.custom and P.custom.steps)) then
  if opts.custom then P.custom = CustomFrom(tonumber(opts.custom)) end
  print("")
  print(string.format("== Custom Roadbook, %d quests, %d steps", #P.custom.tasks, #P.custom.steps))
  if P.baseline and P.baseline.custom and P.baseline.custom.route and not opts.custom then
    local r = S.Evaluate(P, P.baseline.custom.route, {})
    print(string.format("  current   total %s, %d XP", Time(r.time), r.xp))
  end
  S.clock = os.clock
  local co = S.Optimize(P, "custom", { maxEvals = opts.evals and tonumber(opts.evals) or nil })
  local levelWarn = 0
  for _, v in ipairs(co.res.violations) do if v.kind == "level" then levelWarn = levelWarn + 1 end end
  print(string.format("  optimized total %s, %d XP, %d quests below their level; %d evaluations, %d rebuilds kept, %.1f s",
    Time(co.res.time), co.res.xp, levelWarn, co.evals, co.rebuilt or 0, co.seconds or 0))
  if opts.steps then
    for k = 2, #co.route do
      local st = co.route[k]
      print(string.format("  %4d %-7s %-50s %9s  %s", k - 1, st.kind, tostring(st.title or ""):sub(1, 50), Time(co.res.at[k]),
        ZoneName(P, st.p)))
    end
  end
  if opts.service then PrintServiceFirst(co.route) end
  if opts.custom then os.exit(0) end
end

local goal = pl.goal
if opts.goal then
  local kind, value = opts.goal:match("^(%a+):(%d+)$")
  if not (kind == "time" or kind == "level") then fail("--goal: time:<seconds> or level:<level>") end
  goal = { kind = kind, value = tonumber(value) }
end
local g = S.Goal(P, goal)
local listCase = opts.list and tonumber(opts.list)
if listCase then
  P.custom = (listCase > 0 or opts.service) and CustomFrom(listCase) or nil
  if P.custom then
    S.clock = os.clock
    local whole = S.Optimize(P, "custom", { maxEvals = 3000 })
    print("")
    print(string.format("== List of %d quests: whole list %s, %d XP, level %d -> %d", #P.custom.tasks, Time(whole.res.time),
      whole.res.xp, pl.level, whole.res.level))
  end
else
  P.custom = nil -- the candidates alone
end

-- Value of an evaluation for the goal: XP within the time, or time to reach the level.
local function GoalText(res)
  if g.kind == "level" then
    return res.reach and ("level " .. g.target .. " in " .. Time(res.reach)) or ("level " .. g.target .. " not reached")
  end
  local xp = S.XPWithin(res, g.value)
  return string.format("%d XP in %s (%.0f XP/h)", xp, Time(g.value), xp / g.value * 3600)
end

local function Line(name, res)
  print(string.format("  %-9s %s | total %s, %d XP, %d violations", name, GoalText(res), Time(res.time), res.xp,
    #res.violations))
end

print("")
print(string.format("== Optimizer, goal %s %s", g.kind, g.kind == "time" and Time(g.value) or tostring(g.target)))
local base = P.baseline and P.baseline.auto
local baseSame = base and base.route and type(base.goal) == "table" and base.goal.kind == g.kind
  and (g.kind ~= "time" or base.goal.value == g.value) and (g.kind ~= "level" or S.Goal(P, base.goal).target == g.target)
if base and base.route then
  Line(baseSame and "current" or "current*", S.Evaluate(P, base.route, { targetLevel = g.target }))
  if not baseSame then print("  (* computed by the game for another goal)") end
end
S.clock = os.clock
local opt = S.Optimize(P, goal, { maxEvals = opts.evals and tonumber(opts.evals) or nil })
if opts.service and P.custom and P.custom.first then PrintServiceFirst(opt.route) end
Line("optimized", opt.res)
local nT, nH = 0, 0
local listIds = {}
for _, st in ipairs(opt.route) do
  if st.tn and st.k == 1 then nT = nT + 1 end
  if st.kind == "hearth" then nH = nH + 1 end
  if st.ci and st.id then listIds[st.id] = true end
end
if opt.mode then
  print(string.format("  list %s: %d of its %d quests kept, %d candidate quests added", opt.mode, Count(listIds),
    #P.custom.tasks, nT))
end
print(string.format("  %d quests, %d steps, %d teleports; %d evaluations, %d rounds, %d rebuilds kept, %.1f s", nT,
  #opt.route - 1, nH, opt.evals, opt.rounds, opt.rebuilt or 0, opt.seconds or 0))
if opts.steps then
  local res = opt.res
  print(string.format("  %4s %-7s %-50s %9s %5s", "#", "kind", "step", "at", "lvl"))
  for k = 2, #opt.route do
    local st = opt.route[k]
    local title = tostring(st.title or "")
    if st.obj and st.obj.name then title = title .. " / " .. st.obj.name end
    if st.kind == "hearth" then title = title .. string.format(" (saves %s)", Time(st.gain)) end
    print(string.format("  %4d %-7s %-50s %9s %5d  %s", k - 1, st.kind, title:sub(1, 50), Time(res.at[k]), res.levels[k],
      ZoneName(P, st.p)))
  end
end
