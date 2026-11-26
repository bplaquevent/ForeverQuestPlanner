-- A step saved and read back after a /reload.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local _, ns = H.session()
local rec = ns.Geo.SerializeStep({ kind = "fm", p = { c = 0, x = 1, y = 1 }, task = { title = "t" }, work = 1, laterFM = true })
check("flight path for later trips kept", ns.Geo.DeserializeStep(rec, {}).laterFM == true)
finish()
