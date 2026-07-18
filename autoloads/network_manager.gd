## Transport contract — read before adding any connection code.
##
## The rest of the codebase calls ONLY these functions:
##   NetworkManager.host_game()       -> Error (synchronous failure, e.g. port already bound)
##   NetworkManager.join_game(ip)     -> Error (synchronous failure only; async failures
##                                      arrive via connection_failed)
##   NetworkManager.disconnect_game()
##   NetworkManager.kick_peer(id)     (host-only)
##   NetworkManager.current_port()    -> int (bound port while hosting, 0 otherwise)
##
## All ENet (or future Steam / relay) code lives exclusively in host_game(), join_game(), and
## kick_peer() (which reaches into ENetPacketPeer.peer_disconnect_later for its flush-before-
## disconnect guarantee — see its doc for why that can't be done through the generic peer API).
## Every other file stays transport-agnostic. To swap transports:
##   1. Replace the peer-creation lines inside host_game() / join_game().
##   2. Give kick_peer() the new transport's flush-then-disconnect equivalent (its ENet branch is
##      guarded by a cast with a fail-loud fallback, so a new transport announces itself there).
##   3. Touch nothing else.
##
## Example future swap (Steam):
##   func host_game(...) -> Error:
##       var peer := SteamMultiplayerPeer.new()
##       var err := peer.create_host(GameManager.config.max_players - 1)
##       if err != OK:
##           return err
##       multiplayer.multiplayer_peer = peer
##       return OK
##
## The signal layer (multiplayer.*) is above the transport and stays identical
## across ENet / Steam / WebRTC, so all signal wiring here is reusable.

extends Node

# ── Signals ──────────────────────────────────────────────────────────────────

## Client: fired when connection to the server is established.
signal connection_succeeded
## Client: fired when the connection attempt fails.
signal connection_failed
## Client: fired when the server closes the connection.
signal server_disconnected

## All peers: fired when any remote peer joins the session.
signal peer_connected(peer_id: int)
## All peers: fired when any remote peer leaves the session.
signal peer_disconnected(peer_id: int)

# ── Config ────────────────────────────────────────────────────────────────────

const DEFAULT_PORT := 3000

# The port this instance is hosting on; 0 when not hosting. Written by host_game on success,
# zeroed by disconnect_game and join_game. Read via current_port().
var _hosted_port: int = 0

# ── Public API ────────────────────────────────────────────────────────────────

## The port this instance is currently hosting on, or 0 when not hosting. Requested == bound:
## ENet's create_server binds the requested port or returns an error, and host_game surfaces
## that error to its caller instead of storing the port — so this getter can never report a
## port that isn't actually listening.
func current_port() -> int:
	return _hosted_port

## Returns the create error so the caller can stay on the menu and tell the user — a failed
## host (port already bound: e.g. a second host on this machine) must NOT fall through into the
## game, where the default OfflineMultiplayerPeer would fake is_server() and boot a phantom
## solo session nobody can join. No connection_failed here: that signal is the CLIENT contract.
func host_game(port: int = DEFAULT_PORT) -> Error:
	# ── ENet transport ───────────────────────────────────────────────────────
	var peer := ENetMultiplayerPeer.new()
	# Cap transport connections to the session size (the host occupies one max_players slot, so
	# clients get the rest). Excess connectors are refused at the transport — their join fails
	# fast at the menu instead of connecting into a session that will never spawn them.
	var err := peer.create_server(port, maxi(1, GameManager.config.max_players - 1))
	# ────────────────────────────────────────────────────────────────────────
	if err != OK:
		# A failed re-host must not leave a stale port from an earlier successful host —
		# current_port() reports only a port that is actually listening.
		_hosted_port = 0
		return err
	multiplayer.multiplayer_peer = peer
	_hosted_port = port
	return OK


## Returns a synchronous create error (bad address, socket failure). The normal failure path —
## host unreachable / refused — is asynchronous and arrives via connection_failed.
func join_game(ip: String, port: int = DEFAULT_PORT) -> Error:
	# Joining means not hosting — keep current_port()'s "0 when not hosting" contract honest
	# even if a caller ever joins without an intervening disconnect_game.
	_hosted_port = 0
	# ── ENet transport ───────────────────────────────────────────────────────
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	# ────────────────────────────────────────────────────────────────────────
	if err != OK:
		connection_failed.emit()
		return err
	multiplayer.multiplayer_peer = peer
	return OK


func disconnect_game() -> void:
	_hosted_port = 0
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null


## Host-only: forcibly disconnect a peer (e.g. the spawn-gate refusing an over-capacity join),
## delivering any queued reliable packet — the refusal reason — FIRST. The kicked client gets
## server_disconnected and falls back to its menu instead of hanging player-less. This function now
## OWNS the codebase's flush-before-disconnect guarantee: callers (main.gd's refusal path) enqueue
## the reason RPC, then call this, and trust the packet lands before the connection closes.
##
## BOUNDED, never "guaranteed": ENet's peer_disconnect_later holds the connection open until every
## queued outgoing packet is acked OR ENet's disconnect timeout elapses. So the reason is delivered
## if the link can deliver anything at all; under total packet loss it dies with the connection.
## (The v0.5.0 kick claimed a plain graceful disconnect DRAINS queued reliable packets — that was
## wrong: ENet's enet_peer_disconnect calls enet_peer_reset_queues, which provably RESETS the unacked
## reliable queue. peer_disconnect_later is the primitive that actually waits for empty queues + acks;
## overclaiming "guaranteed" is the exact mistake this pass is fixing.)
##
## Residual: while it waits, disconnect_later keeps the ENet CONNECTION open until delivery/timeout,
## so a refused peer can occupy a transport-cap slot slightly longer than a hard disconnect would
## (the _slots ledger is unaffected — a pre-existing exposure class, acceptable at 2-6-player scale).
##
## Transport-swap contract: any future transport MUST preserve "kick delivers pending reliable data
## first." The flush is ENet-specific, so it is isolated here behind the cast; a non-ENet peer takes
## the fail-loud fallback rather than silently reintroducing the swallowed-reason bug.
func kick_peer(peer_id: int) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	# get_peer() errors on an unknown id, so gate on the live peer list first: a peer already gone
	# (double kick, or a self-disconnect racing the refusal) makes this a harmless no-op.
	if not multiplayer.get_peers().has(peer_id):
		return
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet != null:
		enet.get_peer(peer_id).peer_disconnect_later()
	else:
		# FAIL-LOUD: a hypothetical non-ENet transport reached here with no flush primitive. Dead
		# code today (ENet is the only transport), but a silent disconnect_peer would resurrect the
		# swallowed-reason bug this pass fixed, so name the lost guarantee instead of hiding it.
		push_error("[NetworkManager] kick_peer: non-ENet transport lacks flush-before-disconnect — refusal reason may be lost")
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)

# ── Internal signal routing ───────────────────────────────────────────────────

func _ready() -> void:
	multiplayer.peer_connected.connect(func(id): peer_connected.emit(id))
	multiplayer.peer_disconnected.connect(func(id): peer_disconnected.emit(id))
	multiplayer.connected_to_server.connect(func(): connection_succeeded.emit())
	multiplayer.connection_failed.connect(func(): connection_failed.emit(); disconnect_game())
	multiplayer.server_disconnected.connect(func(): server_disconnected.emit(); disconnect_game())
