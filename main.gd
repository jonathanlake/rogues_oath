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
const MONSTER_SCENE: PackedScene = preload("res://entities/monster/monster.tscn")
const GAME_LOG_SCENE: PackedScene = preload("res://ui/game_log/game_log.tscn")

# The one monster kind for M3, loaded per-peer from this PATH (the spawn config carries the path,
# never a Resource over the wire — every peer loads the same authored .tres). Brand-new resource:
# referenced by res:// path until the editor assigns it a uid.
const GOBLIN_TYPE_PATH := "res://resources/monsters/goblin.tres"

# The single goblin's spawn tile (plan §Chunk 1). Map-coupled: the spawn is guarded by
# is_walkable + is_tile_free so a future room edit that walls this tile skips the spawn instead of
# dropping a goblin into a wall.
const GOBLIN_SPAWN_TILE := Vector2i(16, 8)

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

## Presentation only: the multiply applied to alternate floor tiles for the subtle grid
## checkerboard. Alpha stays 1 — modulate multiplies the floor texture, so this reads as the
## slightly darker grey squares against the same background. Tweak to taste.
@export var floor_checker_modulate: Color = Color(0.85, 0.85, 0.9, 1.0)

@onready var _spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var _players: Node2D = $Players
# Monster replication, mirroring the player spawner/container. Present on every peer; the host
# authors monster spawns, clients just play back the replicated nodes. The container is resolved on
# all peers (glide events for monsters animate their node everywhere), the spawner drives from host.
@onready var _monster_spawner: MultiplayerSpawner = $MonsterSpawner
@onready var _monsters: Node2D = $Monsters
# Host-only movement brain. Present on every peer (it's in main.tscn) but activated ONLY inside
# the is_server() branch below, so a client's referee stays inert. Held so the spawn path can ask
# it whether a slot's tile is free before assigning it.
@onready var _referee := $MoveReferee
# Host-only combat authority (HP / damage / death), beside the movement referee. Same inert-on-
# clients contract — activate() runs only in the is_server() branch. Held so the monster spawn path
# can hand it to each brain and the late-join snap can query liveness.
@onready var _combat := $CombatReferee
# Death SFX (placeholder — pitch-shifted bonk). Played on every peer from the `died` event, at Main
# level because the dying entity's own node vanishes with the event (can't play a sound on a freed node).
@onready var _death_sfx: AudioStreamPlayer = $DeathSfx

# Chat/combat log, added on every peer in _ready. Held so spawn/disconnect can post system
# lines through it. Set before the host spawns its own player so that spawn's "joined." lands.
var _game_log: Node = null

# Host-only: peer_id -> spawn slot index, so a disconnect frees the slot for reuse.
var _slots: Dictionary = {}
# Host-only monotonic monster id source (plan decision 5): each monster gets the next NEGATIVE int,
# so monster ids never collide with peer ids (always positive) in the referee's one occupancy space.
var _next_monster_id: int = -1
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

	# Monster spawn_function, on EVERY peer with the same replicated config, so the avatar matches
	# everywhere. The config carries the type PATH (not a Resource) + host-assigned entity id + tile;
	# every peer loads the same .tres and derives the same sprite/position. The brain is activated
	# ONLY on the host (deferred so the referee's enter hook has seeded occupancy and _ready has run
	# before the first think) — a client's brain stays inert.
	_monster_spawner.spawn_function = func(data):
		var monster := MONSTER_SCENE.instantiate() as Monster
		monster.name = str(data.entity_id)
		monster.entity_id = int(data.entity_id)
		monster.monster_type = load(data.type_path) as MonsterType
		var tile: Vector2i = data.tile
		monster.tile = tile
		monster.position = WorldGrid.tile_to_world(tile)
		if multiplayer.is_server():
			monster.activate_brain.call_deferred(_referee, _combat)
		print("[peer %d] spawned monster '%s' (entity %d) at tile %s" % [
			multiplayer.get_unique_id(), monster.name, monster.entity_id, tile])
		return monster

	# Movement, on EVERY peer: play back accepted glide events, and bonk our own player when the
	# host refuses ours. Chat events flow to the game log via its own connection; these two hooks
	# handle only "glide_to" (accept) and glide rejects (sender-only).
	NetEvents.event_received.connect(_on_net_event)
	NetEvents.intent_rejected.connect(_on_intent_rejected)

	if multiplayer.is_server():
		# Self-diagnosing surface — the feedback rule (§2.3.4) extended to session plumbing:
		# which port this host actually bound must never require netstat. Both 2026-07 wire-test
		# failures were exactly this made invisible (the field's :port silently applied to
		# hosting). The log node was added above in this same _ready, so it exists here.
		var hosting_line := "Hosting on port %d." % NetworkManager.current_port()
		if GameManager.host_port_was_ignored:
			hosting_line += " (remote address in field — its port was ignored)"
		_game_log.add_line(hosting_line)
		# Host-only: hand the movement referee the Players container BEFORE spawning the host's own
		# player, so its child_entered_tree seeds occupancy for every player including the host's.
		_referee.activate(_players)
		# Host-only: hand it the Monsters container too, BEFORE spawning any monster, so the monster
		# enter hook seeds occupancy for the goblin. set_monsters connects the referee's seed hook
		# first; the goblin spawns later in this same _ready, after the host's own player.
		_referee.set_monsters(_monsters)
		# Host-only: activate the combat referee AFTER the movement referee is set up and BEFORE any
		# spawn — its container enter hooks then seed HP for every entity (host player + goblin), and
		# the two referees hold each other's references so bump/AoO/wind-up/death can cross-call. Then
		# hand the movement referee the combat reference so its first adjudication has it.
		_combat.activate(_players, _monsters, _referee)
		_referee.set_combat(_combat)
		# Host-only: snap autonomous movers to truth for a late joiner (no event replay exists,
		# §2.7). Fires as each new PLAYER node enters; wired here before the host's own player spawns.
		_players.child_entered_tree.connect(_on_player_spawned_host)
		# Host-only: the chat referee. Strip, reject empty, clamp, and resolve the sender's
		# display name server-side (never from the payload) into the broadcast event's data.
		NetEvents.register_handler("chat", _validate_chat)
		print("[HOST] server started (peer %d) — spawning host player" % multiplayer.get_unique_id())
		# Spawn the host's own player immediately — no RPC needed.
		_spawner.spawn(_spawn_config(multiplayer.get_unique_id(), GameManager.player_name))
		# Host-only: seed the world with M3's single goblin, AFTER the host player so occupancy is
		# already populated for the is_tile_free guard. Off by default in the autostart harness
		# (goblin= knob); on by default for menu play (GameManager.spawn_monsters).
		if GameManager.spawn_monsters:
			_spawn_goblin()
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


