extends Node

## The HOST-ONLY movement brain (DESIGN §2.5.3). It owns the authoritative tile bookkeeping
## and is the "glide_to" validator registered with NetEvents: clients submit a DIRECTION intent,
## this referee decides from ITS own state (never the wire, never a node's rendered position)
## whether the step is legal, stamps the duration server-side, and mutates occupancy. Every
## client just plays back the broadcast event.
##
## Component pattern: Main hands it the Players container via activate() and it never reaches up
## — it only reads the container it was given, GameManager.config, and the mover's own resource.
## It runs on the host alone; clients instantiate the node (it's in main.tscn on every peer) but
## activate() is called only inside main.gd's is_server() branch, so a client's referee is inert.
##
## Two designer toggles change its behaviour, both read live from GameConfig so Jeff can flip
## them in playtest without code (DESIGN §2.2.7 / Part 4 Q4):
##  - origin_frees_at_glide_start: true = the departed tile frees the instant the glide STARTS
##    (conga-line); false = the origin stays held until the glide finishes.
##  - bodies_block_corners: walls ALWAYS block a diagonal squeeze; this only governs whether an
##    occupied flank tile also blocks it.
##
## Pipelined next step (§2.2.5 amendment, v0.3.4): under origin_frees_at_glide_start, the referee
## holds at most ONE accepted-but-unbroadcast step per mover — adjudicated at accept, broadcast
## only when the mover's current glide completes. See `_pending` for the full invariant.

# Sentinel returned by _tile_of_peer when a peer has no occupancy. (0,0) is a wall in every room
# (full border), so it can never be a real resting tile — an unambiguous "not found".
const _NO_TILE := Vector2i(0, 0)

## Fallback per-step glide time (seconds) used only when a mover has no GlideSpeed resource
## assigned — a misconfiguration guard, warned once. The real value comes from the mover's tier.
@export var fallback_glide_duration_sec: float = 0.35

# The Players container, handed in by Main via activate(). We read child Player nodes from it
# (membership, the mover's GlideSpeed) but never reach up to Main — component pattern.
var _players: Node2D = null
# The Monsters container, handed in by Main via set_monsters() on the HOST only (a client's
# referee is inert and never sets it). Monsters are seeded/cleaned via the same enter/exit hooks
# as players and resolved through _node_of_id. Null on clients and until set_monsters runs.
var _monsters: Node2D = null
# The CombatReferee, handed in by Main via set_combat() on the HOST only (chunk 2). The two referees
# are peers wired by Main (component pattern) and call each other ONLY through these references: this
# referee asks combat to resolve bump/AoO damage and to test liveness; combat asks this one to erase
# a dead entity's occupancy and to read a wind-up's target tile. Untyped (combat's script has no
# class_name) so its calls resolve dynamically — locals off it are typed explicitly. Null on clients.
var _combat = null

# Authoritative occupancy: tile (Vector2i) -> ENTITY ID. THE adjudication truth; a node's `tile`
# is only presentation. An entity id is a peer id (> 0) for a player or a host-assigned negative
# int for a monster (plan decision 5) — one occupancy space, no overlap. Seeded from each entity's
# spawn tile on child_entered_tree (players and monsters alike).
var _occupied: Dictionary = {}
# In-flight glides: entity_id -> {from: Vector2i, to: Vector2i, token: int}. Presence here IS the
# "already moving" state (the Commitment Rule backstop). The token disambiguates a stale
# completion timer from a superseded/reconnected glide.
var _gliding: Dictionary = {}
# Destination reservations: tile (Vector2i) -> peer_id. ONLY populated in the
# origin_frees_at_glide_start=false branch, where the origin is held until arrival, so the
# destination must be reserved separately for the duration of the glide. Empty in the true branch.
var _reserved: Dictionary = {}
# Pending pipelined step: peer_id -> {from, to, duration}. At most ONE per mover — the next step,
# adjudicated AT ACCEPT (origin = the current glide's destination) but its broadcast HELD until
# that glide's completion boundary (_finish_glide promotes it). Players ONLY: the pipeline exists
# to hide client RTT, and monsters (negative ids) are host-local brains with no RTT that think at
# step boundaries — the pipelined branch gates on id > 0, so a monster never enters this slot.
#
# Adjudicate-at-accept is NOT a prediction under origin_frees_at_glide_start=true: occupancy
# mutates ONLY at sequential accepts (the pending slot swaps _occupied immediately, one step
# deeper), while the completion timers touch only _gliding/broadcast — so every later accept
# reads authoritative referee truth, never a guessed future. M3 CAUTION: forced movement that
# bypasses the intent pipe (knockback, teleport, etc.) breaks this — any such mechanic MUST
# clear or re-adjudicate a mover's pending slot, or it will broadcast a step from a tile the
# mover no longer occupies. The false branch (origin_frees_at_glide_start off) never accepts
# into this slot: the pipeline is simply off and the stop-and-go RTT gap returns until that
# branch's mechanics are designed. Disconnect is the SOLE cancel path (_on_player_exiting).
var _pending: Dictionary = {}

