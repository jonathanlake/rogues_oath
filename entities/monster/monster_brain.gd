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

## IDLE BANTER window (v0.27.0): each brain re-arms its own randomized timer in this range (SECONDS, not
## beats — idle muttering is wall-clock flavor with no relation to the fight's cadence, and out of combat
## there is no tactical beat to measure it against). Wide and slow on purpose: the bark ALSO has to pass
## the global chance roll and the one-voice-at-a-time cooldown, so the observed rate is far below one per
## 15-30s per monster. Consts rather than config fields — the tuning surface that matters is the LINES.
const _IDLE_BANTER_MIN_SEC := 15.0
const _IDLE_BANTER_MAX_SEC := 30.0

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
# within aggro_range_tiles AND reachable through open floor (v0.31.0 wall-bounded acquire — see
# _should_chase); while latched AND monster_type.aggro_persists, the range check is
# skipped so the chase never leash-drops. With aggro_persists false it tracks current in-range
# state (legacy leash). Unused by unlimited-range monsters (aggro_range_tiles <= 0 skip the gate).
var _aggroed: bool = false
# ONE-pending-re-think latch (v0.22.1): true while a _reschedule/_reschedule_after timer is booked and
# not yet fired. Cleared at _think entry, checked in _reschedule_after — collapses the historical double
# timer chain (activation think + seed-glide boundary think, each self-perpetuating) to a single chain.
var _rethink_pending: bool = false

# THINKING hesitation (v0.24.0 stamina experiment, Jeff: "enemies think before moving"). On the
# became-engaged edge this brain rolls monster_think_min..max_beats (host RNG, at its resolved pace)
# and holds the WHOLE brain — no move, attack or cast — until the deadline. Wall-clock msec like the
# pace referee's forcing window; 0 = not thinking. Gated on stamina_enabled so /stamina off
# restores pre-experiment AI exactly.
var _thinking_until_msec: int = 0
# Edge detector for the hesitation roll: the last aggro state this brain reported. Reset never —
# a monster that genuinely un-aggros (aggro_persists false) re-rolls on its next latch, by design.
var _last_reported_engaged: bool = false
# v0.24.3 story-beat thinks. _last_reported_target: the previous leash target, for the
# retarget-after-a-kill detect (a target switch to a LIVING player — crossing fights — rolls
# nothing; only a vanished/dead old target does). The two once-latches keep last-stand and
# cornered at one roll per life — story beats, not recurring noise.
var _last_reported_target: int = 0
var _saw_engaged_allies: bool = false
var _last_stand_done: bool = false
var _cornered_done: bool = false
# v0.27.0 banter. _help_me_done: the once-per-life latch for the notable-monster scream (same shape as
# the two above — a story beat, not a recurring noise). _banter_idle_gen: the generation token the idle
# chatter timer captures, bumped at activate so a re-activated/pooled brain can never be driven by a
# previous life's booked tick (the same idiom as the stun/round/cast generations elsewhere).
var _help_me_done: bool = false
var _banter_idle_gen: int = 0
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
# This instance's rolled AI PERSONALITY (v0.22.0 weighted utility AI), or null = neutral (all multipliers
# 1.0). Rolled ONCE at activate() from _monster_type.personalities and kept for this monster's whole life.
# It lives HERE, on the brain, and never on the MonsterType: a type is a SHARED cached resource, so writing
# per-instance state onto it would make every shaman in the room share one personality (and /m-reset it).
# Read only by the utility path; a legacy-cascade monster rolls one harmlessly and never consults it.
var _personality: AiPersonality = null


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
	# re-activated monster must never inherit a previous life's latch and skip the acquire gate. (The
	# leash target is now a per-think local in _update_engagement — no field to reset.)
	_aggroed = false
	# Fresh life, fresh disposition (v0.22.0): roll this instance's personality now, before the first think,
	# so every decision it ever makes is scored through the same lens. Host-only — activate() is only called
	# inside Main's is_server() branch, so this uses the same global RNG the host already owns for
	# pick_smite_tile (no new RNG plumbing; reproducibility was not asked for).
	_roll_personality()
	# Fresh life, fresh once-per-life banter latch + a fresh idle-chatter generation (any tick booked by
	# a previous life no longer matches and self-drops).
	_help_me_done = false
	_banter_idle_gen += 1
	_active = true
	_arm_idle_banter()
	_think.call_deferred()


## Boundary hook, wired by the parent monster to its glide_finished. This monster just finished a
## step — re-plan the next one.
func on_boundary() -> void:
	_think()


## Damage is an AGGRO SOURCE (v0.17.2 review fix). Called host-side by the parent monster's forwarder when
## this monster takes a hit: today aggro is a proximity scan at think-time only, so a 7-tile arrow would
## never wake the brain — a shot must aggro REGARDLESS of aggro_range_tiles (no free sniping). Inert if not
## activated (a client's brain, or the brainless dummy, never runs). Latches _aggroed and schedules a
## prompt re-think on the normal back-off cadence; it does NOT interrupt a committed in-flight glide — the
## Commitment Rule applies to monsters too, so the next think/boundary handles retargeting. DESIGN NOTE: the
## chase still targets the NEAREST player (existing model) — a shot from a FARTHER player aggros this monster
## but it chases whoever is closest, not necessarily the shooter.
func notify_attacked() -> void:
	if not _active:
		return
	# PACK RALLY (v0.22.0): being hit is an ORGANIC entry into combat, so it drags the neighbours in. Fired
	# only on the LATCHING edge (was not aggroed, now is) — an already-fighting monster taking another hit
	# must not re-fan the bubble every time it is struck.
	var was_aggroed := _aggroed
	_aggroed = true
	if not was_aggroed:
		_rally_pack()
	# HELP ME (v0.27.0 banter): a NOTABLE monster — a shaman — screams for cover the first time it is hurt
	# WHILE ITS PACK IS STILL FIGHTING. Both conditions carry the moment: alone, "help me" would be
	# addressed to nobody (that is the last_stand beat instead), and repeated every hit it would stop being
	# a moment, hence the once-per-life latch (the _check_last_stand pattern). Forced past the chance roll
	# like the death bark — this one should land — but still cooldown-gated. Placed ABOVE the busy return
	# below, deliberately: a shaman hit mid-cast is exactly when it wants to scream.
	# v0.27.1: "its pack is still fighting" now means an engaged ally WITHIN EARSHOT, not a map-wide
	# engagement count — screaming for help nobody could hear was the same cross-fight bug the revenge
	# bark had (GameConfig.banter_earshot_tiles).
	if not _help_me_done and _monster_type != null and _monster_type.banter_notable \
			and _has_engaged_ally_within_earshot():
		_help_me_done = true
		Banter.bark(_entity_id, _monster_type.display_name, "help_me", _authoritative_tile(), true)
	# Already committed to an action (glide or attack)? Latch aggro ONLY — do NOT schedule an early think.
	# The referee holds this monster busy for its whole action window (v0.19.0: a telegraphed attack now
	# commits windup+recovery), and the end-of-window think already re-decides targeting. Rescheduling here
	# would fire a think MID-window that runs the busy-gate's glide-settle math in a non-glide (commit-in-place)
	# context — harmless but sloppy, and pre-v0.19.0 it was the extra-STRIKE vector (a hit during recovery
	# bought the goblin a bonus attack). Gating on busy makes this "the early think was wrong while committed,"
	# and it covers any future damage source (DoT/trap) that calls notify_attacked. Commitment Rule intact:
	# this never interrupts the in-flight action — the next boundary/window-end think handles retargeting.
	if _referee.is_entity_moving(_entity_id):
		return
	_reschedule()


## PACK RALLY receiver (v0.22.0, Jon's directive — "all the other goblins in there attack"). Called host-side by
## CombatReferee.rally_pack when an allied monster's SHOUT reached this one — i.e. an ally entered combat and the
## sound could travel here over open floor within GameConfig.rally_travel_tiles (v0.30.0; before that it was the
## ally's wall-blind tactical bubble). This brain joins the fight without having seen a player itself. Applies to
## EVERY brain, legacy cascade included — it is a shared aggro source, not a utility-AI feature.
##
## ONE HOP: this latch deliberately does NOT fan out again (no _rally_pack call here), so overlapping shouts can
## never chain-react a whole map awake from a single proximity trip. An ALREADY-aggroed brain returns immediately:
## it is fighting already, and re-waking it mid-cadence would just churn timers.
##
## Commitment Rule intact, mirroring notify_attacked's busy guard: a rally never interrupts an in-flight glide or
## cast — a busy brain latches only, and its end-of-window think picks the fight up with aggro already set.
func notify_rallied() -> void:
	if not _active:
		return
	if _aggroed:
		return
	_aggroed = true
	if _referee.is_entity_moving(_entity_id):
		return
	_reschedule()


