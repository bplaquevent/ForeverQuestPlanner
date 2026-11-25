-- Forever Quest Planner: the floating Objective button: a step's description, its click, the compass,
-- the service shortcuts under it.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, ActivePin, CP, Color, Dist, FormatTime, GeoReady = ns.Geo, ns.ActivePin, ns.CP, ns.Color, ns.Dist, ns.FormatTime, ns.GeoReady
local GetObjectives, ICON, IsInLog, K, L, PlayerPos, PointText = ns.GetObjectives, ns.ICON, ns.IsInLog, ns.K, ns.L, ns.PlayerPos, ns.PointText
local Print, Refresh, Settings, State, TurnInText = ns.Print, ns.Refresh, ns.Settings, ns.State, ns.TurnInText

-- Click on the button. Roadbook being computed: nothing (until it is computed and tracked), unless it
-- is adapted while followed (the followed step stays shown, the click works on it). No
-- Roadbook: the window opens on its tab, where one is made. Roadbook not followed: it starts and
-- the steps panel (RoadbookPanel.lua) is shown. Followed: the steps panel is shown or hidden.
-- Left click: the map opens on the followed step (closed when already open); a Roadbook not followed is tracked (the steps
-- panel shown, the map left closed). Right click: the steps panel shown or hidden.
function CP.ObjectiveClickUnsafe(button)
  -- Roadbook being computed: nothing, unless it is adapted while followed (its step stays shown).
  if State.computing and not (Geo.Tracking() and CP.CurrentFocus()) then return end
  if not Geo.Frozen() then
    CP.ShowActive()
    return
  end
  if button == "RightButton" then
    Geo.MapPanelOpen(true)
    return
  end
  if not Geo.Tracking() then
    if Geo.IsFinished() then
      CP.FinishedMessage()
      CP.ShowActive()
      return
    end
    CP.DoTrackOn() -- tracking only: the map does not open
    Geo.MapPanelOpen(false)
    return
  end
  -- Map already open: the click closes it.
  if WorldMapFrame and WorldMapFrame:IsShown() then
    if ToggleWorldMap then pcall(ToggleWorldMap) else WorldMapFrame:Hide() end
    return
  end
  local s = CP.CurrentFocus()
  if s then Geo.ShowStep(s) else Geo.MapPanelOpen(false) end
end

function CP.ObjectiveClick(button)
  local ok, err = xpcall(function() CP.ObjectiveClickUnsafe(button) end, function(e)
    return tostring(e) .. (debugstack and ("\n" .. debugstack(2, 3, 0)) or "")
  end)
  if not ok then Print(L["|cffff6060Error while validating the checkpoint|r (copy it to report it):\n"] .. err) end
end

-- Teleport step (kind "hearth"): icon and what to do (parts of the description).
function Geo.RecallText(s)
  local spell = s.task and s.task.spell
  local saves = L["saves ~"] .. FormatTime(s.gain or 0)
  if not spell then
    return "|TInterface\\Icons\\INV_Misc_Rune_01:14:14|t", { L["Use the hearthstone"], saves }
  end
  local tex = Geo.SpellIcon(spell) or "Interface\\Icons\\Spell_Arcane_TeleportStormWind"
  local name = Geo.SpellName(spell) or ("#" .. spell)
  return "|T" .. tex .. ":14:14|t", { L["Cast "] .. name, saves }
end

