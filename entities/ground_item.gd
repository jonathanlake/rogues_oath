class_name GroundItem
extends Node2D

## A replicated WORLD item lying on a tile (v0.18.0, inventory chunk A). NOT an Entity, DELIBERATELY: an
## Entity carries the id/tile/glide/HP contract and — crucially — CLAIMS OCCUPANCY through the referees. A
## ground item claims NONE: players glide OVER it (a pickup sits UNDER foot, it is not a body), and the move
## referee never sees it. So it is a plain Node2D that only needs to draw itself at a tile and remember what
## it is; pickup / inventory / use are LATER chunks (this chunk is spawn + display only).
##
## Replication: Main's ItemSpawner (a MultiplayerSpawner) rebuilds one of these on every peer from a config
## dict {item_id, type_path, tile}. The spawn_function load()s the .tres by PATH (never a Resource over the
## wire — every peer loads the same authored file) and sets the public fields below BEFORE add_child, so
## _ready reads them to build the sprite + position. Host-authored only; clients just render the replica.
##
## Component note (CLAUDE.md): code-built chrome (the Sprite2D is made in _ready, no scene) mirrors
## projectile.gd's ITEMS_TEX + region + NEAREST-filter pattern — one texture, one region windowed out of the
## 32rogues items sheet. Everything it holds is event/config primitives (an id, a name, a tile, an atlas
## cell); it never touches occupancy or HP.

const ITEMS_TEX: Texture2D = preload("uid://5r3hjjukcluj")  # assets/32rogues/items.png

# Host-assigned UNIQUE id for this ground item (Main's _next_item_id). POSITIVE and monotonic — a SEPARATE
# id space from entity ids (which are peer ids / negative monster ids): a ground item is not a body in the
# referees' one occupancy space, so it never needs to avoid colliding with an entity id. Set by the spawn
# function before add; read to key the node (its name) and to target it in later pickup chunks.
var item_id: int = 0
# The item's display_name, resolved on every peer from the loaded .tres (the name-resolution model — the
# wire carries the type PATH, the .tres carries the name). Held for later pickup/log lines; set before add.
var item_name: String = ""
# The logical tile this item lies on. Position derives from it (tile center) in _ready — never a pixel
# position over the wire. Set by the spawn function before add.
var tile: Vector2i = Vector2i.ZERO
# The 32rogues items.png cell (col, row) for the icon, resolved on every peer from the loaded .tres. Set
# before add so _ready can window the sprite region out of the sheet. Presentation only.
var atlas_coords: Vector2i = Vector2i.ZERO

var _sprite: Sprite2D = null


func _ready() -> void:
	# Position at the tile CENTER, the same tile→pixel derivation every replicated node uses (never a
	# pixel position over the wire). Set from the pre-tree `tile` field the spawn function assigned.
	position = WorldGrid.tile_to_world(tile)
	_sprite = Sprite2D.new()
	_sprite.texture = ITEMS_TEX
	_sprite.region_enabled = true
	_sprite.region_rect = WorldGrid.atlas_region(atlas_coords)
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Draw the pickup SMALLER than a full tile (0.75×) so it reads as an object lying on the floor, not as
	# an occupant filling the cell — a deliberate presentation cue that this is loot to step onto, not a
	# body to bump. No rotation (an item just lies flat, unlike the projectile's aimed arrow).
	_sprite.scale = Vector2(0.75, 0.75)
	add_child(_sprite)


## Host-side scan: the GroundItem currently on `tile` within the `items` container, or null if none. The ONE
## item-collision / pickup-target predicate, SHARED by Main's spawn guard (_item_on_tile) and
## InventoryReferee.try_pickup — items claim no referee occupancy (a body glides OVER them), so "is there an
## item here" is answered by scanning the container directly rather than the move referee's tile bookkeeping.
## Static so both host-only callers share ONE implementation without reaching across each other. Cheap: a
## handful of ground items per room at most. Host-only by usage (both callers run only on the server).
static func on_tile(items: Node2D, tile: Vector2i) -> GroundItem:
	for node in items.get_children():
		var gi := node as GroundItem
		if gi != null and gi.tile == tile:
			return gi
	return null