## EARLY-RELEASE wake (v0.26.0 recovery-on-contact), relayed by the parent monster from the move
## referee's busy_released signal. THE PROBLEM IT SOLVES: this brain self-paces on the duration it
## QUOTED when it committed the attack (_reschedule_after(windup + recovery + epsilon)) because an
## in-place window ends without a glide_finished. When the swing whiffs, the referee now refunds the
## recovery tail — but the booked wake still sits at the old deadline, so the monster would stand
## frozen through beats it no longer owes and the refund would be invisible.
##
## Shape deliberately identical to notify_attacked/notify_rallied — an external wake, not a new timer
## loop: think NOW at its own (just-arrived) boundary. The BUSY guard is the same one those two use and
## does double duty here: if the release PROMOTED a pipelined step, the referee is already moving this
## monster and the coming glide_finished is the right boundary, so we leave it alone.
##
## Commitment Rule: nothing is cancelled or redirected. The attack already played to completion and
## missed; this only lets the next DECISION happen when the window truly ended.
func notify_busy_released() -> void:
	if not _active:
		return
	if _referee.is_entity_moving(_entity_id):
		return
	# Straight to _think (the on_boundary shape), NOT _reschedule: the window is over now, so a
	# back-off delay would just re-invent the stall this fixes. The stale long booking still fires
	# later and lands in _think's normal gates — the same benign double-wake on_boundary already
	# produces, absorbed by the _rethink_pending latch from there on.
	_think()


# ── Private methods ───────────────────────────────────────────────────────────

## Decide and submit at most ONE step (or log the adjacent-attack seam). Gated on not-busy and on
## authoritative referee state read live at this instant.
func _think() -> void:
	# Clear the re-think booking FIRST (v0.22.1, see _reschedule_after): this think is the booked one
	# firing (or an on_boundary/notify wake superseding it) — either way the slot is free again, and any
	# reschedule THIS think decides on gets to book anew.
	_rethink_pending = false
	if not _active:
		return
	# STUNNED (v0.20.0): a stunned monster cannot act — skip this think and re-poll on the cadence until the
	# stun expires. BEFORE the busy gate, so a stunned monster never pipelines a step either. This never
	# interrupts an in-flight glide (the Commitment Rule) — that completes and wakes us here, where we wait.
	if _combat != null and _combat.is_stunned(_entity_id):
		_reschedule()
		return
	# THINKING hold (v0.24.0): mid-hesitation, the whole brain waits — the same self-skip shape as
	# the stun gate above. Catches every think after the one that rolled; that rolling think is
	# gated at its own action sites (post-engagement-report), so no action ever fires mid-cue.
	if _is_thinking():
		_reschedule()
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
		var backstop_sec := settle_beats * PaceReferee.beat_or_explore(_pace, _entity_id) + windup_rethink_epsilon_sec
		# Arm the backstop ONLY when no step was pipelined this think. A successful pipeline is carried
		# to the next think by the promoted step's glide_finished, so arming here too would fire a
		# redundant busy think that re-arms in turn (backstop thinks are themselves busy) — an unbounded
		# timer cascade. Not-pipelined is the ONLY case needing recovery, and it always gets it. (This
		# is the one deliberate refinement of the plan's "arm at every busy think": it faithfully keeps
		# the plan's stated intent that the backstop "no-ops if the pipelined step ran".)
		if not _is_thinking() and _try_pipeline_next_step():
			return
		_reschedule_after(backstop_sec)
		return
	var my_tile: Vector2i = _referee.tile_of_entity(_entity_id)
	# tile_of_entity returns a wall-sentinel tile when the entity is untracked (e.g. despawned
	# between scheduling and firing). No live monster ever rests on a wall, so this is unambiguous.
	if WorldGrid.is_wall(my_tile):
		return

	# SUPPORT (v0.19.4): a HEALER checks for a wounded ally BEFORE deciding to chase/attack. If one is within
	# heal_range_tiles and below max HP, commit a telegraphed heal cast (Commitment Rule — self-limits via the
	# busy record, no cooldown; §2.8 beats). Priority OVER chasing a player: a shaman keeps its pack alive
	# first. This runs even with no players present (allies can already be hurt). No valid ally, or a declined
	# cast → fall through to the normal chase/attack below (an ARMED healer still fights). An ordinary monster
	# (no authored heal ability) skips the whole branch.
	#
	# v0.22.0: a UTILITY-AI monster skips this branch entirely — heal is one of its SCORED candidates, and
	# letting the hardcoded pre-gate fire first would mean the scorer never got a say on it. The extra
	# `not utility_ai` term is inert for every existing monster (the flag defaults false), so the legacy
	# cascade below stays byte-for-byte what it was.
	# v0.28.0 recovery lockout: a heal is a CAST, so a recovering healer skips this pre-gate entirely and
	# falls through to the cascade below (whose own attack branch is gated too, and whose tail backs off to
	# the end of the recovery wait). Movement is deliberately still reachable from there.
	if _monster_type != null and _monster_type.has_heal_ability() and not _monster_type.utility_ai \
			and not _recovery_locks_actions():
		var heal_target: int = _combat.pick_heal_target(_entity_id, my_tile, _monster_type.heal_range_tiles)
		if heal_target != 0:
			var heal_wait: float = _combat.heal_cast(
					_entity_id, heal_target, _monster_type.heal_amount,
					_monster_type.heal_cast_beats, _monster_type.heal_recovery_beats)
			if heal_wait >= 0.0:
				# The cast's busy record ends WITHOUT waking us (no glide_finished on a commit_in_place) —
				# schedule our OWN re-think just past it, exactly like a wind-up (think-at-own-boundary).
				_reschedule_after(heal_wait + windup_rethink_epsilon_sec)
				return
			# Declined (target vanished / went busy) — fall through to normal chase/attack this think.

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

	# WEIGHTED UTILITY AI (v0.22.0, Jeff's spec — DESIGN §2.12). The one branch point: an opted-in monster
	# hands its decision to the scorer, every other monster falls through to the legacy priority cascade
	# below, untouched. Placed HERE deliberately — after the stun gate, the busy/pipeline gate, the
	# wall-sentinel guard and the no-targets guard — so the utility path inherits ALL of the Commitment-Rule
	# and think-at-own-boundary machinery above verbatim and only ever decides WHAT to commit, never when.
	if _monster_type != null and _monster_type.utility_ai:
		_think_utility(my_tile, targets)
		return

	# Aggro acquisition + persistence + engagement report (Tactical Zones v1, §2.8.7): _update_engagement
	# latches/leashes _aggroed via _should_chase from the nearest-target Chebyshev distance, resolves the
	# leash target id, reports (aggroed, target) to the pace referee, and returns whether to engage. Un-acquired
	# / leash-dropped means idle on the re-think cadence. The SAME _should_chase decision the busy-think
	# pipeline consults, so both chase paths acquire identically.
	if not _update_engagement(my_tile, targets):
		_reschedule()
		return

	# THINKING hold, latch-think leg (v0.24.0): the engagement report above may have JUST rolled the
	# hesitation — this same think must not fall through into the kiter/wind-up/chase actions below.
	if _is_thinking():
		_reschedule()
		return

	# LAST-STAND story beat (v0.24.3): fought beside allies, now alone — pause and turn (once per life).
	if _check_last_stand():
		_reschedule()
		return

	# CASTER / KITER (v0.19.10): a flees_players monster (the goblin shaman) NEVER chases into melee. Having
	# already checked heal above, it now backs off from a too-close player, else smites a random player from
	# range, else holds. Handled here, BEFORE the chase/attack branch a normal monster runs.
	if _monster_type != null and _monster_type.flees_players:
		_act_as_kiter(my_tile, targets)
		return

	# Adjacent to a hostile player? (M3: every player is hostile to the monster — the faction rule;
	# when neutral factions exist this filters by is_hostile_to.) Request a wind-up.
	for t in targets:
		if maxi(absi(t.x - my_tile.x), absi(t.y - my_tile.y)) == 1:
			# RECOVERY LOCKOUT (v0.28.0): at 0 stamina in tactical pace this monster may not swing. Skip the
			# attack and sleep until the recovery wait ends (a silent skip — nothing was submitted). We stand
			# our ground rather than falling through to the chase below: we are already adjacent, so there is
			# no step worth taking, and pushing past the player is not what "wait it out" means.
			if _recovery_locks_actions():
				_reschedule_recovery_aware()
				return
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

	# ROOTED (v0.34.0 conditions): the roots hold this monster in place, so every STEP below is a glide the
	# referee will refuse — skip straight to the re-think cadence rather than spending a submit per think on
	# a guaranteed reject. Placed HERE, below the adjacent-attack rung, because rooted only blocks MOVEMENT:
	# a rooted goblin still swings at anything in reach, which is the whole "the condition fights back"
	# ruling. The referee's gate is still the authority — this is spam control, not adjudication.
	if _is_rooted():
		_reschedule()
		return
	# Not adjacent: step toward the NEAREST player by path length over the walls-only grid. Body
	# occupancy is deliberately not in that grid (bodies are volatile), so the referee's validator
	# is the authority on whether the chosen step is actually free.
	var dir := _first_step_toward(my_tile, targets)
	if dir == Vector2i.ZERO:
		# Every player unreachable even by the walls-only fallback (a corridor-blocking PLAYER is handled
		# as the adjacent-attack case above). As of v0.10.4 monsters path AROUND other monsters toward
		# players (_first_step_toward's `avoid`) and, at a true monster-blocked chokepoint, fall back to a
		# blocked straight step the referee refuses → queue. So ZERO here means a genuine WALL seal, not a
		# monster traffic jam — back off on the re-think cadence and wait for the map to open.
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
##
## v0.32.0: the referee now REFUSES a pipelined step whenever our busy record is IN-PLACE (a windup, its
## recovery tail, a cast, a drink — see MoveReferee._validate_glide). Nothing to change here: the submit
## simply returns false, we fall through to the caller's _reschedule_after backstop, and
## notify_busy_released still wakes us the moment the window ends. Only a REAL glide (from != to) can
## still pipeline, which is the only case this function was ever meant to serve.
func _try_pipeline_next_step() -> bool:
	# ROOTED (v0.34.0): a held body has no next step to queue — fall to the backstop, which re-decides at
	# the window's end (by which time the root may have expired).
	if _is_rooted():
		return false
	# A KITER never chases (v0.19.10), so it must never pipeline a chase step — fall to the backstop so the
	# next boundary re-decides flee/smite/hold via _act_as_kiter.
	if _monster_type != null and _monster_type.flees_players:
		return false
	# A UTILITY-AI monster never pipelines either (v0.22.0): the scorer decides EVERY action this brain
	# takes, and a pipelined chase step is a chase committed without a score. Falling to the backstop costs
	# it the zero-gap open-field parity a legacy chaser gets — the deliberate trade for "one decision maker"
	# — and today's only utility monster (the shaman) is a kiter that already returned above.
	if _monster_type != null and _monster_type.utility_ai:
		return false
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
	var nearest := _nearest_target(my_tile, targets)
	var nearest_dist := maxi(absi(nearest.x - my_tile.x), absi(nearest.y - my_tile.y))
	# Same acquire/leash decision the idle branch makes — never pipeline a chase we wouldn't start.
	# ONE shared decision, so the v0.31.0 wall-bounded acquire applies here identically (my_tile is our
	# post-step tile, the same vantage the pipelined step would be taken from).
	if not _should_chase(my_tile, nearest, nearest_dist):
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


