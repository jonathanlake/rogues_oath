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

## LEGACY stamina dials (v0.46.0) — paired per-side, one row with a Players column and a Monsters column
## (the v0.25.0 split).
##
## MOVED OUT OF THE FRONT PAGE, not retired. Stamina graduated from experiment to a core engine rule on
## Jeff's v0.26.0 verdict, and these seven rows plus the four regen-idle ones below are the dials that
## question was answered WITH. They are still live, still host-validated, still exactly as tunable as they
## were — they simply stopped being what you open the panel to reach, while occupying the top of it. The
## section is collapsed by default; every editor still registers in the same `_game_editors` dict, so a
## snapshot repaints them whether the section is open or shut.
##
## This is the "LEGACY section for the settled stamina dials" cut from v0.37.0 for budget.
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

## The single-column LEGACY dials, joining the paired block above in the collapsed section. The four
## REGEN-IDLE dials (v0.26.0) are single-column rather than paired because the player side is no longer ONE
## number to pair against the monster one: it is three ARMOR-WEIGHT bands (the light dial also covers
## UNARMORED), so a two-column row cannot express it. The monsters' single dial sits alongside them as the
## fourth row, keeping every idle wait in one visual group.
const _LEGACY_SHARED_DIALS := [
	{ "label": "regen idle LIGHT (beats)", "field": "player_regen_idle_light_beats",
		"min": 0, "max": 100, "step": 0.5 },
	{ "label": "regen idle MEDIUM (beats)", "field": "player_regen_idle_medium_beats",
		"min": 0, "max": 100, "step": 0.5 },
	{ "label": "regen idle HEAVY (beats)", "field": "player_regen_idle_heavy_beats",
		"min": 0, "max": 100, "step": 0.5 },
	{ "label": "regen idle MONSTERS (beats)", "field": "monster_regen_idle_beats",
		"min": 0, "max": 100, "step": 0.5 },
]

## Shared single-column dials — the live front page.
const _SHARED_DIALS := [
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
	# v0.46.0 — banter EARSHOT in tiles. A live host dial since v0.27.1 that never got a row, so it was
	# typed-command-only and silently so. 0 makes the ally-died and help-me reactions silent, which is a
	# legitimate setting rather than an off-by-one.
	{ "label": "banter earshot (tiles)", "field": "banter_earshot_tiles", "min": 0, "max": 60, "step": 1 },
	# v0.29.0 — the TESTING PIN, deliberately last in the group so it doesn't read as a balance dial:
	# everyone resolves tactical while it is on, which also runs the stamina system everywhere.
	{ "label": "force tactical", "field": "force_tactical_pace", "bool": true },
]

## GRID GEOMETRY (v0.46.0). The class / monster-type / live-instance grids are the panel's most numerous
## rows by a wide margin — a single monster type renders 28 of them — and at 2 columns they used
## 170 + 80 + separation ≈ 254 of the ~486 usable units. Nearly half the dock was empty space, on exactly
## the sections you scroll longest.
##
## FOUR COLUMNS (label, spin, label, spin) halves those sections' height for free at any zoom, which
## compounds with v0.44.0's taller expanded dock. The widths below are the 2-column pair trimmed to fit two
## pairs inside the SAME collapsed 502-unit budget: 2 x (118 + 76) + separations ≈ 400, comfortably under
## the _MIN_RECT_W floor that keeps the dock from bleeding left. A SpinBox's own minimum is ~68 units
## whatever custom_minimum_size says, so 76 is real and 118 is what the label gets.
const _GRID_COLUMNS := 4
const _GRID_LABEL_W := 118
const _GRID_SPIN_W := 76

const _WEAPON_FIELDS := ["damage_min", "damage_max", "windup_beats", "recovery_beats"]

## Apply a field's HOST CLAMP to a SpinBox (v0.46.0) — the fix for ROADMAP's "panel spin ranges exceed the
## host clamps" finding, which turned out to understate the problem in one direction that mattered.
##
## The old hardcoded `0..999 step 0.5` on the type and instance grids did not merely allow values the host
## would refuse (harmless — the reject is distinct). It made host-LEGAL values UNREACHABLE, because three
## monster dials are explicitly SIGNED: `bonus_windup_beats` and `bonus_recovery_beats` at [-30, 30] and
## `bonus_damage` at [-999, 999], all documented as "a designer can add or subtract". From the panel you
## could only ever add. `utility_alone_move_factor` was worse in the other direction — a [0, 1] fractional
## multiplier offered at step 0.5, so only 0, 0.5 and 1 were reachable at all.
##
## Deriving from the SAME table the host validates against means the panel can express exactly what the
## command line can, and a retuned clamp moves both together. A field with no clamp entry keeps a wide
## permissive default rather than guessing — better an occasional honest reject than an invented ceiling.
##
## STEP is derived too: an int-typed field steps by 1, and a fractional range narrower than 2 gets a fine
## step so a 0-1 dial is actually adjustable.
static func _apply_clamp(spin: SpinBox, field: String, clamps: Dictionary, int_fields: Array) -> void:
	var lo := -999.0
	var hi := 999.0
	# Shape-checked rather than indexed blind (GLM diff review): a malformed table entry should fall back to
	# the permissive default, not crash the whole panel build on a typo in a constant.
	var entry = clamps.get(field)
	if entry is Array and entry.size() >= 2:
		lo = float(entry[0])
		hi = float(entry[1])
	spin.min_value = lo
	spin.max_value = hi
	if field in int_fields:
		spin.step = 1.0
	elif hi - lo <= 2.0:
		spin.step = 0.05
	else:
		spin.step = 0.5

