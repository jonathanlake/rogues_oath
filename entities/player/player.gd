class_name Player
extends Node2D

## A player avatar. Pure presentation for M1 ("See Each Other"): it holds identity
## (peer_id, player_name, spawn_index) and shows a sprite + name label. NO input, NO
## movement, NO _process — nothing moves in this milestone, and the Commitment Rule
## forbids any input-driven redirection anywhere, so there is deliberately no such code.

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

# Assigned by main.gd's spawn_function (from the replicated spawn config) before this
# node enters the tree, so _ready can read them on every peer.
var peer_id: int = 0
var player_name: String = ""
var spawn_index: int = 0

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _name_label: Label = $NameLabel


func _ready() -> void:
	var tile := _SPRITE_TILES[spawn_index % _SPRITE_TILES.size()]
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(tile.x * _TILE_PX, tile.y * _TILE_PX, _TILE_PX, _TILE_PX)
	_name_label.text = player_name
