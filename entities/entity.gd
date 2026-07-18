class_name Entity
extends Node2D

## Abstract parent for the two avatar kinds (Player, Monster) — NEVER instantiated directly.
## It is a PARTIAL contract (GDScript's substitute for an interface): identity + shared
## presentation only, not a full LSP base. Subclass-specific surfaces (Player's input latch,
## Monster's wind-up cues) are reached via explicit casts at call sites — those casts are
## deliberate, not cruft to remove.
##
## What lives here: the entity id + display name + tile identity the referees key on, and the
## committed-movement playback shared verbatim by both kinds — glide_to and its tween guards,
## the flash/shake cue primitives, attacker/target combat feedback, and the HP readout.
##
## Authority note: max_hp / attack_damage on subclasses are AUTHORED-CONFIG reads, host-side
## (the referee seeds HP once at spawn; display seeds labels). CombatReferee's _hp is the sole
## live-value authority — nothing on an Entity node is ever adjudication truth.
##
## Its @onready refs require the shared child node names (Sprite2D/NameLabel/HpLabel/Attack/Hit),
## which both existing scenes provide. A future entity kind without them (decorations etc.)
## generalizes then, not preemptively.

# ── Signals ──────────────────────────────────────────────────────────────────

## Emitted the instant a glide begins (before the tween runs). Player wires it to block its own
## MoveInput so no new step is sampled mid-glide (the Commitment Rule at the input layer); the
## host wires Monster's to nothing — kept for shape parity.
signal glide_started
## Emitted when a glide's tween finishes naturally (a killed catch-up tween does NOT emit it).
## Player wires it to unblock MoveInput; the host wires Monster's to the MonsterBrain so it
## re-plans at its OWN step boundary (never a global tick).
signal glide_finished

## This tier's per-step glide time, read server-side when the referee stamps a glide's duration.
## Player: the scene assigns speed_normal.tres (the export binds by property name through
## inheritance, so player.tscn's assignment lands here); a designer swaps the tier by pointing
## this at a different resources/speed_tiers/*.tres. Monster: derived from monster_type in
## _ready, overwriting the null export (before the brain can ever submit a step).
@export var glide_speed: GlideSpeed = null

# ── Public state ──────────────────────────────────────────────────────────────

## Entity id in the referees' ONE occupancy/HP space (plan decision 5): positive = a player's
## peer id, negative = a host-assigned monster id. Set PRE-tree by Main's spawn_function on
## every peer, so _ready and the referees' container enter hooks can read it.
var entity_id: int = 0

## The one name surface per entity, read HOST-side by the referees when they compose combat
## events/log lines. TIMING INVARIANT: assigned by each subclass at _ready (Player from
## player_name, Monster from monster_type with a "Monster" fallback) and first legitimately
## read at attack time — pre-_ready referee code (the container enter hooks) must key on
## entity_id / monster_type, NEVER on this name.
var display_name: String = ""

## Logical grid position. Presentation metadata mirrored on every peer (set at spawn, then at
## glide START from the broadcast `to`). NOT the adjudication truth — the host referee's own
## occupancy bookkeeping is authoritative; this is only what the avatar believes it stands on.
var tile: Vector2i

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _name_label: Label = $NameLabel
# Presentation-only HP readout under the feet, fed by attack events' hp_after via set_hp_display.
# The nameplate stays name-only; the authoritative HP lives in the host's CombatReferee.
@onready var _hp_label: Label = $HpLabel
# Combat feedback (§2.3.4). Placeholder assets: pitch-shifted reuses of the two existing wavs
# (attack = commit_sent low, hit = bonk high) — flagged placeholder, real SFX arrive later.
@onready var _attack_audio: AudioStreamPlayer = $Attack
@onready var _hit_audio: AudioStreamPlayer = $Hit

# The glide's position tween, held so a newer server event can kill it and catch up (never to
# cancel a commitment — see glide_to). The flash/shake tweens are tracked separately so a real
# glide can pre-empt a lingering cue.
var _glide_tween: Tween = null
var _shake_tween: Tween = null
# The modulate flash tween (commit-sent / hurt / windup cues), held so overlapping cues don't stack.
var _flash_tween: Tween = null


func _ready() -> void:
	# Contract guard: the shared presentation requires these exact child names. An @onready miss
	# resolves silently to null and only explodes at first use — name the missing node NOW instead.
	for missing in [["Sprite2D", _sprite], ["NameLabel", _name_label], ["HpLabel", _hp_label],
			["Attack", _attack_audio], ["Hit", _hit_audio]]:
		if missing[1] == null:
			push_error("[Entity] %s (entity %d) scene is missing required child '%s'" % [
				name, entity_id, missing[0]])