## The tunable ABILITY fields (v0.27.0 CLASSES section) — the same set GameManager.DEV_ABILITY_FIELDS
## enforces host-side, restated here only to fix the ROW ORDER on screen (a snapshot dictionary's key order
## is insertion order, which is that same list — but the panel should not depend on that for its layout).
##
## THEY DRIFTED, WHICH IS WHY THE COUNT IS NO LONGER IN THIS COMMENT. It said "the SIX tunable ability
## fields" over a list of nine, and by v0.43.0 the host allowed fourteen — so the entire mana / orb / blink
## surface shipped with no panel row at all, tunable only by typing `/ab`. Both halves of that are fixed
## here: the list below is complete, and the header no longer states a number that can rot.
##
## A field the host allows but this list omits is simply not shown, so keep them in step — or better, ask
## whether the new field wants a row before adding it host-side.
const _ABILITY_FIELDS := ["damage", "stun_beats", "windup_beats", "recovery_beats", "cooldown_beats",
	"root_beats", "dot_damage", "dot_ticks", "dot_interval_beats",
	"mana_cost", "orb_count", "orb_damage", "orb_interval_beats", "blink_travel_tiles"]

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

## The dock's collapsed ON-SCREEN width in canvas units — the number v0.31.0 grew from 422 to 502 to pay
## for its +2 font bump. Named now (v0.44.0) rather than written twice as the literal pair -510/502, which
## is how two comments elsewhere in this file spent three releases reasoning from the pre-v0.31.0 422
## (both corrected in the same pass).
const _DOCK_W := 502.0
## The narrowest the rect may ever be authored. Horizontal scrolling is DISABLED, so the widest row's
## minimum propagates: go under it and min-size beats the rect and the dock bleeds LEFT (the original
## screenshot bug). The widest row today is a GAME paired row at 150 + 100 + 100 + separations ≈ 358.
const _MIN_RECT_W := 360.0

