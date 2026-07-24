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
# Docked HUD (v0.12.0), instanced on every peer like GameLog. Brand-new scene → res:// path until the
# editor assigns a uid (CLAUDE.md convention); it lives in the reclaimed letterbox margins.
const HUD_SCENE: PackedScene = preload("res://ui/hud/hud.tscn")

# The one monster kind for M3, loaded per-peer from this PATH (the spawn config carries the path,
# never a Resource over the wire — every peer loads the same authored .tres). Deliberately a
# res:// STRING, not a uid preload: it crosses the wire as spawn-config data, and both ends run
# the same build (version gate), so the readable path is the stable, comparable form.
const GOBLIN_TYPE_PATH := "res://resources/monsters/goblin.tres"

# The training dummy — inert scenery-with-HP (has_brain = false) for practising attacks without
# travelling. Loaded per-peer from this PATH like the goblin (spawn config carries the path, never a
# Resource over the wire). Placed in the starting room (room A) at DUMMY_SPAWN_TILE.
const DUMMY_TYPE_PATH := "res://resources/monsters/training_dummy.tres"

# Training-dummy spawn tile: room A (cols 2-13 / rows 2-8), clear of the pillar (10,4) and the six
# player spawn slots, so a player can hit it the moment the round starts.
const DUMMY_SPAWN_TILE := Vector2i(12, 4)

# The one item kind for chunk A (v0.18.0), loaded per-peer from this PATH like the monsters (the item spawn
# config carries the path, never a Resource over the wire — every peer loads the same authored .tres and
# reads its display_name/atlas_coords). Deliberately a res:// STRING, not a uid preload: it crosses the wire
# as spawn-config data, and both ends run the same build (version gate), so the readable path is the stable,
# comparable form (same reasoning as GOBLIN_TYPE_PATH).
const HEALTH_POTION_TYPE_PATH := "res://resources/items/health_potion.tres"

# Session-start item placements (v0.18.0, host-only): two health potions in the starting room (room A), on
# clear floor away from the player spawn slots + the dummy. Verified '.' floor in WorldGrid.ROOM_LAYOUT, but
# _place_starting_items re-checks each defensively via the guarded _spawn_item_at (a map edit that walled a
# tile warns + skips rather than dropping an item into a wall). Re-placed on every F5 round reset, mirroring
# how _spawn_goblins re-runs — so every fresh round has its potions. v1 behavior: session-start set only,
# no re-spawn mid-round.
const STARTING_ITEM_TILES: Array[Vector2i] = [
	Vector2i(5, 5),
	Vector2i(8, 4),
]

# Goblin spawn tiles, populating the far rooms so the multi-room map (M3.5) exercises cross-room
# aggro/chase: room C (centre) gets a TRIO for the chaos test (v0.9.2), B (top-right) and E
# (bottom-right) keep one each — five total. Each C tile is verified '.' floor in WorldGrid.ROOM_LAYOUT
# (cols 19–30 / rows 12–18) and clear of C's pillar (24,15)/(25,15). Map-coupled: each spawn is guarded
# by is_walkable + is_tile_free, so a future room edit that walls a tile skips that goblin instead of
# dropping it into a wall. The autostart goblin=N knob caps how many actually spawn
# (GameManager.monster_spawn_cap); menu play spawns them all.
const GOBLIN_SPAWN_TILES: Array[Vector2i] = [
	Vector2i(38, 6),   # room B
	Vector2i(21, 13),  # room C — trio, NW
	Vector2i(27, 13),  # room C — trio, NE
	Vector2i(24, 16),  # room C — trio, S
	Vector2i(39, 21),  # room E
]

# Goblin Shaman support pack (v0.19.4), room D (south of the starting room A, cols 2–13 / rows 19–25 —
# previously EMPTY of monsters). A healer flanked by two ordinary goblins it can heal: damage a flanking
# goblin and the shaman channels a heal onto the lowest-HP ally within 14 tiles. Spawned UNCONDITIONALLY
# (like the training dummy), so the heal demo always appears regardless of the goblin=N cap. Each tile is
# guarded (walkable + free) by _spawn_monster_at, so a future room edit that walls a tile skips that spawn.
# v0.19.6 — the pack sits at the SOUTH END of room D (row 24, not the row-20 hallway mouth) and uses a
# TIGHT aggro range (3, via goblin_shaman.tres + goblin_ambush.tres) so a party can file down the widened
# hallway and gather INSIDE the room before engaging all three at once (Jon: the old row-20/aggro-5 pack
# woke from the hallway and split — two chased up, one peeled east). The flankers are the low-aggro
# `goblin_ambush.tres` variant (still displays "Goblin"), leaving the B/C/E map goblins at aggro 5.
const SHAMAN_TYPE_PATH := "res://resources/monsters/goblin_shaman.tres"
const GOBLIN_AMBUSH_TYPE_PATH := "res://resources/monsters/goblin_ambush.tres"
const SHAMAN_SPAWN_TILE := Vector2i(7, 24)
const SHAMAN_GUARD_TILES: Array[Vector2i] = [Vector2i(6, 24), Vector2i(8, 24)]

# Sentinel for _pick_room_spawn_tile (F6 summon): out-of-bounds, so it can never collide with a real
# free tile. Returned when a room has no free walkable tile at all, so the validator refuses cleanly.
const _NO_SPAWN_TILE := Vector2i(-1, -1)

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
# Ground-item replication (v0.18.0), mirroring the monster spawner/container. Present on every peer; the
# host authors item spawns (session-start potions, the /item dev command, the potion= knob), clients just
# play back the replicated GroundItem nodes. The container is resolved on all peers (so the spawn_function
# and the item-collision scan see it everywhere); the spawner drives from the host.
@onready var _item_spawner: MultiplayerSpawner = $ItemSpawner
@onready var _items: Node2D = $Items
# Host-only movement brain. Present on every peer (it's in main.tscn) but activated ONLY inside
# the is_server() branch below, so a client's referee stays inert. Held so the spawn path can ask
# it whether a slot's tile is free before assigning it.
@onready var _referee := $MoveReferee
# Host-only combat authority (HP / damage / death), beside the movement referee. Same inert-on-
# clients contract — activate() runs only in the is_server() branch. Held so the monster spawn path
# can hand it to each brain and the late-join snap can query liveness.
@onready var _combat := $CombatReferee
# Host-only pace resolver (Tactical Zones v1, §2.8.7), beside the other referees. Same inert-on-clients
# contract — activate() runs only in the is_server() branch. THE single site that decides, per entity at
# stamp time, whether a committed window stamps from the explore or tactical beat; injected into the two
# stamping referees + each monster brain so every stamp routes through it.
@onready var _pace := $PaceReferee
# Host-only inventory authority (v0.18.0 chunk B — bags + walk-over pickup), beside the other referees. Same
# inert-on-clients contract — activate() runs only in the is_server() branch. Held so main can activate it and
# inject it into the move referee's pickup seam, and so the item_picked_up handler can fan out to the HUD.
@onready var _inventory := $InventoryReferee
# Death SFX (placeholder — pitch-shifted bonk). Played on every peer from the `died` event, at Main
# level because the dying entity's own node vanishes with the event (can't play a sound on a freed node).
@onready var _death_sfx: AudioStreamPlayer = $DeathSfx
# Pickup SFX (v0.18.0 chunk B) — a Feel= PLACEHOLDER: a pitched-up variant of the existing impact stream (NOT
# a new asset), played on every peer from the item_picked_up event at Main level (the same _death_sfx pattern —
# a per-node sound can't ride an event whose subject may be mid-glide). Distinct pitch from the death impact
# (0.8) so a pickup never reads as a hit. A bespoke pickup asset can replace the stream later with no code change.
@onready var _pickup_sfx: AudioStreamPlayer = $PickupSfx
# Heal SFX (v0.18.0 chunk C) — a Feel= PLACEHOLDER: the SAME impact stream pitched UP higher than the pickup
# (2.0 vs 1.6), played on every peer from the `heal` event at Main level (the _death_sfx / _pickup_sfx pattern —
# a per-node sound can't ride an event whose subject may be gliding). Distinct pitch so a heal never reads as a
# pickup or a hit. A bespoke heal chime can replace the stream later with no code change.
@onready var _heal_sfx: AudioStreamPlayer = $HealSfx
# LOCAL-only hurt vignette (v0.6.3 hit juice): a red ColorRect on a high CanvasLayer (main.tscn), alpha 0
# at rest, pulsed ONLY when OUR OWN avatar takes a hit. mouse_filter IGNORE so it never eats input. Its
# .tscn full-rect anchors are the pre-layout default; _on_world_frame_changed (v0.12.0) re-scopes it to
# the WorldFrame rect so the flash tints the play area, not the HUD panels. Pure local presentation —
# never replicated, never adjudication.
@onready var _hurt_vignette: ColorRect = $HurtVignette/Overlay
# LOCAL-only tactical screen border (v0.10.3, §2.8.7 pace ENTRY cue): a thin red edge frame (four
# ColorRects under one Control), alpha 0 at rest, faded IN when OUR OWN pace flips to tactical and OUT
# on explore. modulate is tweened on the parent Control so all four edges fade together. Distinct from
# the hurt vignette pulse (which stays a per-hit red flash). Pure local presentation — never replicated,
# never adjudication. mouse_filter IGNORE so it never eats input. v0.12.0: it now lives INSIDE the HUD's
# WorldFrame (so it frames the play area, not the window) — a plain var assigned from _hud in _ready
# rather than @onready, since the HUD is instanced there. Main still drives ONLY its visibility.
var _tactical_border: Control = null
# Per-peer follow camera (M3.5). Lives under Main (not the avatar) so it SURVIVES the local avatar's
# despawn on death — _update_camera stops tracking and it holds its last position instead of the view
# snapping to origin. Pure local presentation: it reads only THIS peer's own avatar node, nothing
# crosses the wire.
@onready var _camera: Camera2D = $Camera
# Always-on tempo readout (DESIGN §2.8.3), top-center. Session UI only (in main.tscn, never the menu).
# A RichTextLabel (bbcode) since v0.9.5 so the two-tone pace EMPHASIS (§2.8.7 cue) can bright/dim the two
# dials inline — YOUR active pace bold + full-alpha, the inactive one dimmed. Driven by pace_changed.
@onready var _tempo_label: RichTextLabel = $TempoDisplay/Label
# F7 range overlay (v0.10.0). Present on every peer (it's in main.tscn); Main wires it its Monsters
# container in _ready (set_monsters) so it never reaches up to read siblings itself (component pattern).
@onready var _range_overlay := $RangeOverlay
# Floating-combat-text FX layer (v0.10.1), world-space under Main after Monsters. Owns damage_popup;
# the attack handler calls it per-peer off the broadcast `attack` event. Present on every peer.
@onready var _fx := $FxLayer
# In-flight arrow visuals (v0.17.0), projectile id -> Projectile node. Per-peer presentation only, keyed by
# the host's monotonic id so multiple arrows coexist; projectile_launched adds, projectile_ended removes+ends.
var _projectiles: Dictionary = {}
# Host-only slash-command referee (v0.10.1), extracted from Main into its own component. Present on
# every peer (it's in main.tscn) but activate()d + registered as the "dev_command" handler ONLY inside
# the is_server() branch, so a client's node stays inert (mirrors the referees).
@onready var _dev_commands := $DevCommands

# Chat/combat log, added on every peer in _ready. Held so spawn/disconnect can post system
# lines through it. Set before the host spawns its own player so that spawn's "joined." lands.
var _game_log: Node = null
# Docked HUD (v0.12.0), added on every peer in _ready right after the log. Held so the combat/pace/
# spawn event handlers can fan out presentation updates to it (party-frame HP, class/weapon repaint,
# death grey, disconnect removal) — the HUD owns the frames + client-side HP mirror; Main just relays
# the events it already receives (component pattern: the parent wires the children).
var _hud: Node = null

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
# Host-only monotonic ground-item id source (v0.18.0). POSITIVE and separate from the entity id space
# (peer ids positive, monster ids negative): a ground item is NOT a body in the referees' one occupancy
# space, so its id never has to avoid colliding with an entity's — the two id spaces are independent by
# construction. Counts UP from 1; not reset on an F5 round reset (a fresh positive id per placement means
# a later chunk's pickup targeting can never confuse a re-placed potion with a pre-reset one).
var _next_item_id: int = 1
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
# Kill-prior slot for the tactical-border fade (v0.10.3), so a rapid tactical/explore flip replaces the
# in-flight fade rather than stacking competing tweens on the same modulate.
var _border_tween: Tween = null
# The local peer's own avatar node, tracked by _update_camera. Null until our player spawns (or after
# our death); (re)acquired lazily from $Players by our peer id, so first spawn, late join, and F5
# respawn all re-attach the camera uniformly. Local presentation only — never read for adjudication.
var _local_avatar: Node2D = null
# Ghost-cam follow target (v0.10.4): while OUR avatar is absent (dead), the camera follows a LIVING
# teammate node instead of holding its last position. STICKY — re-picked only when this node is freed/
# invalid. Cleared the instant our own avatar exists again (respawn/F5), which always wins the camera
# back. Local presentation only — never networked, never read for adjudication. See _update_camera.
var _spectate_target: Node2D = null
# True while WE are dead (set by our own `died` event, cleared on camera re-acquire). Gates the
# ghost-cam: spectate is a DEATH behavior only — a joining peer's pre-spawn frames and an F5 reset's
# despawn-respawn window (which posts no `died`) both keep the held view, so no spurious "Following X."
# line can fire outside a real death (review fix pass, v0.11.0).
var _local_dead: bool = false
# Was the window SCREEN-WIDE (maximized-like) when F11 entered fullscreen? Cached as a SHAPE, not the
# mode enum: with resizable=false, Windows won't hold a true maximize, so window_get_mode() DECAYS to
# WINDOWED one frame after a maximize while the window still fills the work area (sequence-probed,
# v0.16.2) — caching that lying enum made the 4th F11 press drop a "maximized" player to the small
# window. Size readback is reliable; restore-by-intent from it is not. Local-only — never wired.
var _pre_fullscreen_was_big: bool = true
# The LOCAL player's current pace (Tactical Zones v1, §2.8.7 cue). Presentation only — set from the
# host-authored pace_changed event for our own id, read by _update_tempo_display to emphasize the active
# dial. Defaults false (explore emphasized), the correct pre-fight state on every peer before any flip.
var _local_pace_tactical: bool = false
# EVERY player's current pace (v0.10.3), entity_id -> is_tactical, mirrored on EVERY peer from ALL
# pace_changed events in BOTH directions (seeds included) and pruned on ANY player-node exit (death,
# disconnect, reset — the child_exiting_tree hook below) plus the `died` event for hygiene. Handed to the range
# overlay by reference (set_players) so its F7 green player-bubble rings track the host's live pace with
# no client recompute. Presentation only — never adjudication (the host owns the real resolve).
var _tactical_players: Dictionary = {}
# Host-only cache: the scene-default weapon's display_name, lazily read once from a fresh Player probe by
# _scene_default_weapon_name for the late-join sync filter. Empty until first read.
var _default_weapon_name: String = ""


