-- Forever Quest Planner: Quest log, Available and Nearby tabs.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Color, CurrentMapSet, EntryHaystack, Geo, GeoReady = ns.Color, ns.CurrentMapSet, ns.EntryHaystack, ns.Geo, ns.GeoReady
local IsWatched, K, L, MatchWords, MoneyText, NearItems = ns.IsWatched, ns.K, ns.L, ns.MatchWords, ns.MoneyText, ns.NearItems
local Normalize, PassStates, PlayerPos, Plural, PointText = ns.Normalize, ns.PassStates, ns.PlayerPos, ns.Plural, ns.PointText
local QuestHaystack, RemainingObjectives, RenderList, Settings = ns.QuestHaystack, ns.RemainingObjectives, ns.RenderList, ns.Settings
local ShowMessage, StartScan, State, StateIcons, journalStates = ns.ShowMessage, ns.StartScan, ns.State, ns.StateIcons, ns.journalStates
local nearStates, panels, scan = ns.nearStates, ns.panels, ns.scan

---------------------------------------------------------------------------
-- Quest log tab (to do / to abandon)
---------------------------------------------------------------------------
local function AbandonButton(q)
  return { tip = { L["Abandon"], L["Abandons the quest (asks for confirmation)."] }, fn = function() StaticPopup_Show("FQE_ABANDON", q.title or "?", nil, q.id) end }
end

local function QuestLine(q)
  return Geo.QuestTitle(q.title, { id = q.id, level = q.level, tag = q.tag or "", isClass = q._isClass, isProf = q._isProf })
end

-- Figures of a quest of the log: XP, money, group, interesting reward.
local function QuestFigures(q)
  return Geo.DescLine(Geo.XPText(q.xp),
    (q.money and q.money > 0) and MoneyText(q.money) or nil,
    (q.suggestedGroup and q.suggestedGroup > 1) and Color(K.DESC.warn, L["group "] .. q.suggestedGroup) or nil,
    q._itemReason and Color(K.DESC.good, q._itemReason) or nil)
end

