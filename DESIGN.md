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

*Two sanctioned exceptions exist, both scoped and both documented at their site: an opponent-imposed
**STUN** interrupts an in-flight attack/cast (§2.11 — crowd control, not a self-take-back), and rule 3
plus Part 4 Q9 are **suspended for two abilities inside the `instant_abilities_enabled` experiment**
(§2.11.1 — provisional, verdict pending; off = these rules hold everywhere). **That experiment SHIPS ON**
(`instant_abilities_enabled` default true, no `.tres` override), so the second exception is LIVE by
default — a reader must not take "off = the invariant holds" as a description of the shipped build.*

### 2.2 Movement

1. World is a tile grid. Every entity occupies exactly one tile.
2. Moving = a glide: entity commits to an adjacent tile, then smoothly animates into it over
   a real-time duration. Position data is discrete; presentation is smooth.
3. Glide duration is stat-driven, in discrete speed tiers (breakpoints), not a continuous
   scale. **Rhythm experiment (v0.6.0, Jon+Jeff wire notes 2026-07-19, provisional):** all
   tiers are currently AUTHORED to the same 0.25s beat — one action rhythm for every
   entity ("if I hold right and the goblin holds right, we reach the edge together" —
   Jeff). The tier structure stays; variation returns by editing .tres values.
   **v0.7.0:** tiers are now authored in BEATS (`glide_beats`) against the global
   beat (§2.8) — fast/normal/slow all 1.0, and since v0.23.0 the authored-but-unused
   `speed_lumbering` tier sits at **1.5** (the Warren brute's anvil pace, waiting on a
   hold-position behavior — §2.12), so the rhythm experiment's uniformity is now
   "every tier a monster actually uses", not literally every tier. **v0.8.0 (Responsive Beat):** a step is back to **1 beat TOTAL**
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

