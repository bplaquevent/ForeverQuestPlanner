-- Forever Quest Planner: Quest log, Available and Nearby tabs.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Color, CurrentMapSet, EntryHaystack, Geo, GeoReady, GetItemInfoCompat = ns.Color, ns.CurrentMapSet, ns.EntryHaystack, ns.Geo, ns.GeoReady, ns.GetItemInfoCompat
local IsPinned, IsWatched, K, L, MatchWords, MoneyText = ns.IsPinned, ns.IsWatched, ns.K, ns.L, ns.MatchWords, ns.MoneyText
local NearItems, Nearest, Normalize, PassStates, PinButton, PlayerPos = ns.NearItems, ns.Nearest, ns.Normalize, ns.PassStates, ns.PinButton, ns.PlayerPos
local Plural, PointText, QDB, QGet, QuestHaystack, Refresh = ns.Plural, ns.PointText, ns.QDB, ns.QGet, ns.QuestHaystack, ns.Refresh
local RemainingObjectives, RenderList, SetMapPin, SetWatched, SetWatchedList, Settings = ns.RemainingObjectives, ns.RenderList, ns.SetMapPin, ns.SetWatched, ns.SetWatchedList, ns.Settings
local ShowMessage, StartPoints, StartScan, State, StateIcons, UnpinButton = ns.ShowMessage, ns.StartPoints, ns.StartScan, ns.State, ns.StateIcons, ns.UnpinButton
local journalStates, nearStates, panels, scan = ns.journalStates, ns.nearStates, ns.panels, ns.scan

