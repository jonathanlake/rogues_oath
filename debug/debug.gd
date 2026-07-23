extends Node

## Autostart helper — safe to leave enabled because it is inert without user args. It reads
## OS.get_cmdline_user_args() (everything after `--` on the command line) and, only if a role
## keyword is present, skips the menu and drives the same host/join path the menu uses. This is
## the two-instance test harness: launch one instance with `-- host` and one with `-- join`.



## Verification aid: `-- host screenshot=C:/path/out.png` makes this instance save its OWN
## viewport to a PNG shortly after startup and then quit. Self-contained — no desktop
## capture, no window focus games, and the clean quit() avoids force-kill teardown noise.
@export var screenshot_delay_sec: float = 6.0

## Delay before the HOST's autostart `say=` fires. Long enough that a client launched a few
## seconds later has connected and spawned first — there is no late-join event replay
## (DESIGN §2.7), so an event broadcast before a peer connects is gone for that peer. The
## CLIENT's say is NOT on a blind timer: it is anchored to its own connection event (see
## _on_autostart_connected) so the host is guaranteed present when it fires. Exercises the real
## pipe (submit_intent), never a bypass.
@export var say_delay_sec: float = 5.0

## Settle delay after the CLIENT connects before its `say=` fires — just long enough for the
## scene change + host-side spawn to land. Short because the connection event already
## guarantees the host is up (unlike the host's fixed wait for an unknown client).
@export var client_say_settle_sec: float = 1.0

# Parsed autostart chat payload, stashed so the client can fire it from its connection handler
# (CONNECT_ONE_SHOT, no args) instead of a blind timer. has_say (not is_empty) tracks presence,
# since "say=   " (whitespace) is a valid reject-path test value.
var _say_text: String = ""
var _has_say: bool = false

# Slash-command harness (cmd=/cmdwait=, v0.10.0): feed ONE dev-command string through the REAL
# game_log._on_input_submitted() entry point — the SAME method a typed "/w longsword 3" hits — so the
# scripted run exercises the genuine greenfield interception/parse/clear path (the "/" detection, the
# submit_intent("dev_command", ...), the focus release), NOT a bypass around it. Works from EITHER role;
# the value may contain spaces (a quoted arg is ONE token), so it's parsed by prefix like say=. Fires at
# the role anchor by default (mirrors say= timing); cmdwait= overrides. The leading "/" must be included
# (that's what game_log detects), e.g. `cmd=/w longsword 3` or `cmd=/god` or `cmd=/class knight`.
var _cmd_text: String = ""
var _has_cmd: bool = false
var _cmd_wait_sec: float = -1.0

# Scripted-move harness (move=/movedelay=/movewait=), stashed like say so it survives the scene
# change and can be anchored to the same events (host: after scene change; client: after connect).
# The moves go through the REAL pipe (submit_intent), DELIBERATELY bypassing MoveInput — that
# tests the SERVER's enforcement (already-moving, blocked, corner, occupied), not the client gate.
var _move_dirs: Array[Vector2i] = []
var _has_move: bool = false
# Interval between scripted moves (seconds). Tight values (e.g. 0.05) exercise the "already
# moving" backstop; wide ones (≥ glide duration) land clean back-to-back steps.
var _move_delay_sec: float = 0.8
# Delay before the FIRST scripted move (seconds), after its role's anchor. -1 = unset: fall back
# to the say anchor default for that role (host say_delay_sec, client client_say_settle_sec).
var _move_wait_sec: float = -1.0

# Held-key harness (hold=/holdsec=): synthesizes a HELD move key via Input.action_press/release,
# driving the GENUINE MoveInput sampler — key-held cadence, host/client symmetric — unlike move=,
# which bypasses MoveInput by design and so can't catch input-layer bugs (e.g. a latch that only
# wedges when the host's verdict returns synchronously). Anchored like the scripted moves
# (movewait= timing, per role). Don't combine with move= in one instance: the interleaved cadence
# counts become meaningless (dev tool — no guard, just don't).
var _hold_dir: Vector2i = Vector2i.ZERO
var _has_hold: bool = false
# How long the synthetic key(s) stay held (seconds) before release.
var _hold_sec: float = 3.0
# holdwait=: hold='s OWN first-fire delay, so click-then-key runs can stagger the two sources
# (e.g. click=3,7 hold=e holdwait=2 — the walk starts, then keys take over and cancel it).
# -1 = unset: hold falls back to the shared movewait= timing like every other knob.
var _hold_wait_sec: float = -1.0

# Click harness (click=/clickdelay=): synthesizes left-mouse press+release pairs at tile centers
# via Input.parse_input_event(), driving MoveInput's real _unhandled_input click capture — the
# whole click-to-move path (reachability check, target store, per-step recompute) runs exactly
# as under a physical mouse. Tile coords, converted at fire time through the live canvas
# transform. Anchored at the movewait= timing per role, like the other input knobs.
var _click_tiles: Array[Vector2i] = []
var _has_click: bool = false
# Interval between successive scripted clicks (seconds) — long enough by default for a short
# walk to visibly bend before the next target replaces it. SHARED by click= and shiftclick=.
var _click_delay_sec: float = 1.5

# Shift-click harness (shiftclick=, v0.17.2): an EXACT mirror of click= except the synthesized mouse
# event carries shift_pressed=true, driving MoveInput's shift+click GROUND-FIRE branch (loose at the
# clicked tile unconditionally, skipping the hostile predicate — deliberate lane denial). Same tile-list
# format, same timing anchors, same _click_delay_sec spacing; the shift flag is threaded through the shared
# scheduler/synthesis (_run_clicks / _click_event), not a copy of the click= functions.
var _shiftclick_tiles: Array[Vector2i] = []
var _has_shiftclick: bool = false