func _ready() -> void:
	# Seed the session EXPLORE tempo (DESIGN §2.8) BEFORE any verdict is stamped, on EVERY peer: the
	# authored GameConfig.beat_sec, or the host-only beatsec= debug override when set (mirrors glidesec=).
	# PaceReferee reads GameManager.explore_beat_sec LIVE at stamp time from here (the explore pole of the
	# per-entity resolve, §2.8.7); a future runtime tempo knob (§2.8.3) rebroadcasts a new value. Same
	# value on host and client at start (same authored config, same build), so client-side pacing matches
	# until the knob ships.
	GameManager.explore_beat_sec = GameManager.debug_beat_override_sec if GameManager.debug_beat_override_sec > 0.0 else GameManager.config.beat_sec
	# Seed the TACTICAL beat (the second dial, DESIGN §2.8.3 groundwork, v0.9.2) from config on EVERY
	# peer, alongside the explore beat. No debug override for it (no gameplay reads it yet — groundwork
	# only); the [ / ] keys nudge it live via set_tactical_tempo, a late joiner adopts it via sync_tempo.
	GameManager.tactical_beat_sec = GameManager.config.tactical_beat_sec
	# Seed the always-on tempo readout from those values, on EVERY peer, so it is correct before any
	# set_tempo event (§2.8.3). A late joiner's host-supplied beats (sync_tempo below) refresh it.
	_update_tempo_display()

	# Stuck-window self-heal (v0.16.1): watch for the "WINDOWED but screen-sized" state — reachable when
	# a fullscreen transition clobbers the OS's remembered restore rect (maximize → F11 → back →
	# un-maximize hands the player a screen-sized window that resizable=false makes inescapable). The
	# check runs deferred so a mid-transition size event never reads a half-applied mode. See
	# _on_window_size_changed for why this state is never legitimate here.
	get_window().size_changed.connect(func(): _check_stuck_windowed.call_deferred())

	# Paint the room first, on EVERY peer, so players spawn onto a visible floor. Deterministic
	# presentation of the logical grid — same input (WorldGrid) everywhere, so it can't diverge.
	_build_room()

	# Add the log first, on EVERY peer, so the very first spawn's "joined." line has somewhere
	# to go (the host spawns its own player later in this same _ready).
	_game_log = GAME_LOG_SCENE.instantiate()
	add_child(_game_log)

	# Docked HUD (v0.12.0), on EVERY peer, right after the log. Instanced like GameLog. Wire it per the
	# component convention — Main hands it the containers/refs and connects the events; the HUD never
	# climbs the tree. Order matters: add it (its _ready builds the panels + lays out the margins), then
	# hand it $Players (it builds a frame per existing player and mirrors spawn/despawn), then reparent
	# the log's Panel into the left column's slot, then take the tactical-border reference it now owns.
	_hud = HUD_SCENE.instantiate()
	add_child(_hud)
	_hud.set_players(_players)
	# Chat floats bottom-left over the world again (v0.13.0 right-column-only HUD): the GameLog Panel keeps
	# its own scene-authored bottom-left anchors, so it is NOT docked into the HUD this iteration. GameLog's
	# dock_into stays on disk (dormant) for a future left column — main.gd simply no longer calls it.
	# The tactical border is now a WorldFrame child inside the HUD (frames the play area, not the window).
	# Take the reference; Main keeps driving ONLY its visibility via the existing pace handler.
	_tactical_border = _hud.get_tactical_border()
	# The one remaining external consumer of the world-frame rect: the DebugOverlay F3 label. Connect the
	# signal, THEN seed it once with the current rect so the consumer never sits on a stale/zero rect from
	# _ready ordering (the HUD lays out deferred, but world_frame_rect() returns its seeded default meanwhile).
	_hud.world_frame_changed.connect(_on_world_frame_changed)
	# Left-click on an inventory slot (v0.19.x loot): the HUD emits the bag index; we resolve its content type
	# and submit the matching intent. Local UI on every peer (the HUD only ever surfaces our OWN player's bag).
	_hud.slot_activated.connect(_on_inventory_slot_activated)
	_on_world_frame_changed(_hud.world_frame_rect())

	# Wire the F7 range overlay its Monsters container on EVERY peer (component pattern — the overlay
	# never reaches up to read a sibling itself). A null ref draws nothing; here it always resolves.
	_range_overlay.set_monsters(_monsters)
	# Also hand it the Players container + the live pace dict (v0.10.3) so it can draw a green ring around
	# each player the host has resolved TACTICAL. The dict is shared BY REFERENCE — Main mirrors every
	# pace_changed event into it (both directions) and the overlay reads it live, no recompute.
	_range_overlay.set_players(_players, _tactical_players)
	# Prune the pace mirror on ANY player-node exit (v0.11.0 review fix): death already prunes via the
	# `died` event, but a DISCONNECT frees the node with no died — this hook covers every exit path on
	# every peer, so the dict can never accumulate stale entries across a long session. (Entries are
	# inert without a live node either way — this is hygiene, keeping the mirror ≡ living players.)
	_players.child_exiting_tree.connect(func(node: Node) -> void:
		if node is Entity:
			_tactical_players.erase((node as Entity).entity_id))

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
		# Only the host activates a brain, and only for a monster whose type wants one: has_brain ==
		# false is inert scenery-with-HP (the training dummy) — it seeds HP and takes damage through
		# the referee like any monster, but never moves and never attacks (no brain to think).
		if multiplayer.is_server() and monster.monster_type != null and monster.monster_type.has_brain:
			monster.activate_brain.call_deferred(_referee, _combat, _pace)
		print("[peer %d] spawned monster '%s' (entity %d) at tile %s" % [
			multiplayer.get_unique_id(), monster.name, monster.entity_id, tile])
		return monster

	# Ground-item spawn_function (v0.18.0), on EVERY peer with the same replicated config, so the pickup
	# matches everywhere. The config carries the type PATH (not a Resource) + host-assigned item id + tile;
	# every peer load()s the same .tres and reads its display_name + atlas_coords, so no Resource crosses the
	# wire (mirror of the monster path). GroundItem is code-built (a class_name, no scene) — set its public
	# fields BEFORE returning so its _ready reads them to build the sprite + derive its tile-center position.
	_item_spawner.spawn_function = func(data):
		var item := GroundItem.new()
		item.name = str(data.item_id)
		item.item_id = int(data.item_id)
		item.tile = data.tile
		# Resolve name + icon from EITHER an ItemType (a consumable) OR a WeaponType (a dropped weapon, v0.19.x
		# loot) — both expose display_name + atlas_coords. EXPLICIT type branch (not bare duck-typing): the two-type
		# set is closed, so a future third catalog type without atlas_coords hits the warn+safe-fallback instead of
		# crashing every peer. A broken path / other type leaves the safe fallbacks (empty name / (0,0) cell) + warns.
		var res := load(data.type_path)
		if res is ItemType or res is WeaponType:
			item.item_name = res.display_name
			item.atlas_coords = res.atlas_coords
		else:
			push_warning("[Main] ground-item spawn: type_path '%s' loaded neither ItemType nor WeaponType" % data.type_path)
		print("[peer %d] spawned item '%s' (id %d) at tile %s" % [
			multiplayer.get_unique_id(), item.item_name, item.item_id, item.tile])
		return item

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
		# Host-only: activate the pace resolver (Tactical Zones v1, §2.8.7) AFTER the movement referee has
		# its containers wired (so its tile reads resolve) and BEFORE any spawn (so its monster-exit hook
		# is armed for every spawn). It reads authoritative tiles through the movement referee. Then inject
		# it into the movement referee so its step/rest stamps route through beat_sec_for.
		_pace.activate(_players, _monsters, _referee)
		_referee.set_pace(_pace)
		# Host-only: activate the combat referee AFTER the movement + pace referees are set up and BEFORE
		# any spawn — its container enter hooks then seed HP for every entity (host player + goblin), and
		# the referees hold each other's references so bump/AoO/wind-up/death can cross-call and every attack
		# window stamps at the attacker's resolved pace. Then hand the movement referee the combat reference.
		# The last arg is the weapon-drop-on-death hook (v0.19.x loot): the SAME guarded _spawn_item_at the /item
		# dev command uses, bound as a Callable so the combat referee drops a dead monster's weapon without ever
		# reaching up to Main (its invariant). Inert on clients (this whole branch is host-only).
		_combat.activate(_players, _monsters, _referee, _pace, _spawn_item_at)
		_referee.set_combat(_combat)
		# Host-only: activate the inventory referee (v0.18.0 chunk B) with the Players + Items containers (it
		# wires the players' child_exiting_tree to drop a leaving player's bag — inventory dies with the player,
		# permadeath), then inject it into the move referee so a completed glide's arrival tile routes a walk-over
		# pickup through it. BEFORE any spawn, like the other referees, so its child-exit hook is armed for every
		# player. Inert on clients (activate never runs there — this whole node is host-only).
		# v0.18.0 chunk C: the inventory referee also takes the move + combat + pace referees so its use_item
		# validator can gate on busy/liveness, root the drinker (commit_in_place), stamp at pace, and apply the
		# heal (combat.apply_heal) — the same cross-referee injection CombatReferee.activate receives. Wired AFTER
		# those three are activated above so every ref it holds is live before the first use is adjudicated.
		_inventory.activate(_players, _items, _referee, _combat, _pace)
		_referee.set_inventory(_inventory)
		# Host-only: snap autonomous movers to truth for a late joiner (no event replay exists,
		# §2.7). Fires as each new PLAYER node enters; wired here before the host's own player spawns.
		_players.child_entered_tree.connect(_on_player_spawned_host)
		# Host-only: the chat referee. Strip, reject empty, clamp, and resolve the sender's
		# display name server-side (never from the payload) into the broadcast event's data.
		NetEvents.register_handler("chat", _validate_chat)
		# Host-only: the tempo referee (DESIGN §2.8.3). ANY peer submits a set_tempo intent on the same
		# pipe; this validator clamps/snaps/applies host-side, and the accepted intent broadcasts back as
		# a set_tempo event (intent-name == event-name, like "chat") that every peer adopts. Gameplay only
		# ever reads GameManager.explore_beat_sec (via PaceReferee), which no client can write (§2.5 stands).
		NetEvents.register_handler("set_tempo", _validate_set_tempo)
		# Host-only: the tactical-tempo referee (DESIGN §2.8.3 groundwork, v0.9.2). Mirrors set_tempo
		# exactly — ANY peer submits set_tactical_tempo, this validator clamps/snaps against the SAME
		# tempo band and broadcasts, every peer adopts. Groundwork: it stores GameManager.tactical_beat_sec
		# and refreshes the readout, but no verdict reads it for stamping yet (the mode design is open).
		NetEvents.register_handler("set_tactical_tempo", _validate_set_tactical_tempo)
		# Host-only: the F6 dev-summon referee (v0.9.2). ANY peer submits dev_spawn_goblin; this
		# validator resolves the SENDER's room, picks a free tile in it, and spawns a goblin
		# authoritatively (host single-threaded — the spawn happens in-validator, like swap_weapon),
		# then broadcasts so both logs show "X summoned a goblin." A corridor presser is refused.
		NetEvents.register_handler("dev_spawn_goblin", _validate_dev_spawn_goblin)
		# Host-only: the F5 dev round-reset referee (v0.9.4). ANY peer submits dev_reset_round (like F6);
		# this validator resolves the sender's name, defers the world re-seed (so it never runs mid-RPC-
		# dispatch), and broadcasts one marker so both logs show "— Round reset (X) —". No world state
		# rides the verdict — the respawns replicate via the spawners as they always have.
		NetEvents.register_handler("dev_reset_round", _validate_dev_reset_round)
		# Host-only: the weapon-swap referee (M3.7, DESIGN §2.3.7). A peer submits swap_weapon for its
		# OWN player; this validator refuses it while the player is busy, otherwise toggles within the
		# roster host-side and broadcasts. A dev-era control (M5's inventory replaces the hardwired roster).
		NetEvents.register_handler("swap_weapon", _validate_swap_weapon)
		# Host-only: the slash-command referee (v0.10.0). ANY peer submits dev_command {cmd, args} (from the
		# game_log "/" intercept); this validator dispatches on a command table (/w /m /god /class), applies
		# host-side authoritatively (reads/mutates shared config, toggles god, sets class), and returns a
		# host-COMPOSED log line every peer renders (a generic dev_command event) — except /class, which
		# broadcasts its own class_changed event (mirror of swap_weapon) and defers its dev_command broadcast.
		# Unknown command / bad field / non-number value → reject with a reason (sender-only, like a bad move).
		# Extracted into its own DevCommands component (v0.10.1): activate it host-side with the container +
		# combat refs it needs (/god toggles combat's godded dict, /w & /m read the sender's name off
		# Players), then register its validate as the handler. Inert on clients (activate never runs there).
		# The move referee rides along for the /class equip busy guard (v0.17.0 — no equip mid-commit).
		# The item-spawn Callable (v0.18.0) hands DevCommands the /item spawn access WITHOUT reaching up
		# into Main: it wraps _spawn_item_at (host-only author API), so the component stays decoupled (it
		# calls a value, not a parent) and every item still spawns through the ONE guarded, id-assigning path.
		_dev_commands.activate(_players, _combat, _referee, _spawn_item_at)
		NetEvents.register_handler("dev_command", _dev_commands.validate)
		print("[HOST] server started (peer %d) — spawning host player" % multiplayer.get_unique_id())
		# Spawn the host's own player immediately — no RPC needed. (_spawn_config records the reset
		# roster entry as a side effect — the one chokepoint every spawn path shares.)
		_spawner.spawn(_spawn_config(multiplayer.get_unique_id(), GameManager.player_name))
		# Host-only weapon= knob (M3.7): apply the debug starting weapon to the host's OWN player,
		# host-side + authoritative (like beatsec=/hostile=, this knob is host-only). Resolved through
		# the roster (shared config). A joiner later syncs it via sync_player_field; an F5 reset deliberately
		# does NOT re-apply it (respawn restores the player.tscn default — the defined reset behavior).
		if not GameManager.debug_starting_weapon.is_empty():
			var start_weapon := GameManager.config.weapon_by_name(GameManager.debug_starting_weapon)
			if start_weapon != null:
				var host_player := _players.get_node_or_null(str(multiplayer.get_unique_id())) as Player
				if host_player != null:
					host_player.set_weapon(start_weapon)
			else:
				push_warning("[Main] weapon=%s not in the roster — host keeps its default" % GameManager.debug_starting_weapon)
		# Host-only: seed the world with the map's goblins, AFTER the host player so occupancy is
		# already populated for the is_tile_free guard. Off by default in the autostart harness
		# (goblin= knob); on by default for menu play (GameManager.spawn_monsters).
		if GameManager.spawn_monsters:
			_spawn_goblins()
		# Debug goblinat= (v0.17.2): ADD one goblin at an EXACT tile, independent of goblin=/spawn_monsters,
		# for combat tests needing precise range geometry (first use: the ranged-aggro verification — bow
		# range 7 vs goblin aggro 5). Unset = the impossible sentinel; set = spawn through the SAME guarded
		# per-tile step (walkable + tile-free, negative id, brain activated). Host-only (this branch is
		# is_server()); session-start only (an F5 reset does not re-apply it, mirroring debug_starting_weapon).
		if GameManager.debug_goblin_at != GameManager.DEBUG_GOBLIN_AT_UNSET:
			_spawn_monster_at(GameManager.debug_goblin_at, GOBLIN_TYPE_PATH)
		# Ground items (v0.18.0): pre-place the session-start potions AFTER players + monsters so the item-
		# collision scan sees a fully-populated world (though items only collide with items, not entities —
		# _spawn_item_at deliberately checks walkability + item-collision only, never entity occupancy).
		# Extracted into a helper because the F5 round reset re-runs the exact same placement (mirroring how
		# _spawn_goblins re-runs), so every fresh round gets its potions.
		_place_starting_items()
		# Debug potion=x,y (v0.18.0): ADD one health potion at an EXACT tile, independent of the session-start
		# set, for pickup/inventory tests needing a potion at precise geometry (mirrors goblinat= exactly).
		# Unset = the impossible sentinel; set = spawn through the SAME guarded _spawn_item_at. Host-only (this
		# branch is is_server()); session-start only (an F5 reset does not re-apply it, like debug_goblin_at).
		if GameManager.debug_potion_at != GameManager.DEBUG_POTION_AT_UNSET:
			_spawn_item_at(GameManager.debug_potion_at, HEALTH_POTION_TYPE_PATH)
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


