-- Available quests: what keeps a quest from being offered, and what an offered one still needs.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local data, completed, inlog = {}, {}, {}
local env, ns = H.session(nil, { ["QuestAnalysis.lua"] = function(ns)
  ns.QGet = function(e, id, k)
    if e == "quest" then return data[id] and data[id][k] end
    if e == "item" then return "Item " .. id end
  end
  ns.IsCompleted = function(q) return completed[q] == true end
  ns.IsInLog = function(q) return inlog[q] == true end
  ns.QuestAllowed = function(q) return q ~= 7 end
  ns.QuestPrereqs = function(q) local d = data[q] or {} return d.group or {}, d.single or {} end
  ns.QuestMeta = function() return nil end
  ns.GiverText = function() return "giver", "zone" end
  ns.DBXP = function() return 100 end
  ns.IdKind = function() return nil end
  ns.AreaName = function(a) return "area" .. a end
  ns.SkillName = function(s) return "skill" .. s end
end })
ns.QDB.Quest, ns.QDB.Item, ns.QDB.Npc = "quest", "item", "npc"
ns.QDB.lib = { Enum = {} }
local items = 0
ns.Geo.ItemCount = function() return items end
env.IsSpellKnown = function() return false end

local ctx = { plevel = 30, range = 8, lookahead = 5, skills = { [186] = 60 }, skillsKnown = true, faction = "H" }
local function quest(fields, id)
  local q = { name = "Q", requiredLevel = 28, questLevel = 30, zoneOrSort = 12, startedBy = { { 5 }, {}, {} } }
  for k, v in pairs(fields or {}) do q[k] = v end
  data = { [id or 1] = q, [2] = { name = "Two" }, [3] = { name = "Three" }, [7] = { name = "Other race" } }
  return ns.CheckAvailable(id or 1, ctx)
end

local en = quest()
check("plain quest offered, nothing missing", en and en.missing == nil and en.reqLevel == 28 and en.level == 30)
check("quest level -1: the character's", quest({ questLevel = -1 }).level == 30)
check("slightly too high: kept as future", quest({ requiredLevel = 35 }).future == true)
check("beyond the lookahead", quest({ requiredLevel = 36 }) == nil)
check("above the required maximum level", quest({ requiredMaxLevel = 29 }) == nil)
check("not for the race or class", quest(nil, 7) == nil)
completed = { [1] = true }
check("turned in", quest() == nil)
completed, inlog = {}, { [1] = true }
check("in the log", quest() == nil)
inlog = {}
check("event quest", quest({ zoneOrSort = -22 }) == nil)
check("no giver", quest({ startedBy = { {}, {}, {} } }) == nil)
check("no name", quest({ name = false }) == nil)
check("unknown spell required", quest({ requiredSpell = 5 }) == nil)
check("unknown specialization spell", quest({ requiredSpecialization = 5 }) == nil)
check("parent quest not in the log", quest({ parentQuest = 2 }) == nil)
completed = { [3] = true }
check("exclusive quest done", quest({ exclusiveTo = { 3 } }) == nil)
check("next quest of the chain done", quest({ nextQuestInChain = 3 }) == nil)
completed = {}

en = quest({ group = { 2, 3 } })
check("all of a group required", en.missing and #en.missing.texts == 2 and #en.missing.quests == 2)
completed = { [3] = true }
check("one of the alternatives is enough", quest({ single = { 2, 3 } }).missing == nil)
completed = { [7] = true }
check("a prerequisite of another race does not count", quest({ single = { 7 } }).missing ~= nil)
completed = {}
en = quest({ group = { 2 }, requiredSkill = { 197, 50 }, startedBy = { { 5 }, {}, { 40 } } })
check("quest, profession and starting item missing, in this order", en.missing and #en.missing.texts == 3
  and en.missing.texts[1]:find("Two", 1, true) and en.missing.texts[2] == "skill197 50" and en.missing.texts[3]:find("Item 40", 1, true))
items = 1
check("starting item in the bags", quest({ startedBy = { { 5 }, {}, { 40 } } }).missing == nil)
finish()
