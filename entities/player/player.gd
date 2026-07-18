class_name Player
extends Node2D

## A player avatar. Holds identity (peer_id, player_name, spawn_index), shows a sprite + name
## label, and PRESENTS committed movement — it plays back the server's glide events and fires the
## §2.2.8 feedback cues. It never adjudicates: the host's MoveReferee owns occupancy and outcomes.
##
## Movement flow, per peer:
##  - The LOCAL player's MoveInput (keys/stick, or its click-to-move target driver) emits
##    move_requested(dir, fresh); this node reacts with play_commit_sent() on FRESH input only
##    (the outcome-neutral ack) and submits a "glide_to" intent either way.
##  - When the server broadcasts the accepted event, Main calls glide_to() on THIS node — on
##    every peer, including the mover's own — and the glide begins. There is no client prediction
##    and, per the Commitment Rule, no cancel path: glide_to only ever kills a tween to catch up
##    to a newer server truth, never to abort a committed step.
##  - A reject reaches only the sender; Main calls play_bonk() on the sender's own player.

const _TILE_PX := 32

## Distinct sprite tiles (col, row) into rogues.png, one per spawn slot, so players are
## told apart at a glance. Indexed by spawn_index (wraps if there are more players than tiles).
const _SPRITE_TILES: Array[Vector2i] = [
	Vector2i(3, 0),  # rogue
	Vector2i(0, 1),  # knight
	Vector2i(0, 4),  # female wizard
	Vector2i(0, 3),  # male barbarian
	Vector2i(1, 2),  # priest
	Vector2i(2, 0),  # ranger
]

# ── Signals ──────────────────────────────────────────────────────────────────

## Emitted the instant a glide begins (before the tween runs). The node wires it to block its own
## MoveInput so no new step is sampled mid-glide (the Commitment Rule at the input layer).
signal glide_started
## Emitted when a glide's tween finishes naturally (a killed catch-up tween does NOT emit it).
## Wired to unblock MoveInput so a still-held key naturally submits the next step.
signal glide_finished

## This tier's per-step glide time, read server-side when the referee stamps a glide's
## duration (chunk 2). The scene assigns speed_normal.tres; a designer swaps the tier by
## pointing this at a different resources/speed_tiers/*.tres.
@export var glide_speed: GlideSpeed

## Starting / maximum hit points (RF3-scaled "warrior" placeholder — DESIGN §2.3 amendment).
## Seeds this player's HP in the host's CombatReferee on spawn (read host-side from the node) and
## the nameplate readout; the referee owns the live value thereafter.
@export var max_hp: int = 20

## Damage (HP) this player deals per landed melee attack — a bump (move into a hostile) or an
## attack of opportunity. Deterministic (no to-hit roll, DESIGN §2.3 amendment). Read HOST-side by
## the referees when they stamp this attacker's damage; never trusted from the wire.
@export var melee_damage: int = 5

## Swing commit duration (seconds): after a bump lands (instantly), the attacker is BUSY for this
## long — the Commitment Rule tail (decision 2). The referee stamps it into the from==to busy
## record; the local attacker mirrors it as a blocked-input window (commit_in_place).
@export var attack_duration_sec: float = 0.5

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _name_label: Label = $NameLabel
@onready var _move_input := $MoveInput
@onready var _path_marker: Node2D = $PathMarker
@onready var _commit_audio: AudioStreamPlayer = $CommitSent
@onready var _bonk_audio: AudioStreamPlayer = $Bonk
# Combat feedback (§2.3.4). Placeholder assets: pitch-shifted reuses of the two existing wavs
# (attack = commit_sent low, hit = bonk high) — flagged placeholder, real SFX arrive later.
@onready var _attack_audio: AudioStreamPlayer = $Attack
@onready var _hit_audio: AudioStreamPlayer = $Hit

# Assigned by main.gd's spawn_function (from the replicated spawn config) before this
# node enters the tree, so _ready can read them on every peer.
var peer_id: int = 0
var player_name: String = ""
var spawn_index: int = 0

## Logical grid position. Presentation metadata mirrored on every peer (set at spawn, then at
## glide START from the broadcast `to`). NOT the adjudication truth — the host referee's own
## bookkeeping is authoritative; this is only what the avatar believes it stands on.
var tile: Vector2i

