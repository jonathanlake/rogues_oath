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

# STUN (v0.20.0 status effects). entity id -> true while stunned. Host-only authority (folded into the combat
# referee because every intent validator + the monster brain already holds a _combat reference, so the gate
# needs no new injection). A stunned entity cannot START a new committed action — the validators early-reject
# "stunned" BEFORE the busy check, and the monster brain skips its think — but a stun NEVER touches the
# _gliding/commit_in_place record, so an action already in flight plays out (the Commitment Rule, §2.1). Erased
# with the entity's HP on death / container exit so a fresh spawn is unstunned.
var _stunned: Dictionary = {}
# Per-entity stun GENERATION (v0.20.0), bumped on every apply_stun. The expiry timer for stun N only clears the
# stun if its captured generation is still current — so a RE-STUN (bumps the gen, re-arms, re-broadcasts the
# icon window) is not cut short by the earlier stun's timer. Same idiom as the round/cast generation tokens.
var _stun_gen: Dictionary = {}

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
# Weapon-drop-on-death hook (v0.19.x loot), host-only: a Callable bound to Main._spawn_item_at (the SAME
# guarded, id-assigning, replicating spawn helper the /item dev command uses). Injected via activate so this
# referee never reaches up to Main (its documented invariant). _kill_entity calls it to drop a dead monster's
# equipped weapon as a GroundItem. Unset/invalid on clients (activate never runs there) — is_valid() gates it.
var _drop_item: Callable = Callable()

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
func activate(players: Node2D, monsters: Node2D, move_referee: Node, pace: Node, drop_item: Callable) -> void:
	_players = players
	_monsters = monsters
	_move_referee = move_referee
	_pace = pace
	_drop_item = drop_item
	_players.child_entered_tree.connect(_on_entity_entered)
	_players.child_exiting_tree.connect(_on_entity_exiting)
	_monsters.child_entered_tree.connect(_on_entity_entered)
	_monsters.child_exiting_tree.connect(_on_entity_exiting)
	NetEvents.register_handler("shoot", _validate_shoot)
	# Host-only: the ACTIVE ABILITY validator (v0.20.0). ANY peer submits use_ability {index}; this validates the
	# sender's class ability at that index server-side, commits it, and resolves a melee strike + stun on an
	# adjacent enemy — the 1-5 hotbar. Registered like "shoot" (the other combat intent this referee owns).
	NetEvents.register_handler("use_ability", _validate_use_ability)
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


## Is this entity currently STUNNED (v0.20.0)? The ONE predicate every intent validator + the monster brain
## reads at ENTRY to reject/skip starting a NEW committed action. An untracked id reads false. Host-only truth;
## never trusted from the wire (only apply_stun, host-side, writes it). Reading it never touches the busy record.
func is_stunned(entity_id: int) -> bool:
	return _stunned.get(entity_id, false)


## Apply a STUN to a target for `stun_beats`, host-authoritative (v0.20.0). Stamps the duration at the TARGET's
## resolved pace (so it scales with tempo), latches _stunned, bumps the generation, broadcasts `status_applied`
## (every peer shows the overhead stun icon for the same window), and arms the expiry. Killed/despawned clears
## it (see _kill_entity / _on_entity_exiting). Does NOT interrupt anything — the target's in-flight committed
## action still plays out; the stun only blocks the NEXT one (§2.1). A 0/negative beats is a no-op.
func apply_stun(target_id: int, stun_beats: float) -> void:
	if not is_alive(target_id):
		return
	if stun_beats <= 0.0:
		return
	var stun_sec := stun_beats * PaceReferee.beat_or_explore(_pace, target_id)
	_stunned[target_id] = true
	var gen: int = int(_stun_gen.get(target_id, 0)) + 1
	_stun_gen[target_id] = gen
	# Broadcast the icon window (host-authored, peer 0 — an outcome, like `died`). duration_sec holds the
	# overhead icon exactly the stun window on every peer.
	NetEvents.post_event("status_applied", {
		"entity_id": target_id,
		"name": _name_of(_node_of_id(target_id)),
		"status": "stun",
		"duration_sec": stun_sec,
	})
	# Host SceneTreeTimer (survives despawn by construction). Generation-guarded so a re-stun's later expiry wins.
	get_tree().create_timer(stun_sec).timeout.connect(_expire_stun.bind(target_id, gen))


