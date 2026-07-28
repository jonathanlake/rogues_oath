class_name Spellreach
extends PassiveAbility

## Wizard SPELLREACH (v0.49.0) — your targetable spells reach one tile further.
##
## THE ONLY TRAIT SO FAR THAT IS EVALUATED ON BOTH SIDES rather than inside a referee, and the reason the
## host-only line is drawn where it is. Every other trait mutates something inside a referee, which is
## host-only and inert on clients. This one has to be answered on BOTH: the host resolves the reach for
## its range gate, and the client resolves the same reach for the targeting ring it draws while you aim.
## If only the host knew, the ring would promise a reach the host refuses at its edge; if only the client
## knew, it would refuse to arm on tiles the host would have accepted.
##
## That works because the contribution is a pure read of replicated data — the class resource every peer
## loads, plus `granted_traits` and worn gear, which every peer maintains from the same events — routed
## through the ONE union (Player.all_traits) and the ONE accessor (Player.targeted_reach). Not a synced
## number: a number would need keeping in step, and there is nothing here to fall out of step.
##
## v0.50.0 COLLAPSED IT INTO THE RESOLVER. Through v0.49.0 this trait was hand-threaded through four call
## sites via a bespoke `spell_range_bonus()` query on PassiveAbility, Player AND CombatReferee; now it is
## one contribution to the ABILITY_RANGE stat and the three query functions are gone. That deletion was
## the point of migrating this stat first (`docs/modifier-resolver.md`).
##
## SCOPED TO TARGETED CASTS by the callers, not by this resource. `WeaponType.range_tiles` shares only a
## name with `ActiveAbility.range_tiles` and is the codebase's is-this-ranged predicate in a dozen places
## (including the arrow's flight extension), so a bow must never see this.
##
## AUTHORED TWICE, DELIBERATELY (v0.50.0): the wizard's class Spellreach and the robe of farsight's
## Farsight are two DISTINCT `.tres` files sharing this script, so `all_traits()`'s identity dedupe keeps
## both and their flats sum — a wizard in the robe reaches +2. That is the additive-stacking ruling made
## playable, and it needed no family/rank machinery to get there.

## Extra reach in tiles. Sums across traits if a player ever holds two, which is the arithmetic anyone
## would expect from two things that each say "+1 range".
@export var range_bonus: int = 1


## Gated on the STAT first, per the contract — a contribution that forgot the gate would push its tiles
## into every stat in the game. An int field becomes a float "flat"; `Player.targeted_reach` is the one
## place the resolved total is rounded back to tiles.
func modify_stat(stat: StringName, _ctx: Dictionary) -> Dictionary:
	if stat == Stats.ABILITY_RANGE:
		return { "flat": float(range_bonus) }
	return {}


func tooltip_terms() -> Array[String]:
	var out: Array[String] = []
	out.append("+%d spell range" % range_bonus)
	return out