-- Summary of a step: its title, then the parts of its description (each display joins them its way).
function CP.StepSummary(s)
  local task = s.task
  local function nameOnly(t) return t and (t:match("^(.-) %- ") or t) or nil end
  -- Parts as a list, the missing ones left out.
  local function parts(...)
    local out = {}
    for i = 1, select("#", ...) do
      local part = select(i, ...)
      if part then out[#out + 1] = part end
    end
    return out
  end
  local place = PointText(s.p)
  if s.kind == "bind" then
    return "|TInterface\\Minimap\\Tracking\\Innkeeper:14:14|t " .. (task.title or "?"),
      parts(L["Talk to "] .. (task.npc or "?"), place)
  elseif s.kind == "hearth" then
    local icon, action = Geo.RecallText(s)
    return icon .. " " .. (task.title or "?"), action
  elseif s.kind == "travel" then
    return "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t " .. (task.mode == "flight" and L["Flight"] or K.MODE_NAME[task.mode] or task.mode or L["Transport"]) ..
      L[" to "] .. (task.dest or "?"), parts(L["Departure: "] .. (task.from or "?"), place)
  elseif s.kind == "dungeon" then
    local left = 0
    for _, m in ipairs(task.members or {}) do if not CP.StepDone(m) then left = left + 1 end end
    return K.DUNGEON_ICON .. " " .. (task.title or "?"),
      parts(string.format(L["%d quest step(s) inside"], left), place, "~" .. FormatTime(s.work or 0))
  elseif s.kind == "skill" then
    local sk = s.skill
    return "|TInterface\\Icons\\INV_Misc_Book_11:14:14|t " .. string.format(L["Raise the %s skill to level %d"], sk.name, sk.need),
      parts(s.npc and (L["Train with "] .. s.npc) or L["trainer not located"], s.npc and place or nil,
        string.format(L["skill %d/%d"], sk.have, sk.need), task.title)
  elseif s.kind == "service" then
    local icon = "Interface\\Icons\\INV_Misc_Coin_01"
    for _, def in ipairs(K.SERVICES) do if def.key == task.service then icon = def.icon end end
    return "|T" .. icon .. ":14:14|t " .. (task.title or "?"), parts(L["Talk to "] .. (task.npc or "?"), place)
  elseif s.kind == "fm" then
    return "|TInterface\\Minimap\\Tracking\\FlightMaster:14:14|t " .. (task.title or L["Flight Master"]),
      parts(L["Talk to "] .. (task.npc or "?"), place)
  elseif s.escort and CP.IsFailed(task.id) then
    return K.ESCORT_ICON .. " " .. (task.title or "?"),
      parts(Color(K.DESC.bad, L["Escort failed: abandon the quest and pick it up again"]))
  elseif s.escort then
    local dest = s.kind == "turnin" and (L[", then turn in to "] .. (nameOnly(TurnInText(task.id)) or "?")) or ""
    local xp = s.kind == "turnin" and Geo.XPText(task.xp) or nil
    return K.ESCORT_ICON .. " " .. L["Escort: "] .. (task.title or "?"),
      parts(L["Stay close to "] .. CP.EscortNpc(task) .. dest, place, xp)
  elseif s.kind == "take" then
    local out = parts((s.search and L["Look for "] or L["Pick up from "]) .. (nameOnly(task.starter) or "?"), place)
    if s.search then
      out[#out + 1] = Color(K.DESC.warn, string.format(L["possible place %d/%d"], s.search.i, s.search.n))
    end
    if CP.IsFailed(task.id) then out[#out + 1] = Color(K.DESC.bad, L["failed: abandon it first"])
    elseif Geo.IsEscort(task.id) then out[#out + 1] = Color(K.DESC.warn, L["escort"]) end
    if task.reqLevel then out[#out + 1] = Color(K.DESC.warn, string.format(L["level %d required"], task.reqLevel)) end
    return ICON.available .. " " .. (task.title or "?"), out
  elseif s.kind == "obj" then
    local name = s.r and s.r.tg.name or L["objective"]
    local prog = "x" .. (s.r and s.r.count or "?")
    local o = task.id and IsInLog(task.id) and Geo.TargetObjective(task.id, s.r and s.r.tg, GetObjectives(task.id))
    if o and o.need then prog = (o.have or 0) .. "/" .. o.need end
    local multi = (s.spots and s.spots > 1) and (L["multiple spots ("] .. s.spots .. ")") or nil
    return ICON.inprogress .. " " .. (task.title or "?"), parts(name .. " " .. prog, place, multi)
  end
  local xp = Geo.XPText(task.xp)
  return ICON.turnin .. " " .. (task.title or "?"),
    parts(L["Turn in to "] .. (nameOnly(TurnInText(task.id)) or "?"), place, xp)
end

function CP.RefreshButton()
  Geo.MapSync() -- the Roadbook on the map follows its progress
  local b = CP.checkpointButton
  if not (b and b.title) then return end
  local s = CP.CurrentFocus()
  if State.computing and not s then
    -- Roadbook being computed with no step followed (being computed, start…): the click does nothing.
    b.title:SetText(L["Objective"])
    b.sub:SetText(L["Recomputing…"])
    b.current = nil
  elseif s then
    local t, d = CP.StepSummary(s)
    local maxW = K.OBJECTIVE_MAX_WIDTH - K.OBJECTIVE_TEXT_X - 10
    -- White title, as in the tabs; quest step: then the same badges (colored level, elite), too wide:
    -- on the next line; the quest types on the first line of the details (same font).
    local types = ""
    if not (s.task and s.task.id) then
      t = Color("ffffff", t)
    else
      local badges = Geo.QuestBadges({ id = s.task.id, level = s.task.level, noTypes = true })
      local full = Color("ffffff", t) .. badges
      if CP.TextWidth(b.title, full) > maxW then full = Color("ffffff", t) .. "\n" .. badges:gsub("^%s+", "") end
      types = Geo.QuestTypesText(s.task.id)
      t = full
    end
    b.title:SetText(t)
    local sub = CP.PackInfos(b.sub, d, maxW)
    if types ~= "" then sub = types .. ((sub and sub ~= "") and ("\n" .. sub) or "") end
    -- Roadbook adapted while followed: the step stays shown meanwhile, replaced at the end if needed.
    if State.computing then sub = Color("ffd100", L["Recomputing…"]) .. ((sub and sub ~= "") and ("\n" .. sub) or "") end
    b.sub:SetText(sub)
    b.current = s
  else
    b.title:SetText(L["Objective"])
    b.sub:SetText(L["No objective tracked · click to start"])
    b.current = nil
  end
  -- Width fitted to the widest line, at most K.OBJECTIVE_MAX_WIDTH; the height follows the number of
  -- lines (at least 56 px, text vertically centered).
  local function Natural(fs) return CP.TextWidth(fs, fs:GetText() or "") end
  local w = math.max(Natural(b.title), Natural(b.sub))
  local width = math.min(math.max(K.OBJECTIVE_TEXT_X + w + 14, 230), K.OBJECTIVE_MAX_WIDTH)
  local textW = width - K.OBJECTIVE_TEXT_X - 10
  b.title:SetWidth(textW)
  b.sub:SetWidth(textW)
  local textH = (b.title:GetStringHeight() or 12) + 3 + (b.sub:GetStringHeight() or 10)
  local height = math.max(56, textH + 16)
  b:SetSize(width, height)
  b.title:ClearAllPoints()
  b.title:SetPoint("TOPLEFT", b, "TOPLEFT", K.OBJECTIVE_TEXT_X, -math.floor((height - textH) / 2))
  b.compassTarget = CP.CompassTarget()
  CP.ServiceBarSync()
end

K.OBJECTIVE_TEXT_X = 59       -- text of the Objective button, right of the compass square
K.OBJECTIVE_MAX_WIDTH = 380   -- widest Objective button (beyond, one information per line)

-- Width of a text in a font string, on one line.
function CP.TextWidth(fs, text)
  fs:SetWidth(2000)
  fs:SetText(text)
  return fs:GetStringWidth() or 0
end

-- Upper case first letter (ASCII or accented French letter, after any color code).
K.UPPER_ACCENTS = { ["é"] = "É", ["è"] = "È", ["ê"] = "Ê", ["à"] = "À", ["â"] = "Â", ["î"] = "Î", ["ô"] = "Ô",
  ["û"] = "Û", ["ç"] = "Ç" }
function CP.Capitalize(line)
  local prefix, rest = "", line
  while rest:find("^|c%x%x%x%x%x%x%x%x") do -- Lua patterns cannot repeat a group
    prefix, rest = prefix .. rest:sub(1, 10), rest:sub(11)
  end
  local first, tail = rest:match("^([%z\1-\127\194-\244][\128-\191]*)(.*)$")
  if not first then return line end
  return prefix .. (K.UPPER_ACCENTS[first] or first:upper()) .. tail
end

-- The parts of a description on one line, or, wider than maxW, one per line (never cut inside one),
-- each line starting with an upper case letter.
function CP.PackInfos(fs, parts, maxW)
  local text = table.concat(parts or {}, K.DESC_SEP)
  if CP.TextWidth(fs, text) <= maxW then return text end
  local lines = {}
  for i, part in ipairs(parts) do lines[i] = CP.Capitalize(part) end
  return table.concat(lines, "\n")
end

-- Compass target, in world coordinates: the active pin, otherwise the focused step.
function CP.CompassTarget()
  if Settings().compass == false then return nil end
  local s = CP.checkpointButton and CP.checkpointButton.current
  if not s then return nil end -- no objective followed: no compass
  local pin = ActivePin()
  if pin and pin.ui and pin.x and C_Map.GetWorldPosFromMapPos and CreateVector2D then
    local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, pin.ui, CreateVector2D(pin.x, pin.y))
    if ok and cont and w then
      local x, y = w:GetXY()
      return { c = cont, x = x, y = y }
    end
  end
  if s.p and s.p.c and s.p.x then return s.p end
  return nil
end

-- Rotates the arrow every frame. World coordinates: x towards the north, y towards
-- the west; GetPlayerFacing: 0 = north, counterclockwise, like SetRotation.
function CP.UpdateCompass(b)
  local t = b.compassTarget
  local me = t and PlayerPos()
  local facing = me and GetPlayerFacing and GetPlayerFacing()
  local d = facing and Dist(me, t) -- nil on another continent or in an instance
  if not d then
    b.arrow:Hide()
    b.dist:Hide()
    b.icon:Show()
    return
  end
  b.icon:Hide()
  b.arrow:Show()
  b.dist:Show()
  b.dist:SetText(d < 1000 and string.format(L["%d yd"], d) or string.format(L["%.1f kyd"], d / 1000))
  if d < 5 then
    b.arrow:SetRotation(0)
    b.arrow:SetVertexColor(0.25, 1, 0.25) -- arrived: green
  else
    b.arrow:SetRotation(math.atan2(t.y - me.y, t.x - me.x) - facing)
    b.arrow:SetVertexColor(1, 0.82, 0)
  end
end

-- Centers the Objective button horizontally on the screen, keeping its height.
function CP.CenterCheckpointButton()
  CP.CreateCheckpointButton()
  local b = CP.checkpointButton
  if not b then return end
  local _, cy = b:GetCenter()
  if not cy then return end
  local y = cy * b:GetEffectiveScale() / UIParent:GetEffectiveScale() - UIParent:GetHeight() / 2
  b:ClearAllPoints()
  b:SetPoint("CENTER", UIParent, "CENTER", 0, y)
  Settings().checkpointPos = { "CENTER", 0, y }
end

function CP.UpdateCheckpointButton()
  if not CP.checkpointButton then return end
  CP.checkpointButton:SetShown(CP.CHECKPOINT_TOGGLE.get())
end

function CP.CreateCheckpointButton()
  if CP.checkpointButton then return end
  local b = CreateFrame("Button", "ForeverQuestPlannerCheckpoint", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  b:SetSize(230, 56)
  -- Dark tooltip-like frame, golden border (the style of every window of the addon).
  Geo.FrameStyle(b)
  -- Framed icon (compass square), vertically centered whatever the height of the button.
  local frameTex = b:CreateTexture(nil, "ARTWORK")
  frameTex:SetSize(44, 44)
  local function PlaceIcon(dx, dy)
    frameTex:ClearAllPoints()
    frameTex:SetPoint("LEFT", b, "LEFT", 7 + dx, dy)
  end
  PlaceIcon(0, 0)
  frameTex:SetColorTexture(0, 0, 0, 0.8)
  local icon = b:CreateTexture(nil, "OVERLAY")
  icon:SetPoint("TOPLEFT", frameTex, "TOPLEFT", 1, -1)
  icon:SetPoint("BOTTOMRIGHT", frameTex, "BOTTOMRIGHT", -1, 1)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
  if icon.SetTexCoord then icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
  b.icon = icon
  -- Compass: arrow pointing at the active marker, with the distance below.
  local arrow = b:CreateTexture(nil, "OVERLAY")
  arrow:SetSize(36, 36)
  arrow:SetPoint("CENTER", frameTex, "CENTER", 0, 4)
  arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
  arrow:SetVertexColor(1, 0.82, 0)
  arrow:Hide()
  local dist = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dist:SetPoint("BOTTOM", frameTex, "BOTTOM", 0, 1)
  dist:SetScale(0.85)
  dist:Hide()
  b.arrow, b.dist = arrow, dist
  local elapsed = 1
  b:SetScript("OnUpdate", function(_, e)
    elapsed = elapsed + e
    if elapsed >= 0.5 then -- target and player zone: twice per second is enough
      elapsed = 0
      b.compassTarget = CP.CompassTarget()
    end
    CP.UpdateCompass(b)
  end)
  -- Golden title + gray subtitle.
  local title = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", b, "TOPLEFT", K.OBJECTIVE_TEXT_X, -8)
  title:SetJustifyH("LEFT")
  title:SetText(L["Objective"])
  local sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  sub:SetJustifyH("LEFT")
  sub:SetTextColor(0.75, 0.75, 0.75)
  sub:SetText(L["No objective tracked · click to start"])
  title:SetWordWrap(true)
  sub:SetWordWrap(true)
  b.label, b.title, b.sub = L["Objective"], title, sub
  -- Hover: soft highlight and lighter border; click: slight press.
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", 4, -4)
  hl:SetPoint("BOTTOMRIGHT", -4, 4)
  hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  hl:SetBlendMode("ADD")
  hl:SetAlpha(0.35)
  b:SetScript("OnMouseDown", function() PlaceIcon(1, -1) end)
  b:SetScript("OnMouseUp", function() PlaceIcon(0, 0) end)
  b.HoverIn = function()
    local c = K.FRAME_BORDER_HOVER
    if b.SetBackdropBorderColor then b:SetBackdropBorderColor(c[1], c[2], c[3], c[4]) end
  end
  b.HoverOut = function()
    local c = K.FRAME_BORDER
    if b.SetBackdropBorderColor then b:SetBackdropBorderColor(c[1], c[2], c[3], c[4]) end
  end
  b:SetFrameStrata("MEDIUM")
  b:SetMovable(true)
  b:SetClampedToScreen(true)
  b:RegisterForDrag("LeftButton")
  local pos = Settings().checkpointPos
  if pos then b:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3]) else b:SetPoint("CENTER", UIParent, "CENTER", 0, -220) end
  b:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown and IsShiftKeyDown() then self:StartMoving() end -- Shift + drag: move the button
  end)
  b:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self.dragEnd = GetTime() -- the release of a Shift-drag must not count as a click
    local point, _, _, x, y = self:GetPoint()
    Settings().checkpointPos = { point, x, y }
  end)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(_, button)
    if b.dragEnd and GetTime and GetTime() - b.dragEnd < 0.3 then return end -- release of a Shift-drag
    CP.ObjectiveClick(button)
  end)
  b:SetScript("OnEnter", function(self)
    if self.HoverIn then self.HoverIn() end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(L["Objective"])
    GameTooltip:AddLine(L["Click: open or close the map on the objective"], 1, 1, 1)
    GameTooltip:AddLine(L["Right-click: the steps"], 1, 1, 1)
    GameTooltip:AddLine(L["Shift-drag: move"], 0.75, 0.75, 0.75)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    if self.HoverOut then self.HoverOut() end
    GameTooltip:Hide()
  end)
  CP.checkpointButton = b
  CP.CreateServiceBar(b)
  CP.UpdateCheckpointButton()
  CP.RefreshButton()
