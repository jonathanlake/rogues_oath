class_name PartyFrame
extends PanelContainer

## One party-roster frame in the left HUD column (v0.12.0). A COMPONENT in the strict sense: the HUD
## parent hands it a Player node reference (bind) and pushes HP into it (set_hp / mark_dead); it never
## reaches up the tree and never adjudicates — pure presentation off the events main.gd already fans
## out. The Player reference it holds is a sibling handed by the parent, not a get_parent() climb.
##
## Portrait: the class sprite region drawn through an AtlasTexture over the shared rogues atlas (the
## same source Player.set_class repaints from) — refresh_portrait re-reads player.player_class.atlas_coords
## on a class change. HP: a ColorRect fill over a dark track, green→red by fraction; "DEAD" greys the frame.

# The shared class atlas (assets/32rogues/rogues.png) — preloaded by its editor-assigned uid so a
# move/rename can't break it (CLAUDE.md convention). Same texture the player Sprite2D regions from.
const ROGUES_ATLAS: Texture2D = preload("uid://djrojs1kpsyss")

# Own-frame accent (a warm border so a player picks their own frame out of the roster at a glance).
const _OWN_BORDER := Color(0.85, 0.72, 0.32, 0.9)
# HP-bar endpoints: full = green, empty = red, lerped by the live fraction.
const _BAR_FULL := Color(0.30, 0.75, 0.30, 1.0)
const _BAR_EMPTY := Color(0.80, 0.20, 0.20, 1.0)
# The whole-frame grey held while a player is DEAD (modulate multiplies every child, portrait included).
const _DEAD_TINT := Color(0.5, 0.5, 0.55, 1.0)

@onready var _portrait: TextureRect = $Row/Portrait
@onready var _name_label: Label = $Row/Info/NameLabel
@onready var _hp_fill: ColorRect = $Row/Info/HpBar/Fill
@onready var _hp_text: Label = $Row/Info/HpBar/HpText

# The AtlasTexture that windows the class sprite out of ROGUES_ATLAS; region set in refresh_portrait.
var _atlas := AtlasTexture.new()
# The Player node this frame mirrors, handed by the HUD parent in bind(). Presentation read only.
var _player: Player = null


func _ready() -> void:
	_atlas.atlas = ROGUES_ATLAS
	# Seed a VALID initial region: an AtlasTexture with a zero-size region (Rect2(0,0,0,0)) draws the
	# ENTIRE atlas (documented fallback), which with a TextureRect's default expand would blow the frame
	# out to full-sheet size. A single-tile region + EXPAND_IGNORE_SIZE means a bad/unbound texture can
	# never resize the panel. The portrait stays HIDDEN until the first bind applies the real class region.
	_atlas.region = WorldGrid.atlas_region(Vector2i.ZERO)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.visible = false
	_portrait.texture = _atlas


# ── Public methods ──────────────────────────────────────────────────────────

## Bind (or re-bind, on respawn) this frame to a Player node handed by the HUD parent. Clears any
## DEAD grey, seeds the name + portrait, and accents the local player's own frame with a warm border.
func bind(player: Player, is_own: bool) -> void:
	_player = player
	modulate = Color.WHITE
	_name_label.text = player.player_name
	refresh_portrait()
	if is_own:
		var sb := (get_theme_stylebox("panel") as StyleBoxFlat).duplicate() as StyleBoxFlat
		sb.set_border_width_all(1)
		sb.border_color = _OWN_BORDER
		add_theme_stylebox_override("panel", sb)


## Re-read the bound player's class sprite region (v0.12.0 — driven on a class_changed for this id).
func refresh_portrait() -> void:
	if _player == null or _player.player_class == null:
		return
	_atlas.region = WorldGrid.atlas_region(_player.player_class.atlas_coords)
	# A real class region is now bound — reveal the portrait (hidden at build until this first bind).
	_portrait.visible = true


## Update the HP bar + text from an attack event's running HP (pushed by the HUD, never queried).
func set_hp(cur: int, max_hp: int) -> void:
	var frac := clampf(float(cur) / float(maxi(max_hp, 1)), 0.0, 1.0)
	_hp_fill.anchor_right = frac
	_hp_fill.offset_right = 0.0
	_hp_fill.color = _BAR_EMPTY.lerp(_BAR_FULL, frac)
	_hp_text.text = "%d/%d" % [cur, max_hp]


## Grey the frame and read "DEAD" (v0.12.0). The frame PERSISTS greyed so the party can see a downed
## teammate; a respawn re-binds (un-greys), a disconnect removes it (HUD.remove_frame).
func mark_dead() -> void:
	modulate = _DEAD_TINT
	_hp_fill.anchor_right = 0.0
	_hp_fill.offset_right = 0.0
	_hp_text.text = "DEAD"
