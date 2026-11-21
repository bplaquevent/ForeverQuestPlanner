-- Forever Quest Planner: main window, export to file, minimap button.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local AddStateFilters, CONTENT_WIDTH, CP, CreateFilterPanel, CreateScrollPanel, Geo = ns.AddStateFilters, ns.CONTENT_WIDTH, ns.CP, ns.CreateFilterPanel, ns.CreateScrollPanel, ns.Geo
local L, LOW_LEVEL_TOGGLE, ParseQuery, Print, QDB, Refresh = ns.L, ns.LOW_LEVEL_TOGGLE, ns.ParseQuery, ns.Print, ns.QDB, ns.Refresh
local SelectTab, Settings, Snapshot, State, StopNearTicker, expandedCategories = ns.SelectTab, ns.Settings, ns.Snapshot, ns.State, ns.StopNearTicker, ns.expandedCategories
local journalStates, nearStates, panels, tabButtons = ns.journalStates, ns.nearStates, ns.panels, ns.tabButtons

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
  f.title:SetText("Forever Quest Planner" .. (QDB.ok and "  (QuestieDB)" or ""))
  Geo.AddVersionFooter(f)

  local tabs = {
    { key = "xp", label = L["Roadbook"] },
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
    if tabTemplate then
      b = CreateFrame("Button", "ForeverQuestPlannerFrameTab" .. i, f, tabTemplate)
      b:SetID(i)
      b:SetText(t.label)
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
    { key = "zone", label = L["Current zone"] },
    { key = "dungeon", label = L["Dungeons"] },
    { key = "pvp", label = L["PvP"] },
    { key = "class", label = L["Class & professions"] },
    { key = "all", label = L["All"] },
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

  panels.xp = CreateFilterPanel(f, {
    { key = 3600, label = "1 h" },
    { key = 7200, label = "2 h" },
    { key = 14400, label = "4 h" },
  }, function() return State.xpHorizon end, function(v)
    if v ~= State.xpHorizon then
      State.xpHorizon = v
      Settings().horizon = v
      CP.Recompute() -- new duration: new Roadbook, same as the "Recalculate" button
    end
  end, function(text)
    State.xpQuery = ParseQuery(text)
    Refresh()
  end, nil, L["Duration:"])
  -- "Start": computes the Roadbook of the selected mode and follows its first step.
  local start = CreateFrame("Button", nil, panels.xp, "UIPanelButtonTemplate")
  start:SetSize(120, 22)
  start:SetPoint("TOPRIGHT", -12, -70) -- same place as "Export" in the Quest log tab
  start:SetText(L["Start"])
  start:SetScript("OnClick", function() CP.Recompute() end)
  start:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(L["Start"])
    GameTooltip:AddLine(L["Computes the Roadbook of the selected mode and follows its first step with the Objective button."], 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  start:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Mode: automatic (best XP for the duration) or custom (your quest list, fastest route).
  local modes, prev = {}, start
  for _, m in ipairs({ { key = "custom", label = L["Custom"] }, { key = "auto", label = L["Automatic"] } }) do
    local okR, b = pcall(CreateFrame, "CheckButton", nil, panels.xp, "UIRadioButtonTemplate")
    if not okR or not b then b = CreateFrame("CheckButton", nil, panels.xp, "UICheckButtonTemplate") end
    b:SetSize(18, 18)
    b.label = panels.xp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetText(m.label)
    b.label:SetPoint("RIGHT", prev, "LEFT", prev == start and -12 or -14, 0)
    b:SetPoint("RIGHT", b.label, "LEFT", -2, 0)
    b:SetScript("OnClick", function() CP.SetMode(m.key) end)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(m.label)
      GameTooltip:AddLine(m.key == "custom" and L["Your own quest list (+ button in the other tabs), done along the fastest route."]
        or L["Quests chosen for the best XP within the duration."], 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    modes[m.key] = b
    prev = b
  end
  -- The duration only applies to the automatic Roadbook.
  function panels.xp.UpdateMode()
    local custom = Geo.CustomMode()
    for k, b in pairs(modes) do b:SetChecked((k == "custom") == custom) end
    for _, b in pairs(panels.xp.buttons) do
      b:SetShown(not custom)
      b.label:SetShown(not custom)
    end
    if panels.xp.caption then panels.xp.caption:SetShown(not custom) end
  end

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
    if button == "RightButton" then Geo.ToggleSettings() else ToggleMainFrame() end
  end)
  b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddDoubleLine("Forever Quest Planner", "v" .. Geo.Version(), 1, 0.82, 0, 0.6, 0.6, 0.6)
    GameTooltip:AddLine(L["|cffffff00Click|r: open / close the window"], 1, 1, 1)
    GameTooltip:AddLine(L["|cffffff00Right-click|r: settings"], 1, 1, 1)
    GameTooltip:AddLine(L["|cffffff00Drag|r: move the icon"], 1, 1, 1)
    GameTooltip:AddLine(QDB.ok and L["QuestieDB: active"] or L["QuestieDB: missing"], 0.6, 0.8, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  State.minimapButton = b
  UpdateButtonPosition()
  if Settings().hideMinimap then b:Hide() end
end

-- Shared with the next files.
ns.CreateMinimapButton, ns.ExportAndSave, ns.ToggleMainFrame = CreateMinimapButton, ExportAndSave, ToggleMainFrame
