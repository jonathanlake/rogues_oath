class_name ActiveAbility
extends Resource

## Designer-editable ACTIVE (triggered) ability (v0.20.0, active-ability system). A PlayerClass carries an
## Array[ActiveAbility] (resources/player_class.gd); the HUD binds them to the 1-5 hotbar and pressing a key
## submits a `use_ability {index}` intent the host adjudicates. Unlike a PassiveAbility (a silent combat hook),
## an active ability is a COMMITTED action (DESIGN §2.1): using it ROOTS the player for its beats — which WAS
## the whole anti-spam story until v0.27.0 put a `cooldown_beats` beside it (see that field: it extends the
## §2.11.1 experiment's Part 4 Q9 suspension to strikes, and 0 = the pre-v0.27.0 behavior). HOST-ONLY /
## server-authoritative: the
## AbilityReferee reads these values host-side; the wire only ever carries the slot index. Add an ability by
## dropping a `.tres` into a class's `active_abilities` — no code edit.
##
## v1 shape (both the knight shield-bash and the rogue kick are THIS one mechanic, differing only in numbers):
## a committed melee strike on an ADJACENT enemy that deals `damage` and applies a `stun_beats` STUN. Later
## abilities (ranged, self-buff, ground-target) extend this resource / add a kind selector.

## What SHAPE of ability this is (v0.26.0 instants experiment, DESIGN §2.11.1). The referee dispatches on it:
##  - STRIKE — the v0.20.0 mechanic and the only non-experimental one: a COMMITTED melee strike (+ stun) that
##    respects the busy gate and pays its cost in beats. Every field below is a STRIKE field.
##  - BLOCK  — INSTANT. Raises a one-shot guard that negates the next incoming hit. No window, no damage, no
##    stun; gated by `cooldown_beats` below, charged on CONSUMPTION (holding a guard is free).
##  - BLINK  — INSTANT. Teleports the user one tile OPPOSITE its facing, interrupting its own committed action;
##    gated by `cooldown_beats`, charged on a SUCCESSFUL teleport only.
##  - TARGETED — v0.34.0, the druid's Entangling Roots. A COMMITTED cast at a TILE up to `range_tiles` away
##    (the client arms a cursor and the click names the tile; the host adjudicates from ITS occupancy):
##    windup_beats channels, recovery_beats is the spent tail, and whoever hostile occupies the tile at the
##    END of the channel is ROOTED for `root_beats` — no damage, no stun. Tile-keyed like a monster's smite,
##    so stepping off the tile dodges it. NOT an instant: it opens a real occupied window and respects every
##    Commitment-Rule gate a STRIKE does. (Its `cooldown_beats` rides the SAME §2.11.1 experiment umbrella as
##    kick / shield bash — see cooldown_beats — and reverts with the same one dial.)
## (v0.27.0: both instants used to read a per-ability GameConfig dial; the cooldown is a field on this resource
## now, and STRIKES carry one too — see cooldown_beats.)
## Both instant kinds are inert unless `GameConfig.instant_abilities_enabled` is on (they reject otherwise);
## TARGETED is NOT gated on that toggle (only its cooldown is), because a committed cast is not an instant.
##
## ORDINALS ARE SERIALIZED: `kind` is stored in each `.tres` as a plain int, so this enum is APPEND-ONLY —
## never reorder or insert, or every authored ability silently changes shape.
enum Kind { STRIKE, BLOCK, BLINK, TARGETED }

## This ability's shape (see Kind). Defaults to STRIKE, so every pre-v0.26.0 `.tres` keeps its exact behavior.
@export var kind: Kind = Kind.STRIKE

## WHAT a TARGETED cast commits to (v0.38.0, Jon's ruling). Ignored by every other Kind.
##  - TILE     — the v0.34.0 behavior: the cast names a SQUARE, and whoever hostile is standing on it when
##               the channel ends gets the effect. Stepping one tile off dodges it completely. This is the
##               monster smite's model (§2.3.4's red danger tile) and stays the default, so any TARGETED
##               `.tres` authored before this field keeps its exact behavior.
##  - CREATURE — the cast LOCKS ONTO A BODY. The host resolves whoever occupies the clicked tile at cast
##               START, remembers that ENTITY, and at the end applies the effect wherever that entity now
##               stands. Not a guaranteed hit: the target must still be alive and still within
##               `range_tiles` of the caster when the channel ends, so the counterplay stops being a
##               one-tile sidestep and becomes RUN.
##
## WHY BOTH EXIST, rather than migrating everything to CREATURE (Jon, 2026-07-27): the tile model asks you
## to predict where someone WILL be, which is real depth but reads as twitchy on a 2-beat channel — "a huge
## whiff of a cooldown if the goblin moves off it last second". The creature model asks you to commit to a
## BODY and then keep it in reach, which is a positioning problem rather than a reflex one. Neither is
## strictly better, so the shape belongs to the SPELL: ground-effect magic names ground, and a spell that
## grabs a specific enemy names that enemy.
##
## THE CLIENT NEVER SENDS AN ENTITY ID. A creature-targeted click still puts a TILE on the wire, exactly as
## a tile-targeted one does, and the host resolves it against its own occupancy (§2.5 — never adjudicate
## from a client value). The wire shape is identical between the two modes; only the host's interpretation
## differs, which is why this field is a host-side read and not a protocol change.
##
## ORDINALS ARE SERIALIZED, like Kind above — APPEND-ONLY, never reorder or insert.
enum TargetMode { TILE, CREATURE }

## Which of the two a TARGETED cast uses (see TargetMode). TILE by default so v0.34.0's authored
## Entangling Roots would have been unchanged by this field's mere existence.
@export var target_mode: TargetMode = TargetMode.TILE

