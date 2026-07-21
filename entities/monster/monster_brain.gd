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
## rethink_beats later.
##
## Chase parity (v0.9.3): at a BUSY boundary think (glide_finished fires at the SLIDE boundary while
## the referee still holds this monster committed through the SETTLE), the brain PIPELINES its next
## step — submits it mid-glide so the referee's _pending slot promotes+broadcasts it at the exact
## action-window boundary, ZERO gap, the identical machinery a held-key player rides. An always-armed
## epsilon BACKSTOP (settle + epsilon = status-quo timing) recovers the chase whenever the pipeline
## is refused (blocked/corner/adjacent/no-path/hold-origin). See _think's busy gate for the full why.

## Re-think delay in BEATS after a refused/blocked action (a contested tile back-off) — converted at
## the live beat when used, not cached (DESIGN §2.8; matches MoveInput's held-retry cadence so a
## monster and a player back off a contested tile together). 1 beat = one movement step. NOTE: the
## BUSY-gate case (the referee still showing this monster mid action window) does NOT use this delay —
## it pipelines the next step (zero-gap promotion) and, as a recovery BACKSTOP, arms ONE wake at the
## remaining SETTLE ((1 - slide_fraction) of the glide term + any rest, plus a small epsilon) so a
## refused pipeline resumes right as the action window ends — cadence stays uniform (see _think).
@export var rethink_beats: float = 1.0

## Small margin (seconds) added past a wind-up's duration when the brain schedules its own
## re-think after committing one. A wind-up busy record ends without a glide_finished (that only
## fires on real glides), so the brain wakes ITSELF just after resolution — think-at-own-boundary,
## no new signal plumbing. The epsilon guarantees the referee's busy record has cleared first.
@export var windup_rethink_epsilon_sec: float = 0.05

# Set true by activate(); a client's brain stays false and every think early-returns.
var _active: bool = false
# Whether the last SUBMITTED step was diagonal — the settle wake scales its glide term by the
# diagonal multiplier to mirror the referee's stamp (see the busy gate in _think).
var _last_step_was_diagonal: bool = false
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
# The host's PaceReferee (Tactical Zones v1, §2.8.7), injected alongside the referees. Two uses: the
# brain REPORTS its engagement (aggroed + current chase target) to it every think, and it READS this
# monster's own resolved beat from it for wake/pacing math (an aggroed monster paces at the tactical
# beat, matching the referee's tactical stamp of its glide). Untyped, same reason as _referee. Null on
# a client's inert brain.
var _pace = null
# The player id this monster is currently chasing (its leash target), set at the nearest-pick each
# think and reported to the pace referee; 0 when not chasing (un-aggroed / no target). The leash key
# the resolver reads so a chased player stays tactical however far they run.
var _target_id: int = 0


# ── Public methods ────────────────────────────────────────────────────────────

