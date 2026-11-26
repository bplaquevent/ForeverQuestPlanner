-- Every ns.X imported at the top of a file ("local A, B = ns.A, ns.B") is exported by a file loaded
-- before it: otherwise it is silently nil, as is a name without a value. A file listed twice in the
-- .toc is reported too (the game warns and loads it again). Run from the repository root (tools/check.sh).
local exported, listed, problems = {}, {}, 0
for line in io.lines("ForeverQuestPlanner.toc") do
  local file = line:gsub("\r", ""):gsub("\\", "/")
  if file:match("%.lua$") and not file:match("^#") then
    if listed[file:lower()] then
      print(file .. ": listed twice in the .toc")
      problems = problems + 1
    end
    listed[file:lower()] = true
    local source = {}
    for l in io.lines(file) do source[#source + 1] = l end
    for _, l in ipairs(source) do
      local code = l:gsub("\r", ""):gsub("%s*%-%-.*$", "") -- without a comment at its end
      local names, values = code:match("^local ([%w_, ]+) = (ns%.[%w_%., ]+)$")
      if values and select(2, names:gsub(",", "")) ~= select(2, values:gsub(",", "")) then
        print(file .. ": as many names as values expected: " .. code)
        problems = problems + 1
      end
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
