extends CanvasLayer

## Docked HUD in the reclaimed letterbox margins (v0.12.0). The world renders into a 640×360 base
## viewport that the engine integer-scales into the window; with stretch/aspect="expand" the canvas
## now covers the WHOLE window, so the former black letterbox becomes drawable surface at the edges.
## This CanvasLayer (layer 5 — above the world, below the hurt vignette at 10) draws
## FOUR OPAQUE BANDS over that reclaimed area (left column, right column, top band, bottom band),
## leaving a 640×360 hole — the WorldFrame — through which the world shows at its unchanged pixel scale.
##
## LAYOUT: on `resized` (and once at ready) it reads the live canvas size in base px, centres the
## 640×360 WorldFrame in it (rounded to whole base px so the bands' inner edges are flush, no seam),
## and positions the four bands around it. All rects derive from the ONE WorldFrame rect, so they can
## never drift apart. main.gd wires the two external consumers — the DebugOverlay F3 label
## (world_frame_changed) and the tactical border's visibility (get_tactical_border).
##
## SCALE POLICY: the engine auto-picks the largest integer scale that fits. At a 1080p window that is
## 3× with ZERO margin — no HUD room — so this steps the factor down one (via content_scale_factor,
## which MULTIPLIES the auto factor; the retained integer stretch snaps the product) whenever the side
## margins would fall below the right column's minimum. It never steps below 1×; if even 1× is too
## tight (tiny dev windows) the side columns HIDE and the world runs full-bleed as before.
##
## COMPONENT SHAPE: main.gd owns the events and fans them out to this HUD (note_attack / note_died /
## on_class_changed / on_weapon_swap / remove_frame); the HUD owns the party-frame nodes and the
## client-side HP mirror. It is HANDED the $Players container (set_players) and mirrors spawn/despawn
## off it — it never climbs the tree. Presentation only; nothing here is adjudication truth.

## The base virtual viewport — the WorldFrame is exactly this. Read from the project's
## display/window/size setting (not a hardcoded 640×360) so the frame can never drift from the real
## base viewport if a designer retunes it. Static vars: resolved once at class load, FRAME_SIZE follows.
static var BASE_W: float = float(ProjectSettings.get_setting("display/window/size/viewport_width"))
static var BASE_H: float = float(ProjectSettings.get_setting("display/window/size/viewport_height"))
static var FRAME_SIZE: Vector2 = Vector2(BASE_W, BASE_H)

## The right column's minimum inner content is 5 × 16px inventory slots + gaps + panel padding ≈ 96;
## 104 base px gives that headroom. The scale policy guarantees each side margin is at least this wide
## (or, if it cannot even at 1×, hides the columns). Also the floor the layout tests for full-bleed.
const RIGHT_COL_MIN_PX := 104.0

## Inventory slot edge (base px) and grid shape (5 wide × 5 tall; the top row is the future hotbar).
const SLOT_PX := 16.0
const INV_COLS := 5
const INV_ROWS := 5

## The shared class atlas (assets/32rogues/rogues.png), by uid per CLAUDE.md — same source Player skins from.
const ROGUES_ATLAS: Texture2D = preload("uid://djrojs1kpsyss")

## Party-frame component instanced per roster member (brand-new scene → path preload, uid comes later).
const PARTY_FRAME: PackedScene = preload("res://ui/hud/party_frame.tscn")

## Emitted each layout pass with the current WorldFrame rect (base px). main.gd wires the one external
## consumer (the DebugOverlay F3 label nudge) and reads world_frame_rect() once so it never sits stale.
signal world_frame_changed(rect: Rect2)

@onready var _root: Control = $Root
@onready var _left_column: Panel = $Root/LeftColumn
@onready var _right_column: Panel = $Root/RightColumn
@onready var _top_band: Panel = $Root/TopBand
@onready var _bottom_band: Panel = $Root/BottomBand
@onready var _world_frame: Control = $Root/WorldFrame
@onready var _tactical_border: Control = $Root/WorldFrame/TacticalBorder
@onready var _party_frames: VBoxContainer = $Root/LeftColumn/LeftMargin/LeftVBox/PartyFrames
@onready var _log_slot: Control = $Root/LeftColumn/LeftMargin/LeftVBox/LogSlot
@onready var _minimap_slot: PanelContainer = $Root/RightColumn/RightMargin/RightVBox/MinimapSlot
@onready var _char_info: PanelContainer = $Root/RightColumn/RightMargin/RightVBox/CharInfo
@onready var _equipment: PanelContainer = $Root/RightColumn/RightMargin/RightVBox/Equipment
@onready var _inventory: PanelContainer = $Root/RightColumn/RightMargin/RightVBox/Inventory