# EXPAND (v0.37.0, Jon: "some of us are getting older and our eyesight isn't what it used to be") — the
# GLYPH multiplier. 1.0 = the authored size, 2.0 = double. Applied as a SCALE on the dock root rather than
# a font/size restyle, because scaling the whole node means the layout never reflows: every row, label and
# spin box grows in lockstep, where a font-size sweep would have to re-derive every explicit per-control
# override in this file and would still change wrapping.
#
# v0.44.0 SPLIT ITS SECOND JOB OFF. It used to divide the rect as well as multiply the glyphs, so
# expanding doubled the text and halved the rect — you got bigger words and about a quarter of the rows.
# It is now purely the glyph scale; the dock's on-screen SIZE is chosen separately in _sync_geometry.
# Changing this number no longer changes how much you can see, only how big it is.
#
# SESSION-ONLY by Jon's call (2026-07-27): persisting it needs a prefs store the project does not have
# (no ConfigFile, no user:// write anywhere), which was a third of the remaining budget for that batch.
# Parked in the plan, not forgotten.
var _zoom: float = 1.0
# The PLAY AREA in canvas units, pushed by main.gd off the HUD's world_frame_changed (v0.44.0). The
# expanded dock fills it. A ZERO rect means "not pushed yet" — a real state on a peer whose HUD has not
# had its first deferred layout — and _sync_geometry falls back to the full canvas for it.
var _play_area: Rect2 = Rect2()
var _expand_button: Button = null
# LOCAL section (v0.31.0) — the one non-intent widget set; see the carve-out in the header block.
var _local_box: VBoxContainer = null
var _mute_bonk_check: CheckBox = null
var _game_box: VBoxContainer = null
var _legacy_box: VBoxContainer = null
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
## Per-instance LIVE INSTANCES disclosure state (v0.46.0): instance id -> is its detail grid open. Lives
## here rather than on the Control because _paint_instances rebuilds those Controls on every snapshot; see
## the note at its use site for the bug that caused.
var _instance_open: Dictionary = {}
var _game_editors: Dictionary = {}
## WEAPONS selector + grid (v0.46.0) — replaces the flat build-once `_weapon_editors` registry.
## TRAITS selector + grid (v0.46.0) — the fourth instance of the selector+grid pattern, driven by the
## v0.45.0 trait catalog. Traits became tunable objects that version and had no panel surface at all.
var _traits_box: VBoxContainer = null
var _trait_selector: OptionButton = null
var _trait_grid: GridContainer = null
var _weapon_selector: OptionButton = null
var _weapon_grid: GridContainer = null


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
	# Right-anchored dock. ONLY THE ANCHORS ARE AUTHORED HERE (v0.44.0): every offset — left, top, right,
	# bottom — plus the scale and pivot are owned entirely by _sync_geometry, which runs immediately after
	# this and on every resize/zoom/play-area change. The two offsets below are seeded purely so the node
	# is well-formed for one frame; treating them as the authority is what let the old width/pivot pair
	# drift out of step.
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
	# inside the rect — the two must move TOGETHER or the bleed-left bug returns (see _sync_geometry).
	var panel_theme := Theme.new()
	panel_theme.default_font_size = 13
	for control_type in ["Label", "Button", "CheckBox", "LineEdit", "OptionButton", "SpinBox"]:
		panel_theme.set_font_size("font_size", control_type, 13)
	_root.theme = panel_theme
	add_child(_root)
	# CANVAS-PX vs SCREEN-PX (the v0.16.0 windowed-HUD lesson): offsets are canvas units, which the
	# window's content_scale_factor multiplies on screen — a fixed -400 reads as 800 screen px at
	# scale 2. Divide by the live factor (re-synced on resize) so the dock occupies ~420 SCREEN px.
	_sync_geometry()
	get_window().size_changed.connect(_sync_geometry)
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
	_game_box = _make_section(body, "GAME")
	_weapons_box = _make_section(body, "WEAPONS")
	# v0.27.0: abilities became tunable (cooldowns, retuned stuns/damage), so they get a section. The heading
	# states the sharing model out loud — an ActiveAbility .tres is shared by every class holding it, so
	# editing "Kick" under rogue edits Kick everywhere, exactly as MONSTER TYPES edits every instance.
	_classes_box = _make_section(body, "CLASSES (ability .tres — all wielders)")
	_traits_box = _make_section(body, "TRAITS (passive .tres — all wearers)")
	_types_box = _make_section(body, "MONSTER TYPES (shared .tres — all instances)")
	_instances_box = _make_section(body, "LIVE INSTANCES (this one monster only)")
	# LAST and CLOSED (v0.46.0): the settled stamina dials. See _PAIRED_DIALS for why they moved.
	_legacy_box = _make_section(body, "LEGACY / STAMINA (players | monsters)", false)
	_build_local_rows()
	_build_game_rows()
	# Weapons / types / instances build on the first snapshot (their sets are data-driven).