## The nearest target TILE by Chebyshev (king-move) distance from `my_tile` (strict `<` tie-break, so
## the FIRST of equal-distance tiles wins — the same metric and tie-break the old twin scans shared).
## Callers guard an empty list first, so targets[0] is a safe seed; each derives the distance it needs
## with one Chebyshev expression on the returned tile. Shared by the idle branch and the busy pipeline.
func _nearest_target(my_tile: Vector2i, targets: Array) -> Vector2i:
	var best: Vector2i = targets[0]
	var nearest := -1
	for t in targets:
		var d: int = maxi(absi(t.x - my_tile.x), absi(t.y - my_tile.y))
		if nearest < 0 or d < nearest:
			nearest = d
			best = t
	return best


## KITER action (v0.19.10, the goblin shaman; v0.33.0, the bow goblin): heal was already checked in _think.
## Now, in priority order — (1) if the nearest player is within flee_range_tiles, step AWAY (avoid being
## cornered); (2) else SHOOT the nearest player inside the equipped ranged weapon's range; (3) else smite a
## RANDOM player within smite_range_tiles; (4) else hold on the re-think cadence. A kiter NEVER chases or melees.
## Called from _think only for a flees_players monster. Submits at most one action (a flee glide OR a shot OR
## a smite cast).
##
## ENGAGED ONLY: _think runs the whole engagement gate (_update_engagement — aggro acquire / persist / leash,
## plus the thinking hold and last-stand beat) BEFORE it reaches this ladder, so nothing here needs an aggro
## check of its own. That is what lets the bow goblin author aggro 5 and carry a range-7 bow without becoming
## a sniper: it will not shoot at all until something walked inside FIVE tiles and woke it, and only then does
## its seven tiles of reach start to matter (and keep mattering, since aggro_persists holds the latch).
func _act_as_kiter(my_tile: Vector2i, targets: Array) -> void:
	var nearest := _nearest_target(my_tile, targets)
	var nearest_dist := maxi(absi(nearest.x - my_tile.x), absi(nearest.y - my_tile.y))
	# (1) Too close → back off. Priority over shooting/smiting so a crowded caster makes space first. If
	# cornered (no free away-step), fall through to try a ranged attack instead of freezing.
	if _monster_type.flee_range_tiles > 0 and nearest_dist <= _monster_type.flee_range_tiles:
		if _flee_step(my_tile, nearest):
			return
	# (2) SHOOT (v0.33.0, the bow goblin): a kiter holding a RANGED weapon looses at the nearest player inside
	# its reach. Gated three ways before anything is committed:
	#   - the authored weapon is ranged (range_tiles > 0) — a club-wielding kiter (every shaman) skips the
	#     whole rung, so the legacy ladder is byte-identical for them and the smite keeps its old priority;
	#   - the RECOVERY LOCKOUT (v0.28.0) — a draw is an ACTION, so a recovering archer skips it and holds,
	#     exactly as the smite rung below does. The flee step above stays ungated: that is the movement channel;
	#   - the target is within range_tiles (Chebyshev, the referee's own metric) AND the LANE IS CLEAR.
	# THE LANE CHECK is the friendly-fire guard: projectile_hits_allies ships TRUE, so an arrow STOPS on the
	# first living body — including a packmate. CombatReferee.is_lane_clear walks the EXACT tiles the arrow
	# would fly and answers true only when the first stoppable body on them is hostile. Think → check → commit
	# is one synchronous host stack, so that read is the same occupancy the draw commits against. An ally in
	# front (or no body on the lane at all) → skip the rung and hold: kiting reshuffles the geometry and the
	# next think asks again. An ally BEHIND the target can still eat the overshoot — accepted (Jon: friendly
	# fire is on-brand); the guard is about not shooting your own front line in the back, not about safety.
	# Range read off the authored MonsterType.weapon (the same resource seeded onto equipped_weapon at spawn,
	# which is what the referee re-reads host-side to adjudicate) — the brain only decides, never adjudicates.
	if _monster_type.weapon != null and _monster_type.weapon.range_tiles > 0 and not _recovery_locks_actions():
		if nearest_dist <= _monster_type.weapon.range_tiles and _combat.is_lane_clear(_entity_id, nearest):
			var shot_wait: float = _combat.commit_monster_shot(_entity_id, nearest)
			if shot_wait >= 0.0:
				# The draw + recovery is a commit_in_place record: it ends WITHOUT waking us (no glide), so
				# book our own re-think just past it — the smite rung's exact shape, and the wind-up's.
				_reschedule_after(shot_wait + windup_rethink_epsilon_sec)
				return
			# Declined (went busy / stunned between the gate and here) — fall through to smite / hold.
	# (3) Smite the GROUND at a random in-range player's tile (host picks it; the player can dodge off it).
	# RECOVERY LOCKOUT (v0.28.0): a smite is a CAST, so a recovering kiter skips it and holds — note that
	# the FLEE step above is NOT gated, because backing off is movement and movement is the other channel.
	if _monster_type.has_smite_ability() and not _recovery_locks_actions():
		var smite_tile: Vector2i = _combat.pick_smite_tile(_entity_id, my_tile, _monster_type.smite_range_tiles)
		# (0,0) sentinel = no player in range (it's a border wall — no live body rests there).
		if not WorldGrid.is_wall(smite_tile):
			var wait_sec: float = _combat.smite_cast(_entity_id, smite_tile, _monster_type.smite_damage,
					_monster_type.smite_cast_beats, _monster_type.smite_recovery_beats)
			if wait_sec >= 0.0:
				# Cast committed — its busy record ends without waking us (no glide), so schedule our own
				# re-think just past it (same as heal / wind-up).
				_reschedule_after(wait_sec + windup_rethink_epsilon_sec)
				return
	# (4) Nothing to do this think (no flee needed or cornered, no shot, no smite target) — hold on the
	# cadence, or until the recovery wait ends if the lockout is what silenced the ranged attack (v0.28.0).
	_reschedule_recovery_aware()