## Dev round-reset key (v0.5.4, F5) — a wire-session facility, NOT a game mechanic (see _reset_round
## for the WORLD-re-seed framing). Open to EVERY peer (v0.9.4): F5 rides the intent pipe exactly like
## F6 dev_spawn_goblin, so a CLIENT press resets too — the host validator (_validate_dev_reset_round)
## adjudicates and defers the reset, then broadcasts one marker naming the presser. A DELIBERATE dev-era
## decision: all dev tools stay open to all peers until they're removed for M6's real run flow; there is
## no per-peer gate to justify here. Handled (_unhandled_input) so a focused chat LineEdit consumes its
## own keys first; the event is consumed whenever the action fires so F5 never falls through to anything
## else. (Held-key echoes are already filtered: is_action_pressed defaults to allow_echo=false.)
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("dev_reset_round"):
		NetEvents.submit_intent("dev_reset_round", {})
		get_viewport().set_input_as_handled()
	# Dev summon (F6, v0.9.2): ANY peer spawns a goblin in the room it is standing in. Unlike F5's
	# host-only direct reset, this rides the intent pipe (submit_intent) so a CLIENT press works too —
	# the host validator resolves the sender, picks a free tile in its room, and spawns authoritatively.
	elif event.is_action_pressed("dev_spawn_goblin"):
		NetEvents.submit_intent("dev_spawn_goblin", {})
		get_viewport().set_input_as_handled()
	# Borderless-fullscreen toggle (F11, v0.16.0) — LOCAL presentation only, no wire/intent. Normalized
	# against the CURRENT mode (however fullscreen was entered): if already fullscreen, restore the cached
	# pre-fullscreen mode (maximized by default) AND clear the borderless flag — 4.7 forcibly SETS borderless
	# true when entering WINDOW_MODE_FULLSCREEN (DisplayServer.window_set_mode doc note), so leaving must put
	# the decoration back. Otherwise cache the current mode and enter WINDOW_MODE_FULLSCREEN — which IS
	# borderless fullscreen in 4.7 (same video mode, no decorations). The resize → _relayout chain reflows all
	# HUD + world geometry; nothing else to do here.
	elif event.is_action_pressed("toggle_fullscreen"):
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
			# Restore by INTENT from the cached SHAPE (see _pre_fullscreen_was_big): a screen-wide
			# window goes back to MAXIMIZED (with resizable=false Windows renders that as a work-area-
			# sized window whose mode enum may decay to WINDOWED — visually correct, and the next entry
			# re-caches by SIZE so the decay can't poison anything); a small window gets WINDOWED plus
			# the explicit override rect (the mode change alone does not reliably restore SIZE on
			# Windows — deferred so the transition settles before the rect write).
			DisplayServer.window_set_mode(
				DisplayServer.WINDOW_MODE_MAXIMIZED if _pre_fullscreen_was_big
				else DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			if not _pre_fullscreen_was_big:
				_restore_windowed_rect.call_deferred()
		else:
			# Cache the SHAPE, not window_get_mode() — the enum lies after maximize under
			# resizable=false (decays to WINDOWED at work-area size); width does not.
			var win_w := DisplayServer.window_get_size().x
			var screen_w := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen()).x
			_pre_fullscreen_was_big = win_w >= int(screen_w * 0.98)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
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
	# Tactical tempo dial ([ / ], v0.9.2 groundwork): ] = faster, [ = slower, from ANY peer. Same
	# host-adjudicated request shape as the explore keys above, stepping by the SHARED tempo_step_sec
	# (the tactical dial reuses the explore band pending the mode design). Groundwork — no gameplay
	# reads the tactical beat for stamping yet; this only stores/displays it.
	elif event.is_action_pressed("tactical_tempo_up"):
		_request_tactical_tempo(-GameManager.config.tempo_step_sec)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("tactical_tempo_down"):
		_request_tactical_tempo(GameManager.config.tempo_step_sec)
		get_viewport().set_input_as_handled()
	# Weapon swap (M3.7, DESIGN 2.3.7): Tab / gamepad Y submits a swap intent for OUR OWN player.
	# Handled here (like the tempo keys) so a focused chat LineEdit consumes Tab first. The HOST
	# authority toggles the sender weapon within the roster and broadcasts; we only request. A swap
	# while busy is refused (bonk). Empty data: the host resolves the sender and the next weapon.
	elif event.is_action_pressed("weapon_swap"):
		NetEvents.submit_intent("swap_weapon", {})
		get_viewport().set_input_as_handled()
	# Item use / weapon equip is now LEFT-CLICK on the inventory slot (v0.19.x), NOT a number-key action bar
	# (Jon: nothing auto-binds to a hotbar). The click path is _on_inventory_slot_activated, wired to the HUD's
	# slot_activated signal in _ready — it routes by content type to a use_item or equip_item intent. The old
	# use_slot_1..5 key bindings are retired here (kept in the InputMap harmlessly for the tap= harness).


## Detect and repair the ONE illegitimate window state: WINDOWED at (or beyond) the full screen size.
## With resizable=false a window's size can only come from the project's windowed override or our own
## code, so a screen-sized WINDOWED window is always transition fallout (the OS restore rect clobbered
## by a fullscreen trip) — and the player cannot escape it (no resize handles, no restore state left).
## Deferred from size_changed so the mode read is post-transition. Repair = snap to the override rect.
func _check_stuck_windowed() -> void:
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var screen := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	var win := DisplayServer.window_get_size()
	# 98% threshold, not exact: Windows CLAMPS a decorated window to the work area (taskbar shaved —
	# empirically 2560×1427 on a 2560×1440 screen, 99.1%), so the stuck window lands just UNDER screen
	# size. 98% still clears every legitimate dev window (a 2560×1392 harness window is 96.7%) AND the
	# pseudo-maximized state (resizable=false maximize decays to WINDOWED at work-area size — ~93.8%
	# height with a standard taskbar). KNOWN EDGE: an auto-hidden taskbar makes pseudo-maximized equal
	# the full screen, indistinguishable from the stuck state — such a setup gets snapped to the small
	# window and should just use F11 fullscreen instead.
	if win.x >= screen.x * 0.98 and win.y >= screen.y * 0.98:
		_restore_windowed_rect()


## Snap the window to the project's windowed-override size, centred on its current screen. Used by the
## F11 exit path (Windows does not reliably restore the pre-fullscreen SIZE with the mode) and by the
## stuck-window self-heal above. Reads the override live from ProjectSettings — single source of truth.
func _restore_windowed_rect() -> void:
	var size := Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override")),
		int(ProjectSettings.get_setting("display/window/size/window_height_override")))
	var screen := DisplayServer.window_get_current_screen()
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(
		DisplayServer.screen_get_position(screen) + (DisplayServer.screen_get_size(screen) - size) / 2)


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
		"set_tactical_tempo":
			# The tactical dial's twin of set_tempo (v0.9.2 groundwork): every peer adopts the new
			# tactical beat for its display. No stamping reads it yet — the log line comes from game_log.
			_handle_tactical_tempo_changed_event(event)
		"swap_weapon":
			# An accepted weapon swap broadcasts under its own action name; every peer repaints that
			# player's rig + equipped weapon (the log line comes from game_log's own handler).
			_handle_swap_weapon_event(event)
		"class_changed":
			# A host-adjudicated /class change (v0.10.0) broadcasts under its own action name (mirror of
			# swap_weapon); every peer repaints that player's sprite region from the resolved PlayerClass
			# (the log line comes from game_log's own class_changed handler).
			_handle_class_changed_event(event)
		"pace_changed":
			# A host-resolved pace flip (Tactical Zones v1, §2.8.7). Every peer plays the cue for its OWN
			# player only — the tempo bar emphasizes YOUR active dial (the log line comes from game_log).
			_handle_pace_changed_event(event)
		"projectile_launched":
			# An arrow loosed (v0.17.0, host-authored). CHUNK-1 STUB — see the handler.
			_handle_projectile_launched_event(event)
		"projectile_ended":
			# An arrow ended (hit / blocked / spent). CHUNK-1 STUB — see the handler.
			_handle_projectile_ended_event(event)
		"item_picked_up":
			# A completed walk-over pickup (v0.18.0 chunk B, host-authored). Every peer mirrors the bag +
			# plays the cue; the picker's HUD repaints its hotbar (the log line comes from game_log).
			_handle_item_picked_up_event(event)
		"item_pickup_full":
			# A pickup BLOCKED by a full bag (v0.18.0 chunk B). PRESENTATION ONLY — no node/state change here
			# (the item stayed on the ground, host-side); game_log renders the sender-filtered "bag is full"
			# line off this same broadcast event (the "You died." self-filter precedent). Nothing else to do.
			pass
		"item_used":
			# A committed item use (v0.18.0 chunk C, host-authored). Every peer plays the drink cue + re-packs the
			# user's inventory mirror; the user's HUD repaints its hotbar (the log line comes from game_log).
			_handle_item_used_event(event)
		"equip_item":
			# A committed weapon equip from the bag (v0.19.x loot, host-authored). Every peer repaints the rig +
			# mirrors the swapped bag; the user's HUD repaints (the log line comes from game_log).
			_handle_equip_item_event(event)
		"heal":
			# A resolved heal (v0.18.0 chunk C, host-authored — the effect end of a drink). Every peer floats the
			# green "+N" popup + refreshes HP; the healed player's HUD/party-frame mirrors it (log line from game_log).
			_handle_heal_event(event)
		"heal_cast":
			# A monster's telegraphed heal CHANNEL starting (v0.19.4, host-authored — the shaman). Every peer
			# floats a green channel tell over the caster; the LAND is the later `heal` event (log from game_log).
			_handle_heal_cast_event(event)


