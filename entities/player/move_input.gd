extends Node

## Local-player-only input sampler for committed movement, now with TWO input sources feeding
## one latch/submit path: (1) the four move actions sampled into an 8-way direction, and (2) a
## click-to-move target driver that recomputes a path each step and submits ONE adjacent step at
## a time. Both end in move_requested(dir, fresh) — the parent player turns that into the local
## commit-sent cue (fresh only) plus a "glide_to" intent. It NEVER moves anything and NEVER
## predicts the outcome: the glide begins only when the server's event comes back (DESIGN
## §2.2.8), which the parent surfaces here via set_blocked / on_accepted / on_rejected.
##
## The target driver lives HERE (not a sibling) because it feeds the same latch/state — a
## sibling would have to share three pieces of state through the parent. Click-to-move is
## CLIENT-SIDE convenience only (DESIGN §2.2.9): the server never sees a path or a target and
## never queues; a standing target is NOT a commitment — it may be replaced or dropped freely
## between steps; only each submitted step commits. Walk-stop and unreachable-click UX cross to
## the game log via GameEvents (the bus) — they are local-only and never touch the wire.
##
## It is a conservative state machine (host is truth): after submitting it awaits the verdict
## before sampling again, and it never submits while its player is gliding. It can therefore
## never submit a second step mid-glide — the referee's "already moving" reject is a backstop,
## not the primary guard. This upholds the Commitment Rule at the input layer: no input path
## cancels, interrupts, or redirects a glide in flight.

# ── Signals ──────────────────────────────────────────────────────────────────

## A committed direction is ready to submit. Components in {-1,0,1}, non-zero. fresh=true for a
## deliberate key/stick sample (gets the §2.2.8 commit-sent cue), false for a click-to-move
## auto-continuation step (no cue — one click, one cue, however many steps). The parent wires it.
signal move_requested(dir: Vector2i, fresh: bool)
## A click set (or replaced) the walk target. The parent shows/moves the path marker + cues.
signal path_target_set(tile: Vector2i)
## The walk target is gone — arrived, unreachable, cancelled by keys, or dropped after rejects.
## The parent hides the path marker.
signal path_target_cleared

# ── Exports ───────────────────────────────────────────────────────────────────

## Safety clear for the AWAITING latch (seconds). Verdicts arrive over reliable RPC, so this
## should never fire in practice; it exists so a dropped/never-answered verdict can't wedge input
## forever. A late verdict still renders (glide_to catches up), so clearing early is harmless.
@export var verdict_timeout_sec: float = 2.0

## After a REJECT, a still-held key waits this long before resubmitting (seconds). Without it a
## zero-RTT host would bonk ~60×/sec on a wall. A FRESH press bypasses the wait (responsive to
## deliberate re-taps); only auto-repeat from a held key is throttled.
@export var held_retry_cooldown_sec: float = 0.25

## Consecutive step rejects that drop a standing walk target. The first reject marks the refused
## tile as a transient obstacle and retries around it; a second in a row means the way is shut.
@export var target_reject_cap: int = 2

# ── Public state ──────────────────────────────────────────────────────────────

## Set by the parent: true only on the local player's node. A remote/disabled MoveInput never
## samples (it still exists in the scene so the node graph is uniform on every peer).
var enabled: bool = false

# ── Private vars ──────────────────────────────────────────────────────────────

# The four move actions, sampled together into an 8-way vector.
const _ACTIONS := ["move_right", "move_left", "move_down", "move_up"]

enum State { IDLE, AWAITING, COOLDOWN }
var _state: State = State.IDLE
# True while the parent's player is gliding (set from glide_started/glide_finished). Submitting is
# suppressed until the OWN tween finishes — this is the "GLIDING" state, tracked as a flag so the
# host may consider the peer idle ~RTT before the client stops animating without desyncing input.
var _blocked: bool = false
# Time accumulators for the two timed states.
var _await_elapsed: float = 0.0
var _cooldown_elapsed: float = 0.0