## Lay the dock out: its rect, its counter-scale, its pivot and its height. Rewritten v0.44.0 (renamed
## from `_sync_width`, which owned all four of those and had not been only about width since v0.37.0).
##
## THE MODEL, in one sentence: pick the size the dock should occupy ON SCREEN, then divide by the glyph
## scale to get the rect that produces it.
##
## THE BUG THIS REPLACES. `_zoom` used to be BOTH the glyph multiplier and the rect divisor — the scale
## multiplied by it and the height divided by it in the same breath — so expanding doubled every glyph
## while HALVING the rect. Net effect: the dock kept its on-screen height and showed about a quarter as
## many rows. The old comment here claimed the dock "already spans the window top to bottom, and there is
## nowhere taller to grow"; that was simply wrong, and its own worked number gave it away — "~172 units at
## zoom 2 on the 360-unit base canvas" is 48% of the window, not all of it. On-screen height was
## `visible_height / scale_factor`: the `_zoom` cancelled (correct — height should be zoom-invariant) but
## the counter-scale did not. Roughly half the window was unclaimed the whole time.
##
## THE TWO SIZES ARE NOW SEPARATE NUMBERS:
##   `glyph_scale` — `_zoom / scale_factor`, UNCHANGED and still the whole expand feature. It is what makes
##     text bigger, and v0.44.0 does not touch the font at either setting (Jon: keep the expanded size).
##   `target` — the on-screen extent in CANVAS units, chosen per zoom state and divided by `glyph_scale`
##     to author the rect. Collapsed asks for exactly what it occupied before; expanded asks for the play
##     area.
##
## COLLAPSED IS PROVABLY UNCHANGED, the same proof the v0.37.0 refactor used. At `_zoom == 1`,
## `glyph_scale == 1/scale_factor`, and the collapsed target is `502/scale_factor` wide by
## `(canvas.y-16)/scale_factor` tall — so `rect = target / glyph_scale` is 502 by `canvas.y-16`, which is
## the old constant width and the old `visible_height / 1` height, at the same offsets. Byte-identical.
##
## EXPANDED FILLS THE PLAY AREA (Jon, 2026-07-28), with the width FLOORED at the 502 it already had. The
## floor is not defensive padding — at the 1280×720 dev window the play area is only 460 canvas units
## wide while the dock is 502, so obeying "fill the play area" literally would make expanding NARROWER
## there. Flooring keeps the small-window case at today's width and full height (2× the rows), while a
## 1920×1080 session gets the real win: 780×524 against the old 502×262, a little over 3× the area.
##
## THE PIVOT INVARIANT is now structural instead of hand-maintained: `pivot.x == rect_w` and
## `offset_left == offset_right - rect_w`, both derived from the one `rect_w`. They used to be two hand-
## written constants (-510 / 502) that had to be edited together, which is exactly the kind of pair that
## drifts — two comments in this file had been reasoning from the pre-v0.31.0 422 for three releases.
##
## THE RECT CANNOT CLIP THE CONTENT, unchanged and still because of the ScrollContainer: scaling a node
## does not shrink its children's minimum sizes, so a rect smaller than the content would be the classic
## min-size-beats-the-rect trap — except the body's vertical scroll is ENABLED, and an enabled scroll axis
## contributes no minimum on that axis. The fixed chrome (title row, toggles, status ≈ 60 units) is the
## whole vertical minimum. Horizontal scrolling is DISABLED, so the widest row's minimum DOES propagate —
## which is why `_MIN_RECT_W` exists below.
func _sync_geometry() -> void:
	if _root == null:
		return
	# The EFFECTIVE canvas→screen multiplier is window px over visible canvas units — under the
	# project's canvas_items stretch this is the stretch ratio × content_scale_factor combined
	# (reading content_scale_factor alone misses the stretch half; screenshot bug #4).
	var canvas: Vector2 = get_viewport().get_visible_rect().size
	var canvas_width: float = maxf(canvas.x, 1.0)
	var scale_factor: float = maxf(float(get_window().size.x) / canvas_width, 0.01)
	var glyph_scale: float = maxf(_zoom / scale_factor, 0.01)
	# The on-screen extent we want, in canvas units, and where its top-right corner goes. The corner is
	# what positioning reduces to: the pivot is the rect's top-RIGHT, so scaling leaves that corner fixed
	# and the dock grows left and down from it.
	var target_w: float = _DOCK_W / scale_factor
	var target_h: float = maxf(canvas.y - 16.0, 1.0) / scale_factor
	# Collapsed corner = the canvas's top-right inset by the 8-unit margin, i.e. the v0.43.0 constants.
	var corner_right: float = -8.0
	var corner_top: float = 8.0
	if _zoom > 1.0:
		# EXPANDED: the play area — its POSITION as well as its size (GLM diff review). Size alone was not
		# enough and the difference is visible: the dock is right-anchored while the play area starts at the
		# canvas origin with the HUD column to its right, so a play-area-SIZED dock pinned to the canvas edge
		# covers the whole HUD column and only part of the play area. Aligning the corner to the play area's
		# own top-right makes "fills the play area" true rather than approximate, and leaves the HUD readable
		# while you tune — which is the point of sacrificing the play area specifically.
		#
		# The FALLBACK is the COLLAPSED size, not the whole canvas (GLM diff review). A peer that expands
		# before the HUD's first deferred layout should get the dock it already had, not a full-screen
		# obstruction that self-corrects a frame later.
		if _play_area.size.x > 0.0 and _play_area.size.y > 0.0:
			# Both axes lose the 8-unit margin at each end, so the dock sits INSIDE the play area rather
			# than flush against its edges — symmetric with the collapsed state's own 8-unit insets.
			target_w = maxf(_play_area.size.x - 16.0, _DOCK_W)
			target_h = maxf(_play_area.size.y - 16.0, 1.0)
			corner_right = (_play_area.position.x + _play_area.size.x) - canvas.x - 8.0
			corner_top = _play_area.position.y + 8.0
		else:
			target_w = _DOCK_W
			target_h = maxf(canvas.y - 16.0, 1.0)
	# Author the rect that produces that extent, never narrower than the widest row's minimum (below it
	# the disabled horizontal scroll lets min-size beat the rect and the dock bleeds LEFT — the original
	# screenshot bug, and the reason v0.31.0's font bump had to widen the dock rather than trim a row).
	#
	# NOTE the floor can legitimately make the expanded dock WIDER than the play area on a small window
	# (play area 460 against _DOCK_W 502), so it overhangs the play area's left edge by the difference.
	# That is the trade the floor exists to make: overhanging is strictly better than expanding into
	# something narrower than the dock you started from.
	var rect_w: float = maxf(target_w / glyph_scale, _MIN_RECT_W)
	_root.offset_top = corner_top
	_root.offset_right = corner_right
	_root.offset_left = _root.offset_right - rect_w
	_root.pivot_offset = Vector2(rect_w, 0.0)
	_root.scale = Vector2(glyph_scale, glyph_scale)
	_root.anchor_bottom = 0.0
	_root.offset_bottom = _root.offset_top + target_h / glyph_scale