# The $Players container, handed by main.gd (set_players). Never a get_parent() climb.
var _players: Node2D = null
# entity_id -> PartyFrame node, the live roster of frames.
var _frames: Dictionary = {}
# The last WorldFrame rect, so a late-wired consumer can read it without waiting for the next resize.
var _world_frame_rect: Rect2 = Rect2(Vector2.ZERO, FRAME_SIZE)

# Own-player character panel widgets (built in _ready, refreshed by refresh_self on class/weapon change).
var _own_portrait: TextureRect = null
var _own_atlas := AtlasTexture.new()
var _own_class_label: Label = null
var _own_passives_box: VBoxContainer = null
var _own_mainhand_label: Label = null


func _ready() -> void:
	_style_band(_left_column)
	_style_band(_right_column)
	_style_band(_top_band)
	_style_band(_bottom_band)
	_build_minimap()
	_build_char_info()
	_build_equipment()
	_build_inventory()
	# Layout on every canvas resize; the root Control is anchored full-rect so its `resized` tracks the
	# viewport (including the content_scale_factor change the scale policy applies). Deferred once so the
	# first pass runs after the viewport size has settled.
	_root.resized.connect(_relayout)
	_relayout.call_deferred()


## Restore the window's content scale factor on the way out (session end → return to menu). The scale
## policy multiplies content_scale_factor to step the integer stretch down one notch for HUD margins; that
## write PERSISTS on the shared Window, so without this the menu would render one integer scale smaller
## than intended on step-down geometries (e.g. a maximized 1920×1200 or 4K window). Reset to 1.0 so the
## menu (and any next scene) starts from a clean, un-multiplied factor.
func _exit_tree() -> void:
	get_window().content_scale_factor = 1.0


# ── Public methods (wired by main.gd) ─────────────────────────────────────────

## Hand the HUD the $Players container. It builds a frame per existing player and mirrors spawn/despawn
## off the container's child hooks thereafter (the component is GIVEN the node, it does not climb to it).
func set_players(players: Node2D) -> void:
	_players = players
	for child in _players.get_children():
		_add_frame(child)
	_players.child_entered_tree.connect(_add_frame)
	_players.child_exiting_tree.connect(_on_player_exiting)


## The left column's log slot (the container the GameLog Panel docks into). The HUD OWNS this container;
## main.gd hands it to _game_log.dock_into() so the log reparents its own Panel here — the HUD never
## reaches into the log's node tree (component convention). Called once at HUD init by main.gd.
func get_log_slot() -> Control:
	return _log_slot


## The tactical border Control (v0.12.0 — now a WorldFrame child so it frames the play area, not the
## window). main.gd holds this reference and tweens its modulate on pace flips, exactly as before.
func get_tactical_border() -> Control:
	return _tactical_border


## The current WorldFrame rect (base px), so main.gd can seed the F3-label consumer immediately after
## connecting world_frame_changed (never a stale/zero rect from _ready ordering).
func world_frame_rect() -> Rect2:
	return _world_frame_rect


## A player-target attack event landed (fanned out by main.gd): mirror the running HP into that player's
## frame. Non-players (negative ids) have no frame — a silent no-op. Pure presentation off the event.
func note_attack(target_id: int, hp_after: int, target_max: int) -> void:
	var frame := _frames.get(target_id) as PartyFrame
	if frame != null:
		frame.set_hp(hp_after, target_max)


## A player died (fanned out by main.gd): grey the frame "DEAD". It persists greyed so the party sees a
## downed teammate; a respawn re-binds it (via child_entered_tree), a disconnect removes it.
func note_died(entity_id: int) -> void:
	var frame := _frames.get(entity_id) as PartyFrame
	if frame != null:
		frame.mark_dead()


## A player's class changed (fanned out by main.gd): repaint that frame's portrait, and if it is our own
## player also refresh the character-info panel.
func on_class_changed(entity_id: int) -> void:
	var frame := _frames.get(entity_id) as PartyFrame
	if frame != null:
		frame.refresh_portrait()
	if entity_id == multiplayer.get_unique_id():
		refresh_self()


## A player's weapon swapped (fanned out by main.gd): if it is our own player, refresh the equipment panel.
func on_weapon_swap(entity_id: int) -> void:
	if entity_id == multiplayer.get_unique_id():
		refresh_self()


## A peer genuinely departed (transport disconnect, fanned out by main.gd's _on_peer_departed): remove
## its frame. This is the ONLY removal path — a death keeps the greyed frame; a disconnect clears it.
func remove_frame(entity_id: int) -> void:
	var frame := _frames.get(entity_id) as PartyFrame
	if frame != null:
		_frames.erase(entity_id)
		frame.queue_free()