# What tile this player stands on, as far as input planning is concerned: seeded by the parent
# via set_current_tile() at spawn, then advanced by on_accepted(to_tile) at each accepted step.
# Path recomputes start here — never from the rendered position mid-tween.
var _current_tile: Vector2i
# The standing click-to-move target. Not a commitment (§2.2.9): replaced by any new click,
# cancelled by any key sample, dropped on arrival/unreachable/reject-cap.
var _target_tile: Vector2i
var _has_target: bool = false
# The last direction submitted for the target walk — on a reject, _current_tile + _last_dir is
# the tile the referee refused, which becomes the transient avoid tile for the next recompute.
var _last_dir: Vector2i = Vector2i.ZERO
# Consecutive rejects since the last accept while walking a target; at target_reject_cap the
# target is dropped ("Stopped walking.").
var _target_reject_count: int = 0
# Transient obstacle for path recomputes (a body, most likely — bodies aren't in the A* grid).
# Held only until the next accept; one tile is enough because a fresh reject overwrites it.
var _avoid_tile: Vector2i
var _has_avoid: bool = false
# The target the in-flight step was computed FOR. Race: a click can replace the target while a
# step verdict is in flight — the OLD step's reject must not count against the NEW target (the
# cap would effectively drop from 2 to 1). Set only by target-continuation submits; fresh key
# submits clear it; on_rejected counts only when it still matches the standing target.
var _pending_step_target: Vector2i
var _has_pending_step: bool = false


func _process(delta: float) -> void:
	# Not the local player: never sample.
	if not enabled:
		return
	# Gliding: the Commitment Rule guard — no submitting until our own glide finishes.
	if _blocked:
		return

	match _state:
		State.AWAITING:
			# Waiting on the host's verdict; don't submit. Safety-clear only.
			_await_elapsed += delta
			if _await_elapsed >= verdict_timeout_sec:
				_state = State.IDLE
				_await_elapsed = 0.0
			return
		State.COOLDOWN:
			# Post-reject throttle. A fresh press bypasses it immediately (a key sampling site, so
			# chat- and window-focus-gated, same as (1) below); otherwise wait out the cooldown,
			# then fall through and resample.
			if _fresh_press() and not _chat_focused() and _window_focused():
				_state = State.IDLE
			else:
				_cooldown_elapsed += delta
				if _cooldown_elapsed < held_retry_cooldown_sec:
					return
				_state = State.IDLE
				_cooldown_elapsed = 0.0

	# IDLE (or a just-elapsed cooldown), in priority order:
	# (1) Keys. The chat gate AND the window-focus gate live ONLY on the key sampling sites —
	#     while a text field owns focus the player is typing, not steering (the focused control
	#     IS the source of truth; game_log.gd documents this seam). Window focus matters because
	#     gamepad state isn't OS-routed like keyboard/mouse: Input polls the raw device with no
	#     per-window exclusivity, so two instances on one machine would both see the same stick
	#     (the two-window dev-testing symptom). Real single-window play is unaffected — the one
	#     game window normally holds focus while its player is controlling it. An auto-walk (2)
	#     deliberately continues regardless — it's click-driven, not device-driven, so an
	#     unfocused window can still finish an in-progress walk. A non-zero key sample cancels
	#     any standing target: keys always win.
	var dir := Vector2i.ZERO
	if not _chat_focused():
		if _window_focused():
			dir = _sample_dir()
		elif _fresh_press():
			# One-shot per press (is_action_just_pressed only fires the one frame) — tells a
			# confused player/tester why their key/pad input is doing nothing.
			print("[MoveInput] input ignored: window not focused")
	if dir != Vector2i.ZERO:
		if _has_target:
			_clear_target()
		_last_dir = dir
		# A key step is not a target step: clear the pending-step stamp so its reject can never
		# count toward a walk (e.g. one clicked into existence before the verdict lands).
		_has_pending_step = false
		_submit(dir, true)
		return
	# (2) Standing target: recompute the path THIS step (cheap on a room; picks up moved bodies
	#     and replaced targets for free — redirect falls out of per-step recompute) and submit
	#     only the next adjacent step. The server never sees the path (§2.2.9).
	if _has_target:
		_step_toward_target()


## Click capture. _unhandled_input, so clicks the UI consumed (chat panel, menus) never reach
## it. Deliberately NO chat-focus gate here: a world click while typing ALSO unfocuses the chat
## box (game_log's editing_toggled click-away path), so gating would eat the click that just
## closed the chat — the click is unambiguous intent either way. Clicks are legal in ANY state
## (mid-glide, awaiting, cooldown): they only store/replace the target; the actual step submits
## through the normal IDLE machinery, so no committed glide is ever touched (§2.2.4).
func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if mouse.button_index != MOUSE_BUTTON_LEFT or not mouse.pressed:
		return
	# Viewport coords → world via the canvas transform inverse (camera/stretch-safe), → tile.
	var world_pos: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * mouse.position
	var tile := WorldGrid.world_to_tile(world_pos)
	if tile == _current_tile:
		return
	# Reachability check WITHOUT the avoid tile: a body might vacate, that's what per-step
	# recompute + avoid are for. Empty path = walls/OOB/sealed — tell the player, set nothing
	# (an existing walk keeps going; the failed click just didn't take).
	if WorldGrid.find_path(_current_tile, tile).is_empty():
		print("[MoveInput] click on unreachable tile %s" % tile)
		GameEvents.unreachable_tile_clicked.emit(tile)
		return
	_target_tile = tile
	_has_target = true
	_target_reject_count = 0
	_has_avoid = false
	path_target_set.emit(tile)


