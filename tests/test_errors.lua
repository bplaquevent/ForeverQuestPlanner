-- Errors of the addon's calls: the caller goes on, the error is told in the chat once (ns.Guard).
local H = dofile("tests/harness.lua")
local check, finish = H.checker()
local env, ns, log = H.login()
local function lines(word)
  local n = 0
  for _, m in ipairs(log.chat) do if m:find(word, 1, true) then n = n + 1 end end
  return n
end

local ok, a, b = ns.Guard(function(x, y) return x + y, nil end, 1, 2)
check("success: pcall's results, silent", ok == true and a == 3 and b == nil and lines("(copie-la pour la signaler)") == 0)
local function broken() error("boom") end
ok = ns.Guard(broken)
check("failure: returned, not raised", ok == false)
check("told in the chat, with the file and line", lines("(copie-la pour la signaler)") == 1 and lines("boom") == 1 and lines("test_errors.lua:") == 1)
ns.Guard(broken)
ns.Guard(broken)
check("the same error: once", lines("boom") == 1)
for i = 1, 20 do ns.Guard(function() error("other " .. i) end) end
check("at most 10 different errors per session", lines("(copie-la pour la signaler)") == 10)

-- through a game event: the quest followed up by the Roadbook fails, the other handlers go on
env, ns, log = H.login()
local snapshots = 0
env.C_Timer = { After = function() snapshots = snapshots + 1 end, NewTicker = function() end }
ns.CP.OnGameEvent = function() error("follow-up broke") end
check("event: no error raised", pcall(log.fire, "QUEST_ACCEPTED", 1))
check("event: told", lines("follow-up broke") == 1)
finish()
