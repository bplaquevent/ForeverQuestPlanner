-- Forever Quest Planner: Roadbook tab, filters, tab selection, Refresh.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Analyze, AreaName, CP, CharKey, Color, CreateScrollPanel = ns.Analyze, ns.AreaName, ns.CP, ns.CharKey, ns.Color, ns.CreateScrollPanel
local CreateSearchBox, FormatNumber, FormatTime, Geo, GeoReady, ICON = ns.CreateSearchBox, ns.FormatNumber, ns.FormatTime, ns.Geo, ns.GeoReady, ns.ICON
local IsPinned, IsWatched, K, L, MatchWords, Normalize = ns.IsPinned, ns.IsWatched, ns.K, ns.L, ns.MatchWords, ns.Normalize
local PinIcon, Plural, PointText, Print, QDB, Refresh = ns.PinIcon, ns.Plural, ns.PointText, ns.Print, ns.QDB, ns.Refresh
local RenderAvailable, RenderExport, RenderList, RenderNear, RenderTodo, RouteText = ns.RenderAvailable, ns.RenderExport, ns.RenderList, ns.RenderNear, ns.RenderTodo, ns.RouteText
local Settings, ShowMessage, StartScan, State, StateIcons, TurnInText = ns.Settings, ns.ShowMessage, ns.StartScan, ns.State, ns.StateIcons, ns.TurnInText
local panels, scan, tabButtons = ns.panels, ns.scan, ns.tabButtons

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
        b3 = { text = L["Recalculate"], fn = function() CP.Recompute() end } } })
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
  local frozenRec = Geo.FrozenStore()[CharKey()]

  -- Compact header: plan, level, travel and hearthstone in three short lines.
  local need = (UnitXPMax and UnitXP) and (UnitXPMax("player") - UnitXP("player")) or nil
  local sep = Color("777777", "  ·  ")
  local l1 = { Color("ffffff", Plural(info.count, L["quest"]) .. " · " .. FormatNumber(info.xp) .. " XP") }
  if info.mobXP and info.mobXP > 0 then l1[#l1 + 1] = L["monsters: "] .. FormatNumber(info.mobXP) .. " XP" end
  l1[#l1 + 1] = "~" .. FormatTime(info.total) .. " · ~" ..
    (info.total > 0 and FormatNumber(info.xp / info.total * 3600) or "0") .. " XP/h"
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
  if info.skipped > 0 then l3[#l3 + 1] = Plural(info.skipped, L["quest"]) .. L[" ignored"] end
  local nEx = 0
  for _ in pairs(Settings().excluded) do nEx = nEx + 1 end
  if nEx > 0 then l3[#l3 + 1] = Plural(nEx, L["quest"]) .. L[" removed by you"] end
  local head = { table.concat(l1, sep), table.concat(l2, sep), table.concat(l3, sep) }
  local items = { { text = Color("aaaaaa", table.concat(head, "\n")) } }

  -- Split the plan into sections per zone, in route order.
  local net, plevel = info.net, info.plevel
  local segments, current = {}, nil
  for i = 2, #route do
    local s = route[i]
    local zone = s.p.instance or AreaName(s.p.area) or s.p.zoneName or "?"
    if not current or current.zone ~= zone then
      current = { zone = zone, steps = {}, xp = 0 }
      segments[#segments + 1] = current
    end
    current.steps[#current.steps + 1] = { s = s, prev = route[i - 1], i = i }
    if s.kind == "turnin" or s.kind == "obj" then current.xp = current.xp + (s.xp or 0) end
  end

  local n = 0
  for si, seg in ipairs(segments) do
    local last = seg.steps[#seg.steps].s
    local label = string.format("%d. %s - %s", si, seg.zone, Plural(#seg.steps, L["step"]))
    if seg.xp > 0 then label = label .. " - +" .. FormatNumber(seg.xp) .. " XP" end
    label = label .. L[" - until ~"] .. FormatTime(last.at)
    local segItems = {}
    for _, st in ipairs(seg.steps) do
      local s, task = st.s, st.s.task
      n = n + 1
      local function nameOnly(t) return t and (t:match("^(.-) %- ") or t) or nil end
      -- action: what to do and where (light gray); figures: XP, time, notes (each in its color).
      local D = K.DESC
      local kindLabel, action, pinLabel, spotLine
      local xp, notes = nil, {}
      local function add(hex, s) notes[#notes + 1] = Color(hex, s) end
      if s.kind == "bind" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\Innkeeper:14:14|t" .. Color("ffb060", L["[Innkeeper]"])
        action = L["Talk to "] .. (task.npc or "?") .. L[" and choose \"Make this inn your home\""] .. K.DESC_SEP .. PointText(s.p)
        pinLabel = L["bind the hearthstone"]
      elseif s.kind == "hearth" then
        kindLabel = "|TInterface\\Icons\\INV_Misc_Rune_01:14:14|t" .. Color("ffb060", L["[Hearthstone]"])
        action = L["Use the hearthstone · saves ~"] .. FormatTime(s.gain or 0)
        pinLabel = L["hearthstone"]
      elseif s.kind == "travel" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t" .. Color("80c0ff", L["[Transport]"])
        action = (task.mode == "vol" and (L["Talk to the flight master at "] .. (task.from or "?") .. L[", destination "] .. (task.dest or "?"))
          or (L["Board at "] .. (task.from or "?") .. L[" for "] .. (task.dest or "?"))) .. K.DESC_SEP .. PointText(s.p)
        pinLabel = L["transport"]
      elseif s.kind == "fm" then
        kindLabel = "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t" .. Color("c890ff", L["[Flight master]"])
        action = L["Talk to "] .. (task.npc or "?") .. L[" to activate the flight path"] .. K.DESC_SEP .. PointText(s.p)
        pinLabel = L["activate the flight master"]
      elseif s.escort then
        kindLabel = K.ESCORT_ICON .. Color("ffb060", L["[Escort]"])
        action = L["Stay close to "] .. CP.EscortNpc(task) ..
          (s.kind == "turnin" and (L[", then turn in to "] .. (nameOnly(TurnInText(task.id)) or "?")) or "") ..
          K.DESC_SEP .. PointText(s.p)
        if s.kind == "turnin" then xp = Geo.XPText(task.xp) end
        add(D.warn, "~" .. FormatTime(s.work or 0) .. L[", do not interrupt"])
        pinLabel = s.kind == "obj" and s.r and s.r.tg.name or L["turn in the quest"]
      elseif s.kind == "take" then
        kindLabel = Color("80c0ff", L["[Pick up]"])
        action = L["Pick up from "] .. (nameOnly(task.starter) or "?") .. K.DESC_SEP .. PointText(s.p)
        if Geo.IsEscort(task.id) then add(D.warn, L["escort: starts right after"]) end
        if task.reqLevel then add(D.warn, string.format(L["level %d required"], task.reqLevel)) end
        if task.dep then add(D.chain, string.format(L["follow-up of \"%s\""], task.dep.title or "?")) end
        pinLabel = L["pick up the quest"]
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
        pinLabel = s.r.tg.name
      else
        kindLabel = Color("40ff40", L["[Turn in]"])
        action = L["Turn in to "] .. (nameOnly(TurnInText(task.id)) or "?") .. K.DESC_SEP .. PointText(s.p)
        xp = Geo.XPText(task.xp)
        if s.quick then add(D.good, L["quick win: added on the way"])
        elseif task.quick then add(D.good, L["ready to turn in"]) end
        pinLabel = L["turn in the quest"]
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
        Geo.DescLine(xp, Color(D.meta, "[" .. FormatTime(s.at) .. "]"), unpack(notes))
      if spotLine then text = text .. Geo.DescLine(spotLine) end
      local way = s.kind ~= "hearth" and RouteText(st.prev.p, s.p, net, plevel) or nil
      if way and way ~= L["right here"] then text = text .. Geo.DescLine(Color("ffffff", L["Route: "]) .. way) end
      if task.tags and task.stops and s == task.stops[1] then
        text = text .. Geo.DescLine("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12:12|t " .. Color(D.prio, L["Priority: "] .. table.concat(task.tags, K.DESC_SEP)))
      end
      local lvs = info.levels
      if lvs and st.i and lvs[st.i] and lvs[st.i - 1] and lvs[st.i] > lvs[st.i - 1] then
        text = text .. Geo.DescLine(Color(D.good, L["---- level "] .. lvs[st.i] .. L[" reached (~"] .. FormatTime(s.at) .. ") ----"))
      end
      if #State.xpQuery == 0 or MatchWords(Normalize(text), State.xpQuery) then
        -- Only button: remove the quest from the Roadbook. Tracking and the pin follow the
        -- floating Objective button (exclusive focus).
        local qid, step = task.id, s
        local exclude
        if CP.StepDone(step) then
          -- step done: checked, no button
          text = text:gsub("^  (%d+%. )", "  %1|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t" .. Color("40ff40", L["[Done] "]), 1)
        elseif qid then
          exclude = { text = L["Remove from the Roadbook"], fn = function() CP.AskExclude(step) end }
        end
        segItems[#segItems + 1] = { text = text, b3 = exclude, questID = task.id }
      end
    end
    if #segItems > 0 then
      items[#items + 1] = { header = true, kind = "step", key = "seg" .. si, label = label }
      for _, it in ipairs(segItems) do items[#items + 1] = it end
    end
  end
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
    c.search = CreateSearchBox(c, 140, onSearch)
    c.search:SetPoint("TOPLEFT", x + 12, -71)
    x = x + 12 + 140
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
    RenderXP()

  else
    local a = Analyze()
    RenderTodo(a)
  end
end

-- Shared with the next files.
ns.AddStateFilters, ns.CreateFilterPanel, ns.LOW_LEVEL_TOGGLE, ns.Refresh, ns.SelectTab, ns.StopNearTicker = AddStateFilters, CreateFilterPanel, LOW_LEVEL_TOGGLE, Refresh, SelectTab, StopNearTicker
