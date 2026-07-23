class_name Projectile
extends Node2D

## A per-peer LOCAL flying-arrow visual (v0.17.0, presentation only — NEVER adjudication). Main spawns one
## per `projectile_launched` event under $FxLayer, keyed by the event id, and tweens it tile-by-tile along
## the host-authored path; the matching `projectile_ended` snaps it to the terminal tile and ends it. Many
## arrows coexist (each its own node, id-keyed in main), so multiple in flight work. Code-built (no scene) —
## it creates its one Sprite2D in _ready, the same code-built-chrome pattern hud.gd uses. Everything it reads
## is event primitives (tiles + seconds + an atlas cell); it never touches occupancy or HP.

const ITEMS_TEX: Texture2D = preload("uid://5r3hjjukcluj")  # assets/32rogues/items.png

## Sprite baseline rotation (RADIANS): the items.png arrow art points UP (-y); +PI/2 turns that up vector
## onto the local +x so the arrow points ALONG its flight direction. Tune by eye if the art faces differently.
const _BASELINE_ROT_RAD := PI * 0.5

var _sprite: Sprite2D = null
var _tween: Tween = null


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.texture = ITEMS_TEX
	_sprite.region_enabled = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)


## Start the flight (Main calls this right after add_child, off the projectile_launched event). Positions at
## the shooter's tile EDGE toward the first path tile, points along the flight, and chains one LINEAR tween
## per path tile at tile_duration_sec each — the same baked seconds the host stamped, so every peer's arrow
## flies the identical arc from the one event. An EMPTY path (adjacent-wall shot) just sits at the edge until
## the ended event snaps + ends it.
func launch(shooter_tile: Vector2i, path: Array, tile_duration_sec: float, atlas_coords: Vector2i) -> void:
	_sprite.region_rect = WorldGrid.atlas_region(atlas_coords)
	var start := WorldGrid.tile_to_world(shooter_tile)
	if not path.is_empty():
		var first: Vector2i = path[0]
		var dir := Vector2(first - shooter_tile)
		if dir != Vector2.ZERO:
			rotation = dir.angle() + _BASELINE_ROT_RAD
			start += dir.normalized() * (WorldGrid.TILE_PX * 0.5)  # loose from the tile edge, not the centre
	global_position = start
	if path.is_empty() or tile_duration_sec <= 0.0:
		return
	_tween = create_tween()
	for tile in path:
		_tween.tween_property(self, "global_position", WorldGrid.tile_to_world(tile), tile_duration_sec) \
			.set_trans(Tween.TRANS_LINEAR)


## End the flight (Main calls this off projectile_ended). SNAP to the terminal tile (never freed mid-tween,
## so the arrow can't vanish a pixel short), then present the outcome and free: a "blocked" arrow bursts a
## small puff at the wall face; a "hit"/"spent" arrow just clears (the target's hurt cue rides the `attack`
## event on a hit, and a spent arrow simply flies out of sight). Late-join safe: Main only calls this on a
## projectile it actually spawned, so an unknown id never reaches here.
func finish(end_tile: Vector2i, outcome: String) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	global_position = WorldGrid.tile_to_world(end_tile)
	if outcome == "blocked":
		# Impact puff at the wall face (local tween primitives, no new assets): a quick scale-pop while
		# fading out, then free — reads as "the arrow shatters" alongside the game-log line.
		var puff := create_tween()
		puff.set_parallel(true)
		puff.tween_property(_sprite, "scale", Vector2(1.7, 1.7), 0.12)
		puff.tween_property(_sprite, "modulate:a", 0.0, 0.12)
		puff.chain().tween_callback(queue_free)
	else:
		queue_free()
