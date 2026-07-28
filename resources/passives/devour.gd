class_name Devour
extends PassiveAbility

## Druid DEVOUR (v0.49.0) — an enemy dying near you feeds you.
##
## The first trait to use the NEARBY-DEATH seam (PassiveAbility.on_nearby_death), which v0.49.0 added for
## it. `after_attack` could not serve: that hook runs the ATTACKER's list, and this trait is about being
## nearby, not about landing the blow. A kill by a teammate feeds you exactly as your own does.
##
## REACH IS WALL-BOUNDED. The referee fans out along a flood fill from the death tile, so `distance` is a
## travel distance — a kill two rooms away through a wall is not "five tiles away" however the crow flies,
## and does not feed you.
##
## THE RESTORE ROUNDS UP with a floor of 1, so the trait can never fire for nothing: a druid's 10-mana pool
## at 25% is 2.5, and a version that rounded down to 2 would be fine while a version that rounded a small
## pool to 0 would make the trait silently inert for exactly the classes most likely to carry it.

## How far a death can be and still feed you, in wall-bounded travel tiles.
@export var radius_tiles: int = 5

## Fraction of your MAXIMUM mana restored. 0.25 = a quarter.
@export var mana_fraction: float = 0.25


## Restore part of the bearer's pool when a hostile dies within reach.
##
## Gated on HOSTILITY rather than on the id sign: the negative-id-means-monster convention is real, but
## hostility is the actual question and the predicate already exists, so a future allied or charmed
## monster needs no edit here.
func on_nearby_death(ctx: Dictionary) -> void:
	if int(ctx.get("distance", 999)) > radius_tiles or mana_fraction <= 0.0:
		return
	var bearer = ctx.get("bearer")
	var combat = ctx.get("combat")
	if bearer == null or combat == null:
		return
	# Hostile to the BEARER, not to the killer — the trait is about what died near you.
	if not bearer.has_method("is_hostile_to"):
		return
	var dead = ctx.get("dead")
	if dead == null or not bearer.is_hostile_to(dead):
		return
	var max_mana: int = combat.max_mana_of(int(ctx.get("bearer_id", 0)))
	if max_mana <= 0:
		return  # not a caster; nothing to feed.
	var restored: int = maxi(1, int(ceil(float(max_mana) * mana_fraction)))
	combat.restore_mana(int(ctx.get("bearer_id", 0)), restored)


func tooltip_terms() -> Array[String]:
	var out: Array[String] = []
	out.append("+%d%% mana on a kill nearby" % int(round(mana_fraction * 100.0)))
	out.append("within %d tiles" % radius_tiles)
	return out
