-- Forever Quest Planner: game events and slash commands.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local CP, CreateMinimapButton, ExportAndSave, Geo, InitDeps, K = ns.CP, ns.CreateMinimapButton, ns.ExportAndSave, ns.Geo, ns.InitDeps, ns.K
local L, OnWaypointChanged, PlayerPos, Print, Color, Refresh = ns.L, ns.OnWaypointChanged, ns.PlayerPos, ns.Print, ns.Color, ns.Refresh
local ScheduleSnapshot, Settings, Snapshot, State = ns.ScheduleSnapshot, ns.Settings, ns.Snapshot, ns.State
local ToggleMainFrame, scan = ns.ToggleMainFrame, ns.scan

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_REMOVED")
f:RegisterEvent("QUEST_TURNED_IN")
f:RegisterEvent("PLAYER_LEVEL_UP")
-- Reputation and profession changes can unlock quests: rescan (batched, they can fire often).
pcall(f.RegisterEvent, f, "UPDATE_FACTION")
pcall(f.RegisterEvent, f, "SKILL_LINES_CHANGED")
f:RegisterEvent("TAXIMAP_OPENED")
-- Service shortcuts (vendor, repair, class trainer): the Roadbook step is done when the NPC window opens.
pcall(f.RegisterEvent, f, "MERCHANT_SHOW")
pcall(f.RegisterEvent, f, "TRAINER_SHOW")
pcall(f.RegisterEvent, f, "PLAYER_TARGET_CHANGED")
pcall(f.RegisterEvent, f, "UPDATE_MOUSEOVER_UNIT")
pcall(f.RegisterEvent, f, "BANKFRAME_OPENED")
pcall(f.RegisterEvent, f, "MAIL_SHOW")
pcall(f.RegisterEvent, f, "USER_WAYPOINT_UPDATED")
f:RegisterEvent("PLAYER_LOGOUT")
pcall(f.RegisterEvent, f, "HEARTHSTONE_BOUND")
pcall(f.RegisterEvent, f, "PLAYER_CONTROL_LOST")
pcall(f.RegisterEvent, f, "PLAYER_CONTROL_GAINED")
pcall(f.RegisterEvent, f, "ZONE_CHANGED_NEW_AREA")
pcall(f.RegisterEvent, f, "PLAYER_ENTERING_WORLD")
-- Hearthstone and class teleports: cooldowns, runes, spells learned (checked while a Roadbook is followed).
pcall(f.RegisterEvent, f, "SPELL_UPDATE_COOLDOWN")
pcall(f.RegisterEvent, f, "BAG_UPDATE_COOLDOWN")
pcall(f.RegisterEvent, f, "BAG_UPDATE_DELAYED")
pcall(f.RegisterEvent, f, "SPELLS_CHANGED")
if f.RegisterUnitEvent then
  pcall(f.RegisterUnitEvent, f, "UNIT_SPELLCAST_SUCCEEDED", "player")
else
  pcall(f.RegisterEvent, f, "UNIT_SPELLCAST_SUCCEEDED")
end
-- Event -> handler(event, ...).
local handlers = {}

local function On(events, handler)
  for _, event in ipairs(events) do handlers[event] = handler end
end

-- The window is shown, on a tab other than `except` (if given).
local function WindowShown(except)
  return State.mainFrame and State.mainFrame:IsShown() and State.currentTab ~= except
end

On({ "PLAYER_LOGIN" }, function()
  -- QuestieDB and OpenMap are required: without them (or with an unsupported version) the addon stays off.
  local okD, err = pcall(InitDeps)
  if not okD or err then
    f.disabled = tostring(err)
    f:UnregisterAllEvents()
    Print(Color("ff4040", f.disabled))
    return
  end
  local okData, errData = pcall(ns.Migrate) -- saved data of former versions (Migrations.lua)
  if not okData then Print(Color("ff4040", L["Saved data not updated: "] .. tostring(errData))) end
  -- Options saved from the settings window or the tabs.
  local st = Settings()
  if type(st.goal) == "table" and (st.goal.kind == "time" or st.goal.kind == "level") and st.goal.value then
    State.xpGoal = { kind = st.goal.kind, value = st.goal.value }
  end
  if st.nearRadius then State.nearRadius = st.nearRadius end
  if st.availFilter then State.availFilter = st.availFilter end
  pcall(Geo.ApplyParams)
  local okM, errM = pcall(Geo.MapInit) -- the Roadbook on OpenMap's map (RoadbookMap.lua)
  if not okM then Print(L["Map drawing error: "] .. tostring(errM)) end
  CreateMinimapButton()
  pcall(Geo.QuestLogButtonInit) -- "+ Roadbook" in the game's quest log (UI/QuestLogHook.lua)
  C_Timer.NewTicker(K.PASS_TICK, function()
    pcall(Geo.PassTick) -- zone passes learned on foot
    pcall(Geo.LearnMountSpeed)
  end)
  C_Timer.NewTicker(3, function() pcall(CP.NearbyCheck) end) -- steps on the spot first (Roadbook.lua)
  if CP.CHECKPOINT_TOGGLE.get() then CP.CreateCheckpointButton() end
  ScheduleSnapshot()
end)

