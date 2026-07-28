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
## THE ONE CARVE-OUT (v0.31.0): the "LOCAL (this machine)" section at the top. Those widgets are NOT
## host state and have no dev_command to submit — they are per-machine PRESENTATION preferences
## (today: mute the reject bonk) that live as plain GameManager vars, so they flip that var DIRECTLY.
## The invariant above still holds for everything that touches the game: nothing in the LOCAL section
## may ever read or write a value any referee adjudicates from. Its widgets are deliberately kept OUT
## of _game_editors (and every other editor registry), so _apply_snapshot can never repaint them from
## host data — a snapshot has nothing to say about this machine's speakers.
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
	# v0.26.0 instants experiment (DESIGN §2.11.1) — the toggle Jeff flips to answer the question. Its two
	# cooldown rows moved to the CLASSES section in v0.27.0, where every ability's cooldown now lives.
	{ "label": "instant abilities", "field": "instant_abilities_enabled", "bool": true },
	# v0.27.0 armor FLAT reduction per weight band (DESIGN §2.3.8) — the flat half of the two-term rule,
	# min-combined with the worn item's percentage. Integer damage amounts, so step 1.
	{ "label": "armor flat LIGHT", "field": "armor_flat_reduction_light", "min": 0, "max": 99, "step": 1 },
	{ "label": "armor flat MEDIUM", "field": "armor_flat_reduction_medium", "min": 0, "max": 99, "step": 1 },
	{ "label": "armor flat HEAVY", "field": "armor_flat_reduction_heavy", "min": 0, "max": 99, "step": 1 },
	# v0.32.0 — the whiff tail is a DIAL now, not the v0.28.0 toggle: -1 (the default, and the leftmost
	# value the spin offers) = pay the WHOLE committed tail (pre-v0.26.0 §2.3.9), 0 = pay none (v0.26.0
	# recovery-on-contact), N = pay N beats capped at the full tail. Step 0.5 like the other beat dials.
	# "recovery locks actions" is still the v0.28.0 0-stamina ACTION lockout (a no-op while the stamina
	# button above reads off).
	# v0.35.0 label fix: the old bare "whiff recovery beats" read like a magnitude you turn UP to get more
	# recovery. It is the opposite — a CAP that can only shorten, so every value at or above the weapon's
	# own tail behaves exactly like the -1 default (Jon set it to 14, saw nothing change, and filed it as a
	# bug). The label now states both the sentinel and the direction, since the row is the only place most
	# of this dial's meaning is ever read.
	{ "label": "whiff recovery beats (-1 = full; caps at weapon tail)",
		"field": "whiff_recovery_beats", "min": -1, "max": 30, "step": 0.5 },
	{ "label": "recovery locks actions", "field": "recovery_locks_actions", "bool": true },
	# v0.30.0 — the pack-rally SHOUT's reach in TRAVEL tiles through open floor (walls bound it; 0 = no
	# shout). Sits with the other monster-AI dials rather than the stamina block: it tunes who joins a
	# fight, not how anybody moves.
	{ "label": "rally travel", "field": "rally_travel_tiles", "min": 0, "max": 40, "step": 1 },
	# v0.35.0 — chance a penned-in bow monster shoots THROUGH its own packmate rather than holding. Sits
	# with the other monster-AI dials; step 0.05 because it is a probability, not a beat count. Push it to
	# 1 to make friendly fire (and its banter) reproducible on demand.
	{ "label": "archer reckless shot", "field": "archer_reckless_shot_chance",
		"min": 0, "max": 1, "step": 0.05 },
	# v0.34.0 conditions — the ROOT's break-on-damage question, shipped OFF. On = any damaging hit frees a
	# rooted target; off = the root runs its authored beats whatever you do to it.
	{ "label": "root breaks on damage", "field": "root_breaks_on_damage", "bool": true },
	# v0.29.0 — the TESTING PIN, deliberately last in the group so it doesn't read as a balance dial:
	# everyone resolves tactical while it is on, which also runs the stamina system everywhere.
	{ "label": "force tactical", "field": "force_tactical_pace", "bool": true },
]

