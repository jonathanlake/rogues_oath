class_name ItemType
extends Resource

## Designer-editable item template (DESIGN §2.3.7 "add a .tres, not a script"), the mirror of WeaponType
## for pickups. One ItemType per item; a non-coder adds an item or tunes its heal / commit window by
## dropping / editing a .tres under resources/items/, never by touching code. Read HOST-side for the
## GAMEPLAY fields when a referee adjudicates a use (heal + committed window); the PRESENTATION field
## (atlas_coords) is read CLIENT-side by the ground/hotbar sprite on every peer.
##
## Authoring model (Godot-canonical, same as WeaponType / MonsterType): a .tres stores ONLY values that
## differ from the script defaults below — the editor's saver STRIPS default-equal properties on every
## save, so the defaults here ARE part of the authored surface. The defaults are potion-like (a small
## usable heal), so a fresh ItemType behaves like a health potion until overridden.
##
## CHUNK-A SCOPE (v0.18.0): this is item DATA + replicated GROUND items only. The usable/heal_amount/
## use_beats fields below are authored now (the data model is whole) but NOT yet read by any referee —
## pickup, inventory state, and the use flow land in later chunks. They are documented with their eventual
## host-vs-wire read side so the resource is self-describing the moment those chunks wire them.

# ── Identity ──────────────────────────────────────────────────────────────────

## Machine + display name for this item ("health potion"). Doubles as the identity used everywhere: the
## `item_name` on a ground-item / (future) pickup / use event, and the GameConfig.item_catalog lookup key
## (item_by_name). The codebase-wide name-resolution model — events carry the NAME, peers resolve the
## resource via GameConfig — so this is what crosses the wire, never the Resource itself. Read on BOTH
## sides (host to adjudicate, client to render the log line / catalog the icon).
@export var display_name: String = "health potion"

# ── Presentation (read CLIENT-side; gameplay NEVER reads this) ─────────────────

## Sprite cell (column, row) into assets/32rogues/items.png — 0-indexed, TILE_PX (32px) per cell. The
## GroundItem's Sprite2D region is derived from this × WorldGrid.TILE_PX (WorldGrid.atlas_region), the
## same one-site region math the weapon rig / projectile use. Read CLIENT-side on every peer off the
## loaded .tres; never adjudication.
@export var atlas_coords: Vector2i = Vector2i(1, 19)

# ── Gameplay (read HOST-side by the use referee; never the wire) ───────────────

## Can a player consume / activate this from a hotbar slot (v1 use flow, LATER chunk). true = usable
## (a potion); false = an inert item (a key, a quest token) that occupies a slot but has no use action.
## Read HOST-side when the use referee adjudicates a use request — a use of a non-usable item is refused.
@export var usable: bool = true

## Hit points restored when this item is USED (LATER chunk). 0 = no heal component (a non-healing usable,
## or an inert item). Deterministic — no roll (mirrors WeaponType.damage's no-to-hit model). Read HOST-side
## by the use referee, which applies it through the SAME CombatReferee heal path a spell would; the use
## event then carries the resulting hp_after so every peer renders the bar + popup, never a client compute.
@export var heal_amount: int = 10

## BEATS the USE action OCCUPIES on the user's one timeline (DESIGN's "N-beat commit" for item use, §2.1 /
## §2.8) — the whole committed window during which the user is BUSY and cannot act, exactly like an attack's
## attack_beats or a step's glide. The referee stamps it to SECONDS at the user's resolved pace (beats ×
## beat_sec) when it accepts the use, so the commitment scales with tempo like every other action. Read
## HOST-side by the use referee at commit; the use event carries the stamped seconds so the busy/recovery
## window matches on every peer. Once started it plays to completion — no drinking-cancel (Commitment Rule).
@export var use_beats: float = 2.0
