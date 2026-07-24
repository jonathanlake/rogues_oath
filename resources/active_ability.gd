class_name ActiveAbility
extends Resource

## Designer-editable ACTIVE (triggered) ability (v0.20.0, active-ability system). A PlayerClass carries an
## Array[ActiveAbility] (resources/player_class.gd); the HUD binds them to the 1-5 hotbar and pressing a key
## submits a `use_ability {index}` intent the host adjudicates. Unlike a PassiveAbility (a silent combat hook),
## an active ability is a COMMITTED action (DESIGN §2.1; no separate cooldown per Part 4 Q9): using it ROOTS the
## player for its beats — that occupied window IS the anti-spam. HOST-ONLY / server-authoritative: the
## AbilityReferee reads these values host-side; the wire only ever carries the slot index. Add an ability by
## dropping a `.tres` into a class's `active_abilities` — no code edit.
##
## v1 shape (both the knight shield-bash and the rogue kick are THIS one mechanic, differing only in numbers):
## a committed melee strike on an ADJACENT enemy that deals `damage` and applies a `stun_beats` STUN. Later
## abilities (ranged, self-buff, ground-target) extend this resource / add a kind selector.

## Player-facing name — HUD hotbar tooltip + the source of the combat-log verb. Empty = unnamed (still usable).
@export var display_name: String = ""

## Hotbar icon cell (column, row) into assets/32rogues/items.png — 0-indexed, like an ItemType icon.
@export var atlas_coords: Vector2i = Vector2i.ZERO

## Combat-log verb for a landed use ("bashes", "kicks") — the §2.3.4 distinct line. Empty falls back to "hits".
@export var log_verb: String = ""

## Deterministic damage to the struck enemy (0 = a pure utility strike, e.g. a stun-only kick). Referee floors at 0.
@export var damage: int = 0

## STUN applied to the struck enemy in BEATS (0 = no stun). Stamped at the target's beat, so it scales with tempo.
@export var stun_beats: float = 0.0

## Telegraph windup in BEATS before the strike resolves (0 = instant strike, like a bump). Part of the occupied window.
@export var windup_beats: float = 0.0

## Recovery tail in BEATS after the strike — the committed "spent" window the user stays rooted (Q9 unified occupancy).
@export var recovery_beats: float = 0.0

## Reach in tiles for the target search (1 = 8-adjacent, the v1 default — a point-blank strike). Read HOST-side.
@export var range_tiles: int = 1


## True when this ability is validly authored (has SOME effect AND a real occupied window). The ONE predicate the
## referee gates on, so an empty / misauthored slot can never be "used".
func is_valid_ability() -> bool:
	return (damage > 0 or stun_beats > 0.0) and (windup_beats + recovery_beats) > 0.0
