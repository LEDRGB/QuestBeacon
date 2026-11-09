# QuestBeacon

A World of Warcraft: **Forever** addon that points you at what your quests still need.

- **Arrow on screen** that turns towards the nearest quest object (crates, plants, chests…) or quest mob spawn you still need, with its name, your progress (`3/8`) and the distance. The distance is green when close, yellow at mid range and red when far. Gold arrow = object, red arrow = mob.
- **Glowing nameplates** on enemies you need for a quest.
- **Follow one quest**: focus a quest in Questie's tracker, or middle-click the arrow, and it only points at that quest's targets.
- **Map pin** on the current target, plus a sound when you get there.
- Optional **interact icons**: turns on the game's own soft-target icons, which float over usable objects near you.

Why an arrow and not glowing objects like in retail? Addons can't change how the 3D world is drawn, and Forever doesn't show Blizzard's floating waypoint marker. An arrow is the closest an addon can get.

## Requirements

- WoW **Forever** client (interface `16001`).
- [**Questie**](https://github.com/Questie/Questie) installed and enabled. QuestBeacon reads quest and spawn data from it.

## Install

The addon folder **must be named `QuestBeacon`** and go in:

```
World of Warcraft/_forever_/Interface/AddOns/QuestBeacon/
```

### With Claude Code

Open [Claude Code](https://claude.com/claude-code) on the computer where WoW is installed and paste:

> Install the QuestBeacon WoW addon from https://github.com/LEDRGB/QuestBeacon into my WoW Forever addons folder (`World of Warcraft/_forever_/Interface/AddOns/QuestBeacon`). Find where my WoW is installed first. Check that Questie is installed there too. If a QuestBeacon folder already exists, update it instead of duplicating it. Then tell me to type /reload in game.

Claude will locate your install, clone or download the repo into the right folder and check that Questie is installed. To update later, ask the same thing again.

### Manually

1. Go to [Releases](https://github.com/LEDRGB/QuestBeacon/releases) and download `QuestBeacon.zip` from the latest release.
2. Unzip it into `World of Warcraft/_forever_/Interface/AddOns/`. You should end up with `AddOns/QuestBeacon/QuestBeacon.toc`.
3. Start the game (or type `/reload` if you're already in) and check that QuestBeacon and Questie are ticked in the AddOns list on the character screen.

If you use **Code → Download ZIP** instead of the release, the folder is called `QuestBeacon-main`. Rename it to `QuestBeacon` or the game won't load it.

With git (from the `AddOns` folder):

```sh
git clone https://github.com/LEDRGB/QuestBeacon.git
# update later:
git -C QuestBeacon pull
```

## Using it

| Action | What it does |
|---|---|
| Drag the arrow | Move it anywhere (position is saved) |
| Mouse wheel on the arrow | Bigger / smaller |
| Right-click | Skip to the next spot |
| Shift + right-click | Skip this kind of object for 10 minutes |
| Middle-click | Follow only this quest / back to all quests |
| Hover | Shows the quest and the controls |

Key bindings are under **Key Bindings → QuestBeacon**: skip to next spot, skip object type, follow quest.

Slash commands (`/beacon` or `/glow`):

| Command | Effect |
|---|---|
| `/beacon` | Everything on/off |
| `/beacon follow` | Follow the current target's quest (toggle) |
| `/beacon focus` | Use Questie's tracker focus on/off |
| `/beacon mobs` | Also point at quest mobs on/off |
| `/beacon arrow` / `glow` / `beacon` | Arrow / nameplate glow / map pin on/off |
| `/beacon size 1.5` | Arrow size (0.4–4) |
| `/beacon lock` | Lock the arrow against dragging and resizing |
| `/beacon sound` | Arrival sound on/off |
| `/beacon interact` / `interact off` | Game's floating interact icons on/off |
| `/beacon skip` / `skiptype` | Same as right-click / Shift+right-click |
| `/beacon reset` | Clear skips, default arrow position and size |
| `/beacon debug` | Print what it's tracking (send this when reporting a bug) |

### How it picks a target

Every second it collects every spawn point of every unfinished objective in your quest log, using Questie's data. Then it drops some:

- spots on another continent, or more than 2000 yards away
- spots you just reached: within 6 yd for objects and 20 yd for mobs, skipped for 5 minutes
- spots or object types you skipped

It points at the closest one left. If you follow a quest, only that quest counts. Once that quest has nothing left, it goes back to all quests.

Questie knows where mobs *spawn*, not where they are right now, so for mobs the arrow takes you to the area they live in.

## Development

The logic is tested offline with a stubbed WoW API and fake Questie data:

```sh
luajit tests/test.lua QuestBeacon.lua
```

## License

MIT, see [LICENSE](LICENSE).
