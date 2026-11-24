-- Every ns.X imported at the top of a file ("local A, B = ns.A, ns.B") is exported by a file loaded
-- before it: otherwise it is silently nil. Run from the repository root (tools/check.sh).
local exported, problems = {}, 0
for line in io.lines("ForeverQuestPlanner.toc") do
  local file = line:gsub("\r", ""):gsub("\\", "/")
  if file:match("%.lua$") and not file:match("^#") then
    local source = {}
    for l in io.lines(file) do source[#source + 1] = l end
    for _, l in ipairs(source) do
      local values = l:match("^local [%w_, ]+ = (ns%.[%w_%., ]+)$")
      for name in (values or ""):gmatch("ns%.([%w_]+)") do
        if not exported[name] then
          print(file .. ": ns." .. name .. " imported before any file exports it")
          problems = problems + 1
        end
      end
    end
    for _, l in ipairs(source) do
      -- "ns.A, ns.B = A, B" or "ns.A = ..."
      local targets = l:match("^%s*(ns%.[%w_%., ]-)%s*=[^=]")
      for name in (targets or ""):gmatch("ns%.([%w_]+)") do exported[name] = true end
    end
  end
end
os.exit(problems == 0 and 0 or 1)