## Resolve the FIRST live monster whose display_name matches `name` (case-insensitive) → its entity id, or 0 if
## none (v0.20.0, for the /stun dev command). Host-only, scans the Monsters container. Targets a LIVE instance by
## name (unlike /m, which tunes the shared MonsterType).
func find_monster_by_name(name: String) -> int:
	if _monsters == null:
		return 0
	var lname := name.to_lower()
	for child in _monsters.get_children():
		if child is Monster and is_alive(child.entity_id) and child.display_name.to_lower() == lname:
			return child.entity_id
	return 0


## Apply deterministic melee damage from attacker to target and broadcast the outcome. Host-only.
## Returns whether the target DIED (so MoveReferee's AoO scan can abort a glide whose mover it just
## killed — decision 4). `kind` is bump|free|windup (the flavor for feedback + the combat log).
## `duration_sec` rides the event for the bump kind only (the local attacker's swing-busy window,
## decision 2); free/windup pass 0. The event carries target_max so every peer renders "hp/max"
## with no query. On a lethal hit, death is resolved SYNCHRONOUSLY here (decision 7) — no frame
## window where a stale record blocks another mover.
func apply_damage(attacker_id: int, target_id: int, amount: int, kind: String, duration_sec: float = 0.0, verb: String = "") -> bool:
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
	var attack_data := _build_attack_data(attacker, attacker_id, target, target_id, amount, new_hp, kind, duration_sec, false, tags, verb)
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

	# Telegraphed wind-up path (dial > 0). Commit the FULL window — windup + recovery — as ONE referee-busy
	# record (v0.19.0 double-hit fix), not the windup alone. The strike still resolves at windup_sec (the
	# timer below), but the monster stays referee-busy through its recovery, so an EXTERNAL wake during
	# recovery (notify_attacked when the monster is hit) correctly sees it busy instead of firing a bonus
	# attack. This matches the instant-strike path, which already commits its full recovery. No cancel path
	# is lost — the Commitment Rule already forbids interrupting a committed action; the busy record just now
	# spans the true "cannot act" window. Shared commit_in_place (bump uses it too): from==to busy in one place.
	if not _move_referee.commit_in_place(attacker_id, windup_sec + recovery_sec):
		return -1.0
	# Stamp the weapon on the telegraph event (present-only), mirroring _build_attack_data and the bow
	# shoot path: a MELEE windup weapon (the goblin's club) rides its display_name so every peer's rig
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


# ── Monster heal cast (v0.19.4, the shaman — telegraphed support ability) ──────

## Pick the ALLY MONSTER a healer should target: the lowest-current-HP living monster (other than the caster)
## that is BELOW its max HP and within `range_tiles` CHEBYSHEV of `caster_tile`. Host-only, read straight off the
## combat truth (_hp) + authoritative occupancy (MoveReferee.tile_of_entity) so the brain never adjudicates from
## a rendered position. Returns the target's NEGATIVE entity id, or 0 (never a real id) when there is no valid
## ally — the brain then falls through to chase/attack. Allies = other MONSTERS (negative ids): v1's only
## factions are players-vs-monsters, so every OTHER monster is an ally (matches Monster.is_hostile_to). Tie on
## HP: the FIRST encountered wins (dict insertion order — deterministic on the single-threaded host).
func pick_heal_target(caster_id: int, caster_tile: Vector2i, range_tiles: int) -> int:
	var best_id := 0
	var best_hp := 0
	for id in _hp:
		# Players (positive) are not ally-healed; never heal self.
		if id >= 0 or id == caster_id:
			continue
		if not is_alive(id):
			continue
		var node := _node_of_id(id)
		if node == null:
			continue
		# Only heal COMBATANTS (v0.19.10 fix): skip a brainless prop — the training dummy (has_brain=false) is a
		# monster sitting below max HP, so it was a heal MAGNET the shaman wasted casts on. A real ally only.
		# A null-monster_type node (a spawn-config bug) is also skipped — it's not a valid ally (review #6).
		if node is Monster and (node.monster_type == null or not node.monster_type.has_brain):
			continue
		var hp := int(_hp[id])
		# Already at (or above) max — nothing to heal.
		if hp >= _max_hp_of(node):
			continue
		var tile: Vector2i = _move_referee.tile_of_entity(id)
		var cheb := maxi(absi(tile.x - caster_tile.x), absi(tile.y - caster_tile.y))
		if cheb > range_tiles:
			continue
		if best_id == 0 or hp < best_hp:
			best_id = id
			best_hp = hp
	return best_id


