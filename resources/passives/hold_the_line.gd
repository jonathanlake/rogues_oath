class_name HoldTheLine
extends PassiveAbility

## Knight HOLD THE LINE (v0.49.0) — stand still and you take less.
##
## The first trait to use the DEFENDER seam (PassiveAbility.modify_damage_taken), which v0.49.0 added for
## it: every hook before this one ran the ATTACKER's list, and nothing had ever asked a target's traits
## anything. Owned by resources/classes/knight.tres; CombatReferee runs it at the one damage chokepoint.
##
## ALL DAMAGE, NOT JUST PHYSICAL (Jon's call). It sits outside the armour block's physical-only guard, so
## it reduces smite, plague and missile too — which is most of what armour deliberately cannot touch, and
## the reason a purely-armour answer would have left the knight no better off against casters.
##
## IT COMPOUNDS WITH ARMOUR rather than competing with it. Armour is a min-combined percent-vs-flat rule;
## folding this in as a third term would mean a plate knight's flat reduction usually swallowing it, so
## the knight's own trait would be invisible on the knight. Running after that rule instead makes it
## always worth something. The monster-damage floor still runs last, so this can never make a blow free.
##
## THE CLOCK IS MOVEMENT-ONLY (Jon's ruling): attack, cast and drink freely while braced — standing your
## ground IS the trait. A blink or a knockback breaks it, because those move the body. A STUN does not,
## which means a stunned knight keeps bracing; that follows from the rule as chosen and is the one case
## worth watching in play.

## Beats of stillness before the brace applies. Read live, so `/pa hold_the_line brace_beats 4` retunes
## the very next hit.
@export var brace_beats: float = 10.0

## Fraction of the incoming blow turned aside while braced. 0.15 = 15%.
@export var damage_reduction: float = 0.15


## Reduce the blow if this defender has held still long enough.
##
## HALF-UP ROUNDING, matching every other number at this seam, and it is what stops the trait silently
## zeroing small hits: a 1-damage tick × 0.85 rounds back to 1 rather than to 0. A trait that made ticks
## vanish entirely would be a very different mechanic from "you take a bit less".
func modify_damage_taken(ctx: Dictionary) -> int:
	var amount := int(ctx.get("amount", 0))
	if amount <= 0 or damage_reduction <= 0.0:
		return amount
	# The clock is HANDED IN by the referee, never fetched: a trait is given authoritative state and does
	# not reach for a referee it has no reference to (the passive contract). An absent key reads as "just
	# moved", so a caller that has not supplied it simply gets no reduction rather than a wrong one.
	if float(ctx.get("beats_since_move", 0.0)) < brace_beats:
		return amount
	return maxi(0, int(floor(amount * (1.0 - damage_reduction) + 0.5)))


func tooltip_terms() -> Array[String]:
	var out: Array[String] = []
	out.append("%d%% less damage" % int(round(damage_reduction * 100.0)))
	out.append("after %s still" % _secs(brace_beats))
	return out


## Beats -> a player-facing seconds string, the local twin of hud.gd's `_secs` (a Resource must not reach
## into a UI node; GameManager is the autoload both read). Whole numbers print without a decimal.
func _secs(beats: float) -> String:
	var s := beats * GameManager.tactical_beat_sec
	return "%.0fs" % s if is_equal_approx(s, roundf(s)) else "%.1fs" % s
