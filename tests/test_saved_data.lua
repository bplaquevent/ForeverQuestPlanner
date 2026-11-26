-- Saved data: login and /fqp reset [all] through the real Core.lua and Events.lua.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local session, login = H.session, H.login

local function said(log, text)
  for _, m in ipairs(log.chat) do if m:find(text, 1, true) then return true end end
  return false
end
local function saidCharacters(log) return said(log, "données des personnages") end
local function saidLearned(log) return said(log, "a appris en jeu") end

local PASS = { a = 1, b = 2, c = 3, x = 4, y = 5 }
local function data(dataVersion, learnedVersion)
  return { ForeverQuestPlannerSettings = { dataVersion = dataVersion, learnedVersion = learnedVersion,
      chars = { ["Other-Realm"] = { custom = { list = { 1 } } } },
      learned = { passes = { PASS }, teleportArrivals = { [556] = PASS }, classTrainers = { SHAMAN = { [7] = true } },
        chars = { ["Test-Realm"] = { guid = "Player-1-AAAA", mountSpeed = 11.2, bind = { name = "Orgrimmar" } },
          ["Other-Realm"] = { guid = "Player-1-BBBB", mountSpeed = 14, bind = { name = "Undercity" } } } } },
    ForeverQuestPlannerDB = { ["Other-Realm"] = {} }, ForeverQuestPlannerBench = { x = 1 } }
end
local function charactersKept(env) local c = env.ForeverQuestPlannerSettings.chars
  return c ~= nil and c["Other-Realm"] ~= nil and env.ForeverQuestPlannerDB ~= nil and env.ForeverQuestPlannerBench ~= nil end
local function charactersGone(env) local c = env.ForeverQuestPlannerSettings.chars
  return (c == nil or c["Other-Realm"] == nil) and env.ForeverQuestPlannerDB == nil and env.ForeverQuestPlannerBench == nil end
local function learnedKept(ns) local s = ns.LearnedData()
  local mine, other = s.chars["Test-Realm"], s.chars["Other-Realm"]
  return mine ~= nil and mine.mountSpeed == 11.2 and mine.bind.name == "Orgrimmar" and other ~= nil and other.mountSpeed == 14
    and ns.TravelSpeed() == 11.2 and ns.LearnedChar().bind.name == "Orgrimmar" and #s.passes == 1 and s.teleportArrivals[556] ~= nil and s.classTrainers ~= nil and s.classTrainers.SHAMAN[7] == true end
local function learnedGone(ns) local s = ns.LearnedData()
  return ns.LearnedChar().mountSpeed == nil and ns.LearnedChar().bind == nil and s.chars["Other-Realm"] == nil
    and ns.TravelSpeed() == 7 and #s.passes == 0 and s.teleportArrivals[556] == nil and s.classTrainers == nil end
local function stamped(env) local r = env.ForeverQuestPlannerSettings return r.dataVersion == 1 and r.learnedVersion == 1 end

do local env, _, log = login({})
  check("first install: stamped, silent", stamped(env) and not saidCharacters(log) and not saidLearned(log)) end

-- stored numbers -> are the characters' data / the learned data erased?
for _, case in ipairs({ { 1, 1, false, false }, { 0, 1, true, false }, { 2, 1, true, false }, { 1, 0, false, true },
    { 1, 2, false, true }, { 0, 0, true, true }, { nil, nil, true, true }, { 1, nil, false, true } }) do
  local env, ns, log = login(data(case[1], case[2]))
  local name = "numbers " .. tostring(case[1]) .. "/" .. tostring(case[2])
  check(name .. ": characters", (case[3] and charactersGone or charactersKept)(env))
  check(name .. ": learned", (case[4] and learnedGone or learnedKept)(ns))
  check(name .. ": messages", saidCharacters(log) == case[3] and saidLearned(log) == case[4])
  check(name .. ": stamped", stamped(env))
  check(name .. ": settings usable", ns.Settings() == env.ForeverQuestPlannerSettings.chars["Test-Realm"])
  local env2, _, log2 = login({ ForeverQuestPlannerSettings = env.ForeverQuestPlannerSettings })
  check(name .. ": next login silent", not saidCharacters(log2) and not saidLearned(log2))
end

do local env, _, log = login({ ForeverQuestPlannerDB = { a = {} } })
  check("captures alone: erased, one message", env.ForeverQuestPlannerDB == nil and saidCharacters(log) and not saidLearned(log)) end

