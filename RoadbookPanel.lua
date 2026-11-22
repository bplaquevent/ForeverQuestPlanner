-- Forever Quest Planner: the Roadbook's steps in a panel beside the world map.
-- The names shared between files are published in ns at the end of each file (load order: .toc).
--
-- The Roadbook holding the map (followed or previewed), else the active one, listed step by step:
-- steps done greyed and checked, the others numbered as their pins on the map (1 = next), the
-- current objective highlighted and scrolled to. The panel sits against the map window's right
-- side, outside it; when there is no room there (full-screen map), over the map's right side.
-- Click: the map glides to the step; Shift-click: the Roadbook's tab.

local ADDON_NAME, ns = ...
local AreaName, CP, Color, FormatTime, Geo, K, L = ns.AreaName, ns.CP, ns.Color, ns.FormatTime, ns.Geo, ns.K, ns.L
local IsInLog, OM, OpenQuestDetails, Settings = ns.IsInLog, ns.OM, ns.OpenQuestDetails, ns.Settings
local UpdateScrollBar = ns.UpdateScrollBar

K.MAP_PANEL_W = 300   -- px: panel width
K.MAP_PANEL_ROW = 34  -- px: a step's line
K.MAP_PANEL_HEAD = 42 -- px: title bar (title, count under it, Show and Start / Pause buttons)
K.MAP_PANEL_BOTTOM = 96 -- px kept free under the panel when it is over the map (OpenMap's tabs)

local panel -- created at the first display

-- The Roadbook shown; nil without steps.
function Geo.MapPanelShown()
  return Geo.Frozen() ~= nil
end

function Geo.MapPanelGet()
  return Settings().mapPanel ~= false
end

function Geo.MapPanelSet(v)
  if v then Settings().mapPanel = nil else Settings().mapPanel = false end -- on by default
  Geo.MapPanelSync()
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
-- Beside the map window if the screen has room on its right, over the map's right side otherwise.
function Geo.MapPanelPlace()
  if not panel then return end
  local wm = WorldMapFrame
  local scale = wm:GetEffectiveScale()
  local right = (wm:GetRight() or 0) * scale
  local screen = (UIParent:GetRight() or 0) * UIParent:GetEffectiveScale()
  local inside = screen - right < K.MAP_PANEL_W * scale
  panel:ClearAllPoints()
  if inside then
    local sc = wm.ScrollContainer or wm
    panel:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -4, -4)
    panel:SetPoint("BOTTOMRIGHT", sc, "BOTTOMRIGHT", -4, K.MAP_PANEL_BOTTOM)
    panel:SetFrameLevel(math.min(sc:GetFrameLevel() + 9000, 9800)) -- over OpenMap's art and pins
  else
    panel:SetPoint("TOPLEFT", wm, "TOPRIGHT", -2, 0)
    panel:SetPoint("BOTTOMLEFT", wm, "BOTTOMRIGHT", -2, 0)
    panel:SetFrameLevel(wm:GetFrameLevel() + 5)
  end
  panel:SetWidth(K.MAP_PANEL_W)
  panel.inside = inside
end

