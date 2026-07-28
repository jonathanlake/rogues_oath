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
## WorldFrame, AbilityBar and margin-band Controls are children of THIS scaled layer, so they are PLACED in
## HUD-LOCAL px (the canvas-px geometry × s/h) and Root is sized to the HUD-local canvas (canvas × s/h).
## TacticalBorder is a WorldFrame child — it co-scales, no changes.
##
## ABILITY BAR (v0.21.0): the class's 1-5 active abilities moved OUT of the right column (they were row 0 of the
## inventory grid through v0.20.x) into a BOTTOM-CENTER bar over the world, under the player's eye. It is a $Root
## child — NOT a RightVBox section — so it contributes nothing to _column_stack_min_h() and cannot move the HUD
## zoom h; promoting the freed column row to real bag space therefore costs zero pixels of column height. Like
## every other Control on this scaled layer it is PLACED IN HUD-LOCAL px (see UNIT BOUNDARY): centred on the
## world frame's HUD-local rect and floored to whole HUD-local pixels so it stays crisp at h < s. It is
## MOUSE_FILTER_IGNORE bar-and-sockets — ability slots are display-only, so world clicks pass straight through
## to move_input.gd. The accent (gold) socket style now means abilities-and-hands ONLY; the bag is all grey.
## Accepted: the bar overlays ~10×2 tiles of world at the bottom edge (occlusion only, clicks pass through), and
## in a very small window it can overlap the bottom-left game-log layer — the same severity class as column-hide.
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

## Equipment/inventory slot edge (base px), the gap between adjacent slots, and the inventory grid shape.
## Slot edge doubled from v0.12.0's 16px for the airier column. Since v0.21.0 EVERY inventory socket is bag
## space (the ability row moved to the bottom-center AbilityBar), so INV_COLS is the grid's width only — the
## bag's CAPACITY is authored in game_config.tres (`inventory_slots`, 20 today), and INV_ROWS is now the
## MINIMUM rows drawn, a visual floor that keeps the panel from shrinking below v0.20's 4-row block.
const SLOT_PX := 32.0
const SLOT_GAP_PX := 2.0
const INV_COLS := 5
const INV_ROWS := 4

## Ability-bar shape (v0.21.0): 5 sockets, and the gap (HUD-design px) between the bar and the world frame's
## BOTTOM edge. The socket COUNT is authored (GameConfig.ability_slots, v0.47.0) rather than a const here —
## the same move `inventory_slots` made for the bag grid, and for the same reason: the host now enforces
## that number when it refuses a grant with no free slot, so the panel drawing a different count would be
## the HUD disagreeing with adjudication.
##
## Deliberately NOT INV_COLS, which it happens to equal: the bag's width and the hotbar's length are
## unrelated numbers that must not move together by accident.
##
## RAISING IT PAST 5 NEEDS INPUT-MAP WORK — the keys are authored `use_slot_1..5` actions — which is stated
## on the config field. The floor of 1 stops a 0 or negative authored value producing a bar with no sockets.
static func _ability_slot_count() -> int:
	return GameManager.config.ability_slot_count()
const BOTTOM_PAD := 4.0

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

## Emitted when the local player LEFT-CLICKS an inventory slot (v0.19.x loot). `slot` is the 0-based bag index.
## The HUD stays presentation-only (it never climbs the tree): main.gd wires this, resolves the slot's content
## TYPE against the catalogs, and submits the right intent — use_item for a consumable, equip_item for a weapon.
signal slot_activated(slot: int)

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
# STAMINA pips (v0.24.0 experiment, renamed v0.24.1): the own-player battle-movement budget, one
# square per point, host-pushed via stamina events (never queried — the HP pattern). HIDDEN until
# the first event arrives, so a session with /stamina off from boot never shows an inert row (no
# disable event exists; a mid-session /stamina off just freezes the last state — accepted).
var _own_stamina_row: HBoxContainer = null
var _own_stamina_pips: Array[ColorRect] = []
const _STAMINA_FULL := Color(0.35, 0.8, 0.95)   # teal — deliberately not HP green/red
const _STAMINA_EMPTY := Color(0.1, 0.16, 0.2)
# Own-player HP bar (transplanted party-frame mechanics), fed by note_attack/note_died filtered to our id.
var _own_hp_fill: ColorRect = null
var _own_hp_text: Label = null
# MANA bar (v0.43.0) — the caster resource, directly under the HP bar. The WRAPPER is held (unlike the HP
# bar's) because this one is conditionally VISIBLE: only a class with a non-zero PlayerClass.max_mana shows
# it, and a hidden Control contributes zero height, so a knight's column measures exactly as it did before
# mana existed. Fed by host-pushed `mana` events, never queried — the stamina pattern, for the same reason
# (a pool changes on casts that may deal no damage, so it cannot ride an attack event the way HP does).
var _own_mana_bar: Control = null
var _own_mana_fill: ColorRect = null
var _own_mana_text: Label = null
# Last own-pool values, kept so the client-side "can I afford to arm this cursor?" pre-check in main.gd can
# read them without a query. Mirror only — the host re-checks anything that reaches it.
var _own_mana: int = 0
const _MANA_FULL := Color(0.34, 0.52, 0.95)     # arcane blue — deliberately not HP green/red or stamina teal
const _MANA_EMPTY := Color(0.12, 0.14, 0.28)
# Primary-hand weapon icon: an AtlasTexture over ITEMS_TEX, region re-pointed by refresh_self / on_weapon_swap.
var _own_weapon_icon: TextureRect = null
var _own_weapon_atlas := AtlasTexture.new()
# BODY-slot armor icon (v0.27.0 equipment phase 2) — the exact twin of the weapon icon above, one socket
# over in the armor grid, re-pointed by refresh_self / on_gear_changed. The Body socket is the FIRST of the
# nine equipment sockets to hold a real item; the other eight stay cosmetic name labels.
var _own_body_icon: TextureRect = null
var _own_body_atlas := AtlasTexture.new()
# OFF-HAND socket (v0.39.0, the knight's kite shield) — the SECOND equipment socket to hold a real item,
# built exactly like Body's. Its icon covers the faint "Off" label while something is carried.
var _own_off_hand_icon: TextureRect = null
var _own_off_hand_atlas := AtlasTexture.new()
# The three live equipment SOCKETS, held for their tooltip_text (v0.39.0) — a socket is the hoverable
# control; its icon and label children are IGNORE and invisible to hit-testing.
var _own_weapon_socket: Panel = null
var _own_body_socket: Panel = null
var _own_off_hand_socket: Panel = null
# BAG item icons (v0.18.0 chunk B; renamed from _hotbar_* in v0.21.0, when "hotbar" became the bottom-center
# ability bar): one TextureRect + its own AtlasTexture per REAL bag slot [0..inventory_slots-1], captured when
# _build_inventory builds the grid so _refresh_bag can paint/hide them from the local player's inventory mirror.
# Parallel arrays kept in slot order. Sockets drawn PAST capacity are decorative and are deliberately absent
# from these arrays, so nothing can ever be written or painted past the authored capacity.
var _bag_icons: Array[TextureRect] = []
# The bag SOCKETS, parallel to _bag_icons (v0.39.0) — the hoverable control that carries tooltip_text.
var _bag_slots: Array[Panel] = []
var _bag_atlases: Array[AtlasTexture] = []
# ABILITY bar icons (v0.20.3; moved out of the inventory grid into the bottom-center bar in v0.21.0): the
# accented 1-5 boxes showing the local player's class active_abilities. Parallel arrays in slot order, captured
# in _build_ability_bar, painted by _refresh_abilities from the class. The 1-5 KEYS fire them
# (main._unhandled_input) — the sockets themselves are display-only (mouse IGNORE).
var _ability_icons: Array[TextureRect] = []
# The ability SOCKETS themselves (v0.39.0), parallel to _ability_icons. Held because the socket — not its
# IGNORE icon child — is the hoverable control, so it is what carries tooltip_text.
var _ability_sockets: Array[Panel] = []
var _ability_atlases: Array[AtlasTexture] = []
# COOLDOWN OVERLAYS (v0.26.0 instants experiment): one dark ColorRect per ability socket, drained bottom-up
# over the host's stamped cooldown_sec by note_ability_cooldown. Parallel to the icon arrays. Purely LOCAL
# COSMETIC — the referee's ready-at msec is the only authority on whether a press is refused, so a stale or
# missing overlay can never grant or deny an ability (it only ever misinforms the eye, never the rules).
var _ability_cooldown_fills: Array[ColorRect] = []
var _ability_cooldown_tweens: Array[Tween] = []
# Slot index -> the msec at which that ability is ready again (v0.41.0). Written beside the fill tween and
# read by ability_cooldown_remaining, which Main uses to refuse ARMING a targeting cursor for a spell that
# cannot be cast. LOCAL MIRROR, never authority: the host owns cooldowns and adjudicates every press that
# does reach it; this only stops the client offering a ring it knows will be refused.
var _ability_ready_at_msec: Dictionary = {}
# The ability display_name painted into each socket, in slot order (v0.26.0). The `ability_used` /
# `ability_cooldown` events carry a NAME (not an index — the wire never assumes both peers order a class's
# abilities identically), so this is how a name maps back to the socket that has to darken. Repainted with the
# icons by _refresh_abilities, so a /class change re-keys it in the same pass.
var _ability_names: Array[String] = []
# The bottom-center ability bar Control (v0.21.0), built in _ready as a $Root child — NOT a RightVBox section,
# so it never enters _column_stack_min_h(). Placed in HUD-LOCAL px each _relayout pass (see the header's
# ABILITY BAR + UNIT BOUNDARY notes).
var _ability_bar: Control = null


