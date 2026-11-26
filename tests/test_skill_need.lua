-- Profession level needed to turn in: the highest of QuestieDB's value and of every quest text.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local skill
local _, ns = H.session(nil, {
  ["QuestData.lua"] = function(ns)
    ns.PlayerSkills = function() return { [skill] = 10 }, nil, true end
    ns.QGet = function(_, _, field) if field == "requiredSkill" then return { skill, 1 } end end
    ns.QDB = { Quest = { GetRaw = function() return { "Show your herbalism: 5 herbs." } end } }
    ns.SkillName = function() return "Herboristerie" end
  end,
})
for id, p in pairs(ns.PROFESSIONS) do if p.en == "herbalism" then skill = id end end
local n = ns.Geo.SkillNeed(1, { description = "Reach 20 in herbalism." })
check("a later text asks for more", n and n.need == 20)
finish()
