extends CanvasLayer

## Fixed world rect HUD (DESIGN #10). Every player sees the SAME 42×29-tile world rect (672×464 base px) —
## how much world you see no longer depends on your window (v0.13.0's "world bleeds to three edges" is
## walked back: bleed and equal-vision are mutually exclusive, and fairness wins). The world + the 180px HUD
## column form an 852×464 CONTENT BLOCK; each window picks the LARGEST INTEGER scale that fits that block,
## centres it on the pixel grid, and paints ALL leftover space as a MARGIN FRAME in the column's backdrop
## colour — no black bars, no extra map. The WorldFrame — the rect the vignette, tactical border and F3
## label scope to — is that fixed 672×464 rect at the block's left; the column sits on its right edge. The
## camera recenters the avatar in the world rect (not the window) via main.gd's camera-offset write.
##
## SUB-FLOOR CASE (dev windows / extreme DPI only — a real session is maximized): when the block cannot fit
## even at 1× on either axis, the column HIDES and the world CLAMPS PER AXIS to a strict SUBSET of the rect
## (never MORE than 42×29 tiles on either axis — DESIGN #10's fairness invariant), still centred, margin
## frame still covering the leftover. This replaces v0.13.0's full-bleed fallback, which could leak extra
## vertical tiles in a narrow-tall window.
##
## SCALE POLICY (unchanged machinery, v3 geometry): under aspect=expand the engine auto-picks a FRACTIONAL
## best-fit stretch (scale_mode="integer" is INERT under expand — EMPIRICAL 4.7.1); this policy divides the
## chosen INTEGER target by that fractional auto (via content_scale_factor, which MULTIPLIES it) so the
## engine's product lands on the integer. Target = the largest s ≥ 1 with 852·s ≤ win.x and 464·s ≤ win.y.
## It never steps below 1×; sub-1×-fit windows take the per-axis clamp above.
##
## COMPONENT SHAPE: main.gd owns the events and fans them out (note_attack / note_died / on_class_changed /
## on_weapon_swap / remove_frame); the HUD is HANDED the $Players container (set_players) and mirrors OUR
## OWN player's spawn/despawn off it (for the char-info HP bar seed) — it never climbs the tree. Party
## frames are OFF this iteration (party_frame.gd/.tscn stay on disk, dormant); note_attack/note_died now
## feed the own-player HP bar in the char-info section. Presentation only; nothing here is adjudication truth.

## The base virtual viewport width/height (base px, the project's display size — 640×360 today). These now
## feed ONLY the engine's fractional auto-fit denominator in _apply_scale_policy (auto_f, the stretch
## aspect=expand actually applies); the world area the player sees is the fixed WORLD_RECT below, no longer
## derived from these.
static var BASE_W: float = float(ProjectSettings.get_setting("display/window/size/viewport_width"))
static var BASE_H: float = float(ProjectSettings.get_setting("display/window/size/viewport_height"))

## The FIXED world rect every player sees (DESIGN #10): 42×29 tiles. The TILE COUNT is the definition; the
## 672×464 base px is that count × 16 base px/tile (42·16 = 672, 29·16 = 464), sized to today's
## 1440p-maximized view so that setup stays visually identical. No window/resolution/DPI ever shows more.
const WORLD_TILES := Vector2i(42, 29)
const WORLD_RECT := Vector2(672.0, 464.0)

## Right-column width (base px): 5 × 32px slots (160) + 4 × 2px gaps (8) = 168, + 2 × 3px RightMargin (6)
## + border headroom. INDEPENDENT of the world rect — its own constant, unchanged. Widening it later lowers
## the fit-time scale some windows get (same tiles, smaller magnification), never the tile count.
const RIGHT_COL_W := 180.0

## The DERIVED content block (base px): world rect + column side by side = 852×464. The scale policy fits
## the LARGEST integer multiple of THIS block, and the margin frame covers everything outside it. Derived,
## never a literal — retuning WORLD_RECT or RIGHT_COL_W reshapes it automatically.
const CONTENT_BLOCK := WORLD_RECT + Vector2(RIGHT_COL_W, 0.0)

## Equipment/inventory slot edge (base px) and inventory grid shape (5 wide × 4 tall; the top row is the
## future hotbar). Doubled from v0.12.0's 16px for the airier column.
const SLOT_PX := 32.0
const INV_COLS := 5
const INV_ROWS := 4

