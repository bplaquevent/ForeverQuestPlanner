-- Forever Quest Planner: Roadbook tab, filters, tab selection, Refresh.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Analyze, AreaName, CP, CharKey, Color, CreateScrollPanel = ns.Analyze, ns.AreaName, ns.CP, ns.CharKey, ns.Color, ns.CreateScrollPanel
local CreateSearchBox, FormatNumber, FormatTime, Geo, GeoReady, ICON = ns.CreateSearchBox, ns.FormatNumber, ns.FormatTime, ns.Geo, ns.GeoReady, ns.ICON
local IsCompleted, IsPinned, IsWatched, K, L, MatchWords, Normalize = ns.IsCompleted, ns.IsPinned, ns.IsWatched, ns.K, ns.L, ns.MatchWords, ns.Normalize
local PinIcon, Plural, PointText, Print, QDB, QGet = ns.PinIcon, ns.Plural, ns.PointText, ns.Print, ns.QDB, ns.QGet
local Refresh, RemainingObjectives = ns.Refresh, ns.RemainingObjectives
local RenderAvailable, RenderExport, RenderList, RenderNear, RenderTodo, RouteText = ns.RenderAvailable, ns.RenderExport, ns.RenderList, ns.RenderNear, ns.RenderTodo, ns.RouteText
local Settings, ShowMessage, State, StateIcons, TurnInText = ns.Settings, ns.ShowMessage, ns.State, ns.StateIcons, ns.TurnInText
local expandedCategories, panels, tabButtons = ns.expandedCategories, ns.panels, ns.tabButtons

-- State of the Roadbook: followed by the Objective button, paused, not started, finished.
function Geo.RoadbookStatus(doneCount, total)
  local D = K.DESC
  if total > 0 and doneCount >= total then
    return Color(D.good, L["Finished"]) .. Color(D.meta, Geo.IsCustom() and L[" (add quests to extend it)"]
      or L[" (\"Generate\" makes a new one)"])
  end
  if CP.CurrentFocus() then return Color(D.good, L["Active"]) end
  if doneCount > 0 then return Color(D.warn, L["Paused"]) .. Color(D.meta, L[" (\"Start\" resumes it)"]) end
  return Color(D.meta, L["Not started"]) .. Color(D.meta, L[" (\"Start\" to follow it)"])
end

