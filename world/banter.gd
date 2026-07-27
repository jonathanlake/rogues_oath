class_name Banter
extends RefCounted

## GOBLIN BANTER (v0.24.4, Jon's ask) — one-line overhead barks at pivotal combat moments, host-picked
## so every peer reads the SAME line from the same goblin (multiplayer-first; a client-side random
## would show each player different dialogue). Static-only: no node, no autoload — the two host-side
## callers (MonsterBrain's story-beat thinks, CombatReferee's monster-death hook) call Banter.bark()
## and the outcome rides one `banter` event.
##
## LINES ARE CONTENT and live as @export arrays on GameConfig (banter_engaged / _retarget /
## _last_stand / _cornered / _ally_died, plus v0.27.0's _notable_death / _forced_melee / _idle /
## _help_me) — a designer rewrites goblin dialogue in game_config.tres, never here (CLAUDE.md: "add a
## .tres, not a script"). Empty array = that moment stays silent.
##
## THE ELEVEN MOMENTS and who fires them (all host-side):
##   engaged / retarget / last_stand / cornered — MonsterBrain._begin_think, one per story beat (v0.24.x)
##   ally_died / notable_death                 — CombatReferee._kill_entity, forced, mutually exclusive
##   forced_melee                              — MonsterBrain._execute_candidate, a kiter made to swing
##   idle                                      — MonsterBrain's own 15-30s out-of-combat timer
##   help_me                                   — MonsterBrain.notify_attacked, notable + allies fighting
##   friendly_fire_hurt / friendly_fire_oops   — CombatReferee.apply_damage, an allied monster-on-monster
##                                               hit; forced, and posted as a PAIR (victim, then culprit
##                                               a beat later) — see bark_friendly_fire (v0.35.0)
##
## EARSHOT (v0.28.0, Jon: "gate ALL barks by distance, not just idle"): every bark now carries the
## SPEAKER'S AUTHORITATIVE TILE so each peer's game log prints the line only when its own player is within
## GameConfig.banter_earshot_tiles (Chebyshev) of it. One dial, one meaning — the same number that already
## scoped which monster REACTS to a death now also scopes who HEARS the result.
##
## Throttles: banter_chance rolls per bark (story beats shouldn't ALWAYS talk — surprise is flavor)
## and one global cooldown (banter_cooldown_sec, wall-clock) stops a wall of text when five goblins
## latch at once at the Warren mouth. `force` (the ally-died revenge bark) skips the chance roll but
## still respects the cooldown.

# Global last-bark instant (msec). Static state is fine host-side: barks only ever post on the host,
# and one shared cooldown across all speakers is exactly the intent (a room speaks one line at a time).
static var _last_bark_msec: int = 0

## Gap between the two halves of a friendly-fire exchange (seconds, wall-clock). Long enough that the
## culprit's line reads as an ANSWER to the victim's rather than a simultaneous shout, short enough that the
## two still belong to the same moment. Tuned by feel, not by beats — this is comic timing, not combat.
const _FRIENDLY_FIRE_REPLY_SEC := 0.7


