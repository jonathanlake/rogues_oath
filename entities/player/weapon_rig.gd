extends Node2D

## The weapon rig — the action-timeline animator (DESIGN §2.3.7, v1). A Node2D holding one Sprite2D
## that shows the equipped weapon's items.png region, offset to the avatar's side (no facing logic
## v1). It has ONE job: present the current weapon and play its swing.
##
## Component pattern (CLAUDE.md): the rig NEVER reaches up to the Player. The Player wires it —
## seeding the weapon at spawn (set_weapon), updating it on a swap event (set_weapon), and driving
## the swing off the attack event (play_swing). All playback is EVENT-DRIVEN per peer (no new sync):
## the attack event carries the stamped duration and the weapon identity, so every peer's rig plays
## the same choreography. The tween is node-bound, so an F5 reset (which frees the node) leaves no
## orphaned tween.
##
## DOCTRINE: animation explains state. The three phases are ANIMATION-INTERNAL fractions of the
## stamped attack window (WeaponType.startup/active/recovery_frac), NORMALIZED here at playback so a
## .tres authoring error can never push a phase past the window (the referee's slide_fraction-clamp
## spirit). Gameplay never reads these timings — the referee owns the window in beats.

# The items.png sheet (32px tiles), shared by every weapon region. uid preload per CLAUDE.md.
const ITEMS_TEX: Texture2D = preload("uid://5r3hjjukcluj")  # assets/32rogues/items.png

# Idle offset (pixels) from the avatar center — the weapon rests at the avatar's side. Presentation
# constant (no facing logic v1); every swing springs from and returns to here.
const _BASE_OFFSET := Vector2(7.0, 1.0)

@onready var _sprite: Sprite2D = $Sprite2D

# The weapon currently presented, set by the Player (set_weapon). Null hides the rig (no-weapon
# fallback). The swing reads its animation fields.
var _weapon: WeaponType = null
# The swing tween, held so a fresh swing kills a lingering one and so it never outlives the node.
var _swing_tween: Tween = null


func _ready() -> void:
	position = _BASE_OFFSET


# ── Public methods ────────────────────────────────────────────────────────────

## Present a weapon (Player wires this at spawn, on a swap event, and on the late-join sync). Updates
## the idle sprite region from the weapon's atlas_coords; a null weapon hides the rig entirely (the
## no-weapon fallback). Idempotent — re-setting the same weapon just repaints the region.
func set_weapon(weapon: WeaponType) -> void:
	_weapon = weapon
	if weapon == null:
		_sprite.visible = false
		return
	_sprite.visible = true
	_sprite.texture = ITEMS_TEX
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(
		weapon.atlas_coords.x * WorldGrid.TILE_PX, weapon.atlas_coords.y * WorldGrid.TILE_PX,
		WorldGrid.TILE_PX, WorldGrid.TILE_PX)


## Play the weapon's swing toward `dir` over the stamped `duration_sec` (Player drives this off the
## attack event, on every peer). The three phases are fractions of duration_sec, NORMALIZED here so
## they can never exceed the stamped window. `dir` is the 8-way step toward the target (position
## carries the "toward target" read; rotation carries the swing style — no facing logic v1).
## A null weapon or a non-positive duration (an AoO free attack carries 0) is a no-op.
func play_swing(dir: Vector2i, duration_sec: float) -> void:
	if _weapon == null or duration_sec <= 0.0:
		return
	var unit := Vector2(dir.x, dir.y).normalized() if dir != Vector2i.ZERO else Vector2(1.0, 0.0)
	# Normalize the phase fractions (defensive: a .tres could author any values). A degenerate
	# non-positive sum falls back to an even split rather than dividing by zero.
	var s := _weapon.startup_frac
	var a := _weapon.active_frac
	var r := _weapon.recovery_frac
	var total := s + a + r
	if total <= 0.0:
		s = 1.0; a = 1.0; r = 1.0; total = 3.0
	var t_start := duration_sec * (s / total)
	var t_active := duration_sec * (a / total)
	var t_recover := duration_sec * (r / total)

	var lean := deg_to_rad(_weapon.lean_degrees)
	var arc := deg_to_rad(_weapon.arc_degrees)
	var reach := _weapon.reach_px
	var recoil := _weapon.recoil_px

	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	_swing_tween = create_tween()
	# Startup (anticipation): pull the weapon back and coil — a stab leans, a slash winds to one
	# side of the arc. Capped early by design (startup_frac ≤ ~0.15 for instant strikes, §2.3.7).
	var start_rot := -lean if _weapon.attack_style == "stab" else -arc * 0.5
	_swing_tween.set_parallel(true)
	_swing_tween.tween_property(self, "position", _BASE_OFFSET - unit * recoil, t_start)
	_swing_tween.tween_property(self, "rotation", start_rot, t_start)
	# Active (the strike lands): a stab THRUSTS toward the target and aligns; a slash SWEEPS across
	# the arc while travelling half-reach forward.
	_swing_tween.chain().set_parallel(true)
	if _weapon.attack_style == "stab":
		_swing_tween.tween_property(self, "position", _BASE_OFFSET + unit * reach, t_active)
		_swing_tween.tween_property(self, "rotation", 0.0, t_active)
	else:
		_swing_tween.tween_property(self, "position", _BASE_OFFSET + unit * reach * 0.5, t_active)
		_swing_tween.tween_property(self, "rotation", arc * 0.5, t_active)
	# Recovery (spent): recoil back through center, rotation released to rest — composes with the
	# body's recovery tint (Player.modulate propagates to this child sprite).
	_swing_tween.chain().set_parallel(true)
	_swing_tween.tween_property(self, "position", _BASE_OFFSET - unit * recoil, t_recover * 0.4)
	_swing_tween.tween_property(self, "rotation", 0.0, t_recover * 0.4)
	_swing_tween.chain()
	_swing_tween.tween_property(self, "position", _BASE_OFFSET, t_recover * 0.6)
