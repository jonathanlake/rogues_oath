---
name: implement
description: Implement a Rogue's Oath milestone or any approved plan in this repo. Triggers whenever writing Rogue's Oath game code — dispatches implementation to Opus 4.8 subagents per the global model-roles workflow, with this project's invariants block and two-instance verification.
---

# Implement — Rogue's Oath milestone workflow

Follow the global `model-roles` skill: **Fable 5 coordinates, Opus 4.8 subagents write the
code, GLM-5.2 advises.** This file adds the project specifics.

## Before dispatching anything

1. Read `CLAUDE.md` (rules) and `ROADMAP.md` (current milestone + its **Done =** criterion).
2. Confirm the milestone isn't **[BLOCKED]** on a DESIGN.md Part 4 open question.

## The invariants block — paste into EVERY Opus dispatch, verbatim

```
HARD CONSTRAINTS (violating any of these fails the chunk):
1. Commitment Rule: every action has a duration and completes once started. No code path
   may cancel, interrupt-by-input, or redirect a committed action.
2. Event-sync only: gameplay state replicates as discrete commit events via RPC. No
   per-frame position/input streaming. No MultiplayerSynchronizer for gameplay state.
3. Multiplayer-first: the feature must work with two instances (host + client). No
   offline-only code paths; no logic assuming a single local player.
4. Server-authoritative: the server adjudicates all outcomes, reading tunables from shared
   scene/resource config — never from a client-side value.
5. Do not copy code from Magick With Friends except where CLAUDE.md's reuse boundary
   allows. BANNED in all cases: player_input_synchronizer_component.gd,
   remote_visual_smoother.gd.
GDScript only. 2D only. @export tunables with units. Component + event-bus patterns.
```

## Verification (what "done" means)

- The harness: MWF's `DEBUG` autoload pattern (`framework/debug/debug.gd`, two-window
  autostart via `-- host/join debug_autostart`) is extracted in M1; from then on every
  verification = **Fable launches two instances via the harness and observes the
  milestone's Done= criterion**. Not "it compiles"; never a subagent's word.
- Each chunk review names the specific behavior assertion verified.

## GLM diff cadence

- Multi-chunk milestones: one early GLM diff review after the FIRST chunk lands
  (catches systemic issues before they propagate), plus the milestone-end review before
  the final commit. `git diff HEAD > tmp; node glm-red.js <tmp> diff` — address or decline
  each point explicitly.
- Update `ROADMAP.md` checkboxes in the milestone's final commit.

## Trial clause

Revisit the Fable/Opus split after M1–M2 — if it adds friction without quality, drop it.
