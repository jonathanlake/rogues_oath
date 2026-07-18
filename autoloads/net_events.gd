extends Node

## The intent -> verdict -> broadcast pipe: the single referee gate every gameplay action
## flows through (DESIGN §2.5.3 — "replicate discrete commits, each stamped with
## duration/outcome by the server"). This milestone (M1.3) carries only "chat", but movement,
## attacks, and item use all land on this same pipe.
##
## Topology: listen-server. The host (peer 1) is the authority AND a player; there is no
## dedicated server and NO host migration. `seq` is a per-SESSION counter — it is meaningful
## only within one host's lifetime, never persisted or reconciled across a host change. It is
## reset (with the handler registry) by the session root on teardown via reset_session(), not
## automatically per-host: the autoload outlives any one session.
##
## Admission is deferred: this pipe does NOT verify that a sender belongs to the session — no
## pipe-level membership/admission gate exists yet. Until M2 designs the shared gate, EACH
## validator must check membership itself (e.g. chat rejects senders with no player node).
##
## The shape, in one breath: any peer calls submit_intent(action, data). The host runs it
## through the registered validator; on accept it stamps a monotonic event and broadcasts it
## to everyone (call_local, so the host sees its own event too); on reject only the sender is
## told. Public API is identical on every peer — callers never branch on is_server().
##
## Host-originated events (no client intent): post_event(action, data) stamps and broadcasts a
## server-AUTHORED event on this SAME pipe, marking its origin with `peer: 0`. 0 is never a real
## peer id, so it is the unambiguous "the server authored this — no validator ran, the host IS
## the authority" sentinel. Host-authored and client-driven events share the one monotonic seq
## stream, so they stay totally ordered together. This is the seam every future host-originated
## event reuses (M3+: monster actions, roll outcomes); M2's first passenger is the
## attack-of-opportunity `free_attack` event.

# ── Signals ──────────────────────────────────────────────────────────────────

## All peers: a validated event was broadcast. Carries {seq, peer, action, data, server_time}.
signal event_received(event: Dictionary)
## Sender only: the host refused this peer's intent. UX/feedback surface (DESIGN §2.3.4).
signal intent_rejected(action: String, reason: String)

# ── Private vars ──────────────────────────────────────────────────────────────

# action name -> validator Callable(sender_peer_id: int, data: Dictionary) -> Dictionary.
var _handlers: Dictionary = {}
# Host-only monotonic event counter. seq IS the ordering field for all clients; it starts at
# 1 for the first accepted event of a session. Reset to 0 by reset_session() on teardown (no
# host migration — a new session is a fresh counter).
var _seq: int = 0
# Compiled once, reused for every sanitize_wire_text call: matches a single C0 control char
# (incl. newline/CR/tab) so wire text can be flattened without a per-char scan.
static var _control_char_re: RegEx = RegEx.create_from_string("[\\x00-\\x1f]")

# ── Public methods ────────────────────────────────────────────────────────────

## Flatten untrusted wire text into a single-line, length-capped display string. Shared by
## every validator/name path so control-char forgery (fake newlines splitting one message into
## several log lines, embedded NULs) has exactly one chokepoint. strip → flatten every control
## char to a space (cached RegEx, not a per-char loop) → clamp → strip again so a clamp that
## lands mid-space or a leading/trailing flattened char leaves no ragged edge.
static func sanitize_wire_text(s: String, max_chars: int) -> String:
	var t := s.strip_edges()
	t = _control_char_re.sub(t, " ", true)
	t = t.left(max_chars)
	return t.strip_edges()


## Clear the pipe for a fresh session: drop every registered validator and reset the event
## counter. Called by the session root on teardown (it owns session lifetime); the autoload
## itself persists across sessions, so nothing else is safe to assume about carry-over state.
func reset_session() -> void:
	_handlers.clear()
	_seq = 0


## Submit an intent to the referee. Identical call on host and client: the host adjudicates
## locally (no RPC round-trip to itself); a client ships it to peer 1. The caller never learns
## the verdict here — it arrives asynchronously via event_received / intent_rejected.
func submit_intent(action: String, data: Dictionary) -> void:
	if multiplayer.is_server():
		_handle_intent(1, action, data)
	else:
		_rpc_submit_intent.rpc_id(1, action, data)


## Host-only: author and broadcast a server-originated event on the same pipe, WITHOUT any client
## intent or validator — the host IS the authority (DESIGN §2.5.3). Stamps `peer: 0` (the
## server-originated sentinel; 0 is never a real peer id) onto the SAME monotonic seq stream as
## validated events, so host-authored and client-driven events stay totally ordered together, and
## broadcasts via the same call_local RPC (the host receives its own event too). Used for events
## the world decides on its own (M2: attack-of-opportunity; M3+: monster acts, roll outcomes).
##
## `as_peer != 0` marks a DEFERRED, already-validated verdict being broadcast on behalf of that
## peer: the validator DID run — at accept time — and the step was committed then (occupancy
## swapped, duration stamped); only the broadcast was held to the current glide's completion
## boundary (move_referee's pending slot). It is NOT a bypass of the peer-0 sentinel — peer-0
## still means "server authored, no validator ran"; a non-zero as_peer means "the peer's own
## validated commit, broadcast late."
func post_event(action: String, data: Dictionary, as_peer: int = 0) -> void:
	if not multiplayer.is_server():
		push_error("[NetEvents] post_event('%s') called off-server — ignored" % action)
		return
	_seq += 1
	# Same stamped shape as an accepted intent (see _handle_intent); peer is 0 for a server-authored
	# event or the committing peer for a deferred verdict broadcast. server_time is display/telemetry
	# only; seq is the order.
	var event := {
		"seq": _seq,
		"peer": as_peer,
		"action": action,
		"data": data,
		"server_time": Time.get_unix_time_from_system(),
	}
	_rpc_event.rpc(event)


