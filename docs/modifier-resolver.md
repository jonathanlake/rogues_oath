# The modifier resolver — design and migration

Status: **designed, not started.** Written at the end of the v0.43–v0.49 arc (2026-07-28) so the next
session begins with the reasoning rather than re-deriving it. ROADMAP carries the one-line pointer.

---

## Why

Jon's stated ambition (2026-07-28), verbatim in substance:

> Traits will interact with all sorts of things to give as much variety as possible. Potions and equipment
> will probably interact with the same amount of stuff, possibly active abilities as well. I want them to
> be able to manipulate any state the player has, interact with the terrain, enemies, and each other
> (traits buffing active abilities).

The current shape cannot get there, for two reasons that are worth separating.

### 1. Six of the eight trait hooks are one function wearing six hats

`resources/passive_ability.gd` has eight entry points. Three are **reactions** — `before_attack`,
`after_attack`, `on_nearby_death` — "something happened, observe it". Those are fine: there are few, they
are semantically distinct, and naming them is worth more than uniformity.

The other five plus the query are all *adjust a number, given a context*:

| hook | added | what it adjusts |
|---|---|---|
| `modify_damage` | v0.11.0 | outgoing damage |
| `modify_windup_beats` | v0.35.0 | a wielder's windup |
| `modify_recovery_beats` | v0.35.0 | a wielder's recovery |
| `modify_move_beats` | v0.49.0 | a step's cost |
| `modify_damage_taken` | v0.49.0 | incoming damage |
| `spell_range_bonus` | v0.49.0 | a targeted cast's reach |

Every new number anyone wants to touch costs a contract change, a header amendment, and a dispatch site.
Three of the four v0.49.0 traits needed a brand-new hook each. That curve does not flatten.

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

1. **Build the resolver alongside the hooks.** Nothing existing moves. New work may use it.
2. **Migrate ABILITY RANGE first.** It is the right first move because it *deletes* code rather than
   adding any: Spellreach's four hand-threaded sites and its bespoke `Player.spell_range_bonus()` collapse
   into one contribution. If the shape is wrong, this is where it shows, cheaply.
3. **Then one stat at a time, when something needs it.** Retire each modifier hook as its stat migrates.
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

## Open, for whenever it is reached

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
