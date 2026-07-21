class_name Player
extends Entity

## A player avatar. Holds identity (peer_id, player_name, spawn_index) and the player-specific
## input surface; the shared presentation — sprite/labels, glide playback, combat cues — lives on
## Entity. It never adjudicates: the host's MoveReferee owns occupancy and outcomes.
##
## Movement flow, per peer:
##  - The LOCAL player's MoveInput (keys/stick, or its click-to-move target driver) emits
##    move_requested(dir, fresh); this node submits a "glide_to" intent. (The white commit-sent
##    input-ack flash was removed in v0.10.2 — Jon: the blink was noise; the glide itself is the ack.)
##  - When the server broadcasts the accepted event, Main calls glide_to() on THIS node — on
##    every peer, including the mover's own — and the glide begins. There is no client prediction
##    and, per the Commitment Rule, no cancel path: glide_to only ever kills a tween to catch up
##    to a newer server truth, never to abort a committed step.
##  - A reject reaches only the sender; Main calls play_bonk() on the sender's own player.

## Damage (HP) this player deals per landed melee attack — a bump (move into a hostile) or an
## attack of opportunity. Deterministic (no to-hit roll, DESIGN §2.3 amendment). Read HOST-side by
## the referees when they stamp this attacker's damage; never trusted from the wire.
@export var melee_damage: int = 5

## Recovery in BEATS after a bump lands: damage is instant, then the attacker is BUSY for this many
## beats — the symmetric attack shape (DESIGN §2.8) and the Commitment Rule tail (decision 2). The
## referee converts it to seconds at stamp time (beats × the attacker's resolved pace) into the from==to busy
## record; the local attacker mirrors that window as blocked input (commit_in_place) and every peer
## plays the recovery tell for it. 2.0 → attack rate = movement rate (a step is glide + 1 rest beat).
## NO-WEAPON FALLBACK (M3.7): this and melee_damage are read by the referee ONLY when equipped_weapon
## is null — a weapon's attack_beats/damage win when one is equipped. equipped_weapon itself, the rig
## reference, set_weapon, and play_weapon_swing now live on Entity (v0.9.3, shared with Monster); this
## node keeps only the player-specific swap flow (the swap intent/validator/event and late-join sync).
@export var attack_recovery_beats: float = 2.0

@onready var _move_input := $MoveInput
@onready var _path_marker: Node2D = $PathMarker
@onready var _commit_audio: AudioStreamPlayer = $CommitSent
@onready var _bonk_audio: AudioStreamPlayer = $Bonk

# Assigned by main.gd's spawn_function (from the replicated spawn config) before this
# node enters the tree, so _ready can read them on every peer.
var peer_id: int = 0
var player_name: String = ""
var spawn_index: int = 0

## This player's class (v0.10.0) — its appearance today, its stat identity in future. Seeded in _ready
## from GameConfig.class_roster[spawn_index % size] (the class resources ARE the old per-slot sprite
## table now), reassigned by the /class validator host-side and adopted on every peer via the
## class_changed event / late-join sync_player_field RPC (main.gd) through set_class. Read by the late-join
## loop to tell the joiner our current class. Presentation on the node; never adjudication truth.
var player_class: PlayerClass = null


func _ready() -> void:
	super()
	# Seed the class-driven sprite from the spawn slot (v0.10.0): the class roster replaced the old
	# per-slot _SPRITE_TILES, so slot N wears roster[N % size]'s tile — identical default appearance,
	# now a swappable PlayerClass. set_class paints the region; a /class change or late-join sync
	# repaints it thereafter. An empty roster (misconfig) leaves the scene-default region untouched.
	var roster := GameManager.config.class_roster
	if not roster.is_empty():
		set_class(roster[spawn_index % roster.size()])
	# Nameplate is name-only, seeded from the pre-tree display_name; the HP readout rides its own
	# label under the feet. max_hp is locally known everywhere (an Entity export), so the seed is
	# correct on every peer with no query; the combat referee's attack events drive live updates via
	# set_hp_display, the single formatting site. Full HP at spawn.
	_name_label.text = display_name
	set_hp_display(max_hp, max_hp)

	# Seed the weapon rig from the scene-assigned weapon (longsword by default) on every peer, so a
	# fresh spawn / F5 respawn shows the scene-default weapon; a non-default weapon arrives later via
	# a swap event or the late-join sync (set_weapon). Wired here — the rig never reaches up.
	_weapon_rig.set_weapon(equipped_weapon)

	# MoveInput samples only on the local player's node. Every peer instantiates the child (uniform
	# node graph) but only ours is enabled.
	_move_input.enabled = (peer_id == multiplayer.get_unique_id())
	_move_input.move_requested.connect(_on_move_requested)
	# Seed the sampler's planning tile with the server-derived spawn tile (set by main.gd's
	# spawn_function before this node entered the tree); on_accepted advances it thereafter.
	_move_input.set_current_tile(tile)
	# The node owns the glide<->input handshake: it blocks its own sampler for the whole glide.
	glide_started.connect(func(): _move_input.set_blocked(true))
	glide_finished.connect(func(): _move_input.set_blocked(false))
	# Path-marker wiring, local player only — only the local sampler ever emits target signals,
	# and only the clicker should see their own marker.
	if _move_input.enabled:
		_move_input.path_target_set.connect(_on_path_target_set)
		_move_input.path_target_cleared.connect(func(): _path_marker.visible = false)


