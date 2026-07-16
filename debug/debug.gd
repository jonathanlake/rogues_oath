extends Node

## Autostart helper — safe to leave enabled because it is inert without user args. It reads
## OS.get_cmdline_user_args() (everything after `--` on the command line) and, only if a role
## keyword is present, skips the menu and drives the same host/join path the menu uses. This is
## the two-instance test harness: launch one instance with `-- host` and one with `-- join`.



## Verification aid: `-- host screenshot=C:/path/out.png` makes this instance save its OWN
## viewport to a PNG shortly after startup and then quit. Self-contained — no desktop
## capture, no window focus games, and the clean quit() avoids force-kill teardown noise.
@export var screenshot_delay_sec: float = 6.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	# Role keyword: "host"/"server" start the host, "join"/"client" connect to it. Aliases
	# exist so the intuitive word (matching the HOST/CLIENT window titles) also works.
	var is_host := "host" in args or "server" in args
	var is_client := "join" in args or "client" in args

	for arg in args:
		if arg.begins_with("screenshot="):
			_schedule_screenshot(arg.trim_prefix("screenshot="))

	if not (is_host or is_client):
		return

	# Autoloads initialize before the main scene loads. Wait one frame so the main menu
	# (which wires connection_succeeded -> change scene) is fully ready before we act.
	await get_tree().process_frame

	if is_host:
		DisplayServer.window_set_title("HOST")
		GameManager.player_name = "HOST"
		print("[Debug] autostart: hosting on port %d" % NetworkManager.DEFAULT_PORT)
		if NetworkManager.host_game() != OK:
			push_error("[Debug] autostart host failed")
			return
		get_tree().change_scene_to_packed(load(GameManager.MAIN_SCENE))
	elif is_client:
		DisplayServer.window_set_title("CLIENT")
		GameManager.player_name = "CLIENT"
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
# one of the two paths acts — never both.
func _on_autostart_connected() -> void:
	get_tree().change_scene_to_packed(load(GameManager.MAIN_SCENE))


func _schedule_screenshot(path: String) -> void:
	if path.is_empty():
		return
	await get_tree().create_timer(screenshot_delay_sec).timeout
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(path)
	print("[Debug] viewport screenshot -> %s (%s)" % [path, error_string(err)])
	get_tree().quit()
