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
## THE NINE MOMENTS and who fires them (all host-side):
##   engaged / retarget / last_stand / cornered — MonsterBrain._begin_think, one per story beat (v0.24.x)
##   ally_died / notable_death                 — CombatReferee._kill_entity, forced, mutually exclusive
##   forced_melee                              — MonsterBrain._execute_candidate, a kiter made to swing
##   idle                                      — MonsterBrain's own 15-30s out-of-combat timer
##   help_me                                   — MonsterBrain.notify_attacked, notable + allies fighting
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
static func bark(speaker_id: int, speaker_name: String, moment: String, speaker_tile: Vector2i,
		force: bool = false) -> void:
	var config := GameManager.config
	if not config.banter_enabled:
		return
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
	if lines.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - _last_bark_msec < int(config.banter_cooldown_sec * 1000.0):
		return
	if not force and randf() > config.banter_chance:
		return
	_last_bark_msec = now
	NetEvents.post_event("banter", {
		"entity_id": speaker_id, "name": speaker_name, "text": lines.pick_random(),
		"tile": speaker_tile,
	})
