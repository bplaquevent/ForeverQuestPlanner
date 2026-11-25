-- Forever Quest Planner: window state, the shared list engine (lines, buttons, categories, panes),
-- scrolling, searches, and the frame style of every window.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Color, Geo, IsInLog, K, L, QDB, QGet, Refresh, State = ns.Color, ns.Geo, ns.IsInLog, ns.K, ns.L, ns.QDB, ns.QGet, ns.Refresh, ns.State
local Normalize, OpenQuestDetails = ns.Normalize, ns.OpenQuestDetails

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

-- Tooltip of a widget: a title, then a grey text (optional). anchor: ANCHOR_TOP by default.
function Geo.ShowTip(owner, title, text, anchor)
  GameTooltip:SetOwner(owner, anchor or "ANCHOR_TOP")
  GameTooltip:AddLine(title)
  if text then GameTooltip:AddLine(text, 0.8, 0.8, 0.8, true) end
  GameTooltip:Show()
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

-- Click on a quest's line: a quest of the log opens in the game's quest log; another one is shown at
-- its place (it.place() -> point, label; it.placeTitle), with the map pin. Shift: its link in the chat.
-- A click on a link of the line (a reward, a follow-up) does nothing more.
function Geo.QuestRowClick(row, it)
  local qid = it.questID or it.linkQuest
  if IsShiftKeyDown and IsShiftKeyDown() then
    Geo.LinkQuestInChat(qid)
  elseif row.overLink then
    return
  elseif IsInLog(qid) then
    OpenQuestDetails(qid)
  elseif it.place then
    Geo.ShowQuestPlace(it.place, it.placeTitle, qid)
  end
end

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
      self.overLink = true -- a click on the link is not a click on the line
      GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
      pcall(GameTooltip.SetHyperlink, GameTooltip, link)
      GameTooltip:Show()
    end)
    r:SetScript("OnHyperlinkLeave", function(self)
      self.overLink = nil
      GameTooltip:Hide()
    end)
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
    b:SetScript("OnEnter", tip and function(self) Geo.ShowTip(self, tip[1], tip[2]) end or nil)
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
        Geo.ShowTip(self, trash.tip[1], trash.tip[2])
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
          local clickable = IsInLog(qid) or it.place ~= nil
          r:EnableMouse(true)
          r.overLink = nil
          r:SetScript("OnMouseUp", function(self) Geo.QuestRowClick(self, it) end)
          r:SetScript("OnEnter", clickable and function(self) self.hl:Show() end or nil)
          r:SetScript("OnLeave", clickable and function(self) self.hl:Hide() end or nil)
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
ns.CONTENT_WIDTH, ns.CreateScrollPanel, ns.CreateSearchBox, ns.EntryHaystack, ns.MatchWords, ns.ParseQuery = CONTENT_WIDTH, CreateScrollPanel, CreateSearchBox, EntryHaystack, MatchWords, ParseQuery
ns.Plural, ns.QuestHaystack, ns.RenderList, ns.ShowMessage, ns.UpdateScrollBar, ns.expandedCategories = Plural, QuestHaystack, RenderList, ShowMessage, UpdateScrollBar, expandedCategories
ns.panels, ns.tabButtons = panels, tabButtons
