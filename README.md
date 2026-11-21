# Forever Quest Planner

An addon for **World of Warcraft: Forever** (client 1.60.1, Interface 16001) that helps you level through questing: it analyzes your quest log, finds the quests available around you and computes an optimized route, the **Roadbook**.

Available in **English** (default) and **French** (used automatically on a French client).

## Features

### Roadbook
- Optimized quest route for a **1 h, 2 h or 4 h** session: pick-ups, objectives and turn-ins, grouped by zone.
- Travel using your **known flight masters**, zeppelins and boats, with a penalty for zones that are too high for you.
- **Level forecast**: quest XP and monster XP (Classic formula, rested XP); quests that are too high for now are placed after the level-up.
- **Quest chains** evaluated as a whole (XP, rewards and required level of every step).
- Configurable **priorities**: class quests, blue rewards or rewards suited to your specialization, bags, unlocks…
- **Monster spots**: spawn points are grouped into hunting spots and the most efficient spot is chosen (travel + density).
- **Hearthstone**: binding at an inn and hearthing back when it saves time.
- Steps to **activate unknown flight masters** and to **take transports**.
- Quests kept **for max level** (key, mount, epic item useless while leveling, access to an endgame dungeon).
- **Quick wins**: a quest ready to turn in next to a step is added to the plan.
- **Saved plan**: it no longer changes until the end or until you ask for a recompute (**Start** button).
- Two modes, chosen at the top of the Roadbook tab: **Automatic** (the quests giving the best XP for the duration) and **Custom** (see below). Each mode keeps its own saved plan; **Start** computes the plan of the selected mode and follows its first step.

### Custom Roadbook
- Compose your own list from the Quest log, Available and Around me tabs: **Add** / **Remove** on a quest, **Add all** / **Remove all** on a category (a quest recommended for abandoning must be kept first). The **Custom Roadbook** filter of these tabs shows only the quests of the list. Any quest can be added (dungeon, raid, group, elite, gray, too high); the prerequisite quests it still needs are added with it (and removed with it).
- **Start** computes the **fastest route** to do the whole list: order constraints (pick-up, objectives, turn-in; prerequisites turned in before their follow-ups; required level), flights, zeppelins, boats, hearthstone, and **flight masters worth activating** (an unknown flight master is added as a step when the flights it then allows save more time than the detour).
- **Dungeons**: every step of the list inside the same dungeon is done during **one visit**: all its quests are picked up first, then a single "Dungeon" step at the entrance lists what to do inside, then the turn-ins. A dungeon quest that needs another one turned in outside first goes to a second visit. The time spent inside is a setting (60 min by default).
- The Roadbook tab shows two sections: **My quest list** (collapsible) and **Route**.
- Adding or removing a quest while the custom Roadbook is followed computes it again (the current objective is kept if it is still in the route); quests turned in leave the list. The Objective button stops at the end of the list.

### Focus and floating button
- The floating **Objective** button follows a step (exclusive tracking + pin, compass pointing at it).
- Each Roadbook step of a quest has a **Remove from the Roadbook** button (the whole quest, then a new Roadbook); removed quests can be added back from the settings. In the custom Roadbook, the quest leaves the list.
- Automatically moves to the next step (quest picked up, objective done, quest turned in, flight master activated, take-off, zeppelin or boat arrival, hearthstone…).
- Movable floating button showing a summary of the current step:
  - **click**: follow the objective (no Roadbook yet: starts the one of the selected mode);
  - **Ctrl-click**: stop following the objective;
  - **Shift-click**: link of the quest in the chat;
  - **Alt-click**: new Roadbook;
  - **Ctrl-Alt-click**: remove the step from the Roadbook (a dungeon or transport step is skipped);
  - **Shift-drag**: move the button;
  - **Shift-right-click**: center the button horizontally;
  - **right-click**: open the Roadbook.

### Other tabs
- **Around me**: quests to turn in, steps in progress and available quests within 200 m, 500 m, 1500 m or the whole zone.
- **Quest log**: quests by category, abandon recommendations (class, profession, XP, items, chain, money), text export.
- **Available**: quests you can pick up at your level, by zone, dungeons, class and professions; missing prerequisites (previous quest, profession, reputation) are listed.
- Search, state filters, collapsible categories.
- **Map** button on every quest: places the map pin on its place (quest giver, or the monsters dropping the item that starts it; nearest remaining objective; turn-in) and opens the world map on it.
- **Shift-click** a quest in any tab: its quest link goes into the chat (the game's link for quests of your log, the same link built from QuestieDB otherwise).
- **Settings** (gear icon): General (minimap icon), Quest log ("Keep" list) and Roadbook (objective button: show, compass, center; hearthstone; priorities, look-ahead, time estimates) panels.

## Dependencies

- **[QuestieDB](https://github.com/Questie/QuestieDB)** (strongly recommended): positions, XP, quest chains, monsters, items. Without it, only the quest log and the export work.
- **Questie** (optional).

## Installation

1. Download or clone this repository into `World of Warcraft\_forever_\Interface\AddOns\`.
2. Make sure the folder is named exactly `ForeverQuestPlanner`.
3. Start the game (or `/reload`).

## Commands

| Command | Effect |
|---|---|
| `/fqp` | Open / close the window |
| `/fqp roadbook` | Open the Roadbook |
| `/fqp log` | Open the Quest log tab |
| `/fqp available` | Open the available quests |
| `/fqp around` | Open "Around me" |
| `/fqp settings` | Open the settings |
| `/fqp hearth` | Use / ignore the hearthstone in the Roadbook |
| `/fqp export` | Export the quest log as text |
| `/fqp save` | Save the quest log to the SavedVariables (reloads the UI) |
| `/fqp icon` | Show / hide the minimap icon |
| `/fqp reset` | Clear the quests kept despite the abandon recommendation |

The French command names (`journal`, `dispo`, `autour`, `reglages`, `foyer`) still work.

## Localization

All texts are in English in the code. Translations live in `Locales/`:

- `Locales/Locales.lua`: localization table (a missing translation shows the English text);
- `Locales/frFR.lua`: French translation.

To add a language, copy `frFR.lua`, change the locale code and translate the values.

## Limitations

- Positions, drop rates and quest chains come from QuestieDB: missing or wrong data ends up in the plan.
- Times are estimates (30 s per monster by default, configurable).
- Quests that take place inside a dungeon instance are not planned.

## License

[MIT](LICENSE)