# Monotonic per-glide id, stamped into each _gliding record so a completion timer can tell "my"
# glide from a later one for the same peer (disconnect+rejoin, or any superseding glide).
var _next_token: int = 0
# One-shot latch so a mover with no GlideSpeed resource warns exactly once, not every step.
var _warned_null_speed: bool = false


## Host-only entry point, called by Main inside its is_server() branch BEFORE the host spawns
## its own player — so child_entered_tree seeds occupancy for every player including the host's.
## Registers the validator and wires the container's membership signals.
func activate(players: Node2D) -> void:
	_players = players
	NetEvents.register_handler("glide_to", _validate_glide)
	# Seed occupancy as each Player enters (spawn sets tile + entity_id before it enters the tree,
	# so both are readable here) and forget a peer wholesale as its node leaves (disconnect/teardown).
	# Players and monsters share the one Entity enter/exit contract — one id space.
	_players.child_entered_tree.connect(_on_entity_entered)
	_players.child_exiting_tree.connect(_on_entity_exiting)


## Host-only, called by Main right after activate() and BEFORE the host spawns any monster — so the
## monster enter hook seeds occupancy for every monster. Wires the Monsters container's membership
## signals the same way activate() wires the Players container. Never called on clients (their
## referee is inert), so _monsters stays null there.
func set_monsters(monsters: Node2D) -> void:
	_monsters = monsters
	_monsters.child_entered_tree.connect(_on_entity_entered)
	_monsters.child_exiting_tree.connect(_on_entity_exiting)


## Host-only, called by Main right after the CombatReferee is activated and BEFORE any spawn — so
## the bump/AoO paths and the wind-up commit have the combat reference the moment the first intent
## is adjudicated. Null on clients (their referee is inert and never adjudicates).
func set_combat(combat: Node) -> void:
	_combat = combat


## The one id -> node resolver (plan decision 5). Positive ids are players, negatives are monsters;
## each resolves against its own container, or null if absent/off-host. Used everywhere the referee
## needs the node behind an occupancy value. Node-typed on purpose — callers that need a concrete
## field (glide_speed, player_name) read it dynamically, since a player and a monster share the
## duck-typed surface the referee touches but not a common class.
func _node_of_id(entity_id: int) -> Node:
	if entity_id > 0:
		return _players.get_node_or_null(str(entity_id))
	if _monsters != null:
		return _monsters.get_node_or_null(str(entity_id))
	return null


## True if no body rests on, is gliding onto, or has reserved this tile — the single occupancy
## predicate, used by the validator and by Main's spawn-slot skip. Works for both origin-timing
## branches: in the true branch a glider sits at its destination in _occupied (origin already
## freed) and _reserved is empty; in the false branch the origin stays in _occupied and the
## destination lives in _reserved, so the union covers both resting and in-flight bodies.
func is_tile_free(tile: Vector2i) -> bool:
	return not _occupied.has(tile) and not _reserved.has(tile)


## Host-only entry for a MonsterBrain's decided step. Runs the SAME validator a player intent does
## (host-local — no RPC; monsters have no RTT) and, on a clean accept, broadcasts the glide_to on
## the entity's behalf so every peer plays it back. Returns true on accept, false on any refusal so
## the brain can back off and re-think. A brain-submitted intent bypasses NetEvents._handle_intent
## (which is what broadcasts a player's accepted verdict), so the referee must post the event here.
##
## Monsters never pipeline, so a deferred verdict can't occur here; if one somehow did it's an
## invariant break (a monster wrongly holding a pending slot) — treat it as a non-accept.
func submit_monster_intent(entity_id: int, dir: Vector2i) -> bool:
	var verdict := _validate_glide(entity_id, { "dir": dir })
	if not verdict.get("ok", false) or verdict.get("deferred", false):
		return false
	var data: Dictionary = verdict["data"]
	NetEvents.post_event("glide_to", data, entity_id)
	return true


