extends CanvasLayer

## Full-bleed HUD with bounded-variance scale (DESIGN #10 REVISED 2026-07-22). The world renders FULL-BLEED
## to the window's LEFT, TOP and BOTTOM edges (v0.13.0's look, restored — the v0.14.0 fixed-rect + always-on
## margin frame was rejected: it drew a visible frame on 1080p-class windows). A single opaque RIGHT COLUMN
## overlays the right edge; the WorldFrame — the rect the vignette, tactical border and F3 label scope to —
## is the canvas MINUS that column. The camera recenters the avatar in that rect (not the window) via
## main.gd's camera-offset write, keyed off the emitted rect's centre (unchanged here).
##
## BOUNDED VARIANCE (the fairness knob, DESIGN #10): how much world a window shows still varies with its
## size, but within a TIGHT band instead of the old 2.4× spread. The scale policy picks the integer
## magnification whose canvas width lands NEAREST a canonical amount of world (CANON_CANVAS_W); a hard bound
## then bumps the scale UP if the window would still show meaningfully MORE world width than canonical — so a
## windowed player never sees more than a maximized one. Across maximized 16:9 the residual spread is
## ~16%/13% (853/960 wide, 464/515 tall), vs v0.12's 2.4×.
##
## BLEED_CAP backstop: the world is additionally clamped per axis to BLEED_CAP (52×36 tiles). NO normal 16:9
## window reaches it — a short/wide shape shrinks the canvas before it could, and the scale bound keeps the
## width near canonical. It exists so a PATHOLOGICAL shape (portrait monitor, extreme DPI virtualization)
## cannot reveal unbounded tiles. When a cap bites an axis the world centres on it (floored) and the margin
## bands cover the leftover; in the normal full-bleed case all four bands compute to zero size. A too-narrow
## window (world width < COLUMN_HIDE_FLOOR) hides the column and gives the world the full canvas width, still capped.
##
## SCALE POLICY (unchanged machinery, revised target): under aspect=expand the engine auto-picks a FRACTIONAL
## best-fit stretch (scale_mode="integer" is INERT under expand — EMPIRICAL 4.7.1); this policy divides the
## chosen INTEGER target by that fractional auto (via content_scale_factor, which MULTIPLIES it) so the
## engine's product lands on the integer. Target = nearest-to-canonical integer scale, then the fairness bound.
##
## TWO-ZOOM MODEL (v0.16.0): the WORLD scale s (above) is the fairness knob; the HUD gets its OWN integer
## zoom h (1 ≤ h ≤ s), chosen each pass to FIT the inventory column's measured min-height in the window
## (h = largest integer with stack·h ≤ win.y). Net on-screen HUD scale = (h/s)·s = h — a crisp integer. It is
## applied as THIS CanvasLayer's `scale` = Vector2(h,h)/s, so HUD-local px → canvas px is × h/s and → screen
## px is × h. A small window (1280×720, s=2) can thus render the world at 2× while the HUD drops to 1× to keep
## the whole inventory on screen. When h = s the layer scale is identity and geometry is byte-identical to v0.15.
##
## UNIT BOUNDARY (critical): the WorldFrame rect is computed in VIEWPORT CANVAS px (the column's canvas width
## is RIGHT_COL_W · h/s there) and EMITTED / cached in canvas px — the camera offset, DebugOverlay label and
## HurtVignette consumers all live on identity layers and read canvas px, so they stay UNCHANGED. The column,
## WorldFrame and margin-band Controls are children of THIS scaled layer, so they are PLACED in HUD-LOCAL px
## (the canvas-px geometry × s/h) and Root is sized to the HUD-local canvas (canvas × s/h). TacticalBorder is
## a WorldFrame child — it co-scales, no changes.
##
## COMPONENT SHAPE: main.gd owns the events and fans them out (note_attack / note_died / on_class_changed /
## on_weapon_swap / remove_frame); the HUD is HANDED the $Players container (set_players) and mirrors OUR
## OWN player's spawn/despawn off it (for the char-info HP bar seed) — it never climbs the tree. Party
## frames are OFF this iteration (party_frame.gd/.tscn stay on disk, dormant); note_attack/note_died now
## feed the own-player HP bar in the char-info section. Presentation only; nothing here is adjudication truth.

