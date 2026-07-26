class_name DamagePopup
extends Label

## Floating combat text (v0.10.0, §2.3.4 feedback) — a code-built Label that rises + fades over a
## struck tile, then frees itself. Spawned per-peer by main.gd off the SAME `attack` event every peer
## receives, so a landed hit, a whiff, and a godded no-op each read distinctly: a target-keyed red/white
## "-N" for damage (the colour convention below), grey "miss" on a whiff, grey "0" on a godded target.
## Parented to MAIN (never the target node) at the target tile's world position +
## a small offset, so a KILLING-BLOW popup survives the victim's queue_free — the same Main-parenting
## rationale as the follow camera and the hurt vignette (main.gd).
##
## The ±x jitter is CLIENT-LOCAL COSMETIC ONLY: each peer rolls its own randf offset so rapid hits on
## one tile don't stack into a single blob. It is deliberately NOT synced — jitter differing between
## peers is fine (it never touches adjudication), so a plain randf is used, not a seeded/shared RNG.

## ── THE COLOUR CONVENTION (Jon's ruling, 2026-07-26 — v0.28.1) ────────────────────────────────────
## Floating combat text carries ONE meaning in its colour: WHO A NUMBER HAPPENED TO. Four colours, defined
## here and nowhere else (main.gd's attack/heal handlers pick between these consts; no site invents a Color):
##
##   RED    — a PLAYER took the damage.        LIVE.
##   WHITE  — anything else took the damage (a monster). LIVE.
##   GREEN  — a HEAL, on any target.           LIVE (it predates the convention and already conformed).
##   YELLOW — a CRITICAL hit.                  RESERVED, no consumer — there is no crit system (ROADMAP).
##
## Grey (below) is deliberately OUTSIDE the convention: it is the NO-NUMBER-HAPPENED colour ("miss", a
## godded "0", a "block"), so it can never be mistaken for a real number in any of the four.
##
## KEYED OFF THE TARGET, and Jon framed it by ATTACKER ("damage a player deals" vs "damage an enemy deals
## to a player"). The two readings are IDENTICAL for every case that exists today — no self-damage, thorns,
## reflect or PvP — and target-keying was chosen because it is one predicate that answers monster-on-monster
## and any future PvP exhaustively instead of leaving them undefined. THE ONE DIVERGENCE TO REVISIT: if
## self-damage / thorns ever lands, a player damaging THEMSELVES reads RED under target-keying where Jon's
## wording implies white. That is a decision to re-take when the mechanic arrives, NOT a bug to file.
##
## COLOUR NEVER MEANS "WAS IT MITIGATED" (v0.28.1 removed v0.27.1's steel-blue ARMOR_COLOR). §2.3.8's
## §2.3.4 obligation to make armor visible is met by the LOG — game_log's "(13/20, armor absorbs 2)"
## clause — and by the `armor` tag + `absorbed` field, both still stamped on every mitigated hit.

## RED — a PLAYER took the damage. Shares §2.3.4's hit-red language (the hurt flash / slash streak /
## local vignette family), so "I got hit" reads the same across every cue.
const DAMAGE_COLOR := Color(1.0, 0.3, 0.3)
## WHITE — anything that is not a player took the damage, i.e. a monster (v0.10.2). Kept maximally distinct
## from the red above so "I hit them" can never read as "I got hit" (§2.3.4).
const PLAYER_HIT_COLOR := Color.WHITE
## GREEN — a HEAL (v0.18.0 chunk C), the "+N" over a healed target. Already conformed to the convention
## when it was written, so v0.28.1 changed nothing here: recovery reads as its own outcome, never as a hit
## taken or dealt. Legibility unchanged from the shade shipped since v0.18.0.
const HEAL_COLOR := Color(0.35, 0.9, 0.4)
## YELLOW — RESERVED for CRITICAL hits and deliberately UNUSED: no crit system exists (ROADMAP parks it).
## It exists as a const so the next person adding a popup colour reaches for something else instead of
## spending the reservation. When crits land, a crit's colour wins over the target-keyed red/white — that
## is the one sanctioned override of the rule above, because a crit is a distinct OUTCOME, not a side.
const CRIT_COLOR := Color(1.0, 0.85, 0.2)
## GREY — the NON-DAMAGE outcomes ("miss" on a whiff, "0" on a godded no-op, "block" on a shield block).
## Outside the four-colour convention on purpose: no number landed, so it must not read as one.
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
