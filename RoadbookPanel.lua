-- Forever Quest Planner: the Roadbook's steps in a window of their own.
-- The names shared between files are published in ns at the end of each file (load order: .toc).
--
-- The saved Roadbook, step by step: a short header (size and progress, XP, travel, what to watch),
-- then its steps: done ones greyed and checked, the others numbered as their pins on the map (1 =
-- next), the current objective highlighted and scrolled to. Hover: the step's details; click: the
-- map opens or glides to the step; right-click: its actions (remove the quest, not here, skip).
-- The panel lives on its own, independent of the map: moved with Shift-drag, resized by its bottom
-- edge, shown or hidden by the Objective button and the Steps button.

local ADDON_NAME, ns = ...
local AreaName, CP, Color, FormatNumber, FormatTime, Geo, K = ns.AreaName, ns.CP, ns.Color, ns.FormatNumber, ns.FormatTime, ns.Geo, ns.K
local L, Plural, RouteText, Settings, UpdateScrollBar, State = ns.L, ns.Plural, ns.RouteText, ns.Settings, ns.UpdateScrollBar, ns.State
local IsInLog, OpenQuestDetails = ns.IsInLog, ns.OpenQuestDetails

K.MAP_PANEL_W = 300   -- px: panel width
K.MAP_PANEL_ROW = 34  -- px: a step's line
K.MAP_PANEL_TITLE = 30 -- px: title bar (title, buttons); the header text is under it
K.MAP_PANEL_MIN_H, K.MAP_PANEL_MAX_H = 220, 1000 -- px: height of the panel

local panel -- created at the first display

-- The Roadbook shown; nil without steps.
function Geo.MapPanelShown()
  return Geo.Frozen() ~= nil
end

-- Panel shown or hidden (the Objective button, the Steps button).
function Geo.MapPanelShow(v)
  Settings().stepsHidden = (not v) or nil
  Geo.MapPanelSync()
end

-- Steps button of the Roadbook tab and Objective button: the panel shown (toggle: or hidden when
-- it is shown).
function Geo.MapPanelOpen(toggle)
  local shown = panel and panel:IsShown()
  Geo.MapPanelShow(not (toggle and shown))
end

