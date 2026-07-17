class_name Player
extends Node2D

## A player avatar. Holds identity (peer_id, player_name, spawn_index) and shows a sprite +
## name label. Movement (glide presentation, input, referee wiring) arrives in M2 chunk 2;
## this chunk only adds the tile bookkeeping and the speed-tier hook it will read.

const _TILE_PX := 32

## Distinct sprite tiles (col, row) into rogues.png, one per spawn slot, so players are
## told apart at a glance. Indexed by spawn_index (wraps if there are more players than tiles).
const _SPRITE_TILES: Array[Vector2i] = [
	Vector2i(3, 0),  # rogue
	Vector2i(0, 1),  # knight
	Vector2i(0, 4),  # female wizard
	Vector2i(0, 3),  # male barbarian
	Vector2i(1, 2),  # priest
	Vector2i(2, 0),  # ranger
]

## This tier's per-step glide time, read server-side when the referee stamps a glide's
## duration (chunk 2). The scene assigns speed_normal.tres; a designer swaps the tier by
## pointing this at a different resources/speed_tiers/*.tres.
@export var glide_speed: GlideSpeed

# Assigned by main.gd's spawn_function (from the replicated spawn config) before this
# node enters the tree, so _ready can read them on every peer.
var peer_id: int = 0
var player_name: String = ""
var spawn_index: int = 0

## Logical grid position. Presentation metadata mirrored on every peer (set at spawn here,
## updated at glide start in chunk 2). NOT the adjudication truth — the host referee's own
## bookkeeping is authoritative; this is only what the avatar believes it stands on.
var tile: Vector2i

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _name_label: Label = $NameLabel


func _ready() -> void:
	var sprite_tile := _SPRITE_TILES[spawn_index % _SPRITE_TILES.size()]
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(sprite_tile.x * _TILE_PX, sprite_tile.y * _TILE_PX, _TILE_PX, _TILE_PX)
	_name_label.text = player_name
