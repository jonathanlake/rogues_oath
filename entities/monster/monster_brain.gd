extends Node

## The HOST-ONLY AI for one monster (DESIGN §2.5.3 — the world's decisions are the host's). A child
## of monster.tscn on every peer, but INERT unless activated: Main activates it only inside its
## is_server() branch (component pattern — the parent monster wires this child's boundary hook and
## hands it the referee). A client's brain never runs.
##
## It thinks at its OWN boundaries only — never a global tick: an initial think on activation, then
## again each time this monster's glide completes (the parent wires glide_finished -> on_boundary),
## plus a self-scheduled re-think after any refused action. Every think is gated on the referee
## showing this monster not busy and reads AUTHORITATIVE referee occupancy at that instant, so the
## AI adjudicates from the same truth the referee does — never a rendered position.
##
## Behaviour: if a hostile player is 8-adjacent, it requests a telegraphed wind-up through
## CombatReferee.wind_up (the referee validates + commits it, posts the telegraph, and resolves the
## hit against the target TILE later); the brain then schedules its OWN re-think just past that
## resolution, since a wind-up busy record ends without a glide_finished to wake it. Otherwise it
## paths one step toward the nearest player via WorldGrid.find_path (walls-only A*) and submits it
## through the referee's host-local validator. A refused step or an empty path schedules a re-think
## rethink_beats later, and a busy gate (mid glide+rest) polls on the tight epsilon — both are the
## hot-loop guard (a brain never re-thinks twice in one frame) and mirror MoveInput's retry cadence.

## Re-think delay in BEATS after a refused/blocked action (a contested tile back-off) — converted at
## the live beat when used, not cached (DESIGN §2.8; matches MoveInput's held-retry cadence so a
## monster and a player back off a contested tile together). 1 beat = one movement rest. NOTE: the
## BUSY-gate case (the referee still showing this monster mid glide+rest) does NOT use this delay — it
## schedules ONE wake at exactly the remaining rest (move_rest_beats + a small epsilon), so the monster
## resumes right as its rest ends rather than a whole back-off beat later — go-stop-go stays uniform (see _think).
@export var rethink_beats: float = 1.0

## Small margin (seconds) added past a wind-up's duration when the brain schedules its own
## re-think after committing one. A wind-up busy record ends without a glide_finished (that only
## fires on real glides), so the brain wakes ITSELF just after resolution — think-at-own-boundary,
## no new signal plumbing. The epsilon guarantees the referee's busy record has cleared first.
@export var windup_rethink_epsilon_sec: float = 0.05

# Set true by activate(); a client's brain stays false and every think early-returns.
var _active: bool = false
# Aggro latch (DESIGN §2.8, aggro persistence). Set true the first think the nearest player is
# within aggro_range_tiles; while latched AND monster_type.aggro_persists, the range check is
# skipped so the chase never leash-drops. With aggro_persists false it tracks current in-range
# state (legacy leash). Unused by unlimited-range monsters (aggro_range_tiles <= 0 skip the gate).
var _aggroed: bool = false
# The host's MoveReferee, handed in by the parent at activation. The brain reads occupancy truth
# and submits monster intents through it (host-local — no RPC; monsters have no RTT). It never
# reaches up to Main or the monster; the referee is its one injected dependency. Untyped so its
# MoveReferee-specific calls (no class_name on that script) resolve dynamically without churn.
var _referee = null
# The host's CombatReferee, handed in alongside the movement referee (chunk 2). The brain requests
# a telegraphed wind-up through it when adjacent to a hostile. Untyped, same reason as _referee.
var _combat = null
# This monster's negative entity id, handed in with the referees so every query/submit is keyed
# correctly.
var _entity_id: int = 0
# This monster's authored template, handed in alongside the referees + id so the brain can read
# behavioral tuning (aggro_range_tiles) WITHOUT reaching up to the parent node — same injection
# shape as _referee/_combat/_entity_id (component pattern; the parent wires the child in
# activate_brain). Null on a client's inert brain, which never thinks.
var _monster_type: MonsterType = null


