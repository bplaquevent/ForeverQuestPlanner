-- Forever Quest Planner: how a quest is written in every tab: icons of its states, badges, description
-- lines and colours, follow-ups; state filters.
-- The names shared between files are published in ns at the end of each file (load order: .toc).

local ADDON_NAME, ns = ...
local Geo, ChainInfo, ChainText, Color, FormatNumber = ns.Geo, ns.ChainInfo, ns.ChainText, ns.Color, ns.FormatNumber
local IsClassMeta, IsCompleted, IsInLog, IsPinned = ns.IsClassMeta, ns.IsCompleted, ns.IsInLog, ns.IsPinned
local IsQuestComplete, IsWatched, K, L, PinIcon, QuestMeta = ns.IsQuestComplete, ns.IsWatched, ns.K, ns.L, ns.PinIcon, ns.QuestMeta

-- Quest state icons (textures available in every client).
local ICON = {
  turnin = "|TInterface\\GossipFrame\\ActiveQuestIcon:16:16|t",     -- yellow ?: to turn in
  inprogress = "|TInterface\\GossipFrame\\IncompleteQuestIcon:16:16|t", -- gray ?: in progress
  available = "|TInterface\\GossipFrame\\AvailableQuestIcon:16:16|t",  -- yellow !: to pick up
  watched = "|TInterface\\Buttons\\UI-CheckBox-Check:16:16|t",         -- check mark: tracked
  custom = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:16:16|t", -- yellow star: custom Roadbook
  abandon = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:16:16|t",       -- red cross: to abandon
  done = "|TInterface\\RaidFrame\\ReadyCheck-Ready:16:16|t",            -- green check: turned in (as the steps done)
}

---------------------------------------------------------------------------
-- Quest line shown the same way in every tab: title, level, elite, types
---------------------------------------------------------------------------
K.QUEST_TYPE_LABEL = {
  escort = L["Escort"], assassination = L["Assassination"], slaying = L["Slaying"], collect = L["Collect"],
  gathering = L["Gathering"], interaction = L["Interaction"], exploration = L["Exploration"], talk = L["Talk"],
  reputation = L["Reputation"], delivery = L["Delivery"],
}

-- Quest level, colored like in the game's quest log (gray, green, yellow, orange, red).
function Geo.LevelBadge(level)
  if not (level and level > 0) then return "" end
  local hex
  if GetQuestDifficultyColor then
    local ok, c = pcall(GetQuestDifficultyColor, level)
    if ok and type(c) == "table" and c.r then
      hex = string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
  end
  if not hex then
    local gap = level - (UnitLevel("player") or level)
    hex = (gap >= 5 and "ff2020") or (gap >= 3 and "ff8040") or (gap >= -2 and "ffff00") or "40c040"
  end
  return Color(hex, "[" .. level .. "]")
end

