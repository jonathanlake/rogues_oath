extends Control

## Host/join menu. Simplified from Magick With Friends' main_menu.gd:
##  - Host: set the player name, start the server, and on OK change to main.tscn. A
##    synchronous host failure (port already bound) stays on the menu with an error.
##  - Join: start the client and wait. connection_succeeded changes scene;
##    connection_failed (or a bounded timeout) shows an error and stays on the menu.


@onready var name_input: LineEdit = $VBoxContainer/NameLineEdit
@onready var ip_input: LineEdit = $VBoxContainer/IpLineEdit
@onready var host_button: Button = $VBoxContainer/HBoxContainer/HostButton
@onready var join_button: Button = $VBoxContainer/HBoxContainer/JoinButton
@onready var error_label: Label = $VBoxContainer/ErrorLabel

## Was 5.0, tuned against same-machine testing. Bumped for real cross-internet joins (relay
## handshake + ENet handshake add real round-trip latency a local test never sees) — 2026-07-18,
## after Jeff's first real-internet attempt timed out on a since-diagnosed missing host, but the
## margin itself was already thin regardless.
const JOIN_TIMEOUT_SEC := 12.0
const NAME_HINT := "Enter a name to play"

## Address ip-halves whose :port is honored when HOSTING — loopback/wildcard forms only.
## Everything else in the field is a JOIN address, and its port must never leak into hosting
## (see host_port). Lower-case; compared case-insensitively.
const LOCAL_HOST_HALVES: Array[String] = ["", "127.0.0.1", "localhost", "0.0.0.0", "::1"]

var _connecting: bool = false
var _attempt_token: int = 0  # invalidates stale timeout timers from earlier attempts


func _ready() -> void:
	# Build version, from the ONE source of truth via GameManager.build_version() (project.godot
	# application/config/version — kept in step with the DESIGN changelog). Shown in the corner AND
	# printed, so "which build are you actually running?" is answerable at a glance on both machines
	# — the stale-exe footgun's fix.
	var version := GameManager.build_version()
	$VersionLabel.text = "v" + version
	print("[Menu] Rogue's Oath v%s" % version)
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	name_input.text_changed.connect(_on_name_changed)
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	# EXPORTED-BUILD PREFILL (v0.20.3, Jon's ask): the GitHub .exe that reaches Jeff opens with his name + the
	# tunnel address already filled, so he just clicks Join. Gated on has_feature("editor") == false, i.e. an
	# EXPORTED template build — the editor / local dev build (Jon's machine, hosts locally) is left untouched.
	# Name prefill only when unset (a returning player's own name persists in GameManager); address prefill each
	# load since it isn't persisted. If you later run a LOCAL exported exe for dev, tell me and I'll switch this
	# to a dedicated export FEATURE TAG so only the GitHub build prefills.
	if not OS.has_feature("editor"):
		if GameManager.player_name.strip_edges().is_empty():
			GameManager.player_name = "Jeff"
		# UNCONDITIONAL (v0.20.4 fix): the address field carries a scene default of "127.0.0.1", so an
		# empty-check never fired — the GitHub build always joins Jon's tunnel, so just set it. (The field
		# stays editable; it isn't persisted, so a fresh menu load re-fills it. The editor/local build keeps
		# the "127.0.0.1" default, untouched by this branch.)
		ip_input.text = "147.185.221.211:22619"
	name_input.text = GameManager.player_name  # returning player keeps their name (or the export prefill above)
	_update_button_gate()                      # re-run: the prefill may enable the buttons
	# A prior session's teardown reason (host left, kicked, handshake timeout), shown once. Set
	# AFTER the gate so it wins over NAME_HINT; the gate only clears the label when it equals
	# NAME_HINT, so the reason survives later name edits.
	if not GameManager.last_disconnect_reason.is_empty():
		error_label.text = GameManager.last_disconnect_reason
		GameManager.last_disconnect_reason = ""  # transient: shown once


# Host/Join require a non-empty name. The hint keeps disabled buttons reading as
# intentional, not broken (the feedback rule's spirit); real errors overwrite it and a
# name edit restores/clears appropriately.
func _on_name_changed(_new_text: String) -> void:
	_update_button_gate()


func _update_button_gate() -> void:
	var has_name := not name_input.text.strip_edges().is_empty()
	host_button.disabled = not has_name or _connecting
	join_button.disabled = not has_name or _connecting
	if not has_name:
		error_label.text = NAME_HINT
	elif error_label.text == NAME_HINT:
		error_label.text = ""


