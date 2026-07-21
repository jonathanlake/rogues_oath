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
| `/w <weapon> [field] <value\|reset>` | Tune a weapon. Field ∈ `damage`, `attack_beats`, `windup_beats`; omitted field = `damage`. `reset` restores all three from disk. |
| `/<weapon> <value>` | Shorthand for `/w <weapon> damage <value>` (e.g. `/longsword 5`). The command table wins over this alias, so a weapon named like a command is only reachable via `/w`. |
| `/m <monster> <field> <value\|reset>` | Tune a monster type. Field ∈ `max_hp`, `aggro_range_tiles`, `tactical_radius_tiles`, `recovery_beats`. `reset` restores all four. |
| `/god` | Toggle **your own** invulnerability. A hit on a godded target resolves as a visible no-op (grey `0` popup + "no effect (god)" log line), never a silent block. Cleared on disconnect / despawn / F5 respawn. |
| `/class <name>` | Set **your own** class (sprite today, stats later). `name` ∈ `rogue`, `knight`, `wizard`, `barbarian`, `priest`, `ranger`. Broadcasts to every peer; late joiners sync via `sync_class`. |
| `/help` | Print the command list (local only — never crosses the wire). |

## Resolution notes

- **Weapons** resolve `GameConfig.weapon_roster` (by `display_name`) first, then a filename load
  `res://resources/weapons/<name>.tres` (guarded by `ResourceLoader.exists`) — so the claw (not in the
  roster) is reachable as `/w claw ...`.
- **Monsters** resolve only by filename: `res://resources/monsters/<name>.tres` (e.g. `/m goblin ...`).
- **`reset`** re-reads the `.tres` from disk with `CACHE_MODE_IGNORE` and copies the allowlisted fields
  back onto the shared live instance.
- **`/m ... max_hp`** affects **new spawns only** (HP is seeded at spawn); the other three monster
  fields are read live. The other tunes take effect from the next adjudicated verdict (stamp-and-bake —
  in-flight commits keep their baked values).

## Scripted testing

The `cmd=` autostart knob feeds one command through the real `game_log._on_input_submitted()` entry
point (the genuine interception path), on either role: e.g. `-- host cmd=/god`,
`-- join cmd=/w longsword 3`, `cmd=/class knight`. `cmdwait=<sec>` overrides the fire delay.