## The minimap slot's reserved square (base px) — M4b placeholder, rebudgeted down from 96 for the doubled
## slots below it.
const MINIMAP_PX := 80.0

## The items.png sheet (32px tiles), by uid per CLAUDE.md — the SAME texture weapon_rig regions from. The
## primary-hand socket windows the equipped weapon's region out of it (live icon).
const ITEMS_TEX: Texture2D = preload("uid://5r3hjjukcluj")

## HP-bar endpoints (transplanted from party_frame.gd): full = green, empty = red, lerped by the fraction.
const _BAR_FULL := Color(0.30, 0.75, 0.30, 1.0)
const _BAR_EMPTY := Color(0.80, 0.20, 0.20, 1.0)

## The ONE backdrop colour for all HUD chrome — the right column's fill AND the margin bands. Single
## source so the column and the frame can never drift apart into a visible seam.
const _BACKDROP := Color(0.10, 0.10, 0.13, 1.0)

## Emitted each layout pass with the current WorldFrame rect (base px). main.gd wires the external consumers
## (DebugOverlay F3 label + the hurt-vignette scoping) and reads world_frame_rect() once so they never sit stale.
signal world_frame_changed(rect: Rect2)

@onready var _root: Control = $Root
@onready var _right_column: Panel = $Root/RightColumn
@onready var _world_frame: Control = $Root/WorldFrame
@onready var _tactical_border: Control = $Root/WorldFrame/TacticalBorder
@onready var _minimap_slot: PanelContainer = $Root/RightColumn/RightMargin/RightVBox/MinimapSlot
@onready var _char_info: PanelContainer = $Root/RightColumn/RightMargin/RightVBox/CharInfo
@onready var _equipment: PanelContainer = $Root/RightColumn/RightMargin/RightVBox/Equipment
@onready var _inventory: PanelContainer = $Root/RightColumn/RightMargin/RightVBox/Inventory

# The $Players container, handed by main.gd (set_players). Never a get_parent() climb.
var _players: Node2D = null
# Our own peer id, cached at set_players time (when multiplayer is live). Compared against event ids to
# filter for OUR player — cached rather than queried per-call because `multiplayer` reads null during tree
# teardown (a child_exiting_tree fired at quit would otherwise crash on multiplayer.get_unique_id()).
var _own_id: int = 0
# The last WorldFrame rect, so a late-wired consumer can read it without waiting for the next resize.
var _world_frame_rect: Rect2 = Rect2(Vector2.ZERO, WORLD_RECT)
# The margin-frame bands (left / right / top / bottom ColorRects). Built in _ready BEHIND the column +
# WorldFrame; sized each _relayout pass to opaquely cover all canvas outside the content block (DESIGN #10:
# leftover space is frame, never black bars or extra map). A zero-size band (absent margin) is fine.
var _margin_bands: Array[ColorRect] = []

# Own-player character-panel widgets (built in _ready, refreshed by refresh_self on class/weapon change).
var _own_class_label: Label = null
var _own_passives_box: VBoxContainer = null
# Own-player HP bar (transplanted party-frame mechanics), fed by note_attack/note_died filtered to our id.
var _own_hp_fill: ColorRect = null
var _own_hp_text: Label = null
# Primary-hand weapon icon: an AtlasTexture over ITEMS_TEX, region re-pointed by refresh_self / on_weapon_swap.
var _own_weapon_icon: TextureRect = null
var _own_weapon_atlas := AtlasTexture.new()


func _ready() -> void:
	_build_margin_frame()
	_style_band(_right_column)
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
## policy multiplies content_scale_factor to step the integer stretch down one notch for the column; that
## write PERSISTS on the shared Window, so without this the menu would render one integer scale smaller
## than intended on step-down geometries. Reset to 1.0 so the menu (and any next scene) starts clean.
func _exit_tree() -> void:
	get_window().content_scale_factor = 1.0


# ── Public methods (wired by main.gd) ─────────────────────────────────────────

