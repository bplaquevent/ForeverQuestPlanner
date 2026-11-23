# Forever Quest Planner

An addon for **World of Warcraft: Forever** (client 1.60.1, Interface 16001) that helps you level through questing: it analyzes your quest log, finds the quests available around you and computes an optimized route, the **Roadbook**.

Available in **English** (default) and **French** (used automatically on a French client).

## Features

### Roadbook
- **One Roadbook** per character, saved with its progress, working one way only: the **fastest route doing every quest of its list** (see *Roadbook list*). Pick-ups, objectives and turn-ins, grouped by zone.
- **The list** is filled by hand (**Add** buttons) and/or by **Adapt**, with one of two options:
  - **a session of** 1 h, 2 h, 3 h or 4 h: a list shorter than that is kept whole and completed with the quests earning the most XP within the time; a longer one keeps only its quests earning the most XP within the time;
  - **level** (from your level + 1 to 10 levels above): the same, to reach that level the fastest;
  The list then becomes the quests of the adapted Roadbook (a confirmation first when quests of the list leave it); its steps done and its tracking are kept. The Roadbook always covers the whole list: it is computed at each quest added or removed, and the list cannot change while it is computed (the **Add** / **Remove** buttons are greyed). Afterwards, every computation only aims at doing the quests of the list in the least time: the duration or level only served to fill it.
