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
## Fill for the LIVE player tactical bubble (v0.10.3) — a green disc of radius
## GameConfig.player_tactical_radius_tiles drawn around each player currently resolved TACTICAL. Unlike
## the red/yellow monster fills (static authored ranges), this one IS live: it tracks the host's
## broadcast pace_changed events, so the ring shows only while that player is actually in the fight.
@export var player_bubble_color: Color = Color(0.2, 1.0, 0.3, 0.15)

# The Monsters container, handed in by Main via set_monsters on EVERY peer (component pattern — the
# overlay never reaches up to read a sibling). Null until wired; a null ref draws nothing.
var _monsters: Node2D = null
# The Players container + the live per-player pace dict (entity_id -> is_tactical), handed in by Main via
# set_players on EVERY peer (v0.10.3). The dict is Main's _tactical_players, mirrored from ALL pace_changed
# events in both directions and pruned on death — passed BY REFERENCE, so the overlay reads Main's live
# values without recomputing anything (broadcast-driven, no client inference → no flicker). Null/empty
# until wired; a null container draws no player rings.
var _players: Node2D = null
var _tactical_players: Dictionary = {}


## Component wiring (v0.10.1): Main hands the overlay its Monsters container so it never reaches up to
## read a sibling itself (CLAUDE.md: components never reach up). A null ref draws nothing.
func set_monsters(monsters: Node2D) -> void:
	_monsters = monsters


## Component wiring (v0.10.3): Main hands the overlay its Players container + the live pace dict (the same
## object Main mutates, shared by reference) so the overlay can draw a green ring around each player the
## host has resolved TACTICAL — without reaching up to a sibling or recomputing pace itself.
func set_players(players: Node2D, tactical_players: Dictionary) -> void:
	_players = players
	_tactical_players = tactical_players


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
	# Null until Main wires it (set_monsters), or if wiring is ever skipped — draw nothing (component
	# pattern: the overlay no longer reaches up to find its sibling itself).
	if _monsters == null:
		return
	for child in _monsters.get_children():
		var monster := child as Monster
		if monster == null or monster.monster_type == null:
			continue
		# Aggro first (red), tactical second (yellow) so yellow wins where the two radii overlap. The
		# tactical value comes from MonsterType.resolved_tactical_radius() — the SAME sentinel resolver
		# PaceReferee reads — so the overlay paints exactly the ring the host adjudicates (never a
		# -1-wide rect). A positive override draws verbatim; 0 draws nothing.
		_draw_radius(monster.tile, monster.monster_type.aggro_range_tiles, aggro_color)
		_draw_radius(monster.tile, monster.monster_type.resolved_tactical_radius(), tactical_color)

	# LIVE player tactical bubbles (v0.10.3): a green ring around each player the host has resolved
	# TACTICAL, radius from the shared authored config (same value every peer). Only nodes present in BOTH
	# $Players AND the live dict (value true) draw — a freed/disconnected player's stale dict entry is inert
	# because its node is gone (Main also prunes on death). Broadcast-driven: no client recompute, no flicker.
	if _players != null:
		var player_radius := int(GameManager.config.player_tactical_radius_tiles)
		for child in _players.get_children():
			if not (child is Entity):
				continue
			if not bool(_tactical_players.get(child.entity_id, false)):
				continue
			_draw_radius(child.tile, player_radius, player_bubble_color)


## Fill every tile within `radius` Chebyshev (king-move) tiles of `center` with `color`. radius <= 0
## draws nothing: 0 is the "unlimited" (aggro) / "no bubble" (tactical) sentinel on the authored
## fields, and flooding the whole room for "unlimited" would obscure everything — so it is skipped.
##
## A uniform-alpha Chebyshev disc IS a filled square spanning center ± radius, so this draws ONE rect
## per radius instead of the old (2r+1)² per-tile loop — pixel-identical (the tiles tile edge-to-edge
## with no intra-radius overlap, so a single fill blends the same as the per-tile fills did), and the
## red-then-yellow layering still holds because it lives BETWEEN the two _draw_radius calls above. The
## rect is CLAMPED to the room bounds (WorldGrid.size()) so a radius reaching past the edge doesn't
## paint off-grid; an entirely off-grid disc draws nothing.
func _draw_radius(center: Vector2i, radius: int, color: Color) -> void:
	if radius <= 0:
		return
	var grid_size := WorldGrid.size()
	var lo_x := maxi(center.x - radius, 0)
	var lo_y := maxi(center.y - radius, 0)
	var hi_x := mini(center.x + radius, grid_size.x - 1)
	var hi_y := mini(center.y + radius, grid_size.y - 1)
	if hi_x < lo_x or hi_y < lo_y:
		return  # the disc is entirely off-grid
	var half := Vector2(WorldGrid.TILE_PX, WorldGrid.TILE_PX) * 0.5
	var top_left := WorldGrid.tile_to_world(Vector2i(lo_x, lo_y)) - half
	var span := Vector2((hi_x - lo_x + 1) * WorldGrid.TILE_PX, (hi_y - lo_y + 1) * WorldGrid.TILE_PX)
	draw_rect(Rect2(top_left, span), color)
