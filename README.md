# Rogue's Oath

A 2–6 player real-time co-op tile-grid roguelike — permadeath, short runs, no turns — whose
hook is the **Commitment Rule**: decisions are irrevocable the moment you make them. Every
action has a duration and plays to completion; the server is the referee. Godot 4.x, 2D
top-down. By Jon & Jeff.

## Patch notes & builds

Each version's patch notes live on the
[Releases page](https://github.com/jonathanlake/rogues_oath/releases); playable Windows
builds are attached to release entries (e.g. `rogues_oath_v0.11.0.exe`). The design doc
(`DESIGN.md`) carries the full changelog.

## Running from source

The `assets/32rogues/` sprite pack is **not in this repo** — it's a licensed asset pack
([32rogues by Seth Boyles](https://sethbb.itch.io/32rogues)) whose license bars
redistribution, so it stays local to each dev machine (exported game builds may contain it;
that's the licensed use). Before opening the project in Godot (4.7+), drop the `32rogues`
folder into `assets/` — get it from Jon, or buy it on itch.io. Without it the project will
not load.

Two-instance testing, dev commands (`/help` in the in-game chat), and the contributor
ground rules are documented in `CLAUDE.md`, `docs/`, and `ROADMAP.md`.
