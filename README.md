# Rogue's Oath

A 2–6 player real-time co-op tile-grid roguelike — permadeath, short runs, no turns — whose
hook is the **Commitment Rule**: decisions are irrevocable the moment you make them. Every
action has a duration and plays to completion; the server is the referee. Godot 4.x, 2D
top-down. By Jon & Jeff.

## Patch notes & builds

Each version's patch notes live on the
[Releases page](https://github.com/jonathanlake/rogues_oath/releases); playable Windows
builds are attached to release entries (e.g. `rogues_oath_v0.18.0.exe`). The full changelog
lives in [`docs/design-changelog.md`](docs/design-changelog.md).

## Running from source

The `assets/32rogues/` sprite pack is **not in this repo** — it's a licensed asset pack
([32rogues by Seth Boyles](https://sethbb.itch.io/32rogues)) whose license bars
redistribution, so it stays local to each dev machine (exported game builds may contain it;
that's the licensed use). Before opening the project in Godot (4.7+), drop the `32rogues`
folder into `assets/` — get it from Jon, or buy it on itch.io. Without it the project will
not load.

## Where everything lives

Not sure which doc to open? Start here.

| Doc | What it's for | Who usually opens it |
|-----|---------------|----------------------|
| **[Releases](https://github.com/jonathanlake/rogues_oath/releases)** | What's new each version, in plain language, + the playable build | **Jeff** — for "what's the game like right now" |
| this **README** | What the game is + this map of the docs | anyone new to the repo |
| **[DESIGN.md](DESIGN.md)** | The design — vision, system spec, rationale, and **Part 4: open questions for Jeff** | design work; **Jeff → Part 1 (2-min overview) + Part 4** |
| **[ROADMAP.md](ROADMAP.md)** | The milestone chain + current status (what's done / what's next) | Jon, for dev status |
| **[CLAUDE.md](CLAUDE.md)** | How the project is built — structure, conventions, ground rules | contributors + the AI workflow |
| **[docs/](docs/)** | Depth on tap: [dev commands](docs/dev-commands.md), the [overnight runbook](docs/overnight-runbook.md), the [changelog](docs/design-changelog.md), [research notes](docs/research) | as needed |

In-game, type `/help` in the chat for the dev commands. Two-instance testing and the
contributor ground rules are in `CLAUDE.md`.