# Shoot harness (shoot=, v0.17.0): fire one shoot intent per target tile through the REAL pipe
# (submit_intent("shoot", {"target_tile": ...})) from EITHER role, testing the ranged/bow flow end-to-end —
# the host validates (range / busy / nothing-to-draw), commits the draw, and looses the traveling arrow.
# Semicolon-separated tile list like click=; deliberately bypasses mouse input (chunk 2) to exercise the
# SERVER path. Anchored at the movewait= timing per role, spaced movedelay= apart (mirrors _schedule_moves).
var _shoot_tiles: Array[Vector2i] = []
var _has_shoot: bool = false
# shootwait=: shoot='s OWN first-fire delay (mirrors holdwait=), so draw-then-move sequences can
# stagger shoot against move= (both default to the shared movewait anchor and would otherwise race —
# needed to prove the draw's busy window rejects a mid-draw move). -1 = unset: shared anchor.
var _shoot_wait_sec: float = -1.0

# Tempo harness (tempo=/tempowait=): fire ONE set_tempo intent through the REAL pipe (submit_intent)
# from EITHER role, testing the runtime tempo knob (§2.8.3) end-to-end — the host validates/clamps and
# broadcasts, both peers adopt it. Deliberately bypasses the +/- key sampling (like move= bypasses
# MoveInput), so it exercises the SERVER path: a client tempo= proves the intent crosses the wire and
# the host restamps subsequent verdicts. Fires mid-sequence by default (move anchor + 2s) so a
# concurrent move=/hold= shows durations change across the tempo boundary; tempowait= overrides.
var _tempo_beat: float = 0.0
var _has_tempo: bool = false
var _tempo_wait_sec: float = -1.0

# Tactical-tempo harness (tactical=/tacticalwait=, v0.9.2): fire ONE set_tactical_tempo intent through
# the REAL pipe from EITHER role, testing the second tempo dial (§2.8.3 groundwork) end-to-end — the
# host validates/clamps against the shared band and broadcasts, both peers adopt + display it. Exact
# mirror of tempo=; bypasses the [ / ] key sampling like tempo= bypasses +/-. Fires mid-sequence by
# default (move anchor + 2s); tacticalwait= overrides.
var _tactical_beat: float = 0.0
var _has_tactical: bool = false
var _tactical_wait_sec: float = -1.0

# Weapon-swap harness (swap=/swapwait=): fire ONE swap_weapon intent through the REAL pipe from
# EITHER role, testing the M3.7 swap control end-to-end — the host validates (busy → reject) and, on
# accept, toggles the sender's weapon within the roster and broadcasts. Bypasses the Tab key like
# tempo= bypasses +/-, so it exercises the SERVER path. Fires mid-sequence by default (move anchor +
# 2s) so a concurrent hold=/move= can show subsequent attacks carrying the new weapon; swapwait=
# overrides (e.g. fire while busy to test the reject). The starting weapon is the separate host-only
# weapon= knob (applied pre-session to the host's own player, GameManager.debug_starting_weapon).
var _swap_requested: bool = false
var _swap_wait_sec: float = -1.0

# Tap harness (tap=/tapsec=): synthesizes press/release EVENTS via Input.parse_input_event(),
# which routes through the REAL InputMap bindings — one layer deeper than hold=, which presses
# actions directly and therefore cannot test the bindings themselves (numpad dual-bound
# diagonals, d-pad buttons, analog stick thresholds). Anchored like the scripted moves
# (movewait= timing, per role); successive taps are spaced movedelay= apart.
var _tap_tokens: Array[String] = []
var _has_tap: bool = false
# How long each tap's press event(s) stay down (seconds) before the matching release. A long
# value (≥2) shows repeated stepping from one held binding.
var _tap_sec: float = 0.4

# Compass token -> 8-way step. n/s use screen-space y (down is +y), matching Vector2i grid coords.
const _MOVE_DIRS := {
	"n": Vector2i(0, -1), "s": Vector2i(0, 1), "e": Vector2i(1, 0), "w": Vector2i(-1, 0),
	"ne": Vector2i(1, -1), "nw": Vector2i(-1, -1), "se": Vector2i(1, 1), "sw": Vector2i(-1, 1),
}

