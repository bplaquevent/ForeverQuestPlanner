# Forever Quest Planner

An addon for **World of Warcraft: Forever** (client 1.60.1, Interface 16001) that helps you level through questing: it analyzes your quest log, finds the quests available around you and computes an optimized route, the **Roadbook**.

Available in **English** (default) and **French** (used automatically on a French client).

## Features

### Roadbook
- Quest route optimized for **XP only**, with two goals: **for a play session** of 1 h, 2 h or 4 h (the most XP within that time) or **to reach a level** (from your level + 1 to the max level: the fastest route to it). Pick-ups, objectives and turn-ins, grouped by zone.
- Travel over the **real flight network** of WoW Forever (only the flight paths you have learned, flight time from the length of each path), the boats, zeppelins and airships of your faction (one-way lines included), with a penalty for zones that are too high for you. On foot, going from a zone to another goes through a **zone pass** (mountain pass, tunnel, bridge) rather than in a straight line over the mountains: the passes you walk through are **learned** (account-wide), others come from QuestieDB's patrols crossing a border and from the Warcraft Wiki; zones with no known pass stay in a straight line. Flight network, transport lines and zone levels come from **OpenMap**; the flight paths you have learned are the ones OpenMap records at each flight master (open a flight master's map once).
- **Level forecast**: quest XP and monster XP (Classic formula, rested XP). Quests are taken on from the level expected along the route (required level and "Max quest level" setting), with the XP they give at that level. With a far level goal, the Roadbook is a **stage** (up to ~300 quests / 40 h): at its end, **Generate** plans the next stage from your real level.
- **Quest chains** evaluated as a whole (XP, rewards and required level of every step).
- **Monster spots**: spawn points are grouped into hunting spots and the most efficient spot is chosen (travel + density).
- **Hearthstone**: binding at an inn and hearthing back when it saves time.
- Steps to **activate unknown flight masters** met on the way (setting) and to **take transports**.
- Quests kept **for max level** (key, mount, epic item useless while leveling, access to an endgame dungeon).
- **Quick wins**: a quest ready to turn in next to a step is added to the plan.
- **Two Roadbooks**, each in its own tab and saved with its progress: **Roadbook auto** (the quests giving the most XP for the selected goal) and **Roadbook perso** (custom, see below).
- **Active Roadbook**: there is always one (the automatic one by default), the one the Objective button follows. Its tab shows a green light before its title: pulsing while the Roadbook is followed, steady while paused. The only way to change it is **Start** on the other Roadbook (see below). It stays active, even after a /reload.
- **Life cycle** (buttons of each Roadbook tab, on the Roadbook of the tab):
  - **Generate** (automatic Roadbook only): it is emptied and computed again (a waiting animation shows the computation). If a Roadbook already exists, a confirmation warns that it is replaced; the new one is not started (**Start**); the automatic Roadbook is only computed with this button, never automatically.
  - **Start**: this Roadbook becomes the active one and the Objective button follows it (if the other one was followed, a confirmation pauses it first; Cancel: nothing changes). It is matched to where you are: the next transport steps whose destination you already reached are done, and a flight or boat far from you is replaced by the route from here.
  - **Pause**: only the tracking stops; the steps and their progress are kept, and it stays the active Roadbook.
  - **Delete** (after confirmation): its tracking stops, its steps are emptied, and the quest list too for the custom Roadbook. It is the only way to empty the steps done.
  - At its end, the Roadbook is paused, every step done, and kept as it is: it can no longer be started, only extended (quests added to the custom Roadbook), generated again (automatic Roadbook) or deleted.
  - The steps done are checked and have no button (they cannot be removed or skipped). A click on a step, done or not, opens the world map centered on it with the Roadbook drawn; Shift-click: quest link in the chat.
- Changing the goal (**Session of** 1 h / 2 h / 3 h / 4 h, or **Reach level**, up to 10 levels above yours, each with its radio button and dropdown) keeps the current Roadbook: the new goal is used by the next **Generate**.
- **Skip the step**: a quest step skips the whole quest (pick-up, objectives, turn-in), after a confirmation. The Roadbook persists: the steps done are kept and the route of the steps left is adapted (travel, flights, hearthstone), without adding quests. The skipped quest comes back only with a new Roadbook.

