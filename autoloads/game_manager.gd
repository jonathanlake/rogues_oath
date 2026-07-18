extends Node

## Single source of truth for top-level scene paths — main_menu.gd, main.gd, and debug.gd
## all navigate via load() on these instead of scattering path strings. Deliberately plain
## strings, NOT preloaded PackedScene consts: preloading scenes from an autoload created a
## resource-load cycle (autoload init → main.tscn → scripts → autoload) that handed the
## client an empty PackedScene. Paths also stay comparable to Node.scene_file_path.
const MAIN_SCENE := "res://main.tscn"
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"

## The host populates this before starting the server. All game systems read from it.
var config: GameConfig = GameConfig.new()

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

## When true, the host seeds the world with M3's monster(s) on session start. Default true so menu
## play gets the goblin; the autostart harness sets it false unless `goblin=1` (debug.gd), so the
## existing movement harness runs stay monster-free. Read host-side only — the host authors all
## monster spawns; clients replicate.
var spawn_monsters: bool = true

## DEBUG ONLY. When true, every entity is mutually hostile — the harness `hostile=1` knob sets it
## host-side (before host_game()) so the attack-of-opportunity trigger can be demoed two-instance
## before monsters exist (M3). Players are never hostile to each other in real play; gameplay code
## never sets or reads this outside the AoO scan.
var all_hostile: bool = false

## DEBUG ONLY. When > 0, the movement referee uses this (seconds) as every glide's BASE per-step
## time instead of the mover's GlideSpeed tier — set host-side via debug.gd's `glidesec=` arg to
## stretch glides long enough to script/observe conga timing. The diagonal multiplier still
## applies on top. 0 = off (normal tier-driven pacing). Never touched by gameplay code.
var debug_glide_override_sec: float = 0.0

## DEBUG ONLY. When > 0, the combat referee uses this (seconds) as every monster wind-up's
## telegraph duration instead of the MonsterType.windup_sec — set host-side via debug.gd's
## `windupsec=` arg (exact mirror of `glidesec=`) to stretch the wind-up window long enough to
## script a deterministic dodge/whiff. Read live by CombatReferee when it stamps a wind-up.
## 0 = off (authored per-monster pacing). Never touched by gameplay code.
var debug_windup_override_sec: float = 0.0

## DEBUG ONLY. When true, the F3 diagnostics overlay starts VISIBLE — set by debug.gd's
## `overlay=1` arg (either role, before the main scene loads) for scripted screenshots. The
## in-session toggle is always F3 regardless; gameplay code never reads this.
var debug_overlay_start_visible: bool = false

## DEBUG ONLY. When non-empty, overrides the version string this CLIENT sends in peer_ready — set
## client-side via debug.gd's `fakever=` arg so the version-mismatch refusal path is scriptable
## two-instance without building a second binary. A send-path override ONLY: never a comparison
## basis, and the menu still shows the real version. Read client-side at peer_ready send; inert on
## a host (hosts never send peer_ready). Never touched by gameplay code.
var debug_fake_version: String = ""
