-- The quest log capture (Snapshot, which writes the saved data) is apart from its analysis (Analyze).
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()
local Geo = ns.Geo
local quests = { { questID = 1, title = "First", level = 30 } }
local reads = 0
env.C_QuestLog = {
  GetNumQuestLogEntries = function() reads = reads + 1 return #quests end,
  GetInfo = function(i) return quests[i] end,
  GetQuestObjectives = function() return {} end,
  IsComplete = function() return false end, IsFailed = function() return false end,
}
env.Enum = { QuestTag = { Group = 1, PvP = 41, Raid = 62, Dungeon = 81 } }
env.GetQuestUiMapID = false
env.GetQuestLogRewardXP = function() return 100 end
env.GetQuestLogRewardMoney = function() return 0 end
env.UnitName = function() return "Test" end
env.UnitLevel = function() return 30 end
env.UnitXP = function() return 0 end
env.UnitQuestTrivialLevelRange = function() return 5 end
env.GetMoney = function() return 0 end
env.GetRealZoneText = function() return "Zone" end
env.date = function() return "now" end
ns.QDB.Quest, ns.QDB.Npc, ns.QDB.Item, ns.QDB.Object = { Get = function() end }, { Get = function() end }, { Get = function() end }, { Get = function() end }
ns.QDB.dungeons, ns.QDB.dungeonOf = {}, {}

local function count(a)
  local n = #a.turnIn + #a.later
  for _, list in ipairs({ a.groups, a.instances }) do
    for _, g in ipairs(list) do n = n + #g.quests end
  end
  return n
end

local a = ns.Analyze()
check("analysing alone: no capture, nothing saved", reads == 0 and env.ForeverQuestPlannerDB == nil and count(a) == 0)
ns.Snapshot()
local saved = env.ForeverQuestPlannerDB
check("capture: saved", reads == 1 and saved ~= nil)
quests[2] = { questID = 2, title = "Second", level = 30 }
a = ns.Analyze()
check("analysis of the last capture only", reads == 1 and count(a) == 1)

Geo.InCustom = function() return false end
local cats = Geo.RoadbookCategories({ { id = 1, title = "First", level = 30, order = 1 } })
check("the list's categories do not capture", reads == 1 and #cats == 1)

ns.State.abandonIds = nil
Geo.ToAbandon(1)
check("recommendations computed again: log captured first", reads == 2 and #ns.LogQuests() == 2)
Geo.ToAbandon(1)
Geo.ToAbandon(2)
check("then kept: no other capture", reads == 2)
finish()
