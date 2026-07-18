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
## through the referee's host-local validator. A refused step, an empty path, or a busy gate
## schedules a re-think rethink_delay_sec later — the delay is the hot-loop guard (a brain never
## re-thinks twice in one frame) and mirrors MoveInput's post-reject retry cadence.

## Re-think delay (seconds) after a refused/blocked action or a busy gate. Matches MoveInput's
## held_retry_cooldown_sec so a monster and a player back off a contested tile at the same cadence.
@export var rethink_delay_sec: float = 0.25

## Small margin (seconds) added past a wind-up's duration when the brain schedules its own
## re-think after committing one. A wind-up busy record ends without a glide_finished (that only
## fires on real glides), so the brain wakes ITSELF just after resolution — think-at-own-boundary,
## no new signal plumbing. The epsilon guarantees the referee's busy record has cleared first.
@export var windup_rethink_epsilon_sec: float = 0.05

# Set true by activate(); a client's brain stays false and every think early-returns.
var _active: bool = false
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


# ── Public methods ────────────────────────────────────────────────────────────

## Host-only switch-on, called by the parent monster's activate_brain(). Stores the referees + id
## and kicks off the first think DEFERRED — so the referees' spawn-enter hooks have already seeded
## this monster's occupancy + HP and the node's _ready has run before we query anything.
func activate(referee: Node, combat: Node, entity_id: int) -> void:
	_referee = referee
	_combat = combat
	_entity_id = entity_id
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
	# Busy gate: only ever act between committed steps. If the referee still shows this monster
	# mid-glide (a boundary think can race the referee's completion timer against the visual
	# tween), back off and retry — self-healing, never a lockup.
	if _referee.is_entity_moving(_entity_id):
		_reschedule()
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

	# Adjacent to a hostile player? (M3: every player is hostile to the monster — the faction rule;
	# when neutral factions exist this filters by is_hostile_to.) Chunk-2 seam: request a wind-up.
	for t in targets:
		if maxi(absi(t.x - my_tile.x), absi(t.y - my_tile.y)) == 1:
			# Request a telegraphed wind-up against that tile (decision 3). The combat referee
			# validates it, commits the monster (from==to busy record on the movement referee),
			# posts the telegraph, and resolves it against the TILE windup_sec later.
			var windup_sec: float = _combat.wind_up(_entity_id, t)
			if windup_sec > 0.0:
				# The wind-up busy record ends WITHOUT waking us (glide_finished fires only on real
				# glides), so schedule our OWN re-think just past resolution — think-at-own-boundary,
				# no new signal plumbing. On resolution the target may have fled or died; the next
				# think re-decides (chase, or wind up anew if still adjacent).
				_reschedule_after(windup_sec + windup_rethink_epsilon_sec)
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


## Schedule one re-think rethink_delay_sec from now (the refused/blocked/busy cadence).
func _reschedule() -> void:
	_reschedule_after(rethink_delay_sec)


## Schedule one re-think `sec` from now. A get_tree() SceneTreeTimer (not a Timer child) so it
## survives on the host tree exactly as the referees' completion timers do; if this brain is freed
## (despawn) before it fires, Godot drops the connection to the freed method — no stale call. Used
## both for the normal back-off cadence and, with a longer span, to wake just past a wind-up's end.
func _reschedule_after(sec: float) -> void:
	get_tree().create_timer(sec).timeout.connect(_think)