## Adopt the play-area rect (v0.44.0), pushed by main.gd from the HUD's `world_frame_changed`. The panel
## never reaches up for it — a component takes what it is given (CLAUDE.md's component rule), and this is
## the same one-line-per-consumer fan-out the F3 label and the hurt vignette already ride.
##
## A ZERO rect is a legitimate state, not an error: it is what a peer has before the HUD's first deferred
## layout, and `_sync_geometry` falls back to the full canvas for it. So this can be called early, often,
## or never, and the dock is sensible in all three cases.
func set_play_area_rect(rect: Rect2) -> void:
	if rect.size == _play_area.size and rect.position == _play_area.position:
		return
	_play_area = rect
	# Only the EXPANDED dock reads this, so a collapsed panel caches the value and skips the re-layout
	# (GLM diff review) — the HUD emits this every layout pass on every peer, and recomputing offsets for
	# a state that never consults them is work for nothing. Expanding later reads the cached value.
	if _zoom > 1.0:
		_sync_geometry()


## Flip the dock between authored size and expanded (v0.37.0). Everything lives in _sync_geometry — this just moves
## the number and asks for a re-layout, so the expand path and the resize path can never diverge.
func _toggle_expand() -> void:
	_zoom = 2.0 if _zoom == 1.0 else 1.0
	_sync_expand_button()
	_sync_geometry()


## The toggle's label states what a PRESS WILL DO, not the current state — "expand 2x" while small,
## "shrink 1x" while big. A button that names its own state reads as a status readout you can't act on.
func _sync_expand_button() -> void:
	if _expand_button == null:
		return
	_expand_button.text = "shrink 1x" if _zoom > 1.0 else "expand 2x"


## A folding section: header button toggles the content VBox. Returns the content box.
func _make_section(parent: VBoxContainer, heading: String, start_open: bool = true) -> VBoxContainer:
	var header := Button.new()
	header.text = ("▼ " if start_open else "▶ ") + heading
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.add_theme_font_size_override("font_size", 12)
	parent.add_child(header)
	var content_box := VBoxContainer.new()
	content_box.add_theme_constant_override("separation", 2)
	content_box.visible = start_open
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
	for dial in _SHARED_DIALS:
		var row := HBoxContainer.new()
		row.add_child(_label(str(dial["label"]), 150))
		row.add_child(_make_editor(dial, str(dial["field"])))
		_game_box.add_child(row)
	# The LEGACY section, built in the same pass and into the same `_game_editors` registry — a snapshot
	# repaints these whether the section is open or shut, so collapsing it costs nothing but the pixels.
	var head := HBoxContainer.new()
	head.add_child(_label("", 150))
	head.add_child(_label("players", 100))
	head.add_child(_label("monsters", 100))
	_legacy_box.add_child(head)
	for dial in _PAIRED_DIALS:
		var row := HBoxContainer.new()
		row.add_child(_label(str(dial["label"]), 150))
		row.add_child(_make_editor(dial, str(dial["p"])))
		row.add_child(_make_editor(dial, str(dial["m"])))
		_legacy_box.add_child(row)
	for dial in _LEGACY_SHARED_DIALS:
		var row := HBoxContainer.new()
		row.add_child(_label(str(dial["label"]), 150))
		row.add_child(_make_editor(dial, str(dial["field"])))
		_legacy_box.add_child(row)


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
	_sync_geometry()
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
		# THE BUTTON MUST NOT LIE WHEN THE TWO SIDES DIVERGE (v0.46.0). `/winded` is a CONVERGENT toggle —
		# it reads the PLAYER field and sets BOTH sides to its negation — but the "hard-stop at 0" paired
		# row below sets each side independently. Set players to crawl and monsters to hard-stop from that
		# row, and this button read "exhaustion: crawl" while every monster in the room hard-stopped: a
		# status readout stating half the truth with no hint there was another half.
		#
		# Naming the split is the honest repaint. Pressing it still converges them, which is exactly what
		# you want when you see SPLIT and did not mean to.
		var winded_p := bool(game.get("player_exhausted_blocks_movement", false))
		var winded_m := bool(game.get("monster_exhausted_blocks_movement", winded_p))
		if winded_p != winded_m:
			_winded_button.text = "exhaustion: SPLIT (P %s / M %s)" % [
					"stop" if winded_p else "crawl", "stop" if winded_m else "crawl"]
		else:
			_winded_button.text = "exhaustion: %s" % ("HARD STOP" if winded_p else "crawl")
	# Rebuilding sections: skipped entirely while one of their children owns focus (see above).
	# WEAPONS JOINED THEM in v0.46.0 (GLM diff review). It used to build once and repaint values in place
	# with a per-editor focus check, so it needed no section guard; converting it to a selector+grid made it
	# a rebuild like its siblings, and without this the 0.6s snapshot would free the SpinBox out from under
	# someone typing in it.
	if focused == null or not _weapons_box.is_ancestor_of(focused):
		_paint_weapons(data.get("weapons", {}))
	if focused == null or not _classes_box.is_ancestor_of(focused):
		_paint_classes(data.get("classes", {}))
	if focused == null or not _traits_box.is_ancestor_of(focused):
		_paint_traits(data.get("passives", {}))
	if focused == null or not _types_box.is_ancestor_of(focused):
		_paint_types(data.get("monster_types", {}))
	if focused == null or not _instances_box.is_ancestor_of(focused):
		_paint_instances(data.get("instances", {}))
	if _status_label != null:
		_status_label.text = "synced · %d live monsters" % int(data.get("instances", {}).size())
	_painting = false


