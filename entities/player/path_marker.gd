extends Node2D

## Click-to-move target marker: a faint one-pixel outline around the clicked tile. Pure local
## presentation — shown/hidden and positioned by the parent player from MoveInput's target
## signals, local player only; it never crosses the wire and adjudicates nothing (§2.2.9).
##
## top_level = true (set in the scene): the marker ignores the player's transform, so it stays
## planted on the clicked tile while the player glides. Callers position it via global_position
## EXCLUSIVELY — with top_level on, that is the one unambiguous coordinate space.

## Outline color. Low alpha so it reads as a hint, not a game object.
@export var outline_color := Color(1.0, 1.0, 1.0, 0.25)


func _draw() -> void:
	# One tile's outline, centered on the marker's position (which sits at the tile center,
	# from WorldGrid.tile_to_world). width = 1.0 keeps it a hairline at the game's pixel scale.
	var half := WorldGrid.TILE_PX / 2.0
	draw_rect(Rect2(-half, -half, WorldGrid.TILE_PX, WorldGrid.TILE_PX), outline_color, false, 1.0)
