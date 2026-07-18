extends Node

## The HOST-ONLY combat authority (DESIGN §2.3, §2.5.3). It owns entity HIT POINTS and is the single
## place damage is applied and death is resolved — deterministic (no to-hit roll; DESIGN §2.3
## amendment, RF3 numbers). It sits beside MoveReferee and, like it, is inert on clients: the node
## exists on every peer (it's in main.tscn) but activate() is called only inside main.gd's
## is_server() branch, so a client's combat referee never seeds HP or adjudicates anything.
##
## Component pattern (CLAUDE.md): Main hands it the Players + Monsters containers AND the MoveReferee
## reference via activate(), BEFORE any spawn — so its container enter hooks seed HP for every entity
## and the two referees can call each other ONLY through the references Main wired. It never reaches
## up to Main.
##
## Who drives it:
##  - BUMP — MoveReferee's _validate_glide resolves an idle move into a hostile tile into a bump and
##    calls apply_damage(kind "bump"); MoveReferee also owns the attacker's busy record.
##  - AoO  — MoveReferee's attack-of-opportunity scan calls apply_damage(kind "free").
##  - WIND-UP — a MonsterBrain requests wind_up(); this referee validates it, records the monster's
##    busy commit on MoveReferee, posts the `windup` telegraph, and resolves it against the target
##    TILE windup_sec later (DESIGN §2.1 "slow telegraph, hard commit" — a distinct WHIFF outcome
##    survives deterministic damage).
##
## Every landed hit posts an `attack` event and every death a `died` event on the SAME NetEvents
## pipe (host-authored, peer=attacker/0), so all peers play back feedback and HP readouts from the
## one ordered stream — no per-frame streaming, no query API (max_hp is locally known; hp_after and
## target_max ride the events).

# Sentinel for "no entity on this tile" from _entity_at / MoveReferee.entity_at. 0 is never a real
# entity id (peer ids are > 0, monster ids < 0).
const _NO_ENTITY := 0

# Wind-up fallback (seconds) for a non-monster / missing-type node in _windup_duration_of. Mirrors
# MonsterType.windup_sec's own default so the accessor stays total without inventing a new number.
const _FALLBACK_WINDUP_SEC := 0.8

# Authoritative HIT POINTS: entity id -> current HP. THE combat truth; a node's nameplate is only
# presentation. Seeded from each entity's authored max as it enters its container (players from the
# Player.max_hp export, monsters from MonsterType.max_hp) and erased on exit. Entity id is a peer id
# (> 0) for a player or a host-assigned negative int for a monster — the same id space MoveReferee uses.
var _hp: Dictionary = {}

# The Players / Monsters containers, handed in by Main via activate() on the HOST only. Read for
# node resolution + HP seeding; never reached up from. Null on clients (activate never runs there).
var _players: Node2D = null
var _monsters: Node2D = null
# The MoveReferee, handed in by Main via activate(). Combat needs it to erase a dead entity's
# occupancy synchronously (clear_entity), read the tile a wind-up resolves against (entity_at), and
# gate a wind-up on the attacker not already being busy (is_entity_moving). Untyped (its script has
# no class_name) so its calls resolve dynamically — callers type locals off it explicitly.
var _move_referee = null


## Host-only entry point, called by Main inside its is_server() branch AFTER MoveReferee.activate()
## and set_monsters() and BEFORE any spawn — so the container enter hooks seed HP for every entity,
## including the host's own player. Wires both containers' membership signals the same way MoveReferee
## does. Never called on clients (their combat referee stays inert).
func activate(players: Node2D, monsters: Node2D, move_referee: Node) -> void:
	_players = players
	_monsters = monsters
	_move_referee = move_referee
	_players.child_entered_tree.connect(_on_entity_entered)
	_players.child_exiting_tree.connect(_on_entity_exiting)
	_monsters.child_entered_tree.connect(_on_entity_entered)
	_monsters.child_exiting_tree.connect(_on_entity_exiting)


# ── Public methods ────────────────────────────────────────────────────────────

## Is this entity alive (tracked with HP > 0)? The single liveness predicate — the referees gate
## every attack (attacker able, target alive) on it, and death erases the key so a dead entity is
## never a valid attacker OR target. An untracked id (never seeded / already dead) reads not-alive.
func is_alive(entity_id: int) -> bool:
	return _hp.has(entity_id) and int(_hp[entity_id]) > 0


