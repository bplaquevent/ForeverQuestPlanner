-- A click on a quest's line, the quest shown at its place and the combat message.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local log = {}
local function note(...) log[#log + 1] = table.concat({ ... }, " ") end
local game = { inLog = {}, combat = false, mapOpens = true, owner = nil, stitched = true }
local env, ns = H.session(nil, { ["Geo.lua"] = function(ns)
  ns.IsInLog = function(q) return game.inLog[q] == true end
  ns.GeoReady = function() return true end
  ns.Print = function(m) note("print", m) end
  ns.PointText = function() return "there" end
end })
ns.OM.IsStitched = function() return game.stitched end
ns.OM.ShowWorld = function(u, v, z) note("center", u, v, z) end
ns.OM.GetView = function() return 0, 0, 2 end
ns.OM.TrackPoint = function() note("pin") end
ns.OM.ClearPin = function() end
ns.OM.WaypointPoint = function() end
local Geo = ns.Geo
local shown = false
local frame = { IsShown = function() return shown end, SetMapID = function(_, ui) note("mapid", ui) end, GetMapID = function() return 1 end }
env.WorldMapFrame = frame
env.ToggleWorldMap = function() note("toggle") if game.mapOpens then shown = true end end
env.InCombatLockdown = function() return game.combat end
env.QuestMapFrame_OpenToQuestDetails = function(q) note("details", q) if game.mapOpens then shown = true end end
env.C_Timer = { After = function(_, fn) fn() end, NewTicker = function() end }
local mainHidden = false
ns.State.mainFrame = { IsShown = function() return true end, Hide = function() mainHidden = true end }
Geo.MapOwner = function() return game.owner end
Geo.MapRelease = function() note("release") game.owner = nil end
Geo.MapSync = function() end
Geo.MapUV = function() return 0.5, 0.5 end
Geo.PointUi = function() return 14 end
Geo.QuestZoneUi = function() return 99 end
Geo.LinkQuestInChat = function(q) note("link", q) end
local shift = false
env.IsShiftKeyDown = function() return shift end

local point = { c = 0, x = 1, y = 1, mx = 10, my = 20, ui = 14 }
local function click(it, o)
  o = o or {}
  log = {}
  shown, mainHidden = o.mapShown or false, false
  game.combat, game.mapOpens, game.owner = o.combat or false, not o.combat, o.owner
  shift = o.shift or false
  Geo.QuestRowClick({ overLink = o.overLink }, it)
  return "|" .. table.concat(log, "|") .. "|"
end
local function has(s, word) return s:find(word, 1, true) ~= nil end
local function combatMsg(s) return has(s, "Impossible en combat") end

game.inLog = { [1] = true }
local asked = 0
local inLogRow = { questID = 1, linkQuest = 1, place = function() asked = asked + 1 return point, "x" end, placeTitle = "A" }
local outRow = { linkQuest = 2, place = function() asked = asked + 1 return point, "giver" end, placeTitle = "B" }
local r = click(inLogRow)
check("quest of the log: opened, no pin, no centering", has(r, "|details 1|") and not has(r, "pin") and not has(r, "center") and asked == 0 and not combatMsg(r))
r = click(outRow)
check("other quest: pin, then centered with a zone zoom", has(r, "|pin|") and has(r, "|center 0.5 0.5 8|") and r:find("pin", 1, true) < r:find("center", 1, true) and not has(r, "details"))
check("window kept open", not mainHidden)
r = click({ linkQuest = 2, questID = nil, place = outRow.place }, { shift = true })
check("shift: link only", r == "|link 2|")
r = click(outRow, { shift = true, overLink = true })
check("shift on a link: quest linked as before", r == "|link 2|")
check("click on a link of the line: nothing", click(outRow, { overLink = true }) == "||" and click(inLogRow, { overLink = true }) == "||")
check("no place, not in the log (turned in): nothing", click({ linkQuest = 3 }) == "||")
game.inLog[2] = true
check("accepted since the list was drawn: opened", has(click(outRow), "details 2"))
game.inLog[2] = nil
r = click(outRow, { owner = { mode = "follow" } })
check("followed Roadbook: centered, no pin, said", not has(r, "pin") and has(r, "center") and has(r, "Un Roadbook"))
r = click(outRow, { owner = { mode = "preview" } })
check("preview: ended, pin placed", has(r, "release") and has(r, "|pin|") and has(r, "center"))
r = click({ linkQuest = 2, place = function() return nil end, placeTitle = "B" })
check("unknown position: said, quest's zone opened", has(r, "mapid 99") and not has(r, "pin") and not has(r, "center"))
r = click(inLogRow, { combat = true })
check("combat, quest of the log: message", has(r, "details 1") and combatMsg(r))
r = click(outRow, { combat = true })
check("combat, other quest: message, not centered", combatMsg(r) and not has(r, "center") and not mainHidden)
r = click({ linkQuest = 2, place = function() return nil end }, { combat = true })
check("combat, unknown position: message", combatMsg(r))
r = click(inLogRow, { combat = true, mapShown = true })
check("combat, map already open: no message", not combatMsg(r))
game.stitched = false
r = click(outRow)
check("OpenMap's map off: the zone's map", has(r, "mapid 14") and not has(r, "center"))
game.stitched = true
-- a Roadbook step still centers, then shows its quest
log, shown, game.combat, game.mapOpens, game.owner = {}, true, false, true, nil
env.GetQuestUiMapID = function() return 0 end
env.QuestMapFrame_ShowQuestDetails = function(q) note("show", q) end
frame.QuestLog = { IsShown = function() return true end }
Geo.ClickStep({ p = point, task = { id = 1 } })
r = "|" .. table.concat(log, "|") .. "|"
check("step click: centered, then its quest shown", has(r, "center 0.5 0.5 8") and has(r, "|show 1|"))
finish()
