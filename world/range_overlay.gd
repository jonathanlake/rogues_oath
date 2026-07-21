extends Node2D

## F7 range overlay (v0.10.0) — a world-space debug fill showing each monster's STATIC AUTHORED
## aggro and tactical radii. A Node2D sibling of $Room under Main, so it draws in world space over
## the floor (z_index below the entities); hidden by default — visibility IS the toggle, exactly like
## the F3 diagnostics overlay. While visible it re-draws every frame: for each monster in $Monsters
## it fills the tiles within monster_type.aggro_range_tiles (translucent RED) and within
## tactical_radius_tiles (translucent YELLOW, drawn SECOND so it wins on overlap), measured in
## Chebyshev (king-move) tiles centred on the monster's current tile.
##
## HONEST LIMITATION: this shows the AUTHORED ranges, NOT live aggro state. A monster's real
## engagement — acquire/leash, whether it is actually projecting a tactical bubble — is adjudicated
## HOST-side and deliberately NOT broadcast (DESIGN §2.7 event-sync: no per-frame state stream), so a
## client has no live-aggro signal to colour from. Good enough to eyeball and tune the radii visually:
## the .tres numbers themselves ARE replicated (the monster_type PATH crosses the wire, every peer
## loads the same authored values) and the monster's `tile` updates on every glide event, so the
## fills track position on every peer. Live-state colouring would need a NEW event — recorded here as
## a future note, not built. Presentation only, per-peer, never adjudication.

## Fill for the aggro radius (monster_type.aggro_range_tiles). Low alpha so stacked tiles + the floor
## underneath stay legible.
@export var aggro_color: Color = Color(1.0, 0.15, 0.15, 0.15)
## Fill for the tactical radius (monster_type.tactical_radius_tiles), drawn OVER the aggro fill.
@export var tactical_color: Color = Color(1.0, 0.9, 0.1, 0.15)


func _ready() -> void:
	# Layering comes from SIBLING ORDER in main.tscn — this node sits between $Room and $Players, so
	# the fills draw over the floor and under the entities at default z_index. (A negative z_index
	# would push the fills BELOW the opaque tilemap and hide them — the v0.10.0 first-cut bug.)
	visible = GameManager.debug_range_overlay_start_visible


func _process(_delta: float) -> void:
	# Redraw only while visible (cheap — a handful of rects, and only when toggled on). A monster's
	# tile moves on its glide events, so a per-frame redraw keeps the fills tracking each monster.
	if visible:
		queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_range_overlay"):
		visible = not visible
		queue_redraw()
		# Consume so F7 is this overlay's alone (mirrors the F3 overlay's toggle).
		get_viewport().set_input_as_handled()


func _draw() -> void:
	var monsters := get_parent().get_node_or_null("Monsters")
	if monsters == null:
		return
	for child in monsters.get_children():
		var monster := child as Monster
		if monster == null or monster.monster_type == null:
			continue
		# Aggro first (red), tactical second (yellow) so yellow wins where the two radii overlap.
		_draw_radius(monster.tile, monster.monster_type.aggro_range_tiles, aggro_color)
		_draw_radius(monster.tile, monster.monster_type.tactical_radius_tiles, tactical_color)


## Fill every tile within `radius` Chebyshev (king-move) tiles of `center` with `color`. radius <= 0
## draws nothing: 0 is the "unlimited" (aggro) / "no bubble" (tactical) sentinel on the authored
## fields, and flooding the whole room for "unlimited" would obscure everything — so it is skipped.
func _draw_radius(center: Vector2i, radius: int, color: Color) -> void:
	if radius <= 0:
		return
	var half := Vector2(WorldGrid.TILE_PX, WorldGrid.TILE_PX) * 0.5
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var top_left := WorldGrid.tile_to_world(center + Vector2i(dx, dy)) - half
			draw_rect(Rect2(top_left, Vector2(WorldGrid.TILE_PX, WorldGrid.TILE_PX)), color)
