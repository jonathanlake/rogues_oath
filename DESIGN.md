# Rogue's Oath — Design Doc (v0.8.0)

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
   pipeline slot with the §2.2.8 commit-sent cue (inputs never silently vanish while you look
   ready). A CONTINUING hold needs the threshold in ANY phase — so a hold that merely
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
8. **Commit feedback (added v0.3).** The feedback rule (2.3.4) applies to movement:
   pressing a move renders an instant, local **"commit sent"** acknowledgment, so the
   player always knows the input registered. The **verdict** — glide start, or a rejection
   "bonk" (sound + visual) when the destination is reserved (2.2.5) — always comes from
   the server. The client never predicts the outcome, in either direction; there is no
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

- **v1 decisions (Jon, 2026-07-20, shipped):** the bubble radius is its OWN per-monster dial
  (`MonsterType.tactical_radius_tiles`, default 3) — deliberately NOT aggro range, so "it
  noticed you" (chase starts, still explore) and "you're in the fight" (pace drops) tune
  separately. And the LEASH rule: being an aggroed monster's chase target keeps you tactical
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

---

### Changelog

- **v0.10.1 (2026-07-21)** — Review fix pass on v0.10.0 (10 verified findings). Dev tuning
  clamps every field to a named range (no more negative-damage heals — apply_damage also
  floors amount at 0 — dead-on-arrival spawns, or overlay-stalling radii); godded hits
  suppress the hurt presentation (white flash, slash streak, red vignette) so god mode reads
  as the grey-0 no-op it is; the whiff "miss" popup — previously unreachable dead code —
  spawns from the event's committed tile and actually renders; the F7 overlay draws one
  room-clamped rect per radius (pixel-identical, stall-proof) and is parent-wired per the
  component rule; three stale corner-rule docstrings rewritten; weapon/class late-join sync
  collapses into one sync_player_field RPC filtered to changed-from-default; the tuning
  pipeline and the godded event dict are single-sourced; /help derives its lists from the
  shared tables and roster (can no longer lie); the dev-command subsystem extracts from
  main.gd into debug/dev_commands.gd and popup FX into ui/fx_layer.gd (~190 lines out of
  Main). Verified on temp ports while Jon+Jeff playtested, then on-screen: godded assault
  with zero hurt feedback and frozen HP, batched overlay rects, popup rendering post-refactor.
- **v0.10.0 (2026-07-21)** — Feature pass from Jon's playtest list. MOVEMENT FEEL: the diagonal
  corner rule relaxes to the classic form — blocked only when BOTH flanking orthogonals are
  walls (§2.2.7 amendment, playtest verdict; you can round a single wall corner, never squeeze
  between two); monster A* mirrors it; the body-flank dial keeps its semantics. SPRITE FACING:
  entities flip toward their step/attack/telegraph direction (sprite-only flip — labels and the
  weapon rig untouched), event-driven per peer. SLASH COMMANDS (dev-era, any peer): a leading
  "/" in chat rides a host-validated dev_command intent — /w and /m live-tune weapon and monster
  resources at stamp time (with reset), /god toggles referee-level invulnerability (damage-0
  events keep the feedback rule), /help lists locally; docs/dev-commands.md is the reference.
  PLAYER CLASSES: PlayerClass resources (six authored) replace the hardwired sprite table;
  /class swaps live, class_changed broadcasts, sync_class covers late joiners — the beachhead
  for real class stats. F7 RANGE OVERLAY: translucent aggro (red) / tactical (yellow) fills from
  authored values (static — live aggro state stays host-only). FLOATING COMBAT TEXT: damage
  numbers (miss / godded-0) rise off victims, Main-parented to survive killing blows. All
  two-instance verified (client-typed tuning applying to its own next bump; late-join wizard
  via sync_class; the once-forbidden pillar diagonal accepting).
