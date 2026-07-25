extends Node

## Single source of truth for top-level scene paths — main_menu.gd, main.gd, and debug.gd
## all navigate via load() on these instead of scattering path strings. Deliberately plain
## strings, NOT preloaded PackedScene consts: preloading scenes from an autoload created a
## resource-load cycle (autoload init → main.tscn → scripts → autoload) that handed the
## client an empty PackedScene. Paths also stay comparable to Node.scene_file_path.
const MAIN_SCENE := "res://main.tscn"
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"

## Dev-command tuning tables (v0.10.0 /w & /m), the ONE authoring site shared by the dev-command
## validator (DevCommands) AND the /help renderer (game_log) — so the allowed fields, their int/float
## kinds, and their sane ranges can never drift between the code that enforces them and the help that
## documents them. Each CLAMPS entry is [min, max]; a value outside it is REJECTED (not silently
## clamped), naming the range, at the validator. The field is stored as an int when it appears in the
## matching *_INT_FIELDS list, else as a float.
const DEV_WEAPON_FIELDS := ["damage", "recovery_beats", "windup_beats"]
const DEV_WEAPON_INT_FIELDS := ["damage"]
const DEV_WEAPON_CLAMPS := {
	"damage": [0, 999],
	"recovery_beats": [0.05, 30.0],
	"windup_beats": [0.0, 30.0],
}
const DEV_MONSTER_FIELDS := ["max_hp", "aggro_range_tiles", "tactical_radius_tiles",
	"bonus_windup_beats", "bonus_recovery_beats", "bonus_damage",
	# Spell-casting params (v0.19.10) — ALL live-tunable via /m, not just the heal (Jon's ask).
	"heal_amount", "heal_range_tiles", "heal_cast_beats", "heal_recovery_beats",
	"smite_damage", "smite_range_tiles", "smite_cast_beats", "smite_recovery_beats", "flee_range_tiles",
	# Weighted utility AI weights (v0.22.0). Live-tuning these mid-fight IS the balancing loop: `/ai` shows
	# the running scores in the F3 overlay, `/m shaman utility_smite_weight 80` moves them. All floats
	# except backup_radius_tiles (which also joins the INT list below).
	"utility_tiebreak_margin", "utility_heal_weight", "utility_heal_per_injured_bonus",
	"utility_smite_weight", "utility_standstill_bonus", "utility_smite_adjacent_penalty",
	"utility_melee_weight", "utility_melee_alone_bonus", "utility_flee_weight",
	"utility_alone_move_factor", "utility_approach_weight", "backup_radius_tiles", "heal_seek_radius_tiles"]
const DEV_MONSTER_INT_FIELDS := ["max_hp", "aggro_range_tiles", "tactical_radius_tiles", "bonus_damage",
	"heal_amount", "heal_range_tiles", "smite_damage", "smite_range_tiles", "flee_range_tiles",
	"backup_radius_tiles", "heal_seek_radius_tiles"]
const DEV_MONSTER_CLAMPS := {
	"max_hp": [1, 99999],
	"aggro_range_tiles": [0, 30],
	"tactical_radius_tiles": [0, 30],
	# Wielder MELEE modifiers (v0.19.0). Signed — a designer can add or subtract beats/damage on top of the
	# weapon base; the combat referee floors the effective windup/recovery/damage at 0. /m mutates the shared
	# MonsterType, which the referee reads live, so these tune in-session like the old recovery_beats did.
	"bonus_windup_beats": [-30.0, 30.0],
	"bonus_recovery_beats": [-30.0, 30.0],
	"bonus_damage": [-999, 999],
	# Spell-casting params (v0.19.10): heal + smite amounts/ranges/cast/recovery + the kiter's flee radius.
	"heal_amount": [0, 999],
	"heal_range_tiles": [0, 30],
	"heal_cast_beats": [0.0, 30.0],
	"heal_recovery_beats": [0.0, 30.0],
	"smite_damage": [0, 999],
	"smite_range_tiles": [0, 30],
	"smite_cast_beats": [0.0, 30.0],
	"smite_recovery_beats": [0.0, 30.0],
	"flee_range_tiles": [0, 30],
	# Utility-AI weights (v0.22.0). Scores live on a loose 0-100 scale and only their RELATIVE order matters,
	# so [0, 200] is "any sane weight, plus headroom to make one dominate" — a value outside it is a typo, not
	# a tuning. The three odd ones out: the tie-break margin is a score DISTANCE (a band wider than ~50 would
	# make the coin flip the decision, which is not what the AI is for), the alone-move factor is a
	# MULTIPLIER that must stay in [0,1] (above 1 it would turn courage into cowardice), and the backup radius
	# is a TILE COUNT sharing the [0,30] range every other radius here uses.
	"utility_tiebreak_margin": [0.0, 50.0],
	"utility_heal_weight": [0.0, 200.0],
	"utility_heal_per_injured_bonus": [0.0, 200.0],
	"utility_smite_weight": [0.0, 200.0],
	"utility_standstill_bonus": [0.0, 200.0],
	"utility_smite_adjacent_penalty": [0.0, 200.0],
	"utility_melee_weight": [0.0, 200.0],
	"utility_melee_alone_bonus": [0.0, 200.0],
	"utility_flee_weight": [0.0, 200.0],
	"utility_alone_move_factor": [0.0, 1.0],
	"utility_approach_weight": [0.0, 200.0],
	"backup_radius_tiles": [0, 30],
	"heal_seek_radius_tiles": [0, 30],
}

