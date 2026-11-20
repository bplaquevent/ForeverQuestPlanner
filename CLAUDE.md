# Forever Quest Planner

World of Warcraft addon for the **Forever** server (client 1.60.1, Interface 16001: Classic-era API, Lua 5.1).
QuestieDB is an optional dependency (quest data, NPC/object spawns, chains); without it only the game API is used.
No way to run the game here: check with `tools/check.sh` (compiles every file, detects unknown globals).

## Files (load order = `ForeverQuestPlanner.toc`)

| File | Content |
|---|---|
| `Locales/Locales.lua`, `Locales/frFR.lua` | `ns.L` table; French translations |
| `Core.lua` | utilities (`Print`, `Settings`, `Color`…), constants table `K`, `State`, QuestieDB access (`QDB`, `QGet`, `QuestMeta`, `ChainInfo`), quest log capture (`Snapshot`), reward analysis, `Analyze()` |
| `Available.lua` | available quests: `CheckAvailable`, frame-sliced scan `StartScan` / `scan` |
| `Geo.lua` | world coordinates, travel times, flight/zeppelin/boat network (`Route`, `RouteText`), quest targets (`QuestTargets`) |
| `Planner.lua` | Roadbook model: Nearby items, XP / levels, monster spots, tasks, priorities (`Geo.Priority`), rewards interest |
| `Route.lua` | Roadbook route: flight master / transport stops, hearthstone, improvement, `PlanXP`, `Geo.RequestPlan` |
| `UI/Lists.lua` | window state, list engine (`RenderList`, `ListRow`), quest tracking and map pins, quest descriptions (`Geo.QuestTitle`, `Geo.DescLine`, badges, `K.DESC`), search |
| `UI/Tabs.lua` | Quest log (`RenderTodo`), Available (`RenderAvailable`, rewards line), Nearby (`RenderNear`) tabs |
| `Roadbook.lua` | `CP` table: checkpoints/focus, saved Roadbook (`Geo.Freeze`…), quick wins, auto-advance on game events, floating Objective button |
| `UI/Window.lua` | Roadbook tab (`RenderXP`), filter bars, `SelectTab`, `Refresh` |
| `UI/Settings.lua` | `K.PARAMS` and the settings window |
| `UI/MainFrame.lua` | `CreateMainFrame`, export to file, minimap button |
| `Events.lua` | event frame (`PLAYER_LOGIN` init, quest/taxi/zone events), `/fqp` commands |

Find code with `grep -n "function Name\|Name =" *.lua UI/*.lua` instead of reading whole files.

## Sharing names between files

- Each file starts with `local ADDON_NAME, ns = ...` and imports what it uses: `local A, B = ns.A, ns.B`.
  It ends with `-- Shared with the next files.` followed by `ns.X = X` for the locals other files use.
- A file can only import from files loaded before it. For a call to a later file, call `ns.Name()` at runtime
  (example: `Refresh` in `Available.lua` forwards to the real one in `UI/Window.lua`).
- Mutable variables read by several files live in the `State` table (`State.mainFrame`, `State.currentTab`,
  `State.availFilter`, `State.xpHorizon`, `State.nearRadius`, search queries…). Never export a local that is reassigned later.
- Lua limits: 200 locals per function/file and 60 upvalues per function. That is why constants are in `K` and many
  functions are fields of `Geo` / `CP` instead of locals: add new functions there.

## Conventions

- Code, comments and `L["…"]` keys in English. Every new user-visible string goes through `L["English text"]`
  and gets its French translation in `Locales/frFR.lua` (keys roughly alphabetical).
- Quest descriptions (every tab and the Objective button): white title with badges, then indented lines
  (`K.DESC_LINE`) in a fixed order: what to do and where, figures (XP in blue `K.DESC.xp`), follow-ups,
  warnings, blockers, rewards; informations separated by `K.DESC_SEP` (" · "). Reuse the `Geo.*` helpers.
- Each user-visible change bumps the patch number of `## Version` in the `.toc`; update `README.md` when a feature
  or command changes.
- Commit messages: English, a short title (`Area: change`), then a short paragraph explaining the why.