## Host-only. Maybe post one bark from `speaker_id` for `moment`. Silent no-op when disabled, no
## lines are authored for the moment, the chance roll fails (unless force), or the cooldown holds.
## `speaker_name` rides the event for the log line (this class holds no container refs to resolve it).
##
## `speaker_tile` (v0.28.0) rides it too, so each peer's GAME LOG can gate the printed line on EARSHOT —
## `GameConfig.banter_earshot_tiles`, Chebyshev, the same one dial the host-side mourner/help-me picks
## already use, now meaning one thing everywhere: "how far a bark carries". This class is static and holds
## no referee, so CALLERS PASS IT IN — and every caller MUST read it from the referee's AUTHORITATIVE
## occupancy (tile_of_entity), never a cached or rendered field, or the gated distance could disagree with
## where the overhead label actually floats. The overhead label itself stays UNGATED (distance already
## hides it, and per-peer gating would break this class's "every peer reads the same line" premise).
## `interrupt` (v0.35.0) additionally skips the one-voice-at-a-time COOLDOWN — see the note at the gates
## below for why it is a separate flag from `force` and not a widening of it. Reserved for a bark that is
## the SECOND half of a paired exchange; a lone bark has no reason to jump the queue.
## RETURNS whether a line actually went out, so a caller composing a multi-bark exchange can tell that its
## first half was thrown away and abandon the rest (bark_friendly_fire is the one such caller today). Every
## other caller ignores it, exactly as before.
static func bark(speaker_id: int, speaker_name: String, moment: String, speaker_tile: Vector2i,
		force: bool = false, interrupt: bool = false) -> bool:
	var config := GameManager.config
	if not config.banter_enabled:
		return false
	var lines: Array[String] = []
	match moment:
		"engaged":
			lines = config.banter_engaged
		"retarget":
			lines = config.banter_retarget
		"last_stand":
			lines = config.banter_last_stand
		"cornered":
			lines = config.banter_cornered
		"ally_died":
			lines = config.banter_ally_died
		# v0.27.0 moments (Jeff's second playtest verdict — "more banter, and scope the death one"):
		"notable_death":
			lines = config.banter_notable_death
		"forced_melee":
			lines = config.banter_forced_melee
		"idle":
			lines = config.banter_idle
		"help_me":
			lines = config.banter_help_me
		# v0.35.0 friendly fire — a two-sided moment, so two moments (victim, then culprit).
		"friendly_fire_hurt":
			lines = config.banter_friendly_fire_hurt
		"friendly_fire_oops":
			lines = config.banter_friendly_fire_oops
	if lines.is_empty():
		return false
	var now := Time.get_ticks_msec()
	# TWO SEPARATE OVERRIDES, deliberately not one (v0.35.0). `force` keeps its original and only meaning —
	# skip the CHANCE roll — so every existing forced moment (ally_died, notable_death, help_me) behaves
	# exactly as it did. `interrupt` is the new, narrower one: skip the COOLDOWN too.
	#
	# They were nearly merged, and shouldn't be. The friendly-fire exchange genuinely needs the cooldown
	# bypass — its two halves are one joke told a beat apart, and the second was always swallowed by the
	# cooldown the first had just stamped, leaving a goblin shouting "you IDIOT!" at nobody. But folding
	# that into `force` would have handed the same bypass to the death barks, where the one-voice rule is
	# doing real work: a pack wiping in one fight is several forced ally_died barks inside one cooldown
	# window, and letting them all through is the wall of text this throttle exists to prevent. So the
	# widening stops at the caller that asked for it.
	if now - _last_bark_msec < int(config.banter_cooldown_sec * 1000.0) and not interrupt:
		return false
	if not force and randf() > config.banter_chance:
		return false
	_last_bark_msec = now
	NetEvents.post_event("banter", {
		"entity_id": speaker_id, "name": speaker_name, "text": lines.pick_random(),
		"tile": speaker_tile,
	})
	return true


## Post a FRIENDLY-FIRE EXCHANGE (v0.35.0): the victim yells now, the culprit answers a beat later. Host-only.
##
## Two barks rather than one because that is what makes it funny — the joke is the reply, not the injury. The
## gap is what keeps it reading as a conversation instead of two goblins talking over each other. This
## function owns the pairing rule, including its ALL-OR-NOTHING half, so no caller has to remember either.
##
## `tree` is passed in because this class is static and holds no node — the CombatReferee caller has one.
##
## THE CULPRIT'S TILE IS CAPTURED NOW, not re-read at reply time: a moving goblin may be one step away from it
## when the line lands. That only feeds the game log's earshot gate (the overhead bubble follows the speaker's
## NODE, so it is always in the right place), and being one tile off on a 12-tile radius changes nothing worth
## threading a referee reference through a static class for.
static func bark_friendly_fire(tree: SceneTree, victim_id: int, victim_name: String, victim_tile: Vector2i,
		culprit_id: int, culprit_name: String, culprit_tile: Vector2i) -> void:
	# The victim's yell is forced but does NOT interrupt — if the room is already mid-bark, this one waits its
	# turn like anything else. It is the REPLY below that must jump the queue, because the only thing standing
	# in ITS way is the yell we just posted.
	#
	# AND THE EXCHANGE IS ATOMIC: a swallowed yell means no reply is scheduled at all. Otherwise the cooldown
	# could eat the setup and still let the punchline through on its own, and "whoops." with nothing before it
	# reads as a bug rather than a joke — the same half-an-exchange failure the interrupt flag exists to
	# prevent, arriving from the other end.
	if not bark(victim_id, victim_name, "friendly_fire_hurt", victim_tile, true):
		return
	# Fire-and-forget: if the culprit dies or despawns inside the gap the line still posts, which is correct —
	# the words were already out of its mouth when the arrow landed, and every peer resolves the speaker
	# node defensively anyway (a missing node just means no overhead bubble, the log line stands).
	tree.create_timer(_FRIENDLY_FIRE_REPLY_SEC).timeout.connect(
			func() -> void:
				bark(culprit_id, culprit_name, "friendly_fire_oops", culprit_tile, true, true))
