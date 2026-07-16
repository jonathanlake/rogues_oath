extends Node2D

## Session root for M1 ("See Each Other"). Server-authoritative and event-synced:
##  - The HOST (peer 1) owns every player node and assigns each a spawn SLOT.
##  - Players replicate through a MultiplayerSpawner via a discrete spawn event (a config
##    dict), NOT per-frame streaming and NOT a MultiplayerSynchronizer.
##  - Clients never own nodes and never call set_multiplayer_authority; a client asks to
##    join with a plain client->host RPC (peer_ready) and the host decides.
## Nothing moves in this milestone: players just stand at their assigned spawn slots.

# Brand-new scenes: referenced by res:// path until the editor assigns them a uid. Immutable,
# so const (consts legitimately precede @export in script order).
const PLAYER_SCENE: PackedScene = preload("res://entities/player/player.tscn")
const GAME_LOG_SCENE: PackedScene = preload("res://ui/game_log/game_log.tscn")

## Server-side clamp on chat body length (chars). The referee never trusts the wire; the
## client's LineEdit does no length limiting, so the host is the only guard.
@export var chat_max_chars: int = 200

## Server-assigned spawn slots. The host hands each player a spawn_index; every peer derives
## the same position from it, so no single shared hardcoded point and no client authority.
## Coordinates are DESIGN pixels (the 640x360 base viewport), never window pixels: a 3x2 grid
## centered on (320,180), 96px (3 tiles) apart.
@export var spawn_positions: Array[Vector2] = [
	Vector2(224, 132),
	Vector2(320, 132),
	Vector2(416, 132),
	Vector2(224, 228),
	Vector2(320, 228),
	Vector2(416, 228),
]
## Grid step (px) used to spread overflow players past the explicit slot list.
@export var overflow_offset: Vector2 = Vector2(0, 96)

@onready var _spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var _players: Node2D = $Players

# Chat/combat log, added on every peer in _ready. Held so spawn/disconnect can post system
# lines through it. Set before the host spawns its own player so that spawn's "joined." lands.
var _game_log: Node = null

# Host-only: peer_id -> spawn slot index, so a disconnect frees the slot for reuse.
var _slots: Dictionary = {}
# Teardown guard. Suppresses the child_exiting_tree "X left." spam when players leave because
# the SESSION is ending (returning to menu, app quit) rather than one peer disconnecting.
# INVARIANT: any deliberate session-teardown path added later (host quit-to-menu, etc.) MUST
# set _leaving = true before it tears anything down. Also the client's one-shot host-left guard.
var _leaving: bool = false


func _ready() -> void:
	# Add the log first, on EVERY peer, so the very first spawn's "joined." line has somewhere
	# to go (the host spawns its own player later in this same _ready).
	_game_log = GAME_LOG_SCENE.instantiate()
	add_child(_game_log)

	# Departure lines on EVERY peer: the host frees a leaver directly; clients see the same
	# node removed by the MultiplayerSpawner's despawn. Both paths exit the Players container,
	# so this one hook covers all peers with no double-logging. _leaving guards the client's
	# own teardown (returning to menu removes every player at once — that's not "X left.").
	_players.child_exiting_tree.connect(func(node: Node):
		if node is Player and not _leaving and is_instance_valid(_game_log):
			print("[peer %d] %s left" % [multiplayer.get_unique_id(), node.player_name])
			_game_log.add_line("%s left." % node.player_name))

	# Runs on every peer with the same replicated config, so avatars match everywhere.
	_spawner.spawn_function = func(data):
		var player := PLAYER_SCENE.instantiate() as Player
		player.name = str(data.peer_id)
		player.peer_id = data.peer_id
		player.player_name = data.player_name
		player.spawn_index = int(data.spawn_index)
		player.position = _slot_position(int(data.spawn_index))
		# get_child_count() here is deliberate: this logs the PEER-LOCAL render count (the
		# spawn_function runs on every peer; clients don't have _slots — that's the host's
		# authority bookkeeping, used by the capacity gate in peer_ready).
		print("[peer %d] spawned player '%s' (peer %d) at slot %d — %d player(s) total" % [
			multiplayer.get_unique_id(), player.player_name, player.peer_id,
			player.spawn_index, _players.get_child_count() + 1])
		# System line, posted on every peer as the spawn event replicates (so everyone sees
		# every join, including the host's own player at startup).
		_game_log.add_line("%s joined." % player.player_name)
		return player

	if multiplayer.is_server():
		# Host-only: the chat referee. Strip, reject empty, clamp, and resolve the sender's
		# display name server-side (never from the payload) into the broadcast event's data.
		NetEvents.register_handler("chat", _validate_chat)
		print("[HOST] server started (peer %d) — spawning host player" % multiplayer.get_unique_id())
		# Spawn the host's own player immediately — no RPC needed.
		_spawner.spawn(_spawn_config(multiplayer.get_unique_id(), GameManager.player_name))
		NetworkManager.peer_connected.connect(_on_peer_connected)
		NetworkManager.peer_disconnected.connect(_on_peer_disconnected)
	else:
		print("[CLIENT] connected (peer %d) — requesting spawn from host" % multiplayer.get_unique_id())
		# Tell the host we're ready. call_remote fires only on the host, so
		# get_remote_sender_id() there is always a real peer ID, never 0.
		peer_ready.rpc_id(1, GameManager.player_name)
		# Only clients can lose the host. NetworkManager re-emits and nulls the peer.
		NetworkManager.server_disconnected.connect(_on_server_disconnected)