## Apply deterministic melee damage from attacker to target and broadcast the outcome. Host-only.
## Returns whether the target DIED (so MoveReferee's AoO scan can abort a glide whose mover it just
## killed — decision 4). `kind` is bump|free|windup (the flavor for feedback + the combat log).
## `duration_sec` rides the event for the bump kind only (the local attacker's swing-busy window,
## decision 2); free/windup pass 0. The event carries target_max so every peer renders "hp/max"
## with no query. On a lethal hit, death is resolved SYNCHRONOUSLY here (decision 7) — no frame
## window where a stale record blocks another mover.
func apply_damage(attacker_id: int, target_id: int, amount: int, kind: String, duration_sec: float = 0.0) -> bool:
	# Defensive: a caller should have gated on is_alive, but never damage a dead/untracked target
	# (it would post a spurious event and could double-resolve death).
	if not is_alive(target_id):
		return false
	var attacker := _node_of_id(attacker_id)
	var target := _node_of_id(target_id)
	var new_hp: int = maxi(0, int(_hp[target_id]) - amount)
	_hp[target_id] = new_hp
	var target_name := _name_of(target)
	# Author the hit on the shared pipe (as_peer = attacker, positive for a player or negative for a
	# monster — negative ids are fine on the wire). Posted BEFORE any `died` so hp_after 0 lands first.
	NetEvents.post_event("attack", {
		"attacker_id": attacker_id,
		"attacker_name": _name_of(attacker),
		"target_id": target_id,
		"target_name": target_name,
		"damage": amount,
		"hp_after": new_hp,
		"target_max": _max_hp_of(target),
		"kind": kind,
		"whiff": false,
		"duration_sec": duration_sec,
	}, attacker_id)
	if new_hp <= 0:
		_kill_entity(target_id, target_name)
		return true
	return false


## A MonsterBrain requests a telegraphed wind-up against a target TILE (decision 3). Host-only.
## Validates (attacker alive + not already busy per MoveReferee), records the monster's from==to
## busy commit through MoveReferee's shared commit_in_place, posts the `windup` telegraph, and arms
## a SceneTreeTimer that resolves against the tile windup_sec later. Returns the wind-up duration on
## success (the brain schedules its own re-think just past it), or 0.0 if declined (brain re-thinks
## on the normal cadence). The duration is the authored MonsterType.windup_sec unless the debug
## windupsec= override is set (read LIVE, the exact mirror of the glide override).
func wind_up(attacker_id: int, target_tile: Vector2i) -> float:
	if not is_alive(attacker_id):
		return 0.0
	# The attacker must be free to act — never overlap a wind-up with a glide/another commit. The
	# busy record is the Commitment Rule backstop, owned by MoveReferee.
	if _move_referee.is_entity_moving(attacker_id):
		return 0.0
	var attacker := _node_of_id(attacker_id)
	var windup_sec := _windup_duration_of(attacker)
	if GameManager.debug_windup_override_sec > 0.0:
		windup_sec = GameManager.debug_windup_override_sec
	# Record the busy commit through the ONE shared path (bump uses it too), so the from==to busy
	# logic lives in exactly one place. A miss here means the attacker went busy between the checks
	# above and now — decline cleanly.
	var committed: bool = _move_referee.commit_in_place(attacker_id, windup_sec)
	if not committed:
		return 0.0
	NetEvents.post_event("windup", {
		"entity_id": attacker_id,
		"name": _name_of(attacker),
		"target_tile": target_tile,
		"windup_sec": windup_sec,
	}, attacker_id)
	# SceneTreeTimer on the host tree (never a Timer child of the monster — survives despawn by
	# construction, the same mechanism MoveReferee's completion timers use).
	get_tree().create_timer(windup_sec).timeout.connect(_resolve_windup.bind(attacker_id, target_tile))
	return windup_sec


## Host-side stat accessors, read by MoveReferee for a bump/AoO so combat numbers live in ONE place
## (this referee). Damage is per-entity (player melee_damage / monster attack_damage); the bump's
## swing duration is the player's attack_duration_sec. Duck-typed across the two entity kinds; an
## unknown node reads harmless defaults. DELIBERATELY not collapsed to one Entity read: Player's
## export keeps its tuned name melee_damage (pinned in player.tscn), so the two stats keep their
## own names and this accessor stays the one translation point.
func damage_of(node: Node) -> int:
	if node is Player:
		return node.melee_damage
	if node is Monster and node.monster_type != null:
		return node.monster_type.attack_damage
	return 0


func bump_duration_of(node: Node) -> float:
	if node is Player:
		return node.attack_duration_sec
	# M3 monsters never bump (they attack via wind-up), but keep the accessor total: fall back to
	# the monster's wind-up time so a future monster bump has a sane commit tail.
	return _windup_duration_of(node)


# ── Private methods ───────────────────────────────────────────────────────────