## Hand the HUD the $Players container. It mirrors OUR OWN player's spawn/despawn off the container's child
## hooks (to seed the char-info HP bar) — the component is GIVEN the node, it does not climb to it. The
## container is independent of the (removed) party-frame UI: only the own-player HP seed rides these hooks now.
func set_players(players: Node2D) -> void:
	_players = players
	_own_id = multiplayer.get_unique_id()
	_players.child_entered_tree.connect(_on_player_entered)
	_players.child_exiting_tree.connect(_on_player_exiting)
	for child in _players.get_children():
		_on_player_entered(child)


## The tactical border Control (now a WorldFrame child so it frames the play area, not the window). main.gd
## holds this reference and tweens its modulate on pace flips, exactly as before.
func get_tactical_border() -> Control:
	return _tactical_border


## The current WorldFrame rect (base px), so main.gd can seed the F3-label + hurt-vignette consumers
## immediately after connecting world_frame_changed (never a stale/zero rect from _ready ordering).
func world_frame_rect() -> Rect2:
	return _world_frame_rect


## A player-target attack event landed (fanned out by main.gd): if it is OUR OWN player, mirror the running
## HP into the char-info bar. Other players / monsters (no own bar) are a silent no-op. Pure presentation.
func note_attack(target_id: int, hp_after: int, target_max: int) -> void:
	if target_id == _own_id:
		_set_own_hp(hp_after, target_max)


## A player died (fanned out by main.gd): if it is OUR OWN player, read the bar "DEAD". A respawn re-seeds
## it (via the $Players child hook); a peer's death is not mirrored (no party frames this iteration).
func note_died(entity_id: int) -> void:
	if entity_id == _own_id:
		_mark_own_dead()


## A player's class changed (fanned out by main.gd): if it is our own player, refresh the char-info panel.
func on_class_changed(entity_id: int) -> void:
	if entity_id == _own_id:
		refresh_self()


## A player's weapon swapped (fanned out by main.gd): if it is our own player, refresh the equipment panel
## (the primary-hand icon flips sword↔dagger with zero new wiring — refresh_self re-points the atlas region).
func on_weapon_swap(entity_id: int) -> void:
	if entity_id == _own_id:
		refresh_self()


## Dormant this iteration (v0.13.0): party frames are OFF, so there is no frame to remove — the own-player
## HP mirror is not a frame. Kept as a stable no-op so main.gd's peer-departed fan-out has a target; re-
## enabling party frames (party_frame.gd/.tscn are still on disk) restores per-peer frame removal here.
func remove_frame(_entity_id: int) -> void:
	pass


## Refresh the own-player char + equipment panels from the local Player node (class name, passive list,
## primary-hand weapon icon). A no-op until our player exists; called when it spawns and on our own
## class/weapon changes. Does NOT touch the HP bar — the bar is seeded separately at (re)spawn so a
## weapon swap or class change never resets the running HP to full (see _seed_self).
func refresh_self() -> void:
	if _players == null:
		return
	var me := _players.get_node_or_null(str(_own_id)) as Player
	if me == null:
		return
	if me.player_class != null:
		_own_class_label.text = me.player_class.display_name
		_refresh_passives(me.player_class)
	_set_weapon_icon(me.equipped_weapon)


# ── Private: own-player spawn hooks (HP-bar seed) ─────────────────────────────

## Our own player node (re)entered $Players — seed the char-info panel + HP bar. Deferred because the child
## hook fires BEFORE the player's _ready (which seeds player_class from the roster); by the flush _ready has
## run. Non-own players are ignored (no party frames this iteration).
func _on_player_entered(node: Node) -> void:
	if not (node is Player):
		return
	if (node as Player).entity_id != _own_id:
		return
	_seed_self.call_deferred()


## Deferred seed (see _on_player_entered): the own player has finished _ready, so its class/HP are valid.
## Guarded against a node freed in the meantime (an instant kill between enter and the deferred flush).
## max_hp is an Entity @export (valid even pre-_ready); seed the bar full at (re)spawn — the ONLY seed-to-
## full point, so live combat HP (note_attack) and respawn are the only things that ever move it.
func _seed_self() -> void:
	if _players == null:
		return
	var me := _players.get_node_or_null(str(_own_id)) as Player
	if me == null:
		return
	refresh_self()
	_set_own_hp(me.max_hp, me.max_hp)


## Our own player node is leaving $Players (death / disconnect / F5 reset — indistinguishable here): read
## the bar DEAD. A respawn re-seeds it via _on_player_entered; note_died also covers the death path.
func _on_player_exiting(node: Node) -> void:
	if not (node is Player):
		return
	if (node as Player).entity_id == _own_id:
		_mark_own_dead()