## Register the validator for an action. Called host-side (the only place _handle_intent runs).
## Validator signature: (sender_peer_id: int, data: Dictionary) -> Dictionary, returning either
## { "ok": true, "data": {...} } (data may be rewritten — clamped text, resolved name) or
## { "ok": false, "reason": String }. Duplicate registration is a programming error: log + drop.
func register_handler(action: String, validator: Callable) -> void:
	if _handlers.has(action):
		push_error("[NetEvents] handler already registered for '%s' — ignoring duplicate" % action)
		return
	_handlers[action] = validator

# ── Private methods ───────────────────────────────────────────────────────────

## Server-only brain shared by both entry points (host-local submit and the client RPC). The
## sender id is passed in by the caller — resolved from get_remote_sender_id() for RPCs, or 1
## for the host — and is NEVER read from the payload.
func _handle_intent(sender: int, action: String, data: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	if not _handlers.has(action):
		_reject(sender, action, "unknown action")
		return
	# Guard the Callable itself: a freed validator target (e.g. the session root torn down
	# mid-flight) leaves a stale-but-registered entry. Calling it would abort the frame, so
	# reject cleanly instead.
	if not _handlers[action].is_valid():
		push_error("[NetEvents] validator for '%s' is no longer valid" % action)
		_reject(sender, action, "validator invalid")
		return
	# Call untyped: a validator that returns Nil (missing return path) assigned into a typed
	# Dictionary would hard-abort. Type-check the verdict and reject instead of crashing.
	var verdict = _handlers[action].call(sender, data)
	if typeof(verdict) != TYPE_DICTIONARY:
		push_error("[NetEvents] validator for '%s' returned non-Dictionary" % action)
		_reject(sender, action, "validator error")
		return
	if not verdict.get("ok", false):
		_reject(sender, action, str(verdict.get("reason", "rejected")))
		return
	# Deferred accept: the validator committed the step (occupancy/duration) but is holding the
	# broadcast to a later boundary (move_referee's pending slot, broadcast via post_event at the
	# current glide's completion). No broadcast, no reject, and NO seq consumed here — seq is
	# assigned only at broadcast time so the wire stays in strict broadcast order.
	if verdict.get("deferred", false):
		return
	_seq += 1
	# server_time is wall-clock for display/telemetry ONLY (e.g. log timestamps). seq is THE
	# ordering field — never sort or reconcile on server_time, which can be non-monotonic.
	var event := {
		"seq": _seq,
		"peer": sender,
		"action": action,
		"data": verdict.get("data", {}),
		"server_time": Time.get_unix_time_from_system(),
	}
	_rpc_event.rpc(event)


## Single accept-path trace + signal emit, run once per peer as _rpc_event lands (call_local
## means the host runs it too). This is the ONLY stdout print on the accept path.
func _emit_event(event: Dictionary) -> void:
	# Trace is the harness's verification channel (debug builds only): release skips the
	# per-event stringify + stdout write.
	if OS.is_debug_build():
		print("[NetEvents] seq=%d peer=%d %s %s" % [
			event.get("seq", 0), event.get("peer", 0), event.get("action", ""), event.get("data", {})])
	event_received.emit(event)


## Single reject-path emit + trace, shared by host-local rejects and the client-bound RPC, so
## the trace fires exactly once on the sender's instance regardless of who the sender is.
func _emit_reject(action: String, reason: String) -> void:
	# Same debug-only gate as the accept trace: harness verification in debug, silent in release.
	if OS.is_debug_build():
		print("[NetEvents] rejected %s: %s" % [action, reason])
	intent_rejected.emit(action, reason)


## Host-side reject dispatch: if the sender is the host, emit locally; otherwise notify only
## that peer. Either way the reject surfaces once, on the sender's instance only.
func _reject(sender: int, action: String, reason: String) -> void:
	if sender == 1:
		_emit_reject(action, reason)
	else:
		_rpc_reject.rpc_id(sender, action, reason)

# ── RPCs ──────────────────────────────────────────────────────────────────────

## Client -> host. Thin wrapper: identity comes from get_remote_sender_id() (never the
## payload), then the shared brain does the work. One wrapper, one brain.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_submit_intent(action: String, data: Dictionary) -> void:
	_handle_intent(multiplayer.get_remote_sender_id(), action, data)


## Host -> all (call_local, so the host receives its own broadcast too). The stamped event.
@rpc("authority", "call_local", "reliable")
func _rpc_event(event: Dictionary) -> void:
	_emit_event(event)


## Host -> one peer. The referee refused this peer's intent; only the sender hears about it.
@rpc("authority", "call_remote", "reliable")
func _rpc_reject(action: String, reason: String) -> void:
	_emit_reject(action, reason)