## Reconcile an OptionButton's items against a live name set, preserving the current selection by NAME
## (v0.46.0, GLM diff review). Returns true if the selector has anything to show.
##
## POPULATING ONCE WAS THE OLD BUG WEARING NEW CLOTHES. `_paint_weapons` used to build its rows on the
## first snapshot and never again, so a weapon added mid-session got no rows; converting it to a
## selector+grid fixed the ROWS but left the DROPDOWN static, which is the same defect one level up. The
## grid rebuilds every snapshot; the list of things you can pick has to as well.
##
## Rebuilds only when the set actually differs, because rebuilding unconditionally would fight the user's
## selection every 0.6s. Selection is restored by name rather than index — an added or removed entry
## shifts indices, and a selector that silently jumps to a different weapon while you tune is worse than
## one that never updates.
static func _sync_selector(selector: OptionButton, names: Array) -> bool:
	var current := selector.get_item_text(selector.selected) if selector.selected >= 0 else ""
	var same := selector.item_count == names.size()
	if same:
		for i in names.size():
			if selector.get_item_text(i) != str(names[i]):
				same = false
				break
	if not same:
		selector.clear()
		for n in names:
			selector.add_item(str(n))
		var restored := -1
		for i in names.size():
			if str(names[i]) == current:
				restored = i
				break
		if selector.item_count > 0:
			selector.select(restored if restored >= 0 else 0)
	return selector.item_count > 0


## WEAPONS as a SELECTOR + GRID (v0.46.0) — the "dropdowns for weapons" half of the reorganisation cut from
## v0.37.0 for budget, and now the third instance of the pattern MONSTER TYPES and CLASSES already use.
##
## WHY: the flat form rendered every weapon at once, two rows each — four weapons was 12 rows and a fifth
## would have been 15, growing the section forever for a surface you only ever read one row of. The
## selector shows the one weapon you are tuning and nothing else, which is the same argument
## `_paint_classes` records for not listing every ability of every class at once.
##
## The rebuild-on-selection shape also fixes the old build-once guard: `_paint_weapons` used to populate its
## editors on the first snapshot only, so a weapon added to the catalog mid-session never got rows at all.
func _paint_weapons(weapons: Dictionary) -> void:
	if _weapon_selector == null:
		_weapon_selector = OptionButton.new()
		_weapon_selector.item_selected.connect(func(_index: int): _rebuild_weapon_grid())
		_weapons_box.add_child(_weapon_selector)
		_weapon_grid = GridContainer.new()
		_weapon_grid.columns = _GRID_COLUMNS
		_weapons_box.add_child(_weapon_grid)
	_sync_selector(_weapon_selector, weapons.keys())
	_rebuild_weapon_grid()


