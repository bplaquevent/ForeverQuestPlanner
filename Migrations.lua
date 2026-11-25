-- Forever Quest Planner: the character's saved data brought to the current form, once per step
-- (Settings().schema = last step applied). A change of the form of saved data adds a step at the end;
-- the code only knows the current form.

local ADDON_NAME, ns = ...
local CharKey, Settings = ns.CharKey, ns.Settings

-- Priority settings of former versions (the Roadbook now only optimizes XP).
local FORMER_PARAMS = { "PRIO_CLASS", "PRIO_UNLOCK_CLASS", "PRIO_ITEM_SPEC", "PRIO_ITEM_BLUE", "PRIO_UPGRADE_SPEC",
  "PRIO_UPGRADE", "PRIO_SPELL", "PRIO_BAG", "READY_BONUS", "LOOKAHEAD_WEIGHT" }

-- Per character records formerly saved in tables indexed by the character again: table -> new field.
local PER_CHARACTER = { custom = "custom", bind = "bind", roadbook = "roadbook", mapSaved = "mapSaved", pins = "pin" }

local FORMER_MODES = { vol = "flight", bateau = "boat" }

local steps = {
  -- 1. What former versions saved and nothing reads any more. A Roadbook that was not made from the
  -- quest list (versions with an automatic Roadbook, before 2.45) is dropped, no longer converted.
  function(st, key)
    st.focus, st.expanded, st.paramsScale, st.mapDiag = nil, nil, nil, nil
    st.activeRoadbook, st.roadbookMigrated = nil, nil
    for _, param in ipairs(st.params and FORMER_PARAMS or {}) do st.params[param] = nil end
    local roadbooks = st.roadbook
    if roadbooks then
      roadbooks[key .. "|custom"] = nil
      local rec = roadbooks[key]
      if rec and not (rec.info and rec.info.custom) then roadbooks[key] = nil end
    end
    local list = st.custom and st.custom[key]
    if list then list.mode = nil end
    local map = st.mapSaved and st.mapSaved[key]
    if map then map.kind = nil end
  end,

  -- 2. The character's data is already apart (Settings()): one record each, no second index.
  function(st, key)
    local records = {}
    for former, field in pairs(PER_CHARACTER) do
      records[field] = st[former] and st[former][key] or nil
      st[former] = nil
    end
    for field, record in pairs(records) do st[field] = record end
  end,

  -- 3. Transport modes named in English, in the saved Roadbook too.
  function(st)
    for _, step in ipairs(st.roadbook and st.roadbook.steps or {}) do
      local task = step.task
      if task and FORMER_MODES[task.mode] then task.mode = FORMER_MODES[task.mode] end
    end
  end,
}

-- At login, before anything reads the saved data.
function ns.Migrate()
  local st, key = Settings(), CharKey()
  for version = (st.schema or 0) + 1, #steps do
    steps[version](st, key)
    st.schema = version
  end
end
