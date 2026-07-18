class_name Monster
extends Node2D

## A monster avatar. Holds identity (entity_id, monster_type), shows a sprite + name label, and
## PRESENTS committed movement — it plays back the server's glide events exactly like a Player. It
## never adjudicates: the host's MoveReferee owns occupancy and outcomes, and the host-only
## MonsterBrain child decides this monster's intents. The node graph is identical on every peer
## (uniform replication); only the host activates the brain.
##
## Entity id (DESIGN §2.5, plan decision 5): monsters carry a host-assigned NEGATIVE id, so the
## referee's one occupancy space distinguishes them from players (positive peer ids) with no
## overlap. The id rides the replicated spawn config, so every peer names this node str(entity_id)
## and resolves glide events to it the same way.
##
## Movement flow mirrors Player.glide_to: at spawn the node sits at its tile; when the host
## broadcasts an accepted glide_to for this entity, Main calls glide_to() here on every peer and
## the LINEAR tween runs. Per the Commitment Rule there is no cancel path — glide_to only ever
## kills a tween to catch up to newer server truth, never to abort a committed step.

const _TILE_PX := 32

# ── Signals ──────────────────────────────────────────────────────────────────

## Emitted the instant a glide begins (before the tween runs). Mirrors Player.glide_started —
## kept for shape parity and any future input/AI blocking wired by the parent.
signal glide_started
## Emitted when a glide's tween finishes naturally (a killed catch-up tween does NOT emit it). The
## host wires this to the MonsterBrain so it re-plans at its OWN step boundary (never a global tick).
signal glide_finished

# ── Public state ──────────────────────────────────────────────────────────────

## Host-assigned negative entity id, set by Main's spawn_function (from the replicated spawn
## config) before this node enters the tree, so _ready and the referee's seed hook read it on
## every peer.
var entity_id: int = 0

## This monster's authored template — display name, sprite cell, stats, speed tier. Set at spawn
## from the replicated type PATH (each peer loads the same .tres); never streamed as a resource.
var monster_type: MonsterType = null

## Movement speed tier, mirrored to a plain field so the referee reads mover.glide_speed uniformly
## for players and monsters. Derived from monster_type.glide_speed at _ready (before the brain can
## ever submit a step, which happens post-activation).
var glide_speed: GlideSpeed = null

## Logical grid position. Presentation metadata mirrored on every peer (set at spawn, then at glide
## START from the broadcast `to`). NOT adjudication truth — the host referee's occupancy is.
var tile: Vector2i

## Display name surface, read HOST-side by the referees when they compose combat events/log lines
## (Player exposes player_name; this is the monster's mirror so the referee reads ONE name surface
## per entity). Computed from the authored type, with a safe fallback if the type is missing.
var display_name: String:
	get:
		return monster_type.display_name if monster_type != null else "Monster"

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _name_label: Label = $NameLabel
# Presentation-only HP readout under the feet, fed by attack events' hp_after via set_hp_display.
# The nameplate stays name-only; the authoritative HP lives in the host's CombatReferee.
@onready var _hp_label: Label = $HpLabel
@onready var _brain := $MonsterBrain
# Combat feedback (§2.3.4). Placeholder assets: pitch-shifted reuses of the two existing wavs
# (attack = commit_sent low, hit = bonk high, windup = bonk mid, whiff = commit_sent very low) —
# flagged placeholder, real SFX arrive later.
@onready var _attack_audio: AudioStreamPlayer = $Attack
@onready var _hit_audio: AudioStreamPlayer = $Hit
@onready var _windup_audio: AudioStreamPlayer = $Windup
@onready var _whiff_audio: AudioStreamPlayer = $Whiff

# The glide's position tween, held so a newer server event can kill it and catch up (never to
# cancel a commitment — see glide_to). The flash/shake tweens are tracked separately so a real
# glide can pre-empt a lingering cue, mirroring Player.
var _glide_tween: Tween = null
var _shake_tween: Tween = null
var _flash_tween: Tween = null


func _ready() -> void:
	# monster_type is set at spawn before the node enters the tree, so it's readable here on
	# every peer. A missing type is a spawn-config bug; warn rather than crash on null access.
	if monster_type == null:
		push_warning("[Monster] entity %d spawned with no MonsterType — using bare defaults" % entity_id)
		return
	glide_speed = monster_type.glide_speed
	var cell := monster_type.atlas_coords
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(cell.x * _TILE_PX, cell.y * _TILE_PX, _TILE_PX, _TILE_PX)
	# Nameplate is name-only; the HP readout rides its own label under the feet, seeded from the
	# authored max locally (max_hp is known everywhere). Chunk 2 (combat referee) drives updates
	# from attack events. Full HP at spawn.
	_name_label.text = monster_type.display_name
	_hp_label.text = "%d/%d" % [monster_type.max_hp, monster_type.max_hp]


