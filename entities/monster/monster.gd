class_name Monster
extends Entity

## A monster avatar. Holds identity (entity_id, monster_type) and the monster-specific surfaces
## (brain activation, wind-up/whiff cues); the shared presentation — sprite/labels, glide
## playback, combat cues — lives on Entity. It never adjudicates: the host's MoveReferee owns
## occupancy and outcomes, and the host-only MonsterBrain child decides this monster's intents.
## The node graph is identical on every peer (uniform replication); only the host activates the
## brain.
##
## Entity id (DESIGN §2.5, plan decision 5): monsters carry a host-assigned NEGATIVE id, so the
## referee's one occupancy space distinguishes them from players (positive peer ids) with no
## overlap. The id rides the replicated spawn config, so every peer names this node str(entity_id)
## and resolves glide events to it the same way.
##
## Movement flow is Entity.glide_to verbatim: at spawn the node sits at its tile; when the host
## broadcasts an accepted glide_to for this entity, Main calls glide_to() here on every peer and
## the LINEAR tween runs. Per the Commitment Rule there is no cancel path — glide_to only ever
## kills a tween to catch up to newer server truth, never to abort a committed step.

## Windup blink tell (v0.6.2 — one sharp white pulse at windup start; Jon's feel knobs). Peak is
## the shader flash_amount (0-1, mix-to-white — cannot overshoot); in/out are the pulse's rise and
## fall times in seconds. The sustained plant is the COIL pose, not the light.
@export_range(0.0, 1.0, 0.05) var windup_blink_peak: float = 0.85
@export var windup_blink_in_sec: float = 0.03
@export var windup_blink_out_sec: float = 0.08

# ── Public state ──────────────────────────────────────────────────────────────

## This monster's authored template — display name, sprite cell, stats, speed tier. Set at spawn
## from the replicated type PATH (each peer loads the same .tres); never streamed as a resource.
var monster_type: MonsterType = null

@onready var _brain := $MonsterBrain
# Wind-up/whiff feedback (§2.3.4). Placeholder assets: pitch-shifted reuses of the two existing
# wavs (windup = bonk mid, whiff = commit_sent very low) — flagged placeholder, real SFX later.
@onready var _windup_audio: AudioStreamPlayer = $Windup
@onready var _whiff_audio: AudioStreamPlayer = $Whiff

# The white-flash shader tween (the v0.6.1 windup tell), held on its OWN slot so it never collides
# with the modulate flash (_flash_tween, still play_hurt's) or the position coil (_shake_tween).
# Drives the Sprite2D ShaderMaterial's flash_amount (see _set_flash).
var _flash_shader_tween: Tween = null

# Heal-cast overhead symbol (v0.19.8): a pulsing green sparkle shown above a HEALER's head for the whole
# channel window, driven per-peer from the heal_cast event. Held on its own node + tween slot so a re-cast or a
# mid-cast death clears it cleanly (the node frees with the monster; the end timer's connection drops then).
var _cast_fx: Node2D = null
var _cast_fx_tween: Tween = null