## Play back an accepted glide. Resolve the mover by entity id: positive is a player, negative a
## monster (its glide rides the same event path, posted by the referee with as_peer = the negative
## id). Both nodes expose glide_to(to, duration_sec), so one call animates either.
func _handle_glide_event(event: Dictionary) -> void:
	var mover := _node_for_peer(int(event.get("peer", 0)))
	if mover == null:
		return
	var data: Dictionary = event.get("data", {})
	var from: Vector2i = data.get("from", mover.tile)
	var to: Vector2i = data.get("to")
	# Face the direction of travel before the slide runs (v0.10.0): both from/to already ride every
	# glide event, so this is per-peer deterministic with no new wire field. A pure-vertical step
	# (from.x == to.x) leaves facing unchanged (face_toward no-ops on dx == 0).
	mover.face_toward(signi(to.x - from.x))
	mover.glide_to(to, float(data.get("duration_sec", 0.0)))


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
	# Backstab feedback (v0.11.0, §2.3.4 — a distinct outcome gets a distinct cue). The referee tags a
	# rogue's dagger-from-behind hit; every peer reads the same event `tags` and plays a "!"-suffixed
	# popup, a pitched-up impact, and (in game_log) the backstab log line. Absent on every other hit.
	var backstab := (data.get("tags", []) as Array).has("backstab")
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
	# Facing (v0.10.0): the attacker turns toward its target; the victim turns to face the threat
	# (-dir.x). dir is the per-peer step sign toward the target derived just above; dx == 0 (same
	# column) no-ops for both. On a whiff (no target node) only the attacker turns.
	if attacker != null:
		attacker.face_toward(dir.x)
	if target != null:
		target.face_toward(-dir.x)
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
		# Floating combat text for a whiff (v0.10.0, §2.3.4): grey "miss" over the COMMITTED target tile.
		# A whiff event NEVER carries a resolved target node (target_id is always 0 — the ground was
		# vacated), so the old `if target != null` guard never fired and the popup never showed. It is
		# placed from the event's own target_tile field (combat_referee stamps it on every whiff), no node
		# resolve — guard on the field's presence so a malformed event can't crash the render.
		if data.has("target_tile"):
			_fx.damage_popup("miss", DamagePopup.MISS_COLOR, data.get("target_tile") as Vector2i)
	else:
		# LANDED hit — audio-trim rule (v0.6.0, §2.3.4 feedback audit). The attacker lunges (bowstring)
		# but its swing sound is SUPPRESSED (with_sound=false): a landed exchange plays exactly ONE
		# sound, the target's hit. Per-outcome distinctness still holds — landed hit = target hit sound,
		# whiff = the attacker's swing (play_whiff above, kept audible), reject = bonk (play_bonk) — so
		# every outcome is uniquely audible, one sound each, none confusable (§2.2.8 / §2.3.4).
		# A godded target took the hit as a visible NO-OP (combat_referee posts damage 0 + a "godded"
		# flag). The grey "0" popup + the "no effect (god)" log line ARE the cues; the HURT cues (white
		# flash + slash streak, and the local red vignette) must be SUPPRESSED so a no-effect hit never
		# reads as damage taken (§2.3.4 — distinct outcomes stay distinct). Attacker-side cues (swing,
		# rig, recovery) are unchanged — the world still reacts, only the victim's damage feedback is gated.
		var godded := bool(data.get("godded", false))
		# Arrow HIT (v0.17.0): SUPPRESS the attacker-side lunge/swing here. The shooter's cue was the draw +
		# release (windup / projectile_launched) when it loosed — a lunge now, as the remote arrow lands,
		# would be a wrong double-cue (§2.3.4). Only the TARGET's hurt + popup play (below) for an arrow.
		if attacker != null and kind != "arrow":
			# Swing sound RESTORED (v0.6.2, Jon: attack must be audible AND distinct from the hit —
			# swing = high short whoosh, impact = low thud; pitch-separated in the scenes).
			attacker.play_attack(dir, true)
		if target != null:
			# dir passed through so the victim's slash streak reads directional (v0.6.3), derived
			# per-peer from this same event — no new wire data. SKIPPED for a godded no-op.
			if not godded:
				# On a backstab the impact SFX is pitched UP a step (placeholder audio grammar, §2.3.4)
				# so the sharper hit is audibly distinct from a normal blow — same stream, per-peer local.
				target.play_hurt(dir, 1.5 if backstab else 1.0)
			# HP readout still refreshes on a godded hit (harmless — the value is unchanged).
			target.set_hp_display(int(data.get("hp_after", 0)), int(data.get("target_max", 0)))
			# Party-frame HP mirror (v0.12.0): fan the running HP out to the HUD. A player target (positive
			# id) updates its frame's bar; a monster target (negative id) has no frame — a no-op inside the
			# HUD. Godded hits carry unchanged HP, so this is harmless there too. Pure presentation.
			_hud.note_attack(target_id, int(data.get("hp_after", 0)), int(data.get("target_max", 0)))
			# Floating combat text (v0.10.0, §2.3.4): red "-N" over the struck tile, or grey "0" when
			# the target is godded — a no-effect hit stays visibly distinct rather than silently swallowed.
			# One per peer off this same event; the FX layer parents it (survives the victim's despawn).
			if godded:
				_fx.damage_popup("0", DamagePopup.MISS_COLOR, target.tile)
			else:
				# id-sign invariant (players POSITIVE ids, monsters NEGATIVE): target_id < 0 ⇒ a monster
				# was struck (a player→enemy hit) → white; target_id > 0 ⇒ a player took the hit → red.
				var hit_color := DamagePopup.PLAYER_HIT_COLOR if target_id < 0 else DamagePopup.DAMAGE_COLOR
				# A backstab reads "-N!" (the "!" is the distinct-outcome tell, §2.3.4) in the same white.
				var hit_damage := int(data.get("damage", 0))
				var hit_text := ("-%d!" % hit_damage) if backstab else ("-%d" % hit_damage)
				_fx.damage_popup(hit_text, hit_color, target.tile)
		# LOCAL-only red hit vignette (v0.6.3 juice): fires ONLY when it's OUR OWN avatar being struck
		# (landed — we're already past the whiff branch). Suppressed on a godded no-op (no damage taken).
		# Pure local presentation off the same attack event every peer receives.
		if not godded and target_id == multiplayer.get_unique_id():
			_flash_hurt_vignette()
	# Recovery tell (§2.3.4; DESIGN §2.8): the attacker is SPENT for the recovery window the event
	# carries in duration_sec — a bump (player), an instant strike (goblin windup_beats==0), AND a
	# telegraphed-windup landed hit all stamp it now; an AoO free attack remains the only 0-duration
	# case (play_recovery no-ops on it).
	# Played on the attacker node on EVERY peer (whiff or landed), so the spent window matches the
	# host's busy record on the wire — no new sync, same event the whole party already receives.
	if attacker != null:
		attacker.play_recovery(float(data.get("duration_sec", 0.0)))
	# Weapon rig swing (M3.7 → any Entity, v0.9.3, DESIGN §2.3.7): played on EVERY peer for a
	# weapon-bearing attacker of EITHER kind. This tail runs for BOTH the landed and whiff branches
	# above, so a whiffed weapon swing animates too (the whiff event now carries the weapon field).
	# Gate on FIELD PRESENCE + non-empty (a defaulted string never triggers it) AND the attacker being
	# an Entity (the rig + play_weapon_swing now live on Entity) — a weaponless attacker (bare-handed
	# player, the training dummy) carries no weapon field, so its existing cues stay untouched. It rides
	# the SAME stamped duration_sec as the recovery tell, so the choreography auto-aligns to the
	# occupied window; the rig normalizes the phase fractions inside it.
	if attacker is Entity and data.has("weapon") and str(data.get("weapon", "")) != "":
		attacker.play_weapon_swing(dir, float(data.get("duration_sec", 0.0)))
	# Local attacker's swing-busy mirror for a bump / kick / player WINDUP (decision 2; v0.17.1 kick; v0.19.3
	# windup) — players only (positive id), so commit_in_place is Player surface: deliberate narrow cast, not
	# cruft. A kick is a bump-shaped commit (a ranged weapon's point-blank strike). A player MELEE WINDUP
	# (v0.19.2, opt-in) resolves through wind_up, so its landed/whiffed attack event carries kind "windup"
	# (or "strike" on the instant wind_up path) instead of "bump" — WITHOUT this, the deferred verdict's input
	# latch was never cleared by the event and fell through to the ~2s AWAITING safety timeout, locking the
	# player for an extra beat AFTER recovery (only at windup > 0). Driving commit_in_place here clears the
	# latch at the strike and roots the local player for exactly its recovery window, same as a bump. A
	# MONSTER's windup (negative id) never matches the local-id gate, so this stays player-only.
	if (kind == "bump" or kind == "kick" or kind == "windup" or kind == "strike") \
			and attacker_id == multiplayer.get_unique_id():
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
	# Extended to ANY Entity (v0.17.0): the bow DRAW telegraph is a PLAYER windup too, so resolve the entity
	# (player OR monster) and DISPATCH on the event's weapon. A "draw"-style weapon (the bow) plays the draw
	# telegraph on the rig; anything else (a monster's club — no/melee weapon field) keeps the coil-and-flash.
	var entity := _node_for_peer(int(data.get("entity_id", 0)))
	if entity == null:
		return
	var target_tile: Vector2i = data.get("target_tile", entity.tile)
	var windup_sec := float(data.get("windup_sec", 0.0))
	# Face the telegraph direction — toward the committed target tile (v0.10.0), per-peer deterministic.
	entity.face_toward(signi(target_tile.x - entity.tile.x))
	var weapon := GameManager.config.weapon_by_name(str(data.get("weapon", "")))
	if weapon != null and weapon.attack_style == "draw":
		# Bow draw (player, or a future monster archer): the rig raises + aims + nocks the arrow toward the
		# target tile over the draw. The matching projectile_launched plays the release (play_loose). The
		# event-resolved weapon is passed down (v0.17.1 review #9) so a late-joiner still in the weapon-sync
		# retry window paints the RIGHT art for the draw, not whatever the rig last cached.
		entity.play_draw(_step_sign(target_tile - entity.tile), windup_sec, weapon)
		return
	# Melee windup POSE (v0.18.x, the goblin's club): a non-draw weapon parks the weapon RAISED behind the
	# swing's start edge — aimed TOWARD the target tile, deliberately opposite the coil's AWAY-direction below,
	# so the raised weapon and the away-coiled body read as one "winding up" telegraph. ADDITIVE (no return):
	# the pose shows the weapon, then the monster coil below plays the body's away-coil; play_swing (off the
	# landed attack/whiff event) hands the weapon back to the normal swing at resolution. The event-resolved
	# weapon is passed down (v0.17.1 review #9) so a late-joiner poses the RIGHT art. Weaponless windup
	# attacker (the training dummy): weapon is null, skip the pose and fall straight through to the coil.
	if weapon != null:
		entity.play_windup_pose(_step_sign(target_tile - entity.tile), windup_sec, weapon)
	# Monster club coil-and-flash (unchanged): the coil pulls AWAY from the target (monster - target sign).
	var monster := entity as Monster
	if monster != null:
		monster.play_windup(_step_sign(monster.tile - target_tile), windup_sec)
		return
	# Player windup pose landed above (v0.19.2): a PLAYER melee windup (opt-in windup_beats > 0) resolves its
	# weapon and plays play_windup_pose — the rig raise IS its telegraph, so nothing more is needed here. The
	# fallback below is ONLY for a weaponless / unresolvable player windup (a committed action must never be
	# silent, §2.3.4) — gate it on weapon == null so a real melee windup doesn't ALSO flash the floor tell.
	if weapon == null:
		entity.play_windup_fallback(windup_sec)


## Play back a death (§2.3.4): the death sound on every peer (Main-level — the node itself vanishes
## with the spawner despawn the host authored). The game-log line comes from game_log's own handler,
## and the node's disappearance is the visual.
func _handle_died_event(event: Dictionary) -> void:
	_death_sfx.play()
	# When OUR OWN player died, reset the local pace back to explore (§2.8.7, A): the host erases a dead
	# player's engagement/forcing state and posts no further pace_changed for a gone entity, so without
	# this the tempo bar would FREEZE on whatever emphasis it last held (tactical, if we died mid-fight).
	# Local presentation only — no wire event; a fresh spawn (F5) re-seeds via on_player_spawned.
	var data: Dictionary = event.get("data", {})
	var dead_id := int(data.get("entity_id", 0))
	# Bow-draw cleanup (v0.17.0): a shooter killed MID-DRAW never gets a loose to hide its rig, so clear the
	# drawn bow now (the node despawns a beat later, but this drops the visual at once — mirroring how a
	# monster's windup coil vanishes with its node). Resolve while the node is still valid (the died event runs
	# before the despawn replication); a no-op for any entity not mid-draw.
	var dead_node := _node_for_peer(dead_id)
	if dead_node != null:
		dead_node.hide_weapon_rig()
	# Prune the dead entity from the overlay's live pace dict (v0.10.3) — its node frees so a stale entry is
	# already inert (no node to ring), but drop it for hygiene so the dict tracks only living players.
	_tactical_players.erase(dead_id)
	# Party-frame death cue (v0.12.0): grey the dead player's frame "DEAD" on every peer. It persists
	# greyed (the node despawns, but the frame stays so the party sees a downed teammate) until a respawn
	# re-binds it or a disconnect removes it. Idempotent with the HUD's own child_exiting_tree greying.
	_hud.note_died(dead_id)
	if dead_id == multiplayer.get_unique_id():
		# Arm the ghost-cam (v0.11.0 review fix): only a REAL death — this event — permits spectating,
		# so reset/pre-spawn avatar absences can never pan the camera or log "Following X.".
		_local_dead = true
		_local_pace_tactical = false
		GameManager.local_pace_is_tactical = false
		# Own death clears the tactical screen border too (§2.8.7, A): the host posts no further pace_changed
		# for a gone entity, so without this the border would freeze on whatever it last held (red, if we died
		# mid-fight). Local presentation only — a fresh spawn (F5) re-seeds via on_player_spawned.
		_set_tactical_border(false)
		_update_tempo_display()


