class_name UtilityScorer
extends RefCounted

## The WEIGHTED UTILITY SCORER (v0.22.0, Jeff's spec — DESIGN §2.12). Given one snapshot of a monster's
## situation, it enumerates that monster's candidate actions and SCORES each for desirability. It decides
## NOTHING else: picking, tie-breaking, committing, pacing and every Commitment-Rule concern stay with
## MonsterBrain, which owns the timing machinery. This file is pure ranking.
##
## PURE STATIC FUNCTIONS, no node state, no referee reads, no RNG (RefCounted so it is never instanced —
## `class_name` just makes the statics reachable as `UtilityScorer.score_candidates(...)`). Everything it
## needs arrives in ONE context Dictionary the brain builds from AUTHORITATIVE referee state at think time;
## everything it produces is an Array of `{ action: String, score: float, data: Dictionary }`. That shape
## makes it trivially unit-testable and keeps the scoring rules in one readable place a designer can be
## walked through.
##
## Host-only by construction: the only caller is the host-only MonsterBrain (DESIGN §2.5.3 — the world's
## decisions are the host's). No score ever crosses the wire except on the dev-gated `ai_decision` debug
## event; adjudication reads the shared MonsterType server-side, never a client value.
##
## SCORES ARE DESIRABILITY, NOT PROBABILITY (Jeff's framing): the AI should almost always do the obviously
## right thing, so the weights are tuned to separate cleanly and only the brain's small tie-break band
## introduces any randomness. Every candidate is emitted EVERY think — including the ones scoring 0 — so
## the /ai debug overlay can show "melee 0" (why it did NOT do a thing is half the tuning story). The brain
## skips zero-score candidates when it executes.
##
## Composite scores are FLOORED AT 0: a penalty (the adjacent-smite one) can zero a candidate out but never
## drive it negative, so "unavailable" and "scored badly" collapse to the same 0 the executor skips.

## Candidate action ids — the ONE spelling shared by this scorer, the brain's executor, and the debug
## event/overlay, so a rename can never silently desync the three.
const ACTION_HEAL := "heal"
const ACTION_SMITE := "smite"
const ACTION_MELEE := "melee"
const ACTION_FLEE := "flee"
const ACTION_APPROACH := "approach"


# ── Public methods ────────────────────────────────────────────────────────────

## Score every candidate action from one situation snapshot. Returns them in a FIXED authoring order
## (heal, smite, melee, flee, approach) — the caller applies personality multipliers and sorts.
##
## Context keys (all built by MonsterBrain from authoritative referee state):
##   type                 MonsterType — the authored weights (read live, so /m tuning applies this think)
##   engaged              bool    — the aggro/leash verdict for this think
##   heal_available       bool    — has_heal_ability() AND a valid heal target was found
##   heal_target_id       int     — that target's entity id (echoed into the candidate's `data`)
##   heal_worst_frac      float   — the WORST injured ally's hp/max fraction in heal range (1.0 = none)
##   heal_injured_count   int     — how many injured allies are in heal range
##   smite_available      bool    — has_smite_ability()
##   smite_tile_valid     bool    — a real target tile exists AND has no pending smite already committed
##   smite_tile           Vector2i — that ground tile (echoed into the candidate's `data`)
##   smite_target_moving  bool    — the occupant of that tile is mid-commit (is_entity_moving)
##   melee_available      bool    — a weapon is equipped (a weaponless monster deals nothing)
##   player_adjacent      bool    — the nearest player is Chebyshev 1 away
##   player_in_flee_range bool    — the nearest player is within flee_range_tiles
##   nearest_tile         Vector2i — the nearest player's tile (the melee target / the flee-away anchor)
##   has_backup           bool    — a living, brained ally within backup_radius_tiles
##
## Each candidate's `data` carries what the brain's executor needs to COMMIT that action (the heal target
## id, the smite ground tile, the melee/flee anchor tile) — echoed straight from the context, so the
## executor never re-derives a target the score was not computed against.
static func score_candidates(ctx: Dictionary) -> Array:
	var out: Array = []
	var type: MonsterType = ctx.get("type")
	if type == null:
		# No authored weights = nothing to rank. The brain treats an empty candidate list as "nothing
		# viable" and falls back to its re-think cadence, so a misconfigured monster idles instead of
		# crashing (a null type is a spawn-config bug the Monster._ready warning already reports).
		return out
	var heal := _score_heal(ctx, type)
	var smite := _score_smite(ctx, type)
	var melee := _score_melee(ctx, type)
	var flee := _score_flee(ctx, type)
	# APPROACH is the only candidate that depends on the others: movement must serve another tactical
	# objective (Jeff), so stepping toward a player scores ONLY when no cast/melee is available from here.
	var in_range: bool = float(heal["score"]) > 0.0 or float(smite["score"]) > 0.0 or float(melee["score"]) > 0.0
	var approach := _score_approach(ctx, type, in_range)
	out.append(heal)
	out.append(smite)
	out.append(melee)
	out.append(flee)
	out.append(approach)
	return out


