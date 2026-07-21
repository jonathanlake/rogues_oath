class_name GameConfig
extends Resource

## Session tuning. Designer-editable per the CLAUDE.md "designer-editable by default" rule.

@export var max_players: int = 6

## The global beat (seconds) — the unit every action duration is authored against (DESIGN §2.8).
## Every gameplay resource expresses its timings as designer-editable BEAT MULTIPLES (glide_beats,
## windup_beats, recovery_beats, move_rest_beats); seconds exist only when a referee stamps a
## verdict. Seeded into GameManager.explore_beat_sec at session start; the runtime tempo knob
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

## The TACTICAL beat (seconds) — the second tempo dial (DESIGN §2.8.3 groundwork, v0.9.2). Stored,
## adjustable ([ / ] keys → set_tactical_tempo) and displayed today, but NOT yet read for stamping:
## which pace applies when (mode entry/exit, per-player combat state, healer rules) is still an open
## design discussion with Jeff, so this is groundwork only — gameplay keeps stamping from beat_sec.
## Its clamp/snap bounds are DELIBERATELY SHARED with the explore dial (tempo_min_sec / tempo_max_sec /
## tempo_step_sec above) pending that mode design; when tactical earns its own band, split them here.
## Seeded into GameManager.tactical_beat_sec at session start on every peer. Default 0.50s (120 BPM).
@export var tactical_beat_sec: float = 0.5

## Tactical Zones v1 (DESIGN §2.8.7). FORCING WINDOW in BEATS: after a player lands a hostile action
## (its bump — including hitting the training dummy; the rule is uniform), it stays TACTICAL for this
## many tactical beats. Anti-cheese rationale: without it a player could tap an enemy and instantly
## revert to explore pace between swings, out-tempoing the fight it started. The window is measured in
## TACTICAL beats (tactical_force_beats × tactical_beat_sec seconds) so it scales with the fight's own
## cadence, not the explore dial. Spec range 2–4; default 3.0. Read HOST-side by PaceReferee.
@export var tactical_force_beats: float = 3.0

## Tactical Zones v1 (DESIGN §2.8.7). HYSTERESIS exit delay in SECONDS: once a player STOPS qualifying
## for tactical (left every bubble, no longer leashed, forcing window elapsed) it stays tactical until
## this many seconds of continuously qualifying for EXPLORE have passed. Rationale: a player skimming a
## bubble edge would otherwise flip pace every step (flicker) — this holds the last pace across the
## boundary so the switch reads as one deliberate change. A player with NO history (fresh spawn / late
## join) skips the delay and starts explore immediately. Seconds, NOT beats — it is real-time UI-feel
## smoothing, independent of either tempo dial. Default 1.5. Read HOST-side by PaceReferee.
@export var tactical_exit_sec: float = 1.5

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

## The hardwired weapon roster (M3.7, DESIGN §2.3.7). ONE authoring site for the swap-cycle order:
## the swap validator (main.gd) and the debug weapon= knob (debug.gd) both resolve a weapon THROUGH
## this array — by display_name for a lookup, by index for the swap toggle. Designer-editable (add /
## reorder .tres here, no code). M5's inventory acquisition REPLACES this hardwired list — until
## then swapping just cycles it. Read HOST-side for adjudication resolution; also read client-side to
## repaint a rig from a swap/sync event's weapon name.
@export var weapon_roster: Array[WeaponType] = []


# ── Weapon roster helpers ─────────────────────────────────────────────────────

## Resolve a weapon by its display_name through the roster, or null if absent. The single lookup the
## swap validator, the late-join weapon sync, and the debug weapon= knob share, so the roster stays
## the one place a weapon id maps to a resource.
func weapon_by_name(name: String) -> WeaponType:
	for w in weapon_roster:
		if w != null and w.display_name == name:
			return w
	return null

## The next weapon in the roster after `current` — the swap TOGGLE (cycles; a 2-weapon roster just
## alternates). An unknown / null current (not in the roster) starts at the first entry. Returns
## `current` unchanged when the roster is empty (a misconfiguration — nothing to swap to).
func next_weapon(current: WeaponType) -> WeaponType:
	if weapon_roster.is_empty():
		return current
	var idx := weapon_roster.find(current)  # -1 when absent → (idx + 1) wraps to the first entry
	return weapon_roster[(idx + 1) % weapon_roster.size()]


## The authored player-class roster (v0.10.0). ONE authoring site for the classes a player may BE:
## Player._ready seeds a fresh spawn from `class_roster[spawn_index % size]` (this array IS the old
## per-slot sprite table), the /class validator resolves the requested class through class_by_name, and
## every peer maps a class_changed / sync_class event's name back to the same resource through it.
## Designer-editable (add / reorder .tres here, no code). Read HOST-side for adjudication resolution and
## client-side to repaint a sprite from a class event's name — the mirror of weapon_roster above.
@export var class_roster: Array[PlayerClass] = []


# ── Player-class roster helpers ────────────────────────────────────────────────

## Resolve a class by its display_name through the roster, or null if absent. The single lookup the
## /class validator, the late-join class sync, and the spawn seed share, so the roster stays the one
## place a class name maps to a resource (mirror of weapon_by_name).
func class_by_name(name: String) -> PlayerClass:
	for c in class_roster:
		if c != null and c.display_name == name:
			return c
	return null
