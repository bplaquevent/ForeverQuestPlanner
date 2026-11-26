-- Class trainers of the service shortcut: the NPCs whose QuestieDB sub title names the character's
-- class, in the game's language or in English. Talking to another trainer (weapon master…) changes
-- nothing.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()

local TRAINER = 16
local npcs = {
  [1] = { sub = "Maître des paladins", en = "Paladin Trainer" },
  [2] = { sub = "Maître d'armes", en = "Weapon Master" },
  [3] = { sub = "Maître magicien", en = "Master Mage" },
  [4] = { sub = "Maître des chamans", en = "Shaman Trainer" },
  [5] = { sub = "Maître des familiers", en = "Pet Trainer" },
  [6] = { en = nil },
  [7] = { sub = "Réparateur de dégâts", en = "Damage Repairer" },
}
local saved = { ForeverQuestPlannerSettings = nil }
local env, ns, log = H.session(saved, { ["QuestData.lua"] = function(ns)
  ns.QGet = function(_, id, key)
    local n = npcs[id]
    if not n then return nil end
    if key == "npcFlags" then return TRAINER end
    if key == "subName" then return n.sub end
    if key == "name" then return "npc" .. id end
  end
  ns.QDB.Npc = { GetRaw = function(id, key) return key == "subName" and npcs[id] and npcs[id].en or nil end }
  ns.QDB.Object = "object"
  ns.AllIds = function(e) if e == ns.QDB.Npc then return { 1, 2, 3, 4, 5, 6, 7 } end return {} end
  ns.PlayerFaction = function() return "A" end
  ns.NpcFriendly = function() return true end
end, ["Geo.lua"] = function(ns)
  ns.EntityPoints = function() return { { c = 0, x = 0, y = 0 } } end
end })
local Geo = ns.Geo

local function trainers(classLoc, token)
  env.UnitClass = function() return classLoc, token end
  Geo.svc = nil
  local ids = {}
  for _, e in ipairs(Geo.ServiceNpcs().trainer) do ids[#ids + 1] = e.id end
  table.sort(ids)
  return table.concat(ids, " ")
end

check("paladin: its trainer only, no weapon master", trainers("Paladin", "PALADIN") == "1")
check("class name unlike the game's translation: the English sub title", trainers("Mage", "MAGE") == "3")
check("class name the translation does not hold: the English sub title", trainers("Chamane", "SHAMAN") == "4")
check("the English word alone, not inside another one", not trainers("Mage", "MAGE"):find("7"))

-- a trainer window opened on a weapon master: it never becomes a class trainer
env.UnitClass = function() return "Paladin", "PALADIN" end
env.UnitGUID = function(unit) if unit == "npc" then return "Creature-0-1-0-1-2-000" end return "Player-1-AAAA" end
env.strsplit = function(sep, s)
  local parts = {}
  for part in (s .. sep):gmatch("(.-)%" .. sep) do parts[#parts + 1] = part end
  return unpack(parts)
end
env.IsTradeskillTrainer = function() return false end
ns.CP.OnGameEvent = function() end
Geo.svc = nil
log.fire("TRAINER_SHOW")
check("after talking to a weapon master: still not a class trainer", trainers("Paladin", "PALADIN") == "1")

-- what an earlier version had learned is no longer read
ns.LearnedData().classTrainers = { PALADIN = { [2] = true } }
check("a trainer learned by mistake before: ignored", trainers("Paladin", "PALADIN") == "1")
finish()