const _WEAPON_FIELDS := ["damage_min", "damage_max", "windup_beats", "recovery_beats"]

## The SIX tunable ABILITY fields (v0.27.0 CLASSES section; `root_beats` joined in v0.34.0) — the same list
## GameManager.DEV_ABILITY_FIELDS enforces host-side, restated here only to fix the ROW ORDER on screen (a
## snapshot dictionary's key order is insertion order, which is that same list — but the panel should not
## depend on that for its layout). A field missing from this list is simply not shown; keep them in step.
const _ABILITY_FIELDS := ["damage", "stun_beats", "windup_beats", "recovery_beats", "cooldown_beats",
	"root_beats", "dot_damage", "dot_ticks", "dot_interval_beats"]

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
# EXPAND (v0.37.0, Jon: "some of us are getting older and our eyesight isn't what it used to be") — the
# multiplier applied on top of the counter-scale in _sync_width. 1.0 = the authored size, 2.0 = double.
#
# WHAT IT ACTUALLY DOES, stated precisely because the obvious phrasing is wrong: at 2.0 every glyph and
# widget doubles and the dock doubles in WIDTH, but its on-screen HEIGHT is unchanged — it already spans
# the window top to bottom, and there is nowhere taller to grow. So you see the same column twice as
# large, showing about half as many rows, and you scroll for the rest. That IS the legibility ask (Jon's
# "4x the size and double the font" reads as one wish: make it bigger; only the width has room to obey).
#
# ONE NUMBER, applied as a SCALE on the dock root rather than as a font/size restyle, because scaling the
# whole node means the layout never reflows — every row, label and spin box grows in lockstep, and a
# font-size sweep would instead have to re-derive every explicit per-control override in this file and
# would still change wrapping.
#
# SESSION-ONLY by Jon's call (2026-07-27): persisting it needs a prefs store the project does not have
# (no ConfigFile, no user:// write anywhere), which was a third of the remaining budget for this batch.
# Parked in the plan, not forgotten.
var _zoom: float = 1.0
var _expand_button: Button = null
# LOCAL section (v0.31.0) — the one non-intent widget set; see the carve-out in the header block.
var _local_box: VBoxContainer = null
var _mute_bonk_check: CheckBox = null
var _game_box: VBoxContainer = null
var _weapons_box: VBoxContainer = null
var _types_box: VBoxContainer = null
var _instances_box: VBoxContainer = null
var _status_label: Label = null
var _stamina_button: Button = null
var _winded_button: Button = null
var _type_selector: OptionButton = null
var _type_grid: GridContainer = null
# CLASSES section (v0.27.0): a class picker + a rebuilt-on-selection box of per-ability field grids. Same
# selector+grid shape as MONSTER TYPES above, one level deeper (a class has several abilities).
var _classes_box: VBoxContainer = null
var _class_selector: OptionButton = null
var _class_abilities_box: VBoxContainer = null
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
		_sync_local_widgets()
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
	# HORIZONTAL extent + the top edge only. The VERTICAL extent (anchor_bottom / offset_bottom) is owned
	# entirely by _sync_width since v0.37.0, because the rect's height now depends on the zoom — setting a
	# constant here too would be dead on arrival and would read as the authority when it isn't.
	_root.anchor_left = 1.0
	_root.anchor_right = 1.0
	_root.offset_top = 8.0
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
	# 11 → 13 in v0.31.0 (Jon: the inspector was legible but squint-y). Every per-control override
	# further down moved by the same +2, and the dock widened to -510 to keep the rows' minimum sizes
	# inside the rect — the two must move TOGETHER or the bleed-left bug returns (see _sync_width).
	var panel_theme := Theme.new()
	panel_theme.default_font_size = 13
	for control_type in ["Label", "Button", "CheckBox", "LineEdit", "OptionButton", "SpinBox"]:
		panel_theme.set_font_size("font_size", control_type, 13)
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
	# Title ROW rather than a bare label (v0.37.0), so the expand toggle can sit at the far right. The
	# spacer between them is what pins the button to the edge — the label keeps its natural width.
	var title_row := HBoxContainer.new()
	outer.add_child(title_row)
	var title := Label.new()
	title.text = "DEBUG TUNING  (` to close)"
	title.add_theme_font_size_override("font_size", 14)
	title_row.add_child(title)
	var title_spacer := Control.new()
	title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_spacer)
	_expand_button = Button.new()
	_expand_button.add_theme_font_size_override("font_size", 12)
	# Never take keyboard focus (v0.37.0): a focused Control inside the panel is read as "an edit is in
	# progress" by _apply_snapshot's guard, and this button is not an editor. Costs nothing — it is a mouse
	# toggle — and keeps the guard's meaning exact.
	_expand_button.focus_mode = Control.FOCUS_NONE
	_expand_button.pressed.connect(_toggle_expand)
	title_row.add_child(_expand_button)
	_sync_expand_button()
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
	_status_label.add_theme_font_size_override("font_size", 11)
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
	_local_box = _make_section(body, "LOCAL (this machine)")
	_game_box = _make_section(body, "GAME / STAMINA (players | monsters)")
	_weapons_box = _make_section(body, "WEAPONS")
	# v0.27.0: abilities became tunable (cooldowns, retuned stuns/damage), so they get a section. The heading
	# states the sharing model out loud — an ActiveAbility .tres is shared by every class holding it, so
	# editing "Kick" under rogue edits Kick everywhere, exactly as MONSTER TYPES edits every instance.
	_classes_box = _make_section(body, "CLASSES (ability .tres — all wielders)")
	_types_box = _make_section(body, "MONSTER TYPES (shared .tres — all instances)")
	_instances_box = _make_section(body, "LIVE INSTANCES (this one monster only)")
	_build_local_rows()
	_build_game_rows()
	# Weapons / types / instances build on the first snapshot (their sets are data-driven).