func _ready() -> void:
	_build_margin_frame()
	_style_band(_right_column)
	_build_minimap()
	_build_char_info()
	_build_equipment()
	_build_inventory()
	_build_ability_bar()
	# Two triggers for the one layout pass: (1) the VIEWPORT's size_changed for real window resizes — Root is
	# now top-left anchored with an EXPLICIT size (HUD-local px, see _relayout), so it no longer auto-tracks the
	# viewport and its own `resized` can't catch a window resize; (2) Root's own `resized`, which fires when
	# _relayout writes a new Root size and lets the pass re-settle (compare-before-set keeps it bounded). The
	# content_scale_factor settle still rides the one-shot process_frame inside _relayout (no signal fires for it).
	get_viewport().size_changed.connect(_relayout)
	_root.resized.connect(_relayout)
	_apply_tooltip_theme()
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


## A stamina change landed (v0.24.0, fanned out by main.gd): if it is OUR OWN player, repaint
## the pips. First event reveals the row (and re-measures the column — the one min-height change);
## a max change (class swap) rebuilds the pip set. HUD-local units throughout — the row lives inside
## the char-info column, so the canvas-px vs HUD-local boundary (hud zoom) is never crossed here.
func note_stamina(entity_id: int, points: int, max_points: int) -> void:
	if entity_id != _own_id or _own_stamina_row == null or max_points <= 0:
		return
	# PIPS EXIST ONLY WHEN THERE IS A BUDGET TO COUNT (v0.26.0, DESIGN §2.2.10 graduation): at max 1 the
	# pool is binary — ready or spent — and a single pip says nothing the entity's own recovery
	# presentation (transparency + side bar + ready blink) doesn't say better. Hide the row and stop.
	# Nothing is torn down: raise the dial above 1 and the next stamina event rebuilds the pip set and
	# re-reveals the row through the existing path, no special case.
	if max_points <= 1:
		if _own_stamina_row.visible:
			_own_stamina_row.visible = false
			_relayout()
		return
	if _own_stamina_pips.size() != max_points:
		for pip in _own_stamina_pips:
			pip.queue_free()
		_own_stamina_pips.clear()
		for i in max_points:
			var pip := ColorRect.new()
			pip.custom_minimum_size = Vector2(7, 7)
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_own_stamina_row.add_child(pip)
			_own_stamina_pips.append(pip)
	for i in _own_stamina_pips.size():
		_own_stamina_pips[i].color = _STAMINA_FULL if i < points else _STAMINA_EMPTY
	if not _own_stamina_row.visible:
		_own_stamina_row.visible = true
		_relayout()


## Own-player MANA changed (v0.43.0; fanned out by main.gd from the host's `mana` event). OWN PLAYER ONLY,
## like the pips and the HP bar — a teammate's pool is read through the world, not through our UI.
##
## `max_points <= 0` is the TAKE-IT-DOWN signal, not a bad value: it is exactly what a non-caster class
## reports, and what a `/class` change away from a caster posts. So the bar's whole visibility rule is
## "does this class have a pool", pushed rather than inferred, and the knight never sees an empty blue
## strip. Both visibility flips call `_relayout()` because the bar's 9px enter and leave the column's
## measured min-height, which is what the integer HUD zoom is fitted against.
func note_mana(entity_id: int, points: int, max_points: int) -> void:
	if entity_id != _own_id or _own_mana_bar == null:
		return
	_own_mana = points
	if max_points <= 0:
		if _own_mana_bar.visible:
			_own_mana_bar.visible = false
			_relayout()
		return
	var frac := clampf(float(points) / float(maxi(max_points, 1)), 0.0, 1.0)
	_own_mana_fill.anchor_right = frac
	_own_mana_fill.offset_right = 0.0
	# ONE colour at every level, deliberately — see _build_mana_bar. An empty pool is a budgeting fact, and
	# the LENGTH already says it; recolouring would borrow the HP bar's "you are in danger" grammar for
	# something that is not danger.
	_own_mana_fill.color = _MANA_FULL
	_own_mana_text.text = "%d/%d" % [points, max_points]
	if not _own_mana_bar.visible:
		_own_mana_bar.visible = true
		_relayout()


## Our own current mana (v0.43.0). A MIRROR read for main.gd's "don't arm a cursor you can't pay for"
## pre-check — client-side routing convenience (§2.2.9), never authority: the host re-validates every press
## that reaches it, so a stale value here costs nothing but the pre-v0.43.0 behaviour.
func own_mana() -> int:
	return _own_mana