## Dev GAME-LEVEL preset fields (v0.22.1) — the allowlist for CONFIG_PRESETS' third row kind, "g". Unlike the
## weapon/monster allowlists above, these are NOT resource fields fed through the shared clamp/mutate pipeline:
## a game-level value lives on GameManager (per-peer) or behind a host-adjudicated broadcast, so each field is
## DISPATCHED PER-FIELD in _dev_cmd_config — this is a per-field switch, not a generic pipeline, and adding a
## field here means writing its branch too. Deliberately so: each one needs its own authority story, and a
## generic setter that wrote GameManager members directly would leave every client stale. The ONLY field today
## is the TACTICAL BEAT, routed through the existing set_tactical_tempo broadcast (snap/clamp exactly as the
## host validator does, then post the event) so every peer adopts it through the one _apply_tactical_tempo
## chokepoint. Lives here beside the other allowlists so /help can derive the list from one source.
## v0.24.0 adds the stamina-experiment regen dials; v0.24.1 the exhausted-crawl dial. Authority story
## (per the rule above): all three are read HOST-side only (MoveReferee reads them live at each arm /
## stamp), so their branches are plain host-side config writes — no broadcast, no client ever reads them.
## v0.25.0 overhaul: every stamina dial split player_/monster_. Plain-write fields dispatch through
## DevCommands._GAME_FIELD_SPECS (one shared authority story); tactical_beat_sec keeps its bespoke
## broadcast branch. This list MUST cover specs ∪ bespoke — /help derives from it.
## v0.26.0: the player idle wait became three ARMOR-WEIGHT dials (light covers UNARMORED too), so the
## single player_regen_idle_beats field is GONE from this list — a stale `/config player_regen_idle_beats`
## now rejects, which is correct (the field no longer exists on GameConfig).
const DEV_GAME_FIELDS := ["tactical_beat_sec",
		"player_regen_idle_light_beats", "player_regen_idle_medium_beats",
		"player_regen_idle_heavy_beats", "monster_regen_idle_beats",
		"player_regen_interval_beats", "monster_regen_interval_beats",
		"player_exhausted_step_beats", "monster_exhausted_step_beats",
		"player_refill_lockout_beats", "monster_refill_lockout_beats",
		"player_regen_refills_full", "monster_regen_refills_full",
		"player_passive_regen_beats", "monster_passive_regen_beats",
		"player_exhausted_blocks_movement", "monster_exhausted_blocks_movement",
		"stamina_max", "monster_stamina_max",
		"monster_think_min_beats", "monster_think_max_beats", "swing_catches_adjacent"]

