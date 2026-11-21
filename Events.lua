-- Forever Quest Planner: game events and slash commands.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local CP, CharKey, CreateMinimapButton, ExportAndSave, Geo, InitDeps = ns.CP, ns.CharKey, ns.CreateMinimapButton, ns.ExportAndSave, ns.Geo, ns.InitDeps
local K, L, OnWaypointChanged, PlayerPos, Print = ns.K, ns.L, ns.OnWaypointChanged, ns.PlayerPos, ns.Print
local Color, Refresh, ScheduleSnapshot, Settings, Snapshot, State, ToggleMainFrame = ns.Color, ns.Refresh, ns.ScheduleSnapshot, ns.Settings, ns.Snapshot, ns.State, ns.ToggleMainFrame
local scan = ns.scan

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
pcall(f.RegisterEvent, f, "USER_WAYPOINT_UPDATED")
f:RegisterEvent("PLAYER_LOGOUT")
pcall(f.RegisterEvent, f, "HEARTHSTONE_BOUND")
pcall(f.RegisterEvent, f, "PLAYER_CONTROL_LOST")
pcall(f.RegisterEvent, f, "PLAYER_CONTROL_GAINED")
pcall(f.RegisterEvent, f, "ZONE_CHANGED_NEW_AREA")
pcall(f.RegisterEvent, f, "PLAYER_ENTERING_WORLD")
if f.RegisterUnitEvent then
  pcall(f.RegisterUnitEvent, f, "UNIT_SPELLCAST_SUCCEEDED", "player")
else
  pcall(f.RegisterEvent, f, "UNIT_SPELLCAST_SUCCEEDED")
end
f:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    -- QuestieDB and OpenMap are required: without them (or with an unsupported version) the addon stays off.
    local okD, err = pcall(InitDeps)
    if not okD or err then
      f.disabled = tostring(err)
      f:UnregisterAllEvents()
      Print(Color("ff4040", f.disabled))
      return
    end
    Settings().focus = nil -- old saved focus (versions 2.32.1-2.32.2)
    -- Options saved from the settings window or the tabs.
    local st = Settings()
    if st.horizon then -- former setting: duration only
      st.goal, st.horizon = { kind = "time", value = st.horizon }, nil
    end
    if type(st.goal) == "table" and st.goal.kind and st.goal.value then
      State.xpGoal = { kind = st.goal.kind, value = st.goal.value }
    end
    if st.nearRadius then State.nearRadius = st.nearRadius end
    if st.availFilter then State.availFilter = st.availFilter end
    -- Former versions (one Roadbook, always followed): the Roadbook of the selected mode stays active.
    st.roadbookMigrated = st.roadbookMigrated or {}
    if not st.roadbookMigrated[CharKey()] then
      st.roadbookMigrated[CharKey()] = true
      local kind = Geo.CustomRec().mode == "custom" and "custom" or "auto" -- former view mode
      if Geo.HasRoadbook(kind) then Geo.SetActive(kind) end
    end
    Geo.ResetActiveIfEmpty()
    pcall(Geo.ApplyParams)
    local okM, errM = pcall(Geo.MapInit) -- the Roadbook on OpenMap's map (RoadbookMap.lua)
    if not okM then Print(L["Map drawing error: "] .. tostring(errM)) end
    CreateMinimapButton()
    C_Timer.NewTicker(K.PASS_TICK, function() pcall(Geo.PassTick) end) -- zone passes learned on foot
    if CP.CHECKPOINT_TOGGLE.get() then CP.CreateCheckpointButton() end
    ScheduleSnapshot()
  elseif event == "PLAYER_LOGOUT" then
    Snapshot()
  elseif event == "HEARTHSTONE_BOUND" then
    -- New inn: position of the innkeeper targeted by the Roadbook, otherwise ours.
    local s = CP.focused
    local p = (s and s.kind == "bind" and CP.IsStepFocused(s)) and s.p or PlayerPos()
    pcall(Geo.RecordBind, p)
    pcall(CP.OnGameEvent, event)
    if State.mainFrame and State.mainFrame:IsShown() then C_Timer.After(0.5, Refresh) end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if unit == "player" and spellID == K.HEARTH_SPELL then
      C_Timer.After(5, function()
        local name = GetBindLocation and GetBindLocation()
        local st = Geo.BindStore()[CharKey()]
        if not (st and st.name == name) then pcall(Geo.RecordBind, PlayerPos()) end
        pcall(CP.OnGameEvent, "FQP_HEARTH_ARRIVED")
      end)
    end
  elseif event == "PLAYER_CONTROL_LOST" then
    C_Timer.After(0.5, function()
      if UnitOnTaxi and UnitOnTaxi("player") and not f.onTaxi then
        f.onTaxi = true
        pcall(CP.OnGameEvent, "FQP_TAXI_TAKEOFF")
      end
    end)
  elseif event == "UPDATE_FACTION" or event == "SKILL_LINES_CHANGED" then
    if not f.rescanPending then
      f.rescanPending = true
      C_Timer.After(10, function()
        f.rescanPending = nil
        scan.dirty = true
        if State.mainFrame and State.mainFrame:IsShown() and State.currentTab ~= "xp" and State.currentTab ~= "custom" then Refresh() end
      end)
    end
  elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
    pcall(CP.OnGameEvent, "ZONE_CHANGED_NEW_AREA")
  elseif event == "PLAYER_CONTROL_GAINED" then
    if f.onTaxi then
      f.onTaxi = nil
      C_Timer.After(1, function() pcall(CP.OnGameEvent, "FQP_TAXI_LANDED") end)
    end
  elseif event == "USER_WAYPOINT_UPDATED" then
    OnWaypointChanged()
    C_Timer.After(0.2, function() pcall(CP.RefreshButton) end)
    if State.mainFrame and State.mainFrame:IsShown() then C_Timer.After(0.1, Refresh) end
  elseif event == "TAXIMAP_OPENED" then
    pcall(CP.OnGameEvent, event, ...)
  else
    ScheduleSnapshot()
    State.abandonIds = nil -- recommendations for abandoning computed again on the next display
    pcall(CP.OnGameEvent, event, ...)
    if event == "QUEST_LOG_UPDATE" and State.mainFrame and State.mainFrame:IsShown() and State.currentTab == "groups" and not f.pendingRefresh then
      f.pendingRefresh = true
      C_Timer.After(1, function()
        f.pendingRefresh = nil
        Refresh()
      end)
    end
    if event ~= "QUEST_LOG_UPDATE" then
      scan.dirty = true
      if State.mainFrame and State.mainFrame:IsShown() and State.currentTab ~= "export" then
        C_Timer.After(0.5, Refresh)
      end
    end
  end
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
  elseif msg == "icon" then
    local s = Settings()
    s.hideMinimap = not s.hideMinimap
    if State.minimapButton then State.minimapButton:SetShown(not s.hideMinimap) end
    Print(L["Minimap icon "] .. (s.hideMinimap and L["hidden."] or L["shown."]))
  elseif msg == "abandon" then
    ToggleMainFrame("groups")
  elseif msg == "near" or msg == "around" or msg == "autour" then
    ToggleMainFrame("near")
  elseif msg == "xp" or msg == "roadbook" then
    ToggleMainFrame(Geo.TabOf(Geo.ActiveKind()))
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
  else
    ToggleMainFrame()
  end
end