func _ready() -> void:
	super()
	# monster_type is set at spawn before the node enters the tree, so it's readable here on
	# every peer. A missing type is a spawn-config bug; warn rather than crash on null access. The
	# name surface arrives pre-tree ("Monster" from the spawn config for a broken type), so this
	# early return just seeds the label from it and leaves it intact — never overwrites it.
	if monster_type == null:
		push_warning("[Monster] entity %d spawned with no MonsterType — using bare defaults" % entity_id)
		_name_label.text = display_name
		return
	glide_speed = monster_type.glide_speed
	# Seed the equipped weapon from the authored type (v0.9.3 — monster attacks joined the weapon
	# system). null = weaponless: the training dummy shows no rig sprite, plays no swing, and stamps no
	# weapon field on its (never-fired) attack events. set_weapon (Entity) repaints the rig on every
	# peer; the goblin's club drives both its swing choreography and the host-side damage/occupied-window
	# BASE (in CombatReferee), onto which MonsterType.bonus_damage/windup/recovery are ADDED (v0.19.0
	# base+wielder-modifier model). Seeded once at spawn — monsters don't swap.
	equipped_weapon = monster_type.weapon
	set_weapon(equipped_weapon)
	# Sprite: an optional atlas_texture override points this monster at a different sheet than the
	# scene default (monsters.png); an optional non-zero atlas_region gives an explicit rect for a
	# non-grid sheet, else derive the region from atlas_coords × TILE_PX as usual. Both are authored
	# on the type and loaded identically on every peer (the type PATH crosses the wire, never pixels).
	if monster_type.atlas_texture != null:
		_sprite.texture = monster_type.atlas_texture
	_sprite.region_enabled = true
	if monster_type.atlas_region.size != Vector2.ZERO:
		_sprite.region_rect = monster_type.atlas_region
	else:
		_sprite.region_rect = WorldGrid.atlas_region(monster_type.atlas_coords)
	# Nameplate is name-only, seeded from the pre-tree display_name; the HP readout rides its own
	# label under the feet, seeded from the authored max locally (max_hp is known everywhere) via
	# set_hp_display, the single formatting site. The combat referee drives updates from attack
	# events. Full HP at spawn.
	_name_label.text = display_name
	set_hp_display(max_hp, max_hp)


# ── Public methods ────────────────────────────────────────────────────────────

## Host-only: hand this monster's brain the movement + combat referees and switch it on. Called by
## Main's monster spawn path INSIDE its is_server() guard (component pattern — the parent wires the
## child). The monster owns the brain<->boundary handshake so the brain never reaches up to its
## parent: it connects its OWN glide_finished to the brain's boundary hook here. Inert on clients.
func activate_brain(referee: Node, combat: Node, pace: Node) -> void:
	glide_finished.connect(_brain.on_boundary)
	# Hand the brain this monster's own fields (id + authored type) alongside the referees — the
	# parent reads them off itself and injects them, so the brain never reaches up (component pattern).
	# monster_type carries the aggro-range leash the brain reads each think (v0.6.0 rhythm build); the
	# pace referee (Tactical Zones v1, §2.8.7) receives this monster's engagement each think and stamps
	# its wake/pacing math at its own resolved beat.
	_brain.activate(referee, combat, entity_id, monster_type, pace)


## Host-only forwarder (v0.17.2 review fix): the combat referee tells this monster it just took damage so
## its brain treats the hit as an aggro source — a ranged arrow from beyond aggro_range_tiles still wakes it
## (no free sniping). Null-guards the brain the same way activate_brain assumes it (the node graph is uniform
## on every peer, so _brain is always present, but the guard mirrors the component-wiring contract); the
## brain's own _active gate makes a client / brainless-dummy call inert anyway. Never interrupts a committed
## action — the brain only reschedules a think (Commitment Rule applies to monsters too).
func notify_attacked() -> void:
	if _brain != null:
		_brain.notify_attacked()


## Hostility test (DESIGN §2.2.6, plan decision 6), read HOST-side. A monster is hostile to any
## player and never to another monster; the debug-only GameManager.all_hostile flag ORs on top so
## the AoO/combat wiring can be demoed with the harness. Symmetric with Player.is_hostile_to.
func is_hostile_to(other: Node) -> bool:
	if GameManager.all_hostile and other != self:
		return true
	return other is Player


