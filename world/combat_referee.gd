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

# ── CONDITIONS (v0.34.0) — the GENERIC status registry, with ROOTED as its first tenant ─────────────
#
# entity id -> { condition name -> the generation that armed it }. Presence of a name IS the condition;
# the stored generation is what the expiry timer proves itself against. Host-only authority, exactly like
# _stunned above (this referee is inert on clients, and only apply_condition / clear_condition write here).
#
# WHY A REGISTRY AND NOT A SECOND BESPOKE PAIR OF DICTS: the stun's shape — latch, generation, stamped
# broadcast, generation-guarded expiry — is provably right, but it is hand-written per status. ROOTED is
# the second status, slow / poison / shield are the envisioned rest (DESIGN §2.11), and three more copies
# of that shape is three more places to get the generation guard subtly wrong. So the shape is written
# ONCE, keyed by name.
#
# STUN IS DELIBERATELY NOT MIGRATED. It works, it is load-bearing in every validator and both brains, and
# its INTERRUPT half (the sanctioned §2.1 exception) has no analogue here — a rooted entity's in-flight
# action plays out untouched. Migrating it is future work with its own verification, not a free rider on
# this one. Until then the two systems coexist: `is_stunned` reads _stunned, `is_rooted` reads _conditions,
# and both post the SAME status_applied / status_expired event names so every peer's cue plumbing is shared.
var _conditions: Dictionary = {}
# entity id -> { condition name -> MONOTONIC counter }. Bumped on every apply_condition and — unlike
# _conditions — NEVER erased, not on expiry, not on clear, not at death/teardown.
#
# THAT IS THE POINT, and it is where this differs from _stun_gen. A generation only guards a timer if a
# LATER apply cannot reuse an EARLIER apply's number. _stun_gen is erased at expiry and at teardown, so a
# re-stun after an expiry (or on a respawned peer id) starts from 1 again — and a still-pending timer from
# the previous stun would then match and clear the new one early. Stun gets away with it because nothing
# clears a stun early. A condition CAN be cleared early (break-on-damage, Shadow Step), so the counter has
# to outlive its entry. Cost: one small int per (entity, condition) ever applied, for the session.
var _condition_gen: Dictionary = {}

# PENDING SMITES (v0.22.0, weighted utility AI): the set of GROUND TILES with a smite already committed and
# still in flight (tile -> true). Set at smite_cast, erased at the TOP of _resolve_smite (before every early
# return, so a caster killed or stunned mid-cast still releases its tile) and cleared by reset_round().
# WHY TILE-KEYED, not caster- or victim-keyed: _resolve_smite damages whatever LIVING hostile occupies the
# tile at resolution — a smite is a ground hazard, not a homing missile. Keying by tile means two casters
# never root themselves in long telegraphs aimed at the same square (the thing this exists to prevent),
# while a player who dodges OFF a doomed tile is still fully re-smiteable at their NEW tile, which is the
# legitimate follow-up an entity-keyed set would wrongly block. Read by the utility scorer's smite candidate
# (through has_pending_smite_at) and by pick_smite_tile, which skips already-doomed tiles outright.
var _pending_smites: Dictionary = {}

# SHIELD BLOCK (v0.26.0 instants experiment, DESIGN §2.11.1): entity id -> the ActiveAbility resource whose
# guard is currently RAISED. Presence IS the blocking state; the value is stored (rather than a bare `true`)
# because the consumption site — inside apply_damage — has to know WHICH ability to charge the cooldown
# against, and the ability is the cooldown key. Host-only truth, never trusted from the wire: only the
# use_ability validator writes it, and that runs host-side.
#
# LIFETIME: raised by _use_shield_block, erased the instant it ABSORBS a hit (one-shot — there is no timed
# expiry, deliberately: the guard is a decision you spend, not a window you wait out), and torn down with the
# entity's other per-entity state on death / container exit. Empty forever while the experiment toggle is off
# (nothing can raise a guard), which is what makes the consumption branch inert.
var _blocking: Dictionary = {}
# INSTANT-ABILITY COOLDOWNS (v0.26.0 experiment): entity id -> { ability display_name -> ready-at msec }.
# The Part 4 Q9 suspension made concrete — a second timer beside the occupied window, which is exactly what
# Q9 forbids for a normal ability and exactly what an instant needs, since it HAS no occupied window to pay
# with. Wall-clock msec (Time.get_ticks_msec), stamped from the ability's beats × the user's resolved pace at
# the moment the cost is incurred, so the number bakes the tempo it was charged at (stamp-and-bake, §2.8.2).
# Nested per entity so the death/exit teardown is one erase. Host-only; a client never reads a cooldown.
var _ability_ready_at_msec: Dictionary = {}

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

# ARMOR-BAND WARNING LATCH (v0.27.1): band ordinal -> true, for every band that reached _armor_flat_of's
# fall-through. Armor is resolved on EVERY physical hit, so an un-armed band would otherwise push a warning
# per swing and drown the log; warning once per distinct band keeps the signal loud and the volume finite.
var _warned_armor_bands: Dictionary = {}

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


## Current HP for an entity, or 0 for an untracked/dead id (v0.22.0, the utility AI's ally scan). Public
## read beside is_alive: the scorer needs the NUMBER, not just liveness, to price its quadratic heal curve.
## The brain's scan is monster_tiles() → entity_at(tile) → id → hp_of/max_hp_of, because MoveReferee's
## occupancy answers with an entity ID, not a node — so the numbers have to be readable by id from here,
## the one place that owns them. Host-only truth, never trusted from the wire.
func hp_of(entity_id: int) -> int:
	return int(_hp.get(entity_id, 0))


## The authored MAXIMUM HP for an entity id (v0.22.0), or 0 if the node is gone. Thin id→node wrapper over
## the existing _max_hp_of so the brain can compute an ally's hp FRACTION without a node reference. Pairs
## with hp_of above; a 0 return means "unknown" and the caller must not divide by it.
func max_hp_of(entity_id: int) -> int:
	return _max_hp_of(_node_of_id(entity_id))


## Does this entity id belong to a BRAINED monster (v0.22.0)? The utility AI's "do I have backup?" and
## injured-ally scans must exclude the training dummy (has_brain=false) — a prop with HP is not a
## comrade-in-arms and was already a heal magnet once (the v0.19.10 pick_heal_target fix). Same predicate,
## exposed by id for the brain, which has no container reference of its own. A player id, a missing node
## or a monster with no MonsterType all read false.
func has_brain_of(entity_id: int) -> bool:
	var node := _node_of_id(entity_id)
	if not (node is Monster):
		return false
	return node.monster_type != null and node.monster_type.has_brain


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


# ── Conditions (v0.34.0, the generic status registry — see _conditions) ───────────────────────────────

## Apply a named CONDITION to a target for `beats`, host-authoritative. Mirrors apply_stun step for step —
## alive gate, non-positive-beats gate, seconds stamped at the TARGET's resolved pace (stamp-and-bake §2.8.2,
## so it scales with tempo and a later tempo change never re-derives a window already running), latch,
## generation bump, a `status_applied` broadcast carrying the window, and a generation-guarded expiry timer.
##
## RE-APPLICATION IS A REFRESH, not a stack and not a no-op: the generation bump invalidates the previous
## timer and the NEW duration wins outright. Two druids rooting one goblin therefore means the LATER root's
## clock, which is the stun's exact behavior and the only one that can't be gamed (stacking would let two
## casters chain a permanent lock; ignoring the second would make the second cast a wasted commitment).
##
## Does NOT interrupt anything. The target's in-flight committed action plays out (§2.1); a condition only
## gates what its OWN validators gate — rooted blocks starting a GLIDE and nothing else.
## A 0/negative `beats` and a dead/untracked target are both no-ops.
func apply_condition(target_id: int, name: String, beats: float) -> void:
	if not is_alive(target_id):
		return
	if beats <= 0.0:
		return
	var duration_sec := beats * PaceReferee.beat_or_explore(_pace, target_id)
	var gens: Dictionary = _condition_gen.get(target_id, {})
	var gen: int = int(gens.get(name, 0)) + 1
	gens[name] = gen
	_condition_gen[target_id] = gens
	var active: Dictionary = _conditions.get(target_id, {})
	active[name] = gen
	_conditions[target_id] = active
	# Same event NAME and same field shape the stun broadcasts (host-authored, peer 0 — an outcome, like
	# `died`): `name` is the ENTITY's display name for the log line, `status` is the condition. duration_sec
	# holds every peer's overhead cue for exactly the window the host stamped.
	NetEvents.post_event("status_applied", {
		"entity_id": target_id,
		"name": _name_of(_node_of_id(target_id)),
		"status": name,
		"duration_sec": duration_sec,
	})
	get_tree().create_timer(duration_sec).timeout.connect(_expire_condition.bind(target_id, name, gen))


## Does this entity currently carry `name`? The one presence predicate; an untracked id reads false.
## Host-only truth, never trusted from the wire.
func has_condition(entity_id: int, name: String) -> bool:
	return (_conditions.get(entity_id, {}) as Dictionary).has(name)


## Is this entity ROOTED (v0.34.0)? The NAMED predicate every validator and brain reads, so the string
## "rooted" appears in adjudication code exactly once — here. Rooted = cannot START a glide; attacks, casts,
## abilities and item use are all untouched (the condition fights back, Jon+Jeff's ruling).
func is_rooted(entity_id: int) -> bool:
	return has_condition(entity_id, "rooted")


## END a condition EARLY (host-only) — the break path, used by break-on-damage and by forced movement.
## Posts the same `status_expired` a natural expiry does, so every peer's cue teardown is one code path and
## "released early" needs no event of its own. Absent condition = a clean no-op (idempotent by design: the
## callers are damage and teleport, both of which fire constantly on un-conditioned entities).
##
## Does NOT bump the generation, deliberately: the pending expiry timer already fails its lookup once the
## entry is gone, and the monotonic counter (see _condition_gen) guarantees a fresh apply outranks it anyway.
func clear_condition(entity_id: int, name: String) -> void:
	var active: Dictionary = _conditions.get(entity_id, {})
	if not active.has(name):
		return
	active.erase(name)
	if active.is_empty():
		_conditions.erase(entity_id)
	NetEvents.post_event("status_expired", {
		"entity_id": entity_id,
		"name": _name_of(_node_of_id(entity_id)),
		"status": name,
	})


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
	# SHIELD BLOCK CONSUMPTION (v0.26.0 instants experiment, DESIGN §2.11.1). Insertion point is pinned:
	# AFTER the god check (a godded target returned already and must NEVER spend its block on a hit that was
	# a no-op anyway) and AFTER the forcing-window arm (a blocked swing is still a hostile action — the
	# attacker committed and connected, so it stays tactical), but BEFORE the passive chain / armor / HP
	# write, all of which this returns in front of: a blocked blow is negated WHOLE, so there is no amount
	# left for a backstab to multiply or plate to shave.
	#
	# NEGATES ANY DAMAGE KIND — bump, kick, free, windup, strike, arrow, ability, AND smite (flagged for
	# Jeff: a magic ground-spell being shield-blockable is a real design call, not an accident) — with ONE
	# exemption: "admin". The dev pokes (/mi hp, /mi kill) must stay exact or the tuning tools lie, so a
	# blocking knight still dies to `/mi <id> kill`. Same exemption list shape as _is_physical_kind's, but
	# deliberately NOT that predicate: armor's exemptions are about physicality, this one is about authority.
	#
	# NOT gated on instant_abilities_enabled, on purpose: _blocking can only be non-empty if the toggle was
	# on when the guard went up, so the branch is unreachable in an experiment-off session. Gating it would
	# instead strand a raised guard (a permanently un-consumable dict entry) if the toggle flipped mid-block
	# — and honouring the already-committed block is the Commitment-Rule-correct reading anyway.
	if kind != "admin" and _blocking.has(target_id):
		var block_ability: ActiveAbility = _blocking[target_id]
		_blocking.erase(target_id)
		# COOLDOWN STARTS ON CONSUMPTION (not on the raise): holding a guard is free, spending it is what costs.
		# v0.27.0: the beats come from the ABILITY resource (`cooldown_beats`, shield_block.tres 30) — the
		# GameConfig dial this used to read is gone. _blocking stores the ability object precisely so this
		# site can reach it.
		var block_cooldown_sec := _stamp_cooldown(target_id, block_ability)
		# The blow still gets an `attack` event — §2.3.4 forbids a silent negation. Reuses the ONE attack-dict
		# builder with damage 0, hp UNCHANGED and a present-only `blocked` flag (the `godded` pattern exactly),
		# so every other kind's payload is byte-identical and clients render "turned aside", never "missed".
		# duration_sec rides through untouched: the ATTACKER's recovery is its own commitment, not the victim's.
		var blocked_data := _build_attack_data(attacker, attacker_id, target, target_id, 0,
				int(_hp[target_id]), kind, duration_sec, false, [], verb, true)
		NetEvents.post_event("attack", blocked_data, attacker_id)
		# Drop the overhead shield on every peer, then hand the HUD the cooldown it just incurred. Two events,
		# because they are two facts: the guard is gone (world state) and a socket is now dark (own-player UI).
		NetEvents.post_event("status_expired", { "entity_id": target_id, "status": "block" })
		NetEvents.post_event("ability_cooldown", {
			"entity_id": target_id,
			"ability": block_ability.display_name,
			"cooldown_sec": block_cooldown_sec,
		})
		return false
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
	# ARMOR MITIGATION (v0.26.0 phase 1; TWO-TERM + FLOOR since v0.27.0, Jeff's second verdict). Placed
	# AFTER the attacker's passive chain and BEFORE the HP subtraction — the attacker's bonuses price the
	# blow, then the DEFENDER's armor turns part of it aside, which is the only order where a
	# sneak-then-armor and an armor-then-sneak can't disagree. PHYSICAL only (_is_physical_kind): a smite
	# is magical and an "admin" poke must stay exact (/mi kill against an armored knight has to kill).
	# Every value is read LIVE off the defender each hit (never cached at spawn), so an equip or a /class
	# retunes the very next blow.
	#
	# PLAYERS get BOTH TERMS, min-combined: the PERCENT path (round HALF-UP, so a 5-damage hit at 0.25
	# reads as 4 taken, not 3 — the player-facing number a designer tunes against) and a FLAT path from
	# the worn item's weight band (GameConfig.armor_flat_reduction_*). Whichever leaves the defender
	# taking LESS wins. Why both: a percentage does nothing against SMALL hits (25% of 2 rounds back to
	# 2), which is exactly where Jeff expected plate to matter, while a pure flat rule would trivialize
	# big ones. UNARMORED is a genuine no-op on both terms (0% and flat 0), so the absence of armor can
	# never itself mitigate.
	#
	# Then the MONSTER-DAMAGE FLOOR: a monster's hit on a player never lands for 0. Jeff's worked example
	# is 2 damage vs chainmail — pct 2, flat 0, so the min is 0, and an enemy that cannot hurt you is a
	# broken fight. Gated on attacker_id < 0 and target_id > 0 (monster → player) so it can never turn a
	# player's own armor-shaved hit on a MONSTER into a phantom point, and on amount > 0 so a genuinely
	# zero-damage source stays zero.
	#
	# MONSTER defenders keep the plain percent path — no weight band and no flat table exists for them
	# (MonsterType carries only the fraction), and inventing one here would be balance by accident.
	# The "armor" tag rides the attack event ONLY when the number actually changed, so mitigation is
	# visible rather than a silent nerf (feedback rule §2.3.4).
	#
	# ABSORBED (v0.27.1): the number of points the seam actually turned aside (incoming − final), stamped
	# on the event beside the tag so the mitigation is a VISIBLE NUMBER and not just a colour. §2.3.8 has
	# always claimed armor is visible per §2.3.4; before this the tag had no consumer at all, so a
	# chainmail knight taking a shaved club swing saw a plain "-1" identical to an unarmored one.
	var absorbed := 0
	if _is_physical_kind(kind) and amount > 0:
		var reduction := _phys_reduction_of(target)
		if target is Player:
			var pct_result := maxi(0, int(floor(amount * (1.0 - reduction) + 0.5)))
			var flat_result := maxi(0, amount - _armor_flat_of(_armor_weight_of(target)))
			var final_amount := mini(pct_result, flat_result)
			if attacker_id < 0 and target_id > 0:
				final_amount = maxi(1, final_amount)
			if final_amount != amount:
				absorbed = amount - final_amount
				amount = final_amount
				tags.append("armor")
		elif reduction > 0.0:
			var reduced := maxi(0, int(floor(amount * (1.0 - reduction) + 0.5)))
			if reduced != amount:
				absorbed = amount - reduced
				amount = reduced
				tags.append("armor")
	var new_hp: int = maxi(0, int(_hp[target_id]) - amount)
	_hp[target_id] = new_hp
	var target_name := _name_of(target)
	# Author the hit on the shared pipe (as_peer = attacker, positive for a player or negative for a
	# monster — negative ids are fine on the wire). Posted BEFORE any `died` so hp_after 0 lands first.
	# `tags` rides the event only when non-empty (see _build_attack_data), so a plain hit is unchanged.
	var attack_data := _build_attack_data(attacker, attacker_id, target, target_id, amount, new_hp, kind, duration_sec, false, tags, verb, false, absorbed)
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
	# BREAK-ON-DAMAGE (v0.34.0 conditions, GameConfig.root_breaks_on_damage — ships OFF). A hit that actually
	# dealt damage frees a rooted SURVIVOR. Placed HERE, on the survivor path, for two reasons: a lethal blow
	# already tore the whole condition map down in _kill_entity (a status_expired for a corpse is noise), and
	# sitting AFTER the `attack` post means the release lands immediately behind the hit that caused it in the
	# one ordered stream — which is exactly how it reads on screen and how a trace asserts it.
	# clear_condition's own status_expired IS the "released early" cue; there is no second event shape.
	# The `amount > 0` term is what makes a 0-damage landed hit (a kick, a fully-absorbed swing) leave the
	# root standing — the dial says damage breaks it, not contact.
	if GameManager.config.root_breaks_on_damage and amount > 0:
		clear_condition(target_id, "rooted")
	# Damage is an AGGRO SOURCE (v0.17.2 review fix): a SURVIVING Monster that just took a hit wakes its
	# brain, so a ranged arrow from beyond aggro_range_tiles aggros it (no free sniping). Placed AFTER the
	# lethal path above so a KILLING blow never notifies (dead monsters don't aggro), and after the godded
	# early-return (a no-op hit on an invulnerable target aggros nothing). Host-only by construction —
	# apply_damage only runs on the host. is_alive re-confirms the target survived (belt-and-suspenders with
	# the died branch). A Player target is skipped (only monsters have a brain to wake).
	if target is Monster and is_alive(target_id):
		target.notify_attacked()
	# FRIENDLY FIRE BANTER (v0.35.0, Jon) — one goblin just hurt another. Sits at the very tail, after the
	# `attack` event is out and after the aggro wake, so the exchange lands BEHIND the hit that caused it in
	# the one ordered stream: you see the arrow connect, then hear about it.
	#
	# Deliberately hooked HERE rather than in _arrow_step, even though the archer's stray arrow is the only
	# source today: apply_damage is where every damage kind converges, so a future stray AoE or a thrown
	# weapon inherits the joke without a second hook — and the "am I hitting my own side?" question is
	# answered once, by _is_hostile_pair, the same predicate the lane check trusts.
	#
	# The four terms, each earning its place: BOTH monsters (players have their own voices, and a monster
	# hurting a PLAYER is just combat); not self-inflicted (a monster standing in its own smite is a
	# different joke and has no one to blame); the victim SURVIVED (this is on the survivor path — a
	# corpse doesn't complain, and the death already fires ally_died, which is the better line for it);
	# and amount > 0, so a fully-absorbed graze that nobody felt stays silent.
	if attacker is Monster and target is Monster and attacker_id != target_id \
			and amount > 0 and not _is_hostile_pair(attacker_id, target_id):
		Banter.bark_friendly_fire(get_tree(),
				target_id, _name_of(target), _move_referee.tile_of_entity(target_id),
				attacker_id, _name_of(attacker), _move_referee.tile_of_entity(attacker_id))
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
	# The INTENDED victim (v0.24.8 sticky swing): whoever stands on the committed tile NOW. Threaded
	# through to _resolve_windup so a sidestep that stays adjacent to the attacker can still be caught
	# (swing_catches_adjacent). _NO_ENTITY for a ground-aimed windup — pure tile commitment then.
	var intended_id: int = _move_referee.entity_at(target_tile)
	fire_before_attack(attacker_id, intended_id, "windup")
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
		_resolve_windup(attacker_id, target_tile, "strike", recovery_sec, intended_id)
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
	# NOTE (v0.28.0): the `windup` EVENT below is UNCHANGED and still required. Jeff's third batch deleted
	# only the combat-LOG line for it (ui/game_log/game_log.gd's "windup" arm) — the event still drives the
	# coil, the white flash, the telegraph sound and the weapon rig's raised pose on every peer, and the bow
	# path (_validate_shoot) posts it too. Do not delete it thinking the telegraph went away; it went QUIET.
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
	# interrupt_gen captured AT COMMIT (v0.26.0): an attacker forcibly MOVED during this telegraph (today only
	# a player's Shadow Step, but the same door serves any future knockback) lands nothing at windup end.
	get_tree().create_timer(windup_sec).timeout.connect(
			_resolve_windup.bind(attacker_id, target_tile, "windup", recovery_sec, intended_id,
					_move_referee.interrupt_gen_of(attacker_id)))
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
##
## No recovery release here (v0.26.0 recovery-on-contact): a heal ALWAYS "contacts" — it commits to an ALLY,
## not to ground, so there is no whiff outcome to release on. The healer keeps its full cast + recovery record.
func _resolve_heal_cast(caster_id: int, target_id: int, amount: int) -> void:
	if not is_alive(caster_id):
		return
	# INTERRUPT (v0.20.2): a healer stunned mid-cast heals nothing — stunning the shaman mid-channel cancels it.
	# No forced-movement (interrupt_gen) guard, for the same reason as _resolve_smite: only players blink and
	# only monsters heal-cast, so nothing reaching this resolve is teleportable (v0.26.0).
	if is_stunned(caster_id):
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
		# Already doomed (v0.22.0): another caster has a smite in flight at this exact tile. Skip it, so a
		# second shaman spends its telegraph somewhere useful instead of stacking two casts on one square
		# (the first one's resolution damages whoever is standing there anyway). With every in-range player
		# already targeted the list empties and the caller reads the no-target sentinel — correct: there is
		# genuinely nothing new worth committing to.
		if _pending_smites.has(tile):
			continue
		var cheb := maxi(absi(tile.x - caster_tile.x), absi(tile.y - caster_tile.y))
		if cheb <= range_tiles:
			in_range.append(tile)
	if in_range.is_empty():
		return Vector2i.ZERO  # (0,0) is always a border wall → a safe "no target" sentinel
	return in_range[randi() % in_range.size()]