---------------------------------------------------------------------------
-- Details of a step (tooltips of the panel and of the map pins)
---------------------------------------------------------------------------
-- Quest steps done during a dungeon visit, one line each.
function Geo.DungeonMemberLines(task)
  local lines = {}
  for _, m in ipairs(task.members or {}) do
    local what
    if m.kind == "take" then what = L["pick up"]
    elseif m.kind == "turnin" then what = L["turn in"]
    else what = ((m.r and m.r.tg.name) or L["objective"]) .. L[" x"] .. ((m.r and m.r.count) or "?") end
    local line = "- " .. ((m.task and m.task.title) or "?") .. L[": "] .. what
    lines[#lines + 1] = CP.StepDone(m) and Color(K.DESC.good, line .. L[" (done)"]) or Color(K.DESC.action, line)
  end
  return lines
end

-- Duration of a step alone (way from the previous step and what is done there), from the times
-- of the saved Roadbook (st.at: time since its start); nil if the step is not in it.
function Geo.StepDuration(st)
  local fz = Geo.Frozen()
  local route = fz and fz.route
  for i = 2, route and #route or 0 do
    if route[i] == st then return math.max(0, (st.at or 0) - (route[i - 1].at or 0)) end
  end
end

-- XP of a step: a quest turned in, monsters of an objective (estimate), a dungeon visit.
function Geo.StepXP(s)
  if s.kind == "turnin" then return Geo.XPText(s.task and s.task.xp) end
  if s.kind == "obj" then return Geo.XPText(s.xp, true) end
  if s.kind == "dungeon" then return Geo.XPText(s.xp) end
end

-- Lines of a step's details after its title, coloured: what to do and where (one line per piece),
-- XP · duration of the step, notes, quests of a dungeon, the way from the previous step, level reached.
function Geo.StepDetailLines(st)
  local D = K.DESC
  local lines = {}
  local _, parts = CP.StepSummary(st)
  local xp = Geo.StepXP(st)
  for _, piece in ipairs(parts or {}) do
    if piece ~= xp then lines[#lines + 1] = Color(D.action, CP.Capitalize(piece)) end -- the XP: its own line
  end
  local dur = Geo.StepDuration(st)
  local figures = Geo.DescLine(xp, dur and Color(D.meta, "~" .. FormatTime(dur)))
  if figures ~= "" then lines[#lines + 1] = (figures:gsub("^" .. K.DESC_LINE:gsub("%p", "%%%0"), "")) end
  local task = st.task or {}
  local function add(hex, t) lines[#lines + 1] = Color(hex, t) end
  if st.kind == "fm" and st.fmHub then add(D.good, st.laterFM and L["for later trips"] or L["used afterwards by the route"]) end
  if st.escort then add(D.warn, "~" .. FormatTime(st.work or 0) .. L[", do not interrupt"]) end
  if st.kind == "take" then
    if task.levelWarn and task.reqLevel then
      add(D.warn, string.format(L["level %d required: not reached by this route"], task.reqLevel))
    end
    if task.dep then add(D.chain, string.format(L["follow-up of \"%s\""], task.dep.title or "?")) end
  end
  if st.kind == "obj" and st.spot then
    add(st.spots and st.spots > 1 and D.warn or D.meta, string.format(L["spot of %d monsters"], st.spot.n) ..
      (st.spots and st.spots > 1 and L[", the most efficient (travel + density)"] or ""))
  end
  if st.kind == "turnin" then
    if task.quick then add(D.good, L["ready to turn in"]) end
  end
  if task.id and task.stops and st == task.stops[1] then
    if task.warn then add(D.bad, task.warn) end
    if task.orderWarn then add(D.warn, L["order of the prerequisites not respected"]) end
  end
  if st.kind == "dungeon" then
    for _, l in ipairs(Geo.DungeonMemberLines(task)) do lines[#lines + 1] = l end
  end
  -- The way from the previous step and the level reached: the step's place in the saved Roadbook.
  local fz = Geo.Frozen()
  local route, info = fz and fz.route, fz and fz.info
  local i
  for k = 2, route and #route or 0 do if route[k] == st then i = k break end end
  if i then
    if st.kind ~= "hearth" then
      local okW, way = pcall(function()
        return RouteText(route[i - 1].p, st.p, Geo.NetFor(route, i, info.speed or K.RUN_SPEED), info.plevel)
      end)
      if okW and way and way ~= L["right here"] then lines[#lines + 1] = Color("ffffff", L["Route: "]) .. way end
    end
    local lvs = info.levels
    if lvs and lvs[i] and lvs[i - 1] and lvs[i] > lvs[i - 1] then
      add(D.good, string.format(L["level %d reached"], lvs[i]))
    end
  end
  return lines
end

---------------------------------------------------------------------------
-- Header
---------------------------------------------------------------------------
-- Header text: size and progress, XP, travel (hearthstone, class teleports), then what to watch,
-- one line each (only when there is something).
function Geo.MapPanelHeader(route, info, doneCount)
  local sep = Color("777777", " - ")
  local value = function(t) return Color("dddddd", t) end
  local lines = {}
  if State.computing then lines[1] = Color("ffd100", L["Recomputing… the Roadbook cannot be changed"]) end
  -- Size and progress.
  local total = #route - 1
  local finished = total > 0 and doneCount >= total
  lines[#lines + 1] = value(Plural(info.count or 0, L["quest"])) .. sep ..
    Color(finished and K.DESC.good or "ffd100", string.format(L["%d/%d steps finished"], doneCount, total)) .. sep ..
    value("~" .. FormatTime(info.total or 0))
  -- XP.
  if (info.xp or 0) > 0 then
    lines[#lines + 1] = Color(K.DESC.xp, FormatNumber(info.xp) .. " XP") .. sep ..
      value("~" .. ((info.total or 0) > 0 and FormatNumber(info.xp / info.total * 3600) or "0") .. " XP/h")
  end
  -- Travel: hearthstone, class teleports (cooldown each, runes of the mage teleports).
  local travel = {}
  local ready = Geo.HearthReady()
  local bindP, bindName = Geo.CurrentBind()
  if Settings().noHearth then
    travel[1] = value(L["Hearthstone ignored"])
  elseif ready then
    local where = bindName or "?"
    if not bindP then where = where .. Color("ff8040", " (?)")
    elseif bindP.approx then where = where .. Color("ffd100", " (~)") end
    travel[1] = value(L["Hearth: "] .. where .. " (" .. (ready > 0 and FormatTime(ready) or L["ready"]) .. ")")
  end
  local runes
  for _, src in ipairs(Geo.RecallSources()) do
    if src.spell then
      if src.charges then
        runes = src.charges
      elseif (src.cd or 0) > 0 then
        travel[#travel + 1] = value(src.name .. " (" .. (src.ready > 0 and FormatTime(src.ready) or L["ready to cast"]) .. ")")
      else
        travel[#travel + 1] = value(src.name)
      end
    end
  end
  if runes then travel[#travel + 1] = value(string.format(L["teleports: %d rune(s)"], runes)) end
  if #travel > 0 then lines[#lines + 1] = table.concat(travel, Color("777777", K.DESC_SEP)) end
  -- To watch: one line each.
  local unplanned = #(info.unplanned or {})
  if unplanned > 0 then
    lines[#lines + 1] = Color(K.DESC.bad, Plural(unplanned, L["quest"]) .. L[" cannot be planned"])
  end
  if info.taxi == 0 then
    lines[#lines + 1] = Color("ff8040", CP.Capitalize(L["no flight master recorded (open a flight map)"]))
  end
  if (info.discovered or 0) > 0 then
    lines[#lines + 1] = Color("c890ff", Plural(info.discovered, L["flight path to activate"]))
  end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
-- Where the player left it (default: right of the screen).
function Geo.MapPanelPlace()
  if not panel then return end
  panel:ClearAllPoints()
  panel:SetWidth(K.MAP_PANEL_W)
  local pos = Settings().stepsPos
  if pos then
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos[1], pos[2])
  else
    panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -80, -160)
  end
  panel:SetHeight(Settings().stepsHeight or 480)
end

local function Tip(self, title, text)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine(title, 1, 1, 1)
  GameTooltip:AddLine(text, 0.85, 0.85, 0.85, true)
  GameTooltip:Show()
end

local function RowEnter(self)
  if self.step then
    Geo.StepTooltip(self, self.step, self.n,
      K.CLICK_STEP_TIP .. "\n" .. L["Right-click: actions of the step"],
      "ANCHOR_LEFT")
  end
end

-- Actions of a step ({ label, fn, tooltip, reads = changes nothing }): show its quest (in the quest
-- log); for a step not done: remove its quest, "Not here" (a possible place of the quest giver), skip
-- the followed hearthstone / transport step.
local function StepActions(st)
  local acts = {}
  local qid = st.task and st.task.id
  if qid and IsInLog(qid) then
    acts[#acts + 1] = { L["Show the quest"], function() OpenQuestDetails(qid) end,
      L["Opens the quest in the quest log beside the map."], reads = true }
  end
  if CP.StepDone(st) then return acts end
  if st.search and qid then
    acts[#acts + 1] = { L["Not here"], function() CP.SkipStep(st) end,
      L["The quest giver is not at this place: the step is marked done and the Objective button moves to the next place to check."] }
  end
  if qid then
    acts[#acts + 1] = { L["Remove the quest"], function() CP.ConfirmSkipQuest(st) end,
      L["Removes the quest from the list (with the prerequisites added only for it); the steps to come of the Roadbook are computed again."] }
  elseif (st.kind == "hearth" or st.kind == "travel") and st == CP.CurrentFocus() then
    acts[#acts + 1] = { L["Skip"], function() CP.SkipStep(st) end, st.kind == "travel"
      and L["Marks this step as done; the steps to come are planned again without this transport for the way to the next step."]
      or L["Marks this step as done (already there, other way of travel…); the Objective button moves to the next step."] }
  end
  return acts
end

local DragStart, DragStop -- Shift-drag moves the panel (defined with SavePlace)

local function RowClick(self, button)
  local st = self.step
  if not st then return end
  if panel.dragEnd and GetTime() - panel.dragEnd < 0.3 then return end -- release of a Shift-drag
  if button == "RightButton" then
    local acts = StepActions(st)
    if #acts == 0 or not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    GameTooltip:Hide()
    MenuUtil.CreateContextMenu(self, function(_, root)
      root:CreateTitle(st.task and st.task.title or L["Roadbook step"])
      local computing = State.computing -- what changes the Roadbook waits for it
      if computing then root:CreateTitle(Color("ffd100", L["Recomputing…"])) end
      for _, a in ipairs(acts) do
        local d = root:CreateButton(a[1], a[2])
        local locked = computing and not a.reads
        if locked then d:SetEnabled(false) end
        if d and d.SetTooltip then
          d:SetTooltip(function(tip)
            tip:AddLine(a[1], 1, 1, 1)
            tip:AddLine(a[3], 0.85, 0.85, 0.85, true)
            if locked then tip:AddLine(K.LOCKED_TIP, 1, 0.82, 0, true) end
          end)
        end
      end
    end)
    return
  end
  Geo.ClickStep(st)
end

local function NewRow(parent)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(K.MAP_PANEL_ROW)
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
  r:RegisterForDrag("LeftButton")
  r:SetScript("OnDragStart", DragStart)
  r:SetScript("OnDragStop", DragStop)
  return r
end

local function SavePlace()
  Settings().stepsPos = { panel:GetLeft() or 0, panel:GetTop() or 0 }
  Settings().stepsHeight = math.floor(panel:GetHeight() + 0.5)
end

-- Shift-drag (anywhere on the panel, steps too) moves the panel; the release does not click.
DragStart = function()
  if IsShiftKeyDown() then
    panel.moving = true
    panel:StartMoving()
  end
end
DragStop = function()
  if not panel.moving then return end
  panel.moving = nil
  panel:StopMovingOrSizing()
  panel.dragEnd = GetTime()
  SavePlace()
end

local function Create()
  panel = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  panel:SetFrameStrata("DIALOG") -- over the map when it opens
  Geo.FrameStyle(panel) -- the Objective button's look
  panel:EnableMouse(true) -- (over the map: clicks stay on the panel)
  panel:SetClampedToScreen(true)
  -- Moved by Shift-drag (as the Objective button), resized in height by its bottom edge.
  panel:SetMovable(true)
  panel:SetResizable(true)
  if panel.SetResizeBounds then
    panel:SetResizeBounds(K.MAP_PANEL_W, K.MAP_PANEL_MIN_H, K.MAP_PANEL_W, K.MAP_PANEL_MAX_H)
  elseif panel.SetMinResize then
    panel:SetMinResize(K.MAP_PANEL_W, K.MAP_PANEL_MIN_H)
    panel:SetMaxResize(K.MAP_PANEL_W, K.MAP_PANEL_MAX_H)
  end
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", DragStart)
  panel:SetScript("OnDragStop", DragStop)
  panel.titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  panel.titleText:SetPoint("TOPLEFT", 10, -9)
  panel.titleText:SetText(L["Roadbook"])
  -- Title bar, right to left: "Empty" icon, "Recompute" icon, then the boxes
  -- "Tracking", "Auto" and "Info". (No close button: the Objective button and the Steps button show or
  -- hide the panel.)
  local function IconButton(size, normal, pushed, highlight)
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(size, size)
    b:SetNormalTexture(normal)
    b:SetPushedTexture(pushed or normal)
    b:SetDisabledTexture(normal)
    b:GetDisabledTexture():SetDesaturated(true)
    b:SetHighlightTexture(highlight or "Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
  end
  local emptyB = IconButton(16, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "Interface\\Buttons\\UI-GroupLoot-Pass-Down",
    "Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
  emptyB:SetPoint("TOPRIGHT", -8, -7)
  emptyB:SetScript("OnClick", function() CP.Empty() end)
  emptyB:SetScript("OnEnter", function(self)
    Tip(self, L["Empty"], L["Empties the Roadbook: its steps, their progress and the quest list."])
  end)
  panel.emptyB = emptyB
  -- Recompute (tracked or not): the steps to come planned again from here.
  local recalc = IconButton(16, "Interface\\Buttons\\UI-RefreshButton")
  recalc:SetPoint("RIGHT", emptyB, "LEFT", -6, 0)
  recalc:SetScript("OnClick", function()
    GameTooltip:Hide()
    if CP.Replan(L["Recompute requested. "], nil, true) then Geo.MapPanelSync() end
  end)
  recalc:SetScript("OnEnter", function(self)
    Tip(self, L["Recompute"], L["Plans the steps to come again from where you are: the steps done and the tracking are kept."])
  end)
  panel.recalc = recalc
  local track = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  track:SetSize(20, 20)
  track.label = track:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  track.label:SetText(L["Tracking"])
  track.label:SetPoint("RIGHT", recalc, "LEFT", -6, 0)
  track:SetPoint("RIGHT", track.label, "LEFT", -2, 0)
  local auto = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  auto:SetSize(20, 20)
  auto.label = auto:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  auto.label:SetText(L["Auto"])
  auto.label:SetPoint("RIGHT", track, "LEFT", -6, 0)
  auto:SetPoint("RIGHT", auto.label, "LEFT", -2, 0)
  auto:SetHitRectInsets(0, -((auto.label:GetStringWidth() or 30) + 2), 0, 0)
  auto:SetScript("OnClick", function(self) CP.SetAutoAdd(self:GetChecked()) end)
  auto:SetScript("OnEnter", function(self)
    Tip(self, L["Auto"], L["Each quest you accept is proposed for the Roadbook list (a window asks each time)."])
  end)
  auto:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.auto = auto
  track:SetHitRectInsets(0, -((track.label:GetStringWidth() or 40) + 2), 0, 0)
  track:SetScript("OnClick", function()
    if Geo.Tracking() then CP.TrackOff() else CP.TrackOn() end
    Geo.MapPanelSync()
  end)
  track:SetScript("OnEnter", function(self)
    Tip(self, L["Tracking"], L["On: the Objective button, the map pin and the watched quest follow the Roadbook. Off: they stop and the Roadbook is only computed again by the Recompute icon or a change of its list (greyed steps). Turning it on computes the steps to come again."])
  end)
  track:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.track = track
  -- Header (information) shown or hidden.
  local info = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  info:SetSize(20, 20)
  info.label = info:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  info.label:SetText(L["Info"])
  info.label:SetPoint("RIGHT", auto, "LEFT", -6, 0)
  info:SetPoint("RIGHT", info.label, "LEFT", -2, 0)
  info:SetHitRectInsets(0, -((info.label:GetStringWidth() or 30) + 2), 0, 0)
  info:SetScript("OnClick", function(self)
    Settings().stepsHeaderHidden = (not self:GetChecked()) or nil
    GameTooltip:Hide()
    Geo.MapPanelHeaderSync()
    UpdateScrollBar(panel.scroll)
  end)
  info:SetScript("OnEnter", function(self)
    Tip(self, L["Info"], L["Shows or hides the information at the top of the panel (quests, steps, XP, travel, warnings)."])
  end)
  info:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.info = info
  panel.titleText:SetPoint("RIGHT", info, "LEFT", -4, 0)
  panel.titleText:SetJustifyH("LEFT")
  panel.titleText:SetWordWrap(false)
  -- Header: size and progress, XP, travel, what to watch.
  panel.header = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  panel.header:SetPoint("TOPLEFT", 10, -K.MAP_PANEL_TITLE)
  panel.header:SetWidth(K.MAP_PANEL_W - 20)
  panel.header:SetJustifyH("LEFT")
  panel.header:SetSpacing(2)
  -- Option: steps done hidden.
  local hideDone = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  hideDone:SetSize(20, 20)
  hideDone.label = hideDone:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hideDone.label:SetPoint("LEFT", hideDone, "RIGHT", 2, 0)
  hideDone.label:SetText(L["Hide the finished steps"])
  hideDone:SetScript("OnClick", function(self)
    Settings().stepsHideDone = self:GetChecked() or nil
    panel.scrollKey = nil -- scrolled to the objective again
    Geo.MapPanelSync()
  end)
  panel.hideDone = hideDone
  panel.rule = panel:CreateTexture(nil, "ARTWORK")
  panel.rule:SetColorTexture(1, 0.82, 0, 0.35)
  panel.rule:SetHeight(1)
  local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("BOTTOMRIGHT", -26, 8)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(K.MAP_PANEL_W - 32, 1)
  scroll:SetScrollChild(child)
  scroll.child = child
  scroll:HookScript("OnScrollRangeChanged", UpdateScrollBar) -- scroll bar shown only when useful
  panel.scroll, panel.child, panel.rows = scroll, child, {}
  -- Resize handle in the middle of the bottom edge: a discreet bar, brighter on hover.
  local grip = CreateFrame("Button", nil, panel)
  grip:SetSize(60, 10)
  grip:SetPoint("BOTTOM", 0, 1)
  grip:SetFrameLevel(scroll:GetFrameLevel() + 5)
  grip.bar = grip:CreateTexture(nil, "OVERLAY")
  grip.bar:SetSize(40, 3)
  grip.bar:SetPoint("CENTER")
  grip.bar:SetColorTexture(1, 0.82, 0, 0.45)
  grip:SetScript("OnEnter", function(self)
    self.bar:SetColorTexture(1, 0.9, 0.4, 0.9)
  end)
  grip:SetScript("OnLeave", function(self)
    self.bar:SetColorTexture(1, 0.82, 0, 0.45)
  end)
  grip:SetScript("OnMouseDown", function() panel:StartSizing("BOTTOM") end)
  grip:SetScript("OnMouseUp", function()
    panel:StopMovingOrSizing()
    SavePlace()
    UpdateScrollBar(scroll)
  end)
  -- The header's hearthstone and teleport cooldowns tick while it is shown.
  local elapsed = 0
  panel:SetScript("OnUpdate", function(_, e)
    elapsed = elapsed + e
    if elapsed >= 5 then
      elapsed = 0
      Geo.MapPanelHeaderSync()
    end
  end)
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------
-- Second line of a step: its zone, and its XP.
local function SubText(s)
  local zone = s.p and (s.p.instance or AreaName(s.p.area) or s.p.zoneName) or "?"
  local xp = Geo.StepXP(s)
  return xp and (zone .. K.DESC_SEP .. xp) or zone
end

-- A text without its colour codes (step done: all grey).
local function Plain(s)
  return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Header text again (cooldowns), the option and the list placed under it; folded (-/+ button):
-- only the list, under the title bar.
function Geo.MapPanelHeaderSync()
  if not (panel and panel:IsShown()) then return end
  local fz = Geo.Frozen()
  if not fz then return end
  local done = 0
  for i = 2, #fz.route do if CP.StepDone(fz.route[i]) then done = done + 1 end end
  local folded = Settings().stepsHeaderHidden
  panel.info:SetChecked(not folded)
  panel.header:SetShown(not folded)
  local top = K.MAP_PANEL_TITLE - 2
  if not folded then
    local ok, text = pcall(Geo.MapPanelHeader, fz.route, fz.info, done)
    panel.header:SetText(ok and text or "")
    top = K.MAP_PANEL_TITLE + (panel.header:GetStringHeight() or 0) + 4
  end
  panel.hideDone:ClearAllPoints()
  panel.hideDone:SetPoint("TOPLEFT", 6, -top)
  top = top + 22
  panel.rule:ClearAllPoints()
  panel.rule:SetPoint("TOPLEFT", 6, -top)
  panel.rule:SetPoint("TOPRIGHT", -6, -top)
  panel.scroll:SetPoint("TOPLEFT", 6, -top - 4)
end

-- Fills the panel with the saved Roadbook, or hides it (no Roadbook, or hidden by the Objective or
-- Steps button).
function Geo.MapPanelSync()
  if Settings().stepsHidden or not Geo.MapPanelShown() then
    if panel then panel:Hide() end
    return
  end
  -- Placed when it appears (a new frame counts as shown: placed at its creation too).
  if not panel then
    Create()
    Geo.MapPanelPlace()
  elseif not panel:IsShown() then
    Geo.MapPanelPlace()
  end
  panel:Show()
  local route = Geo.Frozen().route
  local cur = CP.CurrentFocus()
  local rows, width = panel.rows, K.MAP_PANEL_W - 32
  local hideDone = Settings().stepsHideDone
  local following = Geo.Tracking()
  panel.hideDone:SetChecked(hideDone and true or false)
  local n, target, total = 0, nil, 0
  for i = 2, #route do
    local st = route[i]
    -- Steps done hidden (option): the numbers stay those of the pins (steps not done).
    if not (hideDone and CP.StepDone(st)) then
      total = total + 1
      local r = rows[total] or NewRow(panel.child)
      rows[total] = r
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", 0, -(total - 1) * K.MAP_PANEL_ROW)
      r:SetWidth(width)
      local isDone = CP.StepDone(st)
      local title = CP.StepSummary(st)
      local c = K.MAP_COLOR[st.kind] or K.MAP_COLOR.other
      local grey = isDone or not following -- not tracked: the steps are greyed (not updated)
      r.bar:SetColorTexture(c[1], c[2], c[3], grey and 0.3 or 0.9)
      r.step = st
      if isDone then
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
        r.title:SetText(following and title or Color("808080", Plain(title)))
        r.sub:SetText(following and SubText(st) or Color("808080", Plain(SubText(st))))
        if not target then target = total end -- first step not done
      end
      local isCur = st == cur
      if isCur then target = total end
      r.current:SetShown(isCur)
      if following then r.num:SetTextColor(isCur and 0.4 or 1, 1, isCur and 0.4 or 1) else r.num:SetTextColor(0.5, 0.5, 0.5) end
      r.time:SetText(FormatTime(math.max(0, (st.at or 0) - (route[i - 1].at or 0)))) -- the step alone
      r:Show()
    end
  end
  for i = total + 1, #rows do rows[i]:Hide() rows[i].step = nil end
  panel.child:SetHeight(math.max(1, total * K.MAP_PANEL_ROW))
  Geo.MapPanelHeaderSync()
  UpdateScrollBar(panel.scroll)
  panel.track:SetChecked(following)
  panel.auto:SetChecked(Settings().autoAdd and true or false)
  panel.track:SetEnabled(not State.computing and (following or not Geo.IsFinished()))
  panel.emptyB:SetEnabled(not State.computing)
  panel.recalc:SetEnabled(not State.computing and true or false)
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