# tap= token tables, one per event type. Keys are PHYSICAL keycodes (matching the project.godot
# bindings); one key event per tap — the InputMap fans a dual-bound diagonal (KP7/KP9/KP1/KP3)
# out to both actions itself, which is exactly what the harness verifies. No KP5 (no wait action).
# "enter" scripts the chat-focus flow (game_log grabs focus on Enter) — the focus-release
# regression test needs it, and it's generally useful. "f5" scripts the host round-reset key
# (dev_reset_round); "f6" the any-peer goblin summon (dev_spawn_goblin, v0.9.2) — both run
# two-instance without a hand on the keyboard. "lbracket"/"rbracket" script the tactical tempo dial
# ([ / ], v0.9.2) for binding-level tests, mirroring the +/- explore keys.
const _TAP_KEYS := {
	"kp1": KEY_KP_1, "kp2": KEY_KP_2, "kp3": KEY_KP_3, "kp4": KEY_KP_4,
	"kp6": KEY_KP_6, "kp7": KEY_KP_7, "kp8": KEY_KP_8, "kp9": KEY_KP_9,
	"enter": KEY_ENTER, "f5": KEY_F5, "f6": KEY_F6, "f11": KEY_F11,
	"lbracket": KEY_BRACKETLEFT, "rbracket": KEY_BRACKETRIGHT,
}
const _TAP_BUTTONS := {
	"dpup": JOY_BUTTON_DPAD_UP, "dpdown": JOY_BUTTON_DPAD_DOWN,
	"dpleft": JOY_BUTTON_DPAD_LEFT, "dpright": JOY_BUTTON_DPAD_RIGHT,
}
# Stick token -> list of [axis, press value]. ±0.9 clears the 0.35 deadzone decisively; release
# re-sends the same axes at 0.0 (sticks report positions, not press/release pairs).
const _TAP_STICKS := {
	"stickn": [[JOY_AXIS_LEFT_Y, -0.9]], "sticks": [[JOY_AXIS_LEFT_Y, 0.9]],
	"sticke": [[JOY_AXIS_LEFT_X, 0.9]], "stickw": [[JOY_AXIS_LEFT_X, -0.9]],
	"stickne": [[JOY_AXIS_LEFT_X, 0.9], [JOY_AXIS_LEFT_Y, -0.9]],
	"sticknw": [[JOY_AXIS_LEFT_X, -0.9], [JOY_AXIS_LEFT_Y, -0.9]],
	"stickse": [[JOY_AXIS_LEFT_X, 0.9], [JOY_AXIS_LEFT_Y, 0.9]],
	"sticksw": [[JOY_AXIS_LEFT_X, -0.9], [JOY_AXIS_LEFT_Y, 0.9]],
}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	# Role keyword: "host"/"server" start the host, "join"/"client" connect to it. Aliases
	# exist so the intuitive word (matching the HOST/CLIENT window titles) also works.
	var is_host := "host" in args or "server" in args
	var is_client := "join" in args or "client" in args

	# say=<text> / name=<text> may contain spaces — a quoted arg arrives as ONE token, so parse
	# by prefix (like screenshot=) rather than splitting on whitespace. name= overrides the
	# autostart player name so hostile-name injection (e.g. `name=[color=red]x`) is testable E2E.
	var name_text := ""
	var has_name := false
	# host-only harness knobs (inert on the client): hostdelay= reproduces the peer_ready
	# silent-drop race; maxplayers= forces the capacity-kick path with two windows.
	var host_delay_sec := 0.0
	var max_players := 0
	# client-only wire-test knob (inert on the host, inert without the arg): join=<address[:port]>
	# points a scripted client at a REMOTE host instead of localhost — the playit.gg tunnel /
	# real-internet path for M1.5 testing. Limitation: bare IPv6 literals are unsupported (the
	# first-colon split below can't tell them from ip:port), matching the menu's parser. Tunnel
	# addresses are hostnames, so this is fine in practice.
	var join_address := ""
	# client-only version-gate test knob (inert on the host, inert without the arg): fakever=<ver>
	# overrides the version string this client SENDS in peer_ready, so the host's mismatch-refusal
	# path is scriptable two-instance without building a second binary. Send-path only — never a
	# comparison basis, and the real version still shows in the menu. Structurally inert on a host
	# (hosts never send peer_ready), so it's applied in the client branch alongside join=.
	var fake_version := ""
	# host-only beat override (seconds); inert on the client and without the arg. Sets the whole-game
	# tempo (GameManager.explore_beat_sec seed) so a scripted run can test a slower/faster beat
	# end-to-end — e.g. beatsec=0.40 — without editing the .tres. Unlike glidesec=/windupsec= (which
	# override a single FINAL duration), this scales EVERYTHING authored in beats together.
	var beat_override := 0.0
	# host-only glide-duration override (seconds); inert on the client and without the arg.
	# Stretches every glide's base step time so timing tests are scriptable + observable. CONTRACT
	# CHANGE (v0.8.0): this now pins the ACTION window / glide term (the whole step cycle, rest 0 by
	# default); the visible slide broadcast follows as slide_fraction × it (pre-v0.8.0 it pinned the
	# broadcast tween directly). So glidesec=1.0 → broadcast duration_sec ≈ 0.7 at the default 0.7 fraction.
	var glide_override := 0.0
	# host-only wind-up-duration override (seconds); inert on the client and without the arg.
	# Exact mirror of glide_override: stretches every monster wind-up's telegraph window so the
	# dodge=whiff test (verification 3) is deterministic — stand until the windup event, then move.
	var windup_override := 0.0
	# host-only AoO demo knob (inert on the client, inert without the arg): hostile=1 makes every
	# entity mutually hostile so a glide out of an adjacent tile fires a real AoO `attack` event (kind "free") — the
	# two-instance demo of the attack-of-opportunity wiring before monsters exist (M3).
	var all_hostile := false
	# goblin=N: -1 = knob absent (autostart default: monster-free); 0 = none; N>0 = up to N goblins
	# from main.gd's GOBLIN_SPAWN_TILES. Menu play (not autostart) spawns all goblins by default. Note the
	# M3.5 map places those spawn tiles in the FAR rooms (B/C/E), so a scripted COMBAT run wanting immediate
	# aggro should pair goblin=N with hostile=1 (players are adjacent at spawn) or expect no aggro at range.
	var goblin_count := -1
	# host-only starting-weapon knob (M3.7): weapon=dagger|longsword resolves through the roster
	# and applies to the host own player at session start (GameManager.debug_starting_weapon).
	var starting_weapon := ""
	# goblinat=x,y (v0.17.2): host-only exact-tile goblin placement for combat range tests. Parsed to a
	# SINGLE tile (via the shared _parse_tile_list, first entry) and applied to GameManager.debug_goblin_at
	# in the host branch. has_ tracks presence so an unparsed/absent arg leaves the sentinel untouched.
	var goblin_at_tile := Vector2i.ZERO
	var has_goblin_at := false
	for arg in args:
		if arg.begins_with("screenshot="):
			_schedule_screenshot(arg.trim_prefix("screenshot="))
		elif arg.begins_with("say="):
			_say_text = arg.trim_prefix("say=")
			_has_say = true
		elif arg.begins_with("cmdwait="):
			_cmd_wait_sec = arg.trim_prefix("cmdwait=").to_float()
		elif arg.begins_with("cmd="):
			_cmd_text = arg.trim_prefix("cmd=")
			_has_cmd = true
		elif arg.begins_with("name="):
			name_text = arg.trim_prefix("name=")
			has_name = true
		elif arg.begins_with("hostdelay="):
			host_delay_sec = arg.trim_prefix("hostdelay=").to_float()
		elif arg.begins_with("maxplayers="):
			max_players = arg.trim_prefix("maxplayers=").to_int()
		elif arg.begins_with("join="):
			join_address = arg.trim_prefix("join=")
		elif arg.begins_with("fakever="):
			fake_version = arg.trim_prefix("fakever=")
		elif arg.begins_with("move="):
			_parse_move_list(arg.trim_prefix("move="))
		elif arg.begins_with("movedelay="):
			_move_delay_sec = arg.trim_prefix("movedelay=").to_float()
		elif arg.begins_with("movewait="):
			_move_wait_sec = arg.trim_prefix("movewait=").to_float()
		elif arg.begins_with("beatsec="):
			beat_override = arg.trim_prefix("beatsec=").to_float()
		elif arg.begins_with("glidesec="):
			glide_override = arg.trim_prefix("glidesec=").to_float()
		elif arg.begins_with("windupsec="):
			windup_override = arg.trim_prefix("windupsec=").to_float()
		elif arg.begins_with("hold="):
			_parse_hold(arg.trim_prefix("hold="))
		elif arg.begins_with("holdsec="):
			_hold_sec = arg.trim_prefix("holdsec=").to_float()
		elif arg.begins_with("tap="):
			_parse_tap_list(arg.trim_prefix("tap="))
		elif arg.begins_with("tapsec="):
			_tap_sec = arg.trim_prefix("tapsec=").to_float()
		elif arg.begins_with("holdwait="):
			_hold_wait_sec = arg.trim_prefix("holdwait=").to_float()
		elif arg.begins_with("shiftclick="):
			_parse_shiftclick_list(arg.trim_prefix("shiftclick="))
		elif arg.begins_with("click="):
			_parse_click_list(arg.trim_prefix("click="))
		elif arg.begins_with("clickdelay="):
			_click_delay_sec = arg.trim_prefix("clickdelay=").to_float()
		elif arg.begins_with("shootwait="):
			_shoot_wait_sec = arg.trim_prefix("shootwait=").to_float()
		elif arg.begins_with("shoot="):
			_parse_shoot_list(arg.trim_prefix("shoot="))
		elif arg.begins_with("tempo="):
			_tempo_beat = arg.trim_prefix("tempo=").to_float()
			_has_tempo = true
		elif arg.begins_with("tempowait="):
			_tempo_wait_sec = arg.trim_prefix("tempowait=").to_float()
		elif arg.begins_with("tacticalwait="):
			_tactical_wait_sec = arg.trim_prefix("tacticalwait=").to_float()
		elif arg.begins_with("tactical="):
			_tactical_beat = arg.trim_prefix("tactical=").to_float()
			_has_tactical = true
		elif arg.begins_with("overlay="):
			# Both roles: show the F3 overlay from startup (scripted screenshots). Applied via a
			# GameManager flag the overlay reads in its _ready — set here at parse time, before
			# any scene change, so it is role-symmetric with no node hunting.
			GameManager.debug_overlay_start_visible = arg.trim_prefix("overlay=").to_int() != 0
		elif arg.begins_with("rangeoverlay="):
			# Both roles: show the F7 range overlay from startup (scripted screenshots). Applied via a
			# GameManager flag the overlay reads in its _ready — exact mirror of overlay= above.
			GameManager.debug_range_overlay_start_visible = arg.trim_prefix("rangeoverlay=").to_int() != 0
		elif arg.begins_with("hostile="):
			all_hostile = arg.trim_prefix("hostile=").to_int() != 0
		elif arg.begins_with("goblinat="):
			# Single-tile read: reuse the shared list parser, take the first entry. A malformed value
			# leaves has_goblin_at false (the parser warns), so the knob stays inert on a typo.
			var goblin_at_tiles := _parse_tile_list(arg.trim_prefix("goblinat="), "goblinat=")
			if not goblin_at_tiles.is_empty():
				goblin_at_tile = goblin_at_tiles[0]
				has_goblin_at = true
		elif arg.begins_with("goblin="):
			goblin_count = arg.trim_prefix("goblin=").to_int()
		elif arg.begins_with("weapon="):
			starting_weapon = arg.trim_prefix("weapon=").strip_edges().to_lower()
		elif arg.begins_with("swapwait="):
			_swap_wait_sec = arg.trim_prefix("swapwait=").to_float()
		elif arg.begins_with("swap="):
			_swap_requested = arg.trim_prefix("swap=").to_int() != 0

	if not (is_host or is_client):
		return

	# Autoloads initialize before the main scene loads. Wait one frame so the main menu
	# (which wires connection_succeeded -> change scene) is fully ready before we act.
	await get_tree().process_frame

	if is_host:
		DisplayServer.window_set_title("HOST")
		# name= overrides the default BEFORE host_game(), so the host's own player carries the
		# injected name through the real spawn/sanitize path.
		GameManager.player_name = name_text if has_name else "HOST"
		# maxplayers= overrides the capacity gate BEFORE hosting so the host reads it when it
		# adjudicates peer_ready. maxplayers=1 fills the only slot with the host, so any client
		# is capacity-kicked — a two-window test for the kick path.
		if max_players > 0:
			GameManager.config.max_players = max_players
		# beatsec= is host-only: main.gd seeds explore_beat_sec from this override at session start
		# (before any verdict), so setting it before host_game() is enough. Inert on the client (it
		# seeds from its own config) — the host stamps every duration, so both windows' visible cadence
		# still matches. Independent of glidesec=/windupsec= (this scales all beats; those pin one value).
		if beat_override > 0.0:
			GameManager.debug_beat_override_sec = beat_override
		# glidesec= is host-only: the referee reads the override live when it stamps each glide,
		# so setting it any time before the moves fire is enough. Inert on the client. v0.8.0: pins the
		# action window / glide term; the broadcast slide follows as slide_fraction × it (not the tween itself).
		if glide_override > 0.0:
			GameManager.debug_glide_override_sec = glide_override
		# windupsec= is host-only: the combat referee reads the override live when it stamps each
		# wind-up, so setting it before the goblin engages is enough. Inert on the client — and an
		# independent knob, NOT nested under glidesec= (each stretches its own timing alone).
		if windup_override > 0.0:
			GameManager.debug_windup_override_sec = windup_override
		# hostile= is host-only: set the AoO demo flag before host_game() so the referee reads it
		# the moment it adjudicates the first glide. Inert on the client and without the arg.
		if all_hostile:
			GameManager.all_hostile = true
		# weapon= is host-only (M3.7): stash the starting weapon so main.gd applies it to the host
		# own player at session start (resolved through the roster). Set before host_game(); inert
		# on the client and without the arg. The swap=/swapwait= knobs fire the swap intent mid-run.
		if not starting_weapon.is_empty():
			GameManager.debug_starting_weapon = starting_weapon
		# goblinat= is host-only: stash the exact goblin spawn tile so main.gd places ONE goblin there at
		# session start (through the shared guarded spawn step), independent of goblin=. Set before
		# host_game(); inert on the client and without the arg (the sentinel stays put).
		if has_goblin_at:
			GameManager.debug_goblin_at = goblin_at_tile
		# goblin= is host-only: the autostart run is monster-free unless opted in, so movement
		# harness runs (move=/hold=/tap=/click=) keep their clean occupancy. goblin=N caps the count
		# (0 = none, N>0 = up to N); knob absent (-1) stays monster-free. Set before host_game() so Main
		# reads both when it seeds the world. Inert on the client.
		if goblin_count >= 0:
			GameManager.spawn_monsters = goblin_count > 0
			GameManager.monster_spawn_cap = goblin_count
		else:
			GameManager.spawn_monsters = false
		print("[Debug] autostart: hosting on port %d" % NetworkManager.DEFAULT_PORT)
		if NetworkManager.host_game() != OK:
			push_error("[Debug] autostart host failed")
			return
		# hostdelay= holds the host on the menu scene after the transport is up but before
		# /root/Main exists, so an early client's peer_ready targets a node that isn't there yet
		# — reproducing the silent-drop race on demand. Only the say anchor is pushed back by the
		# same span (scheduled after this await); the screenshot timer starts at _ready.
		if host_delay_sec > 0.0:
			await get_tree().create_timer(host_delay_sec).timeout
		get_tree().change_scene_to_packed(load(GameManager.MAIN_SCENE))
		# Every input knob anchors to the host's fixed wait for a client to join (say_delay_sec) so a
		# client has time to connect + spawn before the first scripted action fires.
		_schedule_input_knobs(say_delay_sec)
	elif is_client:
		DisplayServer.window_set_title("CLIENT")
		# name= overrides the default BEFORE join_game(), so peer_ready ships the injected name.
		GameManager.player_name = name_text if has_name else "CLIENT"
		# fakever= overrides the version this client SENDS in peer_ready (see the knob comment above).
		# Set before join_game() so it's stashed by the time the client's peer_ready send reads it.
		# Inert on a host, so this apply lives only in the client branch. Empty = send the real version.
		if not fake_version.is_empty():
			GameManager.debug_fake_version = fake_version
		# join= aims this client at a remote host; absent, it stays on localhost exactly as before.
		# Split on the FIRST colon only (same shape as the menu's _on_join_pressed) into ip + optional
		# port; an out-of-range or non-integer port falls back to DEFAULT_PORT rather than reaching
		# ENet as a confusing failure.
		var ip := "127.0.0.1"
		var port := NetworkManager.DEFAULT_PORT
		if not join_address.is_empty():
			ip = join_address
			if ":" in join_address:
				var parts := join_address.split(":", false, 1)
				ip = parts[0]
				if parts.size() > 1 and parts[1].is_valid_int():
					var parsed := parts[1].to_int()
					if parsed >= 1 and parsed <= 65535:
						port = parsed
		print("[Debug] autostart: joining %s:%d" % [ip, port])
		# This bypasses the menu's join flow (its _connecting flag stays false), so the menu
		# swallows connection_failed by design. A test harness must fail LOUDLY, not hang on
		# the menu forever — so handle failure here: report and quit nonzero.
		NetworkManager.connection_failed.connect(func():
			push_error("[Debug] autostart join FAILED — is a host running?")
			get_tree().quit(1))
		NetworkManager.connection_succeeded.connect(_on_autostart_connected, CONNECT_ONE_SHOT)
		NetworkManager.join_game(ip, port)


