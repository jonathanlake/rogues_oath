class_name PaceReferee
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
## Chunk 2 (v0.9.5): the resolver also BROADCASTS. A player's resolved pace is compared against the
## last value broadcast for them and, on a flip, a `pace_changed` event posts so every peer plays the
## TWO-SIGNAL pace cue (tempo-bar emphasis + own-player log line) — deliberately NO sound: pace flips
## are a two-signal cue by audio-grammar choice (v0.6.2, "hit + swing are the only combat noises"), so
## §2.3.4's sound prong applies to combat OUTCOMES, not to a pace-mode change. Two flush triggers: a coarse host-side poll
## Timer (server-internal re-check — NOT wire traffic; events post only on change per §2.5) catches
## time-driven exits (hysteresis expiry, which no state update signals), and an immediate flush after
## report_engagement / report_hostile_action makes ENTRY cues fire on the frame the fight starts rather
## than waiting for the next poll. Monsters get no cue (their pace needs no player-facing signal).

## Coarse host-side re-check interval (seconds) for the pace-flip poll (§2.8.7). Server-internal
## polling only — it re-resolves each player and posts a `pace_changed` ONLY on a flip (per §2.5, events
## post on change, never per-tick), so this is not wire traffic. Its sole unique job is catching the
## time-driven EXIT (hysteresis expiry / forcing-window lapse), which no state update signals; entry
## flips are already flushed immediately by the report_* hooks. ~0.25s balances cue latency vs churn.
@export var pace_poll_sec: float = 0.25

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
# (negative) -> a small { "target": int, "radius": int } dict. Presence means "this monster is aggroed"
# (drives BOTH the monster's own tactical pace and the players' bubble); `target` is the player id it is
# currently chasing (its leash key), `radius` is its authored tactical_radius_tiles CACHED at report
# time (the value is authored-static — no runtime writes — so resolving it once per engagement, not per
# player-loop iteration, saves the hot-path node lookup). Erased when the brain reports un-aggroed and
# on the monster's container-exit.
var _engagements: Dictionary = {}
# Forcing-window deadlines (anti-cheese): player id -> Time.get_ticks_msec() wall-clock instant the
# window expires. Armed by report_hostile_action; a player is tactical while now < this. No entry /
# past deadline = not forcing.
var _force_until: Dictionary = {}
# Hysteresis timestamps: player id -> the last Time.get_ticks_msec() at which the player would resolve
# tactical. WRITTEN by _resolve_tactical as a side effect on every tactical resolve (host-only, single-
# threaded), so stamp-time (beat_sec_for) and the poll-timer verdict (_flush_pace_changes) share the ONE
# resolve and can never disagree. NO ENTRY = never qualified = explore immediately (fresh spawns / late
# joiners), which is why this is a lazy write rather than a seeded default.
var _last_qualified: Dictionary = {}
# Last pace BROADCAST for each player: player id -> bool (true = tactical). A flush diffs the live
# resolve against this; a flip posts `pace_changed` and updates it. Seeded on player spawn
# (on_player_spawned) so a joiner gets its initial pace once and the poll then posts only changes.
var _last_broadcast: Dictionary = {}
# The coarse re-check Timer (host-only), created + started in activate(). Server-internal — it drives
# the EXIT flush no state update signals (hysteresis expiry). Held so its ownership is unambiguous.
var _poll_timer: Timer = null
# PASS-1 cache (Tactical Zones v1 two-pass resolve, v0.10.3): player id -> MONSTER-SOURCED qualification
# (forcing window ∨ leash ∨ monster bubble), the ONLY qualification that PROJECTS a teammate-pull bubble
# (pass 2). Recomputed fresh at the top of every resolve BATCH — each _flush_pace_changes and each
# single-player _resolve_tactical — and reused across the players within that batch, so pass 2's proximity
# check reads a precomputed map instead of recomputing pass 1 per player (no O(n²) recompute of the
# engagement loop). NEVER cached across batches: player tiles move between polls and no state event
# signals that, so a fresh batch always re-reads authoritative tiles. Holds PURE reads (no hysteresis
# side effect) — the hysteresis writer is _resolve_player_tactical, downstream of this.
var _pass1: Dictionary = {}


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
	# The coarse re-check poll (§2.8.7), host-only. A repeating Timer added as a child of this in-tree
	# referee node — server-internal, it re-resolves each player and posts a pace_changed ONLY on a flip
	# (the EXIT cue the report_* hooks can't catch, since hysteresis expiry is time-driven). Never armed
	# on clients (activate never runs there), so a client's pace referee posts nothing.
	_poll_timer = Timer.new()
	_poll_timer.name = "PacePollTimer"
	_poll_timer.wait_time = pace_poll_sec
	_poll_timer.one_shot = false
	_poll_timer.autostart = true
	_poll_timer.timeout.connect(_flush_pace_changes)
	add_child(_poll_timer)