## Refresh the own-player character + equipment panels from the local Player node (class portrait, class
## name, passive list, main-hand weapon). A no-op until our player exists; called when it spawns and on
## our own class/weapon changes.
func refresh_self() -> void:
	if _players == null:
		return
	var me := _players.get_node_or_null(str(multiplayer.get_unique_id())) as Player
	if me == null:
		return
	if me.player_class != null:
		_own_atlas.region = WorldGrid.atlas_region(me.player_class.atlas_coords)
		# A real class region is now bound — reveal the portrait (hidden at build until this first apply).
		_own_portrait.visible = true
		_own_class_label.text = me.player_class.display_name
		_refresh_passives(me.player_class)
	_own_mainhand_label.text = me.equipped_weapon.display_name if me.equipped_weapon != null else "—"


# ── Private: party frames ─────────────────────────────────────────────────────

## Add (or re-bind, on respawn) a frame for a player node entering $Players. Re-binding an existing frame
## covers the F5 reset / respawn re-seed: entity ids are peer ids, so a fresh node reuses the id.
func _add_frame(node: Node) -> void:
	if not (node is Player):
		return
	var player := node as Player
	var id := player.entity_id
	var frame := _frames.get(id) as PartyFrame
	if frame == null:
		frame = PARTY_FRAME.instantiate() as PartyFrame
		_party_frames.add_child(frame)
		_frames[id] = frame
	# child_entered_tree fires BEFORE the player's _ready (which seeds player_class from the roster), so
	# defer the content bind — by the deferred flush _ready has run and the class/portrait read is valid.
	_bind_frame.call_deferred(frame, player)


## Deferred bind (see _add_frame): the player has finished _ready, so its class/HP are seeded. Guarded
## against a node freed in the meantime (an instant kill between enter and the deferred flush).
func _bind_frame(frame: PartyFrame, player: Player) -> void:
	if not is_instance_valid(frame) or not is_instance_valid(player):
		return
	var is_own := player.entity_id == multiplayer.get_unique_id()
	frame.bind(player, is_own)
	frame.set_hp(player.max_hp, player.max_hp)
	if is_own:
		refresh_self()


## A player node is leaving $Players. Deaths despawn the node too, so this fires on death AND disconnect
## AND F5 reset — we CANNOT tell them apart here, so we grey the frame and KEEP it. Genuine removal is
## remove_frame (disconnect, fanned out from transport truth); a respawn re-binds via _add_frame.
func _on_player_exiting(node: Node) -> void:
	if not (node is Player):
		return
	var frame := _frames.get((node as Player).entity_id) as PartyFrame
	if frame != null:
		frame.mark_dead()


# ── Private: layout ───────────────────────────────────────────────────────────

## The one layout pass. First settles the scale policy (which, if it changes content_scale_factor,
## re-fires `resized` and we bail — the re-fired pass finds the settled factor and proceeds). Then
## centres the WorldFrame and positions the four bands from that single rect.
func _relayout() -> void:
	# Settle the scale policy, then ALWAYS lay out with the canvas as it is right now. If the policy
	# just changed the factor, this pass uses the pre-change canvas (stale ≤1 frame) and we schedule
	# EXACTLY ONE next-frame re-run: empirically (4.7.1) neither the root Control's `resized` nor any
	# other signal fires when content_scale_factor changes the canvas, so nothing re-runs us otherwise —
	# and a same-flush call_deferred is processed in the SAME MessageQueue flush (the unbounded-queue
	# crash the first harness runs hit). process_frame is next-frame by definition and the one-shot +
	# the policy's applied-factor guard make the re-run bounded: it finds the factor applied, lays out
	# with the settled canvas, done.
	if _apply_scale_policy() and not get_tree().process_frame.is_connected(_relayout):
		get_tree().process_frame.connect(_relayout, CONNECT_ONE_SHOT)
	var canvas := get_viewport().get_visible_rect().size
	var frame_pos := ((canvas - FRAME_SIZE) * 0.5).round()
	var frame := Rect2(frame_pos, FRAME_SIZE)
	var left_w := frame.position.x
	var right_w := canvas.x - frame.end.x
	var columns_ok := left_w >= RIGHT_COL_MIN_PX and right_w >= RIGHT_COL_MIN_PX
	_left_column.visible = columns_ok
	_right_column.visible = columns_ok
	_top_band.visible = columns_ok
	_bottom_band.visible = columns_ok
	if columns_ok:
		_place(_left_column, Vector2.ZERO, Vector2(left_w, canvas.y))
		_place(_right_column, Vector2(frame.end.x, 0.0), Vector2(right_w, canvas.y))
		_place(_top_band, Vector2(frame.position.x, 0.0), Vector2(FRAME_SIZE.x, frame.position.y))
		_place(_bottom_band, Vector2(frame.position.x, frame.end.y),
			Vector2(FRAME_SIZE.x, canvas.y - frame.end.y))
		# Keep the minimap a stable square: 96 base px, or the column's inner width if narrower.
		var inner := right_w - 2.0 * 3.0
		var side := clampf(minf(96.0, inner), 0.0, 96.0)
		_minimap_slot.custom_minimum_size = Vector2(side, side)
	else:
		# Even 1× can't give the columns room — full-bleed: the WorldFrame is the whole canvas and the
		# tactical border frames the window, exactly as pre-HUD. No panels overlap the world. NOTE: the
		# docked log Panel lives in the (now-hidden) left column, so the log is NOT visible in this
		# fallback — accepted as dev-only reachability (sub-848px windows; a real session is maximized).
		frame = Rect2(Vector2.ZERO, canvas)
	_place(_world_frame, frame.position, frame.size)
	_world_frame_rect = frame
	world_frame_changed.emit(frame)


