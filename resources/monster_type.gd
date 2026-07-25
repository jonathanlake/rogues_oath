class_name MonsterType
extends Resource

## Designer-editable monster template (DESIGN §2.5 "add a .tres, not a script"). One MonsterType
## per kind of monster; a non-coder tunes a monster's numbers or adds a new monster by editing /
## dropping a .tres under resources/monsters/, never by touching code. Read HOST-side when the
## world spawns and adjudicates a monster — the wire only carries the resource PATH plus the
## host-assigned entity id and tile, so every peer loads the same authored values (never streamed).
##
## Authoring model (Godot-canonical, learned the hard way 2026-07-18): a .tres stores ONLY values
## that differ from the script defaults below — the editor's saver STRIPS default-equal properties
## on every save, so "pin everything in the .tres" cannot survive an editor round-trip. The
## defaults below are therefore part of the authored surface: changing one retunes every monster
## that doesn't override it. Change them as deliberately as you would a .tres value.

## Log / nameplate name for this monster ("Goblin").
@export var display_name: String = ""

## Sprite cell (column, row) into assets/32rogues/monsters.png — 0-indexed, so monsters.txt row 1
## letter c ("goblin") is (2, 0). The monster's Sprite2D region is derived from this × TILE_PX.
## Ignored when atlas_region is set (a non-grid sheet gives an explicit rect instead).
@export var atlas_coords: Vector2i = Vector2i.ZERO

## Override spritesheet for this monster. null (default) = the scene's default sheet (monsters.png);
## set it to point a monster at a DIFFERENT sheet (e.g. a custom asset) without touching the scene.
## Read per-peer in monster._ready — the type PATH crosses the wire, so every peer loads the same
## texture from the same authored .tres (never streamed).
@export var atlas_texture: Texture2D = null

## Explicit sprite region (pixels) for a NON-grid sheet whose art is not on a clean atlas_coords ×
## TILE_PX lattice. Zero-size Rect2() (default) = derive the region from atlas_coords × TILE_PX as
## usual; a non-zero size = use this rect verbatim as the Sprite2D region (atlas_coords is then
## ignored). Read per-peer in monster._ready.
@export var atlas_region: Rect2 = Rect2()

## Starting / maximum hit points. The nameplate seeds its "HP/HP" readout from this locally at
## spawn; the combat referee owns the live value and applies damage against it.
@export var max_hp: int = 10

## The monster's held weapon (v0.9.3 — monster attacks joined the WeaponType + WeaponRig system, the
## same object a player equips). null (default) = WEAPONLESS: no rig sprite, no swing, no weapon field
## on its attack events, and it deals NOTHING (the training dummy; unarmed-with-a-natural-weapon is a
## future concept, not a fallback). When set, the weapon supplies the BASE damage / windup / recovery,
## and the bonus_* modifiers below are ADDED on top (v0.19.0 base+wielder-modifier model, DESIGN §2.3.7).
## Seeded onto the Monster's equipped_weapon in _ready; monsters don't swap, so it is read once at spawn.
## Authored as a .tres path (never streamed).
@export var weapon: WeaponType = null

## DAMAGE MODIFIER (v0.19.0): a flat bonus ADDED to the equipped weapon's base damage when this monster
## attacks (base + wielder-modifier model, DESIGN §2.3.7 — the same shape a future player strength stat
## uses). Signed: a designer can make a monster hit harder (+) or softer (−) with the SAME weapon; the
## referee floors the sum at 0. 0 = the weapon's raw damage. Read HOST-side by CombatReferee.damage_of.
@export var bonus_damage: int = 0

## WINDUP MODIFIER in BEATS (v0.19.0): ADDED to the equipped MELEE weapon's base windup — the telegraph
## between committing the attack and the strike resolving (DESIGN §2.1 "slow telegraph, hard commit").
## This is HOW a monster is slower than a player wielding the same weapon: the club's base windup is 0
## (instant in a player's hands via the bump), and the goblin adds +1 here to telegraph. Signed; the
## referee floors the sum at 0. IGNORED for a RANGED weapon (the bow's windup is its draw — wielder
## beat-bonuses are melee-only, so a future player bonus never retunes the bow). Read HOST-side by
## CombatReferee._windup_duration_of.
@export var bonus_windup_beats: float = 0.0

## RECOVERY MODIFIER in BEATS (v0.19.0): ADDED to the equipped MELEE weapon's base recovery (its whole
## occupied window after the strike, during which the monster is BUSY — Commitment Rule). The goblin adds
## +1 here so its attack rate sits below a player's with the same weapon. Signed; floored at 0 by the
## referee; IGNORED for a ranged weapon (melee-only, same reason as bonus_windup_beats). Read HOST-side by
## CombatReferee._recovery_duration_of and by MonsterBrain's post-attack pacing (via wind_up's return).
@export var bonus_recovery_beats: float = 0.0

