-- Quest kinds (dungeon, raid, PvP): recognition, loading of their tags, automatic choice and labels.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns, log = H.session()
local Geo, K, QDB = ns.Geo, ns.K, ns.QDB
local function plain(s) return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- fake clock and timers
local now, timers = 0, {}
env.GetTime = function() return now end
env.C_Timer = { After = function(d, fn) timers[#timers + 1] = { at = now + d, fn = fn } end, NewTicker = function() end }
local function advance(sec)
  local stop = now + sec
  while true do
    local best
    for i, t in ipairs(timers) do if t.at <= stop and (not best or t.at < timers[best].at) then best = i end end
    if not best then break end
    local t = table.remove(timers, best)
    now = math.max(now, t.at)
    t.fn()
  end
  now = stop
end

-- fake game: tags are given for loaded quests only; requests are recorded
env.Enum = { QuestTag = { Group = 1, PvP = 41, Raid = 62, Dungeon = 81 } }
local TAG = { [1] = { 1, "Élite" }, [41] = { 41, "JcJ" }, [62] = { 62, "Raid" }, [81] = { 81, "Donjon" } }
local gameTag, loaded, inLog, requests = {}, {}, {}, {}
env.C_QuestLog = {
  GetQuestTagInfo = function(id)
    local t = (loaded[id] or inLog[id]) and TAG[gameTag[id]]
    return t and { tagID = t[1], tagName = t[2] } or nil
  end,
  RequestLoadQuestByID = function(id) requests[#requests + 1] = id end,
}
local function answer(id) loaded[id] = true ns.QuestDataLoaded(id) end
local refreshes = 0

-- fake QuestieDB: quest zone or sort, and one instance (area 500, alternate 501) and a battleground 3358
local sorts = {}
QDB.Quest = { Get = function(id, key) if key == "zoneOrSort" then return sorts[id] end if key == "name" then return "Q" .. id end end }
QDB.Npc, QDB.Object, QDB.Item = { Get = function() end }, { Get = function() end }, { Get = function() end }
QDB.dungeons = { [500] = { "Mine" }, [3358] = { "Arathi" } }
QDB.dungeonOf = { [500] = 500, [501] = 500, [3358] = 3358 }
env.C_Map = { GetAreaInfo = function(a) return ({ [500] = "La Mine", [3358] = "Bassin Arathi", [16606] = "Sombrelances", [10] = "Foret" })[a] end }

-- 1. recognition out of the log
sorts = { [900] = 3358, [901] = 3358, [902] = 16606, [903] = 500, [904] = 501, [905] = 10, [906] = 10 }
gameTag = { [900] = 41, [902] = 41, [903] = 81, [905] = 62, [906] = 1 }
local function kind(id) local k, p = ns.IdKind(id) return k, p end
check("not loaded: QuestieDB instance is a dungeon", kind(900) == "dungeon")
check("not loaded: outdoor quest has no kind", kind(902) == nil)
for id = 900, 906 do loaded[id] = true end
check("PvP tag beats the instance list", kind(900) == "pvp" and select(2, ns.IdKind(900)) == "Bassin Arathi")
check("battleground without tag: dungeon", kind(901) == "dungeon")
check("PvP out of any instance: place = the area", kind(902) == "pvp" and select(2, ns.IdKind(902)) == "Sombrelances")
check("dungeon, alternate area", kind(903) == "dungeon" and select(2, ns.IdKind(904)) == "La Mine" and kind(904) == "dungeon")
check("raid tag", kind(905) == "raid")
check("elite tag is no kind", kind(906) == nil)

-- 2. captured quests (log)
local function lk(q) local k, p = ns.LogKind(q) return k, p end
check("captured kind first", lk({ gameKind = "pvp", instanceName = "Bassin Arathi", isInstance = true }) == "pvp")
check("captured raid, place = header", select(2, ns.LogKind({ gameKind = "raid", zone = "En-tete" })) == "En-tete")
check("former capture (instance, no kind): dungeon", lk({ isInstance = true, zone = "Z" }) == "dungeon")
check("header named as an instance: dungeon", lk({ zone = "La Mine" }) == "dungeon")
check("the tag word alone no longer counts", lk({ tag = "Donjon", zone = "Z" }) == nil and lk({ tag = "Raid" }) == nil)

-- 3. capture through the real Snapshot
gameTag = { [1] = 41, [2] = 62, [3] = 81, [4] = 1 }
sorts = { [1] = 3358, [5] = 500 }
local infos = { { title = "Zone", isHeader = true } }
for id = 1, 5 do infos[#infos + 1] = { questID = id, title = "Q" .. id, level = 30 } inLog[id] = true end
env.C_QuestLog.GetNumQuestLogEntries = function() return #infos end
env.C_QuestLog.GetInfo = function(i) return infos[i] end
env.C_QuestLog.GetQuestObjectives = function() return {} end
env.C_QuestLog.IsComplete = function() return false end
env.C_QuestLog.IsFailed = function() return false end
env.GetQuestUiMapID = false
env.GetQuestLogRewardXP = function() return 100 end
env.GetQuestLogRewardMoney = function() return 0 end
env.UnitName = function() return "Test" end
env.UnitLevel = function() return 30 end
env.UnitXP = function() return 0 end
env.GetRealZoneText = function() return "Zone" end
env.date = function() return "now" end
local ok, n = pcall(ns.Snapshot)
check("captured: " .. tostring(not ok and n or ""), ok and n == 5)
local byId = ns.LogById()
check("capture kinds", byId[1] and byId[1].gameKind == "pvp" and byId[2].gameKind == "raid" and byId[3].gameKind == "dungeon" and byId[4].gameKind == nil)
check("capture elite kept", byId[4].gameElite == true and not byId[1].gameElite)
check("a tag alone no longer marks an instance; QuestieDB does", byId[2].isInstance == nil and byId[5].isInstance == true)
check("kind of a log quest by id", ns.QuestKind(2) == "raid" and ns.QuestKind(5) == "dungeon" and ns.QuestKind(4) == nil)

-- 4. loader
loaded, inLog = {}, {}
local ids = {}
for i = 1, 250 do ids[i] = 1000 + i end
local done = 0
check("not settled yet", ns.RequestQuestTags(ids, function() done = done + 1 end) == false)
check("first batch of 100", #requests == 100 and select(2, ns.TagProgress()) == 250)
ns.RequestQuestTags(ids)
check("never asked twice", #requests == 100)
for i = 1, 99 do answer(1000 + i) end
check("batch unfinished: next not asked", #requests == 100 and ns.TagProgress() == 99)
ns.QuestDataLoaded(1100) -- a failed load answers too
advance(0.1)
check("a failure settles: second batch", #requests == 200 and done == 0)
ns.QuestDataLoaded(55555)
check("unrelated answers ignored", ns.TagProgress() == 100)
advance(4) answer(1101) advance(4) answer(1102) advance(4)
check("slow but answering: not given up", ns.TagProgress() == 102 and #requests == 200)
advance(7)
check("silent for 5 s: rest given up, third batch", ns.TagProgress() == 200 and #requests == 250 and done == 0)
advance(11)
check("last batch given up: done once", done == 1 and ns.QuestTagsSettled(ids))
advance(30)
check("given up quests not asked again", ns.RequestQuestTags(ids) == true and #requests == 250 and done == 1)
answer(1200)
check("late answer harmless", done == 1)
-- answers given while the batch is being asked
requests = {}
env.C_QuestLog.RequestLoadQuestByID = function(id) requests[#requests + 1] = id answer(id) end
local sync = {} for i = 1, 150 do sync[i] = 2000 + i end
local sdone = 0
ns.RequestQuestTags(sync, function() sdone = sdone + 1 end)
advance(0.1)
check("synchronous answers", sdone == 1 and #requests == 150 and ns.TagProgress() == 150)
env.C_QuestLog.RequestLoadQuestByID = function(id) requests[#requests + 1] = id end
check("progress restarts after idle", ns.RequestQuestTags({ 3001 }) == false and select(2, ns.TagProgress()) == 1 and ns.TagProgress() == 0)
advance(11)

-- 5. the event goes through Events.lua
requests = {}
ns.RequestQuestTags({ 3100 })
log.fire("QUEST_DATA_LOAD_RESULT", 3100, true)
check("QUEST_DATA_LOAD_RESULT handled", ns.QuestTagsSettled({ 3100 }))

-- 6. waiting for the scan: attempts counted only without progress
ns.scan.running, ns.scan.dirty = true, true
local tries, gaveUp = 0, false
local wait = {} for i = 1, 100 do wait[i] = 4000 + i end
ns.RequestQuestTags(wait)
local function retry(a) if ns.WaitScan(a, retry, function() gaveUp = true end) then tries = tries + 1 end end
retry(nil)
for i = 1, 60 do answer(4000 + i) advance(0.5) end
check("30 s of progress: still waiting", not gaveUp)
ns.scan.running, ns.scan.dirty, ns.scan.entries = false, false, {}
advance(1)
local ended = tries
advance(60)
check("scan over: wait ends", not gaveUp and tries == ended)
ns.scan.running = true
retry(nil)
advance(60)
check("no progress: given up", gaveUp)
ns.scan.running = false
timers = {}

-- 7. the scan publishes once the tags are loaded; a change during it asks for another scan
requests, loaded = {}, {}
sorts = { [7001] = 3358, [7002] = 10 }
gameTag = { [7001] = 41 }
QDB.lib = { Enum = {} }
QDB.Quest = { Get = function(id, key)
  if key == "zoneOrSort" then return sorts[id] end
  if key == "name" then return "Q" .. id end
  if key == "startedBy" then return { { 1 } } end
end, GetAllIds = function() return { 7001, 7002 } end }
QDB.xp, QDB.raceMasks = {}, {}
env.IsInInstance = function() return false end
env.C_QuestLog.IsQuestFlaggedCompleted = function() return false end
env.C_QuestLog.GetLogIndexForQuestID = function() return nil end
env.C_QuestLog.IsOnQuest = function() return false end
env.UnitClass = function() return "Chaman", "SHAMAN", 7 end
env.UnitRace = function() return "Orc", "Orc", 2 end
env.UnitFactionGroup = function() return "Horde" end
env.GetQuestGreenRange = function() return 5 end
env.UnitQuestTrivialLevelRange = function() return 5 end
env.GetMoney = function() return 0 end
env.C_SkillInfo = { GetNumSkillLines = function() return 0 end, GetSkillLineInfo = function() end }
env.IsSpellKnown = function() return false end
Geo.ChainQuests = function() return {} end
ns.scan.entries, ns.scan.dirty = nil, true
ns.StartScan()
advance(0.1)
check("scan error: " .. tostring(ns.scan.error), ns.scan.error == nil)
check("scan waits for the tags", ns.scan.running == true and ns.scan.entries == nil and #requests == 2)
ns.MarkScanDirty()
answer(7001) answer(7002)
check("published with the kinds", ns.scan.running == false and ns.scan.entries and #ns.scan.entries == 2)
local en = {}
for _, e in ipairs(ns.scan.entries or {}) do en[e.id] = e end
check("entry kinds", en[7001] and en[7001].kind == "pvp" and en[7001].instance == "Bassin Arathi" and en[7002].kind == nil and en[7002].area == "Foret")
check("changed during the scan: to scan again", ns.scan.dirty == true)
ns.StartScan() advance(0.1)
check("second scan: tags known, immediate and clean", ns.scan.running == false and ns.scan.dirty == false and #requests == 2)

-- 8. automatic choice
local types = { [1] = { "talk" }, [2] = { "delivery", "talk" }, [3] = { "slaying" }, [4] = { "delivery", "collect" } }
Geo.QuestTypes = function(id) return types[id] or {} end
check("no kind: never left out", not Geo.LeftOut(3, nil))
for _, k in ipairs({ "dungeon", "raid", "pvp" }) do
  check(k .. ": talk and delivery kept", not Geo.LeftOut(1, k) and not Geo.LeftOut(2, k))
  check(k .. ": the rest left out", Geo.LeftOut(3, k) and Geo.LeftOut(4, k))
end

-- 9. groups of the Available tab
local function groups(entries, filter)
  ns.scan.entries = entries
  local g = Geo.AvailableGroups(filter, nil, true)
  local out = {}
  for _, x in ipairs(g) do out[#out + 1] = x.name .. "=" .. x.kind .. "[" .. table.concat(x.kinds or {}, "+") .. "]:" .. #x.list end
  return table.concat(out, " ")
end
env.GetZoneText = function() return "" end
local list = {
  { id = 1, name = "a", level = 1, instance = "La Mine", kind = "dungeon", tagged = true },
  { id = 2, name = "b", level = 1, instance = "Coeur", kind = "raid", tagged = true },
  { id = 3, name = "c", level = 1, instance = "Bassin", kind = "pvp", tagged = true },
  { id = 4, name = "d", level = 1, instance = "Bassin", kind = "dungeon" }, -- battleground quest without tag
  { id = 5, name = "e", level = 1, area = "Foret", kind = "pvp", tagged = true },
  { id = 6, name = "f", level = 1, area = "Foret" },
  { id = 7, name = "g", level = 1, area = "Sombrelances", kind = "pvp", tagged = true },
}
local all = groups(list, "all")
check("all: " .. all, all == "Coeur=raid[raid]:1 La Mine=dungeon[dungeon]:1 Foret=zone[]:2 Bassin=pvp[pvp]:2 Sombrelances=pvp[pvp]:1")
local d = groups(list, "dungeon")
check("dungeon filter includes raids, not PvP: " .. d, d == "Bassin=dungeon[dungeon]:1 Coeur=raid[raid]:1 La Mine=dungeon[dungeon]:1")
local p = groups(list, "pvp")
check("PvP filter: " .. p, p == "Bassin=pvp[pvp]:1 Foret=pvp[pvp]:1 Sombrelances=pvp[pvp]:1")
local mixed = groups({
  { id = 1, name = "a", level = 1, instance = "Lieu", kind = "pvp", tagged = true },
  { id = 2, name = "b", level = 1, instance = "Lieu", kind = "raid", tagged = true },
  { id = 3, name = "c", level = 1, instance = "Lieu", kind = "dungeon" }, -- no tag: deduced from the instance
  { id = 4, name = "d", level = 1, area = "Plaine", kind = "pvp", tagged = true },
  { id = 5, name = "e", level = 1, area = "Plaine", kind = "dungeon", tagged = true },
}, "all")
check("mixed groups name every kind, the first one places them: " .. mixed, mixed == "Lieu=raid[raid+pvp]:3 Plaine=pvp[pvp+dungeon]:2")

-- 10. labels
check("category of a kind", select(1, ns.QuestCategory("raid", "X", 1, 30)) == "raid" and select(2, ns.QuestCategory("pvp", nil, 1, 30)) == "JcJ")
check("titles", ns.KindTitle({ "dungeon" }, "X") == "Donjon : X" and ns.KindTitle({ "raid", "pvp" }, "X") == "Raid, JcJ : X")
check("notes", K.KIND_NOTE.dungeon == "donjon : " and K.KIND_NOTE.raid == "raid : " and K.KIND_NOTE.pvp == "JcJ : ")
Geo.IsFollowUp = function() return false end
Geo.IsEliteQuest = function() return false end
Geo.IsGameElite = function() return false end
Geo.WithLevel = function(s) return s end
Geo.LevelBadge = function() return "[30]" end
Geo.LogTag = function() return nil end
for k, word in pairs({ dungeon = "Donjon", raid = "Raid", pvp = "JcJ" }) do
  local b = plain(Geo.QuestBadges({ id = 99, level = 30, kind = k, instance = "X", isClass = false, noTypes = true }))
  check("badge " .. k .. ": " .. b, b:find("[" .. word .. "]", 1, true) ~= nil)
end

-- 11. log analysis, list categories, visit titles
inLog = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
gameTag = { [1] = 41, [2] = 62, [3] = 81, [4] = 1 }
sorts = { [1] = 3358, [5] = 500 }
env.UnitClass = function() return "Chaman", "SHAMAN", 7 end
local okA, a = pcall(ns.Analyze)
check("analysis: " .. tostring(not okA and a or ""), okA)
local cats = {}
for _, g in ipairs(okA and a.instances or {}) do cats[#cats + 1] = g.kind .. "/" .. g.name .. ":" .. #g.quests end
table.sort(cats)
local got = table.concat(cats, " ")
check("log categories: " .. got, got == "dungeon/La Mine:1 dungeon/Zone:1 pvp/Bassin Arathi:1 raid/Zone:1")
local function task(id) return { id = id, title = "Q" .. id, stops = {}, pres = {} } end
local function visitTitle(...)
  local tasks = {}
  for _, id in ipairs({ ... }) do
    local t = task(id)
    t.stops = { { kind = "obj", p = { instance = "Lieu" }, task = t, xp = 0 } }
    tasks[#tasks + 1] = t
  end
  local v = Geo.GroupDungeons(tasks)
  return v[1] and v[1].task.title
end
check("visit PvP: " .. tostring(visitTitle(1)), visitTitle(1) == "JcJ : Lieu")
check("visit: every kind, in order: " .. tostring(visitTitle(1, 2, 3)), visitTitle(1, 3, 2) == "Raid, JcJ, Donjon : Lieu")
check("visit dungeon", visitTitle(3, 4) == "Donjon : Lieu" and visitTitle(4) == "Donjon : Lieu")
check("visit PvP and tagged dungeon: both", visitTitle(3, 1) == "JcJ, Donjon : Lieu")
check("visit: a dungeon only deduced from the instance is not added to a tagged kind", visitTitle(5, 1) == "JcJ : Lieu")
check("visit: deduced dungeon alone", visitTitle(5) == "Donjon : Lieu")

-- 12. follow-ups: gathered, then awaited inside a computation
Geo.pre = { [10] = { 11, 12 }, [11] = { 13 }, [13] = { 10 }, [20] = { 21 } }
local lvl = { [12] = 60 }
QDB.Quest = { Get = function(id, key) if key == "requiredLevel" then return lvl[id] end end }
env.C_QuestLog.IsQuestFlaggedCompleted = function(id) return id == 21 end
local f = Geo.FollowUpIds({ { id = 10 }, { id = 20 }, {} }, { plevel = 30, lookahead = 5 })
table.sort(f)
check("follow-ups: " .. table.concat(f, ","), table.concat(f, ",") == "10,11,13")
requests, timers = {}, {}
local resumed = false
local co = coroutine.create(function() Geo.AwaitTags({ 8001, 8002 }) resumed = true end)
ns.State.co = co
coroutine.resume(co)
check("computation waits", not resumed and coroutine.status(co) == "suspended")
coroutine.resume(co)
check("still waits", not resumed)
answer(8001) answer(8002)
coroutine.resume(co)
check("computation goes on", resumed)
local co2 = coroutine.create(function() Geo.AwaitTags({ 8003 }) end)
ns.State.co = co2
coroutine.resume(co2)
advance(11)
coroutine.resume(co2)
check("unanswered quest does not block", coroutine.status(co2) == "dead")
ns.State.co = nil
check("outside a computation: no wait", pcall(Geo.AwaitTags, { 8004 }))

finish()