## Is a smite ALREADY committed and in flight at this ground tile (v0.22.0)? The public read over the
## pending-smite set, used by the utility scorer's smite candidate so a second caster scores 0 for a square
## that is already doomed rather than burning its own telegraph on it. Mirrors is_alive's shape (an
## untracked tile reads false). Host-only truth — this whole referee is inert on clients.
func has_pending_smite_at(tile: Vector2i) -> bool:
	return _pending_smites.has(tile)


## PACK RALLY (v0.22.0, Jon's directive): one monster entering combat drags its neighbours in with it —
## "all the other goblins in there attack". Called HOST-side by a MonsterBrain the moment it latches aggro
## ORGANICALLY (proximity acquire, or being attacked), never on a rally-induced latch. Every LIVING, BRAINED
## allied monster the shout REACHES is told through Monster.notify_rallied() -> MonsterBrain.notify_rallied(),
## the same relay shape notify_attacked uses.
##
## v0.30.0 — IT IS A SOUND NOW (Jon + Jeff). `travel_tiles` is spent as a WALL-BOUNDED FLOOD FILL over open
## floor (WorldGrid.tiles_within_travel), not as a Chebyshev radius, and the number is one GLOBAL dial
## (GameConfig.rally_travel_tiles) instead of the shouter's own tactical bubble. The old radius was wrong in
## both directions at once: wall-blind, so a shout carried through solid rock into the next room, and only 3-5
## tiles wide, so the back rows of a big room never joined the fight they were standing in. The model is now
## "can the sound get there" — walls bound it, a doorway carries it. Two consequences worth stating plainly:
##  - A SHOUT LEAKS A FEW TRAVEL-TILES THROUGH AN OPEN DOORWAY, and that is INTENDED emergence — a goblin
##    wandering just outside hears the scuffle. Over-pull is answered by turning the dial down, not by adding
##    a room test.
##  - In open floor a travel tile IS a king-step (the fill uses the A* grid's corner rule), so the number
##    reads exactly like the old radius did; it only ever takes tiles away, never adds surprising ones.
##
## ONE HOP BY CONSTRUCTION, unchanged and independent of the dial: notify_rallied latches aggro but never calls
## back here, so a generous travel number widens ONE fill and can never chain-react the map awake. An
## already-aggroed brain ignores the rally entirely (it is already fighting), which also makes a rally cheap
## and idempotent. One hop + a generous wall-bounded shout is the whole design: it wakes a room, not a map.
##
## Allies = every OTHER monster (v1's only factions are players-vs-monsters, matching Monster.is_hostile_to).
## Tiles are read from the MOVE referee (authoritative occupancy), never a rendered position — and note that
## the fill itself ignores occupancy (bodies do not block sound), so a crowded corridor still carries it.
## A 0/negative `travel_tiles` (the dial's "off" setting) shouts to nobody.
##
## ONE BFS, N LOOKUPS: the fill runs once before the loop and each candidate costs a Dictionary probe — never a
## path query per ally.
func rally_pack(rallier_id: int, travel_tiles: int) -> void:
	if travel_tiles <= 0 or _monsters == null:
		return
	var origin: Vector2i = _move_referee.tile_of_entity(rallier_id)
	# tile_of_entity answers with the wall sentinel for an untracked id (despawned between the brain's
	# decision and here) — no live body rests on a wall, so this is the unambiguous "gone" read.
	if WorldGrid.is_wall(origin):
		return
	var heard: Dictionary = WorldGrid.tiles_within_travel(origin, travel_tiles)
	for child in _monsters.get_children():
		if not (child is Monster) or child.entity_id == rallier_id:
			continue
		if not is_alive(child.entity_id):
			continue
		# Brainless props (the training dummy) have nothing to rally — and a null type is a spawn-config bug.
		if child.monster_type == null or not child.monster_type.has_brain:
			continue
		var tile: Vector2i = _move_referee.tile_of_entity(child.entity_id)
		# Membership IS the reach test: a tile absent from the fill is either too far to travel or walled off
		# from the shout entirely. (A despawned ally's wall-sentinel tile is never in the fill, so it also
		# fails closed here without a separate guard.)
		if not heard.has(tile):
			continue
		child.notify_rallied()


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
	# Mark the ground DOOMED for the length of the cast (v0.22.0). Recorded only AFTER the commit succeeded,
	# so a declined cast never leaves a phantom entry; _resolve_smite erases it before every one of its exit
	# paths, so the tile is released even when the caster dies or is stunned mid-channel.
	_pending_smites[target_tile] = true
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


## Clear a CONDITION at its window's end (host-only, from the expiry timer), GENERATION-guarded (v0.34.0):
## only the timer whose captured generation still matches the live entry clears it, so a REFRESH (which
## bumped the generation and re-armed) is never cut short by the earlier application's timer. An entry
## already gone — expired, cleared early, or torn down with the entity — fails the lookup and no-ops.
##
## The `name` field on the broadcast is the ENTITY's display name, present so the game log can compose a
## release sentence ("The roots release Goblin.") without a lookup. The STUN's expiry deliberately stays
## two-field: it has no log line at all, and widening it would be churn for nothing.
func _expire_condition(entity_id: int, name: String, gen: int) -> void:
	var active: Dictionary = _conditions.get(entity_id, {})
	if int(active.get(name, -1)) != gen:
		return
	active.erase(name)
	if active.is_empty():
		_conditions.erase(entity_id)
	NetEvents.post_event("status_expired", {
		"entity_id": entity_id,
		"name": _name_of(_node_of_id(entity_id)),
		"status": name,
	})


func _resolve_smite(caster_id: int, target_tile: Vector2i, damage: int, recovery_sec: float) -> void:
	# Release the doomed tile FIRST, above every early return (v0.22.0): a cast that fizzles because its
	# caster died or was stunned mid-channel must still free the ground, or the tile would stay permanently
	# un-targetable for the rest of the session. Erasing an absent key is a no-op, so a post-reset_round
	# straggler is harmless here.
	_pending_smites.erase(target_tile)
	if not is_alive(caster_id):
		return
	# INTERRUPT (v0.20.2): a caster stunned mid-smite deals nothing — stunning the shaman mid-cast cancels it.
	# NO forced-movement (interrupt_gen) guard here, unlike the windup/ability/arrow resolves (v0.26.0): only
	# PLAYERS can blink, and only monsters cast — so no caster this resolve can belong to is teleportable today.
	# If a monster ever gains a blink (or a knockback lands on a caster), capture the gen at smite_cast.
	if is_stunned(caster_id):
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
	# WHIFF RECOVERY IS A DIAL (v0.32.0, whiff_recovery_beats, default -1 = pay it all): the dodged cast pays
	# whatever _whiff_tail_sec says it owes and duration_sec carries exactly that, so the caster's spent tell
	# matches the window the host really holds. At 0 the dodge robs the cast of its follow-through entirely
	# (the v0.26.0 behavior); at N > 0 it keeps N beats of it and hands back the rest.
	var paid_sec := _whiff_tail_sec(caster, recovery_sec)
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
		"duration_sec": paid_sec,
	}, caster_id)
	# LAST, after the fizzle event is on the wire (same ordering rule as the other two release sites). The
	# tail was baked into the one cast+recovery record, so shortening it means finishing that record early.
	# v0.32.0, the three regimes of `whiff_recovery_beats`: FULL (the default) skips entirely and the window
	# plays out untouched; NONE releases now; PARTIAL releases at the PAID boundary the event just quoted.
	if paid_sec >= recovery_sec:
		return
	if paid_sec <= 0.0:
		if not _move_referee.finish_busy_early(caster_id):
			push_warning("[CombatReferee] smite whiff for %d posted duration_sec 0 but no in-place record was released — client/server recovery tell may disagree" % caster_id)
		return
	if not _move_referee.release_busy_after(caster_id, paid_sec):
		push_warning("[CombatReferee] smite whiff for %d posted a partial duration_sec but no in-place record was scheduled for release — client/server recovery tell may disagree" % caster_id)


# ── Active abilities (v0.20.0, the 1-5 hotbar — a player-triggered melee strike + stun) ──────