local function RowEnter(self)
  if self.step then
    Geo.StepTooltip(self, self.step, self.n, L["Click: center the map and select the quest in the quest log"],
      panel.inside and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
  end
end

local function RowClick(self)
  local st = self.step
  if not st then return end
  local u, v = Geo.MapUV(st.p)
  local qid = st.task and st.task.id
  if qid and IsInLog(qid) then
    -- The quest log opens on the quest (it moves the map to the quest's zone): the step is centered after it.
    OpenQuestDetails(qid)
    if u then C_Timer.After(0, function() pcall(OM.api.ShowWorld, u, v) end) end
  elseif u then
    pcall(OM.api.ShowWorld, u, v)
  end
end

local function NewRow(parent)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(K.MAP_PANEL_ROW)
  r:RegisterForClicks("LeftButtonUp")
  r.current = r:CreateTexture(nil, "BACKGROUND")
  r.current:SetAllPoints()
  r.current:SetColorTexture(1, 0.82, 0, 0.18)
  r.bar = r:CreateTexture(nil, "ARTWORK") -- the step kind's colour, as its pin
  r.bar:SetPoint("TOPLEFT", 0, -3)
  r.bar:SetPoint("BOTTOMLEFT", 0, 3)
  r.bar:SetWidth(3)
  r.num = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  r.num:SetPoint("TOPLEFT", 6, -4)
  r.num:SetWidth(20)
  r.num:SetJustifyH("CENTER")
  r.check = r:CreateTexture(nil, "OVERLAY")
  r.check:SetSize(14, 14)
  r.check:SetPoint("TOP", r.num, "TOP", 0, 1)
  r.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
  r.time = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.time:SetPoint("TOPRIGHT", -4, -4)
  r.title = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.title:SetPoint("TOPLEFT", 28, -4)
  r.title:SetPoint("RIGHT", r.time, "LEFT", -4, 0)
  r.title:SetJustifyH("LEFT")
  r.title:SetWordWrap(false)
  r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.sub:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -3)
  r.sub:SetPoint("RIGHT", -4, 0)
  r.sub:SetJustifyH("LEFT")
  r.sub:SetWordWrap(false)
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r:SetScript("OnEnter", RowEnter)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r:SetScript("OnClick", RowClick)
  return r
end

local function Create()
  local wm = WorldMapFrame
  panel = CreateFrame("Frame", nil, wm, BackdropTemplateMixin and "BackdropTemplate" or nil)
  if panel.SetBackdrop then
    panel:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 14,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0.06, 0.05, 0.03, 0.94)
    panel:SetBackdropBorderColor(1, 0.82, 0, 0.8)
  else
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.05, 0.03, 0.94)
  end
  panel:EnableMouse(true) -- (over the map: clicks stay on the panel)
  panel.titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  panel.titleText:SetPoint("TOPLEFT", 10, -9)
  panel.count = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  panel.count:SetPoint("TOPLEFT", panel.titleText, "BOTTOMLEFT", 0, -3)
  -- No close button: the panel is shown or hidden from OpenMap's menu only (Geo.MapInit).
  -- Start / Pause, as the Roadbook tab's button.
  local startB = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  startB:SetSize(66, 20)
  startB:SetPoint("TOPRIGHT", -8, -5)
  startB:SetScript("OnClick", function()
    if Geo.Tracking() then CP.Pause() else CP.Start() end
  end)
  startB:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Start / Pause"], 1, 1, 1)
    GameTooltip:AddLine(L["Start: the Objective button follows the Roadbook. Pause: the tracking stops, the progress is kept."], 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
  end)
  startB:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.startB = startB
  -- Roadbook: opens the Roadbook window on its tab.
  local showB = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  showB:SetSize(66, 20)
  showB:SetPoint("RIGHT", startB, "LEFT", -2, 0)
  showB:SetText(L["Roadbook"])
  showB:SetScript("OnClick", function()
    if CP.OpenWindow then CP.OpenWindow("xp") end
  end)
  showB:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Roadbook"], 1, 1, 1)
    GameTooltip:AddLine(L["Opens this Roadbook in the addon's window."], 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
  end)
  showB:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.titleText:SetPoint("RIGHT", showB, "LEFT", -4, 0)
  panel.titleText:SetJustifyH("LEFT")
  panel.titleText:SetWordWrap(false)
  local rule = panel:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(1, 0.82, 0, 0.35)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 6, -K.MAP_PANEL_HEAD)
  rule:SetPoint("TOPRIGHT", -6, -K.MAP_PANEL_HEAD)
  local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 6, -K.MAP_PANEL_HEAD - 4)
  scroll:SetPoint("BOTTOMRIGHT", -26, 8)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(K.MAP_PANEL_W - 32, 1)
  scroll:SetScrollChild(child)
  scroll.child = child
  scroll:HookScript("OnScrollRangeChanged", UpdateScrollBar) -- scroll bar shown only when useful
  panel.scroll, panel.child, panel.rows = scroll, child, {}
  -- Placed again whenever the map window moves to or from the screen's right edge.
  wm:HookScript("OnSizeChanged", function()
    if panel:IsShown() then Geo.MapPanelPlace() UpdateScrollBar(scroll) end
  end)
  wm:HookScript("OnShow", function() panel.scrollKey = nil end) -- scrolled to the objective at each opening
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------
-- Second line of a step: its zone, and its XP.
local function SubText(s)
  local zone = s.p and (s.p.instance or AreaName(s.p.area) or s.p.zoneName) or "?"
  local xp
  if s.kind == "turnin" then xp = Geo.XPText(s.task and s.task.xp)
  elseif s.kind == "obj" then xp = Geo.XPText(s.xp, true)
  elseif s.kind == "dungeon" then xp = Geo.XPText(s.xp) end
  return xp and (zone .. K.DESC_SEP .. xp) or zone
