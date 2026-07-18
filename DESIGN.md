# Rogue's Oath — Design Doc (v0.3.5)

## Part 1 — The Game

You and a couple of friends descend into a procedurally generated dungeon. It's a traditional
roguelike at heart — permadeath, tile-based tactics, monsters, loot, chokepoints, "do we fight
this or run" — but everyone is playing at once, live, in the same dungeon. Nobody takes turns.
Nobody waits.

Combat is slow enough to think. An ogre winding up to hit you is telegraphed seconds in
advance — enough time to decide, not enough time to do everything. You can attack, or you
can drink the potion. Not both. And once you choose, you're locked in: no canceling, no
dodge-rolling out of it, no take-backs. The game never tests your reflexes — it tests whether you
made the right call. It's the kind of combat you can play with a sandwich in one hand, but a
wrong decision still gets you killed.

Runs are short — winnable in a sitting, under an hour or so. Death is permanent. The dungeon
is different every time. Builds are simple enough that you can glance at a friend's character and
know what they do.

**Presentation: 2D top-down tiles** (decided v0.3). Sprites on a tile grid, in the DCSS / Rogue
Fable visual lineage.

Feel targets: the deliberation of DCSS, the pacing of Neverwinter Nights (pacing only — the
presentation is 2D), the streamlined onboarding of Rogue Fable, playable with friends over a
network without anyone's ping mattering.

Explicitly not: an action game, a twitch game, an MMO, a turn-based game with a lobby.

## Part 2 — System Spec

### 2.1 The Commitment Rule (core invariant)

1. Every action — attack, cast, heal, item use, movement — has a duration and plays out
   to completion once started.
2. No action can be canceled, interrupted by player input, or redirected after commit.
3. There is no active dodge, block, or escape input. Defense is stats, positioning, and
   choosing well before committing.
4. Design test for every future mechanic: does it let a player back out of a decision for
   free? If yes, redesign it.

### 2.2 Movement

1. World is a tile grid. Every entity occupies exactly one tile.
2. Moving = a glide: entity commits to an adjacent tile, then smoothly animates into it over
   a real-time duration. Position data is discrete; presentation is smooth.
3. Glide duration is stat-driven, in discrete speed tiers (breakpoints), not a continuous
   scale.
4. A glide obeys the Commitment Rule: once started, it finishes. Being hit does not interrupt
   it.
5. Tile reservation: on commit, the destination tile is reserved for the glide's duration. A
   second entity committing into a reserved tile fails (input rejected; no queuing beyond the
   one pipelined slot below). **Pipelined next step (decided 2026-07-18, Jeff — see Part 4
   Q7):** the server holds AT MOST ONE accepted next step per mover — adjudicated and
   COMMITTED at accept (occupancy swaps at accept: the frees-at-start rule of Q4 applied one
   step deeper), broadcast and started only when that mover's current glide completes. A
   pipelined mover's next tile is therefore spoken for up to one step early — intended
   gameplay, not an artifact ("decisions carry risk": conga semantics one step sooner). No
   cancel path exists; disconnect is the sole slot-clear. **Tap/hold rule (v0.3.5):** only a
   key held ≥ `key_repeat_min_hold_sec` (~0.18s, client-side convenience in the §2.2.9
   spirit) feeds the pipeline; a tap is exactly one committed step. The server contract is
   unchanged — the threshold gates whether a next-step intent is submitted, never when a
   committed step starts.
6. Attack of opportunity: starting a glide out of a tile adjacent to a hostile that is alive and
   able to act grants that hostile one free attack.
7. **Diagonal movement (decided 2026-07-15, Jeff — see Part 4 Q3):** 8-way movement;
   a diagonal glide costs a duration multiplier on the step (designer-tunable `@export`,
   default 2.0× — between Pathfinder's 1.5× and Tibia's 3× — tuned in playtest).
   **Corner rule (defined in M2, Jon/Jeff 2026-07-17 — provisional, pending playtest):** a
   diagonal step requires both orthogonal flank tiles of the origin — `origin+(dx,0)` and
   `origin+(0,dy)` — to be non-wall, so a squeeze between two walls that touch only at a corner
   is illegal even when both endpoints are floor. Flank **occupancy** does NOT block by default —
   walls block corners, bodies don't — with the `bodies_block_corners` GameConfig toggle as the
   playtest alternative: flip it and an occupied flank blocks the diagonal too. Diagonal LoS math
   is still deferred to the dungeon-visibility milestone.
