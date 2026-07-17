class_name WorldGrid
extends RefCounted

## The room's LOGICAL grid — the single source of truth for what's wall, what's floor,
## and where tiles sit in pixel space. The TileMapLayer in main.tscn is PRESENTATION only:
## main.gd paints it FROM this data at runtime, so the picture can never disagree with the
## adjudication grid. This room is a disposable prototype fixture — procedural dungeon
## generation replaces the hardcoded ROOM_LAYOUT at ROADMAP M4a.
##
## All-static: never instanced. Every function is a pure query over the consts below; there is
## no per-node state to hold. (extends RefCounted only so `class_name` is legal — no instances
## are made.)

## Pixels per tile edge (square). Matches the 32rogues tileset cell size.
const TILE_PX := 32

## 20 columns × 11 rows. '#' = wall, '.' = floor. Read as ROOM_LAYOUT[row][col], i.e.
## ROOM_LAYOUT[tile.y][tile.x]. Features, all purpose-built for M2 demos:
##  - full wall border,
##  - two 2-tile pillars left-of-center (row 3 and row 7, cols 5-6),
##  - one diagonal-gate off-center-right: walls at (13,4) and (14,3) touch only at a corner,
##    with their flanking tiles (13,3) and (14,4) left as floor — a purpose-built spot for
##    chunk 2 to demonstrate the corner rule (a diagonal squeeze between the two walls is
##    rejected even though both endpoints are floor).
const ROOM_LAYOUT: Array[String] = [
	"####################",  # row 0  — border
	"#..................#",  # row 1
	"#..................#",  # row 2
	"#....##.......#....#",  # row 3  — pillar (5,6); gate wall (14,3)
	"#............#.....#",  # row 4  — gate wall (13,4)
	"#..................#",  # row 5
	"#..................#",  # row 6
	"#....##............#",  # row 7  — pillar (5,6)
	"#..................#",  # row 8
	"#..................#",  # row 9
	"####################",  # row 10 — border
]


## Grid extent in tiles: Vector2i(columns, rows).
static func size() -> Vector2i:
	return Vector2i(ROOM_LAYOUT[0].length(), ROOM_LAYOUT.size())


## True if the tile coordinate lies within the grid rectangle.
static func in_bounds(tile: Vector2i) -> bool:
	var s := size()
	return tile.x >= 0 and tile.y >= 0 and tile.x < s.x and tile.y < s.y


## True if the tile is a wall. Out-of-bounds counts as wall (nothing off-grid is enterable).
static func is_wall(tile: Vector2i) -> bool:
	if not in_bounds(tile):
		return true
	return ROOM_LAYOUT[tile.y][tile.x] == "#"


## True if a body may occupy this tile: in-bounds AND not a wall.
static func is_walkable(tile: Vector2i) -> bool:
	return in_bounds(tile) and not is_wall(tile)


## Tile → world pixels at the tile's CENTER (tile*TILE_PX + half-tile), so sprites land on
## px ≡ TILE_PX/2 (mod TILE_PX). This is the position a player node renders at.
static func tile_to_world(tile: Vector2i) -> Vector2:
	var half := TILE_PX / 2
	return Vector2(tile.x * TILE_PX + half, tile.y * TILE_PX + half)


## World pixels → the tile that contains them (floor-divide by TILE_PX). Inverse of
## tile_to_world for any point inside a tile's cell.
static func world_to_tile(pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(pos.x / TILE_PX)), int(floor(pos.y / TILE_PX)))


# ── Pathfinding ───────────────────────────────────────────────────────────────

# Lazily-built A* over the room, shared by every caller (static, like everything here). Solids
# come from is_wall only — OCCUPANCY IS DELIBERATELY NOT IN THIS GRID: bodies are volatile
# (they move every step, and per the corner rule bodies don't block diagonal squeezes), so
# callers route around them per-query via find_path's `avoid` parameter instead of mutating
# shared state. NOTE for M4a: dungeon regeneration must drop this cache (rebuild from the new
# layout) — a stale grid would path through the old room's walls.
static var _astar: AStarGrid2D = null


## 8-way path from `from` to `to` over the walkable grid, as tile coords with path[0] == from.
## Empty array = unreachable (or an endpoint is a wall/out of bounds). `avoid` tiles are made
## temporarily solid for THIS query only (transient obstacles — other bodies), restored after.
## Diagonals follow the corner rule's wall half exactly (DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES):
## a squeeze between two corner-touching walls is never in a returned path.
static func find_path(from: Vector2i, to: Vector2i, avoid: Array[Vector2i] = []) -> Array[Vector2i]:
	if not in_bounds(from) or not in_bounds(to):
		return []
	if _astar == null:
		_build_astar()
	# A solid origin can't happen today (players only ever stand on floor), so it means a spawn
	# or bookkeeping bug upstream — warn loudly instead of letting walks silently do nothing.
	if _astar.is_point_solid(from):
		push_warning("[WorldGrid] find_path from solid tile %s — no path (upstream bug?)" % from)
		return []
	# Temp-solid the avoid tiles; track only the ones we actually flipped so restore is exact
	# (walls are already solid, and `from` is never flipped — a solid start yields no path).
	var flipped: Array[Vector2i] = []
	for tile in avoid:
		if in_bounds(tile) and tile != from and not _astar.is_point_solid(tile):
			_astar.set_point_solid(tile, true)
			flipped.append(tile)
	var packed := _astar.get_id_path(from, to)
	for tile in flipped:
		_astar.set_point_solid(tile, false)
	var path: Array[Vector2i] = []
	for point in packed:
		path.append(point)
	return path


## Build the shared grid once from ROOM_LAYOUT: region = the room rectangle, solids = walls,
## octile heuristics (the natural 8-way distance), and ONLY_IF_NO_OBSTACLES diagonals — which
## is precisely the corner rule's wall half, so client paths never propose a step the referee's
## corner check would refuse for walls. (Body occupancy is per-query `avoid`, never baked in.)
static func _build_astar() -> void:
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(Vector2i.ZERO, size())
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	var grid_size := size()
	for y in grid_size.y:
		for x in grid_size.x:
			var tile := Vector2i(x, y)
			if is_wall(tile):
				_astar.set_point_solid(tile, true)