## The session root owns session lifetime, so it clears the shared pipe when it leaves the
## tree: drop stale validators (their target — this node — is going away) and reset the seq
## counter for the next session. Safe on all peers; NetEvents outlives any one session.
func _exit_tree() -> void:
	NetEvents.reset_session()


## Window close fires BEFORE node teardown, so we flip _leaving here to keep the departure hook
## quiet while the whole app quits (otherwise every player's exit would log a bogus "X left.").
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_leaving = true


func _on_peer_connected(peer_id: int) -> void:
	print("[HOST] peer %d connected" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_slots.erase(peer_id)
	var player_node := _players.get_node_or_null(str(peer_id))
	if player_node:
		# Host-only handler (connected inside the is_server() branch of _ready). Just free the
		# node — the "X left." line comes from the Players container's child_exiting_tree hook,
		# which fires on every peer (host free here, clients via spawner despawn).
		player_node.queue_free()
		print("[HOST] peer %d disconnected — freed its player" % peer_id)


# Client-side: the host left. Disconnect the transport BEFORE changing scene so a fresh
# host/join works in the same app run, then return to the menu.
func _on_server_disconnected() -> void:
	if _leaving:
		return
	_leaving = true
	print("[CLIENT] server disconnected — returning to menu")
	NetworkManager.disconnect_game()
	get_tree().change_scene_to_packed(load(GameManager.MENU_SCENE))


## Host-only. Builds the replicated spawn config. spawn_index is the server-assigned slot;
## every peer derives the same position from it in the spawn_function above.
func _spawn_config(peer_id: int, p_name: String) -> Dictionary:
	var slot := _assign_slot(peer_id)
	return {
		"peer_id": peer_id,
		"player_name": p_name,
		"spawn_index": slot,
	}


## Host-only. Lowest free slot index, so a disconnect/rejoin reuses the vacated slot
## rather than marching the index up forever.
func _assign_slot(peer_id: int) -> int:
	if _slots.has(peer_id):
		return _slots[peer_id]
	var used := {}
	for v in _slots.values():
		used[v] = true
	var slot := 0
	while used.has(slot):
		slot += 1
	_slots[peer_id] = slot
	return slot


func _slot_position(index: int) -> Vector2:
	if index < spawn_positions.size():
		return spawn_positions[index]
	# Overflow past the explicit slots: spread from the last known slot.
	var over := index - spawn_positions.size() + 1
	var base: Vector2 = spawn_positions.back() if not spawn_positions.is_empty() else Vector2.ZERO
	return base + overflow_offset * float(over)


## Host-only chat referee, registered with NetEvents in _ready. Sanitizes the wire text (strip,
## flatten control chars, clamp to chat_max_chars), rejects empty, enforces membership, and
## resolves the sender's display name server-side from their player node. Returns rewritten data
## so the broadcast carries clean body + server-resolved name — clients render only what the
## authority produced here. NetEvents defers admission to each validator, so we do it here.
func _validate_chat(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Single shared sanitizer (flattens internal newlines to spaces so one message can't
	# masquerade as several log lines, strips control chars, clamps length).
	var text := NetEvents.sanitize_wire_text(str(data.get("text", "")), chat_max_chars)
	if text.is_empty():
		return { "ok": false, "reason": "empty" }
	# Admission: only peers with a live player node are in the session. No fabricated "Peer N"
	# fallback — a sender the host can't resolve is refused outright.
	var player_node := _players.get_node_or_null(str(sender_peer_id))
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	return { "ok": true, "data": { "text": text, "name": player_node.player_name } }


# ── RPCs ──────────────────────────────────────────────────────────────────────

## Client -> host. The host decides whether to spawn this peer's player.
@rpc("any_peer", "call_remote", "reliable")
func peer_ready(p_name: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	# Duplicate guard via _slots (synchronous bookkeeping), not a node lookup: a re-sent
	# peer_ready in the same frame could race a spawn whose node isn't in the tree yet,
	# double-spawn, and break the name-IS-peer-id contract via Godot's auto-rename.
	if _slots.has(peer_id):
		return
	# The referee never trusts the wire: sanitize the client-supplied name server-side (strip,
	# flatten control chars — kills newline/NUL forgery in names — cap at 24) via the shared
	# wire-text sanitizer before it enters the replicated spawn config. The menu's UI gate is
	# UX; this is the authority's validation. Empty after sanitizing falls back to "Player".
	p_name = NetEvents.sanitize_wire_text(p_name, 24)
	if p_name.is_empty():
		p_name = "Player"
	# Capacity gate (+1 for the host itself). The transport already caps clients at
	# max_players - 1; this is the backstop — kick so an over-capacity peer falls back to
	# its menu (via server_disconnected) instead of sitting connected-but-playerless.
	# Counted via _slots (not get_child_count()): a disconnecting peer's node is freed
	# DEFERRED (queue_free), but its slot is erased immediately — so _slots never
	# over-counts and a join arriving the same frame as a disconnect isn't falsely kicked.
	if _slots.size() < GameManager.config.max_players:
		_spawner.spawn(_spawn_config(peer_id, p_name))
	else:
		NetworkManager.kick_peer(peer_id)