## Apply the runtime scale policy. Returns true if it CHANGED content_scale_factor (a `resized` will
## re-fire and re-run _relayout; the caller bails). The guard compares SNAPPED effective factors, so a
## re-fired resize recomputes the same target and no-ops — no loop.
func _apply_scale_policy() -> bool:
	var win := Vector2(get_window().size)
	# The engine's auto scale under aspect=expand is the FRACTIONAL best-fit (min of the per-axis
	# ratios) — EMPIRICAL 4.7.1 finding (probe: 2552×1427 → canvas 643×360 = 3.964×, not 3×):
	# scale_mode="integer" is INERT under expand despite the Window.xml reading; the snap only applies
	# to the keep-family aspects. So THIS policy is the integer snapper: dividing target by the
	# fractional auto makes the engine's product land exactly on the integer (auto_f × target/auto_f).
	var auto_f := maxf(1.0, minf(win.x / BASE_W, win.y / BASE_H))
	var auto := maxi(1, int(floorf(auto_f)))
	# Step down from auto until each side margin clears the right-column minimum, but never below 1×.
	var target := auto
	while target > 1 and _side_margin(win.x, target) < RIGHT_COL_MIN_PX:
		target -= 1
	# Guard on the FACTOR PROPERTY we write, never on the canvas: a content_scale_factor assignment does
	# NOT update get_visible_rect() synchronously (the canvas recomputes at the next frame), so a canvas-
	# derived "current" stays stale through a whole deferred flush — the settle-loop that crashed the
	# first harness run (each re-run saw target != current, returned true, and re-queued itself into the
	# active deferred flush until the engine died). Comparing desired vs applied factor is loop-proof:
	# once written, every re-run sees it applied and proceeds; the eventual `resized` corrects layout.
	var desired := float(target) / auto_f
	if is_equal_approx(get_window().content_scale_factor, desired):
		return false
	# content_scale_factor MULTIPLIES the engine's fractional auto fit; target/auto_f makes the product
	# exactly the integer `target`, restoring whole-pixel world scaling under expand (see note above).
	get_window().content_scale_factor = desired
	return true


## Each side margin (base px) the WorldFrame would leave at a given integer scale factor.
func _side_margin(win_w: float, factor: int) -> float:
	return (win_w / float(factor) - BASE_W) / 2.0


## Absolute-position a band/frame Control (top-left anchored) at pos with size, in base px.
func _place(c: Control, pos: Vector2, size: Vector2) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	c.position = pos
	c.size = size


# ── Private: styled content builders ──────────────────────────────────────────

## The opaque dark band fill — matches the backdrop so the margins read as one coherent frame. OPAQUE
## (alpha 1) because these cover the world in the reclaimed area (no mask — the WorldFrame is the hole).
func _style_band(p: Panel) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.13, 1.0)
	p.add_theme_stylebox_override("panel", sb)


## A sub-panel fill (char info / equipment / inventory / minimap) — the game_log's dark translucent look:
## a slightly lifted dark with a subtle cool border, so the sockets read as inset without asset chrome.
func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.145, 0.145, 0.185, 1.0)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.32, 0.32, 0.40, 0.55)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 3.0
	sb.content_margin_top = 3.0
	sb.content_margin_right = 3.0
	sb.content_margin_bottom = 3.0
	return sb