## Submit one step DIRECTLY AWAY from `nearest_tile` for a kiter (v0.19.10). Tries the pure-away direction
## first, then component / diagonal fallbacks (so a wall-blocked straight retreat still finds a sideways-away
## step). Pre-checks walkable + free, then submits through the referee's validator (which still owns the corner
## rule). Returns true when a glide was accepted (on_boundary drives the next think), false if every away-step
## is blocked — the caller then tries a smite / holds. A ZERO away vector (impossible: two bodies never share
## a tile) yields no candidates.
func _flee_step(my_tile: Vector2i, nearest_tile: Vector2i) -> bool:
	# ROOTED (v0.34.0): you cannot run from what has your ankles. Report the same "every away-step is
	# blocked" decline a cornered kiter reports, so the caller falls through to a smite / hold — which is
	# precisely the intended play against a rooted caster.
	if _is_rooted():
		return false
	var away := (my_tile - nearest_tile).sign()
	for dir in _flee_candidates(away):
		var dest: Vector2i = my_tile + dir
		if WorldGrid.is_walkable(dest) and _referee.is_tile_free(dest):
			_last_step_was_diagonal = dir.x != 0 and dir.y != 0
			if _referee.submit_monster_intent(_entity_id, dir):
				return true
	return false


## Ordered away-step candidates for a kiter, most-retreating first: the pure away vector, then fallbacks that
## still move away on the free axis (so a blocked diagonal splits into its cardinals, and a blocked cardinal
## tries the two diagonals that keep the retreat). ZERO away yields an empty list (no direction to flee).
func _flee_candidates(away: Vector2i) -> Array:
	if away == Vector2i.ZERO:
		return []
	var list: Array[Vector2i] = [away]
	if away.x != 0 and away.y != 0:
		list.append(Vector2i(away.x, 0))
		list.append(Vector2i(0, away.y))
	elif away.x != 0:
		list.append(Vector2i(away.x, 1))
		list.append(Vector2i(away.x, -1))
	else:
		list.append(Vector2i(1, away.y))
		list.append(Vector2i(-1, away.y))
	return list


# ── Weighted utility AI (v0.22.0, Jeff's spec — the opt-in replacement for the cascade above) ──

## ONE think for a utility_ai monster: snapshot the situation, score every candidate, apply this instance's
## personality, sort, tie-break, and commit the best thing that will actually accept. Called from _think
## AFTER all the shared gates (stun / busy / wall / no-targets), so everything about WHEN this brain may act
## is still owned by the machinery above — this decides only WHAT.
##
## Engagement: _update_engagement is called here exactly as the legacy path calls it, so aggro latching, the
## leash, the pack-rally fan-out and the pace-referee report all behave identically for a utility monster.
## NOT engaged narrows the CANDIDATE LIST to heal only (an out-of-combat healer still tops up its pack, which
## is what the pre-gate heal did before this branch existed) — it never changes a formula: there is exactly
## one heal curve in the scorer, engaged or not.
##
## Commitment Rule: at most ONE action is committed per think and nothing here can cancel or redirect a
## committed one. A move candidate commits a SINGLE tile step, and the brain re-scores at every glide
## boundary, so an approaching caster re-decides per tile and can never chase past its preferred range.
func _think_utility(my_tile: Vector2i, targets: Array) -> void:
	var engaged := _update_engagement(my_tile, targets)
	# THINKING hold, latch-think leg (v0.24.0) — mirror of the legacy path's gate: the report above
	# may have just rolled the hesitation; this think must not walk the candidate list.
	if _is_thinking():
		_reschedule()
		return
	# LAST-STAND story beat (v0.24.3), utility leg — same once-per-life pause as the legacy path.
	if _check_last_stand():
		_reschedule()
		return
	var candidates: Array = UtilityScorer.score_candidates(_build_utility_context(my_tile, targets, engaged))
	if not engaged:
		var heal_only: Array = []
		for c in candidates:
			if str(c["action"]) == UtilityScorer.ACTION_HEAL:
				heal_only.append(c)
		candidates = heal_only
	# Personality FIRST, then sort (the plan's deliberate ordering): the multipliers scale whole composite
	# scores, so they decide the final ranking AND what counts as a close call for the tie-break below.
	UtilityScorer.apply_personality(candidates, _heal_weight_mult(), _smite_weight_mult())
	UtilityScorer.sort_by_score(candidates)
	_apply_tiebreak(candidates)
	# DECLINE FALL-THROUGH: executors are the same ones the legacy cascade uses and may DECLINE (-1.0 / false)
	# when the referee re-validates — a target vanished, a step is blocked, the caster went busy. Walk the
	# candidates in score order and take the first that actually commits. Zero-score candidates are skipped
	# outright. Nothing viable — empty list, all zeros, or every candidate declining — falls back to the
	# normal re-think cadence.
	# The ai_decision post happens AFTER the walk, naming what actually COMMITTED (v0.22.1 battle-run fix):
	# posting the pre-execution top pick lied whenever it declined and a lower candidate fell through — the
	# r2 trace showed "chosen: flee" stamped the same instant as a smite_cast (a cornered shaman's flee was
	# blocked by the south wall). Idle thinks (every candidate zero) and fully-declined walks post nothing —
	# the same fix silences the ~4+ no-op posts per second per idle monster that drowned the r1 trace.
	for c in candidates:
		if float(c["score"]) <= 0.0:
			continue
		if _execute_candidate(c, my_tile, targets):
			_post_ai_decision(candidates, str(c["action"]))
			return
	# CORNERED story beat (v0.24.3, once per life): NOTHING committed this think AND the top pick was
	# flee — the classic walled-in kiter (the r2 trace case). The stall was already happening; the
	# dots just make it readable as "trapped — now what?". If a lower candidate committed above
	# (e.g. the cornered smite), no roll — the cast IS the answer, dots would only mud it.
	if not _cornered_done and not candidates.is_empty() \
			and float(candidates[0]["score"]) > 0.0 \
			and str(candidates[0]["action"]) == UtilityScorer.ACTION_FLEE:
		_cornered_done = true
		_begin_think("cornered")
	# v0.28.0: if the recovery lockout is what made every attack/cast candidate decline, sleep until the
	# wait ends instead of re-scoring on the back-off cadence (the skip is silent, but the thinks add up).
	_reschedule_recovery_aware()


## Build the scorer's context: ONE snapshot of this monster's situation, read from AUTHORITATIVE referee state
## at this instant (occupancy, HP, busy records) and the SHARED MonsterType (never a client value, never a
## rendered position). The type itself rides in the dict rather than 13 copied floats, so a live `/m
## utility_smite_weight 80` retune is picked up on the very next think — the same live-read contract the
## rest of the brain's tuning has.
func _build_utility_context(my_tile: Vector2i, targets: Array, engaged: bool) -> Dictionary:
	var nearest := _nearest_target(my_tile, targets)
	var nearest_dist := maxi(absi(nearest.x - my_tile.x), absi(nearest.y - my_tile.y))
	var allies := _scan_allies(my_tile)
	# HEAL target: the referee's existing argmax (lowest-HP living BRAINED ally in range) still picks WHO
	# gets tended; the scan above supplies the numbers the curve is priced from.
	var heal_target_id := 0
	if _monster_type.has_heal_ability():
		heal_target_id = _combat.pick_heal_target(_entity_id, my_tile, _monster_type.heal_range_tiles)
	# SMITE ground: pick_smite_tile answers with a random in-range player's tile (host owns that RNG) and
	# already skips tiles another caster has doomed; the wall sentinel (0,0) means "no target in range".
	# has_pending_smite_at is re-checked here so the scorer's rule reads as its own guard rather than an
	# implicit side effect of the picker.
	var smite_tile := Vector2i.ZERO
	var smite_tile_valid := false
	var smite_target_moving := false
	if _monster_type.has_smite_ability():
		smite_tile = _combat.pick_smite_tile(_entity_id, my_tile, _monster_type.smite_range_tiles)
		smite_tile_valid = not WorldGrid.is_wall(smite_tile) and not _combat.has_pending_smite_at(smite_tile)
		if smite_tile_valid:
			# "Standing still" = the referee holds no commit record for the occupant. A committed body cannot
			# dodge off the doomed tile, which is exactly why it is worth the standstill bonus.
			var occupant: int = _referee.entity_at(smite_tile)
			smite_target_moving = occupant != 0 and _referee.is_entity_moving(occupant)
	return {
		"type": _monster_type,
		"engaged": engaged,
		"heal_available": heal_target_id != 0,
		"heal_target_id": heal_target_id,
		"heal_worst_frac": allies["worst_frac"],
		"heal_injured_count": allies["injured_count"],
		"heal_far_frac": allies["far_worst_frac"],
		"heal_far_tile": allies["far_worst_tile"],
		"smite_available": _monster_type.has_smite_ability(),
		"smite_tile": smite_tile,
		"smite_tile_valid": smite_tile_valid,
		"smite_target_moving": smite_target_moving,
		# A weaponless monster deals NOTHING (unarmed is a future natural weapon, not a fallback), so it must
		# never score a swing — read from the authored type, the same source the referee's damage math uses.
		"melee_available": _monster_type.weapon != null,
		"player_adjacent": nearest_dist <= 1,
		"player_in_flee_range": _monster_type.flee_range_tiles > 0 and nearest_dist <= _monster_type.flee_range_tiles,
		"nearest_tile": nearest,
		"has_backup": allies["has_backup"],
	}


