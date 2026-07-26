extends CanvasLayer

## THE DEBUG PANEL (v0.25.0, Jon's tuning overhaul) — an in-game, inspector-style GUI over the
## dev-command surface, toggled with the backtick (`) key. Replaces command memorization: every
## tunable the slash commands reach is a labeled widget here.
##
## ARCHITECTURE INVARIANT (the one big decision): this panel is a PRESENTATION SURFACE over the
## EXISTING dev_command intent pipe. Every widget edit submits the same server-authoritative
## intent a typed command would (`NetEvents.submit_intent("dev_command", {cmd, args})`); the host
## validates through the same allowlists/clamps and broadcasts. The panel NEVER mutates local
## state, so it works identically on host and client (multiplayer-first) and can never desync.
## Displayed values come ONLY from host-authored `dev_snapshot` events (requested on open /
## refresh / after changes) — never from the local config, which is stale on clients for
## host-side-written g-fields.
##
## Input safety: no full-rect invisible controls (the v0.7.1 click-eater lesson) — only the
## right-side Panel exists and it STOPs mouse; hidden Controls receive no input in Godot 4.
## Typing in a SpinBox is already movement-safe: its inner LineEdit satisfies MoveInput's
## _chat_focused gate. The backtick is handled in ONE place (_input, accept-always when consumed)
## so it can never double-toggle or type a ` into a focused field.
##
## Edit flow: widget change → pending row (keyed, so scrubbing collapses) → 0.3s flush timer →
## intents; 0.6s later (and on any dev_command event while open) a fresh /snapshot is requested,
## debounced. Multi-admin edits are last-writer-wins by design (Jon+Jeff are the only admins);
## the snapshot refresh converges every open panel within a second.

## Paired per-side stamina dials (v0.25.0 split): one row, Players column | Monsters column.
const _PAIRED_DIALS := [
	{ "label": "stamina max", "p": "stamina_max", "m": "monster_stamina_max",
		"min": 1, "max": 12, "step": 1 },
	{ "label": "regen interval (beats)", "p": "player_regen_interval_beats",
		"m": "monster_regen_interval_beats", "min": 0.25, "max": 100, "step": 0.25 },
	{ "label": "regen refills full", "p": "player_regen_refills_full",
		"m": "monster_regen_refills_full", "bool": true },
	{ "label": "passive regen (beats)", "p": "player_passive_regen_beats",
		"m": "monster_passive_regen_beats", "min": 0, "max": 100, "step": 0.5 },
	{ "label": "exhausted crawl (beats)", "p": "player_exhausted_step_beats",
		"m": "monster_exhausted_step_beats", "min": 1, "max": 100, "step": 0.5 },
	{ "label": "hard-stop at 0", "p": "player_exhausted_blocks_movement",
		"m": "monster_exhausted_blocks_movement", "bool": true },
	{ "label": "refill lockout (beats)", "p": "player_refill_lockout_beats",
		"m": "monster_refill_lockout_beats", "min": 0, "max": 200, "step": 1 },
]