## Movement speed tier — a shared GlideSpeed resource, same mechanism players use. The referee
## reads glide_beats from here when it stamps each monster step's duration.
@export var glide_speed: GlideSpeed

## Aggro range in Chebyshev tiles (king-move distance): the brain chases/attacks only while the
## nearest player is within this many tiles; farther, it idles on its re-poll. Checked EVERY think,
## so it is BOTH the acquire gate and the leash — a chase drops the instant the target breaks range.
## 0 = UNLIMITED (whole-room aggro — the pre-rhythm default): two entities can never share a tile,
## so distance is always >= 1 and 0 is dead value-space, a safe "no limit" sentinel. Read HOST-side
## by MonsterBrain._think.
@export var aggro_range_tiles: int = 0

## Tactical bubble radius in Chebyshev tiles (Tactical Zones v1, DESIGN §2.8.7). While this monster is
## AGGROED, every player within this many king-move tiles of it resolves to TACTICAL pace (the "you're
## in the fight" zone). DEFAULT -1 = "MATCH aggro_range_tiles" (v0.10.3): the bubble tracks aggro so a
## monster's "you're in the fight" zone is its "it noticed you" zone unless a designer splits them —
## the sentinel is resolved to the real aggro number in ONE place (PaceReferee._radius_of), so the -1
## never reaches a distance comparison. Set a positive override to tune the two dials separately (e.g.
## a smaller "in the fight" ring inside a wider aggro range). 0 = projects NO bubble (a monster that
## leashes/attacks but never slows the room by proximity); note that -1 matching an aggro of 0
## (unlimited) also resolves to 0 = no proximity bubble (leash/forcing still apply). The real guard is
## aggroed-only: an idle or brainless monster (the dummy, has_brain=false) never engages, so it projects
## nothing regardless of this value. Read HOST-side by PaceReferee.
@export var tactical_radius_tiles: int = -1


## The ONE resolver for the -1 sentinel above: the tactical radius as a real tile count. Every
## consumer (PaceReferee host-side, the F7 overlay per-peer) reads THIS, never the raw export, so
## the "match aggro" rule can't silently diverge between adjudication and presentation.
func resolved_tactical_radius() -> int:
	return aggro_range_tiles if tactical_radius_tiles == -1 else tactical_radius_tiles

## When true (default), aggro PERSISTS: once the brain acquires a target within aggro_range_tiles it
## stays aggroed and the range check is skipped thereafter — the monster keeps chasing across rooms,
## never leash-dropping (playtest verdict, Jon/Jeff 2026-07-19). When false, the legacy LEASH
## behaviour returns: aggro_range_tiles is re-checked every think and the chase drops the instant the
## target breaks range. Designer dial (DESIGN §2.8). Read HOST-side by MonsterBrain._think.
@export var aggro_persists: bool = true

## When true (default), this monster gets a live brain (chases + attacks). false = inert
## scenery-with-HP: the host spawn path SKIPS activate_brain, so the monster never moves and never
## attacks — a training dummy / destructible prop that still seeds HP, shows a nameplate, takes
## damage, and dies through the normal referee path. Read HOST-side by Main's monster spawn gate.
@export var has_brain: bool = true


## SUPPORT — HEAL ABILITY (v0.19.4). A monster with all three fields below set (has_heal_ability) is a
## HEALER: BEFORE it decides to chase/attack, its brain scans allied monsters and, if one within
## heal_range_tiles is below its max HP, commits a telegraphed heal CAST that restores heal_amount to the
## LOWEST-HP ally at cast END. The cast is a COMMITTED action (Commitment Rule) authored in BEATS — it
## self-limits via the busy record exactly like an attack, so there is NO separate cooldown (this generalizes
## Part 4 Q9's unified-occupancy answer), and it rescales with the live tempo knob like every other duration.
## All three default to 0 = NOT a healer, so an ordinary monster is untouched and a new healer is a .tres,
## never code. Read HOST-side: MonsterBrain runs the target scan through CombatReferee and requests the cast;
## CombatReferee commits + resolves it. Killed / interrupted mid-cast wastes the heal (heal-at-END, the same
## rule potions use). An ARMED healer still chases + attacks when it has no wounded ally to tend.

## Hit points restored to the chosen ally at cast END (apply_heal clamps to the ally's max). 0 = no heal.
@export var heal_amount: int = 0

## Heal reach in CHEBYSHEV (king-move) tiles: the brain only heals an ally within this many tiles. Deliberately
## DISTINCT from aggro_range_tiles — a healer can support from farther than it would engage a player. 0 = no heal.
@export var heal_range_tiles: int = 0