local function RenderTodo(a)
  local searching = #State.todoQuery > 0 or next(journalStates) ~= nil
  local items = {}
  if panels.groups.questCount then
    local count = a.count or 0
    local color = count >= K.MAX_QUESTS and "ff4040" or count >= K.MAX_QUESTS - 5 and "ff8040" or "ffffff"
    panels.groups.questCount:SetText(L["Quests: "] .. Color(color, count .. "/" .. K.MAX_QUESTS))
  end

  local function category(kind, key, label, quests, detail)
    if searching then
      local kept = {}
      for _, q in ipairs(quests) do
        if (#State.todoQuery == 0 or MatchWords(QuestHaystack(q), State.todoQuery)) and PassStates(q.id, journalStates, q._abandon) then
          kept[#kept + 1] = q
        end
      end
      if #kept == 0 then return end
      quests = kept
    end
    local watched, toDrop = 0, 0
    for _, q in ipairs(quests) do
      if IsWatched(q.id) then watched = watched + 1 end
      if q._abandon then toDrop = toDrop + 1 end
    end
    local text = label .. " - " .. Plural(#quests, L["quest"])
    if watched > 0 then text = text .. " - " .. string.format(L["%d tracked"], watched) end
    if toDrop > 0 then text = text .. " - " .. string.format(L["%d to abandon"], toDrop) end
    if searching then text = text .. L["  (filtered)"] end
    local list = {}
    for _, q in ipairs(quests) do list[#list + 1] = { id = q.id, title = q.title, level = q.level } end
    local addAll, removeAll = Geo.CustomBulkButtons(list)
    items[#items + 1] = { header = true, kind = kind, key = key, label = text, b1 = addAll, b2 = removeAll }
    for _, q in ipairs(quests) do
      local body = "  " .. StateIcons(q.id) .. (q._abandon and Color(K.DESC.abandon, L["[To abandon] "]) or "") .. QuestLine(q)
      if q._abandon then body = body .. Geo.DescLine(Color(K.DESC.abandon, L["Reason: "] .. q._abandon)) end
      body = body .. detail(q) .. QuestFigures(q)
      if q._chain then body = body .. Geo.DescLine(Color(K.DESC.chain, q._chain)) end
      items[#items + 1] = {
        text = body,
        questID = q.id,
        tint = q._abandon and { 0.9, 0.5, 0.25 } or nil,
        stripe = q._abandon and { 1, 0.5, 0.15 } or nil,
        b1 = Geo.CustomButton(q.id, q.title, q.level),
        trash = AbandonButton(q), -- trash icon at the left of the quest
      }
    end
  end

  -- Line under the title: what is left to do (objectives), and where for a quest outside a zone group.
  local function objectivesText(q)
    local rest = RemainingObjectives(q)
    return rest ~= "" and Color(K.DESC.action, rest) or nil
  end
  local function normalDetail(q)
    return Geo.DescLine(objectivesText(q))
  end
  local function placeDetail(q)
    return Geo.DescLine(objectivesText(q), Color(K.DESC.meta, q.instanceName or q.mapZone or q.zone or "?"))
  end

  if #a.abandon > 0 and not searching then
    items[#items + 1] = { text = Color(K.DESC.abandon, string.format(L["%s recommended for abandoning: orange lines marked [To abandon], in their category."], Plural(#a.abandon, L["quest"]))),
      tint = { 0.9, 0.5, 0.25 }, stripe = { 1, 0.5, 0.15 } }
  end

  if #a.turnIn > 0 then
    category("turnin", "turnin", L["To turn in"], a.turnIn, function(q)
      local need = Geo.SkillNeed(q.id, q) -- profession level not reached yet: not to turn in yet
      return Geo.DescLine(Color(K.DESC.action, L["Turn in to: "] .. (q._turnIn or q.zone or "?")),
        need and Color(K.DESC.bad, Geo.SkillNeedText(need)) or nil)
    end)
  end

  local singles = {}
  for _, g in ipairs(a.groups) do
    if #g.quests >= 2 then
      category("zone", "zone:" .. g.name, Geo.WithLevel(g.name, g.name), g.quests, normalDetail)
    else
      singles[#singles + 1] = g.quests[1]
    end
  end

  for _, g in ipairs(a.instances) do
    category(g.kind, g.kind .. ":" .. g.name, Geo.WithLevel(K.KIND_TITLE[g.kind] .. g.name, g.name), g.quests, normalDetail)
  end

  if #singles > 0 then
    category("singles", "singles", L["Doable single quests"], singles, placeDetail)
  end

  if #a.later > 0 then
    category("later", "later", L["Later - level too high"], a.later, placeDetail)
  end

  local hasQuests = false
  for _, it in ipairs(items) do if it.header then hasQuests = true break end end
  if not hasQuests then
    items[#items + 1] = { text = searching and L["No quest matches the search or filters."] or L["Your quest log is empty."] }
  end
  RenderList(panels.groups, "groups", items, searching)
end

---------------------------------------------------------------------------
-- Quest rewards: line of the "Available" tab (item names, game tooltip on hover)
---------------------------------------------------------------------------
-- "Possible rewards: [Item] · [Item] · Reputation: Orgrimmar +250"
function Geo.RewardLine(id)
  if not Geo.RewardsReady() then -- index still being built in the background: the list is refreshed when ready
    Geo.BuildRewardIndexAsync()
    return nil
  end
  local r = Geo.QuestRewards(id)
  local parts = {}
  for _, itemId in ipairs(r.items) do
    local it = Geo.RewardItem(itemId)
    parts[#parts + 1] = it.link or ("|cffffffff|Hitem:" .. it.id .. "|h[" .. it.name .. "]|h|r")
  end
  for _, p in ipairs(r.rep) do
    parts[#parts + 1] = Color("aaaaaa", L["Reputation: "]) .. Geo.FactionName(p.faction) .. " +" .. p.value
  end
  if #parts == 0 then return nil end
  return Color(K.DESC.action, L["Possible rewards: "]) .. table.concat(parts, Color(K.DESC.meta, K.DESC_SEP))
end

-- What the running scan is doing: text, then the loading of the quest types once it started.
local function ScanText(text)
  local loaded, total = ns.TagProgress()
  if loaded >= total then return text end
  return string.format(L["Loading quest types: %d / %d"], loaded, total)
end

local function RenderAvailable()
  local panel = panels.avail
  if scan.error then
    ShowMessage(panel, "avail", Color(K.DESC.bad, scan.error))
    return
  end
  if scan.dirty or not scan.entries then
    if not scan.running then StartScan() end
    if scan.running or scan.dirty then
      ShowMessage(panel, "avail", ScanText(L["Scanning the QuestieDB database…"]))
      return
    end
  end

  local searching = #State.availQuery > 0
  local groups, total = Geo.AvailableGroups(State.availFilter, searching and function(e)
    return MatchWords(EntryHaystack(e), State.availQuery)
  end or nil, Settings().showLowLevel)
  local head = string.format(Settings().showLowLevel and L["%s available, low level included, according to QuestieDB. Quests specific to Forever may be missing."]
    or L["%s available (low level excluded), according to QuestieDB. Quests specific to Forever may be missing."], Plural(total, L["quest"]))
  local items = { { text = Color("aaaaaa", head) } }
  for _, g in ipairs(groups) do
    table.sort(g.list, function(a, b) return (a.level or 0) < (b.level or 0) end)
    local list = {}
    for _, e in ipairs(g.list) do list[#list + 1] = { id = e.id, title = e.name, level = e.level } end
    local addAll, removeAll = Geo.CustomBulkButtons(list)
    items[#items + 1] = { header = true, kind = g.kind, key = g.name, label = (g.kind == "class" and g.name or Geo.WithLevel(g.name, g.name)) .. " - " .. Plural(#g.list, L["quest"]),
      b1 = addAll, b2 = removeAll }
    for _, e in ipairs(g.list) do
      local D = K.DESC
      local text = "  " .. StateIcons(e.id) ..
        Geo.QuestTitle(e.name, { id = e.id, level = e.level, isClass = e.isClass, isProf = e.isProf, kind = e.kind, instance = e.instance, doubts = e.doubts }) ..
        Geo.DescLine(e.starter and Color(D.action, L["Given by: "] .. e.starter) or nil) ..
        Geo.DescLine(Geo.XPText(e.xp, true), Color(D.meta, L["requires level "] .. e.reqLevel),
          e.lowLevel and Color(D.meta, L["low level"]) or nil, e.repeatable and Color(D.meta, L["repeatable"]) or nil,
          e.opensChain and Color(D.chain, L["opens a chain"]) or nil)
      text = text .. Geo.DoubtLine(e.doubts)
      if e.repMissing then text = text .. Geo.DescLine(Color(D.bad, e.repMissing)) end
      if e.missing then
        text = text .. Geo.DescLine(Color(D.bad, L["Missing prerequisites: "] .. table.concat(e.missing.texts, ", ")))
      end
      local rewards = Geo.RewardLine(e.id)
      if rewards then text = text .. Geo.DescLine(rewards) end
      local chainText, chainLinks = Geo.ChainLines(e.id)
      text = text .. chainText
      local id = e.id
      items[#items + 1] = { text = text, links = rewards ~= nil or chainLinks, linkQuest = id,
        b1 = Geo.CustomButton(id, e.name, e.level),
        place = function() return Geo.GiverPoint(id, PlayerPos()) end, placeTitle = e.name }
    end
  end
  if total == 0 then items[#items + 1] = { text = searching and L["No quest matches the search."] or L["No quest available for this filter."] } end
  RenderList(panel, "avail", items, searching)
end

local function RenderNear()
  local panel = panels.near
  if not GeoReady() then
    ShowMessage(panel, "near", L["Unable to convert QuestieDB positions to this client's map."])
    return
  end
  if (scan.dirty or not scan.entries) and not scan.running then StartScan() end

  local found, err = NearItems(State.nearRadius)
  if not found then
    ShowMessage(panel, "near", Color(K.DESC.bad, err))
    return
  end
  local where
  if State.nearRadius == "zone" then
    local _, zoneName = CurrentMapSet()
    where = L["In the whole current zone"] .. (zoneName and (" (" .. zoneName .. ")") or "")
  else
    where = string.format(L["Within %d m"], State.nearRadius)
  end
  local info = where .. L[" - updated automatically every 3 s."]
  if scan.running then info = info .. "\n" .. Color("ff8040", ScanText(L["Scanning available quests: \"Available quests\" will fill in."])) end
  local items = { { text = Color("aaaaaa", info) } }

  local function matches(it)
    if not PassStates(it.id, nearStates) then return false end
    if #State.nearQuery == 0 then return true end
    return MatchWords(Normalize(table.concat({ it.label or "", it.giver or "", it.extra or "", PointText(it.p) }, " ")), State.nearQuery)
  end

  -- Quest to turn in or to pick up.
  local function row(it)
    local D = K.DESC
    local take = it.kind == "take"
    local figures = Geo.DescLine(take and Geo.XPText(it.xp, true) or nil, Color(D.meta, string.format(L["%.0f m"], it.d)),
      (take and it.lowLevel) and Color(D.meta, L["low level"]) or nil)
    local who = (take and L["Given by: "] or L["Turn in to: "]) .. (it.giver or "?")
    local text = "  " .. StateIcons(it.id) ..
      Geo.QuestTitle(it.label, it.id and { id = it.id, level = it.level } or nil) ..
      Geo.DescLine(Color(D.action, who .. K.DESC_SEP .. PointText(it.p))) .. figures .. Geo.ChainTextLine(it.id)
    if it.rep then text = text .. Geo.DescLine(Color(D.bad, it.rep)) end
    local label = take and L["pick up the quest"] or L["turn in the quest"]
    return { text = text, questID = not take and it.id or nil, linkQuest = it.id,
      b1 = Geo.CustomButton(it.id, it.label, it.level),
      place = take and function() return it.p, label end or nil, placeTitle = it.label }
  end

  -- Quest in progress: one row per quest, one line per step within reach, the nearest first.
  local function questRow(g)
    local D = K.DESC
    local text = "  " .. StateIcons(g.id) .. Geo.QuestTitle(g.label, g.id and { id = g.id, level = g.level } or nil)
    for _, it in ipairs(g.steps) do
      text = text .. Geo.DescLine(Color(D.action, L["Objective: "] .. (it.extra or "?") .. K.DESC_SEP .. PointText(it.p)),
        Color(D.meta, string.format(L["%.0f m"], it.d)))
    end
    text = text .. Geo.ChainTextLine(g.id)
    return { text = text, questID = g.id, linkQuest = g.id,
      b1 = Geo.CustomButton(g.id, g.label, g.level) }
  end

  local sections = {
    { kind = "turnin", label = L["To turn in"], unit = L["quest"] },
    { kind = "step", label = L["Quests in progress"], unit = L["quest"] },
    { kind = "take", label = L["Available quests"], unit = L["quest"] },
  }
  for _, sec in ipairs(sections) do
    local list = {}
    for _, it in ipairs(found) do
      if it.kind == sec.kind and matches(it) then list[#list + 1] = it end
    end
    if sec.kind == "step" then
      -- Group the steps by quest (list is sorted by distance: the first step of a quest is the nearest).
      local groups, byId = {}, {}
      for _, it in ipairs(list) do
        local g = byId[it.id]
        if not g then
          g = { id = it.id, label = it.label, level = it.level, steps = {} }
          byId[it.id] = g
          groups[#groups + 1] = g
        end
        g.steps[#g.steps + 1] = it
      end
      list = groups
    end
    if #list > 0 then
      local quests, seen = {}, {}
      for _, it in ipairs(list) do
        if it.id and not seen[it.id] then
          seen[it.id] = true
          quests[#quests + 1] = { id = it.id, title = it.label, level = it.level }
        end
      end
      local addAll, removeAll = Geo.CustomBulkButtons(quests)
      items[#items + 1] = { header = true, kind = sec.kind, key = sec.kind, label = sec.label .. " - " .. Plural(#list, sec.unit),
        b1 = addAll, b2 = removeAll }
      for _, it in ipairs(list) do items[#items + 1] = it.steps and questRow(it) or row(it) end
    end
  end

  if #found == 0 then
    items[#items + 1] = { text = State.nearRadius == "zone" and L["Nothing to do in the current zone."] or L["Nothing to do within this radius. Try a larger radius or \"Current zone\"."] }
  end
  if #State.nearQuery > 0 or next(nearStates) ~= nil then
    local any = false
    for _, it in ipairs(items) do if it.header then any = true break end end
    if not any then items[#items + 1] = { text = L["No results for this search or these filters."] } end
  end
  RenderList(panel, "near", items, #State.nearQuery > 0 or next(nearStates) ~= nil)
end

-- Shared with the next files.
ns.RenderAvailable, ns.RenderNear, ns.RenderTodo = RenderAvailable, RenderNear, RenderTodo