## Resolve a wind-up against its committed TILE (decision 3). The attacker must still be alive — a
## mid-wind-up kill deals nothing (that is the distinct outcome a slow telegraph buys). Damage hits
## whatever hostile-to-the-attacker LIVING entity occupies the tile NOW (read from MoveReferee's
## authoritative occupancy): a target that glided off whiffs; a different hostile that stepped onto
## the telegraphed tile eats it (the telegraph commits to ground, not a name). No occupant / no
## hostile / dead occupant → a WHIFF `attack` event (whiff true, no damage).
func _resolve_windup(attacker_id: int, target_tile: Vector2i) -> void:
	if not is_alive(attacker_id):
		return
	var attacker := _node_of_id(attacker_id)
	var occ_id: int = _move_referee.entity_at(target_tile)
	if occ_id != _NO_ENTITY:
		var occ := _node_of_id(occ_id)
		if occ != null and is_alive(occ_id) and attacker != null and attacker.is_hostile_to(occ):
			apply_damage(attacker_id, occ_id, damage_of(attacker), "windup", 0.0)
			return
	# Whiff: swing into empty/vacated ground. Distinct outcome — no damage, hp_after -1 (absent),
	# target_tile carried so the client renders the swing toward the committed tile.
	NetEvents.post_event("attack", {
		"attacker_id": attacker_id,
		"attacker_name": _name_of(attacker),
		"target_id": _NO_ENTITY,
		"target_name": "",
		"target_tile": target_tile,
		"damage": 0,
		"hp_after": -1,
		"target_max": 0,
		"kind": "windup",
		"whiff": true,
		"duration_sec": 0.0,
	}, attacker_id)


## Resolve a lethal hit SYNCHRONOUSLY (decision 7, Q1 placeholder). Erase HP, then erase the dead
## entity's MoveReferee state (occupancy / glide / pending) through the shared clear_entity — no
## frame window where a stale record blocks another mover — then post `died`, then queue_free the
## node. The spawner replicates the despawn to every peer; MoveReferee's own exit hook still fires
## later and is idempotent (erasing already-erased keys is a no-op). `died` is server-authored
## (peer 0) — no attacker attribution; the preceding `attack` event carried that.
func _kill_entity(entity_id: int, ent_name: String) -> void:
	_hp.erase(entity_id)
	_move_referee.clear_entity(entity_id)
	NetEvents.post_event("died", { "entity_id": entity_id, "name": ent_name })
	var node := _node_of_id(entity_id)
	if node != null:
		node.queue_free()


## Seed HP as an Entity enters its container (players + monsters share this hook, branch-free).
## entity_id and max_hp are BOTH set by Main's spawn_function BEFORE the node enters the tree
## (players: max_hp is a scene export, entity_id assigned pre-tree; monsters: both assigned
## pre-tree alongside monster_type), so this reads authored server-side values here on the host —
## this hook fires pre-_ready, so it must never rely on a _ready-time field. A monster spawned
## with no MonsterType carries max_hp 0 and thus is never alive (its _ready warning fires).
func _on_entity_entered(node: Node) -> void:
	if node is Entity:
		_hp[node.entity_id] = node.max_hp


## Forget an entity's HP as its node leaves (disconnect / despawn / teardown). Idempotent with the
## synchronous death erase above — a natural despawn just clears whatever remains.
func _on_entity_exiting(node: Node) -> void:
	if node is Entity:
		_hp.erase(node.entity_id)


## The id -> node resolver over this referee's own containers (mirror of MoveReferee's). Positive is
## a player, negative a monster; null if absent. Entity-typed: everything this referee reads off a
## resolved node (display_name, max_hp, is_hostile_to, the play_* cues via events) is Entity surface.
func _node_of_id(entity_id: int) -> Entity:
	if entity_id > 0:
		return _players.get_node_or_null(str(entity_id)) as Entity
	if _monsters != null:
		return _monsters.get_node_or_null(str(entity_id)) as Entity
	return null


## The one name surface per entity, read host-side for events/log (never trusted from the wire):
## Entity.display_name (Player sets it from player_name, Monster from its type, both at _ready —
## safe here: _name_of is only called at attack/death time, long after _ready). Missing node → "?".
func _name_of(node: Node) -> String:
	if node is Entity:
		return node.display_name
	return "?"


## The authored maximum HP for an entity's node, carried in each attack event so peers render
## "hp/max". Uniform Entity surface: Player's is a scene export; Monster's is mirrored from its
## type pre-tree by Main's spawn_function.
func _max_hp_of(node: Node) -> int:
	if node is Entity:
		return node.max_hp
	return 0


## The wind-up telegraph duration for a node (seconds), from its MonsterType. A non-monster / missing
## type falls back to a sane default so the accessor is total.
func _windup_duration_of(node: Node) -> float:
	if node is Monster and node.monster_type != null:
		return node.monster_type.windup_sec
	return _FALLBACK_WINDUP_SEC