### Custom Roadbook
- Compose your own list from the Quest log, Available and Around me tabs: **Add** / **Remove** on a quest, **Add all** / **Remove all** on a category (quests recommended for abandoning included). The **Custom Roadbook** filter of these tabs shows only the quests of the list. Any quest can be added (dungeon, raid, group, elite, gray, too high); the prerequisite quests it still needs are added with it (and removed with it).
- From the game's quest log too: the **+ Roadbook** / **- Roadbook** button (top of the quest details, beside **Back**) adds or removes the quest shown.
- The **fastest route** to do the whole list is computed again at each quest added or removed (no **Generate** button); it takes into account order constraints (pick-up, objectives, turn-in; prerequisites turned in before their follow-ups; required level), flights, zeppelins, boats, hearthstone, and **flight masters worth activating** (an unknown flight master is added as a step when the flights it then allows save more time than the detour).
- **Dungeons**: every step of the list inside the same dungeon is done during **one visit**: all its quests are picked up first, then a single "Dungeon" step at the entrance lists what to do inside, then the turn-ins. A dungeon quest that needs another one turned in outside first goes to a second visit. The time spent inside is a setting (60 min by default).
- The Roadbook tabs: the search box in the middle, **Map**, **Start / Pause** and **Delete** on the right; the automatic tab adds, below, a box with the goal and **Generate**. The header of the list shows the state of the Roadbook (active, paused, not started, finished). The list shows **Quests** (custom tab, collapsible) and **Objectives**; an empty Roadbook shows, under **Objectives**, how to make one. While the Roadbook is followed, opening it collapses the quest list and expands only the section of the current step.
- Adding or removing a quest computes again only the steps to come: the steps done stay first, as they were (the current objective is kept if it is still in the route; an emptied list removes the steps to come and keeps the steps done); quests turned in leave the list. At the end of the list, the Roadbook is paused; adding quests extends it.