func _on_host_pressed() -> void:
	GameManager.player_name = _resolved_name()
	var address := ip_input.text.strip_edges()
	var port := host_port(address, NetworkManager.DEFAULT_PORT)
	# ASSIGNED on every press, true or false — never sticky: true only when the field carried a
	# :port that host_port ignored because the ip-half is a remote join address (same
	# _is_local_host_half truth host_port itself uses — one source, no silent divergence).
	# main.gd's "Hosting on port" line reads it so the override is visible in-game, not silent.
	GameManager.host_port_was_ignored = ":" in address and not _is_local_host_half(address)
	# host_game fails synchronously when the port is already bound (e.g. a second host on this
	# machine). Stay on the menu and say so — changing scene anyway would boot a phantom offline
	# "host" session nobody could join, with no error shown.
	if NetworkManager.host_game(port) != OK:
		error_label.text = "Could not host on port %d (already in use?)." % port
		return
	get_tree().change_scene_to_packed(load(GameManager.MAIN_SCENE))


func _on_join_pressed() -> void:
	GameManager.player_name = _resolved_name()
	var address := ip_input.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"

	var ip := address
	if ":" in address:
		ip = address.split(":", false, 1)[0]
	var port := _parse_port(address)

	_connecting = true
	_update_button_gate()
	error_label.text = "Connecting..."
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
	# Ownership rule: the menu only transitions for joins IT initiated (_connecting).
	# Guards two cases: a stale success arriving after our timeout already tore the peer
	# down (would otherwise enter the game with a dead peer), and debug-autostart joins,
	# whose transition is owned by debug.gd's own one-shot handler.
	if not _connecting:
		return
	_connecting = false
	get_tree().change_scene_to_packed(load(GameManager.MAIN_SCENE))


func _on_connection_failed() -> void:
	if not _connecting:
		return  # already handled by the timeout fallback
	_fail_connection("Could not connect to a host.")


## The port to BIND when hosting, given the address field's content. Pure and static (and the
## default arrives as a parameter, zero autoload coupling) so a headless script can load this
## file and assert the truth table without any UI.
##
## The field's :port is honored ONLY when the ip-half is clearly local (LOCAL_HOST_HALVES) —
## anything else is a JOIN address, and its port is someone ELSE'S port. Footgun history: the
## menu used to apply the field's :port to hosting unconditionally; with the playit tunnel
## address (`...:22619`) left in the field — the natural state for the person who SHARES that
## address — Host bound 22619 while the tunnel forwarded to 127.0.0.1:3000, which burned both
## the 2026-07-17 and 2026-07-18 wire sessions. Binding is wildcard-only (create_server takes
## no interface), so the ip-half is purely port selection here — which is exactly why a remote
## ip-half means "this was never a hosting instruction." The same-machine multi-session dev
## convenience survives via the local forms (":4000", "127.0.0.1:4000", "localhost:5000").
## Port validation reuses _parse_port's rule (is_valid_int, 1..65535, else default). Bracketed
## IPv6 ("[::1]:4000") stays this parser's documented limitation, consistent with join=.
static func host_port(address: String, default_port: int) -> int:
	if ":" not in address:
		return default_port
	if not _is_local_host_half(address):
		return default_port
	var port_half := address.split(":", true, 1)[1].strip_edges()
	if port_half.is_valid_int():
		var port := port_half.to_int()
		if port >= 1 and port <= 65535:
			return port
	return default_port


## True when the address's ip-half — everything before the FIRST colon, or the whole string
## when there is no colon (a bare local/empty field) — is one of LOCAL_HOST_HALVES. The single
## source of truth for "is this address hosting-local": host_port and _on_host_pressed's
## ignored-port flag both call it, so the two can never silently diverge. allow_empty=true in
## the split so ":4000" yields an empty (local) ip-half.
static func _is_local_host_half(address: String) -> bool:
	var ip_half := address.split(":", true, 1)[0]
	return LOCAL_HOST_HALVES.has(ip_half.strip_edges().to_lower())


# The address field is "ip[:port]" for JOINING; this parser governs joins exactly as it always
# has and is INTENTIONALLY untouched by the host-port fix above (a join needs whatever port the
# host published, remote or not). Out-of-range ports fall back to the default rather than
# reaching ENet as a confusing "connect to port -5" failure.
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
	_update_button_gate()  # re-enable only if the name gate allows it
	error_label.text = message
