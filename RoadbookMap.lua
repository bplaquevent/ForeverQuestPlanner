-- Forever Quest Planner: the Roadbook on OpenMap's world map.
-- The names shared between files are published in ns at the end of each file (load order: .toc).
--
-- A Roadbook "holds" the map while it is followed (mode "track") or previewed (mode "preview",
-- "Map" button of its tab): its remaining steps are drawn as numbered pins joined by its route, in
-- pin sets of its own on OpenMap's stitched map (only it creates, updates or clears them), the
-- current objective highlighted. Meanwhile the player's OpenMap pins are hidden and no pin can be
-- added; when the Roadbook lets the map go, the map gets back exactly what it showed before
-- (the player's pins shown or hidden as they were, and the waypoint followed before tracking).

local ADDON_NAME, ns = ...
local CP, CharKey, ClearPin, Geo, K, L, OM = ns.CP, ns.CharKey, ns.ClearPin, ns.Geo, ns.K, ns.L, ns.OM
local IsInLog, OpenQuestDetails, Print, Settings = ns.IsInLog, ns.OpenQuestDetails, ns.Print, ns.Settings

K.MAP_SET = "fqp_roadbook"             -- OpenMap pin set of the steps
K.MAP_ROUTE_SET = "fqp_roadbook_route" -- and of the route (under the pins)
K.MAP_LINE = 3                         -- px: route thickness
K.MAP_WALK = { 1, 0.82, 0.2, 0.85 }    -- route on foot (r, g, b, a)
K.MAP_RIDE = { 0.4, 0.72, 1, 0.85 }    -- flight, boat, zeppelin legs
K.MAP_FIT = 0.7                        -- preview: share of the view the whole Roadbook takes
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
  if Geo.mapButtons then for _, update in pairs(Geo.mapButtons) do update() end end
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
    Print(L["A Roadbook holds the map: no map pin until it is paused (or its preview closed)."])
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
  if not (okP and okL and pins and lines) then return nil end
  sets = { pins = pins, lines = lines }
  return sets
end

function Geo.MapClear()
  if not sets then return end
  OM.stitch.ClearPinSet(sets.pins)
  OM.stitch.ClearPinSet(sets.lines)
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
-- a straight line otherwise. fit(u, v): each pass joins the drawn points' bounds.
function Geo.MapWalk(lines, u1, v1, p, q, u2, v2, fit)
  local S = OM.stitch
  local pts = { u1, v1 }
  local ok, _, way = false, nil, nil
  if p and p.c and p.x and q and q.c and q.x then ok, _, way = pcall(Geo.WalkWay, p, q) end
  for _, w in ipairs(ok and way or {}) do
    local okW, u, v = pcall(S.FromYards, w.c, w.x, w.y)
    if okW and u then
      table.insert(pts, u)
      table.insert(pts, v)
      fit(u, v)
    end
  end
  table.insert(pts, u2)
  table.insert(pts, v2)
  S.AddPath(lines, pts, K.MAP_LINE, unpack(K.MAP_WALK))
end

-- Draws the Roadbook holding the map: its steps not done yet (every one, or the current objective
-- only when "Whole Roadbook on the map" is off), joined in order; a transport leg runs to its
-- arrival, a hearthstone is a jump (no line). Geo.mapBox: the drawn points' bounds (preview framing).
function Geo.MapDraw()
  Geo.MapClear()
  Geo.mapBox = nil
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
  local box
  local function Fit(u, v)
    if not box then box = { u, v, u, v } return end
    box[1], box[2] = math.min(box[1], u), math.min(box[2], v)
    box[3], box[4] = math.max(box[3], u), math.max(box[4], v)
  end
  local n, pu, pv, pp, curPin = 0, nil, nil, nil, nil
  for i = 2, #fz.route do
    local st = fz.route[i]
    if not CP.StepDone(st) then
      n = n + 1
      local u, v = Geo.MapUV(st.p)
      if u then
        if whole then
          if pu and not st.p.teleport then Geo.MapWalk(set.lines, pu, pv, pp, st.p, u, v, Fit) end
          pu, pv, pp = u, v, st.p
          local du, dv = nil, nil
          if st.kind == "travel" and st.task then du, dv = Geo.MapUV(st.task.destP) end
          if du then
            S.AddLine(set.lines, u, v, du, dv, K.MAP_LINE, unpack(K.MAP_RIDE))
            pu, pv, pp = du, dv, st.task.destP
            Fit(du, dv)
          end
        end
        if st == cur then
          curPin = { st, u, v, n } -- drawn last: over the others
        elseif whole then
          AddStepPin(set.pins, st, u, v, n, false)
        end
        if whole or st == cur then Fit(u, v) end
      end
    end
  end
  if curPin then AddStepPin(set.pins, curPin[1], curPin[2], curPin[3], curPin[4], true) end
  Geo.mapBox = box
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

-- The view framed on the drawn Roadbook.
function Geo.MapFit()
  local b = Geo.mapBox
  if not b then return end
  local span = math.max(b[3] - b[1], b[4] - b[2], 0.005)
  pcall(OM.api.ShowWorld, (b[1] + b[3]) / 2, (b[2] + b[4]) / 2, math.max(1, K.MAP_FIT / span))
end

---------------------------------------------------------------------------
-- Preview ("Map" button of a Roadbook tab) and the "Whole Roadbook on the map" option
---------------------------------------------------------------------------
-- Shows the Roadbook on the map without following it; a second click (or closing the map) ends it.
-- Followed: the map opens on it.
function Geo.MapPreview()
  local owner = Geo.MapOwner()
  if owner and owner.mode == "preview" then
    Geo.MapRelease()
    return
  end
  if not Geo.Frozen() then
    Print(L["This Roadbook has no step: click \"Generate\" first."])
    return
  end
  if not owner then Geo.MapClaim("preview") end
  Geo.OpenWorldMap(nil, true) -- the Forever Quest Planner window stays open
  Geo.MapHookWorldMap()
  C_Timer.After(0.05, function()
    local o = Geo.MapOwner()
    if not (WorldMapFrame and WorldMapFrame:IsShown()) then -- the map could not open (combat…)
      if o and o.mode == "preview" then Geo.MapRelease() end
      return
    end
    Geo.MapSync()
    Geo.MapFit()
  end)
  if Geo.mapButtons then for _, update in pairs(Geo.mapButtons) do update() end end
end

-- Click on a step of a Roadbook tab (done or not): the world map opens centered on it, with the
-- Roadbook drawn (previewed when no Roadbook holds the map), and the quest log on its quest.
-- The Forever Quest Planner window stays open.
function Geo.ShowStep(st)
  if not (st and st.p) then return end
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
  if Geo.mapButtons then for _, update in pairs(Geo.mapButtons) do update() end end
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
