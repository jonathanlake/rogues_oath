class_name Backstab
extends PassiveAbility

## Rogue SNEAK ATTACK (v0.11.0 as "backstab"; REDESIGNED v0.27.0 — Jeff's second playtest verdict). A
## dagger-only damage multiplier that fires when the target is COMPROMISED rather than merely turned
## around. Owned by resources/classes/rogue.tres via its `passives` array; CombatReferee runs it through
## modify_damage at the BeforeDamageApplied seam (host-only, server-authoritative). Feel-tunable in
## backstab.tres — multiplier and the required weapon are both `.tres` fields.
##
## WHY THE REDESIGN: the behind-arc test was invisible in play. A player cannot read an 8-way facing off a
## 32px sprite, monsters turn to face whatever they attack, and a never-moved monster faces NOWHERE (ZERO)
## and so could never be backstabbed at all — so the class's signature move fired by accident or not at
## all. The new triggers are both things the player can SEE and CREATE: an ally on the far side of the
## target (a flank the party sets up together — Jeff wanted it co-op-shaped), or a STUNNED target (which
## is what the rogue's own Kick is for: kick, then sneak).
##
## FILENAME NOTE (v0.27.0): the script + `.tres` deliberately KEEP their `backstab.*` names even though
## every user-facing string is now "sneak attack". Renaming a `.tres` breaks loads through Godot's uid
## cache (a known landmine in this repo), and this release ships without harness testing — so the rename
## is not worth the risk. The class_name, the file names and rogue.tres's ext_resource path are internal;
## the display_name, the event tag ("sneak") and the log line are what a player reads.

## Multiplier applied to the FINAL damage (post any earlier passive in the chain) on a qualifying sneak
## attack. 2.0 = double; the dagger's rolled 2-6 becomes 4-12. A designer knob — no magic number.
@export var damage_multiplier: float = 2.0

## The weapon this passive requires equipped to fire — the dagger (backstab.tres wires dagger.tres).
## Matched by RESOURCE_PATH, not instance identity: Godot shares one .tres instance per path today, but
## a future duplicate()/local-to-scene copy would silently break an `==` identity check, whereas the
## path is immune. Null (unset) disables the passive (it can never match a null-weapon attacker).
@export var required_weapon: WeaponType = null


## The DERIVED tooltip half (v0.43.0) — see PassiveAbility.tooltip_terms for the contract. Quotes the two
## things a player can act on: what the multiplier is worth, and which weapon it demands. The TRIGGERS
## (flanked or stunned) are deliberately left to the authored prose — they are a mechanic, not a number,
## and spelling out "×2.0 when flanked_by_ally or target_stunned" would be the math-not-mechanic failure
## the house rule exists to prevent.
##
## The weapon name is read LIVE off `required_weapon`, so re-pointing the .tres at a different weapon
## retunes the tooltip in the same edit. A null required_weapon quotes no weapon clause rather than
## printing "<null>" — that authoring state already disables the trait, so the tooltip stays honest about
## it doing nothing.
## (Note the number formatting: GDScript's `%` has no `%g`, so a whole multiplier is printed as an int and
## a fractional one to one place — "2× damage", not "2.000000×". Mirrors hud.gd's `_secs` idiom.)
func tooltip_terms() -> Array[String]:
	var out: Array[String] = []
	var mult := ("%d" % int(damage_multiplier)) if is_equal_approx(damage_multiplier, roundf(damage_multiplier)) \
			else ("%.1f" % damage_multiplier)
	out.append("%s× damage" % mult)
	if required_weapon != null:
		out.append("%s only" % required_weapon.display_name)
	return out


## modify_damage (v0.27.0 triggers): multiply the blow when the attacker wields the required weapon AND
## the target is COMPROMISED — either FLANKED BY AN ALLY (a living, non-hostile entity stands on the tile
## directly opposite the attacker, i.e. the target is sandwiched) or STUNNED. Both booleans are
## precomputed HOST-side by CombatReferee._build_damage_ctx from authoritative occupancy/state, so this
## passive stays a pure reader (the PassiveAbility contract) and no positional math lives here.
## On a hit, tag the outcome "sneak" so every peer plays the distinct cue (§2.3.4: log line + popup +
## pitched sound — main.gd/game_log). Non-qualifying hits return the amount unchanged and tag nothing.
##
## The behind-arc static (CombatReferee.is_attack_from_behind) is deliberately LEFT IN PLACE and is simply
## no longer called from here: the parked "should an idle monster have a default facing?" question
## (ROADMAP) still references it, and it is a pure-math helper any future system may reuse.
func modify_damage(ctx: Dictionary) -> int:
	var amount := int(ctx.get("amount", 0))
	var weapon = ctx.get("weapon")
	# Weapon gate: an equipped weapon whose path matches the required one. A bare-handed attacker
	# (weapon null) or an unset required_weapon can never sneak attack.
	if weapon == null or required_weapon == null:
		return amount
	if weapon.resource_path != required_weapon.resource_path:
		return amount
	# Compromised-state gate. `.get` with a default on both, so an older/partial ctx degrades to
	# "not a sneak attack" rather than erroring mid-hit.
	if not (bool(ctx.get("flanked_by_ally", false)) or bool(ctx.get("target_stunned", false))):
		return amount
	var tags: Array = ctx.get("tags", [])
	tags.append("sneak")
	return int(round(amount * damage_multiplier))
