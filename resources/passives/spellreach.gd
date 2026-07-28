class_name Spellreach
extends PassiveAbility

## Wizard SPELLREACH (v0.49.0) — your targetable spells reach one tile further.
##
## THE ONLY TRAIT SO FAR THAT IS A QUERY RATHER THAN A HOOK, and the reason that distinction exists. Every
## other trait mutates something inside a referee, which is host-only and inert on clients. This one has to
## be answered on BOTH sides: the host adds it to its range gate, and the client adds it to the targeting
## ring it draws while you aim. If only the host knew, the ring would promise a reach the host refuses at
## its edge; if only the client knew, it would refuse to arm on tiles the host would have accepted.
##
## That works because a query is a pure read of replicated data — the class resource every peer loads, plus
## `granted_traits`, which every peer maintains from the same events — routed through the ONE union
## (Player.all_traits). Not a synced number: a number would need keeping in step, and there is nothing here
## to fall out of step.
##
## SCOPED TO TARGETED CASTS by the callers, not by this resource. `WeaponType.range_tiles` shares only a
## name with `ActiveAbility.range_tiles` and is the codebase's is-this-ranged predicate in a dozen places
## (including the arrow's flight extension), so a bow must never see this.

## Extra reach in tiles. Sums across traits if a player ever holds two, which is the arithmetic anyone
## would expect from two things that each say "+1 range".
@export var range_bonus: int = 1


func spell_range_bonus() -> int:
	return range_bonus


func tooltip_terms() -> Array[String]:
	var out: Array[String] = []
	out.append("+%d spell range" % range_bonus)
	return out