8. **Commit feedback (added v0.3).** The feedback rule (2.3.4) applies to movement:
   pressing a move renders an instant, local **"commit sent"** acknowledgment, so the
   player always knows the input registered. The **verdict** — glide start, or a rejection
   "bonk" (sound + visual) when the destination is reserved (2.2.5) — always comes from
   the server. The client never predicts the outcome, in either direction; there is no
   client-side authority anywhere. A rejected move must never be confusable with dropped
   input, and a locally-guessed rejection must never contradict a server accept.
9. **Click-to-move pathing (added M2.1, 2026-07-17; walk rule tightened 2026-07-18).**
   Click-to-move is CLIENT-SIDE convenience only: the client turns a clicked destination
   into ordinary one-step commits, submitted one at a time through the same intent pipe as
   a key press. The server never sees a path or a target, and never queues steps — 2.2.5
   stands untouched; each submitted step is the only wire commitment, and each obeys the
   Commitment Rule in full once verdicted. **Walk rule:** a standing walk is NOT cancelable
   by other input. A new CLICK redirects it at the next step boundary — precisely: any
   in-flight or pending step always completes (committed once accepted), and the redirect
   takes effect when the NEXT step is chosen. The walk ends on arrival, or when the world
   refuses it (unreachable target / consecutive step rejects). *Note:* tightened after the
   first wire test from "may be replaced or dropped freely" (Jon 2026-07-18 — "decisions
   carry risk"); Jeff's original answer — redirect at step boundaries — is preserved; the
   removal of key-cancel is the NEW part, **flagged for Jeff review**. See Part 4 Q7
   (pipelined next-step): both amendments reduce the player's cancel-authority over travel
   and should be reviewed together as one axis, not as two independent asks.

### 2.3 Combat Resolution

1. Two-step resolution per attack: (a) accuracy vs. evasion/resist → hit or miss; (b) if hit,
   roll damage magnitude.
2. All hit/evade/resist chances are passive, build-derived stats. Rolled silently, no player
   input involved.
3. Roll types (tentative): miss, crit, block, passive dodge, spell resist.
4. Every distinct roll outcome has a distinct, unambiguous feedback signal (sound +
   visual + combat log line). A player must never confuse "the roll failed" with "my input
   didn't register." *(This rule extends to movement rejection — see 2.2.8.)*
5. Combat presentation stays abstracted (targeted commands, no implied precise physical
   contact). Do not show pre-commit hit percentages.
6. RNG budget: keep output randomness (roll swing) low-magnitude. Replayability comes
   from input randomness — dungeon gen, loot, encounters — not from swingy rolls. A bad
   roll should always leave the player a real next decision, never just erase a correct one.

### 2.4 Periodic Effects (DoTs / HoTs / regen / buffs)

1. No shared global tick. Every periodic effect runs its own independent timer at whatever
   cadence suits it (a 1-dmg-per-second poison and a big heal-every-30s regen coexist
   freely).
2. Deferred: a deliberately loud, group-visible "shared beat" for coordination moments —
   only if a concrete need appears.

### 2.5 Multiplayer Architecture

1. Engine: Godot, built-in high-level multiplayer (ENet, MultiplayerSpawner/Synchronizer,
   RPCs). Server-authoritative.
2. **Reuse (made precise in v0.3): plumbing comes from the Magick With Friends
   `framework/` layer** (the matured successor to the Friend Slop Framework). Scope of
   reuse:
   - **Lift near-verbatim:** `framework/autoloads/network_manager.gd` (swappable
     transport contract — all ENet code isolated behind `host_game` / `join_game` /
     `disconnect_game` / `kick_peer`; verified to contain no tick-rate or state-sync
     assumptions), the `GameManager` config / player-name pattern, the main-menu
     host/join UI, and the dev console (`framework/ui/console/` — host-gated commands,
     invaluable for multiplayer testing).
   - **Lift the patterns, rewrite the code:** session flow from MWF `main.gd` — the
     `peer_ready` RPC with duplicate-spawn guard, capacity spawn-gate with kick
     backstop, host-left handling, peer-disconnect cleanup. (The host-left pattern is
     client-side UX for the disconnect *moment* — freeze, overlay, return to menu — and
     is needed under any host-disconnect policy; lifting it does not pre-answer Open
     Question 2.)
   - **Explicitly excluded:** `player_input_synchronizer_component.gd` and
     `remote_visual_smoother.gd`. Both stream continuous per-frame state — the opposite
     of the event-based commit model below. All movement/action networking is written
     from scratch for this game.
3. All gameplay sync is event-based, not position-streamed: replicate discrete commits
   (`glide_to(tile)`, `attack(target)`, `use_item(id)`), each stamped with
   duration/outcome by the server. The commitment model makes this natural — entities
   are always either idle, inside a known finite action, or (since v0.3.4) inside one
   executing action with exactly one scheduled committed action behind it (§2.2.5's
   pipelined slot — still a known, finite, server-stamped set).
4. No client-side prediction needed for v1 — round-trip latency is absorbed by the slow,
   telegraphed pacing by design.
5. Target scale: small friend groups (2–6 players). No matchmaking/lobby service for v1.
   All players join before the run starts; there is no mid-run join (see 2.7).

### 2.6 UI/HUD (direction only — build later)

1. Aesthetic: simple and readable 2D, in the DCSS / Rogue Fable lineage (NWN informs
   the HUD layout conventions below, not the rendering).
2. Multiplayer additions a solo roguelike HUD lacks, all v1-relevant:
   - persistent party status (portraits + HP, NWN-style)
   - a visible tell on any player currently locked in a commit (so teammates read each
     other's state)
   - nameplates / ally-enemy color coding
   - minimap that also shows teammate positions
   - combat log carrying the per-roll feedback from 2.3.4
3. Not needed ever: initiative / turn-order UI. There are no turns.

### 2.7 Explicitly Out of Scope for v1

- Matchmaking, lobbies, NAT traversal services
- Client-side prediction / rollback netcode
- Shared-beat mechanic (2.4.2)
- Final visual style
- Character build systems beyond placeholder stats (design pass needed — Rogue
  Fable-style legibility is the bar: a build should be readable from a handful of numbers)
- Dungeon generation design (needs its own pass; it is the game's primary randomness
  source, so it deserves one)
- Mid-run join / late-join state snapshot (added v0.3): everyone starts the run together.
  This also removes the "what does a late joiner see mid-glide" replication problem from
  v1 entirely.

## Part 3 — Appendix: Why (short version)

Why commitment instead of turns? What makes a roguelike turn tactical isn't the pause — it's
that the decision is spent once made. Cooldown-based real-time games (EQ/WoW) gate how
often you act, but let you cancel and reposition freely, which is why they feel loose. Hard
commitment recreates the weight of a turn with zero waiting, which is what lets this stay
real-time and multiplayer.

Why no reflex demands? Dark Souls proves commitment works in real time, but couples it to
twitch execution. Decoupling them (slow telegraphs + hard commits) keeps the judgment test
and drops the execution test — and buys near-total lag tolerance for free.

Why grid + glide? Grid gives clean tactics math (adjacency, chokepoints, AoO triggers). Glide
keeps it from reading as turn-based. Tibia has shipped exactly this in live multiplayer for 25+
years; the speed-tier quantization follows Diablo's frame-breakpoint precedent.

Why lock movement too? Free repositioning is an escape hatch with a different name — leave
it uncommitted and optimal play collapses into perpetual kiting instead of hard choices.

Why passive rolls but no active dodge? Passive evasion is a build-time decision resolved
silently — it never un-makes a real-time choice. An active dodge button does. One is texture,
the other is an escape valve.

Why no global tick? EQ's 6-second tick was 1990s MUD server economics, not a design ideal.
Independent per-effect timers express any cadence a designer wants; a shared clock can't.

Why low output-RNG? More decision complexity needs less injected randomness to stay fresh
(the MTG-vs-Hearthstone principle). This game is decision-dense and its choices are
irrevocable — big post-commit roll swings would fight the core pillar.

Why event-sync networking? The design only ever changes state through discrete commits,
so replicating events is both cheaper and truer to the model than streaming positions.

## Part 4 — Open Questions (for Jeff)

*No decisions here — each item frames a tradeoff to discuss. Items marked **[BLOCKS
IMPLEMENTATION]** need answers before the affected system gets built; the rest can wait.*

1. **Death mid-run.** The biggest unaddressed design question. Permadeath + co-op +
   ~1-hour runs means a dead player may spectate for most of a session. Candidate
   directions: pure spectate (purest permadeath, simplest, boring for the dead), a ghost
   with minor utility (scouting, small buffs — engaged without undoing permadeath), or a
   costly revive (softens permadeath — touches the core pillar). Related sub-question the
   Commitment Rule forces: if a player dies mid-commit (killed by an AoO mid-swing,
   glides onto a trap), does the committed action still complete post-mortem?

2. **Host disconnect policy.** Server-authoritative with a friend hosting means a host crash
   can erase a 50-minute run. Accept that consciously (and add it to 2.7), or define a
   save-on-quit / resume story? Note the reused host-left UX (2.5.2) handles the
   disconnect moment either way — this question is about whether the run state survives it.

3. **Diagonal movement.** **ANSWERED (Jeff, 2026-07-15): Option C — 8-way with a
   diagonal duration penalty.** ("Every roguelike I play uses B, but I do know that
   diagonal is faster; in Pathfinder it takes more movement points to move diagonal, so I
   trust that C will be a decent enough compromise for now.") Recorded in §2.2.7:
   designer-tunable multiplier, default 2.0×. Options considered: A) 4-way — simplest
   rules, mis-press-proof; B) 8-way equal cost — classic feel, but real-time glides make
   diagonals visibly ~40% faster (a kiting buff); C) 8-way penalized — Tibia's 25-year
   live-multiplayer precedent (3×), Pathfinder's tabletop rule (1.5×).

