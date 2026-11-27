# Forever Quest Planner

World of Warcraft addon for the **Forever** server (client 1.60.1, Interface 16001: Classic-era API, Lua 5.1).
QuestieDB (quest data, NPC/object spawns, chains) and OpenMap (map, flight network) are required dependencies (`## Dependencies` in the `.toc`):
call their data and functions directly (OpenMap's through `ns.OM`, `OpenMapLink.lua`), never copy them or write code paths that work without them.
No way to run the game here: check with `tools/check.sh` (compiles every file, detects unknown globals and `ns.X` imported before its export)
and `tests/run.sh` (tests with the game faked by `tests/harness.lua`: a test replaces a name of `ns` between two files, never the code's text).
A change of the game logic comes with its test in `tests/test_*.lua`.
Roadbook solver: test bench `lua5.1 tools/bench.lua <SavedVariables or tools/cases/*.lua>` on a problem captured by `/fqp dump`;
`tools/bench_compare.sh` checks that a change leaves the routes of the saved cases as they are.

## Files (load order = `ForeverQuestPlanner.toc`)

| File | Content |
|---|---|
| `Locales/Locales.lua`, `Locales/frFR.lua` | `ns.L` table; French translations |
| `Data/Passes.lua` | walking passes between zones known without having walked them, completed by those learned (`Geo.Passes`): Warcraft Wiki rows `ns.PASSES`, QuestieDB patrol NPCs `ns.PASS_PATROLS` (listed by `tools/patrol_npcs.py`) |
| `Data/Supplements.lua` | what the data we read lacks or gets wrong, completed: faction of the transport lines OpenMap does not give one (`ns.TRANSPORT_SUPPLEMENT`, `ns.TRANSPORT_KIND_FACTION`, read through `Geo.Transports`), QuestieDB's quest categories (`ns.SORT_*`), profession headers, capitals (`ns.CITY_MAPS`), class teleport spells (`ns.RECALL_SPELLS`), start bind points (`ns.START_BINDS`), continent maps, recognised sub titles and mailbox names |
| `Data/GameData.lua` | fixed facts of the game (Classic rules): professions (`ns.PROFESSIONS`: name, text name, trainer words), `ns.XP_TABLE` |
| `Solver.lua` | Roadbook solver in pure Lua (no game API, also run by `tools/bench.lua`): XP formulas (`MobXP`, `QuestXP`), the only travel model, also used by the game: world (`S.World`, walks `S.WalkWay` / `S.WalkCost`, passes, danger, network `S.Network`, its shortest ways at a player level `S.Paths`, `S.Route` / `S.Travel`), level-ups `S.LevelUp`, route evaluation `S.Evaluate` (its walked legs: `res.legs`), goal value `S.Objective`, teleports `S.AddRecalls` / `S.Simulate`, objective order ranks `S.Ranks` / `S.RankPreds`, hunting spot variants `S.Variants`, optimizer `S.Optimize` (a search context passed to `S.Construct`, `S.LocalSearch` with its moves `S.Move*`, `S.DestroyAndRebuild`, `S.AddNearbyFlightMasters`; the list: order rules without cycles `S.Rules`, `S.ValidCustom`, `S.BuildCustom`, quests taken out with the steps needing them `S.WithoutQuests`; list with a duration or level: kept and completed or trimmed, `S.MixPrepare`, units `S.InsertUnit` / `S.WithoutUnit`; tuning `S.OPT`) |
| `Core.lua` | what every file shares: `Print`, errors told in the chat (`Guard` / `ErrorTrace`), `Color`, text normalisation for searches (`Normalize`), formats (`FormatTime`, `FormatNumber`, `MoneyText`, `CoinText`), bit test, `IsCompleted` / `IsInLog`, constants table `K`, `State` |
| `SavedData.lua` | saved data: `Settings` = the character's, `LearnedData` / `LearnedChar`, format numbers, erasing (`EraseData` / `CheckDataVersion`) |
| `QuestData.lua` | QuestieDB access (`QDB`, `QGet`, `AllIds`, `QuestAllowed`, `NpcFriendly`, `PlayerFaction`, `QuestPrereqs` / `AllPrereqs`, `QuestMeta`, `ChainInfo`), dependencies check (`InitDeps`), quest givers texts, professions of the character |
| `QuestLog.lua` | quest log capture (`Snapshot`, read only through `LogRecord` / `LogQuests` / `LogById` / `LogEntry`), the game's quest tag (`GameTag` / `TagKind`) |
| `QuestAnalysis.lua` | what a quest done in a group is, dungeon, raid or PvP (`QuestKind` / `LogKind` / `IdKind`, names `K.KIND_*` in `Core.lua`), every kind of a set of quests, in one order (`SetKinds`, `KindNames` / `KindTitle`), quest categories (`QuestCategory`), interest of the log quests' rewards, `Analyze()` (analysis of the last capture, without capturing: the caller calls `Snapshot()` first; returns copies of the captured quests: derived fields are never saved) |
| `OpenMapLink.lua` | the only file that knows OpenMap: checks at login (`OM.Init`), its data with named fields (flight nodes and paths, transports, instances, zone levels, learned flights), its worldmap functions, public API and pin sets, all as `ns.OM`. Nothing else reads the global `OpenMap` / `OpenMapAPI` |
| `QuestTags.lua` | loading of the quest data the game needs to give the tag of a quest out of the log: batches asked once per session (`RequestQuestTags` / `QuestTagsSettled` / `TagProgress`), event `QuestDataLoaded` |
| `Available.lua` | available quests: `CheckAvailable`, quests that keep one from being offered `QuestBlockers`, quests within reach `WithinReach`, frame-sliced scan `StartScan` / `scan` (results shown once their tags are loaded; to scan again: `MarkScanDirty`), wait for it `WaitScan`, scan started by a display `ScanIfNeeded` |
| `Geo.lua` | world coordinates, travel times, zone passes (`Geo.ZoneIdAt`, `Geo.Passes`, walks in the live world `Geo.WalkWay`, learning `Geo.PassTick`), flight nodes, transport lines and docks (named after their town `Geo.DockName`), directions `RouteText`, points (`Geo.CopyPoint`), travel speed (mount speed learned by `Geo.LearnMountSpeed`), quest targets (`QuestTargets`, quest giver places `Geo.StartPlaces` (the ones found empty left out: `Geo.DismissPlace` / `ForgetDismissedPlaces`), a quest giver's point `Geo.GiverPoint`) |
| `Planner.lua` | computations spread over frames (`Geo.RunSliced`, `Geo.Yield`; a protected call that may pause: `Geo.GuardInSteps`, never `pcall` or `ns.Guard`), Roadbook model: profession level to turn in (`Geo.SkillNeed`), Nearby items, XP / levels, monster spots, tasks, quests left out of the automatic choice (`Geo.LeftOut`), their follow-ups (`Geo.Followers` / `FollowUpIds`), waiting for tags in a computation (`Geo.AwaitTags`), what a quest is (`Geo.QuestTypes`, `Geo.IsFollowUp`, `Geo.LogTag`, `Geo.ToAbandon`), maximum level (`Geo.MaxLevel`), groups of the Available tab (`Geo.AvailableGroups`) |
| `Rewards.lua` | quest rewards: data (`Geo.QuestRewards` / `Geo.RewardItem`, index by item `Geo.RewardIndex`); they play no part in the Roadbook, chosen on XP and time |
| `Services.lua` | service NPCs: profession trainers (`Geo.SkillTrainers`), flight masters and innkeepers (`Geo.ScanServices`), nearest vendor / repair / trainer / bank / mailbox (`Geo.NearestService`) |
| `Route.lua` | Roadbook route: transport stops from the solver's legs (`Geo.TravelStep`, `Geo.LegSteps`, `Geo.AddTransportStops`, network of a leg of a saved route `Geo.NetFor`), hearthstone and class teleports (`Geo.RecallSources`, `RecallState`, `RecallStep`), planning with the solver (`Geo.Solve`, solver route -> game route `Geo.FromSolver`, history kept `Geo.KeepDone`), `Geo.RequestPlan` |
| `Custom.lua` | the Roadbook list: quests (`Geo.CustomAdd` / `CustomRemove`, `Geo.CustomChanged`), dungeon visits and order rules (`Geo.GroupDungeons`, `Geo.CustomConstraints`), steps on the spot first (`Geo.ApplyNearFirst`, steps possible by those rules `Geo.StepsReachable`), planning with the solver (whole list `Geo.PlanCustom`, "Generate" for a duration or level `Geo.PlanGenerate`, new list `Geo.AcceptGenerated`), the Roadbook tab's quests (`Geo.RoadbookQuests` / `Geo.RoadbookCategories`) |
| `Problem.lua` | the Roadbook problem read from the game for the solver: `Geo.Problem` (live: steps keep their game step in `src`), custom list `Geo.CustomPlanSteps`; the solver's world outside a computation `Geo.World` / `Geo.Net`; `/fqp dump` (`Geo.BenchDump`) captures it into `ForeverQuestPlannerBench` for `tools/bench.lua` |
| `UI/Tracking.lua` | quest tracking and map pins, the game's quest log (`OpenQuestDetails`), the world map (`Geo.OpenWorldMap`, `Geo.CombatNotice`), a quest shown at its place (`Geo.ShowQuestPlace`), abandoning a quest, "add / remove" buttons of the Roadbook list (`Geo.CustomToggle` / `CustomButton`) |
| `UI/QuestDesc.lua` | quest descriptions (`Geo.QuestTitle`, `Geo.DescLine`, badges, state icons, follow-ups `Geo.ChainLines`, `K.DESC`), state filters |
| `UI/ListEngine.lua` | window state, list engine (`RenderList`, `ListRow`, panes, click on a quest's line `Geo.QuestRowClick`), scrolling, searches, frame style of every window (`Geo.CreateWindow`) |
| `UI/Export.lua` | the quest log as text, to export |
| `UI/Tabs.lua` | Quest log (`RenderTodo`), Available (`RenderAvailable`, rewards line), Nearby (`RenderNear`) tabs |
| `UI/QuestLogHook.lua` | "+ Roadbook" button in the game's quest log (`Geo.QuestLogButtonInit` at login, `Geo.QuestLogButtonSync`) |
| `Roadbook.lua` | following the Roadbook, a new or adapted plan saved and redrawn (`Geo.AdoptPlan`), only the steps done kept (`Geo.KeepOnlyDone`), quests out of the list dropped after a failed computation (`Geo.DropUnlisted`), `CP` table: checkpoints/focus, auto-advance on game events (`CP.OnGameEvent`, one handler per kind of step in `STEP_EVENTS`), teleport cooldown checks (`CP.RecallCheck`, `CP.ScheduleRecallCheck`), Roadbook adapted `CP.Replan` (removed quest, skipped transport, quest giver found `CP.GiverFound`, steps on the spot first `CP.NearbyCheck`), step order `CP.StepReady` (order rules of the saved route `CP.RouteRules`), questions one window at a time (`CP.Ask` / `CP.Asked`), guards `CP.Busy` / `CP.RefuseWhileComputing` |
| `RoadbookStore.lua` | the saved Roadbook (`Geo.Freeze`, `Geo.Frozen`, `Geo.MarkDone`, steps removed or inserted with their levels only through `Geo.RouteRemove` / `RouteInsert`, `Geo.SaveRoute` after its steps change, saved fields `STEP_FIELDS` / `TASK_FIELDS`) |
| `ObjectiveButton.lua` | the floating Objective button: step description `CP.StepSummary` (title and list of parts; on one line for the chat: `CP.StepLine`), click, compass, service shortcuts |
| `RoadbookMap.lua` | Roadbook on OpenMap's map: map ownership (`Geo.MapClaim` / `MapRelease`, `Geo.MapOwner`; OpenMap's functions are called, never replaced), centering (`Geo.CenterMap`), drawing (`Geo.MapSync` / `MapDraw`) |
| `RoadbookPanel.lua` | Roadbook steps panel, a window of its own (`Geo.MapPanelSync`, header `Geo.MapPanelHeader`, placement `Geo.MapPanelPlace`, shown `Geo.MapPanelOpen` / `MapPanelShow`), step details `Geo.StepDetailLines` (tooltips of the panel and the map pins), right-click actions |
| `UI/Window.lua` | Roadbook tab (`RenderXP`: quests of the list `Geo.RoadbookQuestItems`), filter bars, `SelectTab`, `Refresh` |
| `UI/Settings.lua` | `K.PARAMS` and the settings window |
| `UI/MainFrame.lua` | `CreateMainFrame`, Roadbook tab controls `CreateRoadbookPanel` / `Geo.CreateGoalLine`, export to file, minimap button |
| `Debug.lua` | debugging commands `/fqp quest` (`QuestDiag`) and `/fqp npc` (`Geo.NpcInfo`), in English on purpose |
| `Events.lua` | event frame (`PLAYER_LOGIN` init, quest/taxi/zone events), `/fqp` commands |

Find code with `grep -n "function Name\|Name =" *.lua UI/*.lua` instead of reading whole files.

## Sharing names between files

- Each file starts with `local ADDON_NAME, ns = ...` and imports what it uses: `local A, B = ns.A, ns.B`.
  It ends with `-- Shared with the next files.` followed by `ns.X = X` for the locals other files use.
- A file can only import from files loaded before it. For a call to a later file, call `ns.Name()` at runtime
  (example: `Refresh` in `Available.lua` forwards to the real one in `UI/Window.lua`).
- Saved data: `Settings()` returns the character's own table (`ForeverQuestPlannerSettings.chars[CharKey()]`,
  one record per thing: `custom`, `roadbook`, `pin`, `mapSaved`, `dismissedPlaces`, `trackingPaused`);
  what is learned in game is apart, to be kept longer, in `LearnedData()` (zone passes, teleport arrivals, for
  every character) and `LearnedChar()` (mount speed, bind point: the current character's, dropped
  when the game's identifier of the character differs).
- No migration code: the code only knows the current form of the saved data. A change that makes saved data
  unusable (a field renamed, moved, of another type or meaning; not a new field that may be absent) raises the
  number of its set (`SavedData.lua`): `DATA_VERSION` for the characters' data and the captures, `LEARNED_VERSION` for
  what was learned (`LearnedData()`, `LearnedChar()` included). The addon then erases that set at login, for every character. The
  developer's own data is converted outside the game by a throwaway script, never committed.
- Mutable variables read by several files live in the `State` table (`State.mainFrame`, `State.currentTab`,
  `State.availFilter`, `State.xpHorizon`, `State.nearRadius`, search queries, the running computation
  `State.computing` / `State.co` / `State.planCbs`…). Never export a local that is reassigned later.
- Lua limits: 200 locals per function/file and 60 upvalues per function. That is why constants are in `K` and many
  functions are fields of `Geo` / `CP` instead of locals: add new functions there.

## Conventions

- Never drop an error: call the addon's own functions and the dependencies' through `ns.Guard` (as `pcall`, the error
  told in the chat once). Bare `pcall` is for the game calls expected to fail, and for a call that tells its own message.
- No new hand-written list or list row of game data (zones, quests, NPCs, words…): take it from the game or the
  dependencies, or learn it in game. The existing lists (`Data/`, and some in the code), which predate this rule,
  are still to be audited one by one; nothing is removed from them without the user's agreement.
- Correct or complete the input data, never special-case it in the game code: no `if` on one line, zone, NPC or quest
  in `Geo.lua`, `Route.lua`… One function per kind of data (example: `Geo.Transports`) reads the source's own value
  first, then the supplement of `Data/Supplements.lua` (with a comment citing its source), then a default.
  When the source gives the value itself, the supplement row is deleted and no code changes.

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
