-- Forever Quest Planner: Roadbook tab, filters, tab selection, Refresh.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Analyze, AreaName, CP, CharKey, Color, CreateScrollPanel = ns.Analyze, ns.AreaName, ns.CP, ns.CharKey, ns.Color, ns.CreateScrollPanel
local CreateSearchBox, FormatNumber, FormatTime, Geo, GeoReady, ICON = ns.CreateSearchBox, ns.FormatNumber, ns.FormatTime, ns.Geo, ns.GeoReady, ns.ICON
local IsPinned, IsWatched, K, L, MatchWords, Normalize = ns.IsPinned, ns.IsWatched, ns.K, ns.L, ns.MatchWords, ns.Normalize
local PinIcon, Plural, PointText, Print, QDB, QGet = ns.PinIcon, ns.Plural, ns.PointText, ns.Print, ns.QDB, ns.QGet
local Refresh, RemainingObjectives = ns.Refresh, ns.RemainingObjectives
local RenderAvailable, RenderExport, RenderList, RenderNear, RenderTodo, RouteText = ns.RenderAvailable, ns.RenderExport, ns.RenderList, ns.RenderNear, ns.RenderTodo, ns.RouteText
local Settings, ShowMessage, StartScan, State, StateIcons, TurnInText = ns.Settings, ns.ShowMessage, ns.StartScan, ns.State, ns.StateIcons, ns.TurnInText
local panels, scan, tabButtons = ns.panels, ns.scan, ns.tabButtons

