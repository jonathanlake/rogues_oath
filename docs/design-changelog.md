# Rogue's Oath — Design Changelog

Append-only release history (v0.2 → present). **Split out of `DESIGN.md` (2026-07-23)** so the design
doc stays the *living* spec and this file is the archive — you rarely need it to get oriented. Newest
first. The version source of truth is `application/config/version` in `project.godot`; each release
adds one entry here (see `docs/overnight-runbook.md` for the release flow).

See also: `DESIGN.md` (living design), `ROADMAP.md` (milestone chain), `README.md` (the doc map).

---


- **v0.20.4 (2026-07-24) — FIX: the exported-build address prefill (Jon report).** v0.20.3's prefill set Jeff's
  NAME correctly (confirming the `has_feature("editor")` export gate works) but left the address on "127.0.0.1" —
  the field carries that as a SCENE DEFAULT, so the "only if empty" guard never fired. Now the exported (GitHub)
  build sets the address UNCONDITIONALLY to Jon's tunnel (`147.185.221.211:22619`); the editor/local build is
  still untouched (Jon hosts locally). One-line fix.
- **v0.20.3 (2026-07-24) — HUD: abilities show in the 1-5 hotbar; items drop a row + GitHub-build menu prefill.**
  Two Jon asks. (1) The TOP inventory row (the accented yellow 1-5 boxes) now shows the local player's class
  `active_abilities` with icons + "1".."5" keycaps (knight → kite-shield icon for Shield Bash, rogue → boots for
  Kick; real 32rogues `items.png` cells). The 1-5 KEYS still fire them (the slots are display-only for now,
  Jon: "put them in the yellow boxes, they should show"). Carried ITEMS moved down to row 1 (still left-click to
  use/equip — the click binds the bag index, so main.gd is unchanged). `hud.gd`: `_refresh_abilities` paints the
  ability row off the class (repaints on spawn + `/class`), `_make_slot_icon` dedups the icon setup. VERIFIED with
  a windowed screenshot: a knight shows the shield in box 1. (2) The EXPORTED (GitHub) build now opens with Jeff's
  name + Jon's tunnel address (`147.185.221.211:22619`) prefilled so he just clicks Join — gated on
  `not OS.has_feature("editor")`, so the editor/local dev build (Jon hosts locally) is untouched. Items-to-a-
  separate-Backpack-panel + an equippable off-hand shield remain envisioned (DESIGN §2.11).
