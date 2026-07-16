extends Node2D

## Session root for M1 ("See Each Other"). Server-authoritative and event-synced:
##  - The HOST (peer 1) owns every player node and assigns each a spawn SLOT.
##  - Players replicate through a MultiplayerSpawner via a discrete spawn event (a config
##    dict), NOT per-frame streaming and NOT a MultiplayerSynchronizer.
##  - Clients never own nodes and never call set_multiplayer_authority; a client asks to
##    join with a plain client->host RPC (peer_ready) and the host decides.
## Nothing moves in this milestone: players just stand at their assigned spawn slots.

# Brand-new scene: referenced by res:// path until the editor assigns it a uid.
var player_scene: PackedScene = preload("res://entities/player/player.tscn")
# Loaded (not preloaded) so returning to the menu can't create a cyclic scene dependency
# with main_menu.gd, which preloads this scene.
const _MENU_SCENE_PATH := "res://ui/main_menu/main_menu.tscn"

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

# Host-only: peer_id -> spawn slot index, so a disconnect frees the slot for reuse.
var _slots: Dictionary = {}
# Client-side one-shot guard so losing the host only bails to the menu once.
var _leaving: bool = false


func _ready() -> void:
	# Runs on every peer with the same replicated config, so avatars match everywhere.
	_spawner.spawn_function = func(data):
		var player := player_scene.instantiate() as Player
		player.name = str(data.peer_id)
		player.peer_id = data.peer_id
		player.player_name = data.player_name
		player.spawn_index = int(data.spawn_index)
		player.position = _slot_position(int(data.spawn_index))
		print("[peer %d] spawned player '%s' (peer %d) at slot %d — %d player(s) total" % [
			multiplayer.get_unique_id(), player.player_name, player.peer_id,
			player.spawn_index, _players.get_child_count() + 1])
		return player

	if multiplayer.is_server():
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


func _on_peer_connected(peer_id: int) -> void:
	print("[HOST] peer %d connected" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_slots.erase(peer_id)
	var player_node := _players.get_node_or_null(str(peer_id))
	if player_node:
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
	get_tree().change_scene_to_packed(load(_MENU_SCENE_PATH))


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


# ── RPCs ──────────────────────────────────────────────────────────────────────

## Client -> host. The host decides whether to spawn this peer's player.
@rpc("any_peer", "call_remote", "reliable")
func peer_ready(p_name: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	# Duplicate guard: a re-sent peer_ready would spawn a second node Godot auto-renames,
	# breaking the name-IS-peer-id contract every host lookup relies on.
	if _players.get_node_or_null(str(peer_id)) != null:
		return
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
