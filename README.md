# Rogue's Oath

A 2–6 player real-time co-op tile-grid roguelike — permadeath, short runs, no turns — whose
hook is the **Commitment Rule**: decisions are irrevocable the moment you make them. Every
action has a duration and plays to completion; the server is the referee. Godot 4.x, 2D
top-down. By Jon & Jeff.

## Patch notes & builds

Each version's patch notes live on the
[Releases page](https://github.com/jonathanlake/rogues_oath/releases); playable Windows
builds are attached to release entries (e.g. `rogues_oath_v0.28.1.exe`). The full changelog
lives in [`docs/design-changelog.md`](docs/design-changelog.md).

## Running from source

**First, the assets.** The `assets/32rogues/` sprite pack is **not in this repo** — it's a licensed
asset pack ([32rogues by Seth Boyles](https://sethbb.itch.io/32rogues)) whose license bars
redistribution, so it stays local to each dev machine (exported game builds may contain it;
that's the licensed use). Before opening the project in Godot (4.7+), drop the `32rogues`
folder into `assets/` — get it from Jon, or buy it on itch.io. Without it the project will
not load.

**Then run it.** Open the project folder in Godot 4.7+ and press **F5**. You land on the main menu:
enter a name, then **Host** to start a session or **Join** to connect to one (the address field
takes `host[:port]`; leave it at the default for a game on this machine). The default port is
**3000**, and hosting only honours a `:port` in the field for loopback-style addresses — the log's
first line prints which port it actually bound. To play with someone else, one person hosts and
shares their address; everyone joins before the run starts (there is no mid-run join).

For two instances on one machine — the normal way this game is tested — launch Godot twice against
the same project, host in one and join `127.0.0.1` in the other. In-game, `/help` lists the dev
commands and **`** (backtick) opens the tuning panel.

## Where everything lives

Not sure which doc to open? Start here.

| Doc | What it's for | What to expect |
|-----|---------------|----------------|
| **[Releases](https://github.com/jonathanlake/rogues_oath/releases)** | What's new each version + the playable build | Short patch notes in plain language, newest first; a Windows `.exe` attached |
| this **README** | What the game is + this map of the docs | A short overview and this table |
| **[DESIGN.md](DESIGN.md)** | The design: **Part 1** a 2-min overview, **Part 2** the full system spec, **Part 3** the why, **Part 4** open questions | Authoritative long-form prose; jump by section number (§2.1, §2.7…) |
| **[ROADMAP.md](ROADMAP.md)** | The milestone chain — what's done and what's next | Checkbox milestones + a parking lot of unscheduled ideas |
| **[CLAUDE.md](CLAUDE.md)** | How the project is built: structure, conventions, ground rules | Concise rules + a router to the docs below |
| **[docs/](docs/)** | Depth on tap: [dev commands](docs/dev-commands.md), the [overnight runbook](docs/overnight-runbook.md), the [changelog](docs/design-changelog.md), [research notes](docs/research) | Focused single-topic files |

In-game, type `/help` in the chat for the dev commands. The scripted two-instance test harness and
the contributor ground rules are in `CLAUDE.md`.
