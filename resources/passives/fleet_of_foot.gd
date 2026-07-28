class_name FleetOfFoot
extends PassiveAbility

## Ranger FLEET OF FOOT (v0.49.0) — rough terrain does not slow you.
##
## The first trait to use the MOVEMENT seam (PassiveAbility.modify_move_beats). Owned by
## resources/classes/ranger.tres; MoveReferee runs it inside the one step-duration resolver, host-side.
##
## WHAT IT CANCELS, EXACTLY: the terrain penalty and nothing else. The referee hands this hook the ROUGH
## candidate rather than the final step cost, precisely so a trait can be this specific — returning the
## mover's own tier undoes rough while leaving the exhausted crawl untouched, because the referee takes
## the slowest of tier / this / crawl afterwards. A Fleet-of-Foot ranger who is out of stamina still
## crawls, which is the honest reading: this is sure-footedness, not tirelessness.
##
## NO TUNABLE FIELDS, deliberately. The trait is binary — you ignore rough or you do not — and inventing a
## dial so the debug panel has a row to draw would be worse than an empty section.


## Return the mover's own tier when the destination is rough, which cancels the terrain cost. Any other
## step returns the candidate untouched, so this hook is a no-op everywhere else.
func modify_move_beats(ctx: Dictionary) -> float:
	if not bool(ctx.get("is_rough", false)):
		return float(ctx.get("beats", 0.0))
	return float(ctx.get("tier_beats", ctx.get("beats", 0.0)))


func tooltip_terms() -> Array[String]:
	var out: Array[String] = []
	out.append("ignores rough ground")
	return out
