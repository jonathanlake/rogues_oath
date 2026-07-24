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


## True when this monster is an authored HEALER (all three heal fields set). The ONE predicate both the brain
## and the spawn/scan paths gate on, so "is a healer" can't drift between the target scan and the cast commit.
func has_heal_ability() -> bool:
	return heal_amount > 0 and heal_range_tiles > 0 and heal_cast_beats > 0.0