## The telegraphed CAST window in BEATS: the healer is BUSY (committed — cannot move or re-cast) for this long,
## and the heal LANDS when it ends. Stamped at the caster's resolved pace (PaceReferee §2.8.7), so it scales
## with tempo like every other duration. 0 = no heal (a heal must be telegraphed — there is no instant heal).
@export var heal_cast_beats: float = 0.0

## The RECOVERY tail in BEATS after the heal lands: the healer stays BUSY (spent — cannot move or re-cast) for
## this long AFTER the cast resolves, the same shape a telegraphed attack's recovery tail uses (so a healer
## can't chain-heal instantly). Stamped at the caster's resolved pace; scales with tempo. 0 (default) = the
## healer is free the instant the heal lands. Independent of has_heal_ability (a healer with 0 recovery is valid).
@export var heal_recovery_beats: float = 0.0


## True when this monster is an authored HEALER (the three CAST fields set; recovery is optional). The ONE
## predicate the brain and scan paths gate on, so "is a healer" can't drift between the target scan and commit.
func has_heal_ability() -> bool:
	return heal_amount > 0 and heal_range_tiles > 0 and heal_cast_beats > 0.0


## OFFENSIVE SPELL — SMITE (v0.19.10). A caster with all three SMITE cast fields set can, when it has no ally
## to heal, cast a telegraphed SMITE at a RANDOM player within smite_range_tiles for smite_damage. Same
## committed-cast shape as the heal (cast + recovery beats, self-limiting, no cooldown), authored in beats so it
## scales with tempo. All default 0 = not a smiter. Host-adjudicated: CombatReferee picks the random target
## (host-only) and commits/resolves the cast; the brain only requests it. Read HOST-side.

## Damage dealt to the chosen player at cast END (apply_damage floors at 0). 0 = no smite.
@export var smite_damage: int = 0

## Smite reach in CHEBYSHEV (king-move) tiles: the caster only smites a player within this many tiles. 0 = no smite.
@export var smite_range_tiles: int = 0

## The telegraphed SMITE cast window in BEATS (the offensive twin of heal_cast_beats). 0 = no smite.
@export var smite_cast_beats: float = 0.0

## The SMITE recovery tail in BEATS after the hit lands — the caster stays spent this long (twin of heal_recovery_beats).
@export var smite_recovery_beats: float = 0.0


## AVOIDANCE (v0.19.10): when true, this monster is a KITER — it never chases into melee or swings a weapon;
## instead it steps AWAY from the nearest player whenever one is within flee_range_tiles, and otherwise holds
## position (casting from range). Default false = the normal chaser. A caster (heal/smite) with this on is the
## goblin shaman's disposition: heal an ally first, else back off if crowded, else smite from range. Read HOST-side.
@export var flees_players: bool = false

## The "personal space" radius in CHEBYSHEV tiles for a flees_players kiter: when the nearest player is within
## this many tiles, it steps away before considering a ranged cast. 0 = never flees on proximity (holds while
## it has a cast to make). Read HOST-side by MonsterBrain. Only meaningful with flees_players.
@export var flee_range_tiles: int = 0


## True when this monster is an authored SMITER (the three SMITE cast fields set; recovery is optional). The ONE
## predicate the brain gates on, mirroring has_heal_ability.
func has_smite_ability() -> bool:
	return smite_damage > 0 and smite_range_tiles > 0 and smite_cast_beats > 0.0


## WEIGHTED UTILITY AI (v0.22.0, Jeff's spec). With utility_ai ON this monster's brain stops running the
## hardcoded priority cascade and instead ENUMERATES its available actions each think, SCORES each for
## desirability from the weights below, multiplies by its rolled personality, and commits the top score
## (with a small tie-break band so close calls aren't robotic). Scores are DESIRABILITY, not probability —
## the AI should almost always do the obviously right thing; the weights decide what "right" means.
##
## OPT-IN by design: every existing monster keeps the legacy cascade byte-for-byte (zero regression
## surface), and a new utility monster is a .tres that flips this flag and authors weights — no code.
## Read HOST-side by MonsterBrain (the brain is host-only, DESIGN §2.5.3); the wire never carries a score.
##
## Scale: the weights below are floats on a loose 0-100 scale, and ONLY THEIR RELATIVE ORDER MATTERS —
## doubling every weight changes nothing. All of them are live-tunable mid-fight through `/m <monster>
## <field> <value>` (they are in GameManager's DEV_MONSTER_FIELDS allowlist), which is how a fight gets
## balanced: turn on `/ai` to watch the scores in the F3 overlay, then nudge a weight and watch it move.
##
## Authoring note (see the file header): a .tres stores only values that DIFFER from these defaults, so
## the defaults ARE the authored baseline for every utility monster that doesn't override them. Retune
## them as deliberately as a .tres value.

## Master switch: run the weighted utility scorer instead of the legacy priority cascade. false (default)
## = every existing monster is untouched. All the utility_* weights below are inert while this is false.
@export var utility_ai: bool = false