# ── Private: own HP bar (transplanted party-frame mechanics) ──────────────────

## Update the own HP bar + text from an attack event's running HP (pushed by note_attack, never queried).
func _set_own_hp(cur: int, max_hp: int) -> void:
	var frac := clampf(float(cur) / float(maxi(max_hp, 1)), 0.0, 1.0)
	_own_hp_fill.anchor_right = frac
	_own_hp_fill.offset_right = 0.0
	_own_hp_fill.color = _BAR_EMPTY.lerp(_BAR_FULL, frac)
	_own_hp_text.text = "%d/%d" % [cur, max_hp]


## Empty the own HP bar and read "DEAD" (from note_died / own-node exit). A respawn re-seeds it full.
func _mark_own_dead() -> void:
	_own_hp_fill.anchor_right = 0.0
	_own_hp_fill.offset_right = 0.0
	_own_hp_text.text = "DEAD"


# ── Private: layout ───────────────────────────────────────────────────────────

## The one layout pass. First settles the scale policy (which, if it changes content_scale_factor, re-fires
## `resized` and we bail — the re-fired pass finds the settled factor and proceeds). Then centres the fixed
## 852×464 content block on the pixel grid, places the fixed 672×464 WorldFrame at its left and the column
## on its right edge, and covers all leftover canvas with the margin frame.
func _relayout() -> void:
	# Settle the scale policy, then ALWAYS lay out with the canvas as it is right now. If the policy just
	# changed the factor, this pass uses the pre-change canvas (stale ≤1 frame) and we schedule EXACTLY ONE
	# next-frame re-run: empirically (4.7.1) neither the root Control's `resized` nor any other signal fires
	# when content_scale_factor changes the canvas, so nothing re-runs us otherwise — and a same-flush
	# call_deferred is processed in the SAME MessageQueue flush (the unbounded-queue crash the first harness
	# runs hit). process_frame is next-frame by definition and the one-shot + the policy's applied-factor
	# guard make the re-run bounded: it finds the factor applied, lays out with the settled canvas, done.
	if _apply_scale_policy() and not get_tree().process_frame.is_connected(_relayout):
		get_tree().process_frame.connect(_relayout, CONNECT_ONE_SHOT)
	var canvas := get_viewport().get_visible_rect().size
	# `content_origin` / `block` = the top-left and size of the region the margin frame frames (block = the
	# full 852×464 block in the normal case, the clamped world in the sub-floor case). `frame` = the emitted
	# WorldFrame rect (the world portion only).
	var content_origin: Vector2
	var block: Vector2
	var frame: Rect2
	# Half-base-px tolerance on the fit test: the canvas is win / (auto_f × content_scale_factor), and that
	# float product can land a hair UNDER the exact integer (empirical, first v0.14.0 harness run: a
	# 2560×1392 window — the flagship 1440p-maximized geometry — yielded canvas.y = 463.9999…, which a
	# strict >= 464 read as sub-floor and HID the column). Half a base px can never admit a window that is
	# genuinely a pixel short.
	if canvas.x >= CONTENT_BLOCK.x - 0.5 and canvas.y >= CONTENT_BLOCK.y - 0.5:
		# Normal case: the whole 852×464 block fits. Centre it, floored to whole base px (pixel-grid
		# alignment), put the fixed world rect at its left and the column on the world's right edge. The
		# zero-clamp pairs with the tolerance above: in the epsilon case (canvas - block) is a tiny negative,
		# which floor() would turn into a whole -1 — clamp so the block sits at 0 and overflows by the
		# invisible sub-pixel instead of shifting a full pixel off-canvas.
		block = CONTENT_BLOCK
		content_origin = ((canvas - block) / 2.0).floor()
		content_origin = Vector2(maxf(content_origin.x, 0.0), maxf(content_origin.y, 0.0))
		frame = Rect2(content_origin, WORLD_RECT)
		_right_column.visible = true
		_place(_right_column, content_origin + Vector2(WORLD_RECT.x, 0.0), Vector2(RIGHT_COL_W, WORLD_RECT.y))
	else:
		# Sub-floor case (dev windows / extreme DPI only): the block can't fit at 1× on one or both axes.
		# Hide the column and CLAMP the world PER AXIS to a strict subset of the rect — never more than the
		# rect on either axis (DESIGN #10's fairness invariant, vs the old full-bleed that leaked tiles in a
		# narrow-tall window) — then centre it, floored.
		_right_column.visible = false
		block = Vector2(minf(canvas.x, WORLD_RECT.x), minf(canvas.y, WORLD_RECT.y))
		content_origin = ((canvas - block) / 2.0).floor()
		frame = Rect2(content_origin, block)
	_place(_world_frame, frame.position, frame.size)
	_layout_margin_frame(canvas, content_origin, block)
	_world_frame_rect = frame
	world_frame_changed.emit(frame)