# Success-path scene transition, owned by INITIATOR: this handler is only ever connected
# for joins debug.gd itself started, so it transitions unconditionally. The menu's own
# success handler guards on its _connecting flag (false for autostart joins), so exactly
# one of the two paths acts — never both. The client's say is scheduled HERE (not on a blind
# timer) so it fires only once the connection is real and the host is guaranteed present.
func _on_autostart_connected() -> void:
	get_tree().change_scene_to_packed(load(GameManager.MAIN_SCENE))
	# Every input knob anchors to the connection event (like the client's say), not a blind timer, so
	# the host is guaranteed present — client_say_settle_sec is the settle-after-connect default.
	_schedule_input_knobs(client_say_settle_sec)


## Schedule every parsed input-harness knob (say/move/hold/tap/click) off ONE anchor. Host and
## client differ only in that anchor: the host passes its fixed join wait (say_delay_sec), the
## client passes its post-connect settle (client_say_settle_sec). say fires at the anchor directly;
## move/tap/click honour movewait= (falling back to the anchor); hold honours its own holdwait=
## (falling back to movewait=, then the anchor) so click-then-key runs can stagger the two sources.
func _schedule_input_knobs(default_anchor_sec: float) -> void:
	if _has_say:
		_schedule_say(_say_text, default_anchor_sec)
	# cmd= mirrors say= timing (fires at the role anchor) so a dev command lands after both peers have
	# spawned; cmdwait= overrides for staggering (e.g. /w then a later bump to feel the new damage).
	if _has_cmd:
		_schedule_cmd(_cmd_text, _cmd_wait_sec if _cmd_wait_sec >= 0.0 else default_anchor_sec)
	# movewait= overrides the anchor for the move/tap/click knobs; unset, they share the anchor.
	var move_anchor := _move_wait_sec if _move_wait_sec >= 0.0 else default_anchor_sec
	if _has_move:
		_schedule_moves(move_anchor)
	if _has_hold:
		_schedule_hold(_hold_wait_sec if _hold_wait_sec >= 0.0 else move_anchor)
	if _has_tap:
		_schedule_taps(move_anchor)
	if _has_click:
		_schedule_clicks(move_anchor)
	# shiftclick= shares click='s anchor + spacing; it only differs in the shift flag threaded to the
	# synthesized event (drives MoveInput's ground-fire branch). Independent knob, so both can run together.
	if _has_shiftclick:
		_schedule_shiftclicks(move_anchor)
	# shoot= fires at the move anchor, one target every movedelay= (mirrors move=), so a scripted run can
	# loose a sequence of arrows through the real pipe after both peers have spawned.
	if _has_shoot:
		_schedule_shoots(_shoot_wait_sec if _shoot_wait_sec >= 0.0 else move_anchor)
	# tempo= fires mid-sequence by default (move anchor + 2s) so a concurrent move=/hold= shows glide
	# durations change across the tempo boundary; tempowait= pins it (e.g. early, for a late-join test).
	if _has_tempo:
		_schedule_tempo(_tempo_wait_sec if _tempo_wait_sec >= 0.0 else move_anchor + 2.0)
	# tactical= fires mid-sequence by default (move anchor + 2s), like tempo=; tacticalwait= pins it.
	if _has_tactical:
		_schedule_tactical(_tactical_wait_sec if _tactical_wait_sec >= 0.0 else move_anchor + 2.0)
	# swap= fires mid-sequence by default (move anchor + 2s) so a concurrent hold=/move= shows the
	# subsequent attacks carrying the new weapon; swapwait= pins it (e.g. mid-busy for the reject test).
	if _swap_requested:
		_schedule_swap(_swap_wait_sec if _swap_wait_sec >= 0.0 else move_anchor + 2.0)