func _rebuild_weapon_grid() -> void:
	if _weapon_grid == null or _weapon_selector == null or _weapon_selector.selected < 0:
		return
	for child in _weapon_grid.get_children():
		child.queue_free()
	var weapon_name := _weapon_selector.get_item_text(_weapon_selector.selected)
	var fields: Dictionary = _snapshot.get("weapons", {}).get(weapon_name, {})
	for field in _WEAPON_FIELDS:
		if not fields.has(field) or fields[field] == null:
			continue
		_weapon_grid.add_child(_label(_weapon_field_label(field), _GRID_LABEL_W))
		var spin := SpinBox.new()
		spin.custom_minimum_size = Vector2(_GRID_SPIN_W, 0)
		_apply_clamp(spin, field, GameManager.DEV_WEAPON_CLAMPS, GameManager.DEV_WEAPON_INT_FIELDS)
		spin.set_value_no_signal(float(fields[field]))
		var key := "w:%s:%s" % [weapon_name, field]
		spin.value_changed.connect(func(value: float):
			if not _painting:
				_queue(key, "w", [str(weapon_name), field, str(value)]))
		_weapon_grid.add_child(spin)
## TRAITS section (v0.46.0) — selector + grid over the trait catalog, the same shape as WEAPONS and MONSTER
## TYPES. A trait's fields live on its own subclass, so the snapshot sends only the ones each trait actually
## declares and this renders exactly those: Sneak Attack shows a multiplier, Archery shows two deltas.
func _paint_traits(passives: Dictionary) -> void:
	if _trait_selector == null:
		_trait_selector = OptionButton.new()
		_trait_selector.item_selected.connect(func(_index: int): _rebuild_trait_grid())
		_traits_box.add_child(_trait_selector)
		_trait_grid = GridContainer.new()
		_trait_grid.columns = _GRID_COLUMNS
		_traits_box.add_child(_trait_grid)
	_sync_selector(_trait_selector, passives.keys())
	_rebuild_trait_grid()


func _rebuild_trait_grid() -> void:
	if _trait_grid == null or _trait_selector == null or _trait_selector.selected < 0:
		return
	for child in _trait_grid.get_children():
		child.queue_free()
	var trait_name := _trait_selector.get_item_text(_trait_selector.selected)
	var fields: Dictionary = _snapshot.get("passives", {}).get(trait_name, {})
	for field in fields:
		if fields[field] == null:
			continue
		_trait_grid.add_child(_label(str(field), _GRID_LABEL_W))
		var spin := SpinBox.new()
		spin.custom_minimum_size = Vector2(_GRID_SPIN_W, 0)
		_apply_clamp(spin, str(field), GameManager.DEV_PASSIVE_CLAMPS, GameManager.DEV_PASSIVE_INT_FIELDS)
		spin.set_value_no_signal(float(fields[field]))
		# The /pa token is the display_name SLUG, normalized the same way GameConfig.passive_by_name
		# normalizes it — and submitting the slug keeps the arg a SINGLE token ("Sneak Attack" would
		# arrive as two args and resolve to nothing).
		var slug := str(trait_name).to_lower().replace(" ", "_")
		var key := "pa:%s:%s" % [slug, field]
		spin.value_changed.connect(func(value: float):
			if not _painting:
				_queue(key, "pa", [slug, str(field), str(value)]))
		_trait_grid.add_child(spin)


## The short row label for a weapon field (v0.26.1). The band's two fields would read "damage_min"/
## "damage_max" through the generic trim, so they get explicit abbreviations and everything else keeps the
## "_beats" trim it always had.
func _weapon_field_label(field: String) -> String:
	match field:
		"damage_min":
			return "dmg min"
		"damage_max":
			return "dmg max"
	return field.trim_suffix("_beats")




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
## 4-column (label + spin, twice per row) grid of its fields — the same widths the MONSTER TYPES grid uses, so
## the rows are known to fit the dock's collapsed 502 units (_DOCK_W).
func _rebuild_class_grid() -> void:
	if _class_abilities_box == null or _class_selector == null or _class_selector.selected < 0:
		return
	for child in _class_abilities_box.get_children():
		child.queue_free()
	var class_name_key := _class_selector.get_item_text(_class_selector.selected)
	var abilities: Dictionary = _snapshot.get("classes", {}).get(class_name_key, {})
	if abilities.is_empty():
		_class_abilities_box.add_child(_label("(no active abilities)", _GRID_LABEL_W))
		return
	for ability_name in abilities:
		_class_abilities_box.add_child(_label(str(ability_name), 250))
		var fields: Dictionary = abilities[ability_name]
		var grid := GridContainer.new()
		grid.columns = _GRID_COLUMNS
		_class_abilities_box.add_child(grid)
		# The /ab token is the display_name SLUG (lowercase, spaces→underscores) — GameConfig.ability_by_name
		# normalizes both sides the same way, and submitting the slug keeps the arg a SINGLE token (a raw
		# "Shield Bash" would arrive as two args and resolve to nothing).
		var slug := str(ability_name).to_lower().replace(" ", "_")
		for field in _ABILITY_FIELDS:
			if not fields.has(field) or fields[field] == null:
				continue
			grid.add_child(_label(str(field), _GRID_LABEL_W))
			var spin := SpinBox.new()
			spin.custom_minimum_size = Vector2(_GRID_SPIN_W, 0)
			# v0.46.0: DERIVED from the host's own clamp table, closing ROADMAP's spin-bounds gap here as
			# well as on the monster grids. The three hand-written ceilings this replaces (600 for
			# cooldowns, 120 for roots, 100 for everything else) were correct when written and had already
			# drifted: v0.43.0 added five fields none of them described.
			_apply_clamp(spin, str(field), GameManager.DEV_ABILITY_CLAMPS, GameManager.DEV_ABILITY_INT_FIELDS)
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
		_type_grid.columns = _GRID_COLUMNS
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
		_type_grid.add_child(_label(str(field), _GRID_LABEL_W))
		var spin := SpinBox.new()
		spin.custom_minimum_size = Vector2(_GRID_SPIN_W, 0)
		_apply_clamp(spin, str(field), GameManager.DEV_MONSTER_CLAMPS, GameManager.DEV_MONSTER_INT_FIELDS)
		spin.set_value_no_signal(float(fields[field]))
		var key := "m:%s:%s" % [type_name, field]
		spin.value_changed.connect(func(value: float):
			if not _painting:
				_queue(key, "m", [type_name, str(field), str(value)]))
		_type_grid.add_child(spin)