## All peers: play back a broadcast gameplay event. Chat + combat-LOG lines go to the game log via
## its own hook; this drives the NODE-side presentation (movement + combat feedback). The event's
## `peer`/ids identify the mover/attacker/target; every peer animates the same nodes from the one
## ordered stream — no client prediction (the glide/hit begins ONLY now).
func _on_net_event(event: Dictionary) -> void:
	match str(event.get("action", "")):
		"glide_to":
			_handle_glide_event(event)
		"attack":
			_handle_attack_event(event)
		"windup":
			_handle_windup_event(event)
		"died":
			_handle_died_event(event)


## Play back an accepted glide. Resolve the mover by entity id: positive is a player, negative a
## monster (its glide rides the same event path, posted by the referee with as_peer = the negative
## id). Both nodes expose glide_to(to, duration_sec), so one call animates either.
func _handle_glide_event(event: Dictionary) -> void:
	var mover = _node_for_peer(int(event.get("peer", 0)))
	if mover == null:
		return
	var data: Dictionary = event.get("data", {})
	mover.glide_to(data.get("to"), float(data.get("duration_sec", 0.0)))


## Play back a landed (or whiffed) attack (§2.3.4). All peers: the attacker lunges toward the target
## + swing sound; on a real hit the target red-flashes and its nameplate updates from hp_after. On a
## whiff (a resolved wind-up against empty ground) only the attacker's swing plays. Additionally, on
## the LOCAL player's OWN bump, drive its busy/blocked window (decision 2) — the bump adjudicated as a
## `deferred` verdict, so this event (not a glide_to) is what clears the input latch and holds the swing.
func _handle_attack_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var attacker_id := int(data.get("attacker_id", 0))
	var target_id := int(data.get("target_id", 0))
	var kind := str(data.get("kind", ""))
	var whiff := bool(data.get("whiff", false))
	var attacker = _node_for_peer(attacker_id)
	var target = _node_for_peer(target_id)
	# Direction of the strike, for the attacker's directional lunge. Prefer the two nodes' tiles; on
	# a whiff (no target node) fall back to the event's committed target_tile.
	var dir := Vector2i.ZERO
	if attacker != null:
		if target != null:
			dir = _step_sign(target.tile - attacker.tile)
		elif data.has("target_tile"):
			dir = _step_sign((data.get("target_tile") as Vector2i) - attacker.tile)
	if whiff:
		if attacker != null:
			attacker.play_whiff(dir)
	else:
		if attacker != null:
			attacker.play_attack(dir)
		if target != null:
			target.play_hurt()
			target.set_hp_display(int(data.get("hp_after", 0)), int(data.get("target_max", 0)))
	# Local attacker's swing-busy mirror for a bump (decision 2) — players only (positive id).
	if kind == "bump" and attacker_id == multiplayer.get_unique_id() and attacker != null:
		attacker.commit_in_place(float(data.get("duration_sec", 0.0)))


