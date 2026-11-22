# Forever Quest Planner

World of Warcraft addon for the **Forever** server (client 1.60.1, Interface 16001: Classic-era API, Lua 5.1).
QuestieDB (quest data, NPC/object spawns, chains) and OpenMap (map, flight network) are required dependencies (`## Dependencies` in the `.toc`):
call their data and functions directly, never copy them or write code paths that work without them.
No way to run the game here: check with `tools/check.sh` (compiles every file, detects unknown globals).
Roadbook solver: test bench `lua5.1 tools/bench.lua <SavedVariables or tools/cases/*.lua>` on a problem captured by `/fqp dump`.

## Files (load order = `ForeverQuestPlanner.toc`)

| File | Content |
|---|---|
| `Locales/Locales.lua`, `Locales/frFR.lua` | `ns.L` table; French translations |
| `Data/Passes.lua` | walking passes between zones known before any is learned: Warcraft Wiki rows `ns.PASSES`, QuestieDB patrol NPCs `ns.PASS_PATROLS` (listed by `tools/patrol_npcs.py`) |
| `Solver.lua` | Roadbook solver in pure Lua (no game API, also run by `tools/bench.lua`): XP formulas (`MobXP`, `QuestXP`), world model from a captured problem (walks, passes, danger, network `S.Network` / `S.Route`), route evaluation `S.Evaluate`, goal value `S.Objective`, teleports `S.AddRecalls` / `S.Simulate`, objective order ranks `S.Ranks`, hunting spot variants `S.Variants`, optimizer `S.Optimize` (candidate quests: construction, local search, destroy and rebuild; the list: `S.ValidCustom`, `S.BuildCustom`; list with a duration or level: kept and completed or trimmed, `S.MixPrepare`, units `S.InsertUnit` / `S.WithoutUnit`; tuning `S.OPT`) |
| `Core.lua` | utilities (`Print`, `Settings` = saved data of the character, `Color`…), constants table `K`, `State`, QuestieDB access (`QDB`, `QGet`, `QuestMeta`, `ChainInfo`), quest log capture (`Snapshot`), reward analysis, `Analyze()` |
| `Available.lua` | available quests: `CheckAvailable`, frame-sliced scan `StartScan` / `scan` |
| `Geo.lua` | world coordinates, travel times, zone passes (`Geo.ZoneIdAt`, `Geo.Passes`, `Geo.WalkWay` / `WalkTime`, learning `Geo.PassTick`), flight/zeppelin/boat network (`Route`, `RouteText`, docks named after their town `Geo.DockName`), quest targets (`QuestTargets`, quest giver places `Geo.StartPlaces`) |
| `Planner.lua` | Roadbook model: profession level to turn in (`Geo.SkillNeed`), Nearby items, XP / levels, monster spots, tasks, priorities (`Geo.Priority`), rewards interest |
| `Route.lua` | Roadbook route: transport stops, hearthstone and class teleports (`Geo.RecallSources`, `RecallState`, `RecallStep`), planning with the solver (`Geo.Solve`, solver route -> game route `Geo.FromSolver`, history kept `Geo.KeepDone`), `Geo.RequestPlan` |
| `Custom.lua` | the Roadbook list: quests (`Geo.CustomAdd` / `CustomRemove`, `Geo.CustomChanged`), migrations of former Roadbooks, dungeon visits and order rules (`Geo.GroupDungeons`, `Geo.CustomConstraints`), planning with the solver (whole list `Geo.PlanCustom`, "Generate" for a duration or level `Geo.PlanGenerate`, new list `Geo.AcceptGenerated`), per-leg networks `Geo.RouteNets` |
| `Problem.lua` | the Roadbook problem read from the game for the solver: `Geo.Problem` (live: steps keep their game step in `src`), custom list `Geo.CustomPlanSteps`; `/fqp dump` (`Geo.BenchDump`) captures it into `ForeverQuestPlannerBench` for `tools/bench.lua` |
| `UI/Lists.lua` | window state, list engine (`RenderList`, `ListRow`), quest tracking and map pins, quest descriptions (`Geo.QuestTitle`, `Geo.DescLine`, badges, `K.DESC`), search |
| `UI/Tabs.lua` | Quest log (`RenderTodo`), Available (`RenderAvailable`, rewards line), Nearby (`RenderNear`) tabs |
| `Roadbook.lua` | `CP` table: checkpoints/focus, saved Roadbook (`Geo.Freeze`…), auto-advance on game events, teleport cooldown checks (`CP.RecallCheck`, `CP.ScheduleRecallCheck`), Roadbook adapted `CP.Replan` (removed quest, skipped transport, quest giver found `CP.GiverFound`), step order `CP.StepReady`, floating Objective button |
| `RoadbookMap.lua` | Roadbook on OpenMap's map: map ownership (`Geo.MapClaim` / `MapRelease`, `Geo.MapOwner`), locks on OpenMap's pin functions, drawing (`Geo.MapSync` / `MapDraw`) |
| `RoadbookPanel.lua` | Roadbook steps panel, a window of its own (`Geo.MapPanelSync`, header `Geo.MapPanelHeader`, placement `Geo.MapPanelPlace`, shown `Geo.MapPanelOpen` / `MapPanelShow`), step details `Geo.StepDetailLines` (tooltips of the panel and the map pins), right-click actions |
| `UI/Window.lua` | Roadbook tab (`RenderXP`: quests of the list `Geo.RoadbookQuestItems`), filter bars, `SelectTab`, `Refresh` |
| `UI/Settings.lua` | `K.PARAMS` and the settings window |
| `UI/MainFrame.lua` | `CreateMainFrame`, Roadbook tab controls `CreateRoadbookPanel` / `Geo.CreateGoalLine`, active Roadbook light in the tab titles `Geo.AddTabLed`, export to file, minimap button |
| `Events.lua` | event frame (`PLAYER_LOGIN` init, quest/taxi/zone events), `/fqp` commands |

Find code with `grep -n "function Name\|Name =" *.lua UI/*.lua` instead of reading whole files.

## Sharing names between files

- Each file starts with `local ADDON_NAME, ns = ...` and imports what it uses: `local A, B = ns.A, ns.B`.
  It ends with `-- Shared with the next files.` followed by `ns.X = X` for the locals other files use.
- A file can only import from files loaded before it. For a call to a later file, call `ns.Name()` at runtime
  (example: `Refresh` in `Available.lua` forwards to the real one in `UI/Window.lua`).
- Saved data: `Settings()` returns the character's own table (`ForeverQuestPlannerSettings.chars[CharKey()]`);
  only what is learned about the world and true for every character (zone passes, teleport arrivals) is shared:
  `SharedData()`.
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
  A commit that settles a GitHub issue ends its paragraph with `Fixes #n`.

## Issues

Work is tracked in GitHub Issues (labels: `bug`, `enhancement`, `solver`, `roadbook`, `map`, `ui`, `data`).
Read them with `gh issue list` / `gh issue view <n>` when the user cites a number or a topic.
Open, comment on or close an issue only when asked: it is public.
