-- Forever Quest Planner: Quest log, Available and Nearby tabs.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Color, CurrentMapSet, EntryHaystack, Geo, GeoReady, GetItemInfoCompat = ns.Color, ns.CurrentMapSet, ns.EntryHaystack, ns.Geo, ns.GeoReady, ns.GetItemInfoCompat
local IsWatched, K, L, MatchWords, MoneyText = ns.IsWatched, ns.K, ns.L, ns.MatchWords, ns.MoneyText
local NearItems, Normalize, PassStates, PlayerPos = ns.NearItems, ns.Normalize, ns.PassStates, ns.PlayerPos
local Plural, PointText, QDB, QGet, QuestHaystack, Refresh = ns.Plural, ns.PointText, ns.QDB, ns.QGet, ns.QuestHaystack, ns.Refresh
local RemainingObjectives, RenderList, Settings = ns.RemainingObjectives, ns.RenderList, ns.Settings
local ShowMessage, StartPoints, StartScan, State, StateIcons = ns.ShowMessage, ns.StartPoints, ns.StartScan, ns.State, ns.StateIcons
local journalStates, nearStates, panels, scan = ns.journalStates, ns.nearStates, ns.panels, ns.scan
local PointInMaps = ns.PointInMaps

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
    if watched > 0 then text = text .. " - " .. watched .. L[" tracked"] end
    if toDrop > 0 then text = text .. " - " .. toDrop .. L[" to abandon"] end
    if searching then text = text .. L["  (filtered)"] end
    local list = {}
    for _, q in ipairs(quests) do list[#list + 1] = { id = q.id, title = q.title, level = q.level } end
    local addAll, removeAll = Geo.CustomBulkButtons(list)
    items[#items + 1] = { header = true, kind = kind, key = key, label = text, b1 = addAll, b2 = removeAll }
    for _, q in ipairs(quests) do
      local body = "  " .. StateIcons(q.id) .. (q._abandon and Color("ff8040", L["[To abandon] "]) or "") .. QuestLine(q)
      if q._abandon then body = body .. Geo.DescLine(Color("ff8040", L["Reason: "] .. q._abandon)) end
      body = body .. detail(q) .. QuestFigures(q)
      if q._chain then body = body .. Geo.DescLine(Color(K.DESC.chain, q._chain)) end
      items[#items + 1] = {
        text = body,
        questID = q.id,
        tint = q._abandon and { 0.9, 0.5, 0.25 } or nil,
        stripe = q._abandon and { 1, 0.5, 0.15 } or nil,
        b1 = Geo.CustomButton(q.id, q.title, q.level),
        b2 = Geo.MapButton(function() return Geo.ObjectivePoint(q) end, q.title, q.id),
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
    items[#items + 1] = { text = Color("ff8040", Plural(#a.abandon, L["quest"]) .. L[" recommended for abandoning: orange lines marked [To abandon], in their category."]),
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

  for _, g in ipairs(a.dungeons) do
    category("dungeon", "dungeon:" .. g.name, Geo.WithLevel(L["Dungeon: "] .. g.name, g.name), g.quests, normalDetail)
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

local function CurrentZoneNames()
  local names = {}
  local function add(n) if n and n ~= "" then names[n] = true end end
  add(GetRealZoneText())
  add(GetZoneText())
  if C_Map and C_Map.GetBestMapForUnit then
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    if info then
      add(info.name)
      local parent = info.parentMapID and C_Map.GetMapInfo(info.parentMapID)
      if parent and Enum and Enum.UIMapType and parent.mapType == Enum.UIMapType.Zone then add(parent.name) end
    end
  end
  return names
end


---------------------------------------------------------------------------
-- Quest rewards: line of the "Available" tab (item names, game tooltip on hover)
---------------------------------------------------------------------------
-- Reward item: name from QuestieDB; the game's link (quality color) when already in its cache.
-- No request to the server: the tooltip loads the item on hover.
Geo.itemCache = {}
function Geo.ItemInGameCache(id)
  if C_Item and C_Item.IsItemDataCachedByID then
    local ok, v = pcall(C_Item.IsItemDataCachedByID, id)
    return ok and v and true or false
  end
  return false
end

function Geo.RewardItem(itemId)
  local it = Geo.itemCache[itemId]
  if not it then
    it = { id = itemId, name = QGet(QDB.Item, itemId, "name") or ("#" .. itemId) }
    Geo.itemCache[itemId] = it
  end
  if not it.link and Geo.ItemInGameCache(itemId) then -- e.g. loaded by a tooltip since
    local name, link = GetItemInfoCompat(itemId)
    if name then it.name, it.link = name, link end
  end
  return it
end

-- Rewards of a quest: item ids and reputations.
Geo.rewardCache = {}
function Geo.QuestRewards(id)
  local r = Geo.rewardCache[id]
  if r then return r end
  r = { items = Geo.RewardIndex()[id] or {}, rep = {} }
  local rep = QGet(QDB.Quest, id, "reputationReward")
  if type(rep) == "table" then
    for _, p in ipairs(rep) do
      if type(p) == "table" and p[1] and (p[2] or 0) > 0 then r.rep[#r.rep + 1] = { faction = p[1], value = p[2] } end
    end
  end
  Geo.rewardCache[id] = r
  return r
end

function Geo.FactionName(fid)
  if GetFactionInfoByID then
    local ok, name = pcall(GetFactionInfoByID, fid)
    if ok and name then return name end
  end
  if C_Reputation and C_Reputation.GetFactionDataByID then -- newer API (Forever factions)
    local ok, data = pcall(C_Reputation.GetFactionDataByID, fid)
    if ok and type(data) == "table" and data.name and data.name ~= "" then return data.name end
  end
  return L["Faction "] .. fid
end

-- "Possible rewards: [Item] · [Item] · Reputation: Orgrimmar +250"
function Geo.RewardLine(id)
  if not Geo.rewards then -- index still being built in the background: the list is refreshed when ready
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

local function RenderAvailable()
  local panel = panels.avail
  if scan.error then
    ShowMessage(panel, "avail", Color("ff6060", scan.error))
    return
  end
  if scan.dirty or not scan.entries then
    if not scan.running then StartScan() end
    if scan.running or scan.dirty then
      ShowMessage(panel, "avail", L["Scanning the QuestieDB database…"])
      return
    end
  end

  local searching = #State.availQuery > 0
  local zoneNames = State.availFilter == "zone" and CurrentZoneNames() or nil
  local hereMaps = State.availFilter == "zone" and CurrentMapSet() or {}
  local function StartsHere(e)
    if not GeoReady() then return false end
    for _, pt in ipairs(StartPoints(e.id)) do
      if PointInMaps(pt, hereMaps) then return true end
    end
    return false
  end
  local groups, byKey = {}, {}
  local showLow = Settings().showLowLevel
  -- The groups apart from the places: id (never a place's name) -> title and place in the list.
  local special = { ["#class"] = { name = L["Class"], rank = 1 }, ["#prof"] = { name = L["Professions"], rank = 2 } }
  local function Place(e) return e.dungeon or e.area or e.starterZone or L["Other"] end
  local function ClassOrPlace(e)
    return (e.isClass and "#class") or (e.isProf and "#prof") or Place(e)
  end
  for _, e in ipairs(scan.entries) do
    local keep, key, kind
    local customOnly = State.availFilter == "custom"
    if not customOnly and ((e.lowLevel and not showLow) or e.future) then
      -- low-level quest hidden ("Low-level quests" option), or not at the required level yet
    else
    if State.availFilter == "zone" then
      keep = StartsHere(e) or (e.area and zoneNames[e.area]) or (e.starterZone and zoneNames[e.starterZone])
        or (e.dungeon and zoneNames[e.dungeon])
      key = Place(e)
    elseif State.availFilter == "dungeon" then
      keep = e.dungeon ~= nil and not e.pvp -- battlegrounds have their own filter
      key = e.dungeon
    elseif State.availFilter == "pvp" then
      keep = e.pvp
      key = Place(e)
    elseif customOnly then
      keep = Geo.InCustom(e.id)
      key = ClassOrPlace(e)
    elseif State.availFilter == "class" then
      keep = e.isClass or e.isProf
      key = e.isClass and "#class" or "#prof"
    else
      keep = true
      -- "All": class and profession quests in their own groups (some are not tied to a place,
      -- e.g. the Forever "Crafting" writs), the others by zone.
      key = ClassOrPlace(e)
    end
    if keep and searching then keep = MatchWords(EntryHaystack(e), State.availQuery) end
    end
    if keep then
      kind = e.dungeon and key == e.dungeon and "dungeon" or (special[key] and "class") or "zone"
      local g = byKey[key]
      if not g then
        local s = special[key]
        g = { name = s and s.name or key, rank = s and s.rank, kind = kind, list = {} }
        byKey[key] = g
        groups[#groups + 1] = g
      end
      g.list[#g.list + 1] = e
      if e.pvp then g.pvp, g.kind = true, "pvp" end
    end
  end

  -- Order of the categories: class, professions, dungeons, standard zones, PvP; then alphabetical.
  local function Rank(g)
    if g.rank then return g.rank end -- class, professions
    if g.pvp then return 5 end
    if g.kind == "dungeon" then return 3 end
    return 4
  end
  table.sort(groups, function(a, b)
    local ra, rb = Rank(a), Rank(b)
    if ra ~= rb then return ra < rb end
    return Normalize(a.name) < Normalize(b.name)
  end)

  local total = 0
  for _, g in ipairs(groups) do total = total + #g.list end
  local head = Plural(total, L["quest"]) .. L[" available"] .. (Settings().showLowLevel and L[", low level included"] or L[" (low level excluded)"]) .. L[", according to QuestieDB. Quests specific to Forever may be missing."]
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
        Geo.QuestTitle(e.name, { id = e.id, level = e.level, isClass = e.isClass, isProf = e.isProf, dungeon = e.dungeon, doubts = e.doubts }) ..
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
        b2 = Geo.MapButton(function() return Geo.GiverPoint(id, PlayerPos()) end, e.name, id) }
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

  local found, zoneFound = NearItems(State.nearRadius)
  if not found then
    ShowMessage(panel, "near", Color("ff6060", zoneFound))
    return
  end
  local where
  if State.nearRadius == "zone" then
    local _, zoneName = CurrentMapSet()
    where = L["In the whole current zone"] .. (zoneName and (" (" .. zoneName .. ")") or "")
  else
    where = L["Within "] .. State.nearRadius .. L[" m"]
  end
  local info = where .. L[" - updated automatically every 3 s."]
  if scan.running then info = info .. "\n" .. Color("ff8040", L["Scanning available quests: \"Available quests\" will fill in."]) end
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
    local figures = Geo.DescLine(take and Geo.XPText(it.xp, true) or nil, Color(D.meta, string.format("%.0f m", it.d)),
      (take and it.lowLevel) and Color(D.meta, L["low level"]) or nil)
    local who = (take and L["Given by: "] or L["Turn in to: "]) .. (it.giver or "?")
    local text = "  " .. StateIcons(it.id) ..
      Geo.QuestTitle(it.label, it.id and { id = it.id, level = it.level } or nil) ..
      Geo.DescLine(Color(D.action, who .. K.DESC_SEP .. PointText(it.p))) .. figures .. Geo.ChainTextLine(it.id)
    if it.rep then text = text .. Geo.DescLine(Color(D.bad, it.rep)) end
    local label = take and L["pick up the quest"] or L["turn in the quest"]
    return { text = text, questID = not take and it.id or nil, linkQuest = it.id,
      b1 = Geo.CustomButton(it.id, it.label, it.level),
      b2 = Geo.MapButton(function() return it.p, label end, it.label, it.id) }
  end

  -- Quest in progress: one row per quest, one line per step within reach; the map pin goes to the nearest step.
  local function questRow(g)
    local D = K.DESC
    local text = "  " .. StateIcons(g.id) .. Geo.QuestTitle(g.label, g.id and { id = g.id, level = g.level } or nil)
    for _, it in ipairs(g.steps) do
      text = text .. Geo.DescLine(Color(D.action, L["Objective: "] .. (it.extra or "?") .. K.DESC_SEP .. PointText(it.p)),
        Color(D.meta, string.format("%.0f m", it.d)))
    end
    text = text .. Geo.ChainTextLine(g.id)
    local first = g.steps[1]
    return { text = text, questID = g.id, linkQuest = g.id,
      b1 = Geo.CustomButton(g.id, g.label, g.level),
      b2 = Geo.MapButton(function() return first.p, first.extra end, g.label, g.id) }
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