## ONE pass over allied monsters for the three things the scorer asks about them: BACKUP (courage — is there
## a living, BRAINED ally within backup_radius_tiles?), the INJURED picture inside heal_range_tiles (how
## many, and the worst hp fraction), and — healers only — the worst WOUNDED PATIENT beyond heal range but
## inside heal_seek_radius_tiles (the walk-to-heal destination, v0.23.2/v0.23.3). All walk the same
## authoritative chain: MoveReferee.monster_tiles (occupancy, self excluded) → entity_at(tile) → id →
## CombatReferee.is_alive / has_brain_of / hp_of / max_hp_of, because occupancy answers with an entity ID
## rather than a node. The HP reads are GATED on has_heal_ability (v0.23.3 review fix — a chaser paid the
## per-think ally-HP scan for a result only healers consume).
##
## The training dummy and any other has_brain=false prop is excluded from ALL counts: a destructible barrel
## is not backup, and it is not a comrade worth a cast (it was a heal magnet once — the v0.19.10 fix).
## Returns { has_backup, injured_count, worst_frac, far_worst_frac, far_worst_tile } — worst_frac /
## far_worst_frac of 1.0 mean "nobody is hurt" there.
func _scan_allies(my_tile: Vector2i) -> Dictionary:
	var has_backup := false
	var injured_count := 0
	var worst_frac := 1.0
	var far_worst_frac := 1.0
	var far_worst_tile := Vector2i.ZERO
	var backup_radius: int = _monster_type.backup_radius_tiles
	var heal_radius: int = _monster_type.heal_range_tiles
	var heal_capable := _monster_type.has_heal_ability()
	# The far-patient net (v0.23.3 review fix): its OWN radius, not backup's — with backup 6 and heal 5 the
	# old band collapsed to exactly one tile of awareness and the walk feature almost never fired.
	var seek_radius: int = _monster_type.heal_seek_radius_tiles if heal_capable else 0
	for tile in _referee.monster_tiles(_entity_id):
		var cheb := maxi(absi(tile.x - my_tile.x), absi(tile.y - my_tile.y))
		if cheb > backup_radius and cheb > heal_radius and cheb > seek_radius:
			continue
		var id: int = _referee.entity_at(tile)
		# monster_tiles yields negative ids by construction; anything else is a race with a despawn (0) and
		# is skipped rather than trusted.
		if id >= 0 or not _combat.is_alive(id) or not _combat.has_brain_of(id):
			continue
		if cheb <= backup_radius:
			has_backup = true
		if not heal_capable:
			continue
		var ally_max: int = _combat.max_hp_of(id)
		# A 0 max means the node is gone — never divide by it.
		if ally_max <= 0:
			continue
		var frac := float(_combat.hp_of(id)) / float(ally_max)
		if frac >= 1.0:
			continue
		if cheb <= heal_radius:
			injured_count += 1
			worst_frac = minf(worst_frac, frac)
		elif cheb <= seek_radius and frac < far_worst_frac:
			# Wounded ally BEYOND heal range but inside the seek net (v0.23.2, Jon): the heal candidate
			# scores this patient and the executor WALKS toward it instead of shrugging into a smite —
			# "if heal won the decision, move to your buddy." Worst-first, tile carried so the walk has a
			# destination; the per-step re-think re-scores every tile (deterministic, so heal keeps
			# winning until the patient is in range, healed, or dead).
			far_worst_frac = frac
			far_worst_tile = tile
	return { "has_backup": has_backup, "injured_count": injured_count, "worst_frac": worst_frac,
			"far_worst_frac": far_worst_frac, "far_worst_tile": far_worst_tile }


## TIE-BREAK (Jeff: close calls shouldn't be robotic). If the top two candidates land within
## utility_tiebreak_margin of each other, flip a coin between THOSE TWO ONLY by swapping them in place;
## otherwise the sort already put the argmax first. Operates in POST-personality space deliberately — a
## personality changes which pairs are genuinely close. Uses the global RNG the host already owns (host-only
## code; no new RNG plumbing — reproducibility was not asked for).
##
## Documented limits: a THIRD candidate inside the band is ignored (revisit if a future monster has a crowded
## top set), and a second candidate scoring 0 never enters the coin flip — "not available" must never win a
## toss just because a designer set a wide margin.
func _apply_tiebreak(candidates: Array) -> void:
	if candidates.size() < 2:
		return
	var second := float(candidates[1]["score"])
	if second <= 0.0:
		return
	if float(candidates[0]["score"]) - second > _monster_type.utility_tiebreak_margin:
		return
	if randi() % 2 == 1:
		var swapped = candidates[0]
		candidates[0] = candidates[1]
		candidates[1] = swapped


## Commit ONE scored candidate through the EXISTING executors — the same referee calls the legacy cascade
## makes, with the same contracts: a cast/attack returns the seconds until this monster is free (or -1.0
## DECLINED) and a move returns accepted/refused. Returns true when something was actually committed (the
## caller then stops walking the list), false on a decline so the next candidate gets its turn.
##
## Pacing is unchanged from the cascade: a committed CAST or attack ends its busy record without a
## glide_finished, so the brain wakes ITSELF just past it (think-at-own-boundary); a committed STEP is woken
## by its own glide_finished through on_boundary, so it schedules nothing here.
func _execute_candidate(candidate: Dictionary, my_tile: Vector2i, targets: Array) -> bool:
	var data: Dictionary = candidate["data"]
	var action := str(candidate["action"])
	if action == UtilityScorer.ACTION_HEAL:
		# OUT-OF-RANGE patient (v0.23.2): heal won the decision but the wounded ally is beyond
		# heal_range_tiles — commit ONE STEP toward it instead of casting (Jon: "move TOWARDS his buddy").
		# The glide boundary re-thinks and the deterministic score re-wins per tile until the patient is in
		# range (then this branch's in_range case casts), healed by someone else, or dead (score collapses
		# to whatever is next). A blocked/refused step falls through to the next candidate like any decline.
		if not bool(data.get("in_range", true)):
			# ROOTED (v0.34.0): the approach WALK is a step submission, so a rooted healer declines it and
			# lets the next candidate (a smite, a swing) have its turn. The CAST leg below is untouched —
			# a rooted healer whose patient IS in range still heals.
			if _is_rooted():
				return false
			var toward := _first_step_toward(my_tile, [data.get("approach_tile", Vector2i.ZERO)])
			if toward == Vector2i.ZERO:
				return false
			# Same contract as every other step-submitting site (v0.23.3 review fix — this one skipped it):
			# the busy-gate settle backstop needs the diagonal flag or a diagonal step's wake fires early.
			_last_step_was_diagonal = toward.x != 0 and toward.y != 0
			return _referee.submit_monster_intent(_entity_id, toward)
		# RECOVERY LOCKOUT (v0.28.0): the CAST leg is an action, so a recovering healer declines it and lets
		# the next candidate (which may well be a move) have its turn. The out-of-range STEP leg above is NOT
		# gated — walking to the patient is movement, and movement is the winded dial's channel.
		if _recovery_locks_actions():
			return false
		var heal_wait: float = _combat.heal_cast(
				_entity_id, int(data.get("target_id", 0)), _monster_type.heal_amount,
				_monster_type.heal_cast_beats, _monster_type.heal_recovery_beats)
		if heal_wait < 0.0:
			return false
		_reschedule_after(heal_wait + windup_rethink_epsilon_sec)
		return true
	if action == UtilityScorer.ACTION_SMITE:
		# RECOVERY LOCKOUT (v0.28.0): a cast is an action — decline and let a movement candidate take over.
		if _recovery_locks_actions():
			return false
		var smite_wait: float = _combat.smite_cast(
				_entity_id, data.get("tile", Vector2i.ZERO), _monster_type.smite_damage,
				_monster_type.smite_cast_beats, _monster_type.smite_recovery_beats)
		if smite_wait < 0.0:
			return false
		_reschedule_after(smite_wait + windup_rethink_epsilon_sec)
		return true
	if action == UtilityScorer.ACTION_MELEE:
		# RECOVERY LOCKOUT (v0.28.0): a swing is an action — decline and let a movement candidate take over.
		# Declined BEFORE the forced-melee bark below, so a monster that never actually swung stays quiet.
		if _recovery_locks_actions():
			return false
		# The referee owns instant-strike vs telegraphed wind-up (the weapon's dial) and returns the whole
		# committed window either way — the brain only asks for the swing at that tile.
		var melee_wait: float = _combat.wind_up(_entity_id, data.get("tile", Vector2i.ZERO))
		if melee_wait < 0.0:
			return false
		# FORCED MELEE (v0.27.0 banter): the scorer just made a KITER swing a club. That is the utility AI's
		# courage term firing (cornered, or no backup) and it is the funniest state a caster can be in, so it
		# gets a line. Gated on the CASTER identity (flees_players — "I would rather be running"), NOT on the
		# action, so an ordinary goblin's melee stays silent. Chance-gated, never forced: in a small room this
		# fires repeatedly, and an always-on bark would eat the cooldown every other second.
		if _monster_type != null and _monster_type.flees_players:
			Banter.bark(_entity_id, _monster_type.display_name, "forced_melee", _authoritative_tile())
		_reschedule_after(melee_wait + windup_rethink_epsilon_sec)
		return true
	if action == UtilityScorer.ACTION_FLEE:
		# _flee_step tries the pure away-vector then its fallbacks, submits through the referee's validator,
		# and reports false when every away-step is blocked (cornered) — exactly the decline this loop wants.
		return _flee_step(my_tile, data.get("tile", Vector2i.ZERO))
	if action == UtilityScorer.ACTION_APPROACH:
		# ROOTED (v0.34.0): the utility chase is a step submission like every other — decline so a
		# scoring candidate that can still act (melee, smite) gets its turn instead.
		if _is_rooted():
			return false
		var dir := _first_step_toward(my_tile, targets)
		if dir == Vector2i.ZERO:
			return false
		# Remember the step's shape for the busy gate's settle math (a diagonal window carries the multiplier).
		_last_step_was_diagonal = dir.x != 0 and dir.y != 0
		return _referee.submit_monster_intent(_entity_id, dir)
	return false


