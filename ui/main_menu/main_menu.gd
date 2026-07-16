extends Control

## Host/join menu. Simplified from Magick With Friends' main_menu.gd:
##  - Host: set the player name, start the server, and on OK change to main.tscn. A
##    synchronous host failure (port already bound) stays on the menu with an error.
##  - Join: start the client and wait. connection_succeeded changes scene;
##    connection_failed (or a bounded timeout) shows an error and stays on the menu.

# Brand-new scene: referenced by res:// path until the editor assigns it a uid.
var main_scene: PackedScene = preload("res://main.tscn")

@onready var name_input: LineEdit = $VBoxContainer/NameLineEdit
@onready var ip_input: LineEdit = $VBoxContainer/IpLineEdit
@onready var host_button: Button = $VBoxContainer/HBoxContainer/HostButton
@onready var join_button: Button = $VBoxContainer/HBoxContainer/JoinButton
@onready var error_label: Label = $VBoxContainer/ErrorLabel

const JOIN_TIMEOUT_SEC := 5.0

var _connecting: bool = false
var _attempt_token: int = 0  # invalidates stale timeout timers from earlier attempts


func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)


func _on_host_pressed() -> void:
	GameManager.player_name = _resolved_name()
	var port := _parse_port(ip_input.text.strip_edges())
	# host_game fails synchronously when the port is already bound (e.g. a second host on this
	# machine). Stay on the menu and say so — changing scene anyway would boot a phantom offline
	# "host" session nobody could join, with no error shown.
	if NetworkManager.host_game(port) != OK:
		error_label.text = "Could not host on port %d (already in use?)." % port
		return
	get_tree().change_scene_to_packed(main_scene)


func _on_join_pressed() -> void:
	GameManager.player_name = _resolved_name()
	var address := ip_input.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"

	var ip := address
	if ":" in address:
		ip = address.split(":", false, 1)[0]
	var port := _parse_port(address)

	host_button.disabled = true
	join_button.disabled = true
	error_label.text = "Connecting..."
	_connecting = true
	_attempt_token += 1
	var token := _attempt_token
	NetworkManager.join_game(ip, port)
	# Bounded fallback: ENet's connection_failed can be slow/unreliable for a dead address.
	get_tree().create_timer(JOIN_TIMEOUT_SEC).timeout.connect(_on_join_timeout.bind(token))


func _on_join_timeout(token: int) -> void:
	# Ignore stale timers (a newer attempt) or an attempt already resolved.
	if token != _attempt_token or not _connecting:
		return
	NetworkManager.disconnect_game()  # cancel the half-open peer
	_fail_connection("Could not connect to a host.")


func _on_connection_succeeded() -> void:
	_connecting = false
	get_tree().change_scene_to_packed(main_scene)


func _on_connection_failed() -> void:
	if not _connecting:
		return  # already handled by the timeout fallback
	_fail_connection("Could not connect to a host.")


# The address field is "ip[:port]". The optional port applies to BOTH join and host (host
# ignores the ip half — it always binds locally), so same-machine multi-session testing can
# pick distinct ports. Out-of-range ports fall back to the default rather than reaching ENet
# as a confusing "Could not host on port -5" failure.
func _parse_port(address: String) -> int:
	if ":" in address:
		var parts := address.split(":", false, 1)
		if parts.size() > 1 and parts[1].is_valid_int():
			var port := parts[1].to_int()
			if port >= 1 and port <= 65535:
				return port
	return NetworkManager.DEFAULT_PORT


# Fall back to a non-empty placeholder so a blank name never spawns a nameless player.
func _resolved_name() -> String:
	var n := name_input.text.strip_edges()
	return n if not n.is_empty() else "Player"


func _fail_connection(message: String) -> void:
	_connecting = false
	error_label.text = message
	host_button.disabled = false
	join_button.disabled = false