## Keep the dock ~510 SCREEN pixels wide whatever the window's content scale factor is: the rect
## stays a fixed 502 canvas units (so the rows' minimum sizes always fit — an offset-shrunk rect
## loses to min-size and bleeds left, the first screenshot's bug), and the ROOT is counter-scaled
## by 1/factor, pivoted top-right so the shrink hugs the dock edge. Net visual width = rect px.
##
## THE TWO NUMBERS MOVE TOGETHER: pivot_offset.x is always (dock width − 8), the rect width left
## after the stylebox's 8-unit left content margin. v0.31.0 grew both (430/422 → 510/502) to pay for
## the +2 font bump — a wider font makes every row's MINIMUM wider, and min-size beating the rect is
## exactly what produces the bleed. Widen here rather than trimming a row.
##
## ZOOM (v0.37.0) rides the SAME scale, as a plain multiplier: `_zoom / scale_factor`. That is the whole
## expand feature — one multiply on a number this function already computes — and it is why the DPI work
## makes this cheap rather than expensive.
##
## THE HEIGHT MUST BE DIVIDED BY THE ZOOM IN THE SAME BREATH. The pivot is (502, 0) — the rect's TOP —
## so scaling 2x grows the dock DOWNWARD, and a rect that already spans the window would end up half its
## height off the bottom of the screen. So the rect is authored at `visible_height / _zoom` and the scale
## multiplies it back to full: the net on-screen height is the window, at any zoom.
##
## That is why offset_bottom is now anchored to the TOP (anchor_bottom 0) and computed, where it used to
## be a constant -8 against anchor_bottom 1. AT _zoom == 1 THE TWO ARE ARITHMETICALLY IDENTICAL — old:
## top 8, bottom (canvas_height - 8), height canvas_height - 16; new: top 8, bottom 8 + (canvas_height -
## 16), same height, same place. So the unexpanded dock is provably unchanged by this refactor.
func _sync_width() -> void:
	if _root == null:
		return
	# The EFFECTIVE canvas→screen multiplier is window px over visible canvas units — under the
	# project's canvas_items stretch this is the stretch ratio × content_scale_factor combined
	# (reading content_scale_factor alone misses the stretch half; screenshot bug #4).
	var canvas: Vector2 = get_viewport().get_visible_rect().size
	var canvas_width: float = maxf(canvas.x, 1.0)
	var scale_factor: float = maxf(float(get_window().size.x) / canvas_width, 0.01)
	_root.offset_left = -510.0
	_root.scale = Vector2(_zoom / scale_factor, _zoom / scale_factor)
	_root.pivot_offset = Vector2(502.0, 0.0)
	# Height in CANVAS units the scaled dock should end up occupying: the visible height minus the 8-unit
	# margin top and bottom, exactly as the old constant offsets expressed it.
	#
	# THE SHRUNK RECT CANNOT CLIP THE CONTENT, and the reason is the ScrollContainer. Scaling the node does
	# NOT shrink its children's minimum sizes (those stay in canvas units), so halving the rect at zoom 2
	# would be the classic min-size-beats-the-rect trap — except the body lives in a ScrollContainer whose
	# vertical scroll is enabled, and an enabled scroll axis contributes NO minimum on that axis. So the
	# fixed chrome (title row, toggles, status label ≈ 60 units) is the entire vertical minimum, against
	# ~172 units at zoom 2 on the 360-unit base canvas. Overflow scrolls, which is already how the dock
	# behaves unexpanded on a short window. Disabling vertical scrolling here would reintroduce the trap.
	var visible_height: float = maxf(canvas.y - 16.0, 1.0)
	_root.anchor_bottom = 0.0
	_root.offset_bottom = _root.offset_top + visible_height / _zoom