## The "use_ability" validator (host-only; registered on the shared pipe in activate()). A player submits
## use_ability {index}; the host resolves that class ability server-side and, if a hostile is adjacent, commits
## the player for the ability's occupied window (Q9: no cooldown — the beats ARE the cost) and resolves a melee
## strike that deals damage + applies a stun. Distinct §2.2.8 rejects (dead / stunned / busy / no ability /
## no target). Returns a DEFERRED accept on success — the `attack` + `status_applied` events ARE the outcome.
## v0.26.0 (instants experiment, DESIGN §2.11.1) reshapes the ENTRY ONLY: the ability is now resolved BEFORE
## the busy gate, so an INSTANT (BLOCK / BLINK) can dispatch without ever meeting a Commitment-Rule check it
## is designed to sidestep. A STRIKE falls straight through to the v0.20.0 path below with its busy gate
## intact and its behavior unchanged. The one observable side effect of the reorder is reject PRECEDENCE: a
## busy player pressing an EMPTY slot now hears "no such ability" instead of "busy" (the more accurate of the
## two anyway). The dead → stunned order in front is untouched, deliberately: **a stun blocks instants too**
## (Jon's ruling) — being stunned is the enemy's committed answer to your defensive options, so it must not be
## the one state a block or a blink can escape from.
func _validate_use_ability(sender_peer_id: int, data: Dictionary) -> Dictionary:
	if not is_alive(sender_peer_id):
		return { "ok": false, "reason": "dead" }
	if is_stunned(sender_peer_id):
		return { "ok": false, "reason": "stunned" }
	# RECOVERING gate (v0.28.0, GameConfig.recovery_locks_actions — DESIGN §2.2.10): at 0 stamina in
	# tactical pace the ACTION channel is locked, so an ability press is refused with its own distinct
	# "recovering" reason (§2.2.8 bonk + a game_log line). Mirrors the STUN gate directly above in
	# position and shape — a gate on STARTING an action, never touching the busy record, so anything
	# already committed still plays out (§2.1). MOVEMENT is NOT gated here: 0-stamina movement stays the
	# winded/crawl dials' business, so the two channels toggle independently. Sits WITH the stun gate
	# ABOVE the instant dispatch, so it blocks Shield Block / Shadow Step too — consistent with the
	# deliberate ruling that a stun blocks instants (see this function's header).
	if GameManager.config.recovery_locks_actions and _move_referee.is_recovering(sender_peer_id):
		return { "ok": false, "reason": "recovering" }
	var caster := _node_of_id(sender_peer_id)
	var ability := _ability_of(caster, int(data.get("index", -1)))
	if ability == null or not ability.is_valid_ability():
		return { "ok": false, "reason": "no such ability" }
	# TARGETED DISPATCH (v0.34.0, the druid's Entangling Roots), ABOVE the instants block on purpose: a
	# targeted cast is NOT an instant and must never be gated on `instant_abilities_enabled` (only its
	# cooldown is, inside _charge_strike_cooldown). It is a committed cast with a real occupied window, so
	# its handler re-runs the SAME remaining ladder a STRIKE does — cooldown, then busy — before it commits.
	if ability.kind == ActiveAbility.Kind.TARGETED:
		return _use_targeted(sender_peer_id, ability, data)
	# INSTANT DISPATCH (v0.26.0), ahead of the busy gate. Both handlers are fully SYNCHRONOUS — they validate
	# and execute inside this one callback with no timer and no fire delay — so neither needs an interrupt_gen
	# capture of its own: on the single-threaded host nothing can move the actor between the check and the
	# mutation. They also must never reach the STRIKE path's whiff branch (which releases a busy window and
	# wakes brains): an instant opens no window, so there is nothing there for it to release.
	if ability.kind != ActiveAbility.Kind.STRIKE:
		if not GameManager.config.instant_abilities_enabled:
			return { "ok": false, "reason": "instant abilities are disabled" }
		match ability.kind:
			ActiveAbility.Kind.BLOCK:
				return _use_shield_block(sender_peer_id, ability)
			ActiveAbility.Kind.BLINK:
				return _use_shadow_step(sender_peer_id, ability)
		# A Kind added to the enum but not to this match: fail LOUD-ish rather than silently accept.
		push_warning("[CombatReferee] use_ability: unhandled ActiveAbility.Kind %d on '%s'" % [
				ability.kind, ability.display_name])
		return { "ok": false, "reason": "no such ability" }
	# STRIKE COOLDOWN (v0.27.0, Jeff's second verdict: kick + shield bash are 40-beat abilities). Checked
	# HERE — after the instant dispatch (so the instants path above is byte-identical to v0.26.0) and
	# BEFORE the busy gate and before ANY commit — for two reasons. (1) Precedence: "on cooldown" is the
	# more informative refusal than "busy" when both are true, and it is the cheaper check. (2) Purity: no
	# state is touched by a cooldown reject, so it can never leave a window committed or a facing turned.
	# The reason string carries the remaining SECONDS, matching the instants' wording exactly, so it
	# travels the normal §2.2.8 reject pipe (bonk + sender-only log line) with no new plumbing and the
	# HUD's name-keyed cooldown overlay needs zero changes.
	#
	# SUSPENSION SCOPE: this extends §2.11.1's Part 4 Q9 suspension from the instants to STRIKES, which DO
	# already pay in occupied beats — a second timer beside a real window. Flagged in DESIGN as part of the
	# same pending Jon+Jeff verdict; an ability authored with cooldown_beats 0 behaves exactly as before.
	#
	# GATED ON THE EXPERIMENT TOGGLE (v0.27.1 fix): the strike cooldown is part of the SAME provisional
	# experiment as the instants, so `instant_abilities_enabled` off must revert it too — the changelog
	# promised Jeff "all of them switch off together" and dev-commands.md promises "the pre-v0.26 game
	# exactly". With the toggle off this check is skipped AND no stamp is taken (see
	# _charge_strike_cooldown), so kick / shield bash behave exactly as they did pre-v0.27.0 whatever
	# `cooldown_beats` is authored. `cooldown_beats 0` remains the PER-ABILITY revert while the
	# experiment is on. (A cooldown stamped before the toggle was flipped off is simply not consulted;
	# flipping back on can therefore re-expose it, the same harmless staleness a raised guard has.)
	if GameManager.config.instant_abilities_enabled:
		var strike_remaining := _cooldown_remaining_sec(sender_peer_id, ability)
		if strike_remaining > 0.0:
			return { "ok": false, "reason": "on cooldown (%.1fs)" % strike_remaining }
	if _move_referee.is_entity_moving(sender_peer_id):
		return { "ok": false, "reason": "busy" }
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
		_charge_strike_cooldown(sender_peer_id, ability)
		_resolve_ability(sender_peer_id, target_tile, ability.damage, ability.stun_beats, ability.log_verb, recovery_sec)
		return { "ok": true, "deferred": true }
	# Telegraphed (windup > 0) — commit the FULL window, resolve at windup end (dodgeable), like a monster windup.
	if not _move_referee.commit_in_place(sender_peer_id, windup_sec + recovery_sec):
		return { "ok": false, "reason": "busy" }
	_charge_strike_cooldown(sender_peer_id, ability)
	# interrupt_gen captured AT COMMIT (v0.26.0) and re-checked at fire: a caster who SHADOW-STEPPED out of
	# this telegraph never lands the strike (see _resolve_ability's guard).
	get_tree().create_timer(windup_sec).timeout.connect(
			_resolve_ability.bind(sender_peer_id, target_tile, ability.damage, ability.stun_beats,
					ability.log_verb, recovery_sec, _move_referee.interrupt_gen_of(sender_peer_id)))
	return { "ok": true, "deferred": true }


## Charge a STRIKE ability's cooldown at ACCEPT and tell the user's HUD (v0.27.0). Called from BOTH accept
## branches — instant and telegraphed — immediately after the commit succeeds, i.e. at the moment the
## decision becomes irrevocable.
##
## v0.34.0: the TARGETED cast (Entangling Roots) calls this too, unchanged. The name stays "strike" rather
## than being widened to "_charge_ability_cooldown" because every word of the contract below — spent at
## commit, gated on the experiment toggle, part of the SAME pending §2.11.1 verdict — is the STRIKE
## cooldown's contract, and a rename would cost churn across the changelog and DESIGN for no new meaning.
## Read it as "the committed-ability cooldown"; a 30-beat hard CC needs one for exactly the reason a kick does.
##
## SPENT AT COMMIT, NOT AT CONTACT, deliberately (matching the instants): a strike that whiffs, or one
## whose resolve is FIZZLED by a blink or a stun, still burns the cooldown. You spent the ability the
## instant you committed to it — refunding on a bad outcome would make the cooldown a reward for
## connecting rather than a cost of pressing, and would hand the player a free retry out of a committed
## decision. (This is distinct from v0.26.0's recovery-on-contact refund, which releases the BUSY WINDOW
## on a whiff: that is the referee shortening a commitment it owns, not returning a spent resource.)
##
## The `ability_used` event is the same {entity_id, ability, cooldown_sec} shape the instants post, and the
## HUD's overlay is name-keyed, so the ability bar darkens a strike's socket with ZERO HUD changes. Posted
## even at cooldown 0 (a uniform "an instant/strike fired" signal per press — the overlay no-ops on 0).
##
## GATED ON THE EXPERIMENT TOGGLE (v0.27.1 fix): with `instant_abilities_enabled` off this is a total
## NO-OP — no stamp, and no `ability_used` cooldown event either, so nothing anywhere behaves differently
## from pre-v0.27.0 (the checking half of the same gate lives in _validate_use_ability). The gate is HERE
## rather than at the two call sites so the "a strike cooldown only exists inside the experiment" rule has
## exactly one authoring site.
func _charge_strike_cooldown(user_id: int, ability: ActiveAbility) -> void:
	if not GameManager.config.instant_abilities_enabled:
		return
	var cooldown_sec := _stamp_cooldown(user_id, ability)
	NetEvents.post_event("ability_used", {
		"entity_id": user_id,
		"ability": ability.display_name,
		"cooldown_sec": cooldown_sec,
	}, user_id)


## Resolve an active-ability strike against its committed TILE (host-only). Caster alive-gated (killed mid-windup
## = nothing). Whoever HOSTILE + LIVING occupies the tile NOW eats `damage` (kind "ability", carrying the verb for
## the log) AND a `stun_beats` stun; a target that stepped off / died whiffs (a distinct §2.3.4 outcome). recovery_sec
## rides the hit so the caster shows its spent tell. The strike is deterministic (RF baseline) — the stun is the ability's teeth.
##
## `interrupt_gen` (v0.26.0 instants experiment) is MoveReferee's forced-movement generation captured when this
## resolve was armed; -1 means "no capture needed" — the SYNCHRONOUS instant-strike caller, which resolves inside
## the same stack as its own commit and so cannot be teleported in between.
func _resolve_ability(attacker_id: int, target_tile: Vector2i, damage: int, stun_beats: float, verb: String, recovery_sec: float,
		interrupt_gen: int = -1) -> void:
	if not is_alive(attacker_id):
		return
	# FORCED-MOVEMENT INTERRUPT (v0.26.0): the caster was teleported (Shadow Step) after committing this
	# telegraph — it is no longer standing where it wound up from, so the strike fizzles. Silent, like the stun
	# gates below: the blink WAS the visible outcome. Inert while the experiment is off (the gen never moves).
	if interrupt_gen != -1 and _move_referee.interrupt_gen_of(attacker_id) != interrupt_gen:
		return
	# INTERRUPT (v0.20.2): a caster stunned mid-windup ability deals nothing — same interrupt rule as a monster
	# windup (a telegraphed ability, windup > 0, can be interrupted by stunning its user).
	if is_stunned(attacker_id):
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
	# "<verb> hits nothing". WHIFF RECOVERY IS A DIAL (v0.32.0, whiff_recovery_beats, default -1 = pay it all):
	# the miss pays whatever _whiff_tail_sec says it owes and duration_sec carries exactly that number, so the
	# spent tell every peer plays matches the window the host really holds. At 0 the committed window is
	# released below, leaving a missed ability's user free at once; at N > 0 the remainder is handed back.
	var paid_sec := _whiff_tail_sec(attacker, recovery_sec)
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
		"duration_sec": paid_sec,
		"verb": verb,
	}, attacker_id)
	# LAST, for the same ordering reason as _resolve_windup's release: the miss event precedes any `glide_to`
	# a promoted pipelined step posts. v0.32.0, the three regimes of `whiff_recovery_beats`: FULL (the default)
	# skips entirely and the window plays out untouched; NONE releases now; PARTIAL releases at the PAID
	# boundary the event just quoted.
	if paid_sec >= recovery_sec:
		return
	if paid_sec <= 0.0:
		if not _move_referee.finish_busy_early(attacker_id):
			push_warning("[CombatReferee] ability whiff for %d posted duration_sec 0 but no in-place record was released — client/server recovery tell may disagree" % attacker_id)
		return
	if not _move_referee.release_busy_after(attacker_id, paid_sec):
		push_warning("[CombatReferee] ability whiff for %d posted a partial duration_sec but no in-place record was scheduled for release — client/server recovery tell may disagree" % attacker_id)


# ── Targeted casts (v0.34.0 — the druid's Entangling Roots; DESIGN §2.13 conditions) ─────────

## Adjudicate a TARGETED ability at a clicked TILE (host-only, from _validate_use_ability). The alive /
## stunned / recovering gates already ran in the caller; this owns the rest of the ladder in the STRIKE's
## order — cooldown, busy — then the aim checks, then the commit.
##
## TILE-KEYED, not entity-keyed, and that is the whole design (the smite's model, DESIGN §2.3.3): the cast
## commits to a SQUARE, and whoever hostile is standing on it when the channel ENDS is what gets rooted. A
## target that steps off in time dodges; a different enemy that steps on eats it. The client's cursor
## requires a hostile under it before it will fire, but that is CONVENIENCE (§2.2.9) — the wire carries a
## tile and the host adjudicates a tile, so a client that lies about what is there gains nothing.
##
## Reject reasons are player-facing SENTENCES for the aim faults ("Out of range.") and bare state tokens for
## the rest, exactly as the shoot pipe does — game_log's ability arm surfaces the sentences verbatim, which
## is what makes learning the cursor read cleanly instead of as a generic refusal.
func _use_targeted(user_id: int, ability: ActiveAbility, data: Dictionary) -> Dictionary:
	# COOLDOWN — same position, same gate, same wording as the STRIKE path above (and gated on the same
	# experiment toggle, so `instant_abilities_enabled 0` reverts this ability to "no cooldown" too). A
	# 30-beat hard CC is exactly the case Jeff's cooldown verdict was about. Pure: no state is touched.
	if GameManager.config.instant_abilities_enabled:
		var remaining := _cooldown_remaining_sec(user_id, ability)
		if remaining > 0.0:
			return { "ok": false, "reason": "on cooldown (%.1fs)" % remaining }
	# BUSY — the Commitment Rule backstop every committed action shares (is_entity_moving covers a glide AND
	# an in-place record), so a cast can never overlap or interrupt something already committed.
	if _move_referee.is_entity_moving(user_id):
		return { "ok": false, "reason": "busy" }
	# Never trust the wire: the target tile must be a real Vector2i.
	var tt = data.get("target_tile")
	if typeof(tt) != TYPE_VECTOR2I:
		return { "ok": false, "reason": "bad target" }
	var target_tile: Vector2i = tt
	# Origin from referee truth, never a node position.
	var my_tile: Vector2i = _move_referee.tile_of_entity(user_id)
	if target_tile == my_tile:
		return { "ok": false, "reason": "Can't target your own tile." }
	# RANGE: Chebyshev to the clicked tile ≤ the ability's authored reach, read server-side from the shared
	# resource (never a client value). The shoot pipe's gate, same metric, same sentence.
	var cheb := maxi(absi(target_tile.x - my_tile.x), absi(target_tile.y - my_tile.y))
	if cheb > ability.range_tiles:
		return { "ok": false, "reason": "Out of range." }
	# CREATURE MODE (v0.38.0) — resolve the clicked tile to a BODY, here, from the referee's own occupancy.
	# THE WIRE IS UNCHANGED: the client still sends only a tile, and the host does the tile→entity lookup
	# itself, so a client can never name its own target (§2.5 — never adjudicate from a client value).
	#
	# AN EMPTY (or friendly) TILE IS REFUSED, and refused BEFORE the commit above, so a misclick costs
	# nothing — no channel, no recovery, no 40-beat cooldown. That is the whole point of the mode: a spell
	# that grabs a specific enemy has no meaning aimed at bare ground, and eating the cooldown for clicking
	# dirt is exactly the "huge whiff of a cooldown" Jon asked to get rid of. It is NOT the client-side
	# filtering §2.2.9 warns against either — the host answers with a distinct sentence the sender sees
	# (§2.2.8 bonk + its own game-log line), so the click is never a silent no-op.
	var locked_id: int = _NO_ENTITY
	if ability.target_mode == ActiveAbility.TargetMode.CREATURE:
		locked_id = _move_referee.entity_at(target_tile)
		var locked := _node_of_id(locked_id)
		if locked_id == _NO_ENTITY or locked == null or not is_alive(locked_id):
			return { "ok": false, "reason": "No target there." }
		var caster_probe := _node_of_id(user_id)
		if caster_probe == null or not caster_probe.is_hostile_to(locked):
			return { "ok": false, "reason": "Not an enemy." }
	# ── Accept ──
	# Forcing window (§2.8.7): a hostile cast keeps the caster tactical, like every other offensive action.
	if _pace != null:
		_pace.report_hostile_action(user_id)
	var beat := PaceReferee.beat_or_explore(_pace, user_id)
	var cast_sec := maxf(0.0, ability.windup_beats) * beat
	var recovery_sec := maxf(0.0, ability.recovery_beats) * beat
	# ONE busy record covering channel + spent tail (the heal/smite cast shape) — the caster is rooted in
	# place for the whole thing and no input path may shorten it.
	if not _move_referee.commit_in_place(user_id, cast_sec + recovery_sec):
		return { "ok": false, "reason": "busy" }
	_move_referee.set_facing(user_id, (target_tile - my_tile).sign())
	_charge_strike_cooldown(user_id, ability)
	var caster := _node_of_id(user_id)
	# Name the CURRENT occupant. In TILE mode this is best-effort telegraph text only (the resolve re-reads
	# the square, so a dodge turns it into a fizzle); in CREATURE mode it is the body we just locked, which
	# the gate above proved is alive and hostile.
	var occ_id: int = locked_id if locked_id != _NO_ENTITY else _move_referee.entity_at(target_tile)
	var occ_name := _name_of(_node_of_id(occ_id)) if occ_id != _NO_ENTITY else ""
	# The telegraph on its OWN event (smite_cast's field shape) — a distinct channel per §2.3.4, so the
	# green control-cast can never be confused with the red smite or a white melee wind-up.
	#
	# `locked_id` RIDES THE EVENT (v0.38.0) because the two modes need DIFFERENT cues, and the cue has to
	# match the mechanic or it lies: a TILE cast paints the ground (step off it to dodge), while a CREATURE
	# cast must mark the BODY and follow it (run out of range to escape). Present-only — 0 means tile mode,
	# so nothing about the v0.34.0 event shape changed for a tile-targeted cast.
	var cast_data := {
		"caster_id": user_id,
		"caster_name": _name_of(caster),
		"target_tile": target_tile,
		"target_name": occ_name,
		"cast_sec": cast_sec,
	}
	if locked_id != _NO_ENTITY:
		cast_data["target_id"] = locked_id
	NetEvents.post_event("root_cast", cast_data, user_id)
	# interrupt_gen BOUND AT COMMIT and re-checked at fire. The smite skips this because only players blink
	# and only monsters smite; a PLAYER caster closes that documented gap — a druid shadow-stepped (or, in
	# future, knocked) out of its own channel is no longer standing where it cast from, so the roots fizzle.
	# `locked_id` and `range_tiles` are bound too (v0.38.0): the creature resolve needs to know WHO it
	# grabbed and how far the caster's reach is, and both are read from the ability HERE at commit rather
	# than re-fetched at fire — stamp-and-bake (§2.8.2), so retuning the ability mid-channel cannot change
	# a cast already in flight.
	get_tree().create_timer(cast_sec).timeout.connect(
			_resolve_targeted.bind(user_id, target_tile, ability.root_beats, recovery_sec,
					_move_referee.interrupt_gen_of(user_id), locked_id, ability.range_tiles))
	return { "ok": true, "deferred": true }


