-- A scan of the available quests that fails ends: the error is shown and another scan can start.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local late, deferred
-- one quest offered: enough for the results to have an entry to publish
local quest = { name = "Q", requiredLevel = 28, questLevel = 30, zoneOrSort = 12, startedBy = { { 5 }, {}, {} } }
local env, ns = H.session(nil, {
  ["QuestAnalysis.lua"] = function(ns)
    ns.QGet = function(e, _, k) if e == "quest" then return quest[k] end end
    ns.AllIds = function() return { 1 } end
    ns.PlayerSkills = function() return {}, nil, true end
    ns.PlayerBits = function() return 1, 1 end
    ns.PlayerFaction = function() return "H" end
    ns.IsCompleted = function() return false end
    ns.IsInLog = function() return false end
    ns.QuestAllowed = function() return true end
    ns.QuestPrereqs = function() return {}, {} end
    ns.QuestMeta = function() return nil end
    ns.GiverText = function() return "giver", "zone" end
    ns.DBXP = function() return 100 end
    ns.AreaName = function() return "area" end
    ns.IdKind = function() error("kind broke") end
  end,
  ["QuestTags.lua"] = function(ns)
    ns.RequestQuestTags = function(_, finished)
      if late then deferred = finished return false end
      error("tags broke")
    end
  end,
})
ns.QDB.Quest, ns.QDB.Item, ns.QDB.Npc = "quest", "item", "npc"
ns.QDB.lib = { Enum = {} }
ns.Geo.ChainQuests = function() return {} end
env.UnitLevel = function() return 30 end
local scan = ns.scan

check("failure while concluding: not raised", pcall(ns.StartScan))
check("failure while concluding: scan over, error shown", scan.running == false and scan.error ~= nil)
ns.ScanIfNeeded()
check("not started again by a display", scan.running == false and scan.error ~= nil)
ns.MarkScanDirty()
check("quests changed: the error is dropped, to scan again", scan.error == nil)

-- results published once the tags are loaded, later: an error there ends the scan too
late = true
ns.StartScan()
check("waiting for the tags", scan.running == true and deferred ~= nil)
check("failure while publishing: not raised", pcall(deferred))
check("failure while publishing: scan over", scan.running == false)
finish()