## A reserved-socket fill. `hotbar` gives the top inventory row its distinct brighter border (the future
## 1-5 hotbar — styling only, no key wiring, no item system this chunk).
func _slot_style(hotbar: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.16, 0.21, 1.0) if not hotbar else Color(0.19, 0.18, 0.13, 1.0)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.34, 0.34, 0.42, 0.6) if not hotbar else Color(0.85, 0.72, 0.32, 0.9)
	return sb


func _build_minimap() -> void:
	_minimap_slot.add_theme_stylebox_override("panel", _panel_style())


## Character-info panel: class portrait + class name + passive list (own player only). No section header
## — the layout speaks for itself. Portrait windows the class sprite out of the rogues atlas.
func _build_char_info() -> void:
	_char_info.add_theme_stylebox_override("panel", _panel_style())
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 2)
	_char_info.add_child(vbox)
	_own_portrait = TextureRect.new()
	_own_portrait.custom_minimum_size = Vector2(24, 24)
	_own_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_own_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_own_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_own_atlas.atlas = ROGUES_ATLAS
	# Seed a VALID initial region + EXPAND_IGNORE_SIZE: a zero-size AtlasTexture region (Rect2(0,0,0,0))
	# draws the ENTIRE sheet (documented fallback), which the default expand would blow the panel out to
	# full-sheet size. A single-tile region + ignore-size means a bad/unbound texture can never resize the
	# panel. The portrait stays HIDDEN until the first refresh_self applies our real class region.
	_own_atlas.region = WorldGrid.atlas_region(Vector2i.ZERO)
	_own_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_own_portrait.visible = false
	_own_portrait.texture = _own_atlas
	vbox.add_child(_own_portrait)
	_own_class_label = _make_label(7)
	vbox.add_child(_own_class_label)
	_own_passives_box = VBoxContainer.new()
	_own_passives_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_own_passives_box.add_theme_constant_override("separation", 0)
	vbox.add_child(_own_passives_box)


## Equipment panel: main-hand shows the real equipped weapon name; the other sockets are reserved empties.
func _build_equipment() -> void:
	_equipment.add_theme_stylebox_override("panel", _panel_style())
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 2)
	_equipment.add_child(vbox)
	_own_mainhand_label = _make_label(6)
	_own_mainhand_label.text = "—"
	vbox.add_child(_own_mainhand_label)
	# Reserved sockets (helm / chest / off-hand / …) — empty, no labels, style only.
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 2)
	vbox.add_child(row)
	for i in 4:
		var socket := Panel.new()
		socket.custom_minimum_size = Vector2(SLOT_PX, SLOT_PX)
		socket.mouse_filter = Control.MOUSE_FILTER_IGNORE
		socket.add_theme_stylebox_override("panel", _slot_style(false))
		row.add_child(socket)


## Inventory panel: a pinned 5×5 grid of 16px reserved slots. The TOP ROW is styled distinct (brighter
## border + faint 1-5 keycap numerals) as the future hotbar — styling only; the slot→hotbar mapping is TBD.
func _build_inventory() -> void:
	_inventory.add_theme_stylebox_override("panel", _panel_style())
	var grid := GridContainer.new()
	grid.columns = INV_COLS
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	_inventory.add_child(grid)
	for i in INV_COLS * INV_ROWS:
		var hotbar := i < INV_COLS
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(SLOT_PX, SLOT_PX)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_theme_stylebox_override("panel", _slot_style(hotbar))
		grid.add_child(slot)
		if hotbar:
			# Faint keycap numeral, top-left of the hotbar slot — a style tell, not a key binding.
			var key := Label.new()
			key.text = str(i + 1)
			key.add_theme_font_size_override("font_size", 5)
			key.add_theme_color_override("font_color", Color(0.85, 0.72, 0.32, 0.8))
			key.mouse_filter = Control.MOUSE_FILTER_IGNORE
			key.set_anchors_preset(Control.PRESET_TOP_LEFT)
			key.position = Vector2(1, -1)
			slot.add_child(key)


## Rebuild the own-player passive list from its class (one label per passive that has a display name).
func _refresh_passives(player_class: PlayerClass) -> void:
	for child in _own_passives_box.get_children():
		child.queue_free()
	for passive in player_class.passives:
		if passive == null or passive.display_name.is_empty():
			continue
		var label := _make_label(6)
		label.text = "• %s" % passive.display_name
		label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.95, 0.9))
		_own_passives_box.add_child(label)


## A non-interactive HUD label at the given base font size (mouse-transparent per the HUD discipline).
func _make_label(font_size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
