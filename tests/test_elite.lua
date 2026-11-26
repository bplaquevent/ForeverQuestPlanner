-- The game's elite tag read with the quest log, elite quests, their badges, and the failure of the
-- patrol passes told once.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local ranks = { [100] = 1, [101] = 0 }
local patrolsBroken = false
local OBJ = { [2] = { { { 100, nil, nil } } }, [3] = { { { 101, nil, nil } } } }
local env, ns, log = H.session(nil, { ["Available.lua"] = function(ns)
  ns.QDB.Quest, ns.QDB.Item, ns.QDB.Npc = "quest", "item", "npc"
  ns.QGet = function(entity, id, field)
    if entity == "quest" and field == "objectives" then return OBJ[id] end
    if entity == "npc" and field == "rank" then return ranks[id] end
    if entity == "npc" and field == "waypoints" then
      if patrolsBroken then error("data changed") end
      return {}
    end
  end
end })
local Geo = ns.Geo
local function chat() return table.concat(log.chat, "\n") end

-- 1. the capture reads the game tag by its id
env.Enum = { QuestTag = { Group = 1, Dungeon = 81, Raid = 62 } }
local tags = { [1] = { tagID = 1, tagName = "Élite" }, [2] = nil, [3] = { tagID = 41, tagName = "PvP" }, [4] = { tagID = 81, tagName = "Donjon" },
  [5] = { tagID = 99, tagName = "Élite" } }
local infos = { { title = "Zone", isHeader = true } }
for id = 1, 5 do infos[#infos + 1] = { questID = id, title = "Q" .. id, level = 30 } end
env.C_QuestLog = { GetNumQuestLogEntries = function() return #infos end, GetInfo = function(i) return infos[i] end,
  GetQuestTagInfo = function(id) return tags[id] end, GetQuestObjectives = function() return {} end,
  IsComplete = function() return false end, IsFailed = function() return false end }
env.GetQuestUiMapID = false -- no quest map
env.GetQuestLogRewardXP = function() return 100 end
env.GetQuestLogRewardMoney = function() return 0 end
env.UnitName = function() return "Test" end
env.UnitLevel = function() return 30 end
env.UnitXP = function() return 0 end
env.GetRealZoneText = function() return "Zone" end
env.date = function() return "now" end
local ok, count = pcall(ns.Snapshot)
check("quest log captured: " .. tostring(not ok and count or ""), ok and count == 5)
local byId = {}
for _, q in ipairs((env.ForeverQuestPlannerDB or {})["Test-Realm"] and env.ForeverQuestPlannerDB["Test-Realm"].quests or {}) do byId[q.id] = q end
check("tag id 1: elite", byId[1] and byId[1].gameElite == true and byId[1].tag == "Élite")
check("other tags: not elite", byId[2] and not byId[2].gameElite and not byId[3].gameElite)
check("dungeon id: instance, not elite", byId[4] and byId[4].gameKind == "dungeon" and not byId[4].gameElite)
check("the word alone no longer counts", byId[5] and not byId[5].gameElite)

-- 2. elite quests: the game's tag, then the monsters' rank
check("elite by the game", Geo.IsEliteQuest(1) == true)
check("elite by the monsters' rank", Geo.IsEliteQuest(2) == true)
check("neither", Geo.IsEliteQuest(3) == false and Geo.IsEliteQuest(9) == false)
byId[1].gameElite, Geo.elite = nil, {}
check("former capture without the field: rank only", Geo.IsEliteQuest(1) == false)
byId[1].gameElite, Geo.elite = true, {}
ns.Settings().noElite = true
check("elite excluded by the setting", Geo.MaxQuestLevel(1, 30) == -math.huge and Geo.MaxQuestLevel(9, 30) > 30 - 1)
ns.Settings().noElite = nil
check("elite included: elite gap", Geo.MaxQuestLevel(1, 30) == 30 + ns.K.MAX_ELITE_GAP and Geo.MaxQuestLevel(9, 30) == 30 + ns.K.MAX_LEVEL_GAP)
Geo.IsFollowUp = function() return false end
Geo.QuestTypes = function() return {} end
Geo.WithLevel = function(s) return s end
Geo.LevelBadge = function() return "[30]" end -- its colour is the game's
local function badges(id, tag)
  return (Geo.QuestBadges({ id = id, level = 30, tag = tag, isClass = false, isProf = false, noTypes = true }):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
local function times(s, word) local n = 0 for _ in s:gmatch(word) do n = n + 1 end return n end
local one = badges(1, "Élite")
check("game elite: said once (" .. one .. ")", times(one, "Élite") + times(one, "Elite") == 1)
check("other tag kept", badges(3, "PvP"):find("PvP", 1, true) ~= nil)
local both = badges(2, "Donjon")
check("elite by rank keeps the game's tag", both:find("Donjon", 1, true) ~= nil and (both:find("lite") ~= nil))

-- 3. patrol passes
Geo.ready = true
ns.PASS_PATROLS, ns.PASSES = { 1 }, { { 10, 1, 1, 20 } }
env.CreateVector2D = function(x, y) return { x = x, y = y } end
env.C_Map = { GetWorldPosFromMapPos = function(_, v) return 1, { GetXY = function() return v.x * 100, v.y * 100 end } end }
local before = #log.chat
Geo.PassesChanged()
check("patrols read: nothing said", #Geo.Passes() == 1 and #log.chat == before)
patrolsBroken = true
Geo.PassesChanged()
local okP, list = pcall(Geo.Passes)
check("patrols failing: the other passes stay", okP and #list == 1)
check("patrols failing: said", #log.chat == before + 1 and chat():find("rondes de QuestieDB indisponibles", 1, true) ~= nil and chat():find("data changed", 1, true) ~= nil)
Geo.PassesChanged()
Geo.Passes()
check("said once", #log.chat == before + 1)
check("the window's refresh is defined for every file", type(ns.Refresh) == "function")
finish()
