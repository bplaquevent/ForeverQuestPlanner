-- Forever Quest Planner: the Roadbook on OpenMap's world map.
-- The names shared between files are published in ns at the end of each file (load order: .toc).
--
-- A Roadbook "holds" the map while it is followed (mode "track") or previewed (mode "preview", a click
-- on a step of the Roadbook): its remaining steps are drawn as numbered pins joined by its route, in
-- pin sets of its own on OpenMap's stitched map (only it creates, updates or clears them), the
-- current objective highlighted. Meanwhile the player's OpenMap pins are hidden (OpenMap's own
-- switch: the player can show them again and add pins); when the Roadbook lets the map go, the map
-- gets back what it showed before (the player's pins shown or hidden as they were, and the waypoint
-- followed before tracking). OpenMap's functions are called, never replaced.
-- The drawing uses OpenMap's own pin sets (MapStitch, checked at load, OpenMapLink.lua): its public API
-- places frames on the game's map canvas, which OpenMap makes see-through in a fight.

local ADDON_NAME, ns = ...
local CP, ClearPin, Geo, K, L, OM, IsInLog, Print, Settings = ns.CP, ns.ClearPin, ns.Geo, ns.K, ns.L, ns.OM, ns.IsInLog, ns.Print, ns.Settings
local Guard = ns.Guard