## Host-only switch-on, called by the parent monster's activate_brain(). Stores the referees + id +
## authored type and kicks off the first think DEFERRED — so the referees' spawn-enter hooks have
## already seeded this monster's occupancy + HP and the node's _ready has run before we query anything.
func activate(referee: Node, combat: Node, entity_id: int, monster_type: MonsterType, pace: Node) -> void:
	_referee = referee
	_combat = combat
	_entity_id = entity_id
	_monster_type = monster_type
	_pace = pace
	# Fresh life, fresh aggro. Instances are currently always freshly spawned, but a pooled or
	# re-activated monster must never inherit a previous life's latch/target and skip the acquire gate.
	_aggroed = false
	_target_id = 0
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
	# Busy gate: the referee holds this monster committed for the whole ACTION window (glide term +
	# rest), but the node's glide_finished (which woke us via on_boundary) fires at the SLIDE boundary
	# — so a post-slide think lands mid-SETTLE and sees busy. This is the chase-parity hot loop.
	if _referee.is_entity_moving(_entity_id):
		# Report engagement each think (Tactical Zones v1, §2.8.7) — this busy branch is the chase-parity
		# hot loop, so the resolver's leash target must stay fresh as the monster moves. Reads the
		# post-step tile (this monster's committed destination under conga = its single occupancy entry).
		_update_engagement(_referee.tile_of_entity(_entity_id), _referee.player_tiles())
		# Two things happen here, in order:
		#   1) Compute the always-armed BACKSTOP wake at the remaining SETTLE + epsilon. Settle is
		#      (1 - slide_fraction) of the glide term plus any rest = 0.3 beats at the defaults, so the
		#      wake lands windup_rethink_epsilon_sec (0.05s) PAST the action-window boundary — the exact
		#      per-step wall-clock the pre-v0.9.3 code paid on EVERY step. Now purely a recovery path.
		#   2) PIPELINE the next chase step NOW (_try_pipeline_next_step). On success the referee's
		#      _pending slot promotes+broadcasts it at the action boundary with ZERO gap — the identical
		#      held-key machinery — and the promoted step's glide_finished drives the next think, so we
		#      skip the backstop. Any refusal falls through and the backstop recovers at status-quo timing.
		#
		# WHY: the epsilon-wake WAS the open-field chase gap (v0.9.2 playtest, Jon+Jeff). Scheduling it
		# on every step cost a fixed windup_rethink_epsilon_sec (0.05s, NOT beat-scaled) of wall-clock
		# per step, so a goblin lost 0.05/beat_sec of ground each step — 20% at a 0.25s beat, 10% at
		# 0.50s — while a held-key player rode the referee's zero-gap _pending promotion. Pipelining the
		# step puts the monster on that same promotion path: exact open-field parity (Jon's decision —
		# escapes come from corners/body-blocking, never raw speed; per-monster glide_beats stays the
		# future speed dial). Losing one step at a corner is INTENDED; the backstop re-decides there.
		var glide_beats := 1.0
		if _monster_type != null and _monster_type.glide_speed != null:
			glide_beats = _monster_type.glide_speed.glide_beats
		# A diagonal step's glide term carries the multiplier (the referee stamps it the same way) —
		# without it the wake fires early on diagonals and re-trips the gate, wasting a reschedule.
		if _last_step_was_diagonal:
			glide_beats *= GameManager.config.diagonal_step_multiplier
		var slide_fraction := clampf(GameManager.config.slide_fraction, 0.05, 1.0)
		var settle_beats := (1.0 - slide_fraction) * glide_beats + GameManager.config.move_rest_beats
		var backstop_sec := settle_beats * _pace_beat_sec() + windup_rethink_epsilon_sec
		# Arm the backstop ONLY when no step was pipelined this think. A successful pipeline is carried
		# to the next think by the promoted step's glide_finished, so arming here too would fire a
		# redundant busy think that re-arms in turn (backstop thinks are themselves busy) — an unbounded
		# timer cascade. Not-pipelined is the ONLY case needing recovery, and it always gets it. (This
		# is the one deliberate refinement of the plan's "arm at every busy think": it faithfully keeps
		# the plan's stated intent that the backstop "no-ops if the pipelined step ran".)
		if _try_pipeline_next_step():
			return
		_reschedule_after(backstop_sec)
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
		# a permanently dormant monster. Report disengagement so the resolver drops this monster's
		# bubble/leash (and its own tactical pace) while it idle-waits.
		_report_engagement(false, 0)
		_reschedule()
		return

	# Aggro acquisition + persistence + engagement report (Tactical Zones v1, §2.8.7): _update_engagement
	# latches/leashes _aggroed via _should_chase from the nearest-target Chebyshev distance, records
	# _target_id, reports (aggroed, target) to the pace referee, and returns whether to engage. Un-acquired
	# / leash-dropped means idle on the re-think cadence. The SAME _should_chase decision the busy-think
	# pipeline consults, so both chase paths acquire identically.
	if not _update_engagement(my_tile, targets):
		_reschedule()
		return

	# Adjacent to a hostile player? (M3: every player is hostile to the monster — the faction rule;
	# when neutral factions exist this filters by is_hostile_to.) Request a wind-up.
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
	var dir := _first_step_toward(my_tile, targets)
	if dir == Vector2i.ZERO:
		# Every player unreachable (walls only — a corridor-blocking PLAYER is handled as the
		# adjacent-attack case above, so the single-goblin M3 can't softlock here). A monster
		# blocked by another MONSTER would re-think forever — known M3 limitation; multi-monster
		# pathing is future work.
		_reschedule()
		return

	# Remember the step's shape for the settle wake: a DIAGONAL step's action window carries the
	# diagonal multiplier (the referee stamps it), so the busy-gate's settle math must match or the
	# wake fires early and burns an extra reschedule per diagonal step (speed-parity leak at any
	# multiplier != 1.0).
	_last_step_was_diagonal = dir.x != 0 and dir.y != 0
	# Host-local submit through the referee's validator. On accept the referee broadcasts the
	# glide_to itself (as_peer = this negative id), which drives the tween on every peer and, at
	# this monster's boundary, fires glide_finished -> on_boundary -> the next think. So a SUCCESS
	# schedules nothing here; only a refusal falls through to the re-think.
	if not _referee.submit_monster_intent(_entity_id, dir):
		_reschedule()