## THE resolver read every stamp site uses. Returns the beat (seconds) this entity's NEXT committed
## window stamps from — tactical or explore per _resolve_tactical. Host-only (stamp sites never run on
## clients). Sharing _resolve_tactical with the poll/flush means a stamp and a poll verdict for the same
## instant can never disagree (both take the one hysteresis-writing resolve).
func beat_sec_for(entity_id: int) -> float:
	return GameManager.tactical_beat_sec if _resolve_tactical(entity_id) else GameManager.explore_beat_sec


## THE single "no resolver → explore" policy site (§2.8.7), shared by the three stamp-site referees
## (MoveReferee, CombatReferee, MonsterBrain) so none keeps a private copy of the fallback rule. Given a
## (possibly null) PaceReferee and an entity id, returns that entity's resolved beat (seconds) — tactical
## or explore. The NULL branch exists for PARSE / UNIT safety only (a defensive path); host wiring always
## injects a live resolver at every stamp site, so the real path is always pace.beat_sec_for. Static so a
## caller holding a null _pace can still reach the ONE fallback (it can't call an instance method on null).
static func beat_or_explore(pace, entity_id: int) -> float:
	if pace != null:
		return pace.beat_sec_for(entity_id)
	return GameManager.explore_beat_sec


## Late-join seed (§2.8.7), called from Main's host-side player-spawn hook. Posts this player's CURRENT
## pace once so a joiner's tempo-bar seeds correctly — joiners default to explore in the UI, and this
## single event corrects them if they happened to spawn into a fight. Seeds _last_broadcast so the poll
## then posts only genuine flips. Host-only; a non-player id is ignored.
func on_player_spawned(entity_id: int) -> void:
	if entity_id <= 0:
		return
	var tactical := _resolve_tactical(entity_id)
	_last_broadcast[entity_id] = tactical
	# `seed: true` marks this as a SEED, not a real flip: main.gd applies it to the bar exactly like a flip
	# (correcting a joiner / respawner's initial emphasis), but game_log SKIPS the log line for it — a
	# spawn is not a mode change, so the "— pace —" marker stays reserved for genuine flips.
	NetEvents.post_event("pace_changed", { "entity_id": entity_id, "pace": _pace_name(tactical), "seed": true })


