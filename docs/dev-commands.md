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
| `/stamina` (alias `/mp`) | Toggle the **stamina experiment** (v0.24.0, renamed v0.24.1) live. OFF = byte-for-byte pre-experiment movement and AI (no pool mutation; sweat-drops clear); ON = every pool reseeds to full. Host-authoritative (all reads are host-side). Dials (v0.24.2 direct form; v0.24.3 additions): `/config regen_idle_beats 10`, `/config regen_interval_beats 4`, `/config exhausted_step_beats 5` (crawl speed), `/config monster_think_min_beats 1` / `monster_think_max_beats 6` (hesitation roll range), `/config stamina_refill_lockout_beats 20` (how long after leaving battle a re-entry still counts as the same fight — no refill), `/config stamina_max 3` (PLAYER pip baseline, 1–12; players add class `bonus_stamina` — rogue +1), `/config monster_stamina_max 3` (the MONSTERS' own independent pool, v0.24.7). Both land at the next battle entry, or /stamina off/on to reseed now. |
| `/winded` | Toggle **hard-stop exhaustion** (v0.24.6): on = 0 stamina refuses movement outright (distinct "winded" reject; players and monsters alike); off = the v0.24.1 slow crawl (`exhausted_step_beats`). Host-authoritative config flip, read at adjudication. |
| `/help` | Print the command list (local only — never crosses the wire). |

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
