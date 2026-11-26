-- Forever Quest Planner: quest tracking and map pins, the game's quest log, abandoning a quest, and
-- the "add / remove" buttons of the Roadbook list (with their chain questions).
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, Color, GeoReady, IsInLog, K, L, LogQuests = ns.Geo, ns.Color, ns.GeoReady, ns.IsInLog, ns.K, ns.L, ns.LogQuests
local PointText, Print, QDB, QGet, Refresh, Settings, State = ns.PointText, ns.Print, ns.QDB, ns.QGet, ns.Refresh, ns.Settings, ns.State
local Guard = ns.Guard

---------------------------------------------------------------------------
-- Quest abandon
---------------------------------------------------------------------------
local function AbandonQuestByID(questID)
  if not (C_QuestLog.SetSelectedQuest and C_QuestLog.SetAbandonQuest and C_QuestLog.AbandonQuest) then
    Print(L["Abandon API not found in this client."])
    return
  end
  C_QuestLog.SetSelectedQuest(questID)
  C_QuestLog.SetAbandonQuest()
  C_QuestLog.AbandonQuest()
end

StaticPopupDialogs["FQE_ABANDON"] = {
  text = L["Abandon the quest \"%s\"?\n\nYour progress on this quest will be lost."],
  button1 = L["Abandon"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, questID)
    if not (questID and IsInLog(questID)) then return end
    AbandonQuestByID(questID)
    C_Timer.After(1.5, function()
      if IsInLog(questID) then
        Print(L["|cffff6060The game did not take the abandon into account.|r Abandon it from the quest log (L)."])
      end
      Refresh()
    end)
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

local OpenQuestDetails

---------------------------------------------------------------------------
-- Quest tracking and map pins
---------------------------------------------------------------------------
local function IsWatched(id)
  if C_QuestLog.GetQuestWatchType then return C_QuestLog.GetQuestWatchType(id) ~= nil end
  if IsQuestWatched and C_QuestLog.GetLogIndexForQuestID then
    local i = C_QuestLog.GetLogIndexForQuestID(id)
    return i and IsQuestWatched(i) or false
  end
  return false
end

local function SetWatched(id, on)
  local idx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
  if on then
    if C_QuestLog.AddQuestWatch then pcall(C_QuestLog.AddQuestWatch, id)
    elseif AddQuestWatch and idx then pcall(AddQuestWatch, idx) end
  else
    if C_QuestLog.RemoveQuestWatch then pcall(C_QuestLog.RemoveQuestWatch, id)
    elseif RemoveQuestWatch and idx then pcall(RemoveQuestWatch, idx) end
  end
end

-- Opens the game's quest log on a quest's details (depending on the client's UI).
OpenQuestDetails = function(questID)
  if not (questID and IsInLog(questID)) then return end
  pcall(QuestMapFrame_OpenToQuestDetails, questID) -- the world map with its quest log
  Geo.CombatNotice()
end

-- Tracks a single quest: removes every other one from tracking. Only when the tracking really changes:
-- each change made by the addon taints Blizzard's objective tracker (blocked aura reads afterwards).
local function WatchOnly(questID)
  for _, q in ipairs(LogQuests()) do
    if q.id ~= questID and IsWatched(q.id) then SetWatched(q.id, false) end
  end
  if not IsWatched(questID) then SetWatched(questID, true) end
end

-- Pin placed by the addon (OpenMap's waypoint), remembered per character.
-- The waypoint OpenMap follows now sits on this map point.
function Geo.WaypointAt(ui, x, y)
  local m, wx, wy = ns.OM.worldmap.WaypointPoint()
  return m == ui and wx and math.abs(wx - x) < 1e-3 and math.abs(wy - y) < 1e-3 or false
end

-- Active addon pin, or nil if the waypoint was cleared or replaced by another one.
local function ActivePin()
  local pin = Settings().pin
  if not pin then return nil end
  if not (pin.ui and Geo.WaypointAt(pin.ui, pin.x, pin.y)) then
    Settings().pin = nil
    return nil
  end
  return pin
end

-- Called on USER_WAYPOINT_UPDATED: a waypoint placed or cleared by the player replaces ours; while
-- a Roadbook is followed, it puts its own back (RoadbookMap.lua).
local function OnWaypointChanged()
  if Geo.MapOnWaypoint then Geo.MapOnWaypoint() end -- first: it reads our record
  ActivePin()
end

-- Clears the addon pin (OpenMap's waypoint, when it is still ours).
local function ClearPin()
  if ActivePin() then Guard(ns.OM.worldmap.ClearPin) end
  Settings().pin = nil
end

-- Game map pin icon, or a text fallback if the atlas does not exist in this client.
function Geo.HasAtlas(name)
  local ok, info = pcall(function() return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) end)
  return ok and info and true or false
end

local pinIcon
local function PinIcon()
  if pinIcon == nil then
    pinIcon = Geo.HasAtlas("Waypoint-MapPin-Tracked") and "|A:Waypoint-MapPin-Tracked:18:18|a " or Color("ff66ff", L["[Pin] "])
  end
  return pinIcon
end

local function IsPinned(questId)
  local pin = questId and ActivePin()
  return pin and pin.questId == questId or false
end

local function PinTag(questId)
  return IsPinned(questId) and PinIcon() or ""
end

-- Follows a QuestieDB point: OpenMap's waypoint (the game's pin and arrow, TomTom's too).
local function PinPoint(p, title, label, questId)
  if not p then
    Print(string.format(L["Unknown position for \"%s\"."], title or "?"))
    return
  end
  local ui = Geo.PointUi(p)
  if not ui then
    Print(L["No map found for this position."])
    return
  end
  local x, y = (p.mx or 50) / 100, (p.my or 50) / 100
  -- Recorded first: the waypoint event fired during TrackPoint reads this record (Geo.MapOnWaypoint).
  Settings().pin = { questId = questId, title = title, label = label, ui = ui, x = x, y = y,
    place = PointText(p), area = p.area, mx = p.mx, my = p.my }
  local done = pcall(ns.OM.worldmap.TrackPoint, ui, x, y, title and label and (title .. " - " .. label) or title)
  if done then
    Print(L["Pin: "] .. (title or "?") .. (label and (" - " .. label) or "") .. " - " .. PointText(p))
    C_Timer.After(0.1, Refresh)
  else
    Settings().pin = nil
    Print(string.format(L["This client cannot place a pin here (%s)."], PointText(p)))
  end
end

-- The addon pin as recorded (map point), whether or not OpenMap still follows it.
function Geo.PinRecord()
  return Settings().pin
end

-- Map (uiMap) of a point, or nil.
function Geo.PointUi(p)
  return p and (p.ui or Geo.AreaUi(p.area)) or nil
end

-- Map of the quest's zone (QuestieDB zoneOrSort), when no position is known.
function Geo.QuestZoneUi(id)
  local sort = QGet(QDB.Quest, id, "zoneOrSort") or 0
  if not (type(sort) == "number" and sort > 0 and GeoReady()) then return nil end
  return Geo.PointUi({ area = sort })
end

-- Opens the world map, on a map if given (the addon window stays open).
function Geo.OpenWorldMap(ui)
  if not WorldMapFrame then return end
  if not WorldMapFrame:IsShown() then
    if ToggleWorldMap then pcall(ToggleWorldMap) elseif ShowUIPanel then pcall(ShowUIPanel, WorldMapFrame) end
  end
  if ui and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, ui) end
end

-- After an attempt to open the world map: says why it did not, in combat (the game then refuses it).
function Geo.CombatNotice()
  if InCombatLockdown() and not (WorldMapFrame and WorldMapFrame:IsShown()) then
    Print(L["Not possible in combat, try again once out of combat."])
  end
end

-- A quest that is not in the log, shown at its place (getPoint() -> point, label): the map pin on it,
-- the world map centered on it as on a Roadbook step. A followed Roadbook keeps the map (no pin), a
-- preview ends.
function Geo.ShowQuestPlace(getPoint, title, questId)
  local p, label
  if GeoReady() then p, label = getPoint() end
  local owner = Geo.MapOwner and Geo.MapOwner()
  if owner and owner.mode == "preview" then Geo.MapRelease() owner = nil end
  if not p then
    Print(string.format(L["Unknown position for \"%s\"."], title or "?"))
    Geo.OpenWorldMap(questId and Geo.QuestZoneUi(questId))
    Geo.CombatNotice()
    return
  end
  if owner then
    Print(L["A Roadbook is followed: the map shows only its steps (turn its tracking off to place a pin)."])
  else
    PinPoint(p, title, label or L["objective"], questId)
  end
  Geo.CenterMap(p)
end

-- Custom Roadbook buttons: add / remove a quest, add / remove every quest of a category.
K.CUSTOM_TIP = L["Roadbook list: the quests the Roadbook does, along the fastest route."]

-- Tooltip (title, text) of an add / remove button of the quest id.
function Geo.CustomTip(id)
  return id and Geo.InCustom(id) and L["Remove from the Roadbook list"] or L["Add to the Roadbook list"], K.CUSTOM_TIP
end

-- Adds the quest to the list or removes it; a quest with follow-ups asks whether its whole chain goes with it.
function Geo.CustomToggle(id, title, level)
  if not id or Geo.ListLocked() then return end
  local name = title or QGet(QDB.Quest, id, "name") or "?"
  local chain = Geo.ChainQuests(id)
  if Geo.InCustom(id) then
    local inChain = 0
    for _, c in ipairs(chain) do if Geo.InCustom(c.id) then inChain = inChain + 1 end end
    if inChain == 0 then Geo.CustomRemove(id) return end
    StaticPopup_Show("FQP_REMOVE_CHAIN", name, inChain, { id = id })
  elseif #chain == 0 then
    Geo.CustomAdd(id, title, level)
  else
    StaticPopup_Show("FQP_ADD_CHAIN", name, #chain, { id = id, title = title, level = level })
  end
end

function Geo.CustomButton(id, title, level)
  if not id then return nil end
  return { text = Geo.InCustom(id) and L["Remove"] or L["Add"],
    tip = { Geo.CustomTip(id) },
    disabled = State.computing and true or nil, -- the list is locked while the Roadbook is computed
    fn = function() Geo.CustomToggle(id, title, level) end }
end

-- A quest with follow-ups: added or removed alone, or with its whole chain (Geo.CustomAddChain / CustomRemoveChain).
StaticPopupDialogs["FQP_ADD_CHAIN"] = {
  text = L["\"%s\" has %d follow-up quest(s). Add it to the Roadbook list with its whole chain, or alone?"],
  button1 = L["Whole chain"],
  button3 = L["This quest only"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, d) if d and not Geo.ListLocked() then Geo.CustomAddChain(d.id, d.title, d.level) end end,
  OnAlt = function(_, d) if d and not Geo.ListLocked() then Geo.CustomAdd(d.id, d.title, d.level) end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["FQP_REMOVE_CHAIN"] = {
  text = L["\"%s\" and %d of its follow-up quest(s) are in the Roadbook list. Remove the whole chain, or this quest only?"],
  button1 = L["Whole chain"],
  button3 = L["This quest only"],
  button2 = CANCEL or L["Cancel"],
  OnAccept = function(_, d) if d and not Geo.ListLocked() then Geo.CustomRemoveChain(d.id) end end,
  OnAlt = function(_, d) if d and not Geo.ListLocked() then Geo.CustomRemove(d.id) end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- list: { { id, title, level } }; returns the b1 / b2 buttons of a category bar.
function Geo.CustomBulkButtons(list)
  local locked = State.computing and true or nil
  return { text = L["Add all"], disabled = locked, fn = function() if not Geo.ListLocked() then Geo.CustomAddList(list) end end,
      tip = { L["Add every quest of this category to the Roadbook list"], K.CUSTOM_TIP } },
    { text = L["Remove all"], disabled = locked, fn = function() if not Geo.ListLocked() then Geo.CustomRemoveList(list) end end,
      tip = { L["Remove every quest of this category from the Roadbook list"], K.CUSTOM_TIP } }
end

-- Shared with the next files.
ns.ActivePin, ns.ClearPin, ns.OnWaypointChanged, ns.PinIcon, ns.PinPoint, ns.SetWatched = ActivePin, ClearPin, OnWaypointChanged, PinIcon, PinPoint, SetWatched
ns.WatchOnly, ns.IsWatched, ns.OpenQuestDetails = WatchOnly, IsWatched, OpenQuestDetails
ns.IsPinned = IsPinned