## Shared single-column dials.
## The four REGEN-IDLE dials (v0.26.0) live here rather than in the paired block above because the
## player side is no longer ONE number to pair against the monster one: it is three ARMOR-WEIGHT bands
## (the light dial also covers UNARMORED), so a two-column row can't express it. The monsters' single
## dial sits alongside them as the fourth row, keeping every idle wait in one visual group.
const _SHARED_DIALS := [
	{ "label": "regen idle LIGHT (beats)", "field": "player_regen_idle_light_beats",
		"min": 0, "max": 100, "step": 0.5 },
	{ "label": "regen idle MEDIUM (beats)", "field": "player_regen_idle_medium_beats",
		"min": 0, "max": 100, "step": 0.5 },
	{ "label": "regen idle HEAVY (beats)", "field": "player_regen_idle_heavy_beats",
		"min": 0, "max": 100, "step": 0.5 },
	{ "label": "regen idle MONSTERS (beats)", "field": "monster_regen_idle_beats",
		"min": 0, "max": 100, "step": 0.5 },
	{ "label": "tactical beat (sec)", "field": "tactical_beat_sec", "min": 0.05, "max": 1.0, "step": 0.05 },
	{ "label": "think min (beats)", "field": "monster_think_min_beats", "min": 0, "max": 30, "step": 1 },
	{ "label": "think max (beats)", "field": "monster_think_max_beats", "min": 0, "max": 30, "step": 1 },
	{ "label": "sticky swings", "field": "swing_catches_adjacent", "bool": true },
	# v0.26.0 instants experiment (DESIGN §2.11.1) — the toggle Jeff flips to answer the question, plus the
	# two cooldown dials the answer depends on.
	{ "label": "instant abilities", "field": "instant_abilities_enabled", "bool": true },
	{ "label": "shield block CD (beats)", "field": "shield_block_cooldown_beats",
		"min": 0, "max": 600, "step": 1 },
	{ "label": "shadow step CD (beats)", "field": "shadow_step_cooldown_beats",
		"min": 0, "max": 600, "step": 1 },
]

const _WEAPON_FIELDS := ["damage_min", "damage_max", "windup_beats", "recovery_beats"]

# Pending widget edits: row key -> {cmd, args}. Keyed so scrubbing a SpinBox collapses to one
# intent per flush; flushed by _flush_timer 0.3s after the last change.
var _pending: Dictionary = {}
var _flush_timer: Timer = null
# Snapshot re-request debounce (0.6s) — armed after our own flush and on foreign dev_command events.
var _refresh_timer: Timer = null
# True while a snapshot repaint is writing widget values, so value handlers don't echo intents.
var _painting: bool = false
# The last snapshot payload, kept for rebuilding the instance list / type grid on selector change.
var _snapshot: Dictionary = {}

var _root: PanelContainer = null
var _game_box: VBoxContainer = null
var _weapons_box: VBoxContainer = null
var _types_box: VBoxContainer = null
var _instances_box: VBoxContainer = null
var _status_label: Label = null
var _stamina_button: Button = null
var _winded_button: Button = null
var _type_selector: OptionButton = null
var _type_grid: GridContainer = null
# field -> editor Control for repaint-in-place (game + weapon rows). Instance/type editors rebuild.
var _game_editors: Dictionary = {}
var _weapon_editors: Dictionary = {}


func _ready() -> void:
	layer = 95
	visible = GameManager.debug_panel_start_visible
	_flush_timer = Timer.new()
	_flush_timer.one_shot = true
	_flush_timer.wait_time = 0.3
	_flush_timer.timeout.connect(_flush_pending)
	add_child(_flush_timer)
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	_refresh_timer.wait_time = 0.6
	_refresh_timer.timeout.connect(_request_snapshot)
	add_child(_refresh_timer)
	_build()
	NetEvents.event_received.connect(_on_event)
	if visible:
		# debugpanel=1 autostart: the session may still be handshaking; the request retries on the
		# refresh debounce if the first lands before spawn (a rejected intent is harmless).
		_refresh_timer.start()


## ONE backtick consumer (GLM plan point #7): toggles the panel, releases any field focus on
## close so the key can't type a ` into a SpinBox, and always claims the event when it acted.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.physical_keycode != KEY_QUOTELEFT:
		return
	visible = not visible
	if visible:
		_request_snapshot()
	else:
		var focus := _root.get_viewport().gui_get_focus_owner() if _root != null else null
		if focus != null:
			focus.release_focus()
	get_viewport().set_input_as_handled()


# ── Build ─────────────────────────────────────────────────────────────────────

