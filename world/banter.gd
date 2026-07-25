class_name Banter
extends RefCounted

## GOBLIN BANTER (v0.24.4, Jon's ask) — one-line overhead barks at pivotal combat moments, host-picked
## so every peer reads the SAME line from the same goblin (multiplayer-first; a client-side random
## would show each player different dialogue). Static-only: no node, no autoload — the two host-side
## callers (MonsterBrain's story-beat thinks, CombatReferee's monster-death hook) call Banter.bark()
## and the outcome rides one `banter` event.
##
## LINES ARE CONTENT and live as @export arrays on GameConfig (banter_engaged / _retarget /
## _last_stand / _cornered / _ally_died) — a designer rewrites goblin dialogue in game_config.tres,
## never here (CLAUDE.md: "add a .tres, not a script"). Empty array = that moment stays silent.
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
static func bark(speaker_id: int, speaker_name: String, moment: String, force: bool = false) -> void:
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
	})
