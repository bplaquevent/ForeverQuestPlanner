-- Forever Quest Planner: window state, shared list engine, quest tracking and map pins, quest descriptions, search.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local ChainInfo, ChainText, CharKey, Color, FormatNumber, Geo = ns.ChainInfo, ns.ChainText, ns.CharKey, ns.Color, ns.FormatNumber, ns.Geo
local GeoReady, IsClassMeta, IsCompleted, IsInLog, K, L, Nearest = ns.GeoReady, ns.IsClassMeta, ns.IsCompleted, ns.IsInLog, ns.K, ns.L, ns.Nearest
local PlayerPos, PointText, Print, QDB, QGet, QuestMeta = ns.PlayerPos, ns.PointText, ns.Print, ns.QDB, ns.QGet, ns.QuestMeta
local QuestTargets, Refresh, RemainingTargets, Settings, Snapshot, State = ns.QuestTargets, ns.Refresh, ns.RemainingTargets, ns.Settings, ns.Snapshot, ns.State
local TrivialRange, TurnInText, StartPoints, EntityPoints = ns.TrivialRange, ns.TurnInText, ns.StartPoints, ns.EntityPoints

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
      if Refresh then Refresh() end
    end)
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Text to export (Ctrl+C)
---------------------------------------------------------------------------
local FREQ = { [1] = L["daily"], [2] = L["weekly"] }