end

---------------------------------------------------------------------------
-- Service shortcuts under the Objective button: vendor, repair, class trainer
---------------------------------------------------------------------------
K.SERVICE_ICON_SIZE = 26
-- While the Roadbook is computed, what would change it is greyed (consulting stays): why.
K.LOCKED_TIP = L["The Roadbook is being computed: it can be changed when it is ready."]

-- Click: the nearest NPC of the service becomes the priority objective and the Roadbook is
-- planned again (transport steps to reach it, then the rest). A second click on the pending
-- service cancels it.
function CP.ServiceClick(kind)
  if CP.RefuseWhileComputing() then return end
  if not GeoReady() then
    Print(L["Unable to convert QuestieDB positions to this client's map."])
    return
  end
  local cur = Geo.ServicePending()
  if cur and cur.kind == kind then
    Geo.ServiceClear()
    CP.ServiceBarSync()
    if #Geo.CustomList() == 0 then -- nothing left in the Roadbook but the service
      CP.TrackOff(true)
      if not Geo.KeepOnlyDone() then Geo.ClearFrozen() end
      CP.RefreshButton()
      Refresh()
    elseif not CP.Replan(L["Service cancelled. "]) then
      Refresh()
    end
    return
  end
  local npc = Geo.NearestService(kind)
  if not npc then
    Print(L["No such place found."])
    return
  end
  Geo.ServiceSet({ kind = kind, id = npc.id, name = npc.name, p = npc.p })
  CP.ServiceBarSync()
  CP.turningOn = true -- going to the service means following the Roadbook
  local started = CP.Replan(string.format(L["Going to %s first. "], npc.name or "?"))
  CP.turningOn = nil
  if not started then
    Geo.ServiceClear()
    CP.ServiceBarSync()
  end
