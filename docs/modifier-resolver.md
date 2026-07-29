# The modifier resolver — design and migration

Status: **step 1 SHIPPED (v0.50.0).** `Stats.resolve` exists, `ABILITY_RANGE` is migrated onto it, and
equipment is a trait source. The rest of the migration below is unstarted and still governs. Written at
the end of the v0.43–v0.49 arc (2026-07-28) so the next session begins with the reasoning rather than
re-deriving it. ROADMAP carries the one-line pointer.

---

## The three-layer rule (Jon, 2026-07-28) — read this before adding anything

The question that produced it: *"if a boot does something magical, should it show up as a trait for as
long as it is equipped?"* Yes — but only if it clears the bar. Everything new sorts into exactly one of
three layers, and the rule exists to keep the trait list **worth reading**: if every `+1` becomes a
trait, the character panel becomes a wall nobody looks at, and traits stop being identity.

| layer | what it holds | where it lives | examples |
|---|---|---|---|
| **FIELD / KEYWORD** | what a thing intrinsically *is* | an `@export` on the resource | cleave on an axe, `WeaponType.damage_type` on a flaming sword, `armor_weight` |
| **STAT** | a number *many* sources push on | a named stat in `Stats`, resolved | spell reach, move beats, fire resistance |
| **TRAIT** | a named behaviour a player would describe in a sentence | a `PassiveAbility` resource | Sneak Attack, Devour, Fleet of Foot, Farsight |

The test for the third layer: **would a player describe it in a sentence rather than a number?** If yes,
it is a trait. "All axes cleave" is a keyword — it is what an axe *is*, and every axe having it means it
identifies the weapon, not the build. A boot that is merely +1 speed contributes to a stat. A boot that
*ignores rough terrain* is a trait, because that is a sentence.

Corollary for the layers' interaction: **fields are not resolver-invisible forever.** A field enters the
resolver through `ctx` the moment a stat needs it (a hypothetical cleave-radius stat would receive the
weapon in its ctx, exactly as `ABILITY_RANGE` receives the ability). The layers describe where a value is
*authored*, not what may read it.

### Equipment is a source, and it is DERIVED (v0.50.0)

`ItemType.granted_traits` names the traits a worn item confers. `Player.all_traits()` returns
**class → granted → worn gear**, deduped by reference identity, and the gear half is *computed on every
read* rather than written into `granted_traits`.

Derived, never granted, for two reasons that are both load-bearing: unequipping needs **zero
bookkeeping** (a flat granted-array would have to remove the right copy when a boot and a potion give the
same trait), and there is **no new wire traffic** — gear is already replicated everywhere (spawn seed,
`equip_item` event, late-join `sync_player_field`), so every peer's derived union agrees by construction
rather than by a synced value. This is the same argument that put `all_traits()` on `Player` in v0.49.0.

### Resistances: designed for, deliberately unbuilt

Jon wants fire resistance to be "its own thing that any of the above can manipulate, even an enemy could
debuff it". That is already the STAT layer's shape, and it needs no code until elemental damage exists —
which it does not (`kind` is *provenance*, not element; `WeaponType.damage_type` is labels-only and says
so in its own header, though it already rides the wire). **The seam is the future-proofing.** When
elemental damage ships, a `fire_resist` stat joins the registry and traits/items/enemy debuffs contribute
to it the same way everything else does. Do not build it early.

---

## Why

Jon's stated ambition (2026-07-28), verbatim in substance:

> Traits will interact with all sorts of things to give as much variety as possible. Potions and equipment
> will probably interact with the same amount of stuff, possibly active abilities as well. I want them to
> be able to manipulate any state the player has, interact with the terrain, enemies, and each other
> (traits buffing active abilities).

The pre-v0.50.0 shape could not get there, for two reasons that are worth separating. **This section is
the historical diagnosis** — it describes the state at v0.49.0, which is what the migration below is
dismantling. For where things stand now, read the status line at the top.

### 1. Six of the eight trait hooks were one function wearing six hats

At v0.49.0 `resources/passive_ability.gd` had eight entry points. Three are **reactions** —
`before_attack`, `after_attack`, `on_nearby_death` — "something happened, observe it". Those are fine:
there are few, they are semantically distinct, and naming them is worth more than uniformity. **They are
not migrating** and are untouched.

The other five plus the query were all *adjust a number, given a context*:

