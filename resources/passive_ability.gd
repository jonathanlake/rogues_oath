class_name PassiveAbility
extends Resource

## Designer-editable TRAIT base (v0.11.0, Jeff's class-identity framework; DESIGN §2.3 "add a .tres, not
## a script"). A PassiveAbility — "Trait" to a player since v0.43.0 — is an observer/modifier owned by a
## class OR granted to one body (Player.granted_traits, v0.45.0). The referees run its hooks at fixed
## seams. Subclass it (e.g. resources/passives/backstab.gd) and drop a .tres — no referee edit per trait.
##
## WHOSE LIST RUNS, WHERE. Through v0.47.0 the answer was always "the attacker's, or the wielder's own",
## and this header said so. v0.49.0 widened it, so state it plainly:
##   - `before_attack`, `modify_damage`, `after_attack` — the ATTACKER's.
##   - `modify_windup_beats`, `modify_recovery_beats` — the WIELDER's own.
##   - `modify_move_beats` — the MOVER's own (MoveReferee's step stamp).
##   - `modify_damage_taken` — the DEFENDER's. The first hook to ask the target's list anything.
##   - `on_nearby_death` — every living player near a death, killer or not.
##
## HOOKS ARE HOST-ONLY. QUERIES ARE NOT. That distinction is new in v0.49.0 and is the one thing to keep
## straight:
##   - A HOOK mutates adjudication (a damage number, a duration, a pool) and runs only inside a referee,
##     all of which are inert on clients. It receives a ctx built from authoritative state and never reads
##     a client value.
##   - A QUERY (today: `spell_range_bonus`) answers "what does this kit say" and is a pure function of
##     replicated data — the class resource every peer loads, plus `granted_traits`, which every peer
##     maintains from the same events. Any peer may evaluate one, and the client MUST: a targeting ring
##     drawn from an unadjusted range would promise a reach the host then refuses.
## A query must therefore stay pure — no referee reads, no host-only state — or it will answer differently
## on a client and the UI will lie about the rules.
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

## PROSE for the HUD tooltip (v0.43.0), shown beneath the trait's name. PRESENTATION ONLY — no referee
## reads it and it never crosses the wire (every peer loads the same resource).
##
## NUMBERS ARE DERIVED, PROSE IS AUTHORED — the same rule `ActiveAbility.description` and
## `ItemType.description` carry. Do NOT type a multiplier or a beat count in here; the tooltip builder
## appends those from `tooltip_terms()` below, so a `/w`-style retune can never leave this text quoting a
## stale number. WRITE THE MECHANIC, NOT THE MATH: say that Sneak Attack rewards catching someone
## distracted; do not say it doubles damage.
@export_multiline var description: String = ""


## The DERIVED half of this trait's tooltip (v0.43.0): the short phrases naming what it actually does,
## built from the subclass's own live fields. The base returns EMPTY, which is correct for a purely
## mechanical trait with nothing worth quoting — the tooltip then shows just the name and the prose.
##
## WHY THIS IS A VIRTUAL RATHER THAN A hud.gd FUNCTION: a trait's numbers live on its SUBCLASS
## (`Backstab.damage_multiplier`, `Archery.windup_beats_delta`), which the HUD cannot reach through the
## `PassiveAbility` base type — a `_passive_tooltip` doing `if passive is Backstab` would put a growing
## per-trait switch in the presentation layer and re-couple the HUD to every trait ever added. This keeps
## the existing split intact: the referee owns WHEN a hook runs, the passive owns WHETHER it applies —
## and now also owns how it DESCRIBES itself.
##
## CONTRACT for overrides: return `Array[String]`, exactly this type, built as a local typed array rather
## than a bare literal (GDScript's typed-array assignment is where a mismatch actually bites). Each entry
## is one short phrase, already formatted with its units — the HUD only joins them with ", ". A trait whose
## numbers are BEATS converts them itself (× `GameManager.tactical_beat_sec`, the autoload reachable from a
## Resource, which is the same multiply `hud.gd`'s `_secs` does): "beats" is a dev unit and must never reach
## a player (v0.41.0's plain-English pass).
func tooltip_terms() -> Array[String]:
	return []


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


