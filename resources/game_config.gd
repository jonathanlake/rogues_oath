class_name GameConfig
extends Resource

## Session tuning. Designer-editable per the CLAUDE.md "designer-editable by default" rule.

@export var max_players: int = 6

## The global beat (seconds) — the unit every action duration is authored against (DESIGN §2.8).
## Every gameplay resource expresses its timings as designer-editable BEAT MULTIPLES (glide_beats,
## windup_beats, recovery_beats, move_rest_beats); seconds exist only when a referee stamps a
## verdict. Seeded into GameManager.current_beat_sec at session start; the runtime tempo knob
## (§2.8.3, future chunk) adjusts the live value from there. NOT a global tick — actions still
## start on commit and share only their unit (§2.4.1 stands).
@export var beat_sec: float = 0.25

## Tempo-knob bounds (seconds/beat) for the runtime tempo control (DESIGN §2.8.3). The host's
## set_tempo validator reads these — they are the sole authority on the knob's range and grid, so a
## designer widens/narrows the tempo band or changes its granularity HERE, no code. tempo_min_sec is
## the fastest allowed beat (smaller = faster), tempo_max_sec the slowest; tempo_step_sec is both the
## snap grid every accepted beat is quantized to AND the size of one +/- nudge. Defaults: 0.05s steps
## across [0.10, 1.00] around the 0.25 default (240 BPM), each step a clearly audible cadence change.
@export var tempo_min_sec: float = 0.10
@export var tempo_max_sec: float = 1.00
@export var tempo_step_sec: float = 0.05

## Rest beats appended to every movement step's committed window (DESIGN §2.8/§2.2). A step is now
## 1 beat TOTAL — this defaults to 0.0. Kept as a reversible, now-ANSWERED experiment: the v0.7.0
## committed rest (go-stop-go) read as lag in feel-testing, so the pause moved out of the action
## window and into the visible slide instead (see slide_fraction). If ever re-raised, this is a
## SEPARATE term appended to the action window — the diagonal multiplier scales the glide term only,
## never this rest — so the visible slide length is unchanged and the rest extends only the settle.
## Read HOST-side by MoveReferee when it stamps a step's busy window.
@export var move_rest_beats: float = 0.0

## Fraction of a step's ACTION window that the visible slide occupies; the remainder the avatar
## stands SETTLED on the destination tile — the grid "snap" tell (DESIGN §2.8, v0.8.0). Unitless,
## so it scales with any tier's glide_beats and the diagonal multiplier automatically and can
## never exceed the window. 1.0 = no settle (continuous glide); low = teleport-y. VISUAL ONLY —
## occupancy/adjudication are unchanged (busy window is still the full action window). The referee
## ALSO clamps this at stamp time, so a hand-edited .tres can't drive it out of range.
@export_range(0.05, 1.0) var slide_fraction: float = 0.7

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