## Resolve a committed TARGETED cast at channel END against its TILE (host-only, from the cast timer).
## Fizzle conditions, all silent (the visible outcome already happened, or the caster is gone):
##  - caster dead — killed mid-cast, the rush-it counterplay (the smite/windup rule).
##  - FORCED MOVEMENT — the caster was teleported after committing (v0.26.0's interrupt generation).
##  - caster STUNNED — the sanctioned §2.1 interrupt, stun-parity with the smite and the windup ability.
## Otherwise whoever HOSTILE and LIVING occupies the tile NOW is ROOTED for `root_beats`. NO DAMAGE: the
## root IS the payload, and mixing a damage event in would make the log read as a hit.
##
## CREATURE MODE (v0.38.0) changes only WHICH TILE is asked about. When `locked_id` is a real entity the
## cast committed to a BODY, so the square the player clicked is history: we re-read that entity's CURRENT
## authoritative tile and resolve there. Everything below — hostility, liveness, the root, the aggro wake,
## the whiff tail — is then byte-identical between the two modes, which is the point of resolving the
## difference into a tile up front instead of forking the outcome logic.
##
## THE ESCAPE IS THE COUNTERPLAY (Jon's ruling). A locked target that is still alive but has left
## `range_tiles` of the caster whiffs — the tile is deliberately NOT resolved in that case, so it falls
## through to the same whiff branch a dodged tile-cast takes. A locked target that DIED mid-channel also
## whiffs, via the same liveness test the tile path already applies. So the mode does not remove the
## counterplay, it changes its shape: sidestepping stops working, running works.
func _resolve_targeted(caster_id: int, target_tile: Vector2i, root_beats: float, recovery_sec: float,
		interrupt_gen: int, locked_id: int = _NO_ENTITY, range_tiles: int = 0) -> void:
	if not is_alive(caster_id):
		return
	if _move_referee.interrupt_gen_of(caster_id) != interrupt_gen:
		return
	if is_stunned(caster_id):
		return
	var caster := _node_of_id(caster_id)
	# CREATURE: follow the body. Range is measured from the CASTER's authoritative tile (it has not moved —
	# the channel is an in-place commit, and a caster forcibly moved out of it was already caught by the
	# interrupt-gen test above) to the target's tile RIGHT NOW.
	#
	# THE LOCK IS THE ANSWER — resolve to the ENTITY, never back through its tile. An earlier cut of this
	# read the locked body's tile and then asked who was standing there, which is a round trip
	# (entity → tile → entity) that can only ever return the same answer or a WRONG one: any disagreement
	# between the occupancy map's two directions would silently root a different body or fizzle on a target
	# that was right there. A mode whose whole premise is "commit to a BODY" must not re-derive that body
	# from geography.
	#
	# `target_tile` is still reassigned to wherever the target actually ended up, because it is what the
	# EVENT reports: an escape should read as "the roots erupted where it now is and grasped nothing", not
	# as a fizzle on the square you originally clicked and stopped watching several seconds ago.
	#
	# `escaped` is recorded HERE, at the range test that decides it, rather than inferred later from
	# "locked and still alive" — the two are not the same claim, and only this one is the reason.
	var escaped := false
	var occ_id: int = _NO_ENTITY
	if locked_id == _NO_ENTITY:
		occ_id = _move_referee.entity_at(target_tile)
	elif is_alive(locked_id):
		target_tile = _move_referee.tile_of_entity(locked_id)
		var caster_tile: Vector2i = _move_referee.tile_of_entity(caster_id)
		var reach := maxi(absi(target_tile.x - caster_tile.x), absi(target_tile.y - caster_tile.y))
		if reach <= range_tiles:
			occ_id = locked_id
		else:
			escaped = true
	# else: killed mid-channel — fall through to the whiff on the originally-clicked tile. There is no body
	# left to report a position for, and the death already told that story.
	if occ_id != _NO_ENTITY:
		var occ := _node_of_id(occ_id)
		if occ != null and is_alive(occ_id) and caster != null and caster.is_hostile_to(occ):
			apply_condition(occ_id, "rooted", root_beats)
			# A HOSTILE CAST IS AN AGGRO SOURCE (v0.35.0, Jon's playtest) — the same wake apply_damage
			# performs at its own tail. Without it a control spell was the one offensive act in the game
			# that a monster could sleep through: Entangling Roots dealt no damage, so nothing ever
			# reached notify_attacked and a druid could hold a dormant pack down and walk past it.
			# notify_attacked latches _aggroed and fires the one-hop pack rally ONLY on the latching
			# EDGE, so re-rooting an already-angry goblin is idempotent and never re-shouts.
			#
			# ON THE LAND BRANCH ON PURPOSE, not at the cast commit: dodging the telegraph IS the
			# counterplay (§2.1 "slow telegraph, hard commit"), so a cast that whiffs onto bare ground
			# has nobody to wake and must not aggro. Kept at THIS call site rather than inside
			# apply_condition, which is condition-agnostic and will one day carry beneficial statuses —
			# a buff landing on an ally must never read as an attack.
			if occ is Monster:
				occ.notify_attacked()
			return
	# WHIFF — the target stepped off, died, escaped the reach, or the ground was bare. A distinct §2.3.4
	# outcome on the same `attack` event every other whiff uses (kind "ability"), so no new client plumbing
	# is needed.
	# WHIFF RECOVERY IS A DIAL (v0.32.0, whiff_recovery_beats): the miss pays whatever _whiff_tail_sec says
	# it owes and duration_sec quotes exactly that, so the spent tell matches the window the host holds.
	var paid_sec := _whiff_tail_sec(caster, recovery_sec)
	var whiff_data := {
		"attacker_id": caster_id,
		"attacker_name": _name_of(caster),
		"target_id": _NO_ENTITY,
		"target_name": "",
		"target_tile": target_tile,
		"damage": 0,
		"hp_after": -1,
		"target_max": 0,
		"kind": "ability",
		"whiff": true,
		"duration_sec": paid_sec,
	}
	# ESCAPED (v0.38.0), present-only: a CREATURE cast whose living target outran the caster's reach. It is
	# a genuinely different story from every other whiff — nobody mistimed anything, the target simply won
	# the footrace — and §2.3.4 says a distinct outcome gets a distinct line, so the log can say so instead
	# of reusing "hits nothing", which would read as the caster having fumbled. Absent on every other whiff,
	# including a creature target that DIED mid-channel (that outcome's story is the death).
	# Read from the flag the RANGE TEST set, so this can only ever mean "out of reach" and never stands in
	# for some other reason the cast failed to land on a living target.
	if escaped:
		whiff_data["escaped"] = true
		whiff_data["target_name"] = _name_of(_node_of_id(locked_id))
	NetEvents.post_event("attack", whiff_data, caster_id)
	# LAST, after the fizzle event is on the wire (the ordering rule every whiff release shares). The three
	# regimes of `whiff_recovery_beats`: FULL (the default) leaves the window untouched; NONE releases now;
	# PARTIAL releases at the PAID boundary the event just quoted.
	if paid_sec >= recovery_sec:
		return
	if paid_sec <= 0.0:
		if not _move_referee.finish_busy_early(caster_id):
			push_warning("[CombatReferee] targeted whiff for %d posted duration_sec 0 but no in-place record was released — client/server recovery tell may disagree" % caster_id)
		return
	if not _move_referee.release_busy_after(caster_id, paid_sec):
		push_warning("[CombatReferee] targeted whiff for %d posted a partial duration_sec but no in-place record was scheduled for release — client/server recovery tell may disagree" % caster_id)


# ── Instant abilities (v0.26.0 EXPERIMENT — Shield Block + Shadow Step; DESIGN §2.11.1) ──────
#
# The whole experiment lives in this section plus the consumption branch in apply_damage and
# MoveReferee.teleport_entity. Everything here is unreachable with GameConfig.instant_abilities_enabled
# off (the validator rejects before dispatch), which is the property that makes the toggle a true revert.

## Raise the knight's one-shot GUARD (BLOCK kind). Host-only, fully synchronous, NO occupied window — this is
## the §2.1.3 suspension made concrete: pressing it while mid-swing or mid-glide is exactly the point, so it
## never meets the busy gate. Nothing is committed and nothing is spent yet: the cooldown is charged when a
## blow is actually absorbed (see apply_damage), so a guard that goes unused costs the knight nothing but the
## press. Rejects — both mutation-free — are "already blocking" (idempotent presses must not re-post events)
## and "on cooldown (Ns)". Returns a DEFERRED accept: the status_applied + ability_used events ARE the outcome.
func _use_shield_block(user_id: int, ability: ActiveAbility) -> Dictionary:
	if _blocking.has(user_id):
		return { "ok": false, "reason": "already blocking" }
	var remaining := _cooldown_remaining_sec(user_id, ability)
	if remaining > 0.0:
		return { "ok": false, "reason": "on cooldown (%.1fs)" % remaining }
	_blocking[user_id] = ability
	# duration_sec 0.0 = an OPEN-ENDED status window (§2.3.4): unlike a stun, the host does not know when this
	# icon comes down — a hit does. Clients hold the shield until the paired status_expired, so play_blocking
	# runs no local expiry timer.
	NetEvents.post_event("status_applied", {
		"entity_id": user_id,
		"name": _name_of(_node_of_id(user_id)),
		"status": "block",
		"duration_sec": 0.0,
	})
	# cooldown_sec 0 — the socket must NOT go dark on the raise; it darkens on consumption. Posted anyway so
	# the HUD gets one uniform "an instant fired" signal per press (and a scripted run gets one assertable line).
	NetEvents.post_event("ability_used", {
		"entity_id": user_id,
		"ability": ability.display_name,
		"cooldown_sec": 0.0,
	}, user_id)
	return { "ok": true, "deferred": true }


## The rogue BLINK (BLINK kind): teleport ONE tile directly OPPOSITE the user's facing — a step back out of
## trouble without turning your back on it. Host-only and fully synchronous.
##
## VALIDATION ORDER IS PINNED (GLM resolution, 2026-07-25) and every reject above the teleport is a PURE
## NO-OP — no cooldown burned, no facing touched, no occupancy moved:
##   1. cooldown        — cheapest check, and the one that must not be bypassed by an illegal destination.
##   2. facing          — a never-moved rogue faces NOWHERE (ZERO), so "backwards" is undefined: reject
##                        "no direction" rather than pick an arbitrary axis.
##   3. destination     — computed from the COMMITTED tile (MoveReferee.tile_of_entity), which under conga IS
##                        the in-flight glide's DESTINATION. That is the honest Commitment-Rule read: you are
##                        already counted at the tile you committed to, so you blink back off THAT one.
##   4. walkable + free — a wall or a body behind you means the blink simply cannot happen.
##   5. teleport        — the ONLY mutation, and the ONLY site that bumps the interrupt generation.
## Blocked destination burning NO cooldown is deliberate (Jon): the ability's failure mode is "there was
## nowhere to go", which is a positioning mistake the player already paid for by still being where they were.
func _use_shadow_step(user_id: int, ability: ActiveAbility) -> Dictionary:
	var remaining := _cooldown_remaining_sec(user_id, ability)
	if remaining > 0.0:
		return { "ok": false, "reason": "on cooldown (%.1fs)" % remaining }
	var facing: Vector2i = _move_referee.facing_of(user_id)
	if facing == Vector2i.ZERO:
		return { "ok": false, "reason": "no direction" }
	var from: Vector2i = _move_referee.tile_of_entity(user_id)
	var dest := from - facing
	if not WorldGrid.is_walkable(dest) or not _move_referee.is_tile_free(dest):
		return { "ok": false, "reason": "blocked" }
	# teleport_entity re-derives every one of the checks above from its OWN state before mutating, so a false
	# here is a genuine "it isn't legal after all" and still leaves nothing changed.
	if not _move_referee.teleport_entity(user_id, dest):
		return { "ok": false, "reason": "blocked" }
	var cooldown_sec := _stamp_cooldown(user_id, ability)
	# `blink` is its OWN action, never a `glide_to`: a glide event means "tween over duration_sec", and a
	# teleport has no travel to tween. from/to both ride it so each peer can place the vanish and the arrival.
	NetEvents.post_event("blink", { "entity_id": user_id, "from": from, "to": dest }, user_id)
	NetEvents.post_event("ability_used", {
		"entity_id": user_id,
		"ability": ability.display_name,
		"cooldown_sec": cooldown_sec,
	}, user_id)
	return { "ok": true, "deferred": true }


## Seconds left on this entity's cooldown for `ability`, or 0.0 when it is ready (v0.26.0). Host-only read over
## _ability_ready_at_msec; an untracked entity / never-used ability reads ready. The remaining seconds ride the
## reject reason so §2.3.4's "distinct feedback per outcome" gets a NUMBER, not just a refusal.
func _cooldown_remaining_sec(entity_id: int, ability: ActiveAbility) -> float:
	var per_entity: Dictionary = _ability_ready_at_msec.get(entity_id, {})
	var ready_at := int(per_entity.get(ability.display_name, 0))
	return maxf(0.0, float(ready_at - Time.get_ticks_msec()) / 1000.0)