## An instant ability fired or had its cooldown charged (v0.26.0 instants experiment; fanned out by main.gd
## from the host's `ability_used` / `ability_cooldown` events). OWN PLAYER ONLY — a teammate's cooldown is not
## on our bar — and resolved by ability NAME, because the wire deliberately never assumes two peers order a
## class's abilities the same way. `cooldown_sec` is the HOST's stamped span, so the overlay drains over exactly
## the window the referee will refuse presses for (stamp-and-bake, §2.8.2); a 0 clears the socket, which is how
## Shield Block's RAISE reads (raising is free — only consumption charges it).
##
## Purely cosmetic and locally tweened: nothing here can grant or deny an ability. Being LOCAL is deliberate
## rather than lazy — a per-frame cooldown sync would be exactly the streaming the event model bans (§2.5).
func note_ability_cooldown(entity_id: int, ability_name: String, cooldown_sec: float) -> void:
	if entity_id != _own_id or ability_name.is_empty():
		return
	var idx := _ability_names.find(ability_name)
	if idx < 0 or idx >= _ability_cooldown_fills.size():
		return
	_clear_ability_cooldown(idx)
	if cooldown_sec <= 0.0:
		return
	# READY-AT STAMP beside the visual (v0.41.0), so "is this still cooling?" is answerable without
	# introspecting a Tween. The host tells us a TOTAL here, and recovering "remaining" from tween progress
	# would mean re-deriving something the event already stated — brittle, and it would silently follow any
	# future change to how the fill animates. Same shape the referee's own _ability_ready_at_msec uses.
	_ability_ready_at_msec[idx] = Time.get_ticks_msec() + int(cooldown_sec * 1000.0)
	var fill := _ability_cooldown_fills[idx]
	fill.size = Vector2(SLOT_PX, SLOT_PX)
	fill.visible = true
	var tween := create_tween()
	_ability_cooldown_tweens[idx] = tween
	tween.tween_property(fill, "size", Vector2(SLOT_PX, 0.0), cooldown_sec).set_trans(Tween.TRANS_LINEAR)
	tween.tween_callback(func(): fill.visible = false)


## Kill + hide one socket's cooldown overlay (v0.26.0). Idempotent; shared by note_ability_cooldown's
## replace-on-recall and _refresh_abilities' re-key on a class change.
func _clear_ability_cooldown(idx: int) -> void:
	if idx < 0 or idx >= _ability_cooldown_fills.size():
		return
	var tween: Tween = _ability_cooldown_tweens[idx]
	if tween != null and tween.is_valid():
		tween.kill()
	_ability_cooldown_tweens[idx] = null
	_ability_cooldown_fills[idx].visible = false
	# Drop the stamp with the visual, so a class change (which re-keys every socket) can never leave slot 2
	# reading "still cooling" from the previous loadout's ability.
	_ability_ready_at_msec.erase(idx)


## Seconds remaining on slot `index`'s cooldown, or 0.0 when it is ready (v0.41.0). Main gates ARMING a
## targeting cursor on this: a spell you cannot cast should not open a range ring you cannot use.
##
## LOCAL AND ADVISORY. The host owns cooldowns; this mirrors the last `ability_cooldown` event it sent us.
## That makes it a §2.2.9 client-side ROUTING convenience, exactly like the shoot-target predicate — a
## stale mirror at worst sends a press the host refuses on its own terms, which is the pre-v0.41.0
## behaviour and still perfectly safe. It must never be read as authority for anything.
func ability_cooldown_remaining(index: int) -> float:
	var ready_at: int = int(_ability_ready_at_msec.get(index, 0))
	return maxf(0.0, float(ready_at - Time.get_ticks_msec()) / 1000.0)


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


## A player's WORN GEAR changed (v0.27.0, fanned out by main.gd off the `equip_item {gear}` event): if it is
## our own player, refresh the equipment panel so the Body socket repaints. Its own entry point rather than a
## reuse of on_weapon_swap purely for legibility at the call site — both land in refresh_self, which repaints
## the whole own-player panel from the node.
func on_gear_changed(entity_id: int) -> void:
	if entity_id == _own_id:
		refresh_self()


## A player's inventory changed (fanned out by main.gd off the item_picked_up event): if it is our own
## player, repaint the bag grid from its inventory mirror. Mirror of on_weapon_swap — filter to our id, then
## refresh. A lighter path than refresh_self (no passive re-measure / relayout): item icons never change the
## column's min-height, so the bag repaint alone suffices.
func on_inventory_changed(entity_id: int) -> void:
	if entity_id == _own_id:
		_refresh_bag()


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
	# v0.45.0: the trait list is the UNION of the class's and this player's GRANTED ones, so it repaints
	# from the PLAYER rather than the class — a granted trait belongs to the body, not the role. Runs even
	# for a null class, since a classless player can still have been granted something.
	_refresh_passives(me)
	# Ability bar (v0.20.3; bottom-center since v0.21.0): repaint the 1-5 boxes from the class's active_abilities.
	# Handles a null class (hides all). A /class change re-enters here (on_class_changed → refresh_self), so the
	# bar swaps with the class.
	_refresh_abilities(me)
	_set_weapon_icon(me.equipped_weapon)
	# Body armor (v0.27.0): the same one-line repaint the weapon gets. Reached from the (re)spawn seed (so a
	# fresh spawn shows its class's starting armor) and from every own gear/class change.
	_set_body_icon(me.equipped_body)
	_set_off_hand_icon(me.equipped_off_hand)
	# Bag (v0.18.0 chunk B): repaint the inventory grid from the player's inventory mirror. Called here so the
	# (re)spawn seed (_seed_self → refresh_self) shows an EMPTY bag on a fresh spawn — a freed+re-made player
	# carries nothing — and any own class/weapon refresh re-paints it too (harmless, the mirror is unchanged then).
	_refresh_bag()
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
	# Ability bar (v0.21.0): centred on the world frame's BOTTOM edge, in HUD-LOCAL px like every other Control on
	# this scaled layer (the UNIT BOUNDARY invariant — placing it from the canvas-px `frame` would drift it by s/h
	# at h < s). Its size is DERIVED from the slot constants, never a literal, so a retune of SLOT_PX/SLOT_GAP_PX
	# re-centres it for free. Both axes are floored so the bar lands on a whole HUD-local pixel and stays crisp:
	# floored on the SUM, not on the centring term alone, because origin_local itself is fractional whenever the
	# BLEED_CAP centring bit an axis at h < s. Placed unconditionally — the bar is over the world, not the column,
	# so column-hide doesn't affect it.
	var bar_size := _ability_bar_size()
	_place(_ability_bar, Vector2(
		floorf(origin_local.x + (world_local.x - bar_size.x) / 2.0),
		floorf(origin_local.y + world_local.y - bar_size.y - BOTTOM_PAD)), bar_size)
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


## The ability bar's size in HUD-DESIGN px, DERIVED from the slot constants rather than written as a literal
## (one socket per authored slot plus the gaps between them, one socket tall — 5·32 + 4·2 = 168 × 32 at the
## shipped count). _relayout centres the bar on this, so a retune of SLOT_PX / SLOT_GAP_PX / the authored
## slot count keeps it centred and correctly
## sized with no second edit site — and it matches what the HBoxContainer in _build_ability_bar measures to.
func _ability_bar_size() -> Vector2:
	var slots := _ability_slot_count()
	return Vector2(float(slots) * SLOT_PX + float(slots - 1) * SLOT_GAP_PX, SLOT_PX)


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


