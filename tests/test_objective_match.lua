-- Game objectives matched to QuestieDB targets: the names first, then the positions.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local _, ns = H.session()
local map = ns.Geo.MatchObjectives({ { text = "Rapport de Kristof: 0/1" }, { text = "Loup tué: 0/8" } },
  { { name = "Untranslated" }, { name = "Rapport de Kristof" } })
check("a position never takes the objective a later target names", map[2] == 1 and map[1] == nil)
map = ns.Geo.MatchObjectives({ { text = "Loup tué: 0/8" }, { text = "Rapport de Kristof: 0/1" } },
  { { name = "Rapport de Kristof" }, { name = "Untranslated" } })
check("unnamed target: no objective at its position left", map[1] == 2 and map[2] == nil)
map = ns.Geo.MatchObjectives({ { text = "x" }, { text = "y" } }, { { name = "a" }, { name = "b" } })
check("no name found: by position", map[1] == 1 and map[2] == 2)
finish()