## Called by each MonsterBrain every think (injected ref — the brain never reaches up). Records this
## monster's aggro + current chase target so the resolver can project its bubble and honour the leash.
## aggroed false erases the entry (an idle / leash-dropped monster projects nothing). target_id is the
## player the monster is chasing (0 when none) — the leash key.
func report_engagement(monster_id: int, aggroed: bool, target_id: int) -> void:
	# Change-detect (review #2): this is called EVERY think (the chase-parity hot loop), so on a steady
	# chase / a steady idle the state is unchanged and there is nothing to flush. Only a genuine change
	# writes + flushes: a NEW engagement, a switched leash target, or an un-aggro that drops a live entry.
	if aggroed:
		var existing: Variant = _engagements.get(monster_id)
		# Same target already recorded → no change (radius is authored-static, can't move): skip the dict
		# write AND the flush. Radius is resolved ONCE here (review #4), never in the per-player loop.
		if existing != null and int(existing["target"]) == target_id:
			return
		_engagements[monster_id] = { "target": target_id, "radius": _radius_of(monster_id) }
	else:
		# Un-aggro: only a real drop (an entry existed) is a change worth flushing — an already-idle
		# monster reporting false every think must NOT re-flush (that was the unconditional-flush waste).
		if not _engagements.has(monster_id):
			return
		_engagements.erase(monster_id)
	# Flush immediately so an ENTRY / EXIT cue (a player just entered a bubble / became a leash target, or
	# a monster just dropped aggro) fires on this frame rather than waiting up to pace_poll_sec for the poll.
	_flush_pace_changes()


## Called by CombatReferee / MoveReferee when a PLAYER lands a hostile action (its bump), BEFORE that
## attack's own window is stamped — so the triggering attack is itself a tactical-pace action (no fast
## first swing) AND the player stays tactical for a beat afterward (anti-cheese: hitting the dummy
## counts, the rule is uniform). Arms a wall-clock deadline of tactical_force_beats × tactical_beat_sec
## seconds from now. Host-only.
func report_hostile_action(player_id: int) -> void:
	var window_ms := int(GameManager.config.tactical_force_beats * GameManager.tactical_beat_sec * 1000.0)
	_force_until[player_id] = Time.get_ticks_msec() + window_ms
	# Flush immediately so the attacker's tactical cue fires the instant the swing commits (its own
	# window already stamps tactical — see MoveReferee._begin_bump), not on the next poll.
	_flush_pace_changes()


# ── Private methods ───────────────────────────────────────────────────────────

## THE one pace resolve, shared by beat_sec_for (stamps), on_player_spawned (seed) and — via
## _resolve_player_tactical — _flush_pace_changes (poll), so the stamp verdict and the poll verdict for
## the same instant can never disagree. Monsters: tactical iff engaged (aggroed — always inside their own
## bubble), no hysteresis/forcing, no pass-1 map. Players: this single-entity entry refreshes the pass-1
## map for the whole party (so the player's teammate-pull reads current qualifications) then defers to
## _resolve_player_tactical, which is the qualify + hysteresis half.
func _resolve_tactical(entity_id: int) -> bool:
	# Monsters: tactical iff engaged (always inside their own bubble); no hysteresis/forcing, no pass 1.
	if entity_id < 0:
		return _engagements.has(entity_id)
	# Single-player resolve (a stamp via beat_sec_for, or the spawn seed): refresh the pass-1 map for the
	# whole party first so this player's pass-2 teammate-pull reads current qualifications, THEN resolve.
	# The flush path recomputes ONCE for its whole loop and calls _resolve_player_tactical directly instead.
	_recompute_pass1()
	return _resolve_player_tactical(entity_id)


## The per-player half of the resolve — assumes _pass1 is already fresh for this batch (caller's job).
## Applies the hysteresis and is the hysteresis WRITER: any resolve that lands tactical (monster-sourced
## OR teammate-pulled) stamps _last_qualified as a side effect, so a pulled player earns its own exit
## hysteresis the moment its puller's real source is gone. No _last_qualified entry = never qualified =
## explore immediately (fresh spawns / joiners).
func _resolve_player_tactical(player_id: int) -> bool:
	if _player_qualifies_tactical(player_id):
		_last_qualified[player_id] = Time.get_ticks_msec()
		return true
	if _last_qualified.has(player_id):
		var elapsed_ms := Time.get_ticks_msec() - int(_last_qualified[player_id])
		if elapsed_ms < int(GameManager.config.tactical_exit_sec * 1000.0):
			return true
	return false


