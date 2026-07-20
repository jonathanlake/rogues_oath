# Overnight autonomy runbook

The protocol for unattended build-verify sessions (first proven v0.7.0→v0.7.1,
2026-07-19). Purpose: burn idle plan capacity on the parked backlog so Jon+Jeff
sessions are pure feel-testing and design against builds that already provably
function. Kickoff is a manual `/goal` (Phase 1); cron comes later (Phase 2, gate
below).

## What the loop may work on

- The top **unblocked, S-sized** item from ROADMAP's parking lot, or whatever the
  `/goal` names. One item at a time, smallest first.
- An item qualifies only if its finish line is FUNCTION-checkable (see ROADMAP's
  Working Agreement): the harness-verify skill can demonstrate it without a human
  feel verdict. Presentation-touching items get a Feel= note for the next session
  but may still land if their function is checkable.
- Never: anything [BLOCKED] on a DESIGN Part 4 question, anything M-sized without an
  approved plan, anything the Commitment Rule / ground rules leave ambiguous.

## The loop (per item)

1. **Plan** (Fable, in-context). S items: no GLM plan pass — the plan is usually
   trivial and the diff is where bugs live. M+ items require an approved plan and DO
   get the GLM plan red-team (but M+ items normally shouldn't run overnight at all).
2. **Implement** — Opus subagent per the `implement` skill (invariants block, no
   commit).
3. **GLM red-teams the DIFF** (`glm-red` skill) — address or decline each point
   explicitly, evidence over opinion.
4. **Verify** — the `harness-verify` skill's gate. Deterministic assertions first;
   honesty rule applies.
5. **Land** — commit (one per item, repo conventions), DESIGN changelog entry +
   version bump in that same commit.
6. Next item, until the night's scope or a stop condition is reached.

## End of night — export

- Export happens ONCE, at the end, from HEAD, and ONLY if HEAD is fully green:
  `--export-release` with the explicit absolute path
  `C:/Users/Public/Downloads/rogues_oath_v<version>.exe`, then verify LastWriteTime
  (the preset-path form silently no-ops).
- A non-green HEAD means NO export that night — a skipped export is an acceptable
  outcome; the morning report says why. Never checkout backward to export.

## Skip-and-park, quarantine, halt

- **Feel surprise** (item turns out to need a human verdict): revert the working
  tree (`git checkout . ; git clean -fd` — safe because every item starts from a
  committed-clean tree), park the item with notes in the morning report, move on.
- **Harness-fail before commit**: same revert, park with the failing evidence.
- **Harness-fail after commit** (a later step casts doubt on a landed commit): mark
  that commit SUSPECT in the morning report, stop adding work on top of it, no
  export.
- **Hard halt** (write HANDOFF.md, stop the night): repo-level doubt — a suspect
  commit you can't cleanly isolate, a verify step you can't trust, or anything
  touching the ground rules. Never ship unverified.

## Morning report format

What landed (commit + one-line each) · Evidence (which assertion proved what) ·
Parked + why · Review points declined + why · Suspect commits (if any) · Export
status. Lead with the outcome.

## Phase 2: cron (NOT yet enabled)

A scheduled routine may replace the manual `/goal` kickoff only after **3
consecutive manual overnight runs whose morning reviews required zero reverts or
fix-commits**. That's the bar; count restarts on any morning fix.

## Parallelism (optional, non-default)

The default topology is strictly serial. Independent items MAY run in isolated
worktrees, but worktrees never bump the version and never export — they deliver
commits/branches; the main loop is the single serializer for merge → verify → bump →
export. Anything touching main.gd or the referees stays serial always.
