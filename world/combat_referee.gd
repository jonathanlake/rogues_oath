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

# GOD MODE (v0.10.0 dev command): entity id -> true for every entity the /god command has made
# invulnerable. Host-only authority (this referee is inert on clients — the toggle rides the dev_command
# validator, which only runs host-side), so a client can never grant itself invulnerability. Checked in
# apply_damage's single chokepoint (covers bump / AoO / windup uniformly) — a godded target takes the hit
# as a visible NO-OP (damage 0, a "godded" flag on the event) rather than a silent block (§2.3.4). Erased
# with the entity's HP on container exit (disconnect / despawn / F5 reset), so a fresh spawn is mortal.
var _godded: Dictionary = {}

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

# Monotonic per-shot projectile id (v0.17.0), host-only. Stamped into each projectile_launched /
# projectile_ended pair so multiple arrows in flight stay id-keyed and independent. Never reset mid-session.
var _next_projectile_id: int = 1
# In-flight arrows: projectile id -> { shooter_id, damage, path, clipped, index, tile_duration }. THE
# authoritative flight state, host-only — captured PRIMITIVES at loose (never node refs), advanced one tile
# per arrival timer, erased the instant the arrow ends (hit / blocked / spent). Empty on clients.
var _projectiles: Dictionary = {}

# Round generation (v0.17.1 review #4), host-only. Bumped by reset_round() on every F5 dev round-reset.
# Captured into each pending _loose_arrow bind at accept and re-checked when the draw timer fires, so a
# draw in flight when the round resets looses NOTHING into the fresh round — a same-peer respawn reuses
# the peer id and thus passes the is_alive guard, but its generation no longer matches. Same idiom as
# _next_monster_id's never-reset negative ids: identity that a stale timer can never match post-reset.
var _round_gen: int = 0


## Host-only entry point, called by Main inside its is_server() branch AFTER MoveReferee.activate()
## and set_monsters() and the PaceReferee, and BEFORE any spawn — so the container enter hooks seed HP
## for every entity, including the host's own player, and the pace resolver is on hand the first time an
## attack window is stamped. Wires both containers' membership signals the same way MoveReferee does.
## Registers the "shoot" intent validator on the shared pipe (the way MoveReferee registers "glide_to").
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
	NetEvents.register_handler("shoot", _validate_shoot)
	# Misconfiguration guard (v0.17.1 review #2), host-only: warn ONCE at session start if any roster weapon
	# (global or per-class) is missing from weapon_catalog — such a weapon resolves to null on peers and
	# desyncs a swap/equip SILENTLY at runtime. Runs here (not _ready) because activate is host-only and fires
	# after GameManager.config is loaded, so the catalog/rosters are guaranteed present and authoritative.
	GameManager.config.validate_catalog_covers_rosters()
	# Sibling guard (v0.18.0): warn on duplicate display_names within weapon_catalog / item_catalog — a
	# first-hit-resolution dupe silently shadows the later entry. Same host-only, once-at-startup contract.
	GameManager.config.validate_catalogs()


# ── Public methods ────────────────────────────────────────────────────────────

## Is this entity alive (tracked with HP > 0)? The single liveness predicate — the referees gate
## every attack (attacker able, target alive) on it, and death erases the key so a dead entity is
## never a valid attacker OR target. An untracked id (never seeded / already dead) reads not-alive.
func is_alive(entity_id: int) -> bool:
	return _hp.has(entity_id) and int(_hp[entity_id]) > 0


## Is this entity currently invulnerable (the /god dev command toggled it on)? Host-only truth beside
## is_alive; apply_damage reads it at the single damage chokepoint. An untracked id (never godded /
## already erased) reads false. Never trusted from the wire — only the host's dev_command validator writes it.
func is_godded(entity_id: int) -> bool:
	return _godded.get(entity_id, false)


