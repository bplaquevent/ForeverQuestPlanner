-- Forever Quest Planner: settings window (Roadbook parameters).
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local CP, Color, Geo, K, L, Plural = ns.CP, ns.Color, ns.Geo, ns.K, ns.L, ns.Plural
local Print, Refresh, Settings, scan = ns.Print, ns.Refresh, ns.Settings, ns.scan

---------------------------------------------------------------------------
-- Settings: Roadbook priority and estimate parameters
---------------------------------------------------------------------------
K.PARAMS = {
  { section = L["Priority bonuses (100 % = as if the quest gave the XP of one more average Roadbook quest)"] },
  { key = "PRIO_CLASS", label = L["Class quest (or chain leading to one)"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_ITEM_SPEC", label = L["Blue reward suited to your spec"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_ITEM_BLUE", label = L["Blue reward, off-spec"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_UPGRADE_SPEC", label = L["Upgrade with the right stats"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_UPGRADE", label = L["Upgrade (item level only)"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_SPELL", label = L["Reward that teaches a skill"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "PRIO_BAG", label = L["Reward: bag"], pct = true, min = 0, max = 1, step = 0.05 },
  { key = "READY_BONUS", label = L["Quest ready to turn in"], pct = true, min = 0, max = 1, step = 0.05 },
  { section = L["Difficulty"] },
  { key = "MAX_LEVEL_GAP", label = L["Max quest level"], unit = L[" lvl"], min = -5, max = 5, step = 1, signed = true },
  { key = "MAX_ELITE_GAP", label = L["Max elite quest level"], unit = L[" lvl"], min = -5, max = 5, step = 1, signed = true },
  { section = L["Time estimates"] },
  { key = "MOB_TIME", label = L["Time per monster"], unit = L[" s"], min = 10, max = 90, step = 5 },
  { key = "ELITE_MOB_TIME", label = L["Time per elite monster"], unit = L[" s"], min = 20, max = 240, step = 5 },
  { key = "KILLS_NO_RATE", label = L["Monsters per item (unknown drop rate)"], unit = "", min = 1, max = 20, step = 1 },
  { key = "DUNGEON_TIME", label = L["Time in a dungeon (custom Roadbook)"], unit = L[" min"], min = 15, max = 180, step = 5 },
}
for _, d in ipairs(K.PARAMS) do
  if d.key then d.default = K[d.key] end
end

-- Applies the saved values (or the defaults).
K.PARAMS_SCALE = 2 -- 2: priorities in share of an average quest (before: share of the level's XP)
function Geo.ApplyParams()
  local st = Settings()
  if st.params and st.paramsScale ~= K.PARAMS_SCALE then
    -- Values saved with the former scale make no sense anymore: back to the defaults.
    for _, k in ipairs({ "PRIO_CLASS", "PRIO_UNLOCK_CLASS", "PRIO_ITEM_SPEC", "PRIO_ITEM_BLUE", "PRIO_UPGRADE_SPEC",
      "PRIO_UPGRADE", "PRIO_SPELL", "PRIO_BAG", "READY_BONUS", "LOOKAHEAD_WEIGHT" }) do st.params[k] = nil end
  end
  st.paramsScale = K.PARAMS_SCALE
  local saved = st.params or {}
  for _, d in ipairs(K.PARAMS) do
    if d.key then
      local v = saved[d.key]
      K[d.key] = (type(v) == "number") and math.min(d.max, math.max(d.min, v)) or d.default
    end
  end
  Geo.paramsVersion = (Geo.paramsVersion or 0) + 1
  Geo.planCache = nil
end

function Geo.SetParam(d, v)
  local st = Settings()
  st.params = st.params or {}
  st.params[d.key] = (math.abs(v - d.default) < 1e-6) and nil or v
  Geo.ApplyParams()
  if d.rescan then scan.dirty = true end
end

function Geo.ParamText(d, v)
  if d.pct then return string.format("%d %%", math.floor(v * 100 + 0.5)) end
  if d.signed then return string.format("%+d", v) .. (d.unit or "") end
  return tostring(v) .. (d.unit or "")
end

-- Bordered group box ("panel") with a title, used to sort the settings by family.
function Geo.SettingsBox(parent, title, x, y, w, h)
  local box = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  box:SetPoint("TOPLEFT", x, y)
  box:SetSize(w, h)
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
  local t = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("TOPLEFT", 10, -8)
  t:SetText(title)
  return box
end

function Geo.SettingsCheck(box, label, x, y, get, set, panel)
  local cb = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
  cb:SetSize(22, 22)
  cb:SetPoint("TOPLEFT", x, y)
  cb.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  cb.label:SetText(label)
  cb:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    if Refresh then Refresh() end
  end)
  panel.updaters[#panel.updaters + 1] = function() cb:SetChecked(get() and true or false) end
  return cb
end

function Geo.SettingsSlider(box, d, x, y, panel)
  local name = "ForeverQuestPlannerParam" .. d.key
  local ok, sl = pcall(CreateFrame, "Slider", name, box, "OptionsSliderTemplate")
  if not ok or not sl then
    sl = CreateFrame("Slider", name, box)
    sl:SetOrientation("HORIZONTAL")
    sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  end
  sl:SetSize(200, 16)
  sl:SetPoint("TOPLEFT", x + 160, y - 6)
  sl:SetMinMaxValues(d.min, d.max)
  sl:SetValueStep(d.step)
  if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
  for _, suffix in ipairs({ "Low", "High", "Text" }) do
    local r = _G[name .. suffix]
    if r then r:SetText("") end
  end
  local label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", x, y - 2)
  label:SetWidth(155)
  label:SetJustifyH("LEFT")
  label:SetText(d.label)
  local value = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  value:SetPoint("TOP", sl, "BOTTOM", 0, -1)
  sl.valueText, sl.def = value, d
  sl:SetScript("OnValueChanged", function(self, v, userInput)
    v = math.floor(v / d.step + 0.5) * d.step
    self.valueText:SetText(Geo.ParamText(d, v) .. ((math.abs(v - d.default) < 1e-6) and "" or
      Color("888888", L["  (default "] .. Geo.ParamText(d, d.default) .. ")")))
    if userInput ~= false and not panel.updating then Geo.SetParam(d, v) end
  end)
  sl:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(d.label)
    GameTooltip:AddLine(L["Default value: "] .. Geo.ParamText(d, d.default), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(L["The Roadbook is recomputed with the new value."], 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  sl:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.sliders[#panel.sliders + 1] = sl
end

-- Settings window: general options, then a Roadbook panel with its option groups.
-- (Duration, Around me radius, Available filter and low-level quests stay in their tabs.)
function Geo.CreateSettingsPanel(f)
  local panel = CreateFrame("Frame", nil, f)
  panel:SetAllPoints(f)
  panel.sliders, panel.updaters = {}, {}

  -- General
  local gen = Geo.SettingsBox(panel, L["General"], 14, -32, 392, 62)
  Geo.SettingsCheck(gen, L["Minimap icon"], 10, -28,
    function() return not Settings().hideMinimap end,
    function(v)
      Settings().hideMinimap = not v or nil
      local mb = _G["ForeverQuestPlannerMinimapButton"]
      if mb then mb:SetShown(v) end
    end, panel)

  -- Quest log
  local journal = Geo.SettingsBox(panel, L["Quest log"], 414, -32, 392, 62)
  local keep = CreateFrame("Button", nil, journal, "UIPanelButtonTemplate")
  keep:SetSize(240, 22)
  keep:SetPoint("TOPLEFT", 10, -28)
  keep:SetText(L["Clear \"Keep\" quests"])
  keep:SetScript("OnClick", function()
    Settings().keep = {}
    Print(L["\"Keep\" quest list cleared."])
    if Refresh then Refresh() end
  end)

  -- Roadbook: objective button, hearthstone, then priorities, look-ahead and time estimates.
  -- Layout: boxes 8 px apart; content 10 px from the left edge, first row 28-30 px below the
  -- top edge, 12 px of padding under the last row (slider row = 46 px).
  local rb = Geo.SettingsBox(panel, L["Roadbook"], 14, -102, 792, 572)
  Geo.SettingsCheck(rb, L["Use the hearthstone"], 18, -28,
    function() return not Settings().noHearth end,
    function(v)
      Settings().noHearth = not v or nil
      Geo.planCache = nil
    end, panel)
  local restore = CreateFrame("Button", nil, rb, "UIPanelButtonTemplate")
  restore:SetSize(260, 22)
  restore:SetPoint("TOPRIGHT", -18, -28) -- aligned with "Center horizontally" below
  local function RemovedCount()
    local n = 0
    for _ in pairs(Settings().excluded) do n = n + 1 end
    return n
  end
  local function UpdateRestore()
    local n = RemovedCount()
    restore:SetText(L["Restore removed quests"] .. (n > 0 and (" (" .. n .. ")") or ""))
    restore:SetEnabled(n > 0)
  end
  panel.updaters[#panel.updaters + 1] = UpdateRestore
  restore:SetScript("OnClick", function()
    local n = RemovedCount()
    if n == 0 then return end
    Settings().excluded = {}
    Geo.planCache = nil
    Print(Plural(n, L["quest"]) .. L[" added back: computing a new Roadbook."])
    UpdateRestore()
    CP.Recompute()
  end)
  -- Objective button: shown, compass, centered.
  local obj = Geo.SettingsBox(rb, L["Objective"], 8, -58, 776, 62)
  Geo.SettingsCheck(obj, L["Show"], 10, -28, CP.CHECKPOINT_TOGGLE.get, CP.CHECKPOINT_TOGGLE.set, panel)
  Geo.SettingsCheck(obj, L["Compass"], 220, -28,
    function() return Settings().compass ~= false end,
    function(v)
      if v then Settings().compass = nil else Settings().compass = false end -- shown by default
      local b = CP.checkpointButton
      if b then b.compassTarget = CP.CompassTarget() end
    end, panel)
  local center = CreateFrame("Button", nil, obj, "UIPanelButtonTemplate")
  center:SetSize(260, 22)
  center:SetPoint("TOPRIGHT", -10, -28)
  center:SetText(L["Center horizontally"])
  center:SetScript("OnClick", function() CP.CenterCheckpointButton() end)
  local boxes = {
    Geo.SettingsBox(rb, L["Priorities (100 % = adds the XP of an average Roadbook quest)"], 8, -128, 776, 214),
    Geo.SettingsBox(rb, L["Difficulty"], 8, -350, 384, 214),
    Geo.SettingsBox(rb, L["Time estimates"], 400, -350, 384, 214),
  }
  local sec, n = 0, 0
  for _, d in ipairs(K.PARAMS) do
    if d.section then
      sec, n = sec + 1, 0
    elseif boxes[sec] then
      local cols = (sec == 1) and 2 or 1
      local col, row = n % cols, math.floor(n / cols)
      Geo.SettingsSlider(boxes[sec], d, 10 + col * 392, -30 - row * 46, panel)
      n = n + 1
    end
  end
  -- Elite quests on/off, on the free row of the "Difficulty" box; off: their slider is greyed.
  local function UpdateEliteSlider()
    local sl = _G["ForeverQuestPlannerParamMAX_ELITE_GAP"]
    if sl and sl.Enable then
      if Settings().noElite then sl:Disable() else sl:Enable() end
      sl:SetAlpha(Settings().noElite and 0.4 or 1)
    end
  end
  Geo.SettingsCheck(boxes[2], L["Include elite quests"], 10, -122,
    function() return not Settings().noElite end,
    function(v)
      Settings().noElite = not v or nil
      Geo.planCache = nil
      UpdateEliteSlider()
    end, panel)
  panel.updaters[#panel.updaters + 1] = UpdateEliteSlider

  local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  reset:SetSize(170, 24)
  reset:SetPoint("BOTTOMLEFT", 16, 26)
  reset:SetText(L["Defaults"])
  reset:SetScript("OnClick", function()
    Settings().params = nil
    Geo.ApplyParams()
    scan.dirty = true
    panel.Update()
  end)
  local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  note:SetPoint("LEFT", reset, "RIGHT", 12, 0)
  note:SetWidth(580)
  note:SetJustifyH("LEFT")
  note:SetText(L["Settings are saved. Priorities and estimates apply to the next Roadbook computation; \"Defaults\" resets them."])
  function panel.Update()
    panel.updating = true
    for _, fn in ipairs(panel.updaters) do fn() end
    for _, sl in ipairs(panel.sliders) do
      sl:SetValue(K[sl.def.key])
      local fn = sl:GetScript("OnValueChanged")
      if fn then fn(sl, K[sl.def.key], false) end
    end
    panel.updating = false
  end
  return panel
end

-- "ForeverQuestPlanner vX.Y.Z" footer at the bottom of a window (version read from the .toc).
-- Addon version, read from the .toc.
function Geo.Version()
  local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ok, version = false, nil
  if getMeta then ok, version = pcall(getMeta, "ForeverQuestPlanner", "Version") end
  return (ok and version) or "?"
end

function Geo.AddVersionFooter(frame)
  local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footer:SetPoint("BOTTOMRIGHT", -14, 8)
  footer:SetText("ForeverQuestPlanner v" .. Geo.Version())
  -- GitHub link, bottom left: the game cannot open URLs, so a click shows it ready to copy.
  local link = CreateFrame("Button", nil, frame)
  link.text = link:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  link.text:SetPoint("LEFT")
  link.text:SetText(K.REPO_URL)
  link:SetSize((link.text:GetStringWidth() or 200) + 4, 14)
  link:SetPoint("BOTTOMLEFT", 14, 6)
  link:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 0.82, 0)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Click to copy the link"])
    GameTooltip:Show()
  end)
  link:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.5, 0.5, 0.5)
    GameTooltip:Hide()
  end)
  link:SetScript("OnClick", function() StaticPopup_Show("FQP_COPY_URL") end)
  return footer
end

K.REPO_URL = "https://github.com/bplaquevent/ForeverQuestPlanner"
StaticPopupDialogs["FQP_COPY_URL"] = {
  text = L["Copy the link with Ctrl+C:"],
  button1 = OKAY or "OK",
  hasEditBox = true,
  editBoxWidth = 320,
  OnShow = function(self)
    local eb = self.editBox or self.EditBox
    if eb then
      eb:SetText(K.REPO_URL)
      eb:HighlightText()
      eb:SetFocus()
    end
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
  EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

-- Standalone settings window (movable, closed with Escape or the close button).
function Geo.ToggleSettings()
  local w = Geo.settingsWindow
  if not w then
    w = CreateFrame("Frame", "ForeverQuestPlannerSettingsFrame", UIParent, "BasicFrameTemplateWithInset")
    w:SetSize(820, 746)
    w:SetPoint("CENTER", 40, -20)
    w:SetFrameStrata("DIALOG")
    w:SetToplevel(true)
    w:SetMovable(true)
    w:SetClampedToScreen(true)
    w:EnableMouse(true)
    w:RegisterForDrag("LeftButton")
    w:SetScript("OnDragStart", w.StartMoving)
    w:SetScript("OnDragStop", w.StopMovingOrSizing)
    w.title = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    w.title:SetPoint("TOP", 0, -5)
    w.title:SetText(L["Forever Quest Planner - Roadbook settings"])
    -- Same background as the main window: darkened parchment with a slight gradient.
    w.art = w:CreateTexture(nil, "BACKGROUND", nil, 2)
    w.art:SetPoint("TOPLEFT", 6, -24)
    w.art:SetPoint("BOTTOMRIGHT", -6, 6)
    w.art:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal")
    w.art:SetVertexColor(0.42, 0.34, 0.26)
    w.shade = w:CreateTexture(nil, "BACKGROUND", nil, 3)
    w.shade:SetAllPoints(w.art)
    w.shade:SetColorTexture(0, 0, 0, 1)
    if w.shade.SetGradient and CreateColor then
      pcall(w.shade.SetGradient, w.shade, "VERTICAL", CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0.15))
    else
      w.shade:SetAlpha(0.35)
    end
    w.panel = Geo.CreateSettingsPanel(w)
    Geo.AddVersionFooter(w)
    w:SetScript("OnShow", function() w.panel.Update() end)
    w:SetScript("OnHide", function()
      -- The open Roadbook is recomputed with the new values.
      if Refresh then Refresh() end
    end)
    tinsert(UISpecialFrames, "ForeverQuestPlannerSettingsFrame")
    Geo.settingsWindow = w
    w:Hide()
  end
  w:SetShown(not w:IsShown())
end
