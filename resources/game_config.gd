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

## Tactical Zones v1 (DESIGN §2.8.7). PLAYER TACTICAL BUBBLE radius in Chebyshev tiles (v0.10.3): a
## player who is NOT directly in a fight still resolves to TACTICAL pace when within this many king-move
## tiles of a teammate who qualifies via a MONSTER source (forcing window, leash, or monster bubble).
## Rationale (Jon): "the group fights together" — a nearby ally in combat pulls you into the fight's
## cadence too. DELIBERATELY smaller than the enemy bubble (goblin 5) at default 3, so proximity to an
## engaged teammate is a tighter zone than the monster's own reach. NO CHAINING: only the monster-sourced
## teammate projects this pull — a merely-pulled or hysteresis-lingering player projects nothing, so two
## allies can't hold each other tactical forever after the fight ends (enforced by PaceReferee's two-pass
## resolve). 0 = no player pull (the bubble is disabled; only direct monster sources make a player
## tactical). Read HOST-side by PaceReferee.
@export var player_tactical_radius_tiles: int = 3

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

## Provisional corner rule (DESIGN §2.2.7, amended 2026-07-21). A diagonal squeeze is refused for
## WALLS only when BOTH flanks are walls (a single wall corner may be rounded); this toggle governs
## bodies: when true, EITHER occupied flank also blocks the diagonal. Default false (Jeff: bodies
## don't block) — a playtest toggle, flip without touching code.
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

## Provisional playtest toggle (DESIGN §2.2.9): click-to-move pathing. The .tres ships it false, which
## drops MoveInput into adjacent-only click mode — a click on one of the 8 neighbor tiles submits one
## step, any farther click does nothing (Jeff: "if you click 8 spaces ahead nothing happens"). The SCRIPT
## DEFAULT is ALSO false (v0.12.0): if a config load ever fails and GameManager falls back to a fresh
## GameConfig, click pathing must stay DISARMED — with the pass-through docked HUD a stray click on a UI
## panel would otherwise commit a hidden walk. PARKED DESIGN NOTE: when this is re-enabled, MoveInput
## clicks must be gated on the HUD's world-frame rect (a click outside the play area is UI, not a move).
## Client-side INPUT convenience only: the same authored file ships in every build and the server never
## reads it for adjudication (§2.2.9's client-side framing). Jon/Jeff 2026-07-19.
@export var click_pathing_enabled: bool = false

## The hardwired weapon roster (M3.7, DESIGN §2.3.7). ONE authoring site for the swap-cycle order:
## the swap validator (main.gd) and the debug weapon= knob (debug.gd) both resolve a weapon THROUGH
## this array — by display_name for a lookup, by index for the swap toggle. Designer-editable (add /
## reorder .tres here, no code). M5's inventory acquisition REPLACES this hardwired list — until
## then swapping just cycles it. Read HOST-side for adjudication resolution; also read client-side to
## repaint a rig from a swap/sync event's weapon name.
@export var weapon_roster: Array[WeaponType] = []

## The MASTER weapon catalog (v0.17.0) — EVERY weapon a name may resolve to, whether or not it sits in a
## Tab-cycle. weapon_by_name resolves from THIS, so `weapon=bow` (and a class-roster weapon like the bow)
## resolves even though the global Tab roster above stays the shipped dagger↔longsword pair. Superset of
## every roster (global + per-class). Designer-editable; add a weapon here to make its name resolvable.
@export var weapon_catalog: Array[WeaponType] = []

## The MASTER item catalog (v0.18.0) — EVERY item a name may resolve to (the mirror of weapon_catalog for
## pickups). item_by_name resolves from THIS, so a ground-item / (future) pickup / use event's item_name
## maps back to its ItemType on every peer. Items have NO roster (there is no equip cycle to belong to — an
## item is picked up, not swapped-to), so this is the SOLE resolution source. Designer-editable; add an item
## here to make its name resolvable across the wire.
@export var item_catalog: Array[ItemType] = []

