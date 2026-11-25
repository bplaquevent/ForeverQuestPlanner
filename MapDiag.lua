-- Forever Quest Planner: TEMPORARY diagnostics of the world map (erratic centering, quest details,
-- route not shown). Records by itself, without any command, in Settings().mapDiag of the saved data
-- (with the Roadbook's own trace lines), the last DIAG_MAX lines. To remove: this file and its line in
-- the .toc.
-- It only observes: the addon's own Geo functions are wrapped, the game's are watched with
-- hooksecurefunc / HookScript; nothing of OpenMap or of the game is replaced.

local ADDON_NAME, ns = ...
local Geo, K, OM, Settings, IsInLog, CP = ns.Geo, ns.K, ns.OM, ns.Settings, ns.IsInLog, ns.CP

local DIAG_MAX = 3000

local function Record(text)
  local st = Settings()
  st.mapDiag = st.mapDiag or {}
  local t = st.mapDiag
  t[#t + 1] = date("%H:%M:%S") .. " " .. text
  while #t > DIAG_MAX do table.remove(t, 1) end
end

-- The Roadbook's trace lines (computations, followed step…), with or without /fqp trace on.
local trace = Geo.Trace
Geo.Trace = function(kind, text)
  Record(tostring(kind) .. " " .. tostring(text))
  return trace(kind, text)
end

local function Num(n) return type(n) == "number" and string.format("%.3f", n) or "-" end

local function QuestDetails()
  local qmf = rawget(_G, "QuestMapFrame")
  local details = qmf and qmf.DetailsFrame
  if details and details:IsShown() then return tostring(details.questID or "?") end
  return "no"
end

-- The map as it is now: shown, map id, OpenMap's view, quest details, holder, combat.
local function State()
  local shown = WorldMapFrame and WorldMapFrame:IsShown()
  local mapID = shown and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
  local ok, u, v, zoom = pcall(function() return OM.api.GetView() end)
  local okS, stitched = pcall(function() return OM.api.IsStitched() end)
  local owner = Geo.MapOwner()
  return string.format("[map %s id=%s stitched=%s view=(%s,%s) zoom=%s details=%s owner=%s%s]",
    shown and "open" or "closed", tostring(mapID or "-"), tostring(okS and stitched),
    Num(ok and u), Num(ok and v), Num(ok and zoom), QuestDetails(), tostring(owner and owner.mode or "none"),
    InCombatLockdown() and " combat" or "")
end

local function Log(text)
  local ok, state = pcall(State)
  Record(string.format("map t=%.2f %s %s", GetTime(), text, ok and state or ("? " .. tostring(state))))
end

-- Calls of one of the addon's functions: logged before, with what they are called with.
local function Watch(name, describe)
  local original = Geo[name]
  Geo[name] = function(...)
    local ok, text = pcall(describe or function() return "" end, ...)
    Log(name .. " " .. (ok and text or "?"))
    return original(...)
  end
end

local function StepText(st)
  if not st then return "no step" end
  local id = st.task and st.task.id
  local u, v = Geo.MapUV(st.p)
  return string.format("%s \"%s\" #%s inLog=%s target=(%s,%s)", tostring(st.kind), tostring(st.task and st.task.title),
    tostring(id), tostring(id and IsInLog(id) or false), Num(u), Num(v))
end

-- Where the map ends up after a click.
local function Follow(label)
  for _, delay in ipairs({ 0.1, 0.5, 2, 5, 10 }) do
    C_Timer.After(delay, function() Log(label .. " +" .. delay .. "s") end)
  end
end

local clickStep = Geo.ClickStep
Geo.ClickStep = function(st)
  local ok, text = pcall(StepText, st)
  Log("click " .. (ok and text or "?"))
  Follow("after click")
  return clickStep(st)
end

Watch("ShowStep", StepText)
Watch("MapClaim", function(mode) return tostring(mode) end)
Watch("MapRelease")
Watch("ShowOnMap", function(_, title) return tostring(title) end)

-- What a drawing put on the map, or why nothing: logged only when it changes.
local lastDraw
local draw = Geo.MapDraw
Geo.MapDraw = function(...)
  local result = draw(...)
  do
    local ok, text = pcall(function()
      local owner = Geo.MapOwner()
      if not owner then return "nothing: no holder" end
      if not OM.api.IsStitched() then return "nothing: OpenMap's map is not up" end
      if not OM.stitch.IsBuilt() then return "nothing: stitched map not built" end
      if not Geo.Frozen() then return "nothing: no Roadbook" end
      local out = { "mode=" .. owner.mode, "whole=" .. tostring(Geo.MapWholeGet()),
        "focus=" .. tostring(CP.CurrentFocus() ~= nil) }
      for _, key in ipairs({ K.MAP_SET, K.MAP_ROUTE_SET, K.MAP_PLAYER_SET }) do
        local set = OM.stitch.GetPinSet and OM.stitch.GetPinSet(key)
        if set then
          out[#out + 1] = string.format("%s: %d pins %d lines shown=%s visible=%s level=%s", key, #set.pins,
            #set.lines, tostring(set.frame:IsShown()), tostring(set.frame:IsVisible()), tostring(set.frame:GetFrameLevel()))
        end
      end
      return table.concat(out, "; ")
    end)
    text = ok and text or ("? " .. tostring(text))
    if text ~= lastDraw then
      lastDraw = text
      Log("draw " .. text)
    end
  end
  return result
end

-- The game's side: the world map opened, closed, its map changed; the quest log's details.
local hooked = {}
local function Hook()
  if WorldMapFrame and not hooked.map then
    hooked.map = true
    WorldMapFrame:HookScript("OnShow", function() lastDraw = nil Log("world map shown") end)
    WorldMapFrame:HookScript("OnHide", function() Log("world map hidden") end)
    if WorldMapFrame.OnMapChanged then
      hooksecurefunc(WorldMapFrame, "OnMapChanged", function() Log("game map changed") end)
    end
  end
  for _, name in ipairs({ "QuestMapFrame_OpenToQuestDetails", "QuestMapFrame_ShowQuestDetails",
    "QuestMapFrame_CloseQuestDetails", "QuestMapFrame_ReturnFromQuestDetails", "ToggleWorldMap", "ToggleQuestLog" }) do
    if not hooked[name] and rawget(_G, name) then
      hooked[name] = true
      hooksecurefunc(name, function(arg) Log("game " .. name .. " " .. tostring(arg or "")) end)
    end
  end
end

local mapInit = Geo.MapInit
Geo.MapInit = function(...)
  local result = mapInit(...)
  Record("---- login, addon " .. tostring(Geo.Version and Geo.Version() or "?"))
  ns.Print("map diagnostics are recording (temporary).")
  pcall(Hook)
  C_Timer.After(5, function() pcall(Hook) end) -- the world map and quest log may load after the login
  pcall(OM.api.RegisterCallback, ADDON_NAME .. "Diag", "OpenMap_StitchedChanged", function(_, on)
    Log("OpenMap stitched " .. tostring(on))
  end)
  return result
end
