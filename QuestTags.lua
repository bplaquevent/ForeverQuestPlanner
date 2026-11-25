-- Forever Quest Planner: the game gives the tag (dungeon, raid, PvP) of a quest out of the log only
-- once the quest's data are loaded. They are asked for in batches, once per session.

local ADDON_NAME, ns = ...
local K = ns.K

K.TAG_BATCH = 100  -- quests asked to the game at once (in game: 100 answered within 5 s)
K.TAG_TIMEOUT = 5  -- s without any answer: the quests still waited for are given up for the session

-- queue: ids to ask for, from index head; asked: ids ever queued; settled: answered or given up;
-- waiting: ids of the running batch not answered yet (left of them); count / total: progress since
-- the loader was last idle.
local queue, head, asked, settled = {}, 1, {}, {}
local waiting, left, batch, lastAnswer = {}, 0, 0, 0
local count, total = 0, 0
local watchers = {} -- { ids, done }: done() once all its ids are settled

local function Settled(ids)
  for _, id in ipairs(ids) do
    if not settled[id] then return false end
  end
  return true
end

local function NotifyWatchers()
  local ready = {}
  for i = #watchers, 1, -1 do
    if Settled(watchers[i].ids) then
      table.insert(ready, 1, table.remove(watchers, i))
    end
  end
  for _, w in ipairs(ready) do w.done() end
end

local Pump

local function Settle(id)
  waiting[id], settled[id] = nil, true
  left, count = left - 1, count + 1
end

local function BatchOver()
  if head <= #queue then C_Timer.After(0, Pump) end
  NotifyWatchers()
  ns.Refresh() -- the kinds and the progress shown
end

-- Gives the running batch up when the game stops answering.
local function Watch(n)
  C_Timer.After(K.TAG_TIMEOUT, function()
    if batch ~= n or left == 0 then return end
    if GetTime() - lastAnswer < K.TAG_TIMEOUT then return Watch(n) end
    local late = {}
    for id in pairs(waiting) do late[#late + 1] = id end
    for _, id in ipairs(late) do Settle(id) end
    BatchOver()
  end)
end

function Pump()
  if left > 0 or head > #queue then return end
  batch = batch + 1
  local ids = {}
  while head <= #queue and #ids < K.TAG_BATCH do
    ids[#ids + 1] = queue[head]
    head = head + 1
  end
  -- all waited for before the first request: the game may answer while they are being asked
  for _, id in ipairs(ids) do waiting[id] = true end
  left, lastAnswer = #ids, GetTime()
  Watch(batch)
  for _, id in ipairs(ids) do C_QuestLog.RequestLoadQuestByID(id) end
end

-- Event QUEST_DATA_LOAD_RESULT (Events.lua), successful or not.
local function QuestDataLoaded(id)
  if not waiting[id] then return end
  lastAnswer = GetTime()
  Settle(id)
  if left == 0 then BatchOver() end
end

-- Asks for the tags of the quests ids not asked for yet. True when all of them are settled already;
-- otherwise false, and done() (optional) is called once they are.
local function RequestQuestTags(ids, done)
  if Settled(ids) then return true end
  if left == 0 and head > #queue then count, total = 0, 0 end
  for _, id in ipairs(ids) do
    if not asked[id] then
      asked[id] = true
      queue[#queue + 1] = id
      total = total + 1
    end
  end
  if done then watchers[#watchers + 1] = { ids = ids, done = done } end
  Pump()
  return false
end

-- Quests settled and asked for since the loader was last idle.
local function TagProgress()
  return count, total
end

-- Shared with the next files.
ns.QuestDataLoaded, ns.RequestQuestTags, ns.QuestTagsSettled, ns.TagProgress = QuestDataLoaded, RequestQuestTags, Settled, TagProgress