K.MAP_SET = "fqp_roadbook"             -- OpenMap pin set of the steps
K.MAP_ROUTE_SET = "fqp_roadbook_route" -- and of the route (under the pins)
K.MAP_LINE = 3                         -- px: route thickness
K.MAP_JUMP_LINE = 2                    -- px: thickness of a jump (hearthstone, teleport)
K.MAP_PLAYER_SET = "fqp_roadbook_player" -- OpenMap pin set of the line from the player to the next step
-- Route colour by kind of move (r, g, b, a): the Roadbook's own colours.
K.MAP_MOVE = {
  walk = { 1, 0.82, 0.2, 0.85 },       -- on foot
  flight = { 0.4, 0.72, 1, 0.85 },     -- flight
  ship = { 0.3, 0.9, 0.85, 0.85 },     -- boat, zeppelin, airship
  hearth = { 0.78, 0.56, 1, 0.8 },     -- hearthstone
  teleport = { 1, 0.5, 0.85, 0.8 },    -- teleport spells
}
-- Pin colour by step kind (the current objective: the game's tracked pin, uncoloured).
K.MAP_COLOR = {
  take = { 1, 0.85, 0.2 }, obj = { 1, 0.45, 0.3 }, turnin = { 0.45, 0.95, 0.4 },
  dungeon = { 0.82, 0.55, 1 }, other = { 0.45, 0.72, 1 },
}

---------------------------------------------------------------------------
-- Who holds the map: { mode = "track" | "preview", hidden, wp, tookWp }, saved per character
-- (a /reload in the middle gives the map back at login). hidden / wp: the map's state before.
---------------------------------------------------------------------------
function Geo.MapOwner()
  return Settings().mapSaved
end

-- The Roadbook takes the map. The map's state is saved only the first time: a preview that
-- becomes the tracking keeps the state from before the preview.
function Geo.MapClaim(mode)
  local saved = Geo.MapOwner()
  if not saved then
    local m, x, y = OM.WaypointPoint()
    saved = { hidden = OM.PinsHidden() and true or false, wp = (m and x) and { m, x, y } or nil }
    Settings().mapSaved = saved
    Guard(OM.SetPinsHidden, true)
  end
  if mode == "track" then saved.tookWp = true end -- the tracking moves the waypoint
  saved.mode = mode
  Geo.MapSync()
end

-- The Roadbook lets the map go: its pins and route cleared, the player's pins shown or hidden as
-- before, and the waypoint followed before the tracking put back.
function Geo.MapRelease()
  local saved = Geo.MapOwner()
  if not saved then return end
  Settings().mapSaved = nil
  Geo.MapClear()
  Guard(OM.SetPinsHidden, saved.hidden)
  if saved.tookWp then
    ClearPin()
    if saved.wp then Guard(OM.TrackPoint, saved.wp[1], saved.wp[2], saved.wp[3]) end
  end
  Guard(OM.RefreshWaypoint)
  if Geo.MapPanelSync then Guard(Geo.MapPanelSync) end -- the panel goes back to the active Roadbook
end

-- USER_WAYPOINT_UPDATED while a Roadbook is followed: another waypoint replaced ours, ours goes
-- back. A waypoint cleared (the game does it on arrival) is left as it is: the focus stays.
function Geo.MapOnWaypoint()
  local o, r = Geo.MapOwner(), Geo.PinRecord()
  if not (o and o.mode == "track" and r and r.ui) or Geo.mapRestoring then return end
  local m = OM.WaypointPoint()
  if m and not Geo.WaypointAt(r.ui, r.x, r.y) then
    Geo.mapRestoring = true
    Guard(OM.TrackPoint, r.ui, r.x, r.y, r.title)
    Geo.mapRestoring = nil
  end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local sets -- { pins, lines }: created once OpenMap's stitched map is built

local function Sets()
  if sets then return sets end
  if not OM.MapBuilt() then return nil end
  local okP, pins = Guard(OM.PinSet, K.MAP_SET, 6)
  local okL, lines = Guard(OM.PinSet, K.MAP_ROUTE_SET, 1)
  local okY, player = Guard(OM.PinSet, K.MAP_PLAYER_SET, 2)
  if not (okP and okL and okY and pins and lines and player) then return nil end
  sets = { pins = pins, lines = lines, player = player }
  return sets
end

function Geo.MapClear()
  if not sets then return end
  OM.ClearPinSet(sets.pins)
  OM.ClearPinSet(sets.lines)
  OM.ClearPinSet(sets.player)
end

-- A step's point on OpenMap's stitched world (u, v), or nil.
function Geo.MapUV(p)
  if not p then return nil end
  local ui = Geo.PointUi(p)
  if ui and p.mx and p.my then
    local u, v = OM.WorldFromMap(ui, p.mx / 100, p.my / 100)
    if u then return u, v end
  end
  if p.c and p.x and p.y then
    local ok, u, v = Guard(OM.FromYards, p.c, p.x, p.y)
    if ok and u then return u, v end
  end
  return nil
end

-- A step's tooltip (pins on the map, lines of the steps panel): its title and details
-- (Geo.StepDetailLines); n = its number (nil: done), hint: the last lines (what a click does).
function Geo.StepTooltip(owner, st, n, hint, anchor)
  GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
  GameTooltip:AddLine(n and string.format(L["Roadbook step %d"], n) or L["Roadbook step done"], 0.6, 0.8, 1)
  GameTooltip:AddLine((CP.StepSummary(st)), 1, 1, 1)
  local okD, lines = Guard(Geo.StepDetailLines, st)
  for _, line in ipairs(okD and lines or {}) do GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true) end
  for line in (hint .. "\n"):gmatch("(.-)\n") do GameTooltip:AddLine(line, 0.6, 0.6, 0.6) end
  GameTooltip:Show()
end

-- Zoom at which a place is shown: the player's, kept within the zoom of a zone (a whole zone is
-- about 9; further out the view cannot center on a point, a city's own map shows it at 32).
K.STEP_ZOOM_MIN, K.STEP_ZOOM_MAX = 8, 16
local function StepZoom()
  local ok, _, _, zoom = Guard(OM.GetView)
  return math.max(K.STEP_ZOOM_MIN, math.min(K.STEP_ZOOM_MAX, ok and zoom or K.STEP_ZOOM_MIN))
end

-- The quest's details in the quest log beside the map, the view left where it is (as OpenMap's own
-- quest icons do, Map/Quests.lua). Never when it would move the map: the game closes a quest's details
-- as soon as the map changes (GetQuestUiMapID 0: the game ties this quest to no map). Not in combat,
-- nor on the full screen map, which has no quest log beside it.
local function ShowQuestDetails(qid)
  if InCombatLockdown() or not IsInLog(qid) then return end
  local questMap = GetQuestUiMapID and GetQuestUiMapID(qid)
  if not questMap or (questMap ~= 0 and questMap ~= WorldMapFrame:GetMapID()) then return end
  local log = WorldMapFrame.QuestLog
  if not (log and QuestMapFrame_ShowQuestDetails) or (WorldMapFrame.IsMaximized and WorldMapFrame:IsMaximized()) then return end
  if not log:IsShown() and WorldMapFrame.HandleUserActionOpenSidePanel then
    pcall(WorldMapFrame.HandleUserActionOpenSidePanel, WorldMapFrame)
    local toggle = WorldMapFrame.SidePanelToggle
    if toggle and toggle.Refresh then pcall(toggle.Refresh, toggle) end
  end
  if log:IsShown() then pcall(QuestMapFrame_ShowQuestDetails, qid) end
