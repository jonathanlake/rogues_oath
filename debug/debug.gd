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
	elif is_client:
		DisplayServer.window_set_title("CLIENT")
		# name= overrides the default BEFORE join_game(), so peer_ready ships the injected name.
		GameManager.player_name = name_text if has_name else "CLIENT"
		print("[Debug] autostart: joining 127.0.0.1:%d" % NetworkManager.DEFAULT_PORT)
		# This bypasses the menu's join flow (its _connecting flag stays false), so the menu
		# swallows connection_failed by design. A test harness must fail LOUDLY, not hang on
		# the menu forever — so handle failure here: report and quit nonzero.
		NetworkManager.connection_failed.connect(func():
			push_error("[Debug] autostart join FAILED — is a host running?")
			get_tree().quit(1))
		NetworkManager.connection_succeeded.connect(_on_autostart_connected, CONNECT_ONE_SHOT)
		NetworkManager.join_game("127.0.0.1")


# Success-path scene transition, owned by INITIATOR: this handler is only ever connected
# for joins debug.gd itself started, so it transitions unconditionally. The menu's own
# success handler guards on its _connecting flag (false for autostart joins), so exactly
# one of the two paths acts — never both. The client's say is scheduled HERE (not on a blind
# timer) so it fires only once the connection is real and the host is guaranteed present.
func _on_autostart_connected() -> void:
	get_tree().change_scene_to_packed(load(GameManager.MAIN_SCENE))
	if _has_say:
		_schedule_say(_say_text, client_say_settle_sec)


## Fire one chat intent through the real pipe after a settle delay. Works identically on host
## and client — submit_intent is the single public entry point; there is deliberately no
## host/client branch and no bypass. Debug is an autoload, so this survives the scene change.
func _schedule_say(text: String, delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	NetEvents.submit_intent("chat", {"text": text})


func _schedule_screenshot(path: String) -> void:
	if path.is_empty():
		return
	await get_tree().create_timer(screenshot_delay_sec).timeout
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	print("[Debug] viewport screenshot -> %s (%s)" % [path, error_string(err)])
	get_tree().quit()
