class_name PassiveAbility
extends Resource

## Designer-editable COMBAT-HOOK base (v0.11.0, Jeff's class-identity framework; DESIGN §2.3 "add a
## .tres, not a script"). A PassiveAbility is a class-owned combat observer/modifier: a PlayerClass
## carries an Array[PassiveAbility] (resources/player_class.gd) and CombatReferee runs the ATTACKER's
## list through the five hooks below at the fixed combat seams. Subclass it (e.g. resources/passives/
## backstab.gd) to add an ability, then drop a .tres — no referee edit per ability.
##
## HOST-ONLY, SERVER-AUTHORITATIVE. Every hook runs only inside CombatReferee.apply_damage, the
## before_attack fan-out, or the two beats accessors (_windup_duration_of / _recovery_duration_of) — all
## of which are inert on clients (the referee's activate() runs host-side only).
## A passive therefore NEVER executes client-side and never reads a client value — the ctx it receives
## is built from the referees' authoritative state (occupancy tiles, server facing, HP). Clients only
## ever see the RESULT as the discrete `attack` event (its `tags`), never the passive itself.
##
## CHAINING: when a class owns several passives, modify_damage runs them in ARRAY ORDER, each receiving
## the previous one's output amount (CombatReferee updates ctx.amount between calls). Deterministic.
##
## The ctx keys a hook may read are documented on each method below. A subclass overrides only the
## hooks it needs; the base implementations are inert (observe nothing, change nothing).

## Player-facing name for this passive (v0.12.0 HUD), designer-editable per the resources ground rule
## ("add a .tres, not a script"). The character-info panel lists a class's passives.display_name; empty
## means "unlisted" (the HUD skips it), so a purely-mechanical passive with no display copy stays hidden
## without a code edit. Never adjudication — presentation only, read client-side by the HUD.
@export var display_name: String = ""


## Read-only OBSERVATION seam fired the moment an attack is committed, BEFORE any damage is computed
## (MoveReferee._begin_bump entry for a player bump, CombatReferee.wind_up entry for a telegraphed
## strike). CONTRACT: this hook CANNOT cancel or mutate the attack — it exists for logging or for
## ARMING external state a later hook (or another system) reads. It returns nothing and its ctx is
## treated as read-only; the Commitment Rule forbids a committed action being backed out here, so a
## cancellation seam, if ever wanted, is a deliberate FUTURE contract change, not a silent addition.
## ctx keys: attacker, target (nodes; target may be null for a windup onto a tile), attacker_id,
## target_id, kind, weapon (WeaponType or null), attacker_facing, target_facing (Vector2i).
func before_attack(_ctx: Dictionary) -> void:
	pass


## The BeforeDamageApplied seam: receives ctx.amount and returns the (possibly modified) amount, which
## CombatReferee writes back into ctx.amount before the next passive in the chain runs. May append to
## ctx.tags (Array) to request per-outcome client feedback (e.g. "backstab" → a distinct log line /
## popup / sound, §2.3.4). The base returns the amount UNCHANGED and touches nothing.
## ctx keys: amount (int), attacker, target (nodes), attacker_id, target_id, kind, weapon (WeaponType
## or null), attacker_tile, target_tile (Vector2i, authoritative occupancy), attacker_facing,
## target_facing (Vector2i, server facing), attack_dir (Vector2i sign-vector attacker→target), tags (Array).
func modify_damage(ctx: Dictionary) -> int:
	return int(ctx.get("amount", 0))


## The two TIMING seams (v0.35.0, the ranger's Archery): receive ctx.beats — the wielder's BASE beats for
## this action, the weapon's field plus any wielder bonus, BEFORE the 0-floor and BEFORE the beats→seconds
## pace multiply — and return the (possibly modified) beats. CombatReferee writes the result back into
## ctx.beats between calls, so several passives chain in ARRAY ORDER exactly as modify_damage does, and the
## referee re-floors at 0 afterward (a passive may shorten an action to instant, never to negative).
##
## WHY NOT FOLDED INTO modify_damage: damage is priced when a blow LANDS, but a duration is stamped when an
## action is COMMITTED — a different seam with a different context (there is no target yet, and there may
## never be one). One hook serving both would hand every damage passive a half-built ctx.
##
## FIRED FOR MELEE AND RANGED ALIKE, on every path that converts a weapon's beats into a committed window
## (a telegraphed wind-up, a bow's draw, either one's recovery tail). A passive meaning to touch only one of
## those MUST gate on ctx.weapon itself — Archery checks `weapon.range_tiles > 0`. The referee stays
## weapon-agnostic on purpose: it owns WHEN the chain runs, the passive owns WHETHER it applies.
##
## Host-only and server-authoritative like the rest of this contract; ctx is built from the referees' own
## state. ctx keys: beats (float), wielder (node), wielder_id (int), weapon (WeaponType or null).
func modify_windup_beats(ctx: Dictionary) -> float:
	return float(ctx.get("beats", 0.0))


## The recovery-tail half of the pair above — same ctx, same chaining, same host-only contract.
func modify_recovery_beats(ctx: Dictionary) -> float:
	return float(ctx.get("beats", 0.0))


## Post-broadcast OBSERVATION seam fired AFTER the `attack` event is posted (and the final amount is
## known), for after-the-fact reactions (on-kill effects, counters). ctx carries the same keys as
## modify_damage PLUS `died` (bool) — whether the blow was lethal. Read-only like before_attack; the
## broadcast has already gone out, so nothing this hook does changes the hit the party just saw.
func after_attack(_ctx: Dictionary) -> void:
	pass
