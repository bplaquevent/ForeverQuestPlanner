-- Fake game for the tests: the addon's files are loaded in the order of the .toc, in an environment
-- where every game API not faked by a test is a mock that accepts anything. Run from the repository
-- root: tests/run.sh.

local H = {}

local function Mock()
  return setmetatable({}, {
    __index = function(t, k) local v = Mock() rawset(t, k, v) return v end,
    __call = function() return Mock() end,
  })
end

-- The addon's Lua files, in load order.
function H.files()
  local out = {}
  for line in io.lines("ForeverQuestPlanner.toc") do
    local file = line:gsub("\r", ""):gsub("\\", "/")
    if file:match("%.lua$") and not file:match("^#") then out[#out + 1] = file end
  end
  return out
end

-- Loads the addon. saved: the saved variables. after[file] = function(ns, env) runs once that file
-- is loaded: a name of ns replaced there is the one the next files import (they keep it as a local).
-- Returns env (the fake game's globals), ns (the addon's shared table) and log: chat lines, popups,
-- reloads, event frames, and who is logged in (log.who).
function H.session(saved, after)
  local log = { chat = {}, popups = {}, reloads = 0, frames = {} }
  local mocks = {}
  local env = setmetatable({}, { __index = function(_, k)
    if _G[k] ~= nil then return _G[k] end
    if k:match("^ForeverQuestPlanner") then return nil end
    mocks[k] = mocks[k] or Mock()
    return mocks[k]
  end })
  for k, v in pairs(saved or {}) do env[k] = v end
  env.GetLocale = function() return "frFR" end
  env.UnitClass = function() return "Chaman", "SHAMAN" end
  env.CANCEL = "Annuler"
  env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) log.chat[#log.chat + 1] = m end }
  env.StaticPopupDialogs = {}
  env.StaticPopup_Show = function(name) log.popups[#log.popups + 1] = name end
  env.ReloadUI = function() log.reloads = log.reloads + 1 end
  env.SlashCmdList = {}
  env.C_Timer = { After = function() end, NewTicker = function() end }
  env.CreateFrame = function()
    local frame = Mock()
    frame.disabled = false
    frame.SetScript = function(_, what, fn)
      if what == "OnEvent" then log.frames[#log.frames + 1] = { frame = frame, fn = fn } end
    end
    return frame
  end
  -- the character logged in: name and the game's identifier
  log.who = { name = "Test", guid = "Player-1-AAAA" }
  env.UnitFullName = function() return log.who.name, "Realm" end
  env.UnitGUID = function() return log.who.guid end

  local ns = {}
  for _, file in ipairs(H.files()) do
    if file == "Events.lua" then
      -- what Events.lua keeps as locals and would need the real dependencies or interface
      ns.InitDeps = function() end
      ns.CreateMinimapButton = function() end
      ns.CP.CreateCheckpointButton = function() end
    end
    local chunk = assert(loadfile(file))
    setfenv(chunk, env)
    chunk("ForeverQuestPlanner", ns)
    local hook = after and after[file]
    if hook then hook(ns, env) end
  end
  -- the game event, through the addon's event frame (Events.lua, the last one made at load)
  local events = log.frames[#log.frames]
  log.fire = function(event, ...) events.fn(events.frame, event, ...) end
  return env, ns, log
end

function H.login(saved, after)
  local env, ns, log = H.session(saved, after)
  log.fire("PLAYER_LOGIN")
  return env, ns, log
end

-- A table of saved variables read from a file, as data only (no access to any global).
function H.readSaved(path)
  local data = {}
  local chunk = assert(loadfile(path))
  setfenv(chunk, data)
  chunk()
  return data
end

-- check(what, ok) counts; finish() prints the result and ends the test (status 1 on a failure).
function H.checker()
  local checks, failures = 0, 0
  local function check(what, ok)
    checks = checks + 1
    if not ok then
      failures = failures + 1
      print("FAIL " .. what)
    end
  end
  local function finish()
    print(checks .. " checks, " .. failures .. " failures")
    if failures > 0 then os.exit(1) end
  end
  return check, finish
end

return H
