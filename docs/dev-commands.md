# Dev slash commands, the debug panel + the harness knobs (current to v0.41.0)

Live tuning + dev toggles typed into the in-game chat box. A leading `/` marks a dev command: the
game log intercepts it (never sends it as chat), parses it client-side into `{cmd, args}`, and submits
a `dev_command` intent the **host** validates and adjudicates (server-authoritative — the host reads
and mutates the shared config `.tres`, never a client value). Tokens are lowercased, so commands,
weapon/monster/class names, and field names are case-insensitive.

Dev-era, open to **any peer** (host or client), like the F5/F6/tempo keys. Nothing persists: a process
restart restores every authored value (no command saves to disk).

## Commands

| Command | Effect |
|---|---|
| `/w <weapon> [field] <value\|reset>` | Tune a weapon. Field ∈ `damage_min` (0–999, int), `damage_max` (0–999, int) — **the v0.26.1 damage BAND: each landed hit rolls uniformly in `[min, max]`** — plus `recovery_beats` (0.05–30; the post-strike/post-loose tail — renamed from `attack_beats` v0.23.1) and `windup_beats` (0–30; the telegraph/draw before it — total commit = windup + recovery, melee and ranged alike). Omitting the field triggers the band shorthand below. Out-of-range values are rejected (never clamped). `reset` restores all four from disk. Setting `damage_min` above `damage_max` is legal and safe — the referee rolls the ORDERED range, so a half-finished retune can't crash a fight (an inverted band authored in a `.tres`, by contrast, warns once at startup). |
| `/<weapon> <value>` | **Sets `damage_min` AND `damage_max`** to that value — i.e. collapses the band to fixed damage (e.g. `/longsword 5`, or the equivalent `/w longsword 5`). This is also the determinism pin for scripted runs: there is no RNG seed, so `min == max` is how a harness run gets a predictable damage number. The command table wins over this alias, so a weapon named like a command is only reachable via `/w`. |
| `/m <monster> <field> <value\|reset>` | Tune a MonsterType. Fields: `max_hp`, `aggro_range_tiles` (**wall-bounded ACQUISITION as of v0.31.0**: the number is now a TRAVEL distance through open floor, measured with the same flood-fill the v0.30.0 rally shout uses — a player two tiles away but on the far side of a wall no longer trips it. Identical to the old Chebyshev reading in an open room. Only the acquire edge is bounded: an already-aggroed monster keeps chasing across rooms under `aggro_persists`, being SHOT still aggros regardless of walls or range, and flee/banter ranges are unchanged), `tactical_radius_tiles`, `bonus_windup_beats`, `bonus_recovery_beats`, `bonus_damage`, plus spell params (v0.19.10) `heal_amount`/`heal_range_tiles`/`heal_cast_beats`/`heal_recovery_beats`, `smite_damage`/`smite_range_tiles`/`smite_cast_beats`/`smite_recovery_beats`, and `flee_range_tiles`. Out-of-range rejected; `reset` restores all. `/help` prints the live list (derived from the allowlist, never stale). |
| `/ab <ability> <field> <value\|reset>` | **Tune an ACTIVE ABILITY** (v0.27.0). Resolve by the display_name SLUG — lowercase, spaces→underscores: `kick`, `shield_bash`, `shield_block`, `shadow_step` (a raw "shield bash" would split into two args and resolve to nothing). Fields: `damage` (0–999, int), `stun_beats` (0–60), `windup_beats` (0–30), `recovery_beats` (0–30), `cooldown_beats` (0–600), **`root_beats` (0–120, v0.34.0 — how long a TARGETED cast's ROOTED condition holds)**, and the three **DoT fields (v0.40.0)**: `dot_damage` (0–99, int), `dot_ticks` (0–20, int) and `dot_interval_beats` (0.5–60). Subjects today: `entangling_roots` (root) and `insect_plague` (DoT). The interval's floor is **0.5, not 0**, on purpose — a zero interval would fire the whole run in a single frame, which is a different spell than the one authored (the resource validator refuses that shape outright; the dial cannot reach it either). Note the first tick lands the instant the cast resolves, so a run spans `(ticks − 1) × interval`, not `ticks × interval`. Same reject-not-clamp pipeline as `/w`/`/m`; `reset` restores every field from disk. The `.tres` is SHARED by every class holding that ability, so a retune reaches every wielder at once and is read live at the next use (a cooldown already running keeps the seconds it was stamped with). Resolution needs the ability in `GameConfig.ability_catalog`. |
| `/god` | Toggle **your own** invulnerability. A hit on a godded target resolves as a visible no-op (grey `0` popup + "no effect (god)" log line), never a silent block. Cleared on disconnect / despawn / F5 respawn. |
| `/class <name>` | Set **your own** class (sprite, **traits**, abilities, loadout, **mana pool**). Equips the class's first roster weapon, and **RECONCILES the body slot to the class loadout** (v0.27.0, rewritten v0.27.1): you end up in exactly what that class wears — **including nothing, which strips you**. **The piece you were wearing is DISCARDED** (v0.28.1, Jon's ruling — it went to your bag in v0.27.1, which filled the bag on every character swap): **nothing reaches your bag**, so `/class` is the one path in the game that destroys an item, sanctioned because it is a debug-only command and the weapon half has always worked that way. Not silent — the log names it: *"Host equips the chainmail. (The leather armor is discarded.)"* (The v0.27.1 "bag full" refusal is gone with the bag traffic.) The armor step is skipped with its own distinct clause when you are **dead / stunned / busy** (matching the bag-equip gates); the weapon step still skips on busy only (Tab to recover it), and the class change itself always lands. `name` ∈ `rogue`, `knight`, `wizard`, `barbarian`, `priest`, `ranger`, **`druid`** (v0.34.0 — leather armor, club, Entangling Roots in slot 1). **v0.43.0:** the **wizard** now carries Blink (slot 1) and Magic Missile (slot 2) and a 15-point mana pool; priest 15, druid 10, everyone else none. A class change **re-resolves the pool and clamps it DOWN** to the new max — it never refunds and never tops you up (a class swap is not a mana potion), except for a player who had no pool at all, who starts full. Broadcasts to every peer; late joiners sync via `sync_player_field`. Reverts to the slot default on F5 respawn. |
| `/item <name> [x,y]` | Spawn a ground item (v0.18.0). Tile = explicit `x,y`, else the sender's facing-neighbour tile (never the own tile → reject if the sender hasn't faced yet). Distinct rejects: unknown item or weapon / broken resource path (catalog drift) / not-walkable / tile already has an item. Multi-word names work (`/item health potion`). **v0.21.0: `<name>` resolves the WEAPON catalog as a fallback** (`/item longsword`), so weapons can be placed as ground items — necessary now that only potions autopickup and everything else must be taken with **G**. |
| `/stun [me\|<monster>] [beats]` | Apply a STUN (v0.20.0). No arg / `me` / `self` stuns you; a monster display_name stuns the first live monster of that name. A numeric token = beats (default 3). Host-authoritative; the overhead icon shows on every peer. Stun blocks *starting* a new action AND — since v0.20.2 — INTERRUPTS an in-flight attack/cast (its resolve fizzles); movement is not interrupted. This is the **first** of the two sanctioned exceptions to the Commitment Rule (DESIGN §2.1 / §2.11); the second is the toggled instants carve-out (§2.11.1, `instant_abilities_enabled`). |
| `/root [me\|<monster>] [beats]` | Apply the **ROOTED** condition (v0.34.0 conditions framework). Argument-for-argument the sibling of `/stun`: no arg / `me` / `self` roots you; a monster display_name roots the first live monster of that name; a numeric token = beats (**default 30** — the shipped Entangling Roots duration, so the poke feels like the real ability). Host-authoritative; the green foot-tendrils and the "X is rooted!" line show on every peer, and "The roots release X." marks the end. **Rooted blocks MOVEMENT ONLY** — a rooted body still attacks, shoots, casts, drinks and equips, and Shadow Step both ignores it and BREAKS it (any forced movement does). It is NOT a Commitment-Rule exception: an in-flight glide finishes normally, and the gate only refuses STARTING a new one. Exists beside the druid ability so the condition half can be exercised with no cast, no range and no class in the way. |
| `/config <alias>` | Apply a preset **bundle** of tunings in one command (v0.19.7). Aliases live in `GameManager.CONFIG_PRESETS`; a bad row rejects the whole `/config` naming that row. Rows come in four kinds (v0.27.0 added `ab`): `w` (weapon), `m` (monster) and `ab` (ability — no shipped preset uses it yet) run through the same allowlist + clamp path as `/w`/`/m`/`/ab`; **`g` (game-level, v0.22.1)** is allowlisted by `GameManager.DEV_GAME_FIELDS` and dispatched per-field instead — today only `tactical_beat_sec`, which is snapped/clamped to the shared tempo band and then published as a normal **`set_tactical_tempo` broadcast**, so every peer adopts it exactly as a `[`/`]` nudge does (never a direct host-side write, which would leave clients' dials stale). Currently `1` = longsword & club `windup_beats 1`/`recovery_beats 3`, goblin `bonus_windup_beats 1`, **tactical beat `0.25`s** (so the preset's 1-beat windup / 3-beat swing lands at 0.25s / 0.75s in a fight). **Note (v0.27.1 doc fix):** that beat row used to *halve* a 0.50s default, but **0.25s IS the default since v0.27.0** — so the row now just restates it, and its only remaining effect is undoing a `[`/`]` nudge. Presets **clobber live values by design** — re-applying an alias restamps every row, including a tempo someone had nudged; a re-apply is idempotent (the `g` row skips the host validator's "no change" reject so it can't fail the bundle). `2` (v0.23.2) = the heavier-telegraph loadout: longsword/club `windup 3`/`recovery 4`, dagger `windup 2`/`recovery 4`, tactical beat `0.25`s, **plus four STAMINA rows** — `player_regen_interval_beats 2.0`, `monster_regen_interval_beats 2.0`, `stamina_max 1`, `monster_stamina_max 1` (v0.24.8; the max-1 rows became the shipped defaults, so re-applying them is a no-op, and the preset keeps stating its own loadout explicitly. The regen-IDLE rows were REMOVED from it in v0.26.0 — a preset row would clobber the graduated armor-weight waits with an older experimental number). **Every weapon row and the tempo row of preset `2` are now the shipped defaults too (v0.27.0 promoted the whole loadout), so `/config 2` mainly serves to UNDO live nudges.** Add a loadout by adding an alias entry — no code change (a new `g` *field*, though, needs its dispatch branch). |
| `/ai` | Toggle the **utility-AI score broadcast** (v0.22.0, host-side gate, default OFF). While on, every **committed** utility-brain decision posts an `ai_decision` event (personality, per-action scores, the action that actually committed) that ALL peers' F3 overlays render — one line per monster. Idle thinks and fully-declined walks post nothing (v0.22.1 — they drowned the traces), and `chosen` names what COMMITTED, so a higher score beside a different chosen action reads as "top pick declined" (e.g. a cornered flee) at a glance. Zero wire noise while off. The `/m` allowlist includes the 13 `utility_*`/`backup_radius_tiles` weights, so you can watch a retune move the numbers live; `ai_decision` is in the `eventlog=` allowlist for scripted runs. |
| `/stamina` (alias `/mp`) | Toggle stamina live — since **v0.26.0 stamina is a CORE RULE** (DESIGN §2.2.10, Jeff's verdict), so this is a **dev escape hatch**, not the revert switch it was while the mechanic was provisional. OFF = byte-for-byte pre-stamina movement and AI (no pool mutation; sweat-drops clear); ON = every pool reseeds to full. Host-authoritative (all reads are host-side). See the dial table below for every `/config` field — **note that every stamina dial has been a `player_`/`monster_` PAIR since v0.25.0**; the old unsplit names (`regen_idle_beats`, `regen_interval_beats`, `exhausted_step_beats`, `stamina_refill_lockout_beats`, `regen_refills_full`, `passive_regen_beats`) no longer exist and reject as unknown fields. |
| `/winded` | Toggle **hard-stop exhaustion** (v0.24.6, **ON by default since v0.27.0**): on = 0 stamina refuses movement outright (distinct "winded" reject; players and monsters alike); off = the v0.24.1 slow crawl (`player_/monster_exhausted_step_beats`). One convergent toggle over the two `*_exhausted_blocks_movement` fields, which `/config` can also set per side. **The sweat-drop overhead cue marks the CRAWL** (v0.27.0 inverted this — a hard-stopped body already tells you twice, via the refused-move bonk and the recovery bar, while a crawler had no other tell). **v0.27.1:** flipping the mode — by this command *or* by either `/config` field or its panel checkbox — now RE-POSTS the exhaustion cue for anyone already sitting at 0, so the drip can no longer be left showing the previous mode (the event is edge-triggered, and a live flip crosses no edge). |
| `/mi <id> <field\|hp\|stamina\|stun\|kill\|reset> [v]` | **Per-INSTANCE monster tuning** (v0.25.0). `id` = entity id (negative; bare positive is negated). Stat fields run the same allowlist/clamps as `/m` but against a LAZY instance-local duplicate of the MonsterType — untouched monsters keep sharing the `.tres`, so `/m` stays global; `reset` rejoins the shared type. `hp`/`stamina` poke live referee state through the normal events; `kill` runs the real death path (drops, banter, all of it). |
| `/snapshot` | Broadcast a `dev_snapshot` event carrying the full tuning truth (game fields, weapon values, **class→ability values (v0.27.0)**, monster-type values, live instances with hp/stamina). The debug panel's refresh source; deferred verdict, so no log spam. Weapon keys are `damage_min`, `damage_max`, `windup_beats`, `recovery_beats` (v0.26.1 — `damage` is gone), and the panel's WEAPONS section renders each weapon as two 2-field rows to stay inside the dock's fixed width. |
| `/help` | Print the command list (local only — never crosses the wire). |

## Game-level `/config` fields (the direct `g` form)

`/config <field> <value>` sets ONE game-level dial (v0.22.1's `g` kind, direct form v0.24.2) — the same
allowlist (`GameManager.DEV_GAME_FIELDS`) and clamp table (`DevCommands._GAME_FIELD_SPECS`) the preset
bundles run through, so a typed value can never poison the config past its clamp. Host-side write, read
live at the referee's arm/stamp/resolve site; nothing persists past a restart. `/help` derives its list
from the allowlist, so it is never stale — this table is the annotated version.

| Field | Range | What it does |
|---|---|---|
| `tactical_beat_sec` | tempo band | The TACTICAL pace beat; published as a `set_tactical_tempo` broadcast (not a silent host write) so every peer adopts it exactly as a `[`/`]` nudge does. |
| `stamina_max` | 1–12 | The PLAYER stamina pool (**default 1** since v0.26.0; classes may still add `bonus_stamina`, all 0 today). HUD pips only render when this is > 1. |
| `monster_stamina_max` | 1–12 | The MONSTERS' own independent pool (default 1). |
| `player_regen_idle_light_beats` | 0–100 | **v0.26.0** — the rest-to-recover idle wait for a LIGHT (or UNARMORED) class. Default 2.5. |
| `player_regen_idle_medium_beats` | 0–100 | Same, MEDIUM armor weight. Default 3.0. |
| `player_regen_idle_heavy_beats` | 0–100 | Same, HEAVY armor weight. Default 3.5. Heavier armor rests slower — that IS the armor cost curve (DESIGN §2.2.10 / §2.3.8). |
| `monster_regen_idle_beats` | 0–100 | The monsters' single idle wait (default 3.5). *(These four replaced the one `player_regen_idle_beats` dial — the player side is no longer one number.)* |
| `player_regen_interval_beats` / `monster_regen_interval_beats` | 0.25–100 | Beats per recovered point after the idle wait completes. **Moot at max 1** (the first tick fills the pool) but kept live-tunable. |
| `player_exhausted_step_beats` / `monster_exhausted_step_beats` | 1–100 | Crawl speed at 0 stamina (the soft-exhaustion branch). |
| `player_exhausted_blocks_movement` / `monster_exhausted_blocks_movement` | 0\|1 | Hard-stop at 0 instead of the crawl — the per-side halves of `/winded`. |
| `player_refill_lockout_beats` / `monster_refill_lockout_beats` | 0–200 | How long after leaving battle a re-entry still counts as the same fight (no refill). |
| `player_regen_refills_full` / `monster_regen_refills_full` | 0\|1 | Rest completion refills the WHOLE pool at once (no trickle). |
| `player_passive_regen_beats` / `monster_passive_regen_beats` | 0–100 | +1 stamina every N beats regardless of activity; 0 = off. |
| `monster_think_min_beats` / `monster_think_max_beats` | 0–30 | The visible-hesitation roll range at story-beat moments. |
| `swing_catches_adjacent` | 0\|1 | Sticky swings (v0.24.8, **default back ON in v0.29.0**) — the swing FOLLOWS the intended victim to a tile still adjacent to the swinger; 0 = strict tile-only commitment (step off the committed tile and it whiffs). **The toggle no longer decides whether you can be hit from two tiles away.** That was the v0.27.0 retirement's actual complaint, and it came from the *primary* ground-commit branch — a victim gliding INTO the committed tile owns that tile from the moment its glide is accepted, while its body is still two tiles out. v0.29.0 fixed it at the root: the referee applies the full motion-record reach test to the primary branch too, **unconditionally**, so "never hit from two tiles away" is now referee behavior at either setting. The blink caveat stands: `teleport_entity` wipes the motion record, so with this ON a Shadow Step that lands adjacent can still be caught. |
| `instant_abilities_enabled` | 0\|1 | **Experiment master toggle** (default ON) — Shield Block + Shadow Step (v0.26.0) **and the STRIKE cooldowns on Kick / Shield Bash** (v0.27.0), DESIGN §2.11.1. OFF = the two instants reject, the strike cooldowns are neither checked nor stamped (no refusal, no timer, no `ability_used` event) whatever `cooldown_beats` is authored, and nothing else anywhere behaves differently — i.e. the pre-v0.26 game exactly. **v0.27.1 made that literally true**: v0.27.0 shipped the strike cooldown ungated, so "they all switch off together" was a promise the code did not keep. This is the dial Jeff flips to answer the verdict question. |
| `armor_flat_reduction_light` / `_medium` / `_heavy` | 0–99 (int) | **v0.27.0** — the FLAT half of the two-term armor rule (defaults 1 / 2 / 3), keyed to the worn body item's weight band. A physical hit on a player takes the SMALLER of the percentage result and `amount - flat`; UNARMORED is flat 0 (and 0%), so no armor never mitigates. Monster defenders keep the plain percentage path. **A mitigated hit is VISIBLE in the LOG** — the line names the amount ("… for 2 (13/20, armor absorbs 2)."), and the event carries the `armor` tag + the points `absorbed`. **v0.27.1 also tinted the popup steel-blue; v0.28.1 REMOVED that** (Jon): popup colour now carries exactly one meaning — who took the number (DESIGN §2.3.4's colour convention) — so a fifth colour answering "was it mitigated" was fighting it, and the log is the better channel anyway since it can say *how much*. DESIGN §2.3.8. |
| `banter_earshot_tiles` | 0–60 (int) | **v0.27.1, widened v0.28.0** — one dial with **TWO consumers**, in Chebyshev tiles (default 12 ≈ a room and a bit). (1) **The REACTION gate, host-side:** the revenge/notable-death bark needs a living packmate within earshot **of the corpse**, and `help_me` needs an engaged ally within earshot **of the screamer** — engagement alone only answered "a fight is happening somewhere", which with packs in separate rooms produced cross-fight barks. (2) **The LOG gate, client-side (v0.28.0, Jon: "gate ALL barks by distance"):** every bark event ships the speaker's authoritative tile, and each peer's combat log prints the line only when its OWN player is within earshot of it (`game_log._bark_within_earshot`). So `0` does not merely silence the two reactions — it suppresses **every bark line** unless the speaker shares your tile. Three cases print past the log gate: no own player (a dead player is an earshot-less SPECTATOR and hears everything), a missing/malformed speaker tile, and a wall-sentinel tile on either side. The **overhead label is deliberately ungated** — it floats over the speaker, so distance already hides it. |
| `whiff_recovery_beats` | -1–30 | **v0.32.0 — a DIAL, replacing v0.28.0's `whiff_pays_recovery` toggle**
(that field name now rejects as unknown, which is correct). How much of its committed recovery tail a
WHIFFED attack actually pays — swing, ability, or smite. **`-1` (the default) = pay it ALL**, the
pre-v0.26.0 §2.3.9 behavior and Jeff's third-batch ask: the committed window plays out untouched, the whiff
event carries the real recovery seconds, and every peer shows the spent tint + green bar. **`0` = pay
none**, the v0.26.0/v0.27.x "recovery only on contact" experiment: the tail is released at resolve, the
event stamps `duration_sec` 0.0, and a whiffing goblin wakes in the same frame. **`N > 0` = pay N BEATS
of it** and hand the remainder back — the partial middle Jon asked for, stamped at the ATTACKER's resolved
beat (so the number means the same at either pace) and **capped at the full tail**, so a value past a
weapon's own `recovery_beats` simply reads as "full". The whiff event quotes the PAID number, so the tint,
the bar and the host's busy record always agree. Read host-side at each whiff, so a change lands on the
very next miss. Bow shots have no whiff and are untouched. DESIGN §2.3.9. |
| `recovery_locks_actions` | 0\|1 | **v0.28.0** — the 0-stamina **ACTION** lockout (default ON, Jeff's
third-batch ask). While an entity sits at 0 stamina in tactical pace, every NON-MOVEMENT action is refused
with the distinct `recovering` reject (bump attack, ability — STRIKE *and* instant — shot, drink, equip,
pickup) and the line "Still recovering — wait for the bar."; a monster's brain skips its attack/cast
decisions and waits out the bar. **Movement is deliberately NOT covered** — that stays
`player_`/`monster_exhausted_blocks_movement` (`/winded`), so all four combinations are reachable and
testable. **A no-op while `/stamina` is off** (the predicate's first term). DESIGN §2.2.10. |
| `force_tactical_pace` | 0\|1 | **v0.29.0 — a TESTING PIN, not a balance dial** (ships **0**). While 1,
PaceReferee resolves **TACTICAL for everyone** — every player and every monster — ignoring bubbles, leashes,
forcing windows and hysteresis, so you can look at fight-cadence behavior without first arranging a fight.
**Side effect, and usually the reason you want it:** the stamina system gates on `is_tactical`, so pinning
tactical **runs stamina everywhere** — pools spend, entities exhaust, and the recovery bar plays in an empty
room. Read host-side at every resolve, so a flip lands on the next verdict; turning it back **off** exits
through the normal `tactical_exit_sec` hysteresis ramp rather than snapping to explore. |
| `rally_travel_tiles` | 0–40 (int) | **v0.30.0** — how far the pack-rally **SHOUT** travels through OPEN
FLOOR, in travel tiles (default **15**). **Not a radius: walls bound it.** When a monster aggros organically
it shouts, and the referee flood-fills outward from its tile — every living, brained ally the sound REACHES
joins the fight. In open floor a travel tile is exactly a king-step, so the number reads like a radius; around
a corner it costs what walking it would cost, and a wall stops it dead. 15 covers the largest room end to end,
which is the point: a fight wakes the room you are standing in. **A shout leaking a few travel-tiles through
an open doorway is intended** — if it over-pulls, turn this down; that is what the dial is for. **0 = no
shout** (the rally is off). Replaces the old wall-blind Chebyshev reach, which reused the shouter's tactical
(pace) bubble — 3–5 tiles, so back rows never joined, yet happy to carry through solid rock. The **one-hop**
rule is unchanged and independent of this number: a rallied monster never re-shouts, so a big value widens one
fill and can never chain the map awake. Read host-side at each organic aggro latch, so a change lands on the
very next shout. |
| `archer_reckless_shot_chance` | 0–1 | **v0.35.0** — the odds a BOW MONSTER with no clean firing lane **and no useful sidestep** looses anyway, straight through its own packmate. Rolled host-side once per think, and only after the new reposition rung has already failed to find a tile that opens the lane. **0** = it holds when penned in (the pre-v0.35.0 caution, minus the freeze — the reposition rung still runs). **1** = it always shoots, which is how you make friendly fire (and its paired banter) reproducible on demand instead of waiting on the roll. The middle exists because both absolutes are worse: never shooting is what let a blocked archer stand still forever, and always shooting makes the lane check pointless. Read live at each archer think. |
| `root_breaks_on_damage` | 0\|1 | **v0.34.0 conditions — ships OFF.** OFF = the ROOTED condition runs its authored beats and nothing your party does to the held target frees it (a root is a reliable lock-down). ON = any hit that deals damage > 0 clears the root immediately, so the root becomes a SETUP you spend the moment you cash it in — its normal `status_expired` doubles as the released-early cue, so there is no second event to watch for. A 0-damage landed hit (a kick, a fully-absorbed swing) never breaks it: the dial says damage, not contact. This is the A/B switch for a feel question Jon+Jeff have not answered; read live at the one `apply_damage` seam. |

**REMOVED in v0.27.0:** `shield_block_cooldown_beats` and `shadow_step_cooldown_beats`. Cooldowns live on the
ABILITY resource now (`ActiveAbility.cooldown_beats`) — use `/ab shield_block cooldown_beats 30` or the panel's
CLASSES section. The old field names reject as unknown, which is correct.

## The backtick debug panel (v0.25.0)

Press **`** (backtick) in-game to open the DEBUG TUNING PANEL — an inspector-style GUI over the
whole command surface, on every peer, and since v0.25.0 the primary tuning surface (typing is the
fallback). **SIX sections, in build order:** **LOCAL (this machine)**, GAME/STAMINA (every split dial,
players column vs monsters column), WEAPONS, **CLASSES** (ability `.tres` = `/ab`), MONSTER TYPES
(shared `.tres` tuning = `/m`), LIVE INSTANCES (per-monster hp/stamina/stun/kill and per-instance stat
forks = `/mi`).

**EXPAND (v0.37.0; rebuilt v0.44.0, top-right of the title row)** — toggles the dock between its docked
size and **filling the play area**. Every glyph, row and spin box doubles *and* the dock grows to the
whole play area, so you see the bigger text AND far more of it at once (1920x1080: 780x524 against the
old 502x262, a little over 3x the area).

*What it used to do, since the old text here was wrong:* through v0.43.0 the zoom doubled the glyphs but
**halved the rect**, so expanding took you from ~10 visible rows to ~4 — and this doc, plus three comments
in the panel, claimed the dock "already spans the window top to bottom". It never did; it was ~48% of the
window height, and roughly half the screen was unclaimed. v0.44.0 split the glyph scale from the dock's
size (`_sync_geometry`): the font at either setting is exactly what it was, only the room changed. The
expanded width is floored at the docked 502 so a small window can never come out *narrower* than before,
and the collapsed state is arithmetically identical to v0.43.0's.
**Session-only** — like everything else in LOCAL below, it resets to normal size on each launch.

The CHAT/COMBAT LOG has its own expand button (its top-right, v0.37.0) on different multipliers: the box
doubles but the text grows only 1.5×, so expanding shows MORE LINES rather than the same lines larger.
Both multipliers are `@export`s on `game_log.gd` (`expanded_size_scale` / `expanded_font_scale`) if the
ratio wants tuning.

**LOCAL (this machine)** — v0.31.0, and the panel's ONE exception to "every widget submits a host
intent": these are per-machine presentation preferences, not host state, so they flip a `GameManager`
var directly, have no slash command, never appear in a `/snapshot`, and never reach the other peer.
There is no persistence layer, so they **reset to off on every launch**. One row today: **mute reject
bonk**, which silences the rejection *sound* on this machine only — the red flash and the shake still
fire, because §2.3.4 says a refusal is never confusable with a silent no-op.

**Three header buttons** sit above the sections, and the first two are the panel's ONLY surface for
commands this doc otherwise presents as typed-only: **`stamina: ?`** submits `/stamina`, **`exhaustion: ?`**
submits `/winded`, and **`refresh`** requests a fresh `/snapshot` (the values repaint from it; the panel
shows "press refresh / \` reopen for current values" until one arrives).

Every widget edit submits the same
server-authoritative `dev_command` intent the typed command would (debounced 0.3s); displayed values
come only from host-authored `dev_snapshot` events, so a client's panel shows host truth, never its
own stale config. **Caveat, honestly stated:** only the GAME rows derive their SpinBox bounds from the
clamp spec table, so widget range == host clamp there. The WEAPONS spins are a flat 0–100 against host
clamps of `damage_min`/`damage_max` [0, 999], `windup_beats` [0, 30] and `recovery_beats` [0.05, 30]; the
CLASSES spins are 0–600 for `cooldown_beats` and 0–100 otherwise, against `stun_beats` [0, 60] and
`windup`/`recovery` [0, 30]. A value the widget offers can therefore be REJECTED by the host (and a
value the host would take can be unreachable) — the pipeline is honest, the bounds are not yet derived.
Tracked as a ROADMAP parking-lot item. `debugpanel=1` is the autostart knob for scripted screenshots.

**v0.26.0 rows.** The four REGEN-IDLE dials moved OUT of the paired players|monsters block into shared
single-column rows — the player side is three ARMOR-WEIGHT bands (`LIGHT` also covers unarmored) plus
the monsters' one, which a two-column row can't express; they stay adjacent so every idle wait reads as
one group. The instants experiment added the `instant abilities` toggle row.

**v0.27.0 rows + a new section.** The **CLASSES (ability .tres — all wielders)** section joined the four
above, and sits THIRD (between WEAPONS and MONSTER TYPES): a class
OptionButton over one 2-column grid per ability, carrying all five `/ab` fields including `cooldown_beats`. It
is where the two instants cooldown dials went when they stopped being GameConfig fields — and it is how you
tune Kick's 40-beat cooldown or Shield Bash's stun without a restart. The heading says "all wielders" because
an ability `.tres` is shared, exactly like MONSTER TYPES. GAME also gained the three `armor flat` band rows.

**v0.28.0 rows.** GAME gained the two toggles from Jeff's third batch: **`whiff pays recovery`** and
**`recovery locks actions`** (`recovery_locks_actions`, default ON — the 0-stamina ACTION lockout, a no-op
while `stamina` reads off). **v0.32.0 replaced the first of the two** with the spin row **`whiff recovery
beats`** (`whiff_recovery_beats`, default **-1** = pay the whole tail = the old ON; 0 = pay none = the old
off; N = pay N beats, capped at the full tail). It is the leftmost-negative row in the panel — the -1 is a
sentinel, not a quantity.

**v0.29.0 row.** GAME gained **`force tactical`** (`force_tactical_pace`, ships OFF) — the testing pin that
resolves everyone to tactical pace, and therefore runs the stamina system everywhere. It sits last in the
shared block deliberately: it is a debugging convenience, not a tuning value.

**v0.35.0 row.** GAME gained **`archer reckless shot`** (`archer_reckless_shot_chance`, default 0.25) — how
often a penned-in bow monster shoots through its own packmate. It sits with the monster-AI dials for the same
reason `rally travel` does: it tunes what the pack DOES, not how anybody moves. Also v0.35.0, the **`whiff
recovery beats`** row was RELABELLED (not re-scoped) to `whiff recovery beats (-1 = full; caps at weapon
tail)` — the bare old label read like a magnitude you turn UP, when the dial is a cap that can only ever
SHORTEN a miss's tail, so every value at or above the weapon's own recovery behaves exactly like the default.
Turning it up and seeing nothing change is the expected result, not a bug.

**v0.34.0 row.** GAME gained **`root breaks on damage`** (`root_breaks_on_damage`, ships OFF) — the ROOTED
condition's break-on-damage question. CLASSES gained the sixth `/ab` field, **`root_beats`**, so Entangling
Roots' 30-beat hold is tunable live like every other ability number.

**v0.30.0 row.** GAME gained **`rally travel`** (`rally_travel_tiles`, default 15) — the pack-rally shout's
travel distance through open floor, wall-bounded, 0 = off. It sits with the monster-AI dials rather than the
stamina block: it tunes who joins a fight, not how anybody moves.

## Resolution notes

- **Weapons** resolve `GameConfig.weapon_catalog` by `display_name` first (with `weapon_roster` as a
  belt-and-braces fallback for a config authored without a catalog), then a filename load
  `res://resources/weapons/<name>.tres` guarded by `ResourceLoader.exists`. The catalog holds all four
  shipped weapons — dagger, longsword, bow, club — so `/w club windup_beats 2` works even though the
  club is not in the 2-weapon Tab roster. **The filename fallback therefore has no shipped subject
  today**; it exists so a brand-new `.tres` dropped into `resources/weapons/` is tunable before anyone
  remembers to register it. *(It used to be documented via `claw.tres`, which was deleted in v0.19.0.)*
- **Monsters** resolve only by filename: `res://resources/monsters/<name>.tres` (e.g. `/m goblin ...`).
- **Abilities** (v0.27.0) resolve ONLY through `GameConfig.ability_catalog`, by a SLUG of `display_name`
  (lowercase, spaces→underscores). There is no filename fallback: an ability is content a class points at, so
  the catalog is the one index — add an ability there to make it tunable.
- **Items** resolve by `display_name` through `GameConfig.item_catalog` (`item_by_name`) first, then
  `weapon_catalog` (`weapon_by_name`, v0.21.0) — so a spawnable item must be in ONE of the two catalogs.
  That item-first order is the same one `GameConfig.category_of()` and the HUD's bag icons use; a
  `display_name` present in BOTH catalogs only warns at session start (it does not fail), so keep names
  unique across them.
- **`reset`** re-reads the `.tres` from disk with `CACHE_MODE_IGNORE` and copies the allowlisted fields
  back onto the shared live instance.
- **`/m ... max_hp`** affects **new spawns only** (HP is seeded at spawn); the other three monster
  fields are read live. The other tunes take effect from the next adjudicated verdict (stamp-and-bake —
  in-flight commits keep their baked values).

## The G key (manual pickup, v0.21.0)

Not a slash command — a real gameplay key — but it's the other half of `/item`, so it's documented here.
Autopickup is **potion-only**: walk over anything else (a dropped weapon, a `/item longsword`) and it stays
on the ground with a "press G to pick up" line in your own log (or a bag-full line instead, if the bag is
full). **G** submits a `pickup_item` intent with an EMPTY payload — the host reads your tile from the move
referee's authoritative occupancy — and the pickup is INSTANT, not a committed window: the busy gate refuses
it during any action, so it can only happen between actions. Distinct §2.2.8 rejects, in adjudication order:
dead → stunned → busy → not in session → nothing to pick up → bag full. Bag capacity is authored in
`game_config.tres` as `inventory_slots` (20).

## Scripted testing

The `cmd=` autostart knob feeds one command through the real `game_log._on_input_submitted()` entry
point (the genuine interception path), on either role: e.g. `-- host cmd=/god`,
`-- join cmd=/w longsword 3`, `cmd=/class knight`. `cmdwait=<sec>` overrides the fire delay.

`cmd2=` / `cmd2wait=` (v0.25.0) are the exact mirror — a **second** scripted command with its own delay,
because every two-step tuning recipe (tune, then re-tune; set a dial, then assert the other half is
untouched) needs ordered commands in one run. Unpinned, `cmd2=` fires **2.0s after the `cmd=` anchor**, so a
bare two-command run is ordered without either wait being stated.

**Two arg-mangling traps bite `cmd=` specifically — see the `harness-verify` skill's gotchas.** A value
beginning with `/` gets path-converted under Git Bash (`cmd=/god` → `cmd=C:/Program Files/…`), and a value
containing SPACES is split into separate argv tokens by PowerShell's argument array (`cmd=/w longsword 3`
arrives as three tokens, so the command silently lands truncated).

`pickup=<n>` / `pickupwait=<sec>` (v0.21.0) script the G key from either role. The key's own sampling is
focus-gated like the number keys, so an unfocused window in a two-instance run can never reach it — the knob
bypasses the sampler and submits the **intent**, which is where the adjudication lives (the exact shape of
`ability=`). `n` is clamped 0–8 and the intents go back-to-back with NO spacing, so `pickup=2` lands both in
ONE frame — deliberately the adversarial case for `GroundItem.on_tile`'s `is_queued_for_deletion` ghost guard
(`queue_free()` sets that flag synchronously but defers tree removal, so without the guard the same item banks
twice). Expected: exactly one `item_picked_up`, the rest `rejected pickup_item: nothing to pick up`. The
default anchor is the move anchor — so a run can walk onto a non-potion and then take it — and `pickupwait=`
pins it. The `eventlog=` allowlist now carries `item_picked_up`, `item_pickup_full`, `item_pickup_available`,
`item_used` and `equip_item`, which is how these assertions are made two-instance.

`ability=<index>[,<index>...]` / `abilitywait=` / `abilitydelay=` script the 1-5 hotbar (0-based index)
through the real `use_ability` intent from either role. The **list form is v0.26.0**, for the instants
experiment: a COOLDOWN reject is only observable by pressing the SAME slot twice in one session
(`ability=1,1`), and a reject reaches only the SENDER's stdout — so both presses have to come from one
instance. `abilitywait=` is the first-fire delay, `abilitydelay=` the spacing between presses (default
0.5s, tight enough to land the second press well inside any cooldown; widen it to watch one expire).

`abilityat=<index>@<x>,<y>` (v0.34.0) is `ability=`'s **TARGETED** twin — one `use_ability` intent carrying a
`target_tile` beside the index, which `ability=` cannot express because pressing a targeted slot arms a CLICK
CURSOR rather than sending a packet. TWO focus-gated input layers (the number key, then the mouse click) sit
between a scripted run and the druid's cast, and only one window can hold focus on a two-instance machine — so
this bypasses both and exercises the INTENT, exactly as `shoot=` does for the bow. ONE press per run (a
targeted cast carries a tile per press, and no test wants two casts inside one 40-beat cooldown); a malformed
spec warns and arms nothing rather than firing at a guessed tile. Shares `abilitywait=`'s anchor. Assert on
`root_cast` (the channel committed), then `status_applied`/`status_expired` with `status: rooted` — all three
are in the `eventlog=` allowlist (`root_cast` joined it this version).

### `eventlog=` — the assertion channel

**Syntax: `eventlog=<path>`** (v0.20.0; inert without the arg, either role). It taps the broadcast
NetEvents stream to a file once that instance's session is live, one line per event:
`server_time  peer  action  data`. Event-trace assertions on that file are the harness's preferred
evidence. It is an **allowlist**, so an action absent from it never reaches the file — 26 actions pass:

| Group | Actions |
|---|---|
| Movement | `glide_to` |
| Melee / casts | `windup`, `attack`, `heal_cast`, `smite_cast`, `heal`, `died` |
| Ranged | `projectile_launched`, `projectile_ended` |
| Status + abilities | `status_applied`, `status_expired`, `blink`, `ability_used`, `ability_cooldown` |
| Items | `item_picked_up`, `item_pickup_full`, `item_pickup_available`, `item_used`, `equip_item` |
| Stamina | `stamina`, `stamina_recovery`, `exhausted` |
| AI / flavour | `ai_decision`, `thinking`, `banter` |
| Tuning | `dev_snapshot` |

`stamina_recovery` is the host-stamped armor-weight rest wait — the only way to assert the 2.5 / 3.0 / 3.5
scaling in a scripted run; `blink` / `ability_used` / `ability_cooldown` (v0.26.0) are the instants
experiment's only observables, and `status_applied`/`status_expired` is how the block's `"block"` status is
asserted. The two PROJECTILE actions joined in v0.33.0 (the monster archer): `projectile_launched` carries
`shooter_id` (negative for a monster), the exact flight `path` and the shooter's `recovery_sec`;
`projectile_ended` carries the outcome (`hit` / `spent` / `blocked`). Without them a shot could only be
inferred from its `windup` plus the `attack` it caused, so "drew but loosed nothing" and "loosed and missed"
were indistinguishable. `debug.gd`'s parser is the source of truth if this table ever drifts.

### Harness knob reference

Everything after `--` on the command line, parsed by `debug/debug.gd`. **Re-read that parser before
composing a run** — semantics change and the parser doesn't lie. The knobs above have their own prose;
this is the rest, grouped.

| Group | Knobs |
|---|---|
| Session | `host` / `join` (role), `join=<addr[:port]>`, `port=<n>` (1–65535, host bind), `hostdelay=<sec>` (delay the host's scene, reproduces the join race), `maxplayers=<n>`, `name=<text>`, `fakever=<ver>` (forge the version-gate handshake) |
| Movement | `move=<dirs>` / `movedelay=` / `movewait=` (submits intents directly — focus-immune, the host-side choice), `tap=<dirs>` / `tapsec=`, `hold=<dir>` / `holdsec=` / `holdwait=` (real input; FOCUS-gated, so only the last-launched window holds keys), `click=<tiles>` / `clickdelay=`, `shiftclick=<tiles>` (ground-fire) |
| Combat | `shoot=<tiles>` / `shootwait=`, `ability=<i[,i…]>` / `abilitywait=` / `abilitydelay=`, `abilityat=<i>@<x>,<y>`, `pickup=<n>` / `pickupwait=`, `use=<slot>` / `usewait=`, `equip=<slot>` / `equipwait=`, `swap=<0\|1>` / `swapwait=` (Tab weapon swap) |
| Content | `weapon=<name>` (starting weapon), `goblin=<n>`, `goblinat=x,y[,<type>];…` (see below), `potion=x,y`, `hostile=<0\|1>` (all-hostile players) |
| Tempo | `tempo=<sec>` / `tempowait=`, `tactical=<sec>` / `tacticalwait=`, `beatsec=`, `glidesec=`, `windupsec=` (stamp overrides) |
| Commands | `cmd=` / `cmdwait=`, `cmd2=` / `cmd2wait=`, `say=<text>` |
| Output | `eventlog=<path>`, `screenshot=<path>` (fires ~6s after `_ready`, **then quits that instance**), `overlay=<0\|1>` (F3), `rangeoverlay=<0\|1>` (F7), `debugpanel=<0\|1>` |

Unpinned `*wait=` knobs share their role's anchor (host: after the scene change; client: after connect);
the movement anchor is the default for `ability=`, `pickup=`, `hold=` and friends.

### `goblinat=` — exact-tile monster placement (typed list since v0.33.0)

Host-only, session-start only (an F5 reset does not re-apply it), and independent of `goblin=` — it only
ADDS bodies. Semicolon-separated groups, each `x,y` or `x,y,<type>`:

```
goblinat=7,3                     one plain goblin at (7,3)          — the pre-v0.33.0 meaning, unchanged
goblinat=7,3;9,5                 two plain goblins
goblinat=7,3,goblin_bow          one BOW goblin at (7,3)
goblinat=10,3,goblin_bow;7,3     the archer at (10,3), a plain goblin at (7,3) blocking its lane
```

`<type>` is the `.tres` BASENAME under `resources/monsters/` — `goblin_bow` → `goblin_bow.tres`. Omit it
and you get `goblin`. Case-insensitive. A malformed group or an unknown type is **warned and skipped**, the
rest of the list still spawns; the spawn step then re-checks the path, walkability and occupancy per tile,
so a walled or taken tile warns and skips too. Watch the host's stderr for `[Debug] goblinat=` /
`[Main] monster spawn` warnings when a body you expected isn't there.