## A healer MonsterBrain requests a telegraphed HEAL CAST on a chosen ally (v0.19.4). Host-only. Mirrors
## wind_up's shape: validate caster alive + not already busy + target still valid, commit the FULL cast +
## recovery window as ONE beat-stamped busy record (Commitment Rule — the healer cannot move or re-cast; the
## busy record IS the pacing, so there is no separate cooldown), telegraph the channel (heal_cast event →
## §2.3.4 cue + log on every peer), resolve the heal at cast END through the shared apply_heal pipe, and hold
## the caster spent through the recovery tail (v0.19.9 — like an attack's recovery). `amount`/`cast_beats`/
## `recovery_beats` come from the caller's MonsterType (the brain owns its type), captured now. Returns the
## seconds the brain should wait before its next think (the whole cast + recovery window) on success, or -1.0
## if DECLINED (caster not alive / already busy / target gone) so the brain distinguishes a cast from a back-off.
func heal_cast(caster_id: int, target_id: int, amount: int, cast_beats: float, recovery_beats: float) -> float:
	if not is_alive(caster_id):
		return -1.0
	# The caster must be free — never overlap a cast with a glide/another commit (Commitment Rule backstop,
	# owned by MoveReferee — is_entity_moving covers a glide AND a commit_in_place record).
	if _move_referee.is_entity_moving(caster_id):
		return -1.0
	# Re-validate the target at commit (the brain picked it a think ago). Dead / vanished / already-full means
	# don't burn a cast — decline so the brain re-decides (chase/attack) this think. Between the brain's pick
	# and here nothing yields (single-threaded host), so this is belt-and-suspenders.
	if not is_alive(target_id):
		return -1.0
	var target := _node_of_id(target_id)
	if target == null or int(_hp[target_id]) >= _max_hp_of(target):
		return -1.0
	# Stamp the cast + recovery windows at the CASTER's resolved pace (§2.8.7 — an engaged shaman channels at the
	# tactical beat), authored in beats so both rescale with the live tempo knob. The heal LANDS at cast end; the
	# shaman then stays busy (spent) for the recovery tail — the same shape a telegraphed attack uses (windup +
	# recovery as one busy record, Part 4 Q9 unified occupancy), so a healer can't chain-heal instantly.
	var beat := PaceReferee.beat_or_explore(_pace, caster_id)
	var cast_sec := maxf(0.0, cast_beats) * beat
	var recovery_sec := maxf(0.0, recovery_beats) * beat
	# Commit the WHOLE window (cast + recovery) as one from==to busy record (shared with bump/windup). A miss
	# means the caster went busy between the brain's gate and now (host single-threaded; defensive).
	if not _move_referee.commit_in_place(caster_id, cast_sec + recovery_sec):
		return -1.0
	var caster := _node_of_id(caster_id)
	# Face the ally being tended (server truth; a ZERO dir no-ops). Purely so the tell points the right way.
	_move_referee.set_facing(caster_id, (_move_referee.tile_of_entity(target_id) - _move_referee.tile_of_entity(caster_id)).sign())
	# Telegraph the channel on its OWN event — never an attack/windup (a heal is a DISTINCT outcome, §2.3.4).
	# as_peer = the caster (negative id, fine on the wire), mirroring wind_up. Carries the target tile so every
	# peer can point the tell at the ally, and cast_sec so the on-screen channel holds exactly the window.
	NetEvents.post_event("heal_cast", {
		"caster_id": caster_id,
		"caster_name": _name_of(caster),
		"target_id": target_id,
		"target_name": _name_of(target),
		"target_tile": _move_referee.tile_of_entity(target_id),
		"cast_sec": cast_sec,
	}, caster_id)
	# Resolve at cast END (heal-at-END, like a potion drink): host SceneTreeTimer (survives despawn by
	# construction, same as _resolve_windup). Capture PRIMITIVES — a caster killed mid-cast wastes the heal
	# (the resolve re-checks liveness). amount is baked at cast start (a live /m change mid-cast won't retune).
	get_tree().create_timer(cast_sec).timeout.connect(
			_resolve_heal_cast.bind(caster_id, target_id, maxi(0, amount)))
	return cast_sec + recovery_sec


## Resolve a committed heal cast at its END (host-only, from the cast timer). The caster must still be alive —
## a healer killed or despawned mid-cast heals NOTHING (the distinct outcome a slow telegraph buys, mirroring
## _resolve_windup and heal-at-drink-END). The heal lands on the COMMITTED ally through the shared apply_heal
## pipe (which re-guards liveness + clamps to max, and posts the `heal` event: green +N popup, HP readout, log
## line). If that ally died during the channel, apply_heal's own is-alive guard no-ops cleanly — the ally's
## `died` line already told the story. source_name is the healer's, so the heal's flavor names its caster.
func _resolve_heal_cast(caster_id: int, target_id: int, amount: int) -> void:
	if not is_alive(caster_id):
		return
	apply_heal(target_id, amount, _name_of(_node_of_id(caster_id)))


