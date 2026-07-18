# HANDOFF — pipelined next-step implementation (written 2026-07-18)

In-flight state only. Delete in the pipeline milestone's final commit — after folding every
design-level item below into the DESIGN amendments and referee comments (nothing here may
survive ONLY here).

## Where things stand

- Working tree clean through `d31dc7e` (host-port footgun fix). All wire-test fixes shipped
  and verified. Both Jon↔Jeff connection failures were the host-port footgun (host bound
  the address field's `:22619` while the tunnel forwards to 3000) — fixed; the host's log
  now opens with "Hosting on port N.".
- Second wire test (2026-07-18) confirmed the client stop-and-go is exactly Part 4 Q7's
  RTT gap: Jeff stutters on both screens (his events leave the host at glide+RTT cadence),
  Jon is smooth on both (synchronous verdicts → back-to-back events), input method
  irrelevant. Not a new bug.
- **Q7 is ANSWERED: Jeff approved the pipelined next step** (via Jon, 2026-07-18).
  Recorded in DESIGN Part 4 Q7. This handoff is the implementation spec.

## The design (ready to implement)

**Client (move_input.gd):** MoveInput may have ONE intent in flight while gliding — it
submits its next step at glide START instead of waiting for its tween to finish. Latch
semantics otherwise unchanged. No rendering changes anywhere: clients just receive
back-to-back events.

**Server (move_referee.gd):** an intent from a currently-gliding mover is accepted into a
single per-mover pending slot. It is adjudicated AT ACCEPT TIME (origin = the current
glide's destination), duration stamped then — but the accept is BROADCAST only when the
current glide's completion timer fires. Expected result (not yet measured — verify with F3
numbers before promoting to DESIGN prose): smooth at any RTT below the step duration; the
bound is fixed, not a tunable. RTT ≥ step duration is the one regime where a gap returns.

**Occupancy swaps at ACCEPT** — including pipelined accepts (the frees-at-start rule
applied one step deeper). A pipelined mover's next tile is therefore spoken for up to one
step early: real, intended gameplay ("decisions carry risk" — conga semantics one step
sooner). Document this in the §2.2.5 amendment. Only the AoO hook and the broadcast run at
the start moment; AoO is a pure trigger (§2.2.6) and can never gate or invalidate the
committed step.

## Invariants and cautions (fold into docs/comments before HANDOFF deletion)

a. **Adjudicate-at-accept is not a prediction** under `origin_frees_at_glide_start=true`:
   occupancy mutates ONLY at sequential accepts; completion timers touch only
   `_gliding`/broadcast. Every later accept sees authoritative state. **Target branch,
   decided:** implement against the true branch (shipped default, Jeff's lean). When the
   toggle is false, the referee simply never accepts into the slot (pipeline off,
   stop-and-go returns) until that branch's mechanics are designed. M3-era forced movement
   outside the intent pipe (knockback etc.) would break the invariant — the referee
   comment must name it.
b. **"already moving" broadens** to also mean "pipeline slot occupied" (a THIRD intent
   while one glides + one is held). Same player-mashing semantic — game_log's line
   suppression stays; update its comment.
c. **§2.5.3's "entities are always either idle or inside a known, finite action"** needs
   amending in the same doc pass as §2.2.5 (a mover can be inside one executing + one
   scheduled committed action).
d. **Disconnect is the SOLE slot-cancel exception.** The existing `child_exiting_tree`
   cleanup erases all of a departing peer's `_occupied` entries by peer id — that reverts
   the pre-claimed destination automatically; the slot erase rides the same hook.
e. **Per-MOVER boundary:** each mover's held accept broadcasts when THAT mover's current
   glide completes (its own timer) — never a global boundary.
f. **Redirect vs held slot:** a new click mid-glide replaces `_target_tile` only; the held
   committed step stands and executes; the NEXT submission (at the held step's
   glide-start) paths toward the new target. (§2.2.9 walk-lock semantics unchanged.)
g. The smoothness property is design intent, not yet measurement — F3 numbers first.

## Next-session agenda

1. Implement the pipeline (client + referee) + DESIGN doc pass: §2.2.5 amendment, §2.5.3
   wording, Q7 full write-up, changelog (v0.3.4). Usual cadence: Opus implements, GLM diff
   review, two-instance verification, one commit; delete this file in that commit.
2. Verification sketch (two-instance, harness): `glidesec=`-stretched run — second intent
   accepted mid-glide, broadcast lands exactly at the boundary (back-to-back events in
   stdout); slot-full reject (third intent) → "already moving"; redirect click mid-pipeline
   leaves the held slot untouched (path bends only after it); `hold=` cadence run shows a
   gapless client (the actual symptom fixed — compare event timestamps/cadence vs today);
   standard regression matrix (walk lock, chat focus, occupied/corner/wall rejects, conga).
3. M1.5 latency baseline: first 30 seconds of the next Jon+Jeff session — both press F3,
   note "move verdict" median/p95 (also auto-printed to the log on quit) → close M1.5.
   Pending, not blocked.
4. **Re-export the build for Jeff after committing** (his .exe never includes fixes until
   exported — this has bitten twice).

## Open items (unchanged)

- M1.5 checkbox open pending the latency numbers.
- Jeff's pending review of the §2.2.9 walk-lock tightening (flagged in DESIGN).
- M3 (First Blood) is next on the roadmap after the pipeline ships.