# ── Public methods ────────────────────────────────────────────────────────────

## Hostility test (DESIGN §2.2.6), read HOST-side by the referees. Subclasses MUST override
## (Player: hostile to Monsters; Monster: hostile to Players; the debug all_hostile flag ORs on
## top in both). Loud, not silent, if a future subclass forgets.
func is_hostile_to(_other: Node) -> bool:
	push_error("subclass must override is_hostile_to")
	return false


## Play back a server-accepted glide (called on every peer by Main from the broadcast event).
## Idempotent-late-safe: it always kills any running tween and tweens from the CURRENT rendered
## position to the new target, so a verdict arriving after the client's safety-clear still renders
## as a catch-up glide rather than being ignored (ignoring would desync position permanently).
## This is the ONLY thing that starts a glide — there is no cancel/interrupt entry point.
func glide_to(to_tile: Vector2i, duration_sec: float) -> void:
	# A newer truth supersedes any in-flight visuals: kill the old glide (killed => no
	# glide_finished) and any lingering shake so the tween starts from a clean position base.
	if _glide_tween != null and _glide_tween.is_valid():
		_glide_tween.kill()
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()

	# tile updates at glide START (presentation metadata; the referee's occupancy is the truth).
	tile = to_tile
	glide_started.emit()
	# Subclass hook, at exactly this point in the sequence (after glide_started, before the tween)
	# — Player relays the accept to its own input sampler here.
	_on_glide_accepted(to_tile)

	var target := WorldGrid.tile_to_world(to_tile)
	_glide_tween = create_tween()
	_glide_tween.tween_property(self, "position", target, duration_sec).set_trans(Tween.TRANS_LINEAR)
	_glide_tween.finished.connect(_on_glide_finished)


## Attacker feedback for a landed strike (§2.3.4), played on every peer from the referee's `attack`
## event: a short lunge TOWARD the target + the swing sound. Distinct from any input ack cue —
## this is a committed strike resolving. `dir` is the 8-way step toward the victim so the wobble
## reads directional; Vector2i.ZERO falls back to the plain horizontal shake.
func play_attack(dir: Vector2i) -> void:
	_shake(dir)
	_attack_audio.play()


## Target feedback for taking a hit (§2.3.4), played on every peer from the referee's `attack`
## event: a distinct red flash + the impact sound. Never confusable with the attacker's swing or a
## rejected commit — this is "I got hit."
func play_hurt() -> void:
	_flash(Color(1.0, 0.3, 0.3))
	_hit_audio.play()


## Update the under-feet HP readout ("hp/max") from an `attack` event's hp_after. Presentation
## only — the authoritative HP lives in the host's CombatReferee; this node just renders what the
## event carries. max rides the event so no peer needs to query the referee.
func set_hp_display(hp: int, max_value: int) -> void:
	_hp_label.text = "%d/%d" % [hp, max_value]


# ── Private methods ───────────────────────────────────────────────────────────

## Protected ordering hook, called by glide_to after glide_started.emit and before the tween is
## built. Empty here; Player overrides it to relay the accept — with the destination — to its own
## MoveInput sampler at exactly the point the relay has always sat.
func _on_glide_accepted(_to_tile: Vector2i) -> void:
	pass


func _on_glide_finished() -> void:
	glide_finished.emit()


## Modulate flash to `color`, tweening back to white. Held in _flash_tween so overlapping cues
## (bonk over commit, hurt over windup) cleanly replace rather than stack.
func _flash(color: Color) -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	modulate = color
	_flash_tween = create_tween()
	_flash_tween.tween_property(self, "modulate", Color.WHITE, 0.18)


## A quick 2px position wobble that returns exactly to where it started. If a real glide pre-empts
## it, glide_to kills this tween and tweens from wherever the shake left the node — self-correcting.
## `dir` (an 8-way step) makes the wobble lunge TOWARD the struck tile for an attack; the default
## Vector2i.ZERO is the symmetric horizontal jitter used by the rejection bonk.
func _shake(dir: Vector2i = Vector2i.ZERO) -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	var base := position
	# A directional lunge for an attack (toward → back), or the two-sided jitter for a bonk.
	var offset := Vector2(dir.x, dir.y).normalized() * 3.0 if dir != Vector2i.ZERO else Vector2(2, 0)
	_shake_tween = create_tween()
	_shake_tween.tween_property(self, "position", base + offset, 0.03)
	if dir == Vector2i.ZERO:
		_shake_tween.tween_property(self, "position", base - offset, 0.03)
	_shake_tween.tween_property(self, "position", base, 0.03)
