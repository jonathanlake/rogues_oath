class_name GlideSpeed
extends Resource

## A discrete movement speed tier (DESIGN §2.2.3: speed is a small set of named tiers, not a
## continuous stat). Designer-editable per the CLAUDE.md "designer-editable by default" rule —
## a non-coder tunes pacing by editing the .tres files under resources/speed_tiers/, and adds a
## new tier by dropping in another .tres, never by touching code.
##
## The values shipped in resources/speed_tiers/*.tres are PLAYTEST PLACEHOLDERS — expect them
## to change once M2 movement is in hands.

## Display / debug name for this tier ("slow", "normal", "fast").
@export var tier_name: String = ""

## BEATS to glide ONE orthogonal (N/S/E/W) tile step (DESIGN §2.8 — durations are authored as
## beat multiples, converted to seconds only when the server stamps a verdict: beats ×
## the mover's resolved pace beat). A diagonal step multiplies the resulting seconds by
## GameConfig.diagonal_step_multiplier (DESIGN §2.2.7). The server stamps the final duration onto
## each glide event; clients only play it back. All three shipped tiers are 1.0 beat (the tempo
## lives in the beat now, not the tier — tier VARIATION is a parked rhythm-experiment revert).
@export var glide_beats: float = 1.0