## Busy-think MOVEMENT pipeline (chase parity, v0.9.3). Called ONLY from the busy gate, where
## glide_finished woke us mid-SETTLE (the current step still committed in the referee). Computes the
## next chase step from our POST-STEP tile — the current glide's DESTINATION, which under the conga
## toggle is already this entity's single occupancy entry (tile_of_entity returns it) — and submits
## it into the referee's _pending slot, which promotes+broadcasts it at the exact action-window
## boundary the current step ends on. That is the identical zero-gap machinery a held-key player
## rides. Returns true ONLY when a step was actually pipelined (the caller then skips the backstop and
## lets the promoted step's glide_finished drive the next think); any refusal returns false so the
## caller arms the status-quo backstop.
##
## MOVEMENT ONLY: if the nearest target is Chebyshev-adjacent to our post-step tile we do NOT pipeline
## — a monster never bumps, so a step there would waste the slot; the backstop wake fires the normal
## attack think instead (the 0.05s then only delays ENTERING melee, imperceptible; the hot chase loop
## stays zero-gap). Gated on the SAME conga toggle players pipeline under (origin_frees_at_glide_start)
## — under hold-origin the slot is off for everyone and the backstop recovers at status-quo timing.
func _try_pipeline_next_step() -> bool:
	# Pipelining only exists under conga; the referee refuses a held-origin pipeline anyway, but gate
	# here too so we fall straight to the backstop rather than eating a guaranteed-refused submit.
	if not GameManager.config.origin_frees_at_glide_start:
		return false
	# Post-step tile = the current glide's destination (our one occupancy entry under conga).
	var my_tile: Vector2i = _referee.tile_of_entity(_entity_id)
	if WorldGrid.is_wall(my_tile):
		return false
	var targets: Array = _referee.player_tiles()
	if targets.is_empty():
		return false
	var nearest_dist := _nearest_target_dist(my_tile, targets)
	# Same acquire/leash decision the idle branch makes — never pipeline a chase we wouldn't start.
	if not _should_chase(nearest_dist):
		return false
	# Movement only: adjacency is the attack think's job, fired by the backstop next boundary.
	if nearest_dist <= 1:
		return false
	var dir := _first_step_toward(my_tile, targets)
	if dir == Vector2i.ZERO:
		return false
	# Pipelined steps aim at the target's submit-time position (one think stale — the same trade a
	# held-key player makes; the next boundary think re-aims). Only update _last_step_was_diagonal on
	# a SUCCESSFUL submit: on a refusal it must stay the CURRENT (still-gliding) step's shape so the
	# caller's already-computed backstop settle math still matches.
	if _referee.submit_monster_intent(_entity_id, dir):
		_last_step_was_diagonal = dir.x != 0 and dir.y != 0
		return true
	return false


## Nearest target by Chebyshev (king-move) distance from `my_tile`. Returns -1 only for an empty
## target list (callers guard that first). Shared by the idle branch and the busy-think pipeline so
## both read distance identically.
func _nearest_target_dist(my_tile: Vector2i, targets: Array) -> int:
	var nearest := -1
	for t in targets:
		var d: int = maxi(absi(t.x - my_tile.x), absi(t.y - my_tile.y))
		if nearest < 0 or d < nearest:
			nearest = d
	return nearest


## Aggro acquire + leash decision (monster_type.aggro_range_tiles + aggro_persists, DESIGN §2.8),
## with the _aggroed latch side effect. aggro_range_tiles <= 0 (or a null type — a client's inert
## brain, which never reaches here) = UNLIMITED aggro, so the gate is skipped and we always chase.
## Otherwise ACQUIRE when the nearest is within range (latching _aggroed); with aggro_persists true
## (default) range no longer matters once latched — the chase never leash-drops, following across
## rooms. With aggro_persists false the legacy LEASH returns: _aggroed tracks current in-range state
## and the chase drops the instant the target breaks range. Returns whether to engage.
func _should_chase(nearest_dist: int) -> bool:
	if _monster_type == null or _monster_type.aggro_range_tiles <= 0:
		return true
	if nearest_dist <= _monster_type.aggro_range_tiles:
		_aggroed = true
	elif not _monster_type.aggro_persists:
		_aggroed = false
	return _aggroed