## Flip the dock between authored size and 2x (v0.37.0). Everything lives in _sync_width — this just moves
## the number and asks for a re-layout, so the expand path and the resize path can never diverge.
func _toggle_expand() -> void:
	_zoom = 2.0 if _zoom == 1.0 else 1.0
	_sync_expand_button()
	_sync_width()


## The toggle's label states what a PRESS WILL DO, not the current state — "expand 2x" while small,
## "shrink 1x" while big. A button that names its own state reads as a status readout you can't act on.
func _sync_expand_button() -> void:
	if _expand_button == null:
		return
	_expand_button.text = "shrink 1x" if _zoom > 1.0 else "expand 2x"


## A folding section: header button toggles the content VBox. Returns the content box.
func _make_section(parent: VBoxContainer, heading: String) -> VBoxContainer:
	var header := Button.new()
	header.text = "▼ " + heading
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.add_theme_font_size_override("font_size", 12)
	parent.add_child(header)
	var content_box := VBoxContainer.new()
	content_box.add_theme_constant_override("separation", 2)
	parent.add_child(content_box)
	header.pressed.connect(func():
		content_box.visible = not content_box.visible
		header.text = ("▼ " if content_box.visible else "▶ ") + heading)
	return content_box


## LOCAL section rows (v0.31.0) — THE architecture carve-out (see the header block). These widgets
## flip a GameManager var DIRECTLY: no _queue, no _submit, no dev_command intent, and deliberately NOT
## registered in _game_editors, so no snapshot repaint can ever reach them. That is correct precisely
## because none of this is host state — it is what THIS machine does with its own speakers, and the
## host has no opinion about it. Add a row here ONLY for a value no referee ever reads.
func _build_local_rows() -> void:
	var row := HBoxContainer.new()
	_mute_bonk_check = CheckBox.new()
	_mute_bonk_check.text = "mute reject bonk"
	# Direct local write — the deliberate exception. The bonk's red flash + shake are NOT muted
	# (Player.play_bonk gates only the audio line): §2.3.4 keeps the visual half of the rejection.
	_mute_bonk_check.toggled.connect(func(on: bool): GameManager.mute_reject_sfx = on)
	row.add_child(_mute_bonk_check)
	_local_box.add_child(row)
	_sync_local_widgets()


## Paint the LOCAL widgets from their GameManager vars — on build and on every panel open, so the box
## always shows this machine's real state even if something else ever flips the var. no_signal so the
## repaint can't echo back into the setter (the _painting discipline the host rows use, in miniature).
func _sync_local_widgets() -> void:
	if _mute_bonk_check != null:
		_mute_bonk_check.set_pressed_no_signal(GameManager.mute_reject_sfx)


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
	label.add_theme_font_size_override("font_size", 12)
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
	if focused == null or not _classes_box.is_ancestor_of(focused):
		_paint_classes(data.get("classes", {}))
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