## Telegraph feedback (§2.3.4) for a wind-up starting, played on every peer from the `windup` event:
## a COILED WHITE tell (v0.6.1). Two pieces on the same beat — a TRUE-white shader flash snapped
## near-peak and HELD, and a SNAP-AND-HOLD pull-BACK away from the target. This is the "slow
## telegraph" (DESIGN §2.1) giving a target the window to glide off the committed tile before
## resolution; every peer renders it from the authoritative event, never locally-inferred facing, so
## the tell is identical on the wire (multiplayer-first). The old yellow modulate flash is REPLACED:
## modulate MULTIPLIES, so it can only brighten a green sprite, never whiten it — _flash() itself
## stays, play_hurt still uses it. `dir_away` is the 8-way step from the target toward this monster
## (main derives it from monster.tile - target_tile); `hold_sec` is the windup duration, so the coil
## and flash hold exactly the telegraph window.
func play_windup(dir_away: Vector2i, hold_sec: float) -> void:
	# Sound deliberately ABSENT (v0.6.2 grammar, Jon: hit + swing are the only combat noises; the
	# visual tell carries the telegraph). $Windup stays in the scene per the keep-code rule.
	# White flash is a BLINK, not a hold (Jon v0.6.1: the held flash read as "too much"): one sharp
	# pulse at windup start — up to the peak, straight back to 0 — while the held COIL below carries
	# the sustained plant. One chained tween in the shader-flash slot; it always ends at 0.
	if _flash_shader_tween != null and _flash_shader_tween.is_valid():
		_flash_shader_tween.kill()
	_flash_shader_tween = create_tween()
	_flash_shader_tween.tween_property(_sprite.material, "shader_parameter/flash_amount",
			windup_blink_peak, windup_blink_in_sec)
	_flash_shader_tween.tween_property(_sprite.material, "shader_parameter/flash_amount",
			0.0, windup_blink_out_sec)
	# Coil: SNAP ~5px away from the target in ~30ms, then HOLD for the rest of the windup — a
	# sustained displacement reads as a coil where a slow 4px drift over 0.25s reads as creep. NO
	# return step here: the RELEASE (_bowstring at resolution) springs back through centre. Shares the
	# _shake_tween slot with the bowstring (they can't co-occur — the monster is busy through the
	# windup) so glide_to's kill of _shake_tween pre-empts this pose exactly as it pre-empts a lunge —
	# the same documented arbitration.
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	var unit := Vector2(dir_away.x, dir_away.y).normalized() if dir_away != Vector2i.ZERO else Vector2(-1, 0)
	# Base from TILE CENTRE, not position: the settle-at-centre invariant (see _bowstring). The
	# monster is stationary through the windup (busy record), so tile-centre is exact.
	var base := WorldGrid.tile_to_world(tile)
	var snap_sec := 0.03
	_shake_tween = create_tween()
	_shake_tween.tween_property(self, "position", base + unit * 5.0, snap_sec)
	var hold_remaining := maxf(hold_sec - snap_sec, 0.0)
	if hold_remaining > 0.0:
		_shake_tween.tween_interval(hold_remaining)


## Whiff feedback (§2.3.4): the wind-up resolved against an empty/vacated tile — the SAME bowstring
## lunge the landed strike uses, plus a distinct swing-into-nothing sound (no target flash, no hit).
## On a whiff the swing STAYS audible: the v0.6.0 audio-trim rule suppresses the attacker's sound only
## on a LANDED hit, so "the attack missed" reads audibly separate from "it landed" under deterministic damage.
func play_whiff(dir: Vector2i) -> void:
	_bowstring(dir)
	_whiff_audio.play()


## Fizzle cue for a DODGED ranged spell (v0.19.12, review #1): the swing-into-nothing SOUND only — NO melee
## lunge (a ground-target smite has no swing). Gives a dodged smite a distinct audible outcome (§2.3.4) so it
## isn't silent-but-for-a-popup. Played on the caster on every peer from the whiffed "smite" attack event.
func play_cast_fizzle() -> void:
	_whiff_audio.play()


