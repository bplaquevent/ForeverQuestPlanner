-- tools/check_imports.lua on a small addon made for the test: what leaves an imported name nil is
-- reported, also on a line ending with a comment or with CR LF.
local H = dofile("tests/harness.lua")
local check, finish = H.checker()

local function shell(command)
  local p = assert(io.popen(command))
  local out = p:read("*a")
  p:close()
  return out
end
local root = shell("pwd"):gsub("\n", "")
local dir = shell("mktemp -d"):gsub("\n", "")
local function write(name, text)
  local f = assert(io.open(dir .. "/" .. name, "wb"))
  f:write(text)
  f:close()
end
write("T.toc", "")
write("ForeverQuestPlanner.toc", "A.lua\nB.lua\n")
write("A.lua", "local _, ns = ...\nns.One, ns.Two = 1, 2\n")

-- What the check says of a second file made of one line.
local function report(line, eol)
  write("B.lua", "local _, ns = ..." .. (eol or "\n") .. line .. (eol or "\n"))
  return shell("cd '" .. dir .. "' && lua5.1 '" .. root .. "/tools/check_imports.lua'; echo \"status $?\"")
end
local function accepted(out) return out:find("status 0", 1, true) ~= nil end

check("valid imports accepted", accepted(report("local One, Two = ns.One, ns.Two")))
check("valid imports with a comment accepted", accepted(report("local One = ns.One -- why, and what")))
check("unknown name", report("local Three = ns.Three"):find("ns.Three imported before", 1, true) ~= nil)
check("unknown name before a comment", report("local Three = ns.Three -- why"):find("ns.Three imported before", 1, true) ~= nil)
check("unknown name, CR LF", report("local Three = ns.Three", "\r\n"):find("ns.Three imported before", 1, true) ~= nil)
check("more names than values", report("local One, Two, Three = ns.One, ns.Two"):find("as many names", 1, true) ~= nil)
check("more values than names", not accepted(report("local One = ns.One, ns.Two")))
shell("rm -rf '" .. dir .. "'")
finish()
