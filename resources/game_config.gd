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

## Provisional playtest toggle (DESIGN §2.2.6): attacks of opportunity — a hostile adjacent to a
## tile a mover glides OUT of gets a free strike. Default true = the ORIGINAL shipped behavior (AoO
## on); resources/game_config.tres ships it false for the v0.6.0 rhythm experiment (Jon/Jeff wire
## notes, 2026-07-19 — "toggle it, don't remove it"). Read HOST-side in MoveReferee's AoO scan, so
## no client can grant itself free strikes; the §2.2.6 spec and code both stand — this parks the
## mechanic, nothing more. Flip in the .tres, no code.
@export var attacks_of_opportunity_enabled: bool = true

## Provisional playtest toggle (DESIGN §2.2.9): click-to-move pathing. Default true = the ORIGINAL
## shipped behavior (A* click-to-anywhere); resources/game_config.tres ships it false, which drops
## MoveInput into adjacent-only click mode — a click on one of the 8 neighbor tiles submits one
## step, any farther click does nothing (Jeff: "if you click 8 spaces ahead nothing happens").
## Client-side INPUT convenience only: the same authored file ships in every build and the server
## never reads it for adjudication (§2.2.9's client-side framing). Jon/Jeff 2026-07-19.
@export var click_pathing_enabled: bool = true