# ── Public methods ────────────────────────────────────────────────────────────

## Hostility test (DESIGN §2.2.6, plan decision 6), read HOST-side by the referee/combat. A player
## is hostile to any monster and NEVER to another player. The debug-only GameManager.all_hostile
## flag ORs on top (every entity hostile to every other, itself excepted) so the AoO/combat wiring
## can be demoed two-instance with `hostile=1`. Symmetric with Monster.is_hostile_to.
func is_hostile_to(other: Node) -> bool:
	if GameManager.all_hostile and other != self:
		return true
	return other is Monster


## Adopt a class (v0.10.0): update player_class AND repaint the sprite's region from its atlas_coords in
## ONE place, so a /class change (via the class_changed event) or a late-join sync (sync_player_field) can never
## leave the sprite showing the old class. FLIP PRESERVED: face_toward flips $Sprite2D via flip_h, which
## a region_rect assignment does not touch — but we capture + restore it explicitly so the invariant is
## documented at the site and survives any future region-set that might reset it. A null class is a no-op
## (the misconfig / empty-roster guard) — the scene-default region stays. Driven on the swap/sync event on
## every peer; every peer resolves the same PlayerClass through GameConfig.class_by_name (roster = truth).
func set_class(new_class: PlayerClass) -> void:
	player_class = new_class
	if new_class == null:
		return
	var was_flipped := _sprite.flip_h
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(
		new_class.atlas_coords.x * WorldGrid.TILE_PX, new_class.atlas_coords.y * WorldGrid.TILE_PX,
		WorldGrid.TILE_PX, WorldGrid.TILE_PX)
	_sprite.flip_h = was_flipped


## Relay a reject to the local sampler WITHOUT any cue (1a, v0.10.2). Used for "occupied_hostile":
## the sender was mid-commitment gliding into a hostile it can't bump yet (pipelined) — the bonk's
## thud/flash would misread as "input didn't register" (§2.2.8), so it is suppressed, but the reject
## must still reach the sampler's reject-counting (a walk into an enemy still stops). Mirrors
## play_bonk's on_rejected relay with none of its cues. Local player only (only our sampler is live).
func note_reject_no_cue() -> void:
	if _move_input.enabled:
		_move_input.on_rejected()


## Local attacker's BUSY mirror for a bump (decision 2), driven by the attacker's own `attack`
## event. A bump adjudicates as a `deferred` verdict (no glide_to broadcast), so unlike a glide the
## local player never receives a glide_to to clear its input latch — this does it: it mirrors
## glide_to's signal/relay shape EXACTLY, minus the position tween (the attacker never leaves its
## tile — decision 2's "no client tween"). glide_started blocks MoveInput; on_accepted clears the
## AWAITING latch (advancing nothing — the current tile); a SceneTreeTimer ends the swing window
## and unblocks. No cancel path: the swing plays to completion (the Commitment Rule at the input layer).
func commit_in_place(duration_sec: float) -> void:
	# Kill any lingering glide tween FIRST (mirrors glide_to): the previous step's visual tail can
	# outlive the server's state by ~RTT/2, and its finished callback would emit glide_finished
	# mid-swing — unblocking input early. Killed => no finished, so the swing window owns the end.
	if _glide_tween != null and _glide_tween.is_valid():
		_glide_tween.kill()
	glide_started.emit()
	if _move_input.enabled:
		_move_input.on_accepted(tile)
	get_tree().create_timer(duration_sec).timeout.connect(func(): glide_finished.emit())


## Rejection feedback (§2.3.4): a distinct red flash + a short 2px shake + the thud, all three, so
## "the host refused" is never confusable with the commit ack or with a silent no-op. Called on
## the sender's own player. A bonk only ever fires when NOT gliding (you were refused), but we
## still guard the shake against an active glide tween so the two can't fight over position.
func play_bonk() -> void:
	_flash(_HURT_FLASH_COLOR)
	if not (_glide_tween != null and _glide_tween.is_valid()):
		_shake()
	_bonk_audio.play()
	# Relay the reject to our own sampler (local player only) so it enters the retry cooldown.
	if _move_input.enabled:
		_move_input.on_rejected()


# ── Private methods ───────────────────────────────────────────────────────────

## Entity's glide ordering hook (after glide_started.emit, before the tween is built): relay the
## accept — with the destination — to our own sampler (local player only) so it leaves the
## AWAITING latch and advances its planning tile for the next path recompute.
func _on_glide_accepted(to_tile: Vector2i) -> void:
	if _move_input.enabled:
		_move_input.on_accepted(to_tile)


func _on_move_requested(dir: Vector2i, _fresh: bool) -> void:
	# The white commit-sent input-ack flash was removed in v0.10.2 (Jon: the blink was noise). The
	# submit fires identically for fresh AND auto-walk continuation steps, so `fresh` is now unused.
	# Vector2i survives RPC natively; the host re-derives everything from ITS origin + this dir.
	NetEvents.submit_intent("glide_to", { "dir": dir })


## A click set/replaced the walk target: plant the marker on the tile. top_level marker →
## global_position exclusively. (The commit-sent flash was removed in v0.10.2 — the marker plant is
## now the sole click ack.)
func _on_path_target_set(target_tile: Vector2i) -> void:
	_path_marker.global_position = WorldGrid.tile_to_world(target_tile)
	_path_marker.visible = true