## The base virtual viewport width/height (base px, the project's display size — 640×360 today). These feed
## ONLY the engine's fractional auto-fit denominator in _apply_scale_policy (auto_f, the stretch aspect=expand
## actually applies); the world the player sees is the full-bleed canvas minus the column, scale-bounded below.
static var BASE_W: float = float(ProjectSettings.get_setting("display/window/size/viewport_width"))
static var BASE_H: float = float(ProjectSettings.get_setting("display/window/size/viewport_height"))

## The canonical canvas width (base px): the 1080p/4K maximized natural (1920/2 and 3840/4 both land here).
## The scale policy picks the integer scale whose canvas width lands NEAREST this, so every resolution's view
## clusters around one canonical amount of world — the bounded-variance anchor (DESIGN #10).
const CANON_CANVAS_W := 960.0

## Right-column width in HUD-DESIGN px (HUD-LOCAL units, NOT canvas px — since v0.16.0 the HUD has its own
## integer zoom h, so this maps to canvas px as RIGHT_COL_W · h/s). 5 × 32px slots (160) + 4 × 2px gaps (8)
## = 168, + 2 × 3px RightMargin (6) + border headroom. The world takes the canvas width MINUS the column's
## canvas-px width; a too-narrow window hides the column (COLUMN_HIDE_FLOOR) rather than starve the world.
const RIGHT_COL_W := 180.0

## Fairness backstop (base px): the world is capped per axis at 52×36 tiles (52·16 = 832, 36·16 = 576). NO
## normal 16:9 window reaches this — a short/wide shape shrinks the canvas before it could, and the scale
## bound keeps the width near canonical. It exists SOLELY so a pathological shape (portrait monitor, extreme
## DPI virtualization) cannot reveal unbounded tiles; when it bites an axis the world centres on that axis.
const BLEED_CAP := Vector2(832.0, 576.0)

## Column-hide floor (base px): 20 tiles of world width. If the canvas leaves less than this beside the
## column, the column HIDES and the world takes the full canvas width (still BLEED_CAP-capped) — a playable
## world width is protected over the HUD column in tiny dev windows.
const COLUMN_HIDE_FLOOR := 320.0

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
@onready var _right_margin: MarginContainer = $Root/RightColumn/RightMargin
@onready var _right_vbox: VBoxContainer = $Root/RightColumn/RightMargin/RightVBox
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
# The last WorldFrame rect, so a late-wired consumer can read it without waiting for the next resize. Seeded
# with the base viewport as a neutral pre-layout placeholder — overwritten on the first _relayout pass.
var _world_frame_rect: Rect2 = Rect2(Vector2.ZERO, Vector2(BASE_W, BASE_H))
# The margin-frame bands (left / right / top / bottom ColorRects). Built in _ready BEHIND the column +
# WorldFrame; sized each _relayout pass to opaquely cover all canvas outside the content block (DESIGN #10:
# leftover space is frame, never black bars or extra map). A zero-size band (absent margin) is fine.
var _margin_bands: Array[ColorRect] = []
# The world integer scale s picked by _apply_scale_policy each pass — cached so _relayout can derive the HUD
# zoom h (1 ≤ h ≤ s) and the HUD-local ↔ canvas-px conversion (s/h). The policy always sets it before the guard.
var _world_scale: int = 1

# Own-player character-panel widgets (built in _ready, refreshed by refresh_self on class/weapon change).
var _own_class_label: Label = null
var _own_passives_box: VBoxContainer = null
# Own-player HP bar (transplanted party-frame mechanics), fed by note_attack/note_died filtered to our id.
var _own_hp_fill: ColorRect = null
var _own_hp_text: Label = null
# Primary-hand weapon icon: an AtlasTexture over ITEMS_TEX, region re-pointed by refresh_self / on_weapon_swap.
var _own_weapon_icon: TextureRect = null
var _own_weapon_atlas := AtlasTexture.new()
# Hotbar item icons (v0.18.0 chunk B): one TextureRect + its own AtlasTexture per top-row inventory slot
# [0..INV_COLS-1], captured when _build_inventory builds that row so _refresh_hotbar can paint/hide them from
# the local player's inventory mirror. Parallel arrays kept in slot order; the keycap labels stay on the sockets.
var _hotbar_icons: Array[TextureRect] = []
var _hotbar_atlases: Array[AtlasTexture] = []