## All peers: play back a completed walk-over pickup (v0.18.0 chunk B, §2.3.4). Three presentation jobs off the
## one host-authored event: (1) MIRROR the item into the picker's client-side Player.inventory (the presentation
## copy of the host's authoritative bag) so its HUD/future UI can render without a query; (2) play the pickup
## cue on every peer (the _death_sfx pattern — a per-node sound can't ride an event whose subject may be gliding);
## (3) if it's OUR OWN player, repaint the HUD hotbar. The game_log line rides game_log's own connection.
func _handle_item_picked_up_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var entity_id := int(data.get("entity_id", 0))
	var item_name := str(data.get("item", ""))
	var player := _players.get_node_or_null(str(entity_id)) as Player
	# COUPLING: cap the mirror at the hotbar width (INVENTORY_SLOTS on the inventory referee / INV_COLS in
	# hud.gd — both 5). The host only ever posts item_picked_up when its authoritative bag had room, so this
	# guard never actually bites in normal play; it is the defensive backstop keeping the mirror ≤ the hotbar.
	# If it EVER fires the mirror has desynced from the host's bag — warn loudly (GLM v0.18.0 review #2:
	# a silent drop here would be a permanent, invisible hotbar desync on this peer).
	if player != null:
		if player.inventory.size() < 5:
			player.inventory.append(item_name)
		else:
			push_warning("[Main] item_picked_up for %d but the local mirror is FULL — mirror desynced from the host bag (dropped '%s')" % [entity_id, item_name])
	# Pickup cue on every peer (Feel= placeholder — see _pickup_sfx). Mirrors how _death_sfx plays party-wide.
	_pickup_sfx.play()
	# Own player: repaint the HUD hotbar from the just-updated mirror (filtered to our id inside on_inventory_changed).
	if entity_id == multiplayer.get_unique_id():
		_hud.on_inventory_changed(entity_id)


## All peers: play back a committed item USE (v0.18.0 chunk C, §2.3.4). Three presentation jobs off the one
## host-authored event: (1) play the DRINK cue on the user's node for the committed window (the party sees a
## teammate drink); (2) RE-PACK the user's client-side inventory mirror to match the host's authoritative bag
## (which did the same remove_at — slots shift left); (3) if it's OUR OWN player, repaint the HUD hotbar. The
## game_log "drinks..." line rides game_log's own connection; the HEAL (if any) lands later on the `heal` event.
func _handle_item_used_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var entity_id := int(data.get("entity_id", 0))
	var slot := int(data.get("slot", -1))
	var duration_sec := float(data.get("duration_sec", 0.0))
	var player := _players.get_node_or_null(str(entity_id)) as Player
	if player != null:
		# Drink cue held for the committed window on every peer (mirror of how the recovery/windup tells ride
		# their event's duration). A vanished node (killed the same frame the use committed) renders no cue.
		player.play_drink(duration_sec)
		# RE-PACK the mirror to match the host's bag: the referee did remove_at(slot), compacting higher slots
		# left, so the mirror does the same. Guarded so a malformed slot can't crash — the host only ever posts a
		# slot it consumed, so in normal play this stays in lockstep with the referee's bag.
		if slot >= 0 and slot < player.inventory.size():
			player.inventory.remove_at(slot)
	# Own player: repaint the HUD hotbar from the just-repacked mirror (self-filters to our id). Mirror of the
	# item_picked_up handler's own-player HUD repaint.
	if entity_id == multiplayer.get_unique_id():
		_hud.on_inventory_changed(entity_id)


## Local: a LEFT-CLICK on our own inventory slot (v0.19.x loot), from the HUD's slot_activated signal. Resolve
## the slot's content in our client mirror and submit the matching intent: a CONSUMABLE drinks (use_item), a
## WEAPON equips (equip_item). Client-side type routing only picks the intent name; the HOST re-validates
## authoritatively (dead / busy / wrong-type / unknown, §2.2.8). An empty or unresolvable slot is ignored.
func _on_inventory_slot_activated(slot: int) -> void:
	var me := _players.get_node_or_null(str(multiplayer.get_unique_id())) as Player
	if me == null or slot < 0 or slot >= me.inventory.size():
		return
	var item_name := str(me.inventory[slot])
	if GameManager.config.item_by_name(item_name) != null:
		NetEvents.submit_intent("use_item", { "slot": slot })
	elif GameManager.config.weapon_by_name(item_name) != null:
		NetEvents.submit_intent("equip_item", { "slot": slot })


## All peers: play back a committed weapon EQUIP from the bag (v0.19.x loot, §2.3.4). The host-authored event
## carries the newly-equipped weapon and the one it SWAPPED OUT (now sitting in the freed bag slot). Three jobs:
## (1) repaint the rig to the equipped weapon (name-resolved every peer, like swap_weapon); (2) mirror the SWAP
## into the client bag — the freed slot now holds the returned weapon (an empty return = the slot vacated); (3)
## own player: repaint the HUD inventory + equipment panel + play the equip cue. The log line rides game_log.
func _handle_equip_item_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var entity_id := int(data.get("entity_id", 0))
	var slot := int(data.get("slot", -1))
	var equipped_name := str(data.get("equipped", ""))
	var returned_name := str(data.get("returned", ""))
	var player := _players.get_node_or_null(str(entity_id)) as Player
	if player == null:
		return
	var weapon := GameManager.config.weapon_by_name(equipped_name)
	if weapon != null:
		player.set_weapon(weapon)
	# Mirror the host's authoritative swap: the freed slot takes the previously-equipped weapon, or vacates if
	# there was none (a bare-handed equip — impossible today, but the referee mirrors this exact shape).
	if slot >= 0 and slot < player.inventory.size():
		if returned_name.is_empty():
			player.inventory.remove_at(slot)
		else:
			player.inventory[slot] = returned_name
	_pickup_sfx.play()  # equip cue (Feel= placeholder — reuses the pickup tick; a distinct "gear changed" sound later)
	if entity_id == multiplayer.get_unique_id():
		_hud.on_inventory_changed(entity_id)
		_hud.on_weapon_swap(entity_id)


## All peers: play back a resolved HEAL (v0.18.0 chunk C, §2.3.4 — a distinct recovery cue). Off the one
## host-authored event: the heal sound party-wide, a green "+N" popup over the healed tile, the under-feet HP
## readout, and the HUD/char-info HP mirror. The healed player's bar climbs; a non-own target is a HUD no-op.
## The game_log "recovers N HP" line rides game_log's own connection.
func _handle_heal_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var entity_id := int(data.get("entity_id", 0))
	var amount := int(data.get("amount", 0))
	var hp_after := int(data.get("hp_after", 0))
	var target_max := int(data.get("target_max", 0))
	# Heal sound on every peer (Feel= placeholder — see _heal_sfx). Mirrors _pickup_sfx / _death_sfx playing
	# party-wide off a host event (a per-node sound can't ride an event whose subject may be gliding).
	_heal_sfx.play()
	var target := _node_for_peer(entity_id)
	if target != null:
		# HP readout under the feet refreshes from the authoritative hp_after — the SAME set_hp_display an attack
		# drives (one formatting site), so a heal moves the nameplate exactly like a hit does.
		target.set_hp_display(hp_after, target_max)
		# Green "+N" popup over the healed tile (the DamagePopup pattern, HEAL_COLOR — distinct from the red/white
		# hit popups, §2.3.4). Parented by the FX layer so it survives the node (symmetry with the damage popup).
		_fx.damage_popup("+%d" % amount, DamagePopup.HEAL_COLOR, target.tile)
	# Party-frame / char-info HP mirror (v0.12.0): fan the running HP to the HUD. note_attack is a PURE HP mirror
	# (it just calls _set_own_hp for our own id — no attack-specific logic), so it is REUSED here for the heal
	# twin rather than adding a note_heal: a healed own-player's bar climbs with no new HUD surface. A non-own id
	# is a no-op inside the HUD.
	_hud.note_attack(entity_id, hp_after, target_max)


## All peers: play back a monster's heal-CAST telegraph (§2.3.4, v0.19.4 — the shaman's channel). Rendered from
## the authoritative event on every peer: the caster turns to face its ally and a GREEN "+" floats over it,
## marking the channel window — deliberately DISTINCT from the WHITE attack wind-up so a heal is never confusable
## with a strike. The LAND is the later `heal` event (green +N over the ally); the log line comes from game_log.
## A first-pass tell (facing + popup); a richer held channel visual can follow if it feel-tests as too subtle.
func _handle_heal_cast_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var caster := _node_for_peer(int(data.get("caster_id", 0)))
	if caster == null:
		return
	var target_tile: Vector2i = data.get("target_tile", caster.tile)
	caster.face_toward(signi(target_tile.x - caster.tile.x))
	_fx.damage_popup("+", DamagePopup.HEAL_COLOR, caster.tile)


## All peers: adopt a host-stamped tempo change (§2.8.3). Apply it to the LOCAL GameManager beat so the
## display AND client-side pacing (move_input's held-retry) stay in sync — adjudication stays host-side
## by construction (only the host stamps verdicts). Then refresh the readout. On the HOST this also runs
## (call_local), re-applying the value the validator already set — idempotent. The combat-log line is
## added by game_log off this same event; in-flight commits keep their baked seconds (stamp-and-bake).
func _handle_tempo_changed_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	_apply_tempo(float(data.get("beat_sec", GameManager.explore_beat_sec)))


## All peers: adopt a host-stamped TACTICAL tempo change (§2.8.3 groundwork, v0.9.2). The exact twin of
## _handle_tempo_changed_event for the second dial — route the stamped beat through the _apply_tactical_tempo
## chokepoint so the display updates. GROUNDWORK: no verdict reads tactical_beat_sec for stamping yet; this
## only stores + displays it. On the HOST this also runs (call_local), re-applying the validator's value
## (idempotent). The log line is added by game_log off this same event.
func _handle_tactical_tempo_changed_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	_apply_tactical_tempo(float(data.get("beat_sec", GameManager.tactical_beat_sec)))


## All peers: adopt a host-stamped weapon swap (M3.7, DESIGN §2.3.7). Resolve the player by entity id
## and the weapon by name through the roster (shared config, so every peer maps the id to the same
## resource), then set_weapon — repainting the rig + equipped_weapon together. On the HOST this also
## runs (call_local), re-applying the value the validator already set (idempotent). The log line is
## added by game_log off this same event.
func _handle_swap_weapon_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var player := _players.get_node_or_null(str(int(data.get("entity_id", 0)))) as Player
	if player == null:
		return
	var weapon := GameManager.config.weapon_by_name(str(data.get("weapon", "")))
	if weapon == null:
		# LOUD, not silent (v0.17.1 review #2): a host-broadcast weapon name the catalog can't resolve means
		# this peer keeps the OLD weapon while the host + game_log say the swap succeeded — a silent desync.
		# The startup GameConfig.validate_catalog_covers_rosters (host-side) should have caught the authoring
		# gap already; this is the runtime backstop so a slipped-through case is visible, not swallowed.
		push_warning("[Main] swap_weapon: '%s' not in weapon_catalog — this peer desynced from the host (kept its old weapon)." % str(data.get("weapon", "")))
		return
	player.set_weapon(weapon)
	# Equipment-panel refresh (v0.12.0): if it's our own player the HUD re-reads the main-hand weapon name.
	_hud.on_weapon_swap(int(data.get("entity_id", 0)))


## All peers: adopt a host-adjudicated /class change (v0.10.0). Resolve the player by entity id and the
## class by name through the roster (shared config, so every peer maps the id to the same resource), then
## set_class — repainting the sprite region (flip preserved). On the HOST this also runs (call_local),
## re-applying the value the validator already set (idempotent). The log line is added by game_log off this
## same event. Exact mirror of _handle_swap_weapon_event.
func _handle_class_changed_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var player := _players.get_node_or_null(str(int(data.get("entity_id", 0)))) as Player
	if player == null:
		return
	var player_class := GameManager.config.class_by_name(str(data.get("class", "")))
	if player_class == null:
		return
	player.set_class(player_class)
	# Party-frame + char-panel repaint (v0.12.0): the frame portrait re-reads the new class; if it's our
	# own player the character-info panel refreshes too. Fanned out after the node adopts the class.
	_hud.on_class_changed(int(data.get("entity_id", 0)))


## All peers: adopt a host-resolved pace flip (Tactical Zones v1, §2.8.7). Mirrors EVERY player's pace
## (both directions, seeds included) into _tactical_players so the F7 overlay can ring every tactical
## player (v0.10.3); the OWN-player branch below additionally repaints THIS peer's tempo bar + screen
## border. No local inference — the pace is host-authored, played from the event.
func _handle_pace_changed_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var entity_id := int(data.get("entity_id", 0))
	var is_tactical := str(data.get("pace", "explore")) == "tactical"
	# Mirror ALL players (any id, both directions) for the overlay's green rings — NOT filtered to self.
	_tactical_players[entity_id] = is_tactical
	# The cue below emphasizes YOUR active dial, so only OUR OWN flip repaints our bar/border.
	if entity_id != multiplayer.get_unique_id():
		return
	_local_pace_tactical = is_tactical
	_set_tactical_border(is_tactical)
	# Mirror the pace into GameManager so move_input's retry/hold throttles cadence to the host's stamped
	# window during fights (§2.8.7, C). Seeds count too — a joiner spawning into a fight adopts the right
	# cadence at once. Presentation/pacing only; adjudication stays host-side (never reads this).
	GameManager.local_pace_is_tactical = _local_pace_tactical
	_update_tempo_display()