## CLASSES section (v0.27.0) — a class OptionButton over a box of per-ability field grids, built ONCE (the
## selector is populated from the first snapshot that carries classes) and repainted on every snapshot.
## Deliberately the _paint_types selector+grid pattern rather than a flat list of every ability: five fields
## × several abilities × six classes would be an unscrollable wall, and "which class am I tuning" is how a
## playtester thinks about it. Edits queue a `/ab <slug> <field> <value>` intent under the key
## "ab:<ability>:<field>", so scrubbing one spin collapses to one intent per flush like every other row.
func _paint_classes(classes: Dictionary) -> void:
	if _class_selector == null:
		if classes.is_empty():
			return                          # nothing to build yet (a pre-v0.27.0 host, or an empty roster)
		_class_selector = OptionButton.new()
		for class_name_key in classes:
			_class_selector.add_item(str(class_name_key))
		if _class_selector.item_count > 0:
			_class_selector.select(0)       # start populated, not on a blank grid (the _paint_types lesson)
		_class_selector.item_selected.connect(func(_index: int): _rebuild_class_grid())
		_classes_box.add_child(_class_selector)
		_class_abilities_box = VBoxContainer.new()
		_class_abilities_box.add_theme_constant_override("separation", 2)
		_classes_box.add_child(_class_abilities_box)
	_rebuild_class_grid()


## Rebuild the selected class's ability editors from the last snapshot. One sub-label per ability, then a
## 2-column (label 170 + spin 80) grid of its five fields — the same widths the MONSTER TYPES grid uses, so
## the rows are known to fit the dock's fixed 422 units.
func _rebuild_class_grid() -> void:
	if _class_abilities_box == null or _class_selector == null or _class_selector.selected < 0:
		return
	for child in _class_abilities_box.get_children():
		child.queue_free()
	var class_name_key := _class_selector.get_item_text(_class_selector.selected)
	var abilities: Dictionary = _snapshot.get("classes", {}).get(class_name_key, {})
	if abilities.is_empty():
		_class_abilities_box.add_child(_label("(no active abilities)", 170))
		return
	for ability_name in abilities:
		_class_abilities_box.add_child(_label(str(ability_name), 250))
		var fields: Dictionary = abilities[ability_name]
		var grid := GridContainer.new()
		grid.columns = 2
		_class_abilities_box.add_child(grid)
		# The /ab token is the display_name SLUG (lowercase, spaces→underscores) — GameConfig.ability_by_name
		# normalizes both sides the same way, and submitting the slug keeps the arg a SINGLE token (a raw
		# "Shield Bash" would arrive as two args and resolve to nothing).
		var slug := str(ability_name).to_lower().replace(" ", "_")
		for field in _ABILITY_FIELDS:
			if not fields.has(field) or fields[field] == null:
				continue
			grid.add_child(_label(str(field), 170))
			var spin := SpinBox.new()
			spin.custom_minimum_size = Vector2(80, 0)
			spin.min_value = 0.0
			# Cooldowns reach 600 beats (the instants band); root_beats reaches its own 120 host clamp
			# (v0.34.0 — a 30-beat shipped hold has real headroom above it); every other ability field is
			# well under 100. Still hand-written rather than derived from DEV_ABILITY_CLAMPS — the panel's
			# known spin-bounds gap, tracked in ROADMAP's parking lot.
			if field == "cooldown_beats":
				spin.max_value = 600.0
			elif field == "root_beats":
				spin.max_value = 120.0
			else:
				spin.max_value = 100.0
			spin.step = 1.0 if field == "damage" else 0.5
			spin.set_value_no_signal(float(fields[field]))
			var key := "ab:%s:%s" % [slug, field]
			spin.value_changed.connect(func(value: float):
				if not _painting:
					_queue(key, "ab", [slug, str(field), str(value)]))
			grid.add_child(spin)


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
