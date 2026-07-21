extends Node

## The HOST-ONLY pace resolver (DESIGN §2.8.7 — Tactical Zones v1). It is the SINGLE place the two
## tempo dials (explore vs tactical) are chosen from: every stamp site (MoveReferee's step/rest,
## CombatReferee's windup/recovery, MonsterBrain's pacing) asks THIS referee, per entity, what beat
## their next committed window stamps from. Nothing else decides pace — one resolver, no divergence.
##
## Component pattern (CLAUDE.md): Main hands it the Players + Monsters containers AND the MoveReferee
## reference via activate(), and injects THIS referee into the two stamping referees + each brain. It
## sits beside the other referees and, like them, is inert on clients: the node exists on every peer
## (it's in main.tscn) but activate() runs only inside main.gd's is_server() branch, so a client's
## pace referee never resolves anything (its stamp sites never run either — adjudication is host-side).
##
## The semantics it enforces (DESIGN §2.8.7, v1):
##  - A PLAYER is TACTICAL iff any of: (bubble) within an aggroed monster's tactical_radius_tiles
##    (Chebyshev); (leash) they are some aggroed monster's current chase target; (forcing window)
##    they took a hostile action within the last tactical_force_beats. Otherwise EXPLORE — but only
##    after tactical_exit_sec of continuously qualifying for explore (hysteresis: no flicker at a
##    bubble edge). A player with no history qualifies for explore immediately (zero exit delay).
##  - A MONSTER is TACTICAL iff aggroed (it's always inside its own bubble); idle / brainless monsters
##    (the dummy) act on the explore beat and project no bubble.
##
## Commitment Rule (DESIGN §2.1): pace is read at STAMP time only. An in-flight commit keeps its baked
## seconds (§2.8.2 stamp-and-bake) — this referee never re-derives a committed window.
##
## Chunk 1 scope: the resolver RESOLVES. The pace_changed broadcast + poll timer + UI cue land in
## chunk 2; here beat_sec_for is the only read, and it is also the hysteresis WRITER (see below).

# Sentinel tile for "this entity holds no occupancy" — mirrors MoveReferee._NO_TILE. (0,0) is a wall
# in every room, so no live body ever rests there; an untracked / despawned id reads as this.
const _NO_TILE := Vector2i(0, 0)

# The Players / Monsters containers, handed in by Main via activate() on the HOST only. Players is
# used only for its exit hook (forget a departed player's hysteresis/forcing state); Monsters both
# resolves a monster id -> its authored tactical_radius_tiles AND drives the engagement-erase hook.
# Null on clients (activate never runs there).
var _players: Node2D = null
var _monsters: Node2D = null
# The MoveReferee, handed in by Main via activate(). The pace resolver reads AUTHORITATIVE tiles from
# it (tile_of_entity) for the bubble's Chebyshev test — never a rendered node position (§2.5). Untyped
# (its script has no class_name) so its calls resolve dynamically, like CombatReferee holds it. Null
# on clients.
var _move_referee = null

# Live engagement state, reported by each MonsterBrain every think (report_engagement): monster id
# (negative) -> the player id it is currently chasing (its leash target). Presence means "this monster
# is aggroed" (drives BOTH the monster's own tactical pace and the players' bubble); the value is the
# leash target. Erased when the brain reports un-aggroed and on the monster's container-exit.
var _engagements: Dictionary = {}
# Forcing-window deadlines (anti-cheese): player id -> Time.get_ticks_msec() wall-clock instant the
# window expires. Armed by report_hostile_action; a player is tactical while now < this. No entry /
# past deadline = not forcing.
var _force_until: Dictionary = {}
# Hysteresis timestamps: player id -> the last Time.get_ticks_msec() at which the player would resolve
# tactical. WRITTEN by beat_sec_for as a side effect on every tactical resolve (host-only, single-
# threaded), so stamp-time and any future poll-timer verdict read the SAME truth and can never
# disagree. NO ENTRY = never qualified = explore immediately (fresh spawns / late joiners), which is
# why this is a lazy write rather than a seeded default.
var _last_qualified: Dictionary = {}


# ── Public methods ────────────────────────────────────────────────────────────

## Host-only entry point, called by Main inside its is_server() branch AFTER the MoveReferee has its
## containers wired (so tile reads resolve) and BEFORE any spawn. Stores the refs and wires the
## container-exit hooks: a despawned monster's engagement is forgotten (no ghost bubble), a departed
## player's hysteresis/forcing state is dropped. Never called on clients (the referee stays inert).
func activate(players: Node2D, monsters: Node2D, move_referee: Node) -> void:
	_players = players
	_monsters = monsters
	_move_referee = move_referee
	_monsters.child_exiting_tree.connect(_on_monster_exiting)
	_players.child_exiting_tree.connect(_on_player_exiting)