## Charge this entity's `ability` its own authored cooldown starting NOW, and return the stamped SECONDS
## (which ride the ability_used / ability_cooldown events so every HUD drains its overlay over the host's
## own span — stamp-and-bake, §2.8.2: a later tempo change never re-derives a cooldown already running).
## Beats × the entity's RESOLVED pace, so a cooldown incurred in a fight is measured on the fight's clock.
## v0.27.0: the beats are read from `ability.cooldown_beats` here rather than passed in by each caller —
## the two GameConfig dials are gone, so every call site would otherwise re-fetch the same field. A 0
## authored cooldown stamps a ready-at in the past, which reads as ready (no behavior change).
func _stamp_cooldown(entity_id: int, ability: ActiveAbility) -> float:
	var cooldown_sec := maxf(0.0, ability.cooldown_beats) * PaceReferee.beat_or_explore(_pace, entity_id)
	var per_entity: Dictionary = _ability_ready_at_msec.get(entity_id, {})
	per_entity[ability.display_name] = Time.get_ticks_msec() + int(cooldown_sec * 1000.0)
	_ability_ready_at_msec[entity_id] = per_entity
	return cooldown_sec


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
##
## THE ONE MELEE ROLL SITE (v0.26.1 damage bands, DESIGN §2.3.1 as amended). Every melee weapon-damage
## read in the codebase routes through here — the player bump, the monster's direct hit, the sticky
## adjacent catch, and the AoO free strike — so the band is rolled in exactly one place and each of
## those callers inherits it unchanged. A resolve calls this ONCE (the direct-hit and sticky-catch
## branches each roll independently, but only one of them executes per resolve), so a single strike
## never rolls twice. Host-side only: the rolled number rides the existing attack event, so no client
## rolls anything. TO-HIT is still deterministic — the attack lands; only the number is rolled.
func roll_damage_of(node: Node) -> int:
	# Weapon band roll + wielder bonus (v0.26.1 / v0.19.0), floored at 0. Layer order is UNCHANGED:
	# rolled weapon base → flat wielder bonus → (in apply_damage) the conditional passive modify_damage
	# chain → armor mitigation. mini/maxi order the pair so a live `/w club damage_min 9` retune that
	# momentarily inverts the band can never crash randi_range (same guard as MonsterBrain._begin_think).
	if node is Entity and node.equipped_weapon != null:
		var weapon: WeaponType = node.equipped_weapon
		var rolled := randi_range(mini(weapon.damage_min, weapon.damage_max),
				maxi(weapon.damage_min, weapon.damage_max))
		return maxi(0, rolled + _bonus_damage_of(node))
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
	# Doomed-ground bookkeeping dies with the round too (v0.22.0) — the fresh round's casters must see a
	# clean board. Any straggler _resolve_smite from the old round just erases an absent key (no-op).
	_pending_smites.clear()


# ── Ranged shot — public API (v0.33.0, shooter-agnostic) ──────────────────────

## A MonsterBrain requests a RANGED SHOT at a target TILE (v0.33.0, the bow goblin). Host-only, and the
## exact monster-side twin of `wind_up`: it returns the total SECONDS the shooter stays committed (the draw
## plus the after-loose tail) so the brain can book its own re-think just past that window, or -1.0 when
## DECLINED (dead / stunned / recovering / already busy / nothing to draw with / self-tile / out of range)
## so a refusal stays distinguishable from a real shot. Everything it does — the ordered gate, the stamps,
## the loose timer, the telegraph — IS `_commit_shot`, the very same core a player's `shoot` intent runs
## through, so a monster archer and a player archer can never drift apart (that shared core is the whole
## point of the v0.33.0 extract; before it, the shot lived inside the intent validator).
##
## It deliberately does NOT run the lane check: the referee's projectile rule is "the first stoppable body
## eats it" for EVERYONE, and a player is free to shoot down their own party's line. Refusing to fire past
## an ally is a BRAIN policy (see `is_lane_clear`), so it lives in the caller that wants it.
##
## DO NOT ADD ONE (v0.35.0, GLM diff review). That is no longer merely a design preference — the archer's
## RECKLESS SHOT (GameConfig.archer_reckless_shot_chance) deliberately calls this after its lane check has
## FAILED, to loose through a packmate on purpose. A lane gate here would silently swallow that shot and
## drop the archer back into the do-nothing hold the dial was added to fix, with nothing in the log to say
## why. The brain asks the question; this function only ever answers "can you commit the occupancy".
func commit_monster_shot(shooter_id: int, target_tile: Vector2i) -> float:
	return _commit_shot(shooter_id, target_tile)


## Would an arrow loosed at `target_tile` RIGHT NOW reach a HOSTILE body first? (v0.33.0 friendly-fire guard
## for monster archers; host-only, read from authoritative occupancy — never a client value.)
## `GameConfig.projectile_hits_allies` ships TRUE, so a goblin's arrow STOPS on the goblin standing in front
## of it: an archer that fired blindly would spend its entire draw shooting its own pack in the back.
##
## The check walks the EXACT tiles `_loose_arrow` will fly — the same `_build_arrow_path` (extension to the
## weapon's full range, then the wall clip) and the same `_is_stoppable` rule the flight applies — and
## answers true only when the FIRST stoppable body along that path is hostile to the shooter. Sharing the
## path builder is load-bearing: a check that walked its own line would eventually disagree with the arrow.
##
## An EMPTY lane (no stoppable body anywhere on the path — the target sits off the extended line, or a wall
## clipped the flight short of it) answers FALSE, not true. There is nothing to hit, and a shot costs a full
## draw + recovery of committed occupancy; "nothing to shoot at" and "my own packmate is in the way" both
## mean "not this think", and a kiter's next step reshuffles the geometry and asks again.
##
## EXACT, NOT ADVISORY: the brain's think → check → commit runs as ONE synchronous host stack with no await
## between, so the occupancy read here is the occupancy the draw commits against. It is deliberately NOT
## re-checked at the loose — by then the world has moved, and the Commitment Rule (§2.1) says the arrow flies
## anyway: an ally who walks INTO a committed shot eats it, exactly as they would a player's arrow.
func is_lane_clear(shooter_id: int, target_tile: Vector2i) -> bool:
	return lane_clear_from(shooter_id, _move_referee.tile_of_entity(shooter_id), target_tile)


## The lane check asked from a HYPOTHETICAL tile (v0.35.0) — everything is_lane_clear documents above, with
## the origin passed in rather than read from occupancy. is_lane_clear is now this function called with the
## shooter's live tile, so the two can never answer differently.
##
## WHY IT EXISTS: an archer whose lane is blocked used to have no move but "hold and hope", because it could
## only ask about where it already stood. With `from_tile` it can ask "would stepping HERE open the shot?"
## and act on the answer (MonsterBrain._reposition_step). The occupancy read still comes from the referee —
## only the ORIGIN is hypothetical, so a candidate tile is judged against the real world, including the
## shooter's own body still standing where it is (which is behind the line, never on it).
##
## `from_tile` is NOT validated as walkable or free: this answers a geometry question only. The caller vets
## the tile and the move referee owns the verdict on actually going there.
func lane_clear_from(shooter_id: int, from_tile: Vector2i, target_tile: Vector2i) -> bool:
	var shooter := _node_of_id(shooter_id)
	# Same ranged discriminator the shot gate uses: no weapon / a melee weapon has no lane to clear.
	var weapon: WeaponType = shooter.equipped_weapon if shooter is Entity else null
	if weapon == null or weapon.range_tiles <= 0:
		return false
	var shooter_tile: Vector2i = from_tile
	# A zero-length aim builds no path (line_tiles from == to is empty); refuse it here so the loop below
	# can't be handed a degenerate line the commit would reject a moment later anyway.
	if target_tile == shooter_tile:
		return false
	var clip := _build_arrow_path(shooter_tile, target_tile, weapon.range_tiles)
	var path: Array[Vector2i] = clip["path"]
	for tile in path:
		var occ_id: int = _move_referee.entity_at(tile)
		# Empty tiles and pass-through bodies (an ally while projectile_hits_allies is OFF) are not the
		# first thing the arrow meets — keep walking, exactly as _arrow_step does.
		if occ_id == _NO_ENTITY or not _is_stoppable(occ_id, shooter_id):
			continue
		# THE first stoppable body: the shot is worth taking only if it is an enemy.
		return _is_hostile_pair(shooter_id, occ_id)
	return false


# ── Private methods ───────────────────────────────────────────────────────────


# ── Ranged shot (v0.17.0, the bow — traveling-arrow model) ─────────────────────

## The ONE reject-reason predicate for a shot (v0.33.0 extract). Returns "" when this shooter may draw at
## this tile, or the DISTINCT reason it may not, in the ordered gate below. §2.2.8's reject-to-sender needs
## a different sentence per cause, and the monster path needs the SAME gate without any sentence at all —
## so the ordered predicate lives here exactly once and both callers read it. `_validate_shoot` words the
## refusal from it; `_commit_shot` enforces it. PURE: it reads authoritative truth and changes nothing (no
## stamp, no commit, no event), which is what makes running it twice on the player path harmless.
##
## The short lowercase tokens ("dead", "stunned", "recovering", "busy") are STATE names the intent pipe
## already renders its own way; the capitalized sentences are written to be shown to the player verbatim.
## Both shapes are preserved byte-for-byte from the pre-extract validator — the bonk text did not change.
func _shoot_reject_reason(shooter_id: int, target_tile: Vector2i) -> String:
	# Liveness (log-suppressed like a dead glide — the died event already told the player).
	if not is_alive(shooter_id):
		return "dead"
	# STUNNED (v0.20.0): can't START a new action while stunned — reject BEFORE the busy check (never touches
	# the busy record, so an in-flight action still completes; §2.1). Distinct reason → the §2.2.8 bonk.
	if is_stunned(shooter_id):
		return "stunned"
	# RECOVERING gate (v0.28.0, GameConfig.recovery_locks_actions — DESIGN §2.2.10): at 0 stamina in
	# tactical pace the ACTION channel is locked, so a shot is refused with its own distinct
	# "recovering" reason (§2.2.8 bonk + a game_log line). Mirrors the STUN gate directly above in
	# position and shape — a gate on STARTING an action, never touching the busy record, so anything
	# already committed still plays out (§2.1). MOVEMENT is NOT gated here: 0-stamina movement stays the
	# winded/crawl dials' business, so the two channels toggle independently.
	if GameManager.config.recovery_locks_actions and _move_referee.is_recovering(shooter_id):
		return "recovering"
	# BUSY — the SAME commit-window predicate melee/swap read (is_entity_moving covers a glide AND a
	# commit_in_place record), so a shot can never interrupt or overlap a committed action (Commitment Rule).
	if _move_referee.is_entity_moving(shooter_id):
		return "busy"
	var shooter := _node_of_id(shooter_id)
	# Ranged discriminator: range_tiles > 0. A melee (0) or bare-handed weapon has nothing to draw with.
	var weapon: WeaponType = shooter.equipped_weapon if shooter is Entity else null
	if weapon == null or weapon.range_tiles <= 0:
		return "Nothing to draw with."
	var shooter_tile: Vector2i = _move_referee.tile_of_entity(shooter_id)
	if target_tile == shooter_tile:
		return "Can't shoot your own tile."
	# Range gate: CHEBYSHEV distance to the CLICKED tile ≤ the weapon's range_tiles (server-authoritative,
	# read from the shared weapon resource — never a client value). The click must still be WITHIN range —
	# what changed in v0.31.0 is only what happens AFTER: the arrow no longer STOPS on the clicked tile, it
	# flies the weapon's full range_tiles along that same aim line (see _loose_arrow). Aiming short is now
	# a direction, not a brake.
	var cheb := maxi(absi(target_tile.x - shooter_tile.x), absi(target_tile.y - shooter_tile.y))
	if cheb > weapon.range_tiles:
		return "Out of range."
	return ""


