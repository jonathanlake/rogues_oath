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

## The single authoring site for the wind-up default (BEATS): the windup_beats export below seeds
## from it, and CombatReferee's total-accessor fallback returns it for a non-monster / missing-type
## node — so the "slow telegraph" default has ONE home, not a shadow copy in the referee. Non-zero
## so a fresh monster telegraphs by default (the windup is a per-monster dial the goblin sets to 0).
const DEFAULT_WINDUP_BEATS := 2.0

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

## The monster's held weapon (v0.9.3 — monster attacks joined the WeaponType + WeaponRig system,
## the same object a player equips). null (default) = WEAPONLESS: no rig sprite, no swing, no weapon
## field on its attack events (the training dummy). When set, the weapon WINS over the legacy
## attack fields below at all three CombatReferee read sites (damage / windup / recovery) — those
## fields remain the null-weapon fallbacks. Seeded onto the Monster's equipped_weapon in _ready;
## monsters don't swap, so it is read once at spawn. Authored as a .tres path (never streamed).
@export var weapon: WeaponType = null

## Hit points removed per landed attack (deterministic — no to-hit roll, DESIGN §2.3 amendment).
## NULL-WEAPON FALLBACK (v0.9.3): read by CombatReferee.damage_of ONLY when `weapon` is null — an
## equipped weapon's `damage` wins.
@export var attack_damage: int = 3

## Telegraph duration in BEATS between a monster committing its attack and the damage resolving
## against the target TILE (DESIGN §2.1 "slow telegraphs, hard commits"; §2.8 beats). The windup
## EXPERIMENT failed in both directions (0.25s unreadable, 0.5s dodgeable-every-time), so this is
## now a per-monster DIAL set to 0 on the goblin: at 0 the attack is an instant deterministic
## strike (no telegraph, no whiff window) followed by recovery_beats. At > 0 the full telegraph/
## whiff machinery runs unchanged (CombatReferee.wind_up) — preserved behind the dial, not deleted.
## NULL-WEAPON FALLBACK (v0.9.3): read by CombatReferee._windup_duration_of ONLY when `weapon` is
## null — an equipped weapon's `windup_beats` wins (the goblin's 0 now lives on the claw).
@export var windup_beats: float = DEFAULT_WINDUP_BEATS

## Recovery in BEATS the monster is BUSY after an instant strike (windup_beats == 0) resolves — the
## symmetric attack shape (DESIGN §2.8): instant strike + N-beat recovery during which it cannot
## act. Unlike the old brain-pacing idle, this is a real referee busy record (Commitment Rule
## enforced) for the windup==0 path. For the windup > 0 path it is added as brain pacing after the
## telegraph resolves (that path is otherwise unchanged). Goblin = 2.0 → attack rate = movement
## rate. Read HOST-side by CombatReferee (stamped to seconds) and MonsterBrain (post-attack pacing).
## Non-zero DEFAULT (like the windup's) so a fresh windup-0 monster never gets a zero-length busy
## by omission — attacking every brain poll must be an explicit authoring choice, never a default.
## NULL-WEAPON FALLBACK (v0.9.3): CombatReferee._recovery_duration_of reads this ONLY when `weapon`
## is null — an equipped weapon's `attack_beats` (its whole occupied window) wins (the goblin's 2.0
## now lives on the claw's attack_beats). The brain's post-attack pacing still reads wind_up's return.
@export var recovery_beats: float = 2.0

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