## A reserved-socket fill. `accent` gives the ABILITY BAR / hands sockets their distinct brighter (gold) border.
## Since v0.21.0 the bag grid is all non-accent grey, so accent reads unambiguously as "abilities and hands".
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
	# MANA bar (v0.43.0), directly under the HP bar and above the stamina pips — the reading order a player
	# expects (what I have, then what I can spend, then what I can do right now). Starts HIDDEN by the same
	# rule the stamina row below documents: invisible means zero height, so the column min-height and the
	# integer HUD zoom fit are untouched for every non-caster class, and the visibility flip re-measures
	# through _relayout.
	_own_mana_bar = _build_mana_bar()
	_own_mana_bar.visible = false
	vbox.add_child(_own_mana_bar)
	# Stamina pips row (v0.24.0), directly under the HP bar. Starts hidden (zero height while
	# invisible, so the column's min-height — and thus the integer HUD zoom fit — is untouched until
	# the experiment actually posts a value; the visibility flip re-measures via _relayout).
	_own_stamina_row = HBoxContainer.new()
	_own_stamina_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_own_stamina_row.add_theme_constant_override("separation", 2)
	_own_stamina_row.visible = false
	vbox.add_child(_own_stamina_row)
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


## The own MANA bar (v0.43.0) — the HP bar's twin, deliberately built as a near-copy rather than a shared
## parameterised builder. The two look alike today but answer different questions: HP lerps green→red
## because the COLOUR is the warning, while mana keeps ONE blue at every level because running dry is a
## budgeting fact, not an emergency. Folding them together would mean a builder with a colour-policy flag
## and two callers, which is more coupling than the eleven duplicated lines it would save.
##
## Shorter than the HP bar (9px vs 11) on purpose: it is the secondary resource, and the size difference is
## what keeps the two readable at a glance in a 174px-wide column at HUD zoom 1.
func _build_mana_bar() -> Control:
	var bar := Control.new()
	bar.custom_minimum_size = Vector2(0, 9)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var track := ColorRect.new()
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	track.color = Color(0.05, 0.06, 0.16, 1.0)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(track)
	_own_mana_fill = ColorRect.new()
	_own_mana_fill.anchor_bottom = 1.0
	_own_mana_fill.anchor_right = 1.0
	_own_mana_fill.color = _MANA_FULL
	_own_mana_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(_own_mana_fill)
	_own_mana_text = _make_label(6)
	_own_mana_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	_own_mana_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_own_mana_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_own_mana_text.text = "—"
	bar.add_child(_own_mana_text)
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
	_own_weapon_socket = primary
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
	# OFF-HAND (v0.39.0): a real socket now, built exactly like Body's — icon over the faint "Off" label,
	# so an empty hand still reads as the off-hand slot.
	var offhand := _make_socket(true, "Off")
	_own_off_hand_socket = offhand
	_own_off_hand_icon = TextureRect.new()
	_own_off_hand_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_own_off_hand_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_own_off_hand_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_own_off_hand_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_own_off_hand_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_own_off_hand_atlas.atlas = ITEMS_TEX
	_own_off_hand_atlas.region = WorldGrid.atlas_region(Vector2i.ZERO)
	_own_off_hand_icon.texture = _own_off_hand_atlas
	_own_off_hand_icon.visible = false
	offhand.add_child(_own_off_hand_icon)
	hands.add_child(offhand)
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
		var socket := _make_socket(false, label_text)
		# BODY is the one live slot (v0.27.0 equipment phase 2): give it a real icon on top of its name
		# label, built exactly like the primary hand's above. The faint "Body" label stays underneath and is
		# simply covered while something is worn, so an empty slot still reads as the body slot.
		if label_text == "Body":
			_own_body_socket = socket
			_own_body_icon = TextureRect.new()
			_own_body_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
			_own_body_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			_own_body_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			_own_body_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			_own_body_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_own_body_atlas.atlas = ITEMS_TEX
			# Seed a VALID single-tile region for the same reason the weapon icon does: a zero-size
			# AtlasTexture region draws the WHOLE sheet. Hidden until refresh_self applies a real item.
			_own_body_atlas.region = WorldGrid.atlas_region(Vector2i.ZERO)
			_own_body_icon.texture = _own_body_atlas
			_own_body_icon.visible = false
			socket.add_child(_own_body_icon)
		grid.add_child(socket)
	grid.add_child(_make_socket(false, ""))  # blank filler cell — completes the 2×4 block


## Inventory panel (v0.21.0: ALL bag, ALL grey) — a grid of 32px reserved slots pinned at the column BOTTOM
## (the char-info expand pushes it down), 2px gaps. The ability row is gone (it is the bottom-center AbilityBar
## now), so EVERY socket here is bag space: a carried potion or a looted weapon, each LEFT-CLICKABLE to
## use/equip (v0.19.x). Grey, never accent — the accent (gold) style now reads "abilities and hands", which is
## what makes the bottom bar look special.
##
## CAPACITY IS THE CONFIG's, not the grid's: `GameManager.config.inventory_slots` (20 today) is the single
## source of truth the referee adjudicates from, so the HUD can never show fewer slots than the bag holds —
## the exact drift the old three-way-hardcoded coupling warned about. Clamped to ≥1 on read so a 0/negative
## authored value can't produce a zero-row grid. Rows drawn = max(INV_ROWS, ceil(slots / INV_COLS)): INV_ROWS
## is a VISUAL FLOOR keeping the panel at v0.20's 4-row height, and a capacity past the grid adds rows.
## Sockets BEYOND capacity are decorative — grey, mouse IGNORE, no icon, and absent from _bag_icons/_bag_atlases,
## so nothing can be written or painted past capacity. At the shipped 20 the two sets coincide and no decorative
## socket exists. Going past 20 grows the column and shrinks the HUD zoom h (see _column_stack_min_h) — the
## fractional-h work that permits that is tabled, so 20 is the free maximum today.
func _build_inventory() -> void:
	_inventory.add_theme_stylebox_override("panel", _clear_style())
	var grid := GridContainer.new()
	grid.columns = INV_COLS
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", int(SLOT_GAP_PX))
	grid.add_theme_constant_override("v_separation", int(SLOT_GAP_PX))
	_inventory.add_child(grid)
	var slots := maxi(1, GameManager.config.inventory_slots)
	var rows := maxi(INV_ROWS, ceili(slots / float(INV_COLS)))
	for i in INV_COLS * rows:
		var slot := _make_socket(false, "")
		grid.add_child(slot)
		if i >= slots:
			continue   # decorative filler past capacity: grey, IGNORE (the _make_socket default), untracked
		# Item icon (v0.18.0 pattern). LEFT-CLICK to use/equip — bind the RAW grid index, which IS the bag index
		# now that the ability row no longer offsets it (was i - INV_COLS through v0.20.x). Sockets are IGNORE by
		# default so world clicks pass THROUGH; only these real slots consume. main.gd routes slot_activated to
		# use_item (consumable) or equip_item (weapon) by the slot's content type.
		var it_icon := _make_slot_icon()
		slot.add_child(it_icon["rect"])
		_bag_icons.append(it_icon["rect"])
		_bag_atlases.append(it_icon["atlas"])
		# Kept for its tooltip_text (v0.39.0), the same reason the ability sockets are kept.
		_bag_slots.append(slot)
		# STOP, not the PASS every other socket takes: these genuinely CONSUME their click (equip / use), so
		# the event must stop here rather than bubble on to the world handler and also move the player.
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.gui_input.connect(_on_slot_gui_input.bind(i))


