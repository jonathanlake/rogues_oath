extends Node

## Local-player-only input sampler for committed movement, now with TWO input sources feeding
## one latch/submit path: (1) the four move actions sampled into an 8-way direction, and (2) a
## click-to-move target driver that recomputes a path each step and submits ONE adjacent step at
## a time. Both end in move_requested(dir, fresh) — the parent player turns that into a "glide_to"
## intent (the fresh flag is now vestigial: the white commit-sent flash it once gated was removed in
## v0.10.2). It NEVER moves anything and NEVER
## predicts the outcome: the glide begins only when the server's event comes back (DESIGN
## §2.2.8), which the parent surfaces here via set_blocked / on_accepted / on_rejected.
##
## The target driver lives HERE (not a sibling) because it feeds the same latch/state — a
## sibling would have to share three pieces of state through the parent. Click-to-move is
## CLIENT-SIDE convenience only (DESIGN §2.2.9): the server never sees a path or a target and
## never queues; each submitted step is the only wire commitment. A standing walk is NOT
## cancelable by other input (§2.2.9 amendment, Jon 2026-07-18 — "decisions carry risk"): keys
## are not sampled while it stands; only a new CLICK redirects it (at the next step boundary),
## and it ends on arrival or when the world refuses. Walk-stop and unreachable-click UX cross
## to the game log via GameEvents (the bus) — they are local-only and never touch the wire.
##
## It is a conservative state machine (host is truth): after submitting it awaits the verdict
## before sampling again. It may submit exactly ONE next step while its own player is gliding —
## the pipelined step (§2.2.5 amendment, v0.3.4), sent at glide start so the client's steps arrive
## back-to-back instead of one-per-round-trip. AWAITING is the one-in-flight guard (the latch
## clears only at the held step's boundary verdict); the referee's slot-full "already moving"
## reject is the backstop for a third intent. Only a genuinely HELD key auto-repeats (v0.3.5 /
## v0.8.0): a CONTINUING hold submits its next step only once held past key_repeat_min_hold_beats,
## so a discrete tap commits exactly one step even if the press outlasts the shorter visible slide.
## A fresh tap that lands mid-SLIDE is deliberately dropped (you are visibly moving); from slide end
## through the SETTLE (action window not yet closed) a fresh press submits and the referee slots it.
## The Commitment Rule stands at the input layer: no input path cancels, interrupts, or redirects
## the in-flight OR the held step — a mid-glide click only replaces the target the NEXT submission
## will path toward.

# ── Signals ──────────────────────────────────────────────────────────────────

## A committed direction is ready to submit. Components in {-1,0,1}, non-zero. fresh=true for a
## deliberate key/stick sample, false for a click-to-move auto-continuation step. The flag is now
## vestigial (the commit-sent flash it once gated was removed in v0.10.2); kept on the signal for
## any future fresh-only cue. The parent wires it.
signal move_requested(dir: Vector2i, fresh: bool)
## A click set (or replaced) the walk target. The parent shows/moves the path marker + cues.
signal path_target_set(tile: Vector2i)
## The walk target is gone — arrived, unreachable, or dropped after rejects (keys cannot
## cancel a walk: §2.2.9 amendment). The parent hides the path marker.
signal path_target_cleared

# ── Exports ───────────────────────────────────────────────────────────────────

## Safety clear for the AWAITING latch (seconds). Verdicts arrive over reliable RPC, so this
## should never fire in practice; it exists so a dropped/never-answered verdict can't wedge input
## forever. A late verdict still renders (glide_to catches up), so clearing early is harmless.
@export var verdict_timeout_sec: float = 2.0

## After a REJECT, a still-held key waits this many BEATS before resubmitting. Without it a zero-RTT
## host would bonk ~60×/sec on a wall. A FRESH press bypasses the wait (responsive to deliberate
## re-taps); only auto-repeat from a held key is throttled. Converted to seconds at the LOCAL player's
## RESOLVED PACE when used (§2.8.7 — tactical while the host has us in a fight, else explore; via
## _pace_beats_to_sec), not cached (DESIGN §2.8) — client-side PACING only (adjudication stays
## host-side), so the retry cadence tracks the host's stamped window during a fight. 1 beat = one rest.
@export var held_retry_beats: float = 1.0

## Consecutive step rejects that drop a standing walk target. The first reject marks the refused
## tile as a transient obstacle and retries around it; a second in a row means the way is shut.
@export var target_reject_cap: int = 2

