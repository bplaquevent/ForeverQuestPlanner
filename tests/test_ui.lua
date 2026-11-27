-- The window, the Objective button and what they save: options, search, goal, quests out of the list,
-- export, steps without a place, errors of the interface.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()

local pins = { cleared = 0, pinned = 0 }
local message
local _, count = nil, 0
local env, ns, log = H.session(nil, {
  ["UI/ListEngine.lua"] = function(ns)
    ns.UpdateScrollBar = function() end
    ns.Snapshot = function() return 0 end
    ns.LogRecord = function() return nil end
    ns.ShowMessage = function(_, _, text) message = text end
    ns.ScanIfNeeded = function() ns.scan.error = "scan broke" end -- the scan could not start
  end,
  ["UI/QuestLogHook.lua"] = function(ns)
    ns.ClearPin = function() pins.cleared = pins.cleared + 1 end
    ns.PinPoint = function() pins.pinned = pins.pinned + 1 end
    ns.ActivePin = function() return nil end
  end,
})
local Geo, CP, State, L = ns.Geo, ns.CP, ns.State, ns.L
local function chat() return table.concat(log.chat, "\n") end

-- A widget that records what the tests read: scripts, text, checked state, mouse.
local widgets = {}
local function Widget()
  local w = { scripts = {} }
  widgets[#widgets + 1] = w
  local methods = {
    SetScript = function(self, what, fn) self.scripts[what] = fn end,
    HookScript = function() end,
    SetText = function(self, t) self.value = t end,
    GetText = function(self) return self.value end,
    SetChecked = function(self, v) self.checked = v and true or false end,
    GetChecked = function(self) return self.checked end,
    EnableMouse = function(self, v) self.mouse = v end,
    CreateTexture = function() return Widget() end,
    CreateFontString = function() return Widget() end,
    GetChildren = function() end,
  }
  return setmetatable(w, { __index = function(self, k)
    if methods[k] then return methods[k] end
    if type(k) == "string" and k:match("^Get") then return function() return 10 end end
    if type(k) == "string" and k:match("^%u") then return function() end end
  end })
end
env.CreateFrame = function() return Widget() end
env.UIParent = Widget()
env.UnitLevel = function() return 30 end

-- "Whole Roadbook on the map" can be unchecked
Geo.MapSync = function() end
Geo.MapWholeSet(false)
check("whole Roadbook: unchecked", Geo.MapWholeGet() == false)
Geo.MapWholeSet(true)
check("whole Roadbook: checked again, the default not saved", Geo.MapWholeGet() == true and ns.Settings().mapWhole == nil)

-- searches read the text shown, not the file names of its icons
local text = ns.Normalize("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:16:16|t |AQuestNormal:0:0|a |cffffffffLoup|r")
check("icons left out of the searched text", not text:find("raid") and not text:find("quest") and text:find("loup") ~= nil)

-- a click on the goal already chosen leaves its radio button checked
local radios = {}
Geo.Dropdown = function() return Widget() end
Geo.DropdownSync = function() end
Geo.MaxLevel = function() return 60 end
CP.SetGoal = function() end -- the goal is the same: nothing redrawn
State.xpGoal = { kind = "time", value = 7200 }
local update = Geo.CreateGoalLine(Widget(), 0, function(_, _, _, onClick)
  local b = Widget()
  radios[#radios + 1] = { b = b, click = onClick }
  return b, 0
end, function() return Widget(), 0 end, function() end)
update()
radios[1].b.checked = false -- the game toggles it on the click
radios[1].click()
check("goal clicked again: still checked", radios[1].b.checked == true and radios[2].b.checked == false)

-- quests kept for their steps done, out of the list: shown, without removal, not counted
Geo.RoadbookQuests = function() return { { id = 1, title = "Alpha", listed = true }, { id = 2, title = "Beta", listed = false } } end
Geo.RoadbookCategories = function(list) return { { kind = "singles", key = "s", quests = list } } end
local bulk
Geo.CustomBulkButtons = function(ids) bulk = ids return {}, { text = "all" } end
Geo.QuestTitle = function(title) return title end
Geo.DescLine = function() return "" end
Geo.DoubtLine = function() return "" end
Geo.WithLevel = function(label) return label end
CP.CurrentFocus = function() return nil end
ns.RequestQuestTags = function() end
local items = {}
local shown, total = Geo.RoadbookQuestItems(items, nil, {})
check("only the quests of the list counted", shown == 1 and total == 1)
check("every quest shown", #items == 3)
check("removal only for a quest of the list", items[2].b3 ~= nil and not items[3].b3)
check("\"Remove all\": the quests of the list", bulk and #bulk == 1 and bulk[1].id == 1)
Geo.RoadbookCategories = function(list) return { { kind = "singles", key = "s", quests = { list[2] } } } end
items = {}
Geo.RoadbookQuestItems(items, nil, {})
check("no \"Remove all\" without a quest of the list", items[1].header and not items[1].b3)

-- export: written again at any time, the keyboard taken only when the player opens the tab
local focus, focused = 0, false
local selected = false -- writing the text drops the selection
local eb = { SetText = function() selected = false end, SetCursorPosition = function() end,
  HighlightText = function() selected = true end,
  HasFocus = function() return focused end, SetFocus = function() focus, focused = focus + 1, true end }
ns.panels.export = { scroll = { child = eb } }
ns.RenderExport()
check("export written again: the keyboard is not taken", focus == 0)
check("export written again without the keyboard: still selected", selected)
if ns.FocusExport then ns.FocusExport() end
check("export opened: selected", focus == 1)

-- a step without a place: the former pin goes, no compass target, the click opens the steps
local step = { kind = "skill", nopin = true, p = { c = 0, x = 1, y = 2 }, task = { title = "T" } }
Geo.Trace = function() end
Geo.StepTrace = function() return "" end
Geo.MapClaim = function() end
Geo.Frozen = function() return { route = {} } end
CP.Progress = function() return 0 end
CP.StepPinLabel = function() return "label" end
CP.RefreshButton = function() end
CP.WatchTransport = function() end
local ok, err = pcall(CP.FocusStep, step)
check("step without a place focused: the former pin cleared: " .. tostring(not ok and err or ""),
  ok and pins.cleared == 1 and pins.pinned == 0)
env.C_Map = {}
CP.checkpointButton = { current = step }
check("step without a place: no compass target", CP.CompassTarget() == nil)
local opened, centered = 0, 0
State.computing = nil
Geo.Tracking = function() return true end
Geo.MapPanelOpen = function() opened = opened + 1 end
Geo.ShowStep = function() centered = centered + 1 end
env.WorldMapFrame = { IsShown = function() return false end }
CP.CurrentFocus = function() return step end
CP.ObjectiveClickUnsafe("LeftButton")
check("click on a step without a place: the steps panel", opened == 1 and centered == 0)

-- an error of a service shortcut does not leave the tracking asked for
CP.RefuseWhileComputing = function() return false end
CP.ServiceBarSync = function() end
Geo.ServicePending = function() return nil end
Geo.NearestService = function() return { id = 1, name = "N", p = {} } end
local pending
Geo.ServiceSet = function(s) pending = s end
Geo.ServiceClear = function() pending = nil end
Geo.areaToUi, Geo.parent, Geo.ready = {}, {}, true
CP.Replan = function() error("replan broke") end
Geo.SetPaused(true)
local raised = not pcall(CP.ServiceClick, "vendor")
check("service shortcut in error: nothing left pending, the pause stays", not raised and Geo.Paused() and pending == nil)
check("and told", chat():find("replan broke", 1, true) ~= nil)

-- an error of the quest log button is told
Geo.QuestLogButtonSync = function() error("button broke") end
Geo.SyncQuestLogButton()
check("quest log button: its error told", chat():find("button broke", 1, true) ~= nil)

-- settings: a value back to its default is not saved; "Defaults" resets the elite quests too
local param
for _, d in ipairs(ns.K.PARAMS) do if d.key then param = d break end end
Geo.SetParam(param, param.default + 1)
check("a changed setting is saved", ns.Settings().params[param.key] == param.default + 1)
Geo.SetParam(param, param.default)
check("back to the default: not saved", ns.Settings().params[param.key] == nil)

widgets = {}
local okPanel, errPanel = pcall(Geo.CreateSettingsPanel, Widget())
local reset
for _, w in ipairs(widgets) do if w.value == L["Defaults"] and w.scripts.OnClick then reset = w end end
check("settings panel built: " .. tostring(not okPanel and errPanel or ""), reset ~= nil)
ns.Settings().noElite = true
if reset then pcall(reset.scripts.OnClick, reset) end
check("\"Defaults\": the elite quests included again", ns.Settings().noElite == nil)

-- available quests: the error of a scan that cannot start is shown
ns.scan.error, ns.scan.dirty, ns.scan.running = nil, true, false
ns.RenderAvailable()
check("scan that cannot start: its error shown", message and message:find("scan broke", 1, true) ~= nil)

-- categories all open (search): a click folds nothing
local function header(forceOpen)
  widgets = {}
  local scroll = Widget()
  scroll.child = Widget()
  local pane = { scroll = scroll, contentWidth = 400 }
  ns.RenderList(pane, "t" .. tostring(forceOpen), { { header = true, kind = "zone", key = "k", label = "Zone" } }, forceOpen)
  for _, w in ipairs(widgets) do if w.mouse ~= nil and w.bg then return w end end
end
local folded, forced = header(false), header(true)
check("category: clickable", folded and folded.mouse == true)
check("category forced open: not clickable", forced and forced.mouse == false and forced.scripts.OnMouseUp == nil)
finish()