- **v0.9.6 (2026-07-21)** — Code-review fix pass on Tactical Zones v1 (10 verified findings;
  no standalone export — superseded same-day by v0.10.0). Seed-vs-flip pace events (spawn seeds
  update the bar without log spam); local death resets the tempo bar (was frozen tactical until
  F5 — screenshot-verified at 0/20); resolver hot path: change-detected engagement reports,
  radius cached at report time, merged leash+bubble scan (kills the O(P·M²) chase-loop term);
  client input throttles follow the local broadcast pace; the anti-cheese window also arms at
  the combat chokepoints (covers AoO-when-re-enabled and future windup weapons); one static
  beat_or_explore fallback replaces three copies; twin nearest-target scans merged; pace-cue
  comments cite the deliberate two-signal choice (v0.6.2 audio grammar) instead of §2.3.4.
- **v0.9.5 (2026-07-20)** — TACTICAL ZONES v1 SHIPPED (§2.8.7): the two dials come alive.
  A new host-side PaceReferee is the single resolver both stamping referees and every brain
  consult per entity, per action: players go tactical inside an aggroed monster's bubble
  (`tactical_radius_tiles`, own dial, default 3 — Jon's call, deliberately not aggro range),
  while LEASHED (an aggroed monster's chase target, any distance — provisional, revisit
  candidate recorded), or inside the anti-cheese forcing window (`tactical_force_beats` 3,
  armed BEFORE the triggering attack stamps — no fast first swing; hitting the dummy
  counts); explore returns after `tactical_exit_sec` 1.5 hysteresis. Monsters are tactical
  iff aggroed — chaser and leashed target share the beat, preserving v0.9.3 chase parity.
  Stamp-and-bake untouched; pace reads happen at verdict time only. `pace_changed` events
  broadcast per flip (poll + flush-on-change), late joiners seeded; the tempo bar
  emphasizes YOUR live pace and the log marks own-player flips. `current_beat_sec` renamed
  `explore_beat_sec`. Two-instance verified end-to-end: entry event on aggro, the player's
  own bump stamping the tactical window, exit after hysteresis on the goblin's death, an
  unengaged player gliding at explore through someone else's fight, and both bar states
  captured on-screen.
- **v0.9.4 (2026-07-20)** — Quick pass from the v0.9.3 playtest. UI SHRINK: game log/chat
  fonts 8→6 with a tighter panel (200×72); debug overlay to font 5 with two terse lines
  (FPS, verdict latency) — its tempo line removed as a duplicate of the tempo bar, which
  itself drops to font 8. ANY-PEER F5: round reset now rides the intent pipe like every
  other dev control — the host validates, the single log marker names the presser
  ("— Round reset (NAME) —", replacing the anonymous round_reset event). Policy recorded:
  ALL dev tools stay deliberately any-peer until stripped for release. Claw damage 3→2
  (Jon tuning call). Next up: tactical zones v1 (§2.8.7) — the pace switch goes live.
- **v0.9.3 (2026-07-20)** — Feedback pass 3 (Jon+Jeff playtest of v0.9.2). CHASE PARITY:
  diagnosed why players outran goblins (worse at faster beats) — both sides are authored at
  1.0 glide_beats, but the goblin's brain paid a FIXED 0.05s epsilon-wake per step
  (0.05/beat_sec of lost ground: 20% at 0.25s, 10% at 0.50s) while held-key players rode the
  referee's zero-gap `_pending` promotion. Fix: the busy think now PIPELINES the next chase
  step through that same machinery (the referee's pipeline opens to monster ids) — exact
  open-field parity by construction; the epsilon wake survives only as the recovery/attack
  handoff. Decision: exact parity — escapes come from corners and body-blocking, never raw
  speed; per-monster `glide_beats` is the future speed dial. MONSTER WEAPONS: the v0.9.0
  deferral resolved — the weapon surface (equipped_weapon + WeaponRig + swing) moves up to
  Entity, MonsterType gains a `weapon` ref, the combat referee reads weapon-first with the
  legacy fields as null-weapon fallbacks, and every armed attacker's events (whiffs
  included) carry the weapon for the arc-swing playback. Goblin wields a new `claw`
  WeaponType (club sprite; its exact old numbers). The training dummy stays weaponless.
  NEW **§2.8.7**: the tactical-zones v1 spec (area-pace framing, entry rules, deferred
  support bubbles with the anti-cascade cap, exit hysteresis, N-beat anti-cheese, the
  single-pace-resolver implementation shape) — agreed direction, not yet scheduled.
- **v0.9.2 (2026-07-20)** — Feedback pass 2 (Jon+Jeff playtest of v0.9.1). NUDGE-DRIFT FIX:
  `Entity._bowstring`/`_shake` now base on tile-centre, never the live rendered position — the
  settle-at-centre invariant moves from the Monster override into Entity, killing the sender-only
  drift that walked an attacker's own sprite into the wall under sustained bump-spam (interleaved
  occupied-rejects compounded the captured base). F6 DEV SUMMON (any peer): a `dev_spawn_goblin`
  intent; the host resolves the presser's room (new `WorldGrid.ROOMS` rects) and spawns a goblin
  at a free tile ≥3 away, logged per the feedback rule; F5 reset is the cleanup lever. Room C now
  fields THREE goblins (chaos feel test). DUAL TEMPO DIALS (groundwork for Jeff's two-dial model):
  `tactical_beat_sec` (default 0.50s) alongside the explore beat — `[`/`]` adjust it via a
  `set_tactical_tempo` intent (same clamps as explore by design, pending the mode discussion),
  late-join synced, displayed beside explore everywhere tempo shows. Nothing stamps from the
  tactical beat yet: explore/tactical MODE-SWITCHING (per-player combat state, who gets pulled
  into combat pace, the healer question) is deliberately still open with Jeff.
- **v0.9.1 (2026-07-20)** — Feedback pass on M3.7: BIG ARC SWING + TRAINING DUMMY. Jon's verdict
  on the v0.9.0 rig: the swing read as a tiny nudge. The weapon rig is reworked to a
  pivot-at-avatar-center ORBIT — the sprite rides at `orbit_radius_px` and the rig rotates through
  `arc_degrees` (longsword 90° → 160°) centered on the attack direction; the stab thrusts from
  center out to orbit + reach. The weapon is now visible ONLY during the swing (the body keeps its
  nudge; the weapon carries the rotation). Presentation-only — the §2.3.7 doctrine (normalized
  phase fractions of the stamped window, gameplay never reads animation timings) is unchanged.
  New: the TRAINING DUMMY — an inert scenery-with-HP monster (`MonsterType.has_brain = false`
  skips brain activation; new `atlas_texture`/`atlas_region` overrides for non-grid custom
  sheets) in the starting room at (12,4), 1000 HP, never moves or attacks; spawns outside the
  goblin=N cap and respawns at full HP on F5 reset. Two-instance verified: identical hp_after on
  both peers, zero dummy-originated events, idle/mid-swing screenshots.
- **v0.9.0 (2026-07-20)** — M3.7: ARMS & THE ACTION TIMELINE. v0.8.0's movement is APPROVED
  (Jon+Jeff feel-verdict: "so much better") — the responsive-beat step is the shipped baseline.
  Part 4 **Q9 ANSWERED** (Jeff via ChatGPT + Fable converging): unified occupancy — one timeline,
  actions reserve beats, NO separate cooldowns ever (decoupled attack/move timers breed
  orb-walking/stutter-step, the anti-pillar; the planted recovery stays, counterplay is positional
  or lethal). New **§2.3.7**: weapons are designer resources (`WeaponType` — gameplay fields
  `attack_beats`/`damage`/`windup_beats`, animation fields for the client-side rig), with the
  action-timeline animator (the weapon as its own tweened object, three phases as NORMALIZED
  fractions of the stamped window) and the ANTICIPATION-CAP doctrine (for `windup_beats == 0`,
  startup ≤ ~0.15 so the strike reads simultaneous with its instant damage — a real pre-hit windup
  is what `windup_beats > 0` is for). Two authored weapons: dagger (1 beat, `damage` 2, stab) and
  longsword (2 beats, `damage` 5, slash, today's feel) over a hardwired `GameConfig.weapon_roster`;
  a live dev swap control (Tab / gamepad Y) — refused while busy (Commitment Rule), else instant,
  host-validated, broadcast, with a late-join weapon sync. The combat referee reads the equipped
  weapon for a player's damage + occupied window (legacy `melee_damage`/`attack_recovery_beats` =
  the no-weapon fallback); the `attack` event gains a `weapon` field so every peer animates the
  right rig (monster attack events unchanged — no weapon field). Harness: `weapon=`/`swap=`/
  `swapwait=`. **M5 note:** inventory acquisition replaces the hardwired roster (swap will cost
  beats then). Monsters keep their MonsterType attack fields this pass (unify later).
- **v0.8.0 (2026-07-20)** — M3.6: RESPONSIVE BEAT. Feel-testing v0.7.1 found two things:
  go-stop-go's committed rest read as lag (the pause was in the wrong layer and doubled
  movement's cost), and the tap/hold double-step bug (any press >~0.18s committed two
  tiles). Diagnosis + fix converged from Jeff's ChatGPT consult and Fable's own analysis
  on the same principle — grid feel comes from ATOMICITY (whole-tile commits, snapping),
  NOT inserted dead time. Movement is back to 1 beat total (`move_rest_beats` default 0.0,
  kept behind the field as an ANSWERED/reversible experiment). The visible slide is now
  authored to `slide_fraction` (0.7) of the beat, so every step ends with an on-tile SETTLE
  — the go-stop-go look without the dead time. Broadcast `duration_sec` carries the SLIDE
  (fraction of the glide term, never of glide+rest — so a re-raised rest extends only the
  settle: true reversibility). Tap/hold threshold moved to beats (`key_repeat_min_hold_beats`,
  1.5 — the plan's 1.2 verified as a 0.30s knife-edge where a 0.3s press still doubled, so the
  default landed above it) and now gates the SETTLE phase too, keyed on the explicit slide boundary
  (`glide_finished`) — that is the double-step fix (a hold that merely outlasts the shorter
  slide no longer free-fires). Monster busy-wake re-pointed from the rest to the SETTLE
  remainder ((1 − slide_fraction) of the glide term + any rest), restoring speed parity —
  "we reach the edge together." `glidesec=` now pins the ACTION window / glide term; the
  broadcast slide follows as `slide_fraction ×` it (contract change — it used to pin the
  tween directly). §2.8 gains the beat-is-a-UNIT-not-a-metronome clarification (NecroDancer
  enforced-sync is explicitly not the design). Attacks DELIBERATELY unchanged (recovery_beats=2
  both sides, so the attack cycle is now 2× movement — intended interim); the attack-cooldown
  / move-during-recovery question PAIRED with the §2.2.6 AoO re-enable is the next feel
  milestone (Part 4). No engine/tempo/camera/late-join changes.
