-- Forever Quest Planner: walking passes between zones, before any is learned in game.
-- A walk from a zone to another goes through a pass (Geo.WalkWay, Geo.lua); a pair of zones with
-- a pass learned in game (the player walked from one to the other) no longer uses these.

local ADDON_NAME, ns = ...

-- Passes given by the Warcraft Wiki: { uiMapID, x, y (0-100 on that zone's map), uiMapID of the
-- zone on the other side }. Only rows the wiki locates (most of its zone pages list neighbours
-- without coordinates, and as they are since Cataclysm).
ns.PASSES = {
  { 1446, 27, 56, 1449 }, -- Tanaris -> Un'Goro Crater, Thistleshrub Valley (warcraft.wiki.gg/wiki/Un%27Goro_Crater)
  { 1449, 29, 21, 1451 }, -- Un'Goro Crater -> Silithus, north-west path (warcraft.wiki.gg/wiki/Silithus)
  { 1427, 34, 74, 1428 }, -- Searing Gorge -> Burning Steppes through Blackrock Mountain (warcraft.wiki.gg/wiki/Blackrock_Mountain)
}

-- QuestieDB NPCs whose patrol crosses from a zone to another: their paths' ends on both sides of a
-- border make a pass (Geo.Passes). Listed by tools/patrol_npcs.py from QuestieDB's data.
ns.PASS_PATROLS = { 844, 2041, 2447, 2714, 3056, 4571, 6497, 7050, 10182, 14866 }
