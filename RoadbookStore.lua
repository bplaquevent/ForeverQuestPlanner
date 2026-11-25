-- Forever Quest Planner: the saved Roadbook: its steps written and read back, saved after each change,
-- loaded after a /reload, emptied.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, CP, GeoReady, Settings, State, TaxiCount = ns.Geo, ns.CP, ns.GeoReady, ns.Settings, ns.State, ns.TaxiCount

---------------------------------------------------------------------------
-- Saved Roadbook: once computed, the plan no longer changes until its end, or until a
-- recompute request (duration change, Recalculate button).
---------------------------------------------------------------------------
-- Quest steps done inside a dungeon (dungeon step of the custom Roadbook).
function Geo.SerializeMembers(members)
  if not members then return nil end
  local out = {}
  for _, m in ipairs(members) do
    local t = m.task or {}
    out[#out + 1] = { kind = m.kind, id = t.id, title = t.title, level = t.level, xp = m.xp,
      objName = m.r and m.r.tg and m.r.tg.name, objKind = m.r and m.r.tg and m.r.tg.kind, count = m.r and m.r.count,
      objSource = m.r and m.r.tg and m.r.tg.sourceItem }
  end
  return out
end

function Geo.DeserializeMembers(list)
  if not list then return nil end
  local out = {}
  for _, m in ipairs(list) do
    out[#out + 1] = { kind = m.kind, xp = m.xp, task = { id = m.id, title = m.title, level = m.level },
      r = m.objName and { tg = { name = m.objName, kind = m.objKind, sourceItem = m.objSource }, count = m.count } or nil }
  end
  return out
end

-- Fields of a step and of its task saved as they are; the others are written out below.
local STEP_FIELDS = { "kind", "at", "xp", "work", "gain", "spots", "escort", "glue", "via", "bindDest", "search",
  "done", "afterSource", "skill", "npc", "nopin" }
local TASK_FIELDS = { "id", "title", "level", "xp", "starter", "reqLevel", "tags", "npc", "mode", "from", "dest",
  "kind", "quick", "dungeon", "warn", "levelWarn", "orderWarn", "spell", "service", "npcId" }

local function CopyFields(from, fields, into)
  for _, k in ipairs(fields) do into[k] = from[k] end
  return into
end

function Geo.SerializeStep(st)
  local t = st.task or {}
  local rec = CopyFields(st, STEP_FIELDS, {})
  rec.fmHub = st.fmHub and { id = st.fmHub.id, node = st.fmHub.node, name = st.fmHub.name, p = Geo.CopyPoint(st.fmHub.p) } or nil
  rec.members = Geo.SerializeMembers(t.members)
  rec.spotN = st.spot and st.spot.n
  rec.p = Geo.CopyPoint(st.p)
  local tg = st.r and st.r.tg
  rec.objName, rec.objKind, rec.objSource = tg and tg.name, tg and tg.kind, tg and tg.sourceItem
  rec.count = st.r and st.r.count
  rec.first = t.stops and t.stops[1] == st or nil
  rec.task = CopyFields(t, TASK_FIELDS, {})
  rec.task.depTitle = t.dep and t.dep.title
  rec.task.destP = Geo.CopyPoint(t.destP)
  return rec
end

function Geo.DeserializeStep(rec, tasks)
  local tr = rec.task or {}
  local key = tostring(tr.id) .. "|" .. tostring(tr.title) .. "|" .. tostring((rec.kind == "travel" or rec.kind == "dungeon") and rec.at or "")
  local task = tasks[key]
  if not task then
    task = CopyFields(tr, TASK_FIELDS, { stops = {} })
    task.dep = tr.depTitle and { title = tr.depTitle } or nil
    task.destP = tr.destP
    task.members = Geo.DeserializeMembers(rec.members)
    tasks[key] = task
  end
  local st = CopyFields(rec, STEP_FIELDS, { task = task })
  st.work, st.p, st.fmHub = rec.work or 0, rec.p or {}, rec.fmHub
  st.spot = rec.spotN and { n = rec.spotN } or nil
  st.r = rec.objName and { tg = { name = rec.objName, kind = rec.objKind, sourceItem = rec.objSource }, count = rec.count } or nil
  if rec.first then task.stops[1] = st end
  return st