## Tap/hold threshold in BEATS: a single continuous press shorter than this = exactly ONE step;
## held longer, movement auto-repeats one step per beat. Converted at the LOCAL player's RESOLVED PACE
## (§2.8.7 — via _pace_beats_to_sec) at use, not cached (DESIGN §2.8) — client-side PACING only
## (adjudication stays host-side). Default 1.2 beats (~0.3s at the 0.25 default): deliberately
## ABOVE the 1-beat action window so a hold that merely outlasts the SHORTER visible slide does
## not free-fire a second step (the v0.8.0 settle-phase double-step fix), yet low enough that a
## sustained hold streams at one step per beat. 1.5 (not 1.2): verification found 1.2 = exactly
## 0.30s at the default beat, a knife-edge where a "0.3s press" doubles frame-dependently — 1.5
## puts the stated contract ("under ~0.3s = one step, always") safely inside the single-step zone.
@export_range(0.5, 4.0, 0.1) var key_repeat_min_hold_beats: float = 1.5

# ── Public state ──────────────────────────────────────────────────────────────

## Set by the parent: true only on the local player's node. A remote/disabled MoveInput never
## samples (it still exists in the scene so the node graph is uniform on every peer).
var enabled: bool = false

# ── Private vars ──────────────────────────────────────────────────────────────

# The four move actions, sampled together into an 8-way vector.
const _ACTIONS := ["move_right", "move_left", "move_down", "move_up"]

enum State { IDLE, AWAITING, COOLDOWN }
var _state: State = State.IDLE
# True while the parent's player is gliding (set from glide_started/glide_finished). NO LONGER a
# submit gate — the pipeline (§2.2.5 amendment) lets exactly ONE next step submit while gliding,
# at glide start; AWAITING is the one-in-flight guard and the referee slot-full reject the
# backstop. _blocked survives only as a modifier for two things: it pauses the AWAITING safety
# timer (a pipelined verdict is scheduled for our glide's own finite boundary, not lost), and it
# marks a submit as pipelined so its verdict is excluded from the M1.5 idle-submit latency metric.
var _blocked: bool = false
# Set by _submit from _blocked at emit time: true if that submission was pipelined (fired mid-
# glide). Read by on_accepted/on_rejected to SKIP the verdict-latency sample — a pipelined
# verdict's timing includes the whole held-until-boundary wait, which would wreck the
# "idle-submit→verdict" baseline. One flag, one rule; both accept and reject honor it.
var _submitted_while_blocked: bool = false
# Time accumulators for the two timed states.
var _await_elapsed: float = 0.0
var _cooldown_elapsed: float = 0.0
# How long the current move-key hold has been continuously down (seconds), sampled every frame in
# every state — hold time is physical time, so it accrues across AWAITING/COOLDOWN spans too. Zero
# dir (or a gated one) resets it; a direction CHANGE while still held does NOT (turning mid-hold is
# one continuous movement). Read only by the key-submit gate to distinguish a tap from a hold.
var _key_held_sec: float = 0.0

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

	# Hold-time accumulator, ticked in EVERY state (a hold spans AWAITING/COOLDOWN too). Count the
	# key as held only under the SAME gates as the key-submit branch below (not typing, this window
	# focused); anything else — zero dir or a gated one — resets it. A direction change while still
	# held does NOT reset (hold-turn continuity: turning mid-hold is one continuous movement).
	var _sampling := not _chat_focused() and _window_focused() and _sample_dir() != Vector2i.ZERO
	# A fresh press-EDGE: input resumed from idle this frame (accumulator still 0). A direction change
	# mid-hold keeps the accumulator >0, so it reads as a CONTINUING hold, not a fresh edge.
	var _fresh_edge := _sampling and _key_held_sec == 0.0
	if _sampling:
		_key_held_sec += delta
	else:
		_key_held_sec = 0.0

	match _state:
		State.AWAITING:
			# Waiting on the host's verdict; don't submit. Safety-clear only — and ONLY while not
			# gliding: a pipelined verdict is scheduled for our own glide's completion boundary (a
			# known, finite wait that a stretched glidesec can push past 2.0s), so accruing while
			# _blocked would false-clear the latch mid-glide. Once the tween ends (_blocked drops)
			# the window resumes guarding a genuinely lost verdict.
			if not _blocked:
				_await_elapsed += delta
				if _await_elapsed >= verdict_timeout_sec:
					_state = State.IDLE
					_await_elapsed = 0.0
			return
		State.COOLDOWN:
			# Post-reject throttle. A fresh press bypasses it immediately (a key sampling site, so
			# chat- and window-focus-gated, same as the key branch below) — but NEVER while a walk
			# stands: the walk owns the submit path (§2.2.9 amendment), so a walk-reject's cooldown
			# just runs out normally (0.25s) before the next recompute. Otherwise wait out the
			# cooldown, then fall through and resample.
			if not _has_target and _fresh_press() and not _chat_focused() and _window_focused():
				_state = State.IDLE
			else:
				_cooldown_elapsed += delta
				if _cooldown_elapsed < _pace_beats_to_sec(held_retry_beats):
					return
				_state = State.IDLE
				_cooldown_elapsed = 0.0

	# IDLE (or a just-elapsed cooldown):
	# A standing walk OWNS the submit path (§2.2.9 amendment, Jon 2026-07-18 — "decisions carry
	# risk"): keys are not sampled at all while it stands — only a new CLICK redirects it, and it
	# ends on arrival or when the world refuses. When the walk ends, a still-held key is honored
	# on the NEXT idle frame (held sampling below, no press-edge required): you can still act at
	# arrival. The recompute each step picks up moved bodies and replaced targets for free —
	# redirect falls out of per-step recompute; the server never sees the path (§2.2.9). The walk
	# also continues regardless of chat/window focus — it's click-driven, not device-driven, so
	# typing (or an unfocused window) doesn't stall a walk in progress.
	if _has_target:
		_step_toward_target()
		return
	# Keys (no standing walk). The chat gate AND the window-focus gate live ONLY on the key
	# sampling sites — while a text field owns focus the player is typing, not steering (the
	# focused control IS the source of truth; game_log.gd documents this seam). Window focus
	# matters because gamepad state isn't OS-routed like keyboard/mouse: Input polls the raw
	# device with no per-window exclusivity, so two instances on one machine would both see the
	# same stick (the two-window dev-testing symptom). Real single-window play is unaffected —
	# the one game window normally holds focus while its player is controlling it.
	var dir := Vector2i.ZERO
	if not _chat_focused():
		if _window_focused():
			dir = _sample_dir()
		elif _fresh_press():
			# One-shot per press (is_action_just_pressed only fires the one frame) — tells a
			# confused player/tester why their key/pad input is doing nothing.
			print("[MoveInput] input ignored: window not focused")
	# v0.8.0 tap/hold gate (DESIGN §2.2.5). A FRESH press-edge submits unless we are visibly mid-SLIDE
	# (the v0.3.5 drop — you are visibly moving); during the SETTLE (glide_finished fired, action
	# window not yet closed) or when idle it submits immediately and the referee slots it (§2.2.8 cue
	# fires). A CONTINUING hold auto-repeats only once held past the threshold, in ANY phase — so a
	# hold that merely outlasts the shorter slide no longer free-fires a second step (the settle-phase
	# double-step fix). The AWAITING latch + the referee's one pipeline slot pace the stream to one
	# step per beat; a third intent while the slot is full is the unchanged "already moving" bonk.
	var _may_submit := (not _blocked) if _fresh_edge \
		else (_key_held_sec >= _pace_beats_to_sec(key_repeat_min_hold_beats))
	if dir != Vector2i.ZERO and _may_submit:
		_last_dir = dir
		# A key step is not a target step: clear the pending-step stamp so its reject can never
		# count toward a walk (e.g. one clicked into existence before the verdict lands).
		_has_pending_step = false
		_submit(dir, true)