func _build() -> void:
	_root = PanelContainer.new()
	# Right-side dock: anchored to the viewport's right edge, full height, fixed SCREEN width.
	_root.anchor_left = 1.0
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.offset_top = 8.0
	_root.offset_bottom = -8.0
	_root.offset_right = -8.0
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	# Opaque backing — the default PanelContainer stylebox lets the world bleed through, which
	# fights the inspector read. Plain dark flat box, near-opaque.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.13, 0.96)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	_root.add_theme_stylebox_override("panel", style)
	# Panel-wide small type: the PROJECT theme authors game-sized fonts PER CONTROL TYPE (fine for
	# the HUD, huge for an inspector), and explicit per-type sizes beat a child theme's
	# default_font_size (screenshot bugs #2/#3) — so this theme overrides font_size per type too.
	var panel_theme := Theme.new()
	panel_theme.default_font_size = 11
	for control_type in ["Label", "Button", "CheckBox", "LineEdit", "OptionButton", "SpinBox"]:
		panel_theme.set_font_size("font_size", control_type, 11)
	_root.theme = panel_theme
	add_child(_root)
	# CANVAS-PX vs SCREEN-PX (the v0.16.0 windowed-HUD lesson): offsets are canvas units, which the
	# window's content_scale_factor multiplies on screen — a fixed -400 reads as 800 screen px at
	# scale 2. Divide by the live factor (re-synced on resize) so the dock occupies ~420 SCREEN px.
	_sync_width()
	get_window().size_changed.connect(_sync_width)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	_root.add_child(outer)
	var title := Label.new()
	title.text = "DEBUG TUNING  (` to close)"
	title.add_theme_font_size_override("font_size", 12)
	outer.add_child(title)
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 6)
	outer.add_child(toggles)
	_stamina_button = Button.new()
	_stamina_button.text = "stamina: ?"
	_stamina_button.pressed.connect(func(): _submit("stamina", []))
	toggles.add_child(_stamina_button)
	_winded_button = Button.new()
	_winded_button.text = "exhaustion: ?"
	_winded_button.pressed.connect(func(): _submit("winded", []))
	toggles.add_child(_winded_button)
	var refresh := Button.new()
	refresh.text = "refresh"
	refresh.pressed.connect(_request_snapshot)
	toggles.add_child(refresh)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 9)
	_status_label.text = "press refresh / ` reopen for current values"
	outer.add_child(_status_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 4)
	scroll.add_child(body)
	_game_box = _make_section(body, "GAME / STAMINA (players | monsters)")
	_weapons_box = _make_section(body, "WEAPONS")
	_types_box = _make_section(body, "MONSTER TYPES (shared .tres — all instances)")
	_instances_box = _make_section(body, "LIVE INSTANCES (this one monster only)")
	_build_game_rows()
	# Weapons / types / instances build on the first snapshot (their sets are data-driven).


## Keep the dock ~430 SCREEN pixels wide whatever the window's content scale factor is: the rect
## stays a fixed 422 canvas units (so the rows' minimum sizes always fit — an offset-shrunk rect
## loses to min-size and bleeds left, the first screenshot's bug), and the ROOT is counter-scaled
## by 1/factor, pivoted top-right so the shrink hugs the dock edge. Net visual width = rect px.
func _sync_width() -> void:
	if _root == null:
		return
	# The EFFECTIVE canvas→screen multiplier is window px over visible canvas units — under the
	# project's canvas_items stretch this is the stretch ratio × content_scale_factor combined
	# (reading content_scale_factor alone misses the stretch half; screenshot bug #4).
	var canvas_width: float = maxf(get_viewport().get_visible_rect().size.x, 1.0)
	var scale_factor: float = maxf(float(get_window().size.x) / canvas_width, 0.01)
	_root.offset_left = -430.0
	_root.scale = Vector2(1.0 / scale_factor, 1.0 / scale_factor)
	_root.pivot_offset = Vector2(422.0, 0.0)


## A folding section: header button toggles the content VBox. Returns the content box.
func _make_section(parent: VBoxContainer, heading: String) -> VBoxContainer:
	var header := Button.new()
	header.text = "▼ " + heading
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.add_theme_font_size_override("font_size", 10)
	parent.add_child(header)
	var content_box := VBoxContainer.new()
	content_box.add_theme_constant_override("separation", 2)
	parent.add_child(content_box)
	header.pressed.connect(func():
		content_box.visible = not content_box.visible
		header.text = ("▼ " if content_box.visible else "▶ ") + heading)
	return content_box