## TIE-BREAK band in SCORE POINTS (post-personality). When the top two candidates land within this margin
## of each other, the brain flips a coin between THOSE TWO ONLY (Jeff: "close calls shouldn't be robotic").
## 0 = strict argmax, always the highest score. Deliberately compared in POST-multiplier space: a
## personality changes which pairs are genuinely close calls. A third candidate inside the band is
## ignored — a documented limit of the generic scorer.
@export var utility_tiebreak_margin: float = 8.0

## HEAL base weight — the score a heal earns for an ally at 0% HP. The actual score is
## `utility_heal_weight × (1 - hp_fraction)²`, a QUADRATIC on the worst injured ally's missing HP: an ally
## at 90% scores ~1 and one at 25% scores ~56, so healing is "only a very high priority when significantly
## injured" (Jeff) as a curve rather than a threshold. 0 = never heal by choice.
@export var utility_heal_weight: float = 100.0

## Flat bonus ADDED to the heal score per ADDITIONAL injured ally in heal range (the first injured ally is
## already priced by the curve above). A pack that is broadly hurt is worth tending sooner than one hurt
## body. 0 = injured-ally count doesn't matter, only the worst one.
@export var utility_heal_per_injured_bonus: float = 8.0

## SMITE base weight — the score an available offensive cast earns before situational adjustments. No
## explicit "allies are healthy" term is needed: when allies are hurt the heal curve simply outscores this.
@export var utility_smite_weight: float = 60.0

## Bonus ADDED to the smite score when the chosen target is STANDING STILL (not mid-commit). A committed
## ground-target cast is dodgeable, so a stationary victim is a much better bet than a moving one.
@export var utility_standstill_bonus: float = 15.0

## Penalty SUBTRACTED from the smite score when a player is ADJACENT (Chebyshev 1) — that is melee's or
## the retreat's moment, not the moment to root yourself in a long telegraphed cast. The composite score
## is floored at 0, so an over-large penalty just disables the cast rather than going negative.
@export var utility_smite_adjacent_penalty: float = 25.0

## MELEE base weight — the score for swinging at an ADJACENT player. Requires an equipped weapon (a
## weaponless monster deals nothing, so it never scores melee at all).
@export var utility_melee_weight: float = 50.0

## COURAGE, cornered edition: bonus ADDED to melee when this monster has NO living brained ally within
## backup_radius_tiles. Alone and in contact, a caster stops pretending it has a frontline and fights.
@export var utility_melee_alone_bonus: float = 20.0

## FLEE (kiting step) base weight — the score for stepping AWAY when a player is inside flee_range_tiles.
## Only ever scores for a flees_players monster. High by default: with a frontline alive, a caster's job
## is to keep its distance.
@export var utility_flee_weight: float = 70.0

## COURAGE, the other half: the flee score is MULTIPLIED by this when the monster is ALONE (no living
## brained ally within backup_radius_tiles). < 1 decays kiting into fighting — with the pack alive the
## shaman kites, alone it turns and casts/swings (Jeff's backup-courage behaviour). 1.0 = alone changes
## nothing; 0 = never flee alone.
@export var utility_alone_move_factor: float = 0.25

## APPROACH (chase step) base weight — the score for stepping TOWARD the nearest player. Scores ONLY when
## engaged AND nothing is in range of any cast/melee, so movement always serves another tactical objective
## (Jeff's rule) and the monster never wanders for wandering's sake. Deliberately below the cast weights.
@export var utility_approach_weight: float = 40.0

## BACKUP radius in CHEBYSHEV (king-move) tiles: "do I have a frontline?" is "is there a living, BRAINED
## allied monster within this many tiles" (the training dummy, has_brain=false, never counts as backup).
## Feeds the alone/backed terms of the melee and flee weights above. 0 = always considered alone.
@export var backup_radius_tiles: int = 6

## How far (Chebyshev tiles) a HEALER notices a wounded brained ally BEYOND its heal range and scores the
## walk-to-heal form of the HEAL candidate (v0.23.3 — the v0.23.2 walk feature reused backup_radius_tiles,
## which with backup 6 / heal 5 collapsed the awareness band to a single tile). Read only when
## has_heal_ability(); 12 covers a room. The walk itself is one committed step per decision — the per-step
## re-think re-scores, so a longer seek never means a blind cross-map march.
@export var heal_seek_radius_tiles: int = 12

## The personality pool this monster rolls from at spawn (v0.22.0). The brain picks ONE uniformly at
## activation and keeps it for that instance's life — the roll is stored on the BRAIN, never here, because
## a MonsterType is a SHARED cached resource and must never carry per-instance state. Empty (default) =
## neutral: every multiplier is 1.0. Add a personality by dropping an AiPersonality .tres in this list.
@export var personalities: Array[AiPersonality] = []