## Broadcast this decision on the shared event pipe for the F3 debug overlay (v0.22.0) — DEV-GATED: nothing is
## posted unless the host has turned scores on with `/ai`, so normal play carries zero extra wire traffic. It
## is a broadcast rather than a host-local print so EVERY peer can watch the weights during a two-instance
## tuning session, which is the whole point of the overlay. Host-only by construction (this brain only runs on
## the host, and post_event refuses off-server). Scores ride in post-sort order, chosen first.
func _post_ai_decision(candidates: Array, chosen: String) -> void:
	if not GameManager.debug_ai_decisions:
		return
	var scores := {}
	for c in candidates:
		scores[str(c["action"])] = snappedf(float(c["score"]), 0.1)
	# `chosen` is the action that actually COMMITTED (v0.22.1) — passed in by the execute walk, never
	# inferred from the sorted order, so a decline fall-through is reported truthfully (the score table
	# still shows the declined top pick's higher number beside it, which is exactly the diagnostic:
	# "flee 70 was ranked first but smite committed" reads as a blocked flee at a glance).
	NetEvents.post_event("ai_decision", {
		"entity_id": _entity_id,
		"name": _monster_type.display_name,
		"personality": _personality_name(),
		"chosen": chosen,
		"scores": scores,
	})


## Fan the PACK RALLY out through the combat referee (v0.22.0). Called ONLY on an ORGANIC aggro-latching edge
## (a proximity acquire in _update_engagement, or notify_attacked) — never from notify_rallied, which is what
## keeps the rally one hop deep.
##
## v0.30.0 — THE SHOUT (Jon + Jeff). The reach is now the ONE GLOBAL SOUND DIAL, GameConfig.rally_travel_tiles,
## and the referee spends it as a WALL-BOUNDED FLOOD FILL rather than a radius. It used to be this monster's own
## resolved tactical bubble (§2.8.7, 3-5 tiles), which was the coupling ROADMAP's parking lot and DESIGN §2.12
## flagged: "how far does my presence set the fight's pace" and "how far does my voice carry" are different
## questions, and answering both with one per-type number meant the back rows of a big room never joined a fight
## while a wall was no obstacle at all. The two are decoupled here — the tactical bubble keeps tuning pace only.
##
## LIVE HOST-SIDE READ, deliberately at the moment of the shout rather than cached at activation: this brain runs
## only on the host (§2.5), and reading GameManager.config here is what lets `/config rally_travel_tiles N` (or
## the panel row) land on the very next shout with no restart.
func _rally_pack() -> void:
	if _combat == null or _monster_type == null:
		return
	_combat.rally_pack(_entity_id, GameManager.config.rally_travel_tiles)


## Roll this instance's AI personality at activation (v0.22.0), host-only. Uniform pick over the authored pool;
## an EMPTY pool (every monster today except the shaman) leaves _personality null = neutral, all multipliers
## 1.0. A null slot in the array is a misauthored .tres — treated as neutral rather than crashed on. The roll
## prints to the host log so a session can tell two same-named shamans apart with no new UI.
func _roll_personality() -> void:
	_personality = null
	if _monster_type == null or _monster_type.personalities.is_empty():
		return
	_personality = _monster_type.personalities[randi() % _monster_type.personalities.size()]
	if _personality == null:
		return
	print("[Brain] %s %d personality: %s" % [_monster_type.display_name, _entity_id, _personality.display_name])


## This instance's HEAL score multiplier (1.0 when it rolled no personality). Read fresh each think so a
## live-edited personality .tres retunes without a respawn.
func _heal_weight_mult() -> float:
	return _personality.heal_weight_mult if _personality != null else 1.0


## This instance's SMITE score multiplier (1.0 when it rolled no personality). Twin of _heal_weight_mult.
func _smite_weight_mult() -> float:
	return _personality.smite_weight_mult if _personality != null else 1.0


## The rolled personality's name for logs / the debug event — "neutral" when none was rolled.
func _personality_name() -> String:
	return _personality.display_name if _personality != null else "neutral"


## Aggro acquire + leash decision (monster_type.aggro_range_tiles + aggro_persists, DESIGN §2.8),
## with the _aggroed latch side effect. aggro_range_tiles <= 0 (or a null type — a client's inert
## brain, which never reaches here) = UNLIMITED aggro, so the gate is skipped and we always chase.
## Otherwise ACQUIRE when the nearest is within range (latching _aggroed); with aggro_persists true
## (default) range no longer matters once latched — the chase never leash-drops, following across
## rooms. With aggro_persists false the legacy LEASH returns: _aggroed tracks current in-range state
## and the chase drops the instant the target breaks range. Returns whether to engage.
##
## WALL-BOUNDED ACQUISITION (v0.31.0): on the ACQUIRE EDGE ONLY — not yet latched, and inside the
## Chebyshev range — the target must also be reachable through OPEN FLOOR, i.e. present in
## WorldGrid.tiles_within_travel(my_tile, aggro_range_tiles). Same SOUND MODEL as the v0.30.0 pack
## rally, and the same BFS: a monster notices someone it could walk to, not someone standing on the
## far side of a wall two tiles away. In open floor travel distance EQUALS Chebyshev, so open-room
## behaviour is bit-for-bit what it was; the fill only ever takes tiles away.
##
## THE BFS RUNS ON THAT EDGE ALONE. An already-latched monster short-circuits on _aggroed (a chase
## across rooms is exactly what aggro_persists promises, and re-testing reach would silently
## reintroduce a leash); aggro_range_tiles <= 0 (unlimited) still skips the whole gate before we get
## here. So the cost is one capped flood-fill per acquisition, not per think.
##
## DELIBERATELY UNTOUCHED: `notify_attacked` still aggros regardless of walls or range — being shot
## wakes you up wherever the arrow came from (no free sniping, monster.gd:114). Flee and banter
## ranges keep their pure-Chebyshev reads; only ACQUISITION learned about walls.
func _should_chase(my_tile: Vector2i, nearest_tile: Vector2i, nearest_dist: int) -> bool:
	if _monster_type == null or _monster_type.aggro_range_tiles <= 0:
		return true
	if nearest_dist <= _monster_type.aggro_range_tiles:
		if _aggroed:
			return true                     # already latched: no re-test, no BFS
		if not WorldGrid.tiles_within_travel(my_tile, _monster_type.aggro_range_tiles).has(nearest_tile):
			return _aggroed                 # in Chebyshev range but behind a wall — keep idling
		_aggroed = true
	elif not _monster_type.aggro_persists:
		_aggroed = false
	return _aggroed