func _build_game_rows() -> void:
	# Column header for the paired grid.
	var head := HBoxContainer.new()
	head.add_child(_label("", 150))
	head.add_child(_label("players", 100))
	head.add_child(_label("monsters", 100))
	_game_box.add_child(head)
	for dial in _PAIRED_DIALS:
		var row := HBoxContainer.new()
		row.add_child(_label(str(dial["label"]), 150))
		row.add_child(_make_editor(dial, str(dial["p"])))
		row.add_child(_make_editor(dial, str(dial["m"])))
		_game_box.add_child(row)
	for dial in _SHARED_DIALS:
		var row := HBoxContainer.new()
		row.add_child(_label(str(dial["label"]), 150))
		row.add_child(_make_editor(dial, str(dial["field"])))
		_game_box.add_child(row)


## One editor widget for a config g-field: CheckBox for bools, SpinBox for numbers. Edits queue a
## `/config <field> <value>` intent under the field's own pending key.
func _make_editor(spec: Dictionary, field: String) -> Control:
	if bool(spec.get("bool", false)):
		var check := CheckBox.new()
		check.text = "on"
		check.custom_minimum_size = Vector2(100, 0)
		check.toggled.connect(func(on: bool):
			if not _painting:
				_queue(field, "config", [field, "1" if on else "0"]))
		_game_editors[field] = check
		return check
	var spin := SpinBox.new()
	spin.custom_minimum_size = Vector2(100, 0)
	spin.min_value = float(spec["min"])
	spin.max_value = float(spec["max"])
	spin.step = float(spec["step"])
	spin.value_changed.connect(func(value: float):
		if not _painting:
			_queue(field, "config", [field, str(value)]))
	_game_editors[field] = spin
	return spin


func _label(text: String, width: int) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, 0)
	label.add_theme_font_size_override("font_size", 10)
	label.clip_text = true
	return label


# ── Intent plumbing ───────────────────────────────────────────────────────────

## Queue one edit under `key` (later edits to the same key replace earlier — scrub-collapse) and
## restart the 0.3s flush window.
func _queue(key: String, cmd: String, args: Array) -> void:
	_pending[key] = { "cmd": cmd, "args": args }
	_flush_timer.start()


func _flush_pending() -> void:
	for key in _pending:
		var entry: Dictionary = _pending[key]
		NetEvents.submit_intent("dev_command", { "cmd": entry["cmd"], "args": entry["args"] })
	_pending.clear()
	if visible:
		_refresh_timer.start()


## Immediate (non-debounced) submit for buttons.
func _submit(cmd: String, args: Array) -> void:
	NetEvents.submit_intent("dev_command", { "cmd": cmd, "args": args })
	if visible:
		_refresh_timer.start()


func _request_snapshot() -> void:
	NetEvents.submit_intent("dev_command", { "cmd": "snapshot", "args": [] })


func _on_event(event: Dictionary) -> void:
	var action := str(event.get("action", ""))
	if action == "dev_snapshot":
		_apply_snapshot(event.get("data", {}))
	elif action == "dev_command" and visible:
		# Someone (us via a button, or the other admin) changed something — refresh, debounced.
		_refresh_timer.start()


# ── Snapshot repaint ──────────────────────────────────────────────────────────