## Dev CONFIG PRESETS (v0.19.7): `/config <alias>` applies a whole BUNDLE of /w + /m tunings in one command, so
## a repeated test loadout is a single keystroke instead of five. Lives HERE (beside the DEV_* allowlists) so
## both the DevCommands validator (which applies it) and game_log's /help (which lists the aliases) read the ONE
## source — help can't drift from what the host accepts. Each alias maps to an ORDERED list of [kind, name,
## field, value] rows: kind "w" = weapon (resolved like /w — catalog name or .tres filename), "m" = monster
## (resolved like /m — .tres filename). Every row is applied through the SAME per-field allowlist + clamp path
## /w and /m use, so a preset can never poison a resource past its clamp. ADD A NEW LOADOUT by adding an alias
## entry — no code change. Values are read live by adjudication at the next stamp (weapons/monster bonuses);
## a max_hp-style spawn-seeded field would only affect NEW spawns, same caveat as /m.
## v0.22.1 adds a THIRD kind, "g" = game-level (DEV_GAME_FIELDS above): the `name` column is a LABEL only (no
## resource to resolve) and the row is dispatched per-field rather than through the resource tune pipeline.
## A preset CLOBBERS live values by design — re-applying an alias restamps every row from this table, including
## a tempo a player had nudged with [ / ]. That is what a loadout is for: one keystroke = a known state.
const CONFIG_PRESETS := {
	"1": [
		["w", "longsword", "windup_beats", 1.0],
		["w", "longsword", "recovery_beats", 3.0],
		["w", "club", "windup_beats", 1.0],
		["w", "club", "recovery_beats", 3.0],
		["m", "goblin", "bonus_windup_beats", 1.0],
		# The fight-feel row (v0.22.1): halve the TACTICAL beat from its 0.50s default so this preset's
		# cadence (windup 1 beat / attack 3 beats) lands at 0.25s telegraphs and 0.75s swings for anyone
		# the pace referee has resolved TACTICAL. Game-level kind "g" — routed through the
		# set_tactical_tempo broadcast, never a direct GameManager write (see DEV_GAME_FIELDS above);
		# "tempo" is a label, not a resource name.
		["g", "tempo", "tactical_beat_sec", 0.25],
	],
	# Preset 2 (v0.23.2, Jon): the heavier-telegraph loadout — every weapon gets a LONG windup and a fat
	# recovery tail (dagger's shorter windup keeps it the fast option), on the same 0.25s tactical clock.
	# At that beat: longsword/club 0.75s telegraph + 1.0s tail; dagger 0.5s + 1.0s.
	"2": [
		["w", "longsword", "windup_beats", 3.0],
		["w", "longsword", "recovery_beats", 4.0],
		["w", "club", "windup_beats", 3.0],
		["w", "club", "recovery_beats", 4.0],
		["w", "dagger", "windup_beats", 2.0],
		["w", "dagger", "recovery_beats", 4.0],
		["g", "tempo", "tactical_beat_sec", 0.25],
		# v0.24.8 (Jon): the stamina loadout joins the fight-feel preset — ONE pip each side
		# (every step is precious), regen starts fast (4 idle beats) and refills fast (2/point).
		# v0.25.0: rows doubled for the player/monster split — the preset keeps both sides equal.
		# v0.26.0: the REGEN-IDLE rows are GONE from this preset. Those waits are now the shipped
		# graduated defaults (armor-weight 2.5/3.0/3.5, monsters 3.5 — Jeff's verdict), and a preset
		# row would clobber them with an older experimental number every time someone pressed /config 2.
		# The max-1 rows stay: they became the default too, so re-applying is a no-op, and keeping them
		# means the preset still states its own loadout explicitly.
		["g", "stamina", "player_regen_interval_beats", 2.0],
		["g", "stamina", "monster_regen_interval_beats", 2.0],
		["g", "stamina", "stamina_max", 1],
		["g", "stamina", "monster_stamina_max", 1],
	],
}

## Designer contract: resources/game_config.tres is where Jeff flips playtest toggles
## (bodies_block_corners, origin_frees_at_glide_start, …) WITHOUT touching code. The host
## populates this before starting the server; all game systems read from it. Loaded from the .tres
## so authored values win; a missing/broken file falls back to script defaults LOUDLY (see below).
var config: GameConfig = _load_config()

## The session's live EXPLORE beat (seconds) — the default (out-of-combat) tempo dial (DESIGN §2.8).
## RENAMED from current_beat_sec (v0.9.5, Tactical Zones): with two live paces (explore + tactical,
## §2.8.7) "current" was ambiguous — pace is now resolved PER ENTITY by PaceReferee, and this is the
## explore pole it returns when an entity is out of the fight. Seeded from GameConfig.beat_sec (or the
## host-only beatsec= override) at session start by main.gd, on EVERY peer, BEFORE the first verdict.
## The pace referee reads it LIVE at stamp time (same pattern as debug_glide_override_sec below), so a
## runtime tempo change takes effect from the next verdict onward — never re-deriving an in-flight
## commit (stamp-and-bake, §2.8.2). Clients may read it for local PACING only (move_input retry
## cadence); all adjudication is host-side. Seeded inline from config so it is never 0 before a session opens.
var explore_beat_sec: float = config.beat_sec