## Fire one chat intent through the real pipe after a settle delay. Works identically on host
## and client — submit_intent is the single public entry point; there is deliberately no
## host/client branch and no bypass. Debug is an autoload, so this survives the scene change.
func _schedule_say(text: String, delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	NetEvents.submit_intent("chat", {"text": text})


## Fire one dev command through the REAL game_log entry point after a delay (v0.10.0). Resolves the
## GameLog node (added under Main in main.gd's _ready — /root/Main/GameLog), then calls its
## _on_input_submitted() with the raw string — the SAME method a typed submission hits — so the "/"
## interception, the parse-to-{cmd,args}, the submit_intent("dev_command", ...), and the focus release
## all run under test, not a bypass. Works identically on host and client (submit_intent is the one
## public entry point; game_log's "/help" branch stays local). A missing node warns rather than crashes.
func _schedule_cmd(text: String, delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	var game_log := get_tree().root.get_node_or_null("Main/GameLog")
	if game_log == null:
		push_warning("[Debug] cmd=: GameLog node not found (Main/GameLog) — command dropped")
		return
	print("[Debug] cmd: submitting '%s' through game_log" % text)
	game_log._on_input_submitted(text)


## Fire the scripted move list through the REAL pipe (submit_intent) after an initial delay, one
## step every _move_delay_sec. It deliberately bypasses MoveInput so it exercises the SERVER's
## enforcement — the referee stamps duration and adjudicates from ITS origin, so a tight delay
## surfaces "already moving" and a wall/corner/occupied target surfaces the matching reject.
func _schedule_moves(delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	for i in _move_dirs.size():
		if i > 0:
			await get_tree().create_timer(_move_delay_sec).timeout
		NetEvents.submit_intent("glide_to", { "dir": _move_dirs[i] })


## Fire one swap_weapon intent through the real pipe after a delay (M3.7). Works identically on host
## and client — submit_intent is the single public entry point. The host validates (busy → reject)
## and, on accept, toggles the sender's weapon within the roster and broadcasts.
func _schedule_swap(delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	print("[Debug] swap: submitting swap_weapon")
	NetEvents.submit_intent("swap_weapon", {})


## Fire one set_tempo intent through the real pipe after a delay. Works identically on host and
## client — submit_intent is the single public entry point, no role branch. The host validates,
## clamps/snaps, applies, and broadcasts; both peers adopt the new beat (§2.8.3).
func _schedule_tempo(delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	print("[Debug] tempo: submitting set_tempo beat_sec=%.2f" % _tempo_beat)
	NetEvents.submit_intent("set_tempo", { "beat_sec": _tempo_beat })


## Fire one set_tactical_tempo intent through the real pipe after a delay (v0.9.2). Exact mirror of
## _schedule_tempo for the second dial — submit_intent is the single public entry point, no role branch.
## The host validates, clamps/snaps against the shared band, applies, and broadcasts; both peers adopt.
func _schedule_tactical(delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	print("[Debug] tactical: submitting set_tactical_tempo beat_sec=%.2f" % _tactical_beat)
	NetEvents.submit_intent("set_tactical_tempo", { "beat_sec": _tactical_beat })


## Parse a comma-separated compass list (e.g. "e,ne,sw") into _move_dirs. Unknown tokens are
## skipped with a warning rather than aborting the run — a typo shouldn't silently drop the test.
func _parse_move_list(spec: String) -> void:
	for token in spec.split(",", false):
		var key := token.strip_edges().to_lower()
		if _MOVE_DIRS.has(key):
			_move_dirs.append(_MOVE_DIRS[key])
			_has_move = true
		elif not key.is_empty():
			push_warning("[Debug] move=: unknown direction '%s' (skipped)" % key)


## Parse hold='s single compass token into _hold_dir. Unknown → warn and stay inert.
func _parse_hold(spec: String) -> void:
	var key := spec.strip_edges().to_lower()
	if _MOVE_DIRS.has(key):
		_hold_dir = _MOVE_DIRS[key]
		_has_hold = true
	elif not key.is_empty():
		push_warning("[Debug] hold=: unknown direction '%s' (ignored)" % key)


## Press the mapped move action(s) — two for a diagonal — after the initial delay, hold them for
## _hold_sec, then release. Input.action_press makes MoveInput's is_action_pressed sampling see a
## genuinely held key, so the whole real input path (chat gate, latch, glide block, cooldown) runs
## exactly as it does under a physical key — this is the harness that catches input-layer bugs
## move= (which submits intents directly) structurally cannot.
func _schedule_hold(delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	var actions: Array[String] = []
	if _hold_dir.x > 0:
		actions.append("move_right")
	elif _hold_dir.x < 0:
		actions.append("move_left")
	if _hold_dir.y > 0:
		actions.append("move_down")
	elif _hold_dir.y < 0:
		actions.append("move_up")
	print("[Debug] hold: pressing %s for %.1fs" % [str(actions), _hold_sec])
	for action in actions:
		Input.action_press(action)
	await get_tree().create_timer(_hold_sec).timeout
	for action in actions:
		Input.action_release(action)
	print("[Debug] hold: released %s" % str(actions))


## Parse tap='s comma-separated token list into _tap_tokens. Unknown tokens are skipped with a
## warning rather than aborting the run — a typo shouldn't silently drop the test.
func _parse_tap_list(spec: String) -> void:
	for token in spec.split(",", false):
		var key := token.strip_edges().to_lower()
		if _TAP_KEYS.has(key) or _TAP_BUTTONS.has(key) or _TAP_STICKS.has(key):
			_tap_tokens.append(key)
			_has_tap = true
		elif not key.is_empty():
			push_warning("[Debug] tap=: unknown token '%s' (skipped)" % key)


## Fire the tap list: for each token, inject its press event(s) via Input.parse_input_event(),
## hold for _tap_sec, then inject the matching release event(s); successive taps are spaced
## _move_delay_sec apart. Unlike hold= (which presses ACTIONS directly), these synthetic events
## traverse the real InputMap, so the bindings themselves — numpad dual-bound diagonals, d-pad
## buttons, stick axes vs the action deadzone — are what's under test.
func _schedule_taps(delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	for i in _tap_tokens.size():
		if i > 0:
			await get_tree().create_timer(_move_delay_sec).timeout
		var token := _tap_tokens[i]
		print("[Debug] tap: pressing %s" % token)
		for event in _tap_events(token, true):
			Input.parse_input_event(event)
		await get_tree().create_timer(_tap_sec).timeout
		for event in _tap_events(token, false):
			Input.parse_input_event(event)
		print("[Debug] tap: released %s" % token)


## Build the InputEvent(s) for one tap token. Keys are ONE event even for a dual-bound diagonal
## (the InputMap fans it out to both actions); sticks are one event per involved axis, with
## release re-sending the axis at 0.0 (a stick reports positions, not press/release pairs).
func _tap_events(token: String, pressed: bool) -> Array[InputEvent]:
	var events: Array[InputEvent] = []
	if _TAP_KEYS.has(token):
		var key := InputEventKey.new()
		# Set BOTH keycodes, like a real OS event carries: InputMap bindings here match on
		# physical_keycode, but keycode-checking consumers exist too (game_log's Enter grab reads
		# event.keycode) — a physical-only event would silently fail those.
		key.physical_keycode = _TAP_KEYS[token]
		key.keycode = _TAP_KEYS[token]
		key.pressed = pressed
		events.append(key)
	elif _TAP_BUTTONS.has(token):
		var button := InputEventJoypadButton.new()
		button.button_index = _TAP_BUTTONS[token]
		button.pressed = pressed
		events.append(button)
	elif _TAP_STICKS.has(token):
		for axis_pair in _TAP_STICKS[token]:
			var motion := InputEventJoypadMotion.new()
			motion.axis = axis_pair[0]
			motion.axis_value = axis_pair[1] if pressed else 0.0
			events.append(motion)
	return events


## Parse click='s semicolon-separated tile list ("x,y;x,y;...") into _click_tiles. Malformed
## entries are skipped with a warning rather than aborting the run. Tiles are NOT validated
## against the grid here — an unreachable tile is a legitimate test value ("Can't reach that.").
func _parse_click_list(spec: String) -> void:
	_click_tiles = _parse_tile_list(spec, "click=")
	_has_click = not _click_tiles.is_empty()


## Parse shiftclick='s tile list (v0.17.2) — the SAME semicolon-separated "x,y;..." format as click=,
## into _shiftclick_tiles. Shares the one parser (_parse_tile_list); the shift flag is applied at
## SYNTHESIS time (_run_clicks / _click_event), so parsing is byte-identical to click=.
func _parse_shiftclick_list(spec: String) -> void:
	_shiftclick_tiles = _parse_tile_list(spec, "shiftclick=")
	_has_shiftclick = not _shiftclick_tiles.is_empty()


## Shared tile-list parser for click= / shiftclick= (v0.17.2): semicolon-separated "x,y" entries →
## Array[Vector2i]. A malformed entry is skipped with a warning (named by `knob`) rather than aborting the
## run — a typo shouldn't silently drop the test. Tiles are NOT grid-validated (an unreachable/ground tile
## is a legitimate test value). One parser so the two knobs can never diverge on format.
func _parse_tile_list(spec: String, knob: String) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for entry in spec.split(";", false):
		var parts := entry.strip_edges().split(",", false)
		if parts.size() == 2 and parts[0].strip_edges().is_valid_int() and parts[1].strip_edges().is_valid_int():
			tiles.append(Vector2i(parts[0].strip_edges().to_int(), parts[1].strip_edges().to_int()))
		elif not entry.strip_edges().is_empty():
			push_warning("[Debug] %s malformed entry '%s' (skipped)" % [knob, entry])
	return tiles


## Fire the click list (plain click-to-move): a thin wrapper over the shared _run_clicks with shift=false.
## The events traverse the real input pipeline into MoveInput._unhandled_input — the genuine click-to-move
## path, not a shortcut around it. The window-coordinate position math lives in _run_clicks (see there).
func _schedule_clicks(delay_sec: float) -> void:
	_run_clicks(_click_tiles, delay_sec, false)


## shiftclick= (v0.17.2): the same scheduled click stream, synthesized with shift_pressed=true so it drives
## MoveInput's shift+click ground-fire branch. Thin wrapper over the shared _run_clicks — no copy of the loop.
func _schedule_shiftclicks(delay_sec: float) -> void:
	_run_clicks(_shiftclick_tiles, delay_sec, true)


## Shared click runner for click= / shiftclick= (v0.17.2): fire the tile list as press+release pairs at each
## tile's center, spaced _click_delay_sec apart, with `shift` threaded into the synthesized event. `shift`
## false = the plain click-to-move path; true = the ground-fire path. Position math (world → viewport →
## window through the live screen + canvas transforms, read at fire time) is unchanged from the original
## _schedule_clicks — see that history below. A coroutine (awaits inside); callers fire-and-forget it.
func _run_clicks(tiles: Array[Vector2i], delay_sec: float, shift: bool) -> void:
	var label := "shiftclick" if shift else "click"
	await get_tree().create_timer(delay_sec).timeout
	for i in tiles.size():
		if i > 0:
			await get_tree().create_timer(_click_delay_sec).timeout
		var tile := tiles[i]
		# Position must be in WINDOW coordinates: parse_input_event treats the event as if it came from the
		# OS, so the engine applies the canvas_items stretch transform window → viewport INBOUND before
		# delivery, and MoveInput then inverts get_canvas_transform() viewport → world. So the synthesis must
		# compose the FULL round-trip its inverse expects: world → viewport via the canvas transform (the M3.5
		# follow Camera2D makes this NON-identity), then viewport → window via get_screen_transform(). Both
		# read at fire time, so this stays correct under a maximized/letterboxed window AND a moving camera.
		var window_pos: Vector2 = get_viewport().get_screen_transform() * get_viewport().get_canvas_transform() * WorldGrid.tile_to_world(tile)
		print("[Debug] %s: pressing at tile %s" % [label, tile])
		Input.parse_input_event(_click_event(window_pos, true, shift))
		await get_tree().create_timer(0.1).timeout
		Input.parse_input_event(_click_event(window_pos, false, shift))
		print("[Debug] %s: released at tile %s" % [label, tile])


## Parse a semicolon-separated tile list (e.g. "10,4;3,7") into _shoot_tiles — exact mirror of
## _parse_click_list. A malformed entry is skipped with a warning rather than aborting the run.
func _parse_shoot_list(spec: String) -> void:
	for entry in spec.split(";", false):
		var parts := entry.strip_edges().split(",", false)
		if parts.size() == 2 and parts[0].strip_edges().is_valid_int() and parts[1].strip_edges().is_valid_int():
			_shoot_tiles.append(Vector2i(parts[0].strip_edges().to_int(), parts[1].strip_edges().to_int()))
			_has_shoot = true
		elif not entry.strip_edges().is_empty():
			push_warning("[Debug] shoot=: malformed entry '%s' (skipped)" % entry)


## Fire the shoot list through the REAL pipe (submit_intent("shoot", ...)) after the initial delay, one
## target every _move_delay_sec (mirror of _schedule_moves). Bypasses mouse input (chunk 2) so it exercises
## the SERVER's ranged adjudication — range / busy / nothing-to-draw rejects, the draw commit, and the loose.
func _schedule_shoots(delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	for i in _shoot_tiles.size():
		if i > 0:
			await get_tree().create_timer(_move_delay_sec).timeout
		print("[Debug] shoot: submitting shoot target_tile=%s" % _shoot_tiles[i])
		NetEvents.submit_intent("shoot", { "target_tile": _shoot_tiles[i] })


## Build one synthetic left-mouse event at a viewport position. `shift` sets shift_pressed (v0.17.2):
## false for a plain click= event, true for a shiftclick= event that drives MoveInput's ground-fire branch
## (the InputEventMouseButton.shift_pressed the shift+click gate reads). Defaults false for any other caller.
func _click_event(screen_pos: Vector2, pressed: bool, shift: bool = false) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = screen_pos
	event.global_position = screen_pos
	event.shift_pressed = shift
	return event


func _schedule_screenshot(path: String) -> void:
	if path.is_empty():
		return
	await get_tree().create_timer(screenshot_delay_sec).timeout
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	print("[Debug] viewport screenshot -> %s (%s)" % [path, error_string(err)])
	get_tree().quit()