## Refresh the PASS-1 map (monster-sourced qualification for every live player) for the current resolve
## batch. Pure reads only — _monster_sourced_qualifies has no side effects — so recomputing it here and
## again for the resolving player itself (in _player_qualifies_tactical) is cheap and can never disturb
## hysteresis. Called once per _flush_pace_changes and once per single-player _resolve_tactical.
func _recompute_pass1() -> void:
	_pass1 = {}
	if _players == null:
		return
	for child in _players.get_children():
		if child is Entity and child.entity_id > 0:
			_pass1[child.entity_id] = _monster_sourced_qualifies(child.entity_id)


## Re-resolve every live player and post a `pace_changed` for each whose pace flipped since the last
## broadcast (§2.8.7, §2.5 "events post on change"). Called by the poll Timer (catches time-driven
## EXITs) and immediately after report_engagement / report_hostile_action (ENTRY cues, no poll wait).
## Players only — monster pace needs no player-facing cue. Host-only (post_event is call_local; a client
## never reaches here). Iterating _players is safe: post_event mutates no referee state read in the loop.
func _flush_pace_changes() -> void:
	if _players == null:
		return
	# Recompute the pass-1 map ONCE for this whole flush (not per player), then resolve each player
	# against it — pass 2's teammate-pull reads the precomputed map, so the O(n) engagement work runs
	# per player only once, never n times per player. The _last_broadcast flip diff is unchanged.
	_recompute_pass1()
	for child in _players.get_children():
		if not (child is Entity):
			continue
		var player_id: int = child.entity_id
		if player_id <= 0:
			continue
		var tactical := _resolve_player_tactical(player_id)
		if not _last_broadcast.has(player_id) or bool(_last_broadcast[player_id]) != tactical:
			_last_broadcast[player_id] = tactical
			NetEvents.post_event("pace_changed", { "entity_id": player_id, "pace": _pace_name(tactical) })


## The wire label for a resolved pace — the ONE mapping bool -> the string the cue reads, so the event
## name can't drift between the seed, the poll, and the flush.
func _pace_name(tactical: bool) -> String:
	return "tactical" if tactical else "explore"


## PASS 1 + PASS 2 combined: does this player qualify for tactical RIGHT NOW? Pass 1 =
## _monster_sourced_qualifies (this player, directly). Pass 2 = TEAMMATE PULL: within Chebyshev
## player_tactical_radius_tiles of any teammate whose PASS-1 (monster-sourced) qualification is true.
## Reading _pass1 (monster-sourced only) for the pull — NOT broadcast pace, NOT the puller's hysteresis —
## is what prevents chaining and mutual-lock: a merely-pulled or hysteresis-lingering teammate has a
## false _pass1 entry and projects nothing, so when the real monster source is gone every pulled player
## drops to its own hysteresis and the whole group exits orderly. Pure read; the hysteresis is applied by
## the caller (_resolve_player_tactical). Assumes _pass1 is fresh for this batch (caller recomputed it).
func _player_qualifies_tactical(player_id: int) -> bool:
	# Pass 1: this player's own monster-sourced qualification (the common, in-the-fight case). Recomputed
	# directly here (not read from _pass1) so a stamp for a player not in the just-built map still resolves
	# its own source correctly — one extra cheap call, and it can never be stale for self.
	if _monster_sourced_qualifies(player_id):
		return true
	# Pass 2: teammate pull. Disabled at radius <= 0, and needs this player's live tile.
	var radius := int(GameManager.config.player_tactical_radius_tiles)
	if radius <= 0:
		return false
	var puller_tile := _tile_of(player_id)
	if puller_tile == _NO_TILE:
		return false
	for other_id in _pass1:
		# Only MONSTER-SOURCED teammates project the pull (no chaining); skip self and non-sourced.
		if int(other_id) == player_id or not bool(_pass1[other_id]):
			continue
		var other_tile := _tile_of(int(other_id))
		if other_tile == _NO_TILE:
			continue
		if maxi(absi(puller_tile.x - other_tile.x), absi(puller_tile.y - other_tile.y)) <= radius:
			return true
	return false