## Apply a rolled personality's multipliers IN PLACE and return the same array (v0.22.0). Deliberately a
## multiply on the WHOLE composite score of its action — base weight plus every bonus/penalty already
## folded in — and deliberately applied BEFORE the sort: a personality shifts final desirability, which is
## what the brain's tie-break band then measures (Jeff's "close calls" apply to the decision, not to raw
## base weights). Actions with no multiplier (melee/flee/approach) pass through untouched.
static func apply_personality(candidates: Array, heal_mult: float, smite_mult: float) -> Array:
	for c in candidates:
		var action := str(c["action"])
		if action == ACTION_HEAL:
			c["score"] = float(c["score"]) * heal_mult
		elif action == ACTION_SMITE:
			c["score"] = float(c["score"]) * smite_mult
	return candidates


## Sort candidates by score, highest first, IN PLACE (returns the same array for chaining). Ties keep an
## arbitrary order — that is exactly what the brain's tie-break band exists to decide, with RNG the brain
## owns (this file stays deterministic and pure).
static func sort_by_score(candidates: Array) -> Array:
	candidates.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	return candidates


# ── Private methods ───────────────────────────────────────────────────────────

## HEAL: 0 unless a wounded BRAINED ally is known to the scan. IN heal_range_tiles, the QUADRATIC
## missing-HP curve `utility_heal_weight × (1 - worst_frac)²`, plus utility_heal_per_injured_bonus for
## each ADDITIONAL injured ally (the first is already priced by the curve). The square is the whole point:
## an ally at 90% scores ~1 of 100 and one at 25% scores ~56, so a healer tends the dying and ignores
## scratches without anyone authoring a threshold.
## OUT of heal range but inside the scan (backup_radius_tiles), the SAME curve prices the worst far
## patient and `data.in_range=false` carries its tile — the executor WALKS a step toward it instead of
## casting (v0.23.2, Jon: "if heal won the decision, move TOWARDS his buddy" — previously the healer
## shrugged and smote). No per-injured bonus on the far branch (one patient, one destination); the
## per-step re-think re-scores every tile, deterministically, so the decision re-wins until the patient
## is in range, healed, or dead. An in-range patient always outranks the walk (the walk exists to CREATE
## the in-range case).
static func _score_heal(ctx: Dictionary, type: MonsterType) -> Dictionary:
	var candidate := { "action": ACTION_HEAL, "score": 0.0,
			"data": { "target_id": int(ctx.get("heal_target_id", 0)), "in_range": true } }
	if bool(ctx.get("heal_available", false)):
		# Clamped: an over-heal / bad max would otherwise push the fraction outside [0,1] and invert the curve.
		var worst_frac := clampf(float(ctx.get("heal_worst_frac", 1.0)), 0.0, 1.0)
		var missing := 1.0 - worst_frac
		var extra_injured := maxi(0, int(ctx.get("heal_injured_count", 1)) - 1)
		candidate["score"] = maxf(0.0, type.utility_heal_weight * missing * missing
				+ type.utility_heal_per_injured_bonus * float(extra_injured))
		return candidate
	var far_frac := clampf(float(ctx.get("heal_far_frac", 1.0)), 0.0, 1.0)
	if far_frac < 1.0 and type.has_heal_ability():
		var far_missing := 1.0 - far_frac
		candidate["score"] = maxf(0.0, type.utility_heal_weight * far_missing * far_missing)
		candidate["data"] = { "in_range": false, "approach_tile": ctx.get("heal_far_tile", Vector2i.ZERO) }
	return candidate