end

-- Seconds between centering the map and showing the quest: OpenMap then puts the game's map under its
-- view (about 1 s: its glide, then its wait), and that change would close the details.
K.QUEST_SHOW_DELAY = 1.5

-- The world map centered on a point, opened if needed; centered(click) is then called. A later
-- centering, or the map closed, changes Geo.mapClick: what waited for this one is dropped.
function Geo.CenterMap(p, centered)
  Geo.mapClick = (Geo.mapClick or 0) + 1
  local click = Geo.mapClick
  local zoom = StepZoom()
  if not (WorldMapFrame and WorldMapFrame:IsShown()) then Geo.OpenWorldMap() end
  C_Timer.After(0.05, function() -- once the map is up and laid out
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then -- the map could not open (combat…)
      local o = Geo.MapOwner()
      if o and o.mode == "preview" then Geo.MapRelease() end
      Geo.CombatNotice()
      return
    end
    Geo.MapSync()
    local u, v = Geo.MapUV(p)
    if u and OM.IsStitched() then
      Guard(OM.ShowWorld, u, v, zoom)
    else -- OpenMap's map off: the game's, on the point's zone
      Geo.OpenWorldMap(Geo.PointUi(p))
    end
    if centered then centered(click) end
  end)
end

-- The map centered on the step, then the quest log on its quest.
local function CenterOn(st)
  Geo.CenterMap(st.p, function(click)
    local qid = st.task and st.task.id
    if qid and IsInLog(qid) then
      C_Timer.After(K.QUEST_SHOW_DELAY, function()
        if click == Geo.mapClick and WorldMapFrame:IsShown() then ShowQuestDetails(qid) end
      end)
    end
  end)
end

-- A click on a step, its pin on the map or its line in the steps panel. Map closed: as Geo.ShowStep.
function Geo.ClickStep(st)
  if WorldMapFrame and WorldMapFrame:IsShown() then
    CenterOn(st)
  else
    Geo.ShowStep(st)
  end
end
K.CLICK_STEP_TIP = L["Click: center the map and select the quest in the quest log"]

function Geo.MapPinEnter(self)
  if self.data then Geo.StepTooltip(self, self.data, self.fqpN or 0, K.CLICK_STEP_TIP) end
end

function Geo.MapPinClick(self)
  if self.data then Geo.ClickStep(self.data) end
end

local looks = {} -- pin looks, made once: step kind (.. "!" for the current objective)
local function Look(kind, current)
  local key = (kind or "") .. (current and "!" or "")
  if not looks[key] then
    local c = K.MAP_COLOR[kind] or K.MAP_COLOR.other
    looks[key] = current and { atlas = "Waypoint-MapPin-Tracked", texture = "Interface\\Minimap\\Ping\\ping5", size = 32 }
      or { atlas = "Waypoint-MapPin-Untracked", texture = "Interface\\Minimap\\Ping\\ping5", size = 22, color = c }
  end
  return looks[key]
end

