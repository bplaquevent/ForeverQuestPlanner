-- Reading of QuestieDB and of the game: quest targets (kill credit, objectives without a place, drop
-- rate, places inside a dungeon, escort waiting for its source item), maximum reputation, items that
-- start a quest, services read after a failure, flight nodes without the game's names, two-hand
-- weapons, calls to the dependencies.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()

local data = { quest = {}, npc = {}, item = {}, object = {} }
local bags, completed = {}, {}
local env, ns, log = H.session(nil, {
  -- replaced before QuestAnalysis.lua and the next files import them
  ["QuestData.lua"] = function(ns)
    ns.realQGet = ns.QGet
    ns.QGet = function(e, id, k) local row = data[e] and data[e][id] return row and row[k] end
    ns.QDB.Quest, ns.QDB.Npc, ns.QDB.Item, ns.QDB.Object = "quest", "npc", "item", "object"
    ns.QDB.dungeonOf = { [500] = 500 }
    ns.QDB.dungeons = { [500] = { "Gouffre", nil, nil, { { 12, 50, 50 } } } }
    ns.AreaName = function(a) return "area" .. a end
    ns.AllIds = function(e) if e == "quest" then return { 1 } end return e == "npc" and { 30 } or nil end
    ns.TurnInText = function() return nil end
    ns.PlayerSkills = function() return {}, {}, true end
  end,
  ["QuestLog.lua"] = function(ns, env)
    ns.LogRecord = function() return { quests = { { id = 1, title = "Q", level = 1, complete = true } } } end
    -- read when QuestAnalysis.lua loads
    local items = { two = { 40, "INVTYPE_2HWEAPON" }, orb = { 20, "INVTYPE_HOLDABLE" }, big = { 50, "INVTYPE_HOLDABLE" } }
    env.C_Item = { GetItemInfo = function(l) return l, l, 2, items[l][1], 1, "", "", 1, items[l][2] end }
  end,
  ["QuestAnalysis.lua"] = function(ns)
    ns.IsCompleted = function(q) return completed[q] == true end
    ns.IsInLog = function() return false end
    ns.QuestAllowed = function() return true end
    ns.QuestPrereqs = function() return {}, {} end
    ns.QuestMeta = function() return nil end
    ns.GiverText = function() return "giver", "zone" end
    ns.DBXP = function() return 100 end
    ns.IdKind = function() return nil end
    ns.PlayerFaction = function() return "A" end
    ns.NpcFriendly = function() return true end
  end,
})
local Geo = ns.Geo
env.UnitQuestTrivialLevelRange = function() return 8 end
ns.QDB.lib, ns.QDB.raceMasks = { Enum = {} }, {}
Geo.areaToUi, Geo.parent = { [12] = 12 }, {}
env.CreateVector2D = function(x, y) return { GetXY = function() return x, y end } end
env.C_Map = { GetWorldPosFromMapPos = function(_, v) local x, y = v:GetXY() return 0, env.CreateVector2D(x * 1000, y * 1000) end,
  GetMapPosFromWorldPos = function() return nil end }
ns.OM.Instances = function() return {} end
Geo.ItemCount = function(id) return bags[id] or 0 end

local function spawns(n, x) local list = {} for i = 1, n do list[i] = { x, i % 90 } end return { [12] = list } end
local function targets(id, fields)
  data.quest[id] = fields
  return ns.QuestTargets(id)
end

