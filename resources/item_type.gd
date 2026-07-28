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

## ARMOR WEIGHT band (v0.27.0 — MOVED here from PlayerClass, which held it for the v0.26.0 class-level
## phase 1). This resource is now the canonical home because weight is a property of a WORN OBJECT, not
## of a class: the band a wearer sits in is read off the item in its body slot. Kept as an enum (not a
## number) so a designer picks from a fixed vocabulary and every consumer maps the band to its own dial
## — the stamina rest-to-recover wait (DESIGN §2.2.10), the armor flat-reduction table (§2.3.8), and the
## envisioned spell/mobility penalties. Serialized in a .tres as its ordinal int, so NEVER reorder —
## append only.
enum ArmorWeight { UNARMORED, LIGHT, MEDIUM, HEAVY }

## WHICH SOCKET a wearable occupies (v0.27.1). Split out of `category` because EQUIPMENT is a
## category, not a slot: until now every EQUIPMENT item was treated as BODY ARMOR by both the host
## equip path and the client's routing, so the off-hand kite shield DESIGN §2.11.1 is waiting on would
## have silently REPLACED worn chainmail. This enum is the discriminator that makes that a clean
## refusal instead. Only BODY is implemented (DESIGN §2.10's remaining sockets are future work) —
## anything else rejects with its own reason. Serialized as an ordinal, so NEVER reorder — append only.
enum EquipSlot { BODY, OFF_HAND, HEAD, HANDS, FEET, RING, AMULET }


# ── Identity ──────────────────────────────────────────────────────────────────

## Machine + display name for this item ("health potion"). Doubles as the identity used everywhere: the
## `item_name` on a ground-item / (future) pickup / use event, and the GameConfig.item_catalog lookup key
## (item_by_name). The codebase-wide name-resolution model — events carry the NAME, peers resolve the
## resource via GameConfig — so this is what crosses the wire, never the Resource itself. Read on BOTH
## sides (host to adjudicate, client to render the log line / catalog the icon).
@export var display_name: String = "health potion"

## PROSE for the HUD tooltip (v0.39.0), shown beneath the item's name. PRESENTATION ONLY — no referee
## reads it, and it never crosses the wire (every peer loads the same resource).
##
## THE DISCIPLINE, one line: NUMBERS ARE DERIVED, PROSE IS AUTHORED. Do NOT type a heal amount or an
## armour percentage in here — the tooltip builder reads those off the fields themselves (hud.gd's
## _item_tooltip), so the text can never disagree with a value someone just retuned in the debug panel.
## This field is for what the numbers cannot say. Empty (the default) leaves the derived line standing
## alone, which is the right answer for the potion and both armours.
@export_multiline var description: String = ""

# ── Taxonomy (read HOST-side for pickup rules; never the wire) ─────────────────

## What KIND of thing this is (v0.21.0). Before this, "what kind of thing is this" was inferred from WHICH
## CATALOG resolved the name (item_catalog → consumable-ish, weapon_catalog → weapon) — an implicit taxonomy
## with no authoring surface. This makes it explicit and designer-editable: an enum-typed @export renders as
## an inspector dropdown, so a non-coder picks the category from a list (no magic ints in a .tres).
##   POTION    — auto-picked-up by walking over it (the only autopickup category, v0.21.0).
##   EQUIPMENT — armour / rings / boots. Manual pickup (G) only. Two real items ship since v0.27.0
##               (leather_armor, chainmail) and the BODY socket equips them, routed by `equip_slot`
##               below; the other EIGHT HUD sockets are still cosmetic and the rest of the slot model
##               is still future work (DESIGN §2.10). (v0.28.1 comment fix: this said "wired but EMPTY
##               today — no such .tres exists yet, the sockets are cosmetic, the equip-slot model is a
##               separate milestone" — true at v0.21.0, superseded by equipment phase 2.)
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
## or an inert item). Deterministic — no roll (a heal is a fixed amount; only weapon DAMAGE is banded,
## WeaponType.damage_min/damage_max v0.26.1, and to-hit stays deterministic either way). Read HOST-side
## by the use referee, which applies it through the SAME CombatReferee heal path a spell would; the use
## event then carries the resulting hp_after so every peer renders the bar + popup, never a client compute.
@export var heal_amount: int = 10