## PASS 1: does this player qualify for tactical from a MONSTER SOURCE right now (monster bubble ∨ leash ∨
## forcing window)? Pure read of live engagement + forcing state + authoritative tiles — no hysteresis,
## no teammate pull. This is the ONLY qualification that PROJECTS a pull bubble onto teammates (pass 2),
## so a bubble-pulled or hysteresis-lingering player never appears here — that is the anti-chain guarantee.
func _monster_sourced_qualifies(player_id: int) -> bool:
	# Forcing window (anti-cheese) — a recent hostile action keeps the actor tactical regardless of
	# proximity, so a player can't tap-and-flee to cheese explore pace between swings. Stays AHEAD of the
	# engagement loop: a cheap map probe that short-circuits before any per-monster work.
	if _force_until.has(player_id) and Time.get_ticks_msec() < int(_force_until[player_id]):
		return true
	# ONE pass over live engagements does BOTH proximity tests (was two separate loops, review #9). Per
	# monster, in order:
	#  - LEASH (Jon's pick, DESIGN §2.8.7 revisit note): this player is that monster's current chase
	#    target → tactical however far they run (chase parity). Tile-independent, so it runs for EVERY
	#    entry even when the player holds no tile.
	#  - BUBBLE: within the monster's authored tactical_radius_tiles (Chebyshev). Skipped via `continue`
	#    when the player has no live tile, the monster projects no bubble (radius 0), or the monster is
	#    off-grid. Radius is read from the cached entry (review #4) — no per-iteration _radius_of lookup.
	# player_tile is resolved ONCE before the loop. All matches short-circuit `return true`; a non-match
	# falls through every entry. Idle / brainless monsters (the dummy) never appear in _engagements.
	var player_tile := _tile_of(player_id)
	for monster_id in _engagements:
		var entry: Dictionary = _engagements[monster_id]
		if int(entry["target"]) == player_id:
			return true
		if player_tile == _NO_TILE:
			continue
		var radius := int(entry["radius"])
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
## value everywhere (the wire carries the type PATH, never pixels). Called ONCE per engagement, at
## report_engagement time, and cached in the entry — never in the per-player qualify loop (review #4).
func _radius_of(monster_id: int) -> int:
	if _monsters == null:
		return 0
	var node := _monsters.get_node_or_null(str(monster_id))
	if node is Monster and node.monster_type != null:
		# The -1 "match aggro" sentinel resolves inside MonsterType.resolved_tactical_radius() — the one
		# shared resolver (the F7 overlay reads the same method), so the sentinel never reaches the
		# Chebyshev comparison in _monster_sourced_qualifies. (If aggro is 0 = unlimited, the match is
		# 0 = no proximity bubble; the qualify loop skips radius <= 0 — leash/forcing still apply.)
		return node.monster_type.resolved_tactical_radius()
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
		var departing: int = node.entity_id
		_force_until.erase(departing)
		_last_qualified.erase(departing)
		# Drop the last-broadcast record too, so a rejoining peer id re-seeds fresh (its first flush
		# posts, rather than being deduped against a stale pre-disconnect value).
		_last_broadcast.erase(departing)
		# Ghost-leash sweep (the refuted-but-real note from review): the departing player may still be some
		# aggroed monster's cached leash target. Zero any such target so no cross-reference to a freed
		# player id outlives the disconnect — the monster keeps its aggro + bubble; its next think re-reports
		# a live target. (Values are { target, radius } dicts; mutating a value while iterating keys is safe.)
		for monster_id in _engagements:
			if int(_engagements[monster_id]["target"]) == departing:
				_engagements[monster_id]["target"] = 0
