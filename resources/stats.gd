class_name Stats
extends RefCounted

## THE MODIFIER RESOLVER (v0.50.0, step 1 of `docs/modifier-resolver.md`) — one named-stat registry and
## one algorithm, replacing the "a new number means a new hook" curve that six of `PassiveAbility`'s
## eight entry points were on.
##
## WHY IT EXISTS, in one sentence: every source in the game (a trait today; a worn item's trait already,
## and potions / abilities / terrain in future) contributes to a NAMED STAT through the same one method,
## so adding "a thing that changes a number" stops costing a contract change, a header amendment and a
## dispatch site. See the design doc for the full reasoning and the migration order.
##
## THE REGISTRY. Each stat is a StringName constant below, and each one DOCUMENTS ITS ctx KEYS beside
## itself — the same per-hook ctx-doc convention `passive_ability.gd` carries, for the same reason: the
## ctx is the contract between the site that resolves a stat and every source that might contribute to
## it, and an undocumented key is a key nobody can safely read. A new stat is a constant here, a ctx line
## beside it, and the adjudication site swapping its raw field read for a `resolve` call.
##
## ONE STAT PER VERSION (Jon's ruling, recorded in the design doc). The migration is a refactor across
## roughly 30–50 adjudication sites and every one is a place where a mistake stays invisible until a
## number comes out wrong in play. `modify_damage` migrates LAST — it is the one that is a BEHAVIOUR
## change rather than a refactor (see the stacking ruling below).
##
## HOST-ONLY vs ANY-PEER. `PassiveAbility`'s hooks are host-only because they mutate adjudication inside
## a referee. A STAT is not automatically either: a stat read for PRESENTATION (the targeting ring, a
## tooltip) must be computable on a CLIENT from replicated data alone, or the UI will promise a reach the
## host then refuses. So `modify_stat` must stay PURE — no referee reads, no host-only state — for any
## stat a client resolves. ABILITY_RANGE is exactly such a stat.

## TARGETED-CAST REACH in TILES (v0.50.0, migrated first because it DELETES code — Spellreach's four
## hand-threaded sites and its bespoke `Player.spell_range_bonus()` collapse into one contribution).
##
## Resolved through `Player.targeted_reach()`, which is the ONE place the float is rounded to tiles, so
## the host's range gate and the client's targeting ring cannot round apart.
##
## SCOPED TO TARGETED CASTS BY ITS CALLERS, not by anything here: `WeaponType.range_tiles` shares only a
## name with `ActiveAbility.range_tiles` and is the codebase's is-this-ranged predicate in a dozen
## places, so a bow must never resolve this stat.
##
## ctx keys: `ability` (ActiveAbility — the cast being measured, so a source can be pickier than "all
## spells": Spellreach reads none of it, a future "your fire spells reach further" reads all of it).
const ABILITY_RANGE := &"ability_range"


## THE ONE ALGORITHM. Walks `sources`, asks each for its contribution to `stat`, and applies the summed
## contributions to `base` exactly once.
##
## STACKING IS ADDITIVE, APPLIED ONCE (Jon's ruling, `docs/modifier-resolver.md`):
##     (base + Σflat) × (1 + Σpct)
## Two `+50%` sources give `+100%`, not `+125%`. Chosen over the multiplicative chain deliberately —
## multiplicative is today's ACCIDENTAL behaviour (`modify_damage` chains in array order, each hook
## receiving the previous one's output) and it stops being predictable exactly when the number of sources
## grows, which is the future this resolver is being built for.
##
## FLATS BEFORE PERCENTS, and that ordering is part of the ruling rather than an implementation detail: a
## percentage source describes "everything you have, plus a bit", so it must see the flats. The reverse
## order would make two identical loadouts differ by which source happened to be authored first.
##
## ORDER-INDEPENDENT BY CONSTRUCTION. Sums commute, so the answer does not depend on the order of
## `sources` — unlike the hook chain, where class-then-granted is load-bearing. That is the property
## worth having: a trait granted by a class, a grant or a robe resolves to the same number.
##
## A SOURCE contributes by implementing `modify_stat(stat, ctx) -> Dictionary`. Keys, both optional:
## "flat" (added to the base) and "pct" (a FRACTION — 0.25 is +25%, not 25). An EMPTY dictionary means
## "I have nothing to say about this stat", which is what the base virtual returns and therefore what
## almost every source returns for almost every stat. `{}` and `{"flat": 0.0}` are equivalent.
##
## DUCK-TYPED over `sources` (untyped Array, matching `Player.all_traits()`), so the resolver is
## SOURCE-AGNOSTIC — that is the whole point of the shape. A trait implements `modify_stat` today; an
## `ItemType`, an `ActiveAbility` or a terrain descriptor can implement the same one method tomorrow
## without this function learning what any of them are. Anything in the array lacking the method is
## skipped, which is also what makes a mixed-source array safe.
##
## THE CALLER ROUNDS. This returns a float on purpose: whether a stat floors, rounds or stays fractional
## is a property of the stat, not of the arithmetic — and the rounding belongs in ONE named accessor per
## stat (`Player.targeted_reach`) so two call sites cannot round apart.
##
## NAMED-TERM SUPPRESSION IS DESIGNED BUT NOT IMPLEMENTED HERE, deliberately. Jon's second ruling is that
## a source may additionally declare it SUPPRESSES a specific named term of a stat (Fleet of Foot cancels
## the TERRAIN term of a step's cost while leaving the exhausted crawl alone). That needs a stat whose
## base is built from named terms, and the first one is MOVE_BEATS — so the key ("suppress": [term, …])
## lands with that migration rather than as dead code nothing produces today. Stated here so the next
## person adds it to this function instead of inventing a parallel mechanism.
static func resolve(stat: StringName, base: float, sources: Array, ctx: Dictionary) -> float:
	var flat_sum := 0.0
	var pct_sum := 0.0
	for src in sources:
		if src == null or not src.has_method("modify_stat"):
			continue
		var c = src.modify_stat(stat, ctx)
		if typeof(c) != TYPE_DICTIONARY or c.is_empty():
			continue
		flat_sum += float(c.get("flat", 0.0))
		pct_sum += float(c.get("pct", 0.0))
	return (base + flat_sum) * (1.0 + pct_sum)