## Toggle an entity's invulnerability and return the NEW state (v0.10.0). Host-only — called by the
## /god dev command validator (main.gd), which composes the log line from the returned state. Erasing
## (rather than storing false) keeps the dict to just the godded ids, so the container-exit cleanup is a
## plain erase and an untracked id reads mortal.
func toggle_godded(entity_id: int) -> bool:
	if _godded.get(entity_id, false):
		_godded.erase(entity_id)
		return false
	_godded[entity_id] = true
	return true


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
	# Defense-in-depth (v0.10.1 review fix 1): floor the incoming amount at 0 before any HP math. This
	# pipe is DAMAGE-ONLY (§2.4 heals will be their own path); the maxi(0, hp - amount) floor below has
	# NO ceiling, so a negative amount would otherwise heal a target above its max. The dev-command range
	# clamps are the first line; this is the last, covering any future caller that computes a negative.
	amount = maxi(0, amount)
	var attacker := _node_of_id(attacker_id)
	var target := _node_of_id(target_id)
	# GOD MODE (v0.10.0): a godded target takes the hit as a visible NO-OP — post the attack event with
	# damage 0, hp_after UNCHANGED, and a "godded" flag (the feedback rule forbids a silent block, §2.3.4:
	# main.gd renders a grey "0" popup + the "no effect (god)" line — and SKIPS the hurt cues), then SKIP
	# the HP mutation and _kill_entity and return false (not dead). One chokepoint covers bump / AoO /
	# windup uniformly. The attacker's own commitment (its committed busy window, stamped BEFORE
	# apply_damage) stands — this only cancels the DAMAGE, never an in-flight action (Commitment Rule
	# intact). Placed before the forcing-window arming so a no-op hit on a godded target doesn't re-arm
	# pace either. Reuses the ONE attack-dict builder with the damage=0 / godded overrides (no second literal).
	if is_godded(target_id):
		var godded_data := _build_attack_data(attacker, attacker_id, target, target_id, 0, int(_hp[target_id]), kind, duration_sec, true)
		NetEvents.post_event("attack", godded_data, attacker_id)
		return false
	# Forcing-window arming, uniform catch-all (Tactical Zones v1, §2.8.7, review #6). A PLAYER attacker
	# (positive id) landing ANY damage — an AoO free strike (attacks_of_opportunity_enabled), a future
	# windup weapon's hit, or a bump — counts as a hostile action, so it can't be dodged out of tactical.
	# Two-site split with MoveReferee._begin_bump: the bump arms EARLY (before its own window is stamped)
	# purely for stamp ORDERING (no fast first swing); apply_damage / wind_up are the UNIFORM catch-alls
	# that guarantee every player-dealt hostile action arms regardless of path. Re-arming on the bump path
	# is idempotent-by-design — each hostile action refreshes the same wall-clock deadline.
	# is_alive gate (v0.17.1 review #10): a traveling arrow can land AFTER its shooter disconnected —
	# baked primitives keep the hit valid — and re-arming a gone peer's forcing window would re-create
	# _force_until[id] after cleanup already erased it (a permanent, harmless dict key). Gate on liveness
	# so a dead/departed attacker arms nothing. attacker_id > 0 stays: report_hostile_action is the
	# player-only forcing window; a monster (negative id) never arms one regardless.
	if _pace != null and attacker_id > 0 and is_alive(attacker_id):
		_pace.report_hostile_action(attacker_id)
	# Passive modify_damage dispatch (v0.11.0). AFTER the god-check (a godded no-op returned above and
	# runs NO passives), BEFORE the HP mutation. Run the ATTACKER's passives SEQUENTIALLY in array order
	# — each receives the previous one's output amount (ctx.amount rewritten between calls) — and collect
	# any feedback tags (e.g. "backstab") for the event. Host-only (this referee is inert on clients); a
	# monster or a no-passive attacker yields an empty list and skips the whole block. ctx is kept for
	# the after_attack pass below (same dict, now carrying the final amount).
	var tags: Array = []
	var passives := _passives_of(attacker)
	var ctx: Dictionary = {}
	if not passives.is_empty():
		ctx = _build_damage_ctx(attacker, attacker_id, target, target_id, amount, kind)
		for p in passives:
			ctx["amount"] = p.modify_damage(ctx)
		# Re-floor after the chain (defense-in-depth, mirroring the entry floor): the maxi(0, hp-amount)
		# below has no ceiling, so a buggy passive returning a negative must never heal a target here.
		amount = maxi(0, int(ctx["amount"]))
		tags = ctx["tags"]
	var new_hp: int = maxi(0, int(_hp[target_id]) - amount)
	_hp[target_id] = new_hp
	var target_name := _name_of(target)
	# Author the hit on the shared pipe (as_peer = attacker, positive for a player or negative for a
	# monster — negative ids are fine on the wire). Posted BEFORE any `died` so hp_after 0 lands first.
	# `tags` rides the event only when non-empty (see _build_attack_data), so a plain hit is unchanged.
	var attack_data := _build_attack_data(attacker, attacker_id, target, target_id, amount, new_hp, kind, duration_sec, false, tags)
	NetEvents.post_event("attack", attack_data, attacker_id)
	var died := new_hp <= 0
	# Passive after_attack dispatch (v0.11.0): post-broadcast observation with the lethal flag. Fired
	# BEFORE _kill_entity so the target node is still valid for a passive to read; still fully
	# synchronous + host-only. Read-only per the PassiveAbility contract — the `attack` event is out.
	if not passives.is_empty():
		ctx["died"] = died
		for p in passives:
			p.after_attack(ctx)
	if died:
		_kill_entity(target_id, target_name)
		return true
	# Damage is an AGGRO SOURCE (v0.17.2 review fix): a SURVIVING Monster that just took a hit wakes its
	# brain, so a ranged arrow from beyond aggro_range_tiles aggros it (no free sniping). Placed AFTER the
	# lethal path above so a KILLING blow never notifies (dead monsters don't aggro), and after the godded
	# early-return (a no-op hit on an invulnerable target aggros nothing). Host-only by construction —
	# apply_damage only runs on the host. is_alive re-confirms the target survived (belt-and-suspenders with
	# the died branch). A Player target is skipped (only monsters have a brain to wake).
	if target is Monster and is_alive(target_id):
		target.notify_attacked()
	return false


