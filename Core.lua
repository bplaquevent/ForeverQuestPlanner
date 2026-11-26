-- Forever Quest Planner (formerly Forever Quest Export)
-- Plans quests: Roadbook, around me, quest log, available quests, text export. Requires QuestieDB
-- (quest chains, classes, professions, zones, NPCs, XP) and OpenMap (flight network, boats and
-- zeppelins, zone and dungeon levels): both are read directly.
-- This file: what the others share (messages and errors, texts, formats, constants, shared state).

local ADDON_NAME, ns = ...
-- Localization (Locales/*.lua): English by default.
local L = ns.L
local PREFIX = "|cff33ccffForeverQuestPlanner|r: "

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

-- An error as told in the chat, with its trace.
local function ErrorTrace(e)
  return tostring(e) .. (debugstack and ("\n" .. debugstack(2, 3, 0)) or "")
end

local ERRORS_TOLD = 10 -- different errors told in the chat per session, at most
local told, toldCount = {}, 0

local function Told(ok, ...)
  if not ok then
    local message = tostring((...))
    if not told[message] and toldCount < ERRORS_TOLD then
      told[message], toldCount = true, toldCount + 1
      Print(L["|cffff6060Error|r (copy it to report it):\n"] .. message)
    end
  end
  return ok, ...
end

-- pcall for the addon's own functions and its dependencies': an error does not stop the caller, but it
-- is told in the chat (once per message). Plain pcall is left to the game calls expected to fail.
local function Guard(fn, ...)
  return Told(pcall(fn, ...))
end

local function Color(hex, s) return "|cff" .. hex .. tostring(s) .. "|r" end

---------------------------------------------------------------------------
-- Search (accent and case insensitive, every word must be present)
---------------------------------------------------------------------------
local ACCENTS = {
  ["à"] = "a", ["â"] = "a", ["ä"] = "a", ["á"] = "a", ["À"] = "a", ["Â"] = "a", ["Ä"] = "a",
  ["ç"] = "c", ["Ç"] = "c",
  ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e", ["É"] = "e", ["È"] = "e", ["Ê"] = "e", ["Ë"] = "e",
  ["î"] = "i", ["ï"] = "i", ["í"] = "i", ["Î"] = "i", ["Ï"] = "i",
  ["ô"] = "o", ["ö"] = "o", ["ó"] = "o", ["Ô"] = "o", ["Ö"] = "o",
  ["ù"] = "u", ["û"] = "u", ["ü"] = "u", ["ú"] = "u", ["Ù"] = "u", ["Û"] = "u", ["Ü"] = "u",
  ["œ"] = "oe", ["Œ"] = "oe", ["’"] = "'",
}

local function Normalize(s)
  s = tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:gsub("[\1-\127\194-\244][\128-\191]*", function(c) return ACCENTS[c] or c end)
  return s:lower()
end

-- Resolves WoW plural codes "|4singular:plural;" and strips color codes.
local function CleanText(text, plural)
  if not text then return nil end
  text = text:gsub("|4([^:;]*):([^;]*);", function(s, p) return plural and p or s end)
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return text
end

local function IsCompleted(id)
  return C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) or false
end

local function IsInLog(id)
  if C_QuestLog.GetLogIndexForQuestID then
    return C_QuestLog.GetLogIndexForQuestID(id) ~= nil
  end
  return C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(id) or false
end

-- Bit test without the bit library (Forever race masks exceed 32 bits).
local function HasBit(mask, bitValue)
  return math.floor(mask / bitValue) % 2 == 1
end

local function TrivialRange()
  if UnitQuestTrivialLevelRange then
    local ok, r = pcall(UnitQuestTrivialLevelRange, "player")
    if ok and r then return r end
  end
  if GetQuestGreenRange then
    local ok, r = pcall(GetQuestGreenRange)
    if ok and r then return r end
  end
  return 8
end

---------------------------------------------------------------------------
-- Dependencies: QuestieDB and OpenMap (required, checked by InitDeps at login)
---------------------------------------------------------------------------
local State = {} -- mutable state shared by the addon files (window, tabs, Roadbook horizon)
local K = {} -- tuning constants (avoids the 200 local variables limit)
-- Transport mode names (internal ids -> displayed text).
K.MODE_NAME = { flight = L["flight"], zeppelin = L["zeppelin"], boat = L["boat"], airship = L["airship"] }
-- Kinds of quests done in a group (QuestKind): their name, as a category title and as a note.
K.KIND_LABEL = { dungeon = L["Dungeon"], raid = L["Raid"], pvp = L["PvP"] }
K.KIND_TITLE = { dungeon = L["Dungeon: "], raid = L["Raid: "], pvp = L["PvP: "] }
K.KIND_NOTE = { dungeon = L["dungeon: "], raid = L["raid: "], pvp = L["PvP: "] }
K.MAX_LEVEL_GAP = 2 -- difficulty: quest level at most this many levels above (or below) yours (+1 for quests already in the log)
K.MAX_ELITE_GAP = -2 -- same for elite quests, usually too hard alone at your level
-- Technical search bound: quests whose required level is up to this many levels above yours are
-- examined, but a quest only enters the Roadbook from the step where the expected level reaches its
-- required level (checked by the solver's evaluation).
K.LOOKAHEAD_LEVELS = 5
K.MAX_QUESTS = 40 -- quest log size on the Forever server
K.DESC_SEP = " · " -- between the informations of one line (quest descriptions, UI/QuestDesc.lua)


-- QuestieDB codes: objective NPC icons meaning "talk to", creature ranks (1 elite, 2 rare elite, 3 boss,
-- 4 rare) of the monsters that make a quest elite, and of the NPCs met once (to assassinate).
K.TALK_ICONS = { [3] = true, [5] = true, [17] = true }
K.ELITE_RANKS = { [1] = true, [2] = true, [3] = true }
K.UNIQUE_RANKS = { [2] = true, [3] = true, [4] = true }

local function FormatTime(sec)
  sec = math.floor(sec + 0.5)
  if sec < 60 then return sec .. L[" s"] end
  if sec < 3600 then return math.floor(sec / 60 + 0.5) .. L[" min"] end
  return string.format("%d h %02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

local function FormatNumber(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^ ", ""))
end

-- Money: interest threshold (level² × 2 copper) and display in g/s/c.
local function MoneyThreshold(plevel)
  return (plevel or 1) * (plevel or 1) * 2
end

-- An amount in coins, as plain text ("1g 2s 3c"): the coins that are not zero.
local function CoinText(copper)
  local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. L["g"] end
  if sv > 0 then parts[#parts + 1] = sv .. L["s"] end
  if c > 0 then parts[#parts + 1] = c .. L["c"] end
  return table.concat(parts, " ")
end

local function MoneyText(copper)
  if not copper or copper <= 0 then return nil end
  if GetCoinTextureString then
    local ok, txt = pcall(GetCoinTextureString, copper)
    if ok and txt then return txt end
  end
  return CoinText(copper)
end

-- Shared with the next files.
ns.CleanText, ns.CoinText, ns.Color, ns.ErrorTrace = CleanText, CoinText, Color, ErrorTrace
ns.FormatNumber, ns.FormatTime, ns.Guard, ns.HasBit = FormatNumber, FormatTime, Guard, HasBit
ns.IsCompleted, ns.IsInLog, ns.K, ns.L, ns.MoneyText = IsCompleted, IsInLog, K, L, MoneyText
ns.MoneyThreshold, ns.Normalize, ns.Print, ns.State = MoneyThreshold, Normalize, Print, State
ns.TrivialRange = TrivialRange
