-- Profession level needed to turn in: QuestieDB's requiredSkill and the objective lines of the quest
-- log, their progress counter apart. The other quest texts name quantities, not levels.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local skill, required
local _, ns = H.session(nil, {
  ["QuestData.lua"] = function(ns)
    ns.PlayerSkills = function() return { [skill] = 10 }, nil, true end
    ns.QGet = function(_, _, field)
      if field == "requiredSkill" then return required and { skill, required } end
      if field == "objectivesText" then return { "Collect 40 herbalism supplies." } end
    end
    ns.QDB = { Quest = { GetRaw = function() return { "Collect 40 herbalism supplies." } end } }
    ns.SkillName = function() return "Herboristerie" end
  end,
})
for id, p in pairs(ns.PROFESSIONS) do if p.en == "herbalism" then skill = id end end
local function need(lines)
  local q = lines and { objectivesText = "Collect 40 herbalism supplies.", description = "Bring 50 herbalism bags.", objectives = {} }
  for _, l in ipairs(lines or {}) do q.objectives[#q.objectives + 1] = { text = l } end
  local n = ns.Geo.SkillNeed(1, q)
  return n and n.need
end

check("quest texts: not read", need({}) == nil and need(nil) == nil)
check("a quantity before its counter is not a level", need({ "Herbalism supplies: 0/40" }) == nil)
check("a counter first is not a level", need({ "0/40 herbalism supplies" }) == nil)
check("objective line naming the level", need({ "Reach 20 in herbalism" }) == 20)
check("same line with a counter", need({ "Reach 20 in herbalism: 0/1" }) == 20)
check("several lines: the highest", need({ "Reach 15 in herbalism", "Reach 20 in herbalism" }) == 20)
check("a profession inside another word", ns.Geo.SkillFromText("Finish examining 20 relics") == nil)
check("the word further on", ns.Geo.SkillFromText("examining done, mining 20") ~= nil)
check("between French quotes and non-breaking spaces", ns.Geo.SkillFromText("Atteindre 20 en \194\171\194\160herbalism\194\160\194\187") == skill)
required = 30
check("QuestieDB asks for more", need({ "Reach 20 in herbalism" }) == 30 and need(nil) == 30)
required = 12
check("the log asks for more", need({ "Reach 20 in herbalism" }) == 20)
finish()