end

-- A text without its colour codes (step done: all grey).
local function Plain(s)
  return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Fills the panel with the shown Roadbook (or hides it). Only while the map is open.
function Geo.MapPanelSync()
  if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
  if not (Geo.MapPanelGet() and Geo.MapPanelShown()) then
    if panel then panel:Hide() end
    return
  end
  if not panel then Create() end
  Geo.MapPanelPlace()
  panel:Show()
  local route = Geo.Frozen().route
  local cur = CP.CurrentFocus()
  local rows, width = panel.rows, K.MAP_PANEL_W - 32
  local n, done, target, total = 0, 0, nil, 0
  for i = 2, #route do
    local st = route[i]
    total = total + 1
    local r = rows[total] or NewRow(panel.child)
    rows[total] = r
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, -(total - 1) * K.MAP_PANEL_ROW)
    r:SetWidth(width)
    local isDone = CP.StepDone(st)
    local ok, title = pcall(CP.StepSummary, st)
    if not (ok and title) then title = CP.StepText(st) end
    local c = K.MAP_COLOR[st.kind] or K.MAP_COLOR.other
    r.bar:SetColorTexture(c[1], c[2], c[3], isDone and 0.3 or 0.9)
    r.step = st
    if isDone then
      done = done + 1
      r.n = nil
      r.num:SetText("")
      r.check:Show()
      r.title:SetText(Color("808080", Plain(title)))
      r.sub:SetText(Plain(SubText(st)))
    else
      n = n + 1
      r.n = n
      r.num:SetText(n)
      r.check:Hide()
      r.title:SetText(title)
      r.sub:SetText(SubText(st))
      if not target then target = total end -- first step not done
    end
    local isCur = st == cur
    if isCur then target = total end
    r.current:SetShown(isCur)
    r.num:SetTextColor(isCur and 0.4 or 1, 1, isCur and 0.4 or 1)
    r.time:SetText(FormatTime(st.at or 0))
    r:Show()
  end
  for i = total + 1, #rows do rows[i]:Hide() rows[i].step = nil end
  panel.child:SetHeight(math.max(1, total * K.MAP_PANEL_ROW))
  UpdateScrollBar(panel.scroll)
  panel.titleText:SetText(L["Roadbook"])
  panel.count:SetText(string.format(L["%d/%d steps done"], done, total))
  local following = Geo.Tracking()
  panel.startB:SetText(following and L["Pause"] or L["Start"])
  panel.startB:SetEnabled(not Geo.computing and (following or not Geo.IsFinished()))
  -- Scrolled to the objective when it changes (not at each refresh: the player may be scrolling).
  local key = tostring(target)
  if target and panel.scrollKey ~= key then
    panel.scrollKey = key
    C_Timer.After(0, function()
      local sc = panel.scroll
      local y = (target - 1) * K.MAP_PANEL_ROW - (sc:GetHeight() or 0) / 3
      sc:SetVerticalScroll(math.max(0, math.min(y, sc:GetVerticalScrollRange() or 0)))
    end)
  end
end

-- Shared with the next files: nothing (Geo.MapPanel* are fields of Geo).