## Spell-cast telegraph (§2.3.4, v0.19.8; generalized v0.19.10): a pulsing sparkle in `symbol_color` over the
## caster's head for the whole cast window `hold_sec`, so "I'm channeling a spell" is legible on-screen — HELD
## (unlike the transient +N popup) and distinct from the WHITE attack wind-up. GREEN = heal, orange-red = smite
## (the caller passes the colour per spell). Driven on every peer from the heal_cast / smite_cast event. Drawn
## as a Polygon2D star (font-independent — no glyph to miss) above the name label. Cleared on re-cast, at cast
## end (the timer), and with the node on death (the engine drops the timer's connection to a freed node).
func play_spell_cast(hold_sec: float, symbol_color: Color) -> void:
	_clear_cast_fx()
	var star := Polygon2D.new()
	# 4-pointed sparkle (outer r≈7, inner r≈1.8) centred on the node origin.
	star.polygon = PackedVector2Array([
		Vector2(7, 0), Vector2(1.8, 1.8), Vector2(0, 7), Vector2(-1.8, 1.8),
		Vector2(-7, 0), Vector2(-1.8, -1.8), Vector2(0, -7), Vector2(1.8, -1.8)])
	star.color = symbol_color
	star.position = Vector2(0, -50)  # above the name label (which sits ~ -38..-18)
	add_child(star)
	_cast_fx = star
	# Pulse (scale + a soft alpha throb) for the whole channel; _clear_cast_fx removes it at hold_sec.
	_cast_fx_tween = create_tween().set_loops()
	_cast_fx_tween.tween_property(star, "scale", Vector2(1.3, 1.3), 0.35).from(Vector2(0.85, 0.85))
	_cast_fx_tween.parallel().tween_property(star, "modulate:a", 0.55, 0.35).from(1.0)
	_cast_fx_tween.tween_property(star, "scale", Vector2(0.85, 0.85), 0.35)
	_cast_fx_tween.parallel().tween_property(star, "modulate:a", 1.0, 0.35)
	if hold_sec > 0.0:
		get_tree().create_timer(hold_sec).timeout.connect(_clear_cast_fx)


# ── Private methods ───────────────────────────────────────────────────────────


## Remove the heal-cast overhead symbol + its pulse tween (v0.19.8). Idempotent — safe on re-cast, at cast end
## (the timer), or defensively; a null/freed mark or tween is a no-op.
func _clear_cast_fx() -> void:
	if _cast_fx_tween != null and _cast_fx_tween.is_valid():
		_cast_fx_tween.kill()
	_cast_fx_tween = null
	if _cast_fx != null and is_instance_valid(_cast_fx):
		_cast_fx.queue_free()
	_cast_fx = null

## Release override for the coiled tell (v0.6.1). Both strike paths route here — play_attack (a
## landed windup) and play_whiff (a resolved windup against empty ground) — so this is the SINGLE
## site where the windup RESOLVES, and it does the one thing the base can't: cut the white flash to
## 0 (~50ms, not a fade-during-hold) — the release IS the flash ending. super() then runs Jeff's
## bowstring, which as of v0.9.2 always bases on TILE CENTRE itself (the settle-at-centre invariant
## now lives in Entity._bowstring, so this override no longer re-bases): the lunge springs FROM the
## coiled position THROUGH centre toward the target and settles at that centre. The monster is
## stationary through the windup (busy record), so tile-centre is the exact truth even mid-coil.
func _bowstring(dir: Vector2i) -> void:
	_set_flash(0.0, 0.05)
	super(dir)


## Drive the Sprite2D's white-flash shader param to `amount` over `duration_sec` on its own tween
## slot. TRUE white (mix toward vec3(1.0)) that modulate can't produce on a coloured sprite — the
## §2.3.4 tell must be unmistakable. The material is scene-assigned + resource_local_to_scene, so
## this tweens THIS monster's own copy. A missing material is a scene-config bug: warn, don't crash.
func _set_flash(amount: float, duration_sec: float) -> void:
	var mat := _sprite.material as ShaderMaterial
	if mat == null:
		push_warning("[Monster] entity %d sprite has no ShaderMaterial — white tell not rendered" % entity_id)
		return
	if _flash_shader_tween != null and _flash_shader_tween.is_valid():
		_flash_shader_tween.kill()
	_flash_shader_tween = create_tween()
	_flash_shader_tween.tween_property(mat, "shader_parameter/flash_amount", amount, duration_sec)
