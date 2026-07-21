class_name DamagePopup
extends Label

## Floating combat text (v0.10.0, §2.3.4 feedback) — a code-built Label that rises + fades over a
## struck tile, then frees itself. Spawned per-peer by main.gd off the SAME `attack` event every peer
## receives, so a landed hit, a whiff, and a godded no-op each read distinctly: red "-N" for damage,
## grey "miss" on a whiff, grey "0" on a godded target (the godded flag lands in chunk 2 — rendered
## only when present). Parented to MAIN (never the target node) at the target tile's world position +
## a small offset, so a KILLING-BLOW popup survives the victim's queue_free — the same Main-parenting
## rationale as the follow camera and the hurt vignette (main.gd).
##
## The ±x jitter is CLIENT-LOCAL COSMETIC ONLY: each peer rolls its own randf offset so rapid hits on
## one tile don't stack into a single blob. It is deliberately NOT synced — jitter differing between
## peers is fine (it never touches adjudication), so a plain randf is used, not a seeded/shared RNG.

## Damage red — shares §2.3.4's hit-red language (the hurt flash / slash streak family). Rendered for
## damage the LOCAL side TAKES (a player was struck), so "I got hit" stays red across every cue.
const DAMAGE_COLOR := Color(1.0, 0.3, 0.3)
## Player→enemy hit white — a blow the party LANDED on a monster, kept visually distinct from the red
## of damage taken so "I hit them" never reads as "I got hit" (v0.10.2, §2.3.4). Crit-yellow is future work.
const PLAYER_HIT_COLOR := Color.WHITE
## Grey for the non-damage outcomes ("miss" on a whiff, "0" on a godded no-op) — deliberately NOT the
## damage red, so "no damage happened" never reads as "you took a hit".
const MISS_COLOR := Color(0.72, 0.72, 0.72)

## How far the popup drifts UP over its lifetime (pixels).
const _RISE_PX := 12.0
## Lifetime: rise + fade to nothing, then free (seconds).
const _LIFETIME_SEC := 0.6
## Max horizontal jitter magnitude (± pixels) so stacked hits on one tile spread out.
const _JITTER_PX := 4.0
## Font size (pixels) — small, to sit over a 32px sprite without dominating it.
const _FONT_SIZE := 8


## Build + return a configured (but un-parented, un-positioned) popup for `text` in `color`. The
## caller sets `position` and add_child()s it — the rise/fade tween starts in _ready, so position
## must be assigned BEFORE the node enters the tree.
static func make(text: String, color: Color) -> DamagePopup:
	var popup := DamagePopup.new()
	popup.text = text
	popup.add_theme_font_size_override("font_size", _FONT_SIZE)
	popup.add_theme_color_override("font_color", color)
	popup.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	popup.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Above the entities (their z_index tops out at 1 for the slash streak); world-space label.
	popup.z_index = 100
	return popup


func _ready() -> void:
	# Size to the text now that the theme overrides are applied, then re-centre `position` (a Label's
	# position is its top-left) on the caller's spawn point and add the per-peer cosmetic x-jitter.
	reset_size()
	var jitter := randf_range(-_JITTER_PX, _JITTER_PX)
	position += Vector2(jitter - size.x * 0.5, -size.y * 0.5)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position", position + Vector2(0.0, -_RISE_PX), _LIFETIME_SEC)
	tween.tween_property(self, "modulate:a", 0.0, _LIFETIME_SEC)
	tween.set_parallel(false)
	tween.tween_callback(queue_free)