- **Auto mode**: the **Auto** box (in the steps panel title bar and next to **Adapt** in the Roadbook tab) proposes each quest you accept for the list, a window asking each time (**Add** / **Ignore**). A quest you accept is not tracked in the objective tracker (unless it is the active step's quest), whatever your answer. Quests already in the log when it is turned on are not proposed.
- **Everything decided together**: the quests, their order, the hearthstone and class teleports, the binds and the flight masters to activate are chosen at once, each candidate Roadbook being simulated from start to end (travel, cooldowns, level reached at each step, XP at that level). The solver builds a first route, improves it (blocks of steps moved, quests added, removed or swapped), then takes parts of it apart and rebuilds them to escape bad early choices. The computation stops when nothing improves any more, or after 30 s at most (`K.PLAN_TIME`); the waiting messages show this limit, and you can keep playing meanwhile.
- Travel over the **real flight network** of WoW Forever (only the flight paths you have learned, flight time from the length of each path), the boats, zeppelins and airships of your faction (one-way lines included), with a penalty for zones that are too high for you. On foot, going from a zone to another goes through a **zone pass** (mountain pass, tunnel, bridge) rather than in a straight line over the mountains: the passes you walk through are **learned** (shared by all your characters), others come from QuestieDB's patrols crossing a border and from the Warcraft Wiki; zones with no known pass stay in a straight line. Flight network, transport lines and zone levels come from **OpenMap**; the flight paths you have learned are the ones OpenMap records at each flight master (open a flight master's map once).
- **Level forecast**: quest XP and monster XP (Classic formula, rested XP). **Every quest available** up to the level the Roadbook may reach is considered (not only the nearest ones); a quest is taken on from the level expected along the route (required level and "Max quest level" setting), with the XP it gives at that level.
- **Service shortcuts**: five icons under the Objective button (vendor, repair, class trainer, bank, mailbox). A click makes the nearest NPC or mailbox of that kind (by travel time) the priority objective: the Roadbook is computed again with the transport steps needed to reach it, then carries on optimally from there. The step is done when its window opens; a second click on the highlighted icon cancels it. Works without a quest list, too. Class trainers that QuestieDB gives no class are learned in game: targeting or hovering one (tooltip naming your class) or opening its window remembers it for the characters of that class.
- **Objectives in any order**: monsters to kill, items to loot and objects to use are done in the order that suits the route; talking to an NPC, an event, a place to reach or an escort keep their place among the objectives of their quest. With a far level goal, the Roadbook is a **stage** (up to 40 h): at its end, **Adapt** plans the next stage from your real level.
- **Quest chains** evaluated as a whole (XP, rewards and required level of every step).
- **Monster spots**: spawn points of the target monsters are grouped into hunting spots; the densest ones are tried along the route and the one costing the least (detour + hunting time, shorter where they are dense) is chosen. Items to loot: drop rates as Questie reads them (manual corrections, then private server data measured while on the quest, then Wowhead).
- **Hearthstone**: binding at an inn and hearthing back when it saves time. Until the hearthstone is first used, the bind point is guessed from its name (starting area of the race, innkeeper of the zone), shown with (~) when approximate.
- **Class teleports** (option): Astral Recall (shaman), mage teleports (Stormwind, Ironforge, Darnassus, Orgrimmar, Undercity, Thunder Bluff; limited by the Runes of Teleportation in the bags) and Teleport: Moonglade (druid) are used like the hearthstone when they save time, each with its own cooldown. The arrival of a teleport is learned after its first cast.
- **Steps on the spot first**: the walks are planned as straight lines, which can make the Roadbook leave a city and come back later. While the Roadbook is followed, in a capital the steps of the Roadbook that can be done now in that city (pick-ups, objectives, turn-ins, dungeons: quest ready, level reached, order rules kept) come before any step outside it; elsewhere, a step within 150 yards of you comes first. The Roadbook is adapted with them first; nothing is added.
- **Cooldowns always checked**: when a Roadbook is computed again, when its tracking starts again, and while it is followed (hearthstone or spell used outside the plan, cooldown reset, runes bought or used up, spell learned, new inn), the steps to come are adapted to where you are and to the cooldowns now; the steps done stay in the history.
- **Roadbook adapted**: when the route changes (position or cooldowns above, quest removed, transport skipped, quest giver found), the steps to come are planned again for every quest left of the list in the least time, the steps done stay in the history.
- **Quest givers moving between places**: a quest whose giver (a single NPC) has spawns in several places gets one pick-up step per place to check, all placed in the route like any other step. **Not here** marks a place checked; once the quest is picked up, the other places leave the Roadbook and it is adapted.
- **Profession levels**: a quest that needs a profession level to be turned in (e.g. Herbalism 20 for a profession introduction) is only turned in once that level is reached: "Adapt" leaves it out until then, a quest of the list gets a step "Raise the <profession> skill to level N" before its turn-in (time: setting "Time per skill point", pin on the nearest trainer of the profession, none when it is unknown), done automatically once the level is reached; the quest log tab shows the level needed.
- Steps to **activate unknown flight masters** when the flights they open save time (setting) and to **take transports**.
- Quests kept **for max level** (key, mount, epic item useless while leveling, access to an endgame dungeon).
- **Life cycle** (the Roadbook lives on its own, tracked or not: it is computed again at each change of the list, a step done ahead, a quest giver found elsewhere; the tracking only decides whether the Objective button, the map pin and the watched quest follow it):
  - **Adapt**: the list is completed or trimmed for the chosen option (the Roadbook itself has a single mode: every quest of the list in the least time, whatever filled the list) and the Roadbook computed again (a waiting animation shows the computation); its steps done and its tracking are kept. Adding a quest to the list makes the Roadbook the same way, even when there is none yet. Not available at max level (no XP to earn).
  - **Tracking** (box of the steps panel, or a click on the Objective button): turning it on computes the steps to come again from where you are (the steps done are kept) and the Objective button follows the Roadbook. Turned off, the Roadbook is only computed again by the Recompute icon of the panel or by a change of its list (steps done ahead, cooldowns… are ignored) and the steps of the panel are greyed; the steps and their progress are kept.
  - **Empty** (beside **Adapt** in the Roadbook tab, and title bar of the steps panel; after confirmation): its tracking stops, its steps and the list are emptied. It is the only way to empty the steps done.
  - At its end, its tracking stops, every step done, and it is kept as it is: it can no longer be tracked, only extended (quests added to the list), completed with **Adapt** or abandoned.
  - The steps done are checked and have no button (they cannot be removed or skipped). A click on a step, done or not, opens the world map centered on it with the Roadbook drawn; Shift-click: quest link in the chat.
