-- Forever Quest Planner: the quest log as text, to export.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local CoinText = ns.CoinText
local ChainInfo, ChainText, L, LogRecord, Snapshot = ns.ChainInfo, ns.ChainText, ns.L, ns.LogRecord, ns.Snapshot
local TrivialRange, TurnInText, UpdateScrollBar, panels = ns.TrivialRange, ns.TurnInText, ns.UpdateScrollBar, ns.panels
local K, LogKind = ns.K, ns.LogKind

---------------------------------------------------------------------------
-- Text to export (Ctrl+C)
---------------------------------------------------------------------------
local FREQ = { [1] = L["daily"], [2] = L["weekly"] }

local function BuildText()
  Snapshot()
  local e = LogRecord()
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
    if q.money and q.money > 0 then tags[#tags + 1] = CoinText(q.money) end
    local kind, place = LogKind(q)
    if kind and place then tags[#tags + 1] = K.KIND_NOTE[kind] .. place
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

-- The text may be written again at any time (game events): selected again (writing it drops the
-- selection), but the keyboard is not taken (FocusExport).
local function RenderExport()
  local eb = panels.export.scroll.child
  local text = BuildText()
  eb.fullText = text
  eb:SetText(text)
  eb:SetCursorPosition(0)
  eb:HighlightText()
  UpdateScrollBar(panels.export.scroll)
end

-- The tab just opened by the player: its text selected, ready for Ctrl+C.
local function FocusExport()
  local eb = panels.export.scroll.child
  eb:SetFocus()
  eb:HighlightText()
end

-- Shared with the next files.
ns.FocusExport, ns.RenderExport = FocusExport, RenderExport