## Apply a deterministic heal to a target and broadcast the outcome (v0.18.0 chunk C; DESIGN §2.4). Host-only.
## Heals are their OWN pipe, DELIBERATELY separate from apply_damage (which stays damage-only per its own
## contract — a heal is NOT "negative damage"): the two never share a code path, so a floor / passive / god
## rule on one can never leak onto the other. god mode does NOT block a heal — /god makes a target invulnerable
## to DAMAGE, not immune to recovery, so a godded player can still be healed. `source_name` is the flavor for
## the log line / popup (the item or spell name); the event carries the ACTUAL applied delta after the max clamp.
func apply_heal(target_id: int, amount: int, source_name: String) -> void:
	# Guard liveness — never heal a dead/untracked target: it would post a spurious event and could re-seed HP
	# for an id the death teardown just erased (the caller — _resolve_use — already re-checked, this is the belt).
	if not is_alive(target_id):
		return
	# Floor at 0 (defense-in-depth, mirroring apply_damage's entry floor): a negative "heal" must never become
	# stealth damage on this pipe. A 0 amount is a harmless no-op heal (the clamp below handles it cleanly).
	amount = maxi(0, amount)
	var target := _node_of_id(target_id)
	var max_hp := _max_hp_of(target)
	# Clamp to the authored maximum — a heal never overfills. The event carries the ACTUAL applied delta
	# (new_hp - old_hp), so an over-heal renders "+3" when only 3 HP was missing, not the raw "+10".
	var old_hp: int = int(_hp[target_id])
	var new_hp: int = mini(max_hp, old_hp + amount)
	_hp[target_id] = new_hp
	# Broadcast on the shared pipe (as_peer = the TARGET — a heal's subject is who got healed, mirror of an
	# attack's as_peer = attacker). hp_after + target_max let every peer render the bar with no query; the delta
	# drives the green "+N" popup; source names the cause in the log. Its own action name — never an `attack` event.
	NetEvents.post_event("heal", {
		"entity_id": target_id,
		"name": _name_of(target),
		"amount": new_hp - old_hp,
		"hp_after": new_hp,
		"target_max": max_hp,
		"source": source_name,
	}, target_id)


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
	# Server facing at wind-up ENTRY (v0.11.0): the attacker turns to face its committed target tile —
	# a mid-windup monster faces its victim and so can't be "backstabbed sideways" during the telegraph.
	# Sign-vector from the attacker's authoritative tile toward the target tile; set through MoveReferee
	# (it owns _facing). A ZERO dir (attacker already ON the tile — impossible for a real windup) no-ops.
	var att_tile: Vector2i = _move_referee.tile_of_entity(attacker_id)
	_move_referee.set_facing(attacker_id, (target_tile - att_tile).sign())
	# before_attack observation seam (v0.11.0), fired at wind-up ENTRY before any stamp/telegraph. The
	# target is whatever hostile currently occupies the committed tile (best-effort — the real occupant
	# is re-resolved at strike time); a monster/no-passive attacker no-ops. Read-only per the contract.
	fire_before_attack(attacker_id, _move_referee.entity_at(target_tile), "windup")
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
	# Stamp the weapon on the telegraph event (present-only), mirroring _build_attack_data and the bow
	# shoot path: a MELEE windup weapon (the goblin's claw) rides its display_name so every peer's rig
	# can pose the raised telegraph over the coil. A weaponless windup attacker stamps no field.
	var windup_data := {
		"entity_id": attacker_id,
		"name": _name_of(attacker),
		"target_tile": target_tile,
		"windup_sec": windup_sec,
	}
	if attacker is Entity and attacker.equipped_weapon != null:
		windup_data["weapon"] = attacker.equipped_weapon.display_name
	NetEvents.post_event("windup", windup_data, attacker_id)
	# SceneTreeTimer on the host tree (never a Timer child of the monster — survives despawn by
	# construction, the same mechanism MoveReferee's completion timers use). recovery_sec stamps the
	# landed event's duration (swing + spent tell, same as the instant path); occupancy stays
	# windup-only — recovery remains brain pacing (added to the return), not a referee record.
	get_tree().create_timer(windup_sec).timeout.connect(
			_resolve_windup.bind(attacker_id, target_tile, "windup", recovery_sec))
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


