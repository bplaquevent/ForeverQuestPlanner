-- Forever Quest Planner: what the data we read lacks or gets wrong, completed here.
-- Rule: the game code (Geo.lua, Route.lua...) never singles out a line, a zone or a quest; it reads data
-- already completed by one function per kind of data (example: Geo.Transports), which takes the
-- source's own value first and falls back on these tables. When a source gives the value itself,
-- delete its row: no code changes.

local ADDON_NAME, ns = ...

-- Faction of a boat / zeppelin / airship line of OpenMap that has no `faction` field: by default, what
-- OpenMap's Map/Routes.lua assumes of its kind (zeppelins are the Horde's, boats the Alliance's,
-- airships everyone's). "Neutral" = everyone.
ns.TRANSPORT_KIND_FACTION = { zeppelin = "Horde", boat = "Alliance", airship = "Neutral" }

-- Lines by name (OpenMap's route name) whose faction differs from their kind's:
ns.TRANSPORT_SUPPLEMENT = {
  -- the goblins' lines: everyone's (OpenMap's Map/Routes.lua NEUTRAL)
  ["Booty Bay - Ratchet"] = { faction = "Neutral" },
  ["Steamwheedle Port - Powderfuse Port"] = { faction = "Neutral" },
  -- Zephras Isle is neutral, but each airship line is one faction's (warcraft.wiki.gg/wiki/Zephras_Isle,
  -- "Getting there"): Dalaran's the Alliance's, Mulgore's the Horde's
  ["Alterac Mountains - Zephras Isle"] = { faction = "Alliance" },
  ["Mulgore - Zephras Isle"] = { faction = "Horde" },
}

-- Quest categories of QuestieDB (its "sort": negative = a category, positive = an area), by kind of quest.
ns.SORT_CLASS = { [-395] = true, [-372] = true, [-263] = true, [-262] = true, [-261] = true, [-162] = true,
  [-161] = true, [-141] = true, [-82] = true, [-81] = true, [-61] = true }
-- Profession quest categories. Forever: -666 = "Camping" ("Camping 101: …"), 16941 = "Crafting"
-- (a QuestieDB area grouping the "Craftsman's Writ" quests, no actual place).
ns.SORT_PROFESSION = { [-398] = true, [-377] = true, [-373] = true, [-371] = true, [-324] = true, [-304] = true,
  [-264] = true, [-201] = true, [-182] = true, [-181] = true, [-121] = true, [-101] = true, [-24] = true,
  [-666] = true, [16941] = true }
ns.SORT_EVENT = { [-1000] = true, [-404] = true, [-402] = true, [-378] = true, [-376] = true, [-375] = true,
  [-374] = true, [-370] = true, [-369] = true, [-366] = true, [-364] = true, [-41] = true, [-22] = true,
  [-21] = true, [-368] = true, [-365] = true, [-241] = true }
-- Battleground quest areas: Alterac Valley, Warsong Gulch, Arathi Basin, Darkspear Islands (Forever).
ns.SORT_PVP = { [-25] = true, [2597] = true, [3277] = true, [3358] = true, [16606] = true }

-- Quest log headers that are professions' (the client's languages), besides the names of the character's skills.
ns.PROFESSION_HEADERS = { ["Artisanat"] = true, ["Métiers"] = true, ["Professions"] = true, ["Crafting"] = true }

-- uiMapID of the capitals.
ns.CITY_MAPS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }

-- Class spells that take the player somewhere: bind = back to the hearthstone's bind point; otherwise a
-- fixed arrival (AreaID + 0-100 coordinates, approximate: replaced by the place really reached after the
-- first cast). cast = cast + loading (s); cd = cooldown used to space two uses (the real remaining time is
-- read); reagent = item id used up (17031: Rune of Teleportation).
-- The mage portals are left out: alone, they lead to the same places as the teleports.
local RUNE = 17031
ns.RECALL_SPELLS = {
  { spell = 556, bind = true, cast = 30, cd = 900 },                               -- Astral Recall (shaman)
  { spell = 3561, area = 1519, x = 38.0, y = 79.0, cast = 30, reagent = RUNE },    -- Teleport: Stormwind
  { spell = 3562, area = 1537, x = 25.5, y = 7.0, cast = 30, reagent = RUNE },     -- Teleport: Ironforge
  { spell = 3565, area = 1657, x = 40.0, y = 82.0, cast = 30, reagent = RUNE },    -- Teleport: Darnassus
  { spell = 3567, area = 1637, x = 38.5, y = 85.5, cast = 30, reagent = RUNE },    -- Teleport: Orgrimmar
  { spell = 3563, area = 1497, x = 84.5, y = 17.0, cast = 30, reagent = RUNE },    -- Teleport: Undercity
  { spell = 3566, area = 1638, x = 22.5, y = 16.5, cast = 30, reagent = RUNE },    -- Teleport: Thunder Bluff
  { spell = 18960, area = 493, x = 44.0, y = 45.0, cast = 30 },                    -- Teleport: Moonglade (druid)
}

-- Bind point of a new character: the start position of its race (no inn there). `areas` are the
-- AreaIDs (AreaTable) of the names GetBindLocation can give there ("Shadow Grave" seen in game for an
-- Undead; the others cover the start area and its subzones). Position: world coordinates of the
-- server table playercreateinfo (same as Geo's world points: c = continent, x, y).
ns.START_BINDS = {
  { areas = { 2117, 154 }, c = 0, x = 1676.71, y = 1678.31 },   -- Undead: Shadow Grave, Deathknell
  { areas = { 24, 9 }, c = 0, x = -8949.95, y = -132.493 },     -- Human: Northshire Abbey / Valley
  { areas = { 77, 132 }, c = 0, x = -6240.32, y = 331.033 },    -- Dwarf, Gnome: Anvilmar, Coldridge Valley
  { areas = { 256, 188 }, c = 1, x = 10311.3, y = 832.463 },    -- Night Elf: Aldrassil, Shadowglen
  { areas = { 363 }, c = 1, x = -618.518, y = -4251.67 },       -- Orc, Troll: Valley of Trials
  { areas = { 221, 220 }, c = 1, x = -2917.58, y = -257.98 },   -- Tauren: Camp Narache, Red Cloud Mesa
}

-- uiMapID of the two continents, whose flight nodes the game lists (C_TaxiMap).
ns.CONTINENT_MAPS = { 1414, 1415 }

-- Words of QuestieDB's texts (English, and French where the client or Forever's data give it), for what
-- no flag says: a flight master or an innkeeper without npcFlags (Lua patterns on the NPC's subName),
-- a mailbox (object name, plain text, lower case).
ns.SUBNAMES_FLIGHT_MASTER = { "Flight Master", "Gryphon Master", "Wind Rider Master", "Hippogryph Master",
  "Bat Handler", "[Mm]aître de vol" }
ns.SUBNAMES_INNKEEPER = { "Innkeeper", "[Aa]ubergiste" }
ns.MAILBOX_NAMES = { "mailbox", "boîte aux lettres", "boite aux lettres" }

-- Game quest tags (localized by the client) of a dungeon or raid quest, when the game gives no tag id
-- for it.
ns.DUNGEON_TAG_WORDS = { "Donjon", "Dungeon", "Raid" }
