extends Node2D

## Session root (through M3). Server-authoritative and event-synced — it paints the room,
## spawns the world, plays back committed events, and tears the session down:
##  - Paints the $Room TileMapLayer at runtime from WorldGrid (the logical truth).
##  - The HOST (peer 1) owns every player + monster node and assigns each a spawn SLOT; players
##    and the goblin replicate through a MultiplayerSpawner via a discrete spawn event (a config
##    dict), NOT per-frame streaming and NOT a MultiplayerSynchronizer.
##  - Dispatches NetEvents playback: a validated glide_to/attack/windup/chat/died event arrives
##    on every peer and Main drives the matching node (glide, attack cue, log line, despawn).
##  - Validates chat and gates the version at peer_ready (a client on a mismatched build is
##    refused with a reason).
##  - Clients never own nodes and never call set_multiplayer_authority; a client asks to
##    join with a plain client->host RPC (peer_ready) and the host decides.

# uid preloads per convention (CLAUDE.md) — rename/move-safe. Immutable, so const (consts
# legitimately precede @export in script order).
const PLAYER_SCENE: PackedScene = preload("uid://dvvmk452g1xhs")   # entities/player/player.tscn
const MONSTER_SCENE: PackedScene = preload("uid://ctlrcci4jrejt")  # entities/monster/monster.tscn
const GAME_LOG_SCENE: PackedScene = preload("uid://djd1d1pf44yi2") # ui/game_log/game_log.tscn

# The one monster kind for M3, loaded per-peer from this PATH (the spawn config carries the path,
# never a Resource over the wire — every peer loads the same authored .tres). Deliberately a
# res:// STRING, not a uid preload: it crosses the wire as spawn-config data, and both ends run
# the same build (version gate), so the readable path is the stable, comparable form.
const GOBLIN_TYPE_PATH := "res://resources/monsters/goblin.tres"

