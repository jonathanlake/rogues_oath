class_name GameConfig
extends Resource

## Session tuning. Designer-editable per the CLAUDE.md "designer-editable by default" rule.

@export var max_players: int = 6

## Unitless duration multiplier applied to a glide's per-step time when the step is diagonal
## (DESIGN §2.2.7). Jeff's default is 2.0× — a diagonal costs twice an orthogonal step, so
## corner-cutting isn't a free shortcut. Read server-side when stamping each glide's duration.
@export var diagonal_step_multiplier: float = 2.0

## Provisional corner rule (DESIGN §2.2.7). Walls ALWAYS block a diagonal squeeze; this toggle
## only governs bodies: when true, an occupied flank tile also blocks the diagonal. Default
## false (Jeff: bodies don't block) — a playtest toggle, flip without touching code.
@export var bodies_block_corners: bool = false

## Provisional Q4 origin-tile timing (DESIGN Part 4 Q4). When true, the tile a player departs
## frees the instant the glide STARTS (conga-line movement — Jeff leans this); when false, the
## origin stays held until the glide finishes. A playtest toggle, flip without touching code.
@export var origin_frees_at_glide_start: bool = true