## SMITE: 0 unless the monster is an authored smiter AND a valid target tile exists that has no smite
## already committed to it (the pending-smite set on CombatReferee — two shamans must not both root
## themselves casting at the same square). Else the base weight, PLUS the standstill bonus when the chosen
## target is not mid-commit (a dodgeable ground-target cast is a far better bet against a stationary
## victim), MINUS the adjacent penalty when a player is in contact (that is melee's or the retreat's
## moment). No "allies are healthy" term is needed — when allies are hurt, heal's curve simply outscores
## this, which is the utility model working rather than a special case.
static func _score_smite(ctx: Dictionary, type: MonsterType) -> Dictionary:
	var candidate := { "action": ACTION_SMITE, "score": 0.0,
			"data": { "tile": ctx.get("smite_tile", Vector2i.ZERO) } }
	if not bool(ctx.get("smite_available", false)):
		return candidate
	if not bool(ctx.get("smite_tile_valid", false)):
		return candidate
	var score := type.utility_smite_weight
	if not bool(ctx.get("smite_target_moving", false)):
		score += type.utility_standstill_bonus
	if bool(ctx.get("player_adjacent", false)):
		score -= type.utility_smite_adjacent_penalty
	candidate["score"] = maxf(0.0, score)
	return candidate


## MELEE: 0 unless a player is ADJACENT (Chebyshev 1) and a weapon is equipped — a weaponless monster
## deals nothing (unarmed is a future natural-weapon, not a fallback), so it must never score a swing.
## Else the base weight plus the ALONE bonus: cornered with no backup, a caster stops kiting and fights.
static func _score_melee(ctx: Dictionary, type: MonsterType) -> Dictionary:
	var candidate := { "action": ACTION_MELEE, "score": 0.0,
			"data": { "tile": ctx.get("nearest_tile", Vector2i.ZERO) } }
	if not bool(ctx.get("melee_available", false)):
		return candidate
	if not bool(ctx.get("player_adjacent", false)):
		return candidate
	var score := type.utility_melee_weight
	if not bool(ctx.get("has_backup", false)):
		score += type.utility_melee_alone_bonus
	candidate["score"] = maxf(0.0, score)
	return candidate


## MOVE (flee step): 0 unless this is a flees_players kiter with a player inside flee_range_tiles. Else the
## flee weight, MULTIPLIED by utility_alone_move_factor (< 1) when alone — Jeff's courage rule as a single
## number: with frontline allies alive kiting outscores everything, and alone the retreat decays until
## smite/melee win instead. The factor is clamped to [0,1] so a fat-fingered value can't turn cowardice
## into the dominant score.
static func _score_flee(ctx: Dictionary, type: MonsterType) -> Dictionary:
	var candidate := { "action": ACTION_FLEE, "score": 0.0,
			"data": { "tile": ctx.get("nearest_tile", Vector2i.ZERO) } }
	if not type.flees_players:
		return candidate
	if not bool(ctx.get("player_in_flee_range", false)):
		return candidate
	var score := type.utility_flee_weight
	if not bool(ctx.get("has_backup", false)):
		score *= clampf(type.utility_alone_move_factor, 0.0, 1.0)
	candidate["score"] = maxf(0.0, score)
	return candidate


## MOVE (approach step): 0 unless ENGAGED and nothing is in range of any cast/melee (`in_range`). Else the
## approach weight — the step that gets a caster into smite/heal range. Because it zeroes out the moment
## any cast or swing is available, the monster never wanders for wandering's sake, and because a committed
## step is ONE tile and the brain re-scores at every glide boundary, an approaching caster re-decides per
## tile and cannot chase past its preferred range.
##
## SCOPE NOTE (v0.22.0): `in_range` deliberately does NOT include the flee candidate. The two movement
## candidates can therefore both be live in one think — which is intended courage behaviour: an ALONE
## kiter's flee score has decayed by utility_alone_move_factor, so approach can legitimately win and the
## monster turns to close. With backup alive the flee weight is far above the approach weight, so the
## retreat wins on score, not on a special case.
static func _score_approach(ctx: Dictionary, type: MonsterType, in_range: bool) -> Dictionary:
	var candidate := { "action": ACTION_APPROACH, "score": 0.0, "data": {} }
	if not bool(ctx.get("engaged", false)):
		return candidate
	if in_range:
		return candidate
	candidate["score"] = maxf(0.0, type.utility_approach_weight)
	return candidate
