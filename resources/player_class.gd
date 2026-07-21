class_name PlayerClass
extends Resource

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
## Replication: the class is NEVER streamed as a Resource — the class_changed event and the sync_class
## RPC (main.gd) carry only its display_name, and every peer resolves the same .tres through
## GameConfig.class_by_name (the roster is the one authoring site, mirroring weapon_by_name). So a
## /class change and a late-join snap both repaint from an authored file, host-authoritative.

## Machine + display name for this class ("rogue", "knight", …). LOWERCASE and one-word: it doubles as
## the identity everywhere — the /class token, the class_changed / sync_class `class` field, the
## GameConfig.class_roster lookup key, and the log line ("JON becomes a knight."). Kept lowercase so the
## slash-command token (lowercased client-side) resolves it and the log reads naturally.
@export var display_name: String = ""

## Sprite cell (column, row) into assets/32rogues/rogues.png — 0-indexed. The player's Sprite2D region
## is derived from this × WorldGrid.TILE_PX (Player.set_class). Matches the historical per-spawn-slot
## tiles: rogue (3,0), knight (0,1), wizard (0,4), barbarian (0,3), priest (1,2), ranger (2,0).
@export var atlas_coords: Vector2i = Vector2i.ZERO
