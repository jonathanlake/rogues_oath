extends Node

## Local-player-only input sampler for committed movement. It samples the four move actions into
## an 8-way direction and, when a fresh direction is available, emits move_requested(dir) — the
## parent player turns that into the local commit-sent cue plus a "glide_to" intent. It NEVER
## moves anything and NEVER predicts the outcome: the glide begins only when the server's event
## comes back (DESIGN §2.2.8), which the parent surfaces here via set_blocked / on_accepted /
## on_rejected. Enabled only on the local player's node (the parent sets `enabled`).
##
## It is a conservative state machine (host is truth): after submitting it awaits the verdict
## before sampling again, and it never samples while its player is gliding. It can therefore
## never submit a second step mid-glide — the referee's "already moving" reject is a backstop,
## not the primary guard. This upholds the Commitment Rule at the input layer: no input path
## cancels, interrupts, or redirects a glide in flight.

# ── Signals ──────────────────────────────────────────────────────────────────

## A fresh committed direction was sampled. Components in {-1,0,1}, non-zero. The parent wires it.
signal move_requested(dir: Vector2i)

# ── Exports ───────────────────────────────────────────────────────────────────

## Safety clear for the AWAITING latch (seconds). Verdicts arrive over reliable RPC, so this
## should never fire in practice; it exists so a dropped/never-answered verdict can't wedge input
## forever. A late verdict still renders (glide_to catches up), so clearing early is harmless.
@export var verdict_timeout_sec: float = 2.0

## After a REJECT, a still-held key waits this long before resubmitting (seconds). Without it a
## zero-RTT host would bonk ~60×/sec on a wall. A FRESH press bypasses the wait (responsive to
## deliberate re-taps); only auto-repeat from a held key is throttled.
@export var held_retry_cooldown_sec: float = 0.25

# ── Public state ──────────────────────────────────────────────────────────────

## Set by the parent: true only on the local player's node. A remote/disabled MoveInput never
## samples (it still exists in the scene so the node graph is uniform on every peer).
var enabled: bool = false

# ── Private vars ──────────────────────────────────────────────────────────────

# The four move actions, sampled together into an 8-way vector.
const _ACTIONS := ["move_right", "move_left", "move_down", "move_up"]

enum State { IDLE, AWAITING, COOLDOWN }
var _state: State = State.IDLE
# True while the parent's player is gliding (set from glide_started/glide_finished). Sampling is
# suppressed until the OWN tween finishes — this is the "GLIDING" state, tracked as a flag so the
# host may consider the peer idle ~RTT before the client stops animating without desyncing input.
var _blocked: bool = false
# Time accumulators for the two timed states.
var _await_elapsed: float = 0.0
var _cooldown_elapsed: float = 0.0


func _process(delta: float) -> void:
	# Not the local player: never sample.
	if not enabled:
		return
	# Gliding: the Commitment Rule guard — no sampling until our own glide finishes.
	if _blocked:
		return
	# Chat gate: while a text field owns focus the player is typing, not moving. The focused
	# control IS the source of truth (game_log.gd documents this seam) — no global is_chatting flag.
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return

	match _state:
		State.AWAITING:
			# Waiting on the host's verdict; don't sample. Safety-clear only.
			_await_elapsed += delta
			if _await_elapsed >= verdict_timeout_sec:
				_state = State.IDLE
				_await_elapsed = 0.0
			return
		State.COOLDOWN:
			# Post-reject throttle. A fresh press bypasses it immediately; otherwise wait out the
			# cooldown, then fall through and resample (a still-held key resubmits naturally).
			if _fresh_press():
				_state = State.IDLE
			else:
				_cooldown_elapsed += delta
				if _cooldown_elapsed < held_retry_cooldown_sec:
					return
				_state = State.IDLE
				_cooldown_elapsed = 0.0

	# IDLE (or a just-elapsed cooldown): sample and, on a non-zero direction, submit and latch.
	var dir := _sample_dir()
	if dir != Vector2i.ZERO:
		move_requested.emit(dir)
		_state = State.AWAITING
		_await_elapsed = 0.0


# ── Public methods ────────────────────────────────────────────────────────────

## Called by the parent on glide_started(true) / glide_finished(false). While blocked, sampling
## is suppressed — the local glide plays to completion before the next step can be sampled.
func set_blocked(blocked: bool) -> void:
	_blocked = blocked


## The host accepted our intent (parent relays it from its own glide event). Clear the AWAITING
## latch; blocking for the glide itself is handled by set_blocked from glide_started.
func on_accepted() -> void:
	if _state == State.AWAITING:
		_state = State.IDLE
	_await_elapsed = 0.0


## The host rejected our intent (parent relays it from its own reject). Enter the post-reject
## cooldown so a held key doesn't machine-gun retries; a fresh press bypasses it.
func on_rejected() -> void:
	_state = State.COOLDOWN
	_cooldown_elapsed = 0.0


# ── Private methods ───────────────────────────────────────────────────────────

## Sample the four actions into an 8-way Vector2i (diagonals when two axes are held together).
func _sample_dir() -> Vector2i:
	var dir := Vector2i.ZERO
	if Input.is_action_pressed("move_right"):
		dir.x += 1
	if Input.is_action_pressed("move_left"):
		dir.x -= 1
	if Input.is_action_pressed("move_down"):
		dir.y += 1
	if Input.is_action_pressed("move_up"):
		dir.y -= 1
	return dir


## True if any move action was just pressed THIS frame — a deliberate tap, which bypasses the
## post-reject cooldown (auto-repeat from a held key does not).
func _fresh_press() -> bool:
	for action in _ACTIONS:
		if Input.is_action_just_pressed(action):
			return true
	return false
