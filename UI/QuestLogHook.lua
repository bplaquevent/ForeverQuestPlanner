-- Forever Quest Planner: "+ Roadbook" button in the game's quest log (adds / removes the selected quest
-- from the custom Roadbook). Quest log of the world map (QuestMapFrame details, top bar beside "Back"),
-- or the old standalone quest log (QuestLogFrame, above "Abandon").
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, K, L = ns.Geo, ns.K, ns.L

local buttons = {} -- host frame -> button
local hooked = {}  -- what is already hooked

-- Quest shown in the details of the world map's quest log.
local function MapDetailsQuest(details)
  local id = details.questID
  if (not id or id == 0) and C_QuestLog.GetSelectedQuest then id = C_QuestLog.GetSelectedQuest() end
  if id and id > 0 then return id end
end

-- Quest selected in the old quest log (nil on a header).
local function LogSelectedQuest()
  local index = GetQuestLogSelection and GetQuestLogSelection()
  if not index or index == 0 then return nil end
  if C_QuestLog.GetInfo then
    local info = C_QuestLog.GetInfo(index)
    if info then
      if info.isHeader or not info.questID or info.questID == 0 then return nil end
      return info.questID
    end
  end
  if GetQuestLogTitle then
    local _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(index)
    if not isHeader and questID and questID > 0 then return questID end
  end
end

local function Toggle(id)
  if not id then return end
  if Geo.InCustom(id) then Geo.CustomRemove(id) else Geo.CustomAdd(id) end
  Geo.QuestLogButtonSync()
end

-- host: frame the button belongs to; getQuest: the quest it acts on; place(button): its anchor.
local function CreateButton(host, getQuest, place)
  local b = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  b:SetSize(110, 22)
  b:SetFrameLevel(host:GetFrameLevel() + 10)
  place(b)
  b.getQuest = getQuest
  b:SetScript("OnClick", function(self) Toggle(self.getQuest()) end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    local id = self.getQuest()
    GameTooltip:AddLine(id and Geo.InCustom(id) and L["Remove from the Roadbook list"] or L["Add to the Roadbook list"])
    GameTooltip:AddLine(L[K.CUSTOM_TIP], 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  buttons[host] = b
  return b
end

local function MapDetails()
  local qmf = rawget(_G, "QuestMapFrame")
  return qmf and qmf.DetailsFrame
end

local function BackButtonOf(details)
  return details.BackButton or (details.BackFrame and details.BackFrame.BackButton)
end

local function EnsureButtons()
  local details = MapDetails()
  if details and not buttons[details] then
    CreateButton(details, function() return MapDetailsQuest(details) end, function(b)
      local back = BackButtonOf(details)
      if back then
        b:SetPoint("LEFT", back, "RIGHT", 8, 0)
      else
        b:SetPoint("TOPRIGHT", details, "TOPRIGHT", -30, -4)
      end
    end)
  end
  local logFrame = rawget(_G, "QuestLogFrame")
  if logFrame and not buttons[logFrame] then
    CreateButton(logFrame, LogSelectedQuest, function(b)
      local abandon = rawget(_G, "QuestLogFrameAbandonButton")
      if abandon then
        b:SetPoint("BOTTOMLEFT", abandon, "TOPLEFT", 0, 2)
      else
        b:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", 20, 80)
      end
    end)
  end
end

-- Label (add / remove) and visibility of the buttons, for the quest each one acts on.
function Geo.QuestLogButtonSync()
  EnsureButtons()
  for host, b in pairs(buttons) do
    local id = host:IsShown() and b.getQuest()
    if id then
      b:SetText(Geo.InCustom(id) and L["- Roadbook"] or L["+ Roadbook"])
      b:Show()
    else
      b:Hide()
    end
  end
end

local function Sync() pcall(Geo.QuestLogButtonSync) end
local function SyncNext() C_Timer.After(0, Sync) end

-- Hooks (once each); the world map may load after this file.
local function Install()
  local function HookFunc(name)
    if not hooked[name] and hooksecurefunc and rawget(_G, name) then
      hooksecurefunc(name, SyncNext)
      hooked[name] = true
    end
  end
  HookFunc("QuestMapFrame_ShowQuestDetails")
  HookFunc("QuestLog_Update")
  HookFunc("QuestLog_SetSelection")
  local details = MapDetails()
  if details and not hooked.details then
    details:HookScript("OnShow", SyncNext)
    hooked.details = true
  end
  local logFrame = rawget(_G, "QuestLogFrame")
  if logFrame and not hooked.log then
    logFrame:HookScript("OnShow", SyncNext)
    hooked.log = true
  end
end

Install()
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function() Install() end)
