extends Node

## Single source of truth for top-level scene paths — main_menu.gd, main.gd, and debug.gd
## all navigate via load() on these instead of scattering path strings. Deliberately plain
## strings, NOT preloaded PackedScene consts: preloading scenes from an autoload created a
## resource-load cycle (autoload init → main.tscn → scripts → autoload) that handed the
## client an empty PackedScene. Paths also stay comparable to Node.scene_file_path.
const MAIN_SCENE := "res://main.tscn"
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"

## Designer contract: resources/game_config.tres is where Jeff flips playtest toggles
## (bodies_block_corners, origin_frees_at_glide_start, …) WITHOUT touching code. The host
## populates this before starting the server; all game systems read from it. Loaded from the .tres
## so authored values win; a missing/broken file falls back to script defaults LOUDLY (see below).
var config: GameConfig = _load_config()

## The session's live beat (seconds) — the tempo referees read when they stamp a verdict
## (DESIGN §2.8). Seeded from GameConfig.beat_sec (or the host-only beatsec= override) at session
## start by main.gd, on EVERY peer, BEFORE the first verdict. Referees read it LIVE at stamp time
## (same pattern as debug_glide_override_sec below), so a future runtime tempo change takes effect
## from the next verdict onward — never re-deriving an in-flight commit (stamp-and-bake, §2.8.2).
## Clients may read it for local PACING only (move_input retry cadence); all adjudication is
## host-side. Seeded inline from config so it is never 0 before a session opens.
var current_beat_sec: float = config.beat_sec

## The session's live TACTICAL beat (seconds) — the second tempo dial (DESIGN §2.8.3 groundwork,
## v0.9.2). Seeded from GameConfig.tactical_beat_sec at session start by main.gd, on EVERY peer, and
## nudged live by the [ / ] keys via the set_tactical_tempo intent (host-adjudicated like set_tempo).
## GROUNDWORK ONLY: adjustable and displayed, but NOTHING reads it for stamping yet — the mode design
## (when tactical pace applies) is still open with Jeff. Seeded inline from config so it is never 0.
var tactical_beat_sec: float = config.tactical_beat_sec

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

## DEBUG ONLY. When > 0, main.gd seeds current_beat_sec from this (seconds) at session start
## instead of GameConfig.beat_sec — set host-side via debug.gd's `beatsec=` arg so a scripted run
## can test a whole-game tempo (e.g. beatsec=0.40) without editing the .tres. Host-only, mirroring
## glidesec=/windupsec=; a client seeds from its own config. Read ONCE at seed time (not live like
## the two overrides below — the beat itself is the live value). 0 = off. Never touched by gameplay.
var debug_beat_override_sec: float = 0.0

## DEBUG ONLY. When > 0, the combat referee uses this (seconds) as every monster wind-up's
## telegraph duration instead of the beats product (MonsterType.windup_beats × current_beat_sec) —
## set host-side via debug.gd's
## `windupsec=` arg (exact mirror of `glidesec=`) to stretch the wind-up window long enough to
## script a deterministic dodge/whiff. Read live by CombatReferee when it stamps a wind-up.
## 0 = off (authored per-monster pacing). Never touched by gameplay code.
var debug_windup_override_sec: float = 0.0

## DEBUG ONLY. When true, the F3 diagnostics overlay starts VISIBLE — set by debug.gd's
## `overlay=1` arg (either role, before the main scene loads) for scripted screenshots. The
## in-session toggle is always F3 regardless; gameplay code never reads this.
var debug_overlay_start_visible: bool = false

## DEBUG ONLY. When non-empty, the host applies this weapon (by display_name, resolved through
## GameConfig.weapon_roster) to its OWN player at session start — set host-side via debug.gd's
## `weapon=` arg so a scripted run can start on the dagger vs the longsword without a swap. Host-only
## (like beatsec=/hostile=); a client seeds from the scene default and a joiner syncs from the host.
## Read ONCE at the host's own spawn; an F5 reset deliberately does NOT re-apply it. Never touched by
## gameplay code.
var debug_starting_weapon: String = ""

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


## THE one beats→seconds conversion (DESIGN §2.8), paired with current_beat_sec above. Always a LIVE
## read of the current beat: because a referee stamps-and-bakes a verdict's seconds at commit time
## (§2.8.2), callers convert ONLY at verdict/stamp time (or for client-side pacing) — never caching a
## seconds value that a later tempo change would strand. Every open-coded `beats * current_beat_sec`
## routes through here so the conversion can't drift or be applied at the wrong moment.
func beats_to_sec(beats: float) -> float:
	return beats * current_beat_sec


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
