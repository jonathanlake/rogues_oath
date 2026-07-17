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

# Compass token -> 8-way step. n/s use screen-space y (down is +y), matching Vector2i grid coords.
const _MOVE_DIRS := {
	"n": Vector2i(0, -1), "s": Vector2i(0, 1), "e": Vector2i(1, 0), "w": Vector2i(-1, 0),
	"ne": Vector2i(1, -1), "nw": Vector2i(-1, -1), "se": Vector2i(1, 1), "sw": Vector2i(-1, 1),
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
	# host-only glide-duration override (seconds); inert on the client and without the arg.
	# Stretches every glide's base step time so conga/timing tests are scriptable + observable.
	var glide_override := 0.0
	for arg in args:
		if arg.begins_with("screenshot="):
			_schedule_screenshot(arg.trim_prefix("screenshot="))
		elif arg.begins_with("say="):
			_say_text = arg.trim_prefix("say=")
			_has_say = true
		elif arg.begins_with("name="):
			name_text = arg.trim_prefix("name=")
			has_name = true
		elif arg.begins_with("hostdelay="):
			host_delay_sec = arg.trim_prefix("hostdelay=").to_float()
		elif arg.begins_with("maxplayers="):
			max_players = arg.trim_prefix("maxplayers=").to_int()
		elif arg.begins_with("join="):
			join_address = arg.trim_prefix("join=")
		elif arg.begins_with("move="):
			_parse_move_list(arg.trim_prefix("move="))
		elif arg.begins_with("movedelay="):
			_move_delay_sec = arg.trim_prefix("movedelay=").to_float()
		elif arg.begins_with("movewait="):
			_move_wait_sec = arg.trim_prefix("movewait=").to_float()
		elif arg.begins_with("glidesec="):
			glide_override = arg.trim_prefix("glidesec=").to_float()

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
		# glidesec= is host-only: the referee reads the override live when it stamps each glide,
		# so setting it any time before the moves fire is enough. Inert on the client.
		if glide_override > 0.0:
			GameManager.debug_glide_override_sec = glide_override
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
		# Host waits a fixed span for a client to join before saying anything.
		if _has_say:
			_schedule_say(_say_text, say_delay_sec)
		# Scripted moves share the say anchor (after the scene change). movewait= overrides the
		# delay; unset, it falls back to say_delay_sec so a client has time to join first.
		if _has_move:
			_schedule_moves(_move_wait_sec if _move_wait_sec >= 0.0 else say_delay_sec)
	elif is_client:
		DisplayServer.window_set_title("CLIENT")
		# name= overrides the default BEFORE join_game(), so peer_ready ships the injected name.
		GameManager.player_name = name_text if has_name else "CLIENT"
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
	if _has_say:
		_schedule_say(_say_text, client_say_settle_sec)
	# Scripted moves anchor to the connection event (like the client's say), not a blind timer, so
	# the host is guaranteed present. movewait= overrides; unset, it uses the say settle default.
	if _has_move:
		_schedule_moves(_move_wait_sec if _move_wait_sec >= 0.0 else client_say_settle_sec)


## Fire one chat intent through the real pipe after a settle delay. Works identically on host
## and client — submit_intent is the single public entry point; there is deliberately no
## host/client branch and no bypass. Debug is an autoload, so this survives the scene change.
func _schedule_say(text: String, delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	NetEvents.submit_intent("chat", {"text": text})


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


func _schedule_screenshot(path: String) -> void:
	if path.is_empty():
		return
	await get_tree().create_timer(screenshot_delay_sec).timeout
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	print("[Debug] viewport screenshot -> %s (%s)" % [path, error_string(err)])
	get_tree().quit()
