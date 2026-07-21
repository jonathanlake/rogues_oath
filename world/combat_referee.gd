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
##  - ATTACK — a MonsterBrain requests wind_up(); this referee validates it and, on the goblin's
##    windup_beats==0 dial, resolves an INSTANT deterministic strike then holds a recovery busy
##    (DESIGN §2.8); on a >0 dial it records the busy commit, posts the `windup` telegraph, and
##    resolves against the target TILE later (DESIGN §2.1 "slow telegraph, hard commit" — a distinct
##    WHIFF outcome survives, the machinery preserved behind the dial).
##
## Every landed hit posts an `attack` event and every death a `died` event on the SAME NetEvents
## pipe (host-authored, peer=attacker/0), so all peers play back feedback and HP readouts from the
## one ordered stream — no per-frame streaming, no query API (max_hp is locally known; hp_after and
## target_max ride the events).

# Sentinel for "no entity on this tile" from _entity_at / MoveReferee.entity_at. 0 is never a real
# entity id (peer ids are > 0, monster ids < 0).
const _NO_ENTITY := 0

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
# The PaceReferee, handed in by Main via activate() (Tactical Zones v1, §2.8.7). Combat stamps each
# attack's telegraph + recovery window at the ATTACKER's resolved pace through it (beat_sec_for), so an
# engaged goblin's windup/recovery run at the tactical beat and an out-of-fight attacker's at explore.
# Combat also ARMS it for a PLAYER attacker's forcing window at the two damage chokepoints (apply_damage,
# wind_up) so an AoO / future windup weapon counts as a hostile action just like a bump. Held untyped (its
# instance calls resolve dynamically); the null-resolver fallback lives in PaceReferee.beat_or_explore.
# Null on clients (activate never runs there).
var _pace = null


## Host-only entry point, called by Main inside its is_server() branch AFTER MoveReferee.activate()
## and set_monsters() and the PaceReferee, and BEFORE any spawn — so the container enter hooks seed HP
## for every entity, including the host's own player, and the pace resolver is on hand the first time an
## attack window is stamped. Wires both containers' membership signals the same way MoveReferee does.
## Never called on clients (their combat referee stays inert).
func activate(players: Node2D, monsters: Node2D, move_referee: Node, pace: Node) -> void:
	_players = players
	_monsters = monsters
	_move_referee = move_referee
	_pace = pace
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
	# Forcing-window arming, uniform catch-all (Tactical Zones v1, §2.8.7, review #6). A PLAYER attacker
	# (positive id) landing ANY damage — an AoO free strike (attacks_of_opportunity_enabled), a future
	# windup weapon's hit, or a bump — counts as a hostile action, so it can't be dodged out of tactical.
	# Two-site split with MoveReferee._begin_bump: the bump arms EARLY (before its own window is stamped)
	# purely for stamp ORDERING (no fast first swing); apply_damage / wind_up are the UNIFORM catch-alls
	# that guarantee every player-dealt hostile action arms regardless of path. Re-arming on the bump path
	# is idempotent-by-design — each hostile action refreshes the same wall-clock deadline.
	if _pace != null and attacker_id > 0:
		_pace.report_hostile_action(attacker_id)
	var attacker := _node_of_id(attacker_id)
	var target := _node_of_id(target_id)
	var new_hp: int = maxi(0, int(_hp[target_id]) - amount)
	_hp[target_id] = new_hp
	var target_name := _name_of(target)
	# Author the hit on the shared pipe (as_peer = attacker, positive for a player or negative for a
	# monster — negative ids are fine on the wire). Posted BEFORE any `died` so hp_after 0 lands first.
	var attack_data := {
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
	}
	# Weapon stamp (v0.9.3): ANY Entity attacker with an equipped weapon stamps its `weapon` id so
	# every peer animates the right rig (the guard is field-presence + non-empty in playback). A
	# weaponless attacker (a bare-handed player, the training dummy) stamps no field — its cues stay.
	if attacker is Entity and attacker.equipped_weapon != null:
		attack_data["weapon"] = attacker.equipped_weapon.display_name
	NetEvents.post_event("attack", attack_data, attacker_id)
	if new_hp <= 0:
		_kill_entity(target_id, target_name)
		return true
	return false


