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