## Pick the GROUND TILE a smiter targets (v0.19.10, Rogue-Fable telegraphed-ground model): a RANDOM living
## player's CURRENT tile, if any player is within `range_tiles` CHEBYSHEV of `caster_tile`. Host-only (host owns
## the RNG, so the pick is authoritative and rides the broadcast cast event). The smite commits to this TILE, not
## the player — a player can step OFF it during the cast to dodge, and one who steps ONTO it eats the hit (commit
## to ground, the same model as the melee wind-up). Returns the tile, or the wall-sentinel (0,0) if no player is
## in range (callers detect via WorldGrid.is_wall — no live body ever rests on a wall).
func pick_smite_tile(caster_id: int, caster_tile: Vector2i, range_tiles: int) -> Vector2i:
	var in_range: Array[Vector2i] = []
	for id in _hp:
		if id <= 0:  # players are positive; skip monsters (negative) and the 0 sentinel
			continue
		if not is_alive(id):
			continue
		var tile: Vector2i = _move_referee.tile_of_entity(id)
		var cheb := maxi(absi(tile.x - caster_tile.x), absi(tile.y - caster_tile.y))
		if cheb <= range_tiles:
			in_range.append(tile)
	if in_range.is_empty():
		return Vector2i.ZERO  # (0,0) is always a border wall → a safe "no target" sentinel
	return in_range[randi() % in_range.size()]


## A smiter MonsterBrain requests a telegraphed SMITE on a chosen TILE (v0.19.10). Host-only. Same committed-cast
## shape as heal_cast: validate caster alive + not busy, commit cast + recovery as ONE busy record, telegraph the
## channel (smite_cast event carrying the target_tile → every peer paints it RED for the cast window), resolve
## against the TILE at cast END (dodgeable), and hold the caster spent through the recovery tail. `damage`/
## `cast_beats`/`recovery_beats` come from the caller's MonsterType. Returns the whole cast + recovery seconds on
## success, or -1.0 if DECLINED (caster dead / busy) so the brain distinguishes a cast from a back-off.
func smite_cast(caster_id: int, target_tile: Vector2i, damage: int, cast_beats: float, recovery_beats: float) -> float:
	if not is_alive(caster_id):
		return -1.0
	if _move_referee.is_entity_moving(caster_id):
		return -1.0
	var beat := PaceReferee.beat_or_explore(_pace, caster_id)
	var cast_sec := maxf(0.0, cast_beats) * beat
	var recovery_sec := maxf(0.0, recovery_beats) * beat
	if not _move_referee.commit_in_place(caster_id, cast_sec + recovery_sec):
		return -1.0
	var caster := _node_of_id(caster_id)
	var caster_tile: Vector2i = _move_referee.tile_of_entity(caster_id)
	# Face the targeted tile (server truth; a ZERO dir no-ops).
	_move_referee.set_facing(caster_id, (target_tile - caster_tile).sign())
	# Name the CURRENT occupant (best-effort, for the log line) — the real hit re-resolves at cast end, so a
	# dodge turns this into a fizzle. An empty tile at cast start still telegraphs.
	var occ_id: int = _move_referee.entity_at(target_tile)
	var occ_name := _name_of(_node_of_id(occ_id)) if occ_id != _NO_ENTITY else ""
	# Telegraph on its OWN event — a distinct OFFENSIVE channel (§2.3.4). target_tile drives the red danger-tile.
	NetEvents.post_event("smite_cast", {
		"caster_id": caster_id,
		"caster_name": _name_of(caster),
		"target_tile": target_tile,
		"target_name": occ_name,
		"cast_sec": cast_sec,
	}, caster_id)
	get_tree().create_timer(cast_sec).timeout.connect(
			_resolve_smite.bind(caster_id, target_tile, maxi(0, damage), recovery_sec))
	return cast_sec + recovery_sec