# The glide's position tween, held so a newer server event can kill it and catch up (never to
# cancel a commitment — see glide_to). The bonk shake also animates position, tracked separately
# so a real glide can pre-empt a lingering shake.
var _glide_tween: Tween = null
var _shake_tween: Tween = null
# The modulate flash tween (commit-sent / bonk), held so overlapping cues don't stack.
var _flash_tween: Tween = null


func _ready() -> void:
	var sprite_tile := _SPRITE_TILES[spawn_index % _SPRITE_TILES.size()]
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(sprite_tile.x * _TILE_PX, sprite_tile.y * _TILE_PX, _TILE_PX, _TILE_PX)
	# Nameplate shows the HP readout ("NAME 20/20"). max_hp is locally known everywhere (an @export),
	# so this seeds correctly on every peer with no query; the combat referee's attack events drive
	# the live updates via set_hp_display. Full HP at spawn.
	_name_label.text = "%s %d/%d" % [player_name, max_hp, max_hp]

	# MoveInput samples only on the local player's node. Every peer instantiates the child (uniform
	# node graph) but only ours is enabled.
	_move_input.enabled = (peer_id == multiplayer.get_unique_id())
	_move_input.move_requested.connect(_on_move_requested)
	# Seed the sampler's planning tile with the server-derived spawn tile (set by main.gd's
	# spawn_function before this node entered the tree); on_accepted advances it thereafter.
	_move_input.set_current_tile(tile)
	# The node owns the glide<->input handshake: it blocks its own sampler for the whole glide.
	glide_started.connect(func(): _move_input.set_blocked(true))
	glide_finished.connect(func(): _move_input.set_blocked(false))
	# Path-marker wiring, local player only — only the local sampler ever emits target signals,
	# and only the clicker should see their own marker.
	if _move_input.enabled:
		_move_input.path_target_set.connect(_on_path_target_set)
		_move_input.path_target_cleared.connect(func(): _path_marker.visible = false)


# ── Public methods ────────────────────────────────────────────────────────────

## Hostility test (DESIGN §2.2.6, plan decision 6), read HOST-side by the referee/combat. A player
## is hostile to any monster and NEVER to another player. The debug-only GameManager.all_hostile
## flag ORs on top (every entity hostile to every other, itself excepted) so the AoO/combat wiring
## can be demoed two-instance with `hostile=1`. Symmetric with Monster.is_hostile_to.
func is_hostile_to(other: Node) -> bool:
	if GameManager.all_hostile and other != self:
		return true
	return other is Monster


## Play back a server-accepted glide (called on every peer by Main from the broadcast event).
## Idempotent-late-safe: it always kills any running tween and tweens from the CURRENT rendered
## position to the new target, so a verdict arriving after the client's safety-clear still renders
## as a catch-up glide rather than being ignored (ignoring would desync position permanently).
## This is the ONLY thing that starts a glide — there is no cancel/interrupt entry point.
func glide_to(to_tile: Vector2i, duration_sec: float) -> void:
	# A newer truth supersedes any in-flight visuals: kill the old glide (killed => no
	# glide_finished) and any lingering bonk shake so the tween starts from a clean position base.
	if _glide_tween != null and _glide_tween.is_valid():
		_glide_tween.kill()
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()

	# tile updates at glide START (presentation metadata; the referee's occupancy is the truth).
	tile = to_tile
	glide_started.emit()
	# Relay the accept — with the destination — to our own sampler (local player only) so it
	# leaves the AWAITING latch and advances its planning tile for the next path recompute.
	if _move_input.enabled:
		_move_input.on_accepted(to_tile)

	var target := WorldGrid.tile_to_world(to_tile)
	_glide_tween = create_tween()
	_glide_tween.tween_property(self, "position", target, duration_sec).set_trans(Tween.TRANS_LINEAR)
	_glide_tween.finished.connect(_on_glide_finished)


## Outcome-neutral input ack (§2.2.8): a brief bright flash + tick the instant we SUBMIT, before
## any verdict. Local player only in practice (only our MoveInput emits move_requested). It must
## never be confusable with the glide starting or with a reject — it says only "input received".
## Fired for FRESH input only (a key/stick sample or a click) — auto-walk continuation steps are
## not new input, so they get no cue (one click, one cue, however many steps).
func play_commit_sent() -> void:
	# Debug-only trace so the cue policy is stdout-assertable by the harness (count the prints).
	if OS.is_debug_build():
		print("[peer %d] commit-sent cue" % multiplayer.get_unique_id())
	_flash(Color(1.6, 1.6, 1.6))
	_commit_audio.play()


