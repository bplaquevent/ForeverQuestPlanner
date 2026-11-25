-- Forever Quest Planner: debugging commands (/fqp quest, /fqp npc), in English on purpose, to be
-- reported as they are.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, AllIds, BuildScanContext, CheckAvailable, EntityPoints = ns.Geo, ns.AllIds, ns.BuildScanContext, ns.CheckAvailable, ns.EntityPoints
local IsCompleted, IsInLog, PlayerBits, Print, QDB, QGet = ns.IsCompleted, ns.IsInLog, ns.PlayerBits, ns.Print, ns.QDB, ns.QGet
local QuestDoubts = ns.QuestDoubts

-- /fqp quest <id or part of a name>: what QuestieDB says about the quests that match, and why each is
-- listed or not as available (debugging aid: in English on purpose, as /fqp npc, to be reported as it is).
local function QuestDiag(text)
  local _, race, raceID = UnitRace("player")
  local _, rbit = PlayerBits()
  Print(string.format("race %s (id %s), bit %s", tostring(race), tostring(raceID), tostring(rbit)))
  local want, id = text:lower(), tonumber(text)
  local ids = AllIds(QDB.Quest)
  if not ids then Print("QuestieDB quest list unavailable") return end
  local ctx = BuildScanContext()
  local function list(v) return type(v) == "table" and table.concat(v, ",") or tostring(v) end
  local function bits(mask) -- 1-based positions of the bits set
    local t = {}
    for i = 0, 40 do if math.floor((mask or 0) / 2 ^ i) % 2 == 1 then t[#t + 1] = i + 1 end end
    return #t > 0 and table.concat(t, ",") or "all"
  end
  -- {npcIds?, objectIds?, itemIds?} as "npc 123 Name, object 45 Name, item 67 Name".
  local function givers(t)
    if type(t) ~= "table" then return "-" end
    local out = {}
    for i, kind in ipairs({ "npc", "object", "item" }) do
      local db = ({ QDB.Npc, QDB.Object, QDB.Item })[i]
      if type(t[i]) == "table" then
        for _, gid in ipairs(t[i]) do
          out[#out + 1] = string.format("%s %s %s", kind, tostring(gid), tostring(QGet(db, gid, "name")))
        end
      end
    end
    return #out > 0 and table.concat(out, ", ") or "-"
  end
  local found = 0
  for k, v in pairs(ids) do
    local q = type(v) == "number" and v or k
    local name = QGet(QDB.Quest, q, "name")
    if name and ((id and q == id) or (not id and name:lower():find(want, 1, true))) then
      found = found + 1
      if found > 25 then Print("... more matches, refine the search") break end
      local function g(key) return QGet(QDB.Quest, q, key) end
      local okc, entry = pcall(CheckAvailable, q, ctx)
      Print(string.format("#%d %s lvl %s req %s races[%s] classes %s sort %s rep %s | pre %s/%s excl %s next %s parent %s | done %s log %s | %s",
        q, name, tostring(g("questLevel")), tostring(g("requiredLevel")), bits(g("requiredRaces")), tostring(g("requiredClasses")),
        tostring(g("zoneOrSort")), list(g("requiredMinRep")), list(g("preQuestSingle")), list(g("preQuestGroup")),
        list(g("exclusiveTo")), tostring(g("nextQuestInChain")), tostring(g("parentQuest")),
        tostring(IsCompleted(q)), tostring(IsInLog(q)), (okc and entry) and "AVAILABLE" or "hidden"))
      Print("   startedBy " .. givers(g("startedBy")) .. " | finishedBy " .. givers(g("finishedBy")))
      local doubts = QuestDoubts(q, ctx.faction)
      if doubts then Print("   doubts: " .. table.concat(doubts, " ; ")) end
    end
  end
  if found == 0 then Print("no quest matches") end
end

-- Diagnostic of the targeted NPC for the service lists (/fqp npc): QuestieDB data and why it is or is not a
-- class trainer of the player. Returns lines.
function Geo.NpcInfo()
  local guid = UnitGUID and UnitGUID("target")
  local id = guid and tonumber((select(6, strsplit("-", guid))))
  if not id then return { "no NPC targeted" } end
  local classLoc, token = UnitClass("player")
  local out = { string.format("npc %d '%s' (player class '%s' / '%s')", id, tostring(QGet(QDB.Npc, id, "name")),
    tostring(classLoc), tostring(token)) }
  out[#out + 1] = string.format("npcFlags=%s subName=%s friendlyToFaction=%s", tostring(QGet(QDB.Npc, id, "npcFlags")),
    tostring(QGet(QDB.Npc, id, "subName")), tostring(QGet(QDB.Npc, id, "friendlyToFaction")))
  out[#out + 1] = string.format("faction=%s points=%d", tostring(UnitFactionGroup("player")), #EntityPoints("npc", id))
  for _, field in ipairs({ "questStarts", "questEnds" }) do
    local list = QGet(QDB.Npc, id, field)
    local parts = {}
    for _, qid in ipairs(type(list) == "table" and list or {}) do
      if #parts >= 12 then parts[#parts + 1] = "…" break end
      parts[#parts + 1] = qid .. ":classes=" .. tostring(QGet(QDB.Quest, qid, "requiredClasses")) .. ",sort=" .. tostring(QGet(QDB.Quest, qid, "zoneOrSort"))
        .. ",'" .. tostring(QGet(QDB.Quest, qid, "name")) .. "'"
    end
    out[#out + 1] = field .. " (" .. (type(list) == "table" and #list or 0) .. "): " .. table.concat(parts, " ")
  end
  local n = 0
  for _, e in ipairs(Geo.ServiceNpcs().trainer) do if e.id == id then n = n + 1 end end
  out[#out + 1] = string.format("entries in the trainer list: %d of %d", n, #Geo.ServiceNpcs().trainer)
  return out
end

-- Shared with the next files.
ns.QuestDiag = QuestDiag