# ── Public methods ────────────────────────────────────────────────────────────

## Host-only: hand this monster's brain the movement + combat referees and switch it on. Called by
## Main's monster spawn path INSIDE its is_server() guard (component pattern — the parent wires the
## child). The monster owns the brain<->boundary handshake so the brain never reaches up to its
## parent: it connects its OWN glide_finished to the brain's boundary hook here. Inert on clients.
func activate_brain(referee: Node, combat: Node) -> void:
	glide_finished.connect(_brain.on_boundary)
	_brain.activate(referee, combat, entity_id)


## Hostility test (DESIGN §2.2.6, plan decision 6), read HOST-side. A monster is hostile to any
## player and never to another monster; the debug-only GameManager.all_hostile flag ORs on top so
## the AoO/combat wiring can be demoed with the harness. Symmetric with Player.is_hostile_to.
func is_hostile_to(other: Node) -> bool:
	if GameManager.all_hostile and other != self:
		return true
	return other is Player


## Play back a server-accepted glide (called on every peer by Main from the broadcast event).
## Idempotent-late-safe: always kills any running tween and tweens from the CURRENT rendered
## position to the new target, so a verdict arriving after a catch-up still renders as a glide
## rather than desyncing. The ONLY thing that starts a glide — no cancel/interrupt entry point.
func glide_to(to_tile: Vector2i, duration_sec: float) -> void:
	if _glide_tween != null and _glide_tween.is_valid():
		_glide_tween.kill()
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()

	# tile updates at glide START (presentation metadata; the referee's occupancy is the truth).
	tile = to_tile
	glide_started.emit()

	var target := WorldGrid.tile_to_world(to_tile)
	_glide_tween = create_tween()
	_glide_tween.tween_property(self, "position", target, duration_sec).set_trans(Tween.TRANS_LINEAR)
	_glide_tween.finished.connect(_on_glide_finished)


## Attacker feedback for a landed strike (§2.3.4), played on every peer from the referee's `attack`
## event: a short lunge TOWARD the target + the swing sound. `dir` is the 8-way step toward the
## victim (Vector2i.ZERO = plain shake).
func play_attack(dir: Vector2i) -> void:
	_shake(dir)
	_attack_audio.play()


## Target feedback for taking a hit (§2.3.4): red flash + impact sound. Played on every peer when
## a player bumps this monster.
func play_hurt() -> void:
	_flash(Color(1.0, 0.3, 0.3))
	_hit_audio.play()


## Telegraph feedback (§2.3.4) for a wind-up starting: a distinct yellow flash + telegraph sound,
## played on every peer from the `windup` event. This is the "slow telegraph" tell (DESIGN §2.1)
## that gives a target the window to glide off the committed tile before resolution.
func play_windup() -> void:
	_flash(Color(1.5, 1.5, 0.4))
	_windup_audio.play()


## Whiff feedback (§2.3.4): the wind-up resolved against an empty/vacated tile — a distinct
## swing-into-nothing sound (no target flash, no hit). Keeps "the attack missed" audibly separate
## from "it landed" under deterministic damage.
func play_whiff(dir: Vector2i) -> void:
	_shake(dir)
	_whiff_audio.play()


## Update the under-feet HP readout ("hp/max") from an `attack` event's hp_after. Presentation
## only — the host's CombatReferee owns the live value; max rides the event so no peer queries it.
func set_hp_display(hp: int, max_value: int) -> void:
	_hp_label.text = "%d/%d" % [hp, max_value]


# ── Private methods ───────────────────────────────────────────────────────────

func _on_glide_finished() -> void:
	glide_finished.emit()


## Modulate flash to `color`, tweening back to white. Held in _flash_tween so overlapping cues
## replace rather than stack. Mirrors Player._flash — used by chunk 2's damage feedback.
func _flash(color: Color) -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	modulate = color
	_flash_tween = create_tween()
	_flash_tween.tween_property(self, "modulate", Color.WHITE, 0.18)


## A quick 2px position wobble that returns exactly to where it started; a real glide pre-empts it
## (glide_to kills the tween). Mirrors Player._shake — `dir` (an 8-way step) lunges the wobble
## TOWARD the struck tile for an attack; the default Vector2i.ZERO is a symmetric horizontal jitter.
func _shake(dir: Vector2i = Vector2i.ZERO) -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	var base := position
	var offset := Vector2(dir.x, dir.y).normalized() * 3.0 if dir != Vector2i.ZERO else Vector2(2, 0)
	_shake_tween = create_tween()
	_shake_tween.tween_property(self, "position", base + offset, 0.03)
	if dir == Vector2i.ZERO:
		_shake_tween.tween_property(self, "position", base - offset, 0.03)
	_shake_tween.tween_property(self, "position", base, 0.03)