## Attacker feedback for a landed melee (§2.3.4), played on every peer from the referee's `attack`
## event: a short shake TOWARD the target + the swing sound. Distinct from the commit-sent cue
## (that is input-received; this is a committed strike resolving). `dir` is the 8-way step toward
## the victim so the wobble reads directional; Vector2i.ZERO falls back to the plain horizontal shake.
func play_attack(dir: Vector2i) -> void:
	_shake(dir)
	_attack_audio.play()


## Target feedback for taking a hit (§2.3.4), played on every peer from the referee's `attack`
## event: a distinct red flash + the impact sound. Never confusable with the attacker's swing or a
## rejected commit — this is "I got hit."
func play_hurt() -> void:
	_flash(Color(1.0, 0.3, 0.3))
	_hit_audio.play()


## Update the nameplate HP readout ("NAME hp/max") from an `attack` event's hp_after. Presentation
## only — the authoritative HP lives in the host's CombatReferee; this node just renders what the
## event carries. max rides the event so no peer needs to query the referee.
func set_hp_display(hp: int, max_value: int) -> void:
	_name_label.text = "%s %d/%d" % [player_name, hp, max_value]


## Local attacker's BUSY mirror for a bump (decision 2), driven by the attacker's own `attack`
## event. A bump adjudicates as a `deferred` verdict (no glide_to broadcast), so unlike a glide the
## local player never receives a glide_to to clear its input latch — this does it: it mirrors
## glide_to's signal/relay shape EXACTLY, minus the position tween (the attacker never leaves its
## tile — decision 2's "no client tween"). glide_started blocks MoveInput; on_accepted clears the
## AWAITING latch (advancing nothing — the current tile); a SceneTreeTimer ends the swing window
## and unblocks. No cancel path: the swing plays to completion (the Commitment Rule at the input layer).
func commit_in_place(duration_sec: float) -> void:
	# Kill any lingering glide tween FIRST (mirrors glide_to): the previous step's visual tail can
	# outlive the server's state by ~RTT/2, and its finished callback would emit glide_finished
	# mid-swing — unblocking input early. Killed => no finished, so the swing window owns the end.
	if _glide_tween != null and _glide_tween.is_valid():
		_glide_tween.kill()
	glide_started.emit()
	if _move_input.enabled:
		_move_input.on_accepted(tile)
	get_tree().create_timer(duration_sec).timeout.connect(func(): glide_finished.emit())


## Rejection feedback (§2.3.4): a distinct red flash + a short 2px shake + the thud, all three, so
## "the host refused" is never confusable with the commit ack or with a silent no-op. Called on
## the sender's own player. A bonk only ever fires when NOT gliding (you were refused), but we
## still guard the shake against an active glide tween so the two can't fight over position.
func play_bonk() -> void:
	_flash(Color(1.0, 0.3, 0.3))
	if not (_glide_tween != null and _glide_tween.is_valid()):
		_shake()
	_bonk_audio.play()
	# Relay the reject to our own sampler (local player only) so it enters the retry cooldown.
	if _move_input.enabled:
		_move_input.on_rejected()


# ── Private methods ───────────────────────────────────────────────────────────

func _on_move_requested(dir: Vector2i, fresh: bool) -> void:
	# Instant local cue, THEN the request — the cue acknowledges input receipt, not the outcome.
	# Auto-walk continuation steps (fresh=false) skip the cue: no new input happened (§2.2.8).
	if fresh:
		play_commit_sent()
	# Vector2i survives RPC natively; the host re-derives everything from ITS origin + this dir.
	NetEvents.submit_intent("glide_to", { "dir": dir })


## A click set/replaced the walk target: cue it (a click IS fresh input — the walk's steps then
## stay silent) and plant the marker on the tile. top_level marker → global_position exclusively.
func _on_path_target_set(target_tile: Vector2i) -> void:
	play_commit_sent()
	_path_marker.global_position = WorldGrid.tile_to_world(target_tile)
	_path_marker.visible = true


func _on_glide_finished() -> void:
	glide_finished.emit()


## Modulate flash to `color`, tweening back to white. Held in _flash_tween so a bonk flash cleanly
## replaces a commit flash rather than stacking.
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
