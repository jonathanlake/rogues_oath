# Rogue's Oath — Design Doc

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
   scale. **Rhythm experiment (v0.6.0, Jon+Jeff wire notes 2026-07-19, provisional):** all
   tiers are currently AUTHORED to the same 0.25s beat — one action rhythm for every
   entity ("if I hold right and the goblin holds right, we reach the edge together" —
   Jeff). The tier structure stays; variation returns by editing .tres values.
   **v0.7.0:** tiers are now authored in BEATS (`glide_beats`, all 1.0) against the global
   beat (§2.8). **v0.8.0 (Responsive Beat):** a step is back to **1 beat TOTAL**
   (`move_rest_beats` default 0.0, kept as a reversible/ANSWERED experiment). The v0.7.0
   committed rest read as lag in feel-testing (Jon+Jeff; Jeff's ChatGPT consult and Fable's
   own analysis converged) — grid feel comes from ATOMICITY (whole-tile commits, snapping),
   not inserted dead time. So the visible slide is now authored SHORTER than the beat
   (`slide_fraction`, default 0.7) and every step ends with an on-tile SETTLE — the "go stop
   go" look without the doubled movement cost. The slide is server-stamped and uniform on
   every peer, all movers (players and monsters alike); occupancy is still the full action
   window (visual-only change).
4. A glide obeys the Commitment Rule: once started, it finishes. Being hit does not interrupt
   it.