## Resolve a committed smite at cast END against its TILE (host-only, from the cast timer). Mirrors _resolve_windup:
## the caster must still be alive (killed mid-cast = nothing, the rush-it counterplay); then whoever HOSTILE and
## LIVING occupies the tile NOW eats `damage` (a player who stepped on eats it; the original target who stepped off
## dodges). No hostile occupant → a WHIFF event (kind "smite", whiff true) so the dodge is a distinct §2.3.4 outcome.
## Clear a STUN at its window's end (host-only, from the expiry timer), GENERATION-guarded (v0.20.0): only the
## current stun's timer clears — a re-stun bumped the gen and re-armed, so an earlier timer no-ops. Erases the
## latch and broadcasts status_expired so every peer drops the overhead icon in lockstep. A dead/despawned entity
## (gen already erased) also no-ops.
func _expire_stun(entity_id: int, gen: int) -> void:
	if int(_stun_gen.get(entity_id, -1)) != gen:
		return
	_stunned.erase(entity_id)
	_stun_gen.erase(entity_id)
	NetEvents.post_event("status_expired", { "entity_id": entity_id, "status": "stun" })


func _resolve_smite(caster_id: int, target_tile: Vector2i, damage: int, recovery_sec: float) -> void:
	if not is_alive(caster_id):
		return
	var caster := _node_of_id(caster_id)
	var occ_id: int = _move_referee.entity_at(target_tile)
	if occ_id != _NO_ENTITY:
		var occ := _node_of_id(occ_id)
		if occ != null and is_alive(occ_id) and caster != null and caster.is_hostile_to(occ):
			# recovery_sec rides the hit so the caster plays its "spent" recovery tell (review #2) — without it
			# the shaman froze ~2 beats after every smite with no on-screen explanation.
			apply_damage(caster_id, occ_id, damage, "smite", recovery_sec)
			return
	# Dodged / empty ground — a distinct WHIFF (the target moved off in time). target_tile rides so the miss
	# cue lands on the committed tile; kind "smite" so the log reads "fizzles — dodged!" not a melee miss.
	# recovery_sec rides so the caster shows its spent tell on a dodge too (review #2).
	NetEvents.post_event("attack", {
		"attacker_id": caster_id,
		"attacker_name": _name_of(caster),
		"target_id": _NO_ENTITY,
		"target_name": "",
		"target_tile": target_tile,
		"damage": 0,
		"hp_after": -1,
		"target_max": 0,
		"kind": "smite",
		"whiff": true,
		"duration_sec": recovery_sec,
	}, caster_id)


# ── Active abilities (v0.20.0, the 1-5 hotbar — a player-triggered melee strike + stun) ──────

## The "use_ability" validator (host-only; registered on the shared pipe in activate()). A player submits
## use_ability {index}; the host resolves that class ability server-side and, if a hostile is adjacent, commits
## the player for the ability's occupied window (Q9: no cooldown — the beats ARE the cost) and resolves a melee
## strike that deals damage + applies a stun. Distinct §2.2.8 rejects (dead / stunned / busy / no ability /
## no target). Returns a DEFERRED accept on success — the `attack` + `status_applied` events ARE the outcome.
func _validate_use_ability(sender_peer_id: int, data: Dictionary) -> Dictionary:
	if not is_alive(sender_peer_id):
		return { "ok": false, "reason": "dead" }
	if is_stunned(sender_peer_id):
		return { "ok": false, "reason": "stunned" }
	if _move_referee.is_entity_moving(sender_peer_id):
		return { "ok": false, "reason": "busy" }
	var caster := _node_of_id(sender_peer_id)
	var ability := _ability_of(caster, int(data.get("index", -1)))
	if ability == null or not ability.is_valid_ability():
		return { "ok": false, "reason": "no such ability" }
	# Target: the first ADJACENT hostile (facing neighbour preferred). No target → a clean reject, not a whiff —
	# a player-triggered ability shouldn't burn its window on empty air (unlike a monster's committed windup).
	var my_tile: Vector2i = _move_referee.tile_of_entity(sender_peer_id)
	var target_id := _adjacent_hostile(sender_peer_id, my_tile, caster)
	if target_id == 0:
		return { "ok": false, "reason": "no target" }
	# Forcing window (§2.8.7): an ability is a hostile action, so the caster stamps + stays tactical.
	if _pace != null:
		_pace.report_hostile_action(sender_peer_id)
	var beat := PaceReferee.beat_or_explore(_pace, sender_peer_id)
	var windup_sec := maxf(0.0, ability.windup_beats) * beat
	var recovery_sec := maxf(0.0, ability.recovery_beats) * beat
	var target_tile: Vector2i = _move_referee.tile_of_entity(target_id)
	_move_referee.set_facing(sender_peer_id, (target_tile - my_tile).sign())
	# Instant strike (windup 0) — commit the recovery window and resolve now (mirrors the goblin instant strike).
	if windup_sec <= 0.0:
		if not _move_referee.commit_in_place(sender_peer_id, recovery_sec):
			return { "ok": false, "reason": "busy" }
		_resolve_ability(sender_peer_id, target_tile, ability.damage, ability.stun_beats, ability.log_verb, recovery_sec)
		return { "ok": true, "deferred": true }
	# Telegraphed (windup > 0) — commit the FULL window, resolve at windup end (dodgeable), like a monster windup.
	if not _move_referee.commit_in_place(sender_peer_id, windup_sec + recovery_sec):
		return { "ok": false, "reason": "busy" }
	get_tree().create_timer(windup_sec).timeout.connect(
			_resolve_ability.bind(sender_peer_id, target_tile, ability.damage, ability.stun_beats, ability.log_verb, recovery_sec))
	return { "ok": true, "deferred": true }


