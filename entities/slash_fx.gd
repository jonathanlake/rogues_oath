class_name SlashFx
extends Node2D

## Red slash streak drawn across a struck entity (§2.3.4 hit juice, v0.6.3). A CHILD of the entity,
## drawn OVER the sprite, it flashes a thick red diagonal line for ~0.12s then hides — the "a blow
## landed HERE" mark. It rides the SAME attack event as the hurt flash + hit sound (no new wire
## data): every peer renders it, and the strike direction is derived per-peer in main.gd from the
## event, exactly as the attacker's lunge dir is. Presentation only — never adjudication.
##
## Deterministic, NO RNG: a fixed table maps the 8-way attack dir to one of four diagonal angles,
## each roughly perpendicular to the blow's axis so the streak always crosses the 32px sprite. It is
## a child at the entity's local origin (= sprite centre), so the line is centred on the sprite and
## rides the parent through any glide/lunge without re-basing.

## Length of the streak in pixels — ~28px on the 32px sprites reads as a streak, not a speck.
@export var length_px: float = 28.0
## Line thickness in pixels.
@export var width_px: float = 4.0
## The streak colour (§2.3.4 — the red hit language, shared in spirit with the hurt flash).
@export var color: Color = Color(1.0, 0.15, 0.15, 1.0)
## Fade-out time in seconds — one quick flash, then gone.
@export var fade_sec: float = 0.12

# Current draw angle (radians), set by show_streak before each queue_redraw. Defaults to the
# ZERO-dir fallback so a stray _draw before the first hit is still well-defined.
var _angle_rad: float = deg_to_rad(65.0)
# The alpha fade tween, held so a rapid re-hit cleanly replaces rather than stacks (kill-prior).
var _fade_tween: Tween = null


func _ready() -> void:
	# Drawn over the sprite (sprite sits at z 0); hidden until a hit shows it.
	z_index = 1
	visible = false


# ── Public methods ────────────────────────────────────────────────────────────

## Show the streak for one landed hit. `dir` is the 8-way step from attacker toward this victim,
## derived per-peer in main.gd from the attack event; the fixed table picks the diagonal so the
## streak crosses the sprite roughly perpendicular to the blow. Vector2i.ZERO falls back to 65°.
func show_streak(dir: Vector2i) -> void:
	_angle_rad = deg_to_rad(_angle_for_dir(dir))
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	modulate.a = 1.0
	visible = true
	queue_redraw()
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 0.0, fade_sec)
	_fade_tween.tween_callback(func(): visible = false)


# ── Private methods ───────────────────────────────────────────────────────────

func _draw() -> void:
	# Two-point line centred on the origin: -half .. +half along the chosen angle.
	var half := Vector2(cos(_angle_rad), sin(_angle_rad)) * (length_px * 0.5)
	draw_line(-half, half, color, width_px)


## Fixed dir -> angle table (degrees from +x, y-down screen space). Four diagonals, each roughly
## perpendicular to the blow's axis so the streak always crosses the sprite. Deterministic, no RNG.
## E/W → 115°, N/S → 25°, NE/SW → 155°, NW/SE → 65°, ZERO → 65° (matches the plan's table).
func _angle_for_dir(dir: Vector2i) -> float:
	if dir == Vector2i.ZERO:
		return 65.0
	if dir.x != 0 and dir.y != 0:
		# Diagonals: NE (1,-1) / SW (-1,1) have a negative sign product → 155°; NW (-1,-1) /
		# SE (1,1) positive → 65°.
		return 155.0 if dir.x * dir.y < 0 else 65.0
	if dir.x != 0:
		return 115.0  # horizontal E/W
	return 25.0  # vertical N/S