end

-- One Roadbook per character, with its progress: the fastest route doing every quest of the list
-- (info.custom). "Adapt" completes or trims the list, the changes of the list adapt it.
local frozen -- { route, info } (loaded plan), read through Geo.Frozen()

function Geo.FrozenRec()
  return Settings().roadbook
end

local function SerializeRoute(route)
  local steps = {}
  for i = 2, #route do steps[#steps + 1] = Geo.SerializeStep(route[i]) end
  return steps
end

-- Saves the steps of the loaded plan again, after they changed (marked, removed, added).
function Geo.SaveRoute()
  local fz, rec = frozen, Geo.FrozenRec()
  if fz and rec then rec.steps = SerializeRoute(fz.route) end
end

-- A new or adapted plan, saved (Geo.AdoptPlan, Roadbook.lua: saved, then redrawn).
function Geo.Freeze(route, info)
  local steps = SerializeRoute(route)
  local slim = { count = info.count, xp = info.xp, total = info.total, mobXP = info.mobXP, levels = info.levels,
    speed = info.speed, plevel = info.plevel, skipped = info.skipped, taxi = info.taxi,
    custom = info.custom, unplanned = info.unplanned, dungeons = info.dungeons, discovered = info.discovered }
  Settings().roadbook = { saved = date and date("%H:%M") or "",
    start = Geo.CopyPoint(route[1].p), steps = steps, info = slim, recall = Geo.RecallState() }
  frozen = { route = route, info = info }
  Geo.Trace("freeze", string.format("plan saved: %d step(s), %d done%s", #steps,
    (function() local n = 0 for _, s in ipairs(steps) do if s.done then n = n + 1 end end return n end)(),
    info.custom and ", custom list" or ""))
end

-- Saved plan (reloaded after a /reload), or nil.
function Geo.Frozen()
  if frozen then return frozen end
  local rec = Geo.FrozenRec()
  if not (rec and rec.steps and #rec.steps > 0) then return nil end
  -- After a /reload, the QuestieDB map mappings are not loaded yet.
  if not GeoReady() then return nil end
  local route, tasks = { { kind = "start", p = rec.start or {}, work = 0 } }, {}
  for _, r in ipairs(rec.steps) do route[#route + 1] = Geo.DeserializeStep(r, tasks) end
  local info = {}
  for k, v in pairs(rec.info or {}) do info[k] = v end
  info.taxi = TaxiCount()
  frozen = { route = route, info = info }
  return frozen
end

-- Empties the Roadbook (its steps and its progress).
function Geo.ClearFrozen()
  if frozen or Geo.FrozenRec() then Geo.Trace("clear", "plan emptied") end
  frozen = nil
  Settings().roadbook = nil
  State.lastPlanError = nil
end

-- The Roadbook is tracked (a step is focused); not tracked otherwise.
function Geo.Tracking()
  return ns.CP.CurrentFocus() ~= nil
end

-- Every step of the Roadbook is done: it can only be extended (custom: quests added), generated again or emptied.
function Geo.IsFinished()
  local fz = Geo.Frozen()
  if not fz or #fz.route < 2 then return false end
  for i = 2, #fz.route do
    if not CP.StepDone(fz.route[i]) then return false end
  end
  return true
end

-- The Roadbook exists (saved, or being computed).
function Geo.HasRoadbook()
  if State.computing then return true end
  local rec = Geo.FrozenRec()
  return (rec and rec.steps and #rec.steps > 0) or false
end

-- Marks a step as done (and saves it).
function Geo.MarkDone(st, value)
  if value == nil then value = true end
  Geo.Trace("mark", (value and "done: " or "not done: ") .. Geo.StepTrace(st))
  st.done = value or nil
  Geo.SaveRoute()
end
