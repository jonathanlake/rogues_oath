class_name Backstab
extends PassiveAbility

## Rogue BACKSTAB (v0.11.0, Jeff's first class passive; DESIGN §2.3). A dagger-only, attack-from-behind
## damage multiplier — the rogue's class identity. Owned by resources/classes/rogue.tres via its
## `passives` array; CombatReferee runs it through modify_damage at the BeforeDamageApplied seam
## (host-only, server-authoritative). A frontal or flank hit, or a non-dagger weapon, passes through
## untouched. Feel-tunable in backstab.tres — multiplier and the required weapon are both .tres fields.

## world/combat_referee.gd, preloaded for its `is_attack_from_behind` STATIC (that referee has no
## class_name by design — the referees hold each other untyped — so a passive author reaches the shared
## behind-arc math through the loaded script rather than a global name). No instance is created here.
const _CombatReferee := preload("uid://bxwx82w24gbfp")

## Multiplier applied to the FINAL damage (post any earlier passive in the chain) on a qualifying
## backstab. 2.0 = double; the shipped dagger's 2 damage becomes 4. A designer knob — no magic number.
@export var damage_multiplier: float = 2.0

## The weapon this passive requires equipped to fire — the dagger (backstab.tres wires dagger.tres).
## Matched by RESOURCE_PATH, not instance identity: Godot shares one .tres instance per path today, but
## a future duplicate()/local-to-scene copy would silently break an `==` identity check, whereas the
## path is immune. Null (unset) disables the passive (it can never match a null-weapon attacker).
@export var required_weapon: WeaponType = null


## modify_damage (v0.11.0): double the blow when the attacker wields the required weapon AND strikes the
## target from behind (rear 3 octants of the defender's 8-way facing; a ZERO defender facing — never
## moved — never qualifies). On a hit, tag the outcome "backstab" so every peer plays the distinct cue
## (§2.3.4: log line + popup + pitched sound, main.gd/game_log). Non-qualifying hits return the amount
## unchanged and tag nothing. All inputs are host-authoritative (built by CombatReferee._build_damage_ctx).
func modify_damage(ctx: Dictionary) -> int:
	var amount := int(ctx.get("amount", 0))
	var weapon = ctx.get("weapon")
	# Weapon gate: an equipped weapon whose path matches the required one. A bare-handed attacker
	# (weapon null) or an unset required_weapon can never backstab.
	if weapon == null or required_weapon == null:
		return amount
	if weapon.resource_path != required_weapon.resource_path:
		return amount
	# Positional gate: the DEFENDER's own facing (ctx.target_facing) vs the approach, via the shared static.
	if not _CombatReferee.is_attack_from_behind(ctx.get("attacker_tile"), ctx.get("target_tile"), ctx.get("target_facing")):
		return amount
	var tags: Array = ctx.get("tags", [])
	tags.append("backstab")
	return int(round(amount * damage_multiplier))