## A MonsterBrain requests an attack against a target TILE (decision 3; DESIGN §2.8). Host-only.
## Two shapes on the ONE windup_beats dial:
##  - windup_beats == 0 (the goblin): an INSTANT deterministic strike resolved against the target
##    tile NOW (no telegraph event, no whiff-window timer), then the attacker is BUSY for
##    recovery_beats — the symmetric "instant strike + N-beat recovery" the milestone lands.
##  - windup_beats > 0 (or the windupsec= debug override): the full telegraphed wind-up, UNCHANGED
##    — busy for the telegraph, post the `windup` event, resolve against the tile windup_sec later
##    (the distinct WHIFF outcome survives, DESIGN §2.1). recovery is then brain pacing on top.
## Both stamp seconds from the attacker's RESOLVED pace (PaceReferee, §2.8.7). Returns the total seconds
## the brain should wait before its next think (the committed busy plus any post-telegraph recovery)
## on success, or -1.0 if DECLINED (attacker not alive / already busy) so the brain distinguishes a
## real attack from a back-off. Validates attacker alive + not already busy per MoveReferee first.
func wind_up(attacker_id: int, target_tile: Vector2i) -> float:
	if not is_alive(attacker_id):
		return -1.0
	# The attacker must be free to act — never overlap an attack with a glide/another commit. The
	# busy record is the Commitment Rule backstop, owned by MoveReferee.
	if _move_referee.is_entity_moving(attacker_id):
		return -1.0
	# Forcing-window arming for a PLAYER windup attacker (§2.8.7, review #6), BEFORE this path's stamps
	# so a future player windup weapon telegraphs at the tactical beat (no fast first swing) and stays
	# tactical for a beat after. Monsters (negative id) never need arming (aggro already makes them
	# tactical). No player calls wind_up in M3 — this is the uniform catch-all for when they do; the
	# gate on attacker_id > 0 keeps it inert for the monster path that exists today.
	if _pace != null and attacker_id > 0:
		_pace.report_hostile_action(attacker_id)
	var attacker := _node_of_id(attacker_id)
	var windup_sec := _windup_duration_of(attacker)
	if GameManager.debug_windup_override_sec > 0.0:
		windup_sec = GameManager.debug_windup_override_sec
	var recovery_sec := _recovery_duration_of(attacker)

	# Instant-strike path (windup dial at 0). Commit the recovery busy FIRST (the Commitment Rule
	# tail — the strike plays out its recovery, no cancel path), then resolve immediately against the
	# target tile: apply_damage / whiff carries recovery_sec so every peer shows the recovery tell for
	# it. No telegraph event and no timer — the strike is deterministic and lands in this same stack,
	# so a target cannot dodge it (that dodge window was the failed windup experiment). A commit_in_place
	# miss means the attacker went busy between the checks above and now — decline cleanly.
	if windup_sec <= 0.0:
		if not _move_referee.commit_in_place(attacker_id, recovery_sec):
			return -1.0
		_resolve_windup(attacker_id, target_tile, "strike", recovery_sec)
		return recovery_sec

	# Telegraphed wind-up path (dial > 0) — unchanged. Record the busy commit through the ONE shared
	# path (bump uses it too), so the from==to busy logic lives in exactly one place.
	if not _move_referee.commit_in_place(attacker_id, windup_sec):
		return -1.0
	NetEvents.post_event("windup", {
		"entity_id": attacker_id,
		"name": _name_of(attacker),
		"target_tile": target_tile,
		"windup_sec": windup_sec,
	}, attacker_id)
	# SceneTreeTimer on the host tree (never a Timer child of the monster — survives despawn by
	# construction, the same mechanism MoveReferee's completion timers use). recovery on this path is
	# brain pacing (added to the return), NOT a referee record — the telegraph WAS the busy window.
	get_tree().create_timer(windup_sec).timeout.connect(
			_resolve_windup.bind(attacker_id, target_tile, "windup", 0.0))
	return windup_sec + recovery_sec


## Host-side stat accessors, read by MoveReferee for a bump/AoO so combat numbers live in ONE place
## (this referee). Damage is per-entity (player melee_damage / monster attack_damage); the bump's
## recovery tail is the attacker's recovery beats. Duck-typed across the two entity kinds; an
## unknown node reads harmless defaults. DELIBERATELY not collapsed to one Entity read: Player's
## export keeps its tuned name melee_damage (pinned in player.tscn), so the two stats keep their
## own names and this accessor stays the one translation point.
func damage_of(node: Node) -> int:
	# Weapon-first (v0.9.3): ANY Entity's equipped_weapon.damage wins for both kinds; the per-kind
	# legacy field is the null-weapon fallback, then a hard 0. Explicit order: weapon → legacy → DEFAULT.
	if node is Entity and node.equipped_weapon != null:
		return node.equipped_weapon.damage
	if node is Player:
		return node.melee_damage
	if node is Monster and node.monster_type != null:
		return node.monster_type.attack_damage
	return 0


## The bump's busy tail (seconds): the attacker's recovery beats stamped at the live beat — instant
## strike + N-beat recovery (DESIGN §2.8). Delegates to _recovery_duration_of so player and monster
## bumps share the one beats→seconds conversion (a monster never bumps in M3, but the accessor stays
## total for a future monster bumper).
func bump_duration_of(node: Node) -> float:
	return _recovery_duration_of(node)


# ── Private methods ───────────────────────────────────────────────────────────

