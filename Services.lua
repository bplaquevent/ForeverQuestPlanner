-- Forever Quest Planner: the NPCs of services: profession trainers, flight masters, innkeepers,
-- vendors, repairs, class trainers, banks, mailboxes; the nearest one.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, AllIds, Dist, EntityPoints, HasBit, K, L = ns.Geo, ns.AllIds, ns.Dist, ns.EntityPoints, ns.HasBit, ns.K, ns.L
local NpcFriendly, OM, PlayerFaction, PlayerPos, QDB, QGet = ns.NpcFriendly, ns.OM, ns.PlayerFaction, ns.PlayerPos, ns.QDB, ns.QGet
local TravelSpeed, Guard = ns.TravelSpeed, ns.Guard

-- QuestieDB npcFlags (vanilla 1.12 values).
K.NPC_FLAG_VENDOR, K.NPC_FLAG_TRAINER, K.NPC_FLAG_BANKER, K.NPC_FLAG_REPAIR = 4, 16, 256, 16384
K.NPC_FLAG_FLIGHT, K.NPC_FLAG_INNKEEPER = 8, 128

-- Trainers of a profession (player's faction), read once per skill: { id, name, p } per place.
function Geo.SkillTrainers(skill)
  Geo.skillTrainers = Geo.skillTrainers or {}
  if Geo.skillTrainers[skill] then return Geo.skillTrainers[skill] end
  local out = {}
  Geo.skillTrainers[skill] = out
  local stems = ns.PROFESSIONS[skill] and ns.PROFESSIONS[skill].stems
  if not (PlayerFaction() and stems) then return out end
  local npcs = QDB.Npc
  for _, id in ipairs(AllIds(npcs) or {}) do
    local flags = QGet(npcs, id, "npcFlags")
    if type(flags) == "number" and HasBit(flags, K.NPC_FLAG_TRAINER) then
      local sub = QGet(npcs, id, "subName")
      local low = type(sub) == "string" and sub:lower() or nil
      local match = false
      for _, w in ipairs(low and stems or {}) do
        if low:find(w, 1, true) then match = true break end
      end
      if match and NpcFriendly(id) then
        local name = QGet(npcs, id, "name") or ("#" .. id)
        for _, pt in ipairs(EntityPoints("npc", id)) do
          if not pt.instance then out[#out + 1] = { id = id, name = name, p = pt } end
        end
      end
    end
  end
  return out
end

-- The trainer of a profession nearest to a point (straight line), or nil.
function Geo.NearestSkillTrainer(skill, from)
  local best, bd
  for _, e in ipairs(Geo.SkillTrainers(skill)) do
    local d = Dist(e.p, from)
    if d and (not bd or d < bd) then best, bd = e, d end
  end
  return best
end

K.FM_KNOWN_RADIUS = 150 -- yards: the QuestieDB flight master NPC standing at a flight node

-- Does the text contain one of the words (Lua patterns; plain: literal text)?
local function MatchesAny(text, words, plain)
  for _, word in ipairs(words) do
    if text:find(word, 1, plain) then return true end
  end
  return false
end

-- Service NPCs of the player's faction (QuestieDB), read once per session:
-- flight masters (Geo.fm) and innkeepers (Geo.inn).
function Geo.ScanServices()
  if Geo.fm then return end
  Geo.fm, Geo.inn = {}, {}
  if not PlayerFaction() then return end
  for _, id in ipairs(AllIds(QDB.Npc) or {}) do
    local flags = QGet(QDB.Npc, id, "npcFlags")
    local isFM = type(flags) == "number" and HasBit(flags, K.NPC_FLAG_FLIGHT)
    local isInn = type(flags) == "number" and HasBit(flags, K.NPC_FLAG_INNKEEPER)
    if not (isFM or isInn) then
      local sub = QGet(QDB.Npc, id, "subName")
      if type(sub) == "string" then
        isFM = MatchesAny(sub, ns.SUBNAMES_FLIGHT_MASTER)
        isInn = MatchesAny(sub, ns.SUBNAMES_INNKEEPER)
      end
    end
    if isFM or isInn then
      if NpcFriendly(id) then
        local p = EntityPoints("npc", id)[1]
        if p and not p.instance then
          local name = QGet(QDB.Npc, id, "name")
          if isFM then Geo.fm[#Geo.fm + 1] = { id = id, name = name or L["Flight Master"], p = p } end
          if isInn then Geo.inn[#Geo.inn + 1] = { id = id, name = name or L["Innkeeper"], p = p } end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Service NPCs of the shortcuts under the Objective button: any vendor, repair NPC, class trainer
---------------------------------------------------------------------------
K.SERVICE_TIME = 60          -- seconds spent at a service NPC (selling, repairing, training)
K.SERVICE_NEAR = 12          -- candidates kept per continent, nearest in a straight line
K.SERVICE_CACHE = 20         -- seconds a nearest NPC stays valid (tooltips)
K.SERVICES = {
  { key = "vendor", icon = "Interface\\Icons\\INV_Misc_Coin_01", label = L["Vendor"], title = L["Sell and buy: "] },
  { key = "repair", icon = "Interface\\Icons\\Trade_BlackSmithing", label = L["Repair"], title = L["Repair: "] },
  { key = "trainer", icon = "Interface\\Icons\\INV_Misc_Book_11", label = L["Class trainer"], title = L["Train: "] },
  { key = "bank", icon = "Interface\\Icons\\INV_Misc_Bag_10_Blue", label = L["Bank"], title = L["Bank: "] },
  { key = "mail", icon = "Interface\\Icons\\INV_Letter_15", label = L["Mailbox"], title = L["Mailbox: "] },
}
-- Game event that ends the step of each service (the window of the NPC or mailbox opens).
K.SERVICE_EVENTS = { vendor = "MERCHANT_SHOW", repair = "MERCHANT_SHOW", trainer = "TRAINER_SHOW",
  bank = "BANKFRAME_OPENED", mail = "MAIL_SHOW" }

-- Does the NPC's sub title name the character's class? QuestieDB's translation ("Maître des paladins"
-- holds "Paladin"), or its English one ("Paladin Trainer"), read too: a translation may not hold the
-- class as the game names the character's ("Master Mage": "Maître magicien").
local function NamesClass(id, classLoc, classEn)
  local sub = QGet(QDB.Npc, id, "subName")
  if classLoc and type(sub) == "string" and sub:lower():find(classLoc:lower(), 1, true) then return true end
  if not (classEn and QDB.Npc.GetRaw) then return false end
  local ok, english = Guard(QDB.Npc.GetRaw, id, "subName") -- the base text, untranslated
  return ok and type(english) == "string"
    and (" " .. english:lower() .. " "):find("%A" .. classEn:lower() .. "%A") ~= nil
end

-- Vendors, repair NPCs, class trainers and bankers of the player's faction, and mailboxes (objects),
-- read once per session (QuestieDB). Each entry: { id, name, p }.
function Geo.ServiceNpcs()
  if Geo.svc then return Geo.svc end
  local svc = { vendor = {}, repair = {}, trainer = {}, bank = {}, mail = {} }
  local classLoc, token = UnitClass("player")
  local classEn = token and (token:sub(1, 1) .. token:sub(2):lower()) or nil
  for _, id in ipairs(PlayerFaction() and AllIds(QDB.Npc) or {}) do
    local flags = QGet(QDB.Npc, id, "npcFlags")
    if type(flags) == "number" and flags > 0 then
      local isVendor = HasBit(flags, K.NPC_FLAG_VENDOR)
      local isRepair = HasBit(flags, K.NPC_FLAG_REPAIR)
      local isBank = HasBit(flags, K.NPC_FLAG_BANKER)
      local isTrainer = HasBit(flags, K.NPC_FLAG_TRAINER) and NamesClass(id, classLoc, classEn)
      if isVendor or isRepair or isTrainer or isBank then
        if NpcFriendly(id) then
          local name = QGet(QDB.Npc, id, "name") or ("#" .. id)
          for _, p in ipairs(EntityPoints("npc", id)) do -- one entry per place it stands
            if not p.instance then
              local e = { id = id, name = name, p = p }
              if isVendor then table.insert(svc.vendor, e) end
              if isRepair then table.insert(svc.repair, e) end
              if isTrainer then table.insert(svc.trainer, e) end
              if isBank then table.insert(svc.bank, e) end
            end
          end
        end
      end
    end
  end
  -- Mailboxes: objects named "Mailbox" (no flag, neutral).
  for _, id in ipairs(AllIds(QDB.Object) or {}) do
    local name = QGet(QDB.Object, id, "name")
    if type(name) == "string" then
      local low = name:lower()
      if MatchesAny(low, ns.MAILBOX_NAMES, true) then
        for _, p in ipairs(EntityPoints("object", id)) do -- the same object stands in many places
          if not p.instance then table.insert(svc.mail, { id = id, name = name, p = p }) end
        end
      end
    end
  end
  Geo.svc = svc -- kept once filled: after an error, read again
  return svc
end

-- Nearest NPC of a service (kind: "vendor", "repair", "trainer") by travel time on the transport
-- network: the nearest ones in a straight line on the player's continent, else on each other
-- continent the ones nearest to a flight master. Returns { id, name, p, time } or nil.
function Geo.NearestService(kind, pos)
  pos = pos or PlayerPos()
  if not pos then return nil end
  local cache = Geo.svcNear and Geo.svcNear[kind]
  local now = GetTime()
  if cache and now - cache.at < K.SERVICE_CACHE and cache.pos and (Dist(pos, cache.pos) or math.huge) < 100 then
    return cache.best
  end
  local list = Geo.ServiceNpcs()[kind] or {}
  local byCont = {}
  for _, e in ipairs(list) do
    local c = e.p.c
    byCont[c] = byCont[c] or {}
    table.insert(byCont[c], e)
  end
  local refs = {}
  local function nearest(entries, ref)
    local scored = {}
    for _, e in ipairs(entries) do
      local d = Dist(e.p, ref)
      if d then scored[#scored + 1] = { e = e, d = d } end
    end
    table.sort(scored, function(a, b) return a.d < b.d end)
    return scored
  end
  local cands = {}
  local here = byCont[pos.c]
  if here then
    for i, r in ipairs(nearest(here, pos)) do
      if i > K.SERVICE_NEAR then break end
      cands[#cands + 1] = r.e
    end
  end
  if #cands == 0 then
    for c, entries in pairs(byCont) do
      local ref
      for _, fm in ipairs(Geo.FlightMasters()) do if fm.p.c == c then ref = fm.p break end end
      if ref then
        for i, r in ipairs(nearest(entries, ref)) do
          if i > 8 then break end
          cands[#cands + 1] = r.e
        end
      end
    end
  end
  local plevel = UnitLevel("player")
  local W, net = Geo.World(), Geo.Net(TravelSpeed())
  local best
  for _, e in ipairs(cands) do
    local t = ns.Solver.Travel(W, net, plevel, pos, e.p)
    if t and t < math.huge and (not best or t < best.time) then
      best = { id = e.id, name = e.name, p = e.p, time = t }
    end
  end
  Geo.svcNear = Geo.svcNear or {}
  Geo.svcNear[kind] = { at = now, pos = pos, best = best }
  return best
end

-- Flight masters the character can use: OpenMap's flight nodes (Forever's tables: faction, class),
-- each with the QuestieDB flight master NPC standing there (name, map pin) when there is one.
function Geo.FlightMasters()
  if Geo.fmNodes then return Geo.fmNodes end
  Geo.ScanServices()
  local out = {}
  for id in pairs(OM.FlightNodes()) do
    if Geo.NodeUsable(id) then
      local np = Geo.NodePoint(id)
      local npc, nd
      for _, fm in ipairs(Geo.fm or {}) do
        local d = Dist(fm.p, np)
        if d and d < K.FM_KNOWN_RADIUS and (not nd or d < nd) then npc, nd = fm, d end
      end
      if not npc then
        np = Geo.MapPoint(np)
        np.zoneName = np.zoneName or Geo.NodeName(id)
      end
      out[#out + 1] = { id = npc and npc.id or ("node" .. id), node = id, name = npc and npc.name or Geo.NodeName(id),
        p = npc and npc.p or np }
    end
  end
  Geo.fmNodes = out
  return out
end

function Geo.Innkeepers()
  Geo.ScanServices()
  return Geo.inn or {}
end
