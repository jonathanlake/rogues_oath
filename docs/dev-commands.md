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
| `/w <weapon> [field] <value\|reset>` | Tune a weapon. Field ∈ `damage` (0–999), `attack_beats` (0.05–30), `windup_beats` (0–30); omitted field = `damage`. Out-of-range values are rejected. `reset` restores all three from disk. |
| `/<weapon> <value>` | Shorthand for `/w <weapon> damage <value>` (e.g. `/longsword 5`). The command table wins over this alias, so a weapon named like a command is only reachable via `/w`. |
| `/m <monster> <field> <value\|reset>` | Tune a MonsterType. Fields: `max_hp`, `aggro_range_tiles`, `tactical_radius_tiles`, `bonus_windup_beats`, `bonus_recovery_beats`, `bonus_damage`, plus spell params (v0.19.10) `heal_amount`/`heal_range_tiles`/`heal_cast_beats`/`heal_recovery_beats`, `smite_damage`/`smite_range_tiles`/`smite_cast_beats`/`smite_recovery_beats`, and `flee_range_tiles`. Out-of-range rejected; `reset` restores all. `/help` prints the live list (derived from the allowlist, never stale). |
| `/god` | Toggle **your own** invulnerability. A hit on a godded target resolves as a visible no-op (grey `0` popup + "no effect (god)" log line), never a silent block. Cleared on disconnect / despawn / F5 respawn. |
| `/class <name>` | Set **your own** class (sprite today, stats later). `name` ∈ `rogue`, `knight`, `wizard`, `barbarian`, `priest`, `ranger`. Broadcasts to every peer; late joiners sync via `sync_player_field`. Reverts to the slot default on F5 respawn. |
| `/item <name> [x,y]` | Spawn a ground item (v0.18.0). Tile = explicit `x,y`, else the sender's facing-neighbour tile (never the own tile → reject if the sender hasn't faced yet). Distinct rejects: unknown item / broken resource path (catalog drift) / not-walkable / tile already has an item. Multi-word names work (`/item health potion`). |
| `/stun [me\|<monster>] [beats]` | Apply a STUN (v0.20.0). No arg / `me` / `self` stuns you; a monster display_name stuns the first live monster of that name. A numeric token = beats (default 3). Host-authoritative; the overhead icon shows on every peer. Stun blocks *starting* a new action but never interrupts an in-flight one (§2.1). |
| `/config <alias>` | Apply a preset **bundle** of `/w` + `/m` tunings in one command (v0.19.7). Aliases live in `GameManager.CONFIG_PRESETS`; each row runs through the same allowlist + clamp path as `/w`/`/m`, so a bad row rejects the whole `/config` naming that row. Currently `1` = longsword & club `windup_beats 1`/`attack_beats 3`, goblin `bonus_windup_beats 1`. Add a loadout by adding an alias entry — no code change. |
| `/help` | Print the command list (local only — never crosses the wire). |

## Resolution notes

- **Weapons** resolve `GameConfig.weapon_roster` (by `display_name`) first, then a filename load
  `res://resources/weapons/<name>.tres` (guarded by `ResourceLoader.exists`) — so the claw (not in the
  roster) is reachable as `/w claw ...`.
- **Monsters** resolve only by filename: `res://resources/monsters/<name>.tres` (e.g. `/m goblin ...`).
- **Items** resolve by `display_name` through `GameConfig.item_catalog` (`item_by_name`) — so a
  spawnable item must be in the catalog (a mis-authored/duplicate name warns at session start).
- **`reset`** re-reads the `.tres` from disk with `CACHE_MODE_IGNORE` and copies the allowlisted fields
  back onto the shared live instance.
- **`/m ... max_hp`** affects **new spawns only** (HP is seeded at spawn); the other three monster
  fields are read live. The other tunes take effect from the next adjudicated verdict (stamp-and-bake —
  in-flight commits keep their baked values).

## Scripted testing

The `cmd=` autostart knob feeds one command through the real `game_log._on_input_submitted()` entry
point (the genuine interception path), on either role: e.g. `-- host cmd=/god`,
`-- join cmd=/w longsword 3`, `cmd=/class knight`. `cmdwait=<sec>` overrides the fire delay.