- **v0.7.2 (2026-07-19)** — Late-join player snap + the workflow layer (overnight-runbook
  pilot). Players now get the same 0.05s late-join micro-snap monsters got (main.gd
  `_on_player_spawned_host`): a joiner renders already-moved players at their TRUE tile
  immediately instead of their stale spawn slot until their next step (visible under
  go-stop-go, where players idle most of the time; still the §2.7 dev-facility mend, not
  real mid-run-join support). Same guards as the monster path (living, idle,
  wall-sentinel skip) + self-skip for the joiner's own node. Verified deterministically:
  host walked (3,3)→(8,3), joiner spawned, host log shows peer-1 snap glide_to
  (8,3)→(8,3) @0.05s, no self-snap; screenshot corroborates. FIRST RUN of the new
  workflow layer (same commit): `.claude/skills/harness-verify/` (the two-instance
  verification gate as a project skill), `docs/overnight-runbook.md` (unattended
  build-verify protocol; cron gated on 3 clean manual runs), ROADMAP working-agreement
  FUNCTION/FEEL split (harness-checkable Done= vs human Feel= from M4a on). The pilot's
  pre-flight rule fired for real mid-task: Jon was live on 3000, the run refused to
  join his game and waited. Port-watcher, GLM diff review (3 points, all adjudicated),
  zero manual deviations from the runbook. (8-angle review + GLM, overnight).
  REAL BUG FIXED: M3.5's screen-space Background ColorRect defaulted to mouse_filter
  STOP and ate EVERY mouse click — found by file-probe after scripted clicks never
  reached MoveInput; now IGNORE like its vignette/tempo-label siblings, and adjacent-
  click stepping works again (verified end-to-end: scripted client click → host-accepted
  glide onto the exact tile, under the follow camera). Harness click= synthesis composes
  the canvas transform (the camera made it load-bearing). Hardening + tidy: set_tempo
  refuses malformed/non-positive beats (wire is refused, never coerced); tempo
  bounds/step → GameConfig @exports (designer-editable rule); ONE beats→seconds site
  (GameManager.beats_to_sec) and one tempo formatter replace ~11 scattered copies;
  late-join tempo sync unconditional (same-frame race closed); monster brain rest-wake
  is one scheduled timer, not an epsilon poll; camera follow single-path. Recorded, NOT
  fixed (design venues): a move-into-hostile during the REST half is refused as
  still-committed — CORRECT per the Commitment Rule, the parked queued-attack-slot is
  the venue if it feel-tests as lag; the parked hold-origin toggle branch
  (origin_frees_at_glide_start=false) now lags occupancy behind the visual by the rest
  beat (ROADMAP Q4 note); aggro latch semantics clarified in §2.3.3.