## The bottom-center ability bar (v0.21.0) — the class's 1-5 active abilities, moved wholesale out of the
## inventory grid's top row. A $Root child, NOT a RightVBox section, so it adds nothing to _column_stack_min_h()
## and can never move the HUD zoom h; _relayout places it in HUD-LOCAL px on the world frame's bottom edge (see
## the header's ABILITY BAR note). An HBoxContainer laid out at exactly _ability_bar_size(), so the sockets sit
## on the same 2px gaps as every other slot block. Accent (gold) sockets — the visual signature the bag gave up.
## MOUSE: the bar is IGNORE and every socket is PASS (v0.39.0, was IGNORE). Ability slots are still
## display-only — the 1-5 KEYS fire them via main._unhandled_input — and a click here must still pass
## straight through to move_input.gd's world handling, which PASS preserves: it takes hover (for the
## tooltip) but lets an unhandled click bubble on out. This bar sits over the PLAY AREA, so that
## distinction is load-bearing; STOP here would silently eat clicks in the middle of the screen.
## Clickable ability slots stay a DESIGN §2.11 future item.
func _build_ability_bar() -> void:
	var bar := HBoxContainer.new()
	bar.name = "AbilityBar"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_constant_override("separation", int(SLOT_GAP_PX))
	_root.add_child(bar)
	_ability_bar = bar
	for i in _ability_slot_count():
		var slot := _make_socket(true, "")
		bar.add_child(slot)
		# The SOCKET is kept (v0.39.0), not just its icon: the socket is the hoverable control, so it is
		# what carries tooltip_text. The icon is IGNORE and invisible to hit-testing.
		_ability_sockets.append(slot)
		# ABILITY icon (v0.20.3): the class active_abilities[i] icon, painted by _refresh_abilities.
		var a_icon := _make_slot_icon()
		slot.add_child(a_icon["rect"])
		_ability_icons.append(a_icon["rect"])
		_ability_atlases.append(a_icon["atlas"])
		_ability_names.append("")
		# COOLDOWN OVERLAY (v0.26.0): a dark scrim over the icon, drained bottom-up as the cooldown runs (the
		# same "fill grows / scrim shrinks from the bottom" idiom as the entity recovery bar, so the two read as
		# one language). Added AFTER the icon so it covers it, but BEFORE the keycap so "1".."5" stays legible
		# while the socket is dark. Explicit position/size (a Panel is not a container, so children keep their
		# own rect) and mouse IGNORE like everything else in this bar. Hidden until a cooldown is charged.
		var cd := ColorRect.new()
		cd.color = Color(0.04, 0.05, 0.08, 0.72)
		cd.position = Vector2.ZERO
		cd.size = Vector2(SLOT_PX, SLOT_PX)
		cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cd.visible = false
		slot.add_child(cd)
		_ability_cooldown_fills.append(cd)
		_ability_cooldown_tweens.append(null)
		# Keycap "1".."5" drawn OVER the icon (added LAST so it paints on top).
		var cap := Label.new()
		cap.text = str(i + 1)
		cap.add_theme_font_size_override("font_size", 6)
		cap.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cap.position = Vector2(1.0, -1.0)
		slot.add_child(cap)


## Build a hidden full-rect items.png icon (TextureRect + AtlasTexture) for an inventory slot (v0.20.3 extract) —
## the shared setup for ability icons and item icons. Returns both so the caller keeps the atlas to re-point later.
## A zero-size region would draw the WHOLE sheet, so it seeds a valid single-tile region; the icon stays hidden
## until a refresh applies a real region.
func _make_slot_icon() -> Dictionary:
	var icon := TextureRect.new()
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var atlas := AtlasTexture.new()
	atlas.atlas = ITEMS_TEX
	atlas.region = WorldGrid.atlas_region(Vector2i.ZERO)
	icon.texture = atlas
	icon.visible = false
	return { "rect": icon, "atlas": atlas }


## Rebuild the own-player TRAIT list from the PLAYER (v0.45.0) — its class's traits plus any granted to
## it specifically, one label per trait that has a display name.
##
## "TRAITS" IS THE PLAYER-FACING NAME (v0.43.0, Jon). The code keeps `PassiveAbility` / `PlayerClass.passives`
## / `resources/passives/` — renaming those is a `.tres` schema break, and this repo has a written precedent
## for an internal name diverging from the displayed one (`backstab.gd` is what the file is called; "Sneak
## Attack" is what the player reads). So the rename cost exactly one header label, because until now the
## concept had NO name on screen at all: the panel listed bare bullets and never said what they were.
##
## The header is built HERE rather than in `_build_char_info` so it can be hidden for the four trait-less
## classes — a heading over nothing is worse than no heading. Hidden means zero height, so those classes'
## columns measure exactly as before.
func _refresh_passives(player: Player) -> void:
	for child in _own_passives_box.get_children():
		child.queue_free()
	# CLASS FIRST, THEN GRANTED, THEN GEAR — the same order Player.all_traits() (and so
	# CombatReferee._passives_of) builds the union in, so the panel lists traits in the sequence they
	# actually chain. A list that disagreed with the referee about order would mislead precisely when two
	# multipliers meet, which is the only time order is visible.
	var class_list: Array = player.player_class.passives if player.player_class != null else []
	# WORN GEAR IS THE THIRD SOURCE (v0.50.0), read through `Player.gear_traits()` — the SAME function
	# `all_traits()` uses, so the panel and the referee can never disagree about which slots are worn or in
	# what order (GLM diff review: two hand-copied slot lists would drift the day a slot becomes real, and
	# would drift silently). Provenance order therefore matches the union's dedupe order exactly:
	# class → granted → gear. A trait a player holds from two of the three shows ONCE, under the earliest —
	# the same "you have it once" fact the referee adjudicates.
	var gear_list: Array = player.gear_traits()
	# The panel enumerates its sources SEPARATELY rather than calling all_traits(), which is why provenance
	# is native to its shape at all — the union deliberately forgets where a trait came from.
	var shown: Array = []
	var any := false
	for entry in [{ "list": class_list, "source": "class" },
			{ "list": player.granted_traits, "source": "granted" },
			{ "list": gear_list, "source": "gear" }]:
		for passive in entry["list"]:
			if passive == null or passive.display_name.is_empty():
				continue
			# IDENTITY dedupe, the union's own guard: a robe granting the trait your class already gives is
			# one trait, and listing it twice would imply it applies twice.
			if passive in shown:
				continue
			shown.append(passive)
			if not any:
				any = true
				var header := _make_label(7)
				header.text = "Traits"
				header.add_theme_color_override("font_color", Color(0.62, 0.68, 0.85, 0.75))
				_own_passives_box.add_child(header)
			var label := _make_label(7)
			# GRANTED TRAITS READ AS EARNED (v0.45.0): a different bullet and a warmer colour, because
			# "what my class gives me" and "what I was given" are different facts about a character and the
			# panel is the only place either is stated. Deliberately not a separate section — they chain
			# together in one order, so listing them apart would imply an independence they do not have.
			# GEAR TRAITS GET THE THIRD MARK (v0.50.0) and it is the one a player most needs: a trait that
			# vanishes when you take the robe off is a different promise from one that is yours, and
			# nothing else on screen says which is which.
			var source: String = str(entry["source"])
			match source:
				"granted":
					label.text = "+ %s" % passive.display_name
					label.add_theme_color_override("font_color", Color(0.95, 0.86, 0.6, 0.95))
				"gear":
					# "»" rather than a geometric-shapes glyph: the project ships no font file, so this
					# renders in Godot's built-in face, and a codepoint it lacks would draw as tofu. This
					# one is Latin-1 and safe, like the "•" and "+" beside it.
					label.text = "» %s" % passive.display_name
					label.add_theme_color_override("font_color", Color(0.68, 0.9, 0.82, 0.95))
				_:
					label.text = "• %s" % passive.display_name
					label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.95, 0.9))
			# HOVERABLE (v0.43.0): _make_label hardcodes IGNORE per the HUD discipline, which is right for
			# every other label in this panel but is exactly what stopped traits from ever having a tooltip.
			# PASS (not STOP) so the label answers a hover without eating a click. The IGNORE on the parent
			# boxes does NOT block this: an IGNORE parent still lets its children be hit-tested.
			label.mouse_filter = Control.MOUSE_FILTER_PASS
			label.tooltip_text = _passive_tooltip(passive)
			_own_passives_box.add_child(label)