## Fire the ATTACKER's before_attack passives (v0.11.0 read-only observation seam). Host-only public
## entry: MoveReferee._begin_bump calls it at a player bump's entry; wind_up calls it at wind-up entry.
## Resolves the attacker's passive list and runs each hook with a read-only ctx; a no-passive attacker
## (or a monster, or an unresolved node) no-ops. The contract (PassiveAbility.before_attack) forbids
## this hook cancelling or mutating the attack — it observes/arms only, so nothing here touches state.
func fire_before_attack(attacker_id: int, target_id: int, kind: String) -> void:
	# No resolvable target (a wind-up whose tile has no occupant at entry passes target_id 0): skip the
	# hook rather than hand every passive a null target to guard against — defense-in-depth for the
	# read-only contract. A targetless swing has nothing for an observation hook to observe.
	if target_id == 0:
		return
	var attacker := _node_of_id(attacker_id)
	var passives := _passives_of(attacker)
	if passives.is_empty():
		return
	var target := _node_of_id(target_id)
	var ctx := {
		"attacker": attacker,
		"target": target,
		"attacker_id": attacker_id,
		"target_id": target_id,
		"kind": kind,
		"weapon": attacker.equipped_weapon if attacker is Entity else null,
		"attacker_facing": _move_referee.facing_of(attacker_id),
		"target_facing": _move_referee.facing_of(target_id),
	}
	for p in passives:
		p.before_attack(ctx)


## Positional BEHIND-ARC test (v0.11.0), a pure-math static so any passive (or future system) can reuse
## it (Jeff's ask) — Backstab is the first caller. `behind` = the approach vector (sign-vector from the
## attacker's tile toward the target's tile) points the SAME rough way the target faces: dot > 0 STRICTLY.
## That is the classic wide backstab arc — the rear 3 octants of the defender's 8-way facing; dot == 0 is
## a FLANK (not behind), and a ZERO target_facing (never-moved: faces nowhere) is never a backstab.
## ADJACENCY ASSUMPTION: all combat is melee-adjacent today, so approach is a clean 8-way sign; the parked
## ranged pass (Q6) revisits this with a normalized delta. Vector2i has no dot(), so it's spelled out.
static func is_attack_from_behind(attacker_tile: Vector2i, target_tile: Vector2i, target_facing: Vector2i) -> bool:
	if target_facing == Vector2i.ZERO:
		return false
	var approach := (target_tile - attacker_tile).sign()
	return approach.x * target_facing.x + approach.y * target_facing.y > 0


## Host-only F5 round-reset hook (v0.17.1 review #4), called by Main._reset_round BEFORE it frees the
## avatars. Bumps the round generation and drops all in-flight arrow state so nothing from the old round
## bleeds into the fresh one: clearing _projectiles neutralizes every in-flight _arrow_step chain (each
## chained timer re-looks up its id in _projectiles and bails when absent — and _next_projectile_id is
## monotonic, so a stale callback can never collide with a fresh arrow), while the bumped _round_gen
## catches the OTHER case a cleared dict can't — a draw still pending its loose (its projectile record
## does not exist yet), whose captured generation no longer matches. Idempotent; safe to call any time.
## SCOPE (GLM v0.17.1): F5 (_reset_round) is the ONLY mass-respawn path today. Any FUTURE round-transition
## that frees + respawns entities (game-over restart, floor change) MUST also call this, or a pending loose
## from the prior round would pass the generation guard into the new one — the reset hook lives here so
## every such path has one call to make.
func reset_round() -> void:
	_round_gen += 1
	_projectiles.clear()


# ── Private methods ───────────────────────────────────────────────────────────


# ── Ranged shot (v0.17.0, the bow — traveling-arrow model) ─────────────────────