## The "shoot" intent validator (host-only; registered on the shared pipe in activate()). A player submits
## shoot {target_tile}; the host adjudicates from ITS own truth (occupancy, weapon, pace), commits the
## shooter for the FULL attack window, telegraphs the DRAW, and looses a traveling arrow when the draw ends.
## Reject reasons are DISTINCT per §2.2.8 (reject-to-sender). Returns a DEFERRED accept on success — the
## windup + projectile events ARE the outcome, so no generic "shoot" event is broadcast (mirror of /class).
##
## v0.33.0: this is now a THIN WRAPPER. It owns exactly the two things that are about the WIRE and the
## PLAYER — the target-tile type guard and the reject SENTENCES — and hands the adjudication to
## `_commit_shot`, the shooter-agnostic core a monster archer commits through as well.
func _validate_shoot(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Never trust the wire — the target tile must be a real Vector2i. FIRST now (v0.33.0): every other gate
	# needs a real tile to reason about, so the wire-type guard has to clear before the shared reject-reason
	# predicate can run at all. The only visible consequence is PRECEDENCE — a malformed packet from a
	# dead/stunned/recovering/busy player now reads "bad target" instead of that state's reason. Both were
	# true; the wire fault is the more useful one to report, and no well-formed intent changes its answer.
	var tt = data.get("target_tile")
	if typeof(tt) != TYPE_VECTOR2I:
		return { "ok": false, "reason": "bad target" }
	var target_tile: Vector2i = tt
	var reason := _shoot_reject_reason(sender_peer_id, target_tile)
	if not reason.is_empty():
		return { "ok": false, "reason": reason }
	# ── Accept ── (the core re-runs the same pure predicate as its own guard; nothing yields between, so it
	# cannot answer differently here. A negative return can therefore only be the defensive commit miss.)
	if _commit_shot(sender_peer_id, target_tile) < 0.0:
		return { "ok": false, "reason": "busy" }
	return { "ok": true, "deferred": true }


## THE shot commit (v0.33.0 extract; host-only) — shooter-agnostic, so a PLAYER's `shoot` intent and a
## MONSTER brain's `commit_monster_shot` adjudicate through one body of code. Runs the shared ordered gate,
## arms the forcing window, stamps facing + the draw/recovery window, bakes the damage roll, arms the loose
## timer, commits the occupancy and telegraphs the DRAW. Returns the total committed SECONDS (draw +
## after-loose tail) — `wind_up`'s contract, which is what a brain schedules its next think from — or -1.0
## when the gate refused or the (defensive) commit missed.
##
## The shooter id may be NEGATIVE (a monster): everything below is written to be id-sign-agnostic, and the
## one place that is not — the forcing-window arming — is gated exactly as `wind_up` gates it (see there).
func _commit_shot(shooter_id: int, target_tile: Vector2i) -> float:
	# The shared gate, enforced here too — this is a PUBLIC entry for the brain, so it can never rely on a
	# caller having checked. Pure predicate, so the player path re-running it costs only the reads.
	if not _shoot_reject_reason(shooter_id, target_tile).is_empty():
		return -1.0
	var shooter := _node_of_id(shooter_id)
	# Both proven non-null by the gate above (a null node / null / melee weapon returns a reason).
	var weapon: WeaponType = shooter.equipped_weapon
	var shooter_tile: Vector2i = _move_referee.tile_of_entity(shooter_id)

	# ── Accept ──
	# Forcing-window arming (§2.8.7): a shot is a hostile action, so the shooter stamps at the TACTICAL beat
	# (no fast first draw) and stays tactical afterward. Armed BEFORE the stamps, mirroring wind_up/_begin_bump.
	# GATED `shooter_id > 0` (v0.33.0), the same guard wind_up carries: a MONSTER is already tactical through
	# aggro and has no forcing window of its own, and stamping one for a negative id would write a _force_until
	# entry keyed to an id the pace referee never cleans — a slow leak, not a behavior a monster needs.
	if _pace != null and shooter_id > 0:
		_pace.report_hostile_action(shooter_id)
	# Server facing + before_attack at accept (v0.17.1 review #1), mirroring wind_up (231/235). The shooter
	# turns to face its committed target tile so a backstab adjudicates from the TURNED facing — not the
	# stale pre-shot direction the sprite is visibly leaving (main.gd's face_toward turns the art the same
	# way) — and the read-only before_attack observation seam fires for the shooter's passives, parity with
	# every other committed attack. fire_before_attack is contractually observe-only (it cannot cancel or
	# mutate the shot). Facing set through MoveReferee (it owns _facing); a zero dir no-ops (target == shooter
	# was rejected above). The occupant re-resolves at loose — this is best-effort observation, as in wind_up.
	_move_referee.set_facing(shooter_id, (target_tile - shooter_tile).sign())
	fire_before_attack(shooter_id, _move_referee.entity_at(target_tile), "shoot")
	# Stamp-and-bake (§2.8): the shooter's committed occupancy is DRAW + RECOVERY, ADDITIVE (v0.23.1 —
	# ranged now composes exactly like melee: windup_beats is the draw before the loose, recovery_beats the
	# after-loose tail; pre-rename, ranged attack_beats CONTAINED the draw and needed a misconfiguration
	# guard against windup > attack ending the commit before the loose — additive composition makes that
	# state unrepresentable, so the guard is gone). Both stamped ONCE now at the shooter's resolved pace.
	# A windupsec= override stretches only the draw; the recovery tail rides on top unchanged.
	var windup_sec := _windup_duration_of(shooter)   # weapon.windup_beats × pace beat — the draw before loose
	if GameManager.debug_windup_override_sec > 0.0:
		windup_sec = GameManager.debug_windup_override_sec
	# The after-loose tail in its OWN local (v0.31.0): it is both half of busy_sec AND the number the
	# GREEN RECOVERY BAR needs, and the bar is raised at the LOOSE moment (the only ranged event that
	# fires while the shooter is still spent), so it rides the loose bind down to projectile_launched.
	var recovery_sec := _recovery_duration_of(shooter)
	var busy_sec := windup_sec + recovery_sec   # draw + after-loose tail = the occupied window
	# LOOSE timer armed BEFORE commit_in_place (v0.17.1 review #8). Co-due SceneTreeTimers fire in CREATION
	# order, and commit_in_place creates its OWN completion timer internally — so at the TIE
	# (busy_sec == windup_sec, reachable v0.23.1 only when recovery_beats is authored 0 — a zero after-loose
	# tail) the loose must be the earlier-created timer, else the commit-completion promotes a pipelined move
	# BEFORE the arrow launches. In normal play busy_sec > windup_sec (the recovery tail rides on top), so
	# the two land in different frames and order is moot — this only bites at the tie. The commit miss below is purely defensive: is_entity_moving was
	# checked at entry and nothing yields between (single-threaded host), so the commit cannot actually fail
	# here and the loose is never orphaned. Host SceneTreeTimer (survives despawn by construction, like
	# _resolve_windup). Capture PRIMITIVES only (never node refs): the round generation (review #4), shooter
	# id + tile, damage, weapon name, per-tile speed. round_gen makes an F5-mid-draw loose NOTHING into the
	# fresh round — a same-peer respawn defeats is_alive, but the generation check catches it.
	# interrupt_gen (v0.26.0) rides the bind beside round_gen — the same "identity a stale fire can never match"
	# idiom, one axis further: a shooter who BLINKED mid-draw looses nothing (see _loose_arrow's guard).
	# THE ONE RANGED ROLL SITE (v0.26.1 damage bands): the shot's damage is rolled ONCE here, at DRAW
	# COMMIT, and baked into the loose bind exactly as the flight speed and tiles already are (stamp-and-
	# bake, primitives-only — never a resource ref). One roll per shot, so an arrow's number is settled
	# the moment you commit to the draw and a mid-draw `/w bow` retune cannot change it in flight. Same
	# mini/maxi inversion guard as the melee site. `+ _bonus_damage_of(shooter)`, floored at 0, CLOSES a
	# documented §2.3.7 drift (the spec has always said `bonus_damage` applies to all attacks; arrows
	# alone skipped it) — and as of v0.33.0 it is LIVE: the bow goblin is the first monster archer, so
	# MonsterType.bonus_damage now reaches an arrow (it authors 0, but a designer's +N would land).
	var shot_damage := maxi(0, randi_range(mini(weapon.damage_min, weapon.damage_max),
			maxi(weapon.damage_min, weapon.damage_max)) + _bonus_damage_of(shooter))
	# weapon.range_tiles rides the bind too (v0.31.0 full-range flight): the flight path is built at LOOSE,
	# so the range must be baked HERE with the damage and the flight speed — a mid-draw `/w bow range` retune
	# can no more lengthen an arrow already committed to than it can change its damage (stamp-and-bake).
	get_tree().create_timer(windup_sec).timeout.connect(_loose_arrow.bind(
			_round_gen, shooter_id, shooter_tile, target_tile, shot_damage,
			weapon.display_name, weapon.projectile_tiles_per_beat,
			_move_referee.interrupt_gen_of(shooter_id), weapon.range_tiles, recovery_sec))
	# Commit the FULL window in place (from==to — the shooter is rooted while drawing AND recovering; no
	# occupancy move). UNREACHABLE-in-practice failure (GLM r-diff v0.33.0 #1): _shoot_reject_reason's
	# is_entity_moving gate ran in THIS same synchronous stack, so the record cannot have appeared between
	# the check and here — but the loose timer above is already armed, so if this ever DOES fail (a future
	# yield slipped in between), a stray uncommitted arrow would loose. Warn loudly instead of failing silent.
	if not _move_referee.commit_in_place(shooter_id, busy_sec):
		push_warning("[CombatReferee] _commit_shot %d: commit_in_place failed AFTER the busy check — stray loose timer armed; investigate ordering" % shooter_id)
		return -1.0
	# Telegraph the draw on the EXISTING `windup` event shape (+ the weapon name). A player-posted windup is
	# a harmless no-op in playback (the handler narrow-casts to Monster) until chunk 2's draw rig; the event
	# still broadcasts so headless assertions see it. as_peer = shooter (mirrors wind_up). A MONSTER shooter
	# (v0.33.0) rides this same event: the playback handler already narrow-casts to Monster and dispatches the
	# DRAW animation off `attack_style == "draw"` via the weapon-name catalog lookup, negative ids included —
	# which is exactly why the bow goblin needed no new presentation event.
	NetEvents.post_event("windup", {
		"entity_id": shooter_id,
		"name": _name_of(shooter),
		"target_tile": target_tile,
		"windup_sec": windup_sec,
		"weapon": weapon.display_name,
	}, shooter_id)
	# The committed window, in wind_up's contract: what a brain waits out before its next think.
	return busy_sec


## Loose the arrow at the end of the draw (host-only, from the commit timer). Builds the flight path NOW,
## broadcasts projectile_launched, and starts the per-tile arrival chain. Everything is captured PRIMITIVES
## (no node refs), so a shooter that despawns MID-FLIGHT can't crash the arrow (its damage/identity are baked).
##
## FULL-RANGE FLIGHT (v0.31.0, Jon): the clicked tile aims the shot, it does not stop it. The path is built
## to an endpoint pushed out along the SAME slope to the weapon's full `range_tiles`, so a click at 3 tiles
## with a range-7 bow sends the arrow 7 tiles down that line — anything standing further along it is now in
## the way. The click is still range-GATED at validate (you cannot aim past the bow's reach); only the flight
## got longer. Walls still own the far end: _clip_line_at_walls trims the longer line exactly as before.
##
## RANGED IS OUT OF SCOPE for recovery-on-contact (v0.26.0): the bow keeps its full draw + recovery commit,
## because the arrow resolves on its OWN timeline — a hit/miss can land many beats after the shooter's window
## already closed, so there is no window left to release at the moment contact is known. Melee/casts release
## their tail at resolve (see MoveReferee.finish_busy_early); the bow deliberately does not.
##
## `recovery_sec` is carried purely to STAMP the launch event (v0.31.0 green recovery bar): the shooter is
## rooted for draw + tail and the loose is the one moment on that timeline every peer hears about, so the bar
## is raised there. It changes NO adjudication here — the commit window was stamped at validate and is never
## re-derived (§2.8.2), and nothing about the tail is released early.
func _loose_arrow(round_gen: int, shooter_id: int, shooter_tile: Vector2i, target_tile: Vector2i,
		damage: int, weapon_name: String, tiles_per_beat: float, interrupt_gen: int = -1,
		range_tiles: int = 0, recovery_sec: float = 0.0) -> void:
	# Round-generation guard FIRST (v0.17.1 review #4): a draw in flight when F5 reset the round must loose
	# NOTHING into the fresh round. is_alive alone can't catch it — a same-peer respawn reuses the id and is
	# alive again — so the captured generation (bumped by reset_round) is the identity that no longer matches.
	if round_gen != _round_gen:
		return
	# FORCED-MOVEMENT INTERRUPT (v0.26.0 instants experiment): a shooter who SHADOW-STEPPED mid-draw looses
	# NOTHING. The whole flight path was computed from `shooter_tile` — the tile it drew from — so firing from
	# there after the archer has vanished off it would send an arrow out of thin air. Silent (the blink was the
	# outcome) and the draw's committed window still runs in full: the Commitment Rule keeps its bite, the
	# player traded the shot for the escape. Inert while the experiment is off.
	if interrupt_gen != -1 and _move_referee.interrupt_gen_of(shooter_id) != interrupt_gen:
		return
	# Mid-draw erasure (Q9 / M3): a shooter that died or despawned during the draw looses nothing — the death
	# teardown (clear_entity) already erased its commit record. This mirrors _resolve_windup's is-alive guard.
	if not is_alive(shooter_id):
		return
	# The flight path: aim extended to full range, then clipped at the first wall (v0.33.0 moved the two
	# steps into _build_arrow_path so the brain's lane check can walk the IDENTICAL tiles — see there).
	var clip := _build_arrow_path(shooter_tile, target_tile, range_tiles)
	var path: Array[Vector2i] = clip["path"]
	var clipped: bool = clip["clipped"]
	var proj_id := _next_projectile_id
	_next_projectile_id += 1
	# Per-tile flight time, stamped ONCE at loose (never rescaled mid-flight — same as a glide's baked
	# seconds): the shooter's resolved beat (tactical here — it is mid-forcing-window) ÷ tiles-per-beat.
	var tile_duration := PaceReferee.beat_or_explore(_pace, shooter_id) / maxf(tiles_per_beat, 0.001)
	# Broadcast the launch (as_peer = shooter, mirroring windup) so every peer can render the flight in chunk
	# 2. Paired 1:1 with a projectile_ended by id in EVERY case, including the empty (adjacent-wall) path.
	# `recovery_sec` (v0.31.0): the shooter's after-loose tail, so every peer can raise the GREEN RECOVERY
	# BAR on the shooter at the loose — the melee `attack` event has carried the equivalent since v0.29.0,
	# but a bow's only attack event is the arrow's HIT (duration_sec 0.0, and a miss posts none at all), so
	# the bar had nothing to read. Presentation stamp only: the window itself was committed at validate.
	NetEvents.post_event("projectile_launched", {
		"id": proj_id,
		"shooter_id": shooter_id,
		"path": path,
		"tile_duration_sec": tile_duration,
		"weapon": weapon_name,
		"recovery_sec": recovery_sec,
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


## THE flight path an arrow loosed from `shooter_tile` at `target_tile` will fly (v0.33.0 extract from
## _loose_arrow). Returns _clip_line_at_walls' { path, clipped }. TWO callers, and that is the entire reason
## it exists: `_loose_arrow` builds the real flight from it, and `is_lane_clear` walks it to decide whether a
## monster archer's shot would hit its own pack. A lane check that re-derived the geometry would drift from
## the arrow the first time either half was retuned; sharing one builder makes the guard EXACT by construction.
##
## EXTEND THE AIM TO FULL RANGE (v0.31.0). Push the endpoint out along the SAME slope until the shot is
## `range_tiles` long in Chebyshev terms. Scale the REAL delta, never `.sign()` — snapping to sign would
## flatten every knight-ish aim onto the eight cardinals and send the arrow somewhere the player never
## pointed. cheb >= 1 is guaranteed by both callers (each rejects the shooter's own tile first), and the
## dominant axis scales to exactly ±range_tiles, so the extended length is exactly range_tiles — no overshoot
## past the gate the click had to pass. cheb == range_tiles (a max-range click) leaves the endpoint untouched.
##
## Then the path is the 8-way line shooter→endpoint, CLIPPED to end at the last OPEN tile before the first
## wall (an arrow can't fly through a wall). `clipped` records whether a wall cut it short (→ "blocked") vs it
## reaching the extended end tile (→ "spent"). Walls remain the ONLY thing that shortens the flight.
func _build_arrow_path(shooter_tile: Vector2i, target_tile: Vector2i, range_tiles: int) -> Dictionary:
	var flight_target := target_tile
	var delta := target_tile - shooter_tile
	var cheb := maxi(absi(delta.x), absi(delta.y))
	if cheb > 0 and range_tiles > cheb:
		flight_target = shooter_tile + Vector2i(
				roundi(float(delta.x) * float(range_tiles) / float(cheb)),
				roundi(float(delta.y) * float(range_tiles) / float(cheb)))
	return _clip_line_at_walls(WorldGrid.line_tiles(shooter_tile, flight_target))


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
		tags: Array = [], verb: String = "", blocked: bool = false, absorbed: int = 0) -> Dictionary:
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
	# SHIELD BLOCK (v0.26.0): present-only, exactly like `godded` above — a blocked blow rides damage 0 +
	# unchanged hp + this flag, so clients render "turned aside" (grey shield popup, its own log line, hurt
	# cues SKIPPED) and can never confuse it with a miss or with a real hit. Absent on every other outcome.
	if blocked:
		data["blocked"] = true
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
	# ARMOR ABSORPTION (v0.27.1): present-only, and present exactly when the "armor" tag is — the number
	# of points the mitigation seam turned aside. Rides as its own field rather than inside `tags` because
	# a tag is a LABEL every peer switches presentation on, while this is a QUANTITY the log prints; a
	# reader must use .get("absorbed", 0) like every other present-only field.
	if absorbed > 0:
		data["absorbed"] = absorbed
	# Weapon stamp drives the rig swing on playback (main.gd) — stamped for EVERY kind that swings a
	# weapon (bump / windup / strike / free / arrow). EXCLUDE "kick" (v0.17.1): a ranged weapon's
	# point-blank bump has no melee swing, so it must carry NO weapon field (the rig-swing tail is
	# field-gated) — a kick renders like a bare-handed bump, never the bow slash arc.
	# EXCLUDE "ability" too (v0.20.0): a shield bash / kick is not a weapon swing, so it stamps no weapon field
	# (no longsword rig arc over a bash) — the attacker's lunge in _handle_attack_event is its melee cue.
	# EXCLUDE "smite" (v0.36.0, Jon's playtest — this was a BUG, not a design change). A smite is a
	# ground-target SPELL, but the shaman happens to hold a club, so every landed smite stamped "club" and
	# every peer dutifully played a club swing (and its arc across the recovery window) for a spell — Jon
	# reported it as "his recovery shows the club again". The rule the list above already states — stamp the
	# kinds that SWING A WEAPON — always excluded smite; nobody added it when the shaman shipped. The cast's
	# own cue is the overhead symbol on the separate `smite_cast` event, which is untouched by this, as is the
	# recovery tell (gated on duration_sec, not on the weapon field).
	#
	# THREE EXCLUSIONS IS THE LIMIT: this list is really "kinds where the weapon is not what struck", and a
	# fourth entry means it should be inverted into an allowlist of the kinds that DO swing.
	if attacker is Entity and attacker.equipped_weapon != null \
			and kind != "kick" and kind != "ability" and kind != "smite":
		data["weapon"] = attacker.equipped_weapon.display_name
		# DAMAGE TYPE (v0.27.0): a PRESENT-ONLY label, stamped in the same breath as the weapon identity
		# and under exactly the same condition — a weapon is present AND this hit is that weapon's own
		# blow (a `kick` is a ranged wielder's desperation poke and an `ability` is a bash, neither of
		# which is the weapon striking, which is why both already suppress the weapon field). Absent on
		# every weaponless hit, so any reader MUST use .get() with a default, exactly like `whiff` /
		# `blocked` / `gear`. Nothing reads it yet — armor's physical test stays kind-based — it is on the
		# wire now so the envisioned per-type resist work has its data from day one.
		data["damage_type"] = _damage_type_name(attacker.equipped_weapon.damage_type)
	return data


## The lowercase wire name for a WeaponType.DamageType ordinal (v0.27.0). A STRING crosses the wire, not
## the enum int, for the same reason every other event carries names: an ordinal is meaningless to a
## reader (a log line, a future resist table) without the enum, and reordering the enum would silently
## re-label old traces. SLASHING is the fallback, matching the resource default.
func _damage_type_name(damage_type: int) -> String:
	match damage_type:
		WeaponType.DamageType.BLUNT:
			return "blunt"
		WeaponType.DamageType.PIERCING:
			return "piercing"
	return "slashing"


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
## telegraph buys; on the instant path the same-stack liveness makes this always true).
##
## TWO-STAGE SHAPE (v0.29.0; stage 1's reach test is new, stage 2 is v0.24.8's toggle unchanged):
##   1. GROUND COMMIT (always). Damage hits whatever hostile-to-the-attacker LIVING entity occupies the
##      tile NOW (MoveReferee's authoritative occupancy) — a target that glided off whiffs; a different
##      hostile that stepped onto the tile eats it (the attack commits to ground, not a name) — PROVIDED
##      that occupant is genuinely WITHIN REACH: its whole motion record must sit inside the attacker's
##      8-ring (_motion_within_reach). Occupancy flips to a glide's DESTINATION at accept, so without that
##      test a body still two tiles away could be struck for owning the tile early. UNCONDITIONAL — this
##      is the referee's legibility guarantee, not an experiment, and a failed test FALLS THROUGH.
##   2. STICKY CATCH (toggled, GameConfig.swing_catches_adjacent, default ON since v0.29.0). The swing
##      follows the INTENDED victim off the committed tile, subject to the same reach test in its exact-
##      adjacency form. OFF = strict tile-only commitment.
## Nothing reachable at either stage → a WHIFF event.
##
## `interrupt_gen` (v0.26.0 instants experiment): MoveReferee's forced-movement generation captured when this
## resolve was ARMED. -1 means "no capture needed" — the synchronous instant-strike caller, which resolves in
## the same stack as its own commit and so cannot be teleported in between.
func _resolve_windup(attacker_id: int, target_tile: Vector2i, kind: String, recovery_sec: float,
		intended_id: int = _NO_ENTITY, interrupt_gen: int = -1) -> void:
	if not is_alive(attacker_id):
		return
	# FORCED-MOVEMENT INTERRUPT (v0.26.0): the attacker was teleported (a Shadow Step) after committing this
	# telegraph, so it is no longer standing where it wound up from — the swing fizzles, silently, exactly like
	# the stun gate below (the blink itself was the visible outcome). Placed ABOVE the whiff path deliberately:
	# teleport_entity already erased the busy record, so there is nothing left to release and a whiff event
	# would be a lie. Inert while the experiment is off — nothing ever bumps the generation then.
	if interrupt_gen != -1 and _move_referee.interrupt_gen_of(attacker_id) != interrupt_gen:
		return
	# INTERRUPT (v0.20.2): an attacker STUNNED mid-windup deals NOTHING — the stun cancels the in-flight strike
	# (Jon: stun interrupts an attack, not just blocks the next one). The committed busy record still clears on
	# its own timer; only the DAMAGE fizzles. Legit crowd-control — the interrupt is imposed by an attacker's
	# committed action (the bash), not a free self-take-back, so the Commitment Rule's intent holds (§2.11).
	if is_stunned(attacker_id):
		return
	var attacker := _node_of_id(attacker_id)
	# The attacker's authoritative tile, hoisted (v0.29.0): BOTH resolve stages measure reach from it now.
	var attacker_tile: Vector2i = _move_referee.tile_of_entity(attacker_id)
	var occ_id: int = _move_referee.entity_at(target_tile)
	# ── Stage 1: the GROUND commit (primary) ──────────────────────────────────
	# Whoever authoritatively occupies the committed tile eats the swing — "the attack commits to ground,
	# not a name" — SUBJECT TO the reach test below.
	#
	# v0.29.0 REACH GUARD, UNCONDITIONAL (not part of the sticky toggle — this is a BUG FIX, repro'd
	# headlessly with swing_catches_adjacent OFF): occupancy flips to a glide's DESTINATION at ACCEPT, so a
	# victim gliding INTO the committed tile owns that tile for the whole slide while its rendered body is
	# still up to two tiles from the attacker. Before this, such a victim was hit here, from two tiles away,
	# with `whiff:false` — the very "attacks landing from two tiles away" illegibility (§2.3.4) that v0.24.9
	# fixed for the STICKY branch only. The same motion-record test now guards BOTH branches through one
	# helper (_motion_within_reach) so they cannot drift: EVERY tile in the occupant's motion record —
	# occupancy + in-flight glide from/to + pipelined step from/to — must lie within Chebyshev 1 of the
	# attacker's tile NOW. A settled occupant's record is just its own tile (distance 1 from the attacker),
	# so ordinary hits are untouched; only a mid-flight body arriving from out of reach is spared.
	#
	# FALL-THROUGH on failure, never a return: the sticky branch below may still legitimately catch the
	# INTENDED victim (it re-tests the same record and rejects it identically when it is the same entity),
	# and otherwise the whiff path is the honest outcome.
	if occ_id != _NO_ENTITY:
		var occ := _node_of_id(occ_id)
		if occ != null and is_alive(occ_id) and attacker != null and attacker.is_hostile_to(occ) \
				and _motion_within_reach(occ_id, attacker_tile, true):
			apply_damage(attacker_id, occ_id, roll_damage_of(attacker), kind, recovery_sec)
			return
	# ── Stage 2: the STICKY catch (secondary, toggled) ────────────────────────
	# STICKY SWING (v0.24.8 experiment, Jon: "swings still land if the target moved but is still
	# directly around the swinger"): the committed tile holds no reachable hostile, but the INTENDED victim
	# (the body on the tile at commit) may have only SIDESTEPPED — if it is alive, still hostile, and
	# its authoritative tile is Chebyshev-adjacent to the attacker's NOW, the blade catches it anyway.
	# Escaping beyond adjacency still dodges (the whiff below), a ground-aimed windup (no intended
	# victim) keeps pure tile commitment, and a DIFFERENT body on the tile was already hit above —
	# ground commit stays primary. Symmetric: player swings and monster swings alike.
	#
	# v0.29.0 SCOPE NARROWING (the toggle's meaning, not its code): with stage 1 now doing the reach test
	# unconditionally, this toggle governs ONLY "the swing FOLLOWS the mover off the committed tile". OFF
	# (which is no longer the default — see GameConfig.swing_catches_adjacent) is strict tile-only
	# commitment; the never-hit-from-two-tiles guarantee holds either way.
	if GameManager.config.swing_catches_adjacent and intended_id != _NO_ENTITY and is_alive(intended_id):
		var victim := _node_of_id(intended_id)
		# v0.24.9 tightening (Jon: "never two tiles away"), unchanged in substance — the loop moved into
		# _motion_within_reach. EXACT adjacency here (allow_same_tile false, i.e. the old `!= 1` test): this
		# branch is about a victim that STEPPED OFF the committed tile, so the attacker's own tile is not a
		# candidate and the predicate stays exactly what v0.24.9 shipped.
		if victim != null and attacker != null and attacker.is_hostile_to(victim) \
				and not WorldGrid.is_wall(attacker_tile) \
				and _motion_within_reach(intended_id, attacker_tile, false):
			apply_damage(attacker_id, intended_id, roll_damage_of(attacker), kind, recovery_sec)
			return

	# Whiff: swing into empty/vacated ground. Distinct outcome — no damage, hp_after -1 (absent),
	# target_tile carried so the client renders the swing toward the committed tile.
	#
	# WHIFF RECOVERY IS A DIAL (v0.32.0, GameConfig.whiff_recovery_beats, DEFAULT -1 = pay it ALL =
	# pre-v0.26.0; it replaced the v0.28.0 `whiff_pays_recovery` bool, whose two settings are its two
	# endpoints). _whiff_tail_sec is the one policy site; this resolve just spends what it returns:
	#   paid == recovery_sec — the miss pays its FULL tail. duration_sec carries the real recovery_sec, so
	#                          every peer plays the spent-recovery tint (main.gd's play_recovery) + green
	#                          bar, the local attacker's commit_in_place mirror roots it for exactly that
	#                          window, and the busy record is LEFT ALONE (nothing to release).
	#   paid == 0.0         — v0.26.0 "recovery only on contact": duration_sec 0.0 (no spent tell) and the
	#                          busy window is released AT ONCE at the bottom of this function.
	#   0 < paid < full     — the PARTIAL tail: duration_sec carries the PAID seconds (so the tint/bar show
	#                          exactly what is really owed) and the REMAINDER is released on a timer.
	# Read live host-side, so a `/config whiff_recovery_beats` change lands on the very next miss.
	var paid_sec := _whiff_tail_sec(attacker, recovery_sec)
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
		"duration_sec": paid_sec,
	}
	# Weapon stamp on the WHIFF too (v0.9.3): a whiffed weapon swing still animates the rig arc, so a
	# missed strike plays the weapon (it composes with the monster's whiff bowstring, exactly as a
	# landed hit's swing composes with play_attack). A weaponless attacker stamps no field.
	#
	# `swing_sec` (v0.26.0, present-only alongside the weapon stamp): the rig ARC's visual length, now
	# split from the gameplay `duration_sec` because recovery-on-contact zeroed the latter on a whiff.
	# Without it the rig's play_swing no-ops on a 0 window and the melee WINDUP POSE — which has no
	# expiry and is handed over BY play_swing — would stay parked raised forever after every miss. So
	# the miss still animates its full arc (§2.3.4: a whiff is a visible outcome) while the attacker is
	# mechanically free at once. Only this whiff carries it; the ability / smite whiffs stamp no weapon.
	# NOTE the value coupling: the arc length IS `recovery_sec`, so tuning a weapon's recovery_beats
	# down also shortens its whiff animation — deliberate (pre-v0.26.0 behavior), but not obvious.
	if attacker is Entity and attacker.equipped_weapon != null:
		whiff_data["weapon"] = attacker.equipped_weapon.display_name
		whiff_data["swing_sec"] = recovery_sec
	NetEvents.post_event("attack", whiff_data, attacker_id)
	# Release the recovery remainder LAST (v0.26.0), after this resolve's own bookkeeping and after the
	# event is on the wire — a release can promote a pipelined step and post a `glide_to`, and the miss must
	# be the earlier seq. The tail was baked into the single windup+recovery record at commit (the v0.19.0
	# double-hit fix), so shortening it means finishing that record early. The CONTACT branches above return
	# before this and keep the full record byte-identically. A stunned / dead attacker returned at the top and
	# keeps its window too (the stun IS the punishment; a dead attacker's record was torn down by clear_entity).
	# v0.32.0, the three regimes of `whiff_recovery_beats` (see _whiff_tail_sec):
	#  - FULL (paid == recovery_sec, the default) — SKIPPED ENTIRELY: the committed window plays out
	#    untouched, which is what "the whiff pays" means, and `busy_released` never fires.
	#  - NONE (0.0) — released NOW, the v0.26.0 recovery-on-contact behavior.
	#  - PARTIAL — released on a timer at the PAID boundary, the same number the event just quoted.
	if paid_sec >= recovery_sec:
		return
	if paid_sec <= 0.0:
		if not _move_referee.finish_busy_early(attacker_id):
			push_warning("[CombatReferee] windup whiff for %d posted duration_sec 0 but no in-place record was released — client/server recovery tell may disagree" % attacker_id)
		return
	if not _move_referee.release_busy_after(attacker_id, paid_sec):
		push_warning("[CombatReferee] windup whiff for %d posted a partial duration_sec but no in-place record was scheduled for release — client/server recovery tell may disagree" % attacker_id)


## THE reach predicate for a melee resolve (v0.29.0) — ONE test, both stages of _resolve_windup, so the
## "never hit something that renders two tiles away" guarantee can never drift between them.
##
## True when EVERY tile in `entity_id`'s authoritative motion record — occupancy, the from/to of an
## in-flight glide, and the from/to of a pipelined next step (MoveReferee.motion_tiles_of) — lies within
## Chebyshev 1 of `attacker_tile`. Testing the whole record, not just occupancy, is the v0.24.9 insight:
## occupancy flips to a glide's DESTINATION at accept and can lead the RENDERED body by up to two tiles, so
## any single-point test lets an unreachable-looking body be hit. An EMPTY record (no occupancy, no glide —
## an entity MoveReferee does not track) is false: unknown position is never "in reach".
##
## `allow_same_tile` picks which of the two callers' predicates applies, and it is the ONLY difference
## between them:
##   true  (stage 1, the ground commit) — distance 0..1 is in reach. The honest "within reach" statement;
##         distance 0 would be the attacker's own tile, which occupancy makes unreachable today, so this
##         is future-proofing rather than a live case.
##   false (stage 2, the sticky catch) — distance must be EXACTLY 1, byte-for-byte the `!= 1` rejection
##         v0.24.9 shipped: that branch exists for a victim that stepped OFF the committed tile.
func _motion_within_reach(entity_id: int, attacker_tile: Vector2i, allow_same_tile: bool) -> bool:
	var motion_tiles: Array[Vector2i] = _move_referee.motion_tiles_of(entity_id)
	if motion_tiles.is_empty():
		return false
	for motion_tile in motion_tiles:
		var distance := maxi(absi(motion_tile.x - attacker_tile.x), absi(motion_tile.y - attacker_tile.y))
		if distance > 1:
			return false
		if distance == 0 and not allow_same_tile:
			return false
	return true


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
	# Instants experiment (v0.26.0): a raised guard dies with its knight (no phantom block for a respawned peer
	# id — and the node frees, taking its shield icon), and cooldowns reset so a fresh life starts ready.
	_blocking.erase(entity_id)
	_ability_ready_at_msec.erase(entity_id)
	# Conditions (v0.34.0): a corpse carries nothing, so a same-id respawn is born unrooted. No
	# status_expired is posted — the node frees, taking its cue with it (the stun erases above do the same).
	# _condition_gen is deliberately NOT erased here: it is the monotonic guard that stops a previous life's
	# pending expiry timer from clearing a fresh life's condition (see its declaration).
	_conditions.erase(entity_id)
	_move_referee.clear_entity(entity_id)
	NetEvents.post_event("died", { "entity_id": entity_id, "name": ent_name })
	# Goblin banter (v0.24.4): a MONSTER death makes a living packmate IN THE FIGHT bark revenge — Jon's
	# marquee moment ("the healer dies and a goblin says 'you'll pay for that'"). Forced past the
	# chance roll (the moment should reliably land) but still cooldown-gated. AFTER the erases above,
	# so the dying monster can never be picked as its own mourner (_hp no longer holds it).
	#
	# v0.27.0 — NOTABLE deaths get their own, louder moment: if the dying monster's TYPE is flagged
	# banter_notable (the shamans), the survivor barks `notable_death` INSTEAD of `ally_died`. Exclusive
	# by construction (one bark, chosen by the moment name) — two barks for one death would fight the
	# global cooldown and the second would just be swallowed anyway. The type is read off the node
	# captured ABOVE the erases, since it is still valid until the end-of-frame queue_free.
	if entity_id < 0:
		# death_tile (captured above, BEFORE clear_entity erased occupancy) is the moment's ORIGIN: the
		# mourner has to be within earshot of the body (v0.27.1, DESIGN §2.3.10-adjacent banter scoping).
		var mourner_id := _pick_living_monster_excluding(entity_id, death_tile)
		if mourner_id != 0:
			var mourner := _node_of_id(mourner_id)
			var dead_type = node.get("monster_type") if node != null else null
			var moment := "notable_death" if dead_type != null and dead_type.banter_notable else "ally_died"
			# v0.28.0: the MOURNER's authoritative tile rides the bark so every peer's log can gate the printed
			# line on earshot. Read from occupancy (never the node), like every other tile in this file — and it
			# is the SPEAKER's tile, not death_tile: the mourner is who is talking.
			Banter.bark(mourner_id,
					str(mourner.display_name) if mourner != null else "Goblin", moment,
					_move_referee.tile_of_entity(mourner_id), true)
	if node != null:
		_drop_weapon_of(node, death_tile)
		node.queue_free()


## v0.24.4: a random LIVING BRAINED monster other than `dead_id`, or 0 when none survive. Liveness
## reads the authoritative _hp map (the dying monster was erased before this runs), never node
## state. has_brain gates the pick — the first kill-check run had the Training Dummy mourn a goblin
## ("no... NO!"), which is funny exactly once; a mourner must be something that can think.
##
## v0.27.0 — ONLY MONSTERS IN THE FIGHT MOURN (Jeff's second playtest verdict): the candidate must also
## resolve TACTICAL on the pace referee. Before this, killing one goblin made a goblin three rooms away
## shout revenge, which read as the whole dungeon being psychic. With no eligible survivor the moment stays
## SILENT, deliberately: a bark from nobody relevant is worse than no bark. Null-pace (a parse/unit-safety
## path only; the host always injects a resolver) skips only the engagement half of the test.
##
## v0.27.1 — ENGAGEMENT ALONE WAS NOT ENOUGH. Being tactical means "a fight is happening near me", NOT
## "I am in THIS fight" — with three authored packs in separate rooms and a party that splits up, a
## simultaneous second fight made the far pack mourn a death it could not possibly have witnessed. So the
## candidate must ALSO be within `banter_earshot_tiles` (Chebyshev) of `death_tile`, read from
## authoritative occupancy. The two tests are complementary and both stay: engagement rules out the
## sleeping pack next door, earshot rules out the other live fight.
func _pick_living_monster_excluding(dead_id: int, death_tile: Vector2i) -> int:
	var earshot: int = GameManager.config.banter_earshot_tiles
	var living: Array[int] = []
	for child in _monsters.get_children():
		if child is Entity and child.entity_id < 0 and child.entity_id != dead_id \
				and _hp.has(child.entity_id):
			var monster_type = child.get("monster_type")
			if monster_type == null or not monster_type.has_brain:
				continue
			if _pace != null and not _pace.is_tactical(child.entity_id):
				continue
			# EARSHOT: authoritative tiles only. An untracked candidate reads the wall sentinel, whose
			# distance from a real death tile is meaningless — skip it rather than guess (it has no
			# occupancy, so it is mid-teardown anyway).
			var tile: Vector2i = _move_referee.tile_of_entity(child.entity_id)
			if WorldGrid.is_wall(tile) or WorldGrid.is_wall(death_tile):
				continue
			if maxi(absi(tile.x - death_tile.x), absi(tile.y - death_tile.y)) > earshot:
				continue
			living.append(child.entity_id)
	return living.pick_random() if not living.is_empty() else 0


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
		# Instants experiment (v0.26.0), same contract: a disconnect / despawn / F5 respawn starts unguarded
		# and with every instant cooldown ready. Idempotent with _kill_entity's erases above.
		_blocking.erase(node.entity_id)
		_ability_ready_at_msec.erase(node.entity_id)
		# Conditions (v0.34.0), same contract as the stun/god erases above: a disconnect / despawn / F5
		# respawn starts free of every condition. Idempotent with _kill_entity's erase. _condition_gen
		# survives on purpose (see its declaration) — it is the anti-reuse guard, not per-life state.
		_conditions.erase(node.entity_id)


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
	# The approach vector, reused for the flank probe (the tile on the target's FAR side).
	var attack_dir := (target_tile - attacker_tile).sign()
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
		"attack_dir": attack_dir,
		# SNEAK-ATTACK conditions (v0.27.0), precomputed here so passives stay pure readers — see the
		# doc block above. Both are host-authoritative: the stun latch is this referee's own truth and
		# the flank probe reads MoveReferee occupancy, never a rendered position. v0.27.1: it reads the
		# SETTLED occupant (settled_entity_at), not raw occupancy — an ally still sliding into the far
		# tile, or holding a reservation on it, is not yet visibly standing there, and adjudicating a
		# ×2 off a body the player cannot see in place is the same class of unreadability the behind-arc
		# trigger was retired for (§2.3.10).
		"target_stunned": is_stunned(target_id),
		"flanked_by_ally": _is_flanked_by_ally(attacker, attacker_id, target_tile + attack_dir),
		"tags": [],
	}


