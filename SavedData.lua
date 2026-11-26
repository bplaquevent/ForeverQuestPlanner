-- Forever Quest Planner: the saved data of the characters and what the addon learned in game, the
-- versions of their formats and their erasing.

local ADDON_NAME, ns = ...

-- Formats of the data the addon saves, apart: a number is raised by every change that makes the data
-- it covers unusable (a field renamed, moved, or of another type or meaning; not a new field that may
-- be absent). DATA_VERSION: the characters' data (Settings()) and the captures (quest logs, test
-- bench). LEARNED_VERSION: what the addon learned in game (LearnedData()).
local DATA_VERSION = 1
local LEARNED_VERSION = 1

local function CharKey()
  local name, realm = UnitFullName("player")
  realm = realm or (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
  return (name or "?") .. "-" .. (realm or "?")
end

-- What FQP saves: each character's data, ForeverQuestPlannerSettings.chars[CharKey()] (Settings()),
-- and apart from it, to be kept longer, what it learned in game (LearnedData()).

-- A zone pass as saved: its place and its two zones (a damaged entry would break every walk).
local function ValidPass(ps)
  return type(ps) == "table" and type(ps.a) == "number" and type(ps.b) == "number" and type(ps.c) == "number"
    and type(ps.x) == "number" and type(ps.y) == "number"
end

local function KeepValidPasses(list)
  local out = {}
  for _, ps in ipairs(type(list) == "table" and list or {}) do
    if ValidPass(ps) then out[#out + 1] = ps end
  end
  return out
end

-- The root of the saved settings, created when nothing was saved.
local function SettingsRoot()
  if type(ForeverQuestPlannerSettings) ~= "table" then ForeverQuestPlannerSettings = {} end
  return ForeverQuestPlannerSettings
end

local checkedLearned -- the learned data checked this session

-- Learned in game. True for every character: zone passes walked ({ c, x, y, a, b, n }), the places
-- really reached by the teleport spells (spell -> point). True for one character only:
-- chars[CharKey()], read through LearnedChar().
local function LearnedData()
  local root = SettingsRoot()
  root.learned = type(root.learned) == "table" and root.learned or {}
  local learned = root.learned
  if checkedLearned ~= learned then
    learned.passes = KeepValidPasses(learned.passes)
    learned.teleportArrivals = type(learned.teleportArrivals) == "table" and learned.teleportArrivals or {}
    learned.chars = type(learned.chars) == "table" and learned.chars or {}
    checkedLearned = learned
  end
  return learned
end

-- What was learned for the current character alone: { guid, mountSpeed, bind }. Saved under its name
-- with the game's identifier of the character: another character of the same name (one deleted, then
-- made again) starts afresh. Without the identifier, nothing is read nor kept.
local function LearnedChar()
  local guid = UnitGUID and UnitGUID("player")
  if not guid then return {} end
  local chars, key = LearnedData().chars, CharKey()
  local rec = chars[key]
  if type(rec) ~= "table" or rec.guid ~= guid then
    rec = { guid = guid }
    chars[key] = rec
  end
  return rec
end

local settingsCache = {}
local function Settings()
  local root = SettingsRoot()
  if settingsCache.root == root then return settingsCache.st end
  root.chars = root.chars or {}
  local key = CharKey()
  local st = root.chars[key]
  if not st then
    st = {}
    root.chars[key] = st
  end
  -- Cached once the character is fully known (name and realm).
  if not (key:find("^%?%-") or key:find("%-%?$")) then settingsCache.root, settingsCache.st = root, st end
  return st
end

-- Erases, for every character, their data and the captures (characters), what the addon learned in
-- game (learned), or both; what is not erased is kept as it is.
local function EraseData(characters, learnedToo)
  local old = SettingsRoot()
  local root = { dataVersion = DATA_VERSION, learnedVersion = LEARNED_VERSION }
  if not characters then root.chars = old.chars end
  if not learnedToo then root.learned = old.learned end
  ForeverQuestPlannerSettings = root -- a new table: what was cached from the former one is read again
  if characters then ForeverQuestPlannerDB, ForeverQuestPlannerBench = nil, nil end
end

-- At login, before anything reads the saved data: data saved in another format is erased (the code
-- only knows the current one). Returns whether characters' data and whether learned data was erased
-- (false when there was none to lose).
local function CheckDataVersion()
  local root = SettingsRoot()
  local oldCharacters, oldLearned = root.dataVersion ~= DATA_VERSION, root.learnedVersion ~= LEARNED_VERSION
  if not (oldCharacters or oldLearned) then return false, false end
  local lostCharacters = oldCharacters
    and (root.chars ~= nil or ForeverQuestPlannerDB ~= nil or ForeverQuestPlannerBench ~= nil)
  local lostLearned = oldLearned and root.learned ~= nil
  EraseData(oldCharacters, oldLearned)
  return lostCharacters, lostLearned
end

-- Shared with the next files.
ns.CharKey, ns.CheckDataVersion, ns.EraseData, ns.LearnedChar = CharKey, CheckDataVersion, EraseData, LearnedChar
ns.LearnedData, ns.Settings = LearnedData, Settings