# ── Public methods ────────────────────────────────────────────────────────────

## Host-only switch-on, called by the parent monster's activate_brain(). Stores the referees + id +
## authored type and kicks off the first think DEFERRED — so the referees' spawn-enter hooks have
## already seeded this monster's occupancy + HP and the node's _ready has run before we query anything.
func activate(referee: Node, combat: Node, entity_id: int, monster_type: MonsterType) -> void:
	_referee = referee
	_combat = combat
	_entity_id = entity_id
	_monster_type = monster_type
	# Fresh life, fresh aggro. Instances are currently always freshly spawned, but a pooled or
	# re-activated monster must never inherit a previous life's latch and skip the acquire gate.
	_aggroed = false
	_active = true
	_think.call_deferred()


## Boundary hook, wired by the parent monster to its glide_finished. This monster just finished a
## step — re-plan the next one.
func on_boundary() -> void:
	_think()


# ── Private methods ───────────────────────────────────────────────────────────

## Decide and submit at most ONE step (or log the adjacent-attack seam). Gated on not-busy and on
## authoritative referee state read live at this instant.
func _think() -> void:
	if not _active:
		return
	# Busy gate: only ever act between committed steps. Under go-stop-go the referee holds this monster
	# busy for glide + REST, but the node's glide_finished (which woke us via on_boundary) fires at the
	# GLIDE boundary — so a post-glide think lands mid-rest and sees busy. The remaining busy is then
	# exactly the rest, so schedule ONE wake at rest + epsilon rather than polling: the monster resumes
	# right as its rest ends, no busy loop. Should the gate ever trip from a rarer mid-glide wake, the
	# same delay simply re-checks a little later and converges — self-healing, never a lockup.
	if _referee.is_entity_moving(_entity_id):
		_reschedule_after(GameManager.beats_to_sec(GameManager.config.move_rest_beats) + windup_rethink_epsilon_sec)
		return
	var my_tile: Vector2i = _referee.tile_of_entity(_entity_id)
	# tile_of_entity returns a wall-sentinel tile when the entity is untracked (e.g. despawned
	# between scheduling and firing). No live monster ever rests on a wall, so this is unambiguous.
	if WorldGrid.is_wall(my_tile):
		return

	# Explicit Array type: _referee is deliberately untyped (see its declaration), so := cannot
	# infer through the dynamic call — and an untyped brain must still fail loudly if the referee
	# ever returns a non-array.
	var targets: Array = _referee.player_tiles()
	if targets.is_empty():
		# No players to chase RIGHT NOW (all dead/disconnected). Keep watching: nothing else
		# wakes this brain (on_boundary needs our own glide), so a joiner would otherwise meet
		# a permanently dormant monster.
		_reschedule()
		return

	# Aggro acquisition + persistence (monster_type.aggro_range_tiles + aggro_persists, DESIGN §2.8):
	# nearest player by Chebyshev (king-move) distance. aggro_range_tiles <= 0 = unlimited (whole-room
	# aggro), so an un-ranged monster skips the gate entirely. Otherwise the brain ACQUIRES when the
	# nearest is within range (latching _aggroed) and, with aggro_persists true (the default), IGNORES
	# range from then on — the chase never leash-drops, following the target across rooms. With
	# aggro_persists false the legacy LEASH returns: _aggroed tracks current in-range state and the
	# chase drops the instant the target breaks range. Type is null only on a client's inert brain,
	# which never reaches here; the guard keeps a misconfig from crashing.
	var nearest_dist: int = -1
	for t in targets:
		var d: int = maxi(absi(t.x - my_tile.x), absi(t.y - my_tile.y))
		if nearest_dist < 0 or d < nearest_dist:
			nearest_dist = d
	if _monster_type != null and _monster_type.aggro_range_tiles > 0:
		var in_range := nearest_dist <= _monster_type.aggro_range_tiles
		if in_range:
			_aggroed = true
		elif not _monster_type.aggro_persists:
			# Legacy leash: aggro drops the moment the target breaks range (persistence off).
			_aggroed = false
		# Un-acquired, or leash-dropped, means idle on the re-think cadence. A latched persistent
		# aggro skips straight past this — range no longer matters once acquired.
		if not _aggroed:
			_reschedule()
			return

	# Adjacent to a hostile player? (M3: every player is hostile to the monster — the faction rule;
	# when neutral factions exist this filters by is_hostile_to.) Chunk-2 seam: request a wind-up.
	for t in targets:
		if maxi(absi(t.x - my_tile.x), absi(t.y - my_tile.y)) == 1:
			# Request an attack against that tile (decision 3; DESIGN §2.8). The combat referee runs
			# either the instant strike (goblin, windup_beats==0: resolve now + recovery busy) or the
			# telegraphed wind-up (>0 dial), commits the monster's busy record, and returns the total
			# seconds until the monster is free again (committed busy plus any post-telegraph recovery),
			# or -1.0 if it DECLINED (already busy / not alive).
			var wait_sec: float = _combat.wind_up(_entity_id, t)
			if wait_sec >= 0.0:
				# The attack's busy record ends WITHOUT waking us (glide_finished fires only on real
				# glides), so schedule our OWN re-think just past it — think-at-own-boundary, no new
				# signal plumbing. The epsilon guarantees the referee's busy record has cleared first.
				# On resolution the target may have fled or died; the next think re-decides.
				_reschedule_after(wait_sec + windup_rethink_epsilon_sec)
			else:
				# Declined (already busy / not alive) — back off on the normal cadence and retry.
				_reschedule()
			return

	# Not adjacent: step toward the NEAREST player by path length over the walls-only grid. Body
	# occupancy is deliberately not in that grid (bodies are volatile), so the referee's validator
	# is the authority on whether the chosen step is actually free.
	var best_path: Array[Vector2i] = []
	for t in targets:
		var path := WorldGrid.find_path(my_tile, t)
		# find_path returns [] for unreachable (sealed/OOB) and a >= 2 path when a step exists.
		if path.size() >= 2 and (best_path.is_empty() or path.size() < best_path.size()):
			best_path = path
	if best_path.is_empty():
		# Every player unreachable (walls only — a corridor-blocking PLAYER is handled as the
		# adjacent-attack case above, so the single-goblin M3 can't softlock here). A monster
		# blocked by another MONSTER would re-think forever — known M3 limitation; multi-monster
		# pathing is future work.
		_reschedule()
		return

	var dir := best_path[1] - my_tile
	# Host-local submit through the referee's validator. On accept the referee broadcasts the
	# glide_to itself (as_peer = this negative id), which drives the tween on every peer and, at
	# this monster's boundary, fires glide_finished -> on_boundary -> the next think. So a SUCCESS
	# schedules nothing here; only a refusal falls through to the re-think.
	if not _referee.submit_monster_intent(_entity_id, dir):
		_reschedule()


## Schedule one re-think rethink_beats from now (the refused/blocked/no-target back-off cadence),
## converted at the LIVE beat — not cached, so a tempo change is picked up on the next back-off.
func _reschedule() -> void:
	_reschedule_after(GameManager.beats_to_sec(rethink_beats))


## Schedule one re-think `sec` from now. A get_tree() SceneTreeTimer (not a Timer child) so it
## survives on the host tree exactly as the referees' completion timers do; if this brain is freed
## (despawn) before it fires, Godot drops the connection to the freed method — no stale call. Used
## both for the normal back-off cadence and, with a longer span, to wake just past a wind-up's end.
func _reschedule_after(sec: float) -> void:
	get_tree().create_timer(sec).timeout.connect(_think)
