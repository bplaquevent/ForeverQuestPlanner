-- Quantities of the objectives of a quest out of the log: the game's, else QuestieDB's text or default.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()

local given = {}
env.C_QuestLog = { GetQuestObjectives = function(id) return given[id] end }

-- targets of quest id, as QuestTargets makes them
local function targets(id, ...)
  local t = { id = id }
  for _, tg in ipairs({ ... }) do t[#t + 1] = tg end
  return t
end
local function counts(t)
  local out = {}
  for _, r in ipairs(ns.RemainingTargets(nil, t)) do out[#out + 1] = r.count end
  return table.concat(out, ",")
end
local function check_counts(what, t, want)
  local got = counts(t)
  check(what .. ": " .. got, got == want)
end

local necklace = targets(1, { kind = "item", name = "Shattered Necklace", defaultCount = 6 })
-- item not cached yet: the game gives no name
given[1] = { { text = " : 0/1", type = "item", numRequired = 1, numFulfilled = 0 } }
check_counts("the game's quantity", necklace, "1")
given[1] = {}
check_counts("quest not loaded: default", necklace, "6")
given[1] = nil
check_counts("no answer: default", necklace, "6")
given[1] = { { text = "?", type = "item", numRequired = 0, numFulfilled = 0 } }
check_counts("no quantity given: default", necklace, "6")

-- matched by name, whatever the game's order
given[2] = {
  { text = "Beta : 0/3", type = "item", numRequired = 3, numFulfilled = 0 },
  { text = "Alpha : 0/9", type = "item", numRequired = 9, numFulfilled = 0 },
}
check_counts("matched by name", targets(2, { kind = "item", name = "Alpha", defaultCount = 6 },
  { kind = "item", name = "Beta", defaultCount = 6 }), "9,3")

-- the log's rules do not apply: a "talk" target the game does not list stays planned
given[3] = { { text = "Alpha : 0/2", type = "item", numRequired = 2, numFulfilled = 0 } }
check_counts("unlisted talk target kept", targets(3, { kind = "item", name = "Alpha", defaultCount = 6 },
  { kind = "talk", name = "Someone", defaultCount = 1 }), "2,1")

finish()