## An arrow loosed (v0.17.0): play the shooter's rig RELEASE (+ loose sound) and spawn the LOCAL flying-arrow
## visual under the FX layer, keyed by the event id (multiple arrows in flight coexist). All per-peer from the
## one event — no new sync. The flight seconds + path are the host's baked values, so every peer's arrow flies
## the identical arc; the matching projectile_ended ends this same id.
func _handle_projectile_launched_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var proj_id := int(data.get("id", 0))
	var shooter_id := int(data.get("shooter_id", 0))
	var path: Array = data.get("path", [])
	var tile_dur := float(data.get("tile_duration_sec", 0.0))
	var weapon := GameManager.config.weapon_by_name(str(data.get("weapon", "")))
	var atlas: Vector2i = weapon.projectile_atlas_coords if weapon != null else Vector2i(0, 23)
	var shooter := _node_for_peer(shooter_id)
	# Release snap on the shooter's rig + loose sound (ends the draw telegraph). dir toward the first path
	# tile; an empty path (adjacent-wall shot) falls back to a horizontal snap.
	if shooter != null:
		var dir := Vector2i.ZERO
		if not path.is_empty():
			dir = _step_sign((path[0] as Vector2i) - shooter.tile)
		# Event-resolved weapon passed down (v0.17.1 review #9): a late-joiner whose rig cache is still stale
		# in the weapon-sync retry window paints the RIGHT release art from the launch event, not the old weapon.
		shooter.play_loose(dir, weapon)
	# Spawn the flying-arrow visual (code-built Projectile, under the world-space FX layer). The shooter node
	# is present on every peer that received this launch (no mid-flight late-join replay), so the fallback is
	# purely defensive.
	var shooter_tile := Vector2i.ZERO
	if shooter != null:
		shooter_tile = shooter.tile
	elif not path.is_empty():
		shooter_tile = path[0]
	var proj := Projectile.new()
	_fx.add_child(proj)
	# Per-weapon projectile art baseline (v0.17.1): the 32rogues sheet is NOT uniformly oriented, so the arrow's
	# native-art direction comes from the weapon's projectile_art_points_deg (authored, same .tres on every peer).
	# -deg_to_rad maps that screen-space direction onto the flight line. Omit when weapon is null so launch()'s
	# own arrow-NW default applies (the defensive weapon-missing path, matching the atlas fallback above).
	if weapon != null:
		proj.launch(shooter_tile, path, tile_dur, atlas, -deg_to_rad(weapon.projectile_art_points_deg))
	else:
		proj.launch(shooter_tile, path, tile_dur, atlas)
	_projectiles[proj_id] = proj