## Arrows-hit-allies toggle (v0.17.0, DESIGN ranged). true (default) = an arrow STOPS at the first
## living occupant on its path, ally or enemy (friendly fire on). false = arrows PASS THROUGH allies
## everywhere, stopping only at the first hostile. Read HOST-side by CombatReferee's projectile travel;
## never the wire. A playtest toggle — flip in the .tres, no code.
@export var projectile_hits_allies: bool = true

## Point-blank KICK damage (v0.17.1, DESIGN ranged, option A). Flat damage a RANGED weapon
## (range_tiles > 0) deals when its wielder keyboard-bumps an adjacent hostile — a bow has no melee
## swing, so a point-blank bump is a desperation kick, not a slash. A MELEE weapon (range_tiles == 0)
## keeps its normal swing damage (weapon.damage) instead; this value is read ONLY on the ranged-bump
## path. Deliberately low — the kick is a get-off-me poke, not a wielder's main-hand attack. Read
## HOST-side by MoveReferee._begin_bump. Option D (a knockback on the kick) is a future, separate add.
@export var kick_damage: int = 1


# ── Weapon roster helpers ─────────────────────────────────────────────────────

## Resolve a weapon by its display_name through the CATALOG (v0.17.0), or null if absent. The single lookup
## the swap validator, the late-join weapon sync, the class-equip, and the debug weapon= knob share — the
## catalog (not a Tab roster) is the one place a weapon id maps to a resource, so any weapon in the game is
## name-resolvable regardless of which cycle it belongs to.
func weapon_by_name(name: String) -> WeaponType:
	for w in weapon_catalog:
		if w != null and w.display_name == name:
			return w
	# Fallback for a config authored without a catalog (the shipped .tres has one; this guards any
	# future/experimental GameConfig): the global Tab roster is the pre-catalog resolution source, so
	# name lookups never silently break just because the catalog was left empty.
	for w in weapon_roster:
		if w != null and w.display_name == name:
			return w
	return null

## Resolve an item by its display_name through the CATALOG (v0.18.0), or null if absent. The single lookup
## every item name-resolution shares (the /item dev command today; pickup + use in later chunks). UNLIKE
## weapon_by_name there is NO roster fallback: items have no equip roster to resolve through — the catalog
## is the one and only place an item id maps to a resource, so a name absent from item_catalog is genuinely
## unknown. First-hit resolution (a duplicate display_name silently shadows) — validate_catalogs() warns.
func item_by_name(name: String) -> ItemType:
	for it in item_catalog:
		if it != null and it.display_name == name:
			return it
	return null


## The active swap ROSTER for a player of `player_class` (v0.17.0): the class's own weapon_roster when it is
## non-empty, else the GLOBAL weapon_roster fallback. The ONE resolution the swap validator + class-equip
## share, so "which weapons does THIS player cycle" is answered in exactly one place, host-side.
func active_weapon_roster(player_class: PlayerClass) -> Array[WeaponType]:
	if player_class != null and not player_class.weapon_roster.is_empty():
		return player_class.weapon_roster
	return weapon_roster

## Misconfiguration guard (v0.17.1 review #2). Every weapon that any roster (global + per-class) can
## equip MUST be name-resolvable through weapon_catalog — swap/class-equip/late-join sync all resolve a
## weapon by display_name via weapon_by_name (which reads the catalog), so a roster weapon missing from
## the catalog resolves to null on peers and desyncs SILENTLY while the host's log says success. This
## walks every roster entry and push_warnings any whose display_name the catalog can't resolve, so a
## mis-authored .tres is caught ONCE at session start (called host-side from CombatReferee.activate),
## not mid-fight. Pure diagnostic — mutates nothing. display_name is the join key on BOTH sides
## (weapon_by_name matches w.display_name), so this checks exactly what the runtime resolves.
func validate_catalog_covers_rosters() -> void:
	var rosters: Array = [weapon_roster]
	for c in class_roster:
		if c != null:
			rosters.append(c.weapon_roster)
	for roster in rosters:
		for w in roster:
			if w != null and weapon_by_name(w.display_name) == null:
				push_warning("[GameConfig] weapon '%s' is in a roster but NOT in weapon_catalog — it will resolve to null on peers and desync a swap/equip. Add it to weapon_catalog." % w.display_name)