## Point the primary-hand icon at the equipped weapon's items.png region (the exact weapon_rig pattern).
## A null weapon hides the icon (bare hands). Refreshed by refresh_self, driven on spawn + on_weapon_swap.
func _set_weapon_icon(weapon: WeaponType) -> void:
	# Tooltip beside the icon (v0.39.0), on the SOCKET — set before the null return so bare hands clear it.
	if _own_weapon_socket != null:
		_own_weapon_socket.tooltip_text = _weapon_tooltip(weapon)
	if weapon == null:
		_own_weapon_icon.visible = false
		return
	_own_weapon_atlas.region = WorldGrid.atlas_region(weapon.atlas_coords)
	_own_weapon_icon.visible = true


## Point the BODY socket's icon at the worn armor's items.png region (v0.27.0) — the exact twin of
## _set_weapon_icon above. A null item hides the icon, revealing the faint "Body" label again (unarmored).
## Refreshed by refresh_self, driven on spawn + on_gear_changed (the equip event / late-join snap).
func _set_body_icon(item: ItemType) -> void:
	if _own_body_socket != null:
		_own_body_socket.tooltip_text = _item_tooltip(item)
	if _own_body_icon == null:
		return
	if item == null:
		_own_body_icon.visible = false
		return
	_own_body_atlas.region = WorldGrid.atlas_region(item.atlas_coords)
	_own_body_icon.visible = true


## The OFF-HAND socket's icon + tooltip (v0.39.0) — the exact twin of _set_body_icon. A null item hides the
## icon and reveals the faint "Off" label again. Driven by refresh_self off Player.equipped_off_hand.
func _set_off_hand_icon(item: ItemType) -> void:
	if _own_off_hand_socket != null:
		_own_off_hand_socket.tooltip_text = _item_tooltip(item)
	if _own_off_hand_icon == null:
		return
	if item == null:
		_own_off_hand_icon.visible = false
		return
	_own_off_hand_atlas.region = WorldGrid.atlas_region(item.atlas_coords)
	_own_off_hand_icon.visible = true


## Paint the ABILITY BAR (v0.20.3; bottom-center since v0.21.0) from the LOCAL player's class active_abilities —
## each filled slot windows the ability's items.png icon (the item-icon pattern); an empty/unauthored slot hides
## its icon. A null class hides all. Called from refresh_self (spawn + class change), so switching class repaints
## the bar with its abilities. (Fixed in v0.21.0: this doc block previously carried _refresh_bag's paragraph too.)
func _refresh_abilities(player: Player) -> void:
	# v0.47.0: the SAME ordered read the host adjudicates from (Player.ability_slots) — class abilities then
	# granted ones. Painting from a separately-built list would be the one way a socket's picture could
	# describe a different ability than the one its key casts.
	var abilities: Array = player.ability_slots()
	for i in _ability_icons.size():
		var ability: ActiveAbility = abilities[i] if i < abilities.size() else null
		# The TOOLTIP is set in the same breath as the icon (v0.39.0) — from the same resource, in the same
		# branch — so the picture and the words can never describe different abilities. An empty slot is
		# cleared to "", which Godot renders as no tooltip at all.
		if ability != null:
			_ability_atlases[i].region = WorldGrid.atlas_region(ability.atlas_coords)
			_ability_icons[i].visible = true
			_ability_names[i] = ability.display_name
			_ability_sockets[i].tooltip_text = _ability_tooltip(ability)
		else:
			_ability_icons[i].visible = false
			_ability_names[i] = ""
			_ability_sockets[i].tooltip_text = ""
		# A class change re-keys the sockets, so any overlay still draining belongs to the OLD loadout — clear
		# it rather than leave a stale scrim over a different ability (v0.26.0). The referee's cooldown map is
		# untouched by this: the cooldown is still charged, the eye just stops being told about the wrong socket.
		_clear_ability_cooldown(i)


## Paint the BAG grid (v0.18.0 chunk B; v0.19.x adds weapons; renamed from _refresh_hotbar in v0.21.0) from the
## LOCAL player's inventory mirror (Array[String] of display_names, in slot order). For each slot: a filled slot
## windows the item's items.png region out of ITEMS_TEX (the _set_weapon_icon pattern) — resolved via
## item_by_name (a consumable) OR weapon_by_name (a looted weapon), both exposing atlas_coords; an empty or
## unresolvable name hides the icon back to a bare socket. Reads the local player through $Players like
## refresh_self; no-op when we have no player.
func _refresh_bag() -> void:
	var me := _players.get_node_or_null(str(_own_id)) as Player if _players != null else null
	var bag: Array = me.inventory if me != null else []
	# Bounded by the ICON ARRAY, never by the socket count or the mirror's length: the array holds exactly the
	# in-capacity sockets, so a decorative filler socket can never be painted and an over-long mirror can never
	# overrun the grid.
	for i in _bag_icons.size():
		var entry := str(bag[i]) if i < bag.size() else ""
		var coords := _bag_icon_coords(entry) if not entry.is_empty() else Vector2i(-1, -1)
		# Tooltip beside the icon, from the same NAME (v0.39.0) — an unresolvable entry yields "" from both,
		# so a slot can never show a picture with no words or words with no picture.
		_bag_slots[i].tooltip_text = _bag_tooltip(entry)
		if coords.x >= 0:
			_bag_atlases[i].region = WorldGrid.atlas_region(coords)
			_bag_icons[i].visible = true
		else:
			# Empty slot OR an unresolvable name (absent from both catalogs) — clear back to a bare socket rather
			# than leave a stale icon; the config-validation guards warn on a genuinely missing/ambiguous name.
			_bag_icons[i].visible = false


# ── Tooltips (v0.39.0; sized + de-jargoned v0.41.0) ───────────────────────────
#
## Tooltip text size, matching the chat log's authored font (v0.41.0, Jon: "quite a bit smaller… the same
## size as the font in the chat window"). THE ROOT CAUSE of v0.39.0's huge tooltips was that this project
## has NO project theme at all — nothing sets `gui/theme/custom` and no theme resource exists — so
## tooltips fell back to Godot's DEFAULT theme at its default font size while the rest of the UI runs
## 6-13px.
##
## Size is what fixes the POSITION too, which is why Jon's "the potion one looks right, bottom-right of the
## cursor" was the clue rather than a second request: Godot places a tooltip at the cursor and only shoves
## it elsewhere when it would run off-screen. Shrink them all and they all sit where the potion's does.
const TOOLTIP_FONT_PX := 6