## The session's live TACTICAL beat (seconds) — the second tempo dial (DESIGN §2.8.3, v0.9.2). Seeded
## from GameConfig.tactical_beat_sec at session start by main.gd, on EVERY peer, and nudged live by the
## [ / ] keys via the set_tactical_tempo intent (host-adjudicated like set_tempo) or set wholesale by a
## /config preset row (v0.22.1) — both land through the same broadcast.
## LIVE, NOT GROUNDWORK (comment corrected v0.22.1 — it had gone stale at Tactical Zones v1): every
## stamp site now routes PaceReferee.beat_or_explore, which returns THIS beat for any entity the pace
## referee resolves tactical (§2.8.7). Glides, wind-ups, casts, stuns and item use all stamp from it in
## a fight, so a change here has real teeth from the next verdict onward (stamp-and-bake, §2.8.2 — never
## re-derived mid-commit). Seeded inline from config so it is never 0.
var tactical_beat_sec: float = config.tactical_beat_sec

## CLIENT-SIDE presentation / pacing MIRROR of the local player's broadcast pace (Tactical Zones v1,
## §2.8.7). Set on EVERY peer from the host-authored pace_changed event for OUR OWN id (seeds included),
## by main.gd's handler. Read ONLY for local presentation + input pacing (move_input's retry/hold cadence
## reads it so a fight's throttles match the host's stamped tactical window). It is NEVER read by any
## adjudication — the host stamps every verdict from PaceReferee alone, server-side, from shared config.
## Defaults false (explore), the correct pre-fight state on every peer before any flip.
var local_pace_is_tactical: bool = false

## Set from the main menu before host_game() / join_game(). Flows into the spawn
## dict so all peers know each player's display name independently of peer ID.
var player_name: String = ""

## Transient "why did the last session end" message. Written by main.gd's teardown paths;
## the main menu shows it in its error label on _ready and clears it. Empty = none.
var last_disconnect_reason: String = ""

## Set by the menu on EVERY Host press (assigned true or false each time — never sticky): true
## when the address field carried a :port that hosting ignored because the ip-half was a remote
## join address (main_menu.host_port's rule). Read once by main.gd's "Hosting on port" log line
## so the override is visible in-game instead of silently surprising a deliberate tunneler.
var host_port_was_ignored: bool = false

## When true, the host seeds the world with the map's monster(s) on session start. Default true so
## menu play gets the goblins; the autostart harness sets it false unless `goblin=N>0` (debug.gd), so
## the existing movement harness runs stay monster-free. Read host-side only — the host authors all
## monster spawns; clients replicate.
var spawn_monsters: bool = true

## Caps how many of main.gd's GOBLIN_SPAWN_TILES actually get a goblin. -1 = no cap (spawn all —
## menu play). The autostart `goblin=N` knob (debug.gd) sets it to N so a scripted run can seed fewer
## than the full set. Read host-side only, alongside spawn_monsters, when the host seeds the world.
var monster_spawn_cap: int = -1

## DEBUG ONLY. When true, every entity is mutually hostile — the harness `hostile=1` knob sets it
## host-side (before host_game()) so the attack-of-opportunity trigger can be demoed two-instance
## before monsters exist (M3). Players are never hostile to each other in real play; gameplay code
## never sets or reads this outside the AoO scan.
var all_hostile: bool = false

## DEBUG ONLY. When > 0, the movement referee uses this (seconds) as every glide's BASE per-step
## time instead of the mover's GlideSpeed tier — set host-side via debug.gd's `glidesec=` arg to
## stretch glides long enough to script/observe timing. The diagonal multiplier still applies on
## top. v0.8.0: this pins the GLIDE TERM / action window (rest 0 by default); the broadcast slide
## the client tweens is slide_fraction × it, NOT this value itself. 0 = off (normal tier-driven
## pacing). Never touched by gameplay code.
var debug_glide_override_sec: float = 0.0

## DEBUG ONLY. When > 0, main.gd seeds explore_beat_sec from this (seconds) at session start
## instead of GameConfig.beat_sec — set host-side via debug.gd's `beatsec=` arg so a scripted run
## can test a whole-game tempo (e.g. beatsec=0.40) without editing the .tres. Host-only, mirroring
## glidesec=/windupsec=; a client seeds from its own config. Read ONCE at seed time (not live like
## the two overrides below — the beat itself is the live value). 0 = off. Never touched by gameplay.
var debug_beat_override_sec: float = 0.0