## Duplicate-name guard (v0.18.0), the sibling of validate_catalog_covers_rosters called beside it host-side
## at session start. Both catalogs resolve by FIRST-HIT display_name (weapon_by_name / item_by_name walk the
## array and return the first match), so a SECOND entry sharing a display_name silently SHADOWS the first —
## a name would resolve to the wrong resource with no error. This walks each catalog and push_warnings any
## display_name that appears more than once, so a mis-authored duplicate is caught ONCE at startup rather
## than surfacing as a baffling "wrong weapon/item" at runtime. Pure diagnostic — mutates nothing.
func validate_catalogs() -> void:
	_warn_duplicate_names(weapon_catalog, "weapon_catalog")
	_warn_duplicate_names(item_catalog, "item_catalog")
	_warn_cross_catalog_collisions()


## Cross-catalog uniqueness guard (v0.19.x loot, GLM review). A bag entry is a display_name STRING resolved
## against BOTH catalogs — weapon_by_name for a left-click equip, item_by_name for a left-click use (a looted
## weapon and a consumable now share the inventory). A name present in BOTH catalogs is ambiguous: the HUD icon
## and the click-routing would silently pick one, so the WRONG thing gets equipped/drunk with no error. Warn
## ONCE at startup (called host-side from CombatReferee.activate beside the other catalog guards). Pure diagnostic.
func _warn_cross_catalog_collisions() -> void:
	var weapon_names: Dictionary = {}
	for w in weapon_catalog:
		if w != null:
			weapon_names[w.display_name] = true
	for it in item_catalog:
		if it != null and weapon_names.has(it.display_name):
			push_warning("[GameConfig] display_name '%s' is in BOTH weapon_catalog and item_catalog — a looted bag entry with this name is AMBIGUOUS (equip vs use). Rename one." % it.display_name)


## Shared duplicate-display_name scan for one catalog (v0.18.0). `entries` is an Array of Resources each with
## a `display_name`; `catalog_name` names the catalog in the warning. Tracks the names already seen and
## push_warnings EVERY entry that repeats an earlier name (three copies of one name → two warnings — one
## per shadowed extra, so the warning count matches how many entries are unreachable via first-hit lookup).
func _warn_duplicate_names(entries: Array, catalog_name: String) -> void:
	var seen: Dictionary = {}
	for e in entries:
		if e == null:
			continue
		var name: String = e.display_name
		if seen.has(name):
			push_warning("[GameConfig] duplicate display_name '%s' in %s — first-hit resolution means the later entry is SHADOWED (never resolvable). Rename or remove the duplicate." % [name, catalog_name])
		seen[name] = true


## The next weapon in `roster` after `current` — the swap TOGGLE (cycles; a 2-weapon roster just alternates).
## An unknown / null current (not in the roster) starts at the first entry. Returns `current` unchanged when
## the roster is empty (a misconfiguration — nothing to swap to). The caller passes the active roster
## (active_weapon_roster) so the cycle honours a class loadout when one is set.
func next_weapon(current: WeaponType, roster: Array[WeaponType]) -> WeaponType:
	if roster.is_empty():
		return current
	var idx := roster.find(current)  # -1 when absent → (idx + 1) wraps to the first entry
	return roster[(idx + 1) % roster.size()]


## The authored player-class roster (v0.10.0). ONE authoring site for the classes a player may BE:
## Player._ready seeds a fresh spawn from `class_roster[spawn_index % size]` (this array IS the old
## per-slot sprite table), the /class validator resolves the requested class through class_by_name, and
## every peer maps a class_changed / sync_player_field event's name back to the same resource through it.
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
