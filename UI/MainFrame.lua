-- Forever Quest Planner: main window, export to file, minimap button.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AddFilterRow, FilterBox = ns.AddFilterRow, ns.FilterBox
local AddStateFilters, CONTENT_WIDTH, CP, CreateFilterPanel, CreateScrollPanel, Geo = ns.AddStateFilters, ns.CONTENT_WIDTH, ns.CP, ns.CreateFilterPanel, ns.CreateScrollPanel, ns.Geo
local K, L, LOW_LEVEL_TOGGLE, ParseQuery, Print, QDB, Refresh = ns.K, ns.L, ns.LOW_LEVEL_TOGGLE, ns.ParseQuery, ns.Print, ns.QDB, ns.Refresh

K.GOAL_LEVEL_SPAN = 10 -- "Reach level" goal: at most this many levels above the current one
local SelectTab, Settings, Snapshot, State, StopNearTicker, expandedCategories = ns.SelectTab, ns.Settings, ns.Snapshot, ns.State, ns.StopNearTicker, ns.expandedCategories
local journalStates, nearStates, panels, tabButtons = ns.journalStates, ns.nearStates, ns.panels, ns.tabButtons

-- Roadbook tab ("auto" or "custom"), options at the top:
--   auto:                       [  search  ]                     [Map] [Start|Pause] [Delete]
--         +-------------------------------------------------------------------------+
--         | Goal: (o) Session of [2 h v]   (o) Reach level [25 v]          [Generate] |
--         +-------------------------------------------------------------------------+
--   custom:                     [  search  ]                     [Map] [Start|Pause] [Delete]
-- (no goal box for the custom Roadbook: it is computed at each change of its list)
-- The buttons act on the Roadbook of the tab; "Start" also makes it the active one (shown by a light
-- in the tab title, Geo.AddTabLed).
local function CreateRoadbookPanel(f, kind)
  local custom = kind == "custom"
  local xp = CreateFilterPanel(f, {}, function() return nil end, function() end, function(text)
    if custom then State.customQuery = ParseQuery(text) else State.xpQuery = ParseQuery(text) end
    Refresh()
  end)
  local function Tooltip(widget, title, text)
    -- Hooked: the dropdowns keep their own hover scripts.
    widget:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(title)
      GameTooltip:AddLine(type(text) == "function" and text() or text, 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end
  -- Goal box (auto), the filter box of the other tabs: one row under the search box, the whole width
  -- of the window; the radio buttons, captions and "Generate" are created in it.
  local host, rowY = xp, 0
  if not custom then
    host = FilterBox(xp)
    rowY = AddFilterRow(xp)
  end
  -- Radio button and caption: x from the left of the box, y of the middle of their row.
  local function Radio(x, y, label, onClick)
    local okR, b = pcall(CreateFrame, "CheckButton", nil, host, "UIRadioButtonTemplate")
    if not okR or not b then b = CreateFrame("CheckButton", nil, host, "UICheckButtonTemplate") end
    b:SetSize(18, 18)
    b:SetPoint("LEFT", host, "TOPLEFT", x, y)
    b.label = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", b, "RIGHT", 2, 0)
    b.label:SetText(label)
    b:SetScript("OnClick", onClick)
    return b, x + 18 + 2 + (b.label:GetStringWidth() or 60)
  end
  local function Caption(x, y, text)
    local cap = host:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cap:SetPoint("LEFT", host, "TOPLEFT", x, y)
    cap:SetText(text)
    return cap, x + (cap:GetStringWidth() or 40) + 8
  end
  local function Button(label, w, onClick)
    local b = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
  end

  -- Right of the search line: the actions on the Roadbook of the tab.
  local delete = CreateFrame("Button", nil, xp, "UIPanelButtonTemplate")
  delete:SetSize(80, 22)
  delete:SetText(L["Delete"])
  delete:SetScript("OnClick", function() CP.Delete(kind) end)
  delete:SetPoint("TOPRIGHT", -12, -70)
  Tooltip(delete, L["Delete"], custom and L["Deletes the custom Roadbook: its steps, their progress and its quest list."]
    or L["Deletes the automatic Roadbook: its steps and their progress."])
  local startB = CreateFrame("Button", nil, xp, "UIPanelButtonTemplate")
  startB:SetSize(80, 22)
  startB:SetText(L["Start"])
  startB:SetScript("OnClick", function()
    if Geo.ActiveKind() == kind and Geo.Tracking() then CP.Pause(kind) else CP.Start(kind) end
  end)
  startB:SetPoint("RIGHT", delete, "LEFT", -6, 0)
  Tooltip(startB, L["Start / Pause"], L["Start: this Roadbook becomes the active one and the Objective button follows it. Pause: the tracking stops, the progress is kept."])
  -- Preview on OpenMap's map (RoadbookMap.lua): lit while it is shown.
  local mapB = CreateFrame("Button", nil, xp, "UIPanelButtonTemplate")
  mapB:SetSize(80, 22)
  mapB:SetText(L["Map"])
  mapB:SetScript("OnClick", function() Geo.MapPreview(kind) end)
  mapB:SetPoint("RIGHT", startB, "LEFT", -6, 0)
  Tooltip(mapB, L["Map"], L["Shows this Roadbook on the world map: its steps numbered in order and its route; your map pins are hidden meanwhile. Closing the map gives it back as it was. A click on a step of the list centers the map on it."])
  local function UpdateMapButton()
    local o = Geo.MapOwner()
    if o and o.mode == "preview" and o.kind == kind then mapB:LockHighlight() else mapB:UnlockHighlight() end
  end
  Geo.mapButtons = Geo.mapButtons or {}
  Geo.mapButtons[kind] = UpdateMapButton
  local generate
  if not custom then -- the custom Roadbook is computed at each change of its list
    generate = Button(L["Generate"], 80, function() CP.Generate(kind) end)
    generate:SetPoint("RIGHT", host, "TOPRIGHT", -8, rowY) -- right end of the goal box
    Tooltip(generate, L["Generate"], L["Computes a new Roadbook with the chosen goal; the current one is replaced, after confirmation. Click \"Start\" to follow the new one."])
  end

  -- Waiting animation while the Roadbook of the tab is computed (Geo.RenderBusy shows it).
  local busy = CreateFrame("Frame", nil, xp)
  busy:SetSize(400, 120)
  busy:SetPoint("TOP", xp.scroll, "TOP", 10, -70)
  busy:Hide()
  local busyText = busy:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  busyText:SetPoint("TOP", 0, 0)
  busyText:SetText(L["Computing the Roadbook"])
  -- A wave running along a row of round gold lights.
  local DOTS, GAP = 5, 18
  local dots = {}
  for i = 1, DOTS do
    local d = busy:CreateTexture(nil, "ARTWORK")
    d:SetTexture("Interface\\Common\\Indicator-Yellow")
    d:SetPoint("CENTER", busyText, "BOTTOM", (i - (DOTS + 1) / 2) * GAP, -20)
    dots[i] = d
  end
  local busySub = busy:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  busySub:SetPoint("TOP", busyText, "BOTTOM", 0, -40)
  local tick = 0
  busy:SetScript("OnUpdate", function(_, elapsed)
    local t = GetTime and GetTime() or 0
    for i, d in ipairs(dots) do
      local wave = math.max(0, math.sin(t * 5 - i * 0.7)) -- 0..1, moving from left to right
      d:SetAlpha(0.25 + 0.75 * wave)
      local size = 10 + 6 * wave
      d:SetSize(size, size)
    end
    tick = tick + elapsed
    if tick < 0.5 then return end
    tick = 0
    local sec = math.floor(t - (Geo.computeStart or t))
    busySub:SetText(string.format(L["%d s (up to %d s) · you can keep playing meanwhile"], sec, K.PLAN_TIME))
  end)
  busy:SetScript("OnShow", function() tick = 1 end) -- elapsed time set at once
  xp.busy = busy

  local updateLeft = custom and function() end or Geo.CreateGoalLine(host, rowY, Radio, Caption, Tooltip)

  function xp.UpdateMode()
    updateLeft()
    -- Buttons: state of the Roadbook of the tab.
    local following = Geo.ActiveKind() == kind and Geo.Tracking()
    startB:SetText(following and L["Pause"] or L["Start"])
    -- A finished Roadbook can only be extended (quests added), generated again or deleted.
    startB:SetEnabled(Geo.computing ~= kind and (following or (Geo.HasRoadbook(kind) and not Geo.IsFinished(kind))))
    mapB:SetEnabled(Geo.computing ~= kind and Geo.HasRoadbook(kind))
    UpdateMapButton()
    delete:SetEnabled(Geo.computing ~= kind and (Geo.HasRoadbook(kind) or (custom and #Geo.CustomRec().list > 0)))
    if generate then generate:SetEnabled(Geo.computing == nil) end
  end
  return xp
end

-- Goal of the automatic Roadbook on one row of its box (y: middle of the row), one radio button per
-- dropdown; returns its update function.
function Geo.CreateGoalLine(box, y, Radio, Caption, Tooltip)
  local _, gx = Caption(10, y, L["Goal:"])
  local function GoalTime()
    local g = State.xpGoal
    return Settings().goalTime or (g.kind == "time" and g.value) or 7200
  end
  local function LevelRange()
    local lo = UnitLevel("player") + 1
    return lo, math.max(lo, math.min(Geo.MaxLevel(), UnitLevel("player") + K.GOAL_LEVEL_SPAN))
  end
  local function GoalLevel()
    local g = State.xpGoal
    local lo, hi = LevelRange()
    local v = Settings().goalLevel or (g.kind == "level" and g.value) or lo
    return math.min(math.max(v, lo), hi)
  end
  local timeRadio, tx = Radio(gx, y, L["Session of"], function() CP.SetGoal("time", GoalTime()) end)
  Tooltip(timeRadio, L["For a play session"], L["The route earning the most XP within this time."])
  -- Each dropdown right after its label.
  local TIMES = { { key = 3600, label = "1 h" }, { key = 7200, label = "2 h" }, { key = 10800, label = "3 h" },
    { key = 14400, label = "4 h" } }
  local timeDD = Geo.Dropdown(box, 60, function() return TIMES end,
    function(v) return GoalTime() == v end, function(v) CP.SetGoal("time", v) end)
  timeDD:SetPoint("LEFT", box, "TOPLEFT", tx + 4, y)
  Tooltip(timeDD, L["For a play session"], L["The route earning the most XP within this time."])
  local levelRadio, lx = Radio(tx + 4 + 60 + 26, y, L["Reach level"], function() CP.SetGoal("level", GoalLevel()) end)
  Tooltip(levelRadio, L["To reach the level"], L["The fastest route to this level (at most 10 levels above yours)."])
  -- Levels from the current level + 1 to K.GOAL_LEVEL_SPAN levels above (at most max level).
  local levelDD = Geo.Dropdown(box, 60, function()
    local lo, hi = LevelRange()
    local list = {}
    for v = lo, hi do list[#list + 1] = { key = v, label = tostring(v) } end
    return list
  end, function(v) return GoalLevel() == v end, function(v) CP.SetGoal("level", v) end)
  levelDD:SetPoint("LEFT", box, "TOPLEFT", lx + 4, y)
  Tooltip(levelDD, L["To reach the level"], L["The fastest route to this level (at most 10 levels above yours)."])

  -- Update function.
  return function()
    -- Level goal no longer above the current level: the next level.
    local g = State.xpGoal
    if g.kind == "level" and g.value ~= GoalLevel() then
      State.xpGoal = { kind = "level", value = GoalLevel() }
      Settings().goal = { kind = "level", value = State.xpGoal.value }
    end
    timeRadio:SetChecked(State.xpGoal.kind == "time")
    levelRadio:SetChecked(State.xpGoal.kind == "level")
    Geo.DropdownSync(timeDD)
    Geo.DropdownSync(levelDD)
  end
end

-- Green light in the title of the tab of the active Roadbook (the one the Objective button follows;
-- it changes with "Start"): it pulses while the Roadbook is followed, steady while paused.
K.TAB_LED_ROOM = "      " -- spaces before the title of the Roadbook tabs, under the light
K.TAB_EDGE = 4 -- width of the visible left border of a tab
Geo.tabLeds = {}
function Geo.AddTabLed(tab, kind)
  local led = CreateFrame("Frame", nil, tab)
  led:SetSize(12, 12)
  led:SetFrameLevel(tab:GetFrameLevel() + 2)
  local fs = tab.GetFontString and tab:GetFontString()
  if fs then led:SetPoint("LEFT", fs, "LEFT", 1, 0) else led:SetPoint("LEFT", tab, "LEFT", 10, 0) end
  local path = "Interface\\Common\\Indicator-Green"
  local dot = led:CreateTexture(nil, "ARTWORK")
  dot:SetAllPoints()
  if dot:SetTexture(path) == false then
    path = "Interface\\Common\\Indicator-Yellow"
    dot:SetTexture(path)
  end
  -- Halo around the light (additive), its brightness follows the pulse.
  local glow = led:CreateTexture(nil, "OVERLAY")
  glow:SetPoint("CENTER")
  glow:SetSize(22, 22)
  glow:SetTexture(path)
  glow:SetBlendMode("ADD")
  led:SetScript("OnUpdate", function()
    if Geo.Tracking() then
      local wave = (math.sin((GetTime and GetTime() or 0) * 3) + 1) / 2 -- 0..1
      dot:SetAlpha(0.6 + 0.4 * wave)
      glow:SetAlpha(0.15 + 0.6 * wave)
    else
      dot:SetAlpha(1)
      glow:SetAlpha(0.2)
    end
  end)
  led:Hide()
  tab:HookScript("OnEnter", function(self)
    if Geo.ActiveKind() ~= kind then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(L["Active Roadbook"])
    GameTooltip:AddLine(L["The active Roadbook is the one the Objective button follows; \"Start\" on the other Roadbook makes it the active one."], 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  tab:HookScript("OnLeave", function() GameTooltip:Hide() end)
  led.tab = tab
  Geo.tabLeds[kind] = led
  led:SetShown(Geo.ActiveKind() == kind)
end

-- Light centered between the left border of its tab and the start of the title (after the spaces).
function Geo.PlaceTabLed(led)
  local tab = led.tab
  local fs = tab.GetFontString and tab:GetFontString()
  local tl, fx = tab:GetLeft(), fs and fs:GetCenter()
  if not (tl and fx) then return end
  if not led.roomW then
    -- Width of the spaces: the same text with and without them, in the font of the title.
    local probe = tab:CreateFontString(nil, "OVERLAY")
    local font, size, flags = fs:GetFont()
    if font then probe:SetFont(font, size, flags) else probe:SetFontObject(GameFontNormalSmall) end
    probe:SetText(K.TAB_LED_ROOM .. "x")
    local with = probe:GetStringWidth() or 0
    probe:SetText("x")
    led.roomW = math.max(0, with - (probe:GetStringWidth() or 0))
    probe:Hide()
  end
  local textLeft = fx - (fs:GetStringWidth() or 0) / 2 -- the text is centered in the tab
  local titleX = textLeft - tl + led.roomW              -- start of the title, from the left of the tab
  -- Anchored on the title: same height as the text (it moves on the selected tab).
  led:ClearAllPoints()
  led:SetPoint("CENTER", fs, "CENTER", (K.TAB_EDGE + titleX) / 2 - (fx - tl), 0)
end

-- Light on the tab of the active Roadbook (called by Refresh); only that tab keeps the spaces of
-- the light before its title.
function Geo.UpdateTabLeds()
  local active = Geo.ActiveKind()
  for kind, led in pairs(Geo.tabLeds) do
    led:SetShown(kind == active)
    local tab = led.tab
    local text = (kind == active and K.TAB_LED_ROOM or "") .. tab.ledTitle
    if tab:GetText() ~= text then
      tab:SetText(text)
      if tab.isTopTab and PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 12) end
      C_Timer.After(0, function() Geo.PlaceTabLed(led) end) -- once the tab has its new width
    end
    if kind == active then Geo.PlaceTabLed(led) end
  end
end

local function CreateMainFrame()
  State.currentTab = Settings().lastTab or State.currentTab
  local f = CreateFrame("Frame", "ForeverQuestPlannerFrame", UIParent, "BasicFrameTemplateWithInset")
  State.mainFrame = f
  f:SetSize(820, 570)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()

  -- Background: darkened parchment, quest-book style, with a slight downward gradient.
  f.art = f:CreateTexture(nil, "BACKGROUND", nil, 2)
  f.art:SetPoint("TOPLEFT", 6, -24)
  f.art:SetPoint("BOTTOMRIGHT", -6, 6)
  f.art:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal")
  f.art:SetVertexColor(0.42, 0.34, 0.26)
  f.shade = f:CreateTexture(nil, "BACKGROUND", nil, 3)
  f.shade:SetAllPoints(f.art)
  f.shade:SetColorTexture(0, 0, 0, 1)
  if f.shade.SetGradient and CreateColor then
    pcall(f.shade.SetGradient, f.shade, "VERTICAL", CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0.15))
  else
    f.shade:SetAlpha(0.35)
  end

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.title:SetPoint("TOP", 0, -5)
  f.title:SetText("Forever Quest Planner")
  Geo.AddVersionFooter(f)

  local tabs = {
    { key = "xp", label = L["Auto Roadbook"] },
    { key = "custom", label = L["Custom Roadbook"] },
    { key = "near", label = L["Around me"] },
    { key = "groups", label = L["Quest log"] },
    { key = "avail", label = L["Available"] },
  }
  -- Game tabs if the client provides the template, otherwise regular buttons.
  local tabTemplate
  for _, tpl in ipairs({ "PanelTopTabButtonTemplate", "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate" }) do
    local ok, probe = pcall(CreateFrame, "Button", nil, f, tpl)
    if ok and probe then
      probe:Hide()
      tabTemplate = tpl
      break
    end
  end
  f.Tabs = {}
  local prev
  for i, t in ipairs(tabs) do
    local b
    -- Roadbook tabs: spaces before the title of the active one, room for its light (Geo.UpdateTabLeds).
    local kind = (t.key == "xp" and "auto") or (t.key == "custom" and "custom") or nil
    if tabTemplate then
      b = CreateFrame("Button", "ForeverQuestPlannerFrameTab" .. i, f, tabTemplate)
      b:SetID(i)
      b:SetText(t.label)
      b.isTopTab = true
      if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, b, 12) end
      if tabTemplate == "PanelTopTabButtonTemplate" then
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", 14, -26) end
      else
        -- "old-style" tabs, attached under the window
        if prev then b:SetPoint("LEFT", prev, "RIGHT", -14, 0) else b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 10, 2) end
      end
    else
      b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
      b:SetSize(112, 24)
      if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -30) end
      b:SetText(t.label)
    end
    b:SetScript("OnClick", function() SelectTab(t.key) end)
    if kind then
      b.ledTitle = t.label
      Geo.AddTabLed(b, kind)
    end
    b.tabIndex = i
    tabButtons[t.key] = b
    f.Tabs[i] = b
    prev = b
  end
  f.usesTabs = tabTemplate ~= nil
  if f.usesTabs and PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, f, #tabs) end

  -- Gear icon: opens / closes the settings (back to the previous tab).
  local gear = CreateFrame("Button", nil, f)
  gear:SetSize(18, 18)
  -- Small golden gear, vertically centered on the tab row, right after the last tab.
  gear:SetPoint("BOTTOMLEFT", f.Tabs[#f.Tabs], "BOTTOMRIGHT", 10, -1) -- sitting on the tab text line
  local gearPath = "Interface\\Buttons\\UI-OptionsButton"
  local gearTex = gear:CreateTexture(nil, "ARTWORK")
  gearTex:SetAllPoints()
  if gearTex:SetTexture(gearPath) == false then
    gearPath = "Interface\\Icons\\INV_Misc_Gear_01"
    gearTex:SetTexture(gearPath)
  end
  gear:SetScript("OnMouseDown", function() gearTex:SetVertexColor(0.7, 0.7, 0.7) end)
  gear:SetScript("OnMouseUp", function() gearTex:SetVertexColor(1, 1, 1) end)
  local glow = gear:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetTexture(gearPath)
  glow:SetBlendMode("ADD")
  glow:SetAlpha(0.5)
  gear:SetScript("OnClick", function() Geo.ToggleSettings() end)
  gear:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(L["Roadbook settings"])
    GameTooltip:AddLine(L["Quest priorities, look-ahead, time estimates."], 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  gear:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- "Export" tab: selected, read-only text area.
  local eb = CreateFrame("EditBox", nil, f)
  eb:SetMultiLine(true)
  eb:SetMaxLetters(0)
  eb:SetAutoFocus(false)
  eb:SetFontObject(ChatFontNormal)
  eb:SetWidth(CONTENT_WIDTH)
  eb:SetScript("OnEscapePressed", function() f:Hide() end)
  eb:SetScript("OnTextChanged", function(self, userInput)
    if userInput then
      self:SetText(self.fullText or "")
      self:HighlightText()
    end
  end)
  eb:SetScript("OnMouseUp", function(self) self:HighlightText() end)
  local exportPanel = CreateFrame("Frame", nil, f)
  exportPanel:SetAllPoints(f)
  local back = CreateFrame("Button", nil, exportPanel, "UIPanelButtonTemplate")
  back:SetSize(150, 22)
  back:SetPoint("TOPLEFT", 12, -70)
  back:SetText(L["< Back to the quest log"])
  back:SetScript("OnClick", function() SelectTab("groups") end)
  local hint = exportPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("LEFT", back, "RIGHT", 12, 0)
  hint:SetText(L["Text already selected: Ctrl+C to copy, Escape to close."])
  exportPanel.scroll = CreateScrollPanel(exportPanel, eb, -98)
  panels.export = exportPanel

  panels.groups = CreateFilterPanel(f, {}, function() return nil end, function() end, function(text)
    State.todoQuery = ParseQuery(text)
    Refresh()
  end)
  AddStateFilters(panels.groups, { turnin = true, inprogress = true, watched = true, pinned = true, abandon = true, custom = true }, journalStates)
  local exportButton = CreateFrame("Button", nil, panels.groups, "UIPanelButtonTemplate")
  exportButton:SetSize(150, 22)
  exportButton:SetPoint("TOPRIGHT", -12, -70)
  exportButton:SetText(L["Export"])
  exportButton:SetScript("OnClick", function() SelectTab("export") end)
  local questCount = panels.groups:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  questCount:SetPoint("RIGHT", exportButton, "LEFT", -12, 0)
  panels.groups.questCount = questCount

  panels.avail = CreateFilterPanel(f, {
    { key = "all", label = L["All"] },
    { key = "zone", label = L["Current zone"] },
    { key = "dungeon", label = L["Dungeons"] },
    { key = "pvp", label = L["PvP"] },
    { key = "class", label = L["Class & professions"] },
    { key = "custom", label = L["Custom Roadbook"] },
  }, function() return State.availFilter end, function(v)
    State.availFilter = v
    Settings().availFilter = v
  end, function(text)
    State.availQuery = ParseQuery(text)
    Refresh()
  end, LOW_LEVEL_TOGGLE, L["Quests:"])

  panels.near = CreateFilterPanel(f, {
    { key = 200, label = "200 m" },
    { key = 500, label = "500 m" },
    { key = 1500, label = "1500 m" },
    { key = "zone", label = L["Current zone"] },
  }, function() return State.nearRadius end, function(v)
    State.nearRadius = v
    Settings().nearRadius = v
  end, function(text)
    State.nearQuery = ParseQuery(text)
    Refresh()
  end, LOW_LEVEL_TOGGLE, L["Radius:"])
  AddStateFilters(panels.near, { turnin = true, inprogress = true, watched = true, pinned = true, available = true, custom = true }, nearStates)
  panels.xp = CreateRoadbookPanel(f, "auto")
  panels.custom = CreateRoadbookPanel(f, "custom")

  f:SetScript("OnShow", function()
    -- Same sound as opening the game's quest log.
    if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_OPEN) or 844) end
    for k in pairs(expandedCategories) do expandedCategories[k] = nil end
    Settings().expanded = nil
    SelectTab(State.currentTab)
  end)
  f:SetScript("OnHide", function()
    StopNearTicker()
    Geo.HideRowTooltip()
    if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_CLOSE) or 845) end
  end)
  tinsert(UISpecialFrames, "ForeverQuestPlannerFrame")
end

local function ToggleMainFrame(tab)
  if not State.mainFrame then CreateMainFrame() end
  if tab then State.currentTab = tab end
  if State.mainFrame:IsShown() then
    if tab then SelectTab(State.currentTab) else State.mainFrame:Hide() end
  else
    State.mainFrame:Show() -- OnShow selects the current tab
  end
end
CP.OpenWindow = ToggleMainFrame

---------------------------------------------------------------------------
-- Export to file: capture + UI reload
---------------------------------------------------------------------------
local function ExportAndSave()
  if InCombatLockdown() then
    Print(L["Not possible in combat, try again once out of combat."])
    return
  end
  local count = Snapshot()
  Print(count .. L[" quests exported, reloading the UI to write the file…"])
  ReloadUI()
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------

local function UpdateButtonPosition()
  local angle = math.rad(Settings().minimapAngle or 200)
  local radius = (Minimap:GetWidth() / 2) + 10
  State.minimapButton:ClearAllPoints()
  State.minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  cx, cy = cx / scale, cy / scale
  Settings().minimapAngle = math.deg(math.atan2(cy - my, cx - mx)) % 360
  UpdateButtonPosition()
end

local function CreateMinimapButton()
  if State.minimapButton or not Minimap then return end

  local b = CreateFrame("Button", "ForeverQuestPlannerMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER", 0, 1)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(18, 18)
  icon:SetPoint("CENTER", 0, 1)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      Geo.ToggleSettings()
    elseif State.mainFrame and State.mainFrame:IsShown() then
      State.mainFrame:Hide()
    else
      ToggleMainFrame(Geo.TabOf(Geo.ActiveKind())) -- always opens on the active Roadbook's tab
    end
  end)
  b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddDoubleLine("Forever Quest Planner", "v" .. Geo.Version(), 1, 0.82, 0, 0.6, 0.6, 0.6)
    GameTooltip:AddLine(L["|cffffff00Click|r: active Roadbook / close the window"], 1, 1, 1)
    GameTooltip:AddLine(L["|cffffff00Right-click|r: settings"], 1, 1, 1)
    GameTooltip:AddLine(L["|cffffff00Drag|r: move the icon"], 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  State.minimapButton = b
  UpdateButtonPosition()
  if Settings().hideMinimap then b:Hide() end
end

-- Shared with the next files.
ns.CreateMinimapButton, ns.ExportAndSave, ns.ToggleMainFrame = CreateMinimapButton, ExportAndSave, ToggleMainFrame