**§2.2.10 — STAMINA (v0.24.0 as "movement points", renamed + softened v0.24.1; GRADUATED to a core
rule by Jeff's verdict 2026-07-26 — no longer an experiment).** Battle movement is a budget:
tactical-pace steps spend 1 stamina from a pool. **The pool is ONE point, both sides** (Jeff's
verdict; the rogue's per-class +1 was dropped with it) — a tactical step is a single decision that
spends everything, so the design question moved from "how many steps left" to "am I ready yet."
What varies is RECOVERY: the rest-to-recover idle wait is picked from the mover's **armor weight**
(§2.3.8 — since v0.27.0 that band is read off the WORN body item through the one resolver
`Player.worn_armor_weight()`, not off the class; the class-level phase-1 fields were deleted with it) —
light/unarmored 2.5, medium 3.0, heavy 3.5, monsters 3.5 **beats**
(*units pending Jeff confirmation — he tuned beat-denominated panel dials*). Heavier armor rests
slower; that is the whole cost curve. The per-point interval and instant-refill dials survive
live-tunable but are **moot at max 1** (the first tick fills the pool). At 0 stamina you **cannot move at
all** — the distinct "winded" reject — since **v0.27.0 made hard stop the DEFAULT on both sides** (Jeff's
second playtest verdict: at a one-point pool the crawl was a soft answer to a binary budget, and the spend
should actually gate the step). The v0.24.1 **crawl** (`player_`/`monster_exhausted_step_beats`, 5/tile —
"very slow, never stopped") survives behind `/winded` and the two `*_exhausted_blocks_movement` fields, so
the softer shape is one keystroke away. Pool refills on battle entry (LOCKOUT-gated by
`*_refill_lockout_beats` — a pace flicker back into the same fight keeps the earned pool); otherwise
ONLY by resting, and any move or committed action restarts the clock. Attacks never spend; explore
movement untouched; monsters ride the identical check and additionally roll 1–6 beats of visible
hesitation (whole brain held) at story-beat moments — battle entry (a "!" alert pop, then "…"
dots), target-died retarget, last-stand (allies all dead — the finale pause), and a cornered stall
(each once per life; v0.24.3).

**RECOVERY LOCKS ACTIONS (v0.28.0, `recovery_locks_actions`, DEFAULT ON — Jeff's third batch: "try not
allowing the player or the enemy to do any actions when your stamina is recovering from a move").** While
an entity sits at 0 stamina in tactical pace — the recovery bar showing — every **NON-MOVEMENT** action is
refused with its own distinct **`recovering`** reject (its own token, never folded into `winded`): a bump
attack, an ability (STRIKE *and* instant — the gate sits with the stun gate, above the instant dispatch, so
"a stun blocks instants" and "recovering blocks instants" agree), a shot, a drink, an equip, a pickup. A
MONSTER is gated the same way, in its brain, at every attack/cast decision — a monster's swing never passes
through an intent validator, so that is where the enemy half lives; it reschedules to the end of the
recovery wait rather than spinning on its back-off cadence.
  - **It is a gate on STARTING an action, never a cancel of one in flight** — same position and shape as the
    STUN gate it mirrors, touching no busy or pending record, so §2.1 is untouched.
  - **SCOPE: it does NOT cover movement.** Moving at 0 stamina stays the winded/crawl dials' business, so the
    two are **independently toggleable**: `/winded 0` + lockout ON = crawl freely but cannot attack;
    `/winded 1` + lockout OFF = frozen in place but may still swing. They are not orthogonal *conditions*
    (both fire off the same 0-stamina signal) — they are two **channels** over one condition, each with its
    own dial. They cannot mask each other structurally: a plain move never reaches the action gate (it lives
    inside the hostile-occupant branch of the glide validator), and a bump never reaches the movement spend
    site (it returns at the windup route / bump commit, ~35 lines earlier).
  - **Hostile bump only, and that is an assumption with a shelf life.** A hostile bump is the only
    attack-shaped MOVE today — no doors, no destructibles, nothing bumpable. The first one that lands must
    revisit that gate or it will silently escape the lockout.
  - `stamina_enabled 0` makes the whole lockout a **no-op** (it is the predicate's first term), so "default
    ON" means "on whenever the stamina system itself is on".
  - **Two different "recoveries", deliberately NOT wired together:** this one is the stamina POOL at 0 (the
    green bar). §2.3.9's `whiff_pays_recovery` concerns an attack's committed recovery BEATS. Attacks never
    spend stamina, so releasing a whiff's window cannot move the pool and there is no state to keep in sync.
  - **Status: PENDING Jeff's verdict, alongside the instants experiment** — graduate or revert with
    `recovery_locks_actions 0`.

**PARTIALLY REALIZED (v0.29.0; envisioned Jeff 2026-07-26).** The green recovery bar as the ONE "when can
I act again" read for all actions: as of v0.29.0 every MELEE attacker — player and monster alike — shows
the same transparent-sprite + filling-bar + ready-blink presentation over its post-strike recovery window
(riding the host-stamped `duration_sec` already on the attack event; the weapon swing animation still
plays alongside). Arbitration when both recoveries want the slot: the STAMINA bar wins (the rarer, more
important state); the attack bar self-clears client-side on its stamped duration, while the stamina bar
keeps its host-owned end edge. Still envisioned: casts and the bow draw joining the same read — that is
where this section's pool and §2.3.9's committed windows would fully MERGE.

**THE SYSTEM'S NAME IS STILL OPEN.** Jeff asked for a better one than "stamina"; Jon deferred the decision
(2026-07-26), so it stays "stamina" in every command, field and doc until he calls it. Nothing was renamed.

**Presentation (v0.26.0, §2.3.4; sweat INVERTED v0.27.0).** A spent entity — player or monster — goes
semi-transparent and grows a thin vertical **recovery bar** beside its body that fills over the
host-stamped wait, ending in a two-pulse **ready blink**; the bar restarts whenever activity restarts the
clock. The **sweat-drop marks the CRAWL** — the non-hard-stop mode, and only that. v0.26.0 had it the
other way round, which read backwards once hard stop became the default: the hard-stop mode already
announces itself twice (a distinct reject bonk on every refused step, plus the bar), while the crawl's
whole tell is "I am still moving, but wrong". Each mode now has exactly one visual signature. HUD **pips
appear only when max > 1** — at 1 the body's own cue is the read; raise the dial and the pips return.

STICKY SWINGS (v0.24.8; **DEFAULT ON since v0.29.0, and the two-tile bug fixed at the root**): a melee
wind-up still catches its intended victim if it sidestepped but stayed adjacent to the swinger — a
deliberate, toggleable bend of §2.3's commit-to-ground rule (`swing_catches_adjacent`). Jeff's v0.27.0
verdict had retired it because it read as "attacks landing from two tiles away" — v0.29.0 traced that
read to a REAL bug that was never the sticky catch at all: the PRIMARY hit test struck whoever's
*occupancy* sat on the committed tile, and occupancy flips to a glide's destination at accept, so a body
still visibly two tiles out mid-glide ate the hit (toggle on or off — reproduced headlessly pre-fix).
The referee now requires the victim's ENTIRE motion record (occupancy + glide/pipeline from/to) within
Chebyshev 1 of the attacker on BOTH hit branches, UNCONDITIONALLY — no path can land a hit on a body
that could render outside the ring, and the toggle's meaning narrowed to just "the swing follows the
mover": ON (shipped) = sidestep-within-reach is caught, backstep-to-two always whiffs; OFF = strict
tile-only commitment. Jeff's arc rule verbatim: adjacent = hit, two tiles = never. The story beats drive
GOBLIN BANTER (v0.24.4, expanded v0.27.0): host-picked overhead one-liners (chance-rolled, globally
cooldown-throttled) — lines are GameConfig content, and the **nine moments** are engaged / retarget /
last-stand / cornered (story-beat thinks), ally-died and its louder twin notable-death (a `banter_notable`
monster — the shamans — dying; mutually exclusive, both forced past the chance roll and now scoped to a
packmate actually IN the fight), forced-melee (a kiter made to swing), idle (rare out-of-combat muttering
on each monster's own 15-30s timer) and help-me (a notable monster hurt while its pack still fights, once
per life). **EARSHOT (v0.27.1, `banter_earshot_tiles` = 12):** the two REACTION moments — the death
bark and help-me — additionally require the reacting monster to be within that Chebyshev distance of the
moment (the corpse's tile / an engaged ally's tile). Engagement alone answers "is a fight happening
*somewhere*", which with three authored packs in separate rooms and a party that splits up produced
cross-fight barks; earshot is what makes it "*my* fight". **v0.28.0 widened that one dial to mean "how far
a bark CARRIES" (Jon: gate ALL barks by distance, not just idle):** every bark now ships the speaker's
authoritative tile, and each peer's COMBAT LOG prints the line only when its own player is within
`banter_earshot_tiles` of it. The **overhead label stays ungated** — it floats over the speaker, so distance
already hides it, and per-peer gating would break the "every peer reads the same line" premise. Three cases
print past the gate: no own player (a **dead player is an earshot-less SPECTATOR and hears everything** — a
corpse has no tile to measure from, and losing the log while watching the fight you just died in is worse
than overhearing a distant goblin; a tradeoff Jeff can veto), a missing/malformed speaker tile, and a
wall-sentinel tile on either side — a sentinel must never silently swallow a line. Every dial is split player_/monster_ (v0.25.0) and lives on the backtick DEBUG
TUNING PANEL (docs/dev-commands.md) — a GUI over the same server-authoritative dev_command pipe,
with per-INSTANCE monster forks via `/mi`. Intent, unchanged: movement improves positioning but can
no longer invalidate attacks (the kiting thread) — a fleeing healer burns dry and crawls. `/stamina`
(alias `/mp`) survives as a **dev escape hatch** (off = pre-stamina behavior exactly), not as the
revert switch it was while this was provisional.

### 2.3 Combat Resolution

1. **Deterministic TO-HIT (decided 2026-07-18, Jeff via Discord + Jon — Rogue Fable III
   baseline, which has no to-hit rolls):** every attack that resolves against a body **lands**.
   The original accuracy/evasion two-step roll and the roll-type list (miss, crit, block,
   passive dodge, spell resist) are **PARKED** for the future build-system pass — if those
   rolls ever return, they return through that design, not by default. Whether you get hit
   at all is decided by POSITION, not dice (see item 3).
   **AMENDED v0.26.1 (Jeff, 2026-07-26 — the Q11 answer): the DAMAGE NUMBER is rolled.**
   Each landed hit rolls uniformly in the weapon's authored band
   (`WeaponType.damage_min`..`damage_max`, §2.3.7) — longsword 3-5, dagger 2-6, club 1-4,
   bow 4-4. This is deliberately the *narrow* half of the original roll list: **position
   decides IF you are hit, the band decides how hard.** There is still no miss, no crit, no
   dodge and no block roll — a swing that reaches a body always connects, so the parked list
   above stays parked and the §2.1 "decisions carry risk" reading is unchanged (the risk was
   never "did I connect"). The roll is HOST-side at one seam per attack kind and rides the
   existing attack event; a collapsed band (min == max) is exactly fixed damage, which is what
   the `/w <weapon> <n>` shorthand authors. Applies to weapon damage only — fists, kicks,
   heals, smites and ability damage stay fixed numbers.
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
   *(It WAS: v0.27.0 restored it by authoring windup on every melee weapon — see the v0.27.0
   amendment below. The "one .tres number" prediction held exactly.)*
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
   goblin is spent — now's my window"). Player and goblin recovery were both authored 2 beats
   at v0.7.0, so attack rate = movement rate ("equal in terms of time and ability" — Jon's note).
   The telegraph/whiff machinery was PRESERVED behind `windup_beats` — a future heavy monster
   may windup, ideally re-tested WITH AoO enabled, the configuration where dodging finally
   costs something (parked beside the §2.2.6 AoO toggle). *(Superseded v0.18.x/v0.19.0: the
   goblin DOES telegraph — its club had base windup 0 and the goblin adds a **+1 windup
   wielder-modifier** (§2.3.7 base+modifier), so the telegraph lived on the slow WIELDER, not
   the weapon.)*
   **AMENDED v0.27.0 — the heavy telegraph is now the DEFAULT, and so are longer recoveries
   (Jeff's second playtest verdict promoted the whole `/config 2` loadout to shipped values).**
   Two claims above are no longer current truth:
   - **Nothing is instant any more.** Every shipped melee weapon authors `windup_beats > 0` —
     longsword 3, club 3, dagger 2 — against the 0.25s tactical beat that shipped in the same
     release (§2.8.7), so a 3-beat telegraph is 0.75s of readable wind-up. A PLAYER telegraphs
     too: `MoveReferee` routes a bump through the shared `wind_up` path whenever
     `CombatReferee.melee_windup_beats_of(mover) > 0`, which is now every melee weapon.
   - **Recovery is no longer 2 beats and attack rate is no longer movement rate.** Every player
     weapon authors `recovery_beats` 4.0; the goblin's club resolves to 5 (base 4 + its
     `bonus_recovery_beats` 1). The only surviving 2.0 is `Player.attack_recovery_beats`, the
     no-weapon fallback — which is not what the v0.7.0 sentence meant. An attack is deliberately
     several steps' worth of commitment now.
   What is still PARKED is only the OTHER half of the pairing: **AoO stays disabled**
   (`attacks_of_opportunity_enabled = false` in game_config.tres), so the telegraph shipped and was
   playtested in the configuration where dodging is still free. Re-enabling AoO is the remaining
   feel pass (§2.2.6, and the Part 4 Q9 tail).
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
   **The WIND-UP no longer writes a log line (v0.28.0, Jeff's third batch: "nothing needs to be written in
   the combat log when someone winds up or is about to attack").** A telegraph is not an outcome, and the
   one line fired on every melee windup, every ability-strike telegraph and every bow draw — at fight
   volume it was most of the log. The `windup` EVENT is untouched and still carries the whole telegraph:
   the coil, the white flash, the telegraph sound and the weapon rig's raised pose. Four tells go quiet in
   text only; the likeliest to come back is the player's OWN bow draw, whose remaining tells are just the
   rig's skyward raise and the pitched-down draw sound (the cheap restore is a player-initiated-only
   variant of the line, not the whole arm). Monster CAST channels keep their lines — a heal channel and a
   smite channel are the shaman's only tell, and Jeff asked for those explicitly.
   **A refused PICKUP finally has both channels (v0.28.0):** `pickup_item` was the one reject pipe with no
   bonk *and* no log arm, so a refused G press was indistinguishable from a dropped keypress.
   **THE DAMAGE-NUMBER COLOUR CONVENTION (v0.28.1, Jon's ruling 2026-07-26).** Floating combat text carries
   ONE meaning in its colour: **who a number happened to.** Four colours, defined in exactly one place
   (`DamagePopup`'s const block) and applied at one site (main.gd's attack/heal handlers):
   **RED** = a PLAYER took the damage · **WHITE** = anything else took it (a monster) · **GREEN** = a heal,
   on any target · **YELLOW** = a CRITICAL hit — **RESERVED and unused**, since no crit system exists.
   White, red and green are live; yellow is a held reservation so nothing else claims it. **Grey stays
   OUTSIDE the convention** as the *no-number-happened* colour (a whiff's "miss", a godded "0", a
   block), so it can never read as a real number. Colour is keyed off the **TARGET** — one predicate that
   answers monster-on-monster and any future PvP exhaustively — where Jon framed the rule by attacker; the
   two readings are identical for every case that exists today, and the one divergence (self-damage /
   thorns / reflect would read RED) is recorded at the const block to be re-decided if that mechanic lands.
   **Colour never encodes MITIGATION** — v0.27.1's steel-blue "armor absorbed some" popup is gone (§2.3.8);
   armor's §2.3.4 obligation is met by the log line, which can name the amount.
5. Combat presentation stays abstracted (targeted commands, no implied precise physical
   contact). Do not show pre-commit hit percentages.
6. RNG budget: keep output randomness low-magnitude. Replayability comes from input
   randomness — dungeon gen, loot, encounters — not from swingy rolls. A bad outcome should
   always leave the player a real next decision, never just erase a correct one.
   **The damage band IS this rule's instrument (v0.26.1).** Now that a hit rolls (item 1),
   the *spread* is the dial: it is authored PER WEAPON, so a weapon's swinginess is part of
   its identity rather than a global noise level. Dagger 2-6 is the deliberately swingy pick
   (its low end is a real cost for its 1-beat tempo); longsword 3-5 is the dependable one;
   bow 4-4 is flat. Budget check for any future band: the worst roll must still be a hit
   worth having, so the low end stays meaningful — a band whose floor makes a correct
   engagement feel erased is over budget, and the fix is a narrower band, not a re-roll.
7. **§2.3.7 — Weapons as objects; actions as beats (v0.9.0, M3.7).** A player's weapon is a
   designer resource (`WeaponType`, `resources/weapons/*.tres`) — add a weapon by dropping a
   `.tres`, never by touching code (the §2.5 designer rule). Two field groups:
   - **Gameplay** (read HOST-side by the combat referee; never the wire): `recovery_beats` (renamed from `attack_beats` v0.23.1 — the
     BEATS this attack OCCUPIES *after* it resolves, with no separate cooldown beside it, per Part 4
     Q9), **`damage_min` / `damage_max`** (the rolled band, v0.26.1 —
     replacing the single deterministic `damage`; see item 1), and `windup_beats` (the telegraph
     before the strike; 0 = an instant strike at commit). The occupied window is the SUM —
     `commit_in_place(windup_sec + recovery_sec)`, one busy record (the v0.19.0 double-hit fix) — so
     Q9's "one timeline, one window" holds; it is just no longer spelled by `recovery_beats` alone.
     **STATUS (v0.9.0, AMENDED v0.27.0 — now current):** the referee reads the equipped weapon's
     damage band, `recovery_beats` *and* `windup_beats` when it stamps a bump. Player windup was the
     v0.9.0 scope cut ("authored but not yet wired"); it was wired for players in v0.19.2 and became
     the DEFAULT bump path in v0.27.0, when every melee weapon gained a nonzero telegraph — a player
     bump now routes through the shared `wind_up` machinery whenever
     `CombatReferee.melee_windup_beats_of(mover) > 0`, and the instant path survives only for a
     windup-0 weapon (none ships) and the ranged point-blank kick. The legacy player exports
     (`melee_damage`/`attack_recovery_beats`) are the no-weapon fallback only.
   - **Base + wielder modifier (v0.19.0).** A weapon's damage band /`windup_beats`/`recovery_beats`
     are the BASE; the wielder adds a SIGNED modifier on top, floored at 0 by the referee —
     `MonsterType.bonus_damage`/`bonus_windup_beats`/`bonus_recovery_beats` and `Player.bonus_damage`
     (the future strength-stat hook). The modifier is still how the SAME weapon is slower in a
     monster's hands: the goblin adds **+1 windup** and **+1 recovery** to whatever it holds, so its
     club resolves to 4 windup / 5 recovery against a player's 3 / 4. **AMENDED v0.27.0 — but the
     TELEGRAPH no longer comes from the wielder.** The v0.19.0 form of this claim was "club base
     `windup_beats` 0, instant as a player bump, and the goblin's +1 is the whole telegraph." The club
     now authors **windup 3**, so 3 of the goblin's 4 telegraph beats live on the WEAPON and a player
     wielding the same club telegraphs 3 beats too. The honest reading of the split today: the weapon
     says how heavy a swing is, the wielder says how much *worse* they are at it — a difference of
     degree (one extra beat), not the difference between telegraphed and instant.
     The beat-bonuses are **melee-only** (a ranged weapon's `windup_beats` is its
     draw — a wielder bonus must never retune the bow); `bonus_damage` applies to all.
     **LAYER ORDER, restated for the band (v0.26.1): rolled weapon damage → flat wielder
     `bonus_damage` → passive `modify_damage` chain → armor mitigation (§2.3.8) → HP.** The roll is
     the base the rest of the stack operates on, so a backstab multiplies the number that was
     actually rolled and armor shaves the number that was actually earned. **Arrow fix, same
     release:** ranged shots used to skip the wielder bonus entirely — a drift from this section's
     own "`bonus_damage` applies to all" — and the ranged roll site now adds it, so the code matches
     the spec. Zero live change today (there are no monster archers and `Player.bonus_damage` is 0);
     it is closed so the first strength stat or archer doesn't inherit the hole.
     This split IS the loot spine: enemies drop their equipped weapon on death (v0.19.x) and the player
     equips the very same object, resolving its stats through their own (0-today) modifiers.
   - **Animation** (presentation-only; gameplay NEVER reads these): `atlas_coords` into
     items.png, `attack_style` (stab | slash, v1), the phase fractions
     `startup_frac`/`active_frac`/`recovery_frac`, the small tween knobs
     (`orbit_radius_px`/`arc_degrees`/`reach_px`/`lean_degrees`/`recoil_px`) and — added as the
     telegraph became real art — the three WINDUP-pose knobs
     `windup_raise_degrees`/`windup_reach_px`/`windup_shake_degrees` (how far behind the swing's start
     edge the rig parks, how far past `orbit_radius_px` it sits so it clears the silhouette, and the
     pre-launch jitter). Those three are ignored at windup 0 and for stab/draw styles; with windup live
     on every melee weapon since v0.27.0 they are the knobs a designer actually reaches for.
     The client-side **weapon rig** plays
     the three phases as fractions of the STAMPED window (it NORMALIZES them at playback, so a
     `.tres` authoring error can never push a phase past the window — the referee's
     slide_fraction-clamp spirit).
   **DOCTRINE — animation explains state.** Phases (startup/active/recovery) are
   ANIMATION-INTERNAL slices of the occupied window; gameplay counts only beats. **The
   anticipation cap:** for a `windup_beats == 0` weapon the damage is instant-at-commit, so the
   pose must LOOK simultaneous with its damage flash — `startup` is ANTICIPATION ONLY and is
   kept ≤ ~0.15 of the window (the strike lands within the causality-perception threshold). A
   readable pre-hit windup is exactly what `windup_beats > 0` is for, where the damage genuinely
   lands later and a long startup is honest — which since v0.27.0 is EVERY melee weapon, so the
   anticipation cap now governs only the no-weapon fallback and the ranged kick.
   **The quick/chunk contrast moved from RECOVERY to WINDUP (v0.27.0).** At v0.9.0 it was authored as
   dagger 1 recovery beat vs longsword 2. Today both weapons author `recovery_beats` **4.0** and the
   contrast is the TELEGRAPH: dagger windup **2** vs longsword **3** (club 3), bands **2-6** and
   **3-5** (v0.26.1). So the dagger is the weapon that commits sooner and swings wilder, not the one
   that recovers faster — a knife-fighter's tempo read from the front of the action instead of the
   back. Both still Feel=-tunable in the `.tres`, and the free-beat kite the 1-beat dagger used to buy
   is gone with the 4-beat tail.
   **Weapon swap** is a dev-era control this milestone (the tempo-keys spirit): refused while
   busy (the Commitment Rule — no swapping out of a committed action), otherwise instant,
   host-validated, broadcast, over a hardwired 2-weapon roster (`GameConfig.weapon_roster`). The
   real game costs beats to swap once inventory exists — **M5 owns acquisition and replaces the
   hardwired roster.** Monsters keep their MonsterType attack fields this pass (unify later).

8. **§2.3.8 — Armor: worn weight + two-term mitigation (PHASE 2, v0.27.0; phase 1 v0.26.0 — Jeff's
   verdicts 2026-07-26).** Armor is **mitigation**, not a to-hit modifier — §2.3.1 stands: every attack
   that resolves still lands, it just lands for less. **Armor is now a WORN OBJECT.** `ItemType` (the
   canonical home of the `ArmorWeight` enum since v0.27.0) carries the **weight band**
   (unarmored / light / medium / heavy) and **`phys_damage_reduction`** (a 0–1 fraction absorbed);
   `PlayerClass` carries only `starting_body_armor`, the item a class begins wearing. Shipped items:
   **leather armor** LIGHT / 0.10 (rogue) and **chainmail** MEDIUM / 0.25 (knight) — the exact numbers
   phase 1 hard-coded onto the classes, now on things you can take off, hand over or upgrade. MonsterType
   keeps its own reduction field (0 today) as the armored-monster seam.
   - **TWO TERMS, min-combined (v0.27.0).** A physical hit on a player is reduced by the PERCENTAGE or by
     a **FLAT amount** keyed to the weight band (`GameConfig.armor_flat_reduction_light/_medium/_heavy` =
     1/2/3), *whichever leaves the defender taking less*. Why both: a percentage does nothing to SMALL
     hits (25% of a 2-damage club swing rounds back to 2), which is exactly where Jeff expected plate to
     matter, while a pure flat rule would trivialize big ones. **UNARMORED is 0% AND flat 0** — the
     absence of armor must never itself mitigate. Monster defenders keep the plain percentage path (no
     band, no flat table exists for them).
   - **The monster-damage FLOOR (v0.27.0).** A monster's physical hit on a player never lands for 0: if
     mitigation would zero it, it lands for 1. Jeff's worked example is 2 damage vs chainmail (pct 2,
     flat 0 → min 0), and an enemy that cannot hurt you is a broken fight. Player-dealt hits are NOT
     floored — the rule is about enemies staying threatening, not about rounding.
   - **The kind split.** Reduction is **PHYSICAL only**. `smite` is magic and bypasses it (armor is
     not a ward — a future magic-resistance stat is its own field), and **`admin` damage is exempt**
     so `/mi hp` / `/mi kill` stay exact — a tuning tool that lies is worse than no tool.
   - **Where it applies.** One host-side seam inside `apply_damage`, AFTER the attacker's passive
     `modify_damage` chain and BEFORE the HP subtraction: a hit is priced (weapon base → wielder
     bonus → passives, e.g. a sneak attack) and only then armored. **Rounds half-up**, keeps the existing
     0 floor, and read LIVE from the DEFENDER's worn item so an equip retunes the very next hit.
     A reduced hit carries an **`armor` tag** *and the points `absorbed`* on its event, and mitigation is
     made visible **by the COMBAT LOG** — *"Goblin hits Knight for 2 (13/20, armor absorbs 2)."* Until
     v0.27.1 the tag had **no consumer at all**, so this section's own §2.3.4 claim was false: at shipped
     defaults nearly every monster hit on a player is mitigated, and a chainmail knight saw a plain "-2".
     v0.27.1 answered that with a steel-blue popup *as well*; **v0.28.1 removed the colour half** (Jon),
     because popup colour now carries exactly one meaning — who took the number (§2.3.4's colour
     convention) — and a fifth colour answering a different question was fighting it. The log clause is
     the better channel anyway: it can say *how much*, which a tint cannot.
   - **The band has ONE resolver (v0.27.1).** `Player.worn_armor_weight()` answers "what weight band is
     this wearer in", and both consumers — this flat term and the §2.2.10 rest wait — read it. The
     weight-**promotion** rule below therefore has exactly one site to land in.
   - **The tradeoff philosophy (Jeff).** Heavy armor is not free defense: the *cost* is TEMPO. The
     armor weight band drives the stamina rest-to-recover wait (§2.2.10 — light 2.5, medium 3.0,
     heavy 3.5), so a heavier wearer acts less often, which since v0.26.0 is the primary way builds
     differ in movement — and since v0.27.0 it is a **choice you can change mid-run**: hand your
     chainmail to someone and you start resting like a rogue. **Envisioned, not built:** the same band
     carrying spellcasting penalties (a heavy-armored caster fumbling) and further mobility penalties.
   - **Phase 2 = ONE real slot, and the slot is now NAMED (v0.27.1).** Body armor equips, unequips and
     swaps through the bag (§2.10) with the weapon-equip precedent (instant, busy-gated). `ItemType`
     carries an **`equip_slot`** enum (body / off-hand / head / hands / feet / ring / amulet) and the host
     routes on it: **only BODY is implemented**, and anything else is refused with its own reason
     ("nowhere to wear that yet"). Before that, *any* EQUIPMENT item was body armor by assumption, so the
     off-hand kite shield §2.11.1 is waiting on would have silently replaced worn chainmail. Still future:
     the other eight sockets themselves, and the **weight-promotion rule** (the heaviest worn piece across
     several slots setting the band). With one armor slot, the body item's band IS the wearer's band —
     promotion is a no-op today, which is why it could wait, and it now has a single home to land in (the
     resolver above). See §2.10 and the ROADMAP equipment-slot bullet.
   - **`/class` reconciles the body slot to the class loadout (v0.27.1; the old piece is DISCARDED
     since v0.28.1).** Becoming a class puts you in exactly what that class wears — *including
     nothing*, which strips you. v0.27.1 returned the piece you were wearing to your bag; Jon's
     2026-07-26 ruling made it **DESTROY** that piece instead, because a few character swaps filled the
     bag with armor nobody asked for. So `/class` is the ONE path in the game that destroys an item —
     sanctioned because it is debug-only and the weapon half always worked that way — and with no bag
     traffic left, the v0.27.1 "bag full" refusal is gone too. Not silent: the `equip_item` event
     carries a present-only `discarded` field and the log reads *"(The leather armor is discarded.)"*
     The full rationale lives in **§2.10**.

9. **§2.3.9 — Whiff recovery: A TOGGLE, and it now ships ON (`whiff_pays_recovery` = true, v0.28.0;
   was "recovery only on contact" v0.26.0–v0.27.x).** A committed attack owns its whole window when it
   LANDS — windup plus the planted recovery tail (Part 4 Q9's unified occupancy is untouched, and so is
   the v0.19.0 same-window double-hit fix). What the dial decides is the **whiff** — the telegraphed tile
   was vacated, the ability found nothing, the smite's target dodged:
   - **`whiff_pays_recovery` TRUE (the DEFAULT since v0.28.0, and the pre-v0.26.0 behavior Jeff asked to
     have back):** the miss pays its full recovery tail. The committed window plays out untouched, the
     whiff event carries the real recovery seconds, and every peer shows the spent-recovery tint for it.
   - **FALSE (the v0.26.0 experiment):** the remaining recovery is RELEASED at resolution — you paid for
     the miss with the miss, not with a nap on top of it — the event stamps a zero gameplay duration, and
     a whiffing goblin re-thinks that same frame (the `busy_released` monster wake). Both sides,
     symmetric.
   With the flag TRUE, `busy_released` never fires, so the v0.26.0 whiff-wake is inert by construction.
   Positive polarity deliberately matches `stamina_enabled` / `recovery_locks_actions` — these get flipped
   live mid-playtest and an inverted flag is a footgun. **Not the same "recovery" as §2.2.10's lockout**,
   which reads the stamina POOL; this one is a committed-action window. The v0.26.0 rationale, kept because
   the toggle keeps it reachable:
   - **Why the release was tried.** The recovery tail is the *cost of having connected*; charging it for a
     swing at empty air double-punished a mistake and made whiffs read as bugs ("why is he standing
     there?"). Dodging still WORKS — the attacker loses the hit — it just no longer froze the attacker
     longer than the dodger. **Why it went back off by default:** Jeff played it and wanted the whiff to
     cost again (2026-07-26) — a swing you committed to should be a swing you are stuck in, which is
     simply the Commitment Rule read literally.
   - **The release is not a Commitment Rule leak** (relevant only with the flag FALSE, and the default now
     avoids the question entirely). The release is the referee's, at the host's own resolve
     point, decided by the world's state (was anything there?) — no input cancels anything, and the
     actor cannot choose to whiff for tempo (whiffing forfeits the damage). Rule-of-thumb check:
     "can a player back out of a decision for free?" No — the decision already resolved.
   - **Exceptions, each deliberate.** A **heal always contacts** (it has a target by construction).
     A **stun-fizzled** action keeps its full window — the stun IS the punishment (§2.11), and
     shortening it would reward being crowd-controlled. **Ranged keeps its full draw + tail** — the
     arrow is an independent effect with its own timeline (§2.9), so the loose always "happened."
   - **Presentation.** With the flag FALSE a whiff event carries a zero gameplay duration but still hands
     the client a present-only swing time, so the weapon rig plays a complete arc — §2.3.4 requires the
     miss to look like a miss, not like a dropped input. With the flag TRUE the two are equal and the
     choreography is the pre-v0.26.0 one.
10. **§2.3.10 — SNEAK ATTACK: compromised, not turned around (v0.27.0; Jeff's second verdict
   2026-07-26).** The rogue's dagger multiplier (×2, `resources/passives/backstab.tres`) now fires when the
   target is **FLANKED BY AN ALLY** — a living, non-hostile body **standing (settled, not mid-step)** on the
   tile directly opposite the attacker, so the target is sandwiched — **OR STUNNED**. It no longer reads the
   defender's facing at all. *(The "settled" word is load-bearing and was made true in v0.27.1: raw
   occupancy answers with reserved tiles and can lead the sprite by a step under pipelining, so the probe
   reads a stricter "standing still on that tile" predicate. A ×2 off a body the player cannot see in place
   would be the same unreadability the behind-arc trigger was retired for.)*
   - **Why the behind-arc went.** It was invisible in play: you cannot read an 8-way facing off a 32px
     sprite, a monster turns to face whoever it attacks, and a never-moved monster faces NOWHERE and so
     could never be backstabbed. The class's signature move fired by accident or not at all.
   - **Why these two triggers.** Both are things a player can SEE and CREATE. Flanking is **co-op shaped**
     (someone has to be on the other side — Jeff's ask), and the stun trigger makes the rogue's own Kick a
     setup: kick, then sneak. Future: any *compromised* state qualifies (rooted, blinded, asleep) — the
     rule is deliberately worded as a state test, not a geometry test, so adding one is adding a boolean.
   - **Names.** The event tag and every player-facing string are **"sneak"** / "sneak attack". The script
     and `.tres` deliberately keep their `backstab.*` FILENAMES (a `.tres` rename breaks loads through
     Godot's uid cache, and this release shipped without harness testing). `is_attack_from_behind` stays in
     the referee as a pure-math helper — the parked "should an idle monster have a default facing?"
     question still references it.

11. **§2.3.11 — Damage TYPES are labels (v0.27.0; Jeff's second verdict).** Every weapon declares a
   `damage_type` — SLASHING (longsword), BLUNT (club), PIERCING (dagger, bow) — stamped onto its attack
   events as a lowercase string. **Zero balance change:** nothing reads it, and armor's physical test stays
   kind-based (`smite`/`admin` excluded) so all three are mitigated identically. It ships as IDENTITY plus
   the data seam for the envisioned per-type resist/vulnerability work (a skeleton shrugging off piercing,
   plate ignoring slashing) — which is a build-system-pass design, not a v1 mechanic.


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
   - combat log carrying the per-OUTCOME feedback from 2.3.4 (wording fixed v0.28.1: "per-roll"
     was pre-v0.26.1 vocabulary — there is no to-hit roll, only the damage band, and §2.3.1 keeps
     miss/crit/block/dodge/resist parked)
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
   pace (`[`/`]` keys, `tactical_beat_sec`, **default 0.25 since v0.27.0** — Jeff's second
   playtest verdict promoted the `/config 2` fight cadence to the shipped game; it was 0.50
   from v0.9.2). Both are any-peer adjustable
   through the intent pipe with the same clamps (shared deliberately pending §2.8.7's
   zone design), both display on-screen, both sync to late joiners. *(The v0.9.3 note that
   nothing stamps from the tactical dial expired with Tactical Zones v1 in v0.9.5: EVERY stamp
   site now resolves through `PaceReferee.beat_or_explore`, which returns this beat for any
   entity the referee has resolved TACTICAL. So the weapon windups authored in v0.27.0 are
   authored against THIS beat — raise it without shortening them and every telegraph doubles.)*

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

**Capability track** (CLAUDE.md doc policy): a living spec for a capability that matures across many
versions. This section is current-truth and edits freely; the append-only changelog stays the
per-release history, and stage status lives in ROADMAP. Ranged attacks as a whole — the bow is
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

### 2.10 Items & Inventory (v1 SHIPPED — v0.18.0; equipment body slot v0.27.0, `/class` discard v0.28.1)

**Capability track.** Pick up, carry, and use (later equip) designer-authored items; the
`.tres`-only content pipeline is the end goal (its gate is milestone **M5**).

v1 model (host-authoritative, event-synced like everything else). Items are `ItemType` resources
in `GameConfig.item_catalog`, name-resolved like weapons/classes. A world item is a replicated
`GroundItem` node that claims NO occupancy — you can stand on its tile, and acquiring it never
costs you a tile reservation. The bag dies with the player (permadeath — fresh/late spawns start
empty, so there is no late-join inventory sync in v1).
Using an item is a COMMITTED action (§2.1): `use_item {slot}` roots you for `use_beats`, and a
heal lands at the DRINK'S END — killed mid-drink consumes the potion and heals nothing ("attack
or drink, not both"). Heals are their own referee pipe (`apply_heal`, clamped to max; god blocks
damage, never healing) — the damage pipe stays damage-only. The health potion (heal 10 / 2-beat
drink) is the v1 item; `/item` + `potion=` spawn for testing.

**Categories (v0.21.0).** Every item answers to one of three categories — POTION, EQUIPMENT,
WEAPON. `ItemType` carries `category` as an @export enum; WEAPON is answered by *living in*
`weapon_catalog` rather than by an authored field, so a weapon can never be mis-tagged.
`GameConfig.category_of(name)` is the single resolution point (item_catalog first, then
weapon_catalog, an unresolvable sentinel otherwise) — the same item-first order the HUD's bag
icons resolve in. The default is deliberately EQUIPMENT, so a designer who *forgets* the field
fails CLOSED: the item sits on the ground waiting to be picked up rather than being silently
hoovered up. *At v0.21.0 the EQUIPMENT bucket was wired but EMPTY — no armour/shield/boot/ring/amulet
resources existed, all nine HUD sockets were cosmetic, and the equip-SLOT model was deliberately left
out of this track's v1; the category existed only so acquisition could tell "wearable" from
"drinkable."* **AMENDED v0.27.0/v0.27.1:** two EQUIPMENT resources now exist (`leather_armor.tres`,
`chainmail.tres`, both in `game_config.tres`'s `item_catalog`), `ItemType.equip_slot` names the socket a
wearable claims, the host routes on it (`InventoryReferee` — BODY takes the real path, every other slot
refuses distinctly), and the HUD paints the **Body** socket's icon. The **other eight sockets are still
cosmetic** and the rest of the slot model is still future work — see "THE BODY SLOT IS REAL" below and
the ROADMAP equipment-slot bullet.

**Acquisition: autopickup is POTION-ONLY (v0.21.0).** Gliding onto a potion still banks it at the
glide's settle — consumables are the case where stopping to think adds nothing. Everything else
(weapons, and later equipment) STAYS on the ground and posts a broadcast `item_pickup_available`
event, which each peer self-filters to the mover's own instance and renders as an invitation to
press **G**. If the bag is already full the invitation is replaced by `item_pickup_full`, so the
player is never told "press G" and then refused one keystroke later. The rationale is the pillar:
picking up gear is a decision, and a decision you make by walking is not a decision.

**Manual pickup (G) is INSTANT, not a committed window (v0.21.0).** `pickup_item` carries an EMPTY
payload — the host reads the sender's tile from the move referee's authoritative occupancy, never
from the wire — and adjudicates with §2.2.8-distinct rejects (dead / stunned / busy / not in
session / nothing here / bag full). It deliberately copies the `equip_item` precedent: because the
BUSY gate refuses a pickup during any committed action, a pickup is atomic *between* actions and
therefore cancels nothing — it is not a Commitment Rule leak, it is a zero-length action that can
only happen when you are already free. It reuses the existing `item_picked_up` event, so every
downstream consumer (HUD, log, mirrors) is unchanged.

**The bag is 20 slots, and its capacity is one authored number (v0.21.0).**
`GameConfig.inventory_slots` (20) is the single designer-editable source: the referee's capacity
check, the client-side mirror cap, and the HUD's row count all read it — replacing a three-way
coupling between a referee constant, a literal, and a HUD column count that could drift apart. The
HUD keeps a 4-row visual FLOOR, so a small authored capacity still draws a full grid with the
surplus sockets decorative and untracked, and a large one grows the grid downward. With abilities
moved out to their own bar (§2.11), the whole grid is real inventory, drawn GREY — the gold accent
now means "abilities and hands" and nothing else.

**Loot (v0.19.x).** Enemies DROP their equipped weapon on death — a `GroundItem` carrying the
`WeaponType` on the death tile (nearest walkable neighbour if occupied) — so the bag now holds
weapons alongside consumables. **Interaction is LEFT-CLICK on the inventory slot** (Jon: nothing
auto-binds to a number-key action bar): a consumable drinks (`use_item`), a weapon equips
(`equip_item`) — routed by the slot's content type. An equip is an INSTANT swap (the Tab-swap
precedent — busy-gated, no committed window): the looted weapon comes off the bag and the
previously-held weapon goes back into the freed slot, nothing lost. A looted weapon resolves its
stats through the equipper's own modifiers (§2.3.7 base+modifier), so the goblin's slow club
becomes a fast weapon in the player's hands. A startup guard warns if any `display_name` is in
both catalogs (a bag name resolves against both — ambiguity would equip/drink the wrong thing).

**THE BODY SLOT IS REAL (v0.27.0 — equipment phase 2, Jeff's second verdict).** The EQUIPMENT bucket is no
longer empty and one of the nine sockets is no longer cosmetic. Two armor items exist (`leather_armor.tres`,
`chainmail.tres`), each carrying its own weight band + physical reduction (§2.3.8), and the **Body** socket
equips them: left-click an EQUIPMENT item in the bag and it swaps into the slot, the previously-worn piece
dropping back into the freed bag slot — the *identical* instant, busy-gated swap the weapon equip uses (so
it cancels nothing; it is a zero-length action that can only happen between actions). The HUD paints the
worn item's icon in that socket. A class declares what it starts in (`PlayerClass.starting_body_armor`;
rogue leather, knight chainmail), seeded at spawn on every peer from shared config and re-equipped by
`/class`; late joiners get a `sync_player_field "body_armor"` snap when a player's worn item differs from
their slot default. Routing is now by CATEGORY through `category_of`, so POTION drinks while EQUIPMENT and
WEAPON equip — the old "any ItemType drinks" shortcut would have tried to drink the leather.

**WHICH SOCKET, AND `/class` AS A LOADOUT (v0.27.1).** Two things the phase-2 pass left implicit are now
explicit. (1) **`ItemType.equip_slot`** names the socket a wearable claims (§2.3.8) — the host routes on it
and **refuses any socket but BODY**, so the off-hand shield §2.11 waits on rejects cleanly instead of quietly
taking the armor slot. (2) **`/class` RECONCILES the body slot** to `starting_body_armor` including *null*
(an armour-less class strips you) — before v0.27.1, an armour-less class silently left you in the previous
class's armor. Its gates match the bag path exactly (dead / stunned / busy), and strip / swap each read as
their own line (§2.3.4).

**`/class` DESTROYS THE PIECE IT REPLACES — a sanctioned debug-path exception (v0.28.1, Jon's ruling
2026-07-26).** v0.27.1 had the old armor **return to your bag**, extending this track's "swap in place,
nothing is lost" invariant to the class swap. Jeff's playtest showed the cost: a few character swaps and the
bag is full of armor nobody asked for. So `/class` now **discards** it, and this is the ONE place in the game
where an item is destroyed. Why that is acceptable rather than a hole in the invariant: `/class` is a **debug
command** — you cannot change class mid-run in real play — so no player decision is ever undone by it; the
**weapon** half of the same swap has always discarded (a bare `set_weapon`, no bag call on any path), so the
two slots are now consistent instead of split; and every path a player actually uses to handle gear (the bag
equip, §2.10's own flow) still swaps in place and loses nothing. It is **not silent** (§2.3.4): the
`equip_item` event carries a present-only **`discarded`** field — deliberately *not* `returned`, which means
"went back into your bag" on the bag path and would mislabel a destruction as recoverable — and the log reads
*"Host equips the chainmail. (The leather armor is discarded.)"* **This deliberately overrules v0.27.1 review
finding #6** ("`/class` silently destroys worn armor") on Jon's authority; a future reviewer should not
re-file it. With no bag traffic left on the path, the v0.27.1 "bag full" refusal is gone too.

**Shipped so far:** item resources + catalog, ground items + walk-over pickup, a 5-slot bag,
use-as-commit + heal pipe, dev spawn (v0.18.0); weapon drop-on-death + loot-to-bag + left-click
use/equip-with-swap (v0.19.x); item CATEGORIES, potion-only autopickup + the "press G" invitation,
manual G pickup as a host-adjudicated instant intent, and the config-driven 20-slot bag (v0.21.0);
**the BODY equipment slot with two real armor items, category-routed clicks, class starting armor and
late-join gear sync (v0.27.0)**.

**Still envisioned:** drop tables + the designer `.tres`-only authoring gate (= milestone **M5**,
which owns that bar — this track points at it, doesn't restate its Done=); the REST of the equipment slot
model (the other eight sockets — head/gloves/boots/rings/amulet and the `[Off]`-hand shield §2.11 waits on
— plus the **weight-promotion rule**, which is a no-op while body is the only armor slot; armor items
themselves and the body slot shipped in v0.27.0, §2.3.8, after v0.26.0's class-level phase 1); more
item categories (buffs, keys, scrolls, throwables); the open v1 questions — item stacking,
drop/discard, numbers/cues (Feel=). Two known rough edges live with it: an item that lands
*underneath* a standing player produces no arrival event and so no "press G" hint (G still works —
a proximity scan was judged unjustified), and the cross-catalog `display_name` collision guard is a
startup WARNING rather than a hard failure, so a name authored into both catalogs can misclassify
(pre-existing — it already mis-routes equip-vs-use).

**Complete when** items are a full designer-authored system: drop tables, multiple categories that
all *do* something (including equipment that equips), the `.tres`-only gate (M5) met. *(Stage
progress is tracked in ROADMAP, not here.)*

### 2.11 Active Abilities & Status Effects (v1 in progress — v0.20.x; ability kinds + cooldowns v0.26.0–v0.27.1)

**Capability track.** Class-owned ACTIVE abilities on the 1-5 hotbar, and STATUS EFFECTS imposed on
entities (stun first). Host-authoritative and event-synced like everything else.

**Abilities are committed actions, never cooldowns (Part 4 Q9).** Pressing 1-5 submits a
`use_ability {index}` intent; the host reads the sender's class `active_abilities[index]` server-side
and, if a hostile is adjacent, ROOTS the caster for the ability's beat window (`windup_beats` +
`recovery_beats`) and resolves the effect. The occupied window IS the anti-spam — there is no second
timer bolted beside it. An `ActiveAbility` is a designer `.tres` (`kind`, `damage`, `stun_beats`, the
beats, `cooldown_beats`, `range_tiles`, `log_verb`, icon), resolved off the class exactly as a
`PassiveAbility` is — add an ability by dropping a `.tres` into a class's `active_abilities`.
**`kind`** (v0.26.0) is the ability's SHAPE — **STRIKE** (the default, and the only shape the paragraph
above describes: a committed window, damage, stun), **BLOCK** and **BLINK** (the two instants of
§2.11.1, which have no window and pay with `cooldown_beats` instead). **`cooldown_beats`** (v0.27.0)
moved the cooldown out of two GameConfig dials onto every ability, instants and strikes alike — see
§2.11.1 for why a strike carrying one is a deliberate, flagged widening of the experiment. A telegraphed ability (`windup_beats
> 0`) resolves against the target TILE at windup end, so it is DODGEABLE (the same commit-to-ground
model as the goblin wind-up and the smite); an instant one (0) strikes now. This is NOT an active
DODGE/BLOCK (§2.1.3 forbids those): the SHIELD is an offensive committed BASH, never a hold-to-block.
*(Both claims in this paragraph — no cooldowns, no defensive input — are SUSPENDED for two specific
abilities inside the `instant_abilities_enabled` experiment; see §2.11.1. They stand for everything else.)*

**Stun INTERRUPTS and locks (Jon's call, v0.20.2).** A stun does two things: (1) it BLOCKS a new committed
action — every intent validator (glide / shoot / use_item / equip_item / use_ability) rejects "stunned" at
ENTRY and the monster brain skips its think; and (2) it INTERRUPTS the in-flight action — a stunned actor's
attack/cast RESOLVE fizzles (the damage/heal/smite is gated on `is_stunned` at the resolve point, so a
goblin stunned mid-windup deals nothing, a shaman stunned mid-cast heals nothing). Movement is not
interrupted (a glide finishes; only the offensive resolve is cancelled). The entity also visibly drops its
attack pose and reels (dizzy wobble) on every peer. **This is the ONE sanctioned exception to "no system may
interrupt a committed action":** the Commitment Rule protects a player from backing out of THEIR OWN
decision for free — a stun is the OPPONENT's committed action (the bash) imposing an interrupt on an enemy,
which is crowd control, not a self-take-back. The stunning player still can't un-bash; the victim is just
disrupted. Duration is in BEATS (scales with tempo); host-authoritative (folded into CombatReferee),
broadcast as `status_applied`/`status_expired` with an overhead icon. A stun imposed ON you is not an escape
valve you spend — it is the enemy's teeth, resolved server-side; that's why it fits the pillar where an
active dodge button would not.

**The 1-5 bar is for abilities; items are left-click.** The number bar (which §2.10 had deliberately
left unbound) is the ability hotbar; consumables and weapons are left-clicked in the bag.

**The bar's home is the bottom edge of the world (v0.21.0).** The five gold-accented ability sockets
— icon + "1".."5" keycap, painted from the local player's class — sit in a dedicated bar centred on
the bottom edge of the world frame, the genre-conventional place to look for your actions, instead
of borrowing the top row of the bag grid. It is click-transparent, so the world underneath is still
clickable, and it lives outside the right column's layout stack so it can never push the HUD's
integer zoom around. The cost is honest and accepted: it OCCLUDES a strip of tiles at the world's
bottom edge (occlusion only — clicks pass through), and at very small window sizes it can overlap
the game-log panel. Vacating the bag grid is what let §2.10's bag grow to 20 real slots; the gold
accent now reads as "abilities and hands," grey as "carried."

**Shipped so far (v0.20.x):** the stun status (icon + dizzy wobble, INTERRUPTS an in-flight attack/cast,
`/stun` dev cmd, all validator gates); the `use_ability` pipe + `ActiveAbility` resource +
`PlayerClass.active_abilities`; knight **Shield Bash** and rogue **Kick** — both verified two-instance,
authored at v0.20.x as 2 dmg / 1 dmg with a 3-beat stun each and **RETUNED in v0.27.0 to bash 4 dmg /
kick 0 dmg, both with a 6-beat stun and a 40-beat cooldown** (§2.11.1 has the reasoning — the kick
became pure setup, long enough to land one sneak attack); the 1-5 HOTBAR HUD shows the class ability icons + keycaps, with
carried items dropped to the row below (v0.20.3); the ability bar moved OUT of the bag grid to its own
click-transparent bar on the world's bottom edge, freeing the whole grid for items (v0.21.0).

**Still envisioned:** an equippable off-hand item (a real shield in the `[Off]` socket, not just the class
ability — it waits on §2.10's EQUIPMENT slot model); clickable ability slots (the keys drive them today);
telegraphed/ranged/self-buff abilities; more status effects (slow, poison, shield); abilities from equipped
gear as well as class.

**Complete when** a non-coder can author a class ability + a status effect via `.tres` alone, the hotbar
reads as the ability bar, and abilities compose with the build system (§2.7). *(Stage in ROADMAP.)*

#### 2.11.1 Instant abilities (PROVISIONAL EXPERIMENT — v0.26.0, verdict pending)

**Status: an experiment behind `instant_abilities_enabled`, not a decision — and it SHIPS ON.** Jeff's
verdict pass asked for two abilities that the spec as written forbids. Jon's call (2026-07-25): build them
behind a toggle, the way stamina was built, and let playtest answer. The toggle **defaults to true**
(`GameConfig.instant_abilities_enabled`, no `game_config.tres` override), which is the point — the
experiment has to be in the shipped build for Jeff to judge it. **So the §2.1.3 and Q9 suspensions below
are LIVE in the shipped game**, exactly as `recovery_locks_actions`, `whiff_pays_recovery` and the winded
dials ship ON. **Off = the pre-experiment game exactly** — both abilities reject, the strike cooldowns are
neither checked nor stamped, and nothing else anywhere behaves differently. Read "off" as the revert path,
never as a description of the default.

**What it suspends, and only inside the toggle:**
- **§2.1.3** ("no active dodge, block, or escape input"). Shield Block *is* a defensive input, and Shadow Step
  interrupts the actor's **own** committed action — the only self-interrupt in the game. Note the shape of the
  suspension: §2.11's stun exception was defensible *because* the interrupt came from an opponent. This one has
  no such cover, which is exactly why it is a toggle and not a rewrite of §2.1.
- **Part 4 Q9** ("unified occupancy — NO separate cooldowns, ever"). An instant has no occupied window to pay
  with, so it pays with a cooldown timer beside the timeline.

**EXTENDED TO STRIKES (v0.27.0, Jeff's second verdict — same experiment, same pending verdict).** Cooldowns
are now a field on the ability resource (`ActiveAbility.cooldown_beats`), and the two STRIKE abilities carry
them: **Kick 40 beats** (damage 1 → **0**, stun 3 → **6** — enough to land one sneak attack: kick recovery
2β + dagger windup 2β + margin) and **Shield Bash 40** (damage 2 → **4**, stun 3 → **6**). Shadow Step is
**40** (Jeff believed it already was; made so) and Shield Block stays 30, both now authored in their `.tres`
instead of in two GameConfig dials that only they could ever use. Tunable live with `/ab` and the panel's
CLASSES section.
- **This goes FURTHER than the original suspension, deliberately and on the record.** An instant has no
  window to pay with; a strike DOES, and it now pays twice — occupied beats *and* a timer. That is squarely
  what Q9 forbids, so it is flagged here as part of the SAME pending Jon+Jeff verdict rather than treated as
  settled.
- **THE TOGGLE GATES THE STRIKE COOLDOWNS TOO (v0.27.1).** `instant_abilities_enabled` off skips both the
  cooldown CHECK and the cooldown STAMP for a strike, so kick and shield bash behave exactly as they did
  pre-v0.27.0 — no refusal, no timer, no `ability_used` cooldown event — *whatever* `cooldown_beats` is
  authored. The whole experiment therefore still switches off with one dial, which is what makes it an
  experiment rather than a rewrite. `cooldown_beats 0` remains the PER-ABILITY revert while the experiment
  is on. *(v0.27.0 shipped the strike cooldown ungated, which quietly broke the one-dial promise this
  section and `docs/dev-commands.md` both make.)*
- **Spent at COMMIT, not at contact.** A strike whose resolve whiffs, or is fizzled by a stun or a blink,
  still burns the cooldown — you spent the ability the moment you committed. (Distinct from §2.3.9's
  recovery-on-contact refund, which shortens a window the referee owns rather than returning a resource.)
  Shield Block remains the one charged on CONSUMPTION: holding a guard is free.
- **Reject shape.** "on cooldown (N.Ns)" through the normal §2.2.8 pipe — bonk + sender-only line — checked
  BEFORE the busy gate (the more informative refusal of the two, and a pure no-op).

**Shield Block (knight, slot 2).** Raises a one-shot guard: the next incoming blow is negated whole. Instant,
no window, usable mid-action. The cooldown is charged **on consumption, not on the raise** — holding a guard is
free, spending it is what costs — so its real cost is that you only get one per fight-ish.

**Shadow Step (rogue, slot 2).** Teleports one tile directly **opposite the user's facing** — a step back out
of trouble without turning your back on it. Computed from the *committed* tile, which under conga is the
in-flight glide's destination, so blinking mid-step returns you to the tile you were leaving.

**Rulings recorded (all Jon's, 2026-07-25 unless noted):**
- **A stun blocks both instants.** Being stunned is the enemy's committed answer to your defensive options; it
  must not be the one state a block or a blink escapes.
- **Potion wasted on a blink mid-drink.** Consume-on-commit already took it; the heal never lands. Mirrors
  killed-mid-drink exactly (same class of outcome, same silence, no refund).
- **A blocked Shadow Step destination burns no cooldown.** The failure mode is "there was nowhere to go" —
  a positioning mistake already paid for by still being where you were. Turn and press again.
- **Facing is unchanged by a blink**, deliberately: you keep looking at what you retreated from (and a silent
  turn would also move a backstab arc).
- **No attack of opportunity and no walk-over pickup on a blink.** §2.2.6 grants a free strike for *starting a
  glide out of a tile*; a blink is not a glide, and getting out clean is the ability's whole promise. The
  pickup seam is a movement settle, so vanishing onto a potion does not loot it.
- **`admin` damage is exempt from the block** — `/mi kill` must still kill a blocking knight, or the tuning
  tools lie.
- **Smite IS blockable** (every kind except `admin` is). **Flagged for Jeff:** a shield stopping a magical
  ground-spell is a real design call, not an oversight.
- **Shield Block is "the kite shield expressed at class level"** until §2.10's equipment slots exist — the same
  phase-1 shortcut class armor took. When a real off-hand item lands, this ability is what it grants.
- **Shadow Step was assigned to the rogue by Jon, not Jeff** (Jeff left it unassigned). **Flagged for Jeff.**

**Interrupt correctness is the load-bearing part.** A forced move mid-action invalidates every resolve already
armed against the old tile, so `MoveReferee.teleport_entity` bumps a per-entity **interrupt generation** that
each deferred resolve captures at commit and re-checks at fire: blink mid-windup lands nothing, blink mid-draw
looses nothing, blink mid-drink heals nothing. Same "identity a stale timer can never match" idiom as the round
and stun generations. The teleport also clears the pipelined pending slot — the §2.2.5 forced-movement caution
made real — and frees both occupancy and reservations, so no tile stays claimed.

**Verdict question for Jon+Jeff:** does the game read better with these? If yes, §2.1.3 and Q9 need rewriting
(not merely excepting) and the cooldown model needs a general home — which v0.27.0 has already half-built by
putting `cooldown_beats` on every `ActiveAbility`. If no, the toggle goes off, the strike cooldowns go back
to 0, and the code comes out. Nothing else should be built on top until that is answered.

### 2.12 Monster AI — Weighted Utility (v1 in progress — v0.22.0)

**The model (Jeff's spec, 2026-07-24):** a monster brain decides by *scoring*, not by walking a hardcoded
if/else tree. At each think moment it enumerates its currently-available actions, computes a desirability
weight for each, multiplies by its personality, and takes the top score. **Weights are desirability, NOT
probabilities** — the AI almost always does the obviously right thing; only when the top two scores land
within a designer-set margin (`utility_tiebreak_margin`) does a coin flip pick between them, so close calls
aren't robotic but nothing is ever random for randomness' sake. Players should be able to learn tendencies
("this shaman usually heals dying allies") without every fight replaying identically.

**Real-time mapping:** there are no "AI turns" — the scorer runs at the brain's existing think moments
(activation, glide boundaries, self-reschedule, on being attacked), and a committed action still plays to
completion (§2.1). The scorer replaces only the *choice*; all commitment/timing machinery is unchanged.

**Architecture:** opt-in per MonsterType (`utility_ai` flag) — monsters that don't opt in keep the legacy
cascade untouched. Scoring lives in a pure static `UtilityScorer` (context in, ranked candidates out); the
brain owns all timing and execution; every weight/bonus/penalty is a designer-editable MonsterType `@export`
live-tunable via `/m`. Personalities are `AiPersonality` resources (whole-score multipliers), rolled once
per spawned instance — two exist: **supportive** (heal ×1.5, smite ×0.85) and **aggressive** (heal ×0.8,
smite ×1.3). The `/ai` dev toggle broadcasts each decision's full score table to the F3 overlay so a
session can watch the weights live.

**Pack rally (all brains, not just utility):** a goblin entering combat — proximity aggro or being hit —
rallies every allied brain inside its own tactical bubble (`resolved_tactical_radius()`); rallied brains
latch aggro but do NOT re-rally (one hop, no map-wide cascade). This is how the shaman joins fights beyond
its own 3-tile aggro: the frontline aggros, the pack wakes, the shaman opens at its spell ranges (smite 8,
heal 5 — per-spell exports, deliberately decoupled from aggro).

**Shipped so far (v0.22.0):** the scorer + opt-in flag; the Goblin Shaman on utility AI with
Heal (quadratic missing-HP curve — scratches score ~nothing, a dying ally dominates), Smite (standstill
bonus, adjacent penalty, pending-smite tile exclusion so two casts never stack one tile), Melee (armed with
a club now — it drops on death like any monster weapon), Flee/Approach movement scored by backup-courage
(backed → kite freely; alone → fleeing decays, stand and fight); the two personalities; pack rally; the
`/ai` score overlay.

**The Warren (v0.23.0) — the showcase encounter, room D.** A Goblin Brute (28 HP anvil) fronts two
skirmishers; a pinned-supportive Shaman Mender posts one tile behind (its `heal_cast_beats` is **15.0** —
a **3.75s** cast at the shipped 0.25s tactical beat; v0.23.0 authored 3 beats against the 0.50s beat of
its day, i.e. the 1.5s cast this section used to quote, and the retunes to 10 (v0.26.0) then 15 (v0.27.0)
made the channel the shaman's real cost — and its smite weight is authored DOWN, healer first); a
pinned-aggressive Shaman Zealot holds the east flank lane.
The room mouth is the tripwire: the Brute's aggro trips there and its authored rally bubble (5) pulls the
whole pack, Zealot included. The intended arc — "focus the big one" fails visibly (heals out-pace the
trade, verified: 5.6s unhealed vs 7.7s healed under identical focus — **measured at the v0.23.0 tempo and
cast length, so read them as the shape of the finding, not as current seconds**), "kill the healer" is the real fight,
and the last shaman turns and fights. Emergent, unauthored: the Zealot heals allies while its smite is
pending-blocked, and the pack heals its own wounded Mender. Design findings the calibration runs bought:
one monster's `tactical_radius_tiles` feeds BOTH the pace bubble and the rally bubble (splitting them is
future work), and the chase model inverts tank order — a slow anvil arrives last, so the Brute runs at
normal speed until a hold-position behavior exists (the authored `speed_lumbering` tier waits for it).

**Still envisioned:** positional movement objectives (move *behind* allied melee, formation kiting,
heal-range approach as its own scored candidate); more personalities; a crowded-top-set tie-break (today
only the top two enter the coin flip); utility AI for the plain goblin chassis once the shaman proves the
model; threat memory (who hurt me, how recently) as a scoring input.

**Complete when** every brained monster runs the scorer, a non-coder can author a new monster's action
weights + personality set via `.tres` alone, and the tendencies read is confirmed at a Jon+Jeff table
(FEEL). *(Stage in ROADMAP.)*

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
IMPLEMENTATION]** need answers before the affected system gets built; the rest can wait. (No item
currently carries that marker — the legend stands for whenever one does.)*

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
   windup 2 + recovery 1 (the 2-beat draw, then the after-loose tail — additive since v0.23.1), damage 4, sky-to-horizontal draw telegraph +
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
   input-cancel. This is what M3.7 (v0.9.0) builds on: `WeaponType.recovery_beats` (né attack_beats) IS the occupied
   window (§2.3.7), dagger 1 beat vs longsword 2 beats — a weapon's whole cost is the beats it
   locks, not a cooldown bolted beside it. *(**Restated for v0.27.0:** `recovery_beats` is only the
   TAIL now — every melee weapon authors a nonzero `windup_beats`, and the referee commits
   `windup + recovery` as ONE busy record (`commit_in_place`, §2.3.7). The answer is untouched — still
   one timeline, one window, no second timer — but the window is a SUM, and the current numbers are
   dagger 2+4 vs longsword 3+4 beats, so the contrast lives in the telegraph rather than the tail.)*
   Still PAIRED with the §2.2.6 AoO re-enable as the next
   feel pass: once the beat-cost contrast reads well, turn AoO back on so stepping away from a
   committed attacker carries its intended risk. *(The other half of that pairing — "re-test the
   telegraphed `windup_beats > 0` heavy weapon in that configuration" — is HALF DONE: v0.27.0 made the
   heavy telegraph the DEFAULT on all three melee weapons and Jeff playtested it through v0.28.0, but
   with AoO still off. So only the AoO half is outstanding, and the telegraph has never been tested in
   the configuration where dodging costs something.)*
   **Two v0.26.0 amendments, both recorded at their own sites:** (a) whether a WHIFF pays its recovery
   tail became a TOGGLE, `whiff_pays_recovery` (§2.3.9). v0.26.0 released the tail at resolve — "charged
   only when the attack CONTACTS" — and **v0.28.0 flipped the default back to paying it in full** (Jeff:
   a swing you committed to is a swing you are stuck in), which is this answer read literally; with the
   flag true `busy_released` never fires. Either way the answer above is unchanged for every landed
   action, and no cooldown was added. (b) The "no separate cooldowns,
   EVER" clause is **suspended inside the `instant_abilities_enabled` experiment** (§2.11.1) — for the
   two instants, which have no window to pay with, and since v0.27.0 for the two STRIKE abilities too,
   which have one and now pay twice (flagged there as going further than the original suspension).
   **That toggle ships ON**, so the suspension is live by default. It stays provisional: if the
   experiment graduates, this answer needs
   REWRITING (a general home for the cooldown model), not another exception bolted on.

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

11. **What did "attack range" mean? ANSWERED (Jeff via Jon, 2026-07-26): reading (a) — DAMAGE
    ranges. Implemented v0.26.1.** Each landed hit rolls in the weapon's authored band, exactly as
    Jeff listed them: longsword 3-5, dagger 2-6, club 1-4 (bow, which he did not band, is authored
    4-4 — no behavior change). The fields are `WeaponType.damage_min` / `damage_max`, designer-
    editable per the §2.5 rule and live-tunable via `/w`. It amends **§2.3.1 rather than overturning
    it** — the deterministic *to-hit* stands (every attack that reaches a body still lands; the
    parked miss/crit/block/dodge/resist list STAYS parked for the build-system pass), and §2.3.6's
    RNG budget is satisfied by making the SPREAD per-weapon identity instead of global noise. See
    the amended §2.3.1 item 1 and the §2.3.6 note; the reading below is preserved as the framing
    that produced the question.
    *The original framing, preserved:* Jeff's v0.25.0
    playtest verdict (2026-07-26) listed an **"attack range" per weapon: longsword 3-5, dagger 2-6,
    club 1-4** — and the phrase has at least three readings, one of which contradicts a settled
    decision, so **nothing was built** in v0.26.0 (Jon's call, 2026-07-25). The readings:
    (a) **DAMAGE ranges** — a random roll between the two numbers. This is the likeliest reading
    (the spreads are damage-shaped: the dagger's 2-6 is swingier than the longsword's 3-5) and it
    **overturns §2.3.1's deterministic combat** — the RF3-derived decision that outcome variety comes
    from position, not dice. If that is what he wants, it is a pillar-level conversation and would
    also need §2.3.6's RNG budget applied (low-magnitude, never erasing a correct decision).
    (b) **REACH in tiles** — how far away the weapon can strike. That would be a real new mechanic
    (multi-tile melee, and the numbers as min-max reach imply a dead zone up close, dagger 2-6 being
    unable to hit an adjacent body, which reads wrong for a dagger).
    (c) Something else entirely — beats, or a per-weapon damage band he wants tunable rather than
    rolled.
    *(That framing predicted correctly where the change would land: it is entirely inside
    `WeaponType`, designer-editable, and ranged reach remains the separate `range_tiles` (§2.9).)*

---

### Changelog

The append-only release history moved to **`docs/design-changelog.md`** (split out 2026-07-23) so this
doc stays the living spec. Add each release's entry there — this file holds current design only.