---------------------------------------------------------------------------
-- Quest log tab (to do / to abandon)
---------------------------------------------------------------------------
local function AbandonButton(q)
  return { text = L["Abandon"], fn = function() StaticPopup_Show("FQE_ABANDON", q.title or "?", nil, q.id) end }
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
    local list = quests
    items[#items + 1] = { header = true, kind = kind, key = key, label = text,
      b1 = { text = L["Track all"], fn = function()
        SetWatchedList(list, true)
        C_Timer.After(0.2, Refresh)
      end },
      b2 = { text = L["Track none"], fn = function()
        SetWatchedList(list, false)
        C_Timer.After(0.2, Refresh)
      end },
    }
    for _, q in ipairs(quests) do
      local body = "  " .. StateIcons(q.id) .. (q._abandon and Color("ff8040", L["[To abandon] "]) or "") .. QuestLine(q)
      if q._abandon then body = body .. Geo.DescLine(Color("ff8040", L["Reason: "] .. q._abandon)) end
      body = body .. detail(q) .. QuestFigures(q)
      if q._chain then body = body .. Geo.DescLine(Color(K.DESC.chain, q._chain)) end
      local watchedQ = IsWatched(q.id)
      local b1
      if q._abandon then
        b1 = { text = L["Keep"], fn = function()
          Settings().keep[q.id] = true
          Refresh()
        end }
      else
        b1 = { text = watchedQ and L["Untrack"] or L["Track"], fn = function()
          SetWatchedList({ q }, not watchedQ)
          C_Timer.After(0.2, Refresh)
        end }
      end
      items[#items + 1] = {
        text = body,
        questID = q.id,
        tint = q._abandon and { 0.9, 0.5, 0.25 } or nil,
        stripe = q._abandon and { 1, 0.5, 0.15 } or nil,
        b1 = b1,
        b2 = IsPinned(q.id) and UnpinButton() or (QDB.ok and { text = L["Pin"], fn = function() SetMapPin(q) end } or nil),
        b3 = AbandonButton(q),
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
    items[#items + 1] = { text = Color("ff8040", Plural(#a.abandon, L["quest"]) .. L[" recommended for abandoning: orange lines marked [To abandon], in their category."]) ..
      (a.kept > 0 and Color("888888", "\n" .. Plural(a.kept, L["quest"]) .. L[" kept despite the recommendation (/fqp reset to clear)."]) or ""),
      tint = { 0.9, 0.5, 0.25 }, stripe = { 1, 0.5, 0.15 } }
  elseif a.kept > 0 and not searching then
    items[#items + 1] = { text = Color("888888", Plural(a.kept, L["quest"]) .. L[" kept despite the abandon recommendation (/fqp reset to clear)."]) }
  end

  if #a.turnIn > 0 then
    category("turnin", "turnin", L["To turn in"], a.turnIn, function(q)
      return Geo.DescLine(Color(K.DESC.action, L["Turn in to: "] .. (q._turnIn or q.zone or "?")))
    end)
  end

  local singles = {}
  for _, g in ipairs(a.groups) do
    if #g.quests >= 2 then
      category("zone", "zone:" .. g.name, g.name, g.quests, normalDetail)
    else
      singles[#singles + 1] = g.quests[1]
    end
  end

  for _, g in ipairs(a.dungeons) do
    category("dungeon", "dungeon:" .. g.name, L["Dungeon: "] .. g.name, g.quests, normalDetail)
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
  return Color("bbbbbb", L["Possible rewards: "]) .. table.concat(parts, Color("888888", " · "))
end

local function RenderAvailable()
  local panel = panels.avail
  if not QDB.ok then
    ShowMessage(panel, "avail", L["QuestieDB is not loaded: this tab needs its database.\nInstall or enable the QuestieDB addon, then restart the game."])
    return
  end
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
      local ui = Geo.areaToUi[pt.area] or (Geo.parent[pt.area] and Geo.areaToUi[Geo.parent[pt.area]])
      if ui and hereMaps[ui] then return true end
    end
    return false
  end
  local groups, byKey = {}, {}
  local showLow = Settings().showLowLevel
  for _, e in ipairs(scan.entries) do
    local keep, key, kind
    if (e.lowLevel and not showLow) or e.future then
      -- low-level quest hidden ("Low-level quests" option), or not at the required level yet
    else
    if State.availFilter == "zone" then
      keep = StartsHere(e) or (e.area and zoneNames[e.area]) or (e.starterZone and zoneNames[e.starterZone])
        or (e.dungeon and zoneNames[e.dungeon])
      key = e.dungeon or e.area or e.starterZone or L["Other"]
    elseif State.availFilter == "dungeon" then
      keep = e.dungeon ~= nil and not e.pvp -- battlegrounds have their own filter
      key = e.dungeon
    elseif State.availFilter == "pvp" then
      keep = e.pvp
      key = e.dungeon or e.area or e.starterZone or L["Other"]
    elseif State.availFilter == "class" then
      keep = e.isClass or e.isProf
      key = e.isClass and L["Class"] or L["Professions"]
    else
      keep = true
      -- "All": class and profession quests in their own groups (some are not tied to a place,
      -- e.g. the Forever "Crafting" writs), the others by zone.
      if e.isClass then key = L["Class"]
      elseif e.isProf then key = L["Professions"]
      else key = e.dungeon or e.area or e.starterZone or L["Other"] end
    end
    if keep and searching then keep = MatchWords(EntryHaystack(e), State.availQuery) end
    end
    if keep then
      kind = e.dungeon and key == e.dungeon and "dungeon" or ((key == L["Class"] or key == L["Professions"]) and "class") or "zone"
      local g = byKey[key]
      if not g then
        g = { name = key, kind = kind, list = {} }
        byKey[key] = g
        groups[#groups + 1] = g
      end
      g.list[#g.list + 1] = e
      if e.pvp then g.pvp, g.kind = true, "pvp" end
    end
  end

  -- Order of the categories: class, professions, dungeons, standard zones, PvP; then alphabetical.
  local function Rank(g)
    if g.name == L["Class"] then return 1 end
    if g.name == L["Professions"] then return 2 end
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
  local pos = PlayerPos()
  for _, g in ipairs(groups) do
    table.sort(g.list, function(a, b) return (a.level or 0) < (b.level or 0) end)
    items[#items + 1] = { header = true, kind = g.kind, key = g.name, label = g.name .. " - " .. Plural(#g.list, L["quest"]) }
    for _, e in ipairs(g.list) do
      local D = K.DESC
      local text = "  " .. StateIcons(e.id) ..
        Geo.QuestTitle(e.name, { id = e.id, level = e.level, isClass = e.isClass, isProf = e.isProf, dungeon = e.dungeon }) ..
        Geo.DescLine(e.starter and Color(D.action, L["Given by: "] .. e.starter) or nil) ..
        Geo.DescLine(Geo.XPText(e.xp, true), Color(D.meta, L["requires level "] .. e.reqLevel),
          e.lowLevel and Color(D.meta, L["low level"]) or nil, e.repeatable and Color(D.meta, L["repeatable"]) or nil,
          e.opensChain and Color(D.chain, L["opens a chain"]) or nil)
      if e.repMissing then text = text .. Geo.DescLine(Color(D.bad, e.repMissing)) end
      if e.missing then
        text = text .. Geo.DescLine(Color(D.bad, L["Missing prerequisites: "] .. table.concat(e.missing.texts, ", ")))
      end
      local rewards = Geo.RewardLine(e.id)
      if rewards then text = text .. Geo.DescLine(rewards) end
      local p = GeoReady() and Nearest(StartPoints(e.id), pos) or nil
      items[#items + 1] = { text = text, b2 = PinButton(p, e.name, L["pick up the quest"], e.id), links = rewards ~= nil,
        linkQuest = e.id }
    end
  end
  if total == 0 then items[#items + 1] = { text = searching and L["No quest matches the search."] or L["No quest available for this filter."] } end
  RenderList(panel, "avail", items, searching)
end

local function RenderNear()
  local panel = panels.near
  if not QDB.ok then
    ShowMessage(panel, "near", L["QuestieDB is not loaded: this tab needs the locations from its database."])
    return
  end
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

  local function row(it, withKind)
    local D = K.DESC
    local take = it.kind == "take"
    local figures = Geo.DescLine(take and Geo.XPText(it.xp, true) or nil, Color(D.meta, string.format("%.0f m", it.d)),
      (take and it.lowLevel) and Color(D.meta, L["low level"]) or nil)
    local who
    if it.kind == "take" then
      who = L["Given by: "] .. (it.giver or "?")
    elseif it.kind == "turnin" then
      who = L["Turn in to: "] .. (it.giver or "?")
    else
      who = L["Objective: "] .. (it.extra or "?")
    end
    local text = "  " .. StateIcons(it.id) .. (withKind and (Geo.KindTag(it.kind == "step" and "obj" or it.kind) .. " ") or "") ..
      Geo.QuestTitle(it.label, it.id and { id = it.id, level = it.level } or nil) ..
      Geo.DescLine(Color(D.action, who .. K.DESC_SEP .. PointText(it.p))) .. figures
    if it.rep then text = text .. Geo.DescLine(Color(D.bad, it.rep)) end
    local b1
    if it.kind ~= "take" and it.id then
      local watched = IsWatched(it.id)
      local qid = it.id
      b1 = { text = watched and L["Untrack"] or L["Track"], fn = function()
        SetWatched(qid, not watched)
        C_Timer.After(0.2, Refresh)
      end }
    end
    return { text = text, b1 = b1, questID = it.kind ~= "take" and it.id or nil, linkQuest = it.id,
      b2 = PinButton(it.p, it.label, it.kind == "step" and it.extra or (it.kind == "turnin" and L["turn in the quest"] or L["pick up the quest"]), it.id) }
  end

  local sections = {
    { kind = "turnin", label = L["To turn in"], unit = L["quest"] },
    { kind = "step", label = L["Steps of quests in progress"], unit = L["step"] },
    { kind = "take", label = L["Available quests"], unit = L["quest"] },
  }
  for _, sec in ipairs(sections) do
    local list = {}
    for _, it in ipairs(found) do
      if it.kind == sec.kind and matches(it) then list[#list + 1] = it end
    end
    if #list > 0 then
      items[#items + 1] = { header = true, kind = sec.kind, key = sec.kind, label = sec.label .. " - " .. Plural(#list, sec.unit) }
      for _, it in ipairs(list) do items[#items + 1] = row(it, false) end
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