## Size the four margin bands to cover every part of `canvas` OUTSIDE the content block (top-left
## `content_origin`, size `block`) with the backdrop colour. Left/right run the full canvas height; top/
## bottom span only the block's width between them (so they never double-cover the corners). Negative widths
## are clamped to zero (an absent margin is a zero-size band, harmless). Also covers the sub-floor margins.
func _layout_margin_frame(canvas: Vector2, content_origin: Vector2, block: Vector2) -> void:
	var right_x := content_origin.x + block.x
	var bottom_y := content_origin.y + block.y
	_place(_margin_bands[0], Vector2.ZERO, Vector2(maxf(0.0, content_origin.x), canvas.y))                       # left
	_place(_margin_bands[1], Vector2(right_x, 0.0), Vector2(maxf(0.0, canvas.x - right_x), canvas.y))            # right
	_place(_margin_bands[2], Vector2(content_origin.x, 0.0), Vector2(block.x, maxf(0.0, content_origin.y)))      # top
	_place(_margin_bands[3], Vector2(content_origin.x, bottom_y), Vector2(block.x, maxf(0.0, canvas.y - bottom_y)))  # bottom


## Apply the runtime scale policy. Returns true if it CHANGED content_scale_factor (a `resized` will re-fire
## and re-run _relayout; the caller bails). The guard compares APPLIED effective factors, so a re-fired
## resize recomputes the same target and no-ops — no loop.
func _apply_scale_policy() -> bool:
	var win := Vector2(get_window().size)
	# The engine's auto scale under aspect=expand is the FRACTIONAL best-fit (min of the per-axis ratios) —
	# EMPIRICAL 4.7.1 finding: scale_mode="integer" is INERT under expand. So THIS policy is the integer
	# snapper: dividing target by the fractional auto makes the engine's product land on the integer.
	var auto_f := maxf(1.0, minf(win.x / BASE_W, win.y / BASE_H))
	# Target = the LARGEST integer s ≥ 1 with 852·s ≤ win.x AND 464·s ≤ win.y — the largest integer scale
	# at which the whole content block fits the window (per axis; min of the two). Never below 1× (a smaller
	# window takes _relayout's per-axis sub-floor clamp). Computed from the derived block, not literals.
	var target := maxi(1, mini(floori(win.x / CONTENT_BLOCK.x), floori(win.y / CONTENT_BLOCK.y)))
	# Guard on the FACTOR PROPERTY we write, never on the canvas: a content_scale_factor assignment does NOT
	# update get_visible_rect() synchronously, so a canvas-derived "current" stays stale through a whole
	# deferred flush — the settle-loop that crashed the first harness run. Comparing desired vs applied
	# factor is loop-proof: once written, every re-run sees it applied and proceeds.
	var desired := float(target) / auto_f
	if is_equal_approx(get_window().content_scale_factor, desired):
		return false
	get_window().content_scale_factor = desired
	return true


## Absolute-position a band/frame Control (top-left anchored) at pos with size, in base px.
func _place(c: Control, pos: Vector2, size: Vector2) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	c.position = pos
	c.size = size


# ── Private: styled content builders ──────────────────────────────────────────

## Build the four margin bands (left / right / top / bottom) once, as $Root children behind the column and
## WorldFrame. add_child appends them AFTER the two scene nodes (on top), so move each to index 0 to sit them
## BEHIND — the world/column always draw over the frame. Opaque backdrop colour (same as _style_band's fill)
## so the leftover space reads as one coherent frame. Sized each pass by _layout_margin_frame.
func _build_margin_frame() -> void:
	for _i in 4:
		var band := ColorRect.new()
		band.color = _BACKDROP
		band.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(band)
		_root.move_child(band, 0)
		_margin_bands.append(band)