## Recompute this monster's engagement from live referee state and REPORT it to the pace referee
## (Tactical Zones v1, §2.8.7) — called every think so the resolver always has this monster's current
## (aggroed, chase target) for the tactical bubble + leash. Latches _aggroed via _should_chase, resolves
## the leash target id as the nearest player's id (0 when not chasing) into a LOCAL, reports, and returns
## whether to engage. Empty targets → disengage (report false). Shared by the idle branch and the busy loop.
func _update_engagement(my_tile: Vector2i, targets: Array) -> bool:
	if targets.is_empty():
		_report_engagement(false, 0)
		return false
	# ONE nearest scan (review #8): pick the nearest target TILE, then derive its Chebyshev distance
	# here — the aggro decision and the leash-target id both key off the SAME pick, no twin scans.
	var nearest := _nearest_target(my_tile, targets)
	var nearest_dist := maxi(absi(nearest.x - my_tile.x), absi(nearest.y - my_tile.y))
	# PACK RALLY (v0.22.0): _should_chase latches _aggroed on a proximity ACQUIRE. Capture the pre-state so
	# the rally fires on that LATCHING EDGE only — this runs every think (and the busy pipeline calls
	# _should_chase too), so an unguarded fan-out would re-rally the whole bubble several times a second.
	var was_aggroed := _aggroed
	var chasing := _should_chase(my_tile, nearest, nearest_dist)
	if _aggroed and not was_aggroed:
		_rally_pack()
	# The leash target is the id occupying that nearest tile (authoritative occupancy, not a rendered
	# position). Cleared to 0 when not chasing. A LOCAL, not a field: it is written and read only within
	# this call (reported straight to the pace referee) — no think ever reads a previous think's value.
	var target_id: int = _referee.entity_at(nearest) if chasing else 0
	_report_engagement(chasing, target_id)
	return chasing


## Report this monster's engagement to the pace referee (guarded for a client's null-pace inert brain,
## which never thinks anyway). The ONE call site wrapper so both the idle and busy paths report identically.
func _report_engagement(aggroed: bool, target_id: int) -> void:
	# THINKING hesitation roll (v0.24.0), on the became-engaged edge only — one site, shared by the
	# legacy, kiter, utility and busy paths (they all report through here). Host RNG; duration in
	# beats at this monster's resolved pace (engaged = tactical). The `thinking` event drives the
	# overhead cue on every peer. Tied to the /stamina master toggle: off = pre-experiment AI exactly.
	var was_engaged := _last_reported_engaged
	var old_target := _last_reported_target
	_last_reported_engaged = aggroed
	_last_reported_target = target_id
	if _pace != null:
		_pace.report_engagement(_entity_id, aggroed, target_id)
	# Roll AFTER the referee records the engagement (boot-check finding, v0.24.0): beat_or_explore
	# resolves a monster tactical iff its engagement is on record, so rolling first priced the
	# hesitation at the EXPLORE beat. Order fixed — the think window now scales with the fight tempo.
	if aggroed and not was_engaged:
		_begin_think("engaged")
		return
	# RETARGET-after-a-kill (v0.24.3 story beat): still engaged, the leash moved, and the OLD target
	# is GONE from the referee (dead / disconnected — an untracked id reads the wall sentinel). A
	# switch between two LIVING players (crossing fight) deliberately rolls nothing — that would be
	# recurring noise, not a beat. Gives the survivors a breath while it picks its next victim.
	if aggroed and was_engaged and target_id != old_target and old_target != 0 \
			and WorldGrid.is_wall(_referee.tile_of_entity(old_target)):
		_begin_think("retarget")


## Roll one hesitation window (v0.24.0, reasons v0.24.3): monster_think_min/max_beats (host RNG,
## min/maxi-ordered so a live retune that momentarily inverts the pair can't crash randi_range) at
## this monster's resolved pace, hold the whole brain, and post the cue event. `reason` rides the
## event so presentation can flavor it ("engaged" gets the "!" alert lead-in; story beats get dots
## only) and scripted runs can assert which trigger fired. Gated on the /stamina master toggle.
func _begin_think(reason: String) -> void:
	if not GameManager.config.stamina_enabled:
		return
	var lo := mini(GameManager.config.monster_think_min_beats, GameManager.config.monster_think_max_beats)
	var hi := maxi(GameManager.config.monster_think_min_beats, GameManager.config.monster_think_max_beats)
	var think_sec := randi_range(lo, hi) * PaceReferee.beat_or_explore(_pace, _entity_id)
	_thinking_until_msec = Time.get_ticks_msec() + int(think_sec * 1000.0)
	NetEvents.post_event("thinking", {
		"entity_id": _entity_id, "duration_sec": think_sec, "reason": reason,
	})
	# Goblin banter (v0.24.4): the story beat may also get a one-liner — chance + global cooldown
	# live in Banter, lines in GameConfig. A thinking monster muttering over its dots is the bit.
	var speaker_name: String = _monster_type.display_name if _monster_type != null else "Goblin"
	Banter.bark(_entity_id, speaker_name, reason, _authoritative_tile())


## LAST-STAND check (v0.24.3, once per life): this monster fought beside engaged allies and now
## fights alone — the Warren finale moment (the survivor's flee weight decays and it turns). The
## engaged-ally count comes from the pace referee's engagement map (no container ref needed).
## Returns true when it just rolled, so the caller reschedules instead of acting this think.
func _check_last_stand() -> bool:
	if _pace == null or not _last_reported_engaged or _last_stand_done:
		return false
	if _pace.engaged_count_excluding(_entity_id) > 0:
		_saw_engaged_allies = true
		return false
	if not _saw_engaged_allies:
		return false
	_last_stand_done = true
	_begin_think("last_stand")
	return _is_thinking()


## Is at least ONE engaged allied monster within BANTER EARSHOT of this one (v0.27.1)? The "is this MY
## fight" test the help_me bark needs, replacing a map-wide `engaged_count_excluding > 0` that fired the
## scream whenever ANY fight was happening anywhere (three authored packs in separate rooms made that a
## real cross-fight bug). Tiles come from the MOVE referee's AUTHORITATIVE occupancy — never a rendered
## position — and the ally list from the pace referee's engagement map through its own accessor, so this
## brain still holds no container reference and duck-types no referee internals. Chebyshev, matching every
## other radius test in the codebase. An entity with no occupancy (mid-teardown) reads the wall sentinel
## and is skipped. Missing referees (a client's brain, which never activates) read false.
func _has_engaged_ally_within_earshot() -> bool:
	if _pace == null or _referee == null:
		return false
	var my_tile: Vector2i = _referee.tile_of_entity(_entity_id)
	if WorldGrid.is_wall(my_tile):
		return false
	var earshot: int = GameManager.config.banter_earshot_tiles
	for ally_id in _pace.engaged_ids_excluding(_entity_id):
		var tile: Vector2i = _referee.tile_of_entity(ally_id)
		if WorldGrid.is_wall(tile):
			continue
		if maxi(absi(tile.x - my_tile.x), absi(tile.y - my_tile.y)) <= earshot:
			return true
	return false


## THINKING hold read (v0.24.0): true while this brain's hesitation deadline is in the future.
func _is_thinking() -> bool:
	return Time.get_ticks_msec() < _thinking_until_msec


## THIS monster's AUTHORITATIVE tile (v0.28.0) — the MOVE referee's occupancy truth, never the node's
## presentation `tile`. Exists for the four Banter.bark call sites: the bark payload carries the speaker's
## tile so every peer's log can gate on earshot, and that number MUST come from the same authority the
## overhead label is positioned from or the two could disagree. An untracked / mid-teardown monster reads
## the wall sentinel, which the log treats as "unknown — print anyway" rather than silently swallowing a
## line. Null referee (a client's brain, which never activates) reads the sentinel too.
func _authoritative_tile() -> Vector2i:
	if _referee == null:
		return Vector2i.ZERO
	return _referee.tile_of_entity(_entity_id)