On({ "PLAYER_LOGOUT" }, function() Snapshot() end)

On({ "SPELL_UPDATE_COOLDOWN", "BAG_UPDATE_COOLDOWN", "BAG_UPDATE_DELAYED", "SPELLS_CHANGED" }, function(event)
  Geo.recallDest = nil
  pcall(CP.ScheduleRecallCheck, 3)
  if event == "BAG_UPDATE_DELAYED" then pcall(CP.OnGameEvent, event) end -- source item looted
end)

On({ "HEARTHSTONE_BOUND" }, function(event)
  -- New inn: position of the innkeeper targeted by the Roadbook, otherwise ours.
  local s = CP.focused
  local planned = s and s.kind == "bind" and CP.IsStepFocused(s)
  local p = planned and s.p or PlayerPos()
  pcall(Geo.RecordBind, p)
  if planned then
    C_Timer.After(0.5, function() pcall(Geo.RestampRecalls) end)
  else
    pcall(CP.ScheduleRecallCheck, 3) -- another bind location: the route is adapted
  end
  pcall(CP.OnGameEvent, event)
  if WindowShown() then C_Timer.After(0.5, Refresh) end
end)

On({ "UNIT_SPELLCAST_SUCCEEDED" }, function(_, unit, _, spellID)
  local e = K.RECALL_BY_SPELL[spellID]
  if unit == "player" and (spellID == K.HEARTH_SPELL or e) then
    local key = e and spellID or "hearth"
    pcall(CP.RecallCast, key)
    C_Timer.After(5, function()
      if e and not e.bind then
        pcall(Geo.RecordTeleport, spellID, PlayerPos()) -- the real arrival of this teleport
      else
        local name = GetBindLocation and GetBindLocation()
        local st = Settings().bind
        if not (st and st.name == name) then pcall(Geo.RecordBind, PlayerPos()) end
      end
      pcall(CP.OnGameEvent, "FQP_HEARTH_ARRIVED", key)
    end)
  end
end)

On({ "PLAYER_CONTROL_LOST" }, function()
  C_Timer.After(0.5, function()
    if UnitOnTaxi and UnitOnTaxi("player") and not f.onTaxi then
      f.onTaxi = true
      pcall(CP.OnGameEvent, "FQP_TAXI_TAKEOFF")
    end
  end)
end)

On({ "PLAYER_CONTROL_GAINED" }, function()
  if f.onTaxi then
    f.onTaxi = nil
    C_Timer.After(1, function() pcall(CP.OnGameEvent, "FQP_TAXI_LANDED") end)
  end
end)

On({ "UPDATE_FACTION", "SKILL_LINES_CHANGED" }, function(event)
  if event == "SKILL_LINES_CHANGED" then
    pcall(ns.PlayerSkills, true) -- read again: a "raise the skill" step may be done
    pcall(CP.OnGameEvent, event)
  end
  if not f.rescanPending then
    f.rescanPending = true
    C_Timer.After(10, function()
      f.rescanPending = nil
      scan.dirty = true
      if WindowShown("xp") then Refresh() end
    end)
  end
end)