local function BuildText()
  Snapshot()
  local e = ForeverQuestPlannerDB[CharKey()]
  if not e then return L["No data."] end
  local plevel, range = UnitLevel("player"), TrivialRange()

  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  add(string.format(L["Quest log - %s (%s level %s) - %s - %s - %d quests"],
    e.name or "?", e.class or "?", tostring(e.level or "?"), e.zone or "?", e.updated or "?", e.count or 0))

  local currentZone
  for _, q in ipairs(e.quests) do
    if q.zone ~= currentZone then
      currentZone = q.zone
      add("")
      add("## " .. (currentZone or L["No zone"]))
    end
    local tags = {}
    if q.level then tags[#tags + 1] = L["level "] .. q.level end
    if q.xp and q.xp > 0 then tags[#tags + 1] = q.xp .. " XP" end
    if q.money and q.money > 0 then
      local g, sv, c = math.floor(q.money / 10000), math.floor(q.money / 100) % 100, q.money % 100
      tags[#tags + 1] = (g > 0 and (g .. L["g "]) or "") .. (sv > 0 and (sv .. L["s "]) or "") .. (c > 0 and (c .. L["c"]) or "")
    end
    if q.instanceName then tags[#tags + 1] = L["dungeon: "] .. q.instanceName
    elseif q.mapZone and q.mapZone ~= q.zone then tags[#tags + 1] = L["location: "] .. q.mapZone end
    if q.tag then tags[#tags + 1] = q.tag end
    if q.suggestedGroup and q.suggestedGroup > 1 then tags[#tags + 1] = L["group "] .. q.suggestedGroup end
    if FREQ[q.frequency] then tags[#tags + 1] = FREQ[q.frequency] end
    if q.complete then tags[#tags + 1] = L["COMPLETE"] end
    if q.failed then tags[#tags + 1] = L["FAILED"] end
    add(string.format("- %s [%d] (%s)", q.title or "?", q.id, table.concat(tags, ", ")))
    if q.objectivesText and q.objectivesText ~= "" then
      add(L["    Goal: "] .. (q.objectivesText:gsub("[\r\n]+", " ")))
    end
    for _, o in ipairs(q.objectives or {}) do
      add(string.format("    %s %s", o.finished and "[x]" or "[ ]", o.text or ""))
    end
    local chain = ChainText(ChainInfo(q.id, plevel, range))
    if chain then add("    " .. chain) end
    local turnIn = TurnInText(q.id)
    if turnIn then add(L["    Turn in to: "] .. turnIn) end
  end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local panels, tabButtons = {}, {}
State.currentTab = "near"
State.availFilter = "all"
local CONTENT_WIDTH = 770 -- same gap on the right (to the scroll bar) as on the left

-- Scroll bar of a UIPanelScrollFrameTemplate frame (key, name, or Slider child).
local function ScrollBarOf(scroll)
  if type(scroll.ScrollBar) == "table" then return scroll.ScrollBar end
  local name = scroll.GetName and scroll:GetName()
  if type(name) == "string" and type(_G[name .. "ScrollBar"]) == "table" then return _G[name .. "ScrollBar"] end
  for _, child in ipairs({ scroll:GetChildren() }) do
    if type(child) == "table" and child.GetObjectType and child:GetObjectType() == "Slider" then return child end
  end
  return nil
end

-- Shows the scroll bar only if the content is taller than the visible area.
local function UpdateScrollBar(scroll)
  local function apply()
    local bar = ScrollBarOf(scroll)
    if not bar or not scroll.child then return end
    local need = (scroll.child:GetHeight() or 0) > (scroll:GetHeight() or 0) + 2
    bar:SetShown(need)
    if not need then scroll:SetVerticalScroll(0) end
  end
  apply()
  C_Timer.After(0, apply) -- after the next frame's layout
end

local function CreateScrollPanel(parent, child, top)
  local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", State.mainFrame, "TOPLEFT", 12, top or -64)
  scroll:SetPoint("BOTTOMRIGHT", State.mainFrame, "BOTTOMRIGHT", -32, 24)
  if not child then
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CONTENT_WIDTH, 1)
  end
  scroll:SetScrollChild(child)
  scroll.child = child
  -- The game template hides the scroll bar itself when there is nothing to scroll.
  scroll.scrollBarHideable = true
  if scroll.HookScript then
    scroll:HookScript("OnScrollRangeChanged", function(self) UpdateScrollBar(self) end)
  end
  return scroll
end

---------------------------------------------------------------------------
-- Shared list engine: colored, collapsible category bars, lines with buttons
---------------------------------------------------------------------------
-- Category bar colors (solid background, dark text).
local CAT_COLORS = {
  turnin = { 0.30, 0.80, 0.30 },
  zone = { 0.90, 0.75, 0.20 },
  dungeon = { 0.62, 0.45, 0.90 },
  singles = { 0.80, 0.70, 0.40 },
  later = { 0.85, 0.35, 0.35 },
  pvp = { 0.95, 0.55, 0.45 },
  take = { 0.40, 0.65, 0.95 },
  step = { 0.90, 0.75, 0.20 },
  abandon = { 0.90, 0.50, 0.25 },
  class = { 0.35, 0.80, 0.80 },
  info = { 0.55, 0.55, 0.55 },
}

-- Item tooltip opened from a list line: hidden when the lines are redrawn or the window closes
-- (the line under the cursor may be hidden or reused without any "leave" event).
function Geo.HideRowTooltip()
  local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
  if owner and owner.isListRow then GameTooltip:Hide() end
end

-- Quest link for the chat, the same for every player (with or without addons): the game's link for
-- a quest of the log; otherwise a link in the same format, built from QuestieDB (name, level).
function Geo.QuestChatLink(id)
  if IsInLog(id) then
    for _, f in ipairs({ C_QuestLog and C_QuestLog.GetQuestLink or false, GetQuestLink or false }) do
      if f then
        local ok, link = pcall(f, id)
        if ok and type(link) == "string" and link ~= "" then return link end
      end
    end
  end
  local name = QGet(QDB.Quest, id, "name")
  if not name and C_QuestLog.GetTitleForQuestID then name = C_QuestLog.GetTitleForQuestID(id) end
  local level = tonumber(QGet(QDB.Quest, id, "questLevel")) or 0
  return string.format("|cffffff00|Hquest:%d:%d|h[%s]|h|r", id, level, name or "?")
end

-- Shift-click on a quest line: its link goes into the chat input (opened if needed).
function Geo.LinkQuestInChat(id)
  local link = Geo.QuestChatLink(id)
  if not (ChatEdit_InsertLink and ChatEdit_InsertLink(link)) and ChatFrame_OpenChat then ChatFrame_OpenChat(link) end
end

-- Lines wider than the text area: wrapped here, each continuation starting with the same indent
-- (the game wraps at the left edge). Item links and textures are never cut; an open color goes on.
function Geo.IndentWrap(text, width)
  if not (text and width and width > 0) then return text end
  local fs = Geo.wrapMeasure
  if not fs then
    fs = UIParent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:Hide()
    Geo.wrapMeasure = fs
  end
  local function W(s)
    fs:SetText(s)
    return fs:GetStringWidth() or 0
  end
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if W(line) <= width then
      out[#out + 1] = line
    else
      local indent = line:match("^( *)")
      -- Spaces inside links ("|H...|h[...]|h") and textures ("|T...|t") do not split words.
      local body = line:sub(#indent + 1):gsub("|H.-|h.-|h", function(l) return (l:gsub(" ", "\001")) end)
        :gsub("|T.-|t", function(t) return (t:gsub(" ", "\001")) end)
      local cur, color = nil, nil
      for word in body:gmatch("%S+") do
        word = word:gsub("\001", " ")
        local test = cur and (cur .. " " .. word) or (indent .. (color or "") .. word)
        if cur and W(test) > width then
          out[#out + 1] = cur
          -- Color still open at the end of the line: repeated at the start of the next one.
          local last = nil
          for code in cur:gmatch("|c%x%x%x%x%x%x%x%x") do last = code end
          local lastPos = 0
          for pos in cur:gmatch("()|c%x%x%x%x%x%x%x%x") do lastPos = pos end
          color = (last and not cur:find("|r", lastPos, true)) and last or nil
          cur = indent .. (color or "") .. word
        else
          cur = test
        end
      end
      if cur then out[#out + 1] = cur end
    end
  end
  return table.concat(out, "\n")
end

-- Trash icon: game atlas when this client has it, otherwise the red cross of the loot roll.
K.TRASH_ATLAS = "common-icon-delete"
K.TRASH_TEXTURE = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"

local function ListRow(panel, i)
  panel.rows = panel.rows or {}
  local r = panel.rows[i]
  if r then return r end
  r = CreateFrame("Frame", nil, panel.scroll.child)
  r:SetWidth(panel.contentWidth or CONTENT_WIDTH)
  r.isListRow = true
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.hl = r:CreateTexture(nil, "BACKGROUND", nil, 1)
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 0.85, 0.4, 0.12)
  r.hl:Hide()
  r.stripe = r:CreateTexture(nil, "BORDER")
  r.stripe:SetPoint("TOPLEFT")
  r.stripe:SetPoint("BOTTOMLEFT")
  r.stripe:SetWidth(4)
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  r.text:SetPoint("TOPLEFT", 10, -6)
  r.text:SetJustifyH("LEFT")
  r.text:SetSpacing(2)
  -- Item names of a line (rewards): game tooltip on hover.
  if r.SetHyperlinksEnabled then
    r:SetHyperlinksEnabled(true)
    r:SetScript("OnHyperlinkEnter", function(self, link)
      GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
      pcall(GameTooltip.SetHyperlink, GameTooltip, link)
      GameTooltip:Show()
    end)
    r:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
  end
  -- Three button columns (b1, b2, b3), placed by RenderList according to the tab's grid.
  r.b1 = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  r.b2 = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  r.b3 = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  for _, b in ipairs({ r.b1, r.b2, r.b3 }) do b:SetHeight(20) end
  -- Trash icon at the left of the line (item field `trash`).
  r.trash = CreateFrame("Button", nil, r)
  r.trash:SetSize(16, 16)
  r.trash:SetPoint("TOPLEFT", 8, -5)
  local tex = r.trash:CreateTexture(nil, "ARTWORK")
  tex:SetAllPoints()
  if not (Geo.HasAtlas(K.TRASH_ATLAS) and pcall(tex.SetAtlas, tex, K.TRASH_ATLAS)) then tex:SetTexture(K.TRASH_TEXTURE) end
  r.trash:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  r.trash:Hide()
  -- Section title line: thin golden rule under the text.
  r.rule = r:CreateTexture(nil, "BORDER")
  r.rule:SetPoint("BOTTOMLEFT", 6, 2)
  r.rule:SetPoint("BOTTOMRIGHT", -6, 2)
  r.rule:SetHeight(1)
  r.rule:SetColorTexture(1, 0.82, 0, 0.6)
  r.rule:Hide()
  panel.rows[i] = r
  return r
end

-- spec = { text, fn, tip = { title, text } }: tip shown on hover.
local function SetButton(b, spec)
  if spec then
    b:SetText(spec.text)
    b:SetEnabled(not spec.disabled)
    b:SetScript("OnClick", spec.fn)
    local tip = spec.tip
    b:SetScript("OnEnter", tip and function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(tip[1])
      if tip[2] then GameTooltip:AddLine(tip[2], 0.8, 0.8, 0.8, true) end
      GameTooltip:Show()
    end or nil)
    b:SetScript("OnLeave", tip and function() GameTooltip:Hide() end or nil)
    b:Show()
  else
    b:Hide()
  end
end

local BUTTON_MIN = { 80, 72, 80 } -- minimum width per column
K.BUTTON_GAP = 4

-- List button grid: columns used by at least one line, common width
-- per column (the longest label), aligned as far right as possible.
local measureText
local function ButtonGrid(items)
  if not measureText then
    measureText = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    measureText:Hide()
  end
  local width, used = { 0, 0, 0 }, { false, false, false }
  for _, it in ipairs(items) do
    for c, key in ipairs({ "b1", "b2", "b3" }) do
      local spec = it[key]
      if spec then
        used[c] = true
        measureText:SetText(spec.text)
        local w = (measureText:GetStringWidth() or 0) + 24
        if w > width[c] then width[c] = w end
      end
    end
  end
  local offsets, x = {}, -2
  for c = 3, 1, -1 do
    if used[c] then
      width[c] = math.max(width[c], BUTTON_MIN[c])
      offsets[c] = x
      x = x - width[c] - K.BUTTON_GAP
    end
  end
  return { width = width, used = used, offsets = offsets, total = -x }
end

-- items: { header = true, kind, key, label, b1, b2, b3 } | { text, b1, b2, b3, trash, tint, stripe }  (b = { text, fn, tip })
-- trash: clickable trash icon at the left of the line (b without text).
-- Categories are collapsed by default and every time the window opens.
-- Categories expanded while the window is open; everything collapses again each time it opens.
local expandedCategories = {}

K.MAX_VISIBLE_ROWS = 400

local OpenQuestDetails -- defined with quest tracking, further down

-- panel: a tab, or a pane of one ({ scroll, contentWidth }: Geo.CreatePane).
local function RenderList(panel, tabKey, items, forceOpen)
  Geo.HideRowTooltip()
  local width = panel.contentWidth or CONTENT_WIDTH
  -- Two grids: quest lines and category bars, each aligned to the right.
  local rowItems, headerItems = {}, {}
  for _, it in ipairs(items) do
    if it.header then headerItems[#headerItems + 1] = it else rowItems[#rowItems + 1] = it end
  end
  local rowGrid, headerGrid = ButtonGrid(rowItems), ButtonGrid(headerItems)
  local expanded = expandedCategories
  local y, zebra, n, closed, capped = -4, 0, 0, false, false
  for _, it in ipairs(items) do
    local ckey = it.key and (tabKey .. ":" .. it.key)
    if it.section then closed = false end -- a section ends the previous category
    if it.header then
      -- open = true: category expanded by default (expanded[ckey] == false once collapsed).
      local isClosed = it.open and expanded[ckey] == false or (not it.open and not expanded[ckey])
      closed = (not forceOpen) and ckey and isClosed and true or false
    end
    if n >= K.MAX_VISIBLE_ROWS and not it.header and not it.section then
      capped = capped or not closed -- too many expanded lines: only the bars stay visible
    elseif it.header or it.section or not closed then
      if it.section and n > 0 then y = y - 10 end -- space above a section title
      n = n + 1
      local r = ListRow(panel, n)
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", 0, y)
      r:Show()
      r.hl:Hide()
      local grid = it.header and headerGrid or rowGrid
      for c, b in ipairs({ r.b1, r.b2, r.b3 }) do
        SetButton(b, it["b" .. c])
        if grid.used[c] then
          b:ClearAllPoints()
          b:SetPoint("TOPRIGHT", r, "TOPRIGHT", grid.offsets[c], -2)
          b:SetWidth(grid.width[c])
        end
      end
      local trash = it.trash
      r.trash:SetShown(trash and true or false)
      r.trash:SetScript("OnClick", trash and trash.fn or nil)
      r.trash:SetScript("OnEnter", trash and trash.tip and function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(trash.tip[1])
        if trash.tip[2] then GameTooltip:AddLine(trash.tip[2], 0.8, 0.8, 0.8, true) end
        GameTooltip:Show()
      end or nil)
      r.trash:SetScript("OnLeave", trash and function() GameTooltip:Hide() end or nil)
      r.text:ClearAllPoints()
      r.text:SetPoint("TOPLEFT", trash and 22 or 10, -6)
      local hasButtons = it.b1 or it.b2 or it.b3
      r.text:SetFontObject(it.section and "GameFontNormalLarge" or "GameFontHighlight")
      r.rule:SetShown(it.section and true or false)
      r.text:SetWidth(width - (hasButtons and (grid.total + 12) or 16) - (trash and 12 or 0))
      if it.stripe then
        r.stripe:SetColorTexture(it.stripe[1], it.stripe[2], it.stripe[3], 1)
        r.stripe:Show()
      else
        r.stripe:Hide()
      end
      if it.section then
        r.bg:SetColorTexture(0, 0, 0, 0)
        r.text:SetText(it.text or "")
        r:EnableMouse(false)
        r:SetScript("OnMouseUp", nil)
        r:SetScript("OnEnter", nil)
        r:SetScript("OnLeave", nil)
        zebra = 0
      elseif it.header then
        local c = CAT_COLORS[it.kind] or CAT_COLORS.zone
        r.bg:SetColorTexture(c[1], c[2], c[3], 0.9)
        local prefix = ckey and ((closed and "[+]  ") or "[-]  ") or ""
        r.text:SetText("|cff101010" .. prefix .. it.label .. "|r")
        r:SetScript("OnEnter", nil)
        r:SetScript("OnLeave", nil)
        r.hl:Hide()
        if ckey then
          r:EnableMouse(true)
          r:SetScript("OnMouseUp", function()
            if it.open then
              if expanded[ckey] == false then expanded[ckey] = nil else expanded[ckey] = false end
            else
              expanded[ckey] = not expanded[ckey] or nil
            end
            Refresh()
          end)
        else
          r:EnableMouse(false)
          r:SetScript("OnMouseUp", nil)
        end
        zebra = 0
      else
        zebra = zebra + 1
        if it.tint then
          r.bg:SetColorTexture(it.tint[1], it.tint[2], it.tint[3], (zebra % 2 == 0) and 0.24 or 0.18)
        else
          r.bg:SetColorTexture(1, 1, 1, (zebra % 2 == 0) and 0.05 or 0)
        end
        local qid = it.questID or it.linkQuest
        if it.onClick then
          -- Roadbook step: click shows it on the map; Shift-click: quest link in the chat.
          r:EnableMouse(true)
          r:SetScript("OnMouseUp", function()
            if qid and IsShiftKeyDown and IsShiftKeyDown() then Geo.LinkQuestInChat(qid) else it.onClick() end
          end)
          r:SetScript("OnEnter", function(self) self.hl:Show() end)
          r:SetScript("OnLeave", function(self) self.hl:Hide() end)
        elseif qid then
          -- Click: quest details (quest of the log); Shift-click: quest link in the chat.
          local inLog = it.questID and IsInLog(it.questID)
          r:EnableMouse(true)
          r:SetScript("OnMouseUp", function()
            if IsShiftKeyDown and IsShiftKeyDown() then
              Geo.LinkQuestInChat(qid)
            elseif inLog then
              OpenQuestDetails(qid)
            end
          end)
          r:SetScript("OnEnter", inLog and function(self) self.hl:Show() end or nil)
          r:SetScript("OnLeave", inLog and function(self) self.hl:Hide() end or nil)
        else
          r:EnableMouse(it.links and true or false) -- item names: tooltips need the mouse
          r:SetScript("OnMouseUp", nil)
          r:SetScript("OnEnter", nil)
          r:SetScript("OnLeave", nil)
        end
        r.text:SetText(Geo.IndentWrap(it.text or "", r.text:GetWidth()))
      end
      local h = math.max(it.header and 24 or 26, r.text:GetStringHeight() + (it.section and 14 or 12))
      r:SetHeight(h)
      y = y - h - (it.header and 3 or 0)
    end
  end
  if capped then
    n = n + 1
    local r = ListRow(panel, n)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, y)
    r:Show()
    for _, b in ipairs({ r.b1, r.b2, r.b3, r.trash }) do b:Hide() end
    r.stripe:Hide()
    r.rule:Hide()
    r.text:SetFontObject("GameFontHighlight")
    r.bg:SetColorTexture(1, 0.5, 0.15, 0.2)
    r:EnableMouse(false)
    r:SetScript("OnMouseUp", nil)
    r.text:ClearAllPoints()
    r.text:SetPoint("TOPLEFT", 10, -6)
    r.text:SetWidth(width - 16)
    r.text:SetText(Color("ff8040", L["Too many expanded lines: collapse some categories, pick a narrower filter or search."]))
    r:SetHeight(26)
    y = y - 26
  end
  for i = n + 1, #(panel.rows or {}) do panel.rows[i]:Hide() end
  panel.scroll.child:SetHeight(-y + 10)
  UpdateScrollBar(panel.scroll)
end

-- Pane of a tab: a fixed header (title, info lines, a button on the right) above its own scrolling
-- list, between x1 and x2 (from the left of the window) and from y = top to the bottom.
-- RenderList draws in it; Geo.PaneHeader fills the header.
function Geo.CreatePane(parent, x1, x2, top)
  local pane = { contentWidth = x2 - x1 - 26 }
  local head = CreateFrame("Frame", nil, parent)
  head:SetPoint("TOPLEFT", State.mainFrame, "TOPLEFT", x1, top)
  head:SetWidth(x2 - x1)
  head:SetHeight(30)
  pane.head = head
  pane.title = head:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  pane.title:SetPoint("TOPLEFT", 10, -4)
  pane.rule = head:CreateTexture(nil, "BORDER")
  pane.rule:SetPoint("TOPLEFT", pane.title, "BOTTOMLEFT", -4, -3)
  pane.rule:SetPoint("RIGHT", head, "RIGHT", -6, 0)
  pane.rule:SetHeight(1)
  pane.rule:SetColorTexture(1, 0.82, 0, 0.6)
  pane.button = CreateFrame("Button", nil, head, "UIPanelButtonTemplate")
  pane.button:SetHeight(20)
  pane.button:SetPoint("TOPRIGHT", -24, -2)
  pane.button:Hide()
  pane.info = head:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  pane.info:SetPoint("TOPLEFT", pane.rule, "BOTTOMLEFT", 4, -5)
  pane.info:SetWidth(pane.contentWidth - 8)
  pane.info:SetJustifyH("LEFT")
  pane.info:SetSpacing(2)
  local child = CreateFrame("Frame", nil, parent)
  child:SetSize(pane.contentWidth, 1)
  local scroll = CreateScrollPanel(parent, child)
  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
  scroll:SetPoint("BOTTOMRIGHT", State.mainFrame, "BOTTOMLEFT", x2 - 22, 24)
  pane.scroll = scroll
  return pane
end

-- Header of a pane: title, info text (nil: none) and button ({ text, fn, tip }; nil: hidden).
function Geo.PaneHeader(pane, title, info, button)
  pane.title:SetText(title or "")
  pane.info:SetText(info or "")
  pane.info:SetShown(info ~= nil and info ~= "")
  SetButton(pane.button, button)
  if button then
    measureText = measureText or UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    measureText:Hide()
    measureText:SetText(button.text)
    pane.button:SetWidth(math.max(80, (measureText:GetStringWidth() or 60) + 24))
  end
  local h = 4 + (pane.title:GetStringHeight() or 16) + 4
  if pane.info:IsShown() then h = h + 5 + (pane.info:GetStringHeight() or 0) end
  pane.head:SetHeight(h + 6)
end

local function ShowMessage(panel, tabKey, text)
  RenderList(panel, tabKey, { { text = text } })
end

local function Plural(n, word)
  return n .. " " .. word .. "(s)"
end

local function RenderExport()
  local eb = panels.export.scroll.child
  local text = BuildText()
  eb.fullText = text
  eb:SetText(text)
  eb:SetFocus()
  eb:SetCursorPosition(0)
  eb:HighlightText()
  UpdateScrollBar(panels.export.scroll)
end

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
  if QuestMapFrame_OpenToQuestDetails then
    if pcall(QuestMapFrame_OpenToQuestDetails, questID) then return end
  end
  if C_QuestLog.SetSelectedQuest then pcall(C_QuestLog.SetSelectedQuest, questID) end
  local logFrame = rawget(_G, "QuestLogFrame")
  if logFrame then
    if not logFrame:IsShown() then
      if ShowUIPanel then pcall(ShowUIPanel, logFrame) else logFrame:Show() end
    end
    local idx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
    if idx and QuestLog_SetSelection then pcall(QuestLog_SetSelection, idx) end
    if QuestLog_Update then pcall(QuestLog_Update) end
    return
  end
  if ToggleQuestLog then pcall(ToggleQuestLog) end
end

-- Tracks a single quest: removes every other one from tracking. Only when the tracking really changes:
-- each change made by the addon taints Blizzard's objective tracker (blocked aura reads afterwards).
local function WatchOnly(questID)
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do
    if q.id ~= questID and IsWatched(q.id) then SetWatched(q.id, false) end
  end
  if not IsWatched(questID) then SetWatched(questID, true) end
end

-- Most useful point of a quest: nearest remaining objective, otherwise the turn-in NPC.
local function ObjectivePoint(q)
  local pos = PlayerPos()
  local t = QuestTargets(q.id)
  if not q.complete then
    local best, bd, label
    for _, r in ipairs(RemainingTargets(q, t)) do
      local p, d = Nearest(r.tg.points, pos)
      if p and (not best or (d and (not bd or d < bd))) then best, bd, label = p, d, r.tg.name end
    end
    if best then return best, label end
  end
  local f = Nearest(t.finish, pos)
  return f, L["turn in the quest"]
end
Geo.ObjectivePoint = ObjectivePoint

-- Pin placed by the addon (OpenMap's waypoint), remembered per character.
local function PinStore()
  local s = Settings()
  s.pins = s.pins or {}
  return s.pins
end

-- The waypoint OpenMap follows now sits on this map point.
function Geo.WaypointAt(ui, x, y)
  local m, wx, wy = ns.OM.worldmap.WaypointPoint()
  return m == ui and wx and math.abs(wx - x) < 1e-3 and math.abs(wy - y) < 1e-3 or false
end

-- Active addon pin, or nil if the waypoint was cleared or replaced by another one.
local function ActivePin()
  local pin = PinStore()[CharKey()]
  if not pin then return nil end
  if not (pin.ui and Geo.WaypointAt(pin.ui, pin.x, pin.y)) then
    PinStore()[CharKey()] = nil
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
  if ActivePin() then pcall(ns.OM.worldmap.ClearPin) end
  PinStore()[CharKey()] = nil
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

-- Quest state icons (textures available in every client).
local ICON = {
  turnin = "|TInterface\\GossipFrame\\ActiveQuestIcon:16:16|t",     -- yellow ?: to turn in
  inprogress = "|TInterface\\GossipFrame\\IncompleteQuestIcon:16:16|t", -- gray ?: in progress
  available = "|TInterface\\GossipFrame\\AvailableQuestIcon:16:16|t",  -- yellow !: to pick up
  watched = "|TInterface\\Buttons\\UI-CheckBox-Check:16:16|t",         -- check mark: tracked
  custom = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:16:16|t", -- yellow star: custom Roadbook
  abandon = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:16:16|t",       -- red cross: to abandon
  done = "|TInterface\\RaidFrame\\ReadyCheck-Ready:16:16|t",            -- green check: turned in (as the steps done)
}

-- Quests of the log recommended for abandoning (ids), from the last Analyze(); computed again after
-- a quest event (Events.lua clears State.abandonIds).
function Geo.ToAbandon(questId)
  if not State.abandonIds then
    pcall(ns.Analyze)
    State.abandonIds = State.abandonIds or {} -- no new try on each line after an error
  end
  return State.abandonIds[questId] or false
end

local function StateIcons(questId)
  if not questId then return "" end
  local icons = {}
  if IsInLog(questId) then
    local done = C_QuestLog.IsComplete and C_QuestLog.IsComplete(questId)
    icons[#icons + 1] = done and ICON.turnin or ICON.inprogress
    if IsWatched(questId) then icons[#icons + 1] = ICON.watched end
  elseif IsCompleted(questId) then
    icons[#icons + 1] = ICON.done
  else
    icons[#icons + 1] = ICON.available
  end
  if IsPinned(questId) then icons[#icons + 1] = PinIcon() end
  if Geo.InCustom(questId) then icons[#icons + 1] = ICON.custom end
  if IsInLog(questId) and Geo.ToAbandon(questId) then icons[#icons + 1] = ICON.abandon end -- last: before "[To abandon]"
  return table.concat(icons, "") .. " "
end

---------------------------------------------------------------------------
-- Quest line shown the same way in every tab: title, level, elite, types
---------------------------------------------------------------------------
-- Quest types, deduced from the QuestieDB objectives (several per quest, in this order).
K.QUEST_TYPES = { "escort", "assassination", "slaying", "collect", "gathering", "interaction", "exploration",
  "talk", "reputation", "delivery" }
K.QUEST_TYPE_LABEL = {
  escort = L["Escort"], assassination = L["Assassination"], slaying = L["Slaying"], collect = L["Collect"],
  gathering = L["Gathering"], interaction = L["Interaction"], exploration = L["Exploration"], talk = L["Talk"],
  reputation = L["Reputation"], delivery = L["Delivery"],
}

-- Words of the objective text, for quests whose objectives QuestieDB does not know.
K.QUEST_TYPE_WORDS = {
  slaying = { "%f[%a]kill", "%f[%a]slay", "%f[%a]destroy", "%f[%a]defeat", "%f[%a]exterminate", "%f[%a]eliminate" },
  collect = { "%f[%a]collect%f[%A]", "%f[%a]gather%f[%A]", "%f[%a]obtain%f[%A]", "%f[%a]recover%f[%A]",
    "%f[%a]retrieve%f[%A]", "bring %d", "bring me %d" },
  exploration = { "%f[%a]explore%f[%A]", "%f[%a]scout%f[%A]", "%f[%a]investigate%f[%A]", "%f[%a]locate%f[%A]" },
  interaction = { "%f[%a]use%f[%A]", "%f[%a]place%f[%A]", "%f[%a]plant%f[%A]", "%f[%a]activate%f[%A]" },
}

-- Unique NPC (to assassinate): rare, rare elite or boss, or a single known spawn point.
function Geo.UniqueNpc(id)
  local rank = QGet(QDB.Npc, id, "rank")
  if rank == 2 or rank == 3 or rank == 4 then return true end
  local spawns, n = QGet(QDB.Npc, id, "spawns"), 0
  if type(spawns) == "table" then
    for _, pts in pairs(spawns) do n = n + (type(pts) == "table" and #pts or 0) end
  end
  return n == 1
end

Geo.qtypes = {}
function Geo.QuestTypes(id)
  if not id then return {} end
  local cached = Geo.qtypes[id]
  if cached then return cached end
  local has = {}
  if Geo.IsEscort(id) then has.escort = true end
  local obj = QGet(QDB.Quest, id, "objectives")
  if type(obj) == "table" then
    for _, o in ipairs(obj[1] or {}) do
      local icon = o[3]
      if icon == 3 or icon == 5 or icon == 17 then has.talk = true
      elseif Geo.UniqueNpc(o[1]) then has.assassination = true
      else has.slaying = true end
    end
    if #(obj[2] or {}) > 0 then has.interaction = true end
    for _, o in ipairs(obj[3] or {}) do
      local npcs, objs = QGet(QDB.Item, o[1], "npcDrops"), QGet(QDB.Item, o[1], "objectDrops")
      if type(npcs) == "table" and #npcs > 0 then has.collect = true
      elseif type(objs) == "table" and #objs > 0 then has.gathering = true
      else has.collect = true end -- bought, crafted…
    end
    if #(obj[4] or {}) > 0 then has.reputation = true end
    local givesItem = (tonumber(QGet(QDB.Quest, id, "sourceItemId")) or 0) > 0 -- 0 = no item
    for _, o in ipairs(obj[5] or {}) do
      if givesItem then has.interaction = true -- credit for using the item given by the quest on them
      elseif type(o) == "table" and o[2] and Geo.UniqueNpc(o[2]) then has.assassination = true
      else has.slaying = true end
    end
    if #(obj[6] or {}) > 0 then has.interaction = true end
  end
  if not has.escort and type(QGet(QDB.Quest, id, "triggerEnd")) == "table" then has.exploration = true end
  if not next(has) then
    -- No objective known by QuestieDB (frequent for Forever quests): words of the English text.
    local text = ""
    local ok, t = pcall(QDB.Quest.GetRaw, id, "objectivesText")
    if ok and type(t) == "table" then text = table.concat(t, " "):lower() end
    for kind, words in pairs(K.QUEST_TYPE_WORDS) do
      for _, w in ipairs(words) do
        if text:find(w) then has[kind] = true break end
      end
    end
    if not next(has) then has.delivery = true end -- bring something / someone, or talk to an NPC
  end
  local list = {}
  for _, k in ipairs(K.QUEST_TYPES) do if has[k] then list[#list + 1] = k end end
  Geo.qtypes[id] = list
  return list
end

-- Game tag of a quest of the log ("Elite", "Dungeon"…), "" if none, nil if not in the log.
function Geo.LogTag(id)
  local e = ForeverQuestPlannerDB and ForeverQuestPlannerDB[CharKey()]
  for _, q in ipairs(e and e.quests or {}) do
    if q.id == id then return q.tag or "" end
  end
  return nil
end

-- Quest level, colored like in the game's quest log (gray, green, yellow, orange, red).
function Geo.LevelBadge(level)
  if not (level and level > 0) then return "" end
  local hex
  if GetQuestDifficultyColor then
    local ok, c = pcall(GetQuestDifficultyColor, level)
    if ok and type(c) == "table" and c.r then
      hex = string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
  end
  if not hex then
    local gap = level - (UnitLevel("player") or level)
    hex = (gap >= 5 and "ff2020") or (gap >= 3 and "ff8040") or (gap >= -2 and "ffff00") or "40c040"
  end
  return Color(hex, "[" .. level .. "]")
end

-- Quest types of a quest, colored: "Escort · Collect" ("" if none, at most 3).
function Geo.QuestTypesText(id)
  local types, parts = Geo.QuestTypes(id), {}
  for i = 1, math.min(#types, 3) do parts[#parts + 1] = Color("80c0ff", K.QUEST_TYPE_LABEL[types[i]]) end
  return table.concat(parts, Color("80c0ff", " · "))
end

-- "  [35] Elite · Dungeon · Escort · Collect": o = { id, level, tag (game tag, log quests),
-- isClass, isProf, dungeon, noTypes (types left out, shown apart with Geo.QuestTypesText) }.
-- A quest that follows another one (a quest prerequisite in QuestieDB).
function Geo.IsFollowUp(id)
  if not id then return false end
  for _, key in ipairs({ "preQuestGroup", "preQuestSingle" }) do
    local t = QGet(QDB.Quest, id, key)
    if type(t) == "table" and #t > 0 then return true end
  end
  return false
end

function Geo.QuestBadges(o)
  local id = o.id
  local tag = o.tag
  if tag == nil and id then tag = Geo.LogTag(id) end
  local parts = {}
  if id and Geo.IsFollowUp(id) then parts[#parts + 1] = Color(K.DESC.chain, L["Follow-up"]) end
  if id and Geo.IsEliteQuest(id, tag) then parts[#parts + 1] = Color("ff8040", L["Elite"]) end
  if tag and tag ~= "" and not tag:find("[EÉ]lite") and tag ~= ELITE then parts[#parts + 1] = tag
  elseif o.dungeon then parts[#parts + 1] = Geo.WithLevel(Color("80c0ff", L["Dungeon"]), o.dungeon) end
  local isClass = o.isClass
  if isClass == nil and id then
    local m = QuestMeta(id)
    isClass = m and IsClassMeta(m) or false
  end
  if isClass then parts[#parts + 1] = L["Class"] end
  if o.isProf then parts[#parts + 1] = L["Profession"] end
  local types = o.noTypes and {} or Geo.QuestTypes(id)
  for i = 1, math.min(#types, 3) do parts[#parts + 1] = K.QUEST_TYPE_LABEL[types[i]] end
  local badge = Geo.LevelBadge(o.level)
  -- each part in square brackets, coloured on its own (colour codes do not nest; some parts carry their own colours)
  local blue = Color("80c0ff", "[")
  for i, p in ipairs(parts) do
    if not p:find("^|c") then p = Color("80c0ff", p) end
    parts[i] = blue .. p .. Color("80c0ff", "]")
  end
  return "  " .. badge .. (#parts > 0 and (" " .. table.concat(parts, " ")) or "")
end

-- Quest descriptions: the same layout and colors in every tab and on the Objective button.
--   line 1: state or step icons, [kind], white title, badges (colored level, elite, types);
--   next lines, indented, one subject each: what to do and where (light gray), figures (XP and
--   follow-ups in color, the rest in gray), warnings (orange), blockers (red), rewards.
--   Informations on one line are separated by " · ".
K.DESC = { action = "bbbbbb", meta = "888888", xp = "80c0ff", warn = "ffb060", bad = "ff6060",
  good = "40ff40", chain = "c080ff" }
K.DESC_LINE = "\n       "
K.DESC_SEP = " · "

-- White title + badges (o: options of Geo.QuestBadges; none for a step that is not a quest).
function Geo.QuestTitle(title, o)
  return Color("ffffff", title or "?") .. ((o and o.id) and Geo.QuestBadges(o) or "")
end

-- Next description line: the non-empty parts (already colored), separated by a gray " · ".
function Geo.DescLine(...)
  local kept = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if p and p ~= "" then kept[#kept + 1] = p end
  end
  if #kept == 0 then return "" end
  return K.DESC_LINE .. table.concat(kept, Color(K.DESC.meta, K.DESC_SEP))
end

-- XP of a quest or a step: "+1 200 XP" (exact) or "~1 200 XP" (estimate).
function Geo.XPText(xp, approx, suffix)
  if not (xp and xp > 0) then return nil end
  return Color(K.DESC.xp, (approx and "~" or "+") .. FormatNumber(xp) .. " XP" .. (suffix or ""))
end

-- Kind of step, the same labels and colors in the Roadbook and the Nearby tab.
function Geo.KindTag(kind)
  if kind == "take" then return Color("80c0ff", L["[Pick up]"]) end
  if kind == "obj" then return Color("ffd100", L["[Objective]"]) end
  if kind == "turnin" then return Color("40ff40", L["[Turn in]"]) end
  return ""
end

local function IconLegend(withAvailable)
  return Color("aaaaaa", ICON.turnin .. L[" to turn in   "] .. ICON.inprogress .. L[" in progress   "] .. ICON.watched ..
    L[" tracked   "] .. PinIcon() .. L["pin"] .. (withAvailable and ("   " .. ICON.available .. L[" to pick up"]) or ""))
end

-- Quest states (for filters): turnin, inprogress, watched, pinned, available.
local function QuestStates(questId)
  local st = {}
  if not questId then return st end
  if IsInLog(questId) then
    if C_QuestLog.IsComplete and C_QuestLog.IsComplete(questId) then st.turnin = true else st.inprogress = true end
    if IsWatched(questId) then st.watched = true end
  else
    st.available = true
  end
  if IsPinned(questId) then st.pinned = true end
  if Geo.InCustom(questId) then st.custom = true end
  return st
end

-- State filters: none checked = everything; otherwise the quest must have at least one checked state.
local journalStates, nearStates = {}, {}
local function PassStates(questId, selected, toDrop)
  if not next(selected) then return true end
  local st = QuestStates(questId)
  if toDrop then st.abandon = true end
  for key in pairs(selected) do
    if st[key] then return true end
  end
  return false
end

-- Follows a QuestieDB point: OpenMap's waypoint (the game's pin and arrow, TomTom's too).
local function PinPoint(p, title, label, questId)
  if not p then
    Print(L["Unknown position for \""] .. (title or "?") .. L["\"."])
    return
  end
  local ui = Geo.PointUi(p)
  if not ui then
    Print(L["No map found for this position."])
    return
  end
  local x, y = (p.mx or 50) / 100, (p.my or 50) / 100
  -- Recorded first: OpenMap redraws its waypoint during TrackPoint (see the PinAt lock, RoadbookMap.lua).
  PinStore()[CharKey()] = { questId = questId, title = title, label = label, ui = ui, x = x, y = y,
    place = PointText(p), area = p.area, mx = p.mx, my = p.my }
  local done = pcall(ns.OM.worldmap.TrackPoint, ui, x, y, title and label and (title .. " - " .. label) or title)
  if done then
    Print(L["Pin: "] .. (title or "?") .. (label and (" - " .. label) or "") .. " - " .. PointText(p))
    if Refresh then C_Timer.After(0.1, Refresh) end
  else
    PinStore()[CharKey()] = nil
    Print(L["This client cannot place a pin here ("] .. PointText(p) .. ").")
  end
end

-- The addon pin as recorded (map point), whether or not OpenMap still follows it.
function Geo.PinRecord()
  return PinStore()[CharKey()]
end

-- Map (uiMap) of a point, or nil.
function Geo.PointUi(p)
  if not p then return nil end
  local ui = p.ui or Geo.areaToUi[p.area]
  if (not ui or ui == 0) and Geo.parent[p.area] then ui = Geo.areaToUi[Geo.parent[p.area]] end
  return (ui and ui ~= 0) and ui or nil
end

-- Map of the quest's zone (QuestieDB zoneOrSort), when no position is known.
function Geo.QuestZoneUi(id)
  local sort = QGet(QDB.Quest, id, "zoneOrSort") or 0
  if not (type(sort) == "number" and sort > 0 and GeoReady()) then return nil end
  return Geo.PointUi({ area = sort })
end

-- Where to pick up a quest: its giver, otherwise the monsters / objects dropping the item that
-- starts it, otherwise its first located objective, otherwise its turn-in NPC.
function Geo.GiverPoint(id, pos)
  local p = Nearest(StartPoints(id), pos)
  if p then return p, L["pick up the quest"] end
  local by = QGet(QDB.Quest, id, "startedBy")
  local items = type(by) == "table" and by[3]
  for _, itemId in ipairs(type(items) == "table" and items or {}) do
    local pts = {}
    for _, n in ipairs(QGet(QDB.Item, itemId, "npcDrops") or {}) do
      for _, w in ipairs(EntityPoints("npc", n)) do pts[#pts + 1] = w end
    end
    for _, o in ipairs(QGet(QDB.Item, itemId, "objectDrops") or {}) do
      for _, w in ipairs(EntityPoints("object", o)) do pts[#pts + 1] = w end
    end
    local q = Nearest(pts, pos)
    if q then return q, L["item that starts the quest"] end
  end
  local t = QuestTargets(id)
  for _, tg in ipairs(t) do
    local q = Nearest(tg.points, pos)
    if q then return q, tg.name or L["objective"] end
  end
  local f = Nearest(t.finish, pos)
  if f then return f, L["turn in the quest"] end
  return nil
end

-- Opens the world map on a map (the addon window is closed so that it does not hide it).
-- keepWindow: the Forever Quest Planner window stays open (Roadbook tabs).
function Geo.OpenWorldMap(ui, keepWindow)
  if not keepWindow and State.mainFrame and State.mainFrame:IsShown() then State.mainFrame:Hide() end
  if not WorldMapFrame then return end
  if not WorldMapFrame:IsShown() then
    if ToggleWorldMap then pcall(ToggleWorldMap) elseif ShowUIPanel then pcall(ShowUIPanel, WorldMapFrame) end
  end
  if ui and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, ui) end
end

-- "Map" button: pin on the quest's place (getPoint() -> point, label), then the world map on it.
function Geo.ShowOnMap(getPoint, title, questId)
  local p, label
  if GeoReady() then p, label = getPoint() end
  -- A followed Roadbook keeps the map: the map only opens on the place; a preview ends.
  local owner = Geo.MapOwner and Geo.MapOwner()
  if owner and owner.mode == "preview" then Geo.MapRelease() owner = nil end
  if p and owner then
    Print(L["A Roadbook is followed: the map shows only its steps (turn its tracking off to place a pin)."])
    Geo.OpenWorldMap(Geo.PointUi(p))
    Geo.MapGlide(p)
  elseif p then
    PinPoint(p, title, label or L["objective"], questId)
    Geo.OpenWorldMap(Geo.PointUi(p))
  else
    Print(L["Unknown position for \""] .. (title or "?") .. L["\"."])
    Geo.OpenWorldMap(questId and Geo.QuestZoneUi(questId))
  end
end

function Geo.MapButton(getPoint, title, questId)
  return { text = L["Map"], fn = function() Geo.ShowOnMap(getPoint, title, questId) end,
    tip = { L["Map"], L["Places the map pin on this quest (giver, objective or turn-in) and opens the world map on it."] } }
end

-- Custom Roadbook buttons: add / remove a quest, add / remove every quest of a category.
K.CUSTOM_TIP = "Roadbook list: the quests the Roadbook does, along the fastest route."
function Geo.CustomButton(id, title, level)
  if not id then return nil end
  local inList = Geo.InCustom(id)
  return { text = inList and L["Remove"] or L["Add"],
    tip = { inList and L["Remove from the Roadbook list"] or L["Add to the Roadbook list"], L[K.CUSTOM_TIP] },
    disabled = Geo.computing and true or nil, -- the list is locked while the Roadbook is computed
    fn = function()
      if Geo.ListLocked() then return end
      local chain = Geo.ChainQuests(id)
      if Geo.InCustom(id) then
        local inChain = 0
        for _, c in ipairs(chain) do if Geo.InCustom(c.id) then inChain = inChain + 1 end end
        if inChain == 0 then Geo.CustomRemove(id) return end
        StaticPopup_Show("FQP_REMOVE_CHAIN", title or "?", inChain, { id = id })
      elseif #chain == 0 then
        Geo.CustomAdd(id, title, level)
      else
        StaticPopup_Show("FQP_ADD_CHAIN", title or "?", #chain, { id = id, title = title, level = level })
      end
    end }
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

-- Line "follow-up: n quest(s) up to level X" (nothing for a quest without follow-ups).
function Geo.ChainTextLine(id)
  if not id then return "" end
  local text = ChainText(ChainInfo(id, UnitLevel("player"), 0))
  return text and Geo.DescLine(Color(K.DESC.chain, text)) or ""
end

K.MAX_CHAIN_LINES = 10
K.CHAIN_INDENT = K.DESC_LINE .. "   "
-- Lines under a quest: its follow-ups as an indented block (title, level, level required, XP), muted
-- as they cannot be picked up yet. Beyond K.MAX_CHAIN_LINES, the last ones share a single line.
function Geo.ChainLines(id)
  local chain = Geo.ChainQuests(id)
  if #chain == 0 then return "" end
  local D, plevel = K.DESC, UnitLevel("player")
  local sep = Color(D.meta, K.DESC_SEP)
  local function title(c) return Color(D.chain, (c.title or "?") .. (c.level and (" [" .. c.level .. "]") or "")) end
  local text = K.DESC_LINE .. Color(D.chain, L["Follow-up:"])
  for i, c in ipairs(chain) do
    if i >= K.MAX_CHAIN_LINES and #chain > K.MAX_CHAIN_LINES then
      local rest = {}
      for j = i, #chain do rest[#rest + 1] = title(chain[j]) end
      text = text .. K.CHAIN_INDENT .. table.concat(rest, sep)
      break
    end
    local parts = { title(c) }
    if c.reqLevel > plevel then parts[#parts + 1] = Color(D.meta, L["requires level "] .. c.reqLevel) end
    local xp = Geo.XPText(ns.DBXP(c.id, plevel), true)
    if xp then parts[#parts + 1] = xp end
    text = text .. K.CHAIN_INDENT .. StateIcons(c.id) .. table.concat(parts, sep)
  end
  return text
end

-- list: { { id, title, level } }; returns the b1 / b2 buttons of a category bar.
function Geo.CustomBulkButtons(list)
  local locked = Geo.computing and true or nil
  return { text = L["Add all"], disabled = locked, fn = function() if not Geo.ListLocked() then Geo.CustomAddList(list) end end,
      tip = { L["Add every quest of this category to the Roadbook list"], L[K.CUSTOM_TIP] } },
    { text = L["Remove all"], disabled = locked, fn = function() if not Geo.ListLocked() then Geo.CustomRemoveList(list) end end,
      tip = { L["Remove every quest of this category from the Roadbook list"], L[K.CUSTOM_TIP] } }
end

---------------------------------------------------------------------------
-- Search (accent and case insensitive, every word must be present)
---------------------------------------------------------------------------
local ACCENTS = {
  ["à"] = "a", ["â"] = "a", ["ä"] = "a", ["á"] = "a", ["À"] = "a", ["Â"] = "a", ["Ä"] = "a",
  ["ç"] = "c", ["Ç"] = "c",
  ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e", ["É"] = "e", ["È"] = "e", ["Ê"] = "e", ["Ë"] = "e",
  ["î"] = "i", ["ï"] = "i", ["í"] = "i", ["Î"] = "i", ["Ï"] = "i",
  ["ô"] = "o", ["ö"] = "o", ["ó"] = "o", ["Ô"] = "o", ["Ö"] = "o",
  ["ù"] = "u", ["û"] = "u", ["ü"] = "u", ["ú"] = "u", ["Ù"] = "u", ["Û"] = "u", ["Ü"] = "u",
  ["œ"] = "oe", ["Œ"] = "oe", ["’"] = "'",
}

local function Normalize(s)
  s = tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:gsub("[\1-\127\194-\244][\128-\191]*", function(c) return ACCENTS[c] or c end)
  return s:lower()
end

local function ParseQuery(text)
  local words = {}
  for w in Normalize(text):gmatch("%S+") do words[#words + 1] = w end
  return words
end

local function MatchWords(hay, words)
  for _, w in ipairs(words) do
    if not hay:find(w, 1, true) then return false end
  end
  return true
end

State.todoQuery, State.availQuery, State.nearQuery, State.xpQuery = {}, {}, {}, {}

local function QuestHaystack(q)
  local parts = { q.title, q.zone, q.mapZone, q.instanceName, q.tag, q._turnIn, q.objectivesText, q._chain }
  for _, o in ipairs(q.objectives or {}) do parts[#parts + 1] = o.text end
  local list = {}
  for _, v in pairs(parts) do if v then list[#list + 1] = tostring(v) end end
  return Normalize(table.concat(list, " "))
end

local function EntryHaystack(e)
  if not e._hay then
    e._hay = Normalize(table.concat({ e.name or "", e.area or "", e.dungeon or "", e.starter or "", e.starterZone or "" }, " "))
  end
  return e._hay
end

-- Search box (game template if available), with a short delay before filtering.
local function CreateSearchBox(parent, width, onChange)
  local ok, eb = pcall(CreateFrame, "EditBox", nil, parent, "SearchBoxTemplate")
  local custom = false
  if not ok or not eb then
    eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    custom = true
  end
  eb:SetSize(width, 20)
  eb:SetAutoFocus(false)
  if custom then
    eb.hint = eb:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    eb.hint:SetPoint("LEFT", 4, 0)
    eb.hint:SetText(L["Search…"])
  end
  local timer
  eb:HookScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    if eb.hint then eb.hint:SetShown(text == "") end
    if timer then timer:Cancel() end
    if C_Timer.NewTimer then
      timer = C_Timer.NewTimer(0.25, function() onChange(text) end)
    else
      onChange(text)
    end
  end)
  eb:HookScript("OnEnterPressed", function(self) self:ClearFocus() end)
  eb:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return eb
end

---------------------------------------------------------------------------
-- Frame style shared by every window of the addon (the Objective button's look): thin tooltip
-- border in gold, very dark brown background. Boxes inside a window: lighter, dimmer border.
---------------------------------------------------------------------------
K.FRAME_BG = { 0.09, 0.07, 0.04, 0.94 }
K.FRAME_BORDER = { 1, 0.82, 0, 0.85 }
K.FRAME_BORDER_HOVER = { 1, 0.95, 0.6, 1 }
K.BOX_BG = { 0, 0, 0, 0.35 }
K.BOX_BORDER = { 1, 0.82, 0, 0.45 }

-- frame: created with the BackdropTemplate (when the client has it). box: true for a box inside a window.
function Geo.FrameStyle(frame, box)
  local bg, border = box and K.BOX_BG or K.FRAME_BG, box and K.BOX_BORDER or K.FRAME_BORDER
  if frame.SetBackdrop then
    local inset = box and 3 or 4
    frame:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = box and 12 or 14,
      insets = { left = inset, right = inset, top = inset, bottom = inset },
    })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
  else
    local t = frame:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
  end
end

-- Movable window of the addon (main window, settings): styled frame, golden title, golden rule
-- under the title bar, close button, closed with Escape.
function Geo.CreateWindow(name, title, w, h)
  local f = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  Geo.FrameStyle(f)
  f:SetSize(w, h)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOP", 0, -8)
  f.title:SetText(title)
  f.rule = f:CreateTexture(nil, "ARTWORK")
  f.rule:SetColorTexture(1, 0.82, 0, 0.35)
  f.rule:SetHeight(1)
  f.rule:SetPoint("TOPLEFT", 6, -24)
  f.rule:SetPoint("TOPRIGHT", -6, -24)
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetSize(24, 24)
  close:SetPoint("TOPRIGHT", -2, -1)
  close:SetScript("OnClick", function() f:Hide() end)
  f.CloseButton = close
  tinsert(UISpecialFrames, name)
  f:Hide()
  return f
end

-- Shared with the next files.
ns.ActivePin, ns.CONTENT_WIDTH, ns.ClearPin, ns.CreateScrollPanel, ns.CreateSearchBox, ns.EntryHaystack = ActivePin, CONTENT_WIDTH, ClearPin, CreateScrollPanel, CreateSearchBox, EntryHaystack
ns.ICON, ns.IsPinned, ns.IsWatched, ns.MatchWords, ns.Normalize, ns.OnWaypointChanged = ICON, IsPinned, IsWatched, MatchWords, Normalize, OnWaypointChanged
ns.ParseQuery, ns.PassStates, ns.PinIcon, ns.PinPoint, ns.Plural = ParseQuery, PassStates, PinIcon, PinPoint, Plural
ns.QuestHaystack, ns.RenderExport, ns.RenderList, ns.SetWatched = QuestHaystack, RenderExport, RenderList, SetWatched
ns.ShowMessage, ns.StateIcons, ns.UpdateScrollBar, ns.WatchOnly, ns.IsWatched, ns.SetWatched, ns.expandedCategories, ns.journalStates = ShowMessage, StateIcons, UpdateScrollBar, WatchOnly, IsWatched, SetWatched, expandedCategories, journalStates
ns.nearStates, ns.OpenQuestDetails, ns.panels, ns.tabButtons = nearStates, OpenQuestDetails, panels, tabButtons