## MOVEMENT-TIMING seam (v0.49.0, the ranger's Fleet of Foot). Receives the step's cost in BEATS *before*
## the pace multiply and the diagonal multiplier, and returns the (possibly modified) beats. The MOVER's
## own traits, chained in array order like every other modifier.
##
## WHAT ctx.beats ACTUALLY HOLDS, because it decides what a trait can honestly do: the ROUGH-TERRAIN
## candidate — the mover's tier, or `rough_step_beats` when `is_rough`. NOT the final step cost. That is
## deliberate (see MoveReferee._step_duration): the referee takes the SLOWEST of tier / this result / the
## exhausted crawl afterwards, so a trait handed the merged number could not tell which rule produced it,
## and "ignore rough" would silently cancel the crawl as well. Returning `ctx.beats` unchanged is the
## no-op; returning the tier when `is_rough` cancels exactly the terrain penalty.
##
## Host-only (MoveReferee's stamp). ctx keys: beats (float), mover (node), mover_id (int),
## tier_beats (float — the mover's own authored tier, so a trait can cancel back to it without
## re-deriving it), to_tile (Vector2i — the DESTINATION, since terrain is a property of where you are
## going), is_rough (bool).
func modify_move_beats(ctx: Dictionary) -> float:
	return float(ctx.get("beats", 0.0))


## THE DEFENDER'S damage seam (v0.49.0, the knight's Hold the Line) — the first hook in this file to run
## the TARGET's trait list rather than the attacker's. Receives the amount that survived the attacker's
## passives AND the armour rule, and returns the (possibly modified) amount.
##
## ORDER, pinned because it only looks commutative while every trait multiplies: attacker passives →
## armour's min-combined two-term rule → THIS → the monster-damage floor. The floor stays last so
## "enemies must always be able to hurt you" survives any stack of reductions, and running after armour
## means a reduction here COMPOUNDS with plate rather than competing with it (a knight's own trait losing
## to the knight's own armour would be the worst of both worlds).
##
## NOT gated on `_is_physical_kind`, unlike armour: a defender trait may reduce magic, which is most of
## what armour deliberately cannot touch. A trait meaning to be physical-only gates on ctx.kind itself —
## the referee owns WHEN the chain runs, the trait owns WHETHER it applies.
##
## Host-only. ctx keys: amount (int), attacker, target (nodes), attacker_id, target_id, kind, tags (Array),
## beats_since_move (float — the DEFENDER's stillness, supplied by the referee so a trait never fetches it).
func modify_damage_taken(ctx: Dictionary) -> int:
	return int(ctx.get("amount", 0))


## Post-death OBSERVATION seam (v0.49.0, the druid's Devour). Fired for every LIVING PLAYER within reach
## of a death — the bearer need not be the killer, which is exactly why `after_attack` could not serve it:
## that one runs the attacker's list, and this trait is about being NEARBY.
##
## Read-only like `before_attack` and `after_attack`: the death has already resolved and its `died` event
## has already been posted, so nothing here can change the kill. A trait acting on it (restoring mana,
## say) does so through a referee API, and its own event lands after `died` in the ordered stream — the
## honest order, since it happened because of the death.
##
## REACH IS WALL-BOUNDED (WorldGrid.tiles_within_travel from the death tile), so a kill two rooms away
## through a wall feeds nothing. `distance` is that travel distance, so a trait can be pickier than the
## referee's own radius without re-deriving anything.
##
## Host-only. ctx keys: dead_id, dead_name, death_tile (Vector2i), bearer (node), bearer_id (int),
## distance (int), combat (the CombatReferee, so a trait reaches the pool/HP APIs without a global).
func on_nearby_death(_ctx: Dictionary) -> void:
	pass


## QUERY (not a hook): extra reach in TILES this trait grants to TARGETED casts (v0.49.0, the wizard's
## Spellreach). 0 = none, which is every other trait.
##
## A QUERY, so BOTH SIDES evaluate it — see the header. The host adds it to the range gate; the client
## adds it to the targeting ring. If only the host knew, the ring would draw a circle the host refuses at
## its edge; if only the client knew, it would refuse to arm on tiles the host would accept. Because it is
## a pure read of the class resource plus `granted_traits` (both replicated), the two agree by
## construction rather than by a synced value.
##
## Scoped to TARGETED casts by its CALLERS, not by this function — `WeaponType.range_tiles` shares only a
## name with `ActiveAbility.range_tiles` and is the codebase's is-this-ranged predicate in a dozen places,
## so a bow must never see this.
func spell_range_bonus() -> int:
	return 0
