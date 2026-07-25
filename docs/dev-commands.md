# Dev slash commands (v0.10.0)

Live tuning + dev toggles typed into the in-game chat box. A leading `/` marks a dev command: the
game log intercepts it (never sends it as chat), parses it client-side into `{cmd, args}`, and submits
a `dev_command` intent the **host** validates and adjudicates (server-authoritative — the host reads
and mutates the shared config `.tres`, never a client value). Tokens are lowercased, so commands,
weapon/monster/class names, and field names are case-insensitive.

Dev-era, open to **any peer** (host or client), like the F5/F6/tempo keys. Nothing persists: a process
restart restores every authored value (no command saves to disk).

## Commands

| Command | Effect |
|---|---|
| `/w <weapon> [field] <value\|reset>` | Tune a weapon. Field ∈ `damage` (0–999), `recovery_beats` (0.05–30; the post-strike/post-loose tail — renamed from `attack_beats` v0.23.1), `windup_beats` (0–30; the telegraph/draw before it — total commit = windup + recovery, melee and ranged alike); omitted field = `damage`. Out-of-range values are rejected. `reset` restores all three from disk. |
| `/<weapon> <value>` | Shorthand for `/w <weapon> damage <value>` (e.g. `/longsword 5`). The command table wins over this alias, so a weapon named like a command is only reachable via `/w`. |
| `/m <monster> <field> <value\|reset>` | Tune a MonsterType. Fields: `max_hp`, `aggro_range_tiles`, `tactical_radius_tiles`, `bonus_windup_beats`, `bonus_recovery_beats`, `bonus_damage`, plus spell params (v0.19.10) `heal_amount`/`heal_range_tiles`/`heal_cast_beats`/`heal_recovery_beats`, `smite_damage`/`smite_range_tiles`/`smite_cast_beats`/`smite_recovery_beats`, and `flee_range_tiles`. Out-of-range rejected; `reset` restores all. `/help` prints the live list (derived from the allowlist, never stale). |
| `/god` | Toggle **your own** invulnerability. A hit on a godded target resolves as a visible no-op (grey `0` popup + "no effect (god)" log line), never a silent block. Cleared on disconnect / despawn / F5 respawn. |
| `/class <name>` | Set **your own** class (sprite today, stats later). `name` ∈ `rogue`, `knight`, `wizard`, `barbarian`, `priest`, `ranger`. Broadcasts to every peer; late joiners sync via `sync_player_field`. Reverts to the slot default on F5 respawn. |
| `/item <name> [x,y]` | Spawn a ground item (v0.18.0). Tile = explicit `x,y`, else the sender's facing-neighbour tile (never the own tile → reject if the sender hasn't faced yet). Distinct rejects: unknown item or weapon / broken resource path (catalog drift) / not-walkable / tile already has an item. Multi-word names work (`/item health potion`). **v0.21.0: `<name>` resolves the WEAPON catalog as a fallback** (`/item longsword`), so weapons can be placed as ground items — necessary now that only potions autopickup and everything else must be taken with **G**. |
| `/stun [me\|<monster>] [beats]` | Apply a STUN (v0.20.0). No arg / `me` / `self` stuns you; a monster display_name stuns the first live monster of that name. A numeric token = beats (default 3). Host-authoritative; the overhead icon shows on every peer. Stun blocks *starting* a new action AND — since v0.20.2 — INTERRUPTS an in-flight attack/cast (its resolve fizzles); movement is not interrupted. This is the one sanctioned exception to the Commitment Rule (DESIGN §2.11). |
| `/config <alias>` | Apply a preset **bundle** of tunings in one command (v0.19.7). Aliases live in `GameManager.CONFIG_PRESETS`; a bad row rejects the whole `/config` naming that row. Rows come in three kinds: `w` (weapon) and `m` (monster) run through the same allowlist + clamp path as `/w`/`/m`; **`g` (game-level, v0.22.1)** is allowlisted by `GameManager.DEV_GAME_FIELDS` and dispatched per-field instead — today only `tactical_beat_sec`, which is snapped/clamped to the shared tempo band and then published as a normal **`set_tactical_tempo` broadcast**, so every peer adopts it exactly as a `[`/`]` nudge does (never a direct host-side write, which would leave clients' dials stale). Currently `1` = longsword & club `windup_beats 1`/`recovery_beats 3`, goblin `bonus_windup_beats 1`, **tactical beat `0.25`s** (halved from the 0.50s default, so the preset's 1-beat windup / 3-beat swing lands at 0.25s / 0.75s in a fight). Presets **clobber live values by design** — re-applying an alias restamps every row, including a tempo someone had nudged; a re-apply is idempotent (the `g` row skips the host validator's "no change" reject so it can't fail the bundle). `2` (v0.23.2) = the heavier-telegraph loadout: longsword/club `windup 3`/`recovery 4`, dagger `windup 2`/`recovery 4`, tactical beat `0.25`s. Add a loadout by adding an alias entry — no code change (a new `g` *field*, though, needs its dispatch branch). |
| `/ai` | Toggle the **utility-AI score broadcast** (v0.22.0, host-side gate, default OFF). While on, every **committed** utility-brain decision posts an `ai_decision` event (personality, per-action scores, the action that actually committed) that ALL peers' F3 overlays render — one line per monster. Idle thinks and fully-declined walks post nothing (v0.22.1 — they drowned the traces), and `chosen` names what COMMITTED, so a higher score beside a different chosen action reads as "top pick declined" (e.g. a cornered flee) at a glance. Zero wire noise while off. The `/m` allowlist includes the 13 `utility_*`/`backup_radius_tiles` weights, so you can watch a retune move the numbers live; `ai_decision` is in the `eventlog=` allowlist for scripted runs. |
| `/stamina` (alias `/mp`) | Toggle stamina live — since **v0.26.0 stamina is a CORE RULE** (DESIGN §2.2.10, Jeff's verdict), so this is a **dev escape hatch**, not the revert switch it was while the mechanic was provisional. OFF = byte-for-byte pre-stamina movement and AI (no pool mutation; sweat-drops clear); ON = every pool reseeds to full. Host-authoritative (all reads are host-side). See the dial table below for every `/config` field — **note that every stamina dial has been a `player_`/`monster_` PAIR since v0.25.0**; the old unsplit names (`regen_idle_beats`, `regen_interval_beats`, `exhausted_step_beats`, `stamina_refill_lockout_beats`, `regen_refills_full`, `passive_regen_beats`) no longer exist and reject as unknown fields. |
| `/winded` | Toggle **hard-stop exhaustion** (v0.24.6): on = 0 stamina refuses movement outright (distinct "winded" reject; players and monsters alike); off = the v0.24.1 slow crawl (`player_/monster_exhausted_step_beats`). One convergent toggle over the two `*_exhausted_blocks_movement` fields, which `/config` can also set per side. Since v0.26.0 the sweat-drop overhead cue means ONLY this mode — plain resting has its own recovery bar. |
| `/mi <id> <field\|hp\|stamina\|stun\|kill\|reset> [v]` | **Per-INSTANCE monster tuning** (v0.25.0). `id` = entity id (negative; bare positive is negated). Stat fields run the same allowlist/clamps as `/m` but against a LAZY instance-local duplicate of the MonsterType — untouched monsters keep sharing the `.tres`, so `/m` stays global; `reset` rejoins the shared type. `hp`/`stamina` poke live referee state through the normal events; `kill` runs the real death path (drops, banter, all of it). |
| `/snapshot` | Broadcast a `dev_snapshot` event carrying the full tuning truth (game fields, weapon + monster-type values, live instances with hp/stamina). The debug panel's refresh source; deferred verdict, so no log spam. |
| `/help` | Print the command list (local only — never crosses the wire). |

## Game-level `/config` fields (the direct `g` form)

`/config <field> <value>` sets ONE game-level dial (v0.22.1's `g` kind, direct form v0.24.2) — the same
allowlist (`GameManager.DEV_GAME_FIELDS`) and clamp table (`DevCommands._GAME_FIELD_SPECS`) the preset
bundles run through, so a typed value can never poison the config past its clamp. Host-side write, read
live at the referee's arm/stamp/resolve site; nothing persists past a restart. `/help` derives its list
from the allowlist, so it is never stale — this table is the annotated version.

| Field | Range | What it does |
|---|---|---|
| `tactical_beat_sec` | tempo band | The TACTICAL pace beat; published as a `set_tactical_tempo` broadcast (not a silent host write) so every peer adopts it exactly as a `[`/`]` nudge does. |
| `stamina_max` | 1–12 | The PLAYER stamina pool (**default 1** since v0.26.0; classes may still add `bonus_stamina`, all 0 today). HUD pips only render when this is > 1. |
| `monster_stamina_max` | 1–12 | The MONSTERS' own independent pool (default 1). |
| `player_regen_idle_light_beats` | 0–100 | **v0.26.0** — the rest-to-recover idle wait for a LIGHT (or UNARMORED) class. Default 2.5. |
| `player_regen_idle_medium_beats` | 0–100 | Same, MEDIUM armor weight. Default 3.0. |
| `player_regen_idle_heavy_beats` | 0–100 | Same, HEAVY armor weight. Default 3.5. Heavier armor rests slower — that IS the armor cost curve (DESIGN §2.2.10 / §2.3.8). |
| `monster_regen_idle_beats` | 0–100 | The monsters' single idle wait (default 3.5). *(These four replaced the one `player_regen_idle_beats` dial — the player side is no longer one number.)* |
| `player_regen_interval_beats` / `monster_regen_interval_beats` | 0.25–100 | Beats per recovered point after the idle wait completes. **Moot at max 1** (the first tick fills the pool) but kept live-tunable. |
| `player_exhausted_step_beats` / `monster_exhausted_step_beats` | 1–100 | Crawl speed at 0 stamina (the soft-exhaustion branch). |
| `player_exhausted_blocks_movement` / `monster_exhausted_blocks_movement` | 0\|1 | Hard-stop at 0 instead of the crawl — the per-side halves of `/winded`. |
| `player_refill_lockout_beats` / `monster_refill_lockout_beats` | 0–200 | How long after leaving battle a re-entry still counts as the same fight (no refill). |
| `player_regen_refills_full` / `monster_regen_refills_full` | 0\|1 | Rest completion refills the WHOLE pool at once (no trickle). |
| `player_passive_regen_beats` / `monster_passive_regen_beats` | 0–100 | +1 stamina every N beats regardless of activity; 0 = off. |
| `monster_think_min_beats` / `monster_think_max_beats` | 0–30 | The visible-hesitation roll range at story-beat moments. |
| `swing_catches_adjacent` | 0\|1 | Sticky swings (v0.24.8) — a sidestep that stays adjacent to the swinger is still caught at resolve; 0 = pure ground commit. |
| `instant_abilities_enabled` | 0\|1 | **v0.26.0 experiment master toggle** (default ON) — Shield Block + Shadow Step (DESIGN §2.11.1). OFF = both abilities reject and nothing else anywhere behaves differently, i.e. the pre-v0.26 game exactly. This is the dial Jeff flips to answer the verdict question. |
| `shield_block_cooldown_beats` | 0–600 | Knight Shield Block cooldown, charged on CONSUMPTION (default 30). |
| `shadow_step_cooldown_beats` | 0–600 | Rogue Shadow Step cooldown (default 20). A blocked destination burns none of it. |

## The backtick debug panel (v0.25.0)

Press **`** (backtick) in-game to open the DEBUG TUNING PANEL — an inspector-style GUI over the
whole command surface, on every peer. Sections: GAME/STAMINA (every split dial, players column vs
monsters column), WEAPONS, MONSTER TYPES (shared `.tres` tuning = `/m`), LIVE INSTANCES (per-monster
hp/stamina/stun/kill and per-instance stat forks = `/mi`). Every widget edit submits the same
server-authoritative `dev_command` intent the typed command would (debounced 0.3s); displayed values
come only from host-authored `dev_snapshot` events, so a client's panel shows host truth, never its
own stale config. `debugpanel=1` is the autostart knob for scripted screenshots.

**v0.26.0 rows.** The four REGEN-IDLE dials moved OUT of the paired players|monsters block into shared
single-column rows — the player side is three ARMOR-WEIGHT bands (`LIGHT` also covers unarmored) plus
the monsters' one, which a two-column row can't express; they stay adjacent so every idle wait reads as
one group. The instants experiment added three more shared rows: the `instant abilities` toggle and the
`shield block CD` / `shadow step CD` dials.

## Resolution notes

- **Weapons** resolve `GameConfig.weapon_roster` (by `display_name`) first, then a filename load
  `res://resources/weapons/<name>.tres` (guarded by `ResourceLoader.exists`) — so the claw (not in the
  roster) is reachable as `/w claw ...`.
- **Monsters** resolve only by filename: `res://resources/monsters/<name>.tres` (e.g. `/m goblin ...`).
- **Items** resolve by `display_name` through `GameConfig.item_catalog` (`item_by_name`) first, then
  `weapon_catalog` (`weapon_by_name`, v0.21.0) — so a spawnable item must be in ONE of the two catalogs.
  That item-first order is the same one `GameConfig.category_of()` and the HUD's bag icons use; a
  `display_name` present in BOTH catalogs only warns at session start (it does not fail), so keep names
  unique across them.
- **`reset`** re-reads the `.tres` from disk with `CACHE_MODE_IGNORE` and copies the allowlisted fields
  back onto the shared live instance.
- **`/m ... max_hp`** affects **new spawns only** (HP is seeded at spawn); the other three monster
  fields are read live. The other tunes take effect from the next adjudicated verdict (stamp-and-bake —
  in-flight commits keep their baked values).

## The G key (manual pickup, v0.21.0)

Not a slash command — a real gameplay key — but it's the other half of `/item`, so it's documented here.
Autopickup is **potion-only**: walk over anything else (a dropped weapon, a `/item longsword`) and it stays
on the ground with a "press G to pick up" line in your own log (or a bag-full line instead, if the bag is
full). **G** submits a `pickup_item` intent with an EMPTY payload — the host reads your tile from the move
referee's authoritative occupancy — and the pickup is INSTANT, not a committed window: the busy gate refuses
it during any action, so it can only happen between actions. Distinct §2.2.8 rejects, in adjudication order:
dead → stunned → busy → not in session → nothing to pick up → bag full. Bag capacity is authored in
`game_config.tres` as `inventory_slots` (20).

## Scripted testing

The `cmd=` autostart knob feeds one command through the real `game_log._on_input_submitted()` entry
point (the genuine interception path), on either role: e.g. `-- host cmd=/god`,
`-- join cmd=/w longsword 3`, `cmd=/class knight`. `cmdwait=<sec>` overrides the fire delay.

`pickup=<n>` / `pickupwait=<sec>` (v0.21.0) script the G key from either role. The key's own sampling is
focus-gated like the number keys, so an unfocused window in a two-instance run can never reach it — the knob
bypasses the sampler and submits the **intent**, which is where the adjudication lives (the exact shape of
`ability=`). `n` is clamped 0–8 and the intents go back-to-back with NO spacing, so `pickup=2` lands both in
ONE frame — deliberately the adversarial case for `GroundItem.on_tile`'s `is_queued_for_deletion` ghost guard
(`queue_free()` sets that flag synchronously but defers tree removal, so without the guard the same item banks
twice). Expected: exactly one `item_picked_up`, the rest `rejected pickup_item: nothing to pick up`. The
default anchor is the move anchor — so a run can walk onto a non-potion and then take it — and `pickupwait=`
pins it. The `eventlog=` allowlist now carries `item_picked_up`, `item_pickup_full`, `item_pickup_available`,
`item_used` and `equip_item`, which is how these assertions are made two-instance.

`ability=<index>[,<index>...]` / `abilitywait=` / `abilitydelay=` script the 1-5 hotbar (0-based index)
through the real `use_ability` intent from either role. The **list form is v0.26.0**, for the instants
experiment: a COOLDOWN reject is only observable by pressing the SAME slot twice in one session
(`ability=1,1`), and a reject reaches only the SENDER's stdout — so both presses have to come from one
instance. `abilitywait=` is the first-fire delay, `abilitydelay=` the spacing between presses (default
0.5s, tight enough to land the second press well inside any cooldown; widen it to watch one expire).

`eventlog=` gained four actions in v0.26.0: **`stamina_recovery`** (the host-stamped armor-weight rest
wait — the only way to assert 2.5 / 3.0 / 3.5 scaling in a scripted run) and the three instants
observables **`blink`**, **`ability_used`** and **`ability_cooldown`** (`status_applied`/`status_expired`
were already in, which is how the block's `"block"` status is asserted).