## An arrow ended (hit / blocked / spent): SNAP its visual to the terminal tile and play the outcome (a
## blocked arrow bursts a puff; a hit/spent arrow just clears — a HIT's target cues ride the `attack` event,
## and the log lines come from game_log's own projectile_ended handler). Late-join tolerant: an id we never
## launched (a client that joined mid-flight) is simply not in the dict — end silently, no crash, no log.
func _handle_projectile_ended_event(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var proj_id := int(data.get("id", 0))
	var proj := _projectiles.get(proj_id) as Projectile
	if proj == null:
		return
	_projectiles.erase(proj_id)
	proj.finish(data.get("tile", Vector2i.ZERO) as Vector2i, str(data.get("outcome", "spent")))


## Per-peer local camera follow (M3.5 + ghost-cam v0.10.4). Track OUR OWN avatar's position each frame;
## the avatar's glide tween is already smooth, so the camera rides it smoothly (pure presentation —
## nothing networked). (Re)acquire the avatar from $Players by our peer id whenever we don't hold a live
## one — covering first spawn, late join, and F5 respawn — and snap the camera on (re)acquire; our own
## avatar ALWAYS wins the camera back (and clears any spectate target). When our avatar is absent (dead),
## GHOST-CAM follows a living teammate instead of holding on a corpse: a STICKY pick (nearest to the
## camera's current position at pick time), re-chosen only when the followed node frees, glided over with
## the existing position_smoothing (no snap on switch). Still holds in place only if no teammate exists.
func _update_camera() -> void:
	var acquired := false
	if not is_instance_valid(_local_avatar):
		_local_avatar = _players.get_node_or_null(str(multiplayer.get_unique_id())) as Node2D
		if _local_avatar != null:
			acquired = true
	if is_instance_valid(_local_avatar):
		# Own avatar present — it always wins the camera back. Drop any ghost-cam target so a later death
		# re-picks fresh from that moment's living teammates.
		_spectate_target = null
		# One unconditional follow assignment for both the acquire frame and every steady-state frame.
		_camera.global_position = _local_avatar.global_position
		if acquired:
			# Clear the death flag ONLY on (re)acquire, never per-frame: the `died` event lands a frame or
			# more BEFORE the avatar's replicated despawn, and a per-frame clear in that gap would wipe the
			# flag and dead-lock the ghost-cam (found live in the v0.11.0 fix-pass re-verify).
			_local_dead = false
			# Snap on (re)acquire: the camera uses position_smoothing (main.tscn), so without this the view
			# would ease in from its held position instead of snapping onto the freshly (re)acquired avatar.
			_camera.reset_smoothing()
			# Target-gated ranged click routing (v0.17.1): hand the freshly (re)acquired LOCAL player a
			# predicate that decides whether a clicked tile holds a shootable hostile, so a ranged left-click
			# only looses at a hostile and otherwise falls through to stepping. Wired HERE — the camera-acquire
			# is this peer's "local player is bound" moment, and it runs after the player's _ready (so the
			# sampler exists) and re-fires on every respawn/F5 (a NEW node whose sampler needs the predicate
			# again). CLIENT-SIDE convenience only (§2.2.9): the closure reads THIS peer's replicated node truth
			# (monster node presence ≈ living — they despawn on death; all_hostile ORs in OTHER players), never
			# occupancy — the host still adjudicates every shot from ITS truth.
			var local_player := _local_avatar as Player
			if local_player != null:
				var my_id := multiplayer.get_unique_id()
				local_player.set_shoot_target_check(func(t: Vector2i) -> bool:
					for m in _monsters.get_children():
						if m is Monster and (m as Monster).tile == t:
							return true
					if GameManager.all_hostile:
						for p in _players.get_children():
							var pl := p as Player
							if pl != null and pl.peer_id != my_id and pl.tile == t:
								return true
					return false)
		return
	# Ghost-cam: our avatar is absent AFTER having existed (i.e. we died). Follow a LIVING teammate,
	# STICKY — re-pick only when the followed node is freed/invalid (is_instance_valid poll;
	# _update_camera runs every frame). No reset_smoothing on switch, so the camera GLIDES over to the
	# new target rather than snapping. Gated on _local_dead (our own `died` event): pre-first-spawn
	# frames and F5 reset despawn windows keep the held view, exactly as before v0.10.4.
	if not _local_dead:
		return
	if not is_instance_valid(_spectate_target):
		_spectate_target = _pick_spectate_target()
		var spectated := _spectate_target as Player
		if spectated != null and is_instance_valid(_game_log):
			# One local combat-log line per switch (NOT sent over the wire — each dead peer logs its own).
			# Guarded cast: a non-Player node under $Players just follows silently, never crashes the line.
			_game_log.add_line("Following %s." % spectated.player_name)
	if is_instance_valid(_spectate_target):
		_camera.global_position = _spectate_target.global_position
	# else: no living teammate to follow either — hold the last position, no snap (unchanged pre-spawn feel).


## Ghost-cam target pick (v0.10.4): the LIVING teammate whose node is nearest the camera's current
## position, or null when no other player node exists. Every child of $Players is a live avatar (dead
## players' nodes are freed on death), so mere presence = alive. Called only while our own avatar is
## invalid, but exclude our own id anyway so a same-frame respawn can never pick our own node.
func _pick_spectate_target() -> Node2D:
	var my_name := str(multiplayer.get_unique_id())
	var best: Node2D = null
	var best_dist := INF
	for child in _players.get_children():
		if child.name == my_name:
			continue
		var node := child as Node2D
		if node == null:
			continue
		var d := _camera.global_position.distance_squared_to(node.global_position)
		if d < best_dist:
			best_dist = d
			best = node
	return best


## The one adopt-beat chokepoint (§2.8.3): set the LOCAL GameManager beat, then refresh the readout.
## BOTH tempo-adoption paths route through here — a broadcast set_tempo event (_handle_tempo_changed_event)
## and a late joiner's targeted sync_tempo — so a new beat is never adopted without its display updating,
## and there is one place to extend when adoption grows a side effect. Adjudication stays host-side by
## construction (only the host stamps verdicts); a client's local beat drives display + pacing only.
func _apply_tempo(beat_sec: float) -> void:
	GameManager.explore_beat_sec = beat_sec
	_update_tempo_display()


## The adopt-beat chokepoint for the TACTICAL dial (§2.8.3 groundwork, v0.9.2), the twin of _apply_tempo:
## set the LOCAL GameManager.tactical_beat_sec, then refresh the readout. BOTH tactical-adoption paths
## route through here — the broadcast set_tactical_tempo event and a late joiner's sync_tempo — so the
## dial is never adopted without its display updating. GROUNDWORK: no adjudication reads this beat yet.
func _apply_tactical_tempo(beat_sec: float) -> void:
	GameManager.tactical_beat_sec = beat_sec
	_update_tempo_display()


## Refresh the top-center tempo readout from the LOCAL GameManager beats (each peer's own). Shows BOTH
## dials — "explore 0.25s · 240 BPM   |   tactical 0.50s · 120 BPM" — and, since v0.9.5, EMPHASIZES the
## local player's ACTIVE pace (§2.8.7 cue): the live dial bold + full-alpha, the idle one dimmed, so a
## player reads their current pace at a glance. bbcode two-tone (the label is a RichTextLabel). BPM
## derives through GameManager.bpm_of so the 0-guard and rounding match every other readout (§2.8.3).
func _update_tempo_display() -> void:
	var explore := GameManager.explore_beat_sec
	var tactical := GameManager.tactical_beat_sec
	var explore_text := "explore %.2fs · %d BPM" % [explore, GameManager.bpm_of(explore)]
	var tactical_text := "tactical %.2fs · %d BPM" % [tactical, GameManager.bpm_of(tactical)]
	# The active dial is bright + bold; the inactive one dims to half-alpha. _local_pace_tactical is
	# driven by the own-player pace_changed event (default explore before any flip).
	_tempo_label.text = "[center]%s   |   %s[/center]" % [
		_dial_markup(explore_text, not _local_pace_tactical),
		_dial_markup(tactical_text, _local_pace_tactical)]


## Wrap one dial's text in the emphasis markup for the pace cue (§2.8.7): the ACTIVE dial is bold at full
## alpha, the inactive one dims via a half-alpha color tag. The one styling site both dials share, so the
## bright/dim treatment can't drift between them.
func _dial_markup(dial_text: String, active: bool) -> String:
	if active:
		return "[b]%s[/b]" % dial_text
	# Dim to ~40% alpha in the same bluish readout tone (matches TempoDisplay's theme), so the inactive
	# dial recedes without changing hue.
	return "[color=#ccd9f266]%s[/color]" % dial_text


## Any peer: request a tempo nudge of `delta` seconds/beat (negative = faster; delta = ±config.tempo_step_sec).
## Submit our OWN displayed beat + delta RAW on the ordinary intent pipe — DELIBERATELY no client-side
## clampf/snap: the host's set_tempo validator is the SOLE owner of the bounds and grid (§2.8.3), so a
## second clamp here would only be a place for the two to drift. We never change our own beat here; it
## changes only when the host's accepted set_tempo event returns.
func _request_tempo(delta: float) -> void:
	NetEvents.submit_intent("set_tempo", { "beat_sec": GameManager.explore_beat_sec + delta })


## Any peer: request a TACTICAL tempo nudge of `delta` seconds/beat (v0.9.2 groundwork), the twin of
## _request_tempo. Submit our OWN displayed tactical beat + delta RAW on the intent pipe — the host's
## set_tactical_tempo validator is the SOLE owner of the (shared) bounds and grid, so no client-side
## clamp/snap. We never change our own tactical beat here; it changes only when the host's event returns.
func _request_tactical_tempo(delta: float) -> void:
	NetEvents.submit_intent("set_tactical_tempo", { "beat_sec": GameManager.tactical_beat_sec + delta })


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


## LOCAL-only tactical screen border (§2.8.7 pace ENTRY cue, v0.10.3): fade the red edge frame IN when
## our OWN pace flips to tactical, OUT on explore. Driven from _handle_pace_changed_event (own-id branch)
## and cleared to explore on own death / round reset. Kill-prior slot so a rapid flip replaces the
## in-flight fade. 0.3s tween, target alpha 1.0 (the edges' own 0.18 alpha sets the actual subtlety).
## Distinct from _flash_hurt_vignette (the per-hit pulse) — different node, different cue.
func _set_tactical_border(active: bool) -> void:
	if _border_tween != null and _border_tween.is_valid():
		_border_tween.kill()
	_border_tween = create_tween()
	_border_tween.tween_property(_tactical_border, "modulate:a", 1.0 if active else 0.0, 0.3)


## The HUD's world frame moved/resized (v0.12.0) — relay the rect to the two external consumers. First
## the F3 debug overlay's stats label, so it sits inside the world area's top-right instead of the canvas
## top-right (which now falls under the right HUD column). Second the hurt vignette Overlay: scope it to
## the world-frame rect (clear its full-rect anchors, then position/size = rect) so a hit flash tints the
## PLAY AREA, not the opaque HUD panels — matching the tactical border's play-area scoping (the border
## follows automatically, being a WorldFrame child; the vignette lives in its own layer-10 CanvasLayer so
## it must be sized here). The vignette keeps its CanvasLayer + layer 10 (over world content AND the
## border). Wired in _ready + seeded once.
func _on_world_frame_changed(rect: Rect2) -> void:
	$DebugOverlay.set_world_frame_rect(rect)
	_hurt_vignette.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hurt_vignette.position = rect.position
	_hurt_vignette.size = rect.size
	# Recenter the avatar in the WORLD RECT, not the window (DESIGN #10). _update_camera keeps the camera's
	# global_position ON the avatar (unchanged); this `offset` shifts the point the camera LOOKS AT. With the
	# drag-center anchor the view centre = global_position + offset, so a POSITIVE offset moves world content
	# (the avatar) the OPPOSITE way on screen — LEFT for +x. We want the avatar to land at the world rect's
	# centre instead of the window centre: offset = window_centre − frame_centre puts the look-at point that
	# far PAST the avatar, sliding the avatar back onto the rect centre. Visible-rect size and `rect` are both
	# base px (= world px at zoom 1) — no conversion. Worked example, 1440p maximized (canvas 853.33×464,
	# frame origin 0, centre ≈ (336, 232)): offset = (426.67, 232) − (336, 232) = (+90, 0), avatar shifts
	# ~90px LEFT to the rect centre — closing v0.13.0's "avatar ~90px right of visible centre" feel item.
	# Camera position_smoothing does NOT smooth `offset`, so it snaps; acceptable, as it only changes on resize.
	# The zoom divide is a no-op today (zoom is pinned (1,1) in main.tscn, never written) but keeps the
	# formula correct if a zoom mechanic ever lands: a world-space offset displaces zoom× on screen.
	_camera.offset = (get_viewport().get_visible_rect().size / 2.0 - rect.get_center()) / _camera.zoom


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
	# Late-join pace seed (§2.8.7, v0.9.5): post the joiner's CURRENT pace so its tempo-bar emphasis
	# starts right — normally explore, but corrected in one event if it spawned into a fight. Host-only
	# (this hook is inside the is_server branch); the pace referee dedups against _last_broadcast.
	_pace.on_player_spawned(node.entity_id)


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
	# glide_to, swap_weapon (M3.7), shoot (v0.17.0), use_item (v0.18.0 chunk C), and equip_item (v0.19.x loot)
	# all bonk the sender's own player: a refused move / swap / shot / use / equip gets the same distinct
	# sound+flash, so "the host refused" is never a silent no-op (§2.3.4). An equip reject (dead, busy, wrong
	# slot, not-a-weapon) fires the bonk exactly like a refused move — the game_log line adds the reason.
	if action != "glide_to" and action != "swap_weapon" and action != "shoot" \
			and action != "use_item" and action != "equip_item":
		return
	var me := _players.get_node_or_null(str(multiplayer.get_unique_id())) as Player
	if me == null:
		return
	# occupied_hostile (1a, v0.10.2): the sender was mid-commitment gliding into a hostile it can't
	# bump yet (a pipelined/mid-glide step — a from-idle move into a hostile becomes a bump, never a
	# reject). Suppress the bonk cue: with input held the next from-idle submit IS the attack, so the
	# thud/flash would misread as "your input didn't register" (§2.2.8). The reject must still reach the
	# sampler's reject-counting (a walk into an enemy still stops), so relay it cue-free. Every other
	# reason keeps the full bonk (§2.3.4 — a genuine refusal stays distinctly audible + visible).
	# "arriving" (v0.19.2): the player tried to strike a hostile that hasn't finished sliding into the square.
	# Same cue-suppression as occupied_hostile — with input held the bump re-lands the instant the slide settles,
	# so a thud/flash would misread as "your input didn't register." The reject still reaches reject-counting.
	if reason == "occupied_hostile" or reason == "arriving":
		me.note_reject_no_cue()
	else:
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
	# Party-frame removal (v0.12.0): a genuine transport disconnect is the ONLY frame-removal path — a
	# death keeps the greyed frame, but a departed peer's frame must clear. Runs on every peer (this hook
	# is connected on all peers). Guarded inside the HUD (no frame for this id → a no-op).
	if is_instance_valid(_hud):
		_hud.remove_frame(peer_id)


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
	# Ground items despawn on a round reset too (v0.18.0), the same synchronous free() as players/monsters
	# (they have no exit hook to race — an item claims no referee state — so this is purely tidying the world
	# before the re-seed). The fresh round RE-PLACES the session-start potions below via _place_starting_items,
	# so a reset restores the starting loadout rather than leaving the room barren.
	for node in _items.get_children():
		node.free()

	# Ghost-arrow cleanup (v0.17.1 review #4): bump the combat referee's round generation and drop in-flight
	# arrow state BEFORE the respawn, so a draw pending its loose (or an arrow mid-flight) from the old round
	# can't fire into the fresh one — a same-peer respawn reuses the id and defeats the is_alive guard, so the
	# generation stamp is what invalidates the stale timer. Host-only, alongside the mass frees above.
	_combat.reset_round()
	# Fresh round, fresh bags (v0.18.0 chunk B): clear every inventory. The mass free() of players above already
	# fires the inventory referee's child-exit erase per player; this wholesale clear is the order-independent belt.
	_inventory.reset_round()

	# Clear the local tactical border (v0.10.3): a reset frees every avatar without posting a `died` event,
	# so nothing else would drop it on the resetting peer. On EVERY OTHER peer the respawn's seed
	# pace_changed(explore) drives _set_tactical_border(false) via _handle_pace_changed_event — the same
	# mechanism that re-seeds the tempo bar — so this host-side clear plus that seed cover all peers.
	_set_tactical_border(false)
	# Drop the pace mirror wholesale (GLM v0.10.3 review #1): entity ids are PEER ids, so a respawn
	# reuses them — a stale `true` from before the reset would paint a phantom green ring on the fresh
	# spawn for the frame(s) until its seed pace_changed(explore) lands. Clearing here (and letting the
	# seeds repopulate) closes that window on the resetting peer and caps cross-round growth.
	_tactical_players.clear()

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
	# Re-place the session-start ground items (v0.18.0) so every fresh round has its potions — the same
	# helper the host's _ready calls (mirror of _spawn_goblins re-running above). The potion= debug knob is
	# NOT re-applied here (session-start only, like debug_goblin_at / debug_starting_weapon).
	_place_starting_items()

	# The reset marker is NOT posted here anymore (v0.9.4): the accepted dev_reset_round intent is the
	# ONE source of the "— Round reset (X) —" log line (named after the presser), so a second anonymous
	# marker here would double-log. _reset_round now does world re-seed only; the log line is the
	# validator's broadcast. See _validate_dev_reset_round.


## Host-only. Spawn a goblin at each of GOBLIN_SPAWN_TILES, up to GameManager.monster_spawn_cap
## (-1 = all — menu play; the autostart goblin=N knob caps it). Each spawn is guarded so a future
## room edit that walls or fills a tile skips THAT goblin (push_warning) instead of dropping it into a
## wall or onto a body — a skip doesn't consume a cap slot (the cap counts goblins actually placed).
## Each gets the next negative entity id; the config carries the type PATH so every peer loads the
## same authored .tres (never a Resource over the wire). Reused as-is by the F5 round reset.
##
## Also places the TRAINING DUMMY (DUMMY_SPAWN_TILE) at the end, OUTSIDE the cap count — the goblin=N
## knob caps goblins without dropping the dummy. (goblin=0 disables monster spawning entirely —
## spawn_monsters false skips this whole function, dummy included; use goblin=1 for a near-empty
## harness run that still has the dummy.) Because the F5 reset calls this function wholesale, the
## dummy respawns at full HP for free.
func _spawn_goblins() -> void:
	var cap := GameManager.monster_spawn_cap  # -1 = no cap
	var spawned := 0
	for tile in GOBLIN_SPAWN_TILES:
		if cap >= 0 and spawned >= cap:
			break
		# A skipped (walled/occupied) tile does NOT consume a cap slot — the cap counts goblins
		# actually placed, so _spawn_monster_at's return drives the tally.
		if _spawn_monster_at(tile, GOBLIN_TYPE_PATH):
			spawned += 1

	# The training dummy — same guarded, negative-id spawn step as a goblin, but NOT counted against
	# the goblin cap (it is a practice fixture, not a monster the goblin=N knob governs). Skipped with
	# a warning if its tile is walled/occupied, exactly like a goblin.
	_spawn_monster_at(DUMMY_SPAWN_TILE, DUMMY_TYPE_PATH)

	# Goblin Shaman support pack (v0.19.4) — room D, NOT counted against the goblin cap (like the dummy), so
	# the heal demo always spawns. The shaman first, then its two flanking goblins adjacent to it. The flankers
	# use the low-aggro `goblin_ambush.tres` variant (v0.19.6) so the whole pack holds until the party is in
	# the room (see the SHAMAN_* consts above).
	_spawn_monster_at(SHAMAN_SPAWN_TILE, SHAMAN_TYPE_PATH)
	for tile in SHAMAN_GUARD_TILES:
		_spawn_monster_at(tile, GOBLIN_AMBUSH_TYPE_PATH)


## Host-only per-tile monster spawn step (v0.17.2 extract), shared by _spawn_goblins (each map goblin +
## the dummy) and the goblinat= debug knob. Guards the tile (walkable + occupancy-free) — a walled/occupied
## tile is SKIPPED with a warning and returns false so the caller decides whether that consumes a cap slot.
## On success it takes the next monotonic negative entity id and replicates the spawn config (the type PATH,
## never a Resource over the wire) so every peer loads the same authored .tres; the spawner's host-side
## spawn_function activates the brain for a has_brain type. Returns whether a monster was actually placed.
func _spawn_monster_at(tile: Vector2i, type_path: String) -> bool:
	if not WorldGrid.is_walkable(tile) or not _referee.is_tile_free(tile):
		push_warning("[Main] monster spawn tile %s not walkable/free — skipping (map-coupled)" % tile)
		return false
	var entity_id := _next_monster_id
	_next_monster_id -= 1
	_monster_spawner.spawn({
		"entity_id": entity_id,
		"type_path": type_path,
		"tile": tile,
	})
	return true


## Host-only ground-item author API (v0.18.0), shared by the session-start placement, the F5 re-place, the
## /item dev command, and the potion= knob — the ONE guarded, id-assigning spawn path (mirror of
## _spawn_monster_at). Guards the tile two ways and SKIPS (warn + false) on either:
##  - WALKABILITY: an item can't lie in a wall / off-grid.
##  - ITEM-COLLISION: at most one ground item per tile (scan the Items container) — v1 keeps a tile to a
##    single pickup, so a drop can't silently stack invisibly under another.
## It deliberately does NOT check ENTITY occupancy: a player glides OVER an item (an item claims no
## occupancy), so an item may legitimately sit under / next to a body — only walkability + item-collision
## matter here. On success it takes the next monotonic POSITIVE item id (a space separate from entity ids)
## and replicates the spawn config (the type PATH, never a Resource over the wire) so every peer loads the
## same authored .tres. Returns whether an item was actually placed (the caller decides how to report a skip).
func _spawn_item_at(tile: Vector2i, type_path: String) -> bool:
	# TYPE-PATH guard FIRST (GLM chunk-A review #1): a broken path must NEVER reach the spawner — a
	# MultiplayerSpawner replicates the node to every peer the instant we call spawn(), so a bad path would
	# push a nameless (item_name "") GroundItem out to the whole party while /item still reported success. Refuse
	# here (warn + false) so the caller reports the failure and nothing replicates. ResourceLoader.exists is the
	# cheap pre-load existence check (it does not load the .tres); the per-peer spawn_function still load()s it.
	if not ResourceLoader.exists(type_path):
		push_warning("[Main] item spawn type_path '%s' does not exist — skipping (no replication)" % type_path)
		return false
	if not WorldGrid.is_walkable(tile):
		push_warning("[Main] item spawn tile %s not walkable — skipping (map-coupled)" % tile)
		return false
	if _item_on_tile(tile) != null:
		push_warning("[Main] item spawn tile %s already holds an item — skipping" % tile)
		return false
	var item_id := _next_item_id
	_next_item_id += 1
	_item_spawner.spawn({
		"item_id": item_id,
		"type_path": type_path,
		"tile": tile,
	})
	return true


## Host-only: the GroundItem currently on `tile`, or null if none. The item-collision predicate for
## _spawn_item_at (and the /item dev command's distinct "tile blocked" reject) — items are not tracked in
## the referees' occupancy (they claim none), so their one-per-tile rule is answered by scanning the Items
## container directly. Delegates to GroundItem.on_tile (v0.18.0 chunk B) — the ONE shared scan the inventory
## referee's pickup also uses, so the container walk lives in a single place.
func _item_on_tile(tile: Vector2i) -> GroundItem:
	return GroundItem.on_tile(_items, tile)


## Host-only: place the session-start ground items (v0.18.0). Called from the host's _ready AND from the F5
## round reset, so every fresh round re-places the same potions (mirror of _spawn_goblins re-running). Each
## goes through the guarded _spawn_item_at, so a map edit that walled a listed tile warns + skips that potion
## defensively rather than dropping it into a wall. v1 behavior: this is the ONLY re-placement — items are
## not otherwise re-spawned mid-round.
func _place_starting_items() -> void:
	for tile in STARTING_ITEM_TILES:
		_spawn_item_at(tile, HEALTH_POTION_TYPE_PATH)


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
## explore_beat_sec HOST-side and returns the stamped beat + the requester's server-resolved name; every
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
	if is_equal_approx(beat, GameManager.explore_beat_sec):
		return { "ok": false, "reason": "no change" }
	# Membership: only a peer with a live player node is in the session (mirrors _validate_chat) —
	# the name is resolved server-side, never from the payload.
	var player_node := _players.get_node_or_null(str(sender_peer_id))
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	GameManager.explore_beat_sec = beat
	return { "ok": true, "data": { "beat_sec": beat, "by": player_node.player_name } }


## Host-only TACTICAL-tempo referee (DESIGN §2.8.3 groundwork, v0.9.2), registered in _ready. A byte-for-byte
## MIRROR of _validate_set_tempo for the second dial: same type/range guard, the SAME clamp/snap band
## (cfg.tempo_step_sec / tempo_min_sec / tempo_max_sec — deliberately shared pending the mode design), the
## same no-op reject, the same server-resolved sender name and broadcast. The ONLY differences: it reads and
## writes GameManager.tactical_beat_sec, not explore_beat_sec. GROUNDWORK: this stores the value and every
## peer displays it, but no verdict reads the tactical beat for stamping — that awaits the open mode design.
func _validate_set_tactical_tempo(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Type/range guard first — the wire is never trusted (mirrors _validate_set_tempo).
	var raw = data.get("beat_sec")
	if (typeof(raw) != TYPE_FLOAT and typeof(raw) != TYPE_INT) or float(raw) <= 0.0:
		return { "ok": false, "reason": "malformed" }
	var cfg := GameManager.config
	var beat := clampf(snappedf(float(raw), cfg.tempo_step_sec), cfg.tempo_min_sec, cfg.tempo_max_sec)
	if is_equal_approx(beat, GameManager.tactical_beat_sec):
		return { "ok": false, "reason": "no change" }
	# Membership: only a peer with a live player node is in the session — name resolved server-side.
	var player_node := _players.get_node_or_null(str(sender_peer_id))
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	GameManager.tactical_beat_sec = beat
	return { "ok": true, "data": { "beat_sec": beat, "by": player_node.player_name } }


## Host-only F6 dev-summon referee (v0.9.2), registered in _ready. ANY peer submits dev_spawn_goblin
## (empty data — the host resolves everything). Resolve the SENDER's player, find the room it stands in
## (WorldGrid.room_rect_of); REFUSE if it is in a corridor (no room). Pick a spawn tile: a random FREE
## walkable tile in that room, preferring one ≥ 3 tiles (Chebyshev) from the presser so the goblin isn't
## right on top of them, falling back to any free tile. Spawn synchronously IN the validator (host
## single-threaded — no validate-vs-apply gap, same as swap_weapon) with the next dedicated negative id,
## and return the resolved sender name so the broadcast event's log line reads "X summoned a goblin."
## Accepted risk: no spawn cap — it's a dev key; F5 reset is the cleanup lever.
func _validate_dev_spawn_goblin(sender_peer_id: int, _data: Dictionary) -> Dictionary:
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	var room := WorldGrid.room_rect_of(player_node.tile)
	if not room.has_area():
		return { "ok": false, "reason": "not in a room" }
	var spawn_tile := _pick_room_spawn_tile(room, player_node.tile)
	if spawn_tile == _NO_SPAWN_TILE:
		return { "ok": false, "reason": "room full" }
	var entity_id := _next_monster_id
	_next_monster_id -= 1
	_monster_spawner.spawn({
		"entity_id": entity_id,
		"type_path": GOBLIN_TYPE_PATH,
		"tile": spawn_tile,
	})
	return { "ok": true, "data": { "name": player_node.display_name } }


## Host-only F5 dev round-reset referee (v0.9.4), registered with NetEvents in _ready. Mirrors the F6
## dev_spawn_goblin path: ANY peer submits dev_reset_round (empty data), this validator resolves the
## sender's display name (null-safe — a not-yet-spawned or mid-join sender falls back to "Someone", never
## a crash) and DEFERS _reset_round so the synchronous mass-free runs in the idle deferred-flush phase,
## never mid-RPC-dispatch (the same call_deferred discipline the old direct F5 used). The accepted intent
## broadcasts as the dev_reset_round event carrying only the name — no world state rides the verdict; the
## respawns replicate through the spawners exactly as before. game_log renders "— Round reset (X) —",
## the ONE reset marker (feedback rule §2.3.4). Never refused: a reset has no world precondition.
func _validate_dev_reset_round(sender_peer_id: int, _data: Dictionary) -> Dictionary:
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	var presser_name := player_node.display_name if player_node != null else "Someone"
	_reset_round.call_deferred()
	return { "ok": true, "data": { "name": presser_name } }


## Host-only. Pick a spawn tile for the F6 summon inside `room` (a Rect2i): a RANDOM free walkable tile,
## preferring those ≥ 3 Chebyshev from `presser` (so the goblin isn't right on top of the summoner), and
## falling back to ANY free tile if the room is too small/crowded for the preference. Returns the
## _NO_SPAWN_TILE sentinel when no free tile exists at all (a fully occupied/walled room). Free means
## WorldGrid.is_walkable AND the referee's authoritative occupancy is clear (host-side, never client).
func _pick_room_spawn_tile(room: Rect2i, presser: Vector2i) -> Vector2i:
	var far: Array[Vector2i] = []
	var any: Array[Vector2i] = []
	for y in range(room.position.y, room.end.y):
		for x in range(room.position.x, room.end.x):
			var t := Vector2i(x, y)
			if not WorldGrid.is_walkable(t) or not _referee.is_tile_free(t):
				continue
			any.append(t)
			# Chebyshev distance (max of the axis deltas) — the 8-way step metric this grid uses.
			if maxi(absi(t.x - presser.x), absi(t.y - presser.y)) >= 3:
				far.append(t)
	if not far.is_empty():
		return far[randi() % far.size()]
	if not any.is_empty():
		return any[randi() % any.size()]
	return _NO_SPAWN_TILE


## Host-only weapon-swap referee (M3.7, DESIGN §2.3.7), registered with NetEvents in _ready. A dev-era
## control (the tempo-keys spirit): a peer submits swap_weapon for its OWN player (empty data — the
## host resolves everything). Refused while the player is BUSY (is_entity_moving — the referee's ONE
## occupancy predicate, which covers glides AND attack commit_in_place records, so a swap can never
## interrupt a committed action — the Commitment Rule). Otherwise it toggles within the fixed roster
## (GameConfig.weapon_roster — the ONE authoring site), applies HOST-side authoritatively (so the
## referee's next damage/attack_beats read is the new weapon), and broadcasts under its own action
## name; every peer adopts it in _handle_swap_weapon_event. Late-join is handled separately (sync_player_field
## in peer_ready). Returns the entity id + the new weapon name + the requester's server-resolved name.
func _validate_swap_weapon(sender_peer_id: int, _data: Dictionary) -> Dictionary:
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	# BUSY refusal — is_entity_moving covers a glide AND an attack's commit_in_place busy record, so a
	# swap mid-commit is refused (bonk), state unchanged (Commitment Rule).
	if _referee.is_entity_moving(sender_peer_id):
		return { "ok": false, "reason": "busy" }
	# Cycle the sender's ACTIVE roster (v0.17.0): its class weapon_roster when set, else the global roster —
	# resolved host-side from the player's current class (server-authoritative, never a client value).
	var roster := GameManager.config.active_weapon_roster(player_node.player_class)
	var next: WeaponType = GameManager.config.next_weapon(player_node.equipped_weapon, roster)
	if next == null or next == player_node.equipped_weapon:
		# Empty/single-weapon roster (a misconfiguration) — nothing to swap to. Silent to the log; the
		# sender still gets the bonk so the input isn't a silent no-op.
		return { "ok": false, "reason": "no weapon" }
	# Apply host-side FIRST (authoritative), then broadcast (mirrors _validate_set_tempo). set_weapon
	# (not a raw field write) so the HOST's rig repaints at validator time too — correct even if the
	# broadcast path ever stopped being call_local; the call_local re-apply stays idempotent.
	player_node.set_weapon(next)
	return { "ok": true, "data": {
		"entity_id": sender_peer_id,
		"weapon": next.display_name,
		"by": player_node.player_name,
	} }


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


## The scene-default weapon's display_name (the player.tscn `equipped_weapon`, longsword today), read
## ONCE from a fresh Player instance and cached. Used by the late-join sync filter to skip a player who
## still carries the default weapon — the joiner already seeds that from the scene in the player's _ready,
## so only a DIFFERING weapon needs a wire sync. Reading it off a probe instance keeps the default a
## property of player.tscn (no magic string here) with no per-join cost after the first read.
func _scene_default_weapon_name() -> String:
	if _default_weapon_name.is_empty():
		var probe := PLAYER_SCENE.instantiate() as Player
		if probe != null:
			if probe.equipped_weapon != null:
				_default_weapon_name = probe.equipped_weapon.display_name
			probe.free()
	return _default_weapon_name


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
		# Late-join tempo sync (§2.8.3): ALWAYS hand the admitted joiner the host's current beats over a
		# targeted host->client RPC — BOTH the explore beat AND the tactical beat (v0.9.2), so a joiner's
		# two-dial readout matches a mid-session change to either. Unconditional by design — sync_tempo just
		# adopts the host's live values (idempotent when they already match), so the old "only if it differs
		# from config.beat_sec" gate bought nothing and left two races open: a tempo change landing the SAME
		# frame this peer is admitted, and drift between the host's config default and the joiner's (a
		# mismatched .tres). Syncing every join closes both; a redundant equal-beat adopt is a no-op display
		# refresh, and this is targeted rpc_id so existing peers see nothing regardless.
		sync_tempo.rpc_id(peer_id, GameManager.explore_beat_sec, GameManager.tactical_beat_sec)
		# Late-join player-field sync (M3.7 + v0.10.0, unified v0.10.1): hand the joiner every EXISTING
		# player's CURRENT weapon + class over ONE targeted host->client RPC (sync_player_field), so a
		# non-default weapon (someone swapped, or the host's weapon= knob) or class (someone /class'd) shows
		# immediately instead of the joiner's spawn-seeded default. Same targeted-sync spirit as sync_tempo.
		# Single-threaded host ordering: these RPCs are enqueued here, BEFORE any later attack event, so the
		# joiner has the right weapon/class before it must animate one. The joiner's own just-spawned player
		# carries the scene/slot default, so it's skipped by the entity_id guard.
		#
		# FILTER (v0.10.1): only send a field that DIFFERS from the joiner's own seed for that player — the
		# joiner already seeds each existing player's weapon from the scene default (longsword) and class from
		# its slot default (class_roster[spawn_index % size]) in that player's _ready, so a default value
		# needs no wire traffic. A /class'd wizard (its class differs from its slot default) still syncs.
		var default_weapon := _scene_default_weapon_name()
		var roster := GameManager.config.class_roster
		for existing in _players.get_children():
			if not (existing is Player) or existing.entity_id == peer_id:
				continue
			if existing.equipped_weapon != null and existing.equipped_weapon.display_name != default_weapon:
				sync_player_field.rpc_id(peer_id, existing.entity_id, "weapon", existing.equipped_weapon.display_name)
			if existing.player_class != null and not roster.is_empty():
				var slot_default: String = roster[existing.spawn_index % roster.size()].display_name
				if existing.player_class.display_name != slot_default:
					sync_player_field.rpc_id(peer_id, existing.entity_id, "class", existing.player_class.display_name)
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


## Host -> one late-joining client (§2.8.3). Adopt the host's current beats so the joiner's display and
## client-side pacing match a mid-session tempo. Carries BOTH dials since v0.9.2 — the explore beat AND
## the tactical beat — each through its own adopt chokepoint. Host-authored (authority) and TARGETED (no
## broadcast, so existing peers see no redundant line). One neutral log line per dial — no "set by", since
## nobody just changed it; this is the standing tempo the joiner walked into.
@rpc("authority", "call_remote", "reliable")
func sync_tempo(beat_sec: float, tactical_beat_sec: float) -> void:
	# Same adopt chokepoints as the broadcast events (_apply_tempo / _apply_tactical_tempo), but their OWN
	# neutral log lines — no "set by", since nobody just changed it; this is the standing tempo walked into.
	_apply_tempo(beat_sec)
	_apply_tactical_tempo(tactical_beat_sec)
	if is_instance_valid(_game_log):
		_game_log.add_line("Tempo: %s." % GameManager.tempo_log_text(beat_sec))
		_game_log.add_line("Tactical: %s." % GameManager.tempo_log_text(tactical_beat_sec))


## Host -> one late-joining client (M3.7 + v0.10.0, unified v0.10.1). Adopt one existing player's CURRENT
## weapon OR class so the joiner's rig/sprite shows it (not its spawn-seeded default). `kind` dispatches:
## "weapon" resolves value_name through the roster and repaints via set_weapon; "class" resolves it through
## the class roster and repaints via set_class. Host-authored (authority) and TARGETED (no broadcast —
## existing peers already show it). A not-yet-replicated player node (the spawn race — this RPC can outrun
## the spawner's replication of EXISTING players) gets ONE deferred retry half a second later, which
## outlasts that window by orders of magnitude; only a genuinely absent player (left during the join) drops
## the sync, and its state corrects on any later swap/attack anyway (the §2.7 dev-facility mend, not full
## mid-run join support). No log line: this is silent state sync, like a join snap.
@rpc("authority", "call_remote", "reliable")
func sync_player_field(entity_id: int, kind: String, value_name: String, is_retry: bool = false) -> void:
	var player := _players.get_node_or_null(str(entity_id)) as Player
	if player == null:
		if not is_retry:
			get_tree().create_timer(0.5).timeout.connect(sync_player_field.bind(entity_id, kind, value_name, true))
		return
	match kind:
		"weapon":
			var weapon := GameManager.config.weapon_by_name(value_name)
			if weapon != null:
				player.set_weapon(weapon)
		"class":
			var player_class := GameManager.config.class_by_name(value_name)
			if player_class != null:
				player.set_class(player_class)
				# Party-frame + char-panel repaint (v0.12.0), the same fan-out the live class handler runs
				# (_handle_class_changed_event) — without it a late-join class sync repaints the sprite but
				# leaves that player's HUD portrait stale. Weapon branch needs no HUD fan-out (verified no-op).
				_hud.on_class_changed(entity_id)