## Resolve an active-ability strike against its committed TILE (host-only). Caster alive-gated (killed mid-windup
## = nothing). Whoever HOSTILE + LIVING occupies the tile NOW eats `damage` (kind "ability", carrying the verb for
## the log) AND a `stun_beats` stun; a target that stepped off / died whiffs (a distinct §2.3.4 outcome). recovery_sec
## rides the hit so the caster shows its spent tell. The strike is deterministic (RF baseline) — the stun is the ability's teeth.
func _resolve_ability(attacker_id: int, target_tile: Vector2i, damage: int, stun_beats: float, verb: String, recovery_sec: float) -> void:
	if not is_alive(attacker_id):
		return
	var attacker := _node_of_id(attacker_id)
	var occ_id: int = _move_referee.entity_at(target_tile)
	if occ_id != _NO_ENTITY:
		var occ := _node_of_id(occ_id)
		if occ != null and is_alive(occ_id) and attacker != null and attacker.is_hostile_to(occ):
			apply_damage(attacker_id, occ_id, damage, "ability", recovery_sec, verb)
			# Stun AFTER the damage (order matches the event stream: hit then status). Skipped if the hit
			# killed the target (apply_stun is is_alive-gated, so a dead target is never stunned).
			apply_stun(occ_id, stun_beats)
			return
	# Whiff — the target moved off / died. A distinct outcome (§2.3.4); kind "ability" + verb so the log reads
	# "<verb> hits nothing". recovery_sec rides so the caster still shows its spent tell.
	NetEvents.post_event("attack", {
		"attacker_id": attacker_id,
		"attacker_name": _name_of(attacker),
		"target_id": _NO_ENTITY,
		"target_name": "",
		"target_tile": target_tile,
		"damage": 0,
		"hp_after": -1,
		"target_max": 0,
		"kind": "ability",
		"whiff": true,
		"duration_sec": recovery_sec,
		"verb": verb,
	}, attacker_id)


## The ACTIVE ABILITY at `idx` on this node's class, or null (v0.20.0). Duck-typed off `player_class.active_abilities`
## exactly as _passives_of reads `player_class.passives` — a monster / no-class / out-of-range node yields null.
func _ability_of(node, idx: int) -> ActiveAbility:
	if node == null or idx < 0:
		return null
	var pc = node.get("player_class")
	if pc == null:
		return null
	var abilities = pc.get("active_abilities")
	if abilities == null or idx >= abilities.size():
		return null
	return abilities[idx]


## The FIRST adjacent hostile entity id to `attacker` from `my_tile` (v0.20.0): the FACING neighbour is preferred
## (you bash who you're looking at), else the 8 neighbours are scanned in a fixed order. 0 = none adjacent.
## Authoritative occupancy (entity_at) + server hostility (is_hostile_to) — never a rendered position.
func _adjacent_hostile(attacker_id: int, my_tile: Vector2i, attacker: Node) -> int:
	var facing: Vector2i = _move_referee.facing_of(attacker_id)
	if facing != Vector2i.ZERO:
		var fid := _hostile_at(my_tile + facing, attacker)
		if fid != 0:
			return fid
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
		var id := _hostile_at(my_tile + d, attacker)
		if id != 0:
			return id
	return 0


## The living entity id on `tile` if it is HOSTILE to `attacker`, else 0 (v0.20.0 ability targeting helper).
func _hostile_at(tile: Vector2i, attacker: Node) -> int:
	var id: int = _move_referee.entity_at(tile)
	if id == _NO_ENTITY or not is_alive(id):
		return 0
	var occ := _node_of_id(id)
	if occ != null and attacker != null and attacker.is_hostile_to(occ):
		return id
	return 0