On({ "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }, function()
  pcall(CP.OnGameEvent, "ZONE_CHANGED_NEW_AREA")
end)

On({ "USER_WAYPOINT_UPDATED" }, function()
  OnWaypointChanged()
  C_Timer.After(0.2, function() pcall(CP.RefreshButton) end)
  if WindowShown() then C_Timer.After(0.1, Refresh) end
end)

On({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT" }, function(event)
  pcall(Geo.TrainerSeen, event == "PLAYER_TARGET_CHANGED" and "target" or "mouseover")
end)

On({ "TAXIMAP_OPENED", "MERCHANT_SHOW", "TRAINER_SHOW", "BANKFRAME_OPENED", "MAIL_SHOW" }, function(event, ...)
  if event == "TRAINER_SHOW" then pcall(Geo.TrainerOpened) end
  pcall(CP.OnGameEvent, event, ...)
end)

-- The quest log or the level changed.
On({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "PLAYER_LEVEL_UP" }, function(event, ...)
  ScheduleSnapshot()
  State.abandonIds = nil -- recommendations for abandoning computed again on the next display
  pcall(CP.OnGameEvent, event, ...)
  if event == "QUEST_LOG_UPDATE" then
    if State.mainFrame and State.mainFrame:IsShown() and State.currentTab == "groups" and not f.pendingRefresh then
      f.pendingRefresh = true
      C_Timer.After(1, function()
        f.pendingRefresh = nil
        Refresh()
      end)
    end
    return
  end
  scan.dirty = true
  if WindowShown("export") then C_Timer.After(0.5, Refresh) end
end)

f:SetScript("OnEvent", function(_, event, ...)
  local handler = handlers[event]
  if handler then handler(event, ...) end
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
SLASH_FOREVERQUESTPLANNER1 = "/fqp"
SlashCmdList.FOREVERQUESTPLANNER = function(msg)
  if f.disabled then
    Print(Color("ff4040", f.disabled))
    return
  end
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "save" then
    ExportAndSave()
  elseif msg == "hearth" or msg == "foyer" then
    local st = Settings()
    st.noHearth = not st.noHearth or nil
    Print(st.noHearth and L["Hearthstone ignored by the Roadbook."] or L["Hearthstone used by the Roadbook."])
    if Refresh then Refresh() end
  elseif msg == "teleport" or msg == "teleports" or msg == "tp" then
    local st = Settings()
    st.noRecallSpells = not st.noRecallSpells or nil
    Print(st.noRecallSpells and L["Class teleports ignored by the Roadbook."] or L["Class teleports used by the Roadbook."])
    if Refresh then Refresh() end
  elseif msg == "icon" then
    local s = Settings()
    s.hideMinimap = not s.hideMinimap
    if State.minimapButton then State.minimapButton:SetShown(not s.hideMinimap) end
    Print(s.hideMinimap and L["Minimap icon hidden."] or L["Minimap icon shown."])
  elseif msg == "abandon" then
    ToggleMainFrame("groups")
  elseif msg == "near" or msg == "around" or msg == "autour" then
    ToggleMainFrame("near")
  elseif msg == "xp" or msg == "roadbook" then
    ToggleMainFrame("xp")
  elseif msg == "log" or msg == "journal" or msg == "afaire" or msg == "todo" then
    ToggleMainFrame("groups")
  elseif msg == "available" or msg == "dispo" then
    ToggleMainFrame("avail")
  elseif msg == "settings" or msg == "config" or msg == "reglages" or msg == "réglages" then
    Geo.ToggleSettings()
  elseif msg == "passes" or msg == "passages" then
    local learned, all = #Geo.LearnedPasses(), #Geo.Passes()
    Print(string.format(L["Zone passes: %d learned on foot, %d in all."], learned, all))
  elseif msg == "passes reset" or msg == "passages reset" then
    wipe(Geo.LearnedPasses())
    Geo.PassesChanged()
    Print(L["Learned zone passes forgotten."])
  elseif msg == "export" then
    ToggleMainFrame("export")
  elseif msg == "trace on" or msg == "trace off" then
    Settings().traceOn = (msg == "trace on") or nil
    Print(msg == "trace on" and L["Roadbook trace on."] or L["Roadbook trace off."])
  elseif msg == "trace" or msg == "trace clear" then
    local t = Settings().roadbookTrace or {}
    if msg == "trace" then
      Print(Settings().traceOn and L["Roadbook trace on."] or L["Roadbook trace off (/fqp trace on to record)."])
    end
    if msg == "trace clear" then
      Settings().roadbookTrace = nil
      Print(L["Roadbook trace emptied."])
    elseif #t == 0 then
      Print(L["Roadbook trace is empty."])
    else
      Print(string.format(L["Roadbook trace: %d line(s), the last 20 (all of them in the saved data)."], #t))
      for i = math.max(1, #t - 19), #t do Print(t[i]) end
    end
  elseif msg == "npc" then
    for _, line in ipairs(Geo.NpcInfo()) do Print(line) end
  elseif msg:sub(1, 6) == "quest " then
    ns.QuestDiag(msg:sub(7))
  elseif msg == "dump" then
    Geo.BenchDump()
  else
    ToggleMainFrame()
  end
end
