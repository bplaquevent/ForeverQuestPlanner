-- Forever Quest Planner: fixed facts of the game (Classic rules), not read from any source.

local ADDON_NAME, ns = ...
local L = ns.L

-- Professions, by skill line id: name = shown to the player; en = name looked for in the quest texts;
-- stems = words of a trainer's sub title (QuestieDB subName, English and French); recipe = item
-- subclass of its recipes (item class 9). An id with no name is only known as a profession.
ns.PROFESSIONS = {
  [164] = { name = L["Blacksmithing"], en = "blacksmithing", stems = { "blacksmith", "forgeron", "forge" }, recipe = 4 },
  [165] = { name = L["Leatherworking"], en = "leatherworking", stems = { "leatherwork", "travail du cuir" }, recipe = 1 },
  [171] = { name = L["Alchemy"], en = "alchemy", stems = { "alchem", "alchim" }, recipe = 6 },
  [182] = { name = L["Herbalism"], en = "herbalism", stems = { "herbalis", "herboris" } },
  [185] = { name = L["Cooking"], en = "cooking", stems = { "cook", "cuisin" }, recipe = 5 },
  [186] = { name = L["Mining"], en = "mining", stems = { "mining", "mineur", "minage" } },
  [197] = { name = L["Tailoring"], en = "tailoring", stems = { "tailor", "couture", "tailleur" }, recipe = 2 },
  [202] = { name = L["Engineering"], en = "engineering", stems = { "engineer", "ingénieur", "ingenieur" }, recipe = 3 },
  [333] = { name = L["Enchanting"], en = "enchanting", stems = { "enchant" }, recipe = 8 },
  [356] = { name = L["Fishing"], en = "fishing", stems = { "fishing", "fisher", "pêch", "peche" }, recipe = 9 },
  [393] = { name = L["Skinning"], en = "skinning", stems = { "skinning", "dépeçage", "depecage" } },
  [129] = { name = L["First Aid"], en = "first aid", stems = { "first aid", "premiers soins" }, recipe = 7 },
  [762] = { name = L["Riding"] },
  [755] = {}, [773] = {}, [794] = {},
}

-- XP to go from each level to the next one (Classic).
ns.XP_TABLE = { 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400,
  16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
  50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500,
  123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800 }

-- Armor (subclasses) and weapons usable per class (Classic). Mail / plate from level 40.
ns.ARMOR = {
  WARRIOR = { [1] = true, [2] = true, [3] = true, [4] = 40, [6] = true },
  PALADIN = { [1] = true, [2] = true, [3] = true, [4] = 40, [6] = true },
  HUNTER = { [1] = true, [2] = true, [3] = 40 },
  SHAMAN = { [1] = true, [2] = true, [3] = 40, [6] = true },
  ROGUE = { [1] = true, [2] = true },
  DRUID = { [1] = true, [2] = true },
  PRIEST = { [1] = true }, MAGE = { [1] = true }, WARLOCK = { [1] = true },
}

ns.WEAPONS = {
  WARRIOR = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true, [16] = true, [18] = true },
  PALADIN = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true },
  HUNTER = { [0] = true, [1] = true, [2] = true, [3] = true, [6] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true, [16] = true, [18] = true },
  ROGUE = { [2] = true, [3] = true, [4] = true, [7] = true, [13] = true, [15] = true, [16] = true, [18] = true },
  SHAMAN = { [0] = true, [1] = true, [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
  DRUID = { [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
  PRIEST = { [4] = true, [10] = true, [15] = true, [19] = true },
  MAGE = { [7] = true, [10] = true, [15] = true, [19] = true },
  WARLOCK = { [7] = true, [10] = true, [15] = true, [19] = true },
}

-- Main stats per class and talent tree (Classic tab order).
ns.SPEC_STATS = {
  SHAMAN = { { "INTELLECT" }, { "AGILITY", "STRENGTH" }, { "INTELLECT", "SPIRIT" } },
  PALADIN = { { "INTELLECT", "SPIRIT" }, { "STAMINA", "STRENGTH" }, { "STRENGTH", "AGILITY" } },
  DRUID = { { "INTELLECT" }, { "AGILITY", "STRENGTH" }, { "INTELLECT", "SPIRIT" } },
  WARRIOR = { { "STRENGTH", "AGILITY" }, { "STRENGTH", "AGILITY" }, { "STAMINA", "STRENGTH" } },
  HUNTER = { { "AGILITY" }, { "AGILITY" }, { "AGILITY" } },
  ROGUE = { { "AGILITY" }, { "AGILITY" }, { "AGILITY" } },
  PRIEST = { { "INTELLECT", "SPIRIT" }, { "INTELLECT", "SPIRIT" }, { "INTELLECT" } },
  MAGE = { { "INTELLECT" }, { "INTELLECT" }, { "INTELLECT" } },
  WARLOCK = { { "INTELLECT", "STAMINA" }, { "INTELLECT", "STAMINA" }, { "INTELLECT", "STAMINA" } },
}
