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

# Room presentation. The $Room TileMapLayer is painted at runtime FROM WorldGrid (the logical
# truth) — no authored TileSet .tres, since the room is a disposable prototype fixture. Atlas
# coords are 0-indexed (col, row) into tiles.png; the legend in tiles.txt is 1-indexed by row.
const ROOM_TILES: Texture2D = preload("res://assets/32rogues/tiles.png")
const FLOOR_ATLAS := Vector2i(0, 6)  # tiles.txt row 7a — "blank floor (dark grey)"
const WALL_ATLAS := Vector2i(0, 1)   # tiles.txt row 2a — "rough stone wall (top)"

# Client-side join-handshake retry. peer_ready is fire-and-forget over RPC; if the host's
# main.tscn hasn't finished loading when it arrives (same-frame localhost joins), Godot drops
# it silently — no node at the target path. So the client resends until its own player node
# replicates in (implicit ack) or the budget runs out.
const PEER_READY_RETRY_INTERVAL_SEC := 0.5
const PEER_READY_MAX_ATTEMPTS := 10   # 10 × 0.5s = 5s, mirrors the menu's JOIN_TIMEOUT_SEC

## Server-side clamp on chat body length (chars). The referee never trusts the wire; the
## client's LineEdit does no length limiting, so the host is the only guard.
@export var chat_max_chars: int = 200

## Server-assigned spawn slots, in TILE coordinates. The host hands each player a spawn_index;
## every peer derives the same tile — and thus the same tile-center pixel position — from it, so
## there's no shared hardcoded point and no client authority. A 3x2 cluster near room center:
## six floor tiles, each ≥2 tiles from the others (none are 8-neighbours) and none 8-adjacent to
## the diagonal-gate feature, so chunk 2's corner-rule demo begins from clean ground.
@export var spawn_tiles: Array[Vector2i] = [
	Vector2i(7, 5), Vector2i(9, 5), Vector2i(11, 5),
	Vector2i(7, 8), Vector2i(9, 8), Vector2i(11, 8),
]

@onready var _spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var _players: Node2D = $Players
# Host-only movement brain. Present on every peer (it's in main.tscn) but activated ONLY inside
# the is_server() branch below, so a client's referee stays inert. Held so the spawn path can ask
# it whether a slot's tile is free before assigning it.
@onready var _referee := $MoveReferee

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

# Client-only: how many peer_ready sends we've made this session (see _send_peer_ready).
var _peer_ready_attempts: int = 0


func _ready() -> void:
	# Paint the room first, on EVERY peer, so players spawn onto a visible floor. Deterministic
	# presentation of the logical grid — same input (WorldGrid) everywhere, so it can't diverge.
	_build_room()

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
		# Derive the slot's tile once, then set both the logical tile and the pixel position from
		# it (position is the tile's center) — never reverse-convert pixels back to a tile.
		var slot_tile := _slot_tile(int(data.spawn_index))
		player.tile = slot_tile
		player.position = WorldGrid.tile_to_world(slot_tile)
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

	# Movement, on EVERY peer: play back accepted glide events, and bonk our own player when the
	# host refuses ours. Chat events flow to the game log via its own connection; these two hooks
	# handle only "glide_to" (accept) and glide rejects (sender-only).
	NetEvents.event_received.connect(_on_net_event)
	NetEvents.intent_rejected.connect(_on_intent_rejected)

	if multiplayer.is_server():
		# Host-only: hand the movement referee the Players container BEFORE spawning the host's own
		# player, so its child_entered_tree seeds occupancy for every player including the host's.
		_referee.activate(_players)
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
		# Only clients can lose the host. NetworkManager re-emits and nulls the peer.
		NetworkManager.server_disconnected.connect(_on_server_disconnected)
		# Tell the host we're ready — retried until our player node replicates in (implicit ack)
		# or the budget runs out. call_remote fires only on the host, so get_remote_sender_id()
		# there is always a real peer ID, never 0.
		_send_peer_ready()


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


## All peers: play back an accepted glide. Chat events go to the game log via its own hook; this
## reacts only to "glide_to". The event's `peer` is the mover, so every peer animates that mover's
## node — including the mover's own instance, where the glide begins ONLY now (no client predict).
func _on_net_event(event: Dictionary) -> void:
	if event.get("action", "") != "glide_to":
		return
	var mover := _players.get_node_or_null(str(event.get("peer", 0))) as Player
	if mover == null:
		return
	var data: Dictionary = event.get("data", {})
	mover.glide_to(data.get("to"), float(data.get("duration_sec", 0.0)))


## Sender only: the host refused our glide. Bonk our OWN player (§2.3.4 — the sound+visual half;
## the game log adds the line via its own connection). Rejects reach only the sender, so the
## local player is always the right target.
func _on_intent_rejected(action: String, reason: String) -> void:
	if action != "glide_to":
		return
	var me := _players.get_node_or_null(str(multiplayer.get_unique_id())) as Player
	if me != null:
		me.play_bonk()


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