## Build + attach the tooltip theme (v0.41.0). Per the 4.7 class reference (Control.xml), the default
## tooltip is a PopupPanel + Label themed through the "TooltipPanel" and "TooltipLabel" theme types, and a
## Control's theme propagates to the tooltips its subtree owns — so one assignment on the HUD root covers
## every tooltip in the game (all tooltip-bearing controls are HUD sockets and bag slots).
func _apply_tooltip_theme() -> void:
	var theme := Theme.new()
	theme.set_font_size("font_size", "TooltipLabel", TOOLTIP_FONT_PX)
	# A tight, opaque panel: the default stylebox is padded for 16px type and looks like a dialog around
	# 6px text. Matches the debug panel's dark backing so the two read as one UI.
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.09, 0.10, 0.13, 0.96)
	box.border_color = Color(0.30, 0.32, 0.40, 0.9)
	box.set_border_width_all(1)
	box.content_margin_left = 3.0
	box.content_margin_right = 3.0
	box.content_margin_top = 2.0
	box.content_margin_bottom = 2.0
	theme.set_stylebox("panel", "TooltipPanel", box)
	_root.theme = theme
#
# THE ONE RULE, so every tooltip in the game reads the same way:
#   NUMBERS ARE DERIVED, PROSE IS AUTHORED.
# The derived line is built HERE from the resource's own live fields; the authored `description` follows
# on its own line when non-empty and never replaces it. So retuning a heal, an armour percentage or an
# ability's cooldown in the debug panel moves the tooltip in the same breath, and no `.tres` can ever
# quote a stale figure — which is precisely why the numeric items are NOT hand-written.
#
# Presentation only. Nothing here adjudicates, and every peer resolves the same resources.


## Assemble "NAME", a blank line, then whichever of the derived/authored parts exist. Godot renders a
## multi-line tooltip as-is, which gives the name-on-top / meaning-underneath shape without a custom
## tooltip Control. A nameless thing yields "" — and an empty tooltip_text shows no tooltip at all,
## which is the right outcome for an empty socket.
func _compose_tooltip(item_name: String, derived: String, prose: String) -> String:
	if item_name.is_empty():
		return ""
	var body := ""
	if not derived.is_empty():
		body = derived
	if not prose.is_empty():
		body = prose if body.is_empty() else body + "\n" + prose
	return item_name if body.is_empty() else "%s\n\n%s" % [item_name, body]


## BEATS ARE A DEV UNIT AND NEVER APPEAR IN A TOOLTIP (v0.41.0, Jon). Converts an authored beat count into
## the seconds a player actually experiences, trimmed: 7.5 → "7.5s", 10.0 → "10s".
##
## Uses the TACTICAL beat — the fight tempo, and the one every ability was tuned against. Out of combat the
## explore beat is slower, so a root really does hold longer than the tooltip says; quoting the fight
## number is the honest simplification because casting is a fight activity, and nothing in the UI shows a
## victim a countdown that could contradict it. Read live, so a `/config tactical_beat_sec` retune moves
## every tooltip with it.
func _secs(beats: float) -> String:
	var s := beats * GameManager.tactical_beat_sec
	return "%.0fs" % s if is_equal_approx(s, roundf(s)) else "%.1fs" % s


## Weapon speed as a WORD rather than a number (v0.41.0, Jon's bands). Reads the weapon's TOTAL committed
## beats — windup plus recovery — because that is what "how fast is this weapon" actually means: the whole
## window you are locked into per swing, not either half. It is also the only reading that separates the
## shipped roster (dagger 6 fast, longsword 7 normal, club 7 normal, bow 11 slow); recovery-only or
## windup-only collapse three or four of them into a single bucket and the label stops saying anything.
##
## The bands encode an opinion about the CURRENT four weapons, not a general law — retune them here when
## the roster grows.
const _SPEED_FAST_BELOW := 7.0
const _SPEED_NORMAL_MAX := 10.0

func _attack_speed_word(total_beats: float) -> String:
	if total_beats < _SPEED_FAST_BELOW:
		return "fast"
	return "normal" if total_beats <= _SPEED_NORMAL_MAX else "slow"


## Tooltip for a class TRAIT (v0.43.0) — what the character panel's hover shows.
##
## The DERIVED half is delegated to the trait itself (`PassiveAbility.tooltip_terms`) rather than computed
## here, and that is the whole design of this feature: a trait's numbers live on its SUBCLASS
## (`Backstab.damage_multiplier`, `Archery.windup_beats_delta`), which this file cannot reach through the
## `PassiveAbility` base type. Doing it here would mean `if passive is Backstab: …` growing an arm per
## trait — a presentation file re-coupled to every ability ever written. Asking the trait keeps the
## existing split: the referee owns WHEN a hook fires, the trait owns WHETHER it applies, and now also how
## it describes itself.
##
## Composed through the SAME `_compose_tooltip` every other tooltip uses, so a trait with neither terms nor
## prose degrades to just its name — the identical no-content behaviour an ability with no description
## already has.
func _passive_tooltip(passive: PassiveAbility) -> String:
	if passive == null:
		return ""
	return _compose_tooltip(passive.display_name, ", ".join(passive.tooltip_terms()),
			passive.description)


## Tooltip for a consumable / worn ITEM.
##
## The ARMOUR line states the real two-term rule (DESIGN §2.3.8) rather than just the percentage, because
## half a rule is a misleading rule. CAREFUL READING OF THE REFEREE, since this text is a promise to the
## player: combat_referee applies `mini(pct_result, flat_result)` — the smaller resulting DAMAGE, which is
## the LARGER reduction. So "whichever is greater" is correct even though the referee's operator is a min:
## the tooltip speaks in reductions, the referee speaks in damage. The flat figure comes from
## GameConfig.armor_flat_for, the same function the referee calls, so the two cannot disagree.
##
## GATED so a non-armour EQUIPMENT item (the kite shield: 0% and UNARMORED) prints no armour line at all,
## rather than "0% or 0, whichever is greater" under its prose.
func _item_tooltip(item: ItemType) -> String:
	if item == null:
		return ""
	var derived := ""
	if item.category == ItemType.Category.POTION or item.heal_amount > 0:
		derived = "Heals %d HP." % item.heal_amount
	elif item.phys_damage_reduction > 0.0 or item.armor_weight != ItemType.ArmorWeight.UNARMORED:
		var flat := GameManager.config.armor_flat_for(item.armor_weight)
		derived = "Reduces physical damage by %d%% or %d, whichever is greater." % [
				int(round(item.phys_damage_reduction * 100.0)), flat]
	# GRANTED TRAITS (v0.50.0) — so an item in the BAG advertises what wearing it would give you, before
	# you wear it. Composed from the live resources like every other derived line: the trait's own name
	# plus its own `tooltip_terms()`, which is the same delegation `_passive_tooltip` uses and the reason
	# the HUD needs no `if item is …` arm per magical item. NUMBERS DERIVED, PROSE AUTHORED holds: the
	# figures come from the trait's fields, so a `/pa` retune moves this text with it.
	for t in item.granted_traits:
		if t == null or t.display_name.is_empty():
			continue
		var terms := ", ".join(t.tooltip_terms())
		var line := "Grants %s%s." % [t.display_name, (" (%s)" % terms) if not terms.is_empty() else ""]
		derived = line if derived.is_empty() else "%s\n%s" % [derived, line]
	return _compose_tooltip(item.display_name, derived, item.description)