func _apply_snapshot(data: Dictionary) -> void:
	# Re-sync the counter-scale here too: the HUD's zoom system may change the window's
	# content_scale_factor without a size_changed signal (factor-only writes), and every panel
	# open lands a snapshot — so this hook keeps the dock width honest at all times.
	_sync_width()
	_snapshot = data
	_painting = true
	# EDIT-IN-PROGRESS guard (self-review find): a repaint landing 0.9s after your last keystroke
	# must not overwrite the field you are STILL TYPING IN, and the rebuild sections must not yank
	# a focused editor out from under the caret. One rule: the focused control (if any, inside this
	# panel) is left alone, and the rebuilt sections skip their rebuild while one of their editors
	# owns focus — the next snapshot after focus leaves trues everything up.
	var focused := _root.get_viewport().gui_get_focus_owner()
	var game: Dictionary = data.get("game", {})
	for field in _game_editors:
		if not game.has(field):
			continue
		var editor: Control = _game_editors[field]
		if editor is CheckBox:
			(editor as CheckBox).set_pressed_no_signal(bool(game[field]))
		elif editor is SpinBox:
			if focused != null and (editor as SpinBox).get_line_edit() == focused:
				continue
			(editor as SpinBox).set_value_no_signal(float(game[field]))
	if _stamina_button != null:
		_stamina_button.text = "stamina: %s" % ("ON" if bool(game.get("stamina_enabled", true)) else "off")
	if _winded_button != null:
		_winded_button.text = "exhaustion: %s" % (
				"HARD STOP" if bool(game.get("player_exhausted_blocks_movement", false)) else "crawl")
	_paint_weapons(data.get("weapons", {}))
	# Rebuilding sections: skipped entirely while one of their children owns focus (see above).
	if focused == null or not _types_box.is_ancestor_of(focused):
		_paint_types(data.get("monster_types", {}))
	if focused == null or not _instances_box.is_ancestor_of(focused):
		_paint_instances(data.get("instances", {}))
	if _status_label != null:
		_status_label.text = "synced · %d live monsters" % int(data.get("instances", {}).size())
	_painting = false


func _paint_weapons(weapons: Dictionary) -> void:
	if _weapon_editors.is_empty():
		for weapon_name in weapons:
			var head := _label(str(weapon_name), 150)
			_weapons_box.add_child(head)
			# TWO fields per row (v0.26.1). Damage became a min/max BAND, so the old single row would carry
			# four (label, spin) pairs — MEASURED at 470 units minimum, which overflows the dock's fixed 422
			# and makes the root lose to min-size and bleed left (the bug _sync_width's comment records).
			# A SpinBox's own minimum is ~68 units whatever custom_minimum_size says, so no label trim gets
			# four pairs inside the budget; pairing them is what fits (2 × (62 + 68) + separations ≈ 271)
			# AND keeps the labels spelled out. Vertical cost is one extra row per weapon.
			for pair_start in range(0, _WEAPON_FIELDS.size(), 2):
				var row := HBoxContainer.new()
				for field in _WEAPON_FIELDS.slice(pair_start, pair_start + 2):
					row.add_child(_label(_weapon_field_label(field), 62))
					var spin := SpinBox.new()
					spin.custom_minimum_size = Vector2(58, 0)
					spin.min_value = 0.0
					spin.max_value = 100.0
					spin.step = 1.0 if field.begins_with("damage") else 0.5
					var key := "w:%s:%s" % [weapon_name, field]
					spin.value_changed.connect(func(value: float):
						if not _painting:
							_queue(key, "w", [str(weapon_name), field, str(value)]))
					_weapon_editors[key] = spin
					row.add_child(spin)
				_weapons_box.add_child(row)
	var focused := _root.get_viewport().gui_get_focus_owner()
	for weapon_name in weapons:
		for field in _WEAPON_FIELDS:
			var editor: SpinBox = _weapon_editors.get("w:%s:%s" % [weapon_name, field], null)
			if editor != null and not (focused != null and editor.get_line_edit() == focused):
				editor.set_value_no_signal(float(weapons[weapon_name].get(field, 0)))


## The short row label for a weapon field (v0.26.1). The band's two fields would read "damage_min"/
## "damage_max" through the generic trim, which no longer fits the narrowed 4-field row — so they get
## explicit abbreviations and everything else keeps the "_beats" trim it always had.
func _weapon_field_label(field: String) -> String:
	match field:
		"damage_min":
			return "dmg min"
		"damage_max":
			return "dmg max"
	return field.trim_suffix("_beats")


