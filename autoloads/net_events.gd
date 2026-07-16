extends Node

## The intent -> verdict -> broadcast pipe: the single referee gate every gameplay action
## flows through (DESIGN §2.5.3 — "replicate discrete commits, each stamped with
## duration/outcome by the server"). This milestone (M1.3) carries only "chat", but movement,
## attacks, and item use all land on this same pipe.
##
## Topology: listen-server. The host (peer 1) is the authority AND a player; there is no
## dedicated server and NO host migration. `seq` is a per-SESSION counter that resets to 0
## with every fresh host — it is meaningful only within one host's lifetime, never persisted
## or reconciled across a host change.
##
## The shape, in one breath: any peer calls submit_intent(action, data). The host runs it
## through the registered validator; on accept it stamps a monotonic event and broadcasts it
## to everyone (call_local, so the host sees its own event too); on reject only the sender is
## told. Public API is identical on every peer — callers never branch on is_server().

# ── Signals ──────────────────────────────────────────────────────────────────

## All peers: a validated event was broadcast. Carries {seq, peer, action, data, server_time}.
signal event_received(event: Dictionary)
## Sender only: the host refused this peer's intent. UX/feedback surface (DESIGN §2.3.4).
signal intent_rejected(action: String, reason: String)

# ── Private vars ──────────────────────────────────────────────────────────────

# action name -> validator Callable(sender_peer_id: int, data: Dictionary) -> Dictionary.
var _handlers: Dictionary = {}
# Host-only monotonic event counter. seq IS the ordering field for all clients; it starts at
# 1 for the first accepted event of a session. Resets to 0 here because there is no host
# migration — a new host is a new session.
var _seq: int = 0

# ── Public methods ────────────────────────────────────────────────────────────

## Submit an intent to the referee. Identical call on host and client: the host adjudicates
## locally (no RPC round-trip to itself); a client ships it to peer 1. The caller never learns
## the verdict here — it arrives asynchronously via event_received / intent_rejected.
func submit_intent(action: String, data: Dictionary) -> void:
	if multiplayer.is_server():
		_handle_intent(1, action, data)
	else:
		_rpc_submit_intent.rpc_id(1, action, data)


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
	var verdict: Dictionary = _handlers[action].call(sender, data)
	if not verdict.get("ok", false):
		_reject(sender, action, str(verdict.get("reason", "rejected")))
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
	print("[NetEvents] seq=%d peer=%d %s %s" % [
		event.get("seq", 0), event.get("peer", 0), event.get("action", ""), event.get("data", {})])
	event_received.emit(event)


## Single reject-path emit + trace, shared by host-local rejects and the client-bound RPC, so
## the trace fires exactly once on the sender's instance regardless of who the sender is.
func _emit_reject(action: String, reason: String) -> void:
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