## Brain accessor: is this entity mid-glide right now? The referee's _gliding is the authoritative
## "committed and moving" state (the same predicate that yields "already moving").
func is_entity_moving(entity_id: int) -> bool:
	return _gliding.has(entity_id)


## Brain accessor: the tile this entity currently occupies in authoritative truth, or a wall
## sentinel (0,0) if it holds none (untracked / despawned). (0,0) is a wall in every room, so no
## live body ever rests there — callers treat a wall result as "gone".
func tile_of_entity(entity_id: int) -> Vector2i:
	return _tile_of_peer(entity_id)


## Brain accessor: every player's authoritative tile (occupancy values > 0). Under conga timing a
## gliding player's entry sits at its DESTINATION, so a chaser paths toward where the player is
## heading — the honest read of the Commitment Rule (you can't dodge to a tile you've committed off).
func player_tiles() -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for tile in _occupied:
		if _occupied[tile] > 0:
			tiles.append(tile)
	return tiles


## The authoritative entity id resting on / claiming a tile, or 0 (never a real id) if free. Used by
## CombatReferee to resolve a wind-up's target-tile occupant. Mirrors is_tile_free's union: a body
## sits in _occupied (both timing branches), or _reserved while gliding onto the tile (hold-origin).
func entity_at(tile: Vector2i) -> int:
	if _occupied.has(tile):
		return _occupied[tile]
	if _reserved.has(tile):
		return _reserved[tile]
	return 0


## Host-only: record a from==to BUSY commit for an entity for `duration_sec`, with NO occupancy
## mutation of any kind (the entity never leaves its tile — decision 2). The single shared busy-record
## path for BOTH a player's bump swing and a monster's wind-up, so the "already moving" machinery has
## exactly one authoring site. Presence in _gliding IS the busy state (is_entity_moving reads it);
## the existing _finish_glide runs at the timer verbatim — it promotes a pending slot (a differently-
## directed intent committed mid-swing → swing-then-move) or, with none, erases the record. Returns
## false if the entity is already busy or untracked (the caller declines).
func commit_in_place(entity_id: int, duration_sec: float) -> bool:
	if _gliding.has(entity_id):
		return false
	var from := _tile_of_peer(entity_id)
	if from == _NO_TILE:
		return false
	var token := _next_token
	_next_token += 1
	_gliding[entity_id] = { "from": from, "to": from, "token": token }
	get_tree().create_timer(duration_sec).timeout.connect(_finish_glide.bind(entity_id, token))
	return true


## Host-only: erase ALL of a dead entity's occupancy bookkeeping in ONE synchronous pass (decision 7)
## — occupancy by value, any in-flight glide, any pending slot, any reservation — so the instant a
## kill resolves no stale record blocks another mover. Called by CombatReferee from inside
## apply_damage, BEFORE it despawns the node; the container exit hooks fire later and are idempotent
## (this reuses the very same erases, so re-erasing already-gone keys is a no-op).
func clear_entity(entity_id: int) -> void:
	_gliding.erase(entity_id)
	_pending.erase(entity_id)
	_erase_by_value(_occupied, entity_id)
	_erase_by_value(_reserved, entity_id)


# ── Private methods ───────────────────────────────────────────────────────────

