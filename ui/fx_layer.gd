extends Node2D

## Floating-combat-text FX layer (v0.10.1), extracted from main.gd. A Node2D under Main in WORLD space,
## ordered AFTER Monsters so its popups draw over the entities. Owns the one damage_popup spawn helper the
## attack handler calls (per-peer, off the same broadcast `attack` event every peer receives). Pure local
## presentation — never adjudication, nothing crosses the wire from here.

## Floating-combat-text spawn offset in PIXELS from the struck tile's centre (v0.10.0): lifted up so the
## popup starts above the sprite's head rather than over its face, then rises further from there.
@export var damage_popup_offset_px: Vector2 = Vector2(0.0, -14.0)


## Spawn one floating-combat-text popup for `text`/`color` over `tile` (v0.10.0). The popup is parented
## HERE (this FX layer), NEVER the struck entity, so a killing-blow popup survives the victim's despawn —
## the same rationale as the follow camera and the hurt vignette. Position is set BEFORE add_child so the
## popup's rise/fade tween (its _ready) starts from the correct spot.
func damage_popup(text: String, color: Color, tile: Vector2i) -> void:
	var popup := DamagePopup.make(text, color)
	popup.position = WorldGrid.tile_to_world(tile) + damage_popup_offset_px
	add_child(popup)