func _ready() -> void:
	_build_margin_frame()
	_style_band(_right_column)
	_build_minimap()
	_build_char_info()
	_build_equipment()
	_build_inventory()
	# Two triggers for the one layout pass: (1) the VIEWPORT's size_changed for real window resizes — Root is
	# now top-left anchored with an EXPLICIT size (HUD-local px, see _relayout), so it no longer auto-tracks the
	# viewport and its own `resized` can't catch a window resize; (2) Root's own `resized`, which fires when
	# _relayout writes a new Root size and lets the pass re-settle (compare-before-set keeps it bounded). The
	# content_scale_factor settle still rides the one-shot process_frame inside _relayout (no signal fires for it).
	get_viewport().size_changed.connect(_relayout)
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


## A player's inventory changed (fanned out by main.gd off the item_picked_up event): if it is our own
## player, repaint the hotbar from its inventory mirror. Mirror of on_weapon_swap — filter to our id, then
## refresh. A lighter path than refresh_self (no passive re-measure / relayout): item icons never change the
## column's min-height, so the hotbar repaint alone suffices.
func on_inventory_changed(entity_id: int) -> void:
	if entity_id == _own_id:
		_refresh_hotbar()


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
	# Hotbar (v0.18.0 chunk B): repaint the top inventory row from the player's inventory mirror. Called here so
	# the (re)spawn seed (_seed_self → refresh_self) shows an EMPTY bar on a fresh spawn — a freed+re-made player
	# carries nothing — and any own class/weapon refresh re-paints it too (harmless, the mirror is unchanged then).
	_refresh_hotbar()
	# Passives are the one live content that changes the column's min-height between resizes; re-measure now so
	# the HUD zoom h re-fits immediately (the class swap can add/remove passive lines — see _column_stack_min_h).
	_relayout()


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

## The column's stacked minimum height in HUD-DESIGN px: the sum of the four always-visible RightVBox
## sections' combined-min heights + the VBox separations between them + the RightMargin top/bottom margins —
## all read at runtime from the live theme constants (no literals, so a designer retune reflows h for free).
## This is the height the HUD zoom h must fit into the window; measured each pass because passives are live.
func _column_stack_min_h() -> float:
	var sections := [_minimap_slot, _char_info, _equipment, _inventory]
	var stack := 0.0
	for section in sections:
		stack += (section as Control).get_combined_minimum_size().y
	stack += float(sections.size() - 1) * _right_vbox.get_theme_constant("separation")
	stack += _right_margin.get_theme_constant("margin_top") + _right_margin.get_theme_constant("margin_bottom")
	return stack


