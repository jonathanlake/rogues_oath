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

## The item taxonomy (v0.21.0). Declared HERE (on the item resource) rather than on GameConfig because it is a
## property OF an item type — GameConfig.category_of() merely resolves a bag/ground NAME to one of these.
## Ordinals are part of the authored surface (a .tres stores the int), so NEVER reorder or insert mid-list —
## append only, or every authored .tres silently re-categorises.
enum Category { POTION, EQUIPMENT, WEAPON }


# ── Identity ──────────────────────────────────────────────────────────────────

## Machine + display name for this item ("health potion"). Doubles as the identity used everywhere: the
## `item_name` on a ground-item / (future) pickup / use event, and the GameConfig.item_catalog lookup key
## (item_by_name). The codebase-wide name-resolution model — events carry the NAME, peers resolve the
## resource via GameConfig — so this is what crosses the wire, never the Resource itself. Read on BOTH
## sides (host to adjudicate, client to render the log line / catalog the icon).
@export var display_name: String = "health potion"

# ── Taxonomy (read HOST-side for pickup rules; never the wire) ─────────────────

## What KIND of thing this is (v0.21.0). Before this, "what kind of thing is this" was inferred from WHICH
## CATALOG resolved the name (item_catalog → consumable-ish, weapon_catalog → weapon) — an implicit taxonomy
## with no authoring surface. This makes it explicit and designer-editable: an enum-typed @export renders as
## an inspector dropdown, so a non-coder picks the category from a list (no magic ints in a .tres).
##   POTION    — auto-picked-up by walking over it (the only autopickup category, v0.21.0).
##   EQUIPMENT — armour / rings / boots: wired but EMPTY today (no such .tres exists yet; the HUD's equipment
##               sockets are cosmetic and the equip-slot model is a separate milestone). Manual pickup (G) only.
##   WEAPON    — for completeness of the taxonomy. A WeaponType is NOT an ItemType and is never authored here:
##               a weapon answers WEAPON by virtue of living in GameConfig.weapon_catalog (see
##               GameConfig.category_of). This value exists so the enum is total, not because it is authored.
##
## THE DEFAULT IS EQUIPMENT, DELIBERATELY — it must FAIL CLOSED. A designer who adds a new item .tres and
## forgets this field gets the RESTRICTIVE outcome (walk-over does nothing; you must press G), never the
## permissive one. Defaulting to POTION would silently opt every forgotten field into the exact autopickup
## behaviour the category gate exists to restrict, and the mistake would be invisible in play — the item just
## quietly leaps into your bag. Note the .tres authoring model above (the saver STRIPS default-equal values),
## so this default IS the authored value for any file that omits the field: it has to be the safe one.
##
## RULES-ONLY for now (v0.21.0): category gates AUTOPICKUP and nothing else — no bag sorting, no icon tinting,
## no slot restrictions. The bag stays a flat pickup-order list. Read HOST-side by InventoryReferee through
## GameConfig.category_of; never crosses the wire (events carry the item NAME, peers resolve the category).
@export var category: Category = Category.EQUIPMENT

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