## Click capture. _unhandled_input, so clicks the UI consumed (chat panel, menus) never reach
## it. No chat-focus GATE here — instead a world click RELEASES a focused text control (below):
## a world click on its own moves GUI focus nowhere (no other Control takes it), so without the
## explicit release the chat gate would wedge key input after typing (wire-test bug, 2026-07-18).
## Clicks are legal in ANY state (mid-glide, awaiting, cooldown): they only store/replace the
## target; the actual step submits through the normal IDLE machinery, so no committed glide is
## ever touched (§2.2.4).
func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if mouse.button_index != MOUSE_BUTTON_LEFT or not mouse.pressed:
		return
	# ANY world click means "done typing" — release a focused text control BEFORE the target
	# logic, so even a click on a wall/unreachable tile ends editing. Clicks ON the chat panel
	# are consumed by the GUI and never get here, so they keep focus. This release lands in
	# game_log as editing_toggled(false), which keeps the draft (nothing is sent, nothing is
	# lost — refocus with Enter and it's still there; send is the only clear).
	if _chat_focused():
		get_viewport().gui_release_focus()
	# Viewport coords → world via the canvas transform inverse (camera/stretch-safe), → tile.
	var world_pos: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * mouse.position
	var tile := WorldGrid.world_to_tile(world_pos)
	# Adjacent-only click mode (§2.2.9 provisionally on via config, Jon/Jeff 2026-07-19): with
	# click_pathing_enabled=false the mouse can only step to one of the 8 neighbors of _current_tile —
	# no target, no A*, no marker, no "Can't reach that.". A click that IS a Chebyshev neighbor
	# submits ONE fresh step through the SAME latch/gates a key press uses (cue fires, §2.2.8); the
	# server verdicts walkability, so we do NOT pre-validate walls here (§2.2.8 — identical to a key
	# press into a wall, which bonks). Any non-neighbor click (including the own tile, distance 0) does
	# nothing at all (Jeff: "if you click 8 spaces ahead nothing happens"). State gate: a click is a
	# FRESH press, so it bypasses COOLDOWN exactly as a re-tap does, but it is dropped in AWAITING and
	# — deliberately — while _blocked (mid-SLIDE): a click is a one-shot fresh edge with no held
	# accumulator to satisfy the continuing-hold threshold, so one click = exactly one step from
	# IDLE/COOLDOWN/settle, never a buffered mid-slide step (discrete-tap semantics, v0.3.5 /
	# v0.8.0). No walk can ever stand in this mode (nothing sets
	# _has_target), so the key-sampling gates in _process are the only submit-path interplay.
	if not GameManager.config.click_pathing_enabled:
		if maxi(absi(tile.x - _current_tile.x), absi(tile.y - _current_tile.y)) != 1:
			return
		if _blocked or _state == State.AWAITING:
			return
		var dir := tile - _current_tile
		_last_dir = dir
		# A click step is not a target step: clear the pending-step stamp (mirrors the key path) so
		# its reject can never be attributed to a walk.
		_has_pending_step = false
		_submit(dir, true)
		return
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
		# The AWAITING accumulator IS the submit→verdict time — publish it for the debug overlay
		# before clearing (local-only; ≈0 on the host, whose idle verdict is synchronous). SKIP the
		# sample for a pipelined submit: its measured time includes the whole held-until-boundary
		# wait, which is not the idle-submit→verdict the M1.5 metric wants. Flag cleared regardless.
		if not _submitted_while_blocked:
			GameEvents.verdict_latency_measured.emit(_await_elapsed)
		_state = State.IDLE
	_submitted_while_blocked = false
	_await_elapsed = 0.0