## The ONE opaque column fill — matches the backdrop so the column reads as a coherent frame. OPAQUE
## (alpha 1) because it covers the world in the reclaimed strip (no mask — the WorldFrame is the hole).
func _style_band(p: Panel) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _BACKDROP
	p.add_theme_stylebox_override("panel", sb)


## A transparent section fill: the char/equipment/inventory PanelContainers become plain containers (no
## per-section frame this iteration — padding + the VBox `separation` do the sectioning). StyleBoxEmpty
## keeps them as sizing containers without drawing any chrome.
func _clear_style() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()


## A reserved-socket fill. `accent` gives the hotbar row / hands sockets their distinct brighter border.
func _slot_style(accent: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.16, 0.21, 1.0) if not accent else Color(0.19, 0.18, 0.13, 1.0)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.34, 0.34, 0.42, 0.6) if not accent else Color(0.85, 0.72, 0.32, 0.9)
	return sb


## Minimap slot: an 80×80 reserved square with a slot-style outline (M4b placeholder — no minimap yet).
func _build_minimap() -> void:
	_minimap_slot.add_theme_stylebox_override("panel", _slot_style(false))
	_minimap_slot.custom_minimum_size = Vector2(MINIMAP_PX, MINIMAP_PX)


## Character-info panel (EXPANDS to take the column's spare height; overflow CLIPS via the scene's
## clip_contents so an overgrown passives list never pushes equipment/inventory off the bottom). Content:
## class name + a STATIC "Lvl 1" placeholder + the own HP bar + the passive list. No portrait this iteration.
func _build_char_info() -> void:
	_char_info.add_theme_stylebox_override("panel", _clear_style())
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 3)
	_char_info.add_child(vbox)
	_own_class_label = _make_label(9)
	vbox.add_child(_own_class_label)
	# STATIC placeholder: no leveling system exists yet, so this never changes — a layout stand-in only.
	var level_label := _make_label(7)
	level_label.text = "Lvl 1"
	level_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.95, 0.7))
	vbox.add_child(level_label)
	vbox.add_child(_build_hp_bar())
	_own_passives_box = VBoxContainer.new()
	_own_passives_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_own_passives_box.add_theme_constant_override("separation", 0)
	vbox.add_child(_own_passives_box)


## The own HP bar widget (transplanted party-frame mechanics): a green→red Fill ColorRect over a dark Track,
## driven by anchor_right = fraction, with a centred cur/max Label. Seeded at (re)spawn, moved by note_attack.
func _build_hp_bar() -> Control:
	var bar := Control.new()
	bar.custom_minimum_size = Vector2(0, 11)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var track := ColorRect.new()
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	track.color = Color(0.18, 0.05, 0.05, 1.0)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(track)
	_own_hp_fill = ColorRect.new()
	_own_hp_fill.anchor_bottom = 1.0
	_own_hp_fill.anchor_right = 1.0
	_own_hp_fill.color = _BAR_FULL
	_own_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(_own_hp_fill)
	_own_hp_text = _make_label(7)
	_own_hp_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	_own_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_own_hp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_own_hp_text.text = "—"
	bar.add_child(_own_hp_text)
	return bar


