class_name AiPersonality
extends Resource

## Designer-editable AI PERSONALITY for a utility-AI monster (v0.22.0, weighted utility AI). One
## personality is ROLLED PER INSTANCE at brain activation from its MonsterType's `personalities` array,
## so two goblin shamans spawned from the SAME shared .tres behave differently — Jeff's "two random
## personalities" ask, as data rather than code. The roll and the multipliers live HOST-side (the brain is
## host-only, DESIGN §2.5.3); nothing about a personality crosses the wire except through the host's own
## adjudicated outcomes (and the dev-gated `ai_decision` debug event).
##
## The multipliers scale the WHOLE composite score of their action (base weight + every bonus/penalty
## already folded in), applied BEFORE the candidates are sorted — a personality shifts final desirability,
## not one term of the formula. 1.0 = neutral; an empty `personalities` array on a MonsterType means every
## multiplier is 1.0 and the monster is a plain "average" specimen.
##
## Add a personality by dropping a `.tres` under resources/monsters/ and listing it on a MonsterType —
## no code edit (CLAUDE.md "designer-editable by default").
##
## Authoring model (same as MonsterType): a .tres stores ONLY values that differ from the script defaults
## below — the editor's saver STRIPS default-equal properties on every save. The defaults here are
## therefore part of the authored surface: a 1.0 default is what "this personality doesn't care about
## that action" means.

## Log / debug-overlay name for this personality ("supportive", "aggressive"). Printed to the host log at
## the roll and carried on the dev-gated `ai_decision` event, so a session can tell who's who with no UI.
@export var display_name: String = ""

## Multiplier on the HEAL candidate's whole composite score. > 1 = this specimen values keeping the pack
## alive more than average; < 1 = it would rather be casting at the players. 1.0 = neutral.
@export var heal_weight_mult: float = 1.0

## Multiplier on the SMITE candidate's whole composite score. > 1 = trigger-happy caster; < 1 = it holds
## its offence for when nothing else wants doing. 1.0 = neutral.
@export var smite_weight_mult: float = 1.0