## The one layout pass. First settles the world scale policy (which, if it changes content_scale_factor,
## re-fires and we bail — the re-fired pass finds the settled factor and proceeds). Then picks the HUD zoom h,
## computes the world frame in CANVAS px (emitted), and places the HUD Controls in HUD-LOCAL px (canvas × s/h).
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
	var canvas := get_viewport().get_visible_rect().size   # VIEWPORT canvas px
	var win := Vector2(get_window().size)                  # window px (= canvas × s once the factor settles)
	var s := _world_scale                                  # world integer scale (fairness)
	# HUD zoom h: the largest integer 1..s whose stacked column min-height (HUD-design px) fits the window
	# height at net scale h — stack·h ≤ win.y. floor(win.y / stack), clamped to [1, s]. Below ~400px window
	# height even h = 1 overflows the stack (accepted — a real session window is far taller than that).
	var stack := _column_stack_min_h()
	var h := clampi(floori(win.y / stack), 1, s)
	# Apply the HUD layer zoom: net on-screen HUD scale = (h/s)·s = h. Compare-before-set so a redundant write
	# doesn't churn the layer transform.
	var layer_scale := Vector2(h, h) / float(s)
	if not is_equal_approx(scale.x, layer_scale.x):
		scale = layer_scale
	# Root hosts the HUD in HUD-LOCAL px. It was full-rect anchored (tracking the viewport = canvas px); at
	# h < s that reference is wrong (the layer scale shrinks it), so pin Root top-left and size it explicitly to
	# the HUD-local canvas = canvas × s/h. Compare-before-set so an unchanged size doesn't re-fire `resized`.
	if _root.anchor_right != 0.0 or _root.anchor_bottom != 0.0:
		_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var to_local := float(s) / float(h)                    # canvas px → HUD-local px
	var local_canvas := canvas * to_local
	if not _root.size.is_equal_approx(local_canvas):
		_root.position = Vector2.ZERO
		_root.size = local_canvas
	# ── Geometry in CANVAS px (the emitted rect + the camera/overlay consumers all read canvas px) ──
	# The column's canvas-px width is its HUD-design width scaled by h/s. Column hides when the canvas can't
	# leave a playable world width beside it; then the world takes the full canvas width. Compared in canvas px.
	var col_canvas_full := RIGHT_COL_W * float(h) / float(s)
	var column_visible := canvas.x - col_canvas_full >= COLUMN_HIDE_FLOOR
	var col_canvas_w := col_canvas_full if column_visible else 0.0
	# Full-bleed world (canvas px): canvas minus the column on x, full canvas height on y — each axis clamped by
	# BLEED_CAP (the pathological-shape backstop; no normal 16:9 window reaches it).
	var world := Vector2(minf(canvas.x - col_canvas_w, BLEED_CAP.x), minf(canvas.y, BLEED_CAP.y))
	# Origin (canvas px): 0 normally; when a cap BIT an axis, centre so nothing is clipped. On x the column
	# rides at the world's right edge, so centre world+column together (v0.15 behaviour, reachable at ~2048-wide
	# canvases); on y the column is full-height and unaffected, so centre the world alone. Floored.
	var origin := Vector2.ZERO
	if world.x < canvas.x - col_canvas_w:
		origin.x = floorf((canvas.x - world.x - col_canvas_w) / 2.0)
	if world.y < canvas.y:
		origin.y = floorf((canvas.y - world.y) / 2.0)
	var frame := Rect2(origin, world)                      # EMITTED in canvas px — consumers unchanged
	# ── Placement in HUD-LOCAL px (canvas-px geometry × s/h; Controls are children of this scaled layer) ──
	var origin_local := origin * to_local
	var world_local := world * to_local
	_right_column.visible = column_visible
	if column_visible:
		# Column flush against the world's right edge, full HUD-local canvas height. RIGHT_COL_W is already
		# HUD-design px (= col_canvas_w × s/h), so no further conversion on its width.
		_place(_right_column, Vector2(origin_local.x + world_local.x, 0.0), Vector2(RIGHT_COL_W, local_canvas.y))
	_place(_world_frame, origin_local, world_local)
	_layout_margin_frame(local_canvas, origin_local, world_local, RIGHT_COL_W if column_visible else 0.0)
	_world_frame_rect = frame
	world_frame_changed.emit(frame)


## Size the four margin bands to cover every part of `canvas` OUTSIDE the world + column with the backdrop
## colour. `origin`/`world` are the WorldFrame rect; `col_w` is the column's width beside the world (0 when
## hidden). Left/right run the full canvas height and start/end past the column (which is itself full-height,
## same backdrop colour, so nothing pokes above/below it). Top/bottom frame the WORLD vertically, spanning
## only the world's x-range. In the normal full-bleed case every band degenerates to zero size (world +
## column span the whole canvas, origin 0). Negative extents clamp to zero — an absent margin is harmless.
func _layout_margin_frame(canvas: Vector2, origin: Vector2, world: Vector2, col_w: float) -> void:
	var occupied_right := origin.x + world.x + col_w   # right edge of world + column together
	var world_bottom := origin.y + world.y
	_place(_margin_bands[0], Vector2.ZERO, Vector2(maxf(0.0, origin.x), canvas.y))                                  # left
	_place(_margin_bands[1], Vector2(occupied_right, 0.0), Vector2(maxf(0.0, canvas.x - occupied_right), canvas.y))  # right
	_place(_margin_bands[2], Vector2(origin.x, 0.0), Vector2(world.x, maxf(0.0, origin.y)))                         # top
	_place(_margin_bands[3], Vector2(origin.x, world_bottom), Vector2(world.x, maxf(0.0, canvas.y - world_bottom)))  # bottom