4. **Origin-tile timing during a glide.** Is the departed tile freed at glide start or held until the
   glide ends? Affects chase/kiting feel, body-blocking in corridors, and whether allies can
   file through a chokepoint tightly behind each other.
   **PROVISIONAL (not a final answer), M2 2026-07-17:** M2 ships **origin frees at glide start**
   (conga-line — Jeff leans this; playtest pending), with the `origin_frees_at_glide_start`
   GameConfig toggle to flip it without code. Under this rule the §2.2.1 "one entity per tile"
   bookkeeping counts the mover at its DESTINATION for the whole glide (the origin is released the
   instant the step commits); the toggle's false branch instead holds the origin and reserves the
   destination until arrival. Localized entirely to the MoveReferee — no other system depends on
   which branch is live, so settling this in playtest is a one-bool change.

5. **Stepping away from the keyboard.** Real-time multiplayer can't pause. Since there is
   no action queuing (2.2.5), nothing runs away while AFK — after the current commit
   (seconds) finishes, the player simply stands idle. The real question is idle *exposure*:
   do monsters wander? Is there aggro at rest? Are there safe/rest tiles or zones where
   standing still is genuinely safe for a bathroom break?

6. **Ranged combat & line-of-sight.** Entirely absent from the spec so far. Ranged kiting is
   the main threat to the "no perpetual kiting" pillar (Appendix: "Why lock movement too?")
   — a ranged build that glides, shoots, glides again needs the same hard-choice pressure
   melee has. Needs its own pass alongside the build system.

