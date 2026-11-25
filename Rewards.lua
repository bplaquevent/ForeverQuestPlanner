-- Forever Quest Planner: quest rewards: their data, the interest of an item while leveling, and the
-- quests kept for the maximum level.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, AllIds, AreaName, GetItemInfoCompat, IsCompleted, K = ns.Geo, ns.AllIds, ns.AreaName, ns.GetItemInfoCompat, ns.IsCompleted, ns.K
local L, NextQuests, PlayerSkills, QDB, QGet, QuestMeta = ns.L, ns.NextQuests, ns.PlayerSkills, ns.QDB, ns.QGet, ns.QuestMeta
local Refresh, WornItemLevel = ns.Refresh, ns.WornItemLevel

-- Main talent tree (the one with the most points), nil before level 10.
function Geo.SpecIndex()
  if not (GetNumTalentTabs and GetTalentTabInfo) then return nil end
  local best, bestPts = nil, 0
  for i = 1, GetNumTalentTabs() or 0 do
    local r = { pcall(GetTalentTabInfo, i) }
    if r[1] then
      local pts = type(r[4]) == "number" and r[4] or (type(r[6]) == "number" and r[6]) or 0
      if pts > bestPts then best, bestPts = i, pts end
    end
  end
  return best
end

-- Index "quest -> reward items" (QuestieDB), built once per session.
function Geo.IndexItemRewards(idx, id)
  local qs = QGet(QDB.Item, id, "questRewards")
  if type(qs) == "table" then
    for _, q in ipairs(qs) do
      idx[q] = idx[q] or {}
      table.insert(idx[q], id)
    end
  end
end

-- Built in one go (spread over frames inside the Roadbook computation).
function Geo.RewardIndex()
  if Geo.rewards then return Geo.rewards end
  local idx = {}
  for n, id in ipairs(AllIds(QDB.Item) or {}) do
    Geo.IndexItemRewards(idx, id)
    if n % 500 == 0 then Geo.Yield() end
  end
  Geo.rewards = idx
  return idx
end

