-- Candidate quests of the automatic Roadbook (BuildTasks, TakeTask), and an old saved Roadbook
-- holding the former reserved list.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local outside = { { c = 0, x = 1, y = 1 } }
local inside = { { c = 0, x = 2, y = 2, instance = "Fosse" } }
local LOG = {
  { id = 1, title = "Epic reward", level = 30, xp = 4000 },
  { id = 2, title = "Dungeon fight", level = 30, xp = 4000, isInstance = true },
  { id = 3, title = "Ready", level = 30, xp = 100, complete = true },
  { id = 4, title = "Dungeon ready", level = 30, xp = 100, complete = true, isInstance = true },
  { id = 5, title = "Ends inside", level = 30, xp = 100 },
  { id = 6, title = "PvP fight", level = 30, xp = 4000, gameKind = "pvp" },
  { id = 7, title = "PvP ready", level = 30, xp = 100, complete = true, gameKind = "pvp" },
  { id = 8, title = "Raid fight", level = 30, xp = 4000, gameKind = "raid" },
}
local env, ns = H.session(nil, { ["Geo.lua"] = function(ns)
  ns.LogQuests = function() return LOG end
  ns.QuestTargets = function(id) return { finish = id == 5 and inside or outside, start = outside, missing = 0 } end
  ns.RemainingTargets = function() return {}, 0 end
  ns.DBXP = function() return 100 end
  ns.Nearest = function() return outside[1], 10 end
  ns.StartPoints = function() return outside end
  ns.TravelSpeed = function() return 7 end
  ns.IdKind = function(id) return ({ [12] = "dungeon", [13] = "dungeon", [14] = "pvp", [15] = "raid", [16] = "pvp" })[id] end
end })
local Geo = ns.Geo
env.UnitLevel = function() return 30 end
env.GetMaxPlayerLevel = function() return 60 end
Geo.StartPlaces = function() return nil end
Geo.IsEscort = function() return false end
Geo.SkillNeed = function() return nil end
Geo.MaxQuestLevel = function() return 60 end
local FIGHT = { [2] = true, [4] = true, [6] = true, [7] = true, [8] = true, [11] = true, [12] = true, [14] = true, [15] = true }
Geo.QuestTypes = function(id) return FIGHT[id] and { "slaying" } or { "talk" } end
Geo.UnlockLevel = function() return 30 end

ns.scan.entries = {
  { id = 11, name = "Available, epic reward", level = 30, xp = 500 },
  { id = 12, name = "Available dungeon fight", level = 30, xp = 500, dungeon = "Fosse" },
  { id = 13, name = "Available dungeon talk", level = 30, xp = 500, dungeon = "Fosse" },
  { id = 14, name = "Available PvP fight", level = 30, xp = 500 },
  { id = 15, name = "Available raid fight", level = 30, xp = 500 },
  { id = 16, name = "Available PvP talk", level = 30, xp = 500 },
}
local ok, tasks = pcall(ns.BuildTasks, outside[1], 30)
check("candidates prepared without error: " .. tostring(not ok and tasks or ""), ok)
local by = {}
for _, t in ipairs(ok and tasks or {}) do by[t.id] = t end
check("log quest once reserved: candidate", by[1] ~= nil)
check("dungeon fight in the log: left out", by[2] == nil)
check("ready quest: candidate, quick", by[3] ~= nil and by[3].quick == true)
check("ready dungeon quest turned in outside: candidate", by[4] ~= nil)
check("turned in inside the instance: left out", by[5] == nil)
check("available quest once reserved: candidate", by[11] ~= nil)
check("available dungeon fight: left out", by[12] == nil)
check("available dungeon talk: candidate", by[13] ~= nil)
check("PvP and raid fights in the log: left out", by[6] == nil and by[8] == nil)
check("ready PvP quest: candidate", by[7] ~= nil)
check("available PvP and raid fights: left out", by[14] == nil and by[15] == nil)
check("available PvP talk: candidate", by[16] ~= nil)
check("no task marked for later", by[1] and by[1].later == nil)

-- a Roadbook saved by the former version, with its reserved quests
local st = ns.Settings()
st.roadbook = { saved = "10:00", start = { c = 0, x = 0, y = 0 }, steps = { { kind = "fm", p = { c = 0, x = 1, y = 1 }, task = { title = "a" } } },
  info = { count = 1, xp = 0, total = 0, custom = true, later = { { id = 9, title = "Old", reason = "mount" } } } }
Geo.KnownNodes = function() return {}, 0 end -- known flight paths: read from OpenMap
Geo.ready = true
Geo.areaToUi = Geo.areaToUi or {}
ns.TaxiCount = ns.TaxiCount
local okF, fz = pcall(Geo.Frozen)
check("old Roadbook loaded: " .. tostring(not okF and fz or ""), okF and fz ~= nil and #fz.route == 2)
if okF and fz then
  Geo.RecallState = function() return {} end
  Geo.Trace = function() end
  Geo.Freeze(fz.route, fz.info)
  check("saved again: the reserved list is gone", st.roadbook.info.later == nil and #st.roadbook.steps == 1)
end
finish()