# Goblin spawn tiles, one per far room so the multi-room map (M3.5) is populated and cross-room
# aggro/chase gets exercised: B (top-right), C (centre), E (bottom-right). Map-coupled: each spawn
# is guarded by is_walkable + is_tile_free, so a future room edit that walls a tile skips that goblin
# instead of dropping it into a wall. The autostart goblin=N knob caps how many actually spawn
# (GameManager.monster_spawn_cap); menu play spawns them all.
const GOBLIN_SPAWN_TILES: Array[Vector2i] = [
	Vector2i(38, 6),   # room B
	Vector2i(23, 14),  # room C
	Vector2i(39, 21),  # room E
]

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
## there's no shared hardcoded point and no client authority. A 3x2 cluster in the start room (A,
## top-left of the M3.5 map): six floor tiles, each ≥2 tiles from the others (none are 8-neighbours)
## and clear of A's pillar (10,4) and the col-7 corridor mouth, so the party begins on clean ground.
@export var spawn_tiles: Array[Vector2i] = [
	Vector2i(3, 3), Vector2i(6, 3), Vector2i(9, 3),
	Vector2i(3, 6), Vector2i(6, 6), Vector2i(9, 6),
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
# LOCAL-only hurt vignette (v0.6.3 hit juice): a full-rect red ColorRect on a high CanvasLayer
# (main.tscn), alpha 0 at rest, pulsed ONLY when OUR OWN avatar takes a hit. mouse_filter IGNORE so
# it never eats input. Pure local presentation — never replicated, never adjudication.
@onready var _hurt_vignette: ColorRect = $HurtVignette/Overlay
# Per-peer follow camera (M3.5). Lives under Main (not the avatar) so it SURVIVES the local avatar's
# despawn on death — _update_camera stops tracking and it holds its last position instead of the view
# snapping to origin. Pure local presentation: it reads only THIS peer's own avatar node, nothing
# crosses the wire.
@onready var _camera: Camera2D = $Camera
# Always-on tempo readout (DESIGN §2.8.3), top-center. Session UI only (in main.tscn, never the menu).
@onready var _tempo_label: Label = $TempoDisplay/Label

# Chat/combat log, added on every peer in _ready. Held so spawn/disconnect can post system
# lines through it. Set before the host spawns its own player so that spawn's "joined." lands.
var _game_log: Node = null

# Host-only: peer_id -> spawn slot index, so a disconnect frees the slot for reuse.
var _slots: Dictionary = {}
# Host-only reset roster (v0.5.4 dev key): peer_id -> player_name, captured at each spawn site (the
# host's own in _ready, clients' in peer_ready post-sanitize) and erased on disconnect. The round
# reset's respawn pass reads ONLY this — a player's name otherwise lives on its node, and a DEAD peer
# (host or client) has no node to scrape, so this is the one source that survives a re-seed of the world.
var _peer_names: Dictionary = {}
# Host-only: peer_ids we have refused (never admitted) this session — version mismatch or capacity.
# Set in _refuse_peer, checked FIRST in peer_ready (silent early return, before the _slots duplicate
# guard), erased in _on_peer_disconnected. Suppresses same-connection retry spam (a refused client
# keeps resending peer_ready every 0.5s until its kick lands) AND closes the flush-window
# re-admission race: while a kick is still flushing, a freed slot plus a fast retry could otherwise
# re-admit the very peer being kicked. A genuinely fresh reconnection arrives on a NEW peer_id (the
# old one was erased on its disconnect) and gets a fresh adjudication by design.
var _refused: Dictionary = {}
# Host-only monotonic monster id source (plan decision 5): each monster gets the next NEGATIVE int,
# so monster ids never collide with peer ids (always positive) in the referee's one occupancy space.
var _next_monster_id: int = -1
# Client/teardown guard. Set true when THIS peer's session is ending (returning to menu, app quit,
# host-left, refusal): while set, the client stops resending peer_ready and _end_session is
# first-writer-wins. INVARIANT: any deliberate session-teardown path added later (host quit-to-menu,
# etc.) MUST set _leaving = true before it tears anything down. (v0.6.3: it no longer mutes a
# departure log — departures ride transport truth now, see _on_peer_departed — but the guard stands.)
var _leaving: bool = false

# Client-only: how many peer_ready sends we've made this session (see _send_peer_ready).
var _peer_ready_attempts: int = 0
# Kill-prior slot for the local hurt vignette pulse (v0.6.3), so rapid hits replace rather than stack.
var _vignette_tween: Tween = null
# The local peer's own avatar node, tracked by _update_camera. Null until our player spawns (or after
# our death); (re)acquired lazily from $Players by our peer id, so first spawn, late join, and F5
# respawn all re-attach the camera uniformly. Local presentation only — never read for adjudication.
var _local_avatar: Node2D = null


func _ready() -> void:
	# Seed the session tempo (DESIGN §2.8) BEFORE any verdict is stamped, on EVERY peer: the authored
	# GameConfig.beat_sec, or the host-only beatsec= debug override when set (mirrors glidesec=). The
	# referees read GameManager.current_beat_sec LIVE at stamp time from here; a future runtime tempo
	# knob (§2.8.3) rebroadcasts a new value. Same value on host and client at start (same authored
	# config, same build), so client-side pacing matches until the knob ships.
	GameManager.current_beat_sec = GameManager.debug_beat_override_sec if GameManager.debug_beat_override_sec > 0.0 else GameManager.config.beat_sec
	# Seed the always-on tempo readout from that same value, on EVERY peer, so it is correct before any
	# set_tempo event (§2.8.3). A late joiner's host-supplied beat (sync_tempo below) refreshes it.
	_update_tempo_display()

	# Paint the room first, on EVERY peer, so players spawn onto a visible floor. Deterministic
	# presentation of the logical grid — same input (WorldGrid) everywhere, so it can't diverge.
	_build_room()

	# Add the log first, on EVERY peer, so the very first spawn's "joined." line has somewhere
	# to go (the host spawns its own player later in this same _ready).
	_game_log = GAME_LOG_SCENE.instantiate()
	add_child(_game_log)

	# Departure lines come from TRANSPORT truth now (v0.6.3), NOT node-exit. The old
	# _players.child_exiting_tree "X left." hook fired on death AND on F5 reset too — both keep the
	# peer connected — so those produced phantom "left." lines (the v0.5.6 open item). A real transport
	# disconnect is the only true departure, so it is logged from NetworkManager.peer_disconnected.
	# Connected here on EVERY peer and BEFORE the host's _on_peer_disconnected cleanup (below, in the
	# is_server branch), so the logger resolves the leaver's name while it still exists: signal
	# callbacks fire in connection order, and _on_peer_disconnected erases _peer_names, so this must
	# run first. (This is also why _resetting no longer exists — muting node-exit was its only job.)
	NetworkManager.peer_disconnected.connect(_on_peer_departed)

	# Runs on every peer with the same replicated config, so avatars match everywhere.
	_spawner.spawn_function = func(data):
		var player := PLAYER_SCENE.instantiate() as Player
		player.name = str(data.peer_id)
		player.peer_id = data.peer_id
		# Entity id = peer id (plan decision 5), assigned PRE-tree like tile: the referees' unified
		# container enter hooks read node.entity_id BEFORE _ready runs, so it must be a pre-tree
		# fact here (player._ready re-assigns the same value — harmless).
		player.entity_id = data.peer_id
		player.player_name = data.player_name
		# display_name is the one name surface the referees read at attack time — assigned PRE-tree
		# here (like entity_id/max_hp) so it's correct on every peer at ANY read time, never a
		# _ready-timed field. data.player_name is server-sanitized, never empty.
		player.display_name = data.player_name
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
		# max_hp mirrored from the type PRE-tree (alongside entity_id/tile) so it's a uniform
		# pre-tree Entity fact for both kinds: the combat referee's enter hook seeds HP from
		# node.max_hp BEFORE _ready runs. A missing type reads 0 — never alive; monster._ready
		# still fires its spawn-config warning.
		monster.max_hp = monster.monster_type.max_hp if monster.monster_type != null else 0
		# display_name mirrored from the type PRE-tree (alongside max_hp) so it's a uniform pre-tree
		# Entity fact for both kinds, correct at any read time. The explicit null-check ternary is
		# required: monster_type CAN be null on a broken type_path, so "Monster" is the fallback and
		# monster._ready's null-type early return then just leaves this pre-set value intact.
		monster.display_name = monster.monster_type.display_name if monster.monster_type != null else "Monster"
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
		# Host-only: the tempo referee (DESIGN §2.8.3). ANY peer submits a set_tempo intent on the same
		# pipe; this validator clamps/snaps/applies host-side, and the accepted intent broadcasts back as
		# a set_tempo event (intent-name == event-name, like "chat") that every peer adopts. Gameplay only
		# ever reads GameManager.current_beat_sec, which no client can write (§2.5 stands).
		NetEvents.register_handler("set_tempo", _validate_set_tempo)
		print("[HOST] server started (peer %d) — spawning host player" % multiplayer.get_unique_id())
		# Spawn the host's own player immediately — no RPC needed. (_spawn_config records the reset
		# roster entry as a side effect — the one chokepoint every spawn path shares.)
		_spawner.spawn(_spawn_config(multiplayer.get_unique_id(), GameManager.player_name))
		# Host-only: seed the world with the map's goblins, AFTER the host player so occupancy is
		# already populated for the is_tile_free guard. Off by default in the autostart harness
		# (goblin= knob); on by default for menu play (GameManager.spawn_monsters).
		if GameManager.spawn_monsters:
			_spawn_goblins()
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
	# A debug version override (fakever=) is scoped to the session it was launched for — clear it so
	# a manual re-join from the menu in the same app run sends the REAL build version, not a stale fake.
	GameManager.debug_fake_version = ""


## Window close fires BEFORE node teardown, so we flip _leaving here so a client mid-join stops
## resending peer_ready and any _end_session becomes a no-op while the whole app quits.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_leaving = true


## Host-only dev round-reset key (v0.5.4, F5) — a wire-session facility, NOT a game mechanic (see
## _reset_round for the WORLD-re-seed framing). Host-gated at the source: only the server acts, so
## there is no client->host RPC surface and no client-side reset lever — a client's F5 is a silent
## no-op, which is acceptable for a dev key and stated here so it reads as deliberate, not a missing
## branch. Handled (_unhandled_input) so a focused chat LineEdit consumes its own keys first; the
## event is consumed whenever the action fires so F5 never falls through to anything else.
## call_deferred, not a direct call: the reset frees nodes synchronously, and doing that from
## inside input dispatch could perturb the same frame's input iteration — deferring runs the whole
## reset in the idle deferred-flush phase, where the reset body is the only thing on the stack.
## (Held-key echoes are already filtered: is_action_pressed defaults to allow_echo=false.)
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("dev_reset_round"):
		if multiplayer.is_server():
			_reset_round.call_deferred()
		get_viewport().set_input_as_handled()
	# Tempo knob (DESIGN §2.8.3): +/- from ANY peer. tempo_up = faster (fewer seconds/beat), tempo_down
	# = slower. Handled here (like dev_reset_round) so a focused chat LineEdit consumes its own +/- keys
	# first. The step is applied by the HOST authority — we only submit a request.
	elif event.is_action_pressed("tempo_up"):
		_request_tempo(-GameManager.config.tempo_step_sec)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tempo_down"):
		_request_tempo(GameManager.config.tempo_step_sec)
		get_viewport().set_input_as_handled()


## Per-peer local camera follow (M3.5), every frame on every peer. Pure presentation — reads only our
## own avatar node (see _update_camera); nothing crosses the wire.
func _process(_delta: float) -> void:
	_update_camera()


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
		"set_tempo":
			# An accepted set_tempo intent broadcasts under its own action name (like "chat"), NOT a
			# separate "tempo_changed" — the whole party adopts the new beat from this one event.
			_handle_tempo_changed_event(event)


## Play back an accepted glide. Resolve the mover by entity id: positive is a player, negative a
## monster (its glide rides the same event path, posted by the referee with as_peer = the negative
## id). Both nodes expose glide_to(to, duration_sec), so one call animates either.
func _handle_glide_event(event: Dictionary) -> void:
	var mover := _node_for_peer(int(event.get("peer", 0)))
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
	var attacker := _node_for_peer(attacker_id)
	var target := _node_for_peer(target_id)
	# Direction of the strike, for the attacker's directional lunge. Prefer the two nodes' tiles; on
	# a whiff (no target node) fall back to the event's committed target_tile.
	var dir := Vector2i.ZERO
	if attacker != null:
		if target != null:
			dir = _step_sign(target.tile - attacker.tile)
		elif data.has("target_tile"):
			dir = _step_sign((data.get("target_tile") as Vector2i) - attacker.tile)
	if whiff:
		# Whiff cues are Monster surface (only a wind-up whiffs in M3) — deliberate narrow cast.
		var whiffer := attacker as Monster
		if whiffer != null:
			whiffer.play_whiff(dir)
		else:
			# Whiffs are structurally monster-only today (only _resolve_windup emits them, only
			# brains wind up), so a non-Monster whiffer is a future-shape break — §2.3.4 forbids an
			# outcome being silently swallowed, so name the unhandled attacker instead of dropping it.
			push_warning("[Main] whiff attack from non-Monster attacker %d — no feedback rendered" % attacker_id)
	else:
		# LANDED hit — audio-trim rule (v0.6.0, §2.3.4 feedback audit). The attacker lunges (bowstring)
		# but its swing sound is SUPPRESSED (with_sound=false): a landed exchange plays exactly ONE
		# sound, the target's hit. Per-outcome distinctness still holds — landed hit = target hit sound,
		# whiff = the attacker's swing (play_whiff above, kept audible), reject = bonk (play_bonk) — so
		# every outcome is uniquely audible, one sound each, none confusable (§2.2.8 / §2.3.4).
		if attacker != null:
			# Swing sound RESTORED (v0.6.2, Jon: attack must be audible AND distinct from the hit —
			# swing = high short whoosh, impact = low thud; pitch-separated in the scenes).
			attacker.play_attack(dir, true)
		if target != null:
			# dir passed through so the victim's slash streak reads directional (v0.6.3), derived
			# per-peer from this same event — no new wire data.
			target.play_hurt(dir)
			target.set_hp_display(int(data.get("hp_after", 0)), int(data.get("target_max", 0)))
		# LOCAL-only red hit vignette (v0.6.3 juice): fires ONLY when it's OUR OWN avatar being struck
		# (landed — we're already past the whiff branch). Pure local presentation off the same attack
		# event every peer receives; the target's slash streak + flash still render on every peer.
		if target_id == multiplayer.get_unique_id():
			_flash_hurt_vignette()
	# Recovery tell (§2.3.4; DESIGN §2.8): the attacker is SPENT for the recovery window the event
	# carries in duration_sec — a bump (player) and an instant strike (goblin windup_beats==0) both
	# stamp it; an AoO free attack and a telegraphed-windup landed hit carry 0 (play_recovery no-ops).
	# Played on the attacker node on EVERY peer (whiff or landed), so the spent window matches the
	# host's busy record on the wire — no new sync, same event the whole party already receives.
	if attacker != null:
		attacker.play_recovery(float(data.get("duration_sec", 0.0)))
	# Local attacker's swing-busy mirror for a bump (decision 2) — players only (positive id), so
	# commit_in_place is Player surface: deliberate narrow cast, not cruft.
	if kind == "bump" and attacker_id == multiplayer.get_unique_id():
		var local_attacker := attacker as Player
		if local_attacker != null:
			local_attacker.commit_in_place(float(data.get("duration_sec", 0.0)))


## Play back a monster wind-up telegraph (§2.3.4): the monster white-flashes + coils back + a
## telegraph sound on every peer, rendered on the monster node (the log line comes from game_log).
## Clients render the tell from the authoritative event, never locally-inferred facing. The coil's
## away-direction is derived here (per-peer presentation) from the monster's CURRENT tile and the
## committed target_tile the event carries — sign per axis, the same shape the bowstring dir uses.
## hold_sec rides the event as windup_sec (host-authored / debug-overridden), so the coil holds
## exactly the telegraph window on every peer.
func _handle_windup_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	# Wind-up cues are Monster surface — deliberate narrow cast off the Entity resolver.
	var monster := _node_for_peer(int(data.get("entity_id", 0))) as Monster
	if monster != null:
		var target_tile: Vector2i = data.get("target_tile", monster.tile)
		var dir_away := _step_sign(monster.tile - target_tile)
		monster.play_windup(dir_away, float(data.get("windup_sec", 0.0)))


## Play back a death (§2.3.4): the death sound on every peer (Main-level — the node itself vanishes
## with the spawner despawn the host authored). The game-log line comes from game_log's own handler,
## and the node's disappearance is the visual.
func _handle_died_event(_event: Dictionary) -> void:
	_death_sfx.play()


## All peers: adopt a host-stamped tempo change (§2.8.3). Apply it to the LOCAL GameManager beat so the
## display AND client-side pacing (move_input's held-retry) stay in sync — adjudication stays host-side
## by construction (only the host stamps verdicts). Then refresh the readout. On the HOST this also runs
## (call_local), re-applying the value the validator already set — idempotent. The combat-log line is
## added by game_log off this same event; in-flight commits keep their baked seconds (stamp-and-bake).
func _handle_tempo_changed_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	_apply_tempo(float(data.get("beat_sec", GameManager.current_beat_sec)))


## Per-peer local camera follow (M3.5). Track OUR OWN avatar's position each frame; the avatar's glide
## tween is already smooth, so the camera rides it smoothly (pure presentation — nothing networked).
## (Re)acquire the avatar from $Players by our peer id whenever we don't hold a live one — covering
## first spawn, late join, and F5 respawn — and snap the camera on (re)acquire. On our death the avatar
## frees, re-acquire finds nothing, and the camera simply HOLDS its last position (no snap to origin).
func _update_camera() -> void:
	var acquired := false
	if not is_instance_valid(_local_avatar):
		_local_avatar = _players.get_node_or_null(str(multiplayer.get_unique_id())) as Node2D
		# Nothing to follow (pre-first-spawn, or after our death) — hold the last position, no snap.
		if _local_avatar == null:
			return
		acquired = true
	# One unconditional follow assignment for both the acquire frame and every steady-state frame.
	_camera.global_position = _local_avatar.global_position
	if acquired:
		# Snap on (re)acquire: the camera uses position_smoothing (main.tscn), so without this the view
		# would ease in from its held position instead of snapping onto the freshly (re)acquired avatar.
		_camera.reset_smoothing()


## The one adopt-beat chokepoint (§2.8.3): set the LOCAL GameManager beat, then refresh the readout.
## BOTH tempo-adoption paths route through here — a broadcast set_tempo event (_handle_tempo_changed_event)
## and a late joiner's targeted sync_tempo — so a new beat is never adopted without its display updating,
## and there is one place to extend when adoption grows a side effect. Adjudication stays host-side by
## construction (only the host stamps verdicts); a client's local beat drives display + pacing only.
func _apply_tempo(beat_sec: float) -> void:
	GameManager.current_beat_sec = beat_sec
	_update_tempo_display()


## Refresh the top-center tempo readout from the LOCAL GameManager beat (each peer's own). This label
## keeps its own "beat 0.25s · 240 BPM" layout (distinct from the log's sentence form), but derives BPM
## through GameManager.bpm_of so the 0-guard and rounding match every other readout (§2.8.3).
func _update_tempo_display() -> void:
	var beat := GameManager.current_beat_sec
	_tempo_label.text = "beat %.2fs · %d BPM" % [beat, GameManager.bpm_of(beat)]


## Any peer: request a tempo nudge of `delta` seconds/beat (negative = faster; delta = ±config.tempo_step_sec).
## Submit our OWN displayed beat + delta RAW on the ordinary intent pipe — DELIBERATELY no client-side
## clampf/snap: the host's set_tempo validator is the SOLE owner of the bounds and grid (§2.8.3), so a
## second clamp here would only be a place for the two to drift. We never change our own beat here; it
## changes only when the host's accepted set_tempo event returns.
func _request_tempo(delta: float) -> void:
	NetEvents.submit_intent("set_tempo", { "beat_sec": GameManager.current_beat_sec + delta })


## LOCAL-only red hit vignette (§2.3.4 hit juice, v0.6.3): a brief full-screen red pulse when OUR OWN
## avatar is the one struck. Called by _handle_attack_event gated on target_id == our peer id, so each
## peer runs it only for itself — it never shows for a hit on someone else. Kill-prior slot so rapid
## hits replace rather than stack. Alpha snaps to 0.35 then tweens to 0 over ~0.25s.
func _flash_hurt_vignette() -> void:
	if _vignette_tween != null and _vignette_tween.is_valid():
		_vignette_tween.kill()
	_hurt_vignette.modulate.a = 0.35
	_vignette_tween = create_tween()
	_vignette_tween.tween_property(_hurt_vignette, "modulate:a", 0.0, 0.25)


## Host-only: a new PLAYER node just entered — mend autonomous-mover state for a possible late joiner.
## No late-join event replay exists (§2.7, by design), so a client that joined after the goblin moved
## renders it at its stale spawn-config tile. Post one micro snap glide_to per LIVING monster (from ==
## to == its authoritative tile, 0.05s) on the normal event path (as_peer = monster id): the joiner's
## stale node glides to truth, everyone else no-ops a same-tile micro-glide. Players get the SAME snap
## (as_peer = their positive peer id) — under v0.7.0 go-stop-go a player is idle most of the time, so a
## joiner would otherwise render every already-moved player at its stale spawn slot until that player's
## next glide. The just-spawned node is skipped (it enters at its correct tile — snapping it is noise).
## Minimal §2.7-compliant mend, not real mid-run join support (§2.7 still parks that).
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
	# Same mend for already-moved PLAYERS, with the same guards as the monster path above.
	for p in _players.get_children():
		if not (p is Player):
			continue
		if p == node:
			continue  # the joiner's own player enters at its correct tile — no snap needed
		if not _combat.is_alive(p.entity_id):
			continue
		var cur: Vector2i = _referee.tile_of_entity(p.entity_id)
		if WorldGrid.is_wall(cur):
			continue  # untracked / despawning — no truth to snap to
		# Skip mid-glide players: a gliding player self-corrects on its own next event, and snapping
		# it would kill a running tween on every existing peer (the monster path's reasoning verbatim).
		if _referee.is_entity_moving(p.entity_id):
			continue
		NetEvents.post_event("glide_to", { "from": cur, "to": cur, "duration_sec": 0.05 }, p.entity_id)


## Sign of each axis of a delta, clamped to an 8-way step {-1,0,1}² — used to point an attacker's
## directional lunge at its target without assuming the two are exactly one tile apart.
func _step_sign(delta: Vector2i) -> Vector2i:
	return Vector2i(signi(delta.x), signi(delta.y))


## All peers: resolve an entity id to its avatar node — players in $Players, monsters (negative id)
## in $Monsters. Both containers are plain scene nodes present on every peer, so this works on the
## client (where the referee is inert) too. The referee has its own id->node helper for host-side
## adjudication; this is the presentation-side mirror. Entity-typed: playback drives only the
## shared surface (glide_to, tile, play_* cues, set_hp_display); call sites that need a subclass
## surface cast explicitly (the bump path's Player.commit_in_place).
func _node_for_peer(entity_id: int) -> Entity:
	if entity_id < 0:
		return _monsters.get_node_or_null(str(entity_id)) as Entity
	return _players.get_node_or_null(str(entity_id)) as Entity


## Sender only: the host refused our glide. Bonk our OWN player (§2.3.4 — the sound+visual half;
## the game log adds the line via its own connection). Rejects reach only the sender, so the
## local player is always the right target.
func _on_intent_rejected(action: String, reason: String) -> void:
	if action != "glide_to":
		return
	var me := _players.get_node_or_null(str(multiplayer.get_unique_id())) as Player
	if me != null:
		me.play_bonk()


## All peers: log a departure from TRANSPORT truth (v0.6.3), connected on EVERY peer in _ready and
## BEFORE the host's _on_peer_disconnected cleanup so the name still resolves. The host reads the
## leaver's name from _peer_names (its authoritative roster, which _on_peer_disconnected erases right
## after this); a client reads it off the still-present avatar node's display_name. Fallback "A player"
## covers the race where neither source resolves. This REPLACES the old child_exiting_tree hook — node
## exit fired on death and on F5 reset (both keep the peer connected), producing phantom "left." lines;
## only a transport disconnect is a true departure, so the death and reset spam are gone by construction.
func _on_peer_departed(peer_id: int) -> void:
	var who := ""
	if multiplayer.is_server():
		who = str(_peer_names.get(peer_id, ""))
	else:
		var node := _node_for_peer(peer_id)
		if node != null:
			who = node.display_name
	if who.is_empty():
		who = "A player"
	print("[peer %d] %s left" % [multiplayer.get_unique_id(), who])
	if is_instance_valid(_game_log):
		_game_log.add_line("%s left." % who)


func _on_peer_connected(peer_id: int) -> void:
	print("[HOST] peer %d connected" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_slots.erase(peer_id)
	# Drop the reset roster entry too (v0.5.4): a gone peer must not be respawned by a later F5.
	_peer_names.erase(peer_id)
	# Drop any refusal mark for this connection — the peer is gone, so a future peer_id (even a
	# reconnection from the same machine) starts clean and gets its own adjudication. Session
	# teardown frees the whole Main node, so _refused dies with it; this covers the live case.
	_refused.erase(peer_id)
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
		# Version hint on the give-up: even the degraded legacy pairing (a pre-gate one-arg build
		# meeting a gated host, whose arity-mismatched call is dropped → this timeout) names the
		# likely cause. Uses the REAL build version, never the fakever= override — the fake is a
		# send-path lie for testing; this message is for the human reading their own screen.
		var real_version := GameManager.build_version()
		_end_session("No response from host. (You're on v%s — joining a different version can look like this.)" % real_version)
		return
	_peer_ready_attempts += 1
	# The host handler is idempotent via _slots, so a retry racing an in-flight spawn is harmless
	# (duplicate guard early-returns). The one narrow race — a spawn in flight during the final
	# 500ms — loses cleanly: the client returns to menu and the host frees the orphan player on
	# the resulting disconnect.
	peer_ready.rpc_id(1, GameManager.player_name, _client_version())
	get_tree().create_timer(PEER_READY_RETRY_INTERVAL_SEC).timeout.connect(_send_peer_ready)


## Client-only. The version string this client SENDS in peer_ready: the debug fake if the harness
## set one (fakever= — a send-path override ONLY, never a comparison basis), else the real build
## version read live from the one source of truth, stripped to match how the host reads its own.
func _client_version() -> String:
	if not GameManager.debug_fake_version.is_empty():
		return GameManager.debug_fake_version
	return GameManager.build_version()


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


# Client-side: the host's transport went away. With the version gate (v0.5.0), a refused peer
# (version mismatch or capacity) already received its specific reason via session_refused and ran
# _end_session before this fires, so the _leaving guard swallows this call. This generic message
# is now the genuine host-left case (host quit/crashed) — or the rare kick whose reason RPC was
# lost, which is the acceptable degraded fallback rather than a parked TODO.
func _on_server_disconnected() -> void:
	_end_session("Disconnected from host.")


## Host-only dev round-reset (v0.5.4 F5 key — a wire-session facility, DISPOSABLE: M6's real run
## start/end flow replaces it). Re-seeds the WHOLE world in place — "everyone disconnects and rejoins"
## minus the network part — so Jon + Jeff can iterate a round (kill the goblin or die → reset → test
## again) without tearing down two instances and the playit tunnel each time.
##
## NOT a Commitment Rule leak, and this is the load-bearing distinction: a live player's in-flight
## commitment dies with the despawn exactly as it would on a disconnect — "the WORLD ended, nobody
## backed out of a decision within it." Only the host can fire it, and it resets everything at once,
## never one player's committed action, so it can't become a player-facing cancel lever.
##
## Cleanup is free because despawn already tears down all referee state via the container exit hooks
## (the proven disconnect/death paths), and stale wind-up/glide timers no-op through the existing
## token / is_alive / freed-node guards. The spawn path (_spawn_config, _spawn_goblins) is reused as-is.
func _reset_round() -> void:
	# No departure-mute is armed here anymore (v0.6.3): departures ride transport truth
	# (_on_peer_departed), and a reset fires no transport event, so the mass frees below are silent by
	# construction — the old _resetting flag that muted the node-exit "left." hook is gone with the hook.

	# a. Roster is already captured live in _peer_names (written at both spawn sites, erased on
	# disconnect), so there is nothing to scrape from the about-to-die nodes — names die with them, and
	# a DEAD peer's name lives nowhere else. _peer_names is the single robust source the respawn reads.

	# b/c. Despawn every player + monster SYNCHRONOUSLY (free, not queue_free) — the v0.5.5 race fix.
	# v0.5.4 queue_freed then awaited process_frame, but the awaited resume's ordering vs the deletion
	# flush is engine-internal and phase-dependent: observed in the wild (Jon, first manual F5), the
	# late exit hooks erased the NEW nodes' referee state by entity id ("not in session" forever).
	# free() collapses the window instead of tuning the wait: every exit hook (they only erase the
	# exiting node's own dict keys) completes INLINE, before the respawn seeds anything. Legal because
	# nothing freed is on the current call stack — this body runs as the deferred call, outside input
	# dispatch and entity callbacks; get_children() returns a fresh array, so the iteration is
	# inherently a snapshot. The spawners replicate the despawns from tree-exit exactly as before.
	for node in _players.get_children():
		node.free()
	for node in _monsters.get_children():
		node.free()

	# d. Clear the slot bookkeeping so the respawn assigns fresh — the exit hooks above have already
	# run to completion, so referee occupancy is provably empty HERE, no wait of any kind.
	_slots.clear()

	# e. Re-seed: respawn every roster entry. _peer_names IS the "connected + spawned, host first"
	# set by construction — a GDScript Dictionary is insertion-ordered, the host's entry is written
	# at its own spawn (before any client can peer_ready), and disconnect erases — so iterating it
	# needs no [1]+get_peers() reconstruction and inherently skips mid-join peers (no entry yet;
	# they join the fresh round normally). Note _next_monster_id is deliberately NOT reset (see its
	# declaration): the goblin gets a fresh negative id so a stale timer can never match it.
	for id in _peer_names:
		_spawner.spawn(_spawn_config(id, _peer_names[id]))
	if GameManager.spawn_monsters:
		_spawn_goblins()

	# f. One marker on the shared pipe so BOTH peers' logs show the reset distinctly (feedback rule
	# §2.3.4): host-authored, peer 0 (server-originated, no validator). game_log renders "— Round reset —".
	# Named specifically (not bare "reset") so M6's real run start/end events have namespace room.
	NetEvents.post_event("round_reset", {})


## Host-only. Spawn a goblin at each of GOBLIN_SPAWN_TILES, up to GameManager.monster_spawn_cap
## (-1 = all — menu play; the autostart goblin=N knob caps it). Each spawn is guarded so a future
## room edit that walls or fills a tile skips THAT goblin (push_warning) instead of dropping it into a
## wall or onto a body — a skip doesn't consume a cap slot (the cap counts goblins actually placed).
## Each gets the next negative entity id; the config carries the type PATH so every peer loads the
## same authored .tres (never a Resource over the wire). Reused as-is by the F5 round reset.
func _spawn_goblins() -> void:
	var cap := GameManager.monster_spawn_cap  # -1 = no cap
	var spawned := 0
	for tile in GOBLIN_SPAWN_TILES:
		if cap >= 0 and spawned >= cap:
			break
		if not WorldGrid.is_walkable(tile) or not _referee.is_tile_free(tile):
			push_warning("[Main] goblin spawn tile %s not walkable/free — skipping (map-coupled)" % tile)
			continue
		var entity_id := _next_monster_id
		_next_monster_id -= 1
		_monster_spawner.spawn({
			"entity_id": entity_id,
			"type_path": GOBLIN_TYPE_PATH,
			"tile": tile,
		})
		spawned += 1


## Host-only. Builds the replicated spawn config. spawn_index is the server-assigned slot;
## every peer derives the same position from it in the spawn_function above. Also records the
## F5-reset roster entry (_peer_names) — this is the one chokepoint EVERY player spawn passes
## (host self-spawn, admitted peer_ready, reset respawn), so a future spawn site can't forget
## the roster and silently drop that peer from later resets. Idempotent on respawn.
func _spawn_config(peer_id: int, p_name: String) -> Dictionary:
	_peer_names[peer_id] = p_name
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


## Host-only tempo referee (DESIGN §2.8.3), registered with NetEvents in _ready. The intent carries an
## ABSOLUTE requested beat (the client's displayed beat ± one step, submitted RAW, §2.8.3); this host is
## the SOLE authority that validates it, then snaps it to the config grid and clamps it to
## [tempo_min_sec, tempo_max_sec] — the client's request is only a proposal, never a nudge the host
## trusts. The wire is never coerced: a malformed beat_sec (wrong type or non-positive) is REFUSED, not
## clamped (mirrors _validate_glide's type-guard). Ignores a no-op (unchanged) request so the log/display
## don't churn (its silent reject is by design — game_log ignores set_tempo rejects). Applies to
## current_beat_sec HOST-side and returns the stamped beat + the requester's server-resolved name; every
## peer (host too, via call_local) then adopts it in _handle_tempo_changed_event. Only FUTURE verdicts read
## the new beat — in-flight commits keep their baked seconds (stamp-and-bake, §2.8.2). No re-derivation here.
func _validate_set_tempo(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Type/range guard first — the wire is never trusted. Reject anything that isn't a positive number
	# (a bad type, or to_float garbage → 0.0) rather than snapping/clamping nonsense into a valid beat.
	var raw = data.get("beat_sec")
	if (typeof(raw) != TYPE_FLOAT and typeof(raw) != TYPE_INT) or float(raw) <= 0.0:
		return { "ok": false, "reason": "malformed" }
	var cfg := GameManager.config
	var beat := clampf(snappedf(float(raw), cfg.tempo_step_sec), cfg.tempo_min_sec, cfg.tempo_max_sec)
	if is_equal_approx(beat, GameManager.current_beat_sec):
		return { "ok": false, "reason": "no change" }
	# Membership: only a peer with a live player node is in the session (mirrors _validate_chat) —
	# the name is resolved server-side, never from the payload.
	var player_node := _players.get_node_or_null(str(sender_peer_id))
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	GameManager.current_beat_sec = beat
	return { "ok": true, "data": { "beat_sec": beat, "by": player_node.player_name } }


## Host-only. Refuse a peer that was NEVER admitted (version mismatch or capacity). Used by BOTH
## refusal paths: mark it refused, send the reason over the transient host->client channel, then
## kick IMMEDIATELY — no grace timer. The RPC is enqueued synchronously onto the peer's reliable
## channel before kick_peer runs, and kick_peer now uses peer_disconnect_later, which flushes that
## queue before closing (see NetworkManager.kick_peer). The old 0.4s SceneTreeTimer was a RACE, not
## a guarantee: /code-review of the v0.5.0 gate found the kick's plain disconnect_peer RESETS queued
## reliable packets (ENet's enet_peer_reset_queues), so under loss the reason could be destroyed in
## flight — the timer merely usually won on loopback. The synchronous-enqueue assumption is a real
## experiment, not a hope: a deferred Godot-side send buffer would lose the reason at every latency
## (sends to a disconnect-pending peer are rejected), so a loopback mismatch test that shows the
## reason arriving empirically proves the enqueue happens before the kick. The _refused mark swallows
## the client's 0.5s peer_ready retries (see _refused); a duplicate session_refused would otherwise
## no-op on the client's _leaving guard anyway.
func _refuse_peer(peer_id: int, reason: String) -> void:
	_refused[peer_id] = true
	session_refused.rpc_id(peer_id, reason)
	NetworkManager.kick_peer(peer_id)


# ── RPCs ──────────────────────────────────────────────────────────────────────

## Client -> host. The host decides whether to spawn this peer's player. DELIBERATELY a mutation of
## the old 1-arg signature, NOT a v2: keeping a 1-arg path alive would let a gated client be
## ADMITTED by a gate-less legacy host — failing OPEN into the exact silent mismatch this feature
## prevents. Mutating the arity makes every legacy pairing fail CLOSED — the dispatcher drops the
## arity-mismatched call (noisy console error, never executed) and the client ends in its 5s
## timeout. Handler order matters: duplicate guard → sanitize name → version check → capacity, so
## the refusal log only ever interpolates the sanitized name.
@rpc("any_peer", "call_remote", "reliable")
func peer_ready(p_name: String, client_version: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	# Refused-guard FIRST (before the _slots duplicate guard): a peer we already refused this
	# connection keeps resending peer_ready every 0.5s until its kick flushes and lands. Swallow those
	# retries silently — no log spam, no redundant refusal RPC — and, critically, don't let a slot
	# freed in the meantime re-admit the very peer whose kick is still in flight.
	if _refused.has(peer_id):
		return
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
	# Version gate (before capacity). Sanitize the wire string first — it gets echoed into a
	# displayed refusal message, so never trust it; the 16-char cap fits the current x.y.z scheme
	# (revisit if 1.0-era suffixes like "-rc.1" ever join). Compare EXACT string equality against
	# the host's own config/version, read live per join through GameManager.build_version() — the
	# SAME single read path (and strip) the client uses — so a hand-edited trailing space can't
	# manufacture a refusal. 0.x: everything is breaking, so any difference refuses; a looser
	# major.minor policy can wait for 1.0.
	var client_ver := NetEvents.sanitize_wire_text(client_version, 16)
	var host_ver := GameManager.build_version()
	if client_ver != host_ver:
		print("[HOST] refused %s — version v%s (host v%s)" % [p_name, client_ver, host_ver])
		_game_log.add_line("Refused %s — version v%s (host v%s)." % [p_name, client_ver, host_ver])
		_refuse_peer(peer_id, "Version mismatch — you have v%s, host has v%s." % [client_ver, host_ver])
		return
	# Capacity gate (+1 for the host itself). The transport already caps clients at
	# max_players - 1; this is the backstop — refuse (reason + kick) so an over-capacity peer
	# falls back to its menu with the specific "Server is full." rather than sitting
	# connected-but-playerless. Counted via _slots (not get_child_count()): a disconnecting peer's
	# node is freed DEFERRED (queue_free), but its slot is erased immediately — so _slots never
	# over-counts and a join arriving the same frame as a disconnect isn't falsely refused.
	if _slots.size() < GameManager.config.max_players:
		# _spawn_config records the F5-reset roster entry (only admitted peers reach it — a refused
		# peer never spawns), so a later re-seed can respawn this client by name even after its
		# player node — the only other name source — is gone (dead or despawned).
		_spawner.spawn(_spawn_config(peer_id, p_name))
		# Late-join tempo sync (§2.8.3): ALWAYS hand the admitted joiner the host's current beat over a
		# targeted host->client RPC. Unconditional by design — sync_tempo just adopts the host's live value
		# (idempotent when it already matches), so the old "only if it differs from config.beat_sec" gate
		# bought nothing and left two races open: a tempo change landing the SAME frame this peer is
		# admitted, and drift between the host's config default and the joiner's (a mismatched .tres).
		# Syncing every join closes both; a redundant equal-beat adopt is a no-op display refresh, and this
		# is targeted rpc_id so existing peers see nothing regardless.
		sync_tempo.rpc_id(peer_id, GameManager.current_beat_sec)
	else:
		# Symmetric with the version branch: host-side visibility before the refusal, so a full-server
		# rejection shows in the host's log/console too (not just on the refused client's menu).
		print("[HOST] refused %s — server full (%d/%d)" % [p_name, _slots.size(), GameManager.config.max_players])
		_game_log.add_line("Refused %s — server full." % p_name)
		_refuse_peer(peer_id, "Server is full.")


## Host -> one client. Sent to a peer we are refusing — one that was NEVER admitted (routing has no
## admission concept; Main exists on the client by construction, so this RPC's target node
## resolves). The client funnels it through _end_session (menu shows the reason once); the _leaving
## guard makes it idempotent under the 0.5s retry race and makes the host's follow-up kick a no-op
## on the client's already-closed transport.
@rpc("authority", "call_remote", "reliable")
func session_refused(reason: String) -> void:
	_end_session(reason)


## Host -> one late-joining client (§2.8.3). Adopt the host's current beat so the joiner's display and
## client-side pacing match a mid-session tempo. Host-authored (authority) and TARGETED (no broadcast,
## so existing peers see no redundant line). Applied to the LOCAL beat + readout, with one neutral log
## line — no "set by", since nobody just changed it; this is the standing tempo the joiner walked into.
@rpc("authority", "call_remote", "reliable")
func sync_tempo(beat_sec: float) -> void:
	# Same adopt-beat chokepoint as a broadcast set_tempo (_apply_tempo), but its OWN neutral log line —
	# no "set by", since nobody just changed it; this is the standing tempo the joiner walked into.
	_apply_tempo(beat_sec)
	if is_instance_valid(_game_log):
		_game_log.add_line("Tempo: %s." % GameManager.tempo_log_text(beat_sec))