7. **Pipelined next-step vs stop-and-go.** Wire-test finding (2026-07-18): a client's travel
   is stop-and-go — between consecutive steps the client must wait a full submit→verdict
   round trip (its idle frame is consumed by the wait), so remote movement stutters at a
   cadence the host never feels (its verdicts are synchronous). Proposal to discuss: a
   **pipelined next step** — the server holds AT MOST ONE next-step intent per player,
   committed the moment it is accepted (not cancelable once slotted), so travel is smooth
   without prediction and rubber-banding is impossible. This amends 2.2.5's "no queuing"
   (by exactly one server-held slot) but preserves its intent — no free back-outs, every
   slotted step is a commitment. It is DISTINCT from client-side prediction, which stays
   rejected per 2.2.8: contested tile adjudication makes a misprediction gameplay-wrong,
   not cosmetic. Related: the §2.2.9 walk-rule tightening — same cancel-authority axis,
   review together.
   **ANSWERED (Jeff via Jon, 2026-07-18): pipelined next step approved** — one server-held
   slot, committed on accept, started (and broadcast) only when the current glide
   completes. Amends 2.2.5 by exactly one slot; no cancel path is created.
   **Implemented v0.3.4, with these invariants:** adjudicate-at-accept is NOT prediction —
   under `origin_frees_at_glide_start=true`, occupancy mutates only at sequential accepts
   (completion timers touch only the glide record and the broadcast), so every later accept
   reads authoritative state; the boundary is per-MOVER (each mover's own completion timer
   releases its held step — never a global tick); disconnect is the SOLE slot-cancel path;
   a redirect click mid-glide replaces only the walk target — the held step stands and
   executes, and the NEXT submission paths toward the new target (§2.2.9 unchanged);
   "already moving" now also covers a full slot (a third intent), still suppressed in the
   log as player mashing; the attack-of-opportunity trigger (§2.2.6) fires when the held
   step actually STARTS (boundary-time adjacency — a pure trigger, it can never gate or
   invalidate the committed step). Travel is smooth for any RTT below the step duration —
   a fixed bound, not a tunable; RTT ≥ step duration is the one regime where the gap
   returns. Smoothness is design intent pending measurement: F3 move-verdict numbers at
   the next wire session (M1.5 baseline). In the false toggle branch the referee never
   accepts into the slot — pipeline off, stop-and-go returns — until that branch's
   mechanics are designed. M3-era forced movement (knockback etc.) outside the intent pipe
   would break adjudicate-at-accept; any such mechanic must clear/re-adjudicate the slot
   (named in the referee's code comment). **Smoothness CONFIRMED on the wire (2026-07-18,
   first pipelined session):** Jeff's F3 move verdict med 66.7ms / p95 83.3ms vs the 350ms
   step — the bound holds with ~4× headroom (M1.5's recorded baseline).

---

### Changelog

- **v0.3.5 (2026-07-18)** — Post-wire-session fix pass: §2.2.5 tap/hold rule (a key must be
  held `key_repeat_min_hold_sec` ≈0.18s before it feeds the pipeline; a tap is one committed
  step — fixes the pipeline's double-step tap and its early wall bonk); Q7 smoothness
  confirmed with Jeff's F3 numbers (med 66.7 / p95 83.3ms vs 350ms step) and M1.5 closed on
  that baseline; presentation: name label snugged over the head, subtle floor checkerboard
  (alternate-tile modulate, designer-tunable).
- **v0.3.4 (2026-07-18)** — Q7 shipped: pipelined next step (one server-held slot per mover,
  adjudicated + committed at accept, broadcast at that mover's own glide boundary). §2.2.5
  amended (no queuing beyond the one slot; occupancy swaps at accept — frees-at-start one
  step deeper, next tile spoken for early is intended gameplay); §2.5.3 wording (one
  executing + one scheduled committed action); AoO fires at held-step start (boundary-time
  adjacency); false toggle branch = pipeline off. Smoothness bound fixed at RTT < step
  duration; F3 confirmation pending (M1.5 baseline, next wire session).
- **v0.3.3 (2026-07-18)** — Post-wire-test: §2.2.9 walk rule tightened (a standing walk is not
  cancelable by other input; a new click redirects at the next step boundary; ends on arrival
  or world refusal — Jon's call, "decisions carry risk", flagged for Jeff review). New Part 4
  Q7: pipelined next-step vs stop-and-go (client RTT gap; one server-held committed-on-accept
  slot proposal; distinct from client prediction, which stays rejected per §2.2.8) — awaiting
  overlay latency data + Jeff.
- **v0.3.2 (2026-07-17)** — M2.1 (Input Methods): new §2.2.9 — click-to-move pathing defined
  as client-side convenience only (server never sees a path or target, never queues — §2.2.5
  stands; a standing target is not a commitment, only each submitted step is).
- **v0.3.1 (2026-07-17)** — M2 (Grid & Glide) design calls, both provisional pending playtest:
  §2.2.7 diagonal **corner rule** defined (walls block the squeeze, bodies don't by default;
  `bodies_block_corners` GameConfig toggle flips it); Part 4 Q4 **origin-tile timing** given a
  provisional answer (origin frees at glide start; `origin_frees_at_glide_start` toggle flips it).
  Neither is a final decision — both are designer-editable bools so Jeff can settle them in playtest.
- **v0.3 (2026-07-15)** — Named the game (Rogue's Oath). Decisions: 2D top-down tile
  presentation; networking plumbing sourced from Magick With Friends `framework/`
  (scope of reuse made explicit, continuous-sync components excluded); commit
  feedback extended to movement with server-authoritative verdicts (2.2.8); mid-run join
  moved explicitly out of scope. Added Part 4 — Open Questions. Ported from the v0.2
  PDF (copy-faithful from text extraction).
- **v0.2** — AI-generated draft from Jon & Jeff's design conversation (PDF).