func _paint_instances(instances: Dictionary) -> void:
	for child in _instances_box.get_children():
		child.queue_free()
	# Drop remembered disclosure state for monsters that no longer exist, so the dict tracks the live set
	# rather than every id the session has ever seen.
	for remembered in _instance_open.keys():
		if not instances.has(remembered):
			_instance_open.erase(remembered)
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
		detail.columns = _GRID_COLUMNS
		# DISCLOSURE STATE SURVIVES THE REBUILD (v0.46.0). _paint_instances frees and rebuilds everything on
		# every snapshot, and the open/closed flag used to live only on the Control it rebuilt — so opening a
		# monster's grid and then changing ANY dial (or another admin changing one) collapsed it about 0.6s
		# later, mid-edit. The focus guard above does not cover it: a Button press leaves no LineEdit
		# focused, and live monsters have live-changing hp, so snapshots are frequent.
		#
		# Keyed by instance id in a dict that OUTLIVES the widgets. A despawned monster's entry is pruned
		# below rather than left to accumulate, so a long session does not grow a set of ids for corpses.
		var open_key := str(id_key)
		detail.visible = bool(_instance_open.get(open_key, false))
		_instances_box.add_child(detail)
		edit.pressed.connect(func():
			detail.visible = not detail.visible
			_instance_open[open_key] = detail.visible)
		# hp / stamina live pokes.
		detail.add_child(_label("hp", _GRID_LABEL_W))
		detail.add_child(_instance_spin(str(id_key), "hp", float(info.get("hp", 0)),
				0.0, float(info.get("max_hp", 1))))
		detail.add_child(_label("stamina", _GRID_LABEL_W))
		detail.add_child(_instance_spin(str(id_key), "stamina", float(info.get("stamina", 0)),
				0.0, float(info.get("stamina_max", 1))))
		# Per-instance stat fields (the /mi lazy-fork surface), seeded from THIS instance's values.
		var fields: Dictionary = info.get("fields", {})
		for field in fields:
			if fields[field] == null:
				continue
			detail.add_child(_label(str(field), _GRID_LABEL_W))
			detail.add_child(_instance_spin(str(id_key), str(field), float(fields[field]), 0.0, 999.0))


## `minimum`/`maximum` are the caller's HINT, used only for the two fields that have no entry in the
## monster clamp table (a live instance's hp and stamina, which are per-instance state rather than authored
## MonsterType fields). Everything else derives from the host table — see _apply_clamp.
func _instance_spin(id_key: String, field: String, current: float, minimum: float, maximum: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.custom_minimum_size = Vector2(_GRID_SPIN_W, 0)
	if GameManager.DEV_MONSTER_CLAMPS.has(field):
		_apply_clamp(spin, field, GameManager.DEV_MONSTER_CLAMPS, GameManager.DEV_MONSTER_INT_FIELDS)
	else:
		spin.min_value = minimum
		spin.max_value = maximum
		spin.step = 0.5 if field.ends_with("_beats") else 1.0
	spin.set_value_no_signal(current)
	var key := "mi:%s:%s" % [id_key, field]
	spin.value_changed.connect(func(value: float):
		if not _painting:
			_queue(key, "mi", [id_key, field, str(value)]))
	return spin
