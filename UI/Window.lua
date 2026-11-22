-- Forever Quest Planner: Roadbook tab, filters, tab selection, Refresh.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Analyze, AreaName, CP, CharKey, Color, CreateScrollPanel = ns.Analyze, ns.AreaName, ns.CP, ns.CharKey, ns.Color, ns.CreateScrollPanel
local CreateSearchBox, Geo, GeoReady, ICON = ns.CreateSearchBox, ns.Geo, ns.GeoReady, ns.ICON
local GiverText, IsClassMeta, IsProfMeta, QuestMeta = ns.GiverText, ns.IsClassMeta, ns.IsProfMeta, ns.QuestMeta
local IsCompleted, K, L, MatchWords, Normalize = ns.IsCompleted, ns.K, ns.L, ns.MatchWords, ns.Normalize
local PinIcon, Plural, Print, QDB, QGet = ns.PinIcon, ns.Plural, ns.Print, ns.QDB, ns.QGet
local Refresh, RemainingObjectives = ns.Refresh, ns.RemainingObjectives
local RenderAvailable, RenderExport, RenderList, RenderNear, RenderTodo = ns.RenderAvailable, ns.RenderExport, ns.RenderList, ns.RenderNear, ns.RenderTodo
local Settings, ShowMessage, State, StateIcons = ns.Settings, ns.ShowMessage, ns.State, ns.StateIcons
local expandedCategories, panels, tabButtons = ns.expandedCategories, ns.panels, ns.tabButtons

-- Roadbook being computed: the list is emptied and the waiting animation is shown instead.
function Geo.RenderBusy(panel)
  local busy = Geo.computing and true or false
  if panel.busy then panel.busy:SetShown(busy) end
  if busy then
    Geo.PaneHeader(panel.quests, L["Quests"])
    RenderList(panel.quests, "xp", {})
  end
  return busy
end

-- Category of a quest of the list, as in the Quest log tab (byLog: category of the quests of the log,
-- from Analyze): "done" (turned in), "turnin", "zone" (name), "dungeon" (name), "later" (level too high).
-- A quest not in the log: its dungeon, Professions / Class, the zone of its quest giver.
function Geo.ListCategory(it, byLog, plevel)
  if IsCompleted(it.id) then return "done" end
  local c = byLog[it.id]
  if c then return c.kind, c.name end
  local sort = QGet(QDB.Quest, it.id, "zoneOrSort") or 0
  local dg = sort > 0 and QDB.dungeonOf[sort]
  if dg then return "dungeon", AreaName(dg) or L["Dungeon"] end
  local m = QuestMeta(it.id)
  local isProf = m and IsProfMeta(m)
  local level = it.level or Geo.QuestLevelOf(it.id) or 0
  if level > plevel + 3 and not isProf then return "later" end
  if isProf then return "zone", L["Professions"] end
  if m and IsClassMeta(m) then return "zone", L["Class"] end
  local zone = sort > 0 and AreaName(sort) or nil
  if not zone then
    local _, starterZone = GiverText(QGet(QDB.Quest, it.id, "startedBy"))
    zone = starterZone
  end
  return "zone", zone or L["No zone"]
end