## Recompute this monster's engagement from live referee state and REPORT it to the pace referee
## (Tactical Zones v1, §2.8.7) — called every think so the resolver always has this monster's current
## (aggroed, chase target) for the tactical bubble + leash. Latches _aggroed via _should_chase, records
## _target_id as the nearest player's id (0 when not chasing), reports, and returns whether to engage.
## Empty targets → disengage (report false, clear target). Shared by the idle branch and the busy loop.
func _update_engagement(my_tile: Vector2i, targets: Array) -> bool:
	if targets.is_empty():
		_target_id = 0
		_report_engagement(false, 0)
		return false
	var nearest_dist := _nearest_target_dist(my_tile, targets)
	var chasing := _should_chase(nearest_dist)
	# The leash target is the id occupying the nearest tile (authoritative occupancy, not a rendered
	# position) — the same nearest the aggro decision keyed on. Cleared to 0 when not chasing.
	_target_id = _referee.entity_at(_nearest_target_tile(my_tile, targets)) if chasing else 0
	_report_engagement(chasing, _target_id)
	return chasing


## The tile of the nearest target by Chebyshev distance (the twin of _nearest_target_dist, returning
## the tile instead of the distance). Callers guard an empty list first, so targets[0] is a safe seed.
func _nearest_target_tile(my_tile: Vector2i, targets: Array) -> Vector2i:
	var best: Vector2i = targets[0]
	var nearest := -1
	for t in targets:
		var d: int = maxi(absi(t.x - my_tile.x), absi(t.y - my_tile.y))
		if nearest < 0 or d < nearest:
			nearest = d
			best = t
	return best


## Report this monster's engagement to the pace referee (guarded for a client's null-pace inert brain,
## which never thinks anyway). The ONE call site wrapper so both the idle and busy paths report identically.
func _report_engagement(aggroed: bool, target_id: int) -> void:
	if _pace != null:
		_pace.report_engagement(_entity_id, aggroed, target_id)


## This monster's own resolved beat (seconds) at wake time — tactical when aggroed, explore otherwise
## (§2.8.7), so its pacing math matches the pace the referee stamped its glide at. Explore fallback when
## no pace referee is injected (defensive: the host always injects; a client's brain never thinks).
func _pace_beat_sec() -> float:
	if _pace != null:
		return _pace.beat_sec_for(_entity_id)
	return GameManager.explore_beat_sec


## First step DIRECTION toward the nearest player by path length over the walls-only A* grid, or
## Vector2i.ZERO if every player is unreachable (sealed/OOB). Body occupancy is deliberately NOT in
## that grid (bodies are volatile) — the referee's validator is the authority on whether the chosen
## step is actually free. Shared by the idle branch and the busy-think pipeline.
func _first_step_toward(my_tile: Vector2i, targets: Array) -> Vector2i:
	var best_path: Array[Vector2i] = []
	for t in targets:
		var path := WorldGrid.find_path(my_tile, t)
		# find_path returns [] for unreachable and a >= 2 path when a step exists.
		if path.size() >= 2 and (best_path.is_empty() or path.size() < best_path.size()):
			best_path = path
	if best_path.is_empty():
		return Vector2i.ZERO
	return best_path[1] - my_tile


## Schedule one re-think rethink_beats from now (the refused/blocked/no-target back-off cadence),
## converted at THIS monster's resolved pace (§2.8.7) — not cached, so an aggro/tempo change is picked
## up on the next back-off. An aggroed monster backs off at the tactical beat, matching its glide stamps.
func _reschedule() -> void:
	_reschedule_after(rethink_beats * _pace_beat_sec())


## Schedule one re-think `sec` from now. A get_tree() SceneTreeTimer (not a Timer child) so it
## survives on the host tree exactly as the referees' completion timers do; if this brain is freed
## (despawn) before it fires, Godot drops the connection to the freed method — no stale call. Used
## both for the normal back-off cadence and, with a longer span, to wake just past a wind-up's end.
func _reschedule_after(sec: float) -> void:
	get_tree().create_timer(sec).timeout.connect(_think)