## Host-side stat accessors, read by MoveReferee for a bump/AoO so combat numbers live in ONE place
## (this referee). BASE + WIELDER MODIFIER (v0.19.0, DESIGN §2.3.7): the equipped weapon supplies the
## base damage and the wielder adds a signed bonus on top (floored at 0), so the SAME weapon hits for
## different amounts in different hands. A weaponless Player still reads melee_damage (vestigial fallback
## — a player always has a weapon); a weaponless Monster deals 0 (unarmed is a future natural-weapon, not
## a fallback). Duck-typed across the two entity kinds.
func damage_of(node: Node) -> int:
	# Weapon base + wielder bonus (v0.19.0), floored at 0. The passive modify_damage chain still runs
	# AFTER this in apply_damage (layering: weapon base → flat wielder bonus → conditional passive layer).
	if node is Entity and node.equipped_weapon != null:
		return maxi(0, node.equipped_weapon.damage + _bonus_damage_of(node))
	if node is Player:
		return node.melee_damage
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
	# STUNNED (v0.20.0): can't START a new action while stunned — reject BEFORE the busy check (never touches
	# the busy record, so an in-flight action still completes; §2.1). Distinct reason → the §2.2.8 bonk.
	if is_stunned(sender_peer_id):
		return { "ok": false, "reason": "stunned" }
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
		tags: Array = [], verb: String = "") -> Dictionary:
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
	# Ability verb (v0.20.0): a kind "ability" hit rides its class-authored verb ("bashes"/"kicks") so game_log
	# renders "%s <verb> %s"; present-only, so no other kind's dict changes.
	if verb != "":
		data["verb"] = verb
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
	# EXCLUDE "ability" too (v0.20.0): a shield bash / kick is not a weapon swing, so it stamps no weapon field
	# (no longsword rig arc over a bash) — the attacker's lunge in _handle_attack_event is its melee cue.
	if attacker is Entity and attacker.equipped_weapon != null and kind != "kick" and kind != "ability":
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
	# Capture the authoritative death tile + node BEFORE clear_entity erases occupancy (the drop needs the
	# tile, and the node is still valid — queue_free is deferred to end-of-frame). Read the tile from the
	# MOVE referee (authoritative), never the node's presentation `tile`.
	var death_tile: Vector2i = _move_referee.tile_of_entity(entity_id)
	var node := _node_of_id(entity_id)
	_hp.erase(entity_id)
	# Clear any stun (v0.20.0) so a same-id respawn isn't born stunned; the node frees, taking its icon.
	_stunned.erase(entity_id)
	_stun_gen.erase(entity_id)
	_move_referee.clear_entity(entity_id)
	NetEvents.post_event("died", { "entity_id": entity_id, "name": ent_name })
	if node != null:
		_drop_weapon_of(node, death_tile)
		node.queue_free()


## Drop a dead MONSTER's equipped weapon as a ground item on its death tile (v0.19.x loot). Host-only, called
## from _kill_entity while the node is still valid. MONSTERS ONLY (Jeff: "every enemy drops the weapon it was
## using") — a fallen player keeps its gear on the corpse for now. A weaponless monster (the training dummy)
## and an unset drop hook (clients — this whole referee is inert there) drop nothing. Placement: try the death
## tile first (its occupancy guard is ITEM-occupancy — a corpse is not an item, so the tile is normally free);
## if an item already lies there, fall back to the nearest walkable neighbour so loot never silently vanishes.
func _drop_weapon_of(node: Node, tile: Vector2i) -> void:
	if not (node is Monster) or node.equipped_weapon == null or not _drop_item.is_valid():
		return
	var path: String = node.equipped_weapon.resource_path
	if _drop_item.call(tile, path):
		return
	# Death tile was item-occupied (the only realistic false for a live weapon's always-existing path) — probe
	# the 8 neighbours; _spawn_item_at re-checks walkable + occupancy, so a wall/occupied neighbour just fails on.
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
		if _drop_item.call(tile + d, path):
			return


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
		# Stun cleanup (v0.20.0), same as HP/god — a disconnect / despawn / F5 respawn starts unstunned.
		_stunned.erase(node.entity_id)
		_stun_gen.erase(node.entity_id)


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