# ── Public methods ────────────────────────────────────────────────────────────

## Called by the parent on glide_started(true) / glide_finished(false). While blocked, submitting
## is suppressed — the local glide plays to completion before the next step can go out.
func set_blocked(blocked: bool) -> void:
	_blocked = blocked


## Seed the planning tile at spawn (parent calls it from _ready with the server-derived tile).
func set_current_tile(tile: Vector2i) -> void:
	_current_tile = tile


## The host accepted our intent (parent relays it from its own glide event, with the destination
## tile). Advance the planning tile, clear the AWAITING latch, and forget the transient avoid +
## reject streak — an accept means the walk is making progress again.
func on_accepted(to_tile: Vector2i) -> void:
	_current_tile = to_tile
	_target_reject_count = 0
	_has_avoid = false
	_has_pending_step = false
	if _state == State.AWAITING:
		_state = State.IDLE
	_await_elapsed = 0.0


## The host rejected our intent (parent relays it from its own reject). Enter the post-reject
## cooldown as always; additionally, with a standing target, mark the refused tile as the
## transient avoid (next recompute detours around it — a body, most likely) and count the
## streak: at target_reject_cap consecutive rejects the way is shut, so drop the target and
## tell the player via the bus ("Stopped walking." — a stopped walk must never be silent).
func on_rejected() -> void:
	_state = State.COOLDOWN
	_cooldown_elapsed = 0.0
	# Count only a reject of a step computed for the CURRENT target — a click replacing the
	# target mid-flight must not inherit the old step's strike (cap 2 would in effect become 1).
	if _has_target and _has_pending_step and _pending_step_target == _target_tile:
		_avoid_tile = _current_tile + _last_dir
		_has_avoid = true
		_target_reject_count += 1
		if _target_reject_count >= target_reject_cap:
			_clear_target()
			GameEvents.target_walk_stopped.emit()
	_has_pending_step = false


# ── Private methods ───────────────────────────────────────────────────────────

## The one submit path both input sources share: arm the latch FIRST, then emit. Order matters:
## on the HOST the verdict returns synchronously inside the emit (submit_intent adjudicates
## inline and the call_local event/reject fire in the same stack), so on_accepted / on_rejected
## run before the emit returns. The latch must already be armed when they do — arming it after
## would overwrite their state transition and wedge input until the safety timeout. Clients get
## the verdict a frame later, so either order works for them.
func _submit(dir: Vector2i, fresh: bool) -> void:
	_state = State.AWAITING
	_await_elapsed = 0.0
	move_requested.emit(dir, fresh)


## One auto-walk step: recompute from the planning tile (with the transient avoid, if any) and
## submit the next adjacent step as non-fresh. Two distinct endings: ARRIVED (we stand on the
## target) clears quietly — the walk simply completed; NO-PATH while not arrived (e.g. the
## avoid tile seals the only corridor) is a STOPPED walk, so it tells the player via the bus
## ("Stopped walking.") before clearing — a vanishing marker must never be the only signal.
func _step_toward_target() -> void:
	var avoid: Array[Vector2i] = []
	if _has_avoid:
		avoid.append(_avoid_tile)
	var path := WorldGrid.find_path(_current_tile, _target_tile, avoid)
	if path.size() < 2:
		if _current_tile != _target_tile:
			GameEvents.target_walk_stopped.emit()
		_clear_target()
		return
	var dir := path[1] - _current_tile
	_last_dir = dir
	# Stamp what target this step serves, so a reject is attributed to the right walk (see
	# on_rejected — a mid-flight replacement click must not inherit this step's strike).
	_pending_step_target = _target_tile
	_has_pending_step = true
	_submit(dir, false)


## Forget the standing target and its bookkeeping; tells the parent to hide the marker.
func _clear_target() -> void:
	if not _has_target:
		return
	_has_target = false
	_has_avoid = false
	_target_reject_count = 0
	path_target_cleared.emit()


## True while a text field owns focus — the player is typing, not steering. Used ONLY at the
## key sampling sites; clicks and auto-walk continuation deliberately ignore it (see above).
func _chat_focused() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


## True while THIS OS window is the focused one. Used ONLY at the key sampling sites, same as
## the chat gate above — see the (1) comment in _process for why (gamepad state isn't
## per-window like keyboard/mouse, so two unfocused-aware instances on one machine stop
## fighting over one physical stick).
func _window_focused() -> bool:
	return get_window().has_focus()


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
