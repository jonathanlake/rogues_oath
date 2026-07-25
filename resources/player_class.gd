class_name PlayerClass
extends Resource

## ARMOR WEIGHT class (v0.26.0, Jeff's verdict 2026-07-26 — armor phase 1 at the CLASS level; real
## equipment items + slots stay the parked milestone). The weight band a class's gear sits in, kept
## as an enum (not a number) so a designer picks from a fixed vocabulary and every consumer maps the
## band to its own dial rather than inventing a curve. Serialized in a .tres as its ordinal int.
enum ArmorWeight { UNARMORED, LIGHT, MEDIUM, HEAVY }

## Designer-editable player-class template (v0.10.0, DESIGN §2 "add a .tres, not a script"). One
## PlayerClass per class; a non-coder adds a class or re-skins one by editing / dropping a .tres under
## resources/classes/, never by touching code. Today it carries only IDENTITY + APPEARANCE — the sprite
## a player wears — but it is deliberately the future home of per-class STAT fields (starting HP, melee
## damage, speed tier, class abilities) so classes gain mechanical weight without a schema migration.
##
## Authoring model (Godot-canonical, same as WeaponType / MonsterType): a .tres stores ONLY values
## that differ from the script defaults below — the editor's saver STRIPS default-equal properties on
## every save, so the defaults here ARE part of the authored surface. The six shipped classes each
## override both fields, so the defaults are just the safe empty state for a fresh PlayerClass.
##
## Replication: the class is NEVER streamed as a Resource — the class_changed event and the sync_player_field
## RPC (main.gd) carry only its display_name, and every peer resolves the same .tres through
## GameConfig.class_by_name (the roster is the one authoring site, mirroring weapon_by_name). So a
## /class change and a late-join snap both repaint from an authored file, host-authoritative.

## Machine + display name for this class ("rogue", "knight", …). LOWERCASE and one-word: it doubles as
## the identity everywhere — the /class token, the class_changed / sync_player_field `class` field, the
## GameConfig.class_roster lookup key, and the log line ("JON becomes a knight."). Kept lowercase so the
## slash-command token (lowercased client-side) resolves it and the log reads naturally.
@export var display_name: String = ""

## Sprite cell (column, row) into assets/32rogues/rogues.png — 0-indexed. The player's Sprite2D region
## is derived from this × WorldGrid.TILE_PX (Player.set_class). Matches the historical per-spawn-slot
## tiles: rogue (3,0), knight (0,1), wizard (0,4), barbarian (0,3), priest (1,2), ranger (2,0).
@export var atlas_coords: Vector2i = Vector2i.ZERO

## The class's COMBAT PASSIVES (v0.11.0, Jeff's class-identity framework). CombatReferee runs the
## ATTACKER's list through the PassiveAbility hooks at the fixed combat seams (host-only, server-
## authoritative — see resources/passive_ability.gd). Order matters: modify_damage chains in ARRAY
## order, each passive receiving the previous one's output. Empty for a class with no passives (the
## default) — the rogue overrides it with backstab.tres. A non-coder grants a class an ability by
## dropping a PassiveAbility .tres into this array, no code edit.
@export var passives: Array[PassiveAbility] = []

## The class's ACTIVE ABILITIES (v0.20.0) — the 1-5 hotbar actions this class can trigger (ActiveAbility .tres,
## resources/active_ability.gd). Index 0 = the "1" key, up to 5. EMPTY (default) = no active abilities (the key
## does nothing). Host-adjudicated: the "use_ability" validator reads THIS list from the sender's class server-
## side (never a client value), so a class grants an active ability by dropping a .tres here — no code edit.
## knight → [shield_bash], rogue → [kick]. Ability sets swap with the class (the /class equip flow).
@export var active_abilities: Array[ActiveAbility] = []

## Stamina BONUS for this class (v0.24.0's absolute max, reshaped v0.24.5 into the codebase's
## bonus_* convention — the first per-class STAT field): the class's offset ON TOP of the global
## GameConfig.stamina_max baseline, so the ONE live knob (`/config stamina_max N`) scales every
## class together and the rogue stays ahead. Resolved HOST-side and LAZILY (at each pool
## seed/reset, never cached at spawn) so a mid-session /class change or knob turn takes effect at
## the next battle entry. 0 = baseline; rogue ships +1 (Jeff: the rogue is the mobile class).
@export var bonus_stamina: int = 0

## The class's ARMOR WEIGHT band (v0.26.0 armor phase 1). UNARMORED (default) = the safe empty state
## for a fresh PlayerClass. Today it drives the stamina REST-TO-RECOVER idle wait (DESIGN §2.2.10 —
## heavier armor rests slower; the per-weight dials land in a later chunk of this version), and it is
## deliberately the hook for the ENVISIONED spell / mobility penalties that a weight band should carry
## (a heavy-armored caster fumbling, a light class keeping its speed). Resolved HOST-side and LAZILY
## at each read, never cached at spawn, so a mid-session /class change lands at the next read — the
## same rule bonus_stamina follows. Shipped: rogue LIGHT, knight MEDIUM.
@export var armor_weight: ArmorWeight = ArmorWeight.UNARMORED

## PHYSICAL damage reduction as a FRACTION absorbed (v0.26.0 armor phase 1): 0.0 (default) = no armor,
## 0.25 = a quarter of every physical hit turned aside, 1.0 = immune. Applied HOST-side at the ONE
## apply_damage mitigation seam (CombatReferee._phys_reduction_of), AFTER the attacker's passive
## modify_damage chain and BEFORE the HP subtraction, so a backstab is priced then armored. PHYSICAL
## only: "smite" (magical) and "admin" (/mi hp pokes, /mi kill) pass through unreduced. Read LIVE on
## every hit from the DEFENDER's class, so a /class swap retunes the very next hit. Rounds half-up and
## keeps apply_damage's 0 floor. Shipped: rogue 0.10, knight 0.25.
@export_range(0.0, 1.0) var phys_damage_reduction: float = 0.0

## The class's WEAPON ROSTER (v0.17.0) — the loadout this class carries and Tab-cycles through. EMPTY (the
## default) = use the GLOBAL GameConfig.weapon_roster fallback (the shipped dagger↔longsword cycle); NON-EMPTY
## overrides it, so the swap validator cycles THIS list and a host-side set_class equips its FIRST entry. The
## roster is resolved HOST-side from the player's current class (server-authoritative — never client inference).
## ranger → [longsword, bow]. Designer-editable (add / reorder .tres here, no code).
@export var weapon_roster: Array[WeaponType] = []