## DEBUG ONLY. When > 0, the combat referee uses this (seconds) as every monster wind-up's
## telegraph duration instead of the beats product (MonsterType.windup_beats × the attacker's pace) —
## set host-side via debug.gd's
## `windupsec=` arg (exact mirror of `glidesec=`) to stretch the wind-up window long enough to
## script a deterministic dodge/whiff. Read live by CombatReferee when it stamps a wind-up.
## 0 = off (authored per-monster pacing). Never touched by gameplay code.
var debug_windup_override_sec: float = 0.0

## DEBUG ONLY. When true, the F3 diagnostics overlay starts VISIBLE — set by debug.gd's
## `overlay=1` arg (either role, before the main scene loads) for scripted screenshots. The
## in-session toggle is always F3 regardless; gameplay code never reads this.
var debug_overlay_start_visible: bool = false

## DEBUG ONLY. When true, the backtick DEBUG TUNING PANEL (v0.25.0) starts OPEN — set by debug.gd's
## `debugpanel=1` arg for scripted screenshots. The in-session toggle is always ` regardless.
var debug_panel_start_visible: bool = false

## DEBUG ONLY. When true, every utility-AI monster BROADCASTS its decision (`ai_decision`: the chosen action
## plus every candidate's score) after each think, and the F3 diagnostics overlay renders the last one per
## monster. Default OFF, so normal play carries zero extra wire traffic — this is a tuning instrument, not a
## feature. Toggled at RUNTIME by the host-adjudicated `/ai` dev command (unlike the debug_* knobs above,
## which debug.gd sets before the scene loads); read HOST-side only, in MonsterBrain, because only the host
## has a brain to report. A client's copy of this flag is never read and never written — the events arrive
## from the host either way, so both peers see the same overlay when the host turns it on.
var debug_ai_decisions: bool = false

## DEBUG ONLY. When true, the F7 range overlay (aggro/tactical radii) starts VISIBLE — set by
## debug.gd's `rangeoverlay=1` arg (either role, before the main scene loads) for scripted
## screenshots, mirroring `overlay=`. The in-session toggle is always F7 regardless; gameplay code
## never reads this.
var debug_range_overlay_start_visible: bool = false

## DEBUG ONLY. When non-empty, the host applies this weapon (by display_name, resolved through
## GameConfig.weapon_roster) to its OWN player at session start — set host-side via debug.gd's
## `weapon=` arg so a scripted run can start on the dagger vs the longsword without a swap. Host-only
## (like beatsec=/hostile=); a client seeds from the scene default and a joiner syncs from the host.
## Read ONCE at the host's own spawn; an F5 reset deliberately does NOT re-apply it. Never touched by
## gameplay code.
var debug_starting_weapon: String = ""

## The "unset" sentinel for debug_goblin_at — an impossible tile no real map is anywhere near, so ANY real
## tile (including (0,0)) is a valid placement. Mirrors debug_starting_weapon's empty-string-as-unset idiom.
const DEBUG_GOBLIN_AT_UNSET := Vector2i(-1000, -1000)

## DEBUG ONLY. When set (not the impossible sentinel above), the host spawns ONE extra goblin at EXACTLY
## this tile at session start — set host-side via debug.gd's `goblinat=x,y` arg. Exists so combat tests can
## place a monster at precise range geometry (first use: the ranged-aggro verification — bow range 7 vs
## goblin aggro 5). Works INDEPENDENTLY of goblin=/spawn_monsters: it only ADDS a goblin through the shared
## guarded spawn step, never touching the training dummy or the map goblins. Read ONCE at the host's
## session-start spawn (an F5 reset does NOT re-apply it, mirroring debug_starting_weapon); inert on a
## client and without the arg. Never touched by gameplay code.
var debug_goblin_at: Vector2i = DEBUG_GOBLIN_AT_UNSET

## The "unset" sentinel for debug_potion_at (v0.18.0) — an impossible tile no real map is anywhere near, so
## ANY real tile is a valid placement. Mirrors DEBUG_GOBLIN_AT_UNSET exactly.
const DEBUG_POTION_AT_UNSET := Vector2i(-1000, -1000)