## Apply the runtime scale policy. Returns true if it CHANGED content_scale_factor (a `resized` will re-fire
## and re-run _relayout; the caller bails). The guard compares APPLIED effective factors, so a re-fired
## resize recomputes the same target and no-ops — no loop.
func _apply_scale_policy() -> bool:
	var win := Vector2(get_window().size)
	# The engine's auto scale under aspect=expand is the FRACTIONAL best-fit (min of the per-axis ratios) —
	# EMPIRICAL 4.7.1 finding: scale_mode="integer" is INERT under expand. So THIS policy is the integer
	# snapper: dividing target by the fractional auto makes the engine's product land on the integer.
	var auto_f := maxf(1.0, minf(win.x / BASE_W, win.y / BASE_H))
	# Target = NEAREST-TO-CANONICAL integer scale. Among candidate scales 1..ceil(win.x / (CANON/2)), pick the
	# one whose resulting canvas width (win.x / s) lands nearest CANON_CANVAS_W in LOG space (ratio-symmetric,
	# so 2× too much and 2× too little weigh equally). `<=` with ascending s breaks ties toward the LARGER s —
	# more zoomed = LESS world, and a windowed player must never see more than a maximized one.
	var max_s := maxi(1, ceili(win.x / (CANON_CANVAS_W / 2.0)))
	var target := 1
	var best := INF
	for s in range(1, max_s + 1):
		var metric := absf(log(win.x / float(s) / CANON_CANVAS_W))
		if metric <= best:
			best = metric
			target = s
	# Fairness bound: nearest-canonical picks the CLOSEST view, but a small window (e.g. 1280×720) can still
	# land a scale that shows meaningfully MORE world than canonical. Canonical world width = CANON_CANVAS_W −
	# RIGHT_COL_W (780). While the world width at the chosen scale exceeds that by >10%, bump the scale UP
	# (more zoom, less world) — the windowed-outlier killer (1280×720: s=1 world 1100 > 858 → s=2, world 460).
	while (win.x / float(target) - RIGHT_COL_W) > (CANON_CANVAS_W - RIGHT_COL_W) * 1.10:
		target += 1
	# Height playability floor: the width-driven selection above can leave a DEGENERATE short-wide window
	# (not reachable via resizable=false, but DPI virtualization can synthesize one) with a uselessly short
	# canvas — e.g. 3840×600 at 4× is 150 base px (9 tiles) tall. Step back down until the canvas is at least
	# 15 tiles (240 px) tall or 1×. This may re-widen the world past the fairness bound above — acceptable:
	# BLEED_CAP still hard-caps the visible world per axis, so playability wins and fairness stays bounded.
	while target > 1 and win.y / float(target) < 240.0:
		target -= 1
	# Cache the chosen world scale for _relayout (it derives the HUD zoom h and the HUD-local ↔ canvas-px
	# conversion from it). Set unconditionally — even when the factor write below no-ops, s must stay current.
	_world_scale = target
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
			# Item icon (v0.18.0 chunk B): a full-rect AtlasTexture over ITEMS_TEX, the exact _set_weapon_icon
			# pattern, hidden until _refresh_hotbar points its region at a carried item. Added BEFORE the keycap
			# so the faint numeral draws ON TOP of the icon (later children paint over earlier ones in Godot).
			var icon := TextureRect.new()
			icon.set_anchors_preset(Control.PRESET_FULL_RECT)
			icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var atlas := AtlasTexture.new()
			atlas.atlas = ITEMS_TEX
			# Seed a valid single-tile region (a zero-size region draws the WHOLE sheet — the same guard the
			# weapon socket uses); the icon stays hidden until _refresh_hotbar applies a real item region.
			atlas.region = WorldGrid.atlas_region(Vector2i.ZERO)
			icon.texture = atlas
			icon.visible = false
			slot.add_child(icon)
			_hotbar_icons.append(icon)
			_hotbar_atlases.append(atlas)
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


## Paint the hotbar row (v0.18.0 chunk B) from the LOCAL player's inventory mirror (Array[String] of item
## display_names, in slot order). For each slot: a filled slot windows the item's items.png region out of
## ITEMS_TEX (the _set_weapon_icon pattern, resolved via GameManager.config.item_by_name — same name-resolution
## every peer uses); an empty slot (or one whose name can't resolve) hides the icon back to a bare socket. Reads
## the local player through $Players like refresh_self; a no-op-to-empty when our player doesn't exist yet.
func _refresh_hotbar() -> void:
	var me := _players.get_node_or_null(str(_own_id)) as Player if _players != null else null
	var bag: Array = me.inventory if me != null else []
	for i in _hotbar_icons.size():
		var item_type: ItemType = GameManager.config.item_by_name(str(bag[i])) if i < bag.size() else null
		if item_type != null:
			_hotbar_atlases[i].region = WorldGrid.atlas_region(item_type.atlas_coords)
			_hotbar_icons[i].visible = true
		else:
			# Empty slot OR an unresolvable name (a name absent from item_catalog) — clear back to a bare socket
			# rather than leave a stale icon; the config-validation guard warns on a genuinely missing catalog entry.
			_hotbar_icons[i].visible = false


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