### On the map (OpenMap)
- While a Roadbook is followed, it is **alone on OpenMap's world map**: its remaining steps as numbered pins (colour by kind: pick up, objective, turn in, dungeon, other), joined by its route (on foot in gold, through the zone passes; flights and boats in blue), the **current objective** highlighted. The pins follow its progress; hover one for the step's description, click it to open the Roadbook.
- Setting **Whole Roadbook on the map** (Roadbook settings, or OpenMap's menu): off, only the current objective is shown.
- **Map** button of a Roadbook tab: a **preview** of that Roadbook (followed or not) on the map, framed on all its steps; a second click or closing the map ends it. The Forever Quest Planner window stays open.
- **Steps panel** beside the map window (shown or hidden from OpenMap's menu: *Roadbook steps beside the map*): every step of the Roadbook holding the map (else the active one), numbered as the pins, those done checked, the current objective highlighted and scrolled to. Its **Show** button opens the Roadbook in the addon's window; its **Start / Pause** button starts the active Roadbook or pauses it (hidden while an inactive Roadbook is previewed). Hover a step for its description, click it to glide the map there and open its quest in the quest log (quests of your log). With no room on the right of the screen (full-screen map), it sits over the map's right side.
- The Roadbook owns its pins and route: OpenMap cannot edit or delete them. While it holds the map (followed or previewed), **your OpenMap pins are hidden** and no pin can be added (Ctrl-click, pin button); when it lets go (pause, end, deletion, preview closed, or at the next login after a /reload), your pins come back as they were, and so does the waypoint you followed before.
- The pins are drawn on OpenMap's stitched map: with OpenMap's map turned off, nothing is drawn.

### Focus and floating button
- The floating **Objective** button follows a step (exclusive tracking + OpenMap's waypoint, compass pointing at it).
- Each Roadbook step of a quest has a **Skip the step** button (the whole quest is skipped and the route adapted, see above, after a confirmation). In the custom Roadbook, the quest leaves the list (**Remove**, after a confirmation). The followed hearthstone or transport step has a **Skip** button: the step is just marked done.
- Automatically moves to the next step (quest picked up, objective done, quest turned in, flight master activated, take-off, zeppelin or boat arrival, hearthstone, or arrival at the hearthstone's inn by any other way: Astral Recall, teleport, on foot…).
- Movable floating button showing a summary of the current step:
  - **click**: starts the active Roadbook, then follows its objective (active Roadbook empty: opens its tab, where it is generated or filled);
  - **Ctrl-click**: pause the active Roadbook;
  - **Shift-click**: link of the quest in the chat;
  - **Ctrl-Alt-click**: skip the step (a quest step skips the whole quest, after a confirmation);
  - **Shift-drag**: move the button;
  - **Shift-right-click**: center the button horizontally;
  - **right-click**: open the tab of the active Roadbook.

### Other tabs
- **Around me**: quests to turn in, quests in progress (with their nearby steps) and available quests within 200 m, 500 m, 1500 m or the whole zone.
- **Quest log**: quests by category, abandon recommendations (class, profession, XP, items, chain, money) (**Add** and **Map** buttons, trash icon at the left of the quest to abandon it), text export.
- **Available**: quests you can pick up at your level, by zone, dungeons, class and professions; missing prerequisites (previous quest, profession, reputation) are listed. Zone and dungeon categories (here and in the Quest log) show their level range, coloured for your level; so does the "Dungeon" badge of a quest.
- Search box centered at the top of every tab; below it, a box with the filters (radius or quest kind as a dropdown, low-level quests, state check boxes); collapsible categories.
- Icons in front of the quest titles: to turn in, in progress, tracked, pin, to pick up, in the custom Roadbook (yellow star), recommended for abandoning (red cross).
- **Map** button on every quest: sets OpenMap's waypoint on its place (quest giver, or the monsters dropping the item that starts it; nearest remaining objective; turn-in) and opens the world map on it. While a Roadbook is followed, the map only opens there (the Roadbook keeps the waypoint).
- **Shift-click** a quest in any tab: its quest link goes into the chat (the game's link for quests of your log, the same link built from QuestieDB otherwise).
- **Settings** (gear icon): General (minimap icon) and Roadbook (objective button: show, compass, center; hearthstone; activate nearby flight masters; whole Roadbook on the map; difficulty, time estimates) panels.

## Dependencies

Both are required: the addon does not start without them.

- **[QuestieDB](https://github.com/Questie/QuestieDB)**: positions, XP, quest chains, monsters, items.
- **[OpenMap](https://github.com/openmap-world/openmap)**: WoW Forever's flight network and the flight paths you have learned, boat, zeppelin and airship lines, dungeon entrances with their level range, zone level ranges (shown next to zone names, coloured for your level); its waypoint and its world map, where the Roadbook is drawn.

Optional: **Questie**.

## Installation

1. Download or clone this repository into `World of Warcraft\_forever_\Interface\AddOns\`.
2. Make sure the folder is named exactly `ForeverQuestPlanner`.
3. Start the game (or `/reload`).

## Commands

| Command | Effect |
|---|---|
| `/fqp` | Open / close the window |
| `/fqp roadbook` | Open the tab of the active Roadbook |
| `/fqp log` | Open the Quest log tab |
| `/fqp available` | Open the available quests |
| `/fqp around` | Open "Around me" |
| `/fqp settings` | Open the settings |
| `/fqp hearth` | Use / ignore the hearthstone in the Roadbook |
| `/fqp export` | Export the quest log as text |
| `/fqp save` | Save the quest log to the SavedVariables (reloads the UI) |
| `/fqp icon` | Show / hide the minimap icon |
| `/fqp passes` | Number of zone passes known (learned on foot, in all) |
| `/fqp passes reset` | Forget the zone passes learned on foot |

The French command names (`journal`, `dispo`, `autour`, `reglages`, `foyer`) still work.

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

## License

[MIT](LICENSE)
