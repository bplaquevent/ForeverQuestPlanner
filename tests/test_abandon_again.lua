-- "Pick it up again" on an abandoned quest computes the Roadbook again, tracked or not.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()
local manual
ns.CP.Replan = function(_, _, m) manual = m return true end
env.StaticPopupDialogs.FQP_QUEST_ABANDONED.OnCancel(nil, { id = 1, title = "Q" })
check("computed again even when not tracked", manual == true)
finish()