## Is the target SANDWICHED — does a living ALLY of the attacker STAND on the tile directly OPPOSITE the
## attacker (v0.27.0 sneak attack)? `opposite` is target_tile + attack_dir, i.e. one step further along
## the approach, so attacker / target / ally form a line through the target.
##
## True only when that tile holds an entity that (a) is SETTLED there, (b) is not the attacker itself —
## impossible through this geometry, but the guard keeps the predicate honest if a caller ever passes
## another tile — (c) is ALIVE, and (d) is NOT hostile to the attacker. Hostility is asked of the
## ATTACKER's node (server truth, the same call every other targeting site uses), so the debug
## `all_hostile` knob correctly makes flanking impossible: with everyone hostile, nobody is an ally.
##
## SETTLED, NOT MERELY OCCUPYING (v0.27.1 fix): the probe reads MoveReferee.settled_entity_at, not
## entity_at. entity_at answers with `_reserved` holders too, and under conga `_occupied` can LEAD the
## sprite by a step (the documented `_arriving` gap the bump validator already respects) — so the old read
## could double a hit for an ally who had not arrived yet, or (on the hold-origin branch) for one merely
## gliding toward the tile. Flanking is a thing the party SETS UP and must therefore be a thing the party
## can SEE: the ally has to be standing there.
##
## A ZERO attack_dir (attacker and target on the same tile — unreachable for a real hit) makes `opposite`
## the target's own tile, whose occupant is the target: not hostile to the attacker's enemy list? It IS
## hostile, so the predicate answers false. No special case needed.
func _is_flanked_by_ally(attacker: Node, attacker_id: int, opposite: Vector2i) -> bool:
	var occ: int = _move_referee.settled_entity_at(opposite)
	if occ == _NO_ENTITY or occ == attacker_id:
		return false
	if not is_alive(occ):
		return false
	var occ_node := _node_of_id(occ)
	if occ_node == null or attacker == null:
		return false
	return not attacker.is_hostile_to(occ_node)


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
##
## PASSIVE TIMING CHAIN (v0.35.0): the wielder's class passives get modify_windup_beats on the base+bonus
## beats before the floor and before the pace multiply — the ranger's Archery is the first user. Applied
## HERE rather than at each caller because this accessor is already the ONE funnel every windup runs
## through (a melee telegraph and the bow's draw alike), which is exactly why the chain can't be forgotten
## on a future path. Monsters and classless nodes yield an empty list and skip it entirely.
func _windup_duration_of(node: Node) -> float:
	if node is Entity and node.equipped_weapon != null:
		var w: WeaponType = node.equipped_weapon
		var bonus := 0.0 if w.range_tiles > 0 else _bonus_windup_beats_of(node)
		var beats := _passive_beats(node, w, w.windup_beats + bonus, true)
		return maxf(0.0, beats) * _pace_beat_sec(node)
	return 0.0


