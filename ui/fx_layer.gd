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


## Spawn a one-shot GREEN particle burst over `tile` when a heal LANDS (v0.19.9, §2.3.4 — a distinct recovery
## cue). Parented HERE (world-space FX layer), never the healed entity, so it survives a despawn like the
## popup. CPUParticles2D (not GPU) for GL-Compatibility safety; rising green sparkles that fade via the ramp,
## then the node frees itself just past its lifetime. Fired for EVERY heal (shaman cast, potion drink alike).
func heal_burst(tile: Vector2i) -> void:
	var p := CPUParticles2D.new()
	p.position = WorldGrid.tile_to_world(tile) + damage_popup_offset_px
	p.one_shot = true
	p.explosiveness = 0.85
	p.amount = 18
	p.lifetime = 0.7
	p.direction = Vector2(0, -1)
	p.spread = 55.0
	p.gravity = Vector2(0, -28.0)   # drift UP — a "recovery/rising" read
	p.initial_velocity_min = 16.0
	p.initial_velocity_max = 46.0
	p.scale_amount_min = 1.5
	p.scale_amount_max = 3.0
	var grad := Gradient.new()
	grad.set_color(0, Color(0.45, 1.0, 0.55, 1.0))   # heal green, opaque → transparent
	grad.set_color(1, Color(0.45, 1.0, 0.55, 0.0))
	p.color_ramp = grad
	add_child(p)
	p.emitting = true
	# Free just past the burst's lifetime (one-shot never re-emits). Host-tree timer, survives fine.
	get_tree().create_timer(p.lifetime + 0.2).timeout.connect(p.queue_free)


## Paint a RED DANGER tile over `tile` for `hold_sec` (v0.19.10, Rogue-Fable telegraph): a translucent red
## square, pulsing so it reads as urgent, marking where a monster's ground-target spell (the shaman's smite) will
## land — step off it before the cast ends to dodge. Drawn HERE in world space (a full TILE_PX square centred on
## the tile), removed when the cast resolves. Parented to the FX layer so it never depends on the caster node.
func danger_tile(tile: Vector2i, hold_sec: float) -> void:
	var half := WorldGrid.TILE_PX / 2.0
	var mark := Polygon2D.new()
	mark.polygon = PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	mark.color = Color(0.95, 0.2, 0.2, 0.5)  # translucent red
	mark.position = WorldGrid.tile_to_world(tile)
	add_child(mark)
	# Pulse the alpha so the danger reads as active; killed + freed at hold_sec.
	var t := create_tween().set_loops()
	t.tween_property(mark, "modulate:a", 1.0, 0.3).from(0.55)
	t.tween_property(mark, "modulate:a", 0.55, 0.3)
	if hold_sec > 0.0:
		get_tree().create_timer(hold_sec).timeout.connect(t.kill)
		get_tree().create_timer(hold_sec).timeout.connect(mark.queue_free)