func _paint_types(types: Dictionary) -> void:
	if _type_selector == null:
		_type_selector = OptionButton.new()
		for type_name in types:
			_type_selector.add_item(str(type_name))
		if _type_selector.item_count > 0:
			_type_selector.select(0)  # start populated, not on a blank grid (self-review find)
		_type_selector.item_selected.connect(func(_index: int): _rebuild_type_grid())
		_types_box.add_child(_type_selector)
		_type_grid = GridContainer.new()
		_type_grid.columns = 2
		_types_box.add_child(_type_grid)
	_rebuild_type_grid()


func _rebuild_type_grid() -> void:
	if _type_grid == null or _type_selector == null or _type_selector.selected < 0:
		return
	for child in _type_grid.get_children():
		child.queue_free()
	var type_name := _type_selector.get_item_text(_type_selector.selected)
	var fields: Dictionary = _snapshot.get("monster_types", {}).get(type_name, {})
	for field in fields:
		if fields[field] == null:
			continue
		_type_grid.add_child(_label(str(field), 170))
		var spin := SpinBox.new()
		spin.custom_minimum_size = Vector2(80, 0)
		spin.min_value = 0.0
		spin.max_value = 999.0
		spin.step = 0.5
		spin.set_value_no_signal(float(fields[field]))
		var key := "m:%s:%s" % [type_name, field]
		spin.value_changed.connect(func(value: float):
			if not _painting:
				_queue(key, "m", [type_name, str(field), str(value)]))
		_type_grid.add_child(spin)


func _paint_instances(instances: Dictionary) -> void:
	for child in _instances_box.get_children():
		child.queue_free()
	var ids := instances.keys()
	ids.sort()
	for id_key in ids:
		var info: Dictionary = instances[id_key]
		var header := HBoxContainer.new()
		var tag := "%s %s  %s/%s hp" % [str(info.get("name", "?")), id_key,
				str(info.get("hp", "?")), str(info.get("max_hp", "?"))]
		if bool(info.get("instanced", false)):
			tag += "  [tuned]"
		header.add_child(_label(tag, 190))
		var stun := Button.new()
		stun.text = "stun"
		stun.pressed.connect(func(): _submit("mi", [str(id_key), "stun"]))
		header.add_child(stun)
		var kill := Button.new()
		kill.text = "kill"
		kill.pressed.connect(func(): _submit("mi", [str(id_key), "kill"]))
		header.add_child(kill)
		var edit := Button.new()
		edit.text = "edit"
		header.add_child(edit)
		_instances_box.add_child(header)
		var detail := GridContainer.new()
		detail.columns = 2
		detail.visible = false
		_instances_box.add_child(detail)
		edit.pressed.connect(func(): detail.visible = not detail.visible)
		# hp / stamina live pokes.
		detail.add_child(_label("hp", 170))
		detail.add_child(_instance_spin(str(id_key), "hp", float(info.get("hp", 0)),
				0.0, float(info.get("max_hp", 1))))
		detail.add_child(_label("stamina", 170))
		detail.add_child(_instance_spin(str(id_key), "stamina", float(info.get("stamina", 0)),
				0.0, float(info.get("stamina_max", 1))))
		# Per-instance stat fields (the /mi lazy-fork surface), seeded from THIS instance's values.
		var fields: Dictionary = info.get("fields", {})
		for field in fields:
			if fields[field] == null:
				continue
			detail.add_child(_label(str(field), 170))
			detail.add_child(_instance_spin(str(id_key), str(field), float(fields[field]), 0.0, 999.0))


func _instance_spin(id_key: String, field: String, current: float, minimum: float, maximum: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.custom_minimum_size = Vector2(80, 0)
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 0.5 if field.ends_with("_beats") else 1.0
	spin.set_value_no_signal(current)
	var key := "mi:%s:%s" % [id_key, field]
	spin.value_changed.connect(func(value: float):
		if not _painting:
			_queue(key, "mi", [id_key, field, str(value)]))
	return spin
