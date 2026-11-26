-- The confirmation of a generated list: obsolete once the list or the Roadbook changed meanwhile.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns = H.session()
local Geo, CP = ns.Geo, ns.CP
local data
env.StaticPopup_Show = function(_, _, _, d) data = d return {} end
local set, adopted, answer
Geo.ListFromRoute = function() return {} end
Geo.CustomList = function() return { { id = 1 } } end
Geo.CustomSetList = function() set = set + 1 end
Geo.AdoptPlan = function() adopted = adopted + 1 end
Geo.SyncQuestLogButton = function() end

local function propose()
  set, adopted, answer, data = 0, 0, nil, nil
  Geo.AcceptGenerated({}, {}, function(ok) answer = ok end)
end
local accept = function() env.StaticPopupDialogs.FQP_TRIM_LIST.OnAccept(nil, data) end

propose()
accept()
check("nothing changed: accepted", set == 1 and adopted == 1 and answer == true)
propose()
ns.State.customToken = (ns.State.customToken or 0) + 1 -- the list changed (Geo.CustomChanged, CP.DoEmpty)
accept()
check("list changed meanwhile: nothing overwritten", set == 0 and adopted == 0 and answer == false)
propose()
CP.computeToken = (CP.computeToken or 0) + 1 -- another computation started
accept()
check("Roadbook computed again meanwhile: nothing overwritten", set == 0 and adopted == 0 and answer == false)
finish()
