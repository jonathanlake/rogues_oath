class_name Archery
extends PassiveAbility

## Ranger ARCHERY (v0.35.0, Jon's bow rebalance). A RANGED-ONLY timing passive: the bow's draw and its
## after-loose tail each come in one beat shorter in the ranger's hands. Owned by
## resources/classes/ranger.tres via its `passives` array; CombatReferee runs it through the two timing
## seams (modify_windup_beats / modify_recovery_beats) at the beats→seconds conversion sites, host-only
## and server-authoritative. Both deltas are `.tres` fields — feel-tunable without touching this script.
##
## WHY A PASSIVE AND NOT A SECOND BOW: the v0.35.0 rebalance moved the bow itself to 4-beat draw /
## 7-beat tail (2-5 damage), and ONE bow.tres is shared by the player and the goblin archer. Making the
## ranger's advantage a class passive rather than a separate weapon resource keeps that single shared
## resource as the balance surface — retuning the bow retunes both wielders, and the class keeps exactly
## one relative edge over the goblin instead of two numbers that can silently drift apart. It also puts
## the ranger's identity where the rogue's already lives (see backstab.gd) and gets it listed by name in
## the character-info panel for free, via PassiveAbility.display_name.
##
## RANGED-ONLY IS ENFORCED HERE, not by the referee. The two hooks fire for every weapon on every timing
## path (melee wind-up included), because the referee owns WHEN the chain runs and a passive owns WHETHER
## it applies — so a ranger who draws the longsword swings at the weapon's authored speed, unchanged.

## Beats removed from a RANGED weapon's WINDUP (its draw). NEGATIVE shortens — this is a delta added to
## the base, not a magnitude subtracted from it, so a future "heavy draw" passive can author +1 with the
## same field. The referee floors the chained result at 0, so an over-generous delta yields an instant
## draw rather than a negative one.
@export var windup_beats_delta: float = -1.0

## Beats removed from a RANGED weapon's RECOVERY tail (after the loose). Same delta convention and the
## same 0-floor as the windup above.
@export var recovery_beats_delta: float = -1.0


## Shorten the DRAW when the wielder is holding a ranged weapon. A melee weapon, or no weapon at all,
## returns the beats untouched.
func modify_windup_beats(ctx: Dictionary) -> float:
	var beats := float(ctx.get("beats", 0.0))
	if not _is_ranged(ctx):
		return beats
	return beats + windup_beats_delta


## Shorten the after-loose TAIL under the same weapon gate.
func modify_recovery_beats(ctx: Dictionary) -> float:
	var beats := float(ctx.get("beats", 0.0))
	if not _is_ranged(ctx):
		return beats
	return beats + recovery_beats_delta


## THE weapon gate, one place so the two hooks can never disagree about what "ranged" means. Reads
## `range_tiles > 0` — the same predicate the referee, the shoot validator and the lane check all use to
## decide a weapon shoots rather than swings, so this passive can never apply to a weapon the shot pipe
## would refuse. A null weapon (bare-handed) is not ranged.
func _is_ranged(ctx: Dictionary) -> bool:
	var weapon = ctx.get("weapon")
	return weapon != null and weapon.range_tiles > 0