for _, case in ipairs({ { "reset", "FQP_RESET", false }, { "reset all", "FQP_RESET_ALL", true } }) do
  local env, ns, log = login(data(1, 1))
  local cmd, popup, all = case[1], case[2], case[3]
  ns.Settings().goalLevel = 33
  env.SlashCmdList.FOREVERQUESTPLANNER(cmd)
  check(cmd .. ": asks first", log.popups[#log.popups] == popup and charactersKept(env) and learnedKept(ns) and log.reloads == 0)
  ns.State.computing = true
  env.StaticPopupDialogs[popup].OnAccept()
  local shown = #log.popups
  env.SlashCmdList.FOREVERQUESTPLANNER(cmd)
  check(cmd .. ": refused while computing", log.reloads == 0 and #log.popups == shown and charactersKept(env) and learnedKept(ns))
  ns.State.computing = nil
  env.StaticPopupDialogs[popup].OnAccept()
  check(cmd .. ": characters erased, reload", charactersGone(env) and log.reloads == 1 and stamped(env))
  check(cmd .. ": learned " .. (all and "erased" or "kept"), (all and learnedGone or learnedKept)(ns))
  check(cmd .. ": former settings not reused", ns.Settings().goalLevel == nil)
  local _, _, log2 = login({ ForeverQuestPlannerSettings = env.ForeverQuestPlannerSettings })
  check(cmd .. ": next login silent", not saidCharacters(log2) and not saidLearned(log2))
end

do local env, ns = login({ ForeverQuestPlannerSettings = { dataVersion = 1, learnedVersion = 1,
    learned = { passes = { PASS, { a = "bad" } }, teleportArrivals = 7 } } })
  check("damaged pass dropped", #ns.LearnedData().passes == 1 and type(ns.LearnedData().teleportArrivals) == "table") end

do -- the part learned for one character
  local env, ns, log = login(data(1, 1))
  local recs = env.ForeverQuestPlannerSettings.learned.chars
  -- another character: its own record, the first one untouched
  log.who = { name = "Third", guid = "Player-1-CCCC" }
  check("new character: nothing inherited", ns.TravelSpeed() == 7 and ns.LearnedChar().bind == nil)
  env.IsMounted = function() return true end
  env.GetUnitSpeed = function() return 0, 9.8 end
  ns.Geo.LearnMountSpeed()
  check("mount speed learned apart", ns.TravelSpeed() == 9.8 and recs["Test-Realm"].mountSpeed == 11.2 and recs["Third-Realm"].guid == "Player-1-CCCC")
  log.who = { name = "Test", guid = "Player-1-AAAA" }
  check("same character: found again", ns.TravelSpeed() == 11.2 and ns.LearnedChar().bind.name == "Orgrimmar")
  -- no identifier: nothing read, nothing lost
  log.who = { name = "Test", guid = nil }
  check("no identifier: nothing read", ns.TravelSpeed() == 7 and ns.LearnedChar().bind == nil)
  ns.Geo.LearnMountSpeed()
  check("no identifier: nothing written", recs["Test-Realm"].mountSpeed == 11.2 and recs["Test-Realm"].guid == "Player-1-AAAA")
  -- made again under the same name: another identifier
  log.who = { name = "Test", guid = "Player-1-DDDD" }
  check("made again: starts afresh", ns.TravelSpeed() == 7 and ns.LearnedChar().bind == nil and recs["Test-Realm"].guid == "Player-1-DDDD")
  check("made again: others and passes kept", recs["Other-Realm"].mountSpeed == 14 and #ns.LearnedData().passes == 1)
end

if arg[1] then -- optional: a copy of a real SavedVariables file of this version, accepted as it is
  local d = H.readSaved(arg[1])
  local settings, chars, shared, db, bench = d.ForeverQuestPlannerSettings, d.ForeverQuestPlannerSettings.chars,
    d.ForeverQuestPlannerSettings.learned, d.ForeverQuestPlannerDB, d.ForeverQuestPlannerBench
  local env, _, log = login(d)
  check("converted data: nothing erased", not saidCharacters(log) and not saidLearned(log)
    and env.ForeverQuestPlannerSettings == settings and settings.chars == chars and settings.learned == shared
    and env.ForeverQuestPlannerDB == db and env.ForeverQuestPlannerBench == bench)
end
finish()