-- Header of a Roadbook: plan, level, travel and hearthstone in three short lines.
function Geo.RouteHeader(route, info, doneCount, frozenRec)
  local need = (UnitXPMax and UnitXP) and (UnitXPMax("player") - UnitXP("player")) or nil
  local sep = Color("777777", "  ·  ")
  local l1
  if info.custom then
    l1 = { Color("ffffff", Plural(info.count, L["quest"]) .. " · ~" .. FormatTime(info.total)) }
    if (info.xp or 0) > 0 then l1[#l1 + 1] = FormatNumber(info.xp) .. " XP" end
    if (info.dungeons or 0) > 0 then l1[#l1 + 1] = Plural(info.dungeons, L["dungeon visit"]) end
    if (info.discovered or 0) > 0 then l1[#l1 + 1] = Color("c890ff", Plural(info.discovered, L["flight path to activate"])) end
  else
    l1 = { Color("ffffff", Plural(info.count, L["quest"]) .. " · " .. FormatNumber(info.xp) .. " XP") }
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
  if info.custom then
    if (info.skipped or 0) > 0 then l3[#l3 + 1] = Color("ff6060", Plural(info.skipped, L["quest"]) .. L[" cannot be planned"]) end
  else
    if info.skipped > 0 then l3[#l3 + 1] = Plural(info.skipped, L["quest"]) .. L[" ignored"] end
    local nEx = 0
    for _ in pairs(Settings().excluded) do nEx = nEx + 1 end
    if nEx > 0 then l3[#l3 + 1] = Plural(nEx, L["quest"]) .. L[" removed by you"] end
  end
  return table.concat(l1, sep) .. "\n" .. table.concat(l2, sep) .. "\n" .. table.concat(l3, sep)
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
-- remove(step): button of a quest step not done.
function Geo.RouteStepItems(items, route, info, remove)
  local plevel = info.plevel
  info.netCache = info.netCache or { [""] = { net = info.net } }
  local nets = Geo.RouteNets(route, info.speed or 7, plevel, info.netCache)
  local segments, current = {}, nil
  for i = 2, #route do
    local s = route[i]
    local zone = s.p.instance or AreaName(s.p.area) or s.p.zoneName or "?"
    if not current or current.zone ~= zone then
      current = { zone = zone, steps = {}, xp = 0 }
      segments[#segments + 1] = current
    end
    current.steps[#current.steps + 1] = { s = s, prev = route[i - 1], i = i }
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
        kindLabel = "|TInterface\\Icons\\INV_Misc_Rune_01:14:14|t" .. Color("ffb060", L["[Hearthstone]"])
        action = L["Use the hearthstone · saves ~"] .. FormatTime(s.gain or 0)
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
      if task.tags and task.stops and s == task.stops[1] then
        text = text .. Geo.DescLine("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12:12|t " .. Color(D.prio, L["Priority: "] .. table.concat(task.tags, K.DESC_SEP)))
      end
      local lvs = info.levels
      if lvs and st.i and lvs[st.i] and lvs[st.i - 1] and lvs[st.i] > lvs[st.i - 1] then
        text = text .. Geo.DescLine(Color(D.good, L["---- level "] .. lvs[st.i] .. L[" reached (~"] .. FormatTime(s.at or 0) .. ") ----"))
      end
      if #State.xpQuery == 0 or MatchWords(Normalize(text), State.xpQuery) then
        -- Only button: remove the quest from the Roadbook. Tracking and the pin follow the
        -- floating Objective button (exclusive focus).
        local qid, step = task.id, s
        local button
        if CP.StepDone(step) then
          -- step done: checked, no button
          text = text:gsub("^  (%d+%. )", "  %1|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t" .. Color("40ff40", L["[Done] "]), 1)
        elseif qid then
          button = remove(step)
        end
        segItems[#segItems + 1] = { text = text, b3 = button, questID = task.id }
      end
    end
    if #segItems > 0 then
      items[#items + 1] = { header = true, kind = "step", key = "seg" .. si, label = label }
      for _, it in ipairs(segItems) do items[#items + 1] = it end
    end
  end
end

-- Custom Roadbook tab: the chosen quests, then the computed route once started.
function Geo.RenderCustomXP(panel)
  local list = Geo.CustomList()
  if #list == 0 then
    ShowMessage(panel, "xp", L["The custom Roadbook is empty."] .. "\n\n" ..
      L["Add quests with the + button at the left of the quests, in the Quest log, Available, Around me tabs or the automatic Roadbook; the prerequisite quests they still need are added with them."] .. "\n\n" ..
      L["Then click \"Start\": the fastest route to do them all is computed (flights, boats, hearthstone, flight paths worth activating, one visit per dungeon) and the Objective button follows it."])
    pcall(CP.RefreshButton)
    return
  end
  local fz = Geo.Frozen()
  local D = K.DESC
  local why = {}
  for _, u in ipairs((fz and fz.info.unplanned) or Geo.customUnplanned or {}) do why[u.id] = u.reason end
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  local logById = {}
  for _, q in ipairs(e and e.quests or {}) do logById[q.id] = q end
  local titleOf = {}
  for _, it in ipairs(list) do titleOf[it.id] = it.title end
  local plevel = UnitLevel("player")
  local items = { { section = true, text = L["My quest list"] },
    { header = true, kind = "class", key = "customlist", open = true,
    label = L["Quests of the custom Roadbook - "] .. Plural(#list, L["quest"]),
    b3 = { text = L["Empty the list"], fn = function() StaticPopup_Show("FQP_CUSTOM_CLEAR") end } } }
  for _, it in ipairs(list) do
    local q = logById[it.id]
    local status
    if q and q.complete then status = Color(D.good, L["ready to turn in"])
    elseif q then status = Color(D.action, L["in the quest log"])
    else status = Color(D.action, L["to pick up"]) end
    local notes = {}
    local req = not q and QGet(QDB.Quest, it.id, "requiredLevel")
    if type(req) == "number" and req > plevel then notes[#notes + 1] = Color(D.warn, string.format(L["level %d required"], req)) end
    if it.pre then notes[#notes + 1] = Color(D.chain, string.format(L["prerequisite of \"%s\""], titleOf[it.pre] or ("#" .. it.pre))) end
    local sort = QGet(QDB.Quest, it.id, "zoneOrSort") or 0
    local dg = sort > 0 and QDB.dungeonOf and QDB.dungeonOf[sort]
    if dg then notes[#notes + 1] = Color(D.meta, L["dungeon: "] .. (AreaName(dg) or "?")) end
    local text = "  " .. StateIcons(it.id) .. Geo.QuestTitle(it.title, { id = it.id, level = it.level }) ..
      Geo.DescLine(status, unpack(notes))
    local rest = q and not q.complete and RemainingObjectives(q) or ""
    if rest ~= "" then text = text .. Geo.DescLine(Color(D.action, rest)) end
    if not Geo.ForPlayer(it.id) then text = text .. Geo.DescLine(Color(D.bad, L["not for your class or race"])) end
    if why[it.id] then text = text .. Geo.DescLine(Color(D.bad, L["Cannot be planned: "] .. why[it.id])) end
    if #State.xpQuery == 0 or MatchWords(Normalize(text), State.xpQuery) then
      local id = it.id
      items[#items + 1] = { text = text, questID = q and id or nil, linkQuest = id,
        b3 = { text = L["Remove"], fn = function() Geo.CustomRemove(id) end } }
    end
  end
  items[#items + 1] = { section = true, text = L["Route"] }
  if fz then
    pcall(Geo.InjectQuickWins)
    local route, info = fz.route, fz.info
    local doneCount = 0
    for i = 2, #route do if CP.StepDone(route[i]) then doneCount = doneCount + 1 end end
    items[#items + 1] = { text = Color("aaaaaa", Geo.RouteHeader(route, info, doneCount, Geo.FrozenStore()[Geo.FrozenKey()])) }
    Geo.RouteStepItems(items, route, info, function(step)
      return { text = L["Remove"], fn = function() Geo.CustomRemove(step.task.id) end }
    end)
  elseif Geo.co then
    items[#items + 1] = { text = Color("ffd100", L["Computing the Roadbook, please wait…"]) }
  else
    items[#items + 1] = { text = Color("ffd100", L["Click \"Start\" to compute the fastest route through these quests and follow it with the Objective button."]) }
  end
  RenderList(panel, "xp", items, #State.xpQuery > 0)
  pcall(CP.RefreshButton)
end

local function RenderXP()
  local panel = panels.xp
  if not QDB.ok then
    ShowMessage(panel, "xp", L["QuestieDB is not loaded: this tab needs the locations and XP from its database."])
    return
  end
  if not GeoReady() then
    ShowMessage(panel, "xp", L["Unable to convert QuestieDB positions to this client's map."])
    return
  end
  if Geo.CustomMode() then
    Geo.RenderCustomXP(panel)
    return
  end
  if scan.dirty or not scan.entries then
    if not scan.running then StartScan() end
    if scan.running or scan.dirty then
      ShowMessage(panel, "xp", L["Scanning available quests…"])
      return
    end
  end

  -- Saved Roadbook: it no longer changes until its end or a recompute request.
  local fz = Geo.Frozen()
  if not fz then
    if Geo.co then
      ShowMessage(panel, "xp", L["Computing the Roadbook, please wait…"])
      return
    end
    local last = Geo.planCache
    if last and last.err and not last.route and Geo.lastErrShown ~= last then
      Geo.lastErrShown = last
      RenderList(panel, "xp", { { text = Color("ff6060", last.err),
        b3 = { text = L["Start"], fn = function() CP.Recompute() end } } })
      return
    end
    Geo.Recompute()
    if not Geo.Frozen() then
      ShowMessage(panel, "xp", L["Computing the Roadbook, please wait…"])
      return
    end
    fz = Geo.Frozen()
  end
  pcall(Geo.InjectQuickWins)
  local route, info = fz.route, fz.info
  local doneCount = 0
  for i = 2, #route do if CP.StepDone(route[i]) then doneCount = doneCount + 1 end end
  if doneCount >= #route - 1 then
    Geo.Recompute()
    ShowMessage(panel, "xp", L["Roadbook finished: computing a new Roadbook…"])
    return
  end
  local items = { { text = Color("aaaaaa", Geo.RouteHeader(route, info, doneCount, Geo.FrozenStore()[Geo.FrozenKey()])) } }
  Geo.RouteStepItems(items, route, info, function(step)
    return { text = L["Remove from the Roadbook"], fn = function() CP.AskExclude(step) end }
  end)
  -- Quests kept for max level: reward or access only useful at endgame.
  if info.later and #info.later > 0 then
    local laterItems = {}
    table.sort(info.later, function(a, b) return (a.level or 0) < (b.level or 0) end)
    for _, e in ipairs(info.later) do
      local text = "  " .. StateIcons(e.id) .. Geo.QuestTitle(e.title, { id = e.id, level = e.level }) ..
        Geo.DescLine(Color(K.DESC.warn, L["To do at level "] .. Geo.MaxLevel() .. L[": "] .. (e.reason or "?")))
      if #State.xpQuery == 0 or MatchWords(Normalize(text), State.xpQuery) then
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
  if #State.xpQuery > 0 then
    local any = false
    for _, it in ipairs(items) do if it.header then any = true break end end
    if not any then items[#items + 1] = { text = L["No plan step matches the search."] } end
  end
  RenderList(panel, "xp", items, #State.xpQuery > 0)
  pcall(CP.RefreshButton)
end

-- Second line: toggle state buttons (several allowed), the list moves down one line.
local STATE_DEFS = {
  { key = "turnin", label = L["To turn in"], icon = function() return ICON.turnin end },
  { key = "inprogress", label = L["In progress"], icon = function() return ICON.inprogress end },
  { key = "watched", label = L["Tracked"], icon = function() return ICON.watched end },
  { key = "pinned", label = L["Pin"], icon = function() return PinIcon() end },
  { key = "available", label = L["To pick up"], icon = function() return ICON.available end },
  { key = "abandon", label = L["To abandon"], icon = function() return "|TInterface\\RaidFrame\\ReadyCheck-NotReady:16:16|t" end },
  { key = "custom", label = L["Custom Roadbook"], icon = function() return "|TInterface\\Icons\\INV_Misc_Book_09:16:16|t" end },
}

local function AddStateFilters(panel, keys, selected)
  panel.stateChecks = {}
  local x = 12
  local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", x, -104)
  label:SetText(L["Show:"])
  x = x + 54
  for _, def in ipairs(STATE_DEFS) do
    if keys[def.key] then
      local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
      cb:SetSize(22, 22)
      cb:SetPoint("TOPLEFT", x, -98)
      cb.label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      cb.label:SetPoint("LEFT", cb, "RIGHT", 0, 0)
      cb.label:SetText(def.icon() .. " " .. def.label)
      cb:SetScript("OnClick", function(self)
        selected[def.key] = self:GetChecked() and true or nil
        Refresh()
      end)
      panel.stateChecks[def.key] = cb
      x = x + 112
    end
  end
  panel.scroll:ClearAllPoints()
  panel.scroll:SetPoint("TOPLEFT", State.mainFrame, "TOPLEFT", 12, -124)
  panel.scroll:SetPoint("BOTTOMRIGHT", State.mainFrame, "BOTTOMRIGHT", -32, 24)
  function panel.HighlightStates()
    for k, cb in pairs(panel.stateChecks) do cb:SetChecked(selected[k] and true or false) end
  end
end

local function CreateFilterPanel(f, filters, getCurrent, setCurrent, onSearch, toggle, caption)
  local c = CreateFrame("Frame", nil, f)
  c:SetAllPoints(f)
  c.buttons = {}
  local x = 14
  -- Single choice: radio buttons (game template, otherwise a checkbox used as a radio).
  if #filters > 0 and caption then
    local cap = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cap:SetPoint("TOPLEFT", x, -76)
    cap:SetText(caption)
    c.caption = cap
    x = x + (cap:GetStringWidth() or 40) + 8
  end
  for _, flt in ipairs(filters) do
    local ok, b = pcall(CreateFrame, "CheckButton", nil, c, "UIRadioButtonTemplate")
    if not ok or not b then b = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate") end
    b:SetSize(18, 18)
    b:SetPoint("TOPLEFT", x, -73)
    b.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", b, "RIGHT", 2, 0)
    b.label:SetText(flt.label)
    b:SetScript("OnClick", function()
      setCurrent(flt.key)
      Refresh()
    end)
    c.buttons[flt.key] = b
    x = x + 18 + 2 + (b.label:GetStringWidth() or 50) + 14
  end
  if onSearch then
    -- Search box: 140 px, narrower if the filters and the option would not fit in the window.
    local toggleW = 0
    if toggle then
      local probe = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      probe:SetText(toggle.label)
      toggleW = 8 + 24 + 2 + (probe:GetStringWidth() or 100)
      probe:Hide()
    end
    local w = math.max(90, math.min(140, (f:GetWidth() or 820) - 16 - x - 12 - toggleW))
    c.search = CreateSearchBox(c, w, onSearch)
    c.search:SetPoint("TOPLEFT", x + 12, -71)
    x = x + 12 + w
  end
  if toggle then
    local cb = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x + 8, -69)
    cb.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label:SetText(toggle.label)
    cb:SetChecked(toggle.get() and true or false)
    cb:SetScript("OnClick", function(self)
      toggle.set(self:GetChecked() and true or false)
      Refresh()
    end)
    c.toggle = cb
  end
  c.scroll = CreateScrollPanel(c, nil, -98)
  function c.Highlight()
    local cur = getCurrent()
    for k, b in pairs(c.buttons) do b:SetChecked(k == cur) end
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
ns.AddStateFilters, ns.CreateFilterPanel, ns.LOW_LEVEL_TOGGLE, ns.Refresh, ns.SelectTab, ns.StopNearTicker = AddStateFilters, CreateFilterPanel, LOW_LEVEL_TOGGLE, Refresh, SelectTab, StopNearTicker