end

-- Highlight of the pending service; icons greyed while the Roadbook is computed.
function CP.ServiceBarSync()
  local bar = CP.serviceBar
  if not bar then return end
  local cur = Geo.ServicePending()
  for _, ib in ipairs(bar.buttons) do
    ib.glow:SetShown(cur ~= nil and cur.kind == ib.key)
    ib.icon:SetDesaturated(State.computing and true or false)
    ib.icon:SetAlpha(State.computing and 0.5 or 1)
  end
end

function CP.CreateServiceBar(b)
  local n, size, gap = #K.SERVICES, K.SERVICE_ICON_SIZE, 4
  local bar = CreateFrame("Frame", nil, b)
  bar:SetSize(n * size + (n - 1) * gap, size)
  bar:SetPoint("TOP", b, "BOTTOM", 0, -3)
  bar.buttons = {}
  for i, def in ipairs(K.SERVICES) do
    local ib = CreateFrame("Button", nil, bar, BackdropTemplateMixin and "BackdropTemplate" or nil)
    ib:SetSize(size, size)
    ib:SetPoint("LEFT", bar, "LEFT", (i - 1) * (size + gap), 0)
    Geo.FrameStyle(ib)
    local tex = ib:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 3, -3)
    tex:SetPoint("BOTTOMRIGHT", -3, 3)
    tex:SetTexture(def.icon)
    if tex.SetTexCoord then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    local glow = ib:CreateTexture(nil, "OVERLAY")
    glow:SetPoint("TOPLEFT", -2, 2)
    glow:SetPoint("BOTTOMRIGHT", 2, -2)
    glow:SetColorTexture(1, 0.82, 0, 0.35)
    glow:Hide()
    local hl = ib:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(tex)
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    ib.key, ib.glow, ib.icon = def.key, glow, tex
    ib:RegisterForClicks("LeftButtonUp")
    ib:SetScript("OnClick", function() CP.ServiceClick(def.key) end)
    ib:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(def.label)
      local ok, npc = pcall(Geo.NearestService, def.key)
      if ok and npc then
        GameTooltip:AddLine(string.format(L["Nearest: %s (~%s)"], npc.name or "?", FormatTime(npc.time or 0)), 1, 1, 1)
      else
        GameTooltip:AddLine(L["No such place found."], 1, 0.4, 0.4)
      end
      local cur = Geo.ServicePending()
      if State.computing then
        GameTooltip:AddLine(K.LOCKED_TIP, 1, 0.82, 0, true)
      else
        GameTooltip:AddLine((cur and cur.kind == def.key) and L["Click: cancel this priority"]
          or L["Click: go there first, then carry on with the Roadbook"], 0.75, 0.75, 0.75)
      end
      GameTooltip:Show()
    end)
    ib:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bar.buttons[i] = ib
  end
  CP.serviceBar = bar
end

CP.CHECKPOINT_TOGGLE = {
  label = L["Show objective"],
  get = function() return Settings().checkpoint ~= false end, -- shown by default
  set = function(v)
    Settings().checkpoint = v and true or false
    CP.CreateCheckpointButton()
    CP.UpdateCheckpointButton()
  end,
}
