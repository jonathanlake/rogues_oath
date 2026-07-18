class_name MonsterType
extends Resource

## Designer-editable monster template (DESIGN §2.5 "add a .tres, not a script"). One MonsterType
## per kind of monster; a non-coder tunes a monster's numbers or adds a new monster by editing /
## dropping a .tres under resources/monsters/, never by touching code. Read HOST-side when the
## world spawns and adjudicates a monster — the wire only carries the resource PATH plus the
## host-assigned entity id and tile, so every peer loads the same authored values (never streamed).
##
## Chunk-1 scope: display_name + atlas_coords (presentation) and glide_speed (the referee stamps
## a monster glide's duration from this tier, exactly as it does a player's). max_hp / attack_damage
## / windup_sec are authored now but only READ in chunk 2 (combat referee); the nameplate seeds its
## "HP/HP" readout from max_hp locally at spawn.

## Log / nameplate name for this monster ("Goblin").
@export var display_name: String = ""

## Sprite cell (column, row) into assets/32rogues/monsters.png — 0-indexed, so monsters.txt row 1
## letter c ("goblin") is (2, 0). The monster's Sprite2D region is derived from this × TILE_PX.
@export var atlas_coords: Vector2i = Vector2i.ZERO

## Starting / maximum hit points. Chunk 1 seeds the nameplate readout from this; chunk 2's combat
## referee owns the live value and applies damage against it.
@export var max_hp: int = 10

## Hit points removed per landed attack (deterministic — no to-hit roll, DESIGN §2.3 amendment).
## Chunk-2 value; unused in chunk 1.
@export var attack_damage: int = 3

## Telegraph duration (seconds) between a monster committing its attack and the damage resolving
## against the target TILE (DESIGN §2.1 "slow telegraphs, hard commits"). Chunk-2 value; unused
## in chunk 1.
@export var windup_sec: float = 0.8

## Movement speed tier — a shared GlideSpeed resource, same mechanism players use. The referee
## reads glide_duration_sec from here when it stamps each monster step's duration.
@export var glide_speed: GlideSpeed
