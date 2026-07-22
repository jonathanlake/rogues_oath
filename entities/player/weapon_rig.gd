extends Node2D

## The weapon rig — the action-timeline animator (DESIGN §2.3.7). A Node2D pivoting AT the avatar's
## centre, holding one Sprite2D that shows the equipped weapon's items.png region out on a radius
## (no facing logic v1). It has ONE job: present the current weapon and play its swing.
##
## Pivot-at-centre model (v2, replaces the side-offset nudge): the RIG sits at the avatar centre
## (position = ZERO) and its Sprite2D child sits at (orbit_radius_px, 0) — out along the rig's local
## +x. Rotating the rig ORBITS the weapon around the avatar, which is what makes a slash read as a
## real sweeping arc rather than a tiny nudge. The sprite carries a baseline rotation (_SPRITE_
## BASELINE_ROT_RAD) so the items.png art — drawn pointing UP — points radially OUTWARD along the
## orbit. A slash sweeps the rig through arc_degrees across the target; a stab holds the rig on the
## target and thrusts the sprite out along its radius.
##
## VISIBILITY: the weapon is shown ONLY during a swing. set_weapon() keeps repainting the region but
## NEVER shows the sprite; play_swing() shows it on entry and hides it via a final tween_callback, so
## an idle avatar carries no resting weapon at its side.
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

# Baseline Sprite2D rotation (RADIANS): the items.png art is drawn pointing UP (-y); at +PI/2 that up
# vector maps to the rig's local +x, so the weapon points radially OUTWARD along the orbit. Tune by
# eye if a sheet's art faces differently. Named so there is no magic number in the swing.
const _SPRITE_BASELINE_ROT_RAD := PI * 0.5

# A slash's small extra wind-back (RADIANS) during startup — the coil past the arc's near edge before
# the sweep. Presentation feel; tune by eye.
const _SLASH_STARTUP_WINDBACK_RAD := 0.20

# A stab's coiled-in radius (PIXELS) at the top of the thrust — the sprite pulls in toward centre
# during startup, then drives out. Presentation feel; tune by eye.
const _STAB_START_RADIUS_PX := 6.0

@onready var _sprite: Sprite2D = $Sprite2D

# The weapon currently presented, set by the Player (set_weapon). Null hides the rig (no-weapon
# fallback). The swing reads its animation fields.
var _weapon: WeaponType = null
# The swing tween, held so a fresh swing kills a lingering one and so it never outlives the node.
var _swing_tween: Tween = null


func _ready() -> void:
	# Rig pivots AT the avatar centre; the sprite orbits from there. Kept invisible until a swing —
	# set_weapon repaints but never shows, so an idle avatar carries no weapon at its side.
	position = Vector2.ZERO
	_sprite.visible = false


# ── Public methods ────────────────────────────────────────────────────────────

## Present a weapon (Player wires this at spawn, on a swap event, and on the late-join sync). Updates
## the sprite region from the weapon's atlas_coords; a null weapon leaves the rig hidden (the
## no-weapon fallback). Idempotent — re-setting the same weapon just repaints the region. Never shows
## the sprite: play_swing owns visibility (the weapon is seen ONLY mid-swing).
func set_weapon(weapon: WeaponType) -> void:
	_weapon = weapon
	if weapon == null:
		_sprite.visible = false
		return
	_sprite.texture = ITEMS_TEX
	_sprite.region_enabled = true
	_sprite.region_rect = WorldGrid.atlas_region(weapon.atlas_coords)


## Play the weapon's swing toward `dir` over the stamped `duration_sec` (Player drives this off the
## attack event, on every peer). The three phases are fractions of duration_sec, NORMALIZED here so
## they can never exceed the stamped window. `dir` is the 8-way step toward the target; its angle
## aims the swing (rig rotation carries a slash's sweep and a stab's facing — no facing logic v1).
## A null weapon or a non-positive duration (an AoO free attack carries 0) is a no-op.
func play_swing(dir: Vector2i, duration_sec: float) -> void:
	if _weapon == null or duration_sec <= 0.0:
		return
	var unit := Vector2(dir.x, dir.y).normalized() if dir != Vector2i.ZERO else Vector2(1.0, 0.0)
	var aim := unit.angle()
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

	var arc := deg_to_rad(_weapon.arc_degrees)
	var reach := _weapon.reach_px
	var orbit := _weapon.orbit_radius_px
	var is_stab := _weapon.attack_style == "stab"

	# Baseline reset BEFORE building the tween: kill any in-flight swing and SNAP the full
	# presentation state — sprite visible, at its rest radius and baseline rotation, rig rotation at
	# THIS swing's start angle. Correctness never depends on a killed tween's callbacks having fired
	# (a mid-stab kill would otherwise leave _sprite.position.x extended). Swap-while-busy is refused
	# host-side, so a weapon swap can never race a swing here.
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	_sprite.visible = true
	_sprite.position = Vector2(orbit, 0.0)
	_sprite.rotation = _SPRITE_BASELINE_ROT_RAD
	rotation = aim if is_stab else aim - arc * 0.5

	_swing_tween = create_tween()
	if is_stab:
		# Stab: the rig holds on the target the whole time; the sprite THRUSTS out along its radius —
		# coil in to a short radius (startup), drive out past reach (active), settle back (recovery).
		# Rotation never changes: a straight thrust, not a sweep.
		_swing_tween.tween_property(_sprite, "position:x", _STAB_START_RADIUS_PX, t_start)
		_swing_tween.tween_property(_sprite, "position:x", orbit + reach, t_active)
		_swing_tween.tween_property(_sprite, "position:x", orbit, t_recover)
	else:
		# Slash: a genuine sweeping arc across the target. Wind back a touch past the near edge during
		# startup, then sweep the rig from -arc/2 through +arc/2 during active while the sprite pushes
		# out half-reach, then settle the radius back during recovery.
		_swing_tween.tween_property(self, "rotation", aim - arc * 0.5 - _SLASH_STARTUP_WINDBACK_RAD, t_start)
		_swing_tween.chain().set_parallel(true)
		_swing_tween.tween_property(self, "rotation", aim + arc * 0.5, t_active)
		_swing_tween.tween_property(_sprite, "position:x", orbit + reach * 0.5, t_active)
		_swing_tween.chain().tween_property(_sprite, "position:x", orbit, t_recover)
	# Presentation over: hide the sprite. play_swing is the SINGLE owner of "weapon visible" — every
	# swing shows on entry and hides here, so an idle avatar shows no weapon between strikes.
	_swing_tween.chain().tween_callback(func() -> void: _sprite.visible = false)