## THE resolver — the read every stamp site uses. Returns the beat (seconds) this entity's NEXT
## committed window stamps from. Host-only (stamp sites never run on clients). It is ALSO the
## hysteresis writer: any resolve that lands tactical for a player stamps _last_qualified as a side
## effect, so a later poll/timer verdict reads the same truth (see _last_qualified).
func beat_sec_for(entity_id: int) -> float:
	# Monsters (negative id): tactical iff engaged (aggroed — always inside their own bubble). No
	# engagement entry = idle / brainless = explore. Monsters have no hysteresis or forcing window.
	if entity_id < 0:
		return GameManager.tactical_beat_sec if _engagements.has(entity_id) else GameManager.explore_beat_sec
	# Players (positive id). A live tactical qualification stamps the hysteresis clock and returns
	# tactical NOW.
	if _player_qualifies_tactical(entity_id):
		_last_qualified[entity_id] = Time.get_ticks_msec()
		return GameManager.tactical_beat_sec
	# Not currently qualifying. Hysteresis: hold tactical until tactical_exit_sec has elapsed since the
	# last qualify, so a player skimming a bubble edge doesn't flicker. No _last_qualified entry means
	# never qualified — explore immediately, zero exit delay (fresh spawns / late joiners).
	if _last_qualified.has(entity_id):
		var elapsed_ms := Time.get_ticks_msec() - int(_last_qualified[entity_id])
		if elapsed_ms < int(GameManager.config.tactical_exit_sec * 1000.0):
			return GameManager.tactical_beat_sec
	return GameManager.explore_beat_sec


## Called by each MonsterBrain every think (injected ref — the brain never reaches up). Records this
## monster's aggro + current chase target so the resolver can project its bubble and honour the leash.
## aggroed false erases the entry (an idle / leash-dropped monster projects nothing). target_id is the
## player the monster is chasing (0 when none) — the leash key.
func report_engagement(monster_id: int, aggroed: bool, target_id: int) -> void:
	if aggroed:
		_engagements[monster_id] = target_id
	else:
		_engagements.erase(monster_id)


## Called by CombatReferee / MoveReferee when a PLAYER lands a hostile action (its bump), BEFORE that
## attack's own window is stamped — so the triggering attack is itself a tactical-pace action (no fast
## first swing) AND the player stays tactical for a beat afterward (anti-cheese: hitting the dummy
## counts, the rule is uniform). Arms a wall-clock deadline of tactical_force_beats × tactical_beat_sec
## seconds from now. Host-only.
func report_hostile_action(player_id: int) -> void:
	var window_ms := int(GameManager.config.tactical_force_beats * GameManager.tactical_beat_sec * 1000.0)
	_force_until[player_id] = Time.get_ticks_msec() + window_ms


# ── Private methods ───────────────────────────────────────────────────────────

## Does this player qualify for tactical RIGHT NOW (bubble ∨ leash ∨ forcing window)? Pure read of
## live engagement + forcing state + authoritative tiles — the hysteresis is applied by the caller.
func _player_qualifies_tactical(player_id: int) -> bool:
	# Forcing window (anti-cheese) — a recent hostile action keeps the actor tactical regardless of
	# proximity, so a player can't tap-and-flee to cheese explore pace between swings.
	if _force_until.has(player_id) and Time.get_ticks_msec() < int(_force_until[player_id]):
		return true
	# Leash (Jon's pick, DESIGN §2.8.7 revisit note): a player being chased by any aggroed monster
	# stays tactical however far they run — chase parity, chaser and target share the tactical beat.
	for monster_id in _engagements:
		if int(_engagements[monster_id]) == player_id:
			return true
	# Bubble: within an aggroed monster's tactical_radius_tiles (Chebyshev). Idle / brainless monsters
	# never appear in _engagements, so the dummy never slows anyone; a monster authored radius 0
	# projects no bubble (its aggro is still the real guard via the leash above).
	var player_tile := _tile_of(player_id)
	if player_tile == _NO_TILE:
		return false
	for monster_id in _engagements:
		var radius := _radius_of(monster_id)
		if radius <= 0:
			continue
		var monster_tile := _tile_of(monster_id)
		if monster_tile == _NO_TILE:
			continue
		if maxi(absi(player_tile.x - monster_tile.x), absi(player_tile.y - monster_tile.y)) <= radius:
			return true
	return false


## Authoritative tile for an entity (player or monster), read from the MoveReferee's occupancy — NEVER
## a rendered node position (§2.5). _NO_TILE when untracked / off-host.
func _tile_of(entity_id: int) -> Vector2i:
	if _move_referee == null:
		return _NO_TILE
	return _move_referee.tile_of_entity(entity_id)


## This monster's authored tactical bubble radius (Chebyshev tiles), or 0 (no bubble) for a missing /
## brainless type. Resolved from the authored MonsterType on the node — the same per-peer authored
## value everywhere (the wire carries the type PATH, never pixels).
func _radius_of(monster_id: int) -> int:
	if _monsters == null:
		return 0
	var node := _monsters.get_node_or_null(str(monster_id))
	if node is Monster and node.monster_type != null:
		return node.monster_type.tactical_radius_tiles
	return 0


## Forget a monster's engagement the instant its node leaves (despawn / death / teardown), so no stale
## bubble or leash outlives the monster. Same container-exit pattern as CombatReferee's HP erase;
## idempotent with a prior report_engagement(false).
func _on_monster_exiting(node: Node) -> void:
	if node is Entity:
		_engagements.erase(node.entity_id)


## Forget a departed player's hysteresis + forcing state as its node leaves (disconnect / despawn /
## teardown), so a stale timestamp can't linger and a rejoin starts clean (explore immediately).
func _on_player_exiting(node: Node) -> void:
	if node is Entity:
		_force_until.erase(node.entity_id)
		_last_qualified.erase(node.entity_id)