-- Built in the background (500 items per frame) for the "Available" tab, then the list is refreshed.
function Geo.BuildRewardIndexAsync()
  if Geo.rewards or Geo.rewardsBuilding then return end
  local ids, idx, i = AllIds(QDB.Item) or {}, {}, 1
  Geo.rewardsBuilding = true
  local function step()
    if Geo.rewards then -- built meanwhile by the Roadbook computation
      Geo.rewardsBuilding = nil
      return
    end
    local stop = math.min(i + 499, #ids)
    for k = i, stop do Geo.IndexItemRewards(idx, ids[k]) end
    i = stop + 1
    if i <= #ids then
      C_Timer.After(0, step)
    else
      Geo.rewards, Geo.rewardsBuilding = idx, nil
      if Refresh then Refresh() end
    end
  end
  step()
end

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

-- QuestieDB "teachesSpell" field: a spell ID, or the default 0 (truthy in Lua!) when the item teaches nothing.
function Geo.ItemTeachesSpell(itemId)
  local v = QGet(QDB.Item, itemId, "teachesSpell")
  return type(v) == "number" and v > 0
end

-- Reward that teaches a skill: a book, or a recipe of one of the character's professions.
-- (QuestieDB's "teachesSpell" field is empty in the Forever database: the item class is used too.)
function Geo.TeachesSkill(classID, subclassID)
  if classID ~= 9 then return false end
  if subclassID == 0 then return true end
  local skills = PlayerSkills()
  for line, p in pairs(ns.PROFESSIONS) do
    if p.recipe == subclassID then return skills[line] ~= nil end
  end
  return false
end

-- Interest of a reward item while leveling: 1 + reason, or 0 (an item useful now is not kept for max level).
function Geo.ItemInterest(itemId, plevel)
  local name, link, quality, ilvl, _, _, _, _, equipLoc, _, _, classID, subclassID = GetItemInfoCompat(itemId)
  if not name then
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemId) end
    return 0
  end
  if Geo.ItemTeachesSpell(itemId) or Geo.TeachesSkill(classID, subclassID) then
    return 1, name .. L[" (teaches a skill)"]
  end
  if equipLoc == "INVTYPE_BAG" then return 1, name .. L[" (bag)"] end
  local worst = WornItemLevel(equipLoc)
  if not worst then return 0 end
  local _, cls = UnitClass("player")
  if classID == 4 and subclassID and subclassID > 0 then
    local ok = ns.ARMOR[cls] and ns.ARMOR[cls][subclassID]
    if not ok or (type(ok) == "number" and plevel < ok) then return 0 end
  elseif classID == 2 then
    if not (ns.WEAPONS[cls] and ns.WEAPONS[cls][subclassID]) then return 0 end
  end
  local specOK = true
  local spec = Geo.SpecIndex()
  local wanted = spec and ns.SPEC_STATS[cls] and ns.SPEC_STATS[cls][spec]
  if wanted and link and GetItemStats then
    local ok, stats = pcall(GetItemStats, link)
    if ok and type(stats) == "table" then
      specOK = false
      for _, st in ipairs(wanted) do
        if stats["ITEM_MOD_" .. st .. "_SHORT"] then specOK = true break end
      end
    end
  end
  local upgrade = (ilvl or 0) > worst
  if (quality or 0) >= 3 then
    if specOK then return 1, name .. L[" (blue)"] end
    return 1, name .. L[" (blue, off-spec)"]
  end
  if upgrade then return 1, name .. L[" (upgrade)"] end
  return 0
end

K.ENDGAME_MARGIN = 5      -- a dungeon less than 5 levels below the maximum is an endgame goal

-- Item important for the endgame but useless while leveling: key, mount,
-- epic item that cannot be used (yet).
function Geo.LaterItem(itemId, plevel)
  local name, _, quality, _, _, _, _, _, _, _, _, classID, subclassID = GetItemInfoCompat(itemId)
  if not name then return nil end
  if Geo.ItemInterest(itemId, plevel) > 0 then return nil end
  if classID == 13 then return name .. L[" (key)"] end
  if classID == 15 and subclassID == 5 then return name .. L[" (mount)"] end
  if (quality or 0) >= 4 then return name .. L[" (epic)"] end
  return nil
end

-- Reason to keep a quest (and its chain) for max level, or nil.
function Geo.LaterReason(id, plevel)
  Geo.laterCache = Geo.laterCache or {}
  local c = Geo.laterCache[id]
  if c ~= nil then return c or nil end
  local maxL = Geo.MaxLevel()
  local root = QuestMeta(id)
  local rootLevel = (root and root.level and root.level > 0) and root.level or plevel
  local reason
  local queue, seen, i = { id }, { [id] = true }, 1
  while i <= #queue and i <= 25 and not reason do
    local qid = queue[i]
    i = i + 1
    local m = QuestMeta(qid)
    if m and (qid == id or not IsCompleted(qid)) then
      local lvl = (m.level and m.level > 0) and m.level or rootLevel
      -- Chain rewards, within the same level range as the starting quest.
      if qid == id or lvl <= rootLevel + 5 then
        for _, item in ipairs(Geo.RewardIndex()[qid] or {}) do
          local r = Geo.LaterItem(item, plevel)
          if r then reason = r break end
        end
      end
      -- Chain leading to an endgame dungeon (access, attunement).
      local dg = m.sort and m.sort > 0 and QDB.dungeonOf[m.sort]
      if not reason and dg and lvl >= maxL - K.ENDGAME_MARGIN and rootLevel >= maxL - 10 then
        reason = L["access to "] .. (AreaName(dg) or L["an endgame dungeon"])
      end
      for _, nq in ipairs(NextQuests(m)) do
        if not seen[nq] then
          seen[nq] = true
          queue[#queue + 1] = nq
        end
      end
    end
  end
  Geo.laterCache[id] = reason or false
  return reason
end