## Run the wielder's passive TIMING chain over `beats` and return the result (v0.35.0). `windup` picks
## which of the two hooks to call, so the two accessors share one dispatch and can never drift on ctx
## shape or chaining order. Passives run in ARRAY ORDER, each seeing the previous one's output — the same
## contract modify_damage has, for the same reason (a deterministic result when a class owns several).
##
## NOT FLOORED HERE: the callers floor at 0 immediately after, as they already did for the wielder bonus,
## so there is exactly one floor per accessor rather than two that could disagree. Host-only — this whole
## referee is inert on clients — and reusing _passives_of means a monster, the training dummy or any
## classless node short-circuits on the empty array without building a ctx.
func _passive_beats(node: Node, weapon: WeaponType, beats: float, windup: bool) -> float:
	var passives := _passives_of(node)
	if passives.is_empty():
		return beats
	var ctx := {
		"beats": beats,
		"wielder": node,
		"wielder_id": node.entity_id if node is Entity else 0,
		"weapon": weapon,
	}
	for p in passives:
		ctx["beats"] = p.modify_windup_beats(ctx) if windup else p.modify_recovery_beats(ctx)
	return float(ctx["beats"])


## THE whiff-tail policy (v0.32.0) — how many seconds of its committed recovery a MISS actually pays.
## One function, all three whiff resolves (melee windup, ability, smite), so the three can never drift.
## Reads `GameConfig.whiff_recovery_beats` LIVE host-side, so a `/config whiff_recovery_beats N` lands on
## the very next miss with no restart. `recovery_sec` is the FULL committed tail this resolve was armed
## with. DESIGN §2.3.9; the dial's three regimes are documented on the field itself:
##   -1 (default) → recovery_sec  (pay it all; the caller leaves the busy record alone)
##    0           → 0.0           (pay none; the caller calls finish_busy_early now)
##    N > 0       → min(N beats at THIS attacker's resolved pace, recovery_sec)
##                                (pay part; the caller schedules release_busy_after for the remainder)
## The min() is the whole reason this is a function and not an expression: a dial may only ever SHORTEN
## the committed window, never lengthen it, so a value past the weapon's own recovery reads as "full"
## and the caller's `paid == recovery_sec` comparison then takes the leave-it-alone branch for free.
## Beats (not seconds) so the number means the same thing at either pace — stamped through the attacker's
## own resolved beat, exactly like the recovery it is carving up.
##
## DEGENERATE CASE, stated so nobody re-derives it: an attacker with a ZERO tail (recovery_beats 0) returns
## 0.0 at EVERY setting, so its callers take the "paid == full" leave-it-alone branch and never release
## anything. That is correct and it is why the callers test full BEFORE zero: there is no tail to hand back,
## and the record's own timer is already expiring in the same instant the resolve runs.
func _whiff_tail_sec(node: Node, recovery_sec: float) -> float:
	var beats: float = GameManager.config.whiff_recovery_beats
	if beats < 0.0:
		return recovery_sec
	if beats == 0.0:
		return 0.0
	return minf(beats * _pace_beat_sec(node), recovery_sec)


## The attacker node's resolved beat (seconds) at stamp time — tactical or explore per PaceReferee
## (§2.8.7), keyed by the node's entity_id. Keeps the `node is Entity` guard HERE (combat's duration
## accessors take the resolved attacker node, not an id) and delegates the null-resolver → explore
## fallback to the shared PaceReferee.beat_or_explore policy site; a non-Entity node reads explore.
func _pace_beat_sec(node: Node) -> float:
	if node is Entity:
		return PaceReferee.beat_or_explore(_pace, node.entity_id)
	return GameManager.explore_beat_sec


## The attacker's recovery tail (seconds): the equipped weapon's BASE recovery (recovery_beats — renamed
## from attack_beats v0.23.1, and now purely the post-strike/post-loose tail for melee AND ranged; no
## separate cooldowns, Part 4 Q9) plus the wielder's MELEE recovery bonus (v0.19.0), stamped at the
## ATTACKER's resolved pace (§2.8.7: an engaged attacker recovers at the tactical beat; a player's bump
## tail stamps tactical because _begin_bump armed the forcing window first). Bonus is melee-only + floored
## at 0. A weaponless Player keeps attack_recovery_beats (vestigial fallback); a weaponless Monster has 0.
## The one conversion for a bump tail (bump_duration_of) and an instant strike's busy (wind_up).
## PASSIVE TIMING CHAIN (v0.35.0): same shape and same rationale as _windup_duration_of above — the
## wielder's class passives get modify_recovery_beats on the base+bonus beats before the floor and the
## pace multiply. This accessor is the one funnel for every tail (melee swing, bow loose, bump), which is
## what makes Archery's "one beat off the ranged recovery" a single edit rather than a per-callsite hunt.
func _recovery_duration_of(node: Node) -> float:
	if node is Entity and node.equipped_weapon != null:
		var w: WeaponType = node.equipped_weapon
		var bonus := 0.0 if w.range_tiles > 0 else _bonus_recovery_beats_of(node)
		var beats := _passive_beats(node, w, w.recovery_beats + bonus, false)
		return maxf(0.0, beats) * _pace_beat_sec(node)
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


## The DEFENDER's physical damage reduction as a fraction 0..1, read LIVE at the apply_damage mitigation
## seam. v0.27.0 moved the PLAYER read off the CLASS and onto the WORN BODY ITEM (`equipped_body`, the
## equipment-phase-2 slot): armor is an object now, so taking it off actually takes the mitigation off.
## Duck-typed off the node exactly as MoveReferee._stamina_max_of reads `player_class` — a Monster has no
## `equipped_body` property, so `get` answers null there and falls through to its authored type; anything
## else (a null node, an untyped future entity) reads 0.0, because armor is opt-in and an unknown defender
## is simply unarmored. Null-safe at every hop: an undressed player falls through to 0.0 rather than
## crashing a hit. Clamped defensively even though the export is range-bound, since any authored .tres
## could be pointed at the slot.
func _phys_reduction_of(node: Node) -> float:
	if node == null:
		return 0.0
	var body = node.get("equipped_body")
	if body != null:
		# Null-checked get (same shape as _ability_of): a hand-authored .tres pointing at some other
		# Resource type would answer null here rather than crash the hit on a missing property.
		var reduction = body.get("phys_damage_reduction")
		if reduction == null:
			return 0.0
		return clampf(float(reduction), 0.0, 1.0)
	if node is Monster and node.monster_type != null:
		return clampf(node.monster_type.phys_damage_reduction, 0.0, 1.0)
	return 0.0


## The DEFENDER's ARMOR WEIGHT band as an ItemType.ArmorWeight ordinal (v0.27.0), read LIVE at the same
## seam. An undressed player / a monster / anything unresolvable reads UNARMORED, whose flat reduction is
## 0 — so "no armor" leaves the incoming amount untouched (an absence must never mitigate).
##
## v0.27.1: delegates to Player.worn_armor_weight() — the ONE resolver (see its doc comment). This used
## to duck-read `equipped_body.armor_weight` here, and MoveReferee's stamina rest wait read it again for
## itself, so the weight-PROMOTION rule (DESIGN §2.10, heaviest of several worn pieces) had two homes
## while the comment here claimed it "would replace exactly this function". Now it genuinely does: this
## function is a thin, live, duck-typed hop to that single site. `has_method` (not `is Player`) keeps the
## read structural rather than type-coupled, matching how every other accessor in this file reads a node.
func _armor_weight_of(node: Node) -> int:
	if node != null and node.has_method("worn_armor_weight"):
		return int(node.worn_armor_weight())
	return ItemType.ArmorWeight.UNARMORED


## The FLAT damage reduction for an armor weight band (v0.27.0) — the second armor term, from the three
## authored GameConfig dials. UNARMORED returns 0 EXPLICITLY (there is deliberately no config field for
## it): no armor means the flat path subtracts nothing, so min(pct, flat) collapses to the untouched
## amount. Kept as one match here so the band→amount mapping has exactly one site.
##
## v0.27.1: every band is now an EXPLICIT arm and the fall-through WARNS ONCE (per band value). Before
## this, UNARMORED and a hypothetical future 4th band shared the silent `return 0` default — so adding a
## band to the enum and forgetting this table would have shipped it as "no flat reduction at all" with no
## signal anywhere. The default is still the safe number; it is just no longer silent.
func _armor_flat_of(weight: int) -> int:
	match weight:
		ItemType.ArmorWeight.UNARMORED:
			return 0
		ItemType.ArmorWeight.LIGHT:
			return GameManager.config.armor_flat_reduction_light
		ItemType.ArmorWeight.MEDIUM:
			return GameManager.config.armor_flat_reduction_medium
		ItemType.ArmorWeight.HEAVY:
			return GameManager.config.armor_flat_reduction_heavy
	if not _warned_armor_bands.has(weight):
		_warned_armor_bands[weight] = true
		push_warning("[CombatReferee] armor weight band %d has no flat-reduction arm — treating it as UNARMORED (flat 0). Add it to _armor_flat_of." % weight)
	return 0


## Is this damage `kind` PHYSICAL — i.e. does armor apply to it (v0.26.0)? Everything is physical
## EXCEPT the two documented exemptions:
##  - "smite" — a MAGICAL ground spell; plate turns aside a club, not a curse (flagged for Jeff if he
##    wants a separate magic-resist dial later).
##  - "admin" — the dev pokes (/mi hp, /mi kill) must stay EXACT: an armored knight has to die to
##    "/mi kill" and land on the number "/mi hp" asked for, or the tuning tools lie.
## Kept as a predicate (not an inline check) so every future kind decides its side here, in one place.
func _is_physical_kind(kind: String) -> bool:
	return kind != "smite" and kind != "admin"


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
##
## Runs the SAME passive timing chain _windup_duration_of runs (v0.35.0) even though no shipped passive
## touches melee beats today. This function is a ROUTING predicate and that one is the DURATION stamp; if
## they ever disagreed about the beats, a future passive that shortened a melee windup to 0 would route a
## bump down the telegraphed path and then stamp it a zero-length telegraph. Sharing the chain makes the
## two answers the same answer by construction rather than by everyone remembering.
func melee_windup_beats_of(node: Node) -> float:
	if not (node is Entity) or node.equipped_weapon == null:
		return 0.0
	var w: WeaponType = node.equipped_weapon
	if w.range_tiles > 0:
		return 0.0
	return maxf(0.0, _passive_beats(node, w, w.windup_beats + _bonus_windup_beats_of(node), true))


## Wielder MELEE recovery bonus in BEATS (v0.19.0): monsters only (MonsterType.bonus_recovery_beats). Melee-
## gated by the caller. Missing type / non-monster → 0.
func _bonus_recovery_beats_of(node: Node) -> float:
	if node is Monster and node.monster_type != null:
		return node.monster_type.bonus_recovery_beats
	return 0.0