-- A step's pin, with its number in the Roadbook (n: 1 = next step).
local function AddStepPin(set, st, u, v, n, current)
  local pin = OM.AddPin(set, u, v, Look(st.kind, current), st)
  if not pin.fqpNum then -- (our set's pins are only ever ours: the label stays with the pooled pin)
    pin.fqpNum = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pin.fqpNum:SetPoint("BOTTOM", pin, "TOP", 0, -4)
  end
  pin.fqpNum:SetText(n)
  if current then pin.fqpNum:SetTextColor(0.4, 1, 0.4) else pin.fqpNum:SetTextColor(1, 1, 1) end
  pin.fqpN = n
  pin:SetScript("OnEnter", Geo.MapPinEnter)
  pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
  OM.OnPinClick(pin, Geo.MapPinClick)
end

-- A walk on the map from p (u1, v1) to q (u2, v2): through the zone passes on its way (Geo.WalkWay),
-- a straight line otherwise.
function Geo.MapWalk(lines, u1, v1, p, q, u2, v2, color)
  local pts = { u1, v1 }
  local ok, _, way = false, nil, nil
  if p and p.c and p.x and q and q.c and q.x then ok, _, way = Guard(Geo.WalkWay, p, q) end
  for _, w in ipairs(ok and way or {}) do
    local okW, u, v = Guard(OM.FromYards, w.c, w.x, w.y)
    if okW and u then
      table.insert(pts, u)
      table.insert(pts, v)
    end
  end
  table.insert(pts, u2)
  table.insert(pts, v2)
  OM.AddPath(lines, pts, K.MAP_LINE, unpack(color or K.MAP_MOVE.walk))
end

-- Colour of the move that leads to a step: flight / boat by its mode, hearthstone or teleport spell, else on foot.
function Geo.MapMoveColor(st)
  local task = st and st.task
  if st and st.kind == "hearth" then return task and task.spell and K.MAP_MOVE.teleport or K.MAP_MOVE.hearth end
  if st and st.kind == "travel" and task then return task.mode == "flight" and K.MAP_MOVE.flight or K.MAP_MOVE.ship end
  return K.MAP_MOVE.walk
end

-- Draws the Roadbook holding the map: its steps not done yet (every one, or the current objective
-- only when "Whole Roadbook on the map" is off), joined in order; a transport leg runs to its
-- arrival, a hearthstone or teleport a thin straight jump; colour by kind of move (K.MAP_MOVE).
function Geo.MapDraw()
  Geo.MapClear()
  local owner = Geo.MapOwner()
  if not owner then return end
  if not OM.IsStitched() then
    if not Geo.mapStitchWarned then
      Geo.mapStitchWarned = true
      Print(L["Turn OpenMap's map on to see the Roadbook on it."])
    end
    return
  end
  local set = Sets()
  local fz = set and Geo.Frozen()
  if not fz then return end
  local cur = owner.mode == "track" and CP.CurrentFocus() or nil
  local whole = owner.mode == "preview" or Geo.MapWholeGet()
  local n, pu, pv, pp, curPin = 0, nil, nil, nil, nil
  for i = 2, #fz.route do
    local st = fz.route[i]
    if not CP.StepDone(st) then
      n = n + 1
      local u, v = Geo.MapUV(st.p)
      if u and not st.nopin then -- a step without a place is not drawn
        if whole then
          if pu then
            if st.kind == "hearth" then -- a jump: straight line, thinner
              OM.AddLine(set.lines, pu, pv, u, v, K.MAP_JUMP_LINE, unpack(Geo.MapMoveColor(st)))
            elseif not st.p.teleport then
              Geo.MapWalk(set.lines, pu, pv, pp, st.p, u, v)
            end
          end
          pu, pv, pp = u, v, st.p
          local du, dv = nil, nil
          if st.kind == "travel" and st.task then du, dv = Geo.MapUV(st.task.destP) end
          if du then
            OM.AddLine(set.lines, u, v, du, dv, K.MAP_LINE, unpack(Geo.MapMoveColor(st)))
            pu, pv, pp = du, dv, st.task.destP
          end
        end
        if st == cur then
          curPin = { st, u, v, n } -- drawn last: over the others
        elseif whole then
          AddStepPin(set.pins, st, u, v, n, false)
        end
      end
    end
  end
  if curPin then AddStepPin(set.pins, curPin[1], curPin[2], curPin[3], curPin[4], true) end
  Geo.MapDrawPlayer()
end

-- Line from the player to the next step (the focused one, else the first not done): a jump for a
-- hearthstone or teleport, the walk through the zone passes otherwise (to the boarding point for a
-- transport). Its own pin set: redrawn alone as the player moves.
function Geo.MapDrawPlayer()
  local set = sets
  if not set then return end
  OM.ClearPinSet(set.player)
  local owner = Geo.MapOwner()
  local fz = owner and Geo.Frozen()
  if not (fz and OM.IsStitched()) then return end
  local st = owner.mode == "track" and CP.CurrentFocus() or nil
  for i = 2, #fz.route do
    if st then break end
    if not CP.StepDone(fz.route[i]) and not fz.route[i].nopin then st = fz.route[i] end
  end
  local pos = st and ns.PlayerPos()
  if not pos then return end
  local u1, v1 = Geo.MapUV(pos)
  local u2, v2 = Geo.MapUV(st.p)
  if not (u1 and u2) then return end
  Geo.mapPlayerAt = { pos.c, pos.x, pos.y, st }
  if st.kind == "hearth" then
    OM.AddLine(set.player, u1, v1, u2, v2, K.MAP_JUMP_LINE, unpack(Geo.MapMoveColor(st)))
  else
    Geo.MapWalk(set.player, u1, v1, pos, st.p, u2, v2)
  end
end

-- While the map is open: the player's line follows the player (every half second, once moved).
function Geo.MapPlayerTick(_, elapsed)
  Geo.mapTick = (Geo.mapTick or 0) + elapsed
  if Geo.mapTick < 0.5 then return end
  Geo.mapTick = 0
  if not (sets and Geo.MapOwner()) then return end
  local pos, last = ns.PlayerPos(), Geo.mapPlayerAt
  if pos and last and last[1] == pos.c and math.abs(last[2] - pos.x) + math.abs(last[3] - pos.y) < 5 then return end
  Guard(Geo.MapDrawPlayer)
end

-- Redraws when the map is open (otherwise at its next opening), with the steps panel beside it.
-- The steps panel (its own window) follows too, even with the map closed.
function Geo.MapSync()
  if Geo.MapPanelSync then
    local ok, err = pcall(Geo.MapPanelSync)
    if not ok then Print(L["Map drawing error: "] .. tostring(err)) end
  end
  if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
  local ok, err = pcall(Geo.MapDraw)
  if not ok then Print(L["Map drawing error: "] .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Preview (click on a step of the Roadbook) and the "Whole Roadbook on the map" option
---------------------------------------------------------------------------
-- Shows a step (done or not): the world map opens centered on it, with the Roadbook drawn
-- (previewed when no Roadbook holds the map), then the quest log on its quest.
-- The Forever Quest Planner window stays open.
function Geo.ShowStep(st)
  if not (st and st.p) or st.nopin then return end
  if not Geo.MapOwner() and Geo.Frozen() then Geo.MapClaim("preview") end
  Geo.MapHookWorldMap()
  CenterOn(st)
end

function Geo.MapWholeGet()
  return Settings().mapWhole ~= false
end

function Geo.MapWholeSet(v)
  if v then Settings().mapWhole = nil else Settings().mapWhole = false end -- on by default
  Geo.MapSync()
end

-- Redraw on each opening of the world map, preview ended when it closes (once; the world map may
-- load after the login).
function Geo.MapHookWorldMap()
  if Geo.mapHooked or not WorldMapFrame then return end
  Geo.mapHooked = true
  WorldMapFrame:HookScript("OnShow", function() C_Timer.After(0, Geo.MapSync) end)
  WorldMapFrame:HookScript("OnUpdate", Geo.MapPlayerTick)
  WorldMapFrame:HookScript("OnHide", function()
    Geo.mapClick = (Geo.mapClick or 0) + 1 -- no quest shown after the map closed
    local o = Geo.MapOwner()
    if o and o.mode == "preview" then Geo.MapRelease() end
  end)
end

-- At login: a map still held from before a /reload given back (the focus is not kept), redraw on
-- each opening, preview ended when the map closes, option in OpenMap's menu.
function Geo.MapInit()
  if Geo.MapOwner() then Guard(Geo.MapRelease) end
  Geo.MapHookWorldMap()
  Guard(OM.OnStitchedChanged, ADDON_NAME, function() Geo.MapSync() end)
  Guard(OM.AddMenuToggle, ADDON_NAME, { id = "roadbook", label = L["Whole Roadbook on the map"],
    get = Geo.MapWholeGet, set = Geo.MapWholeSet, icon = "Interface\\Icons\\INV_Misc_Book_09",
    section = "Forever Quest Planner" })
end
