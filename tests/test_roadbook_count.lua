-- Roadbook tab: how many quests are shown out of how many.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()
local Geo = ns.Geo
env.UnitLevel = function() return 30 end
Geo.RoadbookQuests = function() return { { id = 1, title = "Alpha", done = true, listed = true }, { id = 2, title = "Beta", done = true, listed = true } } end
Geo.RoadbookCategories = function(list) return { { kind = "done", key = "d", quests = list } } end
Geo.QuestTitle = function(title) return title end
Geo.DescLine = function() return "" end
Geo.DoubtLine = function() return "" end
ns.RequestQuestTags = function() end
local function count(query)
  local a, b = Geo.RoadbookQuestItems({}, nil, query)
  return tostring(a) .. "/" .. tostring(b)
end
check("no search: every quest", count({}) == "2/2")
check("search: the ones found out of all", count({ "alpha" }) == "1/2")
check("search with no result", count({ "zzz" }) == "0/2")
finish()