## The wind-up telegraph duration for a node (seconds): the equipped weapon's BASE windup plus the
## wielder's MELEE windup bonus (v0.19.0), stamped at the ATTACKER's resolved pace (PaceReferee §2.8.7 —
## an engaged monster telegraphs at the tactical beat). The bonus is melee-only (skipped for a ranged
## weapon, whose windup_beats is its DRAW — wielder beat-bonuses must never retune the bow), floored at 0.
## A weaponless node has no windup (0) — unarmed is a future natural-weapon, not a fallback.
func _windup_duration_of(node: Node) -> float:
	if node is Entity and node.equipped_weapon != null:
		var w: WeaponType = node.equipped_weapon
		var bonus := 0.0 if w.range_tiles > 0 else _bonus_windup_beats_of(node)
		return maxf(0.0, w.windup_beats + bonus) * _pace_beat_sec(node)
	return 0.0


## The attacker node's resolved beat (seconds) at stamp time — tactical or explore per PaceReferee
## (§2.8.7), keyed by the node's entity_id. Keeps the `node is Entity` guard HERE (combat's duration
## accessors take the resolved attacker node, not an id) and delegates the null-resolver → explore
## fallback to the shared PaceReferee.beat_or_explore policy site; a non-Entity node reads explore.
func _pace_beat_sec(node: Node) -> float:
	if node is Entity:
		return PaceReferee.beat_or_explore(_pace, node.entity_id)
	return GameManager.explore_beat_sec


## The attacker's recovery tail (seconds): the equipped weapon's BASE recovery (attack_beats — its whole
## occupied window, Part 4 Q9) plus the wielder's MELEE recovery bonus (v0.19.0), stamped at the ATTACKER's
## resolved pace (§2.8.7: an engaged attacker recovers at the tactical beat; a player's bump tail stamps
## tactical because _begin_bump armed the forcing window first). Bonus is melee-only + floored at 0. A
## weaponless Player keeps attack_recovery_beats (vestigial fallback); a weaponless Monster has 0. The one
## conversion for a bump tail (bump_duration_of) and an instant strike's busy (wind_up).
func _recovery_duration_of(node: Node) -> float:
	if node is Entity and node.equipped_weapon != null:
		var w: WeaponType = node.equipped_weapon
		var bonus := 0.0 if w.range_tiles > 0 else _bonus_recovery_beats_of(node)
		return maxf(0.0, w.attack_beats + bonus) * _pace_beat_sec(node)
	if node is Player:
		return node.attack_recovery_beats * _pace_beat_sec(node)
	return 0.0


## Wielder DAMAGE bonus (v0.19.0 base+modifier): a Player's own bonus_damage (the future strength-stat
## hook, 0 today) or a Monster's authored MonsterType.bonus_damage. Read from the SOURCE (not a cached
## node field) so the /m and /class live-tuning knobs keep working. Anything else / missing type reads 0.
func _bonus_damage_of(node: Node) -> int:
	if node is Player:
		return node.bonus_damage
	if node is Monster and node.monster_type != null:
		return node.monster_type.bonus_damage
	return 0


## Wielder MELEE windup bonus in BEATS (v0.19.0): monsters only (MonsterType.bonus_windup_beats) — a player
## never slows its own weapon. Callers gate this to melee (range_tiles == 0). Missing type / non-monster → 0.
func _bonus_windup_beats_of(node: Node) -> float:
	if node is Monster and node.monster_type != null:
		return node.monster_type.bonus_windup_beats
	return 0.0


## Resolved MELEE windup in BEATS for a would-be bump attacker (v0.19.2): the equipped weapon's base windup +
## the wielder's melee windup bonus, floored at 0 — but ONLY for a MELEE weapon (range_tiles == 0). A ranged
## weapon's point-blank bump is a KICK, never a telegraph, so it returns 0. MoveReferee reads this to decide
## whether a player's bump routes through the telegraphed wind_up path (> 0) or stays the instant strike (0 =
## today's default for every weapon). Read HOST-side; the wire is never trusted.
func melee_windup_beats_of(node: Node) -> float:
	if not (node is Entity) or node.equipped_weapon == null:
		return 0.0
	var w: WeaponType = node.equipped_weapon
	if w.range_tiles > 0:
		return 0.0
	return maxf(0.0, w.windup_beats + _bonus_windup_beats_of(node))


## Wielder MELEE recovery bonus in BEATS (v0.19.0): monsters only (MonsterType.bonus_recovery_beats). Melee-
## gated by the caller. Missing type / non-monster → 0.
func _bonus_recovery_beats_of(node: Node) -> float:
	if node is Monster and node.monster_type != null:
		return node.monster_type.bonus_recovery_beats
	return 0.0