5. Tile reservation: on commit, the destination tile is reserved for the glide's duration. A
   second entity committing into a reserved tile fails (input rejected; no queuing beyond the
   one pipelined slot below). **Pipelined next step (decided 2026-07-18, Jeff — see Part 4
   Q7):** the server holds AT MOST ONE accepted next step per mover — adjudicated and
   COMMITTED at accept (occupancy swaps at accept: the frees-at-start rule of Q4 applied one
   step deeper), broadcast and started only when that mover's current committed window
   completes (v0.7.0: glide + rest — promotion moved from the glide boundary to rest-end,
   which WIDENS the pipeline's RTT budget from one beat to two). A
   pipelined mover's next tile is therefore spoken for up to one step early — intended
   gameplay, not an artifact ("decisions carry risk": conga semantics one step sooner). No
   cancel path exists; disconnect is the sole slot-clear. **Tap/hold rule (v0.3.5, amended
   v0.8.0):** the threshold is now in BEATS — `key_repeat_min_hold_beats` (default 1.5,
   ~0.375s at the default tempo — 1.2 was a verified knife-edge where a 0.3s press doubled;
   client-side convenience in the §2.2.9 spirit). A single
   continuous press shorter than it = exactly ONE step; held longer, movement auto-repeats
   one step per beat. Fresh presses use the EXPLICIT slide boundary (`glide_finished`):
   during the visible SLIDE a fresh tap stays dropped (you are visibly mid-move); from slide
   end to action-window end (the SETTLE — visibly standing) a fresh press queues via the
   pipeline slot (§2.2.8 — the queued step's own glide is the acknowledgment; the separate
   commit-sent flash was retired v0.10.2). A CONTINUING hold needs the threshold in ANY phase — so a hold that merely
   outlasts the shorter slide no longer free-fires a second step (the v0.7.1 double-step bug
   fix: any press >~0.18s used to become two tiles). The server contract is unchanged — the
   threshold gates whether a next-step intent is submitted, never when a committed step starts.
6. Attack of opportunity: starting a glide out of a tile adjacent to a hostile that is alive and
   able to act grants that hostile one free attack. **Provisionally DISABLED (v0.6.0, Jon,
   playtest):** `attacks_of_opportunity_enabled` in game_config.tres — spec and code stand;
   flip the bool to restore.
7. **Diagonal movement (decided 2026-07-15, Jeff — see Part 4 Q3):** 8-way movement;
   a diagonal glide costs a duration multiplier on the step (designer-tunable `@export`,
   default 2.0× — between Pathfinder's 1.5× and Tibia's 3× — tuned in playtest).
   **Set to 1.0× for the rhythm experiment (v0.6.0, Jeff: "keep the variable... have it be
   something that means it isn't being changed at all"; cites 5e dropping diagonal rules
   for simplicity even though "diagonals are OP"; "probably won't ever be double/half,
   too drastic").**
   **Corner rule (defined in M2; AMENDED v0.10.0, Jon playtest verdict 2026-07-21):** a
   diagonal step is refused only when BOTH orthogonal flank tiles of the origin —
   `origin+(dx,0)` and `origin+(0,dy)` — are walls: you may round a single wall corner, but a
   squeeze between two walls that touch only at a corner stays illegal. (The original M2 form
   blocked on EITHER flank wall; playtest read that as "can't move diagonally near a wall.")
   Monster A* mirrors the wall half. Flank **occupancy** does NOT block by default — walls block
   corners, bodies don't — with the `bodies_block_corners` GameConfig toggle as the playtest
   alternative: flip it and an occupied flank blocks the diagonal too (EITHER flank, unchanged).
   Diagonal LoS math is still deferred to the dungeon-visibility milestone.
8. **Commit feedback (added v0.3; AMENDED v0.10.2, Jon).** The feedback rule (2.3.4)
   applies to movement: the **verdict** — glide start, or a rejection "bonk" (sound +
   visual) when the destination is reserved (2.2.5) — always comes from the server, and
   the glide starting IS the input acknowledgment. (The original separate local
   "commit sent" flash was retired in v0.10.2 — movement is responsive enough that it
   read as noise; the rejection bonk remains this section's reject seam, and a bump into
   a hostile you can't attack yet rejects silently by design — the next from-idle step
   IS the attack.) The client never predicts the outcome, in either direction; there is no
   client-side authority anywhere. A rejected move must never be confusable with dropped
   input, and a locally-guessed rejection must never contradict a server accept.
9. **Click-to-move pathing (added M2.1, 2026-07-17; walk rule tightened 2026-07-18;
   provisionally OFF v0.6.0 — `click_pathing_enabled` in game_config.tres, Jon+Jeff: mouse
   clicks act only on the 8 adjacent squares, one fresh step each, a far click does
   nothing; all pathing code stays).**
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

1. **Deterministic combat (decided 2026-07-18, Jeff via Discord + Jon — Rogue Fable III
   baseline, which has no to-hit rolls):** every attack that resolves against a body lands
   for its fixed damage. The original accuracy/evasion two-step roll and the roll-type list
   (miss, crit, block, passive dodge, spell resist) are **PARKED** for the future
   build-system pass — if rolls ever return, they return through that design, not by
   default. Outcome variety comes from POSITION, not dice (see item 3).
2. All combat stats are passive, build-derived numbers (v1: placeholder stat blocks scaled
   from RF3, tuned live in the editor — player tuning lives in player.tscn's exports,
   monster tuning in the MonsterType `.tres` under resources/monsters/; the values are
   deliberately NOT quoted in this doc, so tuning never drifts it stale).
3. **Melee input = bump attack (decided Jeff, 2026-07-17):** gliding into a hostile's tile
   commits an attack instead — the attacker stays in place with a small lunge + attack
   sound, damage resolves at accept, and the attacker is committed for its swing duration.
   **Monster attacks are telegraphed TILE commits:** the wind-up targets a tile, visibly,
   for its full wind-up duration; at resolution it hits whatever hostile body occupies that
   tile — vacate it and the attack WHIFFS; step into it and you eat the hit. **Rhythm
   experiment note (v0.6.0):** windup authored to the 0.25s beat (Jeff's literal "windup+
   attack take the same time as a move"), so the deliberate-dodge window is effectively
   closed and whiffs are incidental — the mechanic is PARKED, restored by one .tres number.
   Playtest question ANSWERED NO within one solo test (Jon, v0.6.0: "winded up maybe
   once... attacked me pretty fast") — the 0.25s yellow blink inside a ~0.3s attack
   cycle was sub-perceptual and the cadence tripled the goblin's DPS. **v0.6.1
   choreography fix (Jon's direction: "flash white, stay in place"):** (a)
   `attack_recovery_sec` (MonsterType, goblin 0.25) — one beat of deliberate stillness
   after each strike; brain pacing, NOT a referee commitment (the server would accept a
   move — the brain isn't asking; a baited swing leaving the monster punishable is
   intended monster-side "decisions carry risk"); cycle ≈ plant 0.25 + strike + rest
   0.25 ≈ 0.55s, DPS back near pre-rhythm. (b) The tell is now a TRUE-white shader
   flash (modulate multiplies — it can never whiten a green sprite) + a snap-and-hold
   coil away from the committed tile, released into the lunge at resolution. Windup
   stays 0.25 (literal-uniform stands). Readability at real speed: re-test on Jon+Jeff
   next session. The telegraph
   commits to ground, not to a name ("decisions carry risk"). Attacks of opportunity
   (2.2.6) resolve instantly through the same damage path.
   **v0.7.0 — the windup experiment is CLOSED (Jon+Jeff, 2026-07-19):** it failed in both
   directions — 0.25s is sub-perceptual (v0.6.0/v0.6.3 verdicts) and 0.5s is
   dodgeable-every-time with AoO off (this session's voice verdict). Structural, not
   tuning: at 1-beat movement, any windup ≥ 1 beat is a free dodge and any windup < 1
   beat is invisible. New shape, BOTH sides symmetric: **instant deterministic strike +
   committed N-beat RECOVERY** with a visible "spent" tell (§2.3.4) — the tell moves from
   before the hit (invites the degenerate dodge-dance) to after it (readable state: "the
   goblin is spent — now's my window"). Player and goblin recovery both authored 2 beats,
   so attack rate = movement rate ("equal in terms of time and ability" — Jon's note).
   The telegraph/whiff machinery is PRESERVED behind `windup_beats` (goblin 0.0) — a
   future heavy monster may windup, ideally re-tested WITH AoO enabled, the configuration
   where dodging finally costs something (parked beside the §2.2.6 AoO toggle).
   **Aggro persistence (same session):** `aggro_range_tiles` becomes the ACQUIRE gate
   only — once aggroed, a monster stays aggroed (`aggro_persists`, MonsterType, default
   true; Jon: "he shouldn't turn off aggro"). The v0.6.0 range-as-leash behavior (chase
   drops the moment range breaks, re-polled every beat) is the flag's false branch.
   *Clarified v0.7.1:* the latch is per-monster "AWAKE", not per-target — an awakened
   monster hunts the NEAREST hostile, including one that never personally entered its
   range (roguelike-standard; per-target threat tables are a future design if wanted).
4. Every distinct outcome (hit, whiff, free attack, death) has a distinct, unambiguous
   feedback signal (sound + visual + combat log line). A player must never confuse "the
   attack missed" with "my input didn't register." *(This rule extends to movement
   rejection — see 2.2.8.)*
5. Combat presentation stays abstracted (targeted commands, no implied precise physical
   contact). Do not show pre-commit hit percentages.
6. RNG budget (stands even under deterministic damage, for any future roll): keep output
   randomness low-magnitude. Replayability comes from input randomness — dungeon gen,
   loot, encounters — not from swingy rolls. A bad outcome should always leave the player
   a real next decision, never just erase a correct one.
7. **§2.3.7 — Weapons as objects; actions as beats (v0.9.0, M3.7).** A player's weapon is a
   designer resource (`WeaponType`, `resources/weapons/*.tres`) — add a weapon by dropping a
   `.tres`, never by touching code (the §2.5 designer rule). Two field groups:
   - **Gameplay** (read HOST-side by the combat referee; never the wire): `attack_beats` (the
     BEATS this attack OCCUPIES on the attacker's one timeline — the whole action window, no
     separate cooldown, per Part 4 Q9), `damage` (deterministic), and `windup_beats` (0 = the
     instant strike at commit — today's default for both weapons; > 0 = the preserved
     telegraph/whiff machinery for a future heavy weapon). HONEST STATUS (v0.9.0): the
     referee reads the equipped weapon's `damage` and `attack_beats` when it stamps a bump;
     `windup_beats` is AUTHORED-BUT-NOT-YET-WIRED for players — the player-side referee hookup
     (bump-with-windup through the proven monster machinery) ships with the first windup
     weapon, a deliberate M3.7 scope cut. The legacy player exports
     (`melee_damage`/`attack_recovery_beats`) are the no-weapon fallback only.
   - **Animation** (presentation-only; gameplay NEVER reads these): `atlas_coords` into
     items.png, `attack_style` (stab | slash, v1), the phase fractions
     `startup_frac`/`active_frac`/`recovery_frac`, and the small tween knobs
     (`arc_degrees`/`reach_px`/`lean_degrees`/`recoil_px`). The client-side **weapon rig** plays
     the three phases as fractions of the STAMPED window (it NORMALIZES them at playback, so a
     `.tres` authoring error can never push a phase past the window — the referee's
     slide_fraction-clamp spirit).
   **DOCTRINE — animation explains state.** Phases (startup/active/recovery) are
   ANIMATION-INTERNAL slices of the occupied window; gameplay counts only beats. **The
   anticipation cap:** for a `windup_beats == 0` weapon the damage is instant-at-commit, so the
   pose must LOOK simultaneous with its damage flash — `startup` is ANTICIPATION ONLY and is
   kept ≤ ~0.15 of the window (the strike lands within the causality-perception threshold). A
   readable pre-hit windup is exactly what `windup_beats > 0` is for, where the damage genuinely
   lands later and a long startup is honest. The first two authored weapons — dagger (1 beat,
   quick, `damage` 2) and longsword (2 beats, today's feel, `damage` 5) — carry equal-ish DPS
   with a chunk/quick contrast, all Feel=-tunable in the `.tres`.
   **Weapon swap** is a dev-era control this milestone (the tempo-keys spirit): refused while
   busy (the Commitment Rule — no swapping out of a committed action), otherwise instant,
   host-validated, broadcast, over a hardwired 2-weapon roster (`GameConfig.weapon_roster`). The
   real game costs beats to swap once inventory exists — **M5 owns acquisition and replaces the
   hardwired roster.** Monsters keep their MonsterType attack fields this pass (unify later).

### 2.4 Periodic Effects (DoTs / HoTs / regen / buffs)

1. No shared global tick. Every periodic effect runs its own independent timer at whatever
   cadence suits it (a 1-dmg-per-second poison and a big heal-every-30s regen coexist
   freely).
2. Deferred: a deliberately loud, group-visible "shared beat" for coordination moments —
   only if a concrete need appears.

### 2.5 Multiplayer Architecture

1. Engine: Godot, built-in high-level multiplayer (ENet, MultiplayerSpawner, RPCs).
   Server-authoritative. MultiplayerSynchronizer is deliberately NOT in this toolkit — it
   streams continuous state, the opposite of the event model in item 3 (v0.5.2 wording fix;
   the exclusion itself dates to v0.3's reuse boundary).
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
     backstop, host-left handling, peer-disconnect cleanup. **Version gate (v0.5.0):**
     clients and host must run the same build — `peer_ready` carries the client's
     `config/version`, and the host refuses mismatches before spawn with both versions in
     the reason ("Version mismatch — you have vX, host has vY."), delivered over a
     `session_refused` RPC ahead of the kick (the same channel now carries "Server is
     full."). Exact-match policy while 0.x; a looser rule is a 1.0-era decision. (The host-left pattern is
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

### 2.8 The Beat (global tempo — v0.7.0)

1. One global beat — `beat_sec` (GameConfig, default 0.25) — is the unit every action
   duration is authored in. Durations live in resources as designer-editable BEAT
   MULTIPLES (`glide_beats`, `windup_beats`, `recovery_beats`, `move_rest_beats`);
   seconds exist only at the moment the server stamps a verdict. This is Jeff's
   "universal rhythm speed" (2026-07-19) made literal — and it is NOT a global tick
   (§2.4.1 stands): actions still start on commit and share only their unit.
2. **Stamp-and-bake:** a commit's full window (glide + rest; strike + recovery) is
   converted to seconds ONCE, at verdict time, and baked into the busy record/event. A
   tempo change never re-derives an in-flight commit's remaining time — it applies from
   the next verdict onward. (The Commitment Rule, applied to time itself.)
3. **Dev tempo knob (Jeff, 2026-07-19):** +/- adjusts the beat live in 0.05s steps,
   clamped 0.10–1.00. ANY peer may request it (playtest convenience, Jon's call) — the
   request rides the ordinary intent pipe, the HOST validates/clamps/applies, and
   gameplay only ever reads the host's value (§2.5 stands untouched). Every peer gets an
   on-screen readout (beat + BPM), a combat-log line naming who changed it, and late
   joiners receive the current tempo at handshake.
4. Whether this knob ships as a player-facing game-speed setting (RimWorld / Dwarf
   Fortress precedent; Fisty's hare-and-tortoise icon) is an open product question —
   Part 4 Q8.
5. **The beat is a UNIT, not a metronome (v0.8.0 clarification).** It is the shared
   duration authored against — NOT a global tick everyone's actions snap to (§2.4.1
   stands; item 1 already says so). NecroDancer-style enforced on-beat sync is explicitly
   NOT the design — that would reintroduce the reflex/timing test the commitment pillar
   removes. Steps still start on commit; they merely share a unit.
6. **`slide_fraction` (GameConfig, default 0.7, v0.8.0)** — the visible slide is authored
   as a UNITLESS fraction of a step's ACTION window; the remainder the avatar stands
   SETTLED on the destination tile, which is the grid "snap" tell. It scales with any
   tier's `glide_beats` and the diagonal multiplier automatically and can never exceed the
   window. VISUAL ONLY — occupancy and adjudication read the full action window unchanged.
   1.0 = no settle (continuous glide); low = teleport-y. The one knob that replaced the
   retired committed-rest experiment as the grid-tell control.
7. **Two paces, two dials (v0.9.2 — Jeff's two-dial model).** The beat splits into an
   EXPLORE pace (+/- keys, the live beat everything stamps from today) and a TACTICAL
   pace (`[`/`]` keys, `tactical_beat_sec`, default 0.50). Both are any-peer adjustable
   through the intent pipe with the same clamps (shared deliberately pending §2.8.7's
   zone design), both display on-screen, both sync to late joiners. As of v0.9.3 nothing
   stamps from the tactical dial — it goes live with tactical zones below.

#### 2.8.7 Tactical zones (v1 SHIPPED — v0.9.5)

Converged by Jon + Jeff (2026-07-20, with a ChatGPT consult). The framing that won: a
zone does not say "you are fighting" — it says **"the pace of the world in this area is
tactical."** Anyone and anything inside — friend, enemy, summon, projectile — operates on
the tactical beat; outside it, the explore beat. This answers the two hard questions
directly: a player two rooms from a fight is simply outside every zone (never slowed by
a party member's fight), and a supporter chooses between ranged help from outside the
zone at explore pace or stepping inside and accepting tactical pace — reach vs tempo
becomes a positioning decision.

- **v1 decisions (Jon, 2026-07-20; AMENDED v0.10.3, Jon playtest):** the bubble radius is
  its own per-monster dial (`MonsterType.tactical_radius_tiles`) but now DEFAULTS to
  **-1 = match `aggro_range_tiles`** — the playtest verdict was that a bubble smaller than
  aggro read as arbitrary; "it noticed you" and "you're in the fight" are the same ring
  (goblin 5) unless a designer authors a positive override to split the two dials. A
  player tactical bubble also exists now (`GameConfig.player_tactical_radius_tiles`,
  default 3, no chaining) — see the v0.10.3 changelog entry. And the LEASH rule: being an aggroed monster's chase target keeps you tactical
  at ANY distance — **provisional; revisit candidate: both chaser and chased revert to
  explore beyond the radius (full-speed pursuit at exact parity), if the hard leash feels
  bad in play.**
- **v1 entry rules** (a player is at tactical pace if ANY hold):
  1. Inside an enemy's tactical bubble (radius per-monster, expected to key off aggro state).
  2. They directly interact with combat — today that means attacking; heal / buff /
     debuff / summon / fire-projectile-into-combat join this list as those actions come to exist.
  3. A hostile targets them (safety net).
- **Support bubbles deferred to v2** (entering tactical via proximity to an engaged ALLY),
  with the anti-cascade cap recorded now: support bubbles must never emanate from players
  who are themselves only tactical via a support bubble — no chain-dragging a spread party.
- **Exit: short timer** — a few seconds clear of all bubbles/triggers before returning to
  explore pace (hysteresis; pace must not flicker at a bubble edge).
- **Anti-cheese:** any hostile action forces tactical pace for N beats regardless of
  position (no attacking at explore pace from a bubble's edge). Intended range N = 2–4
  beats — a dial, but the range is part of the spec.
- **Implementation shape:** ONE host-side pace resolver per player — inputs: zone
  membership, direct-interaction triggers, and the N-beat forcing window (a stateful
  per-player deadline, not a per-action flag). BOTH referees' stamp sites (already
  per-action, §2.8.2) consult that single resolver; never three independent checks
  scattered across stamp sites. Membership changes broadcast as events (§2.5); each
  player gets a UI cue for which pace they're in.
- **v1 scope discipline** (the consult's closing advice, adopted): enemy bubbles +
  interaction triggers + short exit timer, then PLAY it — radii and whether support
  bubbles are even necessary are tuning questions, not architecture.

### 2.9 Ranged Combat (v1 SHIPPED — v0.17.0)

**Capability track** (CLAUDE.md doc policy): a living spec + status checklist for a capability
that matures across many versions. This section is current-truth and edits freely; the
append-only changelog stays the per-release history. Ranged attacks as a whole — the bow is
v1/prototype, not the end state.

The pillar: ranged must carry the SAME hard-choice pressure as melee — no perpetual kiting
(Part 1). The v1 answer (full decision rationale in Part 4 Q6): the **traveling-projectile**
model. The shot is a committed draw (beats on the one timeline); the loosed arrow is an
independent effect that flies its lane tile-by-tile and is adjudicated per tile-arrival against
destination occupancy (§2.2 Q4). Dodging = stepping out of the lane during the draw (prediction,
not reflexes). THE ONE HIT RULE: the arrow stops at the first stoppable occupant (living, not the
shooter, and — with `projectile_hits_allies` off — not an ally). Aiming is a mouse-click on a
hostile tile; SHIFT+click fires at any in-range tile (lane denial / deliberate FF). A ranged
weapon has no melee swing, so a point-blank keyboard-bump is a weaponless KICK (low fixed damage;
Q6 option A). Taking damage from any range AGGROS the target.

**Shipped so far:** the bow — traveling shot, mouse + shift aim, point-blank kick, damage-aggro,
straight-line flight + per-weapon art orientation (v0.17.0–v0.17.3).

**Still envisioned:** monster ranged attackers (the model already allows a non-player shooter);
true line-of-sight (arrows use per-tile wall clipping today; diagonal corner-cutting accepted for
v1); more ranged weapon types (crossbow / thrown — each a `.tres`); gamepad aiming; ranged backstab
/ facing (the normalized-delta note in combat_referee); kick knockback (Q6 option D — re-open the
shooting range; needs a server-authoritative defender-move system vs the Commitment Rule).

**Complete when** ranged is a first-class build: multiple weapons, enemies that shoot back,
LoS-correct, feel-locked. *(Stage-by-stage progress is tracked in ROADMAP's parking lot, not here —
this section is the design; checkboxes live only in ROADMAP.)*

### 2.10 Items & Inventory (v1 SHIPPED — v0.18.0)

**Capability track.** Pick up, carry, and use (later equip) designer-authored items; the
`.tres`-only content pipeline is the end goal (its gate is milestone **M5**).

v1 model (host-authoritative, event-synced like everything else). Items are `ItemType` resources
in `GameConfig.item_catalog`, name-resolved like weapons/classes. A world item is a replicated
`GroundItem` node that claims NO occupancy — you glide onto its tile and pick it up (walk-over,
adjudicated at the glide's settle). The bag is 5 slots (the HUD hotbar); it dies with the player
(permadeath — fresh/late spawns start empty, so there is no late-join inventory sync in v1).
Using an item is a COMMITTED action (§2.1): `use_item {slot}` roots you for `use_beats`, and a
heal lands at the DRINK'S END — killed mid-drink consumes the potion and heals nothing ("attack
or drink, not both"). Heals are their own referee pipe (`apply_heal`, clamped to max; god blocks
damage, never healing) — the damage pipe stays damage-only. The health potion (heal 10 / 2-beat
drink) is the v1 item; 1–5 keys use a slot; `/item` + `potion=` spawn for testing.

**Shipped so far:** item resources + catalog, ground items + walk-over pickup, 5-slot bag,
use-as-commit + heal pipe, hotbar + 1–5 keys, dev spawn (v0.18.0).

**Still envisioned:** drop tables + the designer `.tres`-only authoring gate (= milestone **M5**,
which owns that bar — this track points at it, doesn't restate its Done=); more item categories
(buffs, keys, scrolls, throwables); equipment / wearables (coordinate with the build-system pass);
the open v1 questions — item stacking, drop/discard, inventory beyond the 5-slot hotbar,
numbers/cues (Feel=).

**Complete when** items are a full designer-authored system: drop tables, multiple categories,
the `.tres`-only gate (M5) met. *(Stage progress is tracked in ROADMAP, not here.)*

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
   *M3 (v0.4) shipped the DISPOSABLE placeholder — question stays OPEN:* death = instant
   despawn + "You died." log + passive watching (nothing is built on it). Mid-commit
   placeholder semantics: a dying entity's referee state (occupancy, glide, pending slot)
   is erased synchronously; its in-flight visual snaps out; an attacker killed mid-wind-up
   deals nothing; a mover killed by AoO mid-adjudication has its glide aborted. All of
   these are placeholders Q1's real answer replaces.

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
   **→ Ranged is now a CAPABILITY TRACK spec'd in §2.9 (living spec + status checklist); this
   entry is preserved as the decision-rationale archive.**
   **ANSWERED for ranged v1 (Jon+Jeff, 2026-07-22, Discord). Implemented v0.17.0 — the
   TRAVELING-PROJECTILE model** (chosen over hitscan: "fits the real-time aspect" — Jon).
   The shot is a commitment (the draw wind-up costs full beats on the one timeline, Jeff:
   "make sure it has the wind up start"); the loosed arrow is an independent EFFECT that
   flies the Bresenham lane tile-by-tile at a fractional-beat rate (beats-authored:
   `projectile_tiles_per_beat`), adjudicated per tile-arrival against Q4 destination-based
   occupancy — dodging = stepping out of the lane during the draw, prediction not reflexes.
   THE ONE HIT RULE: the arrow stops at the first stoppable occupant (living, not the
   shooter, and — with the `projectile_hits_allies` GameConfig toggle OFF — not an ally).
   Friendly fire ON by default (Jon: first-occupant body-blocking is on-brand). Mouse-click
   aiming (click a tile in range = commit request; server adjudicates; wall-clicks = "fire
   down this lane"). Bow v1: ranger roster [longsword, bow], 7-tile Chebyshev range,
   3 attack_beats (2-beat draw + 1 recovery), damage 4, sky-to-horizontal draw telegraph +
   nocked arrow + pitched draw/loose sounds (Jon's spec — no string animation). Ranged
   kiting pressure: the 3-beat rooted draw IS the hard choice; a mid-draw move request
   pipelines (Q7 slot) and starts only after the window. STILL OPEN in this question:
   LoS-proper (arrows use per-tile wall clipping; diagonal corner-cutting accepted v1),
   gamepad aiming, monster ranged attackers, ranged backstab/facing (the normalized-delta
   note in combat_referee).
   **MOUSE-AIM v2 (v0.17.2, Jon 2026-07-23) — supersedes the wall-click lane-fire above.**
   A left-click SHOOTS only when the clicked tile holds a hostile (client-side routing
   convenience against replicated monster nodes — the server still adjudicates every
   shot); any other click falls through to the normal step/walk input, so a bow-wielder
   can still move with the mouse. The v0.17.0 "wall-clicks = fire down this lane"
   behavior is REMOVED (no ground fire; a deliberate lane-denial keybind can return later
   if missed). **v2.1 (v0.17.3, Jon): SHIFT+click ground-fires** — the lane-denial /
   deliberate-ally-shot capability returns behind an explicit modifier; plain clicks stay
   hostile-gated. Also v0.17.3: **damage is an aggro source** — a monster that takes
   damage from any range latches aggro (no free sniping from outside its radius); the
   chase still targets the NEAREST player (a farther sniper aggros the monster but it
   closes on whoever is closest — revisit if builds make sniping a role). Also v0.17.2, presentation-only: arrows fly the TRUE straight line to the
   target (the Bresenham path stays authoritative for adjudication — it was never meant
   to be the visual), and art orientation became per-weapon designer data (WeaponType
   art_points_deg / projectile_art_points_deg) — the 32rogues sheet is NOT uniformly
   oriented (melee tips point NE, the arrow NW, the bow fires SW), so no single baseline
   constant can ever be right.
   **POINT-BLANK amended (v0.17.1, Jon — option A of four).** A ranged weapon has no melee
   swing, so keyboard-bumping an adjacent hostile is a weaponless KICK: a flat
   `GameConfig.kick_damage` (default 1, deliberately low — a desperation poke, not a main
   attack), its own "kicks" log verb + no weapon graphic (a bare-handed-bump-shaped commit),
   gated on `range_tiles > 0` so melee weapons keep their swing. Chosen over B (punished
   point-blank shot), C (auto-swap to a melee alt — rejected: a silent uncommanded weapon
   change) and D. **Option D is the deferred richer version**: the kick keeps its low damage
   and gains a 1-tile KNOCKBACK — kick the enemy back to re-open shooting range, turning
   "cornered with a bow" from a punishment into a tool. D needs a server-authoritative
   defender-move system designed against occupancy + the Commitment Rule (does an external
   shove interrupt a committed windup/glide? wall / map-edge / into-another-entity cases), so
   it is its own future feature, not this pass. The kick's `_begin_bump` branch is where D's
   knockback call slots in. STILL OPEN feel=: the kick reuses the bow's recovery window (so
   it commits at shot-recovery speed, 1.5s vs a melee 0.5s) — a dedicated `kick_duration` may
   be warranted; the 1-damage number.

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

8. **Does the tempo knob ship?** The dev +/- beat control (§2.8.3) mirrors RimWorld/DF
   game-speed controls ("maybe its the baseline 'speed' of the game… some players might
   wanna play a faster game, and other want it slower" — Jeff; hare-and-tortoise icon —
   Jon). Options: ship it as a host-side lobby/run setting; lock a tuned default and keep
   the knob dev-only; or something between (a few named presets). Notes for the
   discussion: because EVERYTHING scales off one value, a tempo setting can't unbalance
   relative timings the way per-action tuning could — but very fast beats start testing
   reflexes, which brushes the "never tests your reflexes" pillar (Part 1).

9. **Attack shape vs the 1-beat step. ANSWERED (Jeff via ChatGPT + Fable converging,
   2026-07-20): unified occupancy — NO separate cooldowns, ever.** An entity has ONE timeline;
   every action (move, attack, item) RESERVES beats on it and plays to completion (the
   Commitment Rule), and nothing runs a second parallel timer. The rejected alternative was an
   internal-cooldown / move-during-recovery model: decoupled attack and move timers breed
   orb-walking / stutter-step play that rewards dexterity over tactics — the anti-pillar (Part 1
   "never tests your reflexes"). So the PLANTED recovery stays: a multi-beat action roots you,
   weight as cost. Movement remains the fastest action (1 beat). Counterplay to a long attack is
   POSITIONAL (the whiff machinery, stepping out of a telegraphed tile) or lethal, never a free
   input-cancel. This is what M3.7 (v0.9.0) builds on: `WeaponType.attack_beats` IS the occupied
   window (§2.3.7), dagger 1 beat vs longsword 2 beats — a weapon's whole cost is the beats it
   locks, not a cooldown bolted beside it. Still PAIRED with the §2.2.6 AoO re-enable as the next
   feel pass: once the beat-cost contrast reads well, turn AoO back on so stepping away from a
   committed attacker carries its intended risk (and re-test the telegraphed `windup_beats > 0`
   heavy weapon in that configuration — the one where dodging finally costs something).

10. **Fixed world rect — how much world a player sees must not depend on their window.
    ANSWERED (Jeff, 2026-07-22): approved as proposed, camera recenter included.
    Implemented v0.14.0** (see that changelog entry for the engine finding and the
    verification record).
    **REVISED (Jon, 2026-07-22, implemented v0.15.0): full bleed restored, exact equality
    relaxed to BOUNDED VARIANCE.** Jon rejected v0.14.0's always-on margin frame on sight
    (visible bands on 1080p-class windows): the world must fill the window except the
    column, as in v0.13.0. Revised rule: integer scale NEAREST a canonical canvas width
    (960 base px, the 1080p/4K natural), a hard bound bumping the scale up if a window
    would show >10% more world width than canonical (kills the windowed outlier: 1280×720
    now 2× / 460×360, less than any maximized view, never more), a height playability
    floor (≥15 tiles) for degenerate shapes, and a per-axis BLEED_CAP backstop (52×36
    tiles) so no shape — portrait, extreme DPI — reveals unbounded tiles; only capped axes
    show margin bands. Residual spread across maximized 16:9: ~16% width / ~13% height
    (1080p 780×515, 1440p 673×464, 4K 780×527) — accepted as "somewhat close" (Jon).
    Considered and declined: the Rogue Fable model (one fixed canvas incl. UI,
    fractionally stretched — exact equality, but non-integer scaling shimmers 16px art);
    revisit only if fog-of-war (#6) doesn't land as the real equalizer. The margin-frame +
    exact-equality clauses above are superseded; camera recenter and fog cross-ref stand.
    **UI ZOOM DECOUPLED (Jeff, 2026-07-22 Discord; implemented v0.16.0): the HUD gets its
    OWN integer zoom h, separate from the world's fairness zoom s.** Jeff's framing: "games
    get smaller when the window gets smaller" — the panel should shrink with the window,
    not overflow it (the v0.15.0 windowed inventory clip). Each layout pass h = the largest
    integer 1..s whose MEASURED column stack fits the window height, applied as the HUD
    CanvasLayer's scale = h/s (net on-screen = h — still a crisp integer; both zooms are
    whole steps, no fractional shimmer). h = s on every maximized 16:9 (nothing changes);
    a 1280×720 window runs world 2× / HUD 1× (the v0.13-windowed panel size, full inventory
    visible); 1366×768-class laptops (which clipped even maximized) get the same fix. The
    world_frame rect stays emitted in CANVAS px — the camera/F3/vignette consumers are
    unchanged; only the HUD layer itself is scaled. Also added on Jeff's request: **F11
    borderless fullscreen** (WINDOW_MODE_FULLSCREEN, mode cached and restored on exit,
    borderless flag reset per the 4.7 force-set) — evaluation toggle, local-only.
    Wire-session finding (Jon+Jeff, 2026-07-21): under `aspect="expand"` the visible world
    area is a side effect of window size. Measured: 1440p maximized (3×) sees ~673×464 base
    px of world; 1080p maximized (2×) sees 780×515; a restored 1280×720 window (stepped to
    1×) sees 1100×720 — **2.4× the world area of the 1440p player**. That is information,
    not cosmetics: earlier monster/item sightlines change decisions in a commitment-driven
    game. **PROPOSED (Jon, 2026-07-22): every player sees a fixed world rect of 42×29 tiles
    (672×464 base px — the tile count is the definition; sized to today's 1440p-maximized
    view, so that setup stays visually identical).** Each window picks the largest integer
    scale that fits world + the 180px HUD column (a derived 852×464 block — the column stays
    its own constant; note widening it later would lower the fit-time scale some windows
    get, same tiles at smaller magnification); ALL leftover space becomes frame styled like
    the column backdrop — no black bars, no extra map. Scale is pure magnification: no
    window, resolution, or DPI configuration ever shows more than 42×29 tiles; sub-852×464
    windows (dev, or extreme DPI virtualization) clamp per axis to a strict SUBSET of the
    rect. Geometry: 1440p max 3× (~4px margins), 1080p max 2× (216×102px frame), 1280×720
    restored 1× (large frame — the standard fixed-canvas trade, Nuclear Throne model), 4K
    max 4×. This consciously walks back v0.13.0's "world bleeds to three edges" — bleed and
    equal-vision are mutually exclusive; fairness wins. Separable sub-decision: the camera
    recenters the avatar in the world rect, not the window — closes the v0.13.0
    ~90px-right-of-centre feel item, but Jeff can accept the rect and defer this. Cross-ref
    #6/fog-of-war: the rect is presentation-sized, not vision-sized (29 tiles of height
    exactly hosts a 14-tile vision radius; the 42-tile width is deliberately wider) — a
    future server-side vision system trims visibility inside the rect, at which point this
    cap becomes pure presentation and data-level fairness takes over.


---

### Changelog

The append-only release history moved to **`docs/design-changelog.md`** (split out 2026-07-23) so this
doc stays the living spec. Add each release's entry there — this file holds current design only.