## RECOVERY LOCKOUT read (v0.28.0, GameConfig.recovery_locks_actions — DESIGN §2.2.10): is this monster's
## ACTION channel locked because it is sitting at 0 stamina in tactical pace? The MOVE referee owns the
## predicate (is_recovering) — this brain only asks. Consulted at every ATTACK/CAST decision site and at
## NO movement site: a recovering monster may still crawl (or be hard-stopped by the winded dial, which is
## the other channel's business), it just may not swing, smite or heal. Mirrors the player side exactly.
##
## WHY THE BRAIN SKIPS RATHER THAN LETTING THE VALIDATOR REFUSE: a monster's attack does not go through
## an intent validator at all (it calls CombatReferee.wind_up / smite_cast / heal_cast directly), so this
## IS the enemy-side gate, not a convenience. The skip is silent — nothing is submitted, so there is no
## reject line and no bonk for a monster (§2.3.4 governs the PLAYER's refusals).
## Null referee (a client's brain, which never activates) reads false.
func _recovery_locks_actions() -> bool:
	return GameManager.config.recovery_locks_actions and _referee != null \
			and _referee.is_recovering(_entity_id)


## ROOTED read (v0.34.0 conditions, DESIGN §2.13): are this monster's feet held? The COMBAT referee owns the
## predicate (is_rooted) — this brain only asks. The exact MIRROR-IMAGE of _recovery_locks_actions above: that
## one gates every ACTION site and no movement site; this one gates every MOVEMENT site (chase step, pipelined
## step, flee step, heal-approach walk, utility approach) and no action site. A rooted monster still swings,
## smites and heals — "the condition fights back" is Jon+Jeff's ruling, and it is what makes a root a
## positioning tool rather than a stun.
##
## UNLIKE the action lockout, this is NOT the authority: MoveReferee._validate_glide refuses a rooted glide
## regardless. The brain checks only so a held monster does not burn one refused submit per think for the
## whole window. Null combat ref (a client's brain, which never activates) reads false.
func _is_rooted() -> bool:
	return _combat != null and _combat.is_rooted(_entity_id)


## v0.28.0: back off to the END of the recovery wait when the lockout is what stopped us, and to the normal
## rethink cadence otherwise. Without this a recovery-locked monster would re-poll every rethink_beats and
## spin skip → re-think → skip for the whole wait; the referee's own estimate (rounded UP, so we never wake
## early and re-spin) is the right span to sleep. The referee owns that math — deriving it here from the
## pool + the regen dials would drift the moment one of those dials is retuned.
func _reschedule_recovery_aware() -> void:
	if _recovery_locks_actions():
		_reschedule_after(_referee.recovery_remaining_sec(_entity_id))
		return
	_reschedule()


## IDLE CHATTER (v0.27.0 banter): arm THIS brain's next out-of-combat muttering tick, 15-30s out (host
## RNG). A get_tree() SceneTreeTimer like every other brain timer, so it survives on the host tree and
## Godot drops the connection if this brain is freed. Deliberately its own chain rather than a hook on
## _think: idle monsters think on a back-off cadence measured in beats and would chatter at fight tempo,
## and a monster with nothing to decide should still have a voice. Inert on a client (never activated).
func _arm_idle_banter() -> void:
	if not _active:
		return
	get_tree().create_timer(randf_range(_IDLE_BANTER_MIN_SEC, _IDLE_BANTER_MAX_SEC)) \
			.timeout.connect(_on_idle_banter_tick.bind(_banter_idle_gen))


## One idle-chatter tick. Three gates, then re-arm unconditionally (the chain must not die on a skip, or a
## monster that happened to be fighting once would go permanently mute):
##  - generation / _active — a previous life's booked tick, or a deactivated brain: drop it entirely.
##  - alive               — a dead monster says nothing (its node is usually freed too; belt).
##  - NOT tactical        — this is OUT-OF-COMBAT flavor. In a fight the story-beat moments own the voice,
##                          and idle mumbling over a swing would read as broken AI.
## The bark itself is chance + global-cooldown gated inside Banter, which is what keeps it rare.
func _on_idle_banter_tick(gen: int) -> void:
	if not _active or gen != _banter_idle_gen:
		return
	if _combat != null and not _combat.is_alive(_entity_id):
		return
	if _pace == null or not _pace.is_tactical(_entity_id):
		Banter.bark(_entity_id, _monster_type.display_name if _monster_type != null else "Goblin", "idle",
				_authoritative_tile())
	_arm_idle_banter()


## v0.25.0 (/mi per-instance tuning): migrate this brain's captured type ref to the instance-local
## duplicate (or back to the shared .tres on /mi reset). Called synchronously by the Monster node's
## set_instance_type inside the /mi validator, so the very next think reads the new resource — the
## GLM plan review's race (a stale captured ref silently ignoring instance tunes) cannot occur.
func set_monster_type(new_type: MonsterType) -> void:
	_monster_type = new_type


## First step DIRECTION toward the nearest player by path length over the walls-only A* grid, or
## Vector2i.ZERO if every player is unreachable. Body occupancy is deliberately NOT baked into that grid
## (bodies are volatile) — but as of v0.10.4 a monster ROUTES AROUND its waiting siblings: every OTHER
## monster's tile (from _referee.monster_tiles) is handed to find_path as `avoid` (temp-solid for THAT
## query only, then restored), so a goblin behind another goblin detours instead of stalling. FALLBACK:
## if NO target is reachable while avoiding siblings (a corridor genuinely blocked by monsters — a true
## chokepoint), retry WITHOUT avoid so we still return the blocked straight step; the referee then refuses
## it (a sibling holds the tile) and the caller reschedules = orderly queueing at the choke. A monster must
## never dither pathless when a route exists through a waiting sibling. The referee's validator remains the
## authority on whether the chosen step is actually free. Shared by the idle branch and the busy-think pipeline.
func _first_step_toward(my_tile: Vector2i, targets: Array) -> Vector2i:
	var avoid: Array[Vector2i] = _referee.monster_tiles(_entity_id)
	# A target must never be in its own avoid set (v0.23.3 review fix): find_path temp-solids avoid tiles
	# and protects only `from`, so a MONSTER-tile destination (the heal-walk's patient) would be solid and
	# the sibling-avoiding attempt would ALWAYS fail to the naive retry — silently losing the routing this
	# function exists for. A no-op for player-tile targets (never in monster_tiles), so chase is unchanged.
	for t in targets:
		avoid.erase(t)
	var dir := _best_first_step(my_tile, targets, avoid)
	if dir != Vector2i.ZERO:
		return dir
	# No sibling-avoiding route to ANY target — fall back to the straight walls-only path (keep today's
	# blocked-step-then-queue behavior at a true chokepoint). Skips the retry when there was nothing to
	# avoid (avoid empty ⇒ the first scan already used the walls-only grid).
	if avoid.is_empty():
		return Vector2i.ZERO
	return _best_first_step(my_tile, targets, [])


## The shared path scan: first step DIRECTION toward the NEAREST reachable target over the walls-only A*
## grid with `avoid` tiles temp-solid, or Vector2i.ZERO if every target is unreachable under that avoid set.
func _best_first_step(my_tile: Vector2i, targets: Array, avoid: Array[Vector2i]) -> Vector2i:
	var best_path: Array[Vector2i] = []
	for t in targets:
		var path := WorldGrid.find_path(my_tile, t, avoid)
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
	_reschedule_after(rethink_beats * PaceReferee.beat_or_explore(_pace, _entity_id))


## Schedule one re-think `sec` from now. A get_tree() SceneTreeTimer (not a Timer child) so it
## survives on the host tree exactly as the referees' completion timers do; if this brain is freed
## (despawn) before it fires, Godot drops the connection to the freed method — no stale call. Used
## both for the normal back-off cadence and, with a longer span, to wake just past a wind-up's end.
func _reschedule_after(sec: float) -> void:
	# ONE pending re-think, ever (v0.22.1 battle-run fix). Pre-existing since the brain's first version and
	# affecting EVERY monster: activate()'s deferred think starts one self-perpetuating timer chain, and the
	# spawn seed-glide's glide_finished -> on_boundary starts a SECOND — leaving every idle monster thinking
	# at ~2x the authored cadence for its whole life (observed as 0.06s-apart doublets in the /ai battle
	# traces; invisible before because an idle think is a silent no-op). Deduping here collapses the chains:
	# a think that is already booked absorbs any further request. Safe with the long post-commit waits: if a
	# short idle timer preempts a _reschedule_after(cast_sec) booking, the early think lands in the BUSY gate,
	# which re-schedules the settle backstop from the live busy record — the wake-at-free contract self-heals.
	if _rethink_pending:
		return
	_rethink_pending = true
	get_tree().create_timer(sec).timeout.connect(_think)