- Changing the option of **Adapt** (each with its radio button) keeps the current Roadbook: it is used by the next **Adapt**.
- The Roadbook tab: the search box; below, a box with the options, **Adapt** and **Empty**. Under it, the **Quests** of the list with a fixed header (their number) above their own scrolling list, in the categories of the Quest log tab, with **Turned in** first (then to turn in, zones, dungeons, single quests, level too high; in a category, the quests of the log in its order, then the others by level), collapsed while the Roadbook is followed, each with a **Remove all** (except **Turned in**), then the quests kept for max level. Without a Roadbook, the tab explains how to make one. The steps of the Roadbook are in the **steps panel** (below); a right-click on the Objective button shows it.
- **Remove** a quest (in the quest list, or on one of its steps), after a confirmation: it leaves the list (with the prerequisites added only for it) and the Roadbook persists: the steps done are kept and the steps to come are computed again.
- **Order of a quest's steps**: the Objective button only follows a step that can be done now: a turn-in once the objectives of its quest are done, an objective once the quest is picked up, even when a later step was done ahead.
- **Steps done ahead** (quest picked up, objective done, quest turned in before its place): right after the current step, they are only checked; further on, the steps to come are computed again without them (a few seconds later, never in combat or in flight), tracked or not.
- **Quest abandoned** while the Roadbook plans it: a question offers to **remove it from the list** or to **pick it up again**; the steps to come are computed again either way (the steps done stay).

### Roadbook list
- Compose the list from the Quest log, Available and Around me tabs: **Add** / **Remove** on a quest, **Add all** / **Remove all** on a category (quests recommended for abandoning included). The **Roadbook list** filter of these tabs shows only the quests of the list. Any quest can be added (dungeon, raid, group, elite, gray, too high); the prerequisite quests it still needs are added with it (and removed with it).
- From the game's quest log too: the **+ Roadbook** / **- Roadbook** button (top of the quest details, beside **Back**) adds or removes the quest shown.
- The Roadbook is the **fastest route** doing the whole list: computed at each quest added or removed; it takes into account order constraints (pick-up, objectives, turn-in; prerequisites turned in before their follow-ups; required level), flights, zeppelins, boats, hearthstone, class teleports, and **flight masters worth activating** (an unknown flight master is added as a step when the flights it then allows save more time than the detour). A quest picked up below its required level, or an order rule the list cannot keep, gets a warning.
- **Dungeons**: every step of the list inside the same dungeon is done during **one visit**: all its quests are picked up first, then a single "Dungeon" step at the entrance lists what to do inside, then the turn-ins. A dungeon quest that needs another one turned in outside first goes to a second visit. The time spent inside is a setting (60 min by default).
- The quest list of the Roadbook tab also shows the quests of the list that cannot be planned (with the reason), and **Remove all** on a category takes its quests out of the list.
- Adding or removing a quest computes again only the steps to come: the steps done stay first, as they were (the current objective is kept if it is still in the route; an emptied list removes the steps to come and keeps the steps done); quests turned in leave the list. At the end of the list, the tracking stops; adding quests extends the Roadbook.