## The "glide_to" validator (host-only; NetEvents calls it synchronously on the main thread, so
## each verdict mutates state before the next intent is examined — cross-diagonal swaps resolve
## deterministically in arrival order). Validation order is fixed: membership → dir shape →
## already-moving → origin (from referee truth) → dest walkable → corner rule → dest free →
## stamp duration → mutate + accept. Returns { ok: false, reason } or { ok: true, data }.
func _validate_glide(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Membership: only an entity with a live node is adjudicable — a player (positive id) or a
	# monster (negative id), resolved through the one id -> node helper. Untyped on purpose so the
	# duration/AoO reads below duck-type across player and monster. (`sender_peer_id` keeps its name
	# for minimal churn; it is an entity id, positive OR negative, throughout this validator.)
	var mover = _node_of_id(sender_peer_id)
	if mover == null:
		return { "ok": false, "reason": "not in session" }

	# Direction shape: must be a Vector2i with components in {-1,0,1} and non-zero. The wire is
	# never trusted — a malformed intent is refused, not coerced.
	var dir_raw = data.get("dir")
	if typeof(dir_raw) != TYPE_VECTOR2I:
		return { "ok": false, "reason": "bad direction" }
	var dir: Vector2i = dir_raw
	if dir == Vector2i.ZERO or absi(dir.x) > 1 or absi(dir.y) > 1:
		return { "ok": false, "reason": "bad direction" }

	# Liveness gate: a dead entity's in-flight intent (killed by an AoO while its RPC crossed the
	# wire — the node still exists until queue_free lands) must reject cleanly, not adjudicate from
	# erased occupancy or reach the bump path as a dead attacker. "dead" is log-suppressed like
	# "already moving" (the died event already told the player everything).
	if _combat != null and not _combat.is_alive(sender_peer_id):
		return { "ok": false, "reason": "dead" }

	# The Commitment Rule backstop and the pipeline gate. A mover already gliding may commit ONE
	# next step into the pending slot (§2.2.5 amendment) — but only under the conga toggle, and
	# only if the slot is free. A third intent (one gliding + one held) is the same "already
	# moving" bonk as before. When pipelined, the check chain below runs UNCHANGED: _tile_of_peer
	# already returns the current glide's destination (its single _occupied entry), which IS this
	# step's origin, so walkable/corner/dest-free/duration all adjudicate against the right tile.
	var is_pipelined := false
	if _gliding.has(sender_peer_id):
		# Monsters (id <= 0) never pipeline: host-local brains have no RTT and only think at step
		# boundaries, so a mid-glide monster intent is a bug/backstop and just gets "already moving"
		# (the slot is players-only — see _pending). Players pipeline only under the conga toggle.
		if sender_peer_id <= 0 or not GameManager.config.origin_frees_at_glide_start or _pending.has(sender_peer_id):
			return { "ok": false, "reason": "already moving" }
		is_pipelined = true

	# Origin is read from referee truth, never the node's position. A non-gliding member always
	# has exactly one _occupied entry (seeded at spawn); its absence is a bug, not a legal state.
	var from := _tile_of_peer(sender_peer_id)
	if from == _NO_TILE:
		push_error("[MoveReferee] no occupancy for member peer %d — refusing glide" % sender_peer_id)
		return { "ok": false, "reason": "not in session" }

	# Destination must be in-bounds and floor. OOB counts as wall in WorldGrid, so this one check
	# covers both — reported as "blocked" (a wall is in the way).
	var to := from + dir
	if not WorldGrid.is_walkable(to):
		return { "ok": false, "reason": "blocked" }

	# Corner rule (diagonals only): a squeeze between two walls that touch only at a corner is
	# illegal even though both endpoints are floor. Both orthogonal flanks must be non-wall;
	# when bodies_block_corners is on, an occupied flank blocks it too (DESIGN §2.2.7).
	if dir.x != 0 and dir.y != 0:
		var flank_x := from + Vector2i(dir.x, 0)
		var flank_y := from + Vector2i(0, dir.y)
		if WorldGrid.is_wall(flank_x) or WorldGrid.is_wall(flank_y):
			return { "ok": false, "reason": "corner" }
		if GameManager.config.bodies_block_corners:
			if not is_tile_free(flank_x) or not is_tile_free(flank_y):
				return { "ok": false, "reason": "corner" }

	# Destination must not be held by another body (resting, gliding-onto, or reserved). From IDLE
	# ONLY (decision 1), a dest held by a hostile LIVING entity becomes a BUMP attack instead of a
	# reject: move-into-enemy = attack. A PIPELINED intent into a held tile keeps the plain reject —
	# the held slot never holds an attack, so there is no dead-target-at-boundary problem (and
	# `is_pipelined` here is exactly "mid-glide", since the third-intent case already bonked above).
	if not is_tile_free(to):
		# sender > 0: only PLAYERS bump (M3 monsters attack solely via the telegraphed wind-up; the
		# brain's adjacency branch fires before any step toward a player could be chosen — this is
		# the structural backstop that keeps a monster intent from ever dealing bump damage).
		if not is_pipelined and sender_peer_id > 0 and _combat != null:
			var occupant_id := entity_at(to)
			var occupant := _node_of_id(occupant_id)
			if occupant != null and _combat.is_alive(occupant_id) and mover.is_hostile_to(occupant):
				return _begin_bump(sender_peer_id, mover, occupant_id, occupant)
		return { "ok": false, "reason": "occupied" }

	# Duration is stamped ONCE here (base × diagonal multiplier) and drives BOTH the host's
	# completion timer and every client's tween, so the two can never disagree.
	var duration := _step_duration(mover, dir)

	# Pipelined accept: the mover is mid-glide, so this step is committed NOW (occupancy swaps one
	# step deeper, exactly as the conga branch below) but its broadcast — and its AoO scan — are
	# held to the completion boundary (_finish_glide promotes the slot). No _gliding write and no
	# timer here: the current glide's timer owns the boundary. The debug print is the only stdout
	# trace of a deferred accept (the broadcast that would otherwise log it fires a step later).
	if is_pipelined:
		_occupied.erase(from)
		_occupied[to] = sender_peer_id
		_pending[sender_peer_id] = { "from": from, "to": to, "duration": duration }
		if OS.is_debug_build():
			print("[MoveReferee] pipelined accept peer=%d %s→%s" % [sender_peer_id, from, to])
		return { "ok": true, "deferred": true }

	# Attack of opportunity (DESIGN §2.2.6): starting a glide OUT of a tile grants a free attack to
	# each hostile adjacent to the origin. Fired at verdict time, BEFORE the occupancy mutation below
	# — the mover must still be counted at `from` (§2.2.6 "starting a glide out of a tile"), and in
	# the conga branch the swap that follows erases `from` and claims `to`, which would change the
	# adjacency this scan reads. Names/damage are resolved host-side; no wire value is ever trusted.
	#
	# Chunk 2 makes AoO REAL damage in BOTH directions (decision 4): the chunk-1 player-only guard
	# is gone (monsters take AND deal AoO now), occupants resolve via _node_of_id, and the scan can
	# KILL the mover. If it does, the glide is aborted here — no occupancy mutation, no broadcast,
	# reject "dead" (Q1 placeholder: does a committed action complete post-mortem? — parked OPEN).
	if _trigger_attacks_of_opportunity(from, sender_peer_id, mover):
		return { "ok": false, "reason": "dead" }

	# Mutate occupancy and record the glide, branching on the origin-timing toggle. Both branches
	# live only here — clients never touch this state.
	var token := _next_token
	_next_token += 1
	_gliding[sender_peer_id] = { "from": from, "to": to, "token": token }
	if GameManager.config.origin_frees_at_glide_start:
		# Conga: the origin frees immediately; the mover claims the destination now.
		_occupied.erase(from)
		_occupied[to] = sender_peer_id
	else:
		# Hold origin: keep it in _occupied, reserve the destination until arrival.
		_reserved[to] = sender_peer_id
	# Host-side completion. create_timer survives on the host's tree; the stale-guard in
	# _finish_glide ignores a fire whose glide has been superseded or whose peer has left.
	get_tree().create_timer(duration).timeout.connect(_finish_glide.bind(sender_peer_id, token))

	return { "ok": true, "data": { "from": from, "to": to, "duration_sec": duration } }


## Compute a step's glide time: the mover's tier (or the warned fallback if it has none), then
## the diagonal multiplier for a diagonal step, and the debug override — when set — replaces the
## base BEFORE the multiplier so a diagonal debug step still stamps override × multiplier. `mover`
## is untyped: a Player or a Monster, both of which expose glide_speed (the referee reads only that).
func _step_duration(mover, dir: Vector2i) -> float:
	var base := fallback_glide_duration_sec
	if mover.glide_speed == null:
		if not _warned_null_speed:
			push_warning("[MoveReferee] mover has no GlideSpeed — using fallback %.2fs" % fallback_glide_duration_sec)
			_warned_null_speed = true
	else:
		base = mover.glide_speed.glide_duration_sec
	if GameManager.debug_glide_override_sec > 0.0:
		base = GameManager.debug_glide_override_sec
	if dir.x != 0 and dir.y != 0:
		base *= GameManager.config.diagonal_step_multiplier
	return base


## Begin a BUMP attack (host-only, decision 1+2). The idle mover moves INTO a hostile living tile:
## damage applies instantly (deterministic), then the attacker is BUSY for its swing duration via the
## shared from==to commit — NO occupancy mutation (the attacker never leaves its tile), NO glide_to
## broadcast (the returned `deferred` verdict suppresses it). CombatReferee.apply_damage posts the
## `attack` event that drives all feedback. The busy record's timer runs the existing _finish_glide,
## which promotes a differently-directed intent committed mid-swing (swing-then-move) or erases the
## record. Damage/duration come from the combat referee (stats live in ONE place); `attacker` is
## untyped so the reads duck-type across player (the only M3 bumper) and a future monster bumper.
func _begin_bump(attacker_id: int, attacker, target_id: int, target) -> Dictionary:
	var damage: int = _combat.damage_of(attacker)
	var duration: float = _combat.bump_duration_of(attacker)
	commit_in_place(attacker_id, duration)
	_combat.apply_damage(attacker_id, target_id, damage, "bump", duration)
	return { "ok": true, "deferred": true }


## Attack-of-opportunity scan (host-only, DESIGN §2.2.6, decision 4). For each of the origin's 8
## neighbours holding a body, an alive + hostile occupant gets a REAL free attack (instant, no
## wind-up — an opportunity strike) via CombatReferee.apply_damage(kind "free"). Returns whether the
## MOVER died mid-scan so the caller can abort its glide. Mid-scan death safety: SNAPSHOT the attacker
## list before applying any damage (apply_damage mutates _occupied on a kill — never iterate + mutate),
## then apply in order, stopping the instant the mover is dead. Occupants resolve via _node_of_id, so
## a monster deals AoO and a monster mover takes it (both guards lifted from chunk 1).
func _trigger_attacks_of_opportunity(from: Vector2i, mover_peer_id: int, mover) -> bool:
	if _combat == null:
		return false
	# Snapshot phase: collect the eligible attacker ids from CURRENT occupancy, touching nothing.
	var attackers: Array[int] = []
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var neighbor := from + Vector2i(dx, dy)
			if not _occupied.has(neighbor):
				continue
			var occupant_id: int = _occupied[neighbor]
			var occupant := _node_of_id(occupant_id)
			if occupant == null:
				continue
			# §2.2.6 "alive and able to act": a dead neighbour deals nothing.
			if not _combat.is_alive(occupant_id):
				continue
			if not occupant.is_hostile_to(mover):
				continue
			attackers.append(occupant_id)
	# Apply phase: each snapshotted attacker strikes, in order. Re-check liveness (an earlier strike
	# in this same scan could in principle have killed a later attacker), and stop once the mover
	# dies — a corpse takes no further free hits, and apply_damage already tore its state down.
	for occupant_id in attackers:
		if not is_instance_valid(_node_of_id(occupant_id)) or not _combat.is_alive(occupant_id):
			continue
		if not _combat.is_alive(mover_peer_id):
			return true
		var occupant := _node_of_id(occupant_id)
		var mover_died: bool = _combat.apply_damage(occupant_id, mover_peer_id, _combat.damage_of(occupant), "free", 0.0)
		if mover_died:
			return true
	return false


## Completion timer callback. Stale-guard: only finalize if the peer's current glide is still the
## one this token was stamped for (a superseding glide or a disconnect/rejoin bumps the token, so
## an old timer no-ops). In the hold-origin branch the occupancy swap happens HERE.
func _finish_glide(peer_id: int, token: int) -> void:
	var rec = _gliding.get(peer_id)
	if rec == null or int(rec.get("token", -1)) != token:
		return
	# The pending guard covers a mid-session true->false toggle flip: a pipelined accept already
	# swapped this mover's occupancy one step deeper, so running the hold-origin swap here would
	# write a SECOND _occupied entry at the finished glide's dest. With a pending slot, occupancy
	# is already authoritative — skip. (Pure false-branch sessions never populate the slot.)
	if not GameManager.config.origin_frees_at_glide_start and not _pending.has(peer_id):
		var from: Vector2i = rec["from"]
		var to: Vector2i = rec["to"]
		_occupied.erase(from)
		_reserved.erase(to)
		_occupied[to] = peer_id
	# Boundary of the just-finished glide. A held next step (pipelined accept) is promoted to a
	# live glide and broadcast HERE — keyed on _pending.has alone, never a config re-check, so a
	# mid-session toggle flip can't strand a held slot. Occupancy was already swapped at accept;
	# only the AoO scan, the _gliding record, the completion timer, and the broadcast run now.
	if _pending.has(peer_id):
		var slot: Dictionary = _pending[peer_id]
		_pending.erase(peer_id)
		var from: Vector2i = slot["from"]
		var to: Vector2i = slot["to"]
		var duration: float = slot["duration"]
		# Re-resolve the mover: exit cleanup erases the slot, so a live pending slot should always
		# have a live node — a miss is a real invariant break, worth a log line, never a silent
		# no-op. Erase the stale _gliding record and bail defensively. Pending is players-only, so
		# this id is always positive and _node_of_id lands in the Players container.
		var mover := _node_of_id(peer_id) as Player
		if mover == null:
			push_warning("[MoveReferee] pending slot for peer %d has no node — dropping" % peer_id)
			_gliding.erase(peer_id)
			# Self-contained cleanup: if this fired, exit cleanup did NOT run — drop the ghost's
			# occupancy too (its single entry is the pre-claimed dest) so no tile stays claimed.
			_erase_by_value(_occupied, peer_id)
			return
		# AoO fires at the moment the step actually STARTS (boundary-time adjacency — the honest
		# §2.2.6 read for a deferred step). This INVERTS the fire-before-mutation note on the idle
		# path (there the swap has not happened yet); here occupancy swapped at accept, so `from`
		# is the tile the mover is leaving right now. If the AoO KILLS the mover at this boundary,
		# apply_damage already erased its occupancy (the pre-claimed dest) and despawned it via
		# clear_entity — nothing to promote or broadcast, so bail (decision 4, boundary case).
		if _trigger_attacks_of_opportunity(from, peer_id, mover):
			_gliding.erase(peer_id)
			return
		# Promote to a live glide with a FRESH token + timer. The full _gliding record must be in
		# place BEFORE the broadcast: post_event is call_local, so on the host it re-enters the
		# event path synchronously and any handler that reads referee state must see consistent
		# truth. AoO's attack events sit at the lower seq, same relative order as the idle path.
		var next_token := _next_token
		_next_token += 1
		_gliding[peer_id] = { "from": from, "to": to, "token": next_token }
		get_tree().create_timer(duration).timeout.connect(_finish_glide.bind(peer_id, next_token))
		NetEvents.post_event("glide_to", { "from": from, "to": to, "duration_sec": duration }, peer_id)
		return
	_gliding.erase(peer_id)


## Reverse lookup: the single tile a peer rests on in _occupied, or _NO_TILE if it has none.
## Called only for a non-gliding member, which has exactly one entry — the scan is over ≤ a
## handful of players.
func _tile_of_peer(peer_id: int) -> Vector2i:
	for tile in _occupied:
		if _occupied[tile] == peer_id:
			return tile
	return _NO_TILE


## Seed occupancy as an Entity enters its container — players AND monsters, one hook, one id space
## (positive peer ids, negative monster ids). tile and entity_id are set by Main's spawn_function
## BEFORE the node enters the tree, so both read the server-derived values here — never a
## client-supplied value, and never a _ready-time field (this hook fires pre-_ready).
func _on_entity_entered(node: Node) -> void:
	if node is Entity:
		_occupied[node.tile] = node.entity_id


## Forget an entity wholesale as its node leaves (disconnect / despawn / teardown): drop its resting
## tile, any in-flight glide, any pending slot, and any reservation, so a stale timer or a rejoin
## finds clean state. Shared by players and monsters: monsters never enter _pending (guarded in the
## validator) or _reserved under conga, but those erases are harmless no-ops there.
func _on_entity_exiting(node: Node) -> void:
	if not (node is Entity):
		return
	var entity_id: int = node.entity_id
	_gliding.erase(entity_id)
	# Disconnect is the SOLE pipeline-slot cancel path (§2.2.5 amendment). Dropping the slot here
	# discards the held step; _erase_by_value(_occupied) below already reverts its pre-claimed
	# destination — a pipelined mover's single _occupied entry IS that dest (swapped at accept).
	_pending.erase(entity_id)
	_erase_by_value(_occupied, entity_id)
	_erase_by_value(_reserved, entity_id)


## Remove every tile->peer entry whose value is this peer (a peer holds at most one of each, but
## the hold-origin branch can momentarily have both an _occupied and a _reserved tile).
func _erase_by_value(dict: Dictionary, peer_id: int) -> void:
	for tile in dict.keys():
		if dict[tile] == peer_id:
			dict.erase(tile)
