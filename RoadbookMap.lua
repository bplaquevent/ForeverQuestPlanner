-- Forever Quest Planner: the Roadbook on OpenMap's world map.
-- The names shared between files are published in ns at the end of each file (load order: .toc).
--
-- A Roadbook "holds" the map while it is followed (mode "track") or previewed (mode "preview", a click
-- on a step of the Roadbook): its remaining steps are drawn as numbered pins joined by its route, in
-- pin sets of its own on OpenMap's stitched map (only it creates, updates or clears them), the
-- current objective highlighted. Meanwhile the player's OpenMap pins are hidden and no pin can be
-- added; when the Roadbook lets the map go, the map gets back exactly what it showed before
-- (the player's pins shown or hidden as they were, and the waypoint followed before tracking).

local ADDON_NAME, ns = ...
local CP, CharKey, ClearPin, Geo, K, L, OM, IsInLog = ns.CP, ns.CharKey, ns.ClearPin, ns.Geo, ns.K, ns.L, ns.OM, ns.IsInLog
local OpenQuestDetails, Print, Settings = ns.OpenQuestDetails, ns.Print, ns.Settings

K.MAP_SET = "fqp_roadbook"             -- OpenMap pin set of the steps
K.MAP_ROUTE_SET = "fqp_roadbook_route" -- and of the route (under the pins)
K.MAP_LINE = 3                         -- px: route thickness
K.MAP_JUMP_LINE = 2                    -- px: thickness of a jump (hearthstone, teleport)
K.MAP_PLAYER_SET = "fqp_roadbook_player" -- OpenMap pin set of the line from the player to the next step
-- Route colour by kind of move (r, g, b, a): the Roadbook's own colours.
K.MAP_MOVE = {
  walk = { 1, 0.82, 0.2, 0.85 },       -- on foot
  vol = { 0.4, 0.72, 1, 0.85 },        -- flight
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
local function OwnerStore()
  local st = Settings()
  st.mapSaved = st.mapSaved or {}
  return st.mapSaved
end

function Geo.MapOwner()
  return OwnerStore()[CharKey()]
end

-- OpenMap functions as they were before the locks (Geo.MapInstallLocks).
Geo.mapOrig = {}
local function Orig(name)
  return Geo.mapOrig[name] or OM.worldmap[name]
end

-- The Roadbook takes the map. The map's state is saved only the first time: a preview that
-- becomes the tracking keeps the state from before the preview.
function Geo.MapClaim(mode)
  local store, ck = OwnerStore(), CharKey()
  local saved = store[ck]
  if not saved then
    local wm = OM.worldmap
    local m, x, y = wm.WaypointPoint()
    saved = { hidden = wm.PinsHidden() and true or false, wp = (m and x) and { m, x, y } or nil }
    store[ck] = saved
    pcall(Orig("SetPinsHidden"), true)
  end
  if mode == "track" then saved.tookWp = true end -- the tracking moves the waypoint
  saved.mode, saved.kind = mode, nil -- (kind: versions with two Roadbooks)
  Geo.MapSync()
end

-- The Roadbook lets the map go: its pins and route cleared, the player's pins shown or hidden as
-- before, and the waypoint followed before the tracking put back.
function Geo.MapRelease()
  local store, ck = OwnerStore(), CharKey()
  local saved = store[ck]
  if not saved then return end
  store[ck] = nil
  local wm = OM.worldmap
  Geo.MapClear()
  pcall(Orig("SetPinsHidden"), saved.hidden)
  if saved.tookWp then
    ClearPin()
    if saved.wp then pcall(wm.TrackPoint, saved.wp[1], saved.wp[2], saved.wp[3]) end
  end
  pcall(wm.RefreshWaypoint)
  if Geo.MapPanelSync then pcall(Geo.MapPanelSync) end -- the panel goes back to the active Roadbook
end

---------------------------------------------------------------------------
-- Locks: while a Roadbook holds the map, OpenMap adds no pin (Ctrl-click, its pin button, its menu)
-- and its pins stay hidden; its waypoint marker is not drawn over the Roadbook's current pin (it
-- would clear it on a click). Pins shared or imported meanwhile join the hidden list.
---------------------------------------------------------------------------
function Geo.MapInstallLocks()
  if next(Geo.mapOrig) then return end
  local wm, orig = OM.worldmap, Geo.mapOrig
  local function Refuse()
    Print(L["A Roadbook holds the map: no map pin until its tracking is off (or its preview closed)."])
  end
  orig.AddPin, orig.DropWaypoint, orig.SetPinMode = wm.AddPin, wm.DropWaypoint, wm.SetPinMode
  orig.SetPinsHidden, orig.PinAt = wm.SetPinsHidden, wm.PinAt
  wm.AddPin = function(...)
    if Geo.MapOwner() then return Refuse() end
    return orig.AddPin(...)
  end
  wm.DropWaypoint = function(...)
    if Geo.MapOwner() then return Refuse() end
    return orig.DropWaypoint(...)
  end
  wm.SetPinMode = function(on, ...)
    if on and Geo.MapOwner() then
      Refuse()
      on = false
    end
    return orig.SetPinMode(on, ...)
  end
  wm.SetPinsHidden = function(hidden, ...)
    if not hidden and Geo.MapOwner() then return Refuse() end
    return orig.SetPinsHidden(hidden, ...)
  end
  wm.PinAt = function(mapID, x, y, ...)
    local o, r = Geo.MapOwner(), Geo.PinRecord()
    if o and o.mode == "track" and r and r.ui == mapID and x and y
      and math.abs(r.x - x) < 1e-3 and math.abs(r.y - y) < 1e-3 then
      return r
    end
    return orig.PinAt(mapID, x, y, ...)
  end
end

-- USER_WAYPOINT_UPDATED while a Roadbook is followed: another waypoint replaced ours, ours goes
-- back. A waypoint cleared (the game does it on arrival) is left as it is: the focus stays.
function Geo.MapOnWaypoint()
  local o, r = Geo.MapOwner(), Geo.PinRecord()
  if not (o and o.mode == "track" and r and r.ui) or Geo.mapRestoring then return end
  local m = OM.worldmap.WaypointPoint()
  if m and not Geo.WaypointAt(r.ui, r.x, r.y) then
    Geo.mapRestoring = true
    pcall(OM.worldmap.TrackPoint, r.ui, r.x, r.y, r.title)
    Geo.mapRestoring = nil
  end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local sets -- { pins, lines }: created once OpenMap's stitched map is built

local function Sets()
  if sets then return sets end
  local S = OM.stitch
  if not S.IsBuilt() then return nil end
  local okP, pins = pcall(S.PinSet, K.MAP_SET, 0, 6)
  local okL, lines = pcall(S.PinSet, K.MAP_ROUTE_SET, 0, 1)
  local okY, player = pcall(S.PinSet, K.MAP_PLAYER_SET, 0, 2)
  if not (okP and okL and okY and pins and lines and player) then return nil end
  sets = { pins = pins, lines = lines, player = player }
  return sets
end

function Geo.MapClear()
  if not sets then return end
  OM.stitch.ClearPinSet(sets.pins)
  OM.stitch.ClearPinSet(sets.lines)
  OM.stitch.ClearPinSet(sets.player)
end

-- A step's point on OpenMap's stitched world (u, v), or nil.
function Geo.MapUV(p)
  if not p then return nil end
  local ui = Geo.PointUi(p)
  if ui and p.mx and p.my then
    local u, v = OM.api.WorldFromMap(ui, p.mx / 100, p.my / 100)
    if u then return u, v end
  end
  if p.c and p.x and p.y then
    local ok, u, v = pcall(OM.stitch.FromYards, p.c, p.x, p.y)
    if ok and u then return u, v end
  end
  return nil
end

-- A step's tooltip (pins on the map, lines of the steps panel): its title and details
-- (Geo.StepDetailLines); n = its number (nil: done), hint: the last lines (what a click does).
function Geo.StepTooltip(owner, st, n, hint, anchor)
  GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
  GameTooltip:AddLine(n and string.format(L["Roadbook step %d"], n) or L["Roadbook step done"], 0.6, 0.8, 1)
  local ok, title = pcall(CP.StepSummary, st)
  GameTooltip:AddLine(ok and title or CP.StepText(st), 1, 1, 1)
  local okD, lines = pcall(Geo.StepDetailLines, st)
  for _, line in ipairs(okD and lines or {}) do GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true) end
  for line in (hint .. "\n"):gmatch("(.-)\n") do GameTooltip:AddLine(line, 0.6, 0.6, 0.6) end
  GameTooltip:Show()
