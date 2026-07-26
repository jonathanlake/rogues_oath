class_name PlayerClass
extends Resource

## (v0.27.0: the `ArmorWeight` enum and the `armor_weight` / `phys_damage_reduction` fields that lived
## here for v0.26.0's class-level armor phase 1 are GONE. Armor is a WORN ITEM now — the enum's canonical
## home is `ItemType` and the numbers are authored on the armor `.tres` files — and a class expresses its
## armor identity by which item it STARTS in (`starting_body_armor` below). Nothing was lost: rogue still
## begins in leather 0.10/LIGHT, knight in chainmail 0.25/MEDIUM; those values simply moved onto objects
## the player can now take off, hand over, or upgrade. DESIGN §2.3.8 / §2.10.)

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
## the next battle entry. 0 = baseline.
## v0.26.0: EVERY shipped class is 0 — the rogue's +1 was dropped when Jeff's verdict made the pool a
## single point (a "+1" doubles a binary budget, which is a different mechanic, not a tuning nudge).
## The field STAYS as the per-class hook: the rogue's mobility edge now lives in the WEIGHT of the armor
## it starts in (a faster idle wait — see starting_body_armor), and a future class may legitimately
## carry a deeper pool.
@export var bonus_stamina: int = 0

## The class's STARTING BODY ARMOR (v0.27.0 equipment phase 2) — the EQUIPMENT-category ItemType a player
## of this class begins WEARING. Null (default) = starts unarmored. Exactly two host-side consumers:
## Player._ready SEEDS it right after the class seed (so a fresh spawn / F5 respawn is dressed on every
## peer, deterministically from shared config — the same shape as the scene-default weapon seed), and the
## `/class` validator equips it on a live class change (busy-SKIPPED like the weapon roster's first entry,
## so gear can never be re-armed inside a committed window). Deliberately NOT applied inside `set_class`:
## that runs on every peer for every class event, and a silent gear swap there would bypass the busy gate
## the Commitment Rule needs. The ITEM now carries what the class used to (weight band + physical
## reduction), so this is the whole of a class's armor identity. Shipped: rogue → leather armor
## (LIGHT/0.10), knight → chainmail (MEDIUM/0.25) — v0.26.0's numbers, now on objects you can take off.
@export var starting_body_armor: ItemType = null

## The class's WEAPON ROSTER (v0.17.0) — the loadout this class carries and Tab-cycles through. EMPTY (the
## default) = use the GLOBAL GameConfig.weapon_roster fallback (the shipped dagger↔longsword cycle); NON-EMPTY
## overrides it, so the swap validator cycles THIS list and a host-side set_class equips its FIRST entry. The
## roster is resolved HOST-side from the player's current class (server-authoritative — never client inference).
## ranger → [longsword, bow]. Designer-editable (add / reorder .tres here, no code).
@export var weapon_roster: Array[WeaponType] = []
