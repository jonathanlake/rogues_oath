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

# Sentinel returned by _tile_of_peer when a peer has no occupancy. (0,0) is a wall in every room
# (full border), so it can never be a real resting tile — an unambiguous "not found".
const _NO_TILE := Vector2i(0, 0)

## Fallback per-step glide time (seconds) used only when a mover has no GlideSpeed resource
## assigned — a misconfiguration guard, warned once. The real value comes from the mover's tier.
@export var fallback_glide_duration_sec: float = 0.35

# The Players container, handed in by Main via activate(). We read child Player nodes from it
# (membership, the mover's GlideSpeed) but never reach up to Main — component pattern.
var _players: Node2D = null

# Authoritative occupancy: tile (Vector2i) -> peer_id. THE adjudication truth; a player node's
# `tile` is only presentation. Seeded from each Player's spawn tile on child_entered_tree.
var _occupied: Dictionary = {}
# In-flight glides: peer_id -> {from: Vector2i, to: Vector2i, token: int}. Presence here IS the
# "already moving" state (the Commitment Rule backstop). The token disambiguates a stale
# completion timer from a superseded/reconnected glide.
var _gliding: Dictionary = {}
# Destination reservations: tile (Vector2i) -> peer_id. ONLY populated in the
# origin_frees_at_glide_start=false branch, where the origin is held until arrival, so the
# destination must be reserved separately for the duration of the glide. Empty in the true branch.
var _reserved: Dictionary = {}

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
	# Seed occupancy as each Player enters (spawn sets player.tile before it enters the tree, so
	# it's readable here) and forget a peer wholesale as its node leaves (disconnect/teardown).
	_players.child_entered_tree.connect(_on_player_entered)
	_players.child_exiting_tree.connect(_on_player_exiting)


## True if no body rests on, is gliding onto, or has reserved this tile — the single occupancy
## predicate, used by the validator and by Main's spawn-slot skip. Works for both origin-timing
## branches: in the true branch a glider sits at its destination in _occupied (origin already
## freed) and _reserved is empty; in the false branch the origin stays in _occupied and the
## destination lives in _reserved, so the union covers both resting and in-flight bodies.
func is_tile_free(tile: Vector2i) -> bool:
	return not _occupied.has(tile) and not _reserved.has(tile)


# ── Private methods ───────────────────────────────────────────────────────────

## The "glide_to" validator (host-only; NetEvents calls it synchronously on the main thread, so
## each verdict mutates state before the next intent is examined — cross-diagonal swaps resolve
## deterministically in arrival order). Validation order is fixed: membership → dir shape →
## already-moving → origin (from referee truth) → dest walkable → corner rule → dest free →
## stamp duration → mutate + accept. Returns { ok: false, reason } or { ok: true, data }.
func _validate_glide(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Membership: only a peer with a live player node is in the session (no pipe-level gate yet).
	var mover := _players.get_node_or_null(str(sender_peer_id)) as Player
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

	# The Commitment Rule backstop: a peer already gliding cannot start another step. No queue
	# (DESIGN §2.2.5) — the second intent is simply rejected, felt as a bonk.
	if _gliding.has(sender_peer_id):
		return { "ok": false, "reason": "already moving" }

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

	# Destination must not be held by another body (resting, gliding-onto, or reserved).
	if not is_tile_free(to):
		return { "ok": false, "reason": "occupied" }

	# Duration is stamped ONCE here (base × diagonal multiplier) and drives BOTH the host's
	# completion timer and every client's tween, so the two can never disagree.
	var duration := _step_duration(mover, dir)

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
## base BEFORE the multiplier so a diagonal debug step still stamps override × multiplier.
func _step_duration(mover: Player, dir: Vector2i) -> float:
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


## Completion timer callback. Stale-guard: only finalize if the peer's current glide is still the
## one this token was stamped for (a superseding glide or a disconnect/rejoin bumps the token, so
## an old timer no-ops). In the hold-origin branch the occupancy swap happens HERE.
func _finish_glide(peer_id: int, token: int) -> void:
	var rec = _gliding.get(peer_id)
	if rec == null or int(rec.get("token", -1)) != token:
		return
	if not GameManager.config.origin_frees_at_glide_start:
		var from: Vector2i = rec["from"]
		var to: Vector2i = rec["to"]
		_occupied.erase(from)
		_reserved.erase(to)
		_occupied[to] = peer_id
	_gliding.erase(peer_id)


## Reverse lookup: the single tile a peer rests on in _occupied, or _NO_TILE if it has none.
## Called only for a non-gliding member, which has exactly one entry — the scan is over ≤ a
## handful of players.
func _tile_of_peer(peer_id: int) -> Vector2i:
	for tile in _occupied:
		if _occupied[tile] == peer_id:
			return tile
	return _NO_TILE


## Seed occupancy as a Player enters the tree. player.tile is set by Main's spawn_function before
## the node enters, so it's the server-derived spawn tile here — not a client-supplied value.
func _on_player_entered(node: Node) -> void:
	if node is Player:
		_occupied[node.tile] = node.peer_id


## Forget a peer wholesale as its node leaves (disconnect or session teardown): drop its resting
## tile, any in-flight glide, and any reservation, so a stale timer or a rejoin finds clean state.
func _on_player_exiting(node: Node) -> void:
	if not (node is Player):
		return
	var peer_id: int = node.peer_id
	_gliding.erase(peer_id)
	_erase_by_value(_occupied, peer_id)
	_erase_by_value(_reserved, peer_id)


## Remove every tile->peer entry whose value is this peer (a peer holds at most one of each, but
## the hold-origin branch can momentarily have both an _occupied and a _reserved tile).
func _erase_by_value(dict: Dictionary, peer_id: int) -> void:
	for tile in dict.keys():
		if dict[tile] == peer_id:
			dict.erase(tile)
