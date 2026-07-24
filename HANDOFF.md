# HANDOFF — Active-ability HUD (the one remaining piece), 2026-07-24

The active-ability MECHANICS + the STUN status shipped and are verified two-instance (v0.20.0 stun,
v0.20.1 abilities). What's LEFT is the **HUD**, which I deliberately did NOT do overnight because it's a
layout-heavy `hud.gd` change that wants visual iteration (icon choices, spacing) — a Jon/Jeff activity, and
not something I can visually verify unattended. This file specs it so it's a clean pickup. Delete this file
in the commit that lands the HUD.

## What works TODAY (test it)
- `/class knight` then stand next to a goblin and press **1** → Shield Bash (2 dmg + 3-beat stun).
- `/class rogue`, press **1** → Kick (1 dmg + 3-beat stun). Backstab passive still works too.
- `/stun me` (bonk + you can't act 3 beats) or `/stun goblin` (a goblin freezes, overhead icon).
- The stunned target shows a spinning yellow overhead icon; log reads "X bashes/kicks Y for N" + "Y is stunned!".
- CAVEAT the HUD fixes: the hotbar STILL shows items (potion/club), but 1-5 now fire ABILITIES — a visual
  mismatch. Items are still usable by LEFT-CLICK on their hotbar slot (unchanged).

## The HUD task (all in `ui/hud/hud.gd`, + maybe `ui/hud/hud.tscn`)
Goal: top hotbar row = the class's ACTIVE ABILITIES with "1"-"5" keycaps; items move to a separate lower
**Backpack** panel (left-click to use/equip, exactly as the hotbar does today).

Exact seams (from the overnight architecture map):
1. **Hotbar → abilities.** `_build_inventory` (~hud.gd:624-662) builds a 5×4 grid; row 0 is the accented
   "hotbar". Repaint row 0 from the LOCAL player's `player_class.active_abilities` (icon = `ability.atlas_coords`
   into items.png; the ability icon atlas is `resources/abilities/*.tres` — pick real cells, they're placeholder
   (0,0)/(1,0) now). Add the "1".."5" keycap label (`_make_socket` supports a numeral label, ~hud.gd:731-747;
   the keycap plan is noted at hud.gd:638-639). These slots are NON-interactive by click (the KEY drives them) —
   or optionally emit a new `ability_activated(index)` signal that main routes to `use_ability` (parity with the
   keys). The icon-paint currently lives in `_refresh_hotbar` (~hud.gd:693-704) reading `Player.inventory` — split
   it: `_refresh_hotbar` now reads `active_abilities`, a NEW `_refresh_backpack` reads `Player.inventory`.
2. **Items → Backpack panel.** Add a new `Backpack` `PanelContainer` to `RightVBox` (after `Inventory`, hud.tscn
   ~26-45) OR repurpose rows 1-3 of the existing grid. Show `Player.inventory` items with the SAME `gui_input →
   slot_activated(i)` wiring that exists today (`_on_slot_gui_input`, ~hud.gd:724-726 → `main._on_inventory_slot_
   activated`, ~main.gd:1104). Left-click still routes to `use_item`/`equip_item` by content type — NO gameplay
   change, only which panel the slots live in. Note: `hud.gd:329-336` `_column_stack_min_h` auto-refits the HUD
   zoom, so a new panel "just works" but grows min-height (test on a small window).
3. **Off-hand shield (nice-to-have).** An empty `[Off]` socket already exists (~hud.gd:602). For now the shield is
   only the knight's `shield_bash` ability (there's no equippable off-hand ITEM yet). Options: (a) show a shield
   glyph in `[Off]` when the class has a shield ability (cosmetic), or (b) leave it and make a real off-hand
   `ItemType`/equip slot a follow-up (the cleaner path — coordinate with the item/equip system, §2.10). I'd do (b).

Verify: launch windowed (`-- host`), `/class knight`, screenshot — the hotbar shows the Shield Bash icon with a
"1" keycap and the potion sits in the Backpack. (Windowed screenshot via the `screenshot=` knob; a fresh
`--import` is needed after adding any `.tres`/`class_name`.)

## Also parked (morning-report notes, not blocking)
- Heal-branch pace-report staleness (review #4, pace-only, low) — a healing shaman doesn't report engagement.
- Tuning tension (review #5): shaman `aggro_range 3` vs `smite_range 12` — it can't open with a ranged smite
  (must be approached to 3 first). This is the "no pre-aggro cast" behavior you asked for; the 12 range only
  matters once engaged. If you want it to open with a smite, widen aggro — but that reintroduces pre-aggro casts.
- Ability icons are placeholder atlas cells; the off-hand shield is ability-only (no equippable item yet).
- `heal_recovery_beats` / `heal_cast_beats` / `smite_*` are all `/m`-tunable now (v0.19.10).

## Dev tools added this session
- `/stun [me|<monster>] [beats]`, `/config <alias>` (v0.19.7), the `eventlog=<path>` debug knob (dumps the
  NetEvents stream to a file — the deterministic assertion source; also the joined-observer tool), and the
  `ability=<index>` / `abilitywait=` harness knobs.
