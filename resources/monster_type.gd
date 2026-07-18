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

## The single authoring site for the wind-up default (seconds): the windup_sec export below seeds
## from it, and CombatReferee's total-accessor fallback returns it for a non-monster / missing-type
## node — so the "slow telegraph" default has ONE home, not a shadow copy in the referee.
const DEFAULT_WINDUP_SEC := 0.8

## Log / nameplate name for this monster ("Goblin").
@export var display_name: String = ""

## Sprite cell (column, row) into assets/32rogues/monsters.png — 0-indexed, so monsters.txt row 1
## letter c ("goblin") is (2, 0). The monster's Sprite2D region is derived from this × TILE_PX.
@export var atlas_coords: Vector2i = Vector2i.ZERO

## Starting / maximum hit points. The nameplate seeds its "HP/HP" readout from this locally at
## spawn; the combat referee owns the live value and applies damage against it.
@export var max_hp: int = 10

## Hit points removed per landed attack (deterministic — no to-hit roll, DESIGN §2.3 amendment).
@export var attack_damage: int = 3

## Telegraph duration (seconds) between a monster committing its attack and the damage resolving
## against the target TILE (DESIGN §2.1 "slow telegraphs, hard commits").
@export var windup_sec: float = DEFAULT_WINDUP_SEC

## Movement speed tier — a shared GlideSpeed resource, same mechanism players use. The referee
## reads glide_duration_sec from here when it stamps each monster step's duration.
@export var glide_speed: GlideSpeed