# Client-only. Resends peer_ready until the host acknowledges by replicating our player node in,
# or we exhaust the budget and give up. No stale-token bookkeeping (unlike main_menu.gd's join
# timer): this SceneTreeTimer's timeout targets a method of THIS node, so the connection
# auto-disconnects when Main is freed on scene change — a pending retry can't outlive the session.
func _send_peer_ready() -> void:
	if _leaving:
		return
	# Implicit ack: our player node (named str(peer_id)) replicated into $Players via the spawner.
	# Checked BEFORE the attempts cap so a spawn that arrived on the final tick still wins — the
	# handshake is complete and we must not fall through to the timeout give-up.
	if _players.get_node_or_null(str(multiplayer.get_unique_id())) != null:
		return
	if _peer_ready_attempts >= PEER_READY_MAX_ATTEMPTS:
		_end_session("No response from host.")
		return
	_peer_ready_attempts += 1
	# The host handler is idempotent via _slots, so a retry racing an in-flight spawn is harmless
	# (duplicate guard early-returns). The one narrow race — a spawn in flight during the final
	# 500ms — loses cleanly: the client returns to menu and the host frees the orphan player on
	# the resulting disconnect.
	peer_ready.rpc_id(1, GameManager.player_name)
	get_tree().create_timer(PEER_READY_RETRY_INTERVAL_SEC).timeout.connect(_send_peer_ready)


## Client-side teardown funnel. Every "session over, back to menu" path — host left, kicked,
## handshake timeout — routes through here so they share one reason surface (stashed in
## GameManager for the menu to show once). Disconnect the transport BEFORE changing scene so a
## fresh host/join works in the same app run. First-writer-wins: a nested/second call is swallowed
## by the _leaving guard, so the first known cause survives.
func _end_session(reason: String) -> void:
	if _leaving:
		return
	_leaving = true
	GameManager.last_disconnect_reason = reason
	print("[CLIENT] session ended (%s) — returning to menu" % reason)
	NetworkManager.disconnect_game()
	get_tree().change_scene_to_packed(load(GameManager.MENU_SCENE))


# Client-side: the host left — or kicked us (capacity), which arrives the same way and shares
# this generic message. A distinct "Server is full." needs transport-level flush-before-disconnect
# support (a same-frame kick drops the reliable reason packet) and is parked.
func _on_server_disconnected() -> void:
	_end_session("Disconnected from host.")


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
	# Skip a slot whose tile is already held by a body (a player may have glided onto another
	# slot's spawn tile since — spawn tiles are legal glide targets). Falls to the next free slot.
	var slot := 0
	while used.has(slot) or _slot_occupied(slot):
		slot += 1
	_slots[peer_id] = slot
	return slot


## Host-only guard for _assign_slot: is this slot's tile currently held by a body, per the
## referee's authoritative occupancy? A no-op off-host or before the referee is active (clients
## never assign slots), so the walkable-tile derivation stays a pure function everywhere else.
func _slot_occupied(slot: int) -> bool:
	if not multiplayer.is_server() or _referee == null:
		return false
	return not _referee.is_tile_free(_slot_tile(slot))


## The tile for a spawn slot — the single slot->tile accessor; the spawn path derives both
## player.tile and the pixel position (tile center) from it, so every peer computes the same
## spot with no position ever crossing the wire. Explicit slots come from spawn_tiles; anything
## past the list overflows deterministically: the N-th overflow slot is the N-th walkable tile
## in row-major scan order that isn't an explicit spawn tile — guaranteed walkable and distinct
## while any free floor remains. max_players (6) matches the slot count, so overflow is a
## belt-and-braces guard, not a normal path.
func _slot_tile(index: int) -> Vector2i:
	if index < spawn_tiles.size():
		return spawn_tiles[index]
	var over := index - spawn_tiles.size() + 1  # 1-based overflow index
	var grid_size := WorldGrid.size()
	var seen := 0
	for y in grid_size.y:
		for x in grid_size.x:
			var t := Vector2i(x, y)
			if not WorldGrid.is_walkable(t) or t in spawn_tiles:
				continue
			seen += 1
			if seen == over:
				return t
	# The room ran out of free floor — should be unreachable at any sane player count.
	push_warning("No free floor tile for overflow spawn slot %d — reusing the last explicit slot" % index)
	return spawn_tiles.back() if not spawn_tiles.is_empty() else Vector2i(1, 1)


## Build the room's TileSet in code and paint $Room from WorldGrid. Runs on every peer with the
## same input, so the picture is a deterministic function of the logical grid and can't diverge.
## Presentation only — nothing here is adjudication state; WorldGrid stays the single truth.
func _build_room() -> void:
	var atlas := TileSetAtlasSource.new()
	atlas.texture = ROOM_TILES
	atlas.texture_region_size = Vector2i(WorldGrid.TILE_PX, WorldGrid.TILE_PX)
	# One floor tile, one wall tile — the only two glyphs ROOM_LAYOUT uses.
	atlas.create_tile(FLOOR_ATLAS)
	atlas.create_tile(WALL_ATLAS)

	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(WorldGrid.TILE_PX, WorldGrid.TILE_PX)
	var source_id := tile_set.add_source(atlas)
	$Room.tile_set = tile_set

	var grid_size := WorldGrid.size()
	for y in grid_size.y:
		for x in grid_size.x:
			var cell := Vector2i(x, y)
			var atlas_coords := WALL_ATLAS if WorldGrid.is_wall(cell) else FLOOR_ATLAS
			$Room.set_cell(cell, source_id, atlas_coords)


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