## Which SOCKET this wearable occupies (v0.27.1) — meaningful for an EQUIPMENT item, ignored for a
## POTION. Read HOST-side by the equip validator, which routes on it: BODY takes the body-armor path,
## and every other value is REFUSED ("no slot for that yet") until §2.10's remaining sockets land. The
## client keeps submitting `equip_item` for any EQUIPMENT item — the host owns the verdict (§2.5), so
## this never has to be read client-side to decide an intent.
##
## THE DEFAULT IS BODY because body is the one implemented socket: a designer who authors a new armor
## piece and forgets this field gets the working path, not a dead one. That is the opposite polarity
## from `category` above (which fails CLOSED) and deliberately so — the risk here is an unequippable
## item, not an item that grabs a permission it shouldn't. Note the .tres authoring model: the saver
## STRIPS default-equal values, so BODY is authored by omission; the two shipped armors state it
## explicitly anyway, as the readable record of which socket they claim.
@export var equip_slot: EquipSlot = EquipSlot.BODY

# ── Worn armor (EQUIPMENT category only; read HOST-side by the referees) ───────

## The WEIGHT BAND this item puts its wearer in (v0.27.0 equipment phase 2). Meaningful only for an
## EQUIPMENT item that occupies the BODY slot; every other item leaves it UNARMORED (the default), which
## is also the "no armor" answer the referees read for an empty slot. Two host-side consumers, both live
## (never cached): MoveReferee._regen_idle_beats_of picks the stamina rest wait from it (heavier armor
## rests slower — DESIGN §2.2.10, and since v0.26.0 that IS the armor cost curve), and
## CombatReferee's armor seam picks the FLAT reduction from it (GameConfig.armor_flat_reduction_*).
## Shipped: leather armor LIGHT, chainmail MEDIUM. The weight-PROMOTION rule (heaviest worn piece across
## several slots sets the band) is still future — with ONE armor slot, the body item's band IS the band.
@export var armor_weight: ArmorWeight = ArmorWeight.UNARMORED

## PHYSICAL damage reduction as a FRACTION absorbed while this item is worn (v0.27.0 equipment phase 2):
## 0.0 (default) = no mitigation, 0.25 = a quarter of every physical hit turned aside, 1.0 = immune.
## Applied HOST-side at the ONE apply_damage mitigation seam (CombatReferee._phys_reduction_of), AFTER the
## attacker's passive modify_damage chain and BEFORE the HP subtraction, and MIN-combined with the flat
## band reduction (§2.3.8). PHYSICAL only: "smite" (magical) and "admin" (/mi pokes) pass through
## unreduced. Read LIVE off the DEFENDER's worn item every hit, so an equip retunes the very next blow.
## Shipped: leather armor 0.10, chainmail 0.25 (the numbers PlayerClass carried in v0.26.0 phase 1).
@export_range(0.0, 1.0) var phys_damage_reduction: float = 0.0

## BEATS the USE action OCCUPIES on the user's one timeline (DESIGN's "N-beat commit" for item use, §2.1 /
## §2.8) — the whole committed window during which the user is BUSY and cannot act, exactly like an attack's
## recovery_beats or a step's glide. The referee stamps it to SECONDS at the user's resolved pace (beats ×
## beat_sec) when it accepts the use, so the commitment scales with tempo like every other action. Read
## HOST-side by the use referee at commit; the use event carries the stamped seconds so the busy/recovery
## window matches on every peer. Once started it plays to completion — no drinking-cancel (Commitment Rule).
@export var use_beats: float = 2.0