-- Quest types of a quest, colored: "Escort · Collect" ("" if none, at most 3).
function Geo.QuestTypesText(id)
  local types, parts = Geo.QuestTypes(id), {}
  for i = 1, math.min(#types, 3) do parts[#parts + 1] = Color("80c0ff", K.QUEST_TYPE_LABEL[types[i]]) end
  return table.concat(parts, Color("80c0ff", K.DESC_SEP))
end

-- "  [35] Elite · Dungeon · Escort · Collect": o = { id, level, tag (game tag, log quests),
-- isClass, isProf, dungeon, noTypes (types left out, shown apart with Geo.QuestTypesText) }.
function Geo.QuestBadges(o)
  local id = o.id
  local tag = o.tag
  if tag == nil and id then tag = Geo.LogTag(id) end
  local parts = {}
  if id and Geo.IsFollowUp(id) then parts[#parts + 1] = Color(K.DESC.chain, L["Follow-up"]) end
  if id and Geo.IsEliteQuest(id) then parts[#parts + 1] = Color("ff8040", L["Elite"]) end
  if tag and tag ~= "" and not (id and Geo.IsGameElite(id)) then parts[#parts + 1] = tag -- "Elite": said above
  elseif o.dungeon then parts[#parts + 1] = Geo.WithLevel(Color("80c0ff", L["Dungeon"]), o.dungeon) end
  local isClass = o.isClass
  if isClass == nil and id then
    local m = QuestMeta(id)
    isClass = m and IsClassMeta(m) or false
  end
  if isClass then parts[#parts + 1] = L["Class"] end
  if o.isProf then parts[#parts + 1] = L["Profession"] end
  if o.doubts then parts[#parts + 1] = Color(K.DESC.warn, L["Doubtful"]) end
  local types = o.noTypes and {} or Geo.QuestTypes(id)
  for i = 1, math.min(#types, 3) do parts[#parts + 1] = K.QUEST_TYPE_LABEL[types[i]] end
  local badge = Geo.LevelBadge(o.level)
  -- each part in square brackets, coloured on its own (colour codes do not nest; some parts carry their own colours)
  local blue = Color("80c0ff", "[")
  for i, p in ipairs(parts) do
    if not p:find("^|c") then p = Color("80c0ff", p) end
    parts[i] = blue .. p .. Color("80c0ff", "]")
  end
  return "  " .. badge .. (#parts > 0 and (" " .. table.concat(parts, " ")) or "")
end

-- Quest descriptions: the same layout and colors in every tab and on the Objective button.
--   line 1: state or step icons, [kind], white title, badges (colored level, elite, types);
--   next lines, indented, one subject each: what to do and where (light gray), figures (XP and
--   follow-ups in color, the rest in gray), warnings (orange), blockers (red), rewards.
--   Informations on one line are separated by " · ".
K.DESC = { action = "bbbbbb", meta = "888888", xp = "80c0ff", warn = "ffb060", bad = "ff6060",
  good = "40ff40", chain = "c080ff" }
K.DESC_LINE = "\n       "
K.DESC_SEP = " · "

-- White title + badges (o: options of Geo.QuestBadges; none for a step that is not a quest).
function Geo.QuestTitle(title, o)
  return Color("ffffff", title or "?") .. ((o and o.id) and Geo.QuestBadges(o) or "")
end

-- Next description line: the non-empty parts (already colored), separated by a gray " · ".
function Geo.DescLine(...)
  local kept = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if p and p ~= "" then kept[#kept + 1] = p end
  end
  if #kept == 0 then return "" end
  return K.DESC_LINE .. table.concat(kept, Color(K.DESC.meta, K.DESC_SEP))
end

-- Warning line of a quest whose QuestieDB data contradict each other (ns.QuestDoubts), or "".
function Geo.DoubtLine(doubts)
  if not doubts then return "" end
  return Geo.DescLine(Color(K.DESC.warn, L["QuestieDB data in doubt: "] .. table.concat(doubts, " ; ")))
end

-- XP of a quest or a step: "+1 200 XP" (exact) or "~1 200 XP" (estimate).
function Geo.XPText(xp, approx, suffix)
  if not (xp and xp > 0) then return nil end
  return Color(K.DESC.xp, (approx and "~" or "+") .. FormatNumber(xp) .. " XP" .. (suffix or ""))
end

local function IconLegend(withAvailable)
  return Color("aaaaaa", ICON.turnin .. L[" to turn in   "] .. ICON.inprogress .. L[" in progress   "] .. ICON.watched ..
    L[" tracked   "] .. PinIcon() .. L["pin"] .. (withAvailable and ("   " .. ICON.available .. L[" to pick up"]) or ""))
end

-- Quest states (for filters): turnin, inprogress, watched, pinned, available.
local function QuestStates(questId)
  local st = {}
  if not questId then return st end
  if IsInLog(questId) then
    if IsQuestComplete(questId) then st.turnin = true else st.inprogress = true end
    if IsWatched(questId) then st.watched = true end
  else
    st.available = true
  end
  if IsPinned(questId) then st.pinned = true end
  if Geo.InCustom(questId) then st.custom = true end
  return st
end

-- State icons in front of a quest title.
local function StateIcons(questId)
  if not questId then return "" end
  local st, icons = QuestStates(questId), {}
  local inLog = st.turnin or st.inprogress
  if inLog then
    icons[#icons + 1] = st.turnin and ICON.turnin or ICON.inprogress
  else
    icons[#icons + 1] = IsCompleted(questId) and ICON.done or ICON.available
  end
  if st.watched then icons[#icons + 1] = ICON.watched end
  if st.pinned then icons[#icons + 1] = PinIcon() end
  if st.custom then icons[#icons + 1] = ICON.custom end
  if inLog and Geo.ToAbandon(questId) then icons[#icons + 1] = ICON.abandon end -- last: before "[To abandon]"
  return table.concat(icons, "") .. " "
end

-- State filters: none checked = everything; otherwise the quest must have at least one checked state.
local journalStates, nearStates = {}, {}
local function PassStates(questId, selected, toDrop)
  if not next(selected) then return true end
  local st = QuestStates(questId)
  if toDrop then st.abandon = true end
  for key in pairs(selected) do
    if st[key] then return true end
  end
  return false
end

-- Line "follow-up: n quest(s) up to level X" (nothing for a quest without follow-ups).
function Geo.ChainTextLine(id)
  if not id then return "" end
  local text = ChainText(ChainInfo(id, UnitLevel("player"), 0))
  return text and Geo.DescLine(Color(K.DESC.chain, text)) or ""
end

K.MAX_CHAIN_LINES = 10
K.CHAIN_INDENT = K.DESC_LINE .. "   "
-- Lines under a quest: its follow-ups (each with its possible rewards; 2nd value: true when some carry item links) as an indented block (title, level, level required, XP), muted
-- as they cannot be picked up yet. Beyond K.MAX_CHAIN_LINES, the last ones share a single line.
function Geo.ChainLines(id)
  local chain = Geo.ChainQuests(id)
  if #chain == 0 then return "" end
  local D, plevel = K.DESC, UnitLevel("player")
  local sep = Color(D.meta, K.DESC_SEP)
  local function title(c) return Color(D.chain, (c.title or "?") .. (c.level and (" [" .. c.level .. "]") or "")) end
  local text, links = K.DESC_LINE .. Color(D.chain, L["Follow-up:"]), false
  for i, c in ipairs(chain) do
    if i >= K.MAX_CHAIN_LINES and #chain > K.MAX_CHAIN_LINES then
      local rest = {}
      for j = i, #chain do rest[#rest + 1] = title(chain[j]) end
      text = text .. K.CHAIN_INDENT .. table.concat(rest, sep)
      break
    end
    local parts = { title(c) }
    if c.reqLevel > plevel then parts[#parts + 1] = Color(D.meta, L["requires level "] .. c.reqLevel) end
    local xp = Geo.XPText(ns.DBXP(c.id, plevel), true)
    if xp then parts[#parts + 1] = xp end
    text = text .. K.CHAIN_INDENT .. StateIcons(c.id) .. table.concat(parts, sep)
    local rewards = Geo.RewardLine(c.id)
    if rewards then
      text = text .. K.CHAIN_INDENT .. "   " .. rewards
      links = true
    end
  end
  return text, links
end

-- Shared with the next files.
ns.ICON, ns.PassStates, ns.StateIcons, ns.journalStates, ns.nearStates = ICON, PassStates, StateIcons, journalStates, nearStates