| hook | added | what it adjusts | status |
|---|---|---|---|
| `modify_damage` | v0.11.0 | outgoing damage | migrates LAST (behaviour change) |
| `modify_windup_beats` | v0.35.0 | a wielder's windup | **next up** |
| `modify_recovery_beats` | v0.35.0 | a wielder's recovery | **next up** |
| `modify_move_beats` | v0.49.0 | a step's cost | forces named suppression |
| `modify_damage_taken` | v0.49.0 | incoming damage | pending |
| ~~`spell_range_bonus`~~ | v0.49.0 | a targeted cast's reach | **GONE — migrated v0.50.0** |

Every new number anyone wanted to touch cost a contract change, a header amendment, and a dispatch site.
Three of the four v0.49.0 traits needed a brand-new hook each. That curve does not flatten — which is why
`modify_stat` replaced the *next* one rather than a seventh hook being added.

### 2. The real explosion is SOURCES × HOOKS, not hooks

The hooks live on `PassiveAbility`. An **item** that wants to shorten a windup cannot — `ItemType` has no
hooks at all. Under the current shape, giving potions and equipment the same reach means a parallel hook
set on `ItemType`, another on `ActiveAbility`, and the same six ideas written four times over.

### 3. "Traits buffing abilities" is not expressible today

Ability numbers are read RAW at roughly twenty adjudication sites — `ability.damage`,
`ability.range_tiles`, `ability.cooldown_beats`, `ability.windup_beats`. Spellreach only works because
v0.49.0 hand-threaded a bonus through four of them, using one shared local so the host gate and the
client ring could not disagree. **That thread is the argument for this document**: it does not scale to
"any source can buff any ability number", and the next such trait would hand-thread another four sites.

---

## The shape

**One resolver for numbers. The existing named hooks for reactions.**

```
resolve(stat, base, ctx) -> float/int
```

It walks every SOURCE the entity has — class traits, granted traits, worn equipment, active potion
effects, and the ability itself — and lets each contribute to a named stat.

Two properties fall out, and they are precisely what the ambition needs:

- **Source-agnostic.** A trait, a potion and a piece of armour all implement the same one method. "A potion
  that does what Fleet of Foot does" becomes authoring a `.tres`, not touching a referee.
- **Ability numbers become buffable for free.** The moment `_use_targeted` reads
  `resolve(ABILITY_RANGE, ability.range_tiles, ctx)` instead of the raw field, every source in the game can
  modify it — and Spellreach *collapses* from four hand-threaded sites into one small contribution.

### Jon's two rulings (2026-07-28)

**STACKING IS ADDITIVE, APPLIED ONCE.** All the `+X%` contributions to a stat sum, then one multiply is
applied to the base. Two `+50%` sources give `+100%`, not `+125%`.

Chosen over the multiplicative chain deliberately: multiplicative is today's *accidental* behaviour
(`modify_damage` chains in array order, each trait receiving the previous one's output, so Sneak Attack's
×2 followed by a hypothetical ×1.5 gives ×3), and it stops being predictable exactly when the number of
sources grows — which is the future being designed for. Note this means **migrating `modify_damage` to the
resolver is a behaviour change**, not a refactor; it needs its own release note and its own playtest.

**A SOURCE MAY SUPPRESS A NAMED TERM.** Contribution is the default; a source may additionally declare
that it suppresses a specific named term.

This exists because Fleet of Foot already needs it: it cancels the *terrain* term and must leave the
exhausted crawl alone. v0.49.0 expressed that by handing the hook the terrain candidate rather than the
merged number — a trick that works for one term and does not generalise. Named suppression is the general
form, and it is bounded: a source can only suppress a term that exists, so there is no last-writer-wins
ordering hazard the way a full override would have.

### What stays as it is

The three reaction hooks. `on_nearby_death` reading as itself is clearer than
`on_event(EVENT_NEARBY_DEATH, ctx)`, and there is no growth pressure on three.

---

## Migration

**This is a refactor, not a batch.** Every raw field read at an adjudication site becomes a resolve call:
heaviest in `world/combat_referee.gd`, with `world/move_referee.gd` and `world/inventory_referee.gd`
behind it. Roughly 30–50 sites, and every one is a place where a mistake is invisible until a number comes
out wrong in play.

So it does not land in one go. The sequencing, smallest-provable-step first:

1. ~~**Build the resolver alongside the hooks.**~~ **DONE v0.50.0** — `resources/stats.gd`
   (`Stats.resolve(stat, base, sources, ctx)`) plus the `PassiveAbility.modify_stat(stat, ctx)`
   contribution virtual. The existing hooks are untouched.