## Player-facing name — HUD hotbar tooltip + the source of the combat-log verb. Empty = unnamed (still usable).
## ALSO the COOLDOWN KEY for an instant (the referee's per-entity ready-at map is keyed by it) and the id the
## `ability_used` / `ability_cooldown` events carry so each peer's HUD can find the right socket. Keep it unique
## within a class's `active_abilities`.
@export var display_name: String = ""

## Hotbar icon cell (column, row) into assets/32rogues/items.png — 0-indexed, like an ItemType icon.
@export var atlas_coords: Vector2i = Vector2i.ZERO

## Combat-log verb for a landed use ("bashes", "kicks") — the §2.3.4 distinct line. Empty falls back to "hits".
@export var log_verb: String = ""

## Deterministic damage to the struck enemy (0 = a pure utility strike, e.g. a stun-only kick). Referee floors at 0.
@export var damage: int = 0

## STUN applied to the struck enemy in BEATS (0 = no stun). Stamped at the target's beat, so it scales with tempo.
@export var stun_beats: float = 0.0

## Telegraph windup in BEATS before the strike resolves (0 = instant strike, like a bump). Part of the occupied window.
@export var windup_beats: float = 0.0

## Recovery tail in BEATS after the strike — the committed "spent" window the user stays rooted (Q9 unified occupancy).
@export var recovery_beats: float = 0.0

## Reach in tiles for the target search (1 = 8-adjacent, the v1 default — a point-blank strike). Read HOST-side.
## v0.34.0: a TARGETED ability finally READS this — the host gates the clicked tile on Chebyshev distance
## ≤ this number from the caster's authoritative tile (the shoot pipe's range gate, same shape), and the
## client's targeting cursor draws a ring of exactly this radius. A STRIKE still only uses it as its
## adjacent-hostile search reach.
@export var range_tiles: int = 1

## ROOT duration in BEATS applied to the hostile occupying the target tile when a TARGETED cast lands
## (v0.34.0, DESIGN §2.13 conditions). 0 (the default) = no root, which is why `is_valid_ability` REFUSES a
## TARGETED ability authored at 0 — a targeted cast that roots nothing has no effect at all. Ignored by every
## other Kind. Stamped at the TARGET's resolved pace (stamp-and-bake, §2.8.2), so it scales with tempo the
## way `stun_beats` does. ROOTED = cannot MOVE; attacks and casts stay available (the condition fights back).
## Tunable live through `/ab <ability> root_beats <n>` and the debug panel's CLASSES section.
@export var root_beats: float = 0.0

## COOLDOWN in BEATS before this ability may be used again (v0.27.0). 0 (default) = NO cooldown, which is
## byte-for-byte the pre-v0.27.0 behavior for any ability that leaves it unset.
##
## THIS FIELD REPLACES the two hand-written GameConfig dials (`shield_block_cooldown_beats` /
## `shadow_step_cooldown_beats`) the v0.26.0 instants experiment shipped: a cooldown belongs to the
## ability, not to a global config table that only two abilities could ever address — and now that
## STRIKES carry them too (Jeff's second verdict: kick 40, shield bash 40), one field per `.tres` is the
## only shape that scales. Tunable live through `/ab <ability> cooldown_beats <n>` and the debug panel's
## CLASSES section.
##
## SCOPE NOTE — THIS EXTENDS A SANCTIONED SUSPENSION, it does not create a new rule. Part 4 Q9 says
## "unified occupancy — NO separate cooldowns, ever"; §2.11.1's experiment suspended that for the two
## INSTANTS (which have no occupied window to pay with). Putting a cooldown on a STRIKE — which DOES pay
## in beats — is a second timer beside a window that already exists, so it goes further than the original
## suspension and is explicitly part of the SAME pending Jon+Jeff verdict (DESIGN §2.11.1). Do not build
## on it until that is answered.
##
## Stamped at ACCEPT for a strike (the press is what spends it, so a blink-interrupted strike fizzles its
## effect and the cooldown still stands) and at CONSUMPTION for Shield Block (holding a guard is free).
## Beats × the user's RESOLVED pace at the moment it is charged — stamp-and-bake (§2.8.2), so a later
## tempo change never re-derives a cooldown already running. Read HOST-side only.
@export var cooldown_beats: float = 0.0


## True when this ability is validly authored. The ONE predicate the referee gates on, so an empty /
## misauthored slot can never be "used".
##
## An INSTANT (BLOCK / BLINK) is valid BY CONSTRUCTION (v0.26.0): its whole point is to carry no damage, no
## stun and no occupied window — its cost is a cooldown dial, not authored beats — so the STRIKE test below
## would reject every correctly-authored instant. The STRIKE branch is byte-identical to the pre-v0.26.0 rule.
##
## TARGETED gets an EXPLICIT arm of its own (v0.34.0) rather than riding the instants' free pass: a targeted
## cast has three things it genuinely cannot work without — a reach to aim inside (`range_tiles`), an effect
## to land (`root_beats`) and an occupied window to pay with (windup + recovery) — so a misauthored one must
## be as unusable as a misauthored strike. Written as its OWN branch ABOVE the `!= STRIKE` early-return
## precisely so adding a Kind never silently grants it validity again.
func is_valid_ability() -> bool:
	if kind == Kind.TARGETED:
		return range_tiles > 0 and root_beats > 0.0 and (windup_beats + recovery_beats) > 0.0
	if kind != Kind.STRIKE:
		return true
	return (damage > 0 or stun_beats > 0.0) and (windup_beats + recovery_beats) > 0.0