-- Header of a Roadbook: state, plan, level, travel, hearthstone and teleports in four short lines.
function Geo.RouteHeader(route, info, doneCount)
  local frozenRec = Geo.FrozenRec()
  local need = (UnitXPMax and UnitXP) and (UnitXPMax("player") - UnitXP("player")) or nil
  local sep = Color("777777", "  ·  ")
  local l1
  if info.custom then
    l1 = { Color("ffd100", L["Goal: custom list"]), Color("ffffff", Plural(info.count, L["quest"]) .. " · ~" .. FormatTime(info.total)) }
    if (info.xp or 0) > 0 then l1[#l1 + 1] = FormatNumber(info.xp) .. " XP" end
    if (info.dungeons or 0) > 0 then l1[#l1 + 1] = Plural(info.dungeons, L["dungeon visit"]) end
    if (info.discovered or 0) > 0 then l1[#l1 + 1] = Color("c890ff", Plural(info.discovered, L["flight path to activate"])) end
  else
    if info.goal then
      local g = info.goal
      local goalText = g.kind == "level" and (L["Goal: level "] .. g.value) or (L["Goal: session of "] .. FormatTime(g.value))
      if info.goalStage and info.levels then
        goalText = goalText .. Color("ffffff", string.format(L[" (stage up to level %d: at its end, \"Generate\" plans the next one)"], info.levels[#info.levels]))
      end
      l1 = { Color("ffd100", goalText) }
      l1[#l1 + 1] = Color("ffffff", Plural(info.count, L["quest"]) .. " · " .. FormatNumber(info.xp) .. " XP")
    else
      l1 = { Color("ffffff", Plural(info.count, L["quest"]) .. " · " .. FormatNumber(info.xp) .. " XP") }
    end
    if info.mobXP and info.mobXP > 0 then l1[#l1 + 1] = L["monsters: "] .. FormatNumber(info.mobXP) .. " XP" end
    l1[#l1 + 1] = "~" .. FormatTime(info.total) .. " · ~" ..
      (info.total > 0 and FormatNumber(info.xp / info.total * 3600) or "0") .. " XP/h"
  end
  local l2 = {}
  if info.levels then
    local lEnd, l0 = info.levels[#info.levels], info.levels[1]
    l2[#l2 + 1] = L["Level "] .. l0 .. (lEnd > l0 and (" -> " .. lEnd) or "")
  end
  if need then l2[#l2 + 1] = L["next level in "] .. FormatNumber(need) .. " XP" end
  l2[#l2 + 1] = Color("ffd100", string.format(L["%d/%d steps done"], doneCount, #route - 1) ..
    (frozenRec and frozenRec.saved and (L[" (saved at "] .. frozenRec.saved .. ")") or ""))
  local l3 = { string.format("%.1f m/s", info.speed) .. (Settings().mountSpeed and "" or L[" (on foot)"]) }
  if info.net.taxi == 0 then
    l3[#l3 + 1] = Color("ff8040", L["no flight master recorded (open a flight map)"])
  else
    l3[#l3 + 1] = string.format(L["%d flight master(s)"], info.net.taxi)
  end
  do
    local ready = Geo.HearthReady()
    local bindP, bindName = Geo.CurrentBind()
    if Settings().noHearth then
      l3[#l3 + 1] = L["hearthstone ignored"]
    elseif ready then
      local where = bindName or "?"
      if not bindP then where = where .. Color("ff8040", " (?)")
      elseif bindP.approx then where = where .. Color("ffd100", " (~)") end
      l3[#l3 + 1] = L["hearth: "] .. where .. " (" .. (ready > 0 and FormatTime(ready) or L["ready"]) .. ")"
    end
  end
  -- Class teleports: cooldown of each one, runes left for the mage teleports.
  local runes
  for _, src in ipairs(Geo.RecallSources()) do
    if src.spell then
      if src.charges then
        runes = src.charges
      elseif (src.cd or 0) > 0 then
        l3[#l3 + 1] = src.name .. " (" .. (src.ready > 0 and FormatTime(src.ready) or L["ready to cast"]) .. ")"
      else
        l3[#l3 + 1] = src.name
      end
    end
  end
  if runes then l3[#l3 + 1] = string.format(L["teleports: %d rune(s)"], runes) end
  if info.custom then
    if (info.skipped or 0) > 0 then l3[#l3 + 1] = Color("ff6060", Plural(info.skipped, L["quest"]) .. L[" cannot be planned"]) end
  else
    if (info.skipped or 0) > 0 then l3[#l3 + 1] = Plural(info.skipped, L["quest"]) .. L[" ignored"] end
    local nEx = 0
    for _ in pairs(Geo.Excluded()) do nEx = nEx + 1 end
    if nEx > 0 then l3[#l3 + 1] = Plural(nEx, L["quest"]) .. L[" skipped by you"] end
  end
  return Geo.RoadbookStatus(doneCount, #route - 1) .. "\n" ..
    table.concat(l1, sep) .. "\n" .. table.concat(l2, sep) .. "\n" .. table.concat(l3, sep)
end

-- Quest steps done during a dungeon visit, one line each.
function Geo.DungeonMemberLines(task)
  local lines = {}
  for _, m in ipairs(task.members or {}) do
    local what
    if m.kind == "take" then what = L["pick up"]
    elseif m.kind == "turnin" then what = L["turn in"]
    else what = ((m.r and m.r.tg.name) or L["objective"]) .. L[" x"] .. ((m.r and m.r.count) or "?") end
    local line = "- " .. ((m.task and m.task.title) or "?") .. L[": "] .. what
    lines[#lines + 1] = CP.StepDone(m) and Color("40ff40", line .. L[" (done)"]) or Color(K.DESC.action, line)
  end
  return lines
end

-- Steps of a Roadbook, in sections per zone, in route order, added to `items`.
-- remove(step): button of a quest step not done (a step done has no button); query: search of the
-- tab. A click on a step (done or not) shows it on the map.
function Geo.RouteStepItems(items, route, info, remove, query)
  local plevel = info.plevel
  info.netCache = info.netCache or { [""] = { net = info.net } }
  local nets = Geo.RouteNets(route, info.speed or 7, plevel, info.netCache)
  local segments, current = {}, nil
  local tracking = CP.CurrentFocus() ~= nil and Geo.frozen ~= nil and Geo.frozen.route == route
  for i = 2, #route do
    local s = route[i]
    local zone = s.p.instance or AreaName(s.p.area) or s.p.zoneName or "?"
    if not current or current.zone ~= zone then
      current = { zone = zone, steps = {}, xp = 0 }
      segments[#segments + 1] = current
    end
    current.steps[#current.steps + 1] = { s = s, prev = route[i - 1], i = i }
    if tracking and CP.IsStepFocused(s) then current.focused = true end
    if s.kind == "turnin" or s.kind == "obj" or s.kind == "dungeon" then current.xp = current.xp + (s.xp or 0) end
  end

  local n = 0
  for si, seg in ipairs(segments) do
    local last = seg.steps[#seg.steps].s
    local label = string.format("%d. %s - %s", si, seg.zone, Plural(#seg.steps, L["step"]))
    if seg.xp > 0 then label = label .. " - +" .. FormatNumber(seg.xp) .. " XP" end
    label = label .. L[" - until ~"] .. FormatTime(last.at or 0)
    local segItems = {}
    for _, st in ipairs(seg.steps) do
      local s, task = st.s, st.s.task
      n = n + 1
      local function nameOnly(t) return t and (t:match("^(.-) %- ") or t) or nil end
      -- action: what to do and where (light gray); figures: XP, time, notes (each in its color).
      local D = K.DESC
      local kindLabel, action, spotLine
      local xp, notes, extra = nil, {}, {}
      local function add(hex, s) notes[#notes + 1] = Color(hex, s) end
      if s.kind == "bind" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\Innkeeper:14:14|t" .. Color("ffb060", L["[Innkeeper]"])
        action = L["Talk to "] .. (task.npc or "?") .. L[" and choose \"Make this inn your home\""] .. K.DESC_SEP .. PointText(s.p)
      elseif s.kind == "hearth" then
        local icon, tag, what = Geo.RecallText(s)
        kindLabel = icon .. Color("ffb060", tag)
        action = what
      elseif s.kind == "travel" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t" .. Color("80c0ff", L["[Transport]"])
        action = (task.mode == "vol" and (L["Talk to the flight master at "] .. (task.from or "?") .. L[", destination "] .. (task.dest or "?"))
          or (L["Board at "] .. (task.from or "?") .. L[" for "] .. (task.dest or "?"))) .. K.DESC_SEP .. PointText(s.p)
      elseif s.kind == "fm" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t" .. Color("c890ff", L["[Flight master]"])
        action = L["Talk to "] .. (task.npc or "?") .. L[" to activate the flight path"] .. K.DESC_SEP .. PointText(s.p)
        if s.fmHub then add(D.good, L["used afterwards by the route"]) end
      elseif s.kind == "dungeon" then
        kindLabel = K.DUNGEON_ICON .. Color("c890ff", L["[Dungeon]"])
        action = L["Enter the dungeon and do the steps below"] .. K.DESC_SEP .. PointText(s.p)
        xp = Geo.XPText(s.xp)
        add(D.meta, "~" .. FormatTime(s.work or 0) .. L[" inside (setting)"])
        extra = Geo.DungeonMemberLines(task)
      elseif s.escort then
        kindLabel = K.ESCORT_ICON .. Color("ffb060", L["[Escort]"])
        action = L["Stay close to "] .. CP.EscortNpc(task) ..
          (s.kind == "turnin" and (L[", then turn in to "] .. (nameOnly(TurnInText(task.id)) or "?")) or "") ..
          K.DESC_SEP .. PointText(s.p)
        if s.kind == "turnin" then xp = Geo.XPText(task.xp) end
        add(D.warn, "~" .. FormatTime(s.work or 0) .. L[", do not interrupt"])
      elseif s.kind == "take" then
        kindLabel = Color("80c0ff", L["[Pick up]"])
        action = L["Pick up from "] .. (nameOnly(task.starter) or "?") .. K.DESC_SEP .. PointText(s.p)
        if s.search then
          add(D.warn, string.format(L["possible place %d/%d of the quest giver"], s.search.i, s.search.n))
        end
        if Geo.IsEscort(task.id) then add(D.warn, L["escort: starts right after"]) end
        if task.reqLevel then
          add(D.warn, string.format(task.levelWarn and L["level %d required: not reached by this route"] or L["level %d required"], task.reqLevel))
        end
        if task.dep then add(D.chain, string.format(L["follow-up of \"%s\""], task.dep.title or "?")) end
      elseif s.kind == "obj" then
        kindLabel = Color("ffd100", L["[Objective]"])
        action = (s.r.tg.name or L["objective"]) .. L[" x"] .. s.r.count .. K.DESC_SEP .. PointText(s.p)
        xp = Geo.XPText(s.xp, true, L[" (monsters)"])
        if s.spots and s.spots > 1 then
          spotLine = Color(D.warn, L["Multiple spots ("] .. s.spots .. L["): chosen spot has "] ..
            (s.spot and s.spot.n or "?") .. L[" monsters, the most efficient (travel + density)"])
        elseif s.spot then
          add(D.meta, string.format(L["spot of %d monsters"], s.spot.n))
        end
      else
        kindLabel = Color("40ff40", L["[Turn in]"])
        action = L["Turn in to "] .. (nameOnly(TurnInText(task.id)) or "?") .. K.DESC_SEP .. PointText(s.p)
        xp = Geo.XPText(task.xp)
        if s.quick then add(D.good, L["quick win: added on the way"])
        elseif task.quick then add(D.good, L["ready to turn in"]) end
      end
      if task.id and task.stops and s == task.stops[1] then
        if task.warn then add(D.bad, task.warn) end
        if task.orderWarn then add(D.warn, L["order of the prerequisites not respected"]) end
      end
      -- Step icon (not the quest's current state): ! to pick up, gray ? objective, yellow ? to turn in.
      local icon = ""
      if s.kind == "take" then icon = ICON.available
      elseif s.kind == "obj" then icon = ICON.inprogress
      elseif s.kind == "turnin" then icon = ICON.turnin end
      if task.id and IsWatched(task.id) then icon = icon .. ICON.watched end
      if task.id and IsPinned(task.id) then icon = icon .. PinIcon() end
      if icon ~= "" then icon = icon .. " " end
      local text = string.format("  %d. %s%s %s", n, icon, kindLabel,
        Geo.QuestTitle(task.title, task.id and { id = task.id, level = task.level } or nil))
      text = text .. Geo.DescLine(Color(D.action, action)) ..
        Geo.DescLine(xp, Color(D.meta, "[" .. FormatTime(s.at or 0) .. "]"), unpack(notes))
      for _, line in ipairs(extra) do text = text .. Geo.DescLine(line) end
      if spotLine then text = text .. Geo.DescLine(spotLine) end
      local net = (nets[st.i] or nets[1]).net
      local way = s.kind ~= "hearth" and RouteText(st.prev.p, s.p, net, plevel) or nil
      if way and way ~= L["right here"] then text = text .. Geo.DescLine(Color("ffffff", L["Route: "]) .. way) end
      local lvs = info.levels
      if lvs and st.i and lvs[st.i] and lvs[st.i - 1] and lvs[st.i] > lvs[st.i - 1] then
        text = text .. Geo.DescLine(Color(D.good, L["---- level "] .. lvs[st.i] .. L[" reached (~"] .. FormatTime(s.at or 0) .. ") ----"))
      end
      if #query == 0 or MatchWords(Normalize(text), query) then
        -- Only button: remove the quest, or skip the followed hearthstone /
        -- transport step. Tracking and the pin follow the floating Objective button (exclusive focus).
        local qid, step = task.id, s
        local button
        if CP.StepDone(step) then
          -- step done: checked, no button
          text = text:gsub("^  (%d+%. )", "  %1|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t" .. Color("40ff40", L["[Done] "]), 1)
        elseif step.search and qid then
          -- a place where the quest giver may stand: not there, the next place
          button = { text = L["Not here"], fn = function() CP.SkipStep(step) end,
            tip = { L["Not here"], L["The quest giver is not at this place: the step is marked done and the Objective button moves to the next place to check."] } }
        elseif qid then
          button = remove(step)
        elseif (step.kind == "hearth" or step.kind == "travel") and step == CP.CurrentFocus() then
          -- only the followed transport step: skipping a later one makes no sense
          button = { text = L["Skip"], fn = function() CP.SkipStep(step) end,
            tip = { L["Skip"], step.kind == "travel"
              and L["Marks this step as done; the steps to come are planned again without this transport for the way to the next step."]
              or L["Marks this step as done (already there, other way of travel…); the Objective button moves to the next step."] } }
        end
        segItems[#segItems + 1] = { text = text, b3 = button, questID = task.id,
          onClick = function() Geo.ShowStep(step) end }
      end
    end
    if #segItems > 0 then
      -- While the Roadbook is followed, the section of the current step is expanded by default.
      items[#items + 1] = { header = true, kind = "step", key = "seg" .. si, label = label, open = seg.focused }
      for _, it in ipairs(segItems) do items[#items + 1] = it end
    end
  end
end

-- Roadbook being computed: the list is emptied and the waiting animation is shown instead.
function Geo.RenderBusy(panel)
  local busy = Geo.computing and true or false
  if panel.busy then panel.busy:SetShown(busy) end
  if busy then RenderList(panel, "xp", {}) end
  return busy
end

-- Quests of the Roadbook, in route order (the custom quest list too when it is made of it: the quests
-- that cannot be planned included), one line each with its state; the ones not turned in can be
-- removed from the Roadbook (CP.SkipQuest: excluded, or out of the custom list), which is adapted.
function Geo.RoadbookQuestItems(items, fz, query)
  local D = K.DESC
  local custom = fz.info.custom
  local quests, seen = {}, {}
  local function add(task, quick)
    local id = task and task.id
    if not id or seen[id] then return end
    seen[id] = true
    quests[#quests + 1] = { id = id, title = task.title, level = task.level, quick = quick }
  end
  for i = 2, #fz.route do
    local st = fz.route[i]
    if st.kind == "dungeon" then
      for _, m in ipairs(st.task.members or {}) do add(m.task) end
    else
      add(st.task, st.quick)
    end
  end
  local list, entry, why = {}, {}, {}
  if custom then
    list = Geo.CustomList()
    for _, it in ipairs(list) do entry[it.id] = it end
    for _, u in ipairs(fz.info.unplanned or Geo.customUnplanned or {}) do why[u.id] = u.reason end
    for _, it in ipairs(list) do
      if not seen[it.id] then
        seen[it.id] = true
        quests[#quests + 1] = { id = it.id, title = it.title, level = it.level, unplanned = true }
      end
    end
  end
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  local logById = {}
  for _, q in ipairs(e and e.quests or {}) do logById[q.id] = q end
  local plevel = UnitLevel("player")
  local lines = {}
  for _, it in ipairs(quests) do
    local q = logById[it.id]
    local done = IsCompleted(it.id)
    local status
    if done then status = Color(D.good, L["turned in"])
    elseif q and q.complete then status = Color(D.good, L["ready to turn in"])
    elseif q then status = Color(D.action, L["in the quest log"])
    else status = Color(D.action, L["to pick up"]) end
    local notes = {}
    if it.quick then notes[#notes + 1] = Color(D.good, L["quick win: added on the way"]) end
    local req = not q and not done and QGet(QDB.Quest, it.id, "requiredLevel")
    if type(req) == "number" and req > plevel then notes[#notes + 1] = Color(D.warn, string.format(L["level %d required"], req)) end
    local en = entry[it.id]
    if en and en.pre then
      local by = entry[en.pre]
      notes[#notes + 1] = Color(D.chain, string.format(L["prerequisite of \"%s\""], (by and by.title) or ("#" .. en.pre)))
    end
    local sort = QGet(QDB.Quest, it.id, "zoneOrSort") or 0
    local dg = sort > 0 and QDB.dungeonOf[sort]
    if dg then notes[#notes + 1] = Geo.WithLevel(Color(D.meta, L["dungeon: "] .. (AreaName(dg) or "?")), AreaName(dg)) end
    local text = "  " .. StateIcons(it.id) .. Geo.QuestTitle(it.title, { id = it.id, level = it.level }) ..
      Geo.DescLine(status, unpack(notes))
    local rest = q and not q.complete and RemainingObjectives(q) or ""
    if rest ~= "" then text = text .. Geo.DescLine(Color(D.action, rest)) end
    if custom and not Geo.ForPlayer(it.id) then text = text .. Geo.DescLine(Color(D.bad, L["not for your class or race"])) end
    if it.unplanned then
      text = text .. Geo.DescLine(Color(D.bad, why[it.id] and (L["Cannot be planned: "] .. why[it.id]) or L["not planned yet"]))
    end
    if #query == 0 or MatchWords(Normalize(text), query) then
      local id, title = it.id, it.title
      lines[#lines + 1] = { text = text, questID = q and id or nil, linkQuest = id,
        b3 = not done and { text = L["Remove"], fn = function() CP.ConfirmSkipQuest({ task = { id = id, title = title } }) end,
          tip = { L["Remove"], custom and L["Removes the quest from the Roadbook and from the custom quest list (with the prerequisites added only for it); the steps to come are computed again."]
            or L["Removes the quest from the Roadbook (until a new one); the steps to come are adapted."] } } or nil }
    end
  end
  if #lines == 0 then return end
  -- Collapsed by default while the Roadbook is followed: the route matters more than the list.
  items[#items + 1] = { header = true, kind = "class", key = "rbquests", open = not CP.CurrentFocus(),
    label = L["Quests of the Roadbook - "] .. Plural(#quests, L["quest"]),
    b3 = custom and #list > 0 and { text = L["Remove all"], fn = function() StaticPopup_Show("FQP_CUSTOM_CLEAR") end } or nil }
  for _, line in ipairs(lines) do items[#items + 1] = line end
end

-- Roadbook tab: the quests of the Roadbook, then its steps.
local function RenderXP()
  local panel = panels.xp
  if panel.busy then panel.busy:Hide() end
  if not GeoReady() then
    ShowMessage(panel, "xp", L["Unable to convert QuestieDB positions to this client's map."])
    return
  end
  if Geo.RenderBusy(panel) then pcall(CP.RefreshButton) return end
  local query = State.xpQuery

  -- Saved Roadbook: it no longer changes until "Generate" (or a removed quest, a change of the
  -- custom list when it is made of it).
  local fz = Geo.Frozen()
  if not fz then
    -- No Roadbook: it is only computed with "Generate".
    local custom = State.xpGoal.kind == "custom"
    local last = custom and Geo.customCache or Geo.planCache
    local items = { { section = true, text = L["Objectives"] } }
    if last and last.err and not last.route then items[#items + 1] = { text = Color("ff6060", last.err) } end
    if custom then
      local n = #Geo.CustomList()
      items[#items + 1] = { text = Color("ffd100", n > 0
        and string.format(L["No Roadbook. Your custom quest list has %s: click \"Generate\" for the fastest route doing them all; the Objective button follows it."], Plural(n, L["quest"]))
        or L["No Roadbook. Add quests to the custom list with the \"Add\" button (or \"Add all\" on a category) in the Around me, Quest log and Available tabs, with the prerequisites they still need, then click \"Generate\": the fastest route doing them all is computed and the Objective button follows it."]) }
    else
      items[#items + 1] = { text = Color("ffd100", L["No Roadbook. Choose a goal above, then click \"Generate\": the route earning the XP fastest is computed and the Objective button follows it."]) }
    end
    RenderList(panel, "xp", items)
    pcall(CP.RefreshButton)
    return
  end
  pcall(Geo.InjectQuickWins)
  local route, info = fz.route, fz.info
  local doneCount = 0
  for i = 2, #route do if CP.StepDone(route[i]) then doneCount = doneCount + 1 end end
  local items = { { section = true, text = L["Quests"] } }
  Geo.RoadbookQuestItems(items, fz, query)
  items[#items + 1] = { section = true, text = L["Objectives"] }
  items[#items + 1] = { text = Color("aaaaaa", Geo.RouteHeader(route, info, doneCount)) }
  Geo.RouteStepItems(items, route, info, function(step)
    return { text = L["Remove"], fn = function() CP.ConfirmSkipQuest(step) end }
  end, query)
  -- Quests kept for max level: reward or access only useful at endgame.
  if info.later and #info.later > 0 then
    local laterItems = {}
    table.sort(info.later, function(a, b) return (a.level or 0) < (b.level or 0) end)
    for _, e in ipairs(info.later) do
      local text = "  " .. StateIcons(e.id) .. Geo.QuestTitle(e.title, { id = e.id, level = e.level }) ..
        Geo.DescLine(Color(K.DESC.warn, L["To do at level "] .. Geo.MaxLevel() .. L[": "] .. (e.reason or "?")))
      if #query == 0 or MatchWords(Normalize(text), query) then
        laterItems[#laterItems + 1] = { text = text, questID = e.id }
      end
    end
    if #laterItems > 0 then
      items[#items + 1] = { header = true, kind = "take", key = "later",
        label = L["For max level - "] .. Plural(#laterItems, L["quest"]) .. L[" (easier and faster at that level)"] }
      for _, it in ipairs(laterItems) do items[#items + 1] = it end
    end
  end
  if #route <= 1 then items[#items + 1] = { text = L["No usable quest found around you."] } end
  if #query > 0 then
    local any = false
    for _, it in ipairs(items) do if it.header then any = true break end end
    if not any then items[#items + 1] = { text = L["No plan step matches the search."] } end
  end
  RenderList(panel, "xp", items, #query > 0)
  pcall(CP.RefreshButton)
end

-- State check boxes (several allowed), one row of the filter box.
local STATE_DEFS = {
  { key = "turnin", label = L["To turn in"], icon = function() return ICON.turnin end },
  { key = "inprogress", label = L["In progress"], icon = function() return ICON.inprogress end },
  { key = "watched", label = L["Tracked"], icon = function() return ICON.watched end },
  { key = "pinned", label = L["Pin"], icon = function() return PinIcon() end },
  { key = "available", label = L["To pick up"], icon = function() return ICON.available end },
  { key = "abandon", label = L["To abandon"], icon = function() return "|TInterface\\RaidFrame\\ReadyCheck-NotReady:16:16|t" end },
  { key = "custom", label = L["Custom list"], icon = function() return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:16:16|t" end },
}

-- Filter box, under the search box (same frame as the goal box of the automatic Roadbook): one row
-- per kind of filter, the list starts below it.
K.FILTER_BOX_TOP, K.FILTER_ROW_H = -96, 26
local function FilterBox(panel)
  if panel.box then return panel.box end
  local box = CreateFrame("Frame", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
  box:SetPoint("TOPLEFT", 14, K.FILTER_BOX_TOP)
  box:SetPoint("TOPRIGHT", -14, K.FILTER_BOX_TOP)
  if box.SetBackdrop then
    box:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0, 0, 0, 0.35)
    box:SetBackdropBorderColor(0.8, 0.65, 0.35, 0.8)
  end
  box.rows = 0
  panel.box = box
  return box
end

-- Adds a row to the filter box: returns the y of its middle (in the box); the box grows and the list
-- moves down.
local function AddFilterRow(panel)
  local box = FilterBox(panel)
  box.rows = box.rows + 1
  local h = 12 + K.FILTER_ROW_H * box.rows
  box:SetHeight(h)
  if panel.scroll then
    panel.scroll:ClearAllPoints()
    panel.scroll:SetPoint("TOPLEFT", State.mainFrame, "TOPLEFT", 12, K.FILTER_BOX_TOP - h - 6)
    panel.scroll:SetPoint("BOTTOMRIGHT", State.mainFrame, "BOTTOMRIGHT", -32, 24)
  end
  return -(6 + K.FILTER_ROW_H / 2 + K.FILTER_ROW_H * (box.rows - 1))
end

local function AddStateFilters(panel, keys, selected)
  panel.stateChecks = {}
  local box = FilterBox(panel)
  local y = AddFilterRow(panel)
  local label = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("LEFT", box, "TOPLEFT", 10, y)
  label:SetText(L["Show:"])
  local x = 10 + (label:GetStringWidth() or 46) + 6
  for _, def in ipairs(STATE_DEFS) do
    if keys[def.key] then
      local cb = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
      cb:SetSize(22, 22)
      cb:SetPoint("LEFT", box, "TOPLEFT", x, y)
      cb.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      cb.label:SetPoint("LEFT", cb, "RIGHT", 0, 0)
      cb.label:SetText(def.icon() .. " " .. def.label)
      cb:SetScript("OnClick", function(self)
        selected[def.key] = self:GetChecked() and true or nil
        Refresh()
      end)
      panel.stateChecks[def.key] = cb
      x = x + 22 + (cb.label:GetStringWidth() or 90) + 18 -- each box as wide as its label
    end
  end
  function panel.HighlightStates()
    for k, cb in pairs(panel.stateChecks) do cb:SetChecked(selected[k] and true or false) end
  end
end

K.SEARCH_WIDTH = 200 -- search box, centered at the top of every tab
-- Single choice dropdown with Blizzard's menu API (UIDropDownMenu writes shared globals and so taints
-- Blizzard's own frames: edit mode, objective tracker). choices(): list of { key, label };
-- isSelected(key); onSelect(key). Its text is the selected choice (none: "-"), Geo.DropdownSync after a
-- change made elsewhere.
function Geo.Dropdown(parent, width, choices, isSelected, onSelect)
  local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  dd:SetWidth(width)
  dd:SetDefaultText("-")
  dd:SetupMenu(function(_, root)
    for _, c in ipairs(choices()) do
      root:CreateRadio(c.label, function() return isSelected(c.key) end, function() onSelect(c.key) end)
    end
  end)
  return dd
end
-- Text of the dropdown after a change made elsewhere; not while its menu is open (rebuilding it would
-- close it at every refresh).
function Geo.DropdownSync(dd)
  if not dd:IsMenuOpen() then dd:GenerateMenu() end
end
-- Tab panel: search box centered at the top; single choice filter (dropdown) and option (check box) on
-- the first row of the filter box below it.
local function CreateFilterPanel(f, filters, getCurrent, setCurrent, onSearch, toggle, caption)
  local c = CreateFrame("Frame", nil, f)
  c:SetAllPoints(f)
  if onSearch then
    c.search = CreateSearchBox(c, K.SEARCH_WIDTH, onSearch)
    c.search:SetPoint("TOP", 0, -71)
  end
  c.scroll = CreateScrollPanel(c, nil, -98)
  local box, y, x = nil, 0, 10
  if #filters > 0 or toggle then
    box = FilterBox(c)
    y = AddFilterRow(c)
  end
  local dd
  if #filters > 0 then
    if caption then
      local cap = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      cap:SetPoint("LEFT", box, "TOPLEFT", x, y)
      cap:SetText(caption)
      x = x + (cap:GetStringWidth() or 40) + 2
    end
    -- Dropdown as wide as its longest choice.
    local probe = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local w = 40
    for _, flt in ipairs(filters) do
      probe:SetText(flt.label)
      w = math.max(w, (probe:GetStringWidth() or 80) + 16)
    end
    probe:Hide()
    dd = Geo.Dropdown(box, w + 24, function() return filters end,
      function(key) return getCurrent() == key end,
      function(key) setCurrent(key); Refresh() end)
    dd:SetPoint("LEFT", box, "TOPLEFT", x + 2, y)
    x = x + 2 + w + 24 + 12 -- right edge of the dropdown, then a gap
  end
  if toggle then
    local cb = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("LEFT", box, "TOPLEFT", x, y)
    cb.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label:SetText(toggle.label)
    cb:SetScript("OnClick", function(self)
      toggle.set(self:GetChecked() and true or false)
      Refresh()
    end)
    c.toggle = cb
  end
  function c.Highlight()
    if dd then Geo.DropdownSync(dd) end
    -- Option shared by several tabs: its box follows the setting.
    if c.toggle then c.toggle:SetChecked(toggle.get() and true or false) end
  end
  return c
end

-- Option shared by "Around me" and "Available".
local LOW_LEVEL_TOGGLE = {
  label = L["Low-level quests"],
  get = function() return Settings().showLowLevel end,
  set = function(v) Settings().showLowLevel = v or nil end,
}

local nearTicker

local function StopNearTicker()
  if nearTicker then
    nearTicker:Cancel()
    nearTicker = nil
  end
end

local function SelectTab(name)
  if not panels[name] then name = "groups" end -- old tab removed (e.g. "To abandon")
  State.currentTab = name
  if name ~= "settings" then Settings().lastTab = name end
  for key, p in pairs(panels) do p:SetShown(key == name) end
  local highlighted = (name == "export") and "groups" or name -- the export is part of the Quest log tab
  if State.mainFrame.usesTabs and PanelTemplates_SetTab and tabButtons[highlighted] then
    pcall(PanelTemplates_SetTab, State.mainFrame, tabButtons[highlighted].tabIndex)
  elseif State.mainFrame.usesTabs and PanelTemplates_SetTab then
    pcall(PanelTemplates_SetTab, State.mainFrame, 0) -- settings: no tab selected
  else
    for key, b in pairs(tabButtons) do
      if key == highlighted then b:LockHighlight() else b:UnlockHighlight() end
    end
  end
  -- Opening the Roadbook: back to the default folding (current step's section only while following it).
  if name == "xp" then
    for k in pairs(expandedCategories) do
      if k:find("^" .. name .. ":") then expandedCategories[k] = nil end
    end
  end
  StopNearTicker()
  if name == "near" and C_Timer.NewTicker then
    nearTicker = C_Timer.NewTicker(3, function()
      if State.mainFrame and State.mainFrame:IsShown() and State.currentTab == "near" then
        RenderNear()
      else
        StopNearTicker()
      end
    end)
  end
  Refresh()
end

local RefreshUnsafe
local lastError
Refresh = function()
  if not (State.mainFrame and State.mainFrame:IsShown()) then return end
  local ok, err = xpcall(RefreshUnsafe, function(e)
    return tostring(e) .. (debugstack and ("\n" .. debugstack(2, 3, 0)) or "")
  end)
  if not ok and err ~= lastError then
    lastError = err
    Print(L["|cffff6060Error while updating the window|r (copy it to report it):\n"] .. err)
  end
end

RefreshUnsafe = function()
  if State.currentTab == "export" then
    RenderExport()
  elseif State.currentTab == "avail" then
    panels.avail.Highlight()
    RenderAvailable()
  elseif State.currentTab == "near" then
    panels.near.Highlight()
    panels.near.HighlightStates()
    RenderNear()
  elseif State.currentTab == "xp" then
    panels.xp.Highlight()
    if panels.xp.UpdateMode then panels.xp.UpdateMode() end
    RenderXP()
  else
    local a = Analyze()
    RenderTodo(a)
  end
end

-- Shared with the next files.
ns.AddFilterRow, ns.FilterBox = AddFilterRow, FilterBox
ns.AddStateFilters, ns.CreateFilterPanel, ns.LOW_LEVEL_TOGGLE, ns.Refresh, ns.SelectTab, ns.StopNearTicker = AddStateFilters, CreateFilterPanel, LOW_LEVEL_TOGGLE, Refresh, SelectTab, StopNearTicker