## The "shoot" intent validator (host-only; registered on the shared pipe in activate()). A player submits
## shoot {target_tile}; the host adjudicates from ITS own truth (occupancy, weapon, pace), commits the
## shooter for the FULL attack window, telegraphs the DRAW, and looses a traveling arrow when the draw ends.
## Reject reasons are DISTINCT per §2.2.8 (reject-to-sender). Returns a DEFERRED accept on success — the
## windup + projectile events ARE the outcome, so no generic "shoot" event is broadcast (mirror of /class).
func _validate_shoot(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Liveness (log-suppressed like a dead glide — the died event already told the player).
	if not is_alive(sender_peer_id):
		return { "ok": false, "reason": "dead" }
	# BUSY — the SAME commit-window predicate melee/swap read (is_entity_moving covers a glide AND a
	# commit_in_place record), so a shot can never interrupt or overlap a committed action (Commitment Rule).
	if _move_referee.is_entity_moving(sender_peer_id):
		return { "ok": false, "reason": "busy" }
	var shooter := _node_of_id(sender_peer_id)
	# Ranged discriminator: range_tiles > 0. A melee (0) or bare-handed weapon has nothing to draw with.
	var weapon: WeaponType = shooter.equipped_weapon if shooter is Entity else null
	if weapon == null or weapon.range_tiles <= 0:
		return { "ok": false, "reason": "Nothing to draw with." }
	# Never trust the wire — the target tile must be a real Vector2i.
	var tt = data.get("target_tile")
	if typeof(tt) != TYPE_VECTOR2I:
		return { "ok": false, "reason": "bad target" }
	var target_tile: Vector2i = tt
	var shooter_tile: Vector2i = _move_referee.tile_of_entity(sender_peer_id)
	if target_tile == shooter_tile:
		return { "ok": false, "reason": "Can't shoot your own tile." }
	# Range gate: CHEBYSHEV distance to the CLICKED tile ≤ the weapon's range_tiles (server-authoritative,
	# read from the shared weapon resource — never a client value).
	var cheb := maxi(absi(target_tile.x - shooter_tile.x), absi(target_tile.y - shooter_tile.y))
	if cheb > weapon.range_tiles:
		return { "ok": false, "reason": "Out of range." }

	# ── Accept ──
	# Forcing-window arming (§2.8.7): a shot is a hostile action, so the shooter stamps at the TACTICAL beat
	# (no fast first draw) and stays tactical afterward. Armed BEFORE the stamps, mirroring wind_up/_begin_bump.
	if _pace != null:
		_pace.report_hostile_action(sender_peer_id)
	# Server facing + before_attack at accept (v0.17.1 review #1), mirroring wind_up (231/235). The shooter
	# turns to face its committed target tile so a backstab adjudicates from the TURNED facing — not the
	# stale pre-shot direction the sprite is visibly leaving (main.gd's face_toward turns the art the same
	# way) — and the read-only before_attack observation seam fires for the shooter's passives, parity with
	# every other committed attack. fire_before_attack is contractually observe-only (it cannot cancel or
	# mutate the shot). Facing set through MoveReferee (it owns _facing); a zero dir no-ops (target == shooter
	# was rejected above). The occupant re-resolves at loose — this is best-effort observation, as in wind_up.
	_move_referee.set_facing(sender_peer_id, (target_tile - shooter_tile).sign())
	fire_before_attack(sender_peer_id, _move_referee.entity_at(target_tile), "shoot")
	# Stamp-and-bake (§2.8): the FULL attack_beats window is the shooter's committed occupancy; the DRAW
	# (windup_beats) looses the arrow partway through it. Both stamped ONCE now at the shooter's resolved pace.
	var busy_sec := _recovery_duration_of(shooter)   # weapon.attack_beats × pace beat — the whole occupied window
	var windup_sec := _windup_duration_of(shooter)   # weapon.windup_beats × pace beat — the draw before loose
	if GameManager.debug_windup_override_sec > 0.0:
		windup_sec = GameManager.debug_windup_override_sec
	# Misconfiguration guard (GLM milestone review #2): a .tres with windup_beats > attack_beats (or a big
	# windupsec= override) would end the commit BEFORE the loose — a free-action window while the draw timer
	# still pends (Commitment Rule violation). The commit always covers the draw.
	busy_sec = maxf(busy_sec, windup_sec)
	# LOOSE timer armed BEFORE commit_in_place (v0.17.1 review #8). Co-due SceneTreeTimers fire in CREATION
	# order, and commit_in_place creates its OWN completion timer internally — so at the misconfiguration TIE
	# (busy_sec == windup_sec: windup_beats >= attack_beats, or a windupsec= override) the loose must be the
	# earlier-created timer, else the commit-completion promotes a pipelined move BEFORE the arrow launches.
	# In normal play busy_sec > windup_sec (recovery tail), so the two land in different frames and order is
	# moot — this only bites at the tie. The commit miss below is purely defensive: is_entity_moving was
	# checked at entry and nothing yields between (single-threaded host), so the commit cannot actually fail
	# here and the loose is never orphaned. Host SceneTreeTimer (survives despawn by construction, like
	# _resolve_windup). Capture PRIMITIVES only (never node refs): the round generation (review #4), shooter
	# id + tile, damage, weapon name, per-tile speed. round_gen makes an F5-mid-draw loose NOTHING into the
	# fresh round — a same-peer respawn defeats is_alive, but the generation check catches it.
	get_tree().create_timer(windup_sec).timeout.connect(_loose_arrow.bind(
			_round_gen, sender_peer_id, shooter_tile, target_tile, weapon.damage,
			weapon.display_name, weapon.projectile_tiles_per_beat))
	# Commit the FULL window in place (from==to — the shooter is rooted while drawing AND recovering; no
	# occupancy move). A miss means it went busy between the checks and now (host single-threaded; defensive).
	if not _move_referee.commit_in_place(sender_peer_id, busy_sec):
		return { "ok": false, "reason": "busy" }
	# Telegraph the draw on the EXISTING `windup` event shape (+ the weapon name). A player-posted windup is
	# a harmless no-op in playback (the handler narrow-casts to Monster) until chunk 2's draw rig; the event
	# still broadcasts so headless assertions see it. as_peer = shooter (mirrors wind_up).
	NetEvents.post_event("windup", {
		"entity_id": sender_peer_id,
		"name": _name_of(shooter),
		"target_tile": target_tile,
		"windup_sec": windup_sec,
		"weapon": weapon.display_name,
	}, sender_peer_id)
	return { "ok": true, "deferred": true }


## Loose the arrow at the end of the draw (host-only, from the commit timer). Builds the flight path NOW,
## broadcasts projectile_launched, and starts the per-tile arrival chain. Everything is captured PRIMITIVES
## (no node refs), so a shooter that despawns MID-FLIGHT can't crash the arrow (its damage/identity are baked).
func _loose_arrow(round_gen: int, shooter_id: int, shooter_tile: Vector2i, target_tile: Vector2i,
		damage: int, weapon_name: String, tiles_per_beat: float) -> void:
	# Round-generation guard FIRST (v0.17.1 review #4): a draw in flight when F5 reset the round must loose
	# NOTHING into the fresh round. is_alive alone can't catch it — a same-peer respawn reuses the id and is
	# alive again — so the captured generation (bumped by reset_round) is the identity that no longer matches.
	if round_gen != _round_gen:
		return
	# Mid-draw erasure (Q9 / M3): a shooter that died or despawned during the draw looses nothing — the death
	# teardown (clear_entity) already erased its commit record. This mirrors _resolve_windup's is-alive guard.
	if not is_alive(shooter_id):
		return
	# Path = the 8-way line shooter→target, CLIPPED to end at the last OPEN tile before the first wall (an
	# arrow can't fly through a wall). `clipped` records whether a wall cut it short (→ "blocked") vs it
	# reaching the target tile (→ "spent").
	var clip := _clip_line_at_walls(WorldGrid.line_tiles(shooter_tile, target_tile))
	var path: Array[Vector2i] = clip["path"]
	var clipped: bool = clip["clipped"]
	var proj_id := _next_projectile_id
	_next_projectile_id += 1
	# Per-tile flight time, stamped ONCE at loose (never rescaled mid-flight — same as a glide's baked
	# seconds): the shooter's resolved beat (tactical here — it is mid-forcing-window) ÷ tiles-per-beat.
	var tile_duration := PaceReferee.beat_or_explore(_pace, shooter_id) / maxf(tiles_per_beat, 0.001)
	# Broadcast the launch (as_peer = shooter, mirroring windup) so every peer can render the flight in chunk
	# 2. Paired 1:1 with a projectile_ended by id in EVERY case, including the empty (adjacent-wall) path.
	NetEvents.post_event("projectile_launched", {
		"id": proj_id,
		"shooter_id": shooter_id,
		"path": path,
		"tile_duration_sec": tile_duration,
		"weapon": weapon_name,
	}, shooter_id)
	# Adjacent-wall click: no open tile to enter, the arrow thunks immediately. The commit window still runs
	# in full (Commitment Rule) — only the arrow did nothing. End at the shooter's tile (its last open spot).
	if path.is_empty():
		_end_projectile(proj_id, shooter_tile, "blocked", "")
		return
	_projectiles[proj_id] = {
		"shooter_id": shooter_id,
		"damage": damage,
		"path": path,
		"clipped": clipped,
		"index": 0,
		"tile_duration": tile_duration,
	}
	get_tree().create_timer(tile_duration).timeout.connect(_arrow_step.bind(proj_id))


## One tile-arrival tick for an in-flight arrow (host-only). Reads AUTHORITATIVE occupancy at the arrival
## tile (the same source move/combat referees read — Q4 destination-based) and applies THE ONE HIT RULE:
## stop at the first STOPPABLE occupant. No hit → advance, or finalize at the terminal tile.
func _arrow_step(proj_id: int) -> void:
	var p = _projectiles.get(proj_id)
	if p == null:
		return  # already ended (defensive — the id was erased on a hit / terminal)
	var index: int = p["index"]
	var tile: Vector2i = (p["path"] as Array)[index]
	var shooter_id: int = p["shooter_id"]
	var occ_id: int = _move_referee.entity_at(tile)
	# THE ONE HIT RULE: a STOPPABLE occupant eats the arrow HERE — apply arrow damage (the existing attack
	# event carries HP / log / cues) and end "hit".
	if occ_id != _NO_ENTITY and _is_stoppable(occ_id, shooter_id):
		apply_damage(shooter_id, occ_id, int(p["damage"]), "arrow", 0.0)
		_end_projectile(proj_id, tile, "hit", "")
		return
	# Terminal tile with no stoppable hit: "blocked" if a wall clipped the path, else "spent" (reached the
	# target). A SKIPPED ally sitting on the spent tile is NAMED so chunk 2 can log "sails past <name>".
	if index >= (p["path"] as Array).size() - 1:
		var outcome := "blocked" if p["clipped"] else "spent"
		var target_name := ""
		if outcome == "spent" and occ_id != _NO_ENTITY and _is_skipped_ally(occ_id, shooter_id):
			target_name = _name_of(_node_of_id(occ_id))
		_end_projectile(proj_id, tile, outcome, target_name)
		return
	# Pass through (empty tile, or a non-stoppable ally): advance to the next arrival tick.
	p["index"] = index + 1
	get_tree().create_timer(p["tile_duration"]).timeout.connect(_arrow_step.bind(proj_id))


## Finalize an arrow: forget its flight state and broadcast projectile_ended (server-authored, peer 0 —
## an outcome, mirror of `died`). `target_name` rides only for a skipped ally on the spent tile (chunk 2's
## distinct "sails past <name>" line); absent otherwise, so a plain end stays a minimal dict.
func _end_projectile(proj_id: int, tile: Vector2i, outcome: String, target_name: String) -> void:
	_projectiles.erase(proj_id)
	var data := { "id": proj_id, "tile": tile, "outcome": outcome }
	if not target_name.is_empty():
		data["target_name"] = target_name
	NetEvents.post_event("projectile_ended", data)


## Clip an 8-way line to the tiles an arrow can actually reach: every OPEN tile up to (but not including)
## the first wall. Returns { path, clipped } — `clipped` true when a wall cut the line short of its end.
func _clip_line_at_walls(line: Array[Vector2i]) -> Dictionary:
	var open_tiles: Array[Vector2i] = []
	var clipped := false
	for tile in line:
		if WorldGrid.is_wall(tile):
			clipped = true
			break
		open_tiles.append(tile)
	return { "path": open_tiles, "clipped": clipped }


## Is this occupant STOPPABLE by the shooter's arrow? Living, not the shooter itself, and — when
## projectile_hits_allies is OFF — hostile to the shooter (allies pass through). With the flag ON (default)
## any living non-shooter body stops it (friendly fire). Read HOST-side from shared config.
func _is_stoppable(occ_id: int, shooter_id: int) -> bool:
	if not is_alive(occ_id) or occ_id == shooter_id:
		return false
	if GameManager.config.projectile_hits_allies:
		return true
	return _is_hostile_pair(shooter_id, occ_id)


## Is this occupant an ally the arrow PASSED THROUGH (skipped)? Only meaningful with projectile_hits_allies
## OFF: a living non-shooter body NOT hostile to the shooter. Used to name a skipped ally on the spent tile.
func _is_skipped_ally(occ_id: int, shooter_id: int) -> bool:
	if GameManager.config.projectile_hits_allies:
		return false
	if not is_alive(occ_id) or occ_id == shooter_id:
		return false
	return not _is_hostile_pair(shooter_id, occ_id)


## Hostility between the shooter and an occupant, resolved through their nodes (server truth, never the
## wire). If a node is GONE (e.g. the shooter despawned mid-flight), fall back to ID-SIGN allegiance —
## players are positive ids, monsters negative, and v1's only teams are players-vs-monsters (plus the
## all_hostile dev knob) — so a posthumous arrow keeps the SAME ally/hostile behavior it was loosed with
## and projectile_hits_allies=false stays reliable (GLM milestone review #3). Never "default to stoppable":
## that would silently flip the designer toggle on shooter death.
func _is_hostile_pair(shooter_id: int, occ_id: int) -> bool:
	var shooter := _node_of_id(shooter_id)
	var occ := _node_of_id(occ_id)
	if shooter != null and occ != null:
		return shooter.is_hostile_to(occ)
	if GameManager.all_hostile:
		return true
	return (shooter_id > 0) != (occ_id > 0)


## Build the shared `attack` event dict for a LANDED or GODDED hit (v0.10.1 dedup) — the ONE construction
## both paths use, differing only in the damage / hp_after values passed and the godded flag. The weapon
## stamp (v0.9.3): ANY Entity attacker with an equipped weapon stamps its `weapon` id so every peer
## animates the right rig (playback guards on field-presence + non-empty); a weaponless attacker (a
## bare-handed player, the training dummy) stamps no field. `godded` adds the flag only when true, so a
## normal hit's dict is byte-identical to the pre-dedup literal.
func _build_attack_data(attacker: Node, attacker_id: int, target: Node, target_id: int,
		damage: int, hp_after: int, kind: String, duration_sec: float, godded: bool,
		tags: Array = []) -> Dictionary:
	var data := {
		"attacker_id": attacker_id,
		"attacker_name": _name_of(attacker),
		"target_id": target_id,
		"target_name": _name_of(target),
		"damage": damage,
		"hp_after": hp_after,
		"target_max": _max_hp_of(target),
		"kind": kind,
		"whiff": false,
		"duration_sec": duration_sec,
	}
	if godded:
		data["godded"] = true
	# Passive feedback tags (v0.11.0) ride the event ONLY when non-empty — a plain hit's dict stays
	# byte-identical to the pre-tags shape (same present-only style as `godded`/`weapon`). Clients read
	# these for the distinct per-outcome cue (§2.3.4), e.g. the backstab log line / popup / pitched sound.
	if not tags.is_empty():
		# duplicate(): the caller's ctx["tags"] stays live through the after_attack pass — a future
		# after_attack passive appending there must never mutate the already-posted event's array.
		data["tags"] = tags.duplicate()
	# Weapon stamp drives the rig swing on playback (main.gd) — stamped for EVERY kind that swings a
	# weapon (bump / windup / strike / free / arrow). EXCLUDE "kick" (v0.17.1): a ranged weapon's
	# point-blank bump has no melee swing, so it must carry NO weapon field (the rig-swing tail is
	# field-gated) — a kick renders like a bare-handed bump, never the bow slash arc.
	if attacker is Entity and attacker.equipped_weapon != null and kind != "kick":
		data["weapon"] = attacker.equipped_weapon.display_name
	return data


## Resolve an attack against its committed TILE. Shared by both shapes (decision 3; DESIGN §2.8):
## BOTH paths now stamp the landed event with the recovery seconds — the telegraphed wind-up (armed
## on a timer) AND the instant strike (called synchronously from wind_up). So every landed hit's
## `attack`/whiff event carries the recovery duration and every peer plays the recovery tell for it.
## Occupancy stays windup-only on the telegraphed path (the telegraph WAS the busy window) — recovery
## there is brain pacing, not a referee record; recovery_sec only rides the EVENT for the tell. `kind` is
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
## synchronous death erase above — a natural despawn just clears whatever remains. Also drops any /god
## invulnerability (v0.10.0): a disconnect / despawn / F5 respawn clears the godded flag, so a fresh
## spawn on the same id starts mortal — the same container hook that clears HP owns the god cleanup.
func _on_entity_exiting(node: Node) -> void:
	if node is Entity:
		_hp.erase(node.entity_id)
		_godded.erase(node.entity_id)


## Null-safe passive accessor (v0.11.0): the ATTACKER's PassiveAbility list, or [] for anything without
## one — a monster, the training dummy, an unresolved node. Duck-typed via Object.get so it never
## crashes on a node lacking `player_class` (get returns null for a missing property); a Player exposes
## player_class (its PlayerClass), whose `passives` array is the list. Monsters can own passives later by
## feeding this same accessor from MonsterType — the dispatch sites don't care where the array comes from.
func _passives_of(node) -> Array:
	if node == null:
		return []
	var pc = node.get("player_class")
	if pc == null:
		return []
	var passives = pc.get("passives")
	return passives if passives != null else []


## Build the modify_damage / after_attack context dict (v0.11.0). Authoritative throughout: tiles and
## facing come from MoveReferee (server truth), NEVER a node's rendered `tile`/sprite flip. attack_dir is
## the sign-vector from the attacker's tile toward the target's — for a bump the attacker's facing was
## just set to this same dir by _begin_bump, while target_facing is the DEFENDER's own last-committed
## facing (what a behind-arc check reads). weapon is the attacker's equipped WeaponType (or null). `tags`
## starts empty for a passive to append to. `amount` is rewritten in place as the modify_damage chain runs.
func _build_damage_ctx(attacker: Node, attacker_id: int, target: Node, target_id: int, amount: int, kind: String) -> Dictionary:
	var attacker_tile: Vector2i = _move_referee.tile_of_entity(attacker_id)
	var target_tile: Vector2i = _move_referee.tile_of_entity(target_id)
	return {
		"amount": amount,
		"attacker": attacker,
		"target": target,
		"attacker_id": attacker_id,
		"target_id": target_id,
		"kind": kind,
		"weapon": attacker.equipped_weapon if attacker is Entity else null,
		"attacker_tile": attacker_tile,
		"target_tile": target_tile,
		"attacker_facing": _move_referee.facing_of(attacker_id),
		"target_facing": _move_referee.facing_of(target_id),
		"attack_dir": (target_tile - attacker_tile).sign(),
		"tags": [],
	}


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