## The host rejected our intent (parent relays it from its own reject). Enter the post-reject
## cooldown as always; additionally, with a standing target, mark the refused tile as the
## transient avoid (next recompute detours around it — a body, most likely) and count the
## streak: at target_reject_cap consecutive rejects the way is shut, so drop the target and
## tell the player via the bus ("Stopped walking." — a stopped walk must never be silent).
func on_rejected() -> void:
	# A reject is a verdict too: same submit→verdict sample as the accept path (the overlay
	# measures the pipe, not success). Emitted before the state leaves AWAITING — and skipped for a
	# pipelined submit for the same reason as on_accepted (a pipelined reject's timing carries the
	# held wait). Flag cleared regardless of whether the sample was emitted.
	if _state == State.AWAITING and not _submitted_while_blocked:
		GameEvents.verdict_latency_measured.emit(_await_elapsed)
	_submitted_while_blocked = false
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
## on the HOST the verdict returns synchronously inside the emit ONLY for an idle submit
## (submit_intent adjudicates inline and the call_local event/reject fire in the same stack), so
## on_accepted / on_rejected run before the emit returns. The latch must already be armed when
## they do — arming it after would overwrite their state transition and wedge input until the
## safety timeout. A PIPELINED submit (mid-glide) is different even on the host: its accept is
## deferred to the current glide's boundary, so the verdict arrives later, like a client's — the
## _submitted_while_blocked stamp (captured here) tells on_accepted/on_rejected to skip its
## latency sample so the M1.5 baseline stays idle-submit-only. Clients get every verdict a frame
## later, so either order works for them.
func _submit(dir: Vector2i, fresh: bool) -> void:
	_submitted_while_blocked = _blocked
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


## Convert BEATS to seconds at the LOCAL player's CURRENT pace (Tactical Zones v1, §2.8.7) — the tactical
## dial while the host has us in a fight, else the explore dial, mirrored from the host-authored pace via
## GameManager.local_pace_is_tactical. CLIENT-SIDE PACING ONLY: the retry (held_retry_beats) and hold-
## threshold (key_repeat_min_hold_beats) throttles read it so their cadence tracks the host's stamped
## window during a fight — halving refused-intent spam when tactical slows the beat — instead of always
## converting at the explore beat. Never a verdict input (adjudication stays host-side). Deliberately
## SEPARATE from GameManager.beats_to_sec, which stays the EXPLORE-specific conversion for its own uses.
func _pace_beats_to_sec(beats: float) -> float:
	var beat := GameManager.tactical_beat_sec if GameManager.local_pace_is_tactical else GameManager.explore_beat_sec
	return beats * beat