## Resolve an attack against its committed TILE. Shared by both shapes (decision 3; DESIGN §2.8):
## the telegraphed wind-up (armed on a timer; recovery_sec 0 — recovery is brain pacing there, so
## the landed hit carries no recovery tell, and the coil already told) AND the instant strike
## (called synchronously from wind_up with the recovery seconds, so the strike's `attack`/whiff
## event carries the recovery duration and every peer plays the recovery tell for it). `kind` is
## passed EXPLICITLY by the caller — "windup" for the telegraphed path (log/feedback unchanged),
## "strike" for the instant path — never inferred from recovery_sec, whose sign says nothing about
## which path fired (a zero-recovery instant strike is still a strike).
## The attacker must still be alive — a mid-wind-up kill deals nothing (the distinct outcome a slow
## telegraph buys; on the instant path the same-stack liveness makes this always true). Damage hits
## whatever hostile-to-the-attacker LIVING entity occupies the tile NOW (MoveReferee's authoritative
## occupancy): a target that glided off whiffs; a different hostile that stepped onto the tile eats
## it (the attack commits to ground, not a name). No occupant / no hostile / dead → a WHIFF event.
func _resolve_windup(attacker_id: int, target_tile: Vector2i, kind: String, recovery_sec: float) -> void:
	if not is_alive(attacker_id):
		return
	var attacker := _node_of_id(attacker_id)
	var occ_id: int = _move_referee.entity_at(target_tile)
	if occ_id != _NO_ENTITY:
		var occ := _node_of_id(occ_id)
		if occ != null and is_alive(occ_id) and attacker != null and attacker.is_hostile_to(occ):
			apply_damage(attacker_id, occ_id, damage_of(attacker), kind, recovery_sec)
			return
	# Whiff: swing into empty/vacated ground. Distinct outcome — no damage, hp_after -1 (absent),
	# target_tile carried so the client renders the swing toward the committed tile. recovery_sec
	# still rides so the instant-strike attacker shows its recovery tell even on a (rare) whiff.
	var whiff_data := {
		"attacker_id": attacker_id,
		"attacker_name": _name_of(attacker),
		"target_id": _NO_ENTITY,
		"target_name": "",
		"target_tile": target_tile,
		"damage": 0,
		"hp_after": -1,
		"target_max": 0,
		"kind": kind,
		"whiff": true,
		"duration_sec": recovery_sec,
	}
	# Weapon stamp on the WHIFF too (v0.9.3): a whiffed weapon swing still animates the rig arc, so a
	# missed strike plays the weapon (it composes with the monster's whiff bowstring, exactly as a
	# landed hit's swing composes with play_attack). A weaponless attacker stamps no field.
	if attacker is Entity and attacker.equipped_weapon != null:
		whiff_data["weapon"] = attacker.equipped_weapon.display_name
	NetEvents.post_event("attack", whiff_data, attacker_id)


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


## The wind-up telegraph duration for a node (seconds) — its MonsterType.windup_beats stamped at the
## ATTACKER's resolved pace (PaceReferee, §2.8.7: an engaged monster telegraphs at the tactical beat). A
## non-monster / missing type falls back to MonsterType.DEFAULT_WINDUP_BEATS — the value's single
## authoring site — so the accessor is total without a shadow copy of the number here.
func _windup_duration_of(node: Node) -> float:
	# Weapon-first (v0.9.3): ANY Entity's equipped_weapon.windup_beats wins (the goblin's 0 lives on
	# its claw now). Else the per-type monster windup, else DEFAULT_WINDUP_BEATS (the single authoring
	# site for the telegraph default). Order: weapon → per-kind legacy → DEFAULT.
	if node is Entity and node.equipped_weapon != null:
		return node.equipped_weapon.windup_beats * _pace_beat_sec(node)
	var beats := MonsterType.DEFAULT_WINDUP_BEATS
	if node is Monster and node.monster_type != null:
		beats = node.monster_type.windup_beats
	return beats * _pace_beat_sec(node)


## The attacker node's resolved beat (seconds) at stamp time — tactical or explore per PaceReferee
## (§2.8.7), keyed by the node's entity_id. Keeps the `node is Entity` guard HERE (combat's duration
## accessors take the resolved attacker node, not an id) and delegates the null-resolver → explore
## fallback to the shared PaceReferee.beat_or_explore policy site; a non-Entity node reads explore.
func _pace_beat_sec(node: Node) -> float:
	if node is Entity:
		return PaceReferee.beat_or_explore(_pace, node.entity_id)
	return GameManager.explore_beat_sec


## The attacker's recovery tail (seconds) — its authored recovery beats stamped at the ATTACKER's
## resolved pace (PaceReferee, §2.8.7: an engaged attacker recovers at the tactical beat; a player's bump
## tail stamps tactical because _begin_bump armed the forcing window first). Player: attack_recovery_beats;
## monster: recovery_beats. The one conversion for a bump tail (bump_duration_of) and an instant strike's
## busy (wind_up). Unknown / missing-type node reads 0 (no recovery).
func _recovery_duration_of(node: Node) -> float:
	# Weapon-first (v0.9.3): ANY Entity's equipped_weapon.attack_beats IS its whole occupied window
	# (no separate cooldown, Part 4 Q9). Order: weapon → per-kind legacy recovery field → hard 0.
	if node is Entity and node.equipped_weapon != null:
		return node.equipped_weapon.attack_beats * _pace_beat_sec(node)
	if node is Player:
		return node.attack_recovery_beats * _pace_beat_sec(node)
	if node is Monster and node.monster_type != null:
		return node.monster_type.recovery_beats * _pace_beat_sec(node)
	return 0.0