## Play back a monster wind-up telegraph (§2.3.4): the monster yellow-flashes + a telegraph sound on
## every peer, rendered on the monster node (the log line comes from game_log). Clients render the
## tell from the authoritative event, never locally-inferred facing.
func _handle_windup_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var monster = _node_for_peer(int(data.get("entity_id", 0)))
	if monster != null:
		monster.play_windup()


## Play back a death (§2.3.4): the death sound on every peer (Main-level — the node itself vanishes
## with the spawner despawn the host authored). The game-log line comes from game_log's own handler,
## and the node's disappearance is the visual.
func _handle_died_event(_event: Dictionary) -> void:
	_death_sfx.play()


## Host-only: a new PLAYER node just entered — mend autonomous-mover state for a possible late joiner.
## No late-join event replay exists (§2.7, by design), so a client that joined after the goblin moved
## renders it at its stale spawn-config tile. Post one micro snap glide_to per LIVING monster (from ==
## to == its authoritative tile, 0.05s) on the normal event path (as_peer = monster id): the joiner's
## stale node glides to truth, everyone else no-ops a same-tile micro-glide. Players are NOT snapped
## (out of scope — they sit at spawn during the join window by convention). Minimal §2.7-compliant mend.
func _on_player_spawned_host(node: Node) -> void:
	if not (node is Player):
		return
	for m in _monsters.get_children():
		if not (m is Monster):
			continue
		if not _combat.is_alive(m.entity_id):
			continue
		var cur: Vector2i = _referee.tile_of_entity(m.entity_id)
		if WorldGrid.is_wall(cur):
			continue  # untracked / despawning — no truth to snap to
		# Snap only IDLE monsters: post_event broadcasts to everyone, and a snap landing on a
		# mid-glide monster would kill its running tween on every EXISTING peer (a visible pop).
		# A gliding monster self-corrects for the joiner anyway: its very next glide event tweens
		# from wherever the stale node renders to the true destination (idempotent-late-safe).
		if _referee.is_entity_moving(m.entity_id):
			continue
		NetEvents.post_event("glide_to", { "from": cur, "to": cur, "duration_sec": 0.05 }, m.entity_id)


## Sign of each axis of a delta, clamped to an 8-way step {-1,0,1}² — used to point an attacker's
## directional lunge at its target without assuming the two are exactly one tile apart.
func _step_sign(delta: Vector2i) -> Vector2i:
	return Vector2i(signi(delta.x), signi(delta.y))


## All peers: resolve an entity id to its avatar node — players in $Players, monsters (negative id)
## in $Monsters. Both containers are plain scene nodes present on every peer, so this works on the
## client (where the referee is inert) too. The referee has its own id->node helper for host-side
## adjudication; this is the presentation-side mirror.
func _node_for_peer(entity_id: int) -> Node:
	if entity_id < 0:
		return _monsters.get_node_or_null(str(entity_id))
	return _players.get_node_or_null(str(entity_id))


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


## Host-only. Spawn M3's single goblin at its map-coupled tile, guarded so a future room edit that
## walls or fills the tile skips the spawn (push_warning) instead of dropping a goblin into a wall
## or onto a body. The entity id is the next negative int; the config carries the type PATH so every
## peer loads the same authored .tres (never a Resource over the wire).
func _spawn_goblin() -> void:
	var tile := GOBLIN_SPAWN_TILE
	if not WorldGrid.is_walkable(tile) or not _referee.is_tile_free(tile):
		push_warning("[Main] goblin spawn tile %s not walkable/free — skipping (map-coupled)" % tile)
		return
	var entity_id := _next_monster_id
	_next_monster_id -= 1
	_monster_spawner.spawn({
		"entity_id": entity_id,
		"type_path": GOBLIN_TYPE_PATH,
		"tile": tile,
	})


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
	# A second FLOOR variant for the checkerboard: same texture region, tinted darker via TileData
	# modulate. An alternative tile costs nothing per-frame (it's authored into the source) and adds
	# no new nodes — the paint loop just picks it for the odd cells below.
	var floor_alt_id := atlas.create_alternative_tile(FLOOR_ATLAS)
	atlas.get_tile_data(FLOOR_ATLAS, floor_alt_id).modulate = floor_checker_modulate

	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(WorldGrid.TILE_PX, WorldGrid.TILE_PX)
	var source_id := tile_set.add_source(atlas)
	$Room.tile_set = tile_set

	var grid_size := WorldGrid.size()
	for y in grid_size.y:
		for x in grid_size.x:
			var cell := Vector2i(x, y)
			if WorldGrid.is_wall(cell):
				$Room.set_cell(cell, source_id, WALL_ATLAS)
			else:
				# Checkerboard: odd (x+y) floor cells get the darker alternative tile, even cells
				# the default (alt id 0). Walls are never checkered.
				var alt := floor_alt_id if (cell.x + cell.y) % 2 == 1 else 0
				$Room.set_cell(cell, source_id, FLOOR_ATLAS, alt)


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