end

function Geo.MapPinEnter(self)
  if self.data then Geo.StepTooltip(self, self.data, self.fqpN or 0, L["Click: open the Roadbook"]) end
end

function Geo.MapPinClick(self)
  if CP.OpenWindow then CP.OpenWindow("xp") end
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
  local pin = OM.stitch.AddPin(set, u, v, Look(st.kind, current), st)
  if not pin.fqpNum then -- (our set's pins are only ever ours: the label stays with the pooled pin)
    pin.fqpNum = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pin.fqpNum:SetPoint("BOTTOM", pin, "TOP", 0, -4)
  end
  pin.fqpNum:SetText(n)
  if current then pin.fqpNum:SetTextColor(0.4, 1, 0.4) else pin.fqpNum:SetTextColor(1, 1, 1) end
  pin.fqpN = n
  pin:SetScript("OnEnter", Geo.MapPinEnter)
  pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
  pin.OnClick = Geo.MapPinClick
end

-- A walk on the map from p (u1, v1) to q (u2, v2): through the zone passes on its way (Geo.WalkWay),
-- a straight line otherwise.
function Geo.MapWalk(lines, u1, v1, p, q, u2, v2, color)
  local S = OM.stitch
  local pts = { u1, v1 }
  local ok, _, way = false, nil, nil
  if p and p.c and p.x and q and q.c and q.x then ok, _, way = pcall(Geo.WalkWay, p, q) end
  for _, w in ipairs(ok and way or {}) do
    local okW, u, v = pcall(S.FromYards, w.c, w.x, w.y)
    if okW and u then
      table.insert(pts, u)
      table.insert(pts, v)
    end
  end
  table.insert(pts, u2)
  table.insert(pts, v2)
  S.AddPath(lines, pts, K.MAP_LINE, unpack(color or K.MAP_MOVE.walk))
end

-- Colour of the move that leads to a step: flight / boat by its mode, hearthstone or teleport spell, else on foot.
function Geo.MapMoveColor(st)
  local task = st and st.task
  if st and st.kind == "hearth" then return task and task.spell and K.MAP_MOVE.teleport or K.MAP_MOVE.hearth end
  if st and st.kind == "travel" and task then return task.mode == "vol" and K.MAP_MOVE.vol or K.MAP_MOVE.ship end
  return K.MAP_MOVE.walk
end

-- Draws the Roadbook holding the map: its steps not done yet (every one, or the current objective
-- only when "Whole Roadbook on the map" is off), joined in order; a transport leg runs to its
-- arrival, a hearthstone or teleport a thin straight jump; colour by kind of move (K.MAP_MOVE).
function Geo.MapDraw()
  Geo.MapClear()
  local owner = Geo.MapOwner()
  if not owner then return end
  if not OM.api.IsStitched() then
    if not Geo.mapStitchWarned then
      Geo.mapStitchWarned = true
      Print(L["Turn OpenMap's map on to see the Roadbook on it."])
    end
    return
  end
  local set = Sets()
  local fz = set and Geo.Frozen()
  if not fz then return end
  local S = OM.stitch
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
              S.AddLine(set.lines, pu, pv, u, v, K.MAP_JUMP_LINE, unpack(Geo.MapMoveColor(st)))
            elseif not st.p.teleport then
              Geo.MapWalk(set.lines, pu, pv, pp, st.p, u, v)
            end
          end
          pu, pv, pp = u, v, st.p
          local du, dv = nil, nil
          if st.kind == "travel" and st.task then du, dv = Geo.MapUV(st.task.destP) end
          if du then
            S.AddLine(set.lines, u, v, du, dv, K.MAP_LINE, unpack(Geo.MapMoveColor(st)))
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
  OM.stitch.ClearPinSet(set.player)
  local owner = Geo.MapOwner()
  local fz = owner and Geo.Frozen()
  if not (fz and OM.api.IsStitched()) then return end
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
    OM.stitch.AddLine(set.player, u1, v1, u2, v2, K.MAP_JUMP_LINE, unpack(Geo.MapMoveColor(st)))
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
  pcall(Geo.MapDrawPlayer)
end

-- Redraws when the map is open (otherwise at its next opening), with the steps panel beside it.
-- The steps panel (its own window) follows too, even with the map closed.
function Geo.MapSync()
  if Geo.MapPanelSync then
    local ok, err = pcall(Geo.MapPanelSync)
    if not ok then Print(L["Map drawing error: "] .. tostring(err)) end
  end
  if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
  if OM.stitch then
    local ok, err = pcall(Geo.MapDraw)
    if not ok then Print(L["Map drawing error: "] .. tostring(err)) end
  end
end

-- Glides OpenMap's view to a point (the map opens first: next frame).
function Geo.MapGlide(p)
  C_Timer.After(0.05, function()
    local u, v = Geo.MapUV(p)
    if u then pcall(OM.api.ShowWorld, u, v) end
  end)
end

---------------------------------------------------------------------------
-- Preview (click on a step of the Roadbook) and the "Whole Roadbook on the map" option
---------------------------------------------------------------------------
-- Click on a step of a Roadbook tab (done or not): the world map opens centered on it, with the
-- Roadbook drawn (previewed when no Roadbook holds the map), and the quest log on its quest.
-- The Forever Quest Planner window stays open.
function Geo.ShowStep(st)
  if not (st and st.p) or st.nopin then return end
  if not Geo.MapOwner() and Geo.Frozen() then Geo.MapClaim("preview") end
  local qid = st.task and st.task.id
  if qid and IsInLog(qid) then OpenQuestDetails(qid) end
  Geo.OpenWorldMap(Geo.PointUi(st.p), true)
  Geo.MapHookWorldMap()
  C_Timer.After(0.05, function()
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then -- the map could not open (combat…)
      local o = Geo.MapOwner()
      if o and o.mode == "preview" then Geo.MapRelease() end
      return
    end
    Geo.MapSync()
    local u, v = Geo.MapUV(st.p)
    if u then pcall(OM.api.ShowWorld, u, v) end
  end)
end

function Geo.MapWholeGet()
  return Settings().mapWhole ~= false
end

function Geo.MapWholeSet(v)
  Settings().mapWhole = (not v) and false or nil -- on by default
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
    local o = Geo.MapOwner()
    if o and o.mode == "preview" then Geo.MapRelease() end
  end)
end

-- At login: locks, a map still held from before a /reload given back (the focus is not kept),
-- redraw on each opening, preview ended when the map closes, option in OpenMap's menu.
function Geo.MapInit()
  Geo.MapInstallLocks()
  if Geo.MapOwner() then pcall(Geo.MapRelease) end
  Geo.MapHookWorldMap()
  pcall(OM.api.RegisterCallback, ADDON_NAME, "OpenMap_StitchedChanged", function() Geo.MapSync() end)
  pcall(OM.api.RegisterMenuToggle, ADDON_NAME, { id = "roadbook", label = L["Whole Roadbook on the map"],
    get = Geo.MapWholeGet, set = Geo.MapWholeSet, icon = "Interface\\Icons\\INV_Misc_Book_09",
    section = "Forever Quest Planner" })
end
