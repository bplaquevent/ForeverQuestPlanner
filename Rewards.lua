-- Forever Quest Planner: quest rewards: their data (items, reputations).
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, AllIds, GetItemInfoCompat = ns.Geo, ns.AllIds, ns.GetItemInfoCompat
local L, QDB, QGet = ns.L, ns.QDB, ns.QGet
local Refresh = ns.Refresh

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

local rewardIndex, rewardIndexBuilding -- items rewarding each quest, built once per session

-- Whether the reward index is ready (otherwise Geo.BuildRewardIndexAsync builds it).
function Geo.RewardsReady()
  return rewardIndex ~= nil
end

-- Built in one go (spread over frames inside the Roadbook computation).
function Geo.RewardIndex()
  if rewardIndex then return rewardIndex end
  local idx = {}
  for n, id in ipairs(AllIds(QDB.Item) or {}) do
    Geo.IndexItemRewards(idx, id)
    if n % 500 == 0 then Geo.Yield() end
  end
  rewardIndex = idx
  return idx
end

-- Built in the background (500 items per frame) for the "Available" tab, then the list is refreshed.
function Geo.BuildRewardIndexAsync()
  if rewardIndex or rewardIndexBuilding then return end
  local ids, idx, i = AllIds(QDB.Item) or {}, {}, 1
  rewardIndexBuilding = true
  local function step()
    if rewardIndex then -- built meanwhile by the Roadbook computation
      rewardIndexBuilding = nil
      return
    end
    local stop = math.min(i + 499, #ids)
    for k = i, stop do Geo.IndexItemRewards(idx, ids[k]) end
    i = stop + 1
    if i <= #ids then
      C_Timer.After(0, step)
    else
      rewardIndex, rewardIndexBuilding = idx, nil
      Refresh()
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