## Equipment panel — 9 sockets at 32px. Hands row [Primary][Offhand] (accent border) is visually separated
## from the armor grid by a 6px spacer. The primary-hand socket shows the real equipped weapon ICON; every
## other socket is empty with a faint name label. No section frame (padding + separation do the sectioning).
func _build_equipment() -> void:
	_equipment.add_theme_stylebox_override("panel", _clear_style())
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 0)
	_equipment.add_child(vbox)
	# Hands row: Primary (weapon icon) + Offhand (faint label), both with the accent border.
	var hands := HBoxContainer.new()
	hands.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hands.add_theme_constant_override("separation", 2)
	vbox.add_child(hands)
	var primary := _make_socket(true, "")
	_own_weapon_icon = TextureRect.new()
	_own_weapon_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_own_weapon_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_own_weapon_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_own_weapon_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_own_weapon_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_own_weapon_atlas.atlas = ITEMS_TEX
	# Seed a VALID single-tile region: a zero-size AtlasTexture region draws the WHOLE sheet (a documented
	# fallback); a single tile + EXPAND_IGNORE_SIZE means a bad/unbound weapon can never blow the socket out.
	# Hidden until refresh_self applies our real weapon region.
	_own_weapon_atlas.region = WorldGrid.atlas_region(Vector2i.ZERO)
	_own_weapon_icon.texture = _own_weapon_atlas
	_own_weapon_icon.visible = false
	primary.add_child(_own_weapon_icon)
	hands.add_child(primary)
	hands.add_child(_make_socket(true, "Off"))
	# 6px spacer before the armor grid (the hands→armor visual separation).
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(spacer)
	# Armor grid (4-wide): 7 labeled sockets + 1 blank filler cell to complete the 2×4 rectangle.
	var grid := GridContainer.new()
	grid.columns = 4
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	vbox.add_child(grid)
	for label_text in ["Head", "Body", "Gloves", "Boots", "Ring", "Ring", "Amul"]:
		grid.add_child(_make_socket(false, label_text))
	grid.add_child(_make_socket(false, ""))  # blank filler cell — completes the 2×4 block


## Inventory panel — a 5×4 grid of 32px reserved slots, pinned at the column BOTTOM (the char-info expand
## pushes it down). The TOP ROW is styled distinct (accent border + faint 1-5 keycaps) as the future hotbar
## — styling only; no key wiring, no item system this chunk. 2px gaps.
func _build_inventory() -> void:
	_inventory.add_theme_stylebox_override("panel", _clear_style())
	var grid := GridContainer.new()
	grid.columns = INV_COLS
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	_inventory.add_child(grid)
	for i in INV_COLS * INV_ROWS:
		var hotbar := i < INV_COLS
		var slot := _make_socket(hotbar, "")
		grid.add_child(slot)
		if hotbar:
			# Faint keycap numeral, top-left of the hotbar slot — a style tell, not a key binding. Font
			# stepped up (5 → 8) for the bigger 32px boxes.
			var key := Label.new()
			key.text = str(i + 1)
			key.add_theme_font_size_override("font_size", 8)
			key.add_theme_color_override("font_color", Color(0.85, 0.72, 0.32, 0.8))
			key.mouse_filter = Control.MOUSE_FILTER_IGNORE
			key.set_anchors_preset(Control.PRESET_TOP_LEFT)
			key.position = Vector2(2, 0)
			slot.add_child(key)


## Rebuild the own-player passive list from its class (one label per passive that has a display name).
func _refresh_passives(player_class: PlayerClass) -> void:
	for child in _own_passives_box.get_children():
		child.queue_free()
	for passive in player_class.passives:
		if passive == null or passive.display_name.is_empty():
			continue
		var label := _make_label(7)
		label.text = "• %s" % passive.display_name
		label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.95, 0.9))
		_own_passives_box.add_child(label)


## Point the primary-hand icon at the equipped weapon's items.png region (the exact weapon_rig pattern).
## A null weapon hides the icon (bare hands). Refreshed by refresh_self, driven on spawn + on_weapon_swap.
func _set_weapon_icon(weapon: WeaponType) -> void:
	if weapon == null:
		_own_weapon_icon.visible = false
		return
	_own_weapon_atlas.region = WorldGrid.atlas_region(weapon.atlas_coords)
	_own_weapon_icon.visible = true


## A 32px reserved socket Panel. `accent` = the brighter hotbar/hands border; a non-empty `label_text`
## draws a faint tiny centred name (empty sockets only — the primary hand carries an icon instead).
func _make_socket(accent: bool, label_text: String) -> Panel:
	var socket := Panel.new()
	socket.custom_minimum_size = Vector2(SLOT_PX, SLOT_PX)
	socket.mouse_filter = Control.MOUSE_FILTER_IGNORE
	socket.add_theme_stylebox_override("panel", _slot_style(accent))
	if not label_text.is_empty():
		var lbl := Label.new()
		lbl.text = label_text
		lbl.add_theme_font_size_override("font_size", 5)
		lbl.add_theme_color_override("font_color", Color(0.72, 0.74, 0.85, 0.35))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
		socket.add_child(lbl)
	return socket


## A non-interactive HUD label at the given base font size (mouse-transparent per the HUD discipline).
func _make_label(font_size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