-- Quests of the list, in the categories of the Quest log tab with "Turned in" first: turned in, to
-- turn in, zones (2 quests or more, the biggest first), dungeons, single quests, level too high. In a
-- category: the quests of the log in its order, then the others by level (a dungeon: by level).
-- Without a Roadbook (fz nil), the list as it is; with one, the quests it does not plan show why.
-- One line each with its state; the ones not turned in can be removed (CP.SkipQuest: out of the list,
-- the Roadbook computed again). Returns the number of quests shown and the size of the list.
function Geo.RoadbookQuestItems(items, fz, query)
  local D = K.DESC
  local quests, seen = {}, {}
  local function add(task, quick)
    local id = task and task.id
    if not id or seen[id] then return end
    seen[id] = true
    quests[#quests + 1] = { id = id, title = task.title, level = task.level, quick = quick }
  end
  local route = fz and fz.route or {}
  for i = 2, #route do
    local st = route[i]
    if st.kind == "dungeon" then
      for _, m in ipairs(st.task.members or {}) do add(m.task) end
    else
      add(st.task, st.quick)
    end
  end
  local list, entry, why = Geo.CustomList(), {}, {}
  for _, it in ipairs(list) do entry[it.id] = it end
  for _, u in ipairs((fz and fz.info.unplanned) or Geo.customUnplanned or {}) do why[u.id] = u.reason end
  for _, it in ipairs(list) do
    if not seen[it.id] then
      seen[it.id] = true
      quests[#quests + 1] = { id = it.id, title = it.title, level = it.level, unplanned = fz ~= nil }
    end
  end
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  local logById = {}
  for _, q in ipairs(e and e.quests or {}) do logById[q.id] = q end
  local plevel = UnitLevel("player")
  local lines = {}
  for qi, it in ipairs(quests) do
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
    if not Geo.ForPlayer(it.id) then text = text .. Geo.DescLine(Color(D.bad, L["not for your class or race"])) end
    if it.unplanned then
      text = text .. Geo.DescLine(Color(D.bad, why[it.id] and (L["Cannot be planned: "] .. why[it.id]) or L["not planned yet"]))
    end
    if #query == 0 or MatchWords(Normalize(text), query) then
      local id, title = it.id, it.title
      lines[#lines + 1] = { it = it, qi = qi, item = { text = text, questID = q and id or nil, linkQuest = id,
        b3 = not done and { text = L["Remove"], fn = function() CP.ConfirmSkipQuest({ task = { id = id, title = title } }) end,
          tip = { L["Remove"], L["Removes the quest from the list (with the prerequisites added only for it); the steps to come of the Roadbook are computed again."] } } or nil } }
    end
  end
  if #lines == 0 then return #quests, #list end

  -- Categories of the log (Analyze), and the order of its quests.
  local a = Analyze()
  local byLog, logIndex = {}, {}
  for i, q in ipairs(e and e.quests or {}) do logIndex[q.id] = i end
  for _, q in ipairs(a.turnIn) do byLog[q.id] = { kind = "turnin" } end
  for _, g in ipairs(a.groups) do
    for _, q in ipairs(g.quests) do byLog[q.id] = { kind = "zone", name = g.name } end
  end
  for _, g in ipairs(a.dungeons) do
    for _, q in ipairs(g.quests) do byLog[q.id] = { kind = "dungeon", name = g.name } end
  end
  for _, q in ipairs(a.later) do byLog[q.id] = { kind = "later" } end
  local cats, byKey = {}, {}
  local function cat(kind, name)
    local key = kind .. ":" .. (name or "")
    if not byKey[key] then
      byKey[key] = { kind = kind, name = name, key = key, lines = {} }
      cats[#cats + 1] = byKey[key]
    end
    return byKey[key]
  end
  for _, line in ipairs(lines) do
    local kind, name = Geo.ListCategory(line.it, byLog, plevel)
    table.insert(cat(kind, name).lines, line)
  end
  -- Zones of a single quest: "Doable single quests", as in the log.
  local singles = cat("singles")
  for _, c in ipairs(cats) do
    if c.kind == "zone" and #c.lines < 2 then
      for _, line in ipairs(c.lines) do table.insert(singles.lines, line) end
      c.lines = {}
    end
  end
  local RANK = { done = 1, turnin = 2, zone = 3, dungeon = 4, singles = 5, later = 6 }
  table.sort(cats, function(x, y)
    if RANK[x.kind] ~= RANK[y.kind] then return RANK[x.kind] < RANK[y.kind] end
    if #x.lines ~= #y.lines then return #x.lines > #y.lines end
    return tostring(x.name) < tostring(y.name)
  end)
  local LABEL = { done = L["Turned in"], turnin = L["To turn in"], singles = L["Doable single quests"],
    later = L["Later - level too high"] }
  local following = CP.CurrentFocus() ~= nil
  for _, c in ipairs(cats) do
    if #c.lines > 0 then
      if c.kind == "dungeon" then
        table.sort(c.lines, function(x, y)
          if (x.it.level or 0) ~= (y.it.level or 0) then return (x.it.level or 0) < (y.it.level or 0) end
          return x.qi < y.qi
        end)
      elseif c.kind ~= "done" then -- turned in: in route order
        table.sort(c.lines, function(x, y)
          local lx, ly = logIndex[x.it.id], logIndex[y.it.id]
          if lx and ly then return lx < ly end
          if lx or ly then return lx ~= nil end
          if (x.it.level or 0) ~= (y.it.level or 0) then return (x.it.level or 0) < (y.it.level or 0) end
          return x.qi < y.qi
        end)
      end
      local label
      if c.kind == "zone" then label = Geo.WithLevel(c.name, c.name)
      elseif c.kind == "dungeon" then label = Geo.WithLevel(L["Dungeon: "] .. c.name, c.name)
      else label = LABEL[c.kind] end
      -- Collapsed while the Roadbook is followed (the route matters more).
      items[#items + 1] = { header = true, kind = c.kind == "done" and "info" or c.kind, key = "rbq:" .. c.key,
        open = not following, label = label .. " - " .. Plural(#c.lines, L["quest"]) }
      for _, line in ipairs(c.lines) do items[#items + 1] = line.item end
    end
  end
  return #quests, #list
end

-- Roadbook tab: the quests of the list under a fixed header; the Roadbook's steps are in the panel
-- (RoadbookPanel.lua).
local function RenderXP()
  local panel = panels.xp
  local qp = panel.quests
  if panel.busy then panel.busy:Hide() end
  if panel.UpdateStepsButton then panel.UpdateStepsButton() end
  if not GeoReady() then
    Geo.PaneHeader(qp, L["Quests"])
    ShowMessage(qp, "xp", L["Unable to convert QuestieDB positions to this client's map."])
    return
  end
  if Geo.RenderBusy(panel) then pcall(CP.RefreshButton) return end
  local query = State.xpQuery
  local searching = #query > 0

  -- Saved Roadbook: it changes with the list (and when it is adapted), or with "Generate".
  local fz = Geo.Frozen()
  if fz then pcall(Geo.InjectQuickWins) end

  local qItems = {}
  -- No Roadbook: how to make one (and why the last computation failed).
  if not fz and not searching then
    local last = State.xpGoal.kind == "custom" and Geo.customCache or Geo.planCache
    if last and last.err and not last.route then qItems[#qItems + 1] = { text = Color("ff6060", last.err) } end
    qItems[#qItems + 1] = { text = Color("ffd100", L["No Roadbook. Fill the list with the \"Add\" button (or \"Add all\" on a category) of the Around me, Quest log and Available tabs, and/or let \"Generate\" fill it: for a play session (the most XP within that time) or a level (reached the fastest), the list is completed or trimmed; \"the whole list\" keeps it as it is. The Roadbook then does every quest of the list in the least time, and the Objective button follows it."]) }
  end
  local before = #qItems
  local shown, listSize = Geo.RoadbookQuestItems(qItems, fz, query)
  if #qItems == before and (searching or fz) then
    qItems[#qItems + 1] = { text = searching and L["No quest matches the search."]
      or L["The list is empty: add quests with the \"Add\" button of the other tabs, or choose a session or a level."] }
  end
  -- Quests kept for max level: reward or access only useful at endgame.
  local later = fz and fz.info.later
  if later and #later > 0 then
    local laterItems = {}
    table.sort(later, function(a, b) return (a.level or 0) < (b.level or 0) end)
    for _, e in ipairs(later) do
      local text = "  " .. StateIcons(e.id) .. Geo.QuestTitle(e.title, { id = e.id, level = e.level }) ..
        Geo.DescLine(Color(K.DESC.warn, L["To do at level "] .. Geo.MaxLevel() .. L[": "] .. (e.reason or "?")))
      if not searching or MatchWords(Normalize(text), query) then
        laterItems[#laterItems + 1] = { text = text, questID = e.id }
      end
    end
    if #laterItems > 0 then
      qItems[#qItems + 1] = { header = true, kind = "take", key = "later",
        label = L["For max level - "] .. Plural(#laterItems, L["quest"]) .. L[" (easier and faster at that level)"] }
      for _, it in ipairs(laterItems) do qItems[#qItems + 1] = it end
    end
  end
  if fz and #fz.route <= 1 and not searching then qItems[#qItems + 1] = { text = L["No usable quest found around you."] } end
  Geo.PaneHeader(qp, L["Quests"], Color("aaaaaa", L["Quests of the list: "] .. Plural(shown or 0, L["quest"])),
    (listSize or 0) > 0 and { text = L["Remove all"], fn = function() StaticPopup_Show("FQP_CUSTOM_CLEAR") end } or nil)
  RenderList(qp, "xp", qItems, searching)
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
  { key = "custom", label = L["Roadbook list"], icon = function() return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:16:16|t" end },
}

-- Filter box, under the search box (same frame as the goal box of the automatic Roadbook): one row
-- per kind of filter, the list starts below it.
K.FILTER_BOX_TOP, K.FILTER_ROW_H = -96, 26
local function FilterBox(panel)
  if panel.box then return panel.box end
  local box = CreateFrame("Frame", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
  box:SetPoint("TOPLEFT", 14, K.FILTER_BOX_TOP)
  box:SetPoint("TOPRIGHT", -14, K.FILTER_BOX_TOP)
  Geo.FrameStyle(box, true)
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
