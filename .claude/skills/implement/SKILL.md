---
name: implement
description: Implement a Rogue's Oath milestone or any approved plan in this repo. Triggers whenever writing Rogue's Oath game code — dispatches implementation to Opus 5 subagents per the global model-roles workflow, with this project's invariants block and two-instance verification.
---

# Implement — Rogue's Oath milestone workflow

Follow the global `model-roles` skill: **Fable 5 coordinates, Opus 5 subagents write the
code, GLM-5.2 advises.** This file adds the project specifics.

## Before dispatching anything

1. Read `CLAUDE.md` (rules) and `ROADMAP.md` (current milestone + its **Done =** criterion).
2. Confirm the milestone isn't **[BLOCKED]** on a DESIGN.md Part 4 open question.
3. **Size the work first — CLAUDE.md's "Effort Sizing" section governs** (Jon, 2026-07-26). State
   the expected scale up front, and where a quick path and a thorough path both genuinely exist,
   ASK which Jon wants. The full pipeline below (Opus dispatch + the complete two-instance matrix
   + GLM reviews) is scoped to changes that touch the referees' commitment/occupancy machinery,
   add networked events, or redesign across systems — plus anything shipping in a release build.
   A pinned-spec change on an existing seam is direct implementation, a boot check and one
   targeted harness assertion; don't dispatch it.

## The invariants block — paste into EVERY Opus dispatch, verbatim

```
HARD CONSTRAINTS (violating any of these fails the chunk):
1. Commitment Rule: every action has a duration and completes once started. No code path
   may cancel, interrupt-by-input, or redirect a committed action. TWO sanctioned exceptions
   already exist in shipped code and are NOT violations: (a) an opponent-imposed STUN
   interrupts an in-flight attack/cast, and (b) inside the `instant_abilities_enabled`
   experiment (which ships ON) Shadow Step self-interrupts and STRIKE abilities carry
   cooldowns. DESIGN §2.11 / §2.11.1 are authoritative on their exact scope — read them
   before treating existing code as a breach. Do not WIDEN either exception.
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

- **The gate is the `harness-verify` project skill** (`.claude/skills/harness-verify/`) — invoke
  it for every "prove it works" moment: it carries the canonical two-instance invocation, the
  knob gotchas and the assertion patterns. The harness itself is `debug/debug.gd` (lifted from
  MWF's `DEBUG` autoload pattern in M1, 2026-07-15, and grown far past it since — its arg parser
  is the knob source of truth; `docs/dev-commands.md` annotates it).
- Every verification = **two instances launched via the harness, observing the milestone's
  Done= criterion**. Not "it compiles"; never a subagent's word.
- Each chunk review names the specific behavior assertion verified.

## GLM diff cadence

- Scope it with the Effort Sizing check above — this cadence is for full-pipeline work, not for
  every pass (a fix pass gets no extra GLM review).
- Multi-chunk milestones: one early GLM diff review after the FIRST chunk lands
  (catches systemic issues before they propagate), plus the milestone-end review before
  the final commit — address or decline each point explicitly.
- Invocation is the canonical one in `~/.claude/commands/glm-red.md`: write the diff to
  `.glm-red-input.txt` in the cwd, run
  `node "C:\Users\Jon\.claude\scripts\glm-red.js" .glm-red-input.txt diff`, and **delete
  `.glm-red-input.txt` afterward** (it is gitignored session residue, not an artifact).
- Update `ROADMAP.md` checkboxes in the milestone's final commit.

## Trial clause

Revisit the Fable/Opus split after M1–M2 — if it adds friction without quality, drop it.