-- kill credit: every monster of the row counts, and its icon is read
data.npc[21] = { spawns = spawns(1, 10), minLevel = 7 }
data.npc[22] = { spawns = spawns(1, 20), minLevel = 9 }
local t = targets(1, { objectives = { [5] = { { { 21, 22 }, 23, "Credit" } } } })
check("kill credit: the monsters of the row", t[1] and t[1].kind == "kill" and #t[1].points == 2 and #t[1].mobIds == 2)
check("kill credit: level of a monster located", t[1] and t[1].mobLevel == 7)
t = targets(2, { objectives = { [5] = { { { 21, 22 }, 21, "Talk", 5 } } } })
check("kill credit with a talk icon: nothing to kill", t[1] and t[1].kind == "talk" and t[1].mobLevel == nil and #t[1].points == 2)

-- objectives done at no known place
check("reputation objective: not located", targets(3, { objectives = { [4] = { 21, 3000 } } }).missing == 1)
check("spell objective: not located", targets(4, { objectives = { [6] = { { 99 } } } }).missing == 1)
check("no objective: nothing missing", targets(5, { objectives = {} }).missing == 0)

-- drop rate: each monster weighted by its number of spawns, not by the points sampled
data.npc[24], data.npc[25] = { spawns = spawns(100, 30) }, { spawns = spawns(1, 40) }
data.item[7] = { name = "Fang", npcDrops = { 24, 25 } }
Geo.dropDB = { tablePserver = true, GetItemDroprate = function(_, npc) return { npc == 24 and 10 or 90 } end }
t = targets(6, { objectives = { [3] = { { 7 } } } })
check("drop rate weighted by the spawns", t[1] and t[1].rate and math.abs(t[1].rate - 1090 / 101) < 0.001)

-- a place to reach inside a dungeon: its entrance
t = targets(7, { triggerEnd = { "Reach the heart", { [500] = { { -1, -1 }, { -1, -1 } } } } })
check("trigger in a dungeon: its entrance, once", t[1] and #t[1].points == 1 and t[1].points[1].instance ~= nil)

-- escort that needs a source item: the item first, then the escort, none lost
Geo.IsEscort = function() return true end
local p = { c = 0, x = 0, y = 0 }
local escort = { tg = { kind = "explore", points = { p }, needsSource = true }, count = 1 }
local item = { tg = { kind = "item", points = { p }, sourceItem = 7 }, count = 1 }
local task = { id = 8, kind = "take", xp = 10, remaining = { escort, item }, targets = { start = { p }, finish = { p } } }
local ok, stops = pcall(ns.MakeStops, task, p, 10)
check("escort waiting for its item: both planned, the item first: " .. tostring(not ok and stops or ""),
  ok and stops and #stops == 4 and stops[2].r == item and stops[3].r == escort)

-- maximum reputation
local standing
env.C_Reputation = { GetFactionDataByID = function() return standing and { name = "F", currentStanding = standing } end }
local ctx = { plevel = 30, range = 8, lookahead = 5, skills = {}, skillsKnown = true }
local function offered()
  data.quest = { [1] = { name = "Q", requiredLevel = 28, questLevel = 30, zoneOrSort = 12, startedBy = { { 5 }, {}, {} },
    requiredMaxRep = { 21, 3000 } } }
  return ns.CheckAvailable(1, ctx) ~= nil
end
standing = nil
check("maximum reputation, faction unknown: offered", offered())
standing = 2999
check("below the maximum: offered", offered())
standing = 3000
check("maximum reached: not offered", not offered())

-- item starting a quest, picked up after the scan
data.quest = { [1] = { name = "Q", requiredLevel = 1, questLevel = 1, zoneOrSort = 12, startedBy = { { 5 }, {}, { 40 } } } }
env.UnitLevel = function() return 1 end
env.UnitRace = function() return "r", "r", 1 end
ns.StartScan()
check("starting item: unchanged", not (ns.StartItemsChanged and ns.StartItemsChanged()))
bags[40] = 1
check("starting item looted: seen", ns.StartItemsChanged and ns.StartItemsChanged() or false)

-- services: nothing kept from a reading that failed
local broken = true
data.npc[30] = { npcFlags = ns.K.NPC_FLAG_VENDOR, name = "V", spawns = spawns(1, 50) }
Geo.LearnedTrainers = function() if broken then error("read failed") end return {} end
env.UnitClass = function() return "Chaman", "SHAMAN" end
check("services: the failure goes up", not pcall(Geo.ServiceNpcs))
broken = false
local svc = Geo.ServiceNpcs()
check("services: read again, objects unreadable accepted", #svc.vendor == 1 and #svc.mail == 0)

-- flight nodes: not kept while the game's names cannot be read
local names = {}
env.C_TaxiMap = { GetTaxiNodesForMap = function() return names end }
ns.OM.FlightNodes = function() return {} end
local learned = { Town = true }
ns.OM.LearnedFlights = function() return learned end
Geo.NodeUsable = function() return true end
Geo.taxiNames = nil
local _, count = Geo.KnownNodes()
names = { { nodeID = 3, name = "Town" } }
local _, after = Geo.KnownNodes()
check("flight nodes read again once the game names them", count == 0 and after == 1)

-- off-hand item beside a two-hand weapon: compared with the weapon
local function offHand(link)
  env.GetInventoryItemLink = function(_, slot) return slot == 16 and "two" or nil end
  env.GetNumQuestLogRewards = function() return 1 end
  env.GetNumQuestLogChoices = function() return 0 end
  env.GetQuestLogItemLink = function() return link end
  env.GetQuestLogRewardInfo = function() return nil, nil, nil, nil, true end
  local q = ns.Analyze().turnIn[1]
  return q and q._itemReason
end
check("off hand worse than the two-hand weapon: no upgrade", offHand("orb") == nil)
check("off hand better than the two-hand weapon: upgrade", offHand("big") ~= nil)

-- a dependency's error is told
local ok16 = pcall(ns.realQGet, { Get = function() error("database broke") end }, 1, "name")
check("a QuestieDB error is told in the chat", ok16 and table.concat(log.chat, "\n"):find("database broke", 1, true) ~= nil)
finish()