## Tooltip for an equipped WEAPON — its damage band and the two halves of its committed window, plus reach
## for a ranged one. All live off the resource, so a `/w` retune is reflected immediately.
## Tooltip for an equipped WEAPON. TWO LINES since v0.41.0, per Jon: damage, then attack speed underneath.
## The raw windup/recovery beats are gone from the player's view — they are a dev unit, and the debug panel
## keeps them. Everything is still read live off the resource, so a `/w` retune moves the text.
func _weapon_tooltip(weapon: WeaponType) -> String:
	if weapon == null:
		return ""
	var lines: Array[String] = ["%d-%d damage" % [weapon.damage_min, weapon.damage_max]]
	lines.append("Attack speed: %s" % _attack_speed_word(weapon.windup_beats + weapon.recovery_beats))
	if weapon.range_tiles > 0:
		lines.append("Range: %d tiles" % weapon.range_tiles)
	return _compose_tooltip(weapon.display_name, "\n".join(lines), weapon.description)


## Tooltip for an ACTIVE ABILITY. The derived line lists only the terms this ability actually authors
## non-zero, so Kick shows a stun and a cooldown with no damage, and Shield Block shows a cooldown alone —
## an ability never advertises a number it does not have.
func _ability_tooltip(ability: ActiveAbility) -> String:
	if ability == null:
		return ""
	# SECONDS, never beats (v0.41.0). Every duration converts through _secs; only damage, reach and tick
	# COUNT stay as bare numbers, because those are already the units a player thinks in.
	var parts: Array[String] = []
	if ability.damage > 0:
		parts.append("%d damage" % ability.damage)
	if ability.dot_damage > 0 and ability.dot_ticks > 0:
		# The DoT reads as its whole story rather than three separate numbers: what it does, how often,
		# how many times. "2 damage every 1.5s, 4 times" is a sentence; "dot_interval 6" is a field name.
		# TWO DEGENERATE SHAPES the phrasing must not mangle (GLM diff review): a SINGLE tick has no
		# "every", and neither does a zero interval — is_valid_ability refuses a multi-tick DoT authored
		# without one, so this is the single-tick case and a misauthoring both landing on the same branch.
		if ability.dot_ticks == 1 or ability.dot_interval_beats <= 0.0:
			parts.append("%d damage over time" % ability.dot_damage)
		else:
			parts.append("%d damage every %s, %d times" % [
					ability.dot_damage, _secs(ability.dot_interval_beats), ability.dot_ticks])
	# ORB VOLLEY (v0.43.0) — the TOTAL leads, because "6 damage" is the number a player budgets against;
	# the shape follows so the spread over time is not a surprise. A single orb drops the "in N orbs"
	# clause, which would be a strange way to describe one projectile.
	if ability.orb_damage > 0 and ability.orb_count > 0:
		if ability.orb_count == 1:
			parts.append("%d damage" % ability.orb_damage)
		else:
			parts.append("%d damage in %d orbs" % [ability.orb_damage * ability.orb_count,
					ability.orb_count])
	if ability.stun_beats > 0.0:
		parts.append("stuns for %s" % _secs(ability.stun_beats))
	if ability.root_beats > 0.0:
		parts.append("holds for %s" % _secs(ability.root_beats))
	# BLINK REACH (v0.43.0) — phrased as the distance it can move you, not as the field name. "up to"
	# because the destination is random within the reach, so the number is a bound and not a promise.
	if ability.blink_travel_tiles > 0:
		parts.append("blinks up to %d tiles" % ability.blink_travel_tiles)
	# RESOLVED REACH (v0.49.0; through the resolver since v0.50.0): quote the reach this player ACTUALLY
	# has, not the ability's authored number — a tooltip that says 6 while the ring draws 7 is the same lie
	# in a different place. The SAME `targeted_reach` the ring and the host's gate use, so all three agree
	# by construction. Own player only, which is all this tooltip has ever described.
	var reach: int = ability.range_tiles
	if ability.kind == ActiveAbility.Kind.TARGETED and _players != null:
		var me := _players.get_node_or_null(str(_own_id)) as Player
		if me != null:
			reach = me.targeted_reach(ability)
	if reach > 1:
		parts.append("range %d tiles" % reach)
	if ability.windup_beats + ability.recovery_beats > 0.0:
		parts.append("%s cast" % _secs(ability.windup_beats + ability.recovery_beats))
	if ability.mana_cost > 0:
		parts.append("%d mana" % ability.mana_cost)
	if ability.cooldown_beats > 0.0:
		parts.append("%s cooldown" % _secs(ability.cooldown_beats))
	var derived := (", ".join(parts) + ".") if not parts.is_empty() else ""
	return _compose_tooltip(ability.display_name, derived, ability.description)


## Tooltip for a BAG entry by NAME — resolved consumable-first then weapon, the same order (and for the
## same disjoint-catalogs reason) as _bag_icon_coords. An unresolvable name yields "" (no tooltip).
func _bag_tooltip(name: String) -> String:
	var it := GameManager.config.item_by_name(name)
	if it != null:
		return _item_tooltip(it)
	return _weapon_tooltip(GameManager.config.weapon_by_name(name))


## The items.png cell for a bag entry NAME, resolving a consumable (item_catalog) first, then a looted weapon
## (weapon_catalog) — both expose atlas_coords. Returns (-1, -1) for an empty/unresolvable name (hide the icon).
## The cross-catalog uniqueness guard (GameConfig) keeps the two disjoint, so the item-first order is unambiguous.
func _bag_icon_coords(name: String) -> Vector2i:
	var it := GameManager.config.item_by_name(name)
	if it != null:
		return it.atlas_coords
	var w := GameManager.config.weapon_by_name(name)
	if w != null:
		return w.atlas_coords
	return Vector2i(-1, -1)


## A left-click on bag slot `slot` (v0.19.x): forward it to main.gd via slot_activated. Only a LEFT press
## fires (right/other buttons ignored). The HUD stays presentation-only — it neither reads the bag's type nor
## submits an intent; main.gd resolves the slot's content and routes to use_item / equip_item. The STOP filter
## on the slot already keeps the click off the world (no accidental move/shoot).
func _on_slot_gui_input(event: InputEvent, slot: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		slot_activated.emit(slot)


## A 32px reserved socket Panel. `accent` = the brighter ability-bar/hands border; a non-empty `label_text`
## draws a faint tiny centred name (empty sockets only — the primary hand carries an icon instead).
func _make_socket(accent: bool, label_text: String) -> Panel:
	var socket := Panel.new()
	socket.custom_minimum_size = Vector2(SLOT_PX, SLOT_PX)
	# HOVERABLE, NOT CLICK-EATING (v0.39.0 tooltips). PASS, deliberately, not STOP: PASS receives mouse
	# movement and the mouse_entered/exited signals — which is all a tooltip needs — while an unhandled
	# click still bubbles up and out to the world handler. STOP would have worked for the right-edge
	# equipment panel and been a REGRESSION for the ability bar, which sits bottom-CENTRE over the play
	# area: every click there would have stopped reaching move_input. One filter serves both because the
	# sockets are display-only; the bag slots keep STOP precisely because they DO consume their clicks.
	# The socket's CHILDREN (label, icon, cooldown scrim) stay IGNORE, so hit-testing skips them and the
	# hover resolves to exactly one control with exactly one tooltip.
	socket.mouse_filter = Control.MOUSE_FILTER_PASS
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