- **v0.20.2 (2026-07-24) — STUN now INTERRUPTS + a dizzy visual (Jon feel-test fix).** Jon's test: the bash showed
  the stun icon + damage, but the goblin's attack still LANDED and it barely paused — because v0.20.0 stun was
  Commitment-SAFE (blocked the next action, let the in-flight one complete). Jon's call: stun should INTERRUPT.
  Now a stunned actor's RESOLVE fizzles — `_resolve_windup` / `_resolve_smite` / `_resolve_heal_cast` /
  `_resolve_ability` each early-return on `is_stunned(attacker_id)`, so a goblin stunned mid-windup deals NOTHING
  (verified: a windup at T produced NO attack resolve after a stun landed 0.4s into its 0.5s telegraph), a shaman
  stunned mid-cast heals/smites nothing. Movement isn't interrupted (a glide finishes — only the offensive resolve
  is cancelled). VISUAL: `Entity.play_stunned` now drops the attack pose (kills the coil/lunge tween + hides the
  weapon rig) and adds a WoW-style dizzy sprite WOBBLE alongside the spinning icon; `hide_stun` straightens it.
  DESIGN §2.11 + CLAUDE.md updated: this is the ONE sanctioned exception to "never interrupt a committed action" —
  the rule guards a player's OWN commitment (no free self-take-back), and an opponent-imposed stun interrupting an
  ENEMY is crowd control, not a take-back (the stunning player still can't un-bash). Verified two-instance.
- **v0.20.1 (2026-07-24) — ACTIVE ABILITIES: the 1-5 hotbar (knight Shield Bash, rogue Kick) — MECHANICS (overnight).**
  The active-ability MECHANIC (HUD visuals are the next slice). The 1-5 keys (the retired `use_slot_1..5` InputMap
  actions) now submit a `use_ability {index}` intent; the host resolves the sender's class ability server-side and,
  if a hostile is ADJACENT (facing neighbour preferred), commits the caster for the ability's beat window and
  strikes for `damage` + a `stun_beats` STUN. NO cooldown — the committed window IS the cost (Q9). New
  designer-editable `ActiveAbility` resource (`damage`/`stun_beats`/`windup_beats`/`recovery_beats`/`range_tiles`/
  `log_verb`) + `PlayerClass.active_abilities`; abilities resolve off the class exactly as passives do (duck-typed).
  Ships two as `.tres`: **knight Shield Bash** (2 dmg, 3-beat stun) on `knight.tres`, **rogue Kick** (1 dmg, 3-beat
  stun) on `rogue.tres` — both instant strikes, 2-beat recovery. Resolved through the shared `apply_damage`
  (kind "ability" + verb, no weapon-rig swing — the lunge is its cue) + `apply_stun`; distinct §2.2.8 rejects
  (dead / stunned / busy / no ability / no target); "X bashes/kicks Y for N" + "Y is stunned!" log lines. Reuses
  the tile-resolve shape so a telegraphed (windup>0) ability is dodgeable. New `ability=<index>` harness knob.
  **Verified two-instance:** host (made a knight, goblin spawned adjacent) fires ability 0 — the CLIENT logs
  `attack{kind:"ability", verb:"bashes", damage:2}` + `status_applied{stun}`, the goblin does NOTHING for the full
  1.5s (3-beat) stun then resumes attacking the instant it expires, and the rogue-kick run mirrored it (verb
  "kicks", 1 dmg). SHIPPED-SO-FAR: mechanics + two class abilities. NEXT: the HUD (hotbar shows ability icons +
  1-5 keycaps, potion/club move to a left-click Backpack panel, the knight's off-hand shield socket).
- **v0.20.0 (2026-07-24) — STATUS EFFECTS: the STUN mechanic (Commitment-safe) + overhead icon + /stun (overnight).**
  First slice of the active-ability push (Jon's overnight brief): the STATUS-EFFECT foundation, starting with STUN.
  Host-authoritative, folded into CombatReferee (every intent validator + the monster brain already holds a
  `_combat` ref, so the gate needs no new injection): `is_stunned` / `apply_stun` / `_expire_stun`, generation-
  tokened so a re-stun isn't cut short. A stunned entity CANNOT start a new committed action — the glide / shoot /
  use_item / equip_item validators early-reject "stunned" (→ the §2.2.8 bonk for a player) and the monster brain
  skips its think — but the gate is at validator ENTRY and NEVER touches the `_gliding`/`commit_in_place` record,
  so an in-flight action still plays to completion (the Commitment Rule, §2.1). Duration in BEATS (scales with
  tempo), broadcast as `status_applied`/`status_expired` events; a spinning yellow overhead STUN icon on every
  peer (the Monster cast-symbol system was lifted to `Entity` so players + monsters share it, and gained a
  generation token that also fixes review #3's early-clear). New `/stun [me|<monster>] [beats]` dev command to
  trigger it, and an `eventlog=<path>` debug knob that dumps the broadcast NetEvents stream to a file (the
  deterministic assertion source for headless two-instance runs; also the joined-observer tool). New empty
  `ActiveAbility` resource + `PlayerClass.active_abilities` land next.
  **Verified two-instance:** a client `/stun`s itself, then `move=`s across and past the window — the event log
  shows ZERO accepted glides during the 1.5s (3-beat) stun, `status_applied`→`status_expired` at the right times,
  and glides landing again immediately after. Monster-stun + mid-action-completion are logic-verified (the same
  entry gate; the gate never touches the busy record).
- **v0.19.12 (2026-07-24) — REVIEW FIXES: dodged-smite sound + smite recovery tell + heal-target hardening.**
  A fresh-eyes code review of the v0.19.4–.11 quick builds (found no crash / desync / Commitment-Rule bypass —
  the spell code faithfully mirrors the proven wind-up pattern). Three fixes landed: (1) §2.3.4 — a DODGED smite
  was silent (only a grey "miss" popup); it now plays a distinct FIZZLE sound (`Monster.play_cast_fizzle`, the
  swing-into-nothing SFX with no melee lunge). (2) FEEL — the smite passed `duration_sec: 0.0` to its resolve, so
  the shaman froze ~2 beats of recovery with NO "spent" tell; `_resolve_smite` now carries `recovery_sec` into
  both the hit and the whiff event, so `play_recovery` shows the spent window. (3) ROBUSTNESS — `pick_heal_target`
  now also skips a null-`monster_type` node (defensive; a real ally always has a type). Deferred/parked (morning
  report): the overlap-token for back-to-back cast symbols (can't trigger at current tuning) is folded into the
  ability-system's Entity overhead-icon lift; a heal-branch pace-report staleness (pace-only, low) and the
  aggro-3-vs-smite-range-12 tuning tension are notes for Jon, no code change. Logic/parse-verified.
- **v0.19.11 (2026-07-24) — SMITE = a DODGEABLE ground-target (red tile telegraph); shaman won't cast pre-aggro.**
  Two fixes from the feel-test. (1) **Smite is now Rogue-Fable telegraphed ground**, not a homing hit: the shaman
  picks a random in-range player's TILE, every peer paints that tile RED for the whole cast, and the hit resolves
  against the TILE at cast END — so you get the full cast (6 beats) to step off it and DODGE (a distinct "smite
  fizzles — dodged!" line + grey "miss" on the vacated tile), and a player who steps ONTO it eats it (commit to
  ground, the same model as the melee wind-up). `CombatReferee.pick_smite_target`→`pick_smite_tile` (returns a
  tile), `smite_cast`/`_resolve_smite` now tile-based (mirroring `_resolve_windup`); the smite_cast event carries
  `target_tile`, and `FxLayer.danger_tile(tile, hold_sec)` draws the pulsing red square. The smite whiff suppresses
  the melee lunge (ranged spell). (2) **The shaman no longer casts before it's aggroed** — its `aggro_range_tiles`
  went 12 → 3 (matching the flanking goblins), so the whole pack holds until you approach; smite/flee run only
  once engaged (acquired within 3), then it kites + smites from up to its 12-tile smite range. Compile-verified
  headless (clean parse). Feel: red-tile lead time vs the 6-beat cast, and `flee_range_tiles`, are `/m` nudges.
- **v0.19.10 (2026-07-24) — SHAMAN = a fleeing CASTER: adds SMITE, stops meleeing; + dummy-heal fix + /m spell tuning.**
  From the live observe pass (a joined event-log capture). THREE changes. (1) **Dummy-heal FIX:** the shaman was
  wasting casts healing the Training Dummy — a brainless monster sitting below its 1000 max HP counted as a
  wounded ally. `CombatReferee.pick_heal_target` now skips brainless props (`has_brain == false`), so it only
  heals real combatants. (2) **All spell params are live-tunable via `/m`** (Jon's ask — "tune all spell casting,
  not just the heal"): `heal_amount`/`heal_range_tiles`/`heal_cast_beats`/`heal_recovery_beats`,
  `smite_damage`/`smite_range_tiles`/`smite_cast_beats`/`smite_recovery_beats`, and `flee_range_tiles` joined the
  `DEV_MONSTER_FIELDS` allowlist (with clamps); `/help` lists them live. (3) **The shaman is now a fleeing
  CASTER, not a club-swinger.** It has NO weapon and never chases into melee (new `MonsterType.flees_players` +
  `flee_range_tiles`): it heals a wounded ally first, else backs AWAY from a too-close player, else casts the new
  **SMITE** — 5 damage, 12-tile range, same 6-beat cast / 2-beat recovery as the heal, on a RANDOM in-range
  player (host-picked RNG, authoritative). New `MonsterType` smite fields + `has_smite_ability()`; a new
  `CombatReferee.pick_smite_target` (random) + `smite_cast`/`_resolve_smite` mirroring the heal path (committed
  cast, killed-mid-cast wastes it — rush it to interrupt). §2.3.4: a DISTINCT orange-red overhead cast sparkle
  (the heal's is green; the overhead symbol generalized to `Monster.play_spell_cast(color)`), a "begins to
  smite X..." channel line, and a "smites X for N" land line (the melee lunge is suppressed — it's a ranged
  spell). Compile-verified headless (clean parse). Feel: `flee_range_tiles` (3) + smite cadence are `/m` nudges.
- **v0.19.9 (2026-07-24) — SHAMAN FEEL: heal cast 6 beats + a 2-beat recovery tail + heal particles.**
  Continued feel-tuning. (1) Cast `heal_cast_beats` 8 → 6. (2) NEW `heal_recovery_beats` (2 on the shaman): after
  the heal lands the healer stays BUSY/spent for a recovery tail before it can act again — `CombatReferee.heal_cast`
  now commits `cast + recovery` as ONE busy record and resolves the heal at cast END (the recovery is the tail),
  the exact shape a telegraphed attack's windup+recovery uses (Part 4 Q9 unified occupancy), so a shaman can't
  chain-heal instantly. New `MonsterType.heal_recovery_beats` field (default 0 = free the instant the heal lands;
  independent of `has_heal_ability`). (3) A GREEN PARTICLE BURST on a landed heal — `FxLayer.heal_burst` spawns a
  one-shot rising-green `CPUParticles2D` (GL-Compatibility-safe, fades via a color ramp, self-frees) over the
  recovering entity, fired per-peer off the existing `heal` event — so it juices EVERY heal (shaman cast + potion
  drink). The overhead cast symbol still holds for the CAST window only (clears when the heal lands, right as the
  particles fire). Compile-verified headless (clean parse). Feel: cast/recovery lengths are `.tres` nudges.
- **v0.19.8 (2026-07-24) — SHAMAN FEEL: longer heal cast + an overhead "casting" symbol.**
  Two tweaks from the first live look. (1) The shaman's heal channel is LONGER — `heal_cast_beats` 4 → 8 (a
  `.tres` value), so there's a real window to react and kill it (or its target) before the heal lands. (2) A
  HELD overhead tell: while channeling, a pulsing GREEN sparkle floats above the healer's head for the whole
  cast window, so "it's casting a spell" is legible on-screen — distinct from the WHITE attack wind-up, and
  held (unlike the transient +N popup it replaces). Drawn as a `Polygon2D` star (font-independent — no glyph
  to miss on the default font), driven per-peer from the `heal_cast` event (which already carries `cast_sec`,
  so the symbol holds exactly the channel window everywhere) and cleared on re-cast / at cast end / with the
  node on a mid-cast death. Compile-verified headless (clean parse). Feel: cast length + symbol read are
  Jon/Jeff's to judge — `heal_cast_beats` is a one-value `.tres` nudge (not yet in the `/m` allowlist).
- **v0.19.7 (2026-07-24) — DEV TOOL: `/config <alias>` — apply a whole test loadout in one command.**
  A repeated tuning setup (several `/w` + `/m` edits to try a feel) is now one keystroke. `/config 1` applies the
  first preset — longsword & club `windup_beats 1` / `attack_beats 3`, goblin `bonus_windup_beats 1` — the exact
  bundle Jon named. Presets live in `GameManager.CONFIG_PRESETS` (beside the `DEV_*` allowlists) as ordered
  `[kind, name, field, value]` rows; the DevCommands validator applies each row through the SAME per-field
  allowlist + clamp path `/w` and `/m` use (`_dev_tune_resource`), so a preset can't poison a resource past its
  clamp and a bad row rejects the whole `/config` naming that row. Host-adjudicated + broadcast like every dev
  command (any peer can invoke it; every peer logs the one summary line). `/help` lists the known aliases and
  `docs/dev-commands.md` documents it — both derive from the one `CONFIG_PRESETS` source, so they can't drift.
  Add a new loadout by adding an alias entry — no code change. Compile-verified headless (clean parse).
- **v0.19.6 (2026-07-24) — TUNING: the south-room (D) pack holds until the party is inside (approachable).**
  The v0.19.4 shaman pack sat at row 20 (the hallway mouth) with the goblins' default aggro range 5, so a party
  coming down the hall woke it from the corridor — two goblins chased UP the hall and one peeled east, splitting
  the fight before the party could even enter (Jon report). Two localized changes so you can file everyone into
  the room and engage all three at once: (1) the pack moved to the SOUTH END of room D (row 24 — shaman (7,24),
  flankers (6,24)/(8,24)), away from the hallway mouth; (2) TIGHT aggro range 3 for the pack only — the shaman
  (`goblin_shaman.tres` aggro 5→3) and a new `goblin_ambush.tres` flanker variant (aggro 3, still displays
  "Goblin") so the B/C/E map goblins keep aggro 5. The shaman's HEAL is independent of its aggro (it heals a
  wounded ally whenever one is in range), so lowering aggro doesn't stop it healing once the fight starts. A
  `.tres`/const tune of the disposable M3.5 fixture, not a systemic change. Compile-verified headless (clean
  parse, pack spawns at 7/6/8,24). Ships for Jon+Jeff's session (supersedes v0.19.5).
- **v0.19.5 (2026-07-24) — MAP: the A↔D hallway (to the south room) widened 1→2 tiles (anti-tunneling).**
  The vertical corridor connecting the starting room (A) to the south room (D) — `WorldGrid.ROOM_LAYOUT` col 7,
  rows 9–18 — was a single-file 1-wide chute, which read as a "tunneling" bottleneck (party + the shaman pack
  forced into single file). Carved col 8 to floor across those rows, so the corridor is now cols 7–8 (2 wide)
  with solid walls still on both sides (col 6 and col 9) and 10+ tiles of wall still separating it from room C.
  Rooms/border unchanged; the A* grid rebuilds from the edited layout at boot. Disposable M3.5 fixture (real
  gen lands at M4a), so this is a hand-tune of the prototype map, not a systemic change. Ships with the v0.19.4
  Goblin Shaman for Jon+Jeff's session (supersedes the v0.19.4 build).
- **v0.19.4 (2026-07-24) — NEW ENEMY: Goblin Shaman (heals its pack) + the first monster SUPPORT ability.**
  A `goblin_shaman.tres` (goblin-mage sprite, `max_hp` 8, armed with the club so it still fights) that, before
  it decides to chase/attack, scans allied monsters and heals the LOWEST-HP one within 14 Chebyshev tiles. The
  heal is a **long telegraphed CAST**, not a cooldown: `heal_cast_beats` (4.0) commits the shaman as a from==to
  busy record (`commit_in_place`) exactly like an attack's occupancy, so it self-limits via the Commitment Rule
  with **no separate cooldown concept** (generalizes Part 4 Q9's unified-occupancy answer — Jon's call this
  session). Authored in BEATS, so it rescales with the live tempo knob like every other duration. Killed or
  interrupted mid-cast **wastes** the heal (`_resolve_heal_cast` re-checks caster liveness → resolves through
  the shared `apply_heal` at cast END, the same heal-at-drink-END rule potions use). New `MonsterType` fields
  `heal_amount` / `heal_range_tiles` / `heal_cast_beats` (all default 0 = not a healer; `has_heal_ability()` is
  the one predicate), so a new healer is a `.tres`, not code. Host-authoritative throughout: `CombatReferee`
  owns the target scan (`pick_heal_target`, off `_hp` + authoritative occupancy) and the cast commit/resolve;
  the brain only asks. §2.3.4 feedback: a DISTINCT `heal_cast` event → green "+" channel tell over the shaman +
  face-the-ally + a "Goblin Shaman channels a heal toward Goblin..." log line (never confusable with the WHITE
  attack wind-up), then the existing `heal` land cue (green +N + "recovers N HP"). PLACEMENT: room D (south of
  the starting room, previously empty) now holds the shaman flanked by two ordinary goblins it can heal —
  spawned unconditionally (like the training dummy), so the demo always appears regardless of the `goblin=N`
  cap. Feel/verification: implemented for a live Jon manual test (his call — no two-instance harness gate or GLM
  pass this pass); the channel visual is a first-pass tell (facing + popup) that can gain richer held art if it
  reads as too subtle.
- **v0.19.3 (2026-07-24) — FIX: player-windup phantom lock after recovery (Jeff report).** With a player
  weapon's `windup_beats > 0` (v0.19.2), control returned ~1 beat LATE — the player couldn't move for an extra
  second after the swing's recovery, only at windup > 0. Root cause: a player bump adjudicates as a DEFERRED
  verdict, so the `attack` event (not a `glide_to`) is what clears the local input latch and drives the
  swing-busy window — but `main._handle_attack_event` only did that for `kind == "bump"/"kick"`. A player
  MELEE WINDUP resolves through `wind_up`, whose event carries `kind == "windup"`, so the client's
  `commit_in_place` never ran; the AWAITING latch fell through to its ~2.0s `verdict_timeout_sec` safety timeout
  instead of the real `windup + recovery` window — the extra lock whenever `windup + recovery < 2.0s`. FIX: the
  local attacker's `commit_in_place` now also fires for `kind == "windup"` (and the defensive `"strike"`),
  gated as before on `attacker_id == our own peer id` (a monster's negative-id windup never matches, so this
  stays player-only). The latch now clears at the strike and roots the player for exactly its recovery, same as
  a bump. (Logic-verified against the client input state machine; not re-smoked because a live v0.19.2 session
  held the test port.)
- **v0.19.2 (2026-07-24) — COMBAT-FEEL TEST HOOKS: player windup, swing mirror, arriving gate (Jeff's 3 asks).**
  Three things Jeff needed to stress-test the beats-and-grid core himself (he tunes the beats via `/w` and `/m`
  live; these are the parts that needed code). LIGHTER verification by request — a boot smoke + GLM plan review,
  not the full two-instance gate (feel-testing is Jon/Jeff's now). (1) **Enemy must be VISUALLY in the square
  before it's attackable.** Under conga a glider claims its destination tile at glide START, so you could bump
  a goblin a fraction of a beat before its sprite arrived. New `_arriving` set (MoveReferee) tracks the
  slide-in window — set when a glide's visible slide begins (direct accept + pipelined promotion), cleared at
  `slide_sec` (VISUAL arrival) by a token-guarded timer, and on death/exit. The bump validator refuses a strike
  against a still-arriving hostile with a distinct `arriving` reject (cue-suppressed like `occupied_hostile`, so
  held input re-lands the instant it settles); the settle period (visually on-tile) stays fair game. (2) **Slash
  mirror.** The shared rig's slash swept `aim − arc/2 → aim + arc/2`, which reads overhead for a rightward aim
  but "upward from the feet" for a leftward one (a goblin on your right swinging at you). A `sweep` sign
  (`unit.x < 0`) now mirrors the arc — and the wound-back windup pose — so a leftward swing is a proper mirrored
  overhead; fixes goblin and player rigs both (8-way discrete aims, so no crossing pop; N/S keep the symmetric
  vertical sweep). (3) **Player weapon windup (opt-in).** Player melee now routes through the SAME telegraphed
  `wind_up` path the goblin uses when its resolved MELEE windup > 0 — commits in place, posts a `windup` event
  (the player rig raises via the shared pose), resolves against the tile after the telegraph (distinct WHIFF if
  the target flees). **Hard invariant: `windup_beats 0` (every weapon's default) stays the byte-identical
  instant bump**; a ranged point-blank stays a kick. Dial it with `/w longsword windup_beats 2`. New
  `equip=`-style `/w windup_beats` is already live; new `MoveReferee` reads `CombatReferee.melee_windup_beats_of`.
  **Boot-verified:** a `windup_beats 2` player longsword telegraphs from a bump (`windup {HOST, windup_sec 1.0}`)
  and resolves to a swing, no errors; instant bump unchanged. Swing-mirror correctness + the arriving feel are
  Jeff's to eyeball.
- **v0.19.1 (2026-07-24) — LOOT: enemies drop their weapon; left-click inventory to use/equip (Jon/Jeff).**
  The payoff on v0.19.0's base+modifier foundation (Jeff: "every enemy should drop the weapon it was using").
  THREE parts. (1) **Drop-on-death.** A dying MONSTER drops its equipped weapon as a `GroundItem` on its death
  tile (nearest walkable neighbour if the tile already holds loot) — CombatReferee gets the drop as an injected
  Callable bound to Main's guarded `_spawn_item_at` (no reach-up), captured BEFORE `clear_entity` erases
  occupancy. The `ItemSpawner` now resolves a ground item's name+icon from EITHER an `ItemType` or a
  `WeaponType` (explicit type branch). A weaponless monster (the dummy) drops nothing. (2) **Loot into the
  bag.** Walk-over pickup already stored the display_name, so a dropped `club` enters the 5-slot bag; the HUD
  now renders a bag slot's icon via item_by_name OR weapon_by_name (so a looted weapon shows). (3) **Left-click
  to use/equip — no number-key action bar** (Jon: nothing auto-binds to a hotbar). Inventory slots are now
  mouse-interactive (STOP filter — a click elsewhere still reaches the world to move/shoot); a left-click emits
  `slot_activated`, and Main routes by content type: a consumable drinks (`use_item`), a weapon equips
  (`equip_item`). The old 1–5 use keys are retired. **Equip is an INSTANT swap** (the Tab swap_weapon precedent
  — busy-gated, no committed window): the looted weapon comes off the bag, the previously-held weapon goes back
  into the freed slot (nothing lost). A looted weapon resolves its stats through the equipper's OWN modifiers
  (v0.19.0), so the goblin's slow club is a fast weapon in your hands. A startup guard warns on any display_name
  present in BOTH catalogs (a bag name resolves against both — ambiguity would equip/drink the wrong thing).
  New `equip=`/`equipwait=` harness knobs (mirror of `use=`) exercise the equip server path. **VERIFIED
  two-instance:** host kills a goblin → `spawned item 'club'` on its tile → walk-over `item_picked_up "club"` →
  `equip_item {equipped: "club", returned: "longsword"}` (the longsword swaps back into the bag), all replicated
  to the client; a windowed screenshot shows the club icon in the inventory + the log "Goblin dies / HOST picks
  up the club." (The raw left-click gesture is windowed-only and unscriptable — `click=` targets world tiles —
  so the HUD click→intent handler is verified by construction; every other link is directly observed.)
- **v0.19.0 (2026-07-23) — WEAPONS: base stats + wielder modifiers, claw→club, the double-hit fix
  (Jon/Jeff).** Foundation for lootable weapons (Jeff: "every enemy should drop the weapon it was
  using"). THREE coupled changes. (1) **Base + wielder-modifier stat model (§2.3.7).** A weapon now
  supplies BASE damage/windup/recovery; the wielder adds a SIGNED modifier on top, floored at 0 —
  `MonsterType.bonus_damage`/`bonus_windup_beats`/`bonus_recovery_beats` and `Player.bonus_damage` (the
  future strength hook). Replaces the old weapon-WINS-over-fallback override. This is HOW enemies are
  slower than players with the SAME weapon: the goblin's club has base windup 0 (instant as a player
  bump) and the goblin adds +1 windup to telegraph + 1 recovery to slow its rate. Beat-bonuses are
  MELEE-ONLY (a ranged weapon's windup is its draw — never retuned by a wielder bonus, so the bow is
  permanently unaffected); `bonus_damage` applies to all; the passive `modify_damage` chain layers on
  top (weapon base → flat wielder bonus → passives). Bonuses read from the SOURCE (MonsterType / Player
  export) so `/m` live-tuning still works (`DEV_MONSTER_FIELDS` now carries the three bonus fields).
  (2) **claw → club.** The goblin's weapon is now a real `club.tres` (damage 2, base windup 0, recovery
  2); the misnamed `claw.tres` is deleted (a truly unarmed enemy gets a natural weapon later, not the
  claw). Resolved goblin = windup 1 / recovery 3 / damage 2. (3) **Double-hit fix.** The telegraphed
  wind-up now commits the FULL window (windup + recovery) as ONE referee-busy record, not the wind-up
  alone — so `notify_attacked` (v0.17.2 "damage wakes the brain") during recovery correctly sees the
  goblin busy instead of buying it a bonus attack. `notify_attacked` also skips its reschedule when the
  monster is already committed (belt: covers future DoT/trap callers). **VERIFIED two-instance:** goblin
  attacks the club with `windup_sec 0.5` (1 beat) + recovery `duration_sec 1.5` (3 beats), damage 2; a
  host wielding the same club bumps INSTANTLY (recovery 2 beats, no windup). Double-hit: with the host
  landing 7 bumps on the goblin, its attack count is **9 — identical to the idle baseline (9)**; the
  pre-fix code produces **22** from the same 7 bumps (Jeff's "double-hitting after you hit him,"
  reproduced and closed). **UX unchanged this version.** NEXT (v0.19.x): enemies drop the weapon on
  death; loot into the inventory; left-click to equip (swap).
- **v0.18.2 (2026-07-23) — GOBLIN WINDUP POSE v2 + the telegraph-never-showed bug (Jon).** Jon's
  feel verdict on v0.18.1: the club didn't show during the wind-up. VERIFICATION CAUGHT THE REAL
  BUG (probe, not the eye): the melee windup POSE resolves its weapon via
  `GameConfig.weapon_by_name(event.weapon)`, but the **claw was never in `weapon_catalog`**
  (`[dagger, longsword, bow]`), so it resolved null and `_handle_windup_event`'s `if weapon != null`
  gate **skipped the pose entirely** — the "raised claw" seen in the v0.18.1 shot was the goblin's
  BASE sprite, not the rig. (The swing still showed because it reads the rig's cached weapon, not
  the catalog.) FIX: add `claw.tres` to `weapon_catalog` (the authoritative event name→weapon
  resolver; `weapon_roster`/player-swap unchanged, so the claw is NOT player-equippable). POSE v2
  (once it actually runs): the club now winds BACK behind the goblin and PUSHES OUT past the body
  silhouette (new `windup_reach_px = 12` — orbit 12px alone buried the 32px sprite inside the body),
  LINGERS, then a quick SHAKE (new `windup_shake_degrees = 12`) builds tension; `play_swing` is gated
  (`_windup_posed`) to LAUNCH from the wound-back angle instead of hard-snapping to the near edge (which
  jumped the club forward). claw ships `windup_raise_degrees = 90` (parks ~behind). Wind-back/linger are
  fractions of the windup window (tempo-adaptive); the launch endpoint stays the same terminus as the
  instant swing (no reach overstatement; damage is deterministic adjacency, not a swept hitbox). The
  instant path (`windup_beats = 0`) is byte-identical — the gate is off there. VERIFIED two-instance:
  probe confirms the pose executes (`back = 30°`, `ext = 24`, `vis = true`); mid-windup screenshots both
  facings show the claw wound back behind, clear of the body; `/w claw windup_beats 0` reverts to
  byte-identical instant strikes (0 windup events after, `kind = strike`, unchanged duration).
  **Feel (Jeff/Jon):** the wound-back read, the claw art (32rogues `items.png` 0,8 reads blobby at the
  extended radius), and the per-facing high/low asymmetry (the rig raise isn't mirrored by facing) are
  the tuning surface — `windup_reach_px`/`windup_shake_degrees`/`windup_raise_degrees` are the knobs.
- **v0.18.1 (2026-07-23) — GOBLIN TELEGRAPH: the windup re-test ships with real art (bug fix +
  raised-claw pose — Jon).** Jon's claw experiment (`windup_beats` 0 → 1.0) exposed a latent bug:
  the telegraphed path stamped the landed `attack` event with `duration_sec = 0.0`, so the rig's
  swing never played — the club was invisible for the whole attack. FIX (one token): the
  resolution bind now stamps `recovery_sec` (attack_beats × pace beat — the same value the
  instant path always stamped), so swing + §2.3.4 spent-dim play on every peer; occupancy is
  UNCHANGED (windup-only commit; recovery stays brain pacing — the baited-swing punish window
  stands). NEW ART: `weapon_rig.play_windup_pose` — during the windup the weapon shows RAISED
  `windup_raise_degrees` (new WeaponType export, default 60°) behind the swing's start edge,
  snap-and-hold (the v0.6.1 coil grammar), over the body's away-coil; melee `windup` events now
  carry the weapon name (present-only field) so every peer paints it. `claw.tres` ships
  `windup_beats = 1.0` — the SANCTIONED RE-TEST of the closed v0.7.0 windup experiment, now with
  the telegraph art it lacked; `/w claw windup_beats <n>` live-tunes it in-session. VERIFIED
  two-instance: windup→attack event pairs with nonzero stamped durations + weapon fields on both
  peers; dodge-whiff carries the same (swing-through animates); live flip to 0 reverts to
  byte-identical instant strikes (0 windup events after); mid-windup screenshots both facings.
  **Feel (Jeff):** does the raised claw read as "prepare to dodge"? Raise angle is the `.tres`
  knob; DESIGN notes the re-test should pair with the AoO re-enable (the config where dodging
  costs).
- **v0.18.0 (2026-07-23, overnight) — INVENTORY v1 (M5-lite, pulled ahead of M4a/M4b —
  Jon).** The parked "N-beat potion commit" ships. DECISIONS (Jon, this session):
  walk-over auto-pickup; potion heals 10 over a 2-beat drink; the heal lands at the
  DRINK'S END — killed mid-drink = potion consumed, no heal (the Commitment Rule bite:
  "attack or drink, not both"); items v1 = pre-placed + dev-spawn (goblin drop tables
  stay in M5); 5 slots (the HUD hotbar), no stacking, bags die with the player
  (permadeath — fresh/late-join spawns start empty, so no late-join sync exists).
  SYSTEMS: ItemType resource + GameConfig.item_catalog/item_by_name (+ duplicate-name
  catalog warnings); replicated GroundItem nodes via a third MultiplayerSpawner (host-
  exclusive spawns, NO occupancy claim — walk-over by construction); host-side
  InventoryReferee (bags, walk-over pickup at the glide-settle seam — monsters don't
  loot, arrival-only detection; `use_item` validator with distinct rejects
  dead/busy/"nothing in that slot"/"can't use that"; consume-on-commit, commit_in_place
  roots the drinker, end-of-drink timer carries the round generation);
  CombatReferee.apply_heal — heals are their OWN pipe (apply_damage stays damage-only),
  clamped to max, the `heal` event carries the ACTUAL applied delta; god blocks damage,
  never healing. FEEDBACK (§2.3.4 all prongs): green drink tint held for the stamped
  window, green "+N" popup, distinct pickup/heal sounds (pitched placeholders), log
  lines ("picks up" / "drinks…" / "recovers N HP (h/m)" / self-only "(your bag is
  full)"). Input: 1-5 keys (use_slot_N actions); harness use=/usewait= + potion= knobs
  + tap tokens 1-5; /item dev command. VERIFIED two-instance event-trace: pickup slots
  0→1 on both peers + hotbar icon screenshot; damage→drink→heal with the clamp proven
  (amount 5 applied of 10, hp_after 20); use-while-moving rejected busy; empty-slot
  reject; killed mid-drink → died, ZERO heal; F5 mid-drink → zero heal into the fresh
  round; kick/shoot/click regressions green. Feel= Jon+Jeff: drink-cue readability,
  pickup/heal sounds, potion numbers (10 HP / 2 beats), hotbar look, full-bag flow
  (code-verified only — spawn caps prevented a 6-potion scripted run).
- **v0.17.3 (2026-07-23, overnight)** — Jon's v0.17.2 playtest fixes, part 1 of the
  overnight run. (1) SHIFT+CLICK ground fire (mouse-aim v2.1): shift+click fires the bow
  at any in-range tile — lane denial returns behind an explicit modifier; plain clicks
  stay hostile-gated (verified: plain click on empty ground → no shot; shift+click →
  windup at exactly the clicked tile). (2) DAMAGE AGGROS (#6 amended): a monster hit
  from ANY range latches aggro — new brain seam `notify_attacked()` called host-side
  from apply_damage for a surviving Monster target; chase still targets the nearest
  player. Verified with exact geometry (new `goblinat=` harness knob): goblin at
  Chebyshev 6 (inside bow-7, outside aggro-5) stayed idle a full negative-control run,
  then chased immediately after one arrow in the positive run. (3) MELEE ART REVERT
  (Jon's veto): `art_points_deg` default −45→−90 restores the pre-v0.17.2 melee look
  exactly; bow/arrow keep their verified orientations. Harness: `shiftclick=` +
  `goblinat=` knobs added (keepers). Kick regression green.
- **v0.17.2 (2026-07-23)** — BOW FEEL FIXES (Jon's playtest of v0.17.1): three reports, all
  fixed. (1) MOUSE-AIM v2: a click SHOOTS only when the clicked tile holds a hostile —
  empty-tile clicks now MOVE again (with a bow equipped, every click used to fire); the
  v0.17.0 wall-click lane-fire is REMOVED (#6 amended). Client-side routing convenience
  (injected predicate over replicated monster nodes; unwired fallback warns + keeps old
  behavior); the server still adjudicates every shot. Verified two-instance: click on the
  dummy → shoot (windup "bow" + launch), click adjacent-empty → glide, click far-empty →
  nothing. (2) ZIG-ZAG arrows: the flight visual now flies ONE straight line to the
  terminal tile over the same total time (per-tile Bresenham tweens staircased at shallow
  angles); the Bresenham path stays authoritative for adjudication; impact snaps to the
  closest point ON the flight line (no lateral pop). (3) ROTATIONS: root cause — the
  32rogues item sheet is NOT uniformly oriented (melee tips NE −45°, arrow NW −135°, bow
  fires SW +135°) while the code assumed one up-pointing baseline; the global constants are
  replaced by designer-editable per-weapon fields (WeaponType.art_points_deg /
  projectile_art_points_deg, melee-convention defaults so only bow.tres overrides).
  Verified by magnified screenshot: the flying arrow now points ALONG its flight line; the
  draw pose reads as a real drawn bow (arc toward target, string toward archer, arrow
  level). Melee (dagger/longsword) alignment is corrected by the same math (was 45°
  off-radial since M3.7, unnoticed in motion) — mid-swing screenshot capture was
  inconclusive (sprite camouflage), Jon eyeballs in motion and can veto via the .tres
  fields, no code.
- **v0.17.1 (2026-07-23)** — THE BOW, fix pass: v0.17.0 code-review findings (10 confirmed +
  2 below-cap) plus one DESIGN decision. NEW MECHANIC — the point-blank KICK (option A, Jon):
  a RANGED weapon (`range_tiles > 0`) has no melee swing, so keyboard-bumping an adjacent
  hostile is now a weaponless KICK — a flat `GameConfig.kick_damage` (default 1), its own
  "kicks" log verb, NO weapon graphic — instead of the bow doing a 4-damage slash arc. Bow-
  only (a dagger/longsword bump still swings for its own damage); knockback (option D — kick
  the enemy back a tile to re-open range) is deferred to a future feature (see #6). Verified
  two-instance: bow-bump → `kind:"kick"`, damage 1, no weapon field; dagger-bump regression →
  `kind:"bump"`, damage 2, `weapon:"dagger"`. FIXES: shoot accept path now sets the shooter's
  authoritative facing + fires the `before_attack` seam (parity with wind_up); F5-mid-draw
  ghost arrows eliminated (round-generation guard — verified: mid-draw F5 → 0 `projectile_
  launched`, baseline shoot still looses); catalog⊉rosters caught at startup (host-side
  `validate_catalog_covers_rosters`) + a loud runtime warning on the swap-null branch;
  `/class` equip guards a null roster[0] slot and surfaces a player-visible "weapon not
  equipped — busy" line on a busy-skip; distinct "draws the bow…" log (was "winds up…"); a
  default held-flash telegraph for any non-draw player windup; late-joiner rig paints the
  event-resolved weapon (draw + loose); equal-deadline loose/commit tie ordered loose-first;
  disconnected-shooter pace re-arm gated on `is_alive`; the 8 shoot methods moved under the
  Private-methods header (script-order). Feel= Jon+Jeff: kick reuses the bow's recovery window
  (1.5s vs a melee 0.5s) — a dedicated `kick_duration` may be wanted; the 1-damage number.
- **v0.17.0 (2026-07-22)** — THE BOW: first ranged weapon, traveling-arrow model (open
  question #6 ANSWERED for ranged v1 — see that entry for the full spec). New: WorldGrid
  Bresenham `line_tiles` (doc-flagged NOT LoS-correct until the corner rule); WeaponType
  ranged fields (`range_tiles`, `projectile_tiles_per_beat`, `projectile_atlas_coords`,
  "draw" style); bow.tres (3 beats, 2-beat draw, damage 4, range 7); PlayerClass
  weapon_roster + ranger [longsword, bow] (global Tab-cycle untouched for other classes;
  new weapon_catalog is the name-lookup source); `shoot` intent with distinct §2.2.8
  rejects; server-side flight (per-tile arrival timers reading Q4 occupancy, ONE HIT RULE,
  `projectile_hits_allies` toggle default true); `projectile_launched/ended` events;
  per-peer Projectile node (id-keyed, snap-then-free, late-join tolerant); WeaponRig draw
  style (skyward→aim rotation + nocked arrow + pitched draw/loose sounds); mouse-click
  shoot input; /class equips roster[0] (busy-guarded). EMERGENT KEEPER: a mid-draw move
  request PIPELINES (Q7's slot) and starts only after the commit window — archers pre-
  buffer their escape step; commitment intact (event-trace verified: loose 3.0s → glide
  3.5s → arrow lands 3.625s). Verified two-instance headless: hostile hit (hp 20→16, kind
  "arrow"), ally hit (FF on), ally pass-through + "sails past <name>" (FF off), wall clip
  → blocked, spent, out-of-range/busy rejects, re-loose with two arrows in flight, tempo
  scaling (tactical 0.8 → windup 1.6/tile 0.2), windowed screenshots (draw pose, release,
  ranger loadout end-to-end). GLM chunk + milestone reviews: 6 accepted fixes (catalog
  fallback, /class busy guard, loose-state init, windup≤window clamp, id-sign allegiance
  for posthumous arrows, hide_draw resets). Feel= Jon+Jeff: bow numbers (3 beats/damage 4/
  range 7/arrow speed 4 tiles-per-beat), draw telegraph readability, FF-on default,
  mouse-aim feel, shoot-vs-move input coexistence.
- **v0.16.2 (2026-07-22)** — F11 cache fix (Jon's report: the 4th press dropped a maximized
  player to the small window). ENGINE FINDING (sequence-probed): with resizable=false,
  Windows will not hold a true maximize — `window_get_mode()` DECAYS to WINDOWED one frame
  after a maximize while the window still fills the work area (2560×1351 observed). Caching
  that lying enum meant press 3 recorded "windowed" and press 4 faithfully restored the
  wrong thing. Fix: cache the window's SHAPE, not the mode enum — at fullscreen entry
  record whether the window was screen-wide (width ≥98% of screen; size readback is
  reliable where the enum is not), and restore by intent: big → MAXIMIZED (renders as the
  work-area window), small → WINDOWED + the override rect. Verified: six-press cycle from
  pseudo-maximized is perfectly periodic (big→fullscreen→big ×3, no decay); four-press
  small-window cycle returns to exactly 1280×720. Also documented the auto-hidden-taskbar
  edge on the v0.16.1 self-heal (pseudo-maximized = full screen there; such setups should
  use F11 fullscreen).
- **v0.16.1 (2026-07-22)** — Stuck-window fix (Jon's report, same day): a fullscreen trip
  could clobber the OS's remembered restore rect, so un-maximizing after F11 sometimes
  handed the player a screen-sized WINDOWED window that resizable=false made inescapable.
  Two-part fix in main.gd: the F11 exit-to-windowed path now explicitly restores the
  project's windowed-override rect (Windows does not reliably restore SIZE with mode), and
  a self-heal guard watches size_changed for the one illegitimate state — WINDOWED at
  ≥98% of screen size (98% not 100%: Windows clamps decorated windows to the work area,
  measured 2560×1427 on a 2560×1440 screen) — and snaps it to the override rect, centred.
  Path-independent: fixes the maximize→F11→restore route and any other transition fallout.
  Verified: simulated stuck window (screen-sized windowed launch) self-heals to 1280×720;
  the 2560×1392 harness window (96.7%) untouched — no false positive; F11 round-trip from
  windowed still restores exactly; compile clean.
- **v0.16.0 (2026-07-22)** — Two-zoom model: independent HUD zoom (#10 UI ZOOM DECOUPLED,
  Jeff's idea from the Discord session) + F11 borderless fullscreen. The world keeps its
  v0.15.0 fairness scale s untouched; the HUD now picks its OWN integer zoom h each layout
  pass — the largest whole step whose column stack (MEASURED live: section minimums +
  theme separations + margins, no literals; re-measured on refresh_self so passives count)
  fits the window height — applied as the HUD CanvasLayer's scale = h/s (net = h, crisp).
  Maximized 16:9 → h = s, byte-identical to v0.15.0 (probe-verified). 1280×720 windowed →
  world 2× / HUD 1×: the whole inventory fits again (the v0.15.0 windowed clip, root cause
  measured at stack 409 vs 360 available, is closed) at v0.13's panel size. 1366×768-class
  laptops (which clipped even maximized) inherit the same fix. UNIT BOUNDARY: the world
  frame is computed and emitted in canvas px (column footprint = 180·h/s there), Controls
  placed in HUD-local px — camera offset, F3 label, and hurt vignette consumers unchanged
  (screenshot-verified at 720p: F3 label at frame edge x=1100, avatar at frame centre).
  Root is now explicitly sized (canvas·s/h) with a viewport size_changed hook (its own
  `resized` no longer fires once off full-rect anchors). F11 toggles borderless fullscreen
  (mode cached/restored, borderless flag reset on exit per the 4.7 force-set; harness
  token tap=f11) — Jeff's evaluation ask; verified live 2560×1392 windowed → 2560×1440
  fullscreen mid-run with correct 3× re-layout. Two-instance wire gate passed (chat +
  adjudicated glides + reject). Feel= Jon+Jeff: chat/tempo banner keep the WORLD zoom
  beside a 1× panel in small windows (720p-only mismatch — co-scale them with the HUD if
  it grates); borderless fullscreen verdict; windowed world-2×/panel-1× overall feel.
- **v0.15.0 (2026-07-22)** — Full-bleed restored, bounded-variance scale (#10 REVISED —
  supersedes v0.14.0's margin frame ONE DAY later; Jeff, see the release notes). Jon
  rejected the always-on frame: the world again bleeds to the left/top/bottom edges with
  the full-height column on the right (the v0.13.0 look). Fairness relaxed from exact to
  bounded: scale = integer nearest the canonical 960-px canvas (1080p 2× → 780×515, 1440p
  3× → 673×464 pixel-identical to v0.13/v0.14 flagship, 4K 4× → 780×527, spread ~16%/13%);
  a hard bound bumps small windows UP a scale so windowed (1280×720 → 2×, 460×360) never
  sees more than maximized; height floor ≥15 tiles for degenerate shapes; BLEED_CAP 52×36
  tiles per axis as the no-shape-reveals-unbounded-tiles backstop (bands appear ONLY on a
  capped axis — portrait monitors). Camera recenter and world_frame_changed contract
  unchanged from v0.14.0. Verified: probe geometry at eight window shapes incl. ultrawide-
  short (2560×720 → 673×240 full bleed, no bands) and portrait (800×1200 → 620×576
  centered, top/bottom bands), two-instance host+client wire run (chat + glides + reject),
  full-bleed screenshots at 1080p-class (world touches three edges, avatar at frame centre
  780,515→781,517 observed). Feel= Jon+Jeff: the 460×360 2× view in a restored 720p window
  (zoomier than before), recentered camera (carried from v0.14.0, still pending verdict).
- **v0.14.0 (2026-07-22)** — Fixed world rect (open question #10, ANSWERED same day —
  Jeff approved as proposed, camera recenter included). Every player now sees exactly
  42×29 tiles (672×464 base px) of world at every window size and resolution: the scale
  policy picks the largest integer scale fitting the 852×464 world+column block (1440p-max
  3×, 1080p-class 2×, 720p-class 1×), centres it, and covers all leftover canvas with four
  backdrop-colored margin bands (one shared `_BACKDROP` const with the column — no seam).
  Sub-852×464 windows hide the column and clamp the world PER AXIS to a strict subset of
  the rect — the old full-bleed fallback could leak extra vertical tiles in a narrow-tall
  window. Camera: `Camera2D.offset` (set from `world_frame_changed`, zoom-divided for
  future-proofing) centres the avatar in the world rect — the v0.13.0 "avatar ~90px right
  of visible centre" feel item is closed. ENGINE FINDING: the canvas the fractional
  stretch yields can land a float hair UNDER the integer target (2560×1392 → canvas.y
  463.9999…), so the fit test needs a half-base-px tolerance — a strict >= hid the column
  at exactly the flagship 1440p geometry (caught by the harness, first run). Verified:
  probe-file geometry assertions at 700×400 / 1280×720 / 1920×1080 / 2560×1392 (all →
  672×464 or a per-axis subset; predicted origins exact), two-instance host+client run
  (chat + glides adjudicated, reject path intact), screenshots at 1×/3× confirming margin
  frame, column, and avatar at frame centre (550,360 / 1008,696 as computed). Feel= Jon+
  Jeff: the 1×-window frame proportion (852×464 in a 720p window), recentered camera.
- **v0.13.0 (2026-07-22)** — HUD iteration 2 (Jon's verdict on v0.12.0): RIGHT COLUMN
  ONLY — the world now bleeds to the window's left/top/bottom edges (full-window render,
  camera untouched; the column overlays the right edge, player ≥7 tiles from it at every
  scale). Party frames OFF for now (party_frame.gd/.tres dormant on disk; their HP
  plumbing now drives the char-panel bar); chat floats bottom-left over the world again
  (dock_into dormant); tempo floats top-center as before. Char section: class, Lvl 1
  placeholder (no leveling system yet), OWN live HP bar (green→red, DEAD state), passives
  — portrait removed, section takes the column's expandable room. Equipment: 9 sockets at
  32px — accented [Primary][Offhand] hands pair separated from the labeled armor grid
  (Head/Body/Gloves/Boots/Ring/Ring/Amulet); the primary-hand socket shows the REAL
  equipped-weapon icon (items.png region via WeaponType.atlas_coords) and flips on Tab.
  Inventory: 5×4 at 32px (doubled), gold hotbar row kept, pinned at the column bottom.
  Sections separated by padding, no boxes. Scale policy v2 keeps ≥640px of world beside
  the column (1280×720-class windows step to 1×). Verified: layout/tactical-border/F7
  screenshots, click regression, Tab icon flip probe, two-instance own-HP bar
  (20→0→DEAD on the victim only), step-down at 720p. Feel= Jon+Jeff: padding-as-
  sectioning, socket label legibility, off-visible-center player (camera offset is a
  small follow-up if it bothers), char-section spacing.
- **v0.12.0 (2026-07-21)** — Docked HUD in the reclaimed letterbox (Jon+Jeff layout, from
  the Gemini mockup direction). The window's dead black margins become UI: LEFT column =
  party frames (portrait, name, live HP bar green→red, gold border on your own, greyed
  DEAD persists; event-fed client mirror, no wire changes) over the docked chat/combat
  log; RIGHT column = reserved minimap slot (M4b), character info (class + passives —
  `PassiveAbility.display_name` added, designer-editable), equipment (live main-hand),
  and a 5×5 inventory grid whose gold top row reserves the future 1-5 hotbar (style only;
  mapping TBD). No headers. The world stays PIXEL-IDENTICAL: exactly 640×360 base at a
  whole-integer scale, visible through the WorldFrame hole between four opaque bands; the
  tactical border now frames the PLAY AREA (WorldFrame child), and the hurt vignette is
  scoped to it too. ENGINE FINDING (empirical, 4.7.1): `scale_mode="integer"` is inert
  under `aspect="expand"` (fractional best-fit + content_scale_factor writes silently
  discarded) — shipped as `fractional` with the HUD's scale policy as the integer snapper
  (`content_scale_factor = target/auto_fit`; guard on the applied factor; one-shot
  next-frame relayout — the settle-loop crash is documented in hud.gd). Scale policy:
  steps the factor down one when margins can't fit the columns (1080p-class windows play
  at 2× WITH HUD — Feel/decision item for Jeff); tiny dev windows fall back to full-bleed
  (no HUD columns, log hidden — dev-only). Full review pass (8-angle + GLM): 10 verified
  findings fixed pre-land (portrait atlas fallback blowout, late-join portrait sync,
  scale-factor restore on session end, component-clean log docking via
  `GameLog.dock_into`, silent click-pathing arming default, invisible-focus chat wedge,
  shared `WorldGrid.atlas_region` helper, ProjectSettings-sourced base size). Parked with
  eyes open: late-join party sync (dead-teammate frames + real HP seed — needs a join-sync
  wire field), the main.gd→HUD relay → direct NetEvents subscription cleanup, click-gate
  on WorldFrame when click pathing re-enables. Feel= Jon+Jeff: panel styling/proportions,
  hotbar-row treatment, in-world nameplates now redundant?, menu renders fractional
  pre-session (cosmetic), 1080p 2×-with-HUD tradeoff.
- **v0.11.0 (2026-07-21)** — Combat events + Backstab (Jeff's class-identity spec, overnight
  batch chunk 4). Three layers: (1) SERVER-SIDE 8-WAY FACING — MoveReferee now tracks an
  authoritative facing per entity, written ONLY on accepted verdicts (accepted glide,
  executed bump, monster wind-up entry; rejects never mutate — no face-fishing; spawn = ZERO
  by design: a never-moved entity has no back to stab). Presentation sprite-flip unchanged;
  nothing new crosses the wire. (2) PASSIVE FRAMEWORK — `PassiveAbility` Resource with three
  combat-event hooks: `before_attack` (read-only observation), `modify_damage` (the
  BeforeDamageApplied seam: sequential chain in class-array order, host-only, may append
  feedback `tags` that ride the attack event when non-empty), `after_attack` (post-broadcast,
  `died` flag). PlayerClass gains a `passives` array; dispatch is duck-typed and null-safe
  (monsters can join later via MonsterType). The combat system exposes information — tiles,
  facings, weapon, attack_dir — and passives decide what to do with it; a reusable
  `is_attack_from_behind()` helper (rear-3-octant arc, strict dot > 0) is the first shared
  positional predicate. (3) BACKSTAB — the Rogue's first passive (`backstab.tres`): dagger
  equipped (resource_path match) + attack from the defender's rear arc → damage ×
  `damage_multiplier` (2.0), tagged "backstab" with a distinct log line ("X backstabs Y for
  N!"), a white "-N!" popup, and a pitched-up hit sound (§2.3.4). Verified two-instance:
  rear dagger = 4 + tag on players AND a moved/attacking goblin; frontal dagger = 2 untagged;
  rear LONGSWORD = 5 untagged (weapon gate); never-moved dummy untagged (spawn-ZERO rule).
  Design question parked for Jeff: should idle/never-moved monsters be backstabbable
  (sneak-attack flavor) via a spawn-facing default?
- **v0.10.4 (2026-07-21)** — Goblins route around blockers + ghost-cam (overnight batch
  chunk 3). Monster pathing now feeds sibling-occupied tiles into A* as temp-solids
  (`MoveReferee.monster_tiles` → `find_path(avoid)`), with a walls-only fallback so a truly
  sealed corridor still queues instead of dithering — the M3 "monster blocked by monster"
  limitation is retired (verified: a goblin blocked behind its sibling in the 1-wide
  corridor took the alternate loop through rooms E and D and attacked from the far side).
  The referee stays the final arbiter (same-tile races: loser waits one boundary).
  Ghost-cam: when YOUR avatar dies, your camera follows the nearest living teammate
  (sticky; re-picks only when that node frees; own respawn always wins back; pre-first-
  spawn intro hold unchanged) with a local "Following <name>." log line. Pure client-side
  presentation — no wire changes.
- **v0.10.3 (2026-07-21)** — Tactical clarity (overnight batch chunk 2). §2.8.7 amendments:
  (1) a monster's tactical bubble now DEFAULTS to its aggro range — `tactical_radius_tiles`
  ships as a -1 "match aggro" sentinel resolved in one shared place
  (`MonsterType.resolved_tactical_radius()`), so the goblin's in-the-fight zone = its
  noticed-you zone (5) unless a designer splits them; (2) NEW player tactical bubble
  (`player_tactical_radius_tiles`, default 3 — deliberately tighter than the enemy 5): a
  player near a teammate who's genuinely in a fight gets pulled to tactical pace too. No
  chaining by construction — only MONSTER-sourced players project the pull (two-pass
  resolve reads qualification, never broadcast pace), so allies can't hold each other
  tactical after combat ends (verified: adjacent players exit orderly). F7 overlay adds a
  live green ring around tactical players (broadcast-driven via a per-peer pace mirror,
  pruned on death/reset); a subtle red screen border fades in while YOUR pace is tactical.
  Feel= for Jon+Jeff: border alpha (0.18), green tint, player radius 3.
- **v0.10.2 (2026-07-21)** — Feedback polish (Jon+Jeff v0.10.0 playtest, overnight batch
  chunk 1). Bumping a hostile you can't attack yet (pipelined/mid-glide step into an enemy)
  now rejects with a distinct `occupied_hostile` reason and the client suppresses the bonk
  cue — the thud/flash misread as "input didn't register" when the very next from-idle step
  IS the attack; non-hostile blockers (players) keep the full bonk, and the reject still
  feeds the sampler's walk-stop counting. Damage popups are direction-coded: player→enemy
  hits render white (`PLAYER_HIT_COLOR`; crit-yellow reserved for a future crit system),
  enemy→player stays red. §2.2.8 amendment: the commit-sent WHITE FLASH is retired entirely
  (Jon's call — the glide starting is the ack; the rejection bonk remains §2.2.8's reject
  seam), removing the "players blink when they move" artifact.
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