- **v0.7.0 (2026-07-19)** — M3.5: THE BEAT BECOMES A VARIABLE (Jon+Jeff Discord/voice
  notes, post-v0.6.4 test). New §2.8: global `beat_sec` (default 0.25); every action
  duration authored in beats (`glide_beats`/`windup_beats`/`recovery_beats`/
  `move_rest_beats`), stamped to seconds only at verdict time (STAMP-AND-BAKE — tempo
  changes never touch in-flight commits). Live +/- tempo knob: any peer requests via the
  intent pipe, host clamps (0.10–1.00, 0.05 steps) and broadcasts; readout + log line +
  F3 line + late-join handshake sync; ship-it question → new Q8. GO-STOP-GO movement:
  step = 1-beat glide + 1-beat rest, all part of the commit, all movers; pipeline
  promotion moves to rest-end (RTT budget widens to two beats). WINDUP EXPERIMENT CLOSED
  (§2.3.3): failed both directions (0.25s invisible, 0.5s dodgeable-every-time) —
  instant strike + 2-beat visible recovery on BOTH sides ("equal in time and ability"),
  machinery preserved behind windup_beats=0; re-test-with-AoO parked. Aggro persistence:
  range is acquire-only, `aggro_persists` default true ("he shouldn't turn off aggro").
  Disposable multi-room hand-carved map + per-peer follow camera (screen-size eval —
  M4a's generator untouched). Potions/inventory noted and parked to M5 (an N-beat
  commit once beats exist — Jeff's "same natural rhythm").
- **v0.6.4 (2026-07-19)** — First DESIGNED combat SFX: SFX_CombatHitDesigned02.wav
  (sourced by Jon) replaces the generated impact.wav on the monster's Hit player, at
  natural pitch. Scope is deliberate: only "player hits an enemy" — a player TAKING a
  hit still plays the impact.wav placeholder, keeping the two hit directions aurally
  distinct (§2.3.4) until a designed counterpart arrives.
- **v0.6.3 (2026-07-19)** — Hit juice, honest bonk, 2-beat windup, transport-truth
  departures (Jon's v0.6.2 notes). Two GENERATED placeholder sounds (script committed):
  slash.wav (swept-noise swish) and impact.wav (110Hz thud) — hits/swings/death leave
  the bonk family; bonk now means exactly "the world refused your move." Red hurt
  vignette (local-only screen flash when YOUR avatar is hit) + red slash streak across
  any victim (deterministic 4-angle table off the attack dir). **Windup = 0.5s (2
  beats, FLAGGED FOR JEFF):** Jon's second readability test confirmed 0.25s is below
  the perceptual floor for any tell — the coil/blink approach wasn't wrong, it was
  starved; grid-aligned at 2 beats, one .tres number to revert; movement/swing stay
  0.25. Departure lines moved from node-exit to TRANSPORT truth (peer_disconnected,
  relayed to all peers — server_relay default): death no longer prints "X left.", F5
  reset no longer spams the client log, real quits still log everywhere (verified all
  three). _resetting removed (its mute job vanished with the node-exit hook).
- **v0.6.2 (2026-07-19)** — Sound grammar + blink tell (Jon's v0.6.1 verdict: flash
  "too much — needs to be a blink"; too many noises). Movement is SILENT (the §2.2.8
  ack is the flash alone; the tick is gone); combat is exactly swing + impact, pitch-
  separated (swing = commit_sent high/short 1.5-1.7, impact = bonk low 0.7 — standard
  whoosh-vs-thud timbre grammar); the windup tell is one sharp white BLINK
  (Monster-exported peak/in/out knobs) over the HELD coil — motion carries the plant,
  light marks the instant. Windup sound removed. KEPT deliberately: the rejection bonk
  (§2.2.8 — a refused move must never be silent; errors only, not spam) and the death
  sound. All sounds are still pitch-shifted placeholders — the real SFX pass stays
  parked. Honest verification note: the grammar is code-path-verified (sole call sites
  silenced/restored, whole-project grep); the ACOUSTIC verdict is Jon's first launch.
- **v0.6.1 (2026-07-19)** — Attack choreography: plant, flash white, strike, rest
  (Jon's first v0.6.0 test answered the telegraph question NO — see §2.3.3). New
  MonsterType.attack_recovery_sec (goblin 0.25): one beat of stillness after each
  strike — brain pacing, not a commitment; cycle ~0.55s, DPS near pre-rhythm. True
  -white windup tell via a minimal canvas shader (modulate can't whiten) + snap-and-
  hold coil released into the lunge; settle-at-center invariant on the release.
  Verified two-instance: strict windup→attack alternation with zero interleaved
  goblin moves, adjacency survival 2.1s → 3.9s, and — with a stretched telegraph —
  a live dodge-to-whiff, proving the parked mechanic returns whenever windup_sec
  grows. Readability at real 0.25s speed: Jon+Jeff re-test next session.
- **v0.6.0 (2026-07-19)** — THE RHYTHM BUILD (Jon+Jeff wire-session notes, first combat
  session over the tunnel). One 0.25s beat for every action, every entity: all speed
  tiers authored to 0.25 (structure kept), diagonal multiplier 1.0 (Jeff: keep the
  variable, no change for now), player swing 0.25, goblin windup 0.25 (dodge window
  knowingly parked — Jeff: "what was this dodge thing?"). NOT a global tick — actions
  start on commit and share only a duration; Commitment Rule/event model untouched;
  pipeline bound holds (0.25s vs 66-83ms measured RTT). Equal speeds move chases onto
  position — corners, chokepoints, body-blocks — nobody outruns anybody in open field.
  Provisional toggles (all default-original, flipped in game_config.tres): AoO off,
  click pathing off (adjacent-square clicks only — Jeff: "if you click 8 spaces ahead
  nothing happens"). New MonsterType.aggro_range_tiles (Chebyshev; 0=unlimited; goblin
  5) — checked every think, so acquire gate AND leash. Bowstring attack animation
  (pull-back then lunge past the tile edge, Jeff's drawstring). Audio trim: landed hit
  = target hit sound only; commit/windup cues -6dB. Verified two-instance: lockstep
  0.25 cadence incl. diagonals, leash at authoritative range 5, zero AoO events,
  adjacent-click single steps, silent far clicks, F5 reset clean.

- **v0.5.6 (2026-07-18)** — Post-wire-session review hygiene on the reset key (5-angle
  code review of v0.5.4/v0.5.5; verified against the first Jon+Jeff combat wire session
  running live). Field + screenshot evidence REFUTED the one scary candidate (client-side
  despawn/respawn name collision — the client renders post-reset movement correctly; the
  spawner orders same-batch despawn-before-spawn). Landed: reset event named
  `round_reset` (namespace room for M6); `_peer_names` roster written in `_spawn_config`
  — the one chokepoint every player spawn passes; respawn iterates the roster directly
  (insertion-ordered, host-first by construction); `_resetting` re-documented as
  mute-only and its unreachable re-entry return removed (body is synchronous); redundant
  `is_echo` filter dropped (`is_action_pressed` filters echoes by default, per docs).
  CONFIRMED and still OPEN (Jon to triage): each reset spams the CLIENT's log with bogus
  "X left./joined." lines — the mute is host-side only; the right-altitude fix is moving
  departure lines from node-exit to transport truth (`peer_disconnected`), which would
  also fix the pre-existing "X dies." + "X left." death double-line.
- **v0.5.5 (2026-07-18)** — F5 reset race fix, found by Jon's FIRST manual press (the
  humbling kind): v0.5.4's queue_free + awaited process_frame let the old nodes' exit
  hooks fire AFTER the respawn had seeded — erasing the new round's referee state by
  entity id ("Move rejected (not in session)" forever, unmuted "left." lines). Fixed
  by collapsing the window, not tuning the wait: the reset body (now call_deferred
  from the input handler, is_echo-filtered) frees entities SYNCHRONOUSLY, so hook
  cleanup provably completes before the re-seed — ordering is a property of the code,
  not the engine's phase schedule. v0.5.4's verification gap named honestly: its
  scripted runs never submitted a player move post-reset (goblin chasing made the
  world look alive). The harness now reproduces the bug on the old code, passes on
  the fix, and asserts accepted post-reset player glides on both roles — the symptom
  net this class needed. Known pre-existing cosmetic (predates the reset key): a
  death prints "X left." beside "X dies." — parked.
- **v0.5.4 (2026-07-18)** — Dev round-reset key: host-only F5 re-seeds the whole world in place
  (despawn all + respawn from a host-only name roster + fresh goblin) so a wire session can iterate
  rounds without tearing down two instances and the tunnel. Explicitly DISPOSABLE — M6's real run
  start/end flow replaces it; not a Commitment Rule leak (a world re-seed is disconnect semantics —
  the world ended, nobody backed out of a decision within it), host-authored, no client reset surface.
- **v0.5.3 (2026-07-18)** — Code-review fix pass on the v0.5.2 series (5-angle review,
  GLM red-teamed the review itself; 8 fixes, 6 declines recorded in the commit). The
  Entity contract completed: `max_hp` and `display_name` are now Entity-level and
  assigned PRE-TREE by the spawn configs (uniform with entity_id/tile — correct at any
  read time, closing the empty-name window and the duck-typed HP seed); wind-up default
  gets ONE authoring site (MonsterType.DEFAULT_WINDUP_SEC — the referee's shadow copy
  removed); redundant entity_id re-assignment, triple-site HP formatting, an AoO double
  node-resolve, and a duplicated flash color cleaned; a whiff from a non-Monster attacker
  now warns instead of silently dropping feedback (§2.3.4). GLM's review-of-the-review
  caught a null-deref in one proposed fix (nulled monster_type) before it shipped —
  fixed in spec. Verified two-instance (combat regression, zero empty names, zero
  errors) + screenshot (labels/nameplates render identically).
- **v0.5.2 (2026-07-18)** — Full docs+code review pass (no bugs found; every ground rule
  verified in code) + the Entity refactor it motivated. **Architecture boundary decided
  (now a CLAUDE.md convention):** universal entity contract → `Entity` base class;
  varying/optional behavior → component child (the existing MoveInput/MonsterBrain
  pattern); authoritative state → referees only, never on replicated nodes — MWF's
  HealthComponent model explicitly rejected for this game. Player/Monster's ~100 mirrored
  presentation lines now live once in `entities/entity.gd`; referees seed/read one
  entity_id space branch-free. GameConfig is now an authored .tres (Jeff flips playtest
  toggles without code; missing file = loud error + script defaults). Authoring-model
  correction, learned from the editor: Godot's saver strips default-equal properties, so
  .tres/.tscn store OVERRIDES only and script defaults are part of the authored surface
  (monster_type.gd records it). Scene uids assigned (editor resave) and code preloads
  switched to uid://. **Spec addition (ROADMAP M4a):** generated maps keep a full solid
  border ((0,0)-is-wall sentinel) and regeneration rebuilds the cached A* grid. §2.5.1
  wording: MultiplayerSynchronizer removed from the named toolkit (excluded since v0.3;
  the listing predated the ban). Verified two-instance post-refactor: party wipe with
  session surviving, bump chain, AoO-on-flee, dodge=whiff, version gate.
- **v0.5.1 (2026-07-18)** — Code-review fix pass on the gate: kicks are now
  flush-before-disconnect inside the transport contract (ENet `peer_disconnect_later` —
  review proved plain disconnect RESETS queued reliable packets, so v0.5.0's delayed kick
  was a race, not a guarantee; delivery is bounded by ENet's disconnect timeout, never
  claimed absolute); a refused-peer set kills retry log-spam and the flush-window
  re-admission race; capacity refusals now logged host-side (symmetry); one
  `GameManager.build_version()` read replaces four drifting copies; `fakever=` is scoped
  to its session (cleared on teardown).
- **v0.5.0 (2026-07-18)** — Version gate: the host refuses joins from a different build at
  `peer_ready` (client version rides the handshake; exact match while 0.x), with the
  reason — both versions named — delivered over a new `session_refused` RPC before the
  kick; the same channel finally carries the parked "Server is full." message. Legacy
  pre-gate builds fail closed (arity drop → the existing timeout, whose message now hints
  at version mismatch). `fakever=` harness knob for scripted mismatch tests.
- **v0.4.1 (2026-07-18)** — Post-M3 polish: HP readout moved off the nameplate to its own
  label under each entity's feet (Jon — readability); first combat tuning pass recorded
  (player melee 5→2, goblin speed tier → slow — Jon: "too fast for a real time game";
  FEEL-TEST PENDING the next wire session — recorded, not validated); §2.3.2 stops quoting
  tunable numbers (they live in player.tscn exports / MonsterType .tres, where tuning
  happens).
- **v0.4 (2026-07-18)** — M3 (First Blood): §2.3 rewritten for DETERMINISTIC combat (RF3
  baseline, Jeff via Discord — accuracy/evasion rolls and roll types PARKED for the build
  pass); bump attack (Jeff: move-into-enemy, in-place lunge) and monster TILE-commit
  telegraphs specced (§2.3.3 — vacate to whiff, telegraph commits to ground); §2.2.6 AoO
  now deals real damage with the alive/able gate; entity-id space (players > 0, monsters
  < 0) behind the one referee occupancy; Q1 death placeholder shipped (instant despawn +
  spectate log, disposable — question stays OPEN, mid-commit semantics recorded as
  placeholder). RF3-scaled placeholder stats in resources (warrior 20/5, goblin 10/3).
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