2. ~~**Migrate ABILITY RANGE first.**~~ **DONE v0.50.0**, and it did delete more than it added:
   `PassiveAbility.spell_range_bonus`, `Player.spell_range_bonus` and
   `CombatReferee._spell_range_bonus_of` are gone, and the four hand-threaded sites now call one shared
   `Player.targeted_reach(ability)` — which is also **the single rounding site**, so the host gate and the
   client ring cannot round apart, a hazard the four-site version had no defence against.
3. **Then one stat at a time, when something needs it.** Retire each modifier hook as its stat migrates.
   **Next up: `WINDUP_BEATS` / `RECOVERY_BEATS`** — `_windup_duration_of` and `_recovery_duration_of` are
   already the single funnels for every windup/recovery in the file, and the migration should absorb
   `MonsterType.bonus_windup_beats` / `bonus_recovery_beats` in the same move (they are additive flats
   sitting inside that very funnel). `MOVE_BEATS` is the one that forces **named-term suppression** to be
   built, since Fleet of Foot must cancel the terrain term and leave the exhausted crawl alone.
   `modify_damage` goes LAST — it is the behaviour change (see the stacking ruling) and the most
   load-bearing.

At every step both systems coexist and each is verifiable on its own. Never hold two half-built ones.

### Verification shape

Each migrated stat wants the same two assertions:
- the stat resolves to its authored value with no sources present (a pure refactor, provable);
- a source contributing changes it by exactly the expected amount, **and** a second source stacks
  additively rather than multiplicatively (the ruling, made checkable).

`Spellreach` is the ready-made case for both: `/pa spellreach range_bonus 0` already proves the
with-and-without pair, and a granted second reach source would prove the stacking rule.

---

## OPEN — do traits stack, or upgrade? (Jon, undecided 2026-07-28)

Left open deliberately; **do not resolve it by accident** in a version that happens to touch traits.
Jon's words: *"part of me wants unique traits, but I also think if you want to stack archery skills, like
having the archery trait, and boots that make you faster with a bow, there should be a way to do that."*
Also on the table: **upgrades** — an "Archery II", possibly chosen as a **branching** decision on level-up
(Devour upgrading either to restore more mana for less reach, *or* to reach the whole floor).

**The thing that makes this less urgent than it sounds:** Jon's own example — Archery *plus* bow-speed
boots — needs **no machinery at all**. Those are two DIFFERENT trait resources contributing to the same
stat, and the additive ruling already sums them. Reference-identity dedupe only bites for the *same
resource twice*, which is a duplicate, not a build. So the currently-shipped behaviour already serves the
motivating case, and the genuinely undecided part is narrower than it first looks:

- the **same** trait from two sources — does the second do nothing (today's answer), or add?
- explicit **ranks** — should Archery II *replace* Archery I rather than stack with it?

Whenever it is answered, the likely shape is a `family` + `rank` (+ per-trait `stacks` opt-out) on
`PassiveAbility`: same family never coexists, higher rank wins, and branching upgrades are then just two
`.tres` files in one family — no further data model. **Branching does not need deciding now**; nothing in
today's shape forecloses it. One UX debt to pay when it lands: a trait that is silently suppressed
(dedupe today, lower-rank tomorrow) must **say so in the tooltip**, or a player wearing a redundant item
gets nothing and is never told why.

## Open, for whenever it is reached

- **Equipment granting ACTIVE ABILITIES** (the kite shield's Shield Block) is NOT closed by v0.50.0 and
  stays parked in ROADMAP. Traits could go derived because the trait union is an unordered set; an
  ability is addressed by **slot index** on the wire, so a derived ability list changes what pressing "2"
  casts. That, plus the unanswered unequip-mid-cooldown question, is why the harder half waited.
- **Do monsters get sources?** `_passives_of` already returns `[]` for them by duck-typing, and
  `MonsterType` carries its own `bonus_*` fields that are a parallel modifier system in all but name. The
  resolver could absorb them; nothing forces it to.
- **Where does the client draw the line?** v0.49.0 established that hooks are host-only while *queries* may
  be evaluated on any peer, because the targeting ring must agree with the host's gate
  (`resources/passive_ability.gd` header). The resolver inherits that split: a stat read for PRESENTATION
  must be computable client-side from replicated data alone.
- **Terrain as a source.** Jon wants sources to "interact with the terrain". Rough ground is currently a
  term inside `_step_duration` rather than a source; making terrain contribute to a stat like anything else
  would unify it, and would let a trait suppress it by name without the referee knowing the trait exists.