## DEBUG ONLY. When set (not the impossible sentinel above), the host spawns ONE extra health potion at
## EXACTLY this tile at session start — set host-side via debug.gd's `potion=x,y` arg. Exists so pickup /
## inventory tests can place an item at precise geometry. Works INDEPENDENTLY of the session-start item set:
## it only ADDS a potion through the shared guarded _spawn_item_at. Read ONCE at the host's session-start
## placement (an F5 reset does NOT re-apply it, mirroring debug_goblin_at); inert on a client and without the
## arg. Never touched by gameplay code.
var debug_potion_at: Vector2i = DEBUG_POTION_AT_UNSET

## DEBUG ONLY. When non-empty, overrides the version string this CLIENT sends in peer_ready — set
## client-side via debug.gd's `fakever=` arg so the version-mismatch refusal path is scriptable
## two-instance without building a second binary. A send-path override ONLY: never a comparison
## basis, and the menu still shows the real version. Read client-side at peer_ready send; inert on
## a host (hosts never send peer_ready). Never touched by gameplay code.
var debug_fake_version: String = ""

# One-shot latch so a missing/typo'd config/version key warns exactly once (the referee's
# _warned_null_speed pattern), not on every read.
var _warned_missing_version: bool = false


## Load the authored session config, or fall back to script defaults. A designer-facing file
## silently reverting to defaults would mask a real problem — Jeff's playtest toggles quietly
## ignored — so a missing/broken .tres is a push_error, not a warning; the game stays runnable on
## GameConfig.new() either way. Static so it can seed `config` at autoload init with no self-order
## concern (it touches no other member).
static func _load_config() -> GameConfig:
	var loaded := load("res://resources/game_config.tres") as GameConfig
	if loaded == null:
		push_error("[GameManager] res://resources/game_config.tres missing or not a GameConfig — running on GameConfig.new() script defaults; the designer toggles in that file are being ignored.")
		return GameConfig.new()
	return loaded


## The single read path for the build version string (project.godot application/config/version,
## kept in step with the DESIGN changelog). Every version read — the menu corner, the client's
## peer_ready send, the host's gate compare, the join-timeout hint — routes through here so they
## can't drift on stripping or fallback (the review caught the menu reading it un-stripped). Falls
## back to "?" when the key is missing/empty, and push_warning announces that fallback ONCE (via
## _warned_missing_version) so a config mistake surfaces as itself instead of masquerading as a
## network version refusal.
func build_version() -> String:
	var raw := str(ProjectSettings.get_setting("application/config/version", "?")).strip_edges()
	if raw.is_empty() or raw == "?":
		if not _warned_missing_version:
			push_warning("[GameManager] application/config/version missing or empty — build version reads as '?'")
			_warned_missing_version = true
		return "?"
	return raw


## THE beats→seconds conversion at the EXPLORE beat (DESIGN §2.8), paired with explore_beat_sec above.
## Always a LIVE read: because a referee stamps-and-bakes a verdict's seconds at commit time (§2.8.2),
## callers convert ONLY at verdict/stamp time (or for client-side pacing) — never caching a seconds
## value that a later tempo change would strand.
## DELIBERATE-CONVERSION NOTE (Tactical Zones v1, §2.8.7): with two paces, this is the EXPLORE conversion
## specifically — it is NOT the pace-resolved stamp any more. Today's callers are exactly: (a) tempo UI
## text (explore-labelled, correct), and (b) fallbacks where no pace referee is present. The live STAMP
## sites (MoveReferee step/rest, CombatReferee windup/recovery) and brain pacing route through
## PaceReferee.beat_sec_for(entity_id) instead. Any FUTURE periodic-effect timing (§2.4 — a poison tick,
## a regen pulse) MUST choose its conversion deliberately: explore (this) vs the actor's resolved pace.
func beats_to_sec(beats: float) -> float:
	return beats * explore_beat_sec


## Beats-per-minute for a given beat (seconds), rounded to a whole number for display. Guards a
## non-positive beat (returns 0) so a mid-seed 0.0 or a garbage value can't divide-by-zero. The one
## BPM derivation the readouts (top-center label, F3 overlay, game log) share.
func bpm_of(beat_sec: float) -> int:
	return int(round(60.0 / beat_sec)) if beat_sec > 0.0 else 0


## The shared "%.2fs/beat (%d BPM)" fragment for the game log + sync lines, so every tempo log line
## reads identically. The top-center label keeps its own "beat %.2fs · %d BPM" layout (it computes
## BPM via bpm_of above); this is the sentence form used in the combat/system log.
func tempo_log_text(beat_sec: float) -> String:
	return "%.2fs/beat (%d BPM)" % [beat_sec, bpm_of(beat_sec)]
