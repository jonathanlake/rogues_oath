class_name Projectile
extends Node2D

## A per-peer LOCAL flying-arrow visual (v0.17.0, presentation only — NEVER adjudication). Main spawns one
## per `projectile_launched` event under $FxLayer, keyed by the event id, and tweens it tile-by-tile along
## the host-authored path; the matching `projectile_ended` snaps it to the terminal tile and ends it. Many
## arrows coexist (each its own node, id-keyed in main), so multiple in flight work. Code-built (no scene) —
## it creates its one Sprite2D in _ready, the same code-built-chrome pattern hud.gd uses. Everything it reads
## is event primitives (tiles + seconds + an atlas cell); it never touches occupancy or HP.

const ITEMS_TEX: Texture2D = preload("uid://5r3hjjukcluj")  # assets/32rogues/items.png

var _sprite: Sprite2D = null
var _tween: Tween = null
# The straight flight segment (v0.17.1), stored by launch() and read by finish() to snap the arrow to the
# CLOSEST POINT on the line rather than the terminal tile CENTRE — a raw centre snap would pop the arrow
# laterally off the flight line by up to half a tile at impact. _has_line stays false for an empty-path shot
# (no line stored), where finish() keeps the plain centre snap. start = the tile-EDGE loose point, end = the
# terminal tile centre — the exact segment global_position tweens along.
var _line_start: Vector2 = Vector2.ZERO
var _line_end: Vector2 = Vector2.ZERO
var _has_line: bool = false


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.texture = ITEMS_TEX
	_sprite.region_enabled = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)


## Start the flight (Main calls this right after add_child, off the projectile_launched event). Positions at
## the shooter's tile EDGE along the TRUE line to the terminal tile, points along that line, and runs ONE
## LINEAR tween to the terminal centre over the SAME total baked seconds the host's per-tile timer chain runs
## — so every peer's arrow flies the identical straight line and arrives simultaneously with the host's
## ended event. An EMPTY path (adjacent-wall shot) just sits at the shooter tile CENTRE until the ended event
## snaps + ends it. art_baseline_rad is the rotation mapping the PROJECTILE art's native direction onto its
## flight line (v0.17.1) — Main passes -deg_to_rad(weapon.projectile_art_points_deg) so a per-weapon arrow
## art aims right; the default (0.75*PI) is the 32rogues arrow-NW mapping for any caller that omits it.
func launch(shooter_tile: Vector2i, path: Array, tile_duration_sec: float, atlas_coords: Vector2i, art_baseline_rad: float = 0.75 * PI) -> void:
	_sprite.region_rect = WorldGrid.atlas_region(atlas_coords)
	# EMPTY-path guard FIRST (adjacent-wall shot): sit at the shooter tile CENTRE and store no flight line —
	# evaluated BEFORE any path.back() read below, and finish() then plain-snaps to the terminal centre.
	if path.is_empty():
		global_position = WorldGrid.tile_to_world(shooter_tile)
		return
	# ONE straight segment along the TRUE line to the terminal tile (v0.17.1) — the old per-tile tween chain
	# stair-stepped the arrow through each Bresenham cell, so it visibly kinked off the true line. The
	# Bresenham path stays AUTHORITATIVE for the host's adjudication; this straight line is presentation only.
	var end_world := WorldGrid.tile_to_world(path.back())
	var start_world := WorldGrid.tile_to_world(shooter_tile)
	var true_dir := (end_world - start_world).normalized()
	# Degenerate zero-length guard (terminal tile == shooter tile — shouldn't happen with a non-empty path):
	# fall back to +x so angle() and the edge offset stay finite rather than producing a NaN direction.
	if true_dir == Vector2.ZERO:
		true_dir = Vector2(1.0, 0.0)
	# Loose from the shooter tile EDGE (half a tile out along the TRUE line), not the centre, and aim the
	# arrow along that true line — replaces the old aim off the first 8-way path step, which could differ
	# from the real flight direction by up to 45°.
	var edge_start := start_world + true_dir * (WorldGrid.TILE_PX * 0.5)
	rotation = true_dir.angle() + art_baseline_rad
	global_position = edge_start
	# Store the flight segment (edge → terminal centre) for finish()'s closest-point snap.
	_line_start = edge_start
	_line_end = end_world
	_has_line = true
	if tile_duration_sec <= 0.0:
		return
	# ONE linear tween over the SAME total flight TIME as the host's per-tile timer chain (path.size() tiles
	# × tile_duration_sec each), so terminal arrival is simultaneous with the host's projectile_ended by
	# construction — the straight line just removes the per-cell kinks the old chain produced.
	_tween = create_tween()
	_tween.tween_property(self, "global_position", end_world, path.size() * tile_duration_sec) \
		.set_trans(Tween.TRANS_LINEAR)


## End the flight (Main calls this off projectile_ended). SNAP to the terminal tile (never freed mid-tween,
## so the arrow can't vanish a pixel short), then present the outcome and free: a "blocked" arrow bursts a
## small puff at the wall face; a "hit"/"spent" arrow just clears (the target's hurt cue rides the `attack`
## event on a hit, and a spent arrow simply flies out of sight). Late-join safe: Main only calls this on a
## projectile it actually spawned, so an unknown id never reaches here.
func finish(end_tile: Vector2i, outcome: String) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var center := WorldGrid.tile_to_world(end_tile)
	# Snap to the CLOSEST POINT on the stored flight segment to the terminal tile centre, NOT the centre
	# itself: a straight-line arrow arrives OFF the tile centre (it flew edge→centre along the true line, and
	# a blocked shot stops on a wall tile short of the line's end), so a raw centre snap would pop it
	# laterally off the flight line by up to half a tile at impact. No line stored (empty-path adjacent-wall
	# shot) → keep the plain centre snap.
	if _has_line:
		global_position = Geometry2D.get_closest_point_to_segment(center, _line_start, _line_end)
	else:
		global_position = center
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