### On the map (OpenMap)
- While a Roadbook is followed, it is **alone on OpenMap's world map**: its remaining steps as numbered pins (colour by kind: pick up, objective, turn in, dungeon, other), joined by its route (on foot in gold, through the zone passes; flights in blue, boats and zeppelins in teal, hearthstone in purple and teleport spells in pink, these two as a thin straight line from where you leave to where you arrive), the **current objective** highlighted. A line also runs from **your position to the next step** (on foot, or the jump of the hearthstone or teleport to cast) and follows you while the map is open. The pins follow its progress; hover one for the step's description, click it to open the Roadbook.
- Setting **Whole Roadbook on the map** (Roadbook settings, or OpenMap's menu): off, only the current objective is shown.
- **Steps panel**: a window of its own, independent of the map, moved with Shift-drag (as the Objective button) and resized by the handle in the middle of its bottom edge; a right-click on the Objective button shows or hides it. Its **Info** box shows or hides its header: number of quests, steps finished and duration; XP and XP per hour; hearthstone and teleports; then what to watch, one line each (no flight master recorded, quests that cannot be planned, flight paths to activate). Then every step of the Roadbook (**Hide the finished steps**, always shown, keeps only the ones to do), numbered as the pins, those done checked, the current objective highlighted and scrolled to. The **Tracking** box turns the tracking on or off, the red cross icon empties the Roadbook (title bar); the circular-arrow icon next to it (greyed unless it is tracked) plans the steps to come again from where you are (steps done and tracking kept). Each step shows its own duration (the way from the previous step and what is done there). Hover a step for its details (what to do and where, XP and duration, notes, quests of a dungeon, the way from the previous step, level reached); click it to open the map on it (or glide the map there) and open its quest in the quest log; right-click it for its actions (**Remove the quest**, **Not here**, **Skip**).
- **Objective button**: while the Roadbook is computed with no step followed (being computed…), it shows *Recomputing…* and a click does nothing; while a followed Roadbook is adapted (step done ahead, cooldowns changed…), the next step stays shown, with *Recomputing…*, and can be clicked: it is replaced a few seconds later if the new plan starts elsewhere. Otherwise a click starts the Roadbook when it is not followed and shows the steps panel; once followed, a click opens the world map on the followed step (centered on its marker, the Roadbook drawn, its quest opened in the quest log), or closes it when it is already open; a right-click shows or hides the steps panel. Hover it for a reminder.
- The Roadbook owns its pins and route: OpenMap cannot edit or delete them. While it holds the map (followed or previewed), **your OpenMap pins are hidden** and no pin can be added (Ctrl-click, pin button); when it lets go (tracking off, end, emptied, preview closed, or at the next login after a /reload), your pins come back as they were, and so does the waypoint you followed before.
- The pins are drawn on OpenMap's stitched map: with OpenMap's map turned off, nothing is drawn.

### Focus and floating button
- The floating **Objective** button follows a step (exclusive tracking + OpenMap's waypoint, compass pointing at it).
- Each Roadbook step of a quest has a **Remove** button (the whole quest leaves the Roadbook and the route is adapted, see above, after a confirmation). The followed hearthstone or teleport step has a **Skip** button: the step is just marked done. **Skip** on the followed transport step marks it done and adapts the Roadbook without that transport for the way to the next step (only this time). A place to check for a quest giver has a **Not here** button.
- Automatically moves to the next step (quest picked up, objective done, quest turned in, flight master activated, take-off, zeppelin or boat arrival, hearthstone or class teleport, or arrival at the hearthstone's inn by any other way: Astral Recall, teleport, on foot…).
- Movable floating button showing a summary of the current step:
  - **click**: starts the Roadbook (empty: opens its tab, where it is made); once followed, opens the game's quest log on the quest of the current step, or the world map centered on the step's pin when no quest of the log goes with it;
  - **Shift-drag**: move the button.

### Other tabs
- **Around me**: quests to turn in, quests in progress (with their nearby steps) and available quests within 200 m, 500 m, 1500 m or the whole zone.
- **Quest log**: quests by category, abandon recommendations (class, profession, XP, items, chain, money) (**Add** and **Map** buttons, trash icon at the left of the quest to abandon it), text export.
- **Available**: quests you can pick up at your level, by zone, dungeons, class and professions; missing prerequisites (previous quest, profession, reputation) are listed. Zone and dungeon categories (here and in the Quest log) show their level range, coloured for your level; so does the "Dungeon" badge of a quest.
- Search box centered at the top of every tab; below it, a box with the filters (radius or quest kind as a dropdown, low-level quests, state check boxes); collapsible categories.
- Icons in front of the quest titles: to turn in, in progress, tracked, pin, to pick up, turned in (green check), in the Roadbook list (yellow star), recommended for abandoning (red cross).
- **Map** button on every quest: sets OpenMap's waypoint on its place (quest giver, or the monsters dropping the item that starts it; nearest remaining objective; turn-in) and opens the world map on it. While a Roadbook is followed, the map only opens there (the Roadbook keeps the waypoint).
- **Shift-click** a quest in any tab: its quest link goes into the chat (the game's link for quests of your log, the same link built from QuestieDB otherwise).
- **Minimap icon**: click opens the window on the Roadbook tab (or closes it); right-click: settings; drag: move it.
- **Settings** (gear icon): General (minimap icon) and Roadbook (objective button: show, compass, center; hearthstone; class teleports; activate nearby flight masters (every unknown flight master within 500 yards of a step is activated, even without a gain for this Roadbook; farther ones only when they save time); whole Roadbook on the map; difficulty, time estimates including the time per profession skill point) panels.

## Dependencies

Both are required: the addon does not start without them.

- **[QuestieDB](https://github.com/Questie/QuestieDB)**: positions, XP, quest chains, monsters, items.
- **[OpenMap](https://github.com/openmap-world/openmap)**: WoW Forever's flight network and the flight paths you have learned, boat, zeppelin and airship lines, dungeon entrances with their level range, zone level ranges (shown next to zone names, coloured for your level); its waypoint and its world map, where the Roadbook is drawn.

Optional: **Questie**.

## Installation

1. Download or clone this repository into `World of Warcraft\_forever_\Interface\AddOns\`.
2. Make sure the folder is named exactly `ForeverQuestPlanner`.
3. Start the game (or `/reload`).

Settings and Roadbooks are saved per character; only what the addon learns about the world (zone passes
walked, places reached by the teleport spells) is shared by all your characters.

## Commands

| Command | Effect |
|---|---|
| `/fqp` | Open / close the window |
| `/fqp roadbook` | Open the Roadbook tab |
| `/fqp log` | Open the Quest log tab |
| `/fqp available` | Open the available quests |
| `/fqp around` | Open "Around me" |
| `/fqp settings` | Open the settings |
| `/fqp hearth` | Use / ignore the hearthstone in the Roadbook |
| `/fqp teleport` | Use / ignore the class teleports in the Roadbook |
| `/fqp export` | Export the quest log as text |
| `/fqp save` | Save the quest log to the SavedVariables (reloads the UI) |
| `/fqp trace` | Show the last lines of the Roadbook trace (changes of the plan, steps marked, focus, list); `/fqp trace on` / `off` records it or not (off by default, to send with a bug report), `/fqp trace clear` empties it. The last 300 lines are kept in the SavedVariables |
| `/fqp icon` | Show / hide the minimap icon |
| `/fqp passes` | Number of zone passes known (learned on foot, in all) |
| `/fqp passes reset` | Forget the zone passes learned on foot |
| `/fqp npc` | Diagnose the targeted NPC for the service shortcuts (class trainer data) |
| `/fqp dump` | Capture the Roadbook problem for the test bench (then `/reload`) |

The French command names (`journal`, `dispo`, `autour`, `reglages`, `foyer`) still work.

## Test bench

The Roadbook solver (`Solver.lua`) is plain Lua: it also runs outside the game, on a problem captured in game.

1. In game: `/fqp dump`, wait for the "capture done" message, then `/reload` (the capture goes to the
   `ForeverQuestPlannerBench` SavedVariable: world model, character, candidate quests, Roadbooks of the planner).
2. Here: `lua5.1 tools/bench.lua <WTF/Account/<ACCOUNT>/SavedVariables/ForeverQuestPlanner.lua> [--steps]`
   evaluates the Roadbooks of the planner with the solver (in-game accounting, then the full model: flight paths
   activated on the way, cooldowns, danger and XP at the level reached).
3. `--list <N> --goal time:<seconds>|level:<level>` runs "Adapt" on a list made of the first N captured quests
   (kept whole and completed, or trimmed).
4. `--save <name>` keeps the problem as a test case in `tools/cases/`; `tools/cases/synthetic.lua` is a small one.

## Localization

All texts are in English in the code. Translations live in `Locales/`:

- `Locales/Locales.lua`: localization table (a missing translation shows the English text);
- `Locales/frFR.lua`: French translation.

To add a language, copy `frFR.lua`, change the locale code and translate the values.

## Limitations

- Positions, drop rates and quest chains come from QuestieDB, travel data from OpenMap: missing or wrong data ends up in the plan.
- FQP reads OpenMap's own data tables, which are not its documented API: a change there is reported at login (the addon then stays off until it is updated).
- Times are estimates (30 s per monster by default, configurable).
- Quests that take place inside a dungeon instance are not planned.

## Reporting bugs and ideas

Bugs and feature requests are tracked in the [GitHub Issues](https://github.com/bplaquevent/ForeverQuestPlanner/issues).
Mention the addon version (`## Version` in the `.toc`). For a problem in a Roadbook plan, attach a `/fqp dump`
capture (see [Test bench](#test-bench)).

## License

[MIT](LICENSE)
