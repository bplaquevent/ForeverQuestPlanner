-- The character's professions are read one by one by their skill line, without expanding the
-- categories of the game's skill list: the player's folding stays.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()

local lines, expanded = 4, 0
local learned = { [171] = { name = "Alchimie", rank = 175 }, [185] = { name = "Cuisine", rank = 1 } }
env.GetTime = function() return 0 end
env.C_SkillInfo = {
  GetNumSkillLines = function() return lines end,
  -- every category collapsed: only the headers are listed
  GetSkillLineInfo = function() return { isHeader = true, isCollapsed = true } end,
  ExpandSkillHeader = function() expanded = expanded + 1 end,
  GetSkillLineInfoByID = function(id) return learned[id] end,
}
local skills, names, known = ns.PlayerSkills(true)
check("no category expanded", expanded == 0)
check("professions of collapsed categories read, with their rank", skills[171] == 175 and skills[185] == 1)
check("their names", names["Alchimie"] and names["Cuisine"])
check("nothing for a profession not learned", skills[186] == nil)
check("read", known == true)
lines = 0
skills, names, known = ns.PlayerSkills(true)
check("skill list not loaded yet: not read", known == false)
finish()
